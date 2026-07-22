//! Walks `@import`/`@embedFile` edges outward from the real compile-graph
//! roots (as reported by the build manifest, see `build/manifest.zig`) to
//! find every `.zig` file actually reachable -- the set Zippy should lint.
//!
//! This is what makes bare `zippy` in a project with a `build.zig` behave
//! like a builder mode instead of a "lint every `.zig` file under the tree"
//! mode: a project can have dead files, WIP playgrounds, or files for a
//! target that isn't the one being built, and none of those are part of
//! what actually compiles. Only files reachable from a real root are.
const std = @import("std");
const Source = @import("../Source.zig");
const Ast = std.zig.Ast;

/// A path queued for the worklist below, paired with whether it should be
/// parsed for its own `@import`/`@embedFile` edges. An `@import` target is
/// itself Zig source that may import further files, so it's followed
/// recursively. An `@embedFile` target is data compiled into the binary --
/// it belongs in the reachable set, but it isn't necessarily even valid Zig
/// (it's just a blob `@embedFile` slurps in), so walking it for further
/// imports would be wrong even on the occasions it happens to parse.
const WorkItem = struct {
    /// Owned; freed once popped off the worklist.
    path: []const u8,
    recurse: bool,
};

/// Walks `@import`/`@embedFile` edges from `roots` and returns the
/// canonical (symlink-resolved) absolute paths of every `.zig` file
/// reachable from them: `roots` themselves, every file transitively
/// `@import`-ed from them, and every file named in an `@embedFile(...)`
/// (added to the set but not itself parsed -- see `WorkItem`).
///
/// `roots` must already be absolute paths (as `build/manifest.zig`'s
/// `Root.path` provides); resolving a relative path against an unspecified
/// "current directory" isn't a decision this walk should make on the
/// caller's behalf, so it asserts instead of guessing.
///
/// A candidate that doesn't exist, isn't readable, or fails to resolve is
/// skipped silently rather than erroring: enforcing that every `@import`
/// resolves is the real Zig compiler's job, and it already does that (and
/// reports it) far better than a second, partial copy of the same check
/// living here would. Likewise `@import("std")` or any other bare module
/// name (no `.zig` target) is skipped -- it names a module, not a file on
/// disk, so there is nothing for this file-level walk to add.
///
/// Returns a map used as a set (`void` values). The caller owns it: free
/// every key with `gpa`, then `deinit(gpa)` the map itself.
pub fn collect(
    gpa: std.mem.Allocator,
    io: std.Io,
    roots: []const []const u8,
) !std.StringHashMapUnmanaged(void) {
    var result: std.StringHashMapUnmanaged(void) = .empty;
    errdefer {
        var it = result.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        result.deinit(gpa);
    }

    var worklist: std.ArrayList(WorkItem) = .empty;
    defer {
        for (worklist.items) |item| gpa.free(item.path);
        worklist.deinit(gpa);
    }

    for (roots) |root| {
        std.debug.assert(std.fs.path.isAbsolute(root));
        const path = try gpa.dupe(u8, root);
        errdefer gpa.free(path);
        try worklist.append(gpa, .{ .path = path, .recurse = true });
    }

    while (worklist.pop()) |item| {
        defer gpa.free(item.path);

        const canonical = (try canonicalize(gpa, io, item.path)) orelse continue;

        {
            errdefer gpa.free(canonical);
            const gop = try result.getOrPut(gpa, canonical);
            if (gop.found_existing) {
                // Already visited (possibly via a different, non-canonical
                // spelling, e.g. through a `..` or a symlink) -- this is
                // what guards the walk against `@import` cycles.
                gpa.free(canonical);
                continue;
            }
            gop.value_ptr.* = {};
        }

        if (!item.recurse) continue; // `@embedFile` target: added, not parsed.

        try expand(gpa, io, canonical, &worklist);
    }

    return result;
}

/// Resolves `abs_path` to its canonical (symlink-free) absolute form.
/// Returns `null` -- a silent skip, see `collect`'s doc comment -- for any
/// failure except allocation failure, which always propagates.
///
/// `pub` because `build/dead_file.zig` calls this directly rather than
/// keeping its own copy: `reachable.collect`'s set keys and `dead_file.find`'s
/// candidates MUST canonicalize the exact same way, or a file that really is
/// reachable would look dead purely from a path-spelling difference (a
/// symlink, a relative-vs-absolute form, a stray `.`/`..`). Sharing this one
/// function is what makes that drift impossible instead of merely unlikely.
pub fn canonicalize(gpa: std.mem.Allocator, io: std.Io, abs_path: []const u8) !?[]const u8 {
    const Dir = std.Io.Dir;
    const sentineled = Dir.realPathFileAbsoluteAlloc(io, abs_path, gpa) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer gpa.free(sentineled);
    // Re-dupe into a plain (non-sentineled) allocation before this becomes a
    // map key. `realPathFileAbsoluteAlloc` returns `[:0]u8`; the caller of
    // `collect` frees each key as a plain `[]const u8` (that's the map's key
    // type), and `Allocator.free` only restores the sentinel byte to the
    // freed range when the *static type* at the free call site still spells
    // it out (`std.mem.absorbSentinel`). Storing the `[:0]u8` allocation
    // straight into the map and later freeing it through a `[]const u8`
    // view would under-free by one byte on every entry.
    return try gpa.dupe(u8, sentineled);
}

/// Parses the `.zig` file at `path` (already canonicalized) and pushes its
/// `@import`/`@embedFile` targets onto `worklist`. Anything that stops this
/// from happening -- `path` doesn't end in `.zig`, can't be read, or fails
/// to parse -- is a silent skip (same rationale as `collect`'s doc comment:
/// not this walk's job to enforce).
fn expand(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    worklist: *std.ArrayList(WorkItem),
) !void {
    if (!std.mem.endsWith(u8, path, ".zig")) return;

    var src = Source.load(io, gpa, path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer src.deinit(gpa);

    const tree = &src.ast;
    // `path` is absolute (canonicalized by our only caller), so it always
    // has a parent; the fallback is unreachable in practice and only here
    // to keep this function total instead of asserting.
    const dir = std.fs.path.dirname(path) orelse "/";

    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @enumFromInt(idx);
        switch (tree.nodeTag(node)) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
            else => continue,
        }

        const builtin_name = tree.tokenSlice(tree.nodeMainToken(node));
        const is_import = std.mem.eql(u8, builtin_name, "@import");
        const is_embed = std.mem.eql(u8, builtin_name, "@embedFile");
        if (!is_import and !is_embed) continue;

        var buf: [2]Ast.Node.Index = undefined;
        const params = tree.builtinCallParams(&buf, node) orelse continue;
        if (params.len != 1) continue; // not the one-string-arg shape we recognize
        if (tree.nodeTag(params[0]) != .string_literal) continue; // e.g. @import(some_var)

        const raw = tree.tokenSlice(tree.nodeMainToken(params[0]));
        const content = std.zig.string_literal.parseAlloc(gpa, raw) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.InvalidLiteral => continue,
        };
        defer gpa.free(content);

        if (!std.mem.endsWith(u8, content, ".zig")) continue; // e.g. "std": a module, not a file

        const target = try std.fs.path.resolve(gpa, &.{ dir, content });
        errdefer gpa.free(target);
        try worklist.append(gpa, .{ .path = target, .recurse = is_import });
    }
}

fn freeSet(gpa: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void)) void {
    var it = set.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    set.deinit(gpa);
}

/// Test-only helper resolving a fixture-tree relative path to an absolute
/// one, the shape `collect`'s `roots` expects. Kept as `[:0]u8` (rather than
/// coercing to `[]u8`) all the way out to the caller's `gpa.free`: see
/// `canonicalize`'s doc comment for why losing the sentinel-ness in the
/// static type before freeing under-frees by one byte.
fn rootAbs(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8) ![:0]u8 {
    return dir.realPathFileAlloc(io, sub_path, gpa);
}

test "collect follows @import chains and @embedFile, dedups, ignores cycles" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "root.zig", .data =
        \\const a = @import("a.zig");
        \\const e = @embedFile("data.zig");
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data =
        \\const b = @import("b.zig");
        \\const back = @import("root.zig"); // cycle
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "const x = 1;\n" });
    // `data.zig` (the @embedFile target) itself has an @import -- if `collect`
    // wrongly recursed into @embedFile targets, this would drag
    // shouldnotappear.zig into the reachable set too.
    try tmp.dir.writeFile(io, .{ .sub_path = "data.zig", .data =
        \\const nested = @import("shouldnotappear.zig");
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "shouldnotappear.zig", .data = "const y = 1;\n" });
    const root_abs = try rootAbs(io, gpa, tmp.dir, "root.zig");
    defer gpa.free(root_abs);
    const shouldnotappear_abs = try rootAbs(io, gpa, tmp.dir, "shouldnotappear.zig");
    defer gpa.free(shouldnotappear_abs);

    var set = try collect(gpa, io, &.{root_abs});
    defer freeSet(gpa, &set);
    // root, a, b, data all reachable (4); the cycle back to root doesn't
    // loop, and data.zig's own @import is never followed.
    try std.testing.expectEqual(@as(usize, 4), set.count());
    try std.testing.expect(!set.contains(shouldnotappear_abs));
}

test "collect skips a missing @import target without erroring" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "root.zig", .data =
        \\const missing = @import("nope.zig");
        \\const ok = @import("a.zig");
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const x = 1;\n" });
    const root_abs = try rootAbs(io, gpa, tmp.dir, "root.zig");
    defer gpa.free(root_abs);

    var set = try collect(gpa, io, &.{root_abs});
    defer freeSet(gpa, &set);
    // root + a; "nope.zig" doesn't exist, so it's never added.
    try std.testing.expectEqual(@as(usize, 2), set.count());
}

test "collect ignores a bare module @import" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "root.zig", .data =
        \\const std = @import("std");
        \\const a = @import("a.zig");
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const x = 1;\n" });
    // A real file literally named `std` (no `.zig` suffix) sits right next
    // to root.zig. Without the `.zig`-suffix filter on @import targets,
    // `@import("std")` would resolve straight to it and get added -- so this
    // proves the bare-module skip is a real check, not a side effect of the
    // target simply not existing.
    try tmp.dir.writeFile(io, .{ .sub_path = "std", .data = "not a real zig file\n" });
    const root_abs = try rootAbs(io, gpa, tmp.dir, "root.zig");
    defer gpa.free(root_abs);
    const std_file_abs = try rootAbs(io, gpa, tmp.dir, "std");
    defer gpa.free(std_file_abs);

    var set = try collect(gpa, io, &.{root_abs});
    defer freeSet(gpa, &set);
    // root + a; "std" names a module, not a file, so it adds nothing, even
    // though a file named `std` actually exists on disk.
    try std.testing.expectEqual(@as(usize, 2), set.count());
    try std.testing.expect(!set.contains(std_file_abs));
}

test "collect resolves @import relative to the importing file's own directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "root.zig", .data =
        \\const a = @import("sub/a.zig");
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/a.zig", .data =
        \\const b = @import("b.zig");
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/b.zig", .data = "const x = 1;\n" });
    // A decoy at the tmp root with the same basename: if "b.zig" inside
    // sub/a.zig were (wrongly) resolved against the root instead of sub/,
    // this is the file that would get picked up instead.
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "const decoy = 1;\n" });
    const root_abs = try rootAbs(io, gpa, tmp.dir, "root.zig");
    defer gpa.free(root_abs);
    const sub_b_abs = try rootAbs(io, gpa, tmp.dir, "sub/b.zig");
    defer gpa.free(sub_b_abs);
    const root_b_abs = try rootAbs(io, gpa, tmp.dir, "b.zig");
    defer gpa.free(root_b_abs);

    var set = try collect(gpa, io, &.{root_abs});
    defer freeSet(gpa, &set);
    // root, sub/a.zig, sub/b.zig (3); the root-level decoy b.zig is never
    // reached.
    try std.testing.expectEqual(@as(usize, 3), set.count());
    try std.testing.expect(set.contains(sub_b_abs));
    try std.testing.expect(!set.contains(root_b_abs));
}

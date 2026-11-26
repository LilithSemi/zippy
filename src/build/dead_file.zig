//! Finds `.zig` files present under `project_root` that are NOT in the
//! reachable set computed by `build/reachable.zig` -- i.e. `.zig` files
//! sitting in the tree but wired into no compilation. These are candidate
//! dead files: WIP playgrounds, leftovers from a rename, or files that were
//! genuinely removed from the build but never deleted from disk.
//!
//! This walk deliberately does NOT try to understand why a file is
//! unreachable (unlike `reachable.zig`, which follows real `@import`/
//! `@embedFile` edges); it just diffs "every `.zig` file on disk under the
//! project root" against "every `.zig` file `reachable.collect` found",
//! skipping build-output/cache directories. It's the natural complement to
//! `reachable.zig`: `collect` walks OUT from the compile-graph roots; this
//! walks the whole tree and works out what got left behind.
const std = @import("std");
const paths = @import("../paths.zig");
// Named `reachable_mod` (rather than `reachable`) purely to avoid shadowing
// `find`'s `reachable` parameter (and its tests' `reachable` locals) below --
// no behavior implication, just a naming clash with the module import.
const reachable_mod = @import("reachable.zig");

/// Directory-walk path COMPONENTS never descended into. Shared with
/// `cli.zig`'s directory walk via `paths.isSkipped` -- see that module's doc
/// comment for the component-exactness rationale.
const isSkipped = paths.isSkipped;

/// Resolves `abs_path` to its canonical (symlink-free) absolute form.
/// Shared with `reachable.zig`'s `collect` via `reachable.canonicalize`
/// rather than kept as its own copy: `reachable.collect`'s set keys and this
/// walk's candidates MUST canonicalize the exact same way, or a file that
/// really is reachable would look dead purely from a path-spelling
/// difference (a symlink, a relative-vs-absolute form, a stray `.`/`..`). See
/// `reachable.zig`'s doc comment on `canonicalize` for the full rationale.
const canonicalize = reachable_mod.canonicalize;

/// Walks `project_root` recursively and returns the canonical absolute paths
/// of every `.zig` file found that is NOT a key of `reachable` -- candidate
/// dead files. `.zig-cache`/`zig-out` subtrees are skipped by path component
/// and never even opened (not merely filtered out after the fact), matching
/// `cli.zig`'s `walkDir`.
///
/// `reachable` must already hold canonicalized keys, as `reachable.collect`
/// produces; every candidate this walk finds is canonicalized the exact same
/// way before the membership check, so the two sides compare equal
/// regardless of how a path happens to be spelled on disk (relative
/// segments, symlinks, `.`/`..`).
///
/// `project_root` must already be an absolute path -- same contract as
/// `reachable.collect`'s `roots` -- since resolving a relative path against
/// an unspecified "current directory" isn't a decision this walk should make
/// on the caller's behalf.
///
/// `dep_dirs` (from `manifest.zig`'s `Manifest.dep_dirs`) names every
/// dependency's build-root directory, absolute -- a file under any of these
/// is skipped exactly like `.zig-cache`/`zig-out`, never flagged dead. This
/// matters because a dependency can be vendored UNDER `project_root` itself
/// (e.g. `zig-pkg/uefi-<hash>/`, see `bsp.zig`'s `Graph.resolve`), where
/// this walk would otherwise find its files and -- since they're never a
/// project compile root and so never in `reachable` either -- wrongly report
/// third-party source as dead project code.
///
/// Returns a slice the caller owns: free each string with `gpa`, then free
/// the slice itself.
pub fn find(
    io: std.Io,
    gpa: std.mem.Allocator,
    project_root: []const u8,
    reachable: *const std.StringHashMapUnmanaged(void),
    dep_dirs: []const []const u8,
) ![]const []const u8 {
    std.debug.assert(std.fs.path.isAbsolute(project_root));

    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |item| gpa.free(item);
        result.deinit(gpa);
    }

    // Canonicalized up front, the same way every dead-file candidate below
    // is (see `canonicalize`'s doc comment): a `dep_dir` straight off the
    // build graph may spell the same directory differently (a symlink, a
    // relative segment) than this walk's own candidates, and a spelling
    // mismatch would silently defeat the skip. A `dep_dir` that fails to
    // canonicalize (e.g. it no longer exists) is dropped rather than erroring
    // -- same "not this walk's job to enforce" rationale as `canonicalize`'s
    // other callers.
    var canon_dep_dirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (canon_dep_dirs.items) |d| gpa.free(d);
        canon_dep_dirs.deinit(gpa);
    }
    for (dep_dirs) |dep_dir| {
        const canonical = (try canonicalize(io, gpa, dep_dir)) orelse continue;
        errdefer gpa.free(canonical);
        try canon_dep_dirs.append(gpa, canonical);
    }

    var dir = try std.Io.Dir.cwd().openDir(io, project_root, .{ .iterate = true });
    defer dir.close(io);

    // `walkSelectively` (rather than the auto-recursing `walk`) is used
    // deliberately, matching `cli.zig`'s `walkDir`: it only descends into a
    // directory when `enter` is called, which is exactly the hook needed to
    // skip `.zig-cache`/`zig-out` subtrees instead of filtering their files
    // after the fact (those directories can be huge, so never opening them
    // at all matters).
    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (isSkipped(entry.path)) continue;
        switch (entry.kind) {
            .directory => try walker.enter(io, entry),
            .file => {
                if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                // `build.zig` (at any depth, e.g. a nested package's own
                // build script) is never `@import`-reachable from a compile
                // root -- the build runner invokes it directly, not via an
                // `@import` edge `reachable.collect` could ever walk -- but
                // it is always "used": it's the file that drives the build.
                // Flagging it here would be a guaranteed false positive on
                // every Zippy project, since every project has one. Basename
                // comparison, not full-path or "is this THE root build.zig",
                // because a nested `build.zig` (e.g. a dependency's) is
                // equally exempt for the same reason.
                if (std.mem.eql(u8, entry.basename, "build.zig")) continue;

                const full = try std.fs.path.join(gpa, &.{ project_root, entry.path });
                defer gpa.free(full);

                const canonical = (try canonicalize(io, gpa, full)) orelse continue;
                errdefer gpa.free(canonical);
                if (reachable.contains(canonical)) {
                    gpa.free(canonical);
                    continue;
                }
                if (isUnderAnyDepDir(canonical, canon_dep_dirs.items)) {
                    gpa.free(canonical);
                    continue;
                }
                try result.append(gpa, canonical);
            },
            else => {},
        }
    }

    return result.toOwnedSlice(gpa);
}

/// True if canonical `path` sits at or under any of `dep_dirs` (already
/// canonicalized -- see `find`'s own canonicalization pass above). Mirrors
/// `build/mode.zig`'s `isUnderRoot` component-boundary check (kept as a
/// local copy, not a shared import: `mode.zig` already imports this module,
/// so importing back would be circular) -- a plain `startsWith` isn't enough,
/// since `/proj/zig-pkg2` textually starts with `/proj/zig-pkg` without
/// being under it as a path.
fn isUnderAnyDepDir(path: []const u8, dep_dirs: []const []const u8) bool {
    for (dep_dirs) |dir| {
        if (!std.mem.startsWith(u8, path, dir)) continue;
        if (path.len == dir.len or path[dir.len] == std.fs.path.sep) return true;
    }
    return false;
}

test "find flags stray .zig not in reachable, ignores .zig-cache" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "used.zig", .data = "const x = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "stray.zig", .data = "const y = 2;\n" });
    // Matches the real Zig local cache dir name (dot-prefixed), and
    // `skip_components` above, which skips it component-exactly.
    try tmp.dir.createDirPath(io, ".zig-cache");
    try tmp.dir.writeFile(io, .{ .sub_path = ".zig-cache/gen.zig", .data = "const z = 3;\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_abs);
    const used_abs = try tmp.dir.realPathFileAlloc(io, "used.zig", gpa);
    defer gpa.free(used_abs);

    var reachable: std.StringHashMapUnmanaged(void) = .empty;
    defer reachable.deinit(gpa);
    try reachable.put(gpa, used_abs, {});

    const dead = try find(io, gpa, root_abs, &reachable, &.{});
    defer {
        for (dead) |d| gpa.free(d);
        gpa.free(dead);
    }
    // only stray.zig is dead; used.zig is reachable; zig-cache/gen.zig is
    // never even walked into.
    try std.testing.expectEqual(@as(usize, 1), dead.len);
    try std.testing.expect(std.mem.endsWith(u8, dead[0], "stray.zig"));
}

test "find ignores files under zig-out and non-.zig files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "zig-out/bin");
    try tmp.dir.writeFile(io, .{
        .sub_path = "zig-out/bin/leftover.zig",
        .data = "const a = 1;\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "not zig\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_abs);

    var reachable: std.StringHashMapUnmanaged(void) = .empty;
    defer reachable.deinit(gpa);

    const dead = try find(io, gpa, root_abs, &reachable, &.{});
    defer {
        for (dead) |d| gpa.free(d);
        gpa.free(dead);
    }
    // zig-out/ is skipped by component, and notes.txt isn't `.zig` -- both
    // never make it into the result.
    try std.testing.expectEqual(@as(usize, 0), dead.len);
}

test "find flags a .zig file under a nested subdirectory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub/deeper");
    try tmp.dir.writeFile(io, .{ .sub_path = "used.zig", .data = "const x = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/deeper/nested.zig", .data = "const y = 1;\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_abs);
    const used_abs = try tmp.dir.realPathFileAlloc(io, "used.zig", gpa);
    defer gpa.free(used_abs);

    var reachable: std.StringHashMapUnmanaged(void) = .empty;
    defer reachable.deinit(gpa);
    try reachable.put(gpa, used_abs, {});

    const dead = try find(io, gpa, root_abs, &reachable, &.{});
    defer {
        for (dead) |d| gpa.free(d);
        gpa.free(dead);
    }
    // used.zig is reachable; sub/deeper/nested.zig is not, even nested two
    // levels down.
    try std.testing.expectEqual(@as(usize, 1), dead.len);
    try std.testing.expect(std.mem.endsWith(u8, dead[0], "nested.zig"));
}

test "find never flags build.zig, even though it's unreachable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "const b = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "stray.zig", .data = "const y = 2;\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_abs);

    // `build.zig` is never `@import`-reachable from a compile root -- the
    // build runner invokes it directly -- so `reachable` is empty here,
    // exactly as it would be for a real project's build script.
    var reachable: std.StringHashMapUnmanaged(void) = .empty;
    defer reachable.deinit(gpa);

    const dead = try find(io, gpa, root_abs, &reachable, &.{});
    defer {
        for (dead) |d| gpa.free(d);
        gpa.free(dead);
    }
    // only stray.zig is dead; build.zig is exempt by basename despite being
    // unreachable, since it's always used as the build script.
    try std.testing.expectEqual(@as(usize, 1), dead.len);
    try std.testing.expect(std.mem.endsWith(u8, dead[0], "stray.zig"));
}

test "find skips a file under a dep_dir, even though it's unreachable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Mirrors a dependency vendored UNDER the project tree (e.g.
    // `zig-pkg/uefi-<hash>/uefi.zig`, see this file's doc comment and
    // `bsp.zig`'s `Graph.resolve`): `dep/vendored.zig` is neither a
    // project compile root nor reachable from one, so without the `dep_dirs`
    // skip it would look exactly like a dead project file.
    try tmp.dir.createDirPath(io, "dep");
    try tmp.dir.writeFile(io, .{ .sub_path = "dep/vendored.zig", .data = "const v = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "stray.zig", .data = "const y = 2;\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_abs);
    const dep_dir_abs = try tmp.dir.realPathFileAlloc(io, "dep", gpa);
    defer gpa.free(dep_dir_abs);

    var reachable: std.StringHashMapUnmanaged(void) = .empty;
    defer reachable.deinit(gpa);

    const dead = try find(io, gpa, root_abs, &reachable, &.{dep_dir_abs});
    defer {
        for (dead) |d| gpa.free(d);
        gpa.free(dead);
    }
    // stray.zig is still flagged dead; dep/vendored.zig is skipped entirely
    // because it sits under a dep_dir.
    try std.testing.expectEqual(@as(usize, 1), dead.len);
    try std.testing.expect(std.mem.endsWith(u8, dead[0], "stray.zig"));
}

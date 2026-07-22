//! Applies `Diagnostic.Fix`es to files on disk. `applyEdits` is the pure,
//! git-free splicer -- descending-offset application with overlap-skip, so
//! it can be unit-tested without touching the filesystem. `isFileClean`
//! spawns `git status --porcelain` to decide whether a file is safe to
//! rewrite unattended. `apply` is the orchestrator: it groups a diagnostic
//! list's fixes by path, refuses to touch a dirty file unless told to, and
//! writes the spliced result back for every file it does touch.
//!
//! Correctness bias throughout: a bad autofix that garbles a file is worse
//! than no fix at all, so every ambiguous case (an overlapping edit, an
//! unclean file, a git spawn failure) resolves to "don't touch it" rather
//! than "guess and proceed".
const std = @import("std");
const Diagnostic = @import("Diagnostic.zig");
const Fix = Diagnostic.Fix;

/// Tally of what happened across every file `apply` considered.
/// `applied`/`skipped` count individual EDITS (one file can contribute many
/// of each); `refused` counts FILES turned away outright for being dirty.
pub const Result = struct {
    applied: usize = 0,
    skipped: usize = 0,
    refused: usize = 0,
};

/// The git-free result of splicing `edits` into a copy of some source text:
/// `text` is the caller-owned spliced buffer, `applied`/`skipped` tally how
/// many edits made it in vs. were dropped for overlapping an already-applied
/// one (or being malformed).
const ApplyOne = struct { text: []u8, applied: usize, skipped: usize };

/// Descending order by `(start, end)`: applying edits highest-offset-first
/// means every edit still queued sits at a LOWER original offset, so
/// splicing the current one never shifts the offsets the rest still rely on
/// -- no offset-bookkeeping pass needed after each splice.
fn cmpDesc(_: void, a: Fix, b: Fix) bool {
    if (a.start != b.start) return a.start > b.start;
    return a.end > b.end;
}

/// Applies `edits` (byte offsets into the ORIGINAL `bytes`) to a fresh copy
/// of `bytes`, descending by start (see `cmpDesc`) so already-spliced lower
/// offsets never invalidate an edit still to come. An edit that overlaps one
/// already applied -- tracked by `applied_lo`, the lowest start applied so
/// far -- is SKIPPED rather than applied: garbling a file by splicing two
/// edits that both claim the same bytes is strictly worse than leaving one
/// of them unapplied. A malformed edit (`start > end`, or `end` past the end
/// of `bytes`) is skipped the same way. `edits` is sorted in place; the
/// caller frees the returned `.text` with `gpa`.
fn applyEdits(gpa: std.mem.Allocator, bytes: []const u8, edits: []Fix) !ApplyOne {
    std.mem.sort(Fix, edits, {}, cmpDesc);
    var work: std.ArrayList(u8) = .empty;
    errdefer work.deinit(gpa);
    try work.appendSlice(gpa, bytes);
    var applied: usize = 0;
    var skipped: usize = 0;
    var applied_lo: usize = bytes.len; // lowest start applied so far
    for (edits) |e| {
        if (e.start > e.end or e.end > bytes.len) {
            skipped += 1;
            continue;
        }
        if (e.end > applied_lo) { // overlaps a higher, already-applied edit
            skipped += 1;
            continue;
        }
        try work.replaceRange(gpa, e.start, e.end - e.start, e.replacement);
        applied_lo = e.start;
        applied += 1;
    }
    return .{ .text = try work.toOwnedSlice(gpa), .applied = applied, .skipped = skipped };
}

/// A file is safe to auto-fix only if it's git-tracked with no staged or
/// unstaged changes: `git status --porcelain -- <basename>`, run in the
/// file's own directory, prints nothing at all for a clean tracked file, and
/// at least one line for anything else -- modified, staged, or untracked.
/// Spawning git failing outright (not on `PATH`, the directory isn't inside
/// a repo, or any other error) means this can't PROVE the file is safe, so
/// it returns `false` just like a genuinely dirty file would -- never `true`
/// on an inconclusive result, since rewriting an uncommitted file the user
/// never chose to risk is exactly the mistake this check exists to prevent.
fn isFileClean(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !bool {
    const dir = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "status", "--porcelain", "--", base },
        .cwd = .{ .path = dir },
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const exit_code: ?u8 = switch (result.term) {
        .exited => |code| code,
        else => null,
    };
    return exit_code == 0 and result.stdout.len == 0;
}

/// Groups every `.fix` present in `diags` by `.path` (a diagnostic with
/// `fix == null` contributes nothing -- there's nothing to apply), then for
/// each path with at least one fix: unless `allow_dirty` is set, refuses to
/// touch it when `isFileClean` says no (tallied in `result.refused`, with a
/// message to `stderr`); otherwise reads the file, splices every fix for it
/// via `applyEdits`, writes the spliced text back, and folds that file's
/// `applied`/`skipped` counts into the running total. `path`s are expected
/// to be absolute (same contract as the rest of Zippy's file I/O).
pub fn apply(
    io: std.Io,
    gpa: std.mem.Allocator,
    diags: []const Diagnostic,
    allow_dirty: bool,
    stderr: *std.Io.Writer,
) !Result {
    var groups: std.StringArrayHashMapUnmanaged(std.ArrayList(Fix)) = .empty;
    defer {
        var it = groups.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(gpa);
        groups.deinit(gpa);
    }

    for (diags) |d| {
        const f = d.fix orelse continue;
        const gop = try groups.getOrPut(gpa, d.path);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, f);
    }

    var result: Result = .{};
    var it = groups.iterator();
    while (it.next()) |entry| {
        const path = entry.key_ptr.*;
        const edits = entry.value_ptr;

        if (!allow_dirty and !(try isFileClean(io, gpa, path))) {
            try stderr.print(
                "zippy: refusing to fix '{s}': uncommitted changes " ++
                    "(commit/stash or --allow-dirty)\n",
                .{path},
            );
            result.refused += 1;
            continue;
        }

        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(bytes);

        const r = try applyEdits(gpa, bytes, edits.items);
        defer gpa.free(r.text);

        try writeFileAtomic(io, gpa, path, r.text);

        result.applied += r.applied;
        result.skipped += r.skipped;
    }
    return result;
}

/// Writes `data` to `path` atomically: it writes a sibling temp file first,
/// then renames it over `path`. A rename within one directory is atomic on
/// POSIX, so a concurrent reader (or a crash, or a `write` cut short by a
/// full disk or a signal) only ever sees the whole old file or the whole new
/// one -- never a half-spliced file. This upholds the module's correctness
/// bias literally: the git-clean gate and overlap-skip all exist so a fix
/// never garbles a file, and a plain in-place `writeFile` interrupted midway
/// would garble the very file the user trusted us to edit -- the one failure
/// mode this whole module is built to avoid.
///
/// The temp file is a SIBLING (same directory, via a suffix on `path`) so the
/// final rename stays on one filesystem -- a cross-device rename isn't atomic
/// and errors out instead of silently falling back to a copy. A random suffix
/// avoids colliding with a concurrent `zippy --fix` on the same file, and a
/// failed write or rename deletes the temp rather than leaving `.tmp` litter
/// behind.
fn writeFileAtomic(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    data: []const u8,
) !void {
    var random_bytes: [12]u8 = undefined;
    io.random(&random_bytes);
    var name_buf: [std.base64.url_safe.Encoder.calcSize(random_bytes.len)]u8 = undefined;
    const suffix = std.base64.url_safe.Encoder.encode(&name_buf, &random_bytes);

    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.zippy-{s}.tmp", .{ path, suffix });
    defer gpa.free(tmp_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp_path, .data = data });
    // Only fires if the rename below never succeeds: on success the temp name
    // no longer exists, so this best-effort delete is a no-op whose error is
    // swallowed. On a write/rename failure it clears the half-written temp.
    errdefer cwd.deleteFile(io, tmp_path) catch {};

    try cwd.rename(tmp_path, cwd, path, io);
}

test "applyEdits splices descending, deletes, and skips overlaps" {
    const gpa = std.testing.allocator;
    // "abcdefgh": delete [2,4) and replace [5,7) with "XY"; non-overlapping.
    var edits = [_]Fix{
        .{ .start = 2, .end = 4, .replacement = "" },
        .{ .start = 5, .end = 7, .replacement = "XY" },
    };
    const r = try applyEdits(gpa, "abcdefgh", &edits);
    defer gpa.free(r.text);
    // offsets are ORIGINAL. del[2,4)="cd", replace[5,7)="fg"->"XY". Applied
    // DESC: [5,7)->XY = "abcdeXYh", then [2,4)->"" = "abeXYh".
    try std.testing.expectEqualStrings("abeXYh", r.text);
    try std.testing.expectEqual(@as(usize, 0), r.skipped);
    try std.testing.expectEqual(@as(usize, 2), r.applied);
}

test "applyEdits skips an overlapping edit" {
    const gpa = std.testing.allocator;
    var edits = [_]Fix{
        .{ .start = 1, .end = 5, .replacement = "" },
        .{ .start = 3, .end = 7, .replacement = "" }, // overlaps the first
    };
    const r = try applyEdits(gpa, "abcdefgh", &edits);
    defer gpa.free(r.text);
    // DESC order applies [3,7) first ("defg"->""), then [1,5) is skipped:
    // its end (5) is past applied_lo (3).
    try std.testing.expectEqualStrings("abch", r.text);
    try std.testing.expectEqual(@as(usize, 1), r.applied);
    try std.testing.expectEqual(@as(usize, 1), r.skipped);
}

test "applyEdits handles a pure deletion" {
    const gpa = std.testing.allocator;
    // "const x = 1;": delete " x = " (indices [5,10)), leaving "const1;".
    var edits = [_]Fix{.{ .start = 5, .end = 10, .replacement = "" }};
    const r = try applyEdits(gpa, "const x = 1;", &edits);
    defer gpa.free(r.text);
    try std.testing.expectEqualStrings("const1;", r.text);
    try std.testing.expectEqual(@as(usize, 1), r.applied);
    try std.testing.expectEqual(@as(usize, 0), r.skipped);
}

test "writeFileAtomic replaces contents and leaves no temp file behind" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // `.iterate` so the no-litter check below can enumerate the directory.
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "old contents" });

    const abs = try tmp.dir.realPathFileAlloc(io, "f.txt", gpa);
    defer gpa.free(abs);

    try writeFileAtomic(io, gpa, abs, "new contents");

    const got = try std.Io.Dir.cwd().readFileAlloc(io, abs, gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("new contents", got);

    // The sibling temp file must have been renamed away, not left behind: the
    // only entry in the directory is the target file itself.
    var it = tmp.dir.iterate();
    var entries: usize = 0;
    while (try it.next(io)) |entry| {
        entries += 1;
        try std.testing.expectEqualStrings("f.txt", entry.name);
    }
    try std.testing.expectEqual(@as(usize, 1), entries);
}

/// Runs `argv` in `dir`, treating a `FileNotFound` spawn failure (git isn't
/// on `PATH` in this environment) as a reason to skip the whole test rather
/// than fail it -- the same gate `build/e2e_test.zig` uses for tools it
/// can't assume are installed. Returns the run result for anything else so
/// the caller can still assert on a real git failure.
fn runOrSkip(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: []const u8,
    argv: []const []const u8,
) !std.process.RunResult {
    return std.process.run(gpa, io, .{ .argv = argv, .cwd = .{ .path = dir } }) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
}

test "apply refuses a dirty file, fixes it with allow_dirty" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_abs);

    // git init the tmp dir; skip the whole test if git isn't available.
    var r = try runOrSkip(io, gpa, dir_abs, &.{ "git", "init" });
    gpa.free(r.stdout);
    gpa.free(r.stderr);

    // Needed to commit in a sandbox with no global git identity configured.
    r = try runOrSkip(io, gpa, dir_abs, &.{ "git", "config", "user.email", "zippy@test.local" });
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    r = try runOrSkip(io, gpa, dir_abs, &.{ "git", "config", "user.name", "Zippy Test" });
    gpa.free(r.stdout);
    gpa.free(r.stderr);

    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const x = 1;\n" });
    r = try runOrSkip(io, gpa, dir_abs, &.{ "git", "add", "a.zig" });
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    r = try runOrSkip(io, gpa, dir_abs, &.{ "git", "commit", "-m", "add a.zig" });
    gpa.free(r.stdout);
    gpa.free(r.stderr);

    // Dirty it on disk without committing.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const x = 2;\n" });

    const path = try std.fs.path.join(gpa, &.{ dir_abs, "a.zig" });
    defer gpa.free(path);

    const diags = [_]Diagnostic{.{
        .path = path,
        .byte_offset = 10,
        .end_offset = 11,
        .severity = .warn,
        .lint = "test_lint",
        .message = "irrelevant",
        .fix = .{ .start = 10, .end = 11, .replacement = "9" },
    }};

    var err_buf: [512]u8 = undefined;
    var err_writer = std.Io.Writer.fixed(&err_buf);

    const refused_result = try apply(io, gpa, &diags, false, &err_writer);
    try std.testing.expectEqual(@as(usize, 0), refused_result.applied);
    try std.testing.expectEqual(@as(usize, 1), refused_result.refused);
    const after_refuse = try tmp.dir.readFileAlloc(io, "a.zig", gpa, .unlimited);
    defer gpa.free(after_refuse);
    try std.testing.expectEqualStrings("const x = 2;\n", after_refuse);

    err_writer = std.Io.Writer.fixed(&err_buf);
    const allowed_result = try apply(io, gpa, &diags, true, &err_writer);
    try std.testing.expectEqual(@as(usize, 1), allowed_result.applied);
    try std.testing.expectEqual(@as(usize, 0), allowed_result.refused);
    const after_allow = try tmp.dir.readFileAlloc(io, "a.zig", gpa, .unlimited);
    defer gpa.free(after_allow);
    try std.testing.expectEqualStrings("const x = 9;\n", after_allow);
}

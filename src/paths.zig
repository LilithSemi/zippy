//! Small shared path utilities used by more than one module. Currently just
//! the build-output/cache directory skip-list, needed identically by
//! `cli.zig`'s lint-mode directory walk and `build/dead_file.zig`'s
//! dead-file walk -- a neutral home neither of those layers has to reach
//! into the other for (a low-level build module importing the CLI driver
//! would invert the codebase's layering).
const std = @import("std");

/// Directory-walk path COMPONENTS that must never be descended into:
/// generated build output and the compiler's own cache. `.zig-cache` in
/// particular can be enormous and contains no source a user wrote, so
/// walking it wastes time at best and risks linting/flagging
/// compiler-generated garbage at worst.
///
/// Matched component-exactly (not as a substring, see `isSkipped`) so a
/// legitimately-named path like `zig-outline/` or `notes.zig-cache.txt` is
/// never mistaken for the directories being skipped.
pub const skip_components = [_][]const u8{ ".zig-cache", "zig-out" };

/// True if any path component of `path` exactly matches an entry in
/// `skip_components`. Shared by `cli.zig`'s lint-mode directory walk and
/// `build/dead_file.zig`'s dead-file walk -- both need to agree on exactly
/// which subtrees are "not real source" for their skip to mean the same
/// thing, so this lives in one place instead of two copies that could
/// silently drift apart.
pub fn isSkipped(path: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, path, std.fs.path.sep);
    while (it.next()) |component| {
        for (skip_components) |s| {
            if (std.mem.eql(u8, component, s)) return true;
        }
    }
    return false;
}

test "isSkipped matches path components exactly, not substrings" {
    try std.testing.expect(!isSkipped("zig-outline"));
    try std.testing.expect(!isSkipped("zig-outline/foo.zig"));
    try std.testing.expect(!isSkipped("notes.zig-cache.txt"));
    try std.testing.expect(isSkipped(".zig-cache"));
    try std.testing.expect(isSkipped(".zig-cache/foo.zig"));
    try std.testing.expect(isSkipped("sub/.zig-cache/foo.zig"));
    try std.testing.expect(isSkipped("zig-out"));
    try std.testing.expect(isSkipped("zig-out/bin/zippy"));
}

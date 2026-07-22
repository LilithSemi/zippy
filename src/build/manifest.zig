const std = @import("std");

pub const Root = struct {
    path: []const u8,
    module: []const u8,
    step: []const u8,
    target: []const u8,
    /// True when this root's module is owned by a DEPENDENCY's `*Build`
    /// (`b.dependency("foo")`), not the project's own -- set by
    /// `runner.zig`'s `dependencyDir` from the build graph itself (the owning
    /// `Build`'s `build_root.path`), never from where the file happens to sit
    /// on disk. A dependency can be vendored anywhere, including UNDER the
    /// project's own tree (e.g. a `zig-pkg/uefi-<hash>/` package dir), so a
    /// path-prefix check can't tell a dependency from project code -- only
    /// the build graph can. Defaults `false` so a manifest predating this
    /// field still parses as "not a dependency", matching every root that
    /// existed before dependency detection was added.
    is_dependency: bool = false,
};
pub const CompileError = struct {
    path: []const u8,
    line: u32,
    col: u32,
    span_start: u32,
    span_end: u32,
    message: []const u8,
};
pub const Manifest = struct {
    project_root: []const u8,
    roots: []const Root,
    errors: []const CompileError = &.{}, // default empty: no `errors` key still parses (Tier 1)
    /// Absolute build-root directories of every DISTINCT dependency reachable
    /// from `roots` (see `Root.is_dependency`'s doc comment) -- fed to
    /// `dead_file.find` so a dependency vendored under the project tree is
    /// never mistaken for a stray/dead project file. Default empty: a
    /// manifest predating this field still parses, and an empty list simply
    /// means "skip nothing extra" -- the same behavior as before this field
    /// existed.
    dep_dirs: []const []const u8 = &.{},
};

/// Parses the manifest the embedded runner emits. Caller owns the returned
/// `Parsed` and must `deinit()` it. `ignore_unknown_fields` future-proofs the
/// format.
pub fn parse(gpa: std.mem.Allocator, json_bytes: []const u8) !std.json.Parsed(Manifest) {
    return std.json.parseFromSlice(Manifest, gpa, json_bytes, .{ .ignore_unknown_fields = true });
}

test "parse a manifest" {
    const gpa = std.testing.allocator;
    const src =
        \\{"project_root":"/p","roots":[{"path":"/p/src/main.zig","module":"root",
        \\"step":"exe","target":"x86_64-linux"}]}
    ;
    const parsed = try parse(gpa, src);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/p", parsed.value.project_root);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.roots.len);
    try std.testing.expectEqualStrings("/p/src/main.zig", parsed.value.roots[0].path);
}

test "parse a manifest with compiler errors" {
    const gpa = std.testing.allocator;
    const j =
        \\{"project_root":"/p","roots":[],"errors":[{"path":"/p/src/main.zig",
        \\"line":3,"col":5,"span_start":40,"span_end":44,
        \\"message":"expected type 'u8', found 'bool'"}]}
    ;
    const parsed = try parse(gpa, j);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.errors.len);
    try std.testing.expectEqualStrings("/p/src/main.zig", parsed.value.errors[0].path);
    try std.testing.expectEqual(@as(u32, 40), parsed.value.errors[0].span_start);
}

test "parse a Tier-1 manifest with no errors key" {
    const gpa = std.testing.allocator;
    const j = "{\"project_root\":\"/p\",\"roots\":[]}";
    const parsed = try parse(gpa, j);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.errors.len);
}

test "parse a manifest with is_dependency and dep_dirs" {
    const gpa = std.testing.allocator;
    const src =
        \\{"project_root":"/p","roots":[
        \\  {"path":"/p/src/main.zig","module":"root","step":"exe","target":"",
        \\   "is_dependency":false},
        \\  {"path":"/p/zig-pkg/uefi-abc/uefi.zig","module":"uefi","step":"exe",
        \\   "target":"","is_dependency":true}
        \\],"dep_dirs":["/p/zig-pkg/uefi-abc"]}
    ;
    const parsed = try parse(gpa, src);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.roots.len);
    try std.testing.expect(!parsed.value.roots[0].is_dependency);
    try std.testing.expect(parsed.value.roots[1].is_dependency);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.dep_dirs.len);
    try std.testing.expectEqualStrings("/p/zig-pkg/uefi-abc", parsed.value.dep_dirs[0]);
}

test "parse a manifest without is_dependency/dep_dirs still parses (back-compat)" {
    const gpa = std.testing.allocator;
    const src =
        \\{"project_root":"/p","roots":[{"path":"/p/src/main.zig","module":"root",
        \\"step":"exe","target":"x86_64-linux"}]}
    ;
    const parsed = try parse(gpa, src);
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.roots[0].is_dependency);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.dep_dirs.len);
}

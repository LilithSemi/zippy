//! End-to-end fixture tests. For each sample file in `test/fixtures/`, this
//! loads it exactly like the CLI would, runs the full `Linter.run` (every
//! lint, default config), and asserts the *exact* set of diagnostics that
//! fired -- both count and each `{lint, line}` pair.
//!
//! This is what actually catches regressions: a fixture that starts firing
//! one more or one fewer diagnostic than expected fails loudly here, instead
//! of only ever being checked by each lint's own narrower unit test (which
//! runs that lint in isolation, not the full default-config pipeline every
//! lint together produces against a real file).
//!
//! Types come from the "zippy" module (see build.zig), i.e. from
//! src/root.zig, rather than by importing src/ files directly by relative
//! path -- that would create a second, distinct instance of each module and
//! the resulting types wouldn't match `Linter.run`'s.
const std = @import("std");
const zippy = @import("zippy");
const Source = zippy.Source;
const Config = zippy.Config;
const Linter = zippy.Linter;
const Diagnostic = zippy.Diagnostic;

const Expect = struct { lint: []const u8, line: usize };

fn expectLessThan(_: void, a: Expect, b: Expect) bool {
    if (a.line != b.line) return a.line < b.line;
    return std.mem.lessThan(u8, a.lint, b.lint);
}

/// Diagnostics are appended in lint-registry order, not source order, so
/// e.g. a `discarded_error` hit on an earlier line can be emitted after an
/// `inline_container_type` hit on a later one. Both `expected` and the
/// actual diagnostics are reduced to `(lint, line)` and sorted the same way
/// before comparing, so the assertion only depends on *what* fired, not the
/// registry's iteration order.
fn checkFixture(
    gpa: std.mem.Allocator,
    rel_path: []const u8,
    expected_unsorted: []const Expect,
) !void {
    var src = try Source.load(std.testing.io, gpa, rel_path);
    defer src.deinit(gpa);
    const cfg = Config.default();

    var diags: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diags.items) |d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try Linter.run(gpa, &src, &cfg, &diags);

    const expected = try gpa.dupe(Expect, expected_unsorted);
    defer gpa.free(expected);
    std.mem.sort(Expect, expected, {}, expectLessThan);

    const actual = try gpa.alloc(Expect, diags.items.len);
    defer gpa.free(actual);
    for (diags.items, 0..) |d, i| {
        actual[i] = .{
            .lint = d.lint,
            .line = Diagnostic.lineColAt(src.bytes, d.byte_offset).line,
        };
    }
    std.mem.sort(Expect, actual, {}, expectLessThan);

    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, got| {
        try std.testing.expectEqualStrings(e.lint, got.lint);
        try std.testing.expectEqual(e.line, got.line);
    }
}

test "clean fixture produces no diagnostics" {
    try checkFixture(std.testing.allocator, "test/fixtures/clean.zig", &.{});
}

test "line_width fixture flags the one over-limit comment line" {
    try checkFixture(std.testing.allocator, "test/fixtures/line_width.zig", &.{
        .{ .lint = "line_width", .line = 1 },
        .{ .lint = "unused_decl", .line = 2 }, // private `x` is never referenced
    });
}

test "naming_convention fixture flags the bad function and bad type names" {
    try checkFixture(std.testing.allocator, "test/fixtures/naming_convention.zig", &.{
        .{ .lint = "naming_convention", .line = 3 }, // `Bad_Name` fn
        .{ .lint = "naming_convention", .line = 4 }, // `myType` const-of-struct
        .{ .lint = "unused_decl", .line = 1 }, // private `std` is never referenced
        .{ .lint = "unused_decl", .line = 4 }, // private `myType` is never referenced
        .{ .lint = "unused_decl", .line = 7 }, // private `GoodType` is never referenced
    });
}

test "too_many_params fixture flags the six-param fn and its tuple discards" {
    try checkFixture(std.testing.allocator, "test/fixtures/too_many_params.zig", &.{
        .{ .lint = "too_many_params", .line = 3 }, // `tooMany` has 6 params
        .{ .lint = "discarded_error", .line = 4 }, // `_ = .{ a, b, c, d, e, f };`
        .{ .lint = "discarded_error", .line = 8 }, // `_ = .{ a, b };`
        .{ .lint = "unused_decl", .line = 1 }, // private `std` is never referenced
    });
}

test "redundant_else fixture flags only the branch that always returns" {
    try checkFixture(std.testing.allocator, "test/fixtures/redundant_else.zig", &.{
        .{ .lint = "redundant_else", .line = 7 },
        .{ .lint = "unused_decl", .line = 4 }, // private `classify` is never called
        .{ .lint = "unused_decl", .line = 13 }, // private `describe` is never called
    });
}

test "discarded_error fixture flags the one discard" {
    try checkFixture(std.testing.allocator, "test/fixtures/discarded_error.zig", &.{
        .{ .lint = "discarded_error", .line = 9 },
        .{ .lint = "unused_decl", .line = 8 }, // private `doWork` is never called
        .{ .lint = "unused_decl", .line = 13 }, // private `useIt` is never called
    });
}

test "unused_decl fixture flags the dead private fn but not the referenced one" {
    try checkFixture(std.testing.allocator, "test/fixtures/unused_decl.zig", &.{
        .{ .lint = "unused_decl", .line = 4 }, // `deadHelper` is never called
    });
}

test "inline_container_type fixture flags the inline struct and its discards" {
    try checkFixture(std.testing.allocator, "test/fixtures/inline_container_type.zig", &.{
        .{ .lint = "inline_container_type", .line = 5 }, // inline anon return struct, 4 fields
        // `_ = std;` (line 16) is no longer flagged: bare-identifier
        // discards are the idiomatic unused-var/param suppression, not a
        // silent error discard.
        .{ .lint = "discarded_error", .line = 17 }, // `_ = &used;`
    });
}

//! A small, idiomatic sample module that must trigger zero diagnostics
//! across all six lints under the default config. Used by the fixture
//! integration test as the "nothing to see here" baseline.
const std = @import("std");

/// Named via this const decl, so inline_container_type never applies to it
/// regardless of field count -- and it's well under the default max (3)
/// anyway.
pub const Point = struct {
    x: i32,
    y: i32,
};

/// camelCase name, two params (under the default max of five).
pub fn addPoints(a: Point, b: Point) Point {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}

/// An `if` with no `else` is never flagged by redundant_else, no matter how
/// the then-branch ends.
pub fn magnitudeSquared(p: Point) i32 {
    if (p.x == 0 and p.y == 0) {
        return 0;
    }
    return (p.x * p.x) + (p.y * p.y);
}

pub fn printPoint(p: Point) void {
    std.log.debug("({d}, {d})\n", .{ p.x, p.y });
}

test "addPoints sums components" {
    const sum = addPoints(.{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 });
    try std.testing.expectEqual(@as(i32, 4), sum.x);
    try std.testing.expectEqual(@as(i32, 6), sum.y);
}

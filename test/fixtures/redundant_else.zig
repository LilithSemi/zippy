const std = @import("std");

// Redundant: the then-branch always returns, so the else adds nothing.
fn classify(x: i32) []const u8 {
    if (x < 0) {
        return "negative";
    } else {
        return "non-negative";
    }
}

// Legitimate: neither branch jumps, so the else is meaningful.
fn describe(x: i32) []const u8 {
    if (x < 0) {
        std.debug.print("negative\n", .{});
    } else {
        std.debug.print("non-negative\n", .{});
    }
    return "done";
}

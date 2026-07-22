const std = @import("std");

// Dead: nothing in this file ever calls it.
fn deadHelper() void {}

// Live: called from `main` below.
fn liveHelper() void {
    std.debug.print("hi\n", .{});
}

pub fn main() void {
    liveHelper();
}

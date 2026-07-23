const std = @import("std");

// `std.debug.print` is flagged: shipping code should use `std.log`, not a
// debug print left behind.
fn debugIt() void {
    std.debug.print("debugging {d}\n", .{1});
}

pub fn main() void {
    debugIt();
}

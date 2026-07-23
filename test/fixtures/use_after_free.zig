const std = @import("std");

pub fn broken(a: std.mem.Allocator) void {
    const x = a.alloc(u8, 4) catch return;
    a.free(x);
    x[0] = 1;
}

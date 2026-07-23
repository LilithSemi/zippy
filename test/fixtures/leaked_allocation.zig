const std = @import("std");

pub fn leaky(a: std.mem.Allocator) void {
    const x = a.alloc(u8, 4) catch return;
    x[0] = 1;
}

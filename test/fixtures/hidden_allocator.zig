const std = @import("std");

pub fn leaky() void {
    const a = std.heap.page_allocator;
    _ = a;
}

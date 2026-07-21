const std = @import("std");

pub fn tooMany(a: u8, b: u8, c: u8, d: u8, e: u8, f: u8) void {
    _ = .{ a, b, c, d, e, f };
}

pub fn fine(a: u8, b: u8) void {
    _ = .{ a, b };
}

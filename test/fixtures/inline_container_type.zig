const std = @import("std");

// Inline anonymous return type with more fields than the default max (3):
// should be hoisted to a named `pub const`.
pub fn build() struct { a: u8, b: u8, c: u8, d: u8 } {
    return .{ .a = 0, .b = 0, .c = 0, .d = 0 };
}

// Already named via the const decl -- exempt even though it has the same
// number of fields.
pub const Named = struct { a: u8, b: u8, c: u8, d: u8 };

var used: Named = undefined;

pub fn use() void {
    _ = std;
    _ = &used;
}

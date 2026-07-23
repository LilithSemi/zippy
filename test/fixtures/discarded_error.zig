const std = @import("std");

fn compute() u8 {
    return 42;
}

// Discarded: the computed value is thrown away.
fn doWork() void {
    _ = compute();
}

// Legitimate: the computed value is bound and used.
fn useIt() void {
    const x = compute();
    std.log.debug("{d}\n", .{x});
}

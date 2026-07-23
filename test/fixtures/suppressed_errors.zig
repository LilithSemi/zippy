pub fn a() void {
    g() catch {};
}

pub fn b() void {
    g() catch unreachable;
}

fn g() !void {
    return error.Bad;
}

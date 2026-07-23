fn uselessFn() !void {
    return;
}

fn realFn() !void {
    return error.Bad;
}

pub fn main() !void {
    try uselessFn();
    try realFn();
}

//! Thin process entry point. All real behavior lives in `cli.zig` so it can
//! be tested without a process boundary; this file only wires up the zig
//! 0.16 runtime-provided args/io/allocator, hands them to `cli.run`, flushes
//! output, and exits with the code `cli.run` decided.
//!
//! `main` takes `std.process.Init` (rather than being a bare `pub fn main()
//! !void`) because that's how the 0.16 runtime hands over a real `std.Io`
//! (backed by `std.Io.Threaded`, with leak-checking wired up in Debug
//! builds) plus a `gpa` and the process args, without this file having to
//! construct any of those itself.
const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // `toSlice` requires an arena because on Windows it may synthesize new
    // allocations for the individual args; `init.arena` is exactly the
    // permanent, process-lifetime arena meant for this.
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &out_buf);
    var stderr_writer = std.Io.File.stderr().writer(io, &err_buf);

    // Only read by the `lsp` subcommand (see `cli.run`), but built
    // unconditionally alongside stdout/stderr for the same reason: a real
    // process only ever has one stdin, so there's no benefit to deferring
    // this past the subcommand check. 64 KiB comfortably covers a typical
    // framed LSP message header+body without extra syscalls; a body larger
    // than the buffer still works fine since `transport.readMessage` reads
    // it into its own heap allocation via `readSliceAll`, not the reader's
    // internal buffer.
    var in_buf: [64 * 1024]u8 = undefined;
    const stdin_file = std.Io.File.stdin();
    var stdin_reader = stdin_file.reader(io, &in_buf);

    // `--color=auto` (the default) should color only when stdout is really
    // a terminal AND the user hasn't opted out via `NO_COLOR` (no-color.org:
    // presence of the var disables color regardless of its value). A
    // canceled `isTty` call (e.g. the io backend shutting down) falls back
    // to "not a tty" -- when in doubt, stay plain rather than risk raw
    // escapes landing in a file or non-terminal consumer.
    const is_tty = stdout_file.isTty(io) catch false;
    const no_color_set = init.environ_map.contains("NO_COLOR");
    const stdout_is_tty = is_tty and !no_color_set;

    // args[0] is the executable path; cli.run only wants the paths/flags
    // that follow it.
    const code = try cli.run(.{
        .io = io,
        .gpa = gpa,
        .args = args[1..],
        .stdout = &stdout_writer.interface,
        .stderr = &stderr_writer.interface,
        .stdout_is_tty = stdout_is_tty,
        .stdin = &stdin_reader.interface,
    });

    try stdout_writer.interface.flush();
    try stderr_writer.interface.flush();
    std.process.exit(code);
}

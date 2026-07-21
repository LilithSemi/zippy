//! The actual behavior behind the `zippy` executable, kept separate from
//! `main.zig` so it can be driven in tests without a process boundary (no
//! `std.process.exit` lives here -- `run` just returns the exit code).
const std = @import("std");
const Source = @import("Source.zig");
const Config = @import("Config.zig");
const Linter = @import("Linter.zig");
const Diagnostic = @import("Diagnostic.zig");

const usage =
    \\Usage: zippy [options] [paths...]
    \\       zippy lsp
    \\
    \\  -h, --help              Show this help.
    \\  --color=auto|always|never
    \\                          Control ANSI color in diagnostic output.
    \\                          auto (default): color iff stdout is a TTY
    \\                          and NO_COLOR is unset.
    \\  lsp                     Run as a Language Server (LSP over stdio).
    \\
    \\Lints .zig files (directories are walked). Reads the nearest zippy.zon,
    \\walking up from the current directory; if none is found, built-in
    \\defaults are used.
    \\
;

/// The three states `--color` can be set to; `.auto` is the default and
/// defers to whether stdout is really a terminal (and `NO_COLOR` is unset).
const ColorMode = enum { auto, always, never };

/// Parses a `--color=VALUE` argument's value, or `null` if `value` isn't
/// one of the three recognized modes -- callers turn that into a loud
/// usage error rather than silently falling back to a default, per this
/// codebase's fail-loud convention.
fn parseColorMode(value: []const u8) ?ColorMode {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "always")) return .always;
    if (std.mem.eql(u8, value, "never")) return .never;
    return null;
}

/// Resolves the final `use_color` decision `Diagnostic.render` needs, from
/// the parsed `--color` mode and whether stdout is really a TTY.
///
/// `stdout_is_tty` (as computed by `main.zig`) already accounts for
/// `NO_COLOR`: per no-color.org, `auto` must not color when `NO_COLOR` is
/// set, so `main.zig` folds "is a TTY AND NO_COLOR is unset" into this one
/// signal before calling `run`. `.always`/`.never` are explicit user
/// overrides and intentionally ignore both the TTY-ness and `NO_COLOR` --
/// an explicit `--color=always` should punch through a pipe or `NO_COLOR`.
fn resolveColor(mode: ColorMode, stdout_is_tty: bool) bool {
    return switch (mode) {
        .never => false,
        .always => true,
        .auto => stdout_is_tty,
    };
}

/// Directory-walk path COMPONENTS that must never be descended into:
/// generated build output and the compiler's own cache. `.zig-cache` in
/// particular can be enormous and contains no source a user wrote, so
/// walking it wastes time at best and risks linting compiler-generated
/// garbage at worst.
///
/// Matched component-exactly (not as a substring) so a legitimately-named
/// path like `zig-outline/` or `notes.zig-cache.txt` is never mistaken for
/// the directories being skipped.
const skip_components = [_][]const u8{ ".zig-cache", "zig-out" };

fn isSkipped(path: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, path, std.fs.path.sep);
    while (it.next()) |component| {
        for (skip_components) |s| {
            if (std.mem.eql(u8, component, s)) return true;
        }
    }
    return false;
}

test "isSkipped matches path components exactly, not substrings" {
    try std.testing.expect(!isSkipped("zig-outline"));
    try std.testing.expect(!isSkipped("zig-outline/foo.zig"));
    try std.testing.expect(!isSkipped("notes.zig-cache.txt"));
    try std.testing.expect(isSkipped(".zig-cache"));
    try std.testing.expect(isSkipped(".zig-cache/foo.zig"));
    try std.testing.expect(isSkipped("sub/.zig-cache/foo.zig"));
    try std.testing.expect(isSkipped("zig-out"));
    try std.testing.expect(isSkipped("zig-out/bin/zippy"));
}

/// Bundles every argument `run` needs. See the doc comment on `run` for why
/// this is a struct instead of six positional parameters.
pub const RunArgs = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    /// Whether the real process stdout is attached to a terminal. Already
    /// accounts for `NO_COLOR` (see `main.zig`): it's really "should
    /// `--color=auto` behave as if this were a colorful terminal", not a
    /// literal `isatty()` result, so `resolveColor`'s `.auto` branch can
    /// use it directly.
    stdout_is_tty: bool,
    /// Only read by the `lsp` subcommand (see the top of `run`): the framed
    /// JSON-RPC input stream the LSP server reads client messages from.
    /// Every other subcommand ignores it, but it's still required on every
    /// `RunArgs` (rather than optional) so callers can't forget to wire a
    /// real stdin through and have `lsp` silently read nothing.
    stdin: *std.Io.Reader,
};

/// Entry point shared by `main.zig` and (indirectly) tests. `io` is threaded
/// through explicitly rather than pulled from a global, matching every other
/// module in this codebase (`Source.load` in particular needs it).
///
/// Returns the process exit code:
///   0 - clean, or only `.warn`/`.off` diagnostics fired.
///   1 - at least one `.@"error"`-severity diagnostic fired.
///   2 - Zippy itself failed (bad `zippy.zon`, unreadable path, bad usage).
///
/// Takes a single `RunArgs` bundle rather than six positional parameters --
/// same reasoning as `LintFileArgs` below: this codebase caps functions at
/// five parameters (`too_many_params`), and `io`/`gpa`/`args`/`stdout`/
/// `stderr`/`stdout_is_tty` are all independently necessary, so they're
/// grouped into one named, documented struct instead of trimming a
/// genuinely-needed parameter.
pub fn run(a: RunArgs) !u8 {
    // `lsp` is dispatched before any of the lint-mode argument parsing
    // below: it's a wholly different mode (a long-lived JSON-RPC server
    // over stdio, not a one-shot lint-and-exit), so it takes over `run`
    // entirely rather than threading a flag through the lint path.
    if (a.args.len > 0 and std.mem.eql(u8, a.args[0], "lsp")) {
        const server = @import("lsp/server.zig");
        return server.serve(a.io, a.gpa, a.stdin, a.stdout);
    }

    const color_flag_prefix = "--color=";
    var color_mode: ColorMode = .auto;
    var targets: std.ArrayList([]const u8) = .empty;
    defer targets.deinit(a.gpa);
    for (a.args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try a.stdout.writeAll(usage);
            return 0;
        }
        if (std.mem.startsWith(u8, arg, color_flag_prefix)) {
            const value = arg[color_flag_prefix.len..];
            color_mode = parseColorMode(value) orelse {
                try a.stderr.print("zippy: invalid --color value: {s}\n", .{value});
                return 2;
            };
            continue;
        }
        try targets.append(a.gpa, arg);
    }
    if (targets.items.len == 0) {
        try a.stderr.writeAll(usage);
        return 2;
    }
    const use_color = resolveColor(color_mode, a.stdout_is_tty);

    var cfg = loadNearestConfig(a.io, a.gpa) catch |err| {
        try a.stderr.print("zippy: config error: {s}\n", .{@errorName(err)});
        return 2;
    };
    defer cfg.deinit(a.gpa);

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| a.gpa.free(f);
        files.deinit(a.gpa);
    }
    for (targets.items) |t| {
        collectTargets(a.io, a.gpa, t, &files) catch |err| {
            try a.stderr.print("zippy: {s}: {s}\n", .{ t, @errorName(err) });
            return 2;
        };
    }

    var had_error = false;
    const lint_args: LintFileArgs = .{
        .io = a.io,
        .gpa = a.gpa,
        .cfg = &cfg,
        .stdout = a.stdout,
        .use_color = use_color,
    };
    for (files.items) |f| {
        lintFile(lint_args, f, &had_error) catch |err| {
            try a.stderr.print("zippy: {s}: {s}\n", .{ f, @errorName(err) });
            return 2;
        };
    }
    return if (had_error) @as(u8, 1) else @as(u8, 0);
}

/// Resolves `target` to one or more `.zig` files, appending owned path
/// strings to `out`. A file target is taken as-is (the user asked for it
/// explicitly, so it's linted even if its path happens to contain a skipped
/// substring); a directory target is walked, skipping `.zig-cache`/`zig-out`
/// subtrees entirely rather than merely filtering their files out, so those
/// (potentially huge) directories are never even opened.
fn collectTargets(
    io: std.Io,
    gpa: std.mem.Allocator,
    target: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const st = try std.Io.Dir.cwd().statFile(io, target, .{});
    switch (st.kind) {
        .directory => try walkDir(io, gpa, target, out),
        else => try out.append(gpa, try gpa.dupe(u8, target)),
    }
}

fn walkDir(
    io: std.Io,
    gpa: std.mem.Allocator,
    root_path: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer dir.close(io);

    // `walkSelectively` (rather than the auto-recursing `walk`) is used
    // deliberately: it only descends into a directory when `enter` is
    // called, which is exactly the hook needed to skip `.zig-cache`/
    // `zig-out` subtrees instead of just filtering their files after the
    // fact.
    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (isSkipped(entry.path)) continue;
        switch (entry.kind) {
            .directory => try walker.enter(io, entry),
            .file => {
                if (std.mem.endsWith(u8, entry.basename, ".zig")) {
                    const full = try std.fs.path.join(gpa, &.{ root_path, entry.path });
                    try out.append(gpa, full);
                }
            },
            else => {},
        }
    }
}

/// Walks up from the current directory looking for the nearest `zippy.zon`.
/// None found -> `Config.default()`. Found but unparseable -> propagated as
/// an error (fail loud: a broken config the user wrote should never be
/// silently treated as "no config").
fn loadNearestConfig(io: std.Io, gpa: std.mem.Allocator) !Config {
    const cwd_abs = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_abs);
    return loadNearestConfigFrom(io, gpa, cwd_abs);
}

/// Same walk-up as `loadNearestConfig`, but seeded from an arbitrary
/// (absolute) starting directory rather than the process's current
/// directory. Extracted as its own `pub` entry point so callers that don't
/// have a meaningful "current directory" -- e.g. `lsp/documents.zig`
/// resolving a config for a document identified by URI, not by cwd -- can
/// reuse the exact same walk-up/parse/fail-loud behavior instead of
/// duplicating it.
pub fn loadNearestConfigFrom(io: std.Io, gpa: std.mem.Allocator, start_dir: []const u8) !Config {
    var dir_path: []const u8 = start_dir;
    while (true) {
        const candidate = try std.fs.path.join(gpa, &.{ dir_path, "zippy.zon" });
        defer gpa.free(candidate);

        const bytes = std.Io.Dir.cwd().readFileAllocOptions(
            io,
            candidate,
            gpa,
            .limited(1024 * 1024),
            .of(u8),
            0,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                dir_path = std.fs.path.dirname(dir_path) orelse return Config.default();
                continue;
            },
            else => return err,
        };
        defer gpa.free(bytes);
        return Config.loadFromSlice(gpa, bytes);
    }
}

/// Bundles the fixed-for-the-whole-run arguments `lintFile` needs, keeping
/// its own parameter count at (this codebase's own) limit of five: this
/// struct, the path being linted, and the mutable `had_error` flag.
const LintFileArgs = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const Config,
    stdout: *std.Io.Writer,
    use_color: bool,
};

/// Lints a single file: loads it, runs every enabled lint, renders each
/// diagnostic to `stdout` in zig-compiler style, and sets `had_error.*` if
/// any diagnostic fired at `.@"error"` severity.
fn lintFile(a: LintFileArgs, path: []const u8, had_error: *bool) !void {
    var src = try Source.load(a.io, a.gpa, path);
    defer src.deinit(a.gpa);

    var diags: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diags.items) |d| a.gpa.free(d.message);
        diags.deinit(a.gpa);
    }
    try Linter.run(a.gpa, &src, a.cfg, &diags);

    for (diags.items) |d| {
        try d.render(src.bytes, a.stdout, a.use_color);
        if (d.severity == .@"error") had_error.* = true;
    }
}

// `run` exercised end-to-end (no process boundary): real `std.testing.io`,
// real `std.testing.allocator` (so a leak anywhere in `run`'s path fails
// the test), and `std.Io.Writer.Allocating` in place of the real
// stdout/stderr files so assertions can inspect captured output. These run
// with cwd = the project root (`zig build test`'s working directory), so
// the relative `test/fixtures/*.zig` paths resolve and config discovery
// walks up to find no in-repo `zippy.zon`, landing on `Config.default()`.
test "run: no paths -> usage on stderr, exit 2" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var stdin: std.Io.Reader = .fixed("");

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
    });

    try std.testing.expectEqual(@as(u8, 2), code);
    try std.testing.expectEqualStrings("", out.written());
    try std.testing.expect(err.written().len > 0);
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "Usage") != null);
}

test "run: --help -> usage on stdout, exit 0" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var stdin: std.Io.Reader = .fixed("");

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{"--help"},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
    });

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("", err.written());
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Usage") != null);
}

test "run: clean fixture -> no diagnostics, exit 0" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var stdin: std.Io.Reader = .fixed("");

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{"test/fixtures/clean.zig"},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
    });

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("", out.written());
}

test "run: line_width fixture -> warning only, exit 0" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var stdin: std.Io.Reader = .fixed("");

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{"test/fixtures/line_width.zig"},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
    });

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "line_width") != null);
}

test "run: discarded_error fixture -> error severity, exit 1" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var stdin: std.Io.Reader = .fixed("");

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{"test/fixtures/discarded_error.zig"},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
    });

    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "discarded_error") != null);
}

test "run: --color=always -> ANSI escapes in stdout, exit 1" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var stdin: std.Io.Reader = .fixed("");

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{ "--color=always", "test/fixtures/discarded_error.zig" },
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false, // not a tty -- --color=always forces color anyway.
    });

    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[") != null);
}

test "run: --color=never -> no ANSI escapes in stdout" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var stdin: std.Io.Reader = .fixed("");

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{ "--color=never", "test/fixtures/discarded_error.zig" },
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = true, // even a real tty must stay plain w/ --color=never.
    });

    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[") == null);
}

test "run: auto with stdout_is_tty=false -> no ANSI escapes" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var stdin: std.Io.Reader = .fixed("");

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{"test/fixtures/discarded_error.zig"},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
    });

    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[") == null);
}

test "run: unreadable path -> exit 2" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var stdin: std.Io.Reader = .fixed("");

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{"test/fixtures/does_not_exist_xyz.zig"},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
    });

    try std.testing.expectEqual(@as(u8, 2), code);
    try std.testing.expect(err.written().len > 0);
}

test "run: --color=purple (unrecognized value) -> exit 2, stderr names the bad value" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var stdin: std.Io.Reader = .fixed("");

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{ "--color=purple", "test/fixtures/clean.zig" },
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
    });

    try std.testing.expectEqual(@as(u8, 2), code);
    try std.testing.expectEqualStrings("", out.written());
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "purple") != null);
}

// The deep LSP protocol behavior (didOpen/hover/diagnostics/etc.) is already
// covered exhaustively by `lsp/server.zig`'s own tests; this one only proves
// `run` actually ROUTES `args[0] == "lsp"` to `server.serve` with `stdin`/
// `stdout` wired through, rather than falling into the lint-mode argument
// parsing above. An `initialize` + `shutdown` + `exit` script is the
// smallest conversation that both produces visible output (the initialize
// result) and exits 0 (shutdown preceded exit, per the LSP spec).
test "run: 'lsp' subcommand dispatches to the LSP server" {
    const gpa = std.testing.allocator;
    const lsp_transport = @import("lsp/transport.zig");

    var input: std.Io.Writer.Allocating = .init(gpa);
    defer input.deinit();
    try lsp_transport.writeMessage(
        &input.writer,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
    );
    try lsp_transport.writeMessage(
        &input.writer,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}",
    );
    try lsp_transport.writeMessage(&input.writer, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    var stdin: std.Io.Reader = .fixed(input.written());
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{"lsp"},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
    });

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"serverInfo\"") != null);
}

// `loadNearestConfig` walks up from the real current directory, so a
// malformed `zippy.zon` can't be dropped into a `tmpDir` and exercised
// through `run` without changing the process's cwd -- a global, shared piece
// of state that would race with every other test in this file. Instead this
// tests the exact unit `loadNearestConfig` hands its `catch` to on the
// exit-2 branch: `Config.loadFromSlice` on malformed ZON must fail loud with
// `error.ParseZon`, which is the fail-loud guarantee `run`'s config-error
// branch (line ~146) relies on to turn a broken `zippy.zon` into an exit-2
// rather than silently falling back to defaults.
test "Config.loadFromSlice on malformed ZON fails loud with error.ParseZon" {
    const gpa = std.testing.allocator;
    const malformed = ".{ .lints = .{ .line_width = .{ .max = \"not a number\" } } }";
    try std.testing.expectError(error.ParseZon, Config.loadFromSlice(gpa, malformed));
}

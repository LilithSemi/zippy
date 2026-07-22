//! The actual behavior behind the `zippy` executable, kept separate from
//! `main.zig` so it can be driven in tests without a process boundary (no
//! `std.process.exit` lives here -- `run` just returns the exit code).
const std = @import("std");
const Config = @import("Config.zig");
const build_mode = @import("build/mode.zig");

const usage =
    \\Usage: zippy [options]
    \\       zippy lsp
    \\
    \\  -h, --help              Show this help.
    \\  --color=auto|always|never
    \\                          Control ANSI color in diagnostic output.
    \\                          auto (default): color iff stdout is a TTY
    \\                          and NO_COLOR is unset.
    \\  --fix                   Apply every diagnostic's automatic fix (if it
    \\                          has one) to the working tree. Refuses to
    \\                          touch a file with uncommitted git changes
    \\                          unless --allow-dirty is also given.
    \\  --allow-dirty           With --fix, also fix files that have
    \\                          uncommitted git changes. Has no effect
    \\                          without --fix.
    \\  lsp                     Run as a Language Server (LSP over stdio).
    \\
    \\Bare `zippy`, run inside a project with a build.zig, is builder mode: it
    \\builds the project, lints exactly what's actually compiled (plus a
    \\dead_file lint for unreferenced .zig files), and applies fixes with
    \\--fix. Config is the nearest zippy.zon (walking up from cwd); built-in
    \\defaults are used if none is found.
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
    /// The real process environment. Only read by the builder-mode dispatch
    /// below (forwarded to `mode.run` as `base_env`, which spawns `zig
    /// build` needing a real `PATH` etc.), but -- like `stdin` above --
    /// required on every `RunArgs` rather than optional: Zig 0.16's
    /// `std.Io` interface has no accessor for "the current process's
    /// environment" (only `std.process.Init`, which only `main.zig` has,
    /// does), so making this optional would invite a caller to pass `null`
    /// and have builder mode silently fail later instead of a compile-time
    /// reminder to wire the real thing through.
    environ_map: *const std.process.Environ.Map,
};

/// Entry point shared by `main.zig` and (indirectly) tests. `io` is threaded
/// through explicitly rather than pulled from a global, matching every other
/// module in this codebase (`Source.load` in particular needs it).
///
/// Returns the process exit code:
///   0 - clean, or only `.warn`/`.off` diagnostics fired.
///   1 - at least one `.@"error"`-severity diagnostic fired (builder mode).
///   2 - Zippy itself failed (bad usage/unknown argument, no project found,
///       or a builder-mode/`zig build` failure).
///
/// Takes a single `RunArgs` bundle rather than six positional parameters:
/// this codebase caps functions at five parameters (`too_many_params`), and
/// `io`/`gpa`/`args`/`stdout`/`stderr`/`stdout_is_tty` are all independently
/// necessary, so they're grouped into one named, documented struct instead
/// of trimming a genuinely-needed parameter.
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
    var fix_mode = false;
    var allow_dirty = false;
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
        if (std.mem.eql(u8, arg, "--fix")) {
            fix_mode = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--allow-dirty")) {
            allow_dirty = true;
            continue;
        }
        // Any other argument -- a positional path (static-path linting has been
        // removed; builder mode lints the real compile graph instead) or an
        // unrecognized flag -- is a hard usage error rather than something
        // silently linted or forwarded to `zig build`.
        try a.stderr.print("zippy: unknown argument: {s}\n", .{arg});
        return 2;
    }

    // Every invocation that reaches here is bare `zippy` (plus recognized
    // flags): dispatch to builder mode, the sole linting path. It walks up
    // from cwd for a `build.zig`; if none is found anywhere above, there is no
    // project to lint -> usage + exit 2.
    const use_color = resolveColor(color_mode, a.stdout_is_tty);
    const cwd_abs = try std.process.currentPathAlloc(a.io, a.gpa);
    defer a.gpa.free(cwd_abs);
    const project_root = (try findProjectRoot(a.io, a.gpa, cwd_abs)) orelse {
        try a.stderr.writeAll(usage);
        return 2;
    };
    defer a.gpa.free(project_root);
    return build_mode.run(.{
        .io = a.io,
        .gpa = a.gpa,
        .project_root = project_root,
        .build_args = &.{},
        .stdout = a.stdout,
        .stderr = a.stderr,
        .base_env = a.environ_map,
        .use_color = use_color,
        .fix_mode = fix_mode,
        .allow_dirty = allow_dirty,
    });
}

/// Walks up from `start_dir` looking for the nearest `zippy.zon`. None
/// found -> `Config.default()`. Found but unparseable -> propagated as an
/// error (fail loud: a broken config the user wrote should never be
/// silently treated as "no config"). Takes an arbitrary (absolute) starting
/// directory rather than the process's current directory so callers that
/// don't have a meaningful "current directory" -- e.g. `lsp/documents.zig`
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

/// Walks up from `start_dir` looking for a directory containing `build.zig`
/// -- that's what turns bare `zippy` (no path arguments) into builder mode
/// instead of today's "no paths" usage error (see `run`'s dispatch, above).
/// Mirrors `loadNearestConfigFrom`'s walk-up shape exactly, but checks for
/// existence of `build.zig` rather than reading+parsing `zippy.zon`.
///
/// Returns a newly allocated absolute path to the directory found (the
/// caller frees it with `gpa`), or `null` if no `build.zig` was found before
/// reaching the filesystem root.
pub fn findProjectRoot(io: std.Io, gpa: std.mem.Allocator, start_dir: []const u8) !?[]const u8 {
    var dir_path: []const u8 = start_dir;
    while (true) {
        const candidate = try std.fs.path.join(gpa, &.{ dir_path, "build.zig" });
        defer gpa.free(candidate);

        const found = if (std.Io.Dir.cwd().statFile(io, candidate, .{})) |_|
            true
        else |err| switch (err) {
            error.FileNotFound => false,
            else => return err,
        };
        if (found) return try gpa.dupe(u8, dir_path);
        dir_path = std.fs.path.dirname(dir_path) orelse return null;
    }
}

// `run` exercised end-to-end (no process boundary): real `std.testing.io`,
// real `std.testing.allocator` (so a leak anywhere in `run`'s path fails
// the test), and `std.Io.Writer.Allocating` in place of the real
// stdout/stderr files so assertions can inspect captured output. These run
// with cwd = the project root (`zig build test`'s working directory), so
// the relative `test/fixtures/*.zig` paths resolve and config discovery
// walks up to find no in-repo `zippy.zon`, landing on `Config.default()`.
// Previously this asserted "no paths -> usage, exit 2" -- but bare `zippy`
// is no longer just "no paths": per the dispatch added above, it walks up
// from cwd for a `build.zig` and enters builder mode when one is found, and
// `zig build test`'s cwd IS this repo's root, which has one. So this now
// proves the OPPOSITE: real builder mode fires against Zippy's own build
// graph rather than falling into the "no project found" usage/exit-2 path.
// It deliberately does NOT assert an exact diagnostic count or exit code --
// that's self-clean's job elsewhere, and asserting it here would make this
// test brittle to any future churn in Zippy's own source. It only checks
// that the OLD branch didn't fire (no "Usage" text) and that builder mode
// ran to completion without an error bubbling out.
test "run: no paths, cwd inside this project -> builder mode dispatch (not usage)" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var stdin: std.Io.Reader = .fixed("");
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
        .environ_map = &env_map,
    });

    try std.testing.expect(code == 0 or code == 1);
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "Usage") == null);
}

// Regression test: a recognized flag like `--color=never` must be CONSUMED by
// the parse loop (folded into `use_color` and `continue`d past), never falling
// through to the loop's final "unknown argument -> exit 2" branch. This proves
// flags-only args still route to builder mode: same as the no-args test above
// (real repo root, `zig build test`'s cwd has a `build.zig`), but with
// `--color=never` present -- so it fails loud if `--color=` (or any other
// recognized flag) ever regresses to being rejected as an unknown argument.
test "run: flags-only args (--color=never) route to builder mode, not an unknown-arg error" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var stdin: std.Io.Reader = .fixed("");
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{"--color=never"},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
        .environ_map = &env_map,
    });

    try std.testing.expect(code == 0 or code == 1);
    // Neither the "no project found -> usage" branch nor the "unknown
    // argument" branch fired -- the flag was consumed and builder mode ran.
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "Usage") == null);
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "unknown argument") == null);
}

// The old "no build.zig found anywhere above cwd -> usage, exit 2" behavior
// can no longer be exercised through `run` itself now that it's real (see
// the test above) -- `run`'s dispatch always walks up from the REAL process
// cwd, and changing that cwd mid-test-binary would race every other test in
// this file (the same reason `loadNearestConfigFrom`'s walk-up is exercised
// via its own `start_dir` argument, not the process cwd; see the malformed-ZON
// test's comment below). `findProjectRoot` takes an explicit `start_dir`
// instead of reading
// the process cwd, so it sidesteps that entirely and can be tmpDir-tested.
test "findProjectRoot: build.zig in start_dir itself -> found immediately" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });

    const tmp_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(tmp_abs);

    const found = (try findProjectRoot(io, gpa, tmp_abs)).?;
    defer gpa.free(found);
    try std.testing.expectEqualStrings(tmp_abs, found);
}

test "findProjectRoot: walks up through nested subdirectories to a parent build.zig" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.createDirPath(io, "a/b/c");

    const tmp_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(tmp_abs);
    const start = try std.fs.path.join(gpa, &.{ tmp_abs, "a", "b", "c" });
    defer gpa.free(start);

    const found = (try findProjectRoot(io, gpa, start)).?;
    defer gpa.free(found);
    try std.testing.expectEqualStrings(tmp_abs, found);
}

test "findProjectRoot: no build.zig anywhere above start_dir -> null" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Deliberately NOT `std.testing.tmpDir`: that creates directories under
    // `.zig-cache/tmp` INSIDE this very project, which has a `build.zig` at
    // its root -- walking up from there would eventually find it and defeat
    // the point of this test. A real OS scratch directory (fully outside
    // this project's tree) is used instead, mirroring how `mode.run` itself
    // picks its own scratch directory (the `TMPDIR` env var, falling back to
    // `/tmp`).
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();
    const tmp_base = env_map.get("TMPDIR") orelse "/tmp";

    var random_bytes: [12]u8 = undefined;
    io.random(&random_bytes);
    var name_buf: [std.base64.url_safe.Encoder.calcSize(random_bytes.len)]u8 = undefined;
    const name = std.base64.url_safe.Encoder.encode(&name_buf, &random_bytes);
    const dir_path = try std.fmt.allocPrint(gpa, "{s}/zippy-findroot-{s}", .{ tmp_base, name });
    defer gpa.free(dir_path);

    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    try std.testing.expect(try findProjectRoot(io, gpa, dir_path) == null);
}

test "run: --help -> usage on stdout, exit 0" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var stdin: std.Io.Reader = .fixed("");
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{"--help"},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
        .environ_map = &env_map,
    });

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("", err.written());
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Usage") != null);
}

test "run: a positional path argument -> unknown argument, exit 2" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var stdin: std.Io.Reader = .fixed("");
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{"src/main.zig"},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
        .environ_map = &env_map,
    });

    try std.testing.expectEqual(@as(u8, 2), code);
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "unknown argument") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "src/main.zig") != null);
}

test "run: --color=purple (unrecognized value) -> exit 2, stderr names the bad value" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var stdin: std.Io.Reader = .fixed("");
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{"--color=purple"},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
        .environ_map = &env_map,
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
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{"lsp"},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
        .environ_map = &env_map,
    });

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"serverInfo\"") != null);
}

// `loadNearestConfigFrom` walks up looking for `zippy.zon` and hands whatever
// it finds to `Config.loadFromSlice`; this tests that exact unit directly
// rather than through a `tmpDir` + real filesystem walk: `Config.loadFromSlice`
// on malformed ZON must fail loud with `error.ParseZon` rather than silently
// falling back to `Config.default()`, which is what lets every caller of
// `loadNearestConfigFrom` (builder mode, the LSP's per-document config) treat
// a broken `zippy.zon` as a hard failure instead of a silent default.
test "Config.loadFromSlice on malformed ZON fails loud with error.ParseZon" {
    const gpa = std.testing.allocator;
    const malformed = ".{ .lints = .{ .line_width = .{ .max = \"not a number\" } } }";
    try std.testing.expectError(error.ParseZon, Config.loadFromSlice(gpa, malformed));
}

test "parseColorMode recognizes the three modes and rejects others" {
    try std.testing.expectEqual(ColorMode.auto, parseColorMode("auto").?);
    try std.testing.expectEqual(ColorMode.always, parseColorMode("always").?);
    try std.testing.expectEqual(ColorMode.never, parseColorMode("never").?);
    try std.testing.expect(parseColorMode("purple") == null);
    try std.testing.expect(parseColorMode("") == null);
}

test "resolveColor: always/never override tty, auto follows it" {
    try std.testing.expect(resolveColor(.always, false)); // always punches through a pipe
    try std.testing.expect(!resolveColor(.never, true)); // never stays plain even on a tty
    try std.testing.expect(resolveColor(.auto, true)); // auto colors on a tty
    try std.testing.expect(!resolveColor(.auto, false)); // auto stays plain off a tty
}

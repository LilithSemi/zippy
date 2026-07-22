//! The actual behavior behind the `zippy` executable, kept separate from
//! `main.zig` so it can be driven in tests without a process boundary (no
//! `std.process.exit` lives here -- `run` just returns the exit code).
const std = @import("std");
const Source = @import("Source.zig");
const Config = @import("Config.zig");
const Linter = @import("Linter.zig");
const Diagnostic = @import("Diagnostic.zig");
const paths = @import("paths.zig");
const build_mode = @import("build/mode.zig");
const fix = @import("fix.zig");

const usage =
    \\Usage: zippy [options] [paths...]
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
    \\Bare `zippy` (no paths), run inside a project with a build.zig, runs
    \\builder mode: it builds the project and lints exactly what's actually
    \\compiled, plus a dead_file lint for unreferenced .zig files. Passing
    \\explicit paths lints those files directly and is deprecated in favor
    \\of builder mode.
    \\
    \\Lints .zig files (directories are walked). Reads the nearest zippy.zon,
    \\walking up from the current directory; if none is found, built-in
    \\defaults are used.
    \\
;

/// Printed to stderr before falling back to static (explicit-paths) mode --
/// see `run`'s dispatch, below. Static mode is being phased out in favor of
/// builder mode (which lints exactly the real compile graph, not whatever
/// paths happen to be passed), but stays fully supported so this is a
/// heads-up, not a hard error.
const deprecation_note =
    "zippy: linting explicit paths is deprecated; run zippy in a project for builder mode\n";

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

/// Shared with `build/dead_file.zig`'s dead-file walk -- see `paths.zig`'s
/// doc comment for why the two need to agree on exactly which subtrees are
/// skipped, and the `isSkipped`-matches-components-exactly test that moved
/// there with it.
const isSkipped = paths.isSkipped;

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
///   1 - at least one `.@"error"`-severity diagnostic fired.
///   2 - Zippy itself failed (bad `zippy.zon`, unreadable path, bad usage,
///       or -- with `--fix` -- `fix.apply` itself failing to read/write a
///       file it had already decided to touch).
///
/// With `--fix`: every diagnostic carrying a `.fix` is collected and handed
/// to `fix.apply` once, after all normal rendering is done (never before --
/// re-reading a file `fix.apply` already spliced would misalign every
/// diagnostic's byte offsets against the now-shorter/longer source). The
/// exit code then uses an approximation rather than re-linting the fixed
/// files: if the apply pass was fully clean (nothing refused or skipped),
/// every diagnostic that HAD a `.fix` is treated as resolved and excluded
/// from the error-severity check; otherwise (any refusal/skip happened) this
/// falls back to the conservative, unmodified rule -- every `.@"error"`
/// diagnostic counts, fixed or not -- so a partially-applied `--fix` run
/// never falsely reports clean to a caller (e.g. CI) that checks the exit
/// code alone.
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
    // Both consumed here, never appended to `targets` (so neither is ever
    // mistaken for a path target in static mode, nor forwarded as a `zig
    // build` argument in builder mode's dispatch below).
    var fix_mode = false;
    var allow_dirty = false;
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
        if (std.mem.eql(u8, arg, "--fix")) {
            fix_mode = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--allow-dirty")) {
            allow_dirty = true;
            continue;
        }
        try targets.append(a.gpa, arg);
    }
    // No explicit path arguments: this is bare `zippy`, which (per the
    // deprecation note below) is now the PREFERRED way to invoke Zippy --
    // dispatch to builder mode if the cwd sits inside a project (walking up
    // for a `build.zig`, mirroring `loadNearestConfig`'s walk-up for
    // `zippy.zon`). Only when no `build.zig` is found anywhere above cwd
    // does this fall back to today's "no paths -> usage, exit 2".
    // Resolved once, up front, and reused by both dispatch branches below
    // (builder mode and static mode): they must agree on exactly the same
    // `--color`/TTY/`NO_COLOR` decision, so there is exactly one place that
    // makes it, not two copies that could drift.
    const use_color = resolveColor(color_mode, a.stdout_is_tty);
    if (targets.items.len == 0) {
        const cwd_abs = try std.process.currentPathAlloc(a.io, a.gpa);
        defer a.gpa.free(cwd_abs);
        const project_root = (try findProjectRoot(a.io, a.gpa, cwd_abs)) orelse {
            try a.stderr.writeAll(usage);
            return 2;
        };
        defer a.gpa.free(project_root);
        // No leftover args to forward: everything in `a.args` was already
        // consumed above as `-h`/`--help` (which returned already),
        // `--color=`, `--fix`, or `--allow-dirty` -- none of which `zig
        // build` understands. In particular `build_args` is unconditionally
        // empty here, so a flag meant for Zippy can never leak through to
        // the spawned `zig build` invocation as an argument it doesn't
        // recognize -- each is fully consumed by the parse loop above
        // (resolved into `use_color`/`fix_mode`/`allow_dirty`, never
        // appended to `targets`).
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
    try a.stderr.writeAll(deprecation_note);

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

    var tracking: ErrorTracking = .{};
    // Collects a COPY of every diagnostic that carries a `.fix`, across every
    // file, so `fix.apply` can be called once at the end with the full set
    // rather than per-file -- see `lintFile`'s doc comment for why a copy
    // (not the original `Diagnostic`) is what gets appended here. Built
    // regardless of `fix_mode` costs nothing when it stays empty (the common
    // case: today only `unused_decl` ever sets `.fix`), so there's no need to
    // thread `fix_mode` down into `lintFile` just to skip it.
    var fixable: std.ArrayList(Diagnostic) = .empty;
    defer fixable.deinit(a.gpa);
    const lint_args: LintFileArgs = .{
        .io = a.io,
        .gpa = a.gpa,
        .cfg = &cfg,
        .stdout = a.stdout,
        .use_color = use_color,
    };
    for (files.items) |f| {
        lintFile(lint_args, f, &tracking, &fixable) catch |err| {
            try a.stderr.print("zippy: {s}: {s}\n", .{ f, @errorName(err) });
            return 2;
        };
    }

    if (!fix_mode) return if (tracking.any) @as(u8, 1) else @as(u8, 0);

    // `fix.apply` runs only now, AFTER every diagnostic above has already
    // been rendered against the original (pre-fix) source -- rendering
    // against a file `fix.apply` already spliced would misalign every
    // diagnostic's byte offsets against the now-different-length text. Its
    // own failure (a read/write error on a file it had already decided to
    // touch) is caught and turned into this function's documented exit-2
    // contract rather than left to propagate as a raw Zig error, matching
    // every other Zippy-itself-failed branch in this function.
    const result = fix.apply(a.gpa, a.io, fixable.items, allow_dirty, a.stderr) catch |err| {
        try a.stderr.print("zippy: fix apply failed: {s}\n", .{@errorName(err)});
        return 2;
    };
    try a.stderr.print(
        "zippy: applied {d} fix(es), {d} skipped, {d} refused\n",
        .{ result.applied, result.skipped, result.refused },
    );
    // See `run`'s doc comment for the exit-code approximation this
    // implements: a fully clean apply pass (nothing refused or skipped)
    // treats every diagnostic that HAD a `.fix` as resolved; any refusal or
    // skip falls back to the conservative `tracking.any` (every
    // `.@"error"` diagnostic counts, fixed or not).
    const clean = result.refused == 0 and result.skipped == 0;
    const had_error = if (clean) tracking.unfixable else tracking.any;
    return if (had_error) @as(u8, 1) else @as(u8, 0);
}

/// Accumulates two exit-code signals across every file `lintFile` processes,
/// bundled into one struct (rather than two separate `*bool` parameters) so
/// `lintFile` stays under this codebase's five-parameter cap. See `run`'s
/// doc comment for how `--fix` uses the distinction between the two.
const ErrorTracking = struct {
    /// True if ANY `.@"error"`-severity diagnostic fired, fixed or not. This
    /// alone is the exit-code signal when `--fix` wasn't given (unchanged
    /// from before `--fix` existed) and the conservative fallback signal
    /// when `--fix` was given but its apply pass wasn't fully clean.
    any: bool = false,
    /// True if an `.@"error"`-severity diagnostic fired that had NO `.fix`
    /// at all -- i.e. one `--fix` could never have resolved regardless of
    /// how its apply pass went. Used as the exit-code signal only when
    /// `--fix` ran AND its apply pass was fully clean.
    unfixable: bool = false,
};

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

/// Bundles the fixed-for-the-whole-run arguments `lintFile` needs, keeping
/// its own parameter count at (this codebase's own) limit of five: this
/// struct, the path being linted, the mutable `tracking` accumulator, and
/// the `fixable` list collected diagnostics are appended to.
const LintFileArgs = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const Config,
    stdout: *std.Io.Writer,
    use_color: bool,
};

/// Lints a single file: loads it, runs every enabled lint, renders each
/// diagnostic to `stdout` in zig-compiler style, and folds its findings into
/// `tracking` (see `ErrorTracking`'s doc comment).
///
/// Every diagnostic that carries a `.fix` also gets a COPY appended to
/// `fixable`, for `run` to hand to `fix.apply` once at the end across every
/// file. The copy's `.message` is overwritten with a static `""` rather than
/// kept as-is: `.message` is gpa-owned and freed by this function's own
/// `defer` below right after rendering, so keeping the original pointer
/// around in `fixable` past that point would leave a dangling reference
/// sitting in the list. `fix.apply` never reads `.message` (only `.path`/
/// `.fix`), so the empty placeholder is never observed. `.path` needs no
/// such copy -- it borrows from the caller's `files` list in `run`, which
/// outlives this whole loop (freed only in `run`'s own `defer`, well after
/// `fix.apply` is called).
fn lintFile(
    a: LintFileArgs,
    path: []const u8,
    tracking: *ErrorTracking,
    fixable: *std.ArrayList(Diagnostic),
) !void {
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
        if (d.severity == .@"error") {
            tracking.any = true;
            if (d.fix == null) tracking.unfixable = true;
        }
        if (d.fix != null) {
            var copy = d;
            copy.message = "";
            try fixable.append(a.gpa, copy);
        }
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

// Regression test: the dispatch above branches on `targets.items.len == 0`,
// NOT `a.args.len == 0` -- `--color=never` is a real element of `a.args` that
// must be parsed out as a color flag (never appended to `targets`) before
// that check runs. A naive `a.args.len == 0` check would wrongly treat any
// non-empty `args` (including flags-only args like this) as "explicit paths
// given" and fall into static/deprecated-path mode instead of builder mode.
// This proves flags-only args still route to builder mode: same as the
// no-args test above (real repo root, `zig build test`'s cwd has a
// `build.zig`), but with `--color=never` present -- so it fails loud if that
// branch ever regresses to checking `a.args.len` instead of `targets.len`,
// or if `--color=never` were ever mistakenly treated as a path target (which
// would make `collectTargets` stat a file named literally `--color=never`
// and fail, landing on exit 2 with a stderr message naming that bogus path
// rather than clean builder-mode output).
test "run: flags-only args (--color=never), no paths -> builder mode dispatch, not static mode" {
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
    // Neither the old "no paths -> usage" branch nor the deprecated static
    // path (which prints this note for every explicit-path invocation) fired.
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "Usage") == null);
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "deprecated") == null);
}

// The old "no build.zig found anywhere above cwd -> usage, exit 2" behavior
// can no longer be exercised through `run` itself now that it's real (see
// the test above) -- `run`'s dispatch always walks up from the REAL process
// cwd, and changing that cwd mid-test-binary would race every other test in
// this file (the same reason `loadNearestConfig`'s walk-up was never
// tmpDir-tested directly either; see the malformed-ZON test's comment
// below). `findProjectRoot` takes an explicit `start_dir` instead of reading
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

test "run: explicit path -> deprecation note on stderr before static-mode output" {
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
        .args = &.{"test/fixtures/clean.zig"},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
        .environ_map = &env_map,
    });

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "deprecated") != null);
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

test "run: clean fixture -> no diagnostics, exit 0" {
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
        .args = &.{"test/fixtures/clean.zig"},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
        .environ_map = &env_map,
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
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{"test/fixtures/line_width.zig"},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
        .environ_map = &env_map,
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
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{"test/fixtures/discarded_error.zig"},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
        .environ_map = &env_map,
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
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{ "--color=always", "test/fixtures/discarded_error.zig" },
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false, // not a tty -- --color=always forces color anyway.
        .environ_map = &env_map,
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
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{ "--color=never", "test/fixtures/discarded_error.zig" },
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = true, // even a real tty must stay plain w/ --color=never.
        .environ_map = &env_map,
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
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{"test/fixtures/discarded_error.zig"},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
        .environ_map = &env_map,
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
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{"test/fixtures/does_not_exist_xyz.zig"},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .stdin = &stdin,
        .stdout_is_tty = false,
        .environ_map = &env_map,
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
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();

    const code = try run(.{
        .io = std.testing.io,
        .gpa = gpa,
        .args = &.{ "--color=purple", "test/fixtures/clean.zig" },
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

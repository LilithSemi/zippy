//! Builder-mode driver: the orchestrator behind bare `zippy` in a project
//! that has a `build.zig`. Spawns `zig build` with the embedded
//! `--build-runner` (`runner.zig`), reads the manifest it emits, walks
//! `@import`/`@embedFile` reachability from the manifest's roots
//! (`reachable.zig`), lints every reachable file under the project root
//! (the existing `Source`/`Config`/`Linter`/`Diagnostic` pipeline), and adds
//! a conservative `dead_file` diagnostic for every `.zig` file under the
//! project root that's on disk but reachable from none of those roots
//! (`dead_file.zig`).
//!
//! This is the "fat Zippy" half of the architecture: the embedded runner is
//! deliberately std-only and minimal (see `runner.zig`'s own doc comment);
//! everything that actually understands Zippy's lints, config, and
//! diagnostics lives here instead, so the runner never has to change when a
//! lint does.
//!
//! FAIL LOUD: if the child `zig build` invocation fails for any reason (bad
//! `build.zig`, `zig` missing, a crash, a non-zero exit), this returns exit
//! code 2 with the child's stderr forwarded -- there is deliberately no
//! silent fallback to linting the raw file tree. A build that doesn't build
//! is exactly the situation where Zippy must not pretend everything is fine.
const std = @import("std");
const manifest = @import("manifest.zig");
const reachable = @import("reachable.zig");
const dead_file = @import("dead_file.zig");
const Source = @import("../Source.zig");
const Config = @import("../Config.zig");
const Linter = @import("../Linter.zig");
const Diagnostic = @import("../Diagnostic.zig");
const cli = @import("../cli.zig");
const fix = @import("../fix.zig");

/// The `--build-runner` implementation, embedded into the `zippy` binary at
/// compile time so it ships as a single static executable with no sidecar
/// files. `run` writes these exact bytes out to a tmp file at runtime and
/// hands that path to `zig build --build-runner`. See `runner.zig`'s own
/// doc comment for why it has to be a near-standalone file (it can't
/// `@import` any other Zippy module once it's compiled out-of-tree by the
/// `zig` frontend).
const runner_source = @embedFile("runner.zig");

/// Bundles every argument `run` needs into one struct rather than six-plus
/// positional parameters -- this codebase caps functions at five params
/// (its own `too_many_params` lint, which self-lints this very file), and
/// every field below is independently necessary, so `cli.zig`'s `RunArgs`
/// pattern is reused here rather than trimming a genuinely-needed argument.
pub const RunArgs = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Absolute path to the directory containing the project's `build.zig`.
    project_root: []const u8,
    /// Extra arguments forwarded verbatim to the spawned `zig build`
    /// invocation (e.g. `-Dfoo=bar`); the embedded runner only understands
    /// `-D` itself (see `runner.zig`), everything else is parsed just far
    /// enough to be skipped.
    build_args: []const []const u8,
    /// The real process environment the spawned `zig build` should inherit,
    /// with `ZIPPY_MANIFEST` added on top by `run`. Threaded in from the
    /// caller rather than fetched here because Zig 0.16's `std.Io` interface
    /// (unlike `std.process.Init`) has no accessor for "the current
    /// process's environment" -- only whichever `main` received it from the
    /// runtime does. Passing `null` instead (asking `std.process.run` to
    /// just inherit the parent's environment untouched) isn't an option
    /// either: there would be no way to add `ZIPPY_MANIFEST` on top.
    base_env: *const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    /// Whether rendered diagnostics (both regular lint findings and
    /// `dead_file` findings below) should include ANSI color escapes --
    /// resolved by `cli.zig`'s `resolveColor` from `--color`/TTY-ness/
    /// `NO_COLOR` the exact same way static mode resolves it, then threaded
    /// through here so builder mode honors `--color` identically instead of
    /// hardcoding plain output.
    use_color: bool,
    /// `--fix`: after the normal render pass, collect every `.lint`-kind
    /// `MergedDiag` that carries a `.fix` and hand them to `fix.apply` once.
    /// Defaults to `false` so every existing caller (in particular the four
    /// `e2e_test.zig` invocations predating `--fix`) keeps building without
    /// having to name this field.
    fix_mode: bool = false,
    /// `--allow-dirty`, forwarded verbatim to `fix.apply`. Has no effect
    /// unless `fix_mode` is also set. Same default-`false` reasoning as
    /// `fix_mode` above.
    allow_dirty: bool = false,
};

/// Which of the three diagnostic sources produced a `MergedDiag`, needed by
/// the unified render pass in `run` for two things a bare `Diagnostic` alone
/// can't tell it: whether `.diag.message` is gpa-owned and must be freed
/// (only `.lint` -- see `Linter.run`'s own allocations; `.dead_file`'s
/// message is a static string literal and `.compile_error`'s is borrowed
/// from the parsed manifest, so freeing either would be a double-free), and
/// whether an unreadable-source fallback is even possible for this entry at
/// all (only `.compile_error` -- see `MergedDiag.ce` and `run`'s render loop).
const DiagKind = enum { lint, dead_file, compile_error };

/// One diagnostic plus enough provenance for `run`'s unified render pass to
/// treat it correctly regardless of which of the three sources (lint,
/// `dead_file`, compiler error) produced it. All three sources feed the same
/// `std.ArrayList(MergedDiag)`, which is then sorted once by
/// `(diag.path, diag.byte_offset)` so the final output reads in file order
/// across ALL of them -- a single merged stream -- rather than as three
/// separately-ordered blocks: a compiler error on an earlier line of a file
/// renders before a lint on a later line of that same file.
const MergedDiag = struct {
    diag: Diagnostic,
    kind: DiagKind,
    /// Only populated (non-null) when `kind == .compile_error`: the manifest
    /// entry `diag` was built from, kept around so the render pass can fall
    /// back to a header-only render using `ce.line`/`ce.col` if `diag.path`
    /// turns out to be unreadable (e.g. a `std` or dependency file). Lints
    /// and `dead_file` entries never need this fallback -- both are always
    /// project files Zippy has already proven it can read (lints by having
    /// just loaded them to run `Linter.run`; `dead_file` by having just found
    /// them on disk via its own directory walk) -- so it stays `null` there.
    ce: ?manifest.CompileError = null,
};

/// Runs the full builder-mode flow and returns the process exit code:
///   0 - clean, or only `.warn`/`.off` diagnostics fired.
///   1 - at least one `.@"error"`-severity diagnostic fired (a real lint
///       finding, or a `dead_file` whose resolved severity is `.@"error"`).
///   2 - Zippy itself failed: the child `zig build` failed or couldn't be
///       spawned, the manifest was missing/unparseable, the project root
///       vanished, a file it needed to read became unreadable mid-run, or --
///       with `--fix` -- `fix.apply` itself failed to read/write a file it
///       had already decided to touch.
///
/// With `--fix` (`a.fix_mode`): after the render pass below (never before --
/// see the comment at the fix-apply call site for why), every `.lint`-kind
/// `MergedDiag` carrying a `.fix` is collected and handed to `fix.apply`
/// once. `dead_file`/`compile_error` entries never carry a `.fix` (see
/// `DiagKind`'s doc comment), so they're untouched either way. The exit code
/// then uses the same approximation `cli.zig`'s static mode uses (see its
/// `run`'s doc comment): a fully clean apply pass treats every diagnostic
/// that HAD a `.fix` as resolved and excludes it from the error-severity
/// check; any refusal/skip falls back to the original, unmodified rule --
/// every `.@"error"` diagnostic counts, fixed or not -- so a partially
/// applied `--fix` run never reports a falsely-clean exit code.
pub fn run(a: RunArgs) !u8 {
    const tmp_base = a.base_env.get("TMPDIR") orelse "/tmp";
    var random_bytes: [12]u8 = undefined;
    a.io.random(&random_bytes);
    var name_buf: [std.base64.url_safe.Encoder.calcSize(random_bytes.len)]u8 = undefined;
    const name = std.base64.url_safe.Encoder.encode(&name_buf, &random_bytes);

    const tmp_dir_path = try std.fmt.allocPrint(a.gpa, "{s}/zippy-{s}", .{ tmp_base, name });
    defer a.gpa.free(tmp_dir_path);
    std.Io.Dir.cwd().createDirPath(a.io, tmp_dir_path) catch |err| {
        try a.stderr.print("zippy: failed to create temp dir: {s}\n", .{@errorName(err)});
        return 2;
    };
    // Best-effort: a scratch tmp dir failing to delete (e.g. it was already
    // removed by something else) must never turn a successful lint run into
    // a failure -- matches `std.testing.tmpDir`'s own `TmpDir.cleanup`. Only
    // registered once `createDirPath` above has actually succeeded, so a
    // create failure never schedules a `deleteTree` on a directory that was
    // never made.
    defer std.Io.Dir.cwd().deleteTree(a.io, tmp_dir_path) catch {};

    const runner_abs = try std.fs.path.join(a.gpa, &.{ tmp_dir_path, "zippy_runner.zig" });
    defer a.gpa.free(runner_abs);
    const runner_file: std.Io.Dir.WriteFileOptions = .{
        .sub_path = runner_abs,
        .data = runner_source,
    };
    std.Io.Dir.cwd().writeFile(a.io, runner_file) catch |err| {
        try a.stderr.print("zippy: failed to write build runner: {s}\n", .{@errorName(err)});
        return 2;
    };

    const manifest_abs = try std.fs.path.join(a.gpa, &.{ tmp_dir_path, "manifest.json" });
    defer a.gpa.free(manifest_abs);

    var env_map = try a.base_env.clone(a.gpa);
    defer env_map.deinit();
    try env_map.put("ZIPPY_MANIFEST", manifest_abs);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a.gpa);
    try argv.appendSlice(a.gpa, &.{ "zig", "build", "--build-runner", runner_abs });
    try argv.appendSlice(a.gpa, a.build_args);

    const result = std.process.run(a.gpa, a.io, .{
        .argv = argv.items,
        .cwd = .{ .path = a.project_root },
        .environ_map = &env_map,
    }) catch |err| {
        try a.stderr.print(
            "zippy: failed to run 'zig build --build-runner': {s}\n",
            .{@errorName(err)},
        );
        return 2;
    };
    defer a.gpa.free(result.stdout);
    defer a.gpa.free(result.stderr);

    // FAIL LOUD: no fallback to linting the raw file tree if the project
    // doesn't actually build -- see this file's doc comment.
    const exit_code: ?u8 = switch (result.term) {
        .exited => |code| code,
        else => null,
    };
    if (exit_code != 0) {
        try a.stderr.writeAll(result.stderr);
        return 2;
    }

    const manifest_bytes = std.Io.Dir.cwd().readFileAlloc(
        a.io,
        manifest_abs,
        a.gpa,
        .unlimited,
    ) catch |err| {
        try a.stderr.print("zippy: could not read build manifest: {s}\n", .{@errorName(err)});
        return 2;
    };
    defer a.gpa.free(manifest_bytes);

    var parsed = manifest.parse(a.gpa, manifest_bytes) catch |err| {
        try a.stderr.print("zippy: could not parse build manifest: {s}\n", .{@errorName(err)});
        return 2;
    };
    defer parsed.deinit();

    // `reachable.collect`'s keys are canonical (symlink-resolved) paths, so
    // `project_root` must be canonicalized the same way before it's used as
    // a prefix -- otherwise a symlinked project root would make every real
    // reachable file look like it's outside of it. `dead_file.find` below
    // gets the raw, uncanonicalized `project_root` instead: it canonicalizes
    // each candidate itself before comparing (see its own doc comment) and
    // only needs a directory to open, not a canonical spelling of it.
    const project_root_canon = (try reachable.canonicalize(a.io, a.gpa, a.project_root)) orelse {
        try a.stderr.print("zippy: project root not found: {s}\n", .{a.project_root});
        return 2;
    };
    defer a.gpa.free(project_root_canon);

    // Only the PROJECT's own roots -- see `projectRootPaths`'s doc comment
    // for why a dependency root (`root.is_dependency`) is skipped here rather
    // than merely filtered out downstream: Zippy must never lint dependency
    // code, and starting the reachability walk from a dependency root at all
    // would pull its files into the reachable set.
    const root_paths = try projectRootPaths(a.gpa, parsed.value.roots);
    defer a.gpa.free(root_paths);

    // Cross-module `@import`s name a module (e.g. `@import("uefi")`), never a
    // file path, so this walk can't accidentally wander INTO a dependency
    // even starting purely from project roots -- the reachable set stays
    // project-files-only. `isUnderRoot` below is therefore redundant for
    // dependency exclusion now, but harmless to keep (it still matters if a
    // manifest root ever names a path genuinely outside `project_root` for
    // some other reason).
    var reached = try reachable.collect(a.io, a.gpa, root_paths);
    defer {
        var it = reached.keyIterator();
        while (it.next()) |k| a.gpa.free(k.*);
        reached.deinit(a.gpa);
    }

    var cfg = cli.loadNearestConfigFrom(a.io, a.gpa, a.project_root) catch |err| {
        try a.stderr.print("zippy: config error: {s}\n", .{@errorName(err)});
        return 2;
    };
    defer cfg.deinit(a.gpa);

    var tracking: ErrorTracking = .{};

    // Every diagnostic from all three sources (lints, `dead_file`, compiler
    // errors) is collected into ONE list here, then sorted once below by
    // `(path, byte_offset)` and rendered as a SINGLE merged stream -- see
    // `MergedDiag`'s doc comment for why, rather than as three
    // separately-ordered blocks the way this used to work. Both `defer`s
    // below are declared immediately so every exit path out of the rest of
    // this function (including the early `return 2`s further down) still
    // cleans them up, not just the happy path.
    var merged: std.ArrayList(MergedDiag) = .empty;
    defer merged.deinit(a.gpa);
    // Frees only the gpa-owned `.lint` messages (see `DiagKind`'s doc
    // comment) -- declared AFTER `merged`'s own `defer` above, so by `defer`
    // LIFO ordering it runs BEFORE `merged.deinit`, i.e. still after the
    // unified render pass below has read every message, exactly like the
    // free used to happen right after `lintFile`'s own render loop.
    defer {
        for (merged.items) |m| {
            if (m.kind == .lint) m.diag.deinit(a.gpa);
        }
    }

    // Sorted for deterministic output: `reached` is a hash map, whose
    // iteration order is otherwise arbitrary and would make Zippy's own
    // output (and any test asserting on it) flaky from run to run.
    var lint_targets: std.ArrayList([]const u8) = .empty;
    defer lint_targets.deinit(a.gpa);
    {
        var it = reached.keyIterator();
        while (it.next()) |k| {
            if (isUnderRoot(k.*, project_root_canon)) try lint_targets.append(a.gpa, k.*);
        }
    }
    std.mem.sort([]const u8, lint_targets.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    const lint_args: LintFileArgs = .{ .io = a.io, .gpa = a.gpa, .cfg = &cfg };
    for (lint_targets.items) |path| {
        lintFile(lint_args, path, &merged) catch |err| {
            try a.stderr.print("zippy: {s}: {s}\n", .{ path, @errorName(err) });
            return 2;
        };
    }

    const dead = dead_file.find(
        a.io,
        a.gpa,
        a.project_root,
        &reached,
        parsed.value.dep_dirs,
    ) catch |err| {
        try a.stderr.print("zippy: dead-file scan failed: {s}\n", .{@errorName(err)});
        return 2;
    };
    defer {
        for (dead) |d| a.gpa.free(d);
        a.gpa.free(dead);
    }
    for (dead) |path| {
        const diag = deadFileDiagnostic(path, &cfg) orelse continue;
        try merged.append(a.gpa, .{ .diag = diag, .kind = .dead_file });
    }

    // Unlike lints and `dead_file` (both scoped to `isUnderRoot`), compiler
    // errors are collected for EVERY path the compiler reported one against
    // -- including a file in `std` or a dependency the project doesn't own.
    // A build that doesn't compile clean must stay visible even when the
    // failing code isn't something the project's author can edit directly;
    // silently dropping it just because it's outside `project_root` would
    // hide a real break behind a false "clean" report.
    for (parsed.value.errors) |ce| {
        try merged.append(a.gpa, .{
            .diag = compileErrorToDiagnostic(ce),
            .kind = .compile_error,
            .ce = ce,
        });
    }

    // A single sort over ALL three sources together -- by path first (so
    // every diagnostic for a file is contiguous, letting the render pass
    // below load each file's source exactly once), then by byte offset
    // within a path (so within one file the output reads top-to-bottom
    // regardless of which of the three sources a given diagnostic came from).
    std.mem.sort(MergedDiag, merged.items, {}, struct {
        fn lessThan(_: void, lhs: MergedDiag, rhs: MergedDiag) bool {
            const path_order = std.mem.order(u8, lhs.diag.path, rhs.diag.path);
            if (path_order != .eq) return path_order == .lt;
            return lhs.diag.byte_offset < rhs.diag.byte_offset;
        }
    }.lessThan);

    // Renders the merged, sorted stream, (re)loading a file's source only
    // when the path actually changes from one entry to the next -- safe
    // because the sort above guarantees every diagnostic for a given path is
    // contiguous.
    var loaded_path: ?[]const u8 = null;
    var loaded_src: ?Source = null;
    var load_err: ?anyerror = null;
    defer if (loaded_src) |*s| s.deinit(a.gpa);

    for (merged.items) |m| {
        if (loaded_path == null or !std.mem.eql(u8, loaded_path.?, m.diag.path)) {
            if (loaded_src) |*s| s.deinit(a.gpa);
            loaded_src = null;
            loaded_path = m.diag.path;
            load_err = null;
            if (Source.load(a.io, a.gpa, m.diag.path)) |s| {
                loaded_src = s;
            } else |err| {
                load_err = err;
            }
        }

        if (loaded_src) |s| {
            try m.diag.render(s.bytes, a.stdout, a.use_color);
        } else if (m.kind == .compile_error) {
            // The offending file can't be read (e.g. it lives in `std` or
            // some other path this process has no access to, or it's been
            // removed since the compile ran) -- render the header line only,
            // using the manifest's own `line`/`col` rather than `Diagnostic
            // .render`'s `lineColAt`, which needs real source bytes to
            // recompute a line/col from a byte offset and would otherwise
            // report a nonsense location (or a huge caret) for empty input.
            // The error itself must still surface -- an unreadable path is a
            // reason to drop the snippet, never a reason to drop the error.
            try renderUnreadableCompileError(m.ce.?, a.stdout, a.use_color);
        } else {
            // Only a compiler error can reference a path outside the
            // project (lints and `dead_file` are always project files Zippy
            // has already proven it can read -- see `MergedDiag.ce`'s doc
            // comment), so reaching here for a `.lint`/`.dead_file` entry
            // means a project file became unreadable between being scanned
            // and being rendered here -- fail loud rather than silently drop
            // it, matching this function's own FAIL LOUD doc comment.
            try a.stderr.print("zippy: {s}: {s}\n", .{ m.diag.path, @errorName(load_err.?) });
            return 2;
        }

        if (m.diag.severity == .@"error") {
            tracking.any = true;
            if (m.diag.fix == null) tracking.unfixable = true;
        }
    }

    if (!a.fix_mode) return if (tracking.any) @as(u8, 1) else @as(u8, 0);

    // `fix.apply` runs only now, AFTER the render pass above has already
    // rendered every diagnostic against the original (pre-fix) source --
    // running it any earlier would let it splice a file on disk before that
    // file's own diagnostics were rendered, misaligning their byte offsets
    // against the now-different-length text (or, in the merged multi-source
    // stream here, potentially against a LATER diagnostic sharing that same
    // path). Only `.lint`-kind entries can carry a `.fix` at all (`dead_file`
    // and `compile_error` never do -- see `DiagKind`'s doc comment), so this
    // filter alone is enough; no separate check of `m.kind` covers something
    // `m.diag.fix != null` doesn't already imply.
    var fixable: std.ArrayList(Diagnostic) = .empty;
    defer fixable.deinit(a.gpa);
    for (merged.items) |m| {
        if (m.kind == .lint and m.diag.fix != null) try fixable.append(a.gpa, m.diag);
    }

    const fix_result = fix.apply(a.io, a.gpa, fixable.items, a.allow_dirty, a.stderr) catch |err| {
        try a.stderr.print("zippy: fix apply failed: {s}\n", .{@errorName(err)});
        return 2;
    };
    try a.stderr.print(
        "zippy: applied {d} fix(es), {d} skipped, {d} refused\n",
        .{ fix_result.applied, fix_result.skipped, fix_result.refused },
    );
    // See `run`'s doc comment for the exit-code approximation this
    // implements.
    const clean = fix_result.refused == 0 and fix_result.skipped == 0;
    const had_error = if (clean) tracking.unfixable else tracking.any;
    return if (had_error) @as(u8, 1) else @as(u8, 0);
}

/// Accumulates two exit-code signals across the whole merged render pass,
/// bundled into one struct so the field-access sites above stay simple. See
/// `run`'s doc comment for how `--fix` uses the distinction between the two;
/// mirrors `cli.zig`'s own `ErrorTracking` (kept separate rather than shared
/// since the two modules aren't otherwise coupled -- same reasoning as
/// `LintFileArgs` below).
const ErrorTracking = struct {
    /// True if ANY `.@"error"`-severity diagnostic fired, fixed or not.
    any: bool = false,
    /// True if an `.@"error"`-severity diagnostic fired that had NO `.fix`
    /// at all. Always true alongside `any` for `dead_file`/`compile_error`
    /// entries (neither ever carries a `.fix`), and only ever diverges from
    /// `any` when a `.lint` entry with a `.fix` is the sole error-severity
    /// finding.
    unfixable: bool = false,
};

/// Builds the `Diagnostic` for one manifest `CompileError`. Always
/// `.@"error"` severity (there is no such thing as a warning-level compiler
/// error) and tagged `"zig"` so rendered output reads distinctly from
/// Zippy's own AST-lint diagnostics. `byte_offset`/`end_offset` are seeded
/// from the error's SPAN (`span_start`/`span_end`), not its `line`/`col`:
/// `Diagnostic.render` recomputes line/col itself from the byte offset via
/// `lineColAt`, so handing it the span keeps the rendered caret aligned to
/// the real source instead of round-tripping through two independent
/// line/col systems (the compiler's own and `lineColAt`'s).
fn compileErrorToDiagnostic(ce: manifest.CompileError) Diagnostic {
    return .{
        .path = ce.path,
        .byte_offset = ce.span_start,
        .end_offset = ce.span_end,
        .severity = .@"error",
        .lint = "zig",
        .message = ce.message,
    };
}

/// Renders one compiler error's header line ONLY -- no source line, no caret
/// -- for when `Source.load` couldn't read `ce.path`. Mirrors the header
/// `Diagnostic.render` itself prints (`path:line:col: error: message [zig]`,
/// with the same bold-red/dim ANSI escapes when `use_color` is set), using
/// `ce.line`/`ce.col` directly rather than deriving them from a byte offset,
/// since there's no source text here for `lineColAt` to derive them from.
fn renderUnreadableCompileError(
    ce: manifest.CompileError,
    w: *std.Io.Writer,
    use_color: bool,
) !void {
    if (use_color) {
        // Dims only the lint name `zig` inside plain brackets -- `[{s}{s}{s}]`
        // in `Diagnostic.render` -- not the brackets themselves; matches that
        // exact escape placement rather than dimming the whole `[zig]` tag.
        try w.print("{s}:{d}:{d}: \x1b[1;31merror\x1b[0m: {s} [\x1b[2mzig\x1b[0m]\n", .{
            ce.path, ce.line, ce.col, ce.message,
        });
    } else {
        try w.print("{s}:{d}:{d}: error: {s} [zig]\n", .{
            ce.path, ce.line, ce.col, ce.message,
        });
    }
}

/// Returns the `path` of every root in `roots` that belongs to the PROJECT's
/// own build, skipping every `root.is_dependency` root -- the set fed to
/// `reachable.collect`, so the reachability walk (and therefore the eventual
/// lint target set) never starts from a dependency's module at all, no
/// matter where that dependency happens to live on disk (a dependency can be
/// vendored UNDER `project_root` itself, e.g. `zig-pkg/uefi-<hash>/`, which a
/// path-prefix filter alone can't distinguish from project code -- see
/// `runner.zig`'s `dependencyDir` for how `is_dependency` is actually
/// determined). Returns a slice the caller owns (`gpa.free` it); the
/// individual `path` strings are borrowed from `roots` and outlive this call
/// via the manifest's own arena/parsed-json ownership, so they aren't duped.
fn projectRootPaths(gpa: std.mem.Allocator, roots: []const manifest.Root) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    for (roots) |root| {
        if (root.is_dependency) continue;
        try out.append(gpa, root.path);
    }
    return out.toOwnedSlice(gpa);
}

/// True if canonicalized `path` sits at or under canonicalized `root`.
///
/// The manifest (and therefore `reachable.collect`'s output) can include
/// roots pulled in from dependency PACKAGES cached under
/// `~/.cache/zig/p/<hash>` -- needed so the reachability walk can follow
/// intra-project `@import` chains that happen to pass through them -- but
/// those are third-party sources a `zippy` user can't act on. Only files
/// under `root` (the project actually being linted) should ever be linted
/// or reported on; `dead_file.find` is naturally already scoped to
/// `project_root` by its own directory walk, so this filter only needs to
/// apply to the reachable set.
///
/// A plain `startsWith` isn't enough: `/proj2` starts with `/proj` as a
/// string but isn't under it as a path, so a component boundary is checked
/// too (either an exact match, or the next byte after the prefix is a path
/// separator).
fn isUnderRoot(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    return path[root.len] == std.fs.path.sep;
}

/// Builds the `dead_file` diagnostic for `path`, or `null` if the `unused`
/// group's resolved severity is `.off` -- mirrors `Linter.run`'s own
/// severity gate (it never constructs a `Diagnostic` for an `.off` lint
/// either), so a user who disables `dead_file` sees nothing at all rather
/// than a diagnostic that gets filtered right back out.
fn deadFileDiagnostic(path: []const u8, cfg: *const Config) ?Diagnostic {
    const severity = cfg.severityFor("dead_file", .unused);
    if (severity == .off) return null;
    return .{
        .path = path,
        .byte_offset = 0,
        .end_offset = 0,
        .severity = severity,
        .lint = "dead_file",
        .message = "file is not referenced by any compilation",
    };
}

/// Bundles the fixed-for-the-whole-run arguments `lintFile` needs, keeping
/// its own parameter count at this codebase's limit of five: this struct,
/// the path being linted, and the output list diagnostics are appended to --
/// same reasoning as `cli.zig`'s own `LintFileArgs`/`lintFile`, which this
/// deliberately mirrors rather than sharing (that pair is private to
/// `cli.zig`, and the two modules aren't otherwise coupled).
const LintFileArgs = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const Config,
};

/// Lints a single file and appends every diagnostic it fires to `merged`,
/// tagged `.lint` so `run`'s unified render pass knows `.message` is
/// gpa-owned and must be freed once rendering is done (see `DiagKind`'s doc
/// comment). Rendering itself doesn't happen here -- `run` collects every
/// diagnostic from all three sources first, sorts them into one
/// `(path, byte_offset)` stream, and renders that -- so this only needs the
/// source long enough for `Linter.run` to walk it; the render pass reloads
/// the same file itself once it gets there.
fn lintFile(a: LintFileArgs, path: []const u8, merged: *std.ArrayList(MergedDiag)) !void {
    var src = try Source.load(a.io, a.gpa, path);
    defer src.deinit(a.gpa);

    var diags: std.ArrayList(Diagnostic) = .empty;
    defer diags.deinit(a.gpa);
    try Linter.run(a.gpa, &src, a.cfg, &diags);

    for (diags.items) |d| try merged.append(a.gpa, .{ .diag = d, .kind = .lint });
}

test "projectRootPaths: skips dependency roots, even one vendored under project_root" {
    const gpa = std.testing.allocator;
    const roots = [_]manifest.Root{
        .{
            .path = "/proj/src/main.zig",
            .module = "root",
            .step = "exe",
            .target = "",
            .is_dependency = false,
        },
        // Mirrors a dependency vendored UNDER the project tree (a package
        // dir like `zig-pkg/uefi-<hash>/`, not `~/.cache`) -- the exact case
        // a path-prefix filter alone can't catch, since it physically sits
        // inside `/proj`. `is_dependency` (set by the build graph, not the
        // path -- see `runner.zig`'s `dependencyDir`) is what this function
        // actually keys off.
        .{
            .path = "/proj/zig-pkg/uefi-abc123/uefi.zig",
            .module = "uefi",
            .step = "exe",
            .target = "",
            .is_dependency = true,
        },
    };
    const out = try projectRootPaths(gpa, &roots);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("/proj/src/main.zig", out[0]);
}

test "projectRootPaths: a manifest with only dependency roots yields an empty list" {
    const gpa = std.testing.allocator;
    const roots = [_]manifest.Root{.{
        .path = "/proj/zig-pkg/uefi-abc123/uefi.zig",
        .module = "uefi",
        .step = "exe",
        .target = "",
        .is_dependency = true,
    }};
    const out = try projectRootPaths(gpa, &roots);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "isUnderRoot: file under root, root itself, and a same-prefix sibling" {
    try std.testing.expect(isUnderRoot("/home/user/proj/src/main.zig", "/home/user/proj"));
    try std.testing.expect(isUnderRoot("/home/user/proj", "/home/user/proj"));
    // `/home/user/proj2` textually starts with `/home/user/proj` but is a
    // different directory entirely -- the component-boundary check must
    // reject it.
    try std.testing.expect(!isUnderRoot("/home/user/proj2/src/main.zig", "/home/user/proj"));
    try std.testing.expect(!isUnderRoot("/home/user/other/x.zig", "/home/user/proj"));
}

test "deadFileDiagnostic: default config resolves dead_file to warn" {
    const cfg = Config.default();
    const diag = deadFileDiagnostic("/proj/stray.zig", &cfg).?;
    try std.testing.expectEqualStrings("/proj/stray.zig", diag.path);
    try std.testing.expectEqual(@as(usize, 0), diag.byte_offset);
    try std.testing.expectEqual(@as(usize, 0), diag.end_offset);
    try std.testing.expectEqual(Diagnostic.Severity.warn, diag.severity);
    try std.testing.expectEqualStrings("dead_file", diag.lint);
    try std.testing.expectEqualStrings(
        "file is not referenced by any compilation",
        diag.message,
    );
}

test "deadFileDiagnostic: severity .off yields null (no diagnostic at all)" {
    const gpa = std.testing.allocator;
    var cfg = try Config.loadFromSlice(gpa, ".{ .groups = .{ .unused = .off } }");
    defer cfg.deinit(gpa);
    try std.testing.expect(deadFileDiagnostic("/proj/stray.zig", &cfg) == null);
}

test "deadFileDiagnostic: correctness-group severity does not leak into dead_file" {
    // `dead_file` lives in the `unused` group, not `correctness` -- a config
    // that only touches `correctness` (which defaults to `.@"error"`, see
    // `Config.zig`) must not accidentally elevate `dead_file` too.
    const cfg = Config.default();
    const diag = deadFileDiagnostic("/proj/stray.zig", &cfg).?;
    try std.testing.expect(diag.severity != .@"error");
}

test "compiler errors from the manifest render as zig error diagnostics" {
    // Build a Diagnostic from a manifest CompileError and assert its fields.
    const ce: manifest.CompileError = .{
        .path = "/p/src/main.zig",
        .line = 3,
        .col = 5,
        .span_start = 40,
        .span_end = 44,
        .message = "expected type 'u8', found 'bool'",
    };
    const d = compileErrorToDiagnostic(ce);
    try std.testing.expectEqualStrings("zig", d.lint);
    try std.testing.expectEqual(Diagnostic.Severity.@"error", d.severity);
    try std.testing.expectEqual(@as(usize, 40), d.byte_offset);
    try std.testing.expectEqual(@as(usize, 44), d.end_offset);
    try std.testing.expectEqualStrings("expected type 'u8', found 'bool'", d.message);
}

test "renderUnreadableCompileError: header-only fallback for an unreadable path, no crash" {
    // Direct unit test for the unreadable-file fallback `run`'s merged
    // render pass falls back to when `Source.load` fails for a compile-error
    // entry (e.g. the error is in `std` or a dependency this process can't
    // read) -- this used to only be exercised indirectly (if at all) via a
    // real `zig build` in the e2e tests. `ce.path` here is never written to
    // disk on purpose: the whole point is proving this never tries to read
    // it (no snippet, no crash), only ever uses `ce.line`/`ce.col` directly.
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const ce: manifest.CompileError = .{
        .path = "/nonexistent/path/does/not/exist.zig",
        .line = 7,
        .col = 3,
        .span_start = 0,
        .span_end = 0,
        .message = "no such file or directory",
    };
    try renderUnreadableCompileError(ce, &out.writer, false);

    const text = out.written();
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "/nonexistent/path/does/not/exist.zig:7:3: error: no such file or directory [zig]",
    ) != null);
    // Header-only: exactly one line, no source snippet or caret beneath it.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\n"));
}

test "renderUnreadableCompileError: color escapes dim only the lint name" {
    // `Diagnostic.render` dims only the lint name inside plain brackets
    // (`[{dim}zig{reset}]`), not the whole `[zig]` tag -- this fallback must
    // match that exact placement (FIX 3) rather than `{dim}[zig]{reset}`.
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const ce: manifest.CompileError = .{
        .path = "/nonexistent/path/does/not/exist.zig",
        .line = 1,
        .col = 1,
        .span_start = 0,
        .span_end = 0,
        .message = "boom",
    };
    try renderUnreadableCompileError(ce, &out.writer, true);

    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "[\x1b[2mzig\x1b[0m]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[2m[zig]\x1b[0m") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[1;31merror\x1b[0m") != null);
}

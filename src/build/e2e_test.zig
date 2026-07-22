//! End-to-end test for the whole builder-mode chain, in one shot: embedded
//! runner -> real `zig build --build-runner` -> manifest -> reachability
//! walk -> lint + dead-file. Every other test in `build/` exercises one link
//! of that chain in isolation (`runner_test.zig` the runner itself,
//! `reachable_test`/`dead_file.zig` the walks on a synthetic manifest,
//! `mode.zig`'s own tests the pure helpers); this is the one that proves
//! they actually fit together end to end, against a real `zig build` on a
//! real (if tiny) project -- calling `mode.run` directly rather than
//! `cli.run` so the test doesn't also have to fight the process's real
//! current directory (see `cli.zig`'s own comment on why THAT can't be
//! tmpDir-tested).
const std = @import("std");
const mode = @import("mode.zig");

test "mode.run on a tmp project: naming_convention on the real root + dead_file on a stray file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\    const exe = b.addExecutable(.{
        \\        .name = "proj",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/main.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\    });
        \\    b.installArtifact(exe);
        \\}
    });
    try tmp.dir.createDirPath(io, "src");
    // PLANTED lint: `Bad_Name` isn't camelCase, so `naming_convention` must
    // fire on the REAL root (reached only via the runner -> manifest ->
    // reachability walk, not a static directory scan).
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data =
        \\pub fn main() void {}
        \\fn Bad_Name() void {}
        \\
        ,
    });
    // PLANTED dead file: on disk under the project root, but `@import`ed /
    // `@embedFile`d by nothing reachable from `src/main.zig` -- the
    // `dead_file` lint must flag exactly this.
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/stray.zig",
        .data = "pub const unused: u8 = 0;\n",
    });
    // `std.testing.tmpDir` nests this project under `<cwd>/.zig-cache/tmp/`
    // (see its implementation), i.e. *inside* this very repo when `zig build
    // test` runs -- so `cli.loadNearestConfigFrom`'s walk-up from
    // `project_root` would, without this file, keep going past the tmp dir
    // and find THIS repo's own root `zippy.zon` (which turns the `unused`
    // group off for its own dogfooding reasons; see that file). Planting an
    // explicit, empty `zippy.zon` here stops the walk at the tmp root and
    // keeps this test hermetic -- `.{}` parses to the exact same effective
    // config as "no file found" (`Config.default()`), so this changes
    // nothing about what's under test, it just stops the walk from escaping
    // the tmp project.
    try tmp.dir.writeFile(io, .{ .sub_path = "zippy.zon", .data = ".{}\n" });

    const tmp_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(tmp_abs);

    // `mode.run` spawns a real `zig build`, which needs a real environment
    // (PATH etc.) to find `zig` and its own toolchain -- `std.testing.environ`
    // is the real process environment the test binary itself was launched
    // with (see `test_runner.zig`'s `testing.environ = init.environ`), not a
    // synthetic/empty one.
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();

    const code = try mode.run(.{
        .io = io,
        .gpa = gpa,
        .project_root = tmp_abs,
        .build_args = &.{},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .base_env = &env_map,
        .use_color = false,
    });

    if (code == 2 and std.mem.indexOf(u8, err.written(), "FileNotFound") != null) {
        // `zig` isn't on PATH in whatever environment is running this test --
        // matches `runner_test.zig`'s own skip for the same reason. The
        // devshell always has it, but nothing here should hard-fail a
        // checkout that happens to lack it.
        std.log.warn("skipping builder-mode e2e test: 'zig' not found on PATH", .{});
        return error.SkipZigTest;
    }
    if (code == 2) {
        std.debug.print("mode.run failed (exit 2), stderr:\n{s}\n", .{err.written()});
        return error.BuildRunnerFailed;
    }

    // Both planted lints resolve to `.warn` under the tmp project's
    // effectively-default `zippy.zon` (planted above, `.{}`), so neither
    // sets `had_error` -- exit 0 is the correct "clean" result, not evidence
    // the lints didn't fire.
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "naming_convention") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "dead_file") != null);
}

// `mode.run` used to hardcode `false` for `use_color` on both render calls
// (the regular lint findings AND the `dead_file` finding), so `--color` was
// silently ignored in builder mode -- unlike static mode, which always
// honored it via `cli.zig`'s `resolveColor`. That became user-reachable the
// moment bare `zippy` became the default dispatch. This proves
// `RunArgs.use_color` now actually reaches BOTH render call sites: the same
// planted `naming_convention` + `dead_file` pair as above, but run twice
// (once with `use_color = true`, once `false`) to prove the ANSI escapes
// track the flag rather than being always-on or always-off.
test "mode.run: use_color=true adds ANSI escapes to both lint and dead_file output" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\    const exe = b.addExecutable(.{
        \\        .name = "proj",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/main.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\    });
        \\    b.installArtifact(exe);
        \\}
    });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data =
        \\pub fn main() void {}
        \\fn Bad_Name() void {}
        \\
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/stray.zig",
        .data = "pub const unused: u8 = 0;\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "zippy.zon", .data = ".{}\n" });

    const tmp_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(tmp_abs);

    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();

    const colored = try runOnce(gpa, io, tmp_abs, &env_map, true);
    defer gpa.free(colored.out);
    defer gpa.free(colored.err);
    if (colored.skip) {
        std.log.warn("skipping builder-mode e2e test: 'zig' not found on PATH", .{});
        return error.SkipZigTest;
    }
    try std.testing.expectEqual(@as(u8, 0), colored.code);
    // Both the lint finding and the dead_file finding must be colored: the
    // bold-yellow "warning" escape fires for both (they're both `.warn`
    // under the tmp project's default config), so its presence alongside
    // both lint names is enough to prove NEITHER render call was skipped.
    try std.testing.expect(std.mem.indexOf(u8, colored.out, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored.out, "naming_convention") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored.out, "dead_file") != null);

    const plain = try runOnce(gpa, io, tmp_abs, &env_map, false);
    defer gpa.free(plain.out);
    defer gpa.free(plain.err);
    try std.testing.expectEqual(@as(u8, 0), plain.code);
    try std.testing.expect(std.mem.indexOf(u8, plain.out, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain.out, "naming_convention") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain.out, "dead_file") != null);
}

// Tier 2: the embedded runner now actually runs the project's `Step
// .Compile`s (not just walks the graph for roots, as Tier 1 did) and
// captures their real compiler-error bundle into the manifest's `errors[]`
// -- see `runner.zig`'s `runSteps`/`collectErrors` and `manifest.zig`'s
// `CompileError`. This proves `mode.run` actually renders those alongside
// its existing AST lints, in the SAME run: `src/main.zig` below carries
// both a planted `naming_convention` violation (an AST lint, found by the
// existing static `Linter.run` pipeline) and a genuine type error (`const
// x: u8 = true;`, only discoverable by actually compiling) -- both must show
// up in one invocation's stdout, and the type error's presence must flip the
// exit code to 1 (a lint-only run with only `.warn` findings, like the test
// above, stays at exit 0; a real compiler error never does).
test "mode.run renders a real compiler error alongside an AST lint, in one run" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\    const exe = b.addExecutable(.{
        \\        .name = "proj",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/main.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\    });
        \\    b.installArtifact(exe);
        \\}
    });
    try tmp.dir.createDirPath(io, "src");
    // PLANTED lint: `Bad_Name` isn't camelCase (`naming_convention`).
    // PLANTED compiler error: assigning a `bool` to a `u8` const is a real
    // type error, only found by actually compiling `main.zig`, not by
    // `Linter.run`'s AST-only checks.
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data =
        \\pub fn main() void {
        \\    const x: u8 = true;
        \\    _ = x;
        \\}
        \\fn Bad_Name() void {}
        \\
        ,
    });
    // Turns `unused`/`dead_file` off so this test only has to reason about
    // the two planted findings above (`main.zig` would otherwise also be
    // clean here, but this keeps the config minimal and matches the brief).
    try tmp.dir.writeFile(io, .{
        .sub_path = "zippy.zon",
        .data = ".{ .groups = .{ .unused = .off } }\n",
    });

    const tmp_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(tmp_abs);

    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();

    const code = try mode.run(.{
        .io = io,
        .gpa = gpa,
        .project_root = tmp_abs,
        .build_args = &.{},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .base_env = &env_map,
        .use_color = false,
    });

    if (code == 2 and std.mem.indexOf(u8, err.written(), "FileNotFound") != null) {
        std.log.warn("skipping builder-mode e2e test: 'zig' not found on PATH", .{});
        return error.SkipZigTest;
    }
    if (code == 2) {
        std.debug.print("mode.run failed (exit 2), stderr:\n{s}\n", .{err.written()});
        return error.BuildRunnerFailed;
    }

    // The real compiler error is `.@"error"` severity unconditionally, so its
    // mere presence must flip the exit code to 1, unlike the lint-only test
    // above (whose `naming_convention`/`dead_file` findings are both `.warn`
    // under the same default config).
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "naming_convention") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[zig]") != null);
    // The compiler's own message text for this exact mistake -- proves the
    // rendered diagnostic carries the real compile error, not just the tag.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "bool") != null);
}

// Tier 2, FIX 1: `mode.run` used to render three separately-ordered blocks
// (lints sorted by path, then `dead_file` in whatever order `dead_file.find`
// returned it, then compiler errors sorted among themselves) concatenated
// one after another -- so a compiler error and a lint on the very SAME file
// would render in whichever BLOCK order happened to come first, never in
// file order relative to each other. `mode.run` now collects every
// diagnostic from all three sources into one list and sorts it once by
// `(path, byte_offset)` before rendering, so the final stream reads in file
// order across all of them. This is the payoff case: a real compiler error
// on line 2 of `src/main.zig` and a planted `naming_convention` violation on
// line 5 of that SAME file -- the compiler error's own text must appear in
// stdout strictly BEFORE the lint's, proving the merge (not just the
// presence of both) is actually wired up.
test "mode.run: merged sort renders an earlier compiler error before a later same-file lint" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\    const exe = b.addExecutable(.{
        \\        .name = "proj",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/main.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\    });
        \\    b.installArtifact(exe);
        \\}
    });
    try tmp.dir.createDirPath(io, "src");
    // The compiler error (`u8`/`bool` mismatch) is on line 2, well BEFORE the
    // planted `naming_convention` violation (`Bad_Name`) on line 5.
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data =
        \\pub fn main() void {
        \\    const x: u8 = true;
        \\    _ = x;
        \\}
        \\fn Bad_Name() void {}
        \\
        ,
    });
    // Same reasoning as the sibling test above: keeps this test's assertions
    // scoped to the two planted findings, and stops `loadNearestConfigFrom`
    // from walking up into this repo's own root `zippy.zon`.
    try tmp.dir.writeFile(io, .{
        .sub_path = "zippy.zon",
        .data = ".{ .groups = .{ .unused = .off } }\n",
    });

    const tmp_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(tmp_abs);

    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();

    const code = try mode.run(.{
        .io = io,
        .gpa = gpa,
        .project_root = tmp_abs,
        .build_args = &.{},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .base_env = &env_map,
        .use_color = false,
    });

    if (code == 2 and std.mem.indexOf(u8, err.written(), "FileNotFound") != null) {
        std.log.warn("skipping builder-mode e2e test: 'zig' not found on PATH", .{});
        return error.SkipZigTest;
    }
    if (code == 2) {
        std.debug.print("mode.run failed (exit 2), stderr:\n{s}\n", .{err.written()});
        return error.BuildRunnerFailed;
    }
    // The real compiler error is always `.@"error"` severity, so its mere
    // presence flips the exit code to 1.
    try std.testing.expectEqual(@as(u8, 1), code);

    const text = out.written();
    const compile_err_idx = std.mem.indexOf(u8, text, "[zig]") orelse
        return error.CompileErrorNotFoundInOutput;
    const lint_idx = std.mem.indexOf(u8, text, "naming_convention") orelse
        return error.LintNotFoundInOutput;
    try std.testing.expect(compile_err_idx < lint_idx);
}

/// One `mode.run` invocation against an already-planted tmp project,
/// returning owned copies of stdout/stderr (so the `Allocating` writers used
/// to capture them can be torn down before returning) plus whether the run
/// should be treated as a `zig`-not-on-PATH skip. Factored out so the
/// use_color test above can run the exact same project twice (once per
/// `use_color` value) without duplicating the whole capture/skip dance.
const RunOnceResult = struct { code: u8, out: []const u8, err: []const u8, skip: bool };

fn runOnce(
    gpa: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    env_map: *const std.process.Environ.Map,
    use_color: bool,
) !RunOnceResult {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();

    const code = try mode.run(.{
        .io = io,
        .gpa = gpa,
        .project_root = project_root,
        .build_args = &.{},
        .stdout = &out.writer,
        .stderr = &err.writer,
        .base_env = env_map,
        .use_color = use_color,
    });

    const skip = code == 2 and std.mem.indexOf(u8, err.written(), "FileNotFound") != null;
    return .{
        .code = code,
        .out = try gpa.dupe(u8, out.written()),
        .err = try gpa.dupe(u8, err.written()),
        .skip = skip,
    };
}

//! End-to-end test for `build/runner.zig`. That file can't be unit-tested
//! in isolation -- it needs a real `@import("@build")`, which only exists
//! when the `zig` compiler frontend is the one compiling it as an actual
//! build runner. So instead this test drives the real thing: it writes a
//! tiny throwaway project (a `build.zig` building an exe from
//! `src/main.zig`) plus a copy of `runner.zig`'s own source to a tmp
//! directory, runs `zig build --build-runner <copy>` against it with
//! `ZIPPY_MANIFEST` pointed at a tmp file, and checks that the resulting
//! manifest really does list the project's root source file.
const std = @import("std");
const manifest = @import("manifest.zig");

/// The exact bytes embedded into the real `zippy` binary by the (later)
/// CLI build-mode wiring -- using the same file here means this test is
/// exercising the runner Zippy will actually ship, not a stale copy.
const runner_source = @embedFile("runner.zig");

test "zig build --build-runner with our runner emits a manifest listing the real root" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "runner.zig", .data = runner_source });
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
        .data = "pub fn main() void {}\n",
    });

    const tmp_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(tmp_abs);
    const runner_abs = try tmp.dir.realPathFileAlloc(io, "runner.zig", gpa);
    defer gpa.free(runner_abs);
    const main_abs = try tmp.dir.realPathFileAlloc(io, "src/main.zig", gpa);
    defer gpa.free(main_abs);
    const manifest_path = try std.fs.path.join(gpa, &.{ tmp_abs, "m.json" });
    defer gpa.free(manifest_path);

    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();
    try env_map.put("ZIPPY_MANIFEST", manifest_path);

    const result = std.process.run(gpa, io, .{
        .argv = &.{ "zig", "build", "--build-runner", runner_abs },
        .cwd = .{ .path = tmp_abs },
        .environ_map = &env_map,
    }) catch |err| switch (err) {
        // `zig` isn't on PATH in whatever environment is running this test;
        // the devshell always has it, but nothing about this runner test
        // should hard-fail a checkout that happens to lack it.
        error.FileNotFound => {
            std.log.warn("skipping runner e2e test: 'zig' not found on PATH", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const exit_code: ?u8 = switch (result.term) {
        .exited => |code| code,
        else => null,
    };
    if (exit_code != 0) {
        std.debug.print("zig build --build-runner failed (exit {?d}):\n{s}\n", .{
            exit_code, result.stderr,
        });
        return error.BuildRunnerFailed;
    }

    const manifest_bytes = try tmp.dir.readFileAlloc(io, "m.json", gpa, .unlimited);
    defer gpa.free(manifest_bytes);

    var parsed = try manifest.parse(gpa, manifest_bytes);
    defer parsed.deinit();

    try std.testing.expectEqualStrings(tmp_abs, parsed.value.project_root);

    var found_main = false;
    for (parsed.value.roots) |root| {
        if (std.mem.eql(u8, root.path, main_abs)) found_main = true;
    }
    try std.testing.expect(found_main);
}

test "manifest includes a static library linked into an exe but never installed itself" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "runner.zig", .data = runner_source });
    // `lib` is linked into `exe` via `exe.root_module.linkLibrary(lib)` but
    // only `exe` is `installArtifact`'d -- before FIX 1 (enqueuing
    // `Module.link_objects`' `.other_step`s during the graph walk), `lib`
    // was never reachable from a top-level step's `step.dependencies`
    // alone, so its root (`src/lib.zig`) never made it into the manifest.
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\    const lib = b.addLibrary(.{
        \\        .linkage = .static,
        \\        .name = "lib",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/lib.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\    });
        \\    const exe = b.addExecutable(.{
        \\        .name = "proj",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/main.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\    });
        \\    exe.root_module.linkLibrary(lib);
        \\    b.installArtifact(exe);
        \\}
    });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data = "pub fn main() void {}\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/lib.zig",
        .data = "export fn add(a: i32, b: i32) i32 { return a + b; }\n",
    });

    const tmp_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(tmp_abs);
    const runner_abs = try tmp.dir.realPathFileAlloc(io, "runner.zig", gpa);
    defer gpa.free(runner_abs);
    const lib_abs = try tmp.dir.realPathFileAlloc(io, "src/lib.zig", gpa);
    defer gpa.free(lib_abs);
    const manifest_path = try std.fs.path.join(gpa, &.{ tmp_abs, "m.json" });
    defer gpa.free(manifest_path);

    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();
    try env_map.put("ZIPPY_MANIFEST", manifest_path);

    const result = std.process.run(gpa, io, .{
        .argv = &.{ "zig", "build", "--build-runner", runner_abs },
        .cwd = .{ .path = tmp_abs },
        .environ_map = &env_map,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.warn("skipping runner e2e test: 'zig' not found on PATH", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const exit_code: ?u8 = switch (result.term) {
        .exited => |code| code,
        else => null,
    };
    if (exit_code != 0) {
        std.debug.print("zig build --build-runner failed (exit {?d}):\n{s}\n", .{
            exit_code, result.stderr,
        });
        return error.BuildRunnerFailed;
    }

    const manifest_bytes = try tmp.dir.readFileAlloc(io, "m.json", gpa, .unlimited);
    defer gpa.free(manifest_bytes);

    var parsed = try manifest.parse(gpa, manifest_bytes);
    defer parsed.deinit();

    var found_lib = false;
    for (parsed.value.roots) |root| {
        if (std.mem.eql(u8, root.path, lib_abs)) found_lib = true;
    }
    try std.testing.expect(found_lib);
}

test "zig build --build-runner captures both a type error and an unused-local error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "runner.zig", .data = runner_source });
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
    // Two independent error classes from one file: `x` is a genuine type
    // mismatch (semantic analysis), `y` is a wholly unrelated unused-local
    // constant (a separate, later diagnostic pass) -- proving the runner
    // captures more than just the first error the compiler happens to hit.
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data =
        \\pub fn main() void {
        \\    const x: u8 = true;
        \\    _ = x;
        \\    const y: u8 = 1;
        \\}
        \\
        ,
    });

    const tmp_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(tmp_abs);
    const runner_abs = try tmp.dir.realPathFileAlloc(io, "runner.zig", gpa);
    defer gpa.free(runner_abs);
    const main_abs = try tmp.dir.realPathFileAlloc(io, "src/main.zig", gpa);
    defer gpa.free(main_abs);
    const manifest_path = try std.fs.path.join(gpa, &.{ tmp_abs, "m.json" });
    defer gpa.free(manifest_path);

    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();
    try env_map.put("ZIPPY_MANIFEST", manifest_path);

    const result = std.process.run(gpa, io, .{
        .argv = &.{ "zig", "build", "--build-runner", runner_abs },
        .cwd = .{ .path = tmp_abs },
        .environ_map = &env_map,
    }) catch |err| switch (err) {
        // `zig` isn't on PATH in whatever environment is running this test;
        // the devshell always has it, but nothing about this runner test
        // should hard-fail a checkout that happens to lack it.
        error.FileNotFound => {
            std.log.warn("skipping runner e2e test: 'zig' not found on PATH", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    // A real compile error means the child `zig build --build-runner`
    // itself exits non-zero (`Step.Compile.make` returns `error.MakeFailed`
    // for a step with a populated error bundle -- see `runSteps`'
    // doc comment) -- that's expected here, NOT the "infra fault" case
    // `collectErrors` would `fatal` on, since the bundle is populated. The
    // manifest must still have been written before that non-zero exit.
    const manifest_bytes = try tmp.dir.readFileAlloc(io, "m.json", gpa, .unlimited);
    defer gpa.free(manifest_bytes);

    var parsed = try manifest.parse(gpa, manifest_bytes);
    defer parsed.deinit();

    // Tier-1 behavior intact: the real root is still enumerated even though
    // this compile fails.
    var found_main = false;
    for (parsed.value.roots) |root| {
        if (std.mem.eql(u8, root.path, main_abs)) found_main = true;
    }
    try std.testing.expect(found_main);

    var found_type_error = false;
    var found_unused = false;
    for (parsed.value.errors) |err| {
        if (std.mem.indexOf(u8, err.message, "expected type") != null and
            std.mem.indexOf(u8, err.message, "'u8'") != null)
        {
            found_type_error = true;
            // `const x: u8 = true;` is line 2 of `src/main.zig` (line 1 is
            // the `pub fn main` header); the bundle's own `SourceLocation
            // .line` is 0-based, so this also pins down that the runner
            // emits 1-based line numbers rather than passing that raw.
            try std.testing.expectEqual(@as(u32, 2), err.line);
        }
        if (std.mem.indexOf(u8, err.message, "unused") != null) found_unused = true;
    }
    try std.testing.expect(found_type_error);
    try std.testing.expect(found_unused);
}

test "a skipped Run step generating a module's source blocks its dependent, not panics" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "runner.zig", .data = runner_source });
    // `gen` is a small host tool whose `Step.Run` output (`generated.zig`) is
    // imported as a module by `proj` -- the classic codegen shape. This
    // runner never executes `Step.Run` (see `runner.zig`'s `runSteps`), so
    // `generated.zig` is never actually written and the `LazyPath` handed to
    // `generated_module`'s `root_source_file` has a permanently-null
    // `GeneratedFile.path`. Before FIX 1 (skip propagation in
    // `dependencyFailed`), `proj`'s compile step would still get `make()`'d
    // anyway, and resolving that null generated path mid-compile hits std's
    // own `@panic("misconfigured build script")`, aborting the whole runner
    // before any manifest is written. The only thing this test asserts is
    // that this no longer happens: the runner exits 0 and a manifest,
    // listing both real (non-generated) roots, still gets written.
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
        \\    const gen_exe = b.addExecutable(.{
        \\        .name = "gen",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("gen.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\    });
        \\
        \\    const run_gen = b.addRunArtifact(gen_exe);
        \\    const generated = run_gen.addOutputFileArg("generated.zig");
        \\
        \\    const generated_module = b.createModule(.{
        \\        .root_source_file = generated,
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\
        \\    const exe = b.addExecutable(.{
        \\        .name = "proj",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/main.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\    });
        \\    exe.root_module.addImport("generated", generated_module);
        \\    b.installArtifact(exe);
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "gen.zig", .data = "pub fn main() void {}\n" });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data =
        \\const generated = @import("generated");
        \\pub fn main() void {
        \\    _ = generated;
        \\}
        \\
        ,
    });

    const tmp_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(tmp_abs);
    const runner_abs = try tmp.dir.realPathFileAlloc(io, "runner.zig", gpa);
    defer gpa.free(runner_abs);
    const gen_abs = try tmp.dir.realPathFileAlloc(io, "gen.zig", gpa);
    defer gpa.free(gen_abs);
    const main_abs = try tmp.dir.realPathFileAlloc(io, "src/main.zig", gpa);
    defer gpa.free(main_abs);
    const manifest_path = try std.fs.path.join(gpa, &.{ tmp_abs, "m.json" });
    defer gpa.free(manifest_path);

    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();
    try env_map.put("ZIPPY_MANIFEST", manifest_path);

    const result = std.process.run(gpa, io, .{
        .argv = &.{ "zig", "build", "--build-runner", runner_abs },
        .cwd = .{ .path = tmp_abs },
        .environ_map = &env_map,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.warn("skipping runner e2e test: 'zig' not found on PATH", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    // The key assertion: no panic. A `@panic` in the child process shows up
    // here as a non-`.exited` term (a signal) or stderr carrying the panic
    // trace -- either way, distinguishable from the ordinary "install step
    // succeeded" exit this project should actually produce, since nothing in
    // it is a deliberate compile error.
    const exit_code: ?u8 = switch (result.term) {
        .exited => |code| code,
        else => null,
    };
    if (exit_code != 0) {
        std.debug.print("zig build --build-runner failed (exit {?d}):\n{s}\n", .{
            exit_code, result.stderr,
        });
    }
    try std.testing.expect(
        std.mem.indexOf(u8, result.stderr, "misconfigured build script") == null,
    );
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "panic") == null);
    try std.testing.expectEqual(@as(?u8, 0), exit_code);

    const manifest_bytes = try tmp.dir.readFileAlloc(io, "m.json", gpa, .unlimited);
    defer gpa.free(manifest_bytes);

    var parsed = try manifest.parse(gpa, manifest_bytes);
    defer parsed.deinit();

    var found_gen = false;
    var found_main = false;
    for (parsed.value.roots) |root| {
        if (std.mem.eql(u8, root.path, gen_abs)) found_gen = true;
        if (std.mem.eql(u8, root.path, main_abs)) found_main = true;
    }
    try std.testing.expect(found_gen);
    try std.testing.expect(found_main);
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zippy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run zippy");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit and fixture tests");
    test_step.dependOn(&run_tests.step);

    // Fixture tests live in test/fixture_test.zig and drive the real
    // Source/Config/Linter/Diagnostic pipeline end-to-end against sample
    // files in test/fixtures/. They get those types through a single
    // "zippy" module import (src/root.zig) rather than importing src/ files
    // by relative path, so every type fixture_test.zig sees comes from one
    // module instance and matches what Linter.run itself uses.
    const fixture_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fixture_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fixture_tests.root_module.addImport("zippy", b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_fixture_tests = b.addRunArtifact(fixture_tests);
    test_step.dependOn(&run_fixture_tests.step);
}

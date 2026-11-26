const std = @import("std");
const bsp = @import("bsp.zig");

const File = struct {
    sub_path: []const u8,
    data: []const u8,
};

const exe_build_zig =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const exe = b.addExecutable(.{
    \\        .name = "proj",
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = b.path("src/main.zig"),
    \\            .target = b.standardTargetOptions(.{}),
    \\            .optimize = b.standardOptimizeOption(.{}),
    \\        }),
    \\    });
    \\    b.installArtifact(exe);
    \\}
;

const Project = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,

    fn init(files: []const File) !Project {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        for (files) |file| {
            if (std.fs.path.dirname(file.sub_path)) |dir| try tmp.dir.createDirPath(io, dir);
            try tmp.dir.writeFile(io, .{ .sub_path = file.sub_path, .data = file.data });
        }
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        errdefer arena.deinit();
        const root = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
        return .{ .tmp = tmp, .arena = arena, .root = root };
    }

    fn deinit(p: *Project) void {
        p.arena.deinit();
        p.tmp.cleanup();
    }

    fn path(p: *Project, sub_path: []const u8) ![]const u8 {
        return std.fs.path.join(p.arena.allocator(), &.{ p.root, sub_path });
    }

    fn collect(p: *Project, build_args: []const []const u8) !bsp.Result {
        return bsp.collect(std.testing.io, p.arena.allocator(), .{
            .project_root = p.root,
            .build_args = build_args,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => |e| return e,
        };
    }

    fn collectManifest(p: *Project) !@FieldType(bsp.Result, "manifest") {
        switch (try p.collect(&.{})) {
            .manifest => |m| return m,
            .failed => |message| {
                std.log.err("zig build failed:\n{s}", .{message});
                return error.BuildFailed;
            },
        }
    }
};

fn hasRoot(roots: anytype, path: []const u8) bool {
    for (roots) |root| {
        if (std.mem.eql(u8, root.path, path)) return true;
    }
    return false;
}

test "manifest lists the exe root module as a project root" {
    var p: Project = try .init(&.{
        .{ .sub_path = "build.zig", .data = exe_build_zig },
        .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}\n" },
    });
    defer p.deinit();

    const m = try p.collectManifest();
    try std.testing.expectEqualStrings(p.root, m.project_root);
    try std.testing.expectEqual(@as(usize, 1), m.roots.len);
    try std.testing.expectEqualStrings(try p.path("src/main.zig"), m.roots[0].path);
    try std.testing.expectEqualStrings("root", m.roots[0].module);
    try std.testing.expect(!m.roots[0].is_dependency);
    try std.testing.expectEqual(@as(usize, 0), m.errors.len);
}

test "manifest includes a static library linked into an exe but never installed itself" {
    var p: Project = try .init(&.{
        .{ .sub_path = "build.zig", .data =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const lib = b.addLibrary(.{
        \\        .linkage = .static,
        \\        .name = "lib",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/lib.zig"),
        \\            .target = target,
        \\        }),
        \\    });
        \\    const exe = b.addExecutable(.{
        \\        .name = "proj",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/main.zig"),
        \\            .target = target,
        \\        }),
        \\    });
        \\    exe.root_module.linkLibrary(lib);
        \\    b.installArtifact(exe);
        \\}
        },
        .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}\n" },
        .{ .sub_path = "src/lib.zig", .data = "export fn add(a: i32) i32 { return a; }\n" },
    });
    defer p.deinit();

    const m = try p.collectManifest();
    try std.testing.expect(hasRoot(m.roots, try p.path("src/lib.zig")));
    try std.testing.expect(hasRoot(m.roots, try p.path("src/main.zig")));
}

test "manifest captures both a type error and an unused-local error" {
    var p: Project = try .init(&.{
        .{ .sub_path = "build.zig", .data = exe_build_zig },
        .{ .sub_path = "src/main.zig", .data =
        \\pub fn main() void {
        \\    const x: u8 = true;
        \\    _ = x;
        \\    const y: u8 = 1;
        \\}
        \\
        },
    });
    defer p.deinit();

    const m = try p.collectManifest();
    const main_path = try p.path("src/main.zig");
    var found_type_error = false;
    var found_unused = false;
    for (m.errors) |err| {
        try std.testing.expectEqualStrings(main_path, err.path);
        if (std.mem.find(u8, err.message, "expected type 'u8'") != null) {
            found_type_error = true;
            try std.testing.expectEqual(@as(u32, 2), err.line);
        }
        if (std.mem.find(u8, err.message, "unused local constant") != null) {
            found_unused = true;
            try std.testing.expectEqual(@as(u32, 4), err.line);
        }
    }
    try std.testing.expect(found_type_error);
    try std.testing.expect(found_unused);
}

test "a code generator runs so the module that imports its output compiles" {
    var p: Project = try .init(&.{
        .{ .sub_path = "build.zig", .data =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const gen_exe = b.addExecutable(.{
        \\        .name = "gen",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("gen.zig"),
        \\            .target = b.graph.host,
        \\        }),
        \\    });
        \\    const run_gen = b.addRunArtifact(gen_exe);
        \\    const generated = run_gen.addOutputFileArg("generated.zig");
        \\    const exe = b.addExecutable(.{
        \\        .name = "proj",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/main.zig"),
        \\            .target = target,
        \\        }),
        \\    });
        \\    exe.root_module.addImport("generated", b.createModule(.{
        \\        .root_source_file = generated,
        \\        .target = target,
        \\    }));
        \\    b.installArtifact(exe);
        \\}
        },
        .{ .sub_path = "gen.zig", .data =
        \\const std = @import("std");
        \\pub fn main(init: std.process.Init) !void {
        \\    const args = try init.minimal.args.toSlice(init.arena.allocator());
        \\    try std.Io.Dir.cwd().writeFile(init.io, .{
        \\        .sub_path = args[1],
        \\        .data = "pub const answer: u8 = 42;\n",
        \\    });
        \\}
        \\
        },
        .{ .sub_path = "src/main.zig", .data =
        \\const generated = @import("generated");
        \\pub fn main() void {
        \\    _ = generated.answer;
        \\}
        \\
        },
    });
    defer p.deinit();

    const m = try p.collectManifest();
    try std.testing.expect(hasRoot(m.roots, try p.path("gen.zig")));
    try std.testing.expect(hasRoot(m.roots, try p.path("src/main.zig")));
    try std.testing.expectEqual(@as(usize, 0), m.errors.len);
}

test "a build.zig that does not compile reports failed with the compiler error" {
    var p: Project = try .init(&.{
        .{ .sub_path = "build.zig", .data =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    b.notAFunction();
        \\}
        },
    });
    defer p.deinit();

    switch (try p.collect(&.{})) {
        .manifest => return error.TestExpectedFailure,
        .failed => |message| {
            try std.testing.expect(std.mem.find(u8, message, "notAFunction") != null);
        },
    }
}

test "an unknown -D option reports failed" {
    var p: Project = try .init(&.{
        .{ .sub_path = "build.zig", .data = exe_build_zig },
        .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}\n" },
    });
    defer p.deinit();

    switch (try p.collect(&.{"-Dno-such-option=1"})) {
        .manifest => return error.TestExpectedFailure,
        .failed => |message| {
            try std.testing.expect(std.mem.find(u8, message, "no-such-option") != null);
        },
    }
}

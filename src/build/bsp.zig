//! Client for the build system protocol that `zig build --listen=-` speaks.
//! It configures the project, finds each compile step that a top-level step
//! reaches, builds only those steps, and collects module roots and compiler
//! errors into a `Manifest`.
const std = @import("std");
const manifest = @import("manifest.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Configuration = std.Build.Configuration;
const Client = std.zig.Client;
const Server = std.zig.Server;

pub const Options = struct {
    /// Absolute path to the directory that contains `build.zig`.
    project_root: []const u8,
    /// Forwarded to `zig build`, for example `-Dfoo=bar`.
    build_args: []const []const u8 = &.{},
    environ_map: ?*const std.process.Environ.Map = null,
};

pub const Result = union(enum) {
    manifest: manifest.Manifest,
    /// The build could not be configured or a step failed without a source
    /// location. Holds a message for the user.
    failed: []const u8,
};

/// All memory in the result belongs to `arena`.
pub fn collect(io: Io, arena: Allocator, options: Options) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "zig", "build", "--listen=-" });
    try argv.appendSlice(arena, options.build_args);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .path = options.project_root },
        .environ_map = options.environ_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    // zippy:ignore unsafe_undefined
    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    // zippy:ignore unsafe_undefined
    var multi_reader: Io.File.MultiReader = undefined;
    const pipes: []const Io.File = &.{ child.stdout.?, child.stderr.? };
    multi_reader.init(arena, io, multi_reader_buffer.toStreams(), pipes);
    defer multi_reader.deinit();

    var stdin_buffer: [64]u8 = undefined;
    var stdin_writer = child.stdin.?.writerStreaming(io, &stdin_buffer);

    var session: Session = .{
        .io = io,
        .arena = arena,
        .project_root = options.project_root,
        .multi_reader = &multi_reader,
        .client = .{
            .in = multi_reader.reader(0),
            .out = &stdin_writer.interface,
        },
    };
    const result = try session.run();
    // On failure the maker can still wait for a request. The deferred kill
    // stops it.
    if (result == .failed) return result;

    try session.client.serveBodylessMessage(.exit);
    while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    _ = try child.wait(io);
    return result;
}

const Session = struct {
    io: Io,
    arena: Allocator,
    project_root: []const u8,
    multi_reader: *Io.File.MultiReader,
    client: Client,

    fn run(self: *Session) !Result {
        const handshake = try self.next() orelse
            return self.failure("zig build exited before the handshake");
        if (handshake.tag != .bsp_handshake) return error.UnexpectedMessage;
        var handshake_reader: Io.Reader = .fixed(handshake.body);
        const version = handshake_reader.takeInt(u32, .little) catch
            return error.MalformedMessage;
        if (version != Server.build_system_version) return error.VersionMismatch;

        const configured = try self.next() orelse
            return self.failure("zig build exited before configuration");
        const config_path = switch (configured.tag) {
            .bsp_configuration => configured.body,
            .bsp_configuration_failed => return self.failureFromBundle(configured.body),
            else => return error.UnexpectedMessage,
        };
        const config = try self.loadConfiguration(config_path);

        var graph: Graph = .{ .config = &config, .project_root = self.project_root };
        try graph.walk(self.arena);

        try self.client.serveBuildSteps(graph.compile_steps.keys(), .{ .watch = false });
        var errors: std.ArrayList(manifest.CompileError) = .empty;
        var failed_steps: StepSet = .empty;
        while (true) {
            const message = try self.next() orelse
                return self.failure("zig build exited during the build");
            switch (message.tag) {
                .bsp_build_completed => break,
                .bsp_step_completed => {
                    const completed = try parseStepCompleted(self.arena, &config, message.body);
                    if (completed.status != .failure) continue;
                    try failed_steps.put(self.arena, completed.step_index, {});
                    if (dependencyFailed(&config, completed.step_index, &failed_steps)) continue;

                    const located = try appendLocatedErrors(
                        self.arena,
                        self.project_root,
                        completed.bundle,
                        &errors,
                    );
                    if (located == 0) return self.stepFailure(&config, completed);
                },
                else => {},
            }
        }

        return .{ .manifest = .{
            .project_root = self.project_root,
            .roots = graph.roots.items,
            .errors = try dedupErrors(self.arena, errors.items),
            .dep_dirs = graph.dep_dirs.keys(),
        } };
    }

    const Message = struct {
        tag: Server.Message.Tag,
        body: []const u8,
    };

    /// Returns null when the maker closed its stdout.
    fn next(self: *Session) !?Message {
        const client = &self.client;
        const header = client.receiveMessageWithMultiReader(self.multi_reader, .none) catch |err|
            switch (err) {
                error.EndOfStream => return null,
                error.Timeout => unreachable,
                else => |e| return e,
            };
        // `receiveMessageWithMultiReader` buffers the whole body.
        const in = self.client.in;
        const body = try self.arena.dupe(u8, in.buffered()[0..header.bytes_len]);
        in.toss(header.bytes_len);
        return .{ .tag = header.tag, .body = body };
    }

    fn loadConfiguration(self: *Session, sub_path: []const u8) !Configuration {
        const path = try std.fs.path.resolve(self.arena, &.{ self.project_root, sub_path });
        const file = try Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);
        return Configuration.loadFile(self.arena, self.io, file);
    }

    fn failure(self: *Session, reason: []const u8) !Result {
        const stderr = self.multi_reader.reader(1).buffered();
        return .{ .failed = try std.fmt.allocPrint(self.arena, "{s}\n{s}", .{ reason, stderr }) };
    }

    fn failureFromBundle(self: *Session, body: []const u8) !Result {
        const bundle = Server.allocErrorBundle(self.arena, body) catch |err| switch (err) {
            error.EndOfStream => return error.MalformedMessage,
            error.OutOfMemory => |e| return e,
        };
        var text: Io.Writer.Allocating = .init(self.arena);
        try bundle.renderToWriter(.{}, &text.writer);
        return self.failure(text.written());
    }

    fn stepFailure(self: *Session, config: *const Configuration, completed: StepCompleted) !Result {
        const name = completed.step_index.ptr(config).name.slice(config);
        var text: Io.Writer.Allocating = .init(self.arena);
        try text.writer.print("build step '{s}' failed\n", .{name});
        try completed.bundle.renderToWriter(.{}, &text.writer);
        return self.failure(text.written());
    }
};

const StepSet = std.AutoHashMapUnmanaged(Configuration.Step.Index, void);

const StepCompleted = struct {
    step_index: Configuration.Step.Index,
    status: Server.Message.BuildStepCompleted.Status,
    bundle: std.zig.ErrorBundle,
};

fn parseStepCompleted(
    arena: Allocator,
    config: *const Configuration,
    body: []const u8,
) !StepCompleted {
    var r: Io.Reader = .fixed(body);
    var header: [5]u32 = undefined;
    for (&header) |*word| word.* = r.takeInt(u32, .little) catch return error.MalformedMessage;
    const step_index, const raw_status, const extra_len, const string_bytes_len, _ = header;

    if (step_index >= config.steps.len) return error.MalformedMessage;
    const status = std.enums.fromInt(Server.Message.BuildStepCompleted.Status, raw_status) orelse
        return error.MalformedMessage;
    const bundle = std.zig.ErrorBundle.readAlloc(&r, arena, extra_len, string_bytes_len) catch |err|
        switch (err) {
            error.OutOfMemory => |e| return e,
            else => return error.MalformedMessage,
        };
    return .{
        .step_index = @fromBackingInt(@intCast(step_index)),
        .status = status,
        .bundle = bundle,
    };
}

/// A step whose dependency failed reports `failure` with no errors of its
/// own. Steps complete after their dependencies, so the set is up to date.
fn dependencyFailed(
    config: *const Configuration,
    step_index: Configuration.Step.Index,
    failed_steps: *const StepSet,
) bool {
    for (step_index.ptr(config).deps.slice(config)) |dep| {
        if (failed_steps.contains(dep)) return true;
    }
    return false;
}

/// Returns the number of messages in `bundle` that had a source location.
fn appendLocatedErrors(
    arena: Allocator,
    project_root: []const u8,
    bundle: std.zig.ErrorBundle,
    out: *std.ArrayList(manifest.CompileError),
) !usize {
    if (bundle.errorMessageCount() == 0) return 0;
    var located: usize = 0;
    for (bundle.getMessages()) |message_index| {
        const message = bundle.getErrorMessage(message_index);
        if (message.src_loc == .none) continue;
        const loc = bundle.getSourceLocation(message.src_loc);
        const src_path = bundle.nullTerminatedString(loc.src_path);
        try out.append(arena, .{
            .path = try std.fs.path.resolve(arena, &.{ project_root, src_path }),
            .line = loc.line + 1,
            .col = loc.column + 1,
            .span_start = loc.span_start,
            .span_end = loc.span_end,
            .message = bundle.nullTerminatedString(message.msg),
        });
        located += 1;
    }
    return located;
}

/// Two compile steps that share a module report the same error twice.
fn dedupErrors(
    arena: Allocator,
    records: []const manifest.CompileError,
) ![]const manifest.CompileError {
    var out: std.ArrayList(manifest.CompileError) = .empty;
    outer: for (records) |record| {
        for (out.items) |existing| {
            if (existing.span_start == record.span_start and
                std.mem.eql(u8, existing.path, record.path) and
                std.mem.eql(u8, existing.message, record.message)) continue :outer;
        }
        try out.append(arena, record);
    }
    return out.items;
}

const Graph = struct {
    config: *const Configuration,
    project_root: []const u8,
    compile_steps: std.AutoArrayHashMapUnmanaged(Configuration.Step.Index, void) = .empty,
    roots: std.ArrayList(manifest.Root) = .empty,
    dep_dirs: std.StringArrayHashMapUnmanaged(void) = .empty,

    fn walk(self: *Graph, arena: Allocator) !void {
        const c = self.config;
        var seen: StepSet = .empty;
        var stack: std.ArrayList(Configuration.Step.Index) = .empty;
        for (c.steps, 0..) |step, i| {
            if (step.extended.tag(c) != .top_level) continue;
            if (std.mem.eql(u8, step.name.slice(c), "uninstall")) continue;
            try stack.append(arena, @fromBackingInt(@intCast(i)));
        }

        while (stack.pop()) |step_index| {
            const gop = try seen.getOrPut(arena, step_index);
            if (gop.found_existing) continue;
            const step = step_index.ptr(c);
            try stack.appendSlice(arena, step.deps.slice(c));
            const compile = step.extended.cast(c, Configuration.Step.Compile) orelse continue;
            try self.compile_steps.put(arena, step_index, {});
            try self.addModules(arena, step.name.slice(c), compile.root_module);
        }
    }

    fn addModules(
        self: *Graph,
        arena: Allocator,
        step_name: []const u8,
        root_module: Configuration.Module.Index,
    ) !void {
        const c = self.config;
        var modules: std.AutoArrayHashMapUnmanaged(Configuration.Module.Index, []const u8) = .empty;
        try modules.put(arena, root_module, "root");

        var i: usize = 0;
        while (i < modules.count()) : (i += 1) {
            const module = modules.keys()[i].get(c);
            const imports = module.import_table.get(c).imports.mal;
            for (imports.items(.name), imports.items(.module)) |name, imported| {
                const gop = try modules.getOrPut(arena, imported);
                if (!gop.found_existing) gop.value_ptr.* = name.slice(c);
            }

            const lazy_path = module.root_source_file.unwrap() orelse continue;
            const resolved = try self.resolve(arena, lazy_path.get(c)) orelse continue;
            if (resolved.dep_dir) |dir| try self.dep_dirs.put(arena, dir, {});
            try self.roots.append(arena, .{
                .path = resolved.path,
                .module = modules.values()[i],
                .step = step_name,
                .target = "",
                .is_dependency = resolved.dep_dir != null,
            });
        }
    }

    const Resolved = struct {
        path: []const u8,
        /// Root of the dependency package that owns the path, if any.
        dep_dir: ?[]const u8,
    };

    /// Generated paths and install paths do not exist before the build, so
    /// they resolve to null.
    fn resolve(self: *const Graph, arena: Allocator, lazy_path: Configuration.LazyPath) !?Resolved {
        const c = self.config;
        switch (lazy_path) {
            .source_path => |source| {
                const package = source.owner.get(c) orelse return .{
                    .path = try std.fs.path.resolve(arena, &.{
                        self.project_root,
                        source.sub_path.slice(c),
                    }),
                    .dep_dir = null,
                };
                // The maker runs in `project_root`, and package roots are
                // relative to its working directory.
                const package_root = try std.fs.path.resolve(arena, &.{
                    self.project_root,
                    package.root_path.slice(c),
                });
                return .{
                    .path = try std.fs.path.resolve(arena, &.{
                        package_root,
                        source.sub_path.slice(c),
                    }),
                    .dep_dir = package_root,
                };
            },
            .relative => |relative| {
                if (relative.flags.base != .cwd) return null;
                return .{
                    .path = try std.fs.path.resolve(arena, &.{
                        self.project_root,
                        relative.sub_path.slice(c),
                    }),
                    .dep_dir = null,
                };
            },
            .generated => return null,
        }
    }
};

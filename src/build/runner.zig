//! A stand-in for Zig's own `lib/zig/compiler/build_runner.zig`, installed
//! via `zig build --build-runner <this file>`. Its job is to run the
//! project's `build.zig` `build()` function far enough to populate a
//! `std.Build`, walk the resulting step graph for every `Step.Compile`
//! reachable from a top-level step, and write the real root source file of
//! each of its modules -- *and* actually run that graph (every step except
//! `Step.Run`, so a real compile happens but the user's own program/tests
//! never execute) to capture each `Step.Compile`'s decoded compiler error
//! bundle -- to the path in env var `ZIPPY_MANIFEST`, as JSON matching
//! `build/manifest.zig`'s `Manifest`/`Root`/`CompileError` shape.
//!
//! This file is embedded into the `zippy` binary (via `@embedFile`, see the
//! CLI's build-mode entry point) and written out to a temp file at runtime,
//! so it cannot `@import` any other Zippy module -- it only ever sees
//! `std`, `@build` (the project's build.zig, injected by the `zig` compiler
//! frontend the same way it injects it for the default runner) and
//! `@dependencies`. The `Root`/`Manifest`/`CompileError` shapes below are
//! therefore a deliberate duplicate of `build/manifest.zig`'s, not a shared
//! import -- and the `std.zig.ErrorBundle` decode is inline here for the
//! same reason: it can't call into a Zippy module that would normally own
//! that logic.
//!
//! Uses `main(init: std.process.Init)` -- the same entry point `src/main.zig`
//! uses -- rather than the real build runner's `Init.Minimal`: that lets the
//! 0.16 runtime hand over an already-built `gpa`/`io`/arena/`environ_map`
//! (with leak checking wired up in Debug builds) instead of this file
//! constructing its own `DebugAllocator` and `Io.Threaded` by hand for no
//! benefit, since this runner never needs the manual thread-limit control
//! (`-j`) the real one sets up its own `Io.Threaded` to support.
//!
//! Deliberately dropped, relative to the real build runner: `--watch`,
//! `--webui`, `--fuzz`, the summary tree printer, `-h`/`--list-steps`, RSS
//! tracking/limiting, and nearly every command-line flag (kept only `-D`,
//! since a `build.zig` may branch on `b.option(...)` results regardless of
//! whether any step runs). Step execution itself (see `runSteps`) is a
//! deliberately minimal driver rather than a port of the real scheduler --
//! verified against `lib/zig/std/Build/Step.zig` and every `Step.*`
//! implementation that `step.make()` and every `makeFn` only ever consult a
//! dependency's *output* (files it produced), never its `.state` -- so
//! running every reachable step once, in dependency order, needs none of the
//! real scheduler's `@atomicStore`d state machine, `dependants` bookkeeping,
//! or concurrency (`Io.Group`/RSS budget) machinery.
const std = @import("std");
const builtin = @import("builtin");
const process = std.process;
const Io = std.Io;
const Step = std.Build.Step;
const Allocator = std.mem.Allocator;
const fatal = std.process.fatal;

pub const root = @import("@build");
pub const dependencies = @import("@dependencies");

/// Mirrors `build/manifest.zig`'s `Root` -- see the file doc comment for
/// why this can't just `@import` that file instead.
const ManifestRoot = struct {
    path: []const u8,
    module: []const u8,
    step: []const u8,
    target: []const u8,
    /// See `manifest.zig`'s `Root.is_dependency` doc comment: set by
    /// `dependencyDir` from the OWNING BUILD of this root's `root_source_file`,
    /// never from the resolved path -- a dependency can live anywhere on
    /// disk, including under the project's own tree.
    is_dependency: bool = false,
};

/// One decoded entry from a `Step.Compile`'s `result_error_bundle` after
/// `runSteps` actually ran it. Mirrors `build/manifest.zig`'s `CompileError`
/// field-for-field -- see the file doc comment for why this can't just
/// `@import` that file instead.
const ManifestError = struct {
    path: []const u8,
    line: u32,
    col: u32,
    span_start: u32,
    span_end: u32,
    message: []const u8,
};

/// Mirrors `build/manifest.zig`'s `Manifest`.
const Manifest = struct {
    project_root: []const u8,
    roots: []const ManifestRoot,
    errors: []const ManifestError,
    /// See `manifest.zig`'s `Manifest.dep_dirs` doc comment: the distinct
    /// dependency build-root directories collected while walking the graph
    /// (`WalkCtx.dep_dirs`), for `dead_file.find` to skip.
    dep_dirs: []const []const u8,
};

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    // Skip our own exe name; `zig build --build-runner` always invokes this
    // program with these five positional arguments first, in this order.
    var arg_idx: usize = 1;
    const zig_exe = nextArg(args, &arg_idx) orelse fatal("missing zig compiler path", .{});
    const zig_lib_dir = nextArg(args, &arg_idx) orelse
        fatal("missing zig lib directory path", .{});
    const build_root = nextArg(args, &arg_idx) orelse
        fatal("missing build root directory path", .{});
    const cache_root = nextArg(args, &arg_idx) orelse
        fatal("missing cache root directory path", .{});
    const global_cache_root = nextArg(args, &arg_idx) orelse
        fatal("missing global cache root directory path", .{});

    const cwd: Io.Dir = .cwd();

    const zig_lib_directory: std.Build.Cache.Directory = .{
        .path = zig_lib_dir,
        .handle = try cwd.openDir(io, zig_lib_dir, .{}),
    };
    const build_root_directory: std.Build.Cache.Directory = .{
        .path = build_root,
        .handle = try cwd.openDir(io, build_root, .{}),
    };
    const local_cache_directory: std.Build.Cache.Directory = .{
        .path = cache_root,
        .handle = try cwd.createDirPathOpen(io, cache_root, .{}),
    };
    const global_cache_directory: std.Build.Cache.Directory = .{
        .path = global_cache_root,
        .handle = try cwd.createDirPathOpen(io, global_cache_root, .{}),
    };

    var graph: std.Build.Graph = .{
        .io = io,
        .arena = arena,
        .cache = .{
            .io = io,
            .gpa = gpa,
            .manifest_dir = try local_cache_directory.handle.createDirPathOpen(io, "h", .{}),
            .cwd = try process.currentPathAlloc(io, arena),
        },
        .zig_exe = zig_exe,
        // Shares the runtime-owned map's backing storage rather than
        // building a second copy; never `deinit`'d here, since this runner
        // doesn't own it -- the process exiting reclaims it either way.
        .environ_map = init.environ_map.*,
        .global_cache_root = global_cache_directory,
        .zig_lib_directory = zig_lib_directory,
        .host = .{
            .query = .{},
            .result = try std.zig.system.resolveTargetQuery(io, .{}),
        },
        .time_report = false,
    };
    graph.cache.addPrefix(.{ .path = null, .handle = cwd });
    graph.cache.addPrefix(build_root_directory);
    graph.cache.addPrefix(local_cache_directory);
    graph.cache.addPrefix(global_cache_directory);
    graph.cache.hash.addBytes(builtin.zig_version_string);

    const builder = try std.Build.create(
        &graph,
        build_root_directory,
        local_cache_directory,
        dependencies.root_deps,
    );

    // The only flag this runner honors is `-D<name>[=<value>]`; everything
    // else `zig build` might pass (`-j`, `--release`, `--verbose`,
    // target-step names, ...) is irrelevant to walking the graph, so it's
    // parsed just far enough to skip over it -- never `fatal`, since a
    // future `zig` may pass flags this stripped-down runner has never heard
    // of and has no need to.
    while (nextArg(args, &arg_idx)) |arg| {
        if (!std.mem.startsWith(u8, arg, "-D")) continue;
        const option_contents = arg["-D".len..];
        if (std.mem.indexOfScalar(u8, option_contents, '=')) |eql_idx| {
            const failed = try builder.addUserInputOption(
                option_contents[0..eql_idx],
                option_contents[eql_idx + 1 ..],
            );
            if (failed) fatal("invalid option: '{s}'", .{arg});
        } else if (option_contents.len > 0) {
            if (try builder.addUserInputFlag(option_contents))
                fatal("invalid option: '{s}'", .{arg});
        }
    }

    builder.resolveInstallPrefix(null, .{});
    try builder.runBuild(root);
    // Vendored from the real build runner (see `createModuleDependencies`'s
    // own doc comment below) -- called in the same place it is there,
    // immediately after `runBuild`, and before anything walks the step
    // graph or calls `make()` on any step.
    try createModuleDependencies(builder);
    if (builder.validateUserInputDidItFail()) fatal("invalid -D option", .{});

    const manifest_path = graph.environ_map.get("ZIPPY_MANIFEST") orelse
        fatal("ZIPPY_MANIFEST not set", .{});

    const manifest = try collectManifest(arena, gpa, io, builder);
    const json = try std.json.Stringify.valueAlloc(arena, manifest, .{});
    try cwd.writeFile(io, .{ .sub_path = manifest_path, .data = json });
}

/// Orchestrates the whole manifest: `walkGraph` finds every reachable step
/// (Tier 1's "what does this project compile" answer) and puts it in
/// dependency order, then `runSteps` actually runs that graph and captures
/// each `Step.Compile`'s real compiler errors (Tier 2).
fn collectManifest(arena: Allocator, gpa: Allocator, io: Io, b: *std.Build) !Manifest {
    const walk = try walkGraph(arena, b);
    const errors = try runSteps(arena, gpa, io, walk.order);
    return .{
        .project_root = b.build_root.path orelse ".",
        .roots = walk.roots,
        .errors = errors,
        .dep_dirs = walk.dep_dirs,
    };
}

/// Vendored verbatim from `lib/zig/compiler/build_runner.zig` (same name,
/// same body): starting from every top-level step, adds every
/// `step.dependencies` edge implied by its module graph but never expressed
/// as an explicit `b.step(...).dependOn(...)` call -- e.g. linking a
/// `Step.Compile` into a module via `Module.linkLibrary` only ever records
/// that on the module (`link_objects`/`include_dirs`), never on the step
/// itself. Two things below depend on having run this first: `visitStep`'s
/// walk of plain `step.dependencies.items` would otherwise miss such a
/// linked-but-never-installed library entirely (so it would neither land in
/// the manifest nor get compiled before the step that links it), and some of
/// these edges have side effects beyond bookkeeping -- `other.
/// getEmittedIncludeTree()` below lazily creates a `Step.WriteFile` and
/// caches it on `other`; skip calling it and that library's compile step
/// later reads a null `installed_headers_include_tree` while building its
/// dependents' `-I` flags and panics on the forced unwrap.
fn createModuleDependencies(b: *std.Build) Allocator.Error!void {
    const arena = b.graph.arena;

    var all_steps: std.AutoArrayHashMapUnmanaged(*Step, void) = .empty;
    var next_step_idx: usize = 0;

    try all_steps.ensureUnusedCapacity(arena, b.top_level_steps.count());
    for (b.top_level_steps.values()) |tls| {
        all_steps.putAssumeCapacityNoClobber(&tls.step, {});
    }

    while (next_step_idx < all_steps.count()) {
        const step = all_steps.keys()[next_step_idx];
        next_step_idx += 1;

        // Set up any implied dependencies for this step. It's important that we do this first, so
        // that the loop below discovers steps implied by the module graph.
        try createModuleDependenciesForStep(step);

        try all_steps.ensureUnusedCapacity(arena, step.dependencies.items.len);
        for (step.dependencies.items) |other_step| {
            all_steps.putAssumeCapacity(other_step, {});
        }
    }
}

/// Vendored verbatim from `lib/zig/compiler/build_runner.zig`, alongside
/// `createModuleDependencies` above -- see its doc comment.
fn createModuleDependenciesForStep(step: *Step) Allocator.Error!void {
    const root_module = if (step.cast(Step.Compile)) |cs| root: {
        break :root cs.root_module;
    } else return; // not a compile step so no module dependencies

    // Starting from `root_module`, discover all modules in this graph.
    const modules = root_module.getGraph().modules;

    // For each of those modules, set up the implied step dependencies.
    for (modules) |mod| {
        if (mod.root_source_file) |lp| lp.addStepDependencies(step);
        for (mod.include_dirs.items) |include_dir| switch (include_dir) {
            .path,
            .path_system,
            .path_after,
            .framework_path,
            .framework_path_system,
            .embed_path,
            => |lp| lp.addStepDependencies(step),

            .other_step => |other| {
                other.getEmittedIncludeTree().addStepDependencies(step);
                step.dependOn(&other.step);
            },

            .config_header_step => |other| step.dependOn(&other.step),
        };
        for (mod.lib_paths.items) |lp| lp.addStepDependencies(step);
        for (mod.rpaths.items) |rpath| switch (rpath) {
            .lazy_path => |lp| lp.addStepDependencies(step),
            .special => {},
        };
        for (mod.link_objects.items) |link_object| switch (link_object) {
            .static_path,
            .assembly_file,
            => |lp| lp.addStepDependencies(step),
            .other_step => |other| step.dependOn(&other.step),
            .system_lib => {},
            .c_source_file => |source| source.file.addStepDependencies(step),
            .c_source_files => |source_files| source_files.root.addStepDependencies(step),
            .win32_resource_file => |rc_source| {
                rc_source.file.addStepDependencies(step);
                for (rc_source.include_paths) |lp| lp.addStepDependencies(step);
            },
        };
    }
}

const Walk = struct {
    roots: []const ManifestRoot,
    /// Every reachable step, in dependency order: a step's dependencies --
    /// including ones implied by linking a `Step.Compile` into a module,
    /// which never show up in `step.dependencies` itself, only in
    /// `link_objects` (see the comment in `visitStep`) -- always precede it.
    /// `runSteps` relies on this: a `Step.Compile` that links a static
    /// library needs that library's archive to already exist on disk by the
    /// time its own `make()` invokes the linker.
    order: []const *Step,
    /// The distinct dependency build-root directories discovered across every
    /// root (see `dependencyDir`), for `Manifest.dep_dirs`.
    dep_dirs: []const []const u8,
};

/// A step currently on the DFS stack (`.visiting`, so seeing it again means
/// a dependency cycle -- `build.zig` bugs can create these) versus one
/// that's already fully processed and in `order` (`.done`).
const VisitState = enum { visiting, done };

/// The mutable state threaded through `visitStep`'s recursion, bundled into
/// one struct rather than three-plus separate pointer parameters -- this
/// codebase caps functions at five params (its own `too_many_params` lint,
/// which self-lints this very file).
const WalkCtx = struct {
    b: *std.Build,
    seen: std.AutoHashMapUnmanaged(*Step, VisitState) = .empty,
    order: std.ArrayList(*Step) = .empty,
    roots: std.ArrayList(ManifestRoot) = .empty,
    /// Set (keys only) of every distinct dependency build-root directory seen
    /// so far -- an `ArrayHashMap` (not a plain `HashMap`) so `.keys()` hands
    /// `walkGraph` a stable slice straight into the manifest's `dep_dirs`
    /// without a separate collect-to-slice pass.
    dep_dirs: std.StringArrayHashMapUnmanaged(void) = .empty,
};

/// Walks every step reachable from `b`'s top-level steps (the same set the
/// real build runner would consider running for a bare `zig build`), and for
/// each `Step.Compile` found along the way, records the real root source
/// file of every module in its module graph. This is the actual "what does
/// this project compile" answer -- the whole reason this runner exists
/// instead of Zippy just parsing `build.zig` itself. Also produces the
/// dependency-ordered step list `runSteps` executes.
fn walkGraph(arena: Allocator, b: *std.Build) !Walk {
    var ctx: WalkCtx = .{ .b = b };
    for (b.top_level_steps.values()) |tls| {
        // Every `std.Build` gets a built-in "uninstall" top-level step
        // (`Build.create`), and its `makeFn` (`makeUninstall`) is an
        // unimplemented stub in this Zig version that unconditionally
        // `@panic`s (see ziglang/zig#14943) -- so it must never actually run
        // here (Tier 1 only walked it for roots, never `make()`d it). Safe
        // to skip outright, not just for running it: it has no dependencies
        // of its own, so it would never have contributed a root anyway.
        if (&tls.step == b.getUninstallStep()) continue;
        try visitStep(arena, &ctx, &tls.step);
    }
    return .{ .roots = ctx.roots.items, .order = ctx.order.items, .dep_dirs = ctx.dep_dirs.keys() };
}

/// Post-order DFS over `step.dependencies` (already completed by
/// `createModuleDependencies`, called once in `main` before any walk starts,
/// to include every edge a module graph implies -- e.g. a `Step.Compile`
/// linked into a module via `Module.linkLibrary` -- alongside the explicit
/// ones a `build.zig` adds itself via `step.dependOn`): every dependency is
/// fully visited -- and so already appended to `ctx.order` -- before `step`
/// itself is appended, giving `ctx.order` a valid dependency-first execution
/// order.
fn visitStep(arena: Allocator, ctx: *WalkCtx, step: *Step) !void {
    if (ctx.seen.get(step)) |state| {
        if (state == .visiting) fatal(
            "zippy runner: dependency cycle at build step '{s}'",
            .{step.name},
        );
        return;
    }
    // A fresh `put` (not held across the recursive calls below) rather than
    // reusing a `getOrPut` pointer: those recursive calls insert further
    // entries into `ctx.seen`, and any resize invalidates pointers into it.
    try ctx.seen.put(arena, step, .visiting);

    for (step.dependencies.items) |dep| try visitStep(arena, ctx, dep);

    if (step.cast(Step.Compile)) |compile| {
        const module_graph = compile.root_module.getGraph();
        for (module_graph.modules, module_graph.names) |mod, name| {
            const root_source_file = mod.root_source_file orelse continue;
            const abs = (try lazyPathToAbs(arena, ctx.b, root_source_file)) orelse continue;
            const dep_dir = dependencyDir(ctx.b, root_source_file);
            if (dep_dir) |dir| {
                const gop = try ctx.dep_dirs.getOrPut(arena, dir);
                gop.value_ptr.* = {};
            }
            try ctx.roots.append(arena, .{
                .path = abs,
                .module = name,
                .step = step.name,
                // Left blank deliberately: resolving a triple string needs
                // formatting the module's `resolved_target`, which nothing
                // downstream of this manifest (the reachability walk, the
                // dead-file pass) actually consults yet.
                .target = "",
                .is_dependency = dep_dir != null,
            });
        }
    }

    try ctx.seen.put(arena, step, .done);
    try ctx.order.append(arena, step);
}

/// Whether a step actually ran and succeeded (`.success`), was deliberately
/// never run (`.skipped` -- always a `Step.Run`; `make()` itself reporting
/// `error.MakeSkipped` is folded into `.success` below, since that means the
/// step's outputs already exist from earlier work, not that they're
/// missing), failed outright (`.failed`), or was never attempted because a
/// dependency already failed *or was itself a skipped `Step.Run`*
/// (`.dependency_failure` -- see `dependencyFailed`). Tracked locally in
/// `runSteps` rather than written into `step.state` (what the real scheduler
/// does): nothing outside that scheduler ever reads `.state` (verified
/// against `lib/zig/std/Build/Step.zig` and every `Step/*.zig` -- see
/// `runSteps`' doc comment), so a plain local map is simpler than reaching
/// into a field this runner doesn't otherwise touch.
const RunState = enum { success, skipped, failed, dependency_failure };

/// Runs every step in `order` (already dependency-sorted by `walkGraph`),
/// skipping `Step.Run` entirely: this runner's whole job is to find out
/// whether the project *compiles*, never to execute the project's own
/// binaries or tests, which is exactly what a `Step.Run` does. For every
/// `Step.Compile` that ran, decodes its `result_error_bundle` into the
/// manifest's `errors[]` shape (see `collectErrors`) and dedups the result,
/// then frees that bundle (and `result_failed_command`, if set) with `gpa`
/// -- `make()` allocates both and nothing else in this runner ever frees
/// them, so leaving this out leaks on every run; `collectErrors` has already
/// copied every byte of them this runner still needs into `arena` by the
/// time they're freed here, so this can never dangle anything the manifest
/// goes on to read (see `collectErrors`' doc comment).
///
/// A step whose dependency already failed, or whose dependency is a skipped
/// `Step.Run`, is never `make()`'d at all -- mirroring the real scheduler's
/// own dependency check (`makeStep` in `compiler/build_runner.zig`, which
/// marks such a step `.dependency_failure` without calling `make()`). This
/// isn't optional bookkeeping: `make()` itself never inspects a dependency's
/// outcome, but some `makeFn`s inspect a dependency's *output* -- e.g.
/// `Step.InstallArtifact.make` reads the failed compile's `GeneratedFile` for
/// the binary to install, which was never populated, and `@panic`s
/// ("misconfigured build script") rather than erroring. Confirmed by
/// reproducing it: an install step downstream of a deliberately-broken
/// compile crashes the whole runner without this check. The skipped-`Run`
/// case is the same failure mode with a different trigger -- see
/// `dependencyFailed`'s doc comment.
fn runSteps(arena: Allocator, gpa: Allocator, io: Io, order: []const *Step) ![]const ManifestError {
    var root_prog = std.Progress.start(io, .{});
    defer root_prog.end();

    var state: std.AutoHashMapUnmanaged(*Step, RunState) = .empty;
    var errors: std.ArrayList(ManifestError) = .empty;
    for (order) |step| {
        if (dependencyFailed(&state, step)) {
            // Distinct from the `.run` skip below: this must propagate to
            // this step's own dependants too, so `.dependency_failure`
            // rather than `.skipped` -- see `dependencyFailed`.
            try state.put(arena, step, .dependency_failure);
            continue;
        }
        if (step.id == .run) { // never execute the user's program/tests
            try state.put(arena, step, .skipped);
            continue;
        }

        const node = root_prog.start(step.name, 0);
        defer node.end();
        const failed = if (step.make(.{
            .progress_node = node,
            .watch = false,
            .web_server = null,
            .unit_test_timeout_ns = null,
            .gpa = gpa,
        })) false else |err| switch (err) {
            error.MakeFailed => true,
            error.MakeSkipped => false,
        };
        try state.put(arena, step, if (failed) .failed else .success);

        const compile = step.cast(Step.Compile) orelse continue;
        try collectErrors(arena, compile, failed, &errors);

        // See `runSteps`' doc comment: everything `collectErrors` needed
        // from this bundle/command is already copied into `arena` by now, so
        // freeing them here is safe and stops them leaking on every run.
        compile.step.result_error_bundle.deinit(gpa);
        compile.step.result_error_bundle = .empty;
        if (compile.step.result_failed_command) |cmd| gpa.free(cmd);
        compile.step.result_failed_command = null;
    }
    return dedupErrors(arena, errors.items);
}

/// True if any of `step`'s dependencies already failed, was itself blocked by
/// one, or was a `Step.Run` this runner deliberately skipped -- per the
/// recorded `state` -- so `step` must not be `make()`'d either. `order`'s
/// dependency-first guarantee (see `Walk.order`) means every dependency
/// already has an entry in `state` by the time its dependent is reached; a
/// missing entry can only mean "not a dependency this runner tracked" and is
/// treated as fine to proceed, same as the real scheduler treats
/// `.success`.
///
/// The skipped-`Run` case matters for a codegen project: `b.addRunArtifact
/// (gen)` whose output feeds a module (e.g. via `run.addOutputFileArg` used
/// as a module's `root_source_file`, or as a C header/source) makes that Run
/// step a real dependency of the `Step.Compile` that consumes it -- discovered
/// by `createModuleDependencies`, same as any other module-graph edge. That
/// generated `LazyPath`'s underlying `GeneratedFile.path` is only populated
/// once the `Run` step actually executes; skip it (as `runSteps` always
/// does, to honor "never execute the user's own code") and it stays null.
/// Without this check, the dependent compile step would still get
/// `make()`'d, and resolving that still-null generated path (`LazyPath
/// .getPath3`, called while building the compiler invocation) hits std's own
/// `@panic("misconfigured build script")` (`Build.zig`, near line 2295) --
/// aborting this whole runner before the manifest is ever written. That
/// would be a regression from before this runner ran `make()` at all: a
/// bare graph walk never needed a generated file to exist on disk. Treating
/// a skipped `Run` exactly like a failed dependency here means this step
/// (and, transitively, everything downstream of it, since it in turn ends
/// up `.dependency_failure`) is marked blocked and never reaches
/// `step.make()`, so the panic can never trigger -- at the cost of not
/// reporting compiler errors for a step downstream of a generated source,
/// an acceptable narrowing given this runner's "compile-only, never execute
/// user code" contract.
fn dependencyFailed(state: *const std.AutoHashMapUnmanaged(*Step, RunState), step: *Step) bool {
    for (step.dependencies.items) |dep| {
        switch (state.get(dep) orelse .success) {
            .failed, .dependency_failure, .skipped => return true,
            .success => {},
        }
    }
    return false;
}

/// Decodes `compile.result_error_bundle` (a `std.zig.ErrorBundle`, populated
/// by `make()` win or lose) into `out`, dropping notes (`ErrorMessage
/// .notes_len`) and any message with no source location for this skeleton.
///
/// `sl.line`/`sl.column` are 0-based in the bundle (the std renderer only
/// adds +1 when it prints them); emitted as `+ 1` here so the manifest's
/// `line`/`col` match what a human -- or Zippy reading this JSON -- expects.
///
/// `em.msg` and `sl.src_path` are decoded via `eb.nullTerminatedString`,
/// which returns a slice *into* `eb.string_bytes` -- not a copy. `runSteps`
/// frees this bundle with `gpa` right after this function returns (see its
/// doc comment), so every byte this runner still needs out of it must be
/// copied into `arena` *before* that happens, or the manifest would later
/// serialize a dangling slice (a use-after-free, not just a leak). Hence the
/// `arena.dupe` below for both the message and the path -- and critically,
/// the path is duped *before* being handed to `absFromSrcPath`, whose
/// already-absolute branch (see its doc comment) would otherwise return the
/// eb-owned slice verbatim instead of an arena-owned copy.
///
/// A `make()` that reported `MakeFailed` with a genuinely *empty* bundle
/// means the compiler couldn't even be invoked -- an infra fault (a missing
/// dependency artifact, an I/O error), not a user compile error -- so that's
/// the one case worth failing loud over. A populated bundle is the normal
/// "the user's code doesn't compile" case this whole task exists to capture,
/// never a runner failure. When that infra fault happens, `result_error_msgs`
/// (populated by `Step.evalZigProcess` and friends, separate from the
/// bundle) usually holds the actual reason (e.g. a spawn failure) -- surfaced
/// here so the `fatal` isn't just "something broke, good luck".
fn collectErrors(
    arena: Allocator,
    compile: *Step.Compile,
    make_failed: bool,
    out: *std.ArrayList(ManifestError),
) !void {
    const eb = compile.step.result_error_bundle;
    if (eb.errorMessageCount() == 0) {
        if (make_failed) {
            const reason = if (compile.step.result_error_msgs.items.len > 0)
                compile.step.result_error_msgs.items[0]
            else
                "(no reason captured)";
            fatal(
                "zippy runner: build step '{s}' failed with no error bundle: {s}",
                .{ compile.step.name, reason },
            );
        }
        return;
    }
    for (eb.getMessages()) |msg_index| {
        const em = eb.getErrorMessage(msg_index);
        if (em.src_loc == .none) continue;
        const sl = eb.getSourceLocation(em.src_loc);
        const src_path = try arena.dupe(u8, eb.nullTerminatedString(sl.src_path));
        try out.append(arena, .{
            .path = try absFromSrcPath(arena, compile.step.owner, src_path),
            .line = sl.line + 1,
            .col = sl.column + 1,
            .span_start = sl.span_start,
            .span_end = sl.span_end,
            .message = try arena.dupe(u8, eb.nullTerminatedString(em.msg)),
        });
    }
}

/// Resolves an `ErrorBundle` `SourceLocation.src_path` to an absolute path.
/// The compiler reports it relative to whatever directory that particular
/// compilation considers its root -- usually the build root, but
/// `cwd_relative`-style inputs (see `lazyPathToAbs`) resolve against the
/// runner's own cwd (`graph.cache.cwd`) instead. Preferring whichever
/// candidate actually exists on disk, rather than always assuming
/// build-root-relative, means a path from a dependency's own build script
/// still resolves correctly; if neither exists, the build-root-relative
/// guess is kept rather than erroring, since a stale or synthetic path
/// shouldn't sink the whole manifest.
///
/// Callers must pass an already `arena`-owned `src_path`: the
/// already-absolute branch below returns it verbatim rather than copying it,
/// so a caller passing a bundle-owned slice here (see `collectErrors`) would
/// leak that borrow straight into the manifest.
fn absFromSrcPath(arena: Allocator, b: *std.Build, src_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(src_path)) return src_path;

    const io = b.graph.io;
    const via_build_root = try std.fs.path.resolve(arena, &.{
        b.build_root.path orelse ".",
        src_path,
    });
    if (fileExists(io, via_build_root)) return via_build_root;

    const via_cwd = try std.fs.path.resolve(arena, &.{ b.graph.cache.cwd, src_path });
    if (fileExists(io, via_cwd)) return via_cwd;

    return via_build_root;
}

/// True if `absolute_path` names something accessible on disk right now.
/// Only ever used to pick the more plausible of two resolution candidates in
/// `absFromSrcPath` above, never as a check-then-open (which would be a
/// genuine TOCTOU race) -- nothing here goes on to open the file itself.
fn fileExists(io: Io, absolute_path: []const u8) bool {
    Io.Dir.accessAbsolute(io, absolute_path, .{}) catch return false;
    return true;
}

/// Dedups by `(path, span_start, message)`: the compiler can emit the same
/// diagnostic more than once for one underlying error (e.g. redundant
/// references to the same unused local), and `line`/`col`/`span_end` are
/// derived from the same location so they can't differ for a genuine
/// duplicate. Linear-scan rather than a hash set: a single compile's error
/// count is small enough (tens, not thousands) that O(n^2) here is simpler
/// and just as fast as building a keyed hash map for this.
fn dedupErrors(arena: Allocator, records: []const ManifestError) ![]const ManifestError {
    var out: std.ArrayList(ManifestError) = .empty;
    outer: for (records) |rec| {
        for (out.items) |existing| {
            if (existing.span_start == rec.span_start and
                std.mem.eql(u8, existing.path, rec.path) and
                std.mem.eql(u8, existing.message, rec.message)) continue :outer;
        }
        try out.append(arena, rec);
    }
    return out.items;
}

/// If `lazy_path`'s owning `Build` is a DEPENDENCY's build -- not `b`, the
/// project's own -- returns that dependency's build root (absolute); `null`
/// otherwise (including for variants with no owning `Build` at all, see
/// below).
///
/// Zippy must NEVER lint dependency code (see this project's fix notes), and
/// the only thing that reliably tells a dependency apart from project code is
/// the BUILD GRAPH: `b.dependency("foo")` hands back a separate `*std.Build`
/// with its own `build_root`, entirely independent of where that
/// dependency's files happen to sit on disk -- Zig's package fetcher can
/// place a dependency under `~/.cache/zig/p/<hash>`, or, if a project sets a
/// custom package dir (`build.zig.zon`'s `.paths`, or a vendored checkout), UNDER
/// the project's own tree (e.g. `zig-pkg/uefi-<hash>/`). A path-prefix check
/// (`isUnderRoot` in `build/mode.zig`) only catches the former case; this
/// owner-based check catches both.
///
/// Compared by `build_root.path` STRING, not `owner == b` pointer identity:
/// both are valid (per `std.Build.create`, every dependency genuinely gets
/// its own `*Build` instance, so pointer identity would work too), but the
/// path comparison is the more robust invariant -- it holds even if some
/// future `zig` version ever reused a `*Build` instance across calls.
///
/// `.src_path` is the only `LazyPath` variant with an owning `Build` at all
/// (`.owner`, set by `Build.path`/`b.path`); `.cwd_relative`/`.generated`/
/// `.dependency` all resolve without ever consulting an owning build (see
/// `lazyPathToAbs`'s doc comment on each), so none of them can name a fetched
/// dependency's source -- always `null` here, i.e. "not a dependency".
fn dependencyDir(b: *std.Build, lazy_path: std.Build.LazyPath) ?[]const u8 {
    return switch (lazy_path) {
        .src_path => |sp| {
            const owner_root = sp.owner.build_root.path orelse return null;
            const project_root = b.build_root.path orelse return null;
            if (std.mem.eql(u8, owner_root, project_root)) return null;
            return owner_root;
        },
        .cwd_relative, .generated, .dependency => null,
    };
}

/// Resolves a module's `root_source_file` to an absolute on-disk path, or
/// `null` if it doesn't name a static source file at all.
///
/// `.src_path` (the ordinary case: `b.path("src/foo.zig")`) is relative to
/// its owning `Build`'s build root -- which, for an imported dependency's
/// module, is that dependency's own root, not necessarily this project's.
/// `.cwd_relative` (e.g. paths built from `--search-prefix`) is relative to
/// the build runner's own working directory, tracked in `graph.cache.cwd`.
/// `.generated` (a build-step output) and `.dependency` (a dependency's
/// build-script-relative path, already covered by `.src_path` when that
/// dependency's own modules are walked) name build output or a package
/// fetch, not a file this project's author wrote -- skipped, matching
/// `build/reachable.zig`'s stance that only real source is lintable.
fn lazyPathToAbs(
    arena: Allocator,
    b: *std.Build,
    lazy_path: std.Build.LazyPath,
) !?[]const u8 {
    return switch (lazy_path) {
        .src_path => |sp| try std.fs.path.resolve(arena, &.{
            sp.owner.build_root.path orelse
                fatal("build root path is null", .{}),
            sp.sub_path,
        }),
        .cwd_relative => |p| if (std.fs.path.isAbsolute(p))
            p
        else
            try std.fs.path.resolve(arena, &.{ b.graph.cache.cwd, p }),
        .generated, .dependency => null,
    };
}

fn nextArg(args: []const [:0]const u8, idx: *usize) ?[:0]const u8 {
    if (idx.* >= args.len) return null;
    defer idx.* += 1;
    return args[idx.*];
}

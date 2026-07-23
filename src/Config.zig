//! Typed representation of a `zippy.zon` config file.
//!
//! Parsed via `std.zon.parse` with `ignore_unknown_fields = false` (the
//! default) so a typo'd key in a user's `zippy.zon` fails loud at load time
//! instead of being silently ignored.
const std = @import("std");
const Severity = @import("Diagnostic.zig").Severity;
const Config = @This();

pub const Group = enum { style, complexity, correctness, unused, memory };

/// A nullable severity per lint override.
const LintCfg = struct {
    severity: ?Severity = null,
};
const LineWidthCfg = struct {
    severity: ?Severity = null,
    max: u32 = 100,
};
const TooManyParamsCfg = struct {
    severity: ?Severity = null,
    max: u32 = 5,
};
const InlineContainerCfg = struct {
    severity: ?Severity = null,
    max_fields: u32 = 3,
};
const ParamOrderingCfg = struct {
    severity: ?Severity = null,
    /// Target position of an `io`/`std.Io` param. `>= 0` anchors to the front
    /// (after `self`), `< 0` to the back (`-1` last). Default 0 = first after self.
    io: isize = 0,
    /// Target position of an allocator param. Default 1 = right after `io`.
    allocator: isize = 1,
};
const NoPrintCfg = struct {
    severity: ?Severity = null,
    /// Skip a `std.debug.print`/aliased/bare `print(...)` call reached from
    /// inside a `test` block, or in a file whose path ends `test.zig`. Debug
    /// prints in test code are common and harmless (tests never ship), so
    /// this default keeps the lint focused on non-test code. Default on.
    allow_tests: bool = true,
};
/// NOTE the DEFAULT is `.warn`, not `null` -- unlike every other per-lint cfg
/// struct in `Lints`, which default their `severity` to `null` (fall through
/// to the group). A leaked allocation is a RESOURCE bug, not a memory-safety
/// one (unlike `return_stack_local`/`hidden_allocator`, its `memory`-group
/// siblings), and the underlying heuristic (see `alloc_track.zig`) is newer
/// and less battle-tested than theirs, so it defaults softer than the
/// group's `.@"error"`. QUIRK this creates: because a non-null per-lint
/// severity always wins over the group (see `severityFor`'s doc), setting
/// `.groups.memory = .off` (or any other severity) does NOT retune
/// `leaked_allocation` -- a user has to override `.lints.leaked_allocation
/// .severity` directly to change it.
const LeakedAllocationCfg = struct {
    severity: ?Severity = .warn,
};
const SuppressedErrorsCfg = struct {
    severity: ?Severity = null,
    /// Skip a swallowed `catch` inside a `test` decl. Default off (flag it).
    exempt_tests: bool = false,
    /// Skip `w.print()/write*() catch {}` (writer errors). Default off.
    exempt_writers: bool = false,
    /// Skip `defer/errdefer expr catch {}` (defer can't propagate). Default off.
    exempt_defers: bool = false,
};
const Groups = struct {
    style: ?Severity = null,
    complexity: ?Severity = null,
    /// Defaults to `.@"error"` (unlike `style`/`complexity`, which default
    /// to `null` and fall through to the blanket `default_severity`):
    /// `correctness`-group lints (e.g. `discarded_error`) flag something
    /// that is plausibly a real bug, not a style nit, so Clippy-style they
    /// should fail a CI run by default -- a user who disagrees can always
    /// override it back down via `zippy.zon`.
    ///
    /// This is a STRUCT-FIELD default rather than something layered on in
    /// `default()`, because `std.zon.parse.fromSlice` fills any field a
    /// user's `zippy.zon` omits from that field's own default, not from
    /// `default()`. If this lived only in `default()`, a `zippy.zon` that
    /// omits `.groups.correctness` would resolve to `.warn` while the
    /// no-file path resolved to `.@"error"` -- an inconsistency. Keeping it
    /// here means both paths agree.
    correctness: ?Severity = .@"error",
    /// The dead-code/unused category (`dead_file` today; more Tier 2/3
    /// unused-code lints land here later). Left at `null` (falling through
    /// to `default_severity`, i.e. `.warn`) rather than elevated like
    /// `correctness`, because dead-code detection is conservative/
    /// best-effort -- a false positive here is more likely than for a lint
    /// like `discarded_error`, so it shouldn't fail CI by default.
    unused: ?Severity = null,
    /// Memory-safety lints (`return_stack_local`, `hidden_allocator`).
    /// Defaults to `.@"error"` like `correctness` (not the blanket
    /// `default_severity`): a dangling stack pointer or a hidden global
    /// allocator is a real bug, and both lints are conservative (near-zero
    /// false positives), so Clippy-style they fail the build by default.
    memory: ?Severity = .@"error",
};
const Lints = struct {
    naming_convention: LintCfg = .{},
    redundant_else: LintCfg = .{},
    discarded_error: LintCfg = .{},
    too_many_params: TooManyParamsCfg = .{},
    line_width: LineWidthCfg = .{},
    inline_container_type: InlineContainerCfg = .{},
    unused_decl: LintCfg = .{},
    /// `dead_file` (the whole-file "nothing compiles this" check) isn't
    /// itself a `src/lints/` module -- it's computed in `build/mode.zig`
    /// from the build's reachability graph, not by walking one file's AST --
    /// but it still resolves its severity through `severityFor`, so it needs
    /// a slot here too. Without this, the only way to silence `dead_file`
    /// specifically is `.groups.unused = .off`, which also silences every
    /// *other* `unused`-group lint (e.g. `unused_decl`) -- too blunt once
    /// more than one lint shares the group.
    dead_file: LintCfg = .{},
    return_stack_local: LintCfg = .{},
    hidden_allocator: LintCfg = .{},
    param_ordering: ParamOrderingCfg = .{},
    suppressed_errors: SuppressedErrorsCfg = .{},
    duplicate_case: LintCfg = .{},
    homeless_try: LintCfg = .{},
    no_print: NoPrintCfg = .{},
    leaked_allocation: LeakedAllocationCfg = .{},
    use_after_free: LintCfg = .{},
};

default_severity: Severity = .warn,
groups: Groups = .{},
lints: Lints = .{},

/// All-defaults config, used when no `zippy.zon` is present.
///
/// This is just `.{}` -- the `.@"error"`-by-default behavior for the
/// `correctness` group lives on `Groups.correctness`'s own struct-field
/// default (see its doc comment) so that both this no-file path and a
/// `zippy.zon` that omits `.groups.correctness` resolve identically.
pub fn default() Config {
    return .{};
}

/// Parses `source` (a `zippy.zon` file's contents) into a `Config`.
/// Unknown fields (top-level or nested) are a parse error, not silently
/// dropped, so a typo in a user's config is caught immediately rather than
/// silently doing nothing.
pub fn loadFromSlice(gpa: std.mem.Allocator, source: [:0]const u8) !Config {
    return std.zon.parse.fromSlice(Config, gpa, source, null, .{});
}

/// `Config` (as parsed above) contains no pointers, so there is nothing
/// heap-allocated to release; `std.zon.parse.free` is a safe no-op traversal
/// here. Called anyway so callers don't need to know that detail and the
/// deinit stays correct if fields ever grow pointers (e.g. slices/strings).
pub fn deinit(self: *Config, gpa: std.mem.Allocator) void {
    std.zon.parse.free(gpa, self.*);
}

/// Resolves the effective severity for `lint_name`. Order is deliberate:
/// a per-lint override is the most specific thing a user can write, so it
/// wins over a per-group setting, which in turn wins over the blanket
/// `default_severity` fallback.
pub fn severityFor(cfg: Config, lint_name: []const u8, group: Group) Severity {
    const per_lint: ?Severity = blk: {
        if (std.mem.eql(u8, lint_name, "naming_convention"))
            break :blk cfg.lints.naming_convention.severity;
        if (std.mem.eql(u8, lint_name, "redundant_else"))
            break :blk cfg.lints.redundant_else.severity;
        if (std.mem.eql(u8, lint_name, "discarded_error"))
            break :blk cfg.lints.discarded_error.severity;
        if (std.mem.eql(u8, lint_name, "too_many_params"))
            break :blk cfg.lints.too_many_params.severity;
        if (std.mem.eql(u8, lint_name, "line_width"))
            break :blk cfg.lints.line_width.severity;
        if (std.mem.eql(u8, lint_name, "inline_container_type"))
            break :blk cfg.lints.inline_container_type.severity;
        if (std.mem.eql(u8, lint_name, "unused_decl"))
            break :blk cfg.lints.unused_decl.severity;
        if (std.mem.eql(u8, lint_name, "dead_file"))
            break :blk cfg.lints.dead_file.severity;
        if (std.mem.eql(u8, lint_name, "return_stack_local"))
            break :blk cfg.lints.return_stack_local.severity;
        if (std.mem.eql(u8, lint_name, "hidden_allocator"))
            break :blk cfg.lints.hidden_allocator.severity;
        if (std.mem.eql(u8, lint_name, "param_ordering"))
            break :blk cfg.lints.param_ordering.severity;
        if (std.mem.eql(u8, lint_name, "suppressed_errors"))
            break :blk cfg.lints.suppressed_errors.severity;
        if (std.mem.eql(u8, lint_name, "duplicate_case"))
            break :blk cfg.lints.duplicate_case.severity;
        if (std.mem.eql(u8, lint_name, "homeless_try"))
            break :blk cfg.lints.homeless_try.severity;
        if (std.mem.eql(u8, lint_name, "no_print"))
            break :blk cfg.lints.no_print.severity;
        if (std.mem.eql(u8, lint_name, "leaked_allocation"))
            break :blk cfg.lints.leaked_allocation.severity;
        if (std.mem.eql(u8, lint_name, "use_after_free"))
            break :blk cfg.lints.use_after_free.severity;
        break :blk null;
    };
    if (per_lint) |s| return s;
    const grp: ?Severity = switch (group) {
        .style => cfg.groups.style,
        .complexity => cfg.groups.complexity,
        .correctness => cfg.groups.correctness,
        .unused => cfg.groups.unused,
        .memory => cfg.groups.memory,
    };
    return grp orelse cfg.default_severity;
}

pub fn lineWidthMax(cfg: Config) u32 {
    return cfg.lints.line_width.max;
}
pub fn tooManyParamsMax(cfg: Config) u32 {
    return cfg.lints.too_many_params.max;
}
pub fn inlineContainerMaxFields(cfg: Config) u32 {
    return cfg.lints.inline_container_type.max_fields;
}
pub fn paramOrderingIo(cfg: Config) isize {
    return cfg.lints.param_ordering.io;
}
pub fn paramOrderingAllocator(cfg: Config) isize {
    return cfg.lints.param_ordering.allocator;
}
pub fn suppressedErrorsExemptTests(cfg: Config) bool {
    return cfg.lints.suppressed_errors.exempt_tests;
}
pub fn suppressedErrorsExemptWriters(cfg: Config) bool {
    return cfg.lints.suppressed_errors.exempt_writers;
}
pub fn suppressedErrorsExemptDefers(cfg: Config) bool {
    return cfg.lints.suppressed_errors.exempt_defers;
}
pub fn noPrintAllowTests(cfg: Config) bool {
    return cfg.lints.no_print.allow_tests;
}

test "default config resolves to default_severity then group" {
    const cfg = Config.default();
    try std.testing.expectEqual(Severity.warn, cfg.severityFor("naming_convention", .style));
    try std.testing.expectEqual(
        Severity.@"error",
        cfg.severityFor("discarded_error", .correctness),
    );
}

test "zippy.zon omitting .groups still defaults correctness to error, like default()" {
    const gpa = std.testing.allocator;
    const src =
        \\.{
        \\    .lints = .{ .line_width = .{ .max = 80 } },
        \\}
    ;
    var cfg = try Config.loadFromSlice(gpa, src);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(
        Severity.@"error",
        cfg.severityFor("discarded_error", .correctness),
    );
    try std.testing.expectEqual(
        Severity.@"error",
        Config.default().severityFor("discarded_error", .correctness),
    );
}

test "loadFromSlice applies group and per-lint overrides" {
    const gpa = std.testing.allocator;
    const src =
        \\.{
        \\    .default_severity = .warn,
        \\    .groups = .{ .correctness = .@"error" },
        \\    .lints = .{
        \\        .naming_convention = .{ .severity = .off },
        \\        .line_width = .{ .max = 80 },
        \\    },
        \\}
    ;
    var cfg = try Config.loadFromSlice(gpa, src);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(Severity.off, cfg.severityFor("naming_convention", .style));
    try std.testing.expectEqual(
        Severity.@"error",
        cfg.severityFor("discarded_error", .correctness),
    );
    try std.testing.expectEqual(@as(u32, 80), cfg.lineWidthMax());
}

test "unused group resolves via default then override" {
    const gpa = std.testing.allocator;
    const cfg_default = Config.default();
    // unused is not in the correctness->error default, so it falls to default_severity (.warn)
    try std.testing.expectEqual(Severity.warn, cfg_default.severityFor("dead_file", .unused));

    const src = ".{ .groups = .{ .unused = .off } }";
    var cfg = try Config.loadFromSlice(gpa, src);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(Severity.off, cfg.severityFor("dead_file", .unused));
}

test "unused_decl resolves to warn by default" {
    const cfg = Config.default();
    try std.testing.expectEqual(Severity.warn, cfg.severityFor("unused_decl", .unused));
}

test "a per-lint dead_file override silences it without silencing unused_decl" {
    const gpa = std.testing.allocator;
    const src = ".{ .lints = .{ .dead_file = .{ .severity = .off } } }";
    var cfg = try Config.loadFromSlice(gpa, src);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(Severity.off, cfg.severityFor("dead_file", .unused));
    try std.testing.expectEqual(Severity.warn, cfg.severityFor("unused_decl", .unused));
}

test "suppressed_errors defaults to error and exemptions off" {
    const cfg = Config.default();
    try std.testing.expectEqual(
        Severity.@"error",
        cfg.severityFor("suppressed_errors", .correctness),
    );
    try std.testing.expect(!cfg.suppressedErrorsExemptTests());
    try std.testing.expect(!cfg.suppressedErrorsExemptWriters());
    try std.testing.expect(!cfg.suppressedErrorsExemptDefers());
}

test "duplicate_case resolves to warn by default, via the complexity group" {
    const cfg = Config.default();
    try std.testing.expectEqual(Severity.warn, cfg.severityFor("duplicate_case", .complexity));
}

test "no_print resolves to warn by default via the style group, allow_tests on" {
    const cfg = Config.default();
    try std.testing.expectEqual(Severity.warn, cfg.severityFor("no_print", .style));
    try std.testing.expect(cfg.noPrintAllowTests());
}

test "no_print allow_tests parses from zon" {
    const gpa = std.testing.allocator;
    const src = ".{ .lints = .{ .no_print = .{ .allow_tests = false } } }";
    var cfg = try Config.loadFromSlice(gpa, src);
    defer cfg.deinit(gpa);
    try std.testing.expect(!cfg.noPrintAllowTests());
}

test "leaked_allocation resolves to warn by default, NOT the memory group's error" {
    const cfg = Config.default();
    // .groups.memory defaults to .@"error" (see Groups.memory's doc), but
    // LeakedAllocationCfg.severity's own non-null .warn default wins over it
    // (a non-null per-lint severity always beats the group -- severityFor's
    // doc). This is the quirk LeakedAllocationCfg's own doc comment flags.
    try std.testing.expectEqual(Severity.warn, cfg.severityFor("leaked_allocation", .memory));
}

test "use_after_free resolves to error by default, via the memory group" {
    const cfg = Config.default();
    try std.testing.expectEqual(Severity.@"error", cfg.severityFor("use_after_free", .memory));
}

test "suppressed_errors exemptions parse from zon" {
    const gpa = std.testing.allocator;
    const src =
        \\.{ .lints = .{ .suppressed_errors = .{
        \\    .exempt_tests = true, .exempt_defers = true,
        \\} } }
    ;
    var cfg = try Config.loadFromSlice(gpa, src);
    defer cfg.deinit(gpa);
    try std.testing.expect(cfg.suppressedErrorsExemptTests());
    try std.testing.expect(!cfg.suppressedErrorsExemptWriters());
    try std.testing.expect(cfg.suppressedErrorsExemptDefers());
}

//! Typed representation of a `zippy.zon` config file.
//!
//! Parsed via `std.zon.parse` with `ignore_unknown_fields = false` (the
//! default) so a typo'd key in a user's `zippy.zon` fails loud at load time
//! instead of being silently ignored.
const std = @import("std");
const Severity = @import("Diagnostic.zig").Severity;
const Config = @This();

pub const Group = enum { style, complexity, correctness };

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
};
const Lints = struct {
    naming_convention: LintCfg = .{},
    redundant_else: LintCfg = .{},
    discarded_error: LintCfg = .{},
    too_many_params: TooManyParamsCfg = .{},
    line_width: LineWidthCfg = .{},
    inline_container_type: InlineContainerCfg = .{},
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
        break :blk null;
    };
    if (per_lint) |s| return s;
    const grp: ?Severity = switch (group) {
        .style => cfg.groups.style,
        .complexity => cfg.groups.complexity,
        .correctness => cfg.groups.correctness,
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

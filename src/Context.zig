//! Per-lint-run handle passed to each lint's `run` function. Bundles the
//! parsed `Source`, the resolved `Config`, and a `report` helper so lints
//! never touch `diags` directly or reason about severity themselves --
//! `Linter.run` resolves `current_severity` from config *before* calling the
//! lint, so a lint stays pure "did I see the pattern" logic and can't
//! accidentally disagree with the user's config about whether it's enabled.
const std = @import("std");
const Source = @import("Source.zig");
const Config = @import("Config.zig");
const Diagnostic = @import("Diagnostic.zig");
const Context = @This();

/// The lints' real fault surface: `ctx.report` and every AutoHashMap
/// `put`/`contains` call a lint makes can only ever OOM (AST accessors don't
/// error), so this is named rather than the broader `anyerror` -- a lint
/// `run` signature that says `Context.LintError!void` documents that truth
/// instead of overstating it.
pub const LintError = std.mem.Allocator.Error;

gpa: std.mem.Allocator,
source: *const Source,
config: *const Config,
diags: *std.ArrayList(Diagnostic),
current_lint: []const u8 = "",
current_severity: Diagnostic.Severity = .warn,

/// Appends a diagnostic covering `[start_offset, end_offset)` with
/// `current_lint`/`current_severity`. The message is duped with `ctx.gpa`
/// (not an arena) so every `Diagnostic.message` -- whether from a parse
/// error or a lint -- has one uniform owner and is freed exactly once by
/// whoever drains `diags`, with no arena lifetime to track separately.
pub fn report(
    ctx: *Context,
    start_offset: usize,
    end_offset: usize,
    comptime fmt: []const u8,
    args: anytype,
) LintError!void {
    const msg = try std.fmt.allocPrint(ctx.gpa, fmt, args);
    errdefer ctx.gpa.free(msg);
    try ctx.diags.append(ctx.gpa, .{
        .path = ctx.source.path,
        .byte_offset = start_offset,
        .end_offset = end_offset,
        .severity = ctx.current_severity,
        .lint = ctx.current_lint,
        .message = msg,
    });
}

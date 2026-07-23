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
const Semantic = @import("Semantic.zig");
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
/// The per-file scope tree, set by `Linter.run` before the registry loop
/// runs. Defaults to `undefined` (not a pointer-to-empty-struct or similar)
/// so the many existing hand-built `Context` literals across other lints'
/// unit tests -- which never touch `semantic` -- keep compiling unchanged;
/// only a lint that actually queries `ctx.semantic` needs its test to build
/// a real `Semantic` and set this field first (see `homeless_try`'s tests).
semantic: *const Semantic = undefined,

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

/// The message span plus `Fix` for `reportWithFix`, bundled into one struct
/// per `too_many_params`' own advice ("bundle related parameters into a
/// struct") -- `report` already spends its full 5-parameter budget on
/// `(ctx, start_offset, end_offset, fmt, args)`, so the `Fix` this function
/// adds on top has to travel bundled with the span rather than as its own
/// positional parameter.
pub const FixSpan = struct {
    start_offset: usize,
    end_offset: usize,
    fix: Diagnostic.Fix,
};

/// Like `report`, but attaches an automatic `Fix` (see `FixSpan`).
/// `fix.replacement` must outlive rendering: pass a static string (e.g. ""
/// for a deletion) or an `ctx.gpa`-owned slice freed via `Diagnostic.deinit`.
///
/// Ownership: on SUCCESS this takes ownership of a non-empty `fix.replacement`
/// (it is stored as-is and later freed by `Diagnostic.deinit`). On error it
/// frees only the `message` it allocated, NEVER the replacement -- a caller
/// that passed an owned replacement must keep its own `errdefer` to free it on
/// the error path. A static `""` replacement is owned by no one (len 0).
pub fn reportWithFix(
    ctx: *Context,
    span: FixSpan,
    comptime fmt: []const u8,
    args: anytype,
) LintError!void {
    const msg = try std.fmt.allocPrint(ctx.gpa, fmt, args);
    errdefer ctx.gpa.free(msg);
    try ctx.diags.append(ctx.gpa, .{
        .path = ctx.source.path,
        .byte_offset = span.start_offset,
        .end_offset = span.end_offset,
        .severity = ctx.current_severity,
        .lint = ctx.current_lint,
        .message = msg,
        .fix = span.fix,
    });
}

test "reportWithFix attaches a Fix to the diagnostic" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const x = 1;\n" });
    const p = try tmp.dir.realPathFileAlloc(io, "a.zig", gpa);
    defer gpa.free(p);

    var src = try Source.load(io, gpa, p);
    defer src.deinit(gpa);
    const cfg = Config.default();

    var diags: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diags.items) |d| gpa.free(d.message);
        diags.deinit(gpa);
    }
    var ctx: Context = .{
        .gpa = gpa,
        .source = &src,
        .config = &cfg,
        .diags = &diags,
        .current_lint = "unused_decl",
        .current_severity = .warn,
    };
    try ctx.reportWithFix(.{
        .start_offset = 6,
        .end_offset = 7,
        .fix = .{ .start = 0, .end = 13, .replacement = "" },
    }, "unused decl 'x'", .{});

    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    const fix = diags.items[0].fix.?;
    try std.testing.expectEqual(@as(usize, 0), fix.start);
    try std.testing.expectEqual(@as(usize, 13), fix.end);
    try std.testing.expectEqual(@as(usize, 0), fix.replacement.len);
}

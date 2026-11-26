//! Flags lines longer than `Config.lineWidthMax`. This is the simplest lint
//! in the set: it never touches the AST, only `ctx.source.bytes`, so it also
//! serves as the reference example for a "raw line scan" lint.
//!
//! Column counting here is byte-based, not codepoint-based: each byte after
//! a newline advances `col` by one. That undercounts columns for
//! multi-byte UTF-8 source (each continuation byte adds to `col`) and
//! overcounts them for wide/multi-column glyphs, but Zig source is
//! overwhelmingly ASCII and a byte-accurate skeleton is simpler and faster
//! than threading a UTF-8 decoder through the hot scan loop. Revisit if
//! non-ASCII identifiers/strings turn out to matter in practice.
const std = @import("std");
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");

pub const name = "line_width";
pub const group: Config.Group = .style;
pub const description: []const u8 =
    "Lines longer than the configured maximum hurt readability in " ++
    "side-by-side diffs and narrow terminals. Wrap the line; a " ++
    "struct/call/array literal keeps its wrap under `zig fmt` if the " ++
    "last element has a trailing comma.";

pub fn run(ctx: *Context) Context.LintError!void {
    const max = ctx.config.lineWidthMax();
    const bytes = ctx.source.bytes;
    var col: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\n') {
            col = 0;
            continue;
        }
        col += 1;
        // Report once per line, at the first byte that pushes the line past
        // the limit -- later bytes on the same over-limit line are noise
        // once the finding has already been raised. The span covers the
        // rest of the over-limit line, up to (not including) the newline
        // or EOF, so LSP/fix consumers get the whole offending line.
        if (col == max + 1) {
            var line_end = i;
            while (line_end < bytes.len and bytes[line_end] != '\n') : (line_end += 1) {}
            try ctx.report(i, line_end, "line exceeds {d} columns", .{max});
        }
    }
}

test "flags a line wider than the configured max" {
    const gpa = std.testing.allocator;
    const long = "const x = \"" ++ @as([120]u8, @splat('a')) ++ "\";\nconst y = 1;\n";
    var src = try Source.loadFromSlice(gpa, "t.zig", long);
    defer src.deinit(gpa);
    var cfg = Config.default();

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
        .current_lint = name,
        .current_severity = .warn,
    };
    try run(&ctx);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    const loc = Diagnostic.lineColAt(src.bytes, diags.items[0].byte_offset);
    try std.testing.expectEqual(@as(usize, 1), loc.line);
}

test "stays silent on a file with only short lines" {
    const gpa = std.testing.allocator;
    const short = "const x = 1;\nconst y = 2;\n";
    var src = try Source.loadFromSlice(gpa, "t.zig", short);
    defer src.deinit(gpa);
    var cfg = Config.default();

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
        .current_lint = name,
        .current_severity = .warn,
    };
    try run(&ctx);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

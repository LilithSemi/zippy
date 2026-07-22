//! A single lint finding plus the zig-compiler-style renderer for it.
//! `path`/`byte_offset` locate the finding; `render` turns it into the
//! familiar `path:line:col: level: message` + source line + caret block
//! that `zig build` itself prints, so Zippy output reads like compiler output.
const std = @import("std");
const Diagnostic = @This();

pub const Severity = enum { off, warn, @"error" };

path: []const u8,
byte_offset: usize,
/// Exclusive byte end of the flagged span; the diagnostic covers
/// `[byte_offset, end_offset)`. Editors need a range, not a point, and the
/// coming fix mode needs the exact region to edit. `render` still draws a
/// single caret at `byte_offset`; the span is for LSP/fixes.
end_offset: usize,
severity: Severity,
lint: []const u8,
message: []const u8,
/// An optional automatic fix for this diagnostic. `null` (the default) for
/// every diagnostic that has no machine-applicable fix, which is every
/// diagnostic today -- existing `Diagnostic{...}` literals and the
/// render/LSP paths that build them are unaffected by this field.
fix: ?Fix = null,

/// An automatic fix for a diagnostic: replace the bytes `[start, end)` of the
/// source with `replacement`. Separate from the diagnostic's own
/// `byte_offset`/`end_offset` (where the message points) -- the fix span can
/// differ (e.g. the message points at a name, the fix deletes the whole decl).
///
/// `title` is the imperative label an LSP code action shows for this fix (e.g.
/// "remove unused declaration"); it defaults to `""` so the CLI `--fix`
/// applier (which never shows a title) and existing `Fix` literals are
/// unaffected. A fixable lint sets it to a static string.
///
/// `replacement` is either a static `""` (deletion, never freed) or a
/// gpa-owned non-empty slice freed by `Diagnostic.deinit`.
pub const Fix = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
    title: []const u8 = "",
};

/// Frees everything this diagnostic owns: its `message` (always gpa-owned, see
/// `Context.report`), and -- only when non-empty -- its `fix.replacement`.
///
/// The `replacement.len > 0` guard encodes the ownership convention: a fix's
/// replacement is EITHER a static `""` (a pure deletion, e.g. `unused_decl`),
/// which is never heap-allocated and must not be freed, OR a gpa-owned
/// non-empty string (a reconstructed edit, e.g. `redundant_else`), which is.
/// Callers that own a diagnostics list free each entry with this instead of a
/// bare `gpa.free(d.message)`, so an owned replacement never leaks.
pub fn deinit(d: Diagnostic, gpa: std.mem.Allocator) void {
    gpa.free(d.message);
    if (d.fix) |f| {
        if (f.replacement.len > 0) gpa.free(f.replacement);
    }
}

/// A 1-based line/column plus the `[line_start, line_end)` byte range of
/// that line (excluding the newline). Named (rather than an inline anonymous
/// struct) so it stays under the `inline_container_type` field-count lint
/// and so its shape is documented once instead of at every call site.
pub const Location = struct {
    line: usize,
    col: usize,
    line_start: usize,
    line_end: usize,
};

/// Maps a byte offset into `source_bytes` to a 1-based line/column plus the
/// `[line_start, line_end)` byte range of that line (excluding the newline),
/// so callers can slice out the source line for display without rescanning.
pub fn lineColAt(source_bytes: []const u8, byte_offset: usize) Location {
    var line: usize = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < byte_offset and i < source_bytes.len) : (i += 1) {
        if (source_bytes[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    var line_end = line_start;
    while (line_end < source_bytes.len and source_bytes[line_end] != '\n') : (line_end += 1) {}
    return .{
        .line = line,
        .col = byte_offset - line_start + 1,
        .line_start = line_start,
        .line_end = line_end,
    };
}

/// `.off` is unreachable here: `Linter.run` resolves each lint's severity
/// before calling it and `continue`s past any lint whose resolved severity
/// is `.off`, so no `.off`-severity `Diagnostic` is ever constructed, let
/// alone reaches `render`. Hitting `.off` here would mean that driver
/// guarantee has been broken -- a programmer error to assert on, not a
/// runtime fault to paper over.
fn levelName(s: Severity) []const u8 {
    return switch (s) {
        .off => unreachable,
        .warn => "warning",
        .@"error" => "error",
    };
}

// ANSI SGR (Select Graphic Rendition) escapes used by `render` when
// `use_color` is set. Named rather than inlined so the meaning of each
// escape is documented once instead of re-derived at every call site, and
// so the "reset after every colored span" rule is easy to audit by eye.
/// Bold red: used for the `error` severity word.
const color_bold_red = "\x1b[1;31m";
/// Bold yellow: used for the `warning` severity word.
const color_bold_yellow = "\x1b[1;33m";
/// Bold green: used for the `^` caret.
const color_bold_green = "\x1b[1;32m";
/// Dim: used for the trailing `[lint]` tag.
const color_dim = "\x1b[2m";
/// Ends whichever colored span preceded it.
const color_reset = "\x1b[0m";

/// The color for a severity's level word. `.off` is unreachable here for the
/// same reason as in `levelName`: `Linter.run` filters `.off`-severity lints
/// out before a `Diagnostic` is ever constructed, so `.off` reaching this
/// function (via `render`) would be a programmer error, not a real case to
/// pick a placeholder color for.
fn levelColor(s: Severity) []const u8 {
    return switch (s) {
        .off => unreachable,
        .warn => color_bold_yellow,
        .@"error" => color_bold_red,
    };
}

/// Renders `d` in the zig-compiler style: a `path:line:col: level: message
/// [lint]` header line, the offending source line, and a caret line pointing
/// at the column. Keeps Zippy diagnostics visually indistinguishable from
/// `zig build` errors so editors/tooling that already parse those keep working.
///
/// When `use_color` is `false` the output is byte-for-byte the same plain
/// text Zippy has always printed; `use_color` only ever adds ANSI escapes
/// around spans that already existed, never changes the plain-text content,
/// so a `cat -v`-through-a-pipe or a NO_COLOR-honoring reader always sees the
/// exact same message either way.
pub fn render(
    d: Diagnostic,
    source_bytes: []const u8,
    w: *std.Io.Writer,
    use_color: bool,
) !void {
    const loc = lineColAt(source_bytes, d.byte_offset);
    const level = levelName(d.severity);
    if (use_color) {
        try w.print("{s}:{d}:{d}: {s}{s}{s}: {s} [{s}{s}{s}]\n", .{
            d.path,
            loc.line,
            loc.col,
            levelColor(d.severity),
            level,
            color_reset,
            d.message,
            color_dim,
            d.lint,
            color_reset,
        });
    } else {
        try w.print("{s}:{d}:{d}: {s}: {s} [{s}]\n", .{
            d.path, loc.line, loc.col, level, d.message, d.lint,
        });
    }
    const line_text = source_bytes[loc.line_start..loc.line_end];
    try w.print("{s}\n", .{line_text});
    // caret under the column
    var pad: usize = 1;
    while (pad < loc.col) : (pad += 1) try w.writeByte(' ');
    if (use_color) {
        try w.print("{s}^{s}\n", .{ color_bold_green, color_reset });
    } else {
        try w.writeByte('^');
        try w.writeByte('\n');
    }
}

test "lineColAt maps byte offset to 1-based line and column" {
    const src = "abc\ndef\nghi";
    const loc = lineColAt(src, 5); // 'e' on line 2, col 2
    try std.testing.expectEqual(@as(usize, 2), loc.line);
    try std.testing.expectEqual(@as(usize, 2), loc.col);
    try std.testing.expectEqualStrings("def", src[loc.line_start..loc.line_end]);
}

test "render writes zig-style diagnostic with caret" {
    const src = "const x=1;\n";
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const d: Diagnostic = .{
        .path = "a.zig",
        .byte_offset = 6, // the 'x'
        .end_offset = 6,
        .severity = .warn,
        .lint = "naming_convention",
        .message = "bad name",
    };
    try d.render(src, &w, false);
    const out = w.buffered();
    const expected = "a.zig:1:7: warning: bad name [naming_convention]";
    try std.testing.expect(std.mem.indexOf(u8, out, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "^") != null);
}

test "render with use_color=true adds ANSI escapes without changing text" {
    const src = "const x=1;\n";
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const d: Diagnostic = .{
        .path = "a.zig",
        .byte_offset = 6, // the 'x'
        .end_offset = 6,
        .severity = .@"error",
        .lint = "naming_convention",
        .message = "bad name",
    };
    try d.render(src, &w, true);
    const out = w.buffered();
    // plain-text content is still all present, just interleaved with escapes.
    try std.testing.expect(std.mem.indexOf(u8, out, "a.zig:1:7:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "error") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bad name") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "naming_convention") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "^") != null);
    // color escapes: bold-red error word and at least one reset.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1;31m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[0m") != null);
}

test "deinit frees an owned (non-empty) replacement without leaking" {
    const gpa = std.testing.allocator;
    const msg = try gpa.dupe(u8, "some message");
    const repl = try gpa.dupe(u8, "\n    return 2;");
    const d: Diagnostic = .{
        .path = "t.zig",
        .byte_offset = 0,
        .end_offset = 4,
        .severity = .warn,
        .lint = "redundant_else",
        .message = msg,
        .fix = .{ .start = 0, .end = 10, .replacement = repl, .title = "x" },
    };
    d.deinit(gpa); // frees msg + repl; std.testing.allocator fails the test on any leak
}

test "deinit leaves a static empty replacement untouched (len 0 not freed)" {
    const gpa = std.testing.allocator;
    const msg = try gpa.dupe(u8, "m");
    const d: Diagnostic = .{
        .path = "t.zig",
        .byte_offset = 0,
        .end_offset = 1,
        .severity = .warn,
        .lint = "unused_decl",
        .message = msg,
        .fix = .{ .start = 0, .end = 1, .replacement = "", .title = "y" },
    };
    d.deinit(gpa); // frees only msg; the "" replacement (len 0) must NOT be freed
}

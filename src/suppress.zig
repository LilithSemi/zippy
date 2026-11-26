//! Inline lint suppression: `// zippy:ignore <lints>` comment directives.
//!
//! Zig only tokenizes `///` doc comments and `//!` container-doc comments --
//! a plain `//` comment produces no token at all. So the only way to find
//! plain `//` comments is to look at what's *between* tokens: every byte in
//! the gap between two adjacent AST tokens is either whitespace or a plain
//! comment, and can never be string content, because string literals
//! (including multiline `\\` strings) are themselves tokens. Walking the
//! token stream and scanning each gap for `//` therefore finds every plain
//! comment in the file, and never misfires on a `// zippy:ignore` sequence
//! that merely appears inside a string literal.
const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("Diagnostic.zig");

pub const Suppressions = struct {
    /// One parsed `// zippy:ignore` directive. `names_start..names_end` index
    /// into `names`.
    pub const Entry = struct {
        line: usize, // 1-based target line
        all: bool, // bare directive: suppress every lint on `line`
        names_start: usize,
        names_end: usize,
    };
    entries: std.ArrayList(Entry) = .empty,
    /// Flat lint-name storage. Slices BORROW from the scanned source bytes, so
    /// a `Suppressions` is only valid while that source is alive.
    names: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Suppressions, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
        self.names.deinit(gpa);
    }

    /// True if a directive targets `line` and covers `lint` (bare, or names it).
    pub fn suppressed(self: *const Suppressions, lint: []const u8, line: usize) bool {
        for (self.entries.items) |e| {
            if (e.line != line) continue;
            if (e.all) return true;
            for (self.names.items[e.names_start..e.names_end]) |nm| {
                if (std.mem.eql(u8, nm, lint)) return true;
            }
        }
        return false;
    }

    /// Scans `bytes` for `// zippy:ignore` directives. Uses `tree`'s token
    /// boundaries: the bytes between two adjacent tokens are only whitespace or
    /// plain `//` comments (strings/multiline `\\` strings are tokens), so a
    /// `//` found in a gap is always a real comment -- never string content.
    pub fn scan(gpa: std.mem.Allocator, bytes: [:0]const u8, tree: *const Ast) !Suppressions {
        var sup: Suppressions = .{};
        errdefer sup.deinit(gpa);
        var prev_end: usize = 0;
        var i: u32 = 0;
        const n: u32 = @intCast(tree.tokens.len);
        while (i < n) : (i += 1) {
            const gap_start = prev_end;
            const gap_end = tree.tokenStart(i);
            if (gap_end > gap_start) try scanGap(gpa, &sup, bytes, gap_start, gap_end);
            prev_end = tree.tokenStart(i) + tree.tokenSlice(i).len;
        }
        return sup;
    }
};

/// Scans the byte range `[start, end)` (a token gap: whitespace + plain
/// comments) for `//` comments, processing each as a possible directive.
fn scanGap(
    gpa: std.mem.Allocator,
    sup: *Suppressions,
    bytes: [:0]const u8,
    start: usize,
    end: usize,
) !void {
    var i = start;
    while (i < end) {
        if (bytes[i] == '/' and i + 1 < end and bytes[i + 1] == '/') {
            var j = i + 2;
            // A `//` comment runs to its line's `\n`, which is whitespace still
            // inside this gap (the next token starts on a later line); for the
            // final gap with no trailing newline, `end` == source length. So
            // bounding on the gap's own `end` is both correct and locally auditable.
            while (j < end and bytes[j] != '\n') j += 1;
            try processComment(gpa, sup, bytes, i, j);
            i = j;
        } else {
            i += 1;
        }
    }
}

/// Parses one `//` comment `[c_start, c_end)` as a directive, appending an
/// `Entry` if it starts with exactly `zippy:ignore` (+ whitespace/eol).
fn processComment(
    gpa: std.mem.Allocator,
    sup: *Suppressions,
    bytes: [:0]const u8,
    c_start: usize,
    c_end: usize,
) !void {
    var b = c_start;
    while (b < c_end and bytes[b] == '/') b += 1; // skip leading slashes
    while (b < c_end and (bytes[b] == ' ' or bytes[b] == '\t')) b += 1;
    const core = bytes[b..c_end];
    const kw = "zippy:ignore";
    if (!std.mem.startsWith(u8, core, kw)) return;
    const after = core[kw.len..];
    // Reject `zippy:ignore-file` etc: the keyword must be followed by ws or eol.
    if (after.len != 0 and after[0] != ' ' and after[0] != '\t') return;

    const loc = Diagnostic.lineColAt(bytes, c_start);
    const before = bytes[loc.line_start..c_start];
    const trailing = hasNonWhitespace(before);
    const target: usize = if (trailing) loc.line else loc.line + 1;

    const names_start = sup.names.items.len;
    var it = std.mem.tokenizeAny(u8, after, " \t");
    while (it.next()) |nm| try sup.names.append(gpa, nm);
    const names_end = sup.names.items.len;
    try sup.entries.append(gpa, .{
        .line = target,
        .all = names_end == names_start, // bare directive
        .names_start = names_start,
        .names_end = names_end,
    });
}

fn hasNonWhitespace(s: []const u8) bool {
    for (s) |c| if (c != ' ' and c != '\t') return true;
    return false;
}

fn scanSrc(gpa: std.mem.Allocator, src: [:0]const u8) !Suppressions {
    var tree = try std.zig.Ast.parse(gpa, src, .{});
    defer tree.deinit(gpa);
    // Name slices in the result borrow from `src` (a static test literal here),
    // NOT from `tree`, so deinit'ing the tree is fine.
    return Suppressions.scan(gpa, src, &tree);
}

test "standalone directive suppresses the next line" {
    const gpa = std.testing.allocator;
    var sup = try scanSrc(gpa, "// zippy:ignore discarded_error\nconst x = foo();\n");
    defer sup.deinit(gpa);
    try std.testing.expect(sup.suppressed("discarded_error", 2));
    try std.testing.expect(!sup.suppressed("discarded_error", 1));
    try std.testing.expect(!sup.suppressed("other_lint", 2));
}
test "trailing directive suppresses its own line" {
    const gpa = std.testing.allocator;
    var sup = try scanSrc(gpa, "const x = foo(); // zippy:ignore discarded_error\n");
    defer sup.deinit(gpa);
    try std.testing.expect(sup.suppressed("discarded_error", 1));
    try std.testing.expect(!sup.suppressed("discarded_error", 2));
}
test "bare directive suppresses all lints on the target line" {
    const gpa = std.testing.allocator;
    var sup = try scanSrc(gpa, "// zippy:ignore\nconst x = foo();\n");
    defer sup.deinit(gpa);
    try std.testing.expect(sup.suppressed("anything", 2));
    try std.testing.expect(sup.suppressed("discarded_error", 2));
}
test "multiple space-separated names" {
    const gpa = std.testing.allocator;
    var sup = try scanSrc(gpa, "// zippy:ignore discarded_error hidden_allocator\nx\n");
    defer sup.deinit(gpa);
    try std.testing.expect(sup.suppressed("discarded_error", 2));
    try std.testing.expect(sup.suppressed("hidden_allocator", 2));
    try std.testing.expect(!sup.suppressed("naming_convention", 2));
}
test "a zippy:ignore sequence inside a string literal is not a directive" {
    const gpa = std.testing.allocator;
    var sup = try scanSrc(gpa, "const s = \"// zippy:ignore discarded_error\";\nx\n");
    defer sup.deinit(gpa);
    try std.testing.expect(!sup.suppressed("discarded_error", 2));
    try std.testing.expectEqual(@as(usize, 0), sup.entries.items.len);
}
test "prose that merely mentions the keyword does not trigger" {
    const gpa = std.testing.allocator;
    var sup = try scanSrc(gpa, "// see the zippy:ignore docs\nconst x = foo();\n");
    defer sup.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), sup.entries.items.len);
}
test "zippy:ignore-file (no space after keyword) is not the plain directive" {
    const gpa = std.testing.allocator;
    var sup = try scanSrc(gpa, "// zippy:ignore-file\nx\n");
    defer sup.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), sup.entries.items.len);
}
test "a trailing comment at end of file with no newline still parses" {
    const gpa = std.testing.allocator;
    var sup = try scanSrc(gpa, "const x = foo(); // zippy:ignore discarded_error");
    defer sup.deinit(gpa);
    try std.testing.expect(sup.suppressed("discarded_error", 1));
}

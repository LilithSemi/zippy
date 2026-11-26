//! Flags an `if` expression that has an `else` where the "then" branch's
//! last statement is an unconditional jump (`return`, `break`, or
//! `continue`). When the then-branch always jumps away, control never falls
//! through to the statement after the `if`, so wrapping the rest of the
//! function/loop body in an `else` is redundant -- it would run at the same
//! indentation either way:
//!
//!     if (x) {
//!         return 1;
//!     } else {
//!         return 2;
//!     }
//!
//! is equivalent to, and clearer as:
//!
//!     if (x) {
//!         return 1;
//!     }
//!     return 2;
//!
//! Detection is deliberately conservative (IronStyle: a false positive here
//! -- flagging an `else` that is NOT redundant -- is much worse than missing
//! a case). This only fires when the then-branch's last statement is
//! unambiguously a jump node:
//!   - Block forms `.block`, `.block_semicolon`, `.block_two`,
//!     `.block_two_semicolon`: the last statement in the block is checked.
//!     An empty block never fires (there is no last statement to jump).
//!   - Any other then-expr shape (e.g. a bare, brace-less
//!     `if (x) return 1 else return 2;`) is checked directly: if the node
//!     itself is a jump tag, it fires.
//! Nothing else is inspected -- in particular, a jump nested inside an inner
//! `if`/`while`/`switch` inside the then-block does NOT count, because it is
//! not necessarily the then-block's own last statement's tag; only the
//! block's literal last statement's own tag is checked, so a non-jump last
//! statement (even one that contains jumps deeper inside) leaves the lint
//! silent.
//!
//! A LABELED `break` (`break :blk value;`) is a special case: it does not
//! escape the enclosing function/loop the way a plain `break`/`continue`/
//! `return` does -- it yields a value out of a labeled block, most commonly
//! the `blk: { ... }` shape used to make `if`/`else` an expression:
//!
//!     const v = if (x) blk: {
//!         break :blk a;
//!     } else blk: {
//!         break :blk b;
//!     };
//!
//! Here the `if` is an expression and the `else` is mandatory -- deleting it
//! is a compile error, not a style choice. So a labeled `break` is never
//! treated as a redundant-making jump, regardless of what block it lives in;
//! only a plain, unlabeled `break` counts. `continue` is conservatively
//! restricted the same way (labeled continue does not count either), even
//! though a labeled continue always targets an enclosing loop rather than
//! yielding a block value -- the AST shape is identical to labeled break, so
//! treating them alike keeps the label check trivially correct. `return`
//! has no label to check and always counts.
const std = @import("std");
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Ast = std.zig.Ast;

pub const name = "redundant_else";
pub const group: Config.Group = .complexity;
pub const description: []const u8 =
    "When an if-branch always returns/breaks/continues, the following " ++
    "else is redundant: dedent its body to the outer scope.";

/// True when `node` -- or, for a recognized block shape, its last statement
/// -- is a `return`/`break`/`continue` node. Unrecognized block shapes or
/// empty blocks conservatively return false (see file doc comment).
fn endsInJump(tree: *const Ast, node: Ast.Node.Index) bool {
    const tag = tree.nodeTag(node);
    const last = switch (tag) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => blk: {
            var buf: [2]Ast.Node.Index = undefined;
            const stmts = tree.blockStatements(&buf, node) orelse return false;
            if (stmts.len == 0) return false;
            break :blk stmts[stmts.len - 1];
        },
        else => node,
    };
    return switch (tree.nodeTag(last)) {
        .@"return" => true,
        // `.@"break"`/`.@"continue"` store `(opt_label, opt_rhs)` as
        // `opt_token_and_opt_node`. A labeled break yields a value out of a
        // labeled block (e.g. `break :blk value;`) rather than escaping the
        // enclosing function/loop, so it must NOT count as a redundant-
        // making jump -- see the file doc comment. Labeled continue is
        // conservatively excluded too, for the same AST-shape reason even
        // though it always targets a loop.
        .@"break", .@"continue" => {
            const opt_label, _ = tree.nodeData(last).opt_token_and_opt_node;
            return opt_label.unwrap() == null;
        },
        else => false,
    };
}

/// The reconstructed replacement plus the byte span it replaces.
const FixSpanText = struct { start: u32, end: u32, replacement: []const u8 };

fn tokenEnd(tree: *const Ast, tok: Ast.TokenIndex) u32 {
    return tree.tokenStart(tok) + @as(u32, @intCast(tree.tokenSlice(tok).len));
}

fn isBlockTag(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => true,
        else => false,
    };
}

/// Any DIRECT statement of block `node` a variable declaration? Hoisting such a
/// body to the outer scope could shadow/collide and fail to compile, so the
/// braced-else fix is skipped when true (correctness bias; see file doc).
fn bodyDeclaresLocal(tree: *const Ast, node: Ast.Node.Index) bool {
    var buf: [2]Ast.Node.Index = undefined;
    const stmts = tree.blockStatements(&buf, node) orelse return false;
    for (stmts) |s| if (tree.fullVarDecl(s) != null) return true;
    return false;
}

/// Indentation width of the first non-blank line in `inner` (the raw text
/// between an else block's braces); 0 if none.
fn firstBodyIndent(inner: []const u8) usize {
    var i: usize = 0;
    while (i < inner.len) {
        var j: usize = i;
        var ws: usize = 0;
        while (j < inner.len and (inner[j] == ' ' or inner[j] == '\t')) : (j += 1) ws += 1;
        if (j < inner.len and inner[j] != '\n') return ws;
        while (j < inner.len and inner[j] != '\n') j += 1;
        if (j < inner.len) j += 1;
        i = j;
    }
    return 0;
}

/// Appends `inner` to `buf`, stripping up to `strip_n` leading whitespace chars
/// from each line. Only ever strips whitespace, so it can under-dedent but never
/// corrupt code.
fn dedentInto(
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    inner: []const u8,
    strip_n: usize,
) !void {
    var i: usize = 0;
    while (i < inner.len) {
        var stripped: usize = 0;
        while (i < inner.len and stripped < strip_n and
            (inner[i] == ' ' or inner[i] == '\t')) : (i += 1)
        {
            stripped += 1;
        }
        while (i < inner.len) {
            const c = inner[i];
            try buf.append(gpa, c);
            i += 1;
            if (c == '\n') break;
        }
    }
}

/// Builds the fix for one redundant `if/else`, or `null` to skip it (a
/// non-statement `if`, or a braced else that declares a local). The returned
/// `replacement` is gpa-owned when non-empty (caller transfers ownership to the
/// diagnostic via `reportWithFix`, freeing it on the error path).
fn computeFix(ctx: *Context, full: Ast.full.If) Context.LintError!?FixSpanText {
    const tree = &ctx.source.ast;
    const src = ctx.source.bytes;
    const then_expr = full.ast.then_expr;
    const else_expr = full.ast.else_expr.unwrap().?;

    // outer_indent = the whitespace before `if` on its line; require `if` to be
    // at statement position (the first non-whitespace on the line).
    const if_start = tree.tokenStart(full.ast.if_token);
    var ls: usize = if_start;
    while (ls > 0 and src[ls - 1] != '\n') ls -= 1;
    var ie: usize = ls;
    while (ie < src.len and (src[ie] == ' ' or src[ie] == '\t')) ie += 1;
    if (ie != if_start) return null; // `if` not at statement position
    const outer_indent = src[ls..ie];

    const span_start = tokenEnd(tree, tree.lastToken(then_expr));
    const term: []const u8 = if (isBlockTag(tree.nodeTag(then_expr))) "" else ";";

    if (isBlockTag(tree.nodeTag(else_expr))) {
        if (bodyDeclaresLocal(tree, else_expr)) return null;
        const lbrace = tree.firstToken(else_expr);
        const rbrace = tree.lastToken(else_expr);
        const inner = src[tokenEnd(tree, lbrace)..tree.tokenStart(rbrace)];
        const span_end = tokenEnd(tree, rbrace);

        const body_indent = firstBodyIndent(inner);
        const strip_n = if (body_indent > outer_indent.len) body_indent - outer_indent.len else 0;

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(ctx.gpa);
        try buf.appendSlice(ctx.gpa, term);
        try dedentInto(ctx.gpa, &buf, inner, strip_n);
        const trimmed = std.mem.trimEnd(u8, buf.items, " \t\n");
        buf.shrinkRetainingCapacity(trimmed.len);
        if (buf.items.len == 0) {
            buf.deinit(ctx.gpa);
            return .{ .start = span_start, .end = span_end, .replacement = "" };
        }
        return .{
            .start = span_start,
            .end = span_end,
            .replacement = try buf.toOwnedSlice(ctx.gpa),
        };
    }

    // else-if OR braceless else: keep `else_expr` verbatim on a new line at the
    // outer indent (its body is already correctly indented / it is a single expr).
    const else_first = tree.firstToken(else_expr);
    const else_last = tree.lastToken(else_expr);
    const else_text = src[tree.tokenStart(else_first)..tokenEnd(tree, else_last)];
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(ctx.gpa);
    try buf.appendSlice(ctx.gpa, term);
    try buf.append(ctx.gpa, '\n');
    try buf.appendSlice(ctx.gpa, outer_indent);
    try buf.appendSlice(ctx.gpa, else_text);
    return .{
        .start = span_start,
        .end = tokenEnd(tree, else_last),
        .replacement = try buf.toOwnedSlice(ctx.gpa),
    };
}

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        const full = tree.fullIf(node) orelse continue;
        if (full.ast.else_expr.unwrap() == null) continue;
        if (!endsInJump(tree, full.ast.then_expr)) continue;
        const start = tree.tokenStart(full.else_token);
        const end = start + tree.tokenSlice(full.else_token).len;
        const msg = "redundant else after a branch that always returns, breaks, or continues";
        if (try computeFix(ctx, full)) |fr| {
            errdefer if (fr.replacement.len > 0) ctx.gpa.free(fr.replacement);
            try ctx.reportWithFix(.{
                .start_offset = start,
                .end_offset = end,
                .fix = .{
                    .start = fr.start,
                    .end = fr.end,
                    .replacement = fr.replacement,
                    .title = "remove redundant else",
                },
            }, msg, .{});
        } else {
            try ctx.report(start, end, msg, .{});
        }
    }
}

test "flags else after a returning then-branch" {
    const gpa = std.testing.allocator;
    const s =
        \\pub fn f(x: bool) u8 {
        \\    if (x) {
        \\        return 1;
        \\    } else {
        \\        return 2;
        \\    }
        \\}
        \\
    ;
    var src = try Source.loadFromSlice(gpa, "t.zig", s);
    defer src.deinit(gpa);
    var cfg = Config.default();
    var diags: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diags.items) |d| d.deinit(gpa);
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
}

test "stays silent on an if with no else" {
    const gpa = std.testing.allocator;
    const s =
        \\pub fn f(x: bool) u8 {
        \\    if (x) {
        \\        return 1;
        \\    }
        \\    return 2;
        \\}
        \\
    ;
    var src = try Source.loadFromSlice(gpa, "t.zig", s);
    defer src.deinit(gpa);
    var cfg = Config.default();
    var diags: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diags.items) |d| d.deinit(gpa);
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

test "stays silent when the then-branch does not jump" {
    const gpa = std.testing.allocator;
    const s =
        \\pub fn f(x: bool) void {
        \\    if (x) {
        \\        doThing();
        \\    } else {
        \\        other();
        \\    }
        \\}
        \\
    ;
    var src = try Source.loadFromSlice(gpa, "t.zig", s);
    defer src.deinit(gpa);
    var cfg = Config.default();
    var diags: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diags.items) |d| d.deinit(gpa);
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

test "stays silent when the then-branch ends in a labeled break (if-expression blocks)" {
    const gpa = std.testing.allocator;
    const s =
        \\pub fn f(x: bool) u8 {
        \\    const v = if (x) blk: {
        \\        break :blk @as(u8, 1);
        \\    } else blk: {
        \\        break :blk @as(u8, 2);
        \\    };
        \\    return v;
        \\}
        \\
    ;
    var src = try Source.loadFromSlice(gpa, "t.zig", s);
    defer src.deinit(gpa);
    var cfg = Config.default();
    var diags: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diags.items) |d| d.deinit(gpa);
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
    // The `else` here is mandatory -- the `if` is an expression assigned to
    // `v`, and the labeled `break :blk` yields the block's value rather than
    // unconditionally escaping. Removing the `else` would be a compile
    // error, so this must stay silent.
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "still flags a plain unlabeled break as a redundant-making jump" {
    const gpa = std.testing.allocator;
    const s =
        \\pub fn f(cond: bool, x: bool) void {
        \\    while (cond) {
        \\        if (x) {
        \\            break;
        \\        } else {
        \\            foo();
        \\        }
        \\    }
        \\}
        \\
    ;
    var src = try Source.loadFromSlice(gpa, "t.zig", s);
    defer src.deinit(gpa);
    var cfg = Config.default();
    var diags: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diags.items) |d| d.deinit(gpa);
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
}

test "stays silent when a jump is nested inside the then-block, not its last statement" {
    const gpa = std.testing.allocator;
    const s =
        \\pub fn f(x: bool, y: bool) u8 {
        \\    if (x) {
        \\        if (y) {
        \\            return 1;
        \\        }
        \\        doThing();
        \\    } else {
        \\        return 2;
        \\    }
        \\}
        \\
    ;
    var src = try Source.loadFromSlice(gpa, "t.zig", s);
    defer src.deinit(gpa);
    var cfg = Config.default();
    var diags: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diags.items) |d| d.deinit(gpa);
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
    // The outer if's then-branch last statement is `doThing();`, not a jump,
    // so the outer else must stay silent. The inner if has no else at all,
    // so it can't fire either.
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

/// Runs the lint on `src_text` and returns the source with the FIRST
/// diagnostic's fix applied (or the original text if there was no fix), plus
/// whether a fix was present. The caller owns the returned bytes.
fn applyFirstFix(
    gpa: std.mem.Allocator,
    src_text: []const u8,
) !struct { text: []u8, had_fix: bool } {
    var src = try Source.loadFromSlice(gpa, "t.zig", src_text);
    defer src.deinit(gpa);
    var cfg = Config.default();
    var diags: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diags.items) |d| d.deinit(gpa);
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
    if (diags.items.len == 0 or diags.items[0].fix == null) {
        return .{ .text = try gpa.dupe(u8, src_text), .had_fix = false };
    }
    const f = diags.items[0].fix.?;
    const out = try std.mem.concat(gpa, u8, &.{
        src_text[0..f.start],
        f.replacement,
        src_text[f.end..],
    });
    return .{ .text = out, .had_fix = true };
}

fn expectFixParses(gpa: std.mem.Allocator, after: []const u8) !void {
    const z = try gpa.dupeSentinel(u8, after, 0);
    defer gpa.free(z);
    var t = try std.zig.Ast.parse(gpa, z, .{});
    defer t.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), t.errors.len);
}

test "fix: braced else dedents the body to the outer scope" {
    const gpa = std.testing.allocator;
    const s =
        "pub fn f(x: bool) u8 {\n" ++
        "    if (x) {\n        return 1;\n    } else {\n        return 2;\n    }\n}\n";
    const r = try applyFirstFix(gpa, s);
    defer gpa.free(r.text);
    try std.testing.expect(r.had_fix);
    try std.testing.expectEqualStrings(
        "pub fn f(x: bool) u8 {\n" ++
            "    if (x) {\n        return 1;\n    }\n    return 2;\n}\n",
        r.text,
    );
    try expectFixParses(gpa, r.text);
}

test "fix: else-if becomes a standalone if" {
    const gpa = std.testing.allocator;
    const s =
        "pub fn f(x: bool, y: bool) u8 {\n" ++
        "    if (x) {\n        return 1;\n    } else if (y) {\n" ++
        "        return 2;\n    }\n    return 3;\n}\n";
    const r = try applyFirstFix(gpa, s);
    defer gpa.free(r.text);
    try std.testing.expect(r.had_fix);
    try std.testing.expectEqualStrings(
        "pub fn f(x: bool, y: bool) u8 {\n" ++
            "    if (x) {\n        return 1;\n    }\n    if (y) {\n" ++
            "        return 2;\n    }\n    return 3;\n}\n",
        r.text,
    );
    try expectFixParses(gpa, r.text);
}

test "fix: braceless then + braceless else inserts a terminator" {
    const gpa = std.testing.allocator;
    const s =
        "pub fn f(x: bool) u8 {\n" ++
        "    if (x) return 1 else return 2;\n}\n";
    const r = try applyFirstFix(gpa, s);
    defer gpa.free(r.text);
    try std.testing.expect(r.had_fix);
    try std.testing.expectEqualStrings(
        "pub fn f(x: bool) u8 {\n" ++
            "    if (x) return 1;\n    return 2;\n}\n",
        r.text,
    );
    try expectFixParses(gpa, r.text);
}

test "fix: braced else that declares a local is NOT fixed (scope-hoist guard)" {
    const gpa = std.testing.allocator;
    const s =
        "pub fn f(x: bool) u8 {\n" ++
        "    if (x) {\n        return 1;\n    } else {\n" ++
        "        const y: u8 = 2;\n        return y;\n    }\n}\n";
    const r = try applyFirstFix(gpa, s);
    defer gpa.free(r.text);
    try std.testing.expect(!r.had_fix); // warning still fires, but no fix attached
}

test "fix: redundant_else owned replacement round-trips through a diag list without leaking" {
    const gpa = std.testing.allocator;
    // The whole test runs under std.testing.allocator, so a leaked or
    // double-freed owned replacement fails it. applyFirstFix frees via deinit.
    const s = "pub fn f(x: bool) u8 {\n    if (x) {\n        return 1;\n    } else {\n" ++
        "        return 2;\n    }\n}\n";
    const r = try applyFirstFix(gpa, s);
    defer gpa.free(r.text);
    try std.testing.expect(r.had_fix);
}

test "fix: a redundant_else offers an LSP quickfix titled 'remove redundant else'" {
    const gpa = std.testing.allocator;
    const documents = @import("../lsp/documents.zig");
    var docs = documents.Documents.init(std.testing.io, gpa);
    defer docs.deinit();
    try docs.open(
        "file:///t.zig",
        "pub fn f(x: bool) u8 {\n    if (x) {\n        return 1;\n" ++
            "    } else {\n        return 2;\n    }\n}\n",
    );
    const doc = docs.get("file:///t.zig").?;
    try docs.lint(doc);
    // A range covering the whole document catches the else's squiggle span.
    const cands = try documents.codeActionsAt(gpa, doc, 0, @intCast(doc.text.len));
    defer gpa.free(cands);
    var found = false;
    for (cands) |c| if (std.mem.eql(u8, c.title, "remove redundant else")) {
        found = true;
    };
    try std.testing.expect(found);
}

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

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @enumFromInt(idx);
        const full = tree.fullIf(node) orelse continue;
        if (full.ast.else_expr.unwrap() == null) continue;
        if (!endsInJump(tree, full.ast.then_expr)) continue;
        const start = tree.tokenStart(full.else_token);
        const end = start + tree.tokenSlice(full.else_token).len;
        try ctx.report(
            start,
            end,
            "redundant else after a branch that always returns, breaks, or continues",
            .{},
        );
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
    // The outer if's then-branch last statement is `doThing();`, not a jump,
    // so the outer else must stay silent. The inner if has no else at all,
    // so it can't fire either.
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

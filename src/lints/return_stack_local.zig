//! Flags `return &x;` where `x` names a `var`/`const` declared local to the
//! SAME innermost function as the `return` -- that pointer addresses a stack
//! frame the function is about to tear down, so it dangles the instant the
//! caller gets it back.
//!
//! Detection is conservative and identifier-only: the return operand must be
//! `&<identifier>` (an `.address_of` over an `.identifier`), and that name
//! must match a `var`/`const` declared inside the enclosing `fn_decl`'s own
//! token range. Zig forbids shadowing, so a name that matches a fn-local
//! decl in scope IS that local -- there is no other declaration it could
//! resolve to -- which makes the name-match sound rather than a heuristic.
//!
//! Deliberately silent (false-negative biased, per IronStyle) on:
//!   - `&self.field` / `&x.y` -- a `.field_access`, not a bare `.identifier`,
//!     so this never even reaches the local-decl check. Field storage may
//!     outlive the function (e.g. `self` is heap-allocated), so flagging it
//!     would risk real false positives.
//!   - `&param` -- a parameter isn't a `var`/`const` decl inside the fn body,
//!     so `localDeclInRange` won't find it; params are never flagged.
//!   - `&global` -- same reasoning: no matching local decl inside the fn's
//!     own token range, so a same-named global/outer const is left alone.
//!   - `const p = &v; return p;` (an indirect return through an intermediate
//!     pointer variable) -- the return operand is `p`, not `&v`, so the
//!     `.address_of` check never fires at all. Catching this would need
//!     data-flow tracking beyond a single-node check; missing it is an
//!     accepted false negative, not a false positive risk.
const std = @import("std");
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Ast = std.zig.Ast;

pub const name = "return_stack_local";
pub const group: Config.Group = .memory;
pub const description: []const u8 =
    "Returning `&x` where `x` is a function-local variable yields a pointer " ++
    "into a stack frame destroyed on return -- it dangles immediately. Return " ++
    "the value, or allocate it with a passed allocator.";

/// The innermost `fn_decl` whose token range contains `tok`, or null if `tok`
/// isn't inside any function. "Innermost" = smallest containing range, so a
/// nested fn wins over its encloser.
fn innermostFn(tree: *const Ast, tok: Ast.TokenIndex) ?Ast.Node.Index {
    var best: ?Ast.Node.Index = null;
    var best_span: u32 = std.math.maxInt(u32);
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @enumFromInt(idx);
        if (tree.nodeTag(node) != .fn_decl) continue;
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        if (first <= tok and tok <= last and (last - first) < best_span) {
            best_span = last - first;
            best = node;
        }
    }
    return best;
}

/// The innermost scope-defining node -- a `fn_decl` OR a container decl
/// (struct/union/enum/opaque) -- whose token range contains `tok`, or null.
/// A plain block is NOT scope-defining, so a decl inside an `if`/`while` block
/// still resolves to its enclosing function. Used to tell a function's real
/// stack local apart from a nested container's MEMBER that merely reuses the
/// same name (Zig's no-shadowing rule permits a nested container member to
/// reuse a file-scope name, so a token-range check alone misattributes
/// `return &<global>` as a stack local -- a false positive).
fn innermostScope(tree: *const Ast, tok: Ast.TokenIndex) ?Ast.Node.Index {
    var buf: [2]Ast.Node.Index = undefined;
    var best: ?Ast.Node.Index = null;
    var best_span: u32 = std.math.maxInt(u32);
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @enumFromInt(idx);
        const is_scope = tree.nodeTag(node) == .fn_decl or
            tree.fullContainerDecl(&buf, node) != null;
        if (!is_scope) continue;
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        if (first <= tok and tok <= last and (last - first) < best_span) {
            best_span = last - first;
            best = node;
        }
    }
    return best;
}

/// True if a `var`/`const` named `ident` is a stack LOCAL of `fn_node` -- its
/// name-token is inside `fn_node`'s range AND its innermost scope is `fn_node`
/// itself (not a nested container member or nested-fn local). See
/// `innermostScope` for why the scope check is needed.
fn localDeclInRange(tree: *const Ast, ident: []const u8, fn_node: Ast.Node.Index) bool {
    const first = tree.firstToken(fn_node);
    const last = tree.lastToken(fn_node);
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @enumFromInt(idx);
        const decl = tree.fullVarDecl(node) orelse continue;
        const name_tok = decl.ast.mut_token + 1;
        if (name_tok < first or name_tok > last) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(name_tok), ident)) continue;
        if (innermostScope(tree, name_tok)) |scope| {
            if (scope == fn_node) return true;
        }
    }
    return false;
}

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @enumFromInt(idx);
        if (tree.nodeTag(node) != .@"return") continue;
        const operand = tree.nodeData(node).opt_node.unwrap() orelse continue;
        if (tree.nodeTag(operand) != .address_of) continue;
        const addr_operand = tree.nodeData(operand).node;
        if (tree.nodeTag(addr_operand) != .identifier) continue;
        const ident = tree.tokenSlice(tree.firstToken(addr_operand));

        // Only a var/const local to the function that contains this return is
        // a stack address; a param/global/field is not (see the file doc).
        const fn_node = innermostFn(tree, tree.firstToken(node)) orelse continue;
        if (!localDeclInRange(tree, ident, fn_node))
            continue;

        // Point the diagnostic at the whole `&x` operand.
        const start = tree.tokenStart(tree.firstToken(operand));
        const last_tok = tree.lastToken(operand);
        const end = tree.tokenStart(last_tok) + @as(u32, @intCast(tree.tokenSlice(last_tok).len));
        try ctx.report(
            start,
            end,
            "returns a pointer to stack local '{s}' (dangles after the function returns)",
            .{ident},
        );
    }
}

fn countDiags(gpa: std.mem.Allocator, src_text: []const u8) !usize {
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
        .current_severity = .@"error",
    };
    try run(&ctx);
    return diags.items.len;
}

test "flags return of a pointer to a local const" {
    try std.testing.expectEqual(@as(usize, 1), try countDiags(
        std.testing.allocator,
        "pub fn f() *const u8 {\n    const v: u8 = 0;\n    return &v;\n}\n",
    ));
}
test "flags return of a pointer to a local var" {
    try std.testing.expectEqual(@as(usize, 1), try countDiags(
        std.testing.allocator,
        "pub fn f() *u8 {\n    var v: u8 = 0;\n    v += 1;\n    return &v;\n}\n",
    ));
}
test "does not flag return of &self.field (field access, not identifier)" {
    try std.testing.expectEqual(@as(usize, 0), try countDiags(
        std.testing.allocator,
        "const S = struct { x: u8, pub fn p(self: *S) *u8 { return &self.x; } };\n",
    ));
}
test "does not flag return of &param" {
    try std.testing.expectEqual(@as(usize, 0), try countDiags(
        std.testing.allocator,
        "pub fn f(p: u8) *const u8 {\n    return &p;\n}\n",
    ));
}
test "does not flag a normal value return" {
    try std.testing.expectEqual(@as(usize, 0), try countDiags(
        std.testing.allocator,
        "pub fn f() u8 {\n    const v: u8 = 0;\n    return v;\n}\n",
    ));
}
test "does not flag an indirect return (const p = &v; return p)" {
    try std.testing.expectEqual(@as(usize, 0), try countDiags(
        std.testing.allocator,
        "pub fn f() *const u8 {\n    const v: u8 = 0;\n    const p = &v;\n    return p;\n}\n",
    ));
}
test "does not flag &global when a nested struct member reuses the name (final-review FP)" {
    try std.testing.expectEqual(@as(usize, 0), try countDiags(
        std.testing.allocator,
        "const v: u8 = 9;\npub fn f() *const u8 {\n" ++
            "    const S = struct { const v: u8 = 0; };\n    _ = S;\n    return &v;\n}\n",
    ));
}

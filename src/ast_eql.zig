//! Conservative structural-equality comparator for AST subtrees: `eql` answers
//! whether two `std.zig.Ast` nodes are, syntactically, "the same expression".
//! Reusable infra for any lint that wants to spot duplicated code without
//! re-implementing tree-walking (first consumer: `duplicate_case`).
//!
//! CONSERVATIVE BY CONSTRUCTION (the IronStyle guarantee): `eqlInner` is a
//! WHITELIST `switch` over node tags. Any tag it does not explicitly handle
//! falls to `else => false`, so this can never claim two subtrees are equal
//! when it doesn't understand their shape -- only false negatives (missed
//! duplicates) are possible, never a false "equal". Prefer ADDING a tag later
//! over loosening this default.
//!
//! Two binary-operator groups get different treatment:
//!   - COMMUTATIVE ops (`+ * & | == !=`) are REFLEXIVE: `a op b` compares
//!     equal to `b op a` (either operand pairing may match).
//!   - `- / %` are compared POSITIONALLY (lhs~lhs, rhs~rhs) only -- and
//!     `and`/`or` aren't handled at all, since short-circuiting makes operand
//!     order observable, not just a presentation choice.
//!
//! Ported from zlint's `visit/AstComparator.zig` (DonIsaac, MIT) -- reworked
//! from a struct-with-methods (`AstComparator{ .ast = tree }`) into a plain
//! recursive function that threads `tree` explicitly, with the four block
//! tags collapsed into one case (Zippy's `blockStatements` already dispatches
//! `.block`/`.block_semicolon`/`.block_two`/`.block_two_semicolon` itself),
//! and the `.@"if"` else-branch presence check folded into `maybeNodesEql`
//! instead of a separate token-zero check (Zippy's `Node.OptionalIndex`
//! already encodes absence, so a second check would be redundant).
const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;

/// Structural equality of subtrees `a` and `b` within `tree`. A same-index
/// fast path, then a tag mismatch is an immediate `false`; otherwise this
/// dispatches into the whitelist switch below.
pub fn eql(tree: *const Ast, a: Node.Index, b: Node.Index) bool {
    if (a == b) return true;
    if (tree.nodeTag(a) != tree.nodeTag(b)) return false;
    return eqlInner(tree, a, b);
}

/// The whitelist switch. Callers (`eql`, and every helper below when it
/// recurses into a child pair) always go back through `eql`, so by the time
/// this runs `tree.nodeTag(a) == tree.nodeTag(b)` is already established --
/// this only needs to switch on `a`'s tag.
fn eqlInner(tree: *const Ast, a: Node.Index, b: Node.Index) bool {
    return switch (tree.nodeTag(a)) {
        .number_literal,
        .string_literal,
        .enum_literal,
        .char_literal,
        .identifier,
        => mainTokensEql(tree, a, b),

        .add, .mul, .bit_and, .bit_or, .equal_equal, .bang_equal => binReflexive(tree, a, b),
        .sub, .div, .mod => binOrdered(tree, a, b),

        .negation, .negation_wrap, .bit_not, .address_of, .@"defer" => eqlNode(tree, a, b),

        .field_access => eqlFieldAccess(tree, a, b),
        .call, .call_comma, .call_one, .call_one_comma => eqlCall(tree, a, b),
        .block, .block_semicolon, .block_two, .block_two_semicolon => eqlBlock(tree, a, b),
        .if_simple => eqlIfSimple(tree, a, b),
        .@"if" => eqlIf(tree, a, b),
        .@"return" => eqlReturn(tree, a, b),
        .unwrap_optional => eqlUnwrapOptional(tree, a, b),
        .local_var_decl, .simple_var_decl, .aligned_var_decl => eqlVarDecl(tree, a, b),

        .unreachable_literal, .root => true,

        else => false,
    };
}

/// `lhs.field` -- the field-name token and the object subtree must both match.
fn eqlFieldAccess(tree: *const Ast, a: Node.Index, b: Node.Index) bool {
    const obj_a, const field_a = tree.nodeData(a).node_and_token;
    const obj_b, const field_b = tree.nodeData(b).node_and_token;
    if (!tokensEql(tree, field_a, field_b)) return false;
    return eql(tree, obj_a, obj_b);
}

/// `f(...)` in any of its four AST shapes -- callee and, pairwise, every
/// argument must match (an argument-count mismatch fails the length check
/// inside `allEql` before any pairwise comparison runs).
fn eqlCall(tree: *const Ast, a: Node.Index, b: Node.Index) bool {
    var buf_a: [1]Node.Index = undefined;
    var buf_b: [1]Node.Index = undefined;
    const call_a = tree.fullCall(&buf_a, a) orelse return false;
    const call_b = tree.fullCall(&buf_b, b) orelse return false;
    if (!eql(tree, call_a.ast.fn_expr, call_b.ast.fn_expr)) return false;
    return allEql(tree, call_a.ast.params, call_b.ast.params);
}

/// Any block shape -- `blockStatements` already dispatches all four tags, so
/// one case covers `.block`/`.block_semicolon`/`.block_two`/
/// `.block_two_semicolon` uniformly; an empty-vs-nonempty statement list
/// fails the length check inside `allEql`.
fn eqlBlock(tree: *const Ast, a: Node.Index, b: Node.Index) bool {
    var buf_a: [2]Node.Index = undefined;
    var buf_b: [2]Node.Index = undefined;
    const stmts_a = tree.blockStatements(&buf_a, a) orelse return false;
    const stmts_b = tree.blockStatements(&buf_b, b) orelse return false;
    return allEql(tree, stmts_a, stmts_b);
}

/// `if (cond) then` / `if (cond) |x| then` -- no `else`, so only the
/// condition, the then-branch, and an optional else (present in neither, by
/// definition of this tag) need to line up.
fn eqlIfSimple(tree: *const Ast, a: Node.Index, b: Node.Index) bool {
    const if_a = tree.ifSimple(a);
    const if_b = tree.ifSimple(b);
    // Compare the capture name too, consistent with `eqlIf` -- an `if_simple`
    // can still carry a payload capture (`if (o) |v| then`, no `else`).
    if (!maybeTokensEql(tree, if_a.payload_token, if_b.payload_token)) return false;
    if (!eql(tree, if_a.ast.cond_expr, if_b.ast.cond_expr)) return false;
    if (!eql(tree, if_a.ast.then_expr, if_b.ast.then_expr)) return false;
    return maybeNodesEql(tree, if_a.ast.else_expr, if_b.ast.else_expr);
}

/// `if (cond) then else other`, in its payload/error-payload variants. The
/// optional capture tokens' NAMES must match too -- `if (x) |v| v else 0`
/// and `if (x) |w| w else 0` are not the same expression under a rename.
fn eqlIf(tree: *const Ast, a: Node.Index, b: Node.Index) bool {
    const if_a = tree.fullIf(a).?;
    const if_b = tree.fullIf(b).?;
    if (!maybeTokensEql(tree, if_a.payload_token, if_b.payload_token)) return false;
    if (!maybeTokensEql(tree, if_a.error_token, if_b.error_token)) return false;
    if (!eql(tree, if_a.ast.cond_expr, if_b.ast.cond_expr)) return false;
    if (!eql(tree, if_a.ast.then_expr, if_b.ast.then_expr)) return false;
    return maybeNodesEql(tree, if_a.ast.else_expr, if_b.ast.else_expr);
}

/// `return expr` / `return` -- the data is a single optional node.
fn eqlReturn(tree: *const Ast, a: Node.Index, b: Node.Index) bool {
    return maybeNodesEql(tree, tree.nodeData(a).opt_node, tree.nodeData(b).opt_node);
}

/// `lhs.?` -- only the operand (index 0 of `node_and_token`) matters; the
/// `?` token itself carries no information worth comparing.
fn eqlUnwrapOptional(tree: *const Ast, a: Node.Index, b: Node.Index) bool {
    const node_a, _ = tree.nodeData(a).node_and_token;
    const node_b, _ = tree.nodeData(b).node_and_token;
    return eql(tree, node_a, node_b);
}

/// `const`/`var` decls in their three plain (non-container-field) shapes.
/// Every side of the declaration that could change its meaning is checked:
/// the declared name, `pub`/`extern`/`comptime` modifiers, and the optional
/// type/align/linksection/addrspace/init subtrees.
fn eqlVarDecl(tree: *const Ast, a: Node.Index, b: Node.Index) bool {
    const decl_a = tree.fullVarDecl(a) orelse return false;
    const decl_b = tree.fullVarDecl(b) orelse return false;
    // The `mut_token` (`const` vs `var`) IS `nodeMainToken`; the name is the
    // token right after it. Both must match -- without the `mut_token` check,
    // `const x = 1` and `var x = 1` would compare equal (a false "equal").
    if (!tokensEql(tree, decl_a.ast.mut_token, decl_b.ast.mut_token)) return false;
    if (!tokensEql(tree, decl_a.ast.mut_token + 1, decl_b.ast.mut_token + 1)) return false;
    if (!maybeTokensEql(tree, decl_a.visib_token, decl_b.visib_token)) return false;
    if (!maybeTokensEql(tree, decl_a.lib_name, decl_b.lib_name)) return false;
    if (!maybeTokensEql(tree, decl_a.threadlocal_token, decl_b.threadlocal_token)) return false;
    if (!maybeTokensEql(tree, decl_a.comptime_token, decl_b.comptime_token)) return false;
    if (!maybeTokensEql(tree, decl_a.extern_export_token, decl_b.extern_export_token)) {
        return false;
    }
    if (!maybeNodesEql(tree, decl_a.ast.type_node, decl_b.ast.type_node)) return false;
    if (!maybeNodesEql(tree, decl_a.ast.align_node, decl_b.ast.align_node)) return false;
    if (!maybeNodesEql(tree, decl_a.ast.section_node, decl_b.ast.section_node)) return false;
    if (!maybeNodesEql(tree, decl_a.ast.addrspace_node, decl_b.ast.addrspace_node)) return false;
    return maybeNodesEql(tree, decl_a.ast.init_node, decl_b.ast.init_node);
}

/// `.negation`/`.negation_wrap`/`.bit_not`/`.address_of`/`.@"defer"` all
/// store a single `.node` operand -- recurse into it.
fn eqlNode(tree: *const Ast, a: Node.Index, b: Node.Index) bool {
    return eql(tree, tree.nodeData(a).node, tree.nodeData(b).node);
}

/// `lhs op rhs` for `- / %`: order matters, so lhs must match lhs and rhs
/// must match rhs.
fn binOrdered(tree: *const Ast, a: Node.Index, b: Node.Index) bool {
    const lhs_a, const rhs_a = tree.nodeData(a).node_and_node;
    const lhs_b, const rhs_b = tree.nodeData(b).node_and_node;
    return eql(tree, lhs_a, lhs_b) and eql(tree, rhs_a, rhs_b);
}

/// `lhs op rhs` for the commutative set `+ * & | == !=`: either operand
/// pairing may match (`a.lhs~b.lhs and a.rhs~b.rhs`, OR crossed).
fn binReflexive(tree: *const Ast, a: Node.Index, b: Node.Index) bool {
    const lhs_a, const rhs_a = tree.nodeData(a).node_and_node;
    const lhs_b, const rhs_b = tree.nodeData(b).node_and_node;
    if (eql(tree, lhs_a, lhs_b)) return eql(tree, rhs_a, rhs_b);
    return eql(tree, lhs_a, rhs_b) and eql(tree, rhs_a, lhs_b);
}

/// Pairwise structural equality of two node slices; a length mismatch is an
/// immediate `false` before any element is compared.
fn allEql(tree: *const Ast, a: []const Node.Index, b: []const Node.Index) bool {
    if (a.len != b.len) return false;
    for (a, b) |node_a, node_b| {
        if (!eql(tree, node_a, node_b)) return false;
    }
    return true;
}

/// Two nodes whose whole meaning is a single token (a literal or an
/// identifier) compare equal iff that token's source text does.
fn mainTokensEql(tree: *const Ast, a: Node.Index, b: Node.Index) bool {
    return tokensEql(tree, tree.nodeMainToken(a), tree.nodeMainToken(b));
}

/// Raw token-text equality.
fn tokensEql(tree: *const Ast, a: TokenIndex, b: TokenIndex) bool {
    return std.mem.eql(u8, tree.tokenSlice(a), tree.tokenSlice(b));
}

/// Both-absent-or-both-present-and-equal, for an optional token (e.g. an
/// `if`'s capture-payload token).
fn maybeTokensEql(tree: *const Ast, a: ?TokenIndex, b: ?TokenIndex) bool {
    if ((a == null) != (b == null)) return false;
    return if (a) |token_a| tokensEql(tree, token_a, b.?) else true;
}

/// Both-absent-or-both-present-and-structurally-equal, for an optional node
/// (e.g. a var decl's init expression, or an `if`'s else branch).
fn maybeNodesEql(tree: *const Ast, a: Node.OptionalIndex, b: Node.OptionalIndex) bool {
    const node_a = a.unwrap();
    const node_b = b.unwrap();
    if ((node_a == null) != (node_b == null)) return false;
    return if (node_a) |na| eql(tree, na, node_b.?) else true;
}

const Source = @import("Source.zig");

/// The first two `const`/`var` decls' init-expression nodes found while
/// scanning `tree` forward by node index. Zig's parser is a single
/// left-to-right recursive-descent pass, so for a snippet written as
/// `const a = ...; const b = ...;` the node for `a`'s subtree is always
/// finished (and thus indexed) before `b`'s begins -- this is the same
/// forward-scan-is-source-order assumption every other Zippy lint already
/// relies on (see e.g. `param_ordering.zig`, `redundant_else.zig`).
fn firstTwoVarDeclInits(tree: *const Ast) [2]Node.Index {
    var found: [2]Node.Index = undefined;
    var count: usize = 0;
    var idx: u32 = 0;
    while (idx < tree.nodes.len and count < 2) : (idx += 1) {
        const node: Node.Index = @fromBackingInt(@intCast(idx));
        const decl = tree.fullVarDecl(node) orelse continue;
        found[count] = decl.ast.init_node.unwrap().?;
        count += 1;
    }
    return found;
}

/// Parses `src_text` (expected to declare exactly `const a = ...; const b =
/// ...;` inside a function body) and asserts `eql` on their init expressions
/// matches `want`.
fn expectEqlSrc(gpa: std.mem.Allocator, src_text: []const u8, want: bool) !void {
    var src = try Source.loadFromSlice(gpa, "t.zig", src_text);
    defer src.deinit(gpa);
    const nodes = firstTwoVarDeclInits(&src.ast);
    try std.testing.expectEqual(want, eql(&src.ast, nodes[0], nodes[1]));
}

/// The first `.@"if"` node's `Ast.full.If` found while scanning forward.
fn firstIfWithElse(tree: *const Ast) Ast.full.If {
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Node.Index = @fromBackingInt(@intCast(idx));
        if (tree.nodeTag(node) == .@"if") return tree.fullIf(node).?;
    }
    unreachable;
}

test "identical literals and identifiers compare equal" {
    const gpa = std.testing.allocator;
    try expectEqlSrc(gpa, "pub fn t() void { const a = 1; const b = 1; }\n", true);
    try expectEqlSrc(gpa, "pub fn t() void { const a = y; const b = y; }\n", true);
}

test "different literals and identifiers compare unequal" {
    const gpa = std.testing.allocator;
    try expectEqlSrc(gpa, "pub fn t() void { const a = 1; const b = 2; }\n", false);
    try expectEqlSrc(gpa, "pub fn t() void { const a = y; const b = z; }\n", false);
}

test "commutative ops (+ * & | == !=) are reflexive under swapped operands" {
    const gpa = std.testing.allocator;
    try expectEqlSrc(gpa, "pub fn t() void { const a = y + 1; const b = 1 + y; }\n", true);
    try expectEqlSrc(gpa, "pub fn t() void { const a = y * 1; const b = 1 * y; }\n", true);
    try expectEqlSrc(gpa, "pub fn t() void { const a = y & 1; const b = 1 & y; }\n", true);
    try expectEqlSrc(gpa, "pub fn t() void { const a = y | 1; const b = 1 | y; }\n", true);
    try expectEqlSrc(gpa, "pub fn t() void { const a = y == 1; const b = 1 == y; }\n", true);
    try expectEqlSrc(gpa, "pub fn t() void { const a = y != 1; const b = 1 != y; }\n", true);
}

test "non-commutative ops (- / %) stay positional under swapped operands" {
    const gpa = std.testing.allocator;
    try expectEqlSrc(gpa, "pub fn t() void { const a = y - 1; const b = 1 - y; }\n", false);
    try expectEqlSrc(gpa, "pub fn t() void { const a = y / 1; const b = 1 / y; }\n", false);
    try expectEqlSrc(gpa, "pub fn t() void { const a = y % 1; const b = 1 % y; }\n", false);
}

test "field access: same object and field name compare equal" {
    const gpa = std.testing.allocator;
    try expectEqlSrc(gpa, "pub fn t() void { const a = thing.x; const b = thing.x; }\n", true);
}

test "field access: different field name compares unequal" {
    const gpa = std.testing.allocator;
    try expectEqlSrc(gpa, "pub fn t() void { const a = thing.x; const b = thing.y; }\n", false);
}

test "calls: same callee and args compare equal, incl. through field access" {
    const gpa = std.testing.allocator;
    try expectEqlSrc(gpa, "pub fn t() void { const a = f(bar); const b = f(bar); }\n", true);
    try expectEqlSrc(
        gpa,
        "pub fn t() void { const a = thing.f(bar); const b = thing.f(bar); }\n",
        true,
    );
}

test "calls: different callee compares unequal" {
    const gpa = std.testing.allocator;
    try expectEqlSrc(gpa, "pub fn t() void { const a = f(bar); const b = g(bar); }\n", false);
}

test "calls: different arity compares unequal" {
    const gpa = std.testing.allocator;
    try expectEqlSrc(gpa, "pub fn t() void { const a = f(bar); const b = f(bar, bar); }\n", false);
}

test "unary: same operand compares equal" {
    const gpa = std.testing.allocator;
    try expectEqlSrc(gpa, "pub fn t() void { const a = ~y; const b = ~y; }\n", true);
}

test "unwrap_optional: same operand equal, different operand unequal" {
    const gpa = std.testing.allocator;
    try expectEqlSrc(gpa, "pub fn t() void { const a = foo.?; const b = foo.?; }\n", true);
    try expectEqlSrc(gpa, "pub fn t() void { const a = foo.?; const b = bar.?; }\n", false);
}

test "if with else: identical branches equal, swapped branches unequal" {
    const gpa = std.testing.allocator;
    try expectEqlSrc(
        gpa,
        "pub fn t() void { const a = if (c) 1 else 2; const b = if (c) 1 else 2; }\n",
        true,
    );
    try expectEqlSrc(
        gpa,
        "pub fn t() void { const a = if (c) 1 else 2; const b = if (c) 2 else 1; }\n",
        false,
    );
}

test "blocks: identical then/else block bodies compare equal" {
    const gpa = std.testing.allocator;
    const s = "pub fn t() void { if (c) { return 1; } else { return 1; } }\n";
    var src = try Source.loadFromSlice(gpa, "t.zig", s);
    defer src.deinit(gpa);
    const full = firstIfWithElse(&src.ast);
    const else_node = full.ast.else_expr.unwrap().?;
    try std.testing.expect(eql(&src.ast, full.ast.then_expr, else_node));
}

test "blocks: a differently-named var decl inside makes the blocks unequal" {
    const gpa = std.testing.allocator;
    const s = "pub fn t() void { if (c) { const x: u8 = 1; } else { const y: u8 = 1; } }\n";
    var src = try Source.loadFromSlice(gpa, "t.zig", s);
    defer src.deinit(gpa);
    const full = firstIfWithElse(&src.ast);
    const else_node = full.ast.else_expr.unwrap().?;
    try std.testing.expect(!eql(&src.ast, full.ast.then_expr, else_node));
}

test "blocks: a const-vs-var decl (same name/init) makes the blocks unequal" {
    const gpa = std.testing.allocator;
    // Regression: eqlVarDecl must compare the `mut_token`, else `const x` and
    // `var x` (identical otherwise) would be a false "equal".
    const s = "pub fn t() void { if (c) { const x: u8 = 1; } else { var x: u8 = 1; } }\n";
    var src = try Source.loadFromSlice(gpa, "t.zig", s);
    defer src.deinit(gpa);
    const full = firstIfWithElse(&src.ast);
    const else_node = full.ast.else_expr.unwrap().?;
    try std.testing.expect(!eql(&src.ast, full.ast.then_expr, else_node));
}

test "an unhandled node tag never claims equality, even if identical text" {
    const gpa = std.testing.allocator;
    // `.@"orelse"` isn't in the whitelist, so two structurally-identical
    // `orelse` expressions must NOT compare equal -- proves the conservative
    // `else => false` default, not just a positive match.
    const s = "pub fn t() void { const a = x orelse y; const b = x orelse y; }\n";
    try expectEqlSrc(gpa, s, false);
}

//! Flags a `fn` declared to return an error union (`!T`) whose body can
//! NEVER actually produce an error -- the `!` is a dishonest promise that
//! forces every caller to handle (or explicitly discard) an error that will
//! never occur. Ported from zlint's `useless_error_return` (DonIsaac, MIT),
//! reworked to be FAR more conservative: zlint flags `const e = baz(); return
//! e;` even when `baz` is fallible (a real false positive -- `e` really can
//! carry a propagated error there). Zippy only flags when it is CERTAIN the
//! function never errors.
//!
//! ## Detection
//! For each `.fn_decl` (which -- unlike `fn_proto`, an extern declaration --
//! always has a body block) whose declared return type is (or plausibly is)
//! an error union -- `.error_union`-tagged, or the inferred-error-set
//! shorthand `!T` (see `homeless_try`'s file doc for why that `!` never joins
//! the return type node's own token range and has to be found by checking
//! the PRECEDING token) -- but is NOT the explicit empty-set promise
//! `error{}!T` (a deliberate "this never errors" declaration -- skip it, it's
//! already honest): the function is flagged iff NEITHER of these "can-error"
//! signals appears anywhere in ITS OWN body (nested `fn`s excluded, see
//! below):
//!   - a `.@"try"` node.
//!   - a `.@"return"` node whose operand is NOT certainly non-error (see the
//!     allowlist below).
//! A suppressing `x() catch @panic(...)`/`x() catch unreachable` falls out of
//! this for free: it has neither a `try` nor a `return`, so a function
//! consisting only of one still flags -- matching zlint's second diagnostic
//! ("suppresses all errors") without needing separate detection.
//!
//! CERTAINLY-NON-ERROR return operand (this is an ALLOWLIST -- anything not
//! on it is conservatively treated as "might carry an error"): no operand at
//! all (`return;`), or the operand's tag is a literal that can never itself
//! be an error value -- a number/string/char/multiline-string/enum literal,
//! or a struct/array initializer (`.{ ... }`, `[_]T{ ... }`, in every
//! `fullX`-recognized shape). An identifier, a call, a field access, an
//! `if`/`switch`/`orelse`/`catch`/block, a builtin call, or a nested `try`
//! all fall through to "might propagate" -- e.g. `return v;`, `return
//! baz();`, and `return if (c) error.X else .{};` all suppress the flag.
//!
//! NESTED-FN EXCLUSION: a `try`/`return` only counts for THIS function if its
//! nearest enclosing `.function` scope (walked via `sema.iterParents`) IS
//! this function's own scope. Without the semantic layer this couldn't be
//! told apart from a `try` that lives lexically inside the body but actually
//! belongs to a `fn` declared inline inside it (e.g. a helper method on an
//! anonymous `struct` literal) -- that inner `try` has nothing to do with
//! whether the OUTER function ever errors.
//!
//! Reports at the function's name token (`fullFnProto.name_token`; a
//! malformed/nameless proto is skipped). Not fixable: dropping the `!` can
//! require editing every call site too, out of scope for an automatic fix.
const std = @import("std");
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Semantic = @import("../Semantic.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Ast = std.zig.Ast;

pub const name = "useless_error_return";
pub const group: Config.Group = .style;
pub const description: []const u8 =
    "A function declared to return an error union (`!T`) whose body can " ++
    "never actually produce an error -- no `try` and every `return`'s " ++
    "operand is certainly non-error. The `!` forces every caller to " ++
    "handle an error that will never happen; drop it.";

const flag_msg = "function returns an error union but never returns an error; drop the `!`";

/// Whether `return_type` is (or plausibly is) an error union, using ONLY the
/// two exact syntactic checks (never the name-heuristic/alias-resolution
/// ones `homeless_try` also uses) -- see the file doc for why: missing a
/// real error union here just means this function is skipped (safe), while
/// over-detecting one would risk flagging a function that never had a real
/// `!` to drop in the first place.
fn isErrorUnionReturn(tree: *const Ast, return_type: Ast.Node.Index) bool {
    if (tree.nodeTag(return_type) == .error_union) return true;
    const first_tok = tree.firstToken(return_type);
    return first_tok > 0 and tree.tokenTag(first_tok - 1) == .bang;
}

/// Whether `return_type` is the explicit empty-set promise `error{}!T` -- a
/// deliberate "this function never errors" declaration that's already
/// honest, so it's excluded rather than flagged.
fn isExplicitEmptyErrorSet(tree: *const Ast, return_type: Ast.Node.Index) bool {
    if (tree.nodeTag(return_type) != .error_union) return false;
    const lhs = tree.nodeData(return_type).node_and_node[0];
    if (tree.nodeTag(lhs) != .error_set_decl) return false;
    const braces = tree.nodeData(lhs).token_and_token;
    return braces[1] == braces[0] + 1;
}

/// See the file doc's allowlist. `ret_node` is a `.@"return"` node.
fn isCertainlyNonError(tree: *const Ast, ret_node: Ast.Node.Index) bool {
    const operand = tree.nodeData(ret_node).opt_node.unwrap() orelse return true;
    return switch (tree.nodeTag(operand)) {
        .number_literal,
        .string_literal,
        .char_literal,
        .multiline_string_literal,
        .enum_literal,
        .struct_init_one,
        .struct_init_one_comma,
        .struct_init,
        .struct_init_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .array_init_one,
        .array_init_one_comma,
        .array_init,
        .array_init_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        => true,
        else => false,
    };
}

/// The `.function`-kind scope `node` lives in, walking outward past any
/// `block`/`loop`/`comptime_`/`test_`/`catch_` scope in between -- `null` if
/// the walk reaches the root container without ever finding one (e.g. a
/// stray top-level `try`, which can't belong to any function).
fn owningFunctionScope(sema: *const Semantic, node: Ast.Node.Index) ?Semantic.Scope.Id {
    var it = sema.iterParents(sema.nodeScope(node));
    while (it.next()) |scope_id| {
        if (sema.scopeKind(scope_id) == .function) return scope_id;
    }
    return null;
}

/// `fn_decl`'s OWN function scope id. `.fn_decl` always has a body block
/// (see the file doc), and a scope-creating node's OWN `node_scope` entry
/// resolves to its ENCLOSING scope (see `Semantic`'s file doc) -- so the
/// body block's `nodeScope` IS the function scope the body lives in, letting
/// this skip the "scan every scope for `scopeNode(id) == fn_decl`" approach
/// entirely.
fn functionScopeOf(
    sema: *const Semantic,
    tree: *const Ast,
    fn_decl: Ast.Node.Index,
) Semantic.Scope.Id {
    const body = tree.nodeData(fn_decl).node_and_node[1];
    return sema.nodeScope(body);
}

/// Whether ANY can-error signal (a `.@"try"`, or a `.@"return"` with an
/// uncertain operand) anywhere in the file belongs to `fn_scope` -- see the
/// file doc's nested-fn exclusion.
fn canError(tree: *const Ast, sema: *const Semantic, fn_scope: Semantic.Scope.Id) bool {
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        const is_signal = switch (tree.nodeTag(node)) {
            .@"try" => true,
            .@"return" => !isCertainlyNonError(tree, node),
            else => false,
        };
        if (!is_signal) continue;
        const scope_id = owningFunctionScope(sema, node) orelse continue;
        if (scope_id == fn_scope) return true;
    }
    return false;
}

fn checkFn(
    ctx: *Context,
    tree: *const Ast,
    sema: *const Semantic,
    fn_decl: Ast.Node.Index,
) Context.LintError!void {
    var buf: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buf, fn_decl) orelse return;
    const return_type = proto.ast.return_type.unwrap() orelse return;
    if (!isErrorUnionReturn(tree, return_type)) return;
    if (isExplicitEmptyErrorSet(tree, return_type)) return;
    if (canError(tree, sema, functionScopeOf(sema, tree, fn_decl))) return;

    const name_tok = proto.name_token orelse return;
    const start = tree.tokenStart(name_tok);
    const end = start + @as(u32, @intCast(tree.tokenSlice(name_tok).len));
    try ctx.report(start, end, flag_msg, .{});
}

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;
    const sema = ctx.semantic;
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        if (tree.nodeTag(node) != .fn_decl) continue;
        try checkFn(ctx, tree, sema, node);
    }
}

fn countDiags(gpa: std.mem.Allocator, src_text: []const u8) !usize {
    var src = try Source.loadFromSlice(gpa, "t.zig", src_text);
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);
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
        .semantic = &sema,
    };
    try run(&ctx);
    return diags.items.len;
}

const fallible_g_void = "fn g() !void {\n    return error.Bad;\n}\n";
const fallible_g_u8 = "fn g() !u8 {\n    return error.Bad;\n}\n";

test "flags a void fn whose only return has no operand" {
    const src = "fn f() !void {\n    return;\n}\n";
    try std.testing.expectEqual(@as(usize, 1), try countDiags(std.testing.allocator, src));
}

test "flags a fn whose only return is a number literal" {
    const src = "fn f() !u8 {\n    return 5;\n}\n";
    try std.testing.expectEqual(@as(usize, 1), try countDiags(std.testing.allocator, src));
}

test "flags an empty-bodied error-union fn (no return, no try)" {
    const src = "fn f() !void {}\n";
    try std.testing.expectEqual(@as(usize, 1), try countDiags(std.testing.allocator, src));
}

test "flags a fn that only suppresses via catch (no try, no error return)" {
    const src = "fn f() !void {\n    g() catch @panic(\"x\");\n}\n" ++ fallible_g_void;
    try std.testing.expectEqual(@as(usize, 1), try countDiags(std.testing.allocator, src));
}

test "clean: a try makes the fn genuinely fallible" {
    const src = "fn f() !void {\n    try g();\n}\n" ++ fallible_g_void;
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, src));
}

test "clean: returning a call result is an uncertain (possibly erroring) return" {
    const src = "fn f() !void {\n    return g();\n}\n" ++ fallible_g_void;
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, src));
}

test "clean: returning an error literal is a genuine error return" {
    const src = "fn f() !void {\n    return error.Bad;\n}\n";
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, src));
}

test "clean: returning an identifier is uncertain even after a catch fallback" {
    const src = "fn f() !u8 {\n    const v = g() catch return 0;\n    return v;\n}\n" ++
        fallible_g_u8;
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, src));
}

test "clean: the explicit empty error set error{}!T is already honest" {
    const src = "fn f() error{}!void {\n    return;\n}\n";
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, src));
}

test "a try inside a nested fn belongs to the nested fn, not the outer one" {
    const src =
        \\fn f() !void {
        \\    const S = struct {
        \\        fn h() !void {
        \\            try g();
        \\        }
        \\    };
        \\    _ = S;
        \\    return;
        \\}
        \\fn g() !u8 {
        \\    return compute();
        \\}
        \\
    ;
    // Only `f` flags: its own body has no can-error signal (the only `try`
    // belongs to nested `h`, not `f`); `h` itself is genuinely fallible (its
    // own `try`); `g`'s `return compute();` is an uncertain (call) operand.
    try std.testing.expectEqual(@as(usize, 1), try countDiags(std.testing.allocator, src));
}

//! Flags a `try expr` that Zig's own compiler would reject: `try` propagates
//! an error by returning early, so it is only legal inside something that
//! can itself return an error -- a function whose return type is an error
//! union, or (implicitly, since Zig makes every `test` block `!void`) a
//! `test` declaration. Adapted from zlint's scope-walking approach
//! (DonIsaac, MIT) to Zippy's own `Semantic` scope tree.
//!
//! This is a compiler-caught error (Zig itself refuses to build the file),
//! so it's high-signal and safe to flag at `.correctness` (error-by-default)
//! severity -- Zippy is only surfacing what `zig build` would say anyway,
//! earlier and with a friendlier message.
//!
//! ## Detection
//! For each `.@"try"` node, walk `sema.iterParents(sema.nodeScope(node))`
//! outward (see `Semantic.ParentIterator`) and inspect each scope's kind:
//!   - `.comptime_` -- `try` is permitted in a comptime block regardless of
//!     the enclosing function's signature (Zig evaluates it at comptime and
//!     turns a comptime error into a compile error, not a runtime
//!     propagation) -- clean, stop walking.
//!   - `.test_` -- every `test` block is implicitly `!void` -- clean, stop.
//!   - `.function` -- the nearest enclosing function; check whether ITS
//!     return type is an error union (`isErrorUnionReturn`). If not, flag
//!     (the `try` has a home, but that home can't propagate an error) --
//!     either way, stop walking (found the answer).
//!   - `.block` / `.loop` / `.catch_` -- not a stopping point; keep walking
//!     outward (e.g. a `try` inside a nested `if`/`while`/`catch` block
//!     still belongs to whichever function encloses THAT).
//!   - `.container` -- the walk reached the file/struct scope without ever
//!     finding an enclosing function/test/comptime: a "homeless" `try`,
//!     e.g. a top-level `const x = try f();` initializer. Flag.
//!
//! ## Error-union detection (conservative: report only when NONE of these hold)
//! Given the enclosing `fn_decl`'s `return_type` node (`fullFnProto`):
//!   - its tag is `.error_union` (`Foo!Bar`, `anyerror!void`, ...) -- an
//!     explicit error union with the error set spelled out on the left.
//!   - OR the token immediately BEFORE the return type's first token is
//!     `.bang` -- Zig's inferred-error-set shorthand `fn f() !T` parses the
//!     `!` as a token consumed by the fn-proto grammar itself (see
//!     `Parse.zig`'s `parseFnProto`), so it never becomes part of the
//!     return-type node's own token range; the return type node for `!void`
//!     is just `void`'s plain `.identifier` node. Checking the preceding
//!     token is the only way to see that leading `!` at all (confirmed by
//!     inspecting the parsed tree directly -- the return type's OWN first
//!     token is never `.bang`).
//!   - OR the return type's rightmost identifier (`rightmostIdentifier`)
//!     ends with `"Error"` -- a named error-set type or alias (`FooError`,
//!     `Foo.Error`) that this AST-only pass can't resolve to confirm it's
//!     really an error set, so this is a deliberately conservative
//!     name-based guess biased toward NOT flagging (avoids false positives
//!     on legitimate named error-set returns).
//!   - OR (last resort, `resolvesToErrorUnionAlias`) the return type is a
//!     bare name (`.identifier`/`.field_access`) that resolves, via
//!     `ctx.semantic`, to a file-level `const`/`var` whose initializer IS an
//!     error union one level deep: `const R = anyerror!void; fn f() R {...}`.
//!     Unlike the "Error"-suffix guess above, this is exact rather than a
//!     name heuristic -- it actually finds and inspects the aliased decl --
//!     but stays conservative by only unwrapping ONE level of aliasing and
//!     by falling through to "not an error union" (not flagging-safe, but
//!     the existing behavior) whenever resolution fails, e.g. for a builtin
//!     primitive like `void` that was never a real declaration to resolve.
const std = @import("std");
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Semantic = @import("../Semantic.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Ast = std.zig.Ast;

pub const name = "homeless_try";
pub const group: Config.Group = .correctness;
pub const description: []const u8 =
    "`try` propagates an error by returning early, so it's only legal " ++
    "inside a function whose return type is an error union or inside a " ++
    "`test` block (implicitly `!void`). Flags a `try` outside either -- " ++
    "the compiler would reject it too.";

/// The rightmost identifier naming `node`'s type, or `null` if `node` isn't
/// a shape this conservative check knows how to read an identifier out of.
/// `Foo.Error` (a `.field_access`) yields `"Error"`; a bare `SomeError`
/// (a `.identifier`) yields itself. Anything else (a pointer type, an
/// optional, a generic instantiation, ...) yields `null` rather than
/// guessing, per this lint's conservative bias.
fn rightmostIdentifier(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    return switch (tree.nodeTag(node)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(node)),
        .field_access => tree.tokenSlice(tree.nodeData(node).node_and_token[1]),
        else => null,
    };
}

/// Whether `fn_decl`'s declared return type is (or plausibly is) an error
/// union. See the file doc's "Error-union detection" section for the four
/// conditions checked and why. A `fn_decl` with a return type this pass
/// can't even find (a malformed/parse-error tree) is treated as clean --
/// missing detail should never manufacture a false positive.
fn isErrorUnionReturn(sema: *const Semantic, tree: *const Ast, fn_decl: Ast.Node.Index) bool {
    var buf: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buf, fn_decl) orelse return true;
    const return_type = proto.ast.return_type.unwrap() orelse return true;

    if (tree.nodeTag(return_type) == .error_union) return true;

    const first_tok = tree.firstToken(return_type);
    if (first_tok > 0 and tree.tokenTag(first_tok - 1) == .bang) return true;

    if (rightmostIdentifier(tree, return_type)) |ident| {
        if (std.mem.endsWith(u8, ident, "Error")) return true;
    }

    return resolvesToErrorUnionAlias(sema, tree, return_type);
}

/// The last-resort check in `isErrorUnionReturn` (see the file doc): whether
/// `return_type` -- a bare name none of the syntactic checks above matched
/// -- resolves, via the semantic layer, to a file-level `const`/`var` whose
/// OWN initializer is an error union: `const R = anyerror!void;` or
/// `const R = !void;`-shaped (the leading-`!` check mirrors the one in
/// `isErrorUnionReturn` itself, since a `var_decl`'s initializer has the
/// exact same "the `!` never joins the node's own token range" quirk a
/// return type does). Only ONE level of aliasing is unwrapped -- `R2 = R`
/// chains are not followed -- per the file doc's conservatism note.
/// `resolveBinding`'s exclude list is empty: a `var`/`const` alias is
/// exactly `.variable` kind, so excluding nothing is correct here (unlike
/// `no_print`'s use of the same API, which deliberately excludes it).
fn resolvesToErrorUnionAlias(
    sema: *const Semantic,
    tree: *const Ast,
    return_type: Ast.Node.Index,
) bool {
    const ident = rightmostIdentifier(tree, return_type) orelse return false;
    const scope = sema.nodeScope(return_type);
    const sym_id = sema.resolveBinding(scope, ident, &.{}) orelse return false;
    const decl = sema.symbol(sym_id).decl;
    const full_var = tree.fullVarDecl(decl) orelse return false;
    const init_node = full_var.ast.init_node.unwrap() orelse return false;
    if (tree.nodeTag(init_node) == .error_union) return true;
    const init_first_tok = tree.firstToken(init_node);
    return init_first_tok > 0 and tree.tokenTag(init_first_tok - 1) == .bang;
}

const homeless_msg = "`try` outside an error-returning function";
const bad_fn_msg = "`try` in a function whose return type isn't an error union";

fn checkTry(
    ctx: *Context,
    tree: *const Ast,
    sema: *const Semantic,
    try_node: Ast.Node.Index,
) Context.LintError!void {
    var it = sema.iterParents(sema.nodeScope(try_node));
    while (it.next()) |scope_id| {
        switch (sema.scopeKind(scope_id)) {
            .comptime_, .test_ => return,
            .function => {
                if (isErrorUnionReturn(sema, tree, sema.scopeNode(scope_id))) return;
                try report(ctx, tree, try_node, bad_fn_msg);
                return;
            },
            .container => break,
            .block, .loop, .catch_ => continue,
        }
    }
    try report(ctx, tree, try_node, homeless_msg);
}

/// Reports on the `try` keyword token alone (not the whole `try expr`),
/// matching this codebase's preference for a minimal, precise span (see
/// `discarded_error`'s file doc for the same reasoning).
fn report(
    ctx: *Context,
    tree: *const Ast,
    try_node: Ast.Node.Index,
    comptime msg: []const u8,
) Context.LintError!void {
    const tok = tree.nodeMainToken(try_node);
    const start = tree.tokenStart(tok);
    const end = start + @as(u32, @intCast(tree.tokenSlice(tok).len));
    try ctx.report(start, end, msg, .{});
}

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;
    const sema = ctx.semantic;
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @enumFromInt(idx);
        if (tree.nodeTag(node) != .@"try") continue;
        try checkTry(ctx, tree, sema, node);
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
        .current_severity = .@"error",
        .semantic = &sema,
    };
    try run(&ctx);
    return diags.items.len;
}

const fallible_g = "fn g() !u8 {\n    return 1;\n}\n";

test "flags try in a void-returning function" {
    const src = "pub fn f() void {\n    _ = try g();\n}\n" ++ fallible_g;
    try std.testing.expectEqual(@as(usize, 1), try countDiags(std.testing.allocator, src));
}

test "clean: try in a function returning an explicit error union" {
    const src = "pub fn f() !void {\n    _ = try g();\n}\n" ++ fallible_g;
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, src));
}

test "clean: try in a function returning anyerror!void" {
    const src = "pub fn f() anyerror!void {\n    _ = try g();\n}\n" ++ fallible_g;
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, src));
}

test "clean: try in a function returning a named error-set field access" {
    const src = "const Foo = struct { pub const Error = error{Bad}; };\n" ++
        "pub fn f() Foo.Error!void {\n    _ = try g();\n}\n" ++ fallible_g;
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, src));
}

test "clean: try in a function returning a bare *Error-suffixed alias" {
    const src = "const SomeError = error{Bad};\n" ++
        "pub fn f() SomeError {\n    _ = try g();\n}\n" ++ fallible_g;
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, src));
}

test "clean: try inside a comptime block in a void-returning function" {
    const src = "pub fn f() void {\n    comptime {\n        _ = try g();\n    }\n}\n" ++ fallible_g;
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, src));
}

test "clean: try inside a test block" {
    const src = "test \"t\" {\n    _ = try g();\n}\n" ++ fallible_g;
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, src));
}

test "flags a container-level try with no enclosing function" {
    const src = "const x = try g();\n" ++ fallible_g;
    try std.testing.expectEqual(@as(usize, 1), try countDiags(std.testing.allocator, src));
}

test "clean (FIX I3): try in a function returning an error-union type ALIAS" {
    // `R` isn't `.error_union`-tagged itself (it's a bare `.identifier`
    // return type) and doesn't end in "Error", so neither syntactic check
    // in `isErrorUnionReturn` sees it -- only resolving `R` via the
    // semantic layer back to `const R = anyerror!void;` proves it's really
    // an error union.
    const src = "const R = anyerror!void;\npub fn f() R {\n    _ = try g();\n}\n" ++ fallible_g;
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, src));
}

test "still flags: try in a void-returning function (alias resolution doesn't over-clean)" {
    // Guards against `resolvesToErrorUnionAlias` becoming too permissive:
    // `void` never resolves to a file decl, so this must still flag exactly
    // like the pre-FIX-I3 "flags try in a void-returning function" case.
    const src = "pub fn h() void {\n    _ = try g();\n}\n" ++ fallible_g;
    try std.testing.expectEqual(@as(usize, 1), try countDiags(std.testing.allocator, src));
}

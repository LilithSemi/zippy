//! Flags a private (non-`pub`) top-level `fn`/`const`/`var` whose name is
//! never referenced anywhere else in its file. The compiler already errors
//! on unused *locals*, but a dead private top-level declaration compiles
//! cleanly -- this closes that gap.
//!
//! Detection uses `ctx.semantic`'s reference lists (see `Semantic.zig`)
//! rather than a token count: for every PRIVATE `variable`/`function`
//! symbol declared in the file's ROOT container scope, the decl is unused
//! iff `symbol.references.items.len == 0` -- Phase B already resolved every
//! real identifier USE in the file (including uses inside dead code, and
//! uses that textually precede the decl) back to the symbol that binds it,
//! so an empty list means nothing in the file ever named this decl via a
//! real scope binding. This is strictly more precise than a whole-file
//! identifier-token count: it correctly sees an OUTER decl as unused when a
//! same-named INNER decl shadows it at every use site (the token count
//! couldn't tell those apart), and it correctly does NOT count a struct
//! field-init name (`.K = 0`) or a field-access member name (`x.K`) as a
//! reference to a same-named top-level decl, since neither is a real
//! `.identifier` scope-binding node (see `Semantic.zig`'s Phase B doc).
//!
//! Known limitation: a decl referenced only via reflection (`@field`,
//! `@hasDecl`, comptime string-building of a member name) has no
//! `.identifier` node spelling it, so `references` stays empty even though
//! the decl is genuinely used. To stay conservative, this lint skips a
//! zero-referenced decl whose name EXACTLY matches a string-literal argument
//! to a reflection builtin (`@field(C, "name")`, `@hasDecl`, `@hasField`,
//! `@FieldType`). The guard is scoped to those builtins (not every string in
//! the file) and matches the string's content exactly, so an unrelated
//! string -- an `@import("std")` path, a format string, a message that merely
//! contains the name as a substring -- never spuriously exempts a decl. A
//! false negative (a genuinely-dead decl reached only by some other reflection
//! shape we don't model) is safe; a false positive is not.
//!
//! Known limitation: a self-recursive private fn that is otherwise
//! unreferenced (calls itself but nothing outside ever calls it) records
//! its own recursive call as a real reference (the call resolves back to
//! the fn's own symbol via the normal scope walk), so it is NOT flagged
//! even though it is genuinely dead. This is a deliberate conservative
//! tradeoff -- catching it would require call-graph reachability beyond a
//! single reference list, and a false positive here is worse than this one
//! missed case.
//!
//! Known limitation: a decl used ONLY via member syntax (`self.helper()`,
//! `Container.member`) has no `.identifier` NODE spelling it either -- Phase
//! B only walks `.identifier` nodes (see `Semantic.zig`'s Phase B doc), and
//! `helper` in `self.helper()` is a `.field_access` FIELD TOKEN, never a node
//! of its own -- so `references` stays empty for the dominant
//! file-as-struct/method-call idiom too. This lint guards against it the
//! same way as the reflection guard above: a zero-referenced decl whose name
//! exactly matches some `.field_access`'s field-token text anywhere in the
//! file is treated as possibly-used and skipped, even though most such
//! matches ARE genuine method calls and a few are coincidental (a field
//! happens to share a name with a dead top-level decl). A false negative
//! here is safe; a false positive that deletes a live method is not.
const std = @import("std");
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Semantic = @import("../Semantic.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Ast = std.zig.Ast;

pub const name = "unused_decl";
pub const group: Config.Group = .unused;
pub const description: []const u8 =
    "A private (non-pub) top-level declaration that nothing in its file " ++
    "references is dead code. Remove it, or make it `pub` if it's meant " ++
    "to be used elsewhere.";

/// `Semantic.build` always creates the whole-file container scope first (see
/// `Semantic.zig`'s `build`), so its id is stable across every file.
const root_scope: Semantic.Scope.Id = 0;

/// The per-decl-node facts this lint needs beyond what `Symbol` already
/// carries: the decl's own name token (for the diagnostic span) and whether
/// an `extern`/`export` keyword is present. Bundled into one struct so a
/// single `fullFnProto`/`fullVarDecl` dispatch serves both, rather than
/// looking the node up twice.
const DeclInfo = struct { name_tok: Ast.TokenIndex, extern_export: bool };

/// `null` if `node` isn't a shape this lint recognizes (shouldn't happen for
/// a `variable`/`function` symbol's own `decl`, but AST accessors return
/// `null` rather than erroring on a weird tree, so this stays conservative).
fn declInfo(tree: *const Ast, node: Ast.Node.Index) ?DeclInfo {
    var fn_buf: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_buf, node)) |proto| {
        const name_tok = proto.name_token orelse return null;
        return .{
            .name_tok = name_tok,
            .extern_export = isExternExport(tree, proto.extern_export_inline_token),
        };
    }
    if (tree.fullVarDecl(node)) |decl| {
        return .{
            .name_tok = decl.ast.mut_token + 1,
            .extern_export = isExternExport(tree, decl.extern_export_token),
        };
    }
    return null;
}

/// `extern_export_inline_token` also covers `inline` (a plain optimization hint
/// on a still-private fn), which must NOT be exempted -- only `extern`/`export`
/// (externally used) are.
fn isExternExport(tree: *const Ast, tok: ?Ast.TokenIndex) bool {
    const t = tok orelse return false;
    return switch (tree.tokenTag(t)) {
        .keyword_extern, .keyword_export => true,
        else => false,
    };
}

/// The reflection builtins whose string argument names a declaration: skip a
/// zero-referenced decl only when its name shows up as one of THESE builtins'
/// string args, not any string anywhere. `@import` is deliberately absent --
/// its string is a module/file path, not a decl name.
const reflection_builtins = [_][]const u8{ "@field", "@hasDecl", "@hasField", "@FieldType" };

fn isReflectionBuiltin(builtin_name: []const u8) bool {
    for (reflection_builtins) |b| {
        if (std.mem.eql(u8, b, builtin_name)) return true;
    }
    return false;
}

/// Whether `node` is a `.string_literal` whose CONTENT (the bytes between the
/// quotes) exactly equals `ident`. Decl names are plain identifiers with no
/// escapes, so stripping the two surrounding quote bytes is enough.
fn stringNodeEquals(tree: *const Ast, node: Ast.Node.Index, ident: []const u8) bool {
    if (tree.nodeTag(node) != .string_literal) return false;
    const slice = tree.tokenSlice(tree.nodeMainToken(node));
    if (slice.len < 2) return false;
    return std.mem.eql(u8, slice[1 .. slice.len - 1], ident);
}

/// The reflection guard (see the file doc): whether `ident` exactly matches a
/// string-literal argument to a reflection builtin anywhere in the file. Only
/// called for a decl that's already zero-referenced, so this whole-file node
/// scan runs at most once per genuinely-dead candidate, not once per decl.
fn nameInReflectionBuiltin(tree: *const Ast, ident: []const u8) bool {
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @enumFromInt(idx);
        const builtin_name = switch (tree.nodeTag(node)) {
            .builtin_call_two,
            .builtin_call_two_comma,
            .builtin_call,
            .builtin_call_comma,
            => tree.tokenSlice(tree.nodeMainToken(node)),
            else => continue,
        };
        if (!isReflectionBuiltin(builtin_name)) continue;
        var buf: [2]Ast.Node.Index = undefined;
        const args = tree.builtinCallParams(&buf, node) orelse continue;
        for (args) |arg| {
            if (stringNodeEquals(tree, arg, ident)) return true;
        }
    }
    return false;
}

/// The member-access guard (see the file doc): whether `name` exactly
/// matches a `.field_access` FIELD token's text anywhere in the file. Only
/// called for a decl that's already zero-referenced, so this whole-file scan
/// runs at most once per genuinely-dead candidate, not once per decl -- same
/// cost shape as `nameInReflectionBuiltin` above.
fn nameIsMemberAccess(tree: *const Ast, decl_name: []const u8) bool {
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @enumFromInt(idx);
        if (tree.nodeTag(node) != .field_access) continue;
        const field_tok = tree.nodeData(node).node_and_token[1];
        if (std.mem.eql(u8, tree.tokenSlice(field_tok), decl_name)) return true;
    }
    return false;
}

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;
    const sema = ctx.semantic;

    var id: Semantic.Symbol.Id = 0;
    while (id < sema.symbols.items.len) : (id += 1) {
        const sym = sema.symbol(id);
        if (sym.scope != root_scope) continue; // only top-level decls
        if (sym.kind != .variable and sym.kind != .function) continue;
        if (sym.visibility == .public) continue;
        const info = declInfo(tree, sym.decl) orelse continue;
        if (info.extern_export) continue;
        if (sym.references.items.len > 0) continue; // a real use exists
        if (nameInReflectionBuiltin(tree, sym.name)) continue; // possibly reflected
        if (nameIsMemberAccess(tree, sym.name)) continue; // possibly used as a member/method

        const start = tree.tokenStart(info.name_tok);

        // Delete span: the decl's first token through the end of its
        // last token, then extended over a following `;` (a var-decl's
        // `lastToken` stops at its initializer expression, not the
        // trailing `;`) and then one trailing `\n` (delete the whole
        // line, no blank line left behind). A fn-with-body's `lastToken`
        // is its closing `}` -- no `;` follows, so the `;` check is a
        // harmless no-op there.
        const first_tok = tree.firstToken(sym.decl);
        const last_tok = tree.lastToken(sym.decl);
        const del_start = tree.tokenStart(first_tok);
        const last_len: u32 = @intCast(tree.tokenSlice(last_tok).len);
        var del_end = tree.tokenStart(last_tok) + last_len;
        const bytes = ctx.source.bytes;
        if (del_end < bytes.len and bytes[del_end] == ';') del_end += 1;
        if (del_end < bytes.len and bytes[del_end] == '\n') del_end += 1;
        const fix: Diagnostic.Fix = .{
            .start = del_start,
            .end = del_end,
            .replacement = "",
            .title = "remove unused declaration",
        };

        try ctx.reportWithFix(.{
            .start_offset = start,
            .end_offset = start + @as(u32, @intCast(sym.name.len)),
            .fix = fix,
        }, "private declaration '{s}' is never referenced", .{sym.name});
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
        .semantic = &sema,
    };
    try run(&ctx);
    return diags.items.len;
}

test "flags an unreferenced private fn" {
    try std.testing.expectEqual(
        @as(usize, 1),
        try countDiags(std.testing.allocator, "fn helper() void {}\npub fn main() void {}\n"),
    );
}
test "does not flag a referenced private fn" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(
            std.testing.allocator,
            "fn helper() void {}\npub fn main() void { helper(); }\n",
        ),
    );
}
test "does not flag a pub decl" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, "pub fn helper() void {}\n"),
    );
}
test "does not flag an export/extern decl" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, "export fn helper() void {}\n"),
    );
}
test "does not flag a private inline fn that is referenced" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(
            std.testing.allocator,
            "inline fn helper() void {}\npub fn main() void { helper(); }\n",
        ),
    );
}
test "flags a private inline fn that is unreferenced" {
    try std.testing.expectEqual(
        @as(usize, 1),
        try countDiags(
            std.testing.allocator,
            "inline fn helper() void {}\npub fn main() void {}\n",
        ),
    );
}
test "flags a private const whose name only appears as an anon-struct field-init label (hardened)" {
    // Under the old token-count heuristic this was a documented false
    // negative: `.K = 0` (an anon-struct field-init LABEL, not a
    // `.field_access` node -- it's a plain token on the `.struct_init`
    // node) spells "K" as a token, so the count was 2 and the old code
    // stayed silent. It's not a real scope-binding `.identifier` node NOR a
    // `.field_access` field token, so neither the reference model nor the
    // member-access guard (see the file doc) sees it as a use -- `K` is
    // still correctly flagged as genuinely dead.
    try std.testing.expectEqual(
        @as(usize, 1),
        try countDiags(
            std.testing.allocator,
            "const K = 1;\npub fn main() void { const x = .{ .K = 0 }; _ = x; }\n",
        ),
    );
}
test "member-access guard: a coincidental x.K field access exempts a same-named const" {
    // The flip side of the C1 fix's tradeoff: `x.K` (a genuine
    // `.field_access` node) matches the member-access guard even though,
    // here, `x` isn't the struct-with-a-method `K` was meant for -- it's
    // coincidental name reuse. This is the documented safe-false-negative
    // half of the guard (see the file doc): treating any `.field_access`
    // field-token match as "possibly a real method/member use" is what
    // fixes the C1 false-positive-DELETE on `self.helper()`, at the cost of
    // also missing this rarer coincidental-name case.
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(
            std.testing.allocator,
            "const K = 1;\npub fn main() void { const x = .{ .K = 0 }; _ = x.K; }\n",
        ),
    );
}
test "flags an unreferenced private const" {
    try std.testing.expectEqual(
        @as(usize, 1),
        try countDiags(std.testing.allocator, "const Unused = 1;\npub fn main() void {}\n"),
    );
}
test "flags an unreferenced private var" {
    try std.testing.expectEqual(
        @as(usize, 1),
        try countDiags(std.testing.allocator, "var unused: u8 = 0;\npub fn main() void {}\n"),
    );
}
test "misses a self-recursive but otherwise unreferenced private fn (documented limitation)" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(
            std.testing.allocator,
            "fn helper() void { helper(); }\npub fn main() void {}\n",
        ),
    );
}
test "flags an outer decl whose every use site actually resolves to an inner shadow" {
    // Old heuristic missed this: "x" appears 3 times (outer decl, inner
    // decl, one use), so a bare count never flagged it. The reference
    // model resolves `_ = x;` to the INNER `x` (nearest-scope-wins), so the
    // outer `x` genuinely has zero references.
    try std.testing.expectEqual(
        @as(usize, 1),
        try countDiags(
            std.testing.allocator,
            "const x = 1;\npub fn f() void {\n    const x = 2;\n    _ = x;\n}\n",
        ),
    );
}
test "does not flag a private const referenced only from inside a fn body" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, "const K = 5;\npub fn main() void { _ = K; }\n"),
    );
}
test "reflection guard: a name passed to @field as a string is not flagged" {
    const src = "const K = 1;\npub fn main() void { _ = @field(@This(), \"K\"); }\n";
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, src));
}
test "reflection guard: a plain (non-reflection) string does NOT exempt a decl" {
    // The guard is scoped to reflection builtins, so an unrelated string that
    // merely contains the name must still let the dead decl be flagged.
    const src = "const K = 1;\npub fn main() void { _ = \"K\"; }\n";
    try std.testing.expectEqual(@as(usize, 1), try countDiags(std.testing.allocator, src));
}
test "member-access guard: a private fn called only as self.helper() is not flagged" {
    // The dominant file-as-struct idiom: `helper` in `self.advance()` is a
    // `.field_access` FIELD TOKEN, never an `.identifier` node, so Phase B
    // never records a reference -- without the guard this was a regression
    // vs. the old token-count heuristic (which DID see the "advance" token).
    const src = "pub fn parse(self: *@This()) void { self.advance(); }\n" ++
        "fn advance(self: *@This()) void { _ = self; }\n";
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, src));
}
test "member-access guard: a truly-dead private fn with no matching field access is flagged" {
    const src = "fn deadHelper() void {}\npub fn main() void {}\n";
    try std.testing.expectEqual(@as(usize, 1), try countDiags(std.testing.allocator, src));
}
test "FIX I2 repro: const read in an if condition guarded by a same-named capture is not flagged" {
    // Without FIX I2's Semantic.zig change, the condition's `cached` read
    // resolved to the `|cached|` capture instead of this top-level const
    // (the capture scope wrongly contained the condition token), so the
    // const looked zero-referenced and `--fix` deleted it out from under a
    // still-live read.
    const src = "const cached = @as(?u8, null);\n" ++
        "pub fn get() u8 {\n    if (cached) |cached| return cached;\n    return 0;\n}\n";
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, src));
}

fn fixOf(gpa: std.mem.Allocator, src_text: []const u8) !?Diagnostic.Fix {
    var src = try Source.loadFromSlice(gpa, "t.zig", src_text);
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);
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
        .semantic = &sema,
    };
    try run(&ctx);
    if (diags.items.len == 0) return null;
    return diags.items[0].fix;
}

test "unused_decl fix deletes the whole dead fn decl (result parses cleanly)" {
    const gpa = std.testing.allocator;
    const s = "fn dead() void {}\npub fn main() void {}\n";
    const fx = (try fixOf(gpa, s)).?;
    // fix span covers `fn dead() void {}` plus the trailing newline
    const after = try std.mem.concat(gpa, u8, &.{ s[0..fx.start], fx.replacement, s[fx.end..] });
    defer gpa.free(after);
    try std.testing.expectEqualStrings("pub fn main() void {}\n", after);
    // and the result still parses:
    const after_z = try gpa.dupeZ(u8, after);
    defer gpa.free(after_z);
    var t = try std.zig.Ast.parse(gpa, after_z, .zig);
    defer t.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), t.errors.len);
}

test "unused_decl fix deletes the whole dead const decl (result parses cleanly)" {
    const gpa = std.testing.allocator;
    const s = "const Unused = 1;\npub fn main() void {}\n";
    const fx = (try fixOf(gpa, s)).?;
    const after = try std.mem.concat(gpa, u8, &.{ s[0..fx.start], fx.replacement, s[fx.end..] });
    defer gpa.free(after);
    try std.testing.expectEqualStrings("pub fn main() void {}\n", after);
    const after_z = try gpa.dupeZ(u8, after);
    defer gpa.free(after_z);
    var t = try std.zig.Ast.parse(gpa, after_z, .zig);
    defer t.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), t.errors.len);
}

test "unused_decl fix carries a code-action title" {
    const gpa = std.testing.allocator;
    const fx = (try fixOf(gpa, "fn dead() void {}\npub fn main() void {}\n")).?;
    try std.testing.expectEqualStrings("remove unused declaration", fx.title);
}

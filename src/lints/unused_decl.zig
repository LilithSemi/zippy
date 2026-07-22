//! Flags a private (non-`pub`) top-level `fn`/`const`/`var` whose name is
//! never referenced anywhere else in its file. The compiler already errors
//! on unused *locals*, but a dead private top-level declaration compiles
//! cleanly -- this closes that gap.
//!
//! Detection is a two-pass, whole-file token count: every `.identifier`
//! token in the file is tallied by its text, then any private, non-extern/
//! export top-level decl whose name occurs exactly once (its own definition
//! token) is flagged. Any other occurrence -- a real call/use, a field
//! access `x.foo`, a shadowing local elsewhere, even a doc-comment-adjacent
//! mention -- conservatively counts as a reference. This can miss a decl
//! that's genuinely dead but named the same as something else in scope (a
//! false negative), but it cannot flag a decl that *is* used (no false
//! positives from this source) -- the documented tradeoff this lint takes,
//! per IronStyle's correctness bias.
//!
//! Known limitation: a decl referenced only via reflection (`@field`,
//! `@hasDecl`, comptime string-building of a member name) has no
//! `.identifier` token spelling it, so this lint cannot see that use and
//! will flag it as unreferenced. Such decls should be kept `pub` or given
//! an explicit reference to stay silent.
//!
//! Known limitation: a self-recursive private fn that is otherwise
//! unreferenced (calls itself but nothing outside ever calls it) has a
//! name-count of 2 (its definition token + the recursive-call token), so it
//! is NOT flagged even though it is genuinely dead. This is the same
//! conservative tradeoff: catching it would require call-graph analysis
//! beyond a token count, and a false positive here is worse than this one
//! missed case.
const std = @import("std");
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Ast = std.zig.Ast;

pub const name = "unused_decl";
pub const group: Config.Group = .unused;
pub const description: []const u8 =
    "A private (non-pub) top-level declaration that nothing in its file " ++
    "references is dead code. Remove it, or make it `pub` if it's meant " ++
    "to be used elsewhere.";

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;

    // Pass 1: count every identifier token in the file. A candidate decl whose
    // name appears exactly once (its own definition) is unreferenced. Any other
    // occurrence -- a real use, a field access `x.foo`, a param, even a
    // shadowing local -- conservatively counts as a reference (a false negative
    // is safe; a false positive is not). Comments/strings aren't `.identifier`
    // tokens, so they never count.
    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer counts.deinit(ctx.gpa);
    var tok: u32 = 0;
    const n_tokens: u32 = @intCast(tree.tokens.len);
    while (tok < n_tokens) : (tok += 1) {
        if (tree.tokenTag(tok) != .identifier) continue;
        const slice = tree.tokenSlice(tok);
        const gop = try counts.getOrPut(ctx.gpa, slice);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    // Pass 2: for each private, non-extern/export top-level decl, flag it if its
    // name's identifier-token count is exactly 1.
    //
    // Unlike naming_convention.zig (which walks *every* node and so must skip
    // `.fn_decl` to avoid double-visiting a body-having fn via both its
    // `fn_decl` wrapper and its inner `fn_proto*` node), `rootDecls()` lists
    // each top-level declaration exactly once -- a body-having fn appears
    // only as its `.fn_decl` node. `fullFnProto` already delegates `.fn_decl`
    // to its wrapped proto internally, so calling it directly on the
    // `rootDecls()` node (no skip) is both correct and necessary: skipping
    // `.fn_decl` here would silently never check any top-level fn with a
    // body.
    var fn_buf: [1]Ast.Node.Index = undefined;
    for (tree.rootDecls()) |node| {
        var name_tok: Ast.TokenIndex = undefined;
        if (tree.fullFnProto(&fn_buf, node)) |proto| {
            if (proto.visib_token != null) continue; // pub
            if (isExternExport(tree, proto.extern_export_inline_token)) continue;
            name_tok = proto.name_token orelse continue;
        } else if (tree.fullVarDecl(node)) |decl| {
            if (decl.visib_token != null) continue; // pub
            if (decl.extern_export_token != null) continue; // extern/export
            name_tok = decl.ast.mut_token + 1;
        } else continue;

        const ident = tree.tokenSlice(name_tok);
        if ((counts.get(ident) orelse 0) == 1) {
            const start = tree.tokenStart(name_tok);

            // Delete span: the decl's first token through the end of its
            // last token, then extended over a following `;` (a var-decl's
            // `lastToken` stops at its initializer expression, not the
            // trailing `;`) and then one trailing `\n` (delete the whole
            // line, no blank line left behind). A fn-with-body's `lastToken`
            // is its closing `}` -- no `;` follows, so the `;` check is a
            // harmless no-op there.
            const first_tok = tree.firstToken(node);
            const last_tok = tree.lastToken(node);
            const del_start = tree.tokenStart(first_tok);
            const last_len: u32 = @intCast(tree.tokenSlice(last_tok).len);
            var del_end = tree.tokenStart(last_tok) + last_len;
            const bytes = ctx.source.bytes;
            if (del_end < bytes.len and bytes[del_end] == ';') del_end += 1;
            if (del_end < bytes.len and bytes[del_end] == '\n') del_end += 1;
            const fix: Diagnostic.Fix = .{ .start = del_start, .end = del_end, .replacement = "" };

            try ctx.reportWithFix(.{
                .start_offset = start,
                .end_offset = start + @as(u32, @intCast(ident.len)),
                .fix = fix,
            }, "private declaration '{s}' is never referenced", .{ident});
        }
    }
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

fn countDiags(gpa: std.mem.Allocator, src_text: []const u8) !usize {
    var src = try Source.loadFromSlice(gpa, "t.zig", src_text);
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
test "does not flag a private const used only via field access (conservative)" {
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

fn fixOf(gpa: std.mem.Allocator, src_text: []const u8) !?Diagnostic.Fix {
    var src = try Source.loadFromSlice(gpa, "t.zig", src_text);
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

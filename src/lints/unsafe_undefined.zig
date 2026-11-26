//! Flags `undefined` (Zig's uninitialized-memory sentinel): reading a value
//! that was only ever set to `undefined` is undefined behavior, so leaving
//! one lying around unexempted is a real memory-safety risk. Ported from
//! zlint's `unsafe_undefined`-style rules (DonIsaac, MIT), reworked to
//! Zippy's `Semantic` scope tree for the test/destructor exemptions.
//!
//! ## Detection
//! Zig's `undefined` is a primitive parsed as a plain `.identifier` node
//! (confirmed by dumping the AST directly -- see this lint's design doc; no
//! other identifier can ever be spelled `undefined`, so no name resolution
//! is needed to tell a real use apart from a shadowing local). For every
//! such node:
//!   - ALWAYS report, skipping every exemption below, if the node is an
//!     operand of an `.equal_equal`/`.bang_equal` node (`x == undefined` /
//!     `x != undefined`). Comparing anything against `undefined` reads the
//!     comparison operand's bit pattern, which is itself UB -- there is no
//!     legitimate reason to write this, so no exemption should ever silence
//!     it. The set of undefined-nodes that are such an operand is
//!     pre-collected in one pass over `.equal_equal`/`.bang_equal` nodes
//!     (simpler and cheaper than a general parent-of query).
//!   - Otherwise, each of these three EXEMPTS (config-toggled, default on;
//!     see `Config.UnsafeUndefinedCfg`):
//!     - `allow_arrays`: the node is the `init_node` of a `fullVarDecl`
//!       whose `ast.type_node` is `.array_type`/`.array_type_sentinel`
//!       (`var buf: [N]u8 = undefined;`) -- an uninitialized fixed-size
//!       buffer about to be filled is idiomatic, not a bug. NOTE a
//!       container FIELD default (`field: [N]T = undefined`) is NOT a
//!       var-decl (`fullVarDecl` only matches `simple_var_decl` and its
//!       kin), so it is correctly left flagged -- only a local/global
//!       var-decl's own initializer gets this exemption.
//!     - `allow_tests`: walking `sema.iterParents(sema.nodeScope(node))`
//!       passes through a `.test_` scope -- tests commonly use `undefined`
//!       as a placeholder overwritten before use, and never ship.
//!     - `allow_destructors`: the node's nearest enclosing `.function`
//!       scope's own fn (`scopeNode`) is named `deinit`/`destroy`/`reset`
//!       -- poisoning freed/reset memory with `undefined` is good practice.
//!   - Otherwise, report at the `undefined` token itself.
//!
//! The escape hatch for a genuine one-off this can't see a reason to exempt
//! is the existing `// zippy:ignore unsafe_undefined` directive -- no
//! separate SAFETY-comment format is implemented, which would only
//! duplicate that suppression mechanism.
const std = @import("std");
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Semantic = @import("../Semantic.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Ast = std.zig.Ast;

pub const name = "unsafe_undefined";
pub const group: Config.Group = .memory;
pub const description: []const u8 =
    "`undefined` leaves memory uninitialized; reading it before it's " ++
    "assigned a real value is undefined behavior. Exempt by default: " ++
    "array-typed local var-decls (`allow_arrays`), `test` blocks " ++
    "(`allow_tests`), and `deinit`/`destroy`/`reset` functions " ++
    "(`allow_destructors`). A comparison against `undefined` " ++
    "(`x == undefined`) always flags regardless of these exemptions.";

const undefined_msg =
    "`undefined` leaves memory uninitialized (undefined behavior if read); " ++
    "initialize it, or `// zippy:ignore unsafe_undefined` if deliberate";

/// True if `tree.tokenSlice(tree.nodeMainToken(node))` spells the primitive
/// `undefined` -- the only case an `.identifier` node's own tag can't tell
/// apart from any other identifier.
fn isUndefinedNode(tree: *const Ast, node: Ast.Node.Index) bool {
    if (tree.nodeTag(node) != .identifier) return false;
    return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "undefined");
}

/// Every `undefined` node that is an operand of `.equal_equal`/`.bang_equal`
/// -- see the file doc's "ALWAYS report" case. Pre-collected in one pass
/// (rather than a parent-of query per `undefined` node) since both directions
/// need the same scan of comparison nodes either way.
fn collectComparisonOperands(
    gpa: std.mem.Allocator,
    tree: *const Ast,
) std.mem.Allocator.Error!std.AutoHashMapUnmanaged(Ast.Node.Index, void) {
    var set: std.AutoHashMapUnmanaged(Ast.Node.Index, void) = .empty;
    errdefer set.deinit(gpa);
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        switch (tree.nodeTag(node)) {
            .equal_equal, .bang_equal => {},
            else => continue,
        }
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        if (isUndefinedNode(tree, lhs)) try set.put(gpa, lhs, {});
        if (isUndefinedNode(tree, rhs)) try set.put(gpa, rhs, {});
    }
    return set;
}

/// True if `node` (an `undefined` node) is the `init_node` of a `fullVarDecl`
/// whose declared type is an array type -- see the file doc's `allow_arrays`
/// exemption. Container fields are never `fullVarDecl`-shaped, so they are
/// never matched here (left flagged, as intended).
fn isArrayVarDeclInit(tree: *const Ast, node: Ast.Node.Index) bool {
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const decl_node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        const decl = tree.fullVarDecl(decl_node) orelse continue;
        const init_node = decl.ast.init_node.unwrap() orelse continue;
        if (init_node != node) continue;
        const type_node = decl.ast.type_node.unwrap() orelse return false;
        return switch (tree.nodeTag(type_node)) {
            .array_type, .array_type_sentinel => true,
            else => false,
        };
    }
    return false;
}

/// True if `sema.iterParents(sema.nodeScope(node))` passes through a
/// `.test_` scope -- see the file doc's `allow_tests` exemption.
fn isInTest(sema: *const Semantic, node: Ast.Node.Index) bool {
    var it = sema.iterParents(sema.nodeScope(node));
    while (it.next()) |scope_id| {
        if (sema.scopeKind(scope_id) == .test_) return true;
    }
    return false;
}

fn isDestructorName(s: []const u8) bool {
    return std.mem.eql(u8, s, "deinit") or
        std.mem.eql(u8, s, "destroy") or
        std.mem.eql(u8, s, "reset");
}

/// True if `node`'s nearest enclosing `.function` scope belongs to a fn named
/// `deinit`/`destroy`/`reset` -- see the file doc's `allow_destructors`
/// exemption. A `node` with no enclosing function (e.g. a container-level
/// `undefined`) never matches.
fn isInDestructor(sema: *const Semantic, tree: *const Ast, node: Ast.Node.Index) bool {
    var it = sema.iterParents(sema.nodeScope(node));
    while (it.next()) |scope_id| {
        if (sema.scopeKind(scope_id) != .function) continue;
        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, sema.scopeNode(scope_id)) orelse return false;
        const name_tok = proto.name_token orelse return false;
        return isDestructorName(tree.tokenSlice(name_tok));
    }
    return false;
}

fn checkUndefined(
    ctx: *Context,
    tree: *const Ast,
    sema: *const Semantic,
    comparison_operands: *const std.AutoHashMapUnmanaged(Ast.Node.Index, void),
    node: Ast.Node.Index,
) Context.LintError!void {
    if (!comparison_operands.contains(node)) {
        if (ctx.config.unsafeUndefinedAllowArrays() and isArrayVarDeclInit(tree, node)) return;
        if (ctx.config.unsafeUndefinedAllowTests() and isInTest(sema, node)) return;
        if (ctx.config.unsafeUndefinedAllowDestructors() and isInDestructor(sema, tree, node))
            return;
    }

    const tok = tree.nodeMainToken(node);
    const start = tree.tokenStart(tok);
    const end = start + @as(u32, @intCast(tree.tokenSlice(tok).len));
    try ctx.report(start, end, undefined_msg, .{});
}

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;
    const sema = ctx.semantic;
    var comparison_operands = try collectComparisonOperands(ctx.gpa, tree);
    defer comparison_operands.deinit(ctx.gpa);

    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        if (!isUndefinedNode(tree, node)) continue;
        try checkUndefined(ctx, tree, sema, &comparison_operands, node);
    }
}

fn countDiagsWith(
    gpa: std.mem.Allocator,
    src_text: []const u8,
    cfg: *Config,
) !usize {
    var src = try Source.loadFromSlice(gpa, "t.zig", src_text);
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);
    var diags: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diags.items) |d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    var ctx: Context = .{
        .gpa = gpa,
        .source = &src,
        .config = cfg,
        .diags = &diags,
        .current_lint = name,
        .current_severity = .@"error",
        .semantic = &sema,
    };
    try run(&ctx);
    return diags.items.len;
}

fn countDiags(gpa: std.mem.Allocator, src_text: []const u8) !usize {
    var cfg = Config.default();
    return countDiagsWith(gpa, src_text, &cfg);
}

const flag_bare_undefined_src = "const x = undefined;\n";

test "flags a bare undefined initializer" {
    try std.testing.expectEqual(
        @as(usize, 1),
        try countDiags(std.testing.allocator, flag_bare_undefined_src),
    );
}

const flag_non_destructor_write_src =
    "pub fn f(p: *u8) void {\n    p.* = undefined;\n}\n";

test "flags undefined written in a non-destructor function" {
    try std.testing.expectEqual(
        @as(usize, 1),
        try countDiags(std.testing.allocator, flag_non_destructor_write_src),
    );
}

const flag_comparison_src =
    "pub fn f(x: u8) bool {\n    return x == undefined;\n}\n";

test "flags a comparison against undefined (always flags)" {
    try std.testing.expectEqual(
        @as(usize, 1),
        try countDiags(std.testing.allocator, flag_comparison_src),
    );
}

const clean_array_src =
    "pub fn f() void {\n    var buf: [8]u8 = undefined;\n    _ = &buf;\n}\n";

test "clean: an array-typed local var-decl's undefined init is exempt" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, clean_array_src),
    );
}

const clean_test_src =
    "test \"t\" {\n    var x: u8 = undefined;\n    _ = &x;\n}\n";

test "clean: undefined inside a test block is exempt" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, clean_test_src),
    );
}

const clean_destructor_src =
    "pub fn deinit(self: *u8) void {\n    self.* = undefined;\n}\n";

test "clean: undefined inside a deinit function is exempt" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, clean_destructor_src),
    );
}

test "allow_arrays = false re-flags the array-typed var-decl case" {
    var cfg = Config.default();
    cfg.lints.unsafe_undefined.allow_arrays = false;
    const n = try countDiagsWith(std.testing.allocator, clean_array_src, &cfg);
    try std.testing.expectEqual(@as(usize, 1), n);
}

const comparison_in_destructor_src =
    "pub fn deinit(self: *u8) bool {\n    return self.* == undefined;\n}\n";

test "a comparison inside a destructor still flags (always-flag overrides)" {
    try std.testing.expectEqual(
        @as(usize, 1),
        try countDiags(std.testing.allocator, comparison_in_destructor_src),
    );
}

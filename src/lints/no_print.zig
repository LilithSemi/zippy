//! Flags a call to `std.debug.print` (or an aliased/bare form of it) outside
//! test code: `print` is meant for quick ad-hoc debugging, not production
//! logging -- it writes straight to stderr with no level, no timestamp, and
//! no way to route/filter it, unlike `std.log`. Adapted from zlint's
//! `no_print` rule (DonIsaac, MIT) to Zippy's `Semantic` scope tree, which is
//! what lets this distinguish a real `std.debug.print` call from a user's own
//! `fn print` that happens to share the name.
//!
//! ## Detection
//! For each call node (`.call`/`.call_comma`/`.call_one`/`.call_one_comma`),
//! read the callee via `tree.fullCall(&buf, node).ast.fn_expr`:
//!   - callee is a bare `.identifier` named `print`: resolve it via
//!     `sema.resolveBinding(sema.nodeScope(callee), "print", &.{.variable})`.
//!     A non-null result means the name resolves to a NON-variable local
//!     binding (a user-declared `fn print`) -- that's a deliberate shadow, so
//!     this returns without flagging. Excluding `.variable` from the lookup
//!     means a `const print = std.debug.print;` ALIAS is treated as "not a
//!     shadow" and still flags -- the alias didn't change what actually gets
//!     called, so it shouldn't change whether this lint fires (matches
//!     zlint's own behavior).
//!   - callee is a `.field_access` whose FIELD token is `print` and whose
//!     object's rightmost identifier (see `rightmostIdentifier`, copied from
//!     `homeless_try`) is `debug`: flags `std.debug.print(...)`,
//!     `x.debug.print(...)`, and a locally-aliased `debug.print(...)` alike.
//!     This is deliberately conservative -- it never resolves `std` itself
//!     through `Semantic` -- because `.debug.print` is already a strong
//!     enough signal on its own that resolving `std` would only add cost, not
//!     precision.
//!
//! ## Test exemption
//! Debug prints left in test code are common and harmless (tests never
//! ship), so by default (`allow_tests = true`, see `Config.NoPrintCfg`) a
//! call is skipped if either:
//!   - it sits inside a `.test_` scope anywhere up
//!     `sema.iterParents(sema.nodeScope(call_node))`, or
//!   - `ctx.source.path` ends with `test.zig` (a whole file dedicated to
//!     tests, even outside any single `test { ... }` block).
const std = @import("std");
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Semantic = @import("../Semantic.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Ast = std.zig.Ast;

pub const name = "no_print";
pub const group: Config.Group = .style;
pub const description: []const u8 =
    "`std.debug.print` writes straight to stderr with no level or " ++
    "filtering -- fine for a quick debug session, but not something " ++
    "that should ship. Use `std.log` for real logging instead. Calls " ++
    "inside test code are exempt by default (see the `allow_tests` " ++
    "config knob).";

const print_msg = "avoid `std.debug.print`; use `std.log` for real logging";

/// The rightmost identifier naming `node`, or `null` if `node` isn't a shape
/// this conservative check knows how to read one out of. Copied from
/// `homeless_try` (same reasoning: `Foo.Error` yields `"Error"`, a bare
/// `debug` yields itself, anything else yields `null` rather than guessing).
fn rightmostIdentifier(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    return switch (tree.nodeTag(node)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(node)),
        .field_access => tree.tokenSlice(tree.nodeData(node).node_and_token[1]),
        else => null,
    };
}

/// Whether `call_node` should be skipped per the file doc's "Test exemption"
/// section: its path ends `test.zig`, or its scope chain passes through a
/// `.test_` scope. Only called when `allow_tests` is on.
fn isTestExempt(ctx: *const Context, sema: *const Semantic, call_node: Ast.Node.Index) bool {
    if (std.mem.endsWith(u8, ctx.source.path, "test.zig")) return true;
    var it = sema.iterParents(sema.nodeScope(call_node));
    while (it.next()) |scope_id| {
        if (sema.scopeKind(scope_id) == .test_) return true;
    }
    return false;
}

/// The token to flag for `node` (a `print` call), or `null` if `node` isn't
/// one of the two flagged shapes (see the file doc's "Detection" section).
fn flagToken(tree: *const Ast, sema: *const Semantic, callee: Ast.Node.Index) ?Ast.TokenIndex {
    switch (tree.nodeTag(callee)) {
        .identifier => {
            const tok = tree.nodeMainToken(callee);
            if (!std.mem.eql(u8, tree.tokenSlice(tok), "print")) return null;
            const shadow = sema.resolveBinding(sema.nodeScope(callee), "print", &.{.variable});
            if (shadow != null) return null;
            return tok;
        },
        .field_access => {
            const object, const field_tok = tree.nodeData(callee).node_and_token;
            if (!std.mem.eql(u8, tree.tokenSlice(field_tok), "print")) return null;
            const object_name = rightmostIdentifier(tree, object) orelse return null;
            if (!std.mem.eql(u8, object_name, "debug")) return null;
            return field_tok;
        },
        else => return null,
    }
}

fn checkCall(
    ctx: *Context,
    tree: *const Ast,
    sema: *const Semantic,
    allow_tests: bool,
    node: Ast.Node.Index,
) Context.LintError!void {
    var buf: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buf, node) orelse return;
    const tok = flagToken(tree, sema, call.ast.fn_expr) orelse return;
    if (allow_tests and isTestExempt(ctx, sema, node)) return;
    const start = tree.tokenStart(tok);
    const end = start + @as(u32, @intCast(tree.tokenSlice(tok).len));
    try ctx.report(start, end, print_msg, .{});
}

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;
    const sema = ctx.semantic;
    const allow_tests = ctx.config.noPrintAllowTests();
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @enumFromInt(idx);
        switch (tree.nodeTag(node)) {
            .call, .call_comma, .call_one, .call_one_comma => {},
            else => continue,
        }
        try checkCall(ctx, tree, sema, allow_tests, node);
    }
}

fn countDiagsWith(
    gpa: std.mem.Allocator,
    path: []const u8,
    src_text: []const u8,
    cfg: *Config,
) !usize {
    var src = try Source.loadFromSlice(gpa, path, src_text);
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
        .current_severity = .warn,
        .semantic = &sema,
    };
    try run(&ctx);
    return diags.items.len;
}

fn countDiags(gpa: std.mem.Allocator, src_text: []const u8) !usize {
    var cfg = Config.default();
    return countDiagsWith(gpa, "t.zig", src_text, &cfg);
}

const std_debug_print_src = "pub fn f() void {\n    std.debug.print(\"x\", .{});\n}\n";

test "flags a direct std.debug.print call" {
    try std.testing.expectEqual(
        @as(usize, 1),
        try countDiags(std.testing.allocator, std_debug_print_src),
    );
}

const aliased_debug_print_src =
    \\const debug = std.debug;
    \\pub fn f() void {
    \\    debug.print("x", .{});
    \\}
    \\
;

test "flags debug.print through a locally aliased `debug`" {
    try std.testing.expectEqual(
        @as(usize, 1),
        try countDiags(std.testing.allocator, aliased_debug_print_src),
    );
}

const aliased_bare_print_src =
    \\const print = std.debug.print;
    \\pub fn f() void {
    \\    print("x", .{});
    \\}
    \\
;

test "flags a bare print(...) that is a `const print = std.debug.print;` alias" {
    try std.testing.expectEqual(
        @as(usize, 1),
        try countDiags(std.testing.allocator, aliased_bare_print_src),
    );
}

const shadowed_print_src =
    \\fn print(x: u8) void {
    \\    _ = x;
    \\}
    \\pub fn f() void {
    \\    print(1);
    \\}
    \\
;

test "clean: a local fn print shadows a bare print(...) call" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, shadowed_print_src),
    );
}

const std_log_debug_src = "pub fn f() void {\n    std.log.debug(\"x\", .{});\n}\n";

test "clean: std.log.debug is not std.debug.print" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, std_log_debug_src),
    );
}

const print_in_test_block_src =
    \\test "t" {
    \\    std.debug.print("x", .{});
    \\}
    \\
;

test "clean: std.debug.print inside a test block is exempt by default" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, print_in_test_block_src),
    );
}

test "clean: a source path ending test.zig is exempt regardless of scope" {
    var cfg = Config.default();
    const n = try countDiagsWith(
        std.testing.allocator,
        "widget_test.zig",
        std_debug_print_src,
        &cfg,
    );
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "allow_tests = false re-flags a print inside a test block" {
    var cfg = Config.default();
    cfg.lints.no_print.allow_tests = false;
    const n = try countDiagsWith(std.testing.allocator, "t.zig", print_in_test_block_src, &cfg);
    try std.testing.expectEqual(@as(usize, 1), n);
}

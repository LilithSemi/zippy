//! Flags `_ = expr;` assignments -- an explicit discard where a computed
//! value is thrown away. This is idiomatic Zig for silencing "unused
//! result" (e.g. `_ = someFn();`), but it's also how errors returned by a
//! fallible call get silently dropped instead of being handled or at least
//! `catch unreachable`'d, so it's worth surfacing for review.
//!
//! Detection is deliberately literal (IronStyle: a false positive here --
//! flagging a normal binding or a real assignment as a discard -- is much
//! worse than missing a rare shape): a node fires only when its tag is
//! `.assign` (an infix `lhs = rhs;`, as opposed to `const`/`var` decls,
//! which are `.simple_var_decl` and never reach this check) AND its LHS is
//! itself an `.identifier` node whose token text is exactly `"_"`. A real
//! assignment like `y = 5;` has an LHS identifier of `"y"`, not `"_"`, and
//! a declaration like `const x = compute();` isn't `.assign` at all, so
//! neither fires.
//!
//! The report spans exactly the `_` token on the LHS (one byte): that's the
//! part of `_ = expr;` this lint actually flags, and a precise one-byte span
//! (rather than the `=` sign) is what a fix mode would need to replace the
//! discard target.
const std = @import("std");
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Ast = std.zig.Ast;

pub const name = "discarded_error";
pub const group: Config.Group = .correctness;
pub const description: []const u8 =
    "`_ = expr;` throws a value away. Make sure discarding it is " ++
    "intentional; if it's an error union, handle or propagate it " ++
    "instead.";

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @enumFromInt(idx);
        if (tree.nodeTag(node) != .assign) continue;
        const lhs = tree.nodeData(node).node_and_node[0];
        if (tree.nodeTag(lhs) != .identifier) continue;
        const ident = tree.tokenSlice(tree.nodeMainToken(lhs));
        if (!std.mem.eql(u8, ident, "_")) continue;
        const start = tree.tokenStart(tree.nodeMainToken(lhs));
        try ctx.report(start, start + 1, "value discarded via '_ ='", .{});
    }
}

test "flags a discard assignment" {
    const gpa = std.testing.allocator;
    const s =
        \\pub fn f() void {
        \\    _ = compute();
        \\}
        \\fn compute() u8 { return 1; }
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

test "stays silent on a normal const binding" {
    const gpa = std.testing.allocator;
    const s =
        \\pub fn f() u8 {
        \\    const x = compute();
        \\    return x;
        \\}
        \\fn compute() u8 { return 1; }
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

test "stays silent on a real assignment to a named variable" {
    const gpa = std.testing.allocator;
    const s =
        \\pub fn f() void {
        \\    var y: u8 = 0;
        \\    y = 5;
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
    // `y = 5;` is a real assignment (LHS identifier "y", not "_") and must
    // stay silent. The linter only parses the source (never compiles it),
    // so `y` being otherwise unused doesn't affect this test.
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

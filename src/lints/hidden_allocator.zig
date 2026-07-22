//! Flags a reference to a named global allocator (`std.heap.page_allocator`
//! and friends) anywhere except inside `fn main`. IronStyle memory.md: pass
//! an allocator, do not reach for one you did not receive -- a function that
//! grabs a global allocator hides its allocation policy/lifetime from the
//! caller, and (for `page_allocator` specifically) is often much slower than
//! an arena or a caller-supplied allocator.
//!
//! Detection is conservative and literal: the flagged node must be the exact
//! field-access chain `std.heap.<name>` (receiver `std`, middle field `heap`,
//! final field one of `page_allocator`/`c_allocator`/`smp_allocator`/
//! `wasm_allocator`). Container-scope uses (e.g. `const g = std.heap.
//! page_allocator;` at file scope) ARE flagged -- there is no enclosing `fn
//! main` to exempt them, and a global allocator constant is exactly the
//! hidden-allocation pattern this lint exists to catch.
//!
//! Deliberately silent (false-negative biased) on:
//!   - An aliased path, e.g. `const heap = std.heap; heap.page_allocator;` --
//!     the receiver of the final field access is the identifier `heap`, not
//!     the literal chain `std.heap`, so `isStdHeap` never matches. Tracking
//!     aliases would need data-flow analysis beyond a single-node check.
//!   - `std.testing.allocator` -- that's `std.testing`, not `std.heap`, so
//!     `isStdHeap` rejects it outright; tests are unaffected.
//!   - Any use textually inside a function named `main` -- `main` is the one
//!     legitimate place a root allocator originates.
const std = @import("std");
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Ast = std.zig.Ast;

pub const name = "hidden_allocator";
pub const group: Config.Group = .memory;
pub const description: []const u8 =
    "Reaching for a global allocator (`std.heap.page_allocator` and friends) " ++
    "hides allocation from the caller. Take an `std.mem.Allocator` parameter " ++
    "instead, so the caller controls allocation policy and lifetime. Only " ++
    "`main` should originate a root allocator.";

fn isGlobalAllocName(s: []const u8) bool {
    return std.mem.eql(u8, s, "page_allocator") or
        std.mem.eql(u8, s, "c_allocator") or
        std.mem.eql(u8, s, "smp_allocator") or
        std.mem.eql(u8, s, "wasm_allocator");
}

/// True if `node` is the field access `std.heap` (receiver identifier `std`,
/// field `heap`).
fn isStdHeap(tree: *const Ast, node: Ast.Node.Index) bool {
    if (tree.nodeTag(node) != .field_access) return false;
    const recv, const field_tok = tree.nodeData(node).node_and_token;
    if (!std.mem.eql(u8, tree.tokenSlice(field_tok), "heap")) return false;
    if (tree.nodeTag(recv) != .identifier) return false;
    return std.mem.eql(u8, tree.tokenSlice(tree.firstToken(recv)), "std");
}

/// True if `tok` is inside a function named `main` (the one legitimate origin
/// of a root allocator).
fn inMain(tree: *const Ast, tok: Ast.TokenIndex) bool {
    var buf: [1]Ast.Node.Index = undefined;
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @enumFromInt(idx);
        if (tree.nodeTag(node) != .fn_decl) continue;
        const proto = tree.fullFnProto(&buf, node) orelse continue;
        const name_tok = proto.name_token orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(name_tok), "main")) continue;
        if (tree.firstToken(node) <= tok and tok <= tree.lastToken(node)) return true;
    }
    return false;
}

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @enumFromInt(idx);
        if (tree.nodeTag(node) != .field_access) continue;
        const recv, const field_tok = tree.nodeData(node).node_and_token;
        const field = tree.tokenSlice(field_tok);
        if (!isGlobalAllocName(field)) continue;
        if (!isStdHeap(tree, recv)) continue;
        if (inMain(tree, tree.firstToken(node))) continue;

        const start = tree.tokenStart(tree.firstToken(node));
        const end = tree.tokenStart(field_tok) + @as(u32, @intCast(field.len));
        try ctx.report(
            start,
            end,
            "uses global allocator 'std.heap.{s}'; take an allocator parameter instead",
            .{field},
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

test "flags std.heap.page_allocator in a non-main function" {
    try std.testing.expectEqual(@as(usize, 1), try countDiags(
        std.testing.allocator,
        "const std = @import(\"std\");\npub fn f() void {\n    " ++
            "const a = std.heap.page_allocator;\n    _ = a;\n}\n",
    ));
}
test "flags std.heap.c_allocator too" {
    try std.testing.expectEqual(@as(usize, 1), try countDiags(
        std.testing.allocator,
        "const std = @import(\"std\");\npub fn f() void {\n    " ++
            "const a = std.heap.c_allocator;\n    _ = a;\n}\n",
    ));
}
test "flags a global allocator at container scope" {
    try std.testing.expectEqual(@as(usize, 1), try countDiags(
        std.testing.allocator,
        "const std = @import(\"std\");\nconst g = std.heap.page_allocator;\n",
    ));
}
test "does not flag std.heap.page_allocator inside main" {
    try std.testing.expectEqual(@as(usize, 0), try countDiags(
        std.testing.allocator,
        "const std = @import(\"std\");\npub fn main() void {\n    " ++
            "const a = std.heap.page_allocator;\n    _ = a;\n}\n",
    ));
}
test "does not flag std.testing.allocator" {
    try std.testing.expectEqual(@as(usize, 0), try countDiags(
        std.testing.allocator,
        "const std = @import(\"std\");\npub fn f() void {\n    " ++
            "const a = std.testing.allocator;\n    _ = a;\n}\n",
    ));
}

//! Flags function declarations with more parameters than
//! `Config.tooManyParamsMax` (default 5) -- a proxy for "this function is
//! doing too many unrelated things and should take a struct or be split up".
//!
//! Like `naming_convention`, this walks the whole node table and matches
//! `fullFnProto` at every node. `fn_decl` (a fn with a body) delegates
//! `fullFnProto` to its wrapped `fn_proto*` node, which is *also* a
//! standalone node visited separately by this same loop -- so without a
//! guard, a function with a body would be matched (and reported) twice.
//! `fn_decl` is skipped here for that reason; the underlying `fn_proto*`
//! node still catches it exactly once, whether or not it has a body.
const std = @import("std");
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Ast = std.zig.Ast;

pub const name = "too_many_params";
pub const group: Config.Group = .complexity;
pub const description: []const u8 =
    "A function with many parameters is hard to call correctly and " ++
    "usually wants a struct of options. Bundle related parameters " ++
    "into a struct.";

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;
    const max = ctx.config.tooManyParamsMax();
    var fn_buf: [1]Ast.Node.Index = undefined;
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        // See the module doc comment: skip `fn_decl` so each function is
        // matched exactly once, via its underlying `fn_proto*` node.
        if (tree.nodeTag(node) == .fn_decl) continue;
        const proto = tree.fullFnProto(&fn_buf, node) orelse continue;
        // The iterator (not `proto.ast.params.len`) is the source of truth
        // for the param count: it also walks `anytype`/varargs params that
        // aren't present in the plain `params` slice.
        var count: u32 = 0;
        var it = proto.iterate(tree);
        while (it.next()) |_| count += 1;
        if (count > max) {
            const tok = proto.name_token orelse proto.ast.fn_token;
            const start = tree.tokenStart(tok);
            const end = start + tree.tokenSlice(tok).len;
            try ctx.report(
                start,
                end,
                "function has {d} parameters (max {d})",
                .{ count, max },
            );
        }
    }
}

test "flags a fn with more than max params" {
    const gpa = std.testing.allocator;
    const s = "pub fn many(a: u8, b: u8, c: u8, d: u8, e: u8, f: u8) void {}\n";
    var src = try Source.loadFromSlice(gpa, "t.zig", s);
    defer src.deinit(gpa);
    var cfg = Config.default(); // max = 5
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
    try std.testing.expect(std.mem.indexOf(u8, diags.items[0].message, "6 parameters") != null);
}

test "a fn with a body and few params fires once, not twice" {
    const gpa = std.testing.allocator;
    const s = "pub fn many(a: u8, b: u8, c: u8, d: u8, e: u8, f: u8) void {\n" ++
        "    _ = a;\n    _ = b;\n    _ = c;\n    _ = d;\n    _ = e;\n    _ = f;\n}\n";
    var src = try Source.loadFromSlice(gpa, "t.zig", s);
    defer src.deinit(gpa);
    var cfg = Config.default(); // max = 5
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

test "stays silent at exactly max params" {
    const gpa = std.testing.allocator;
    const s = "pub fn okay(a: u8, b: u8, c: u8, d: u8, e: u8) void {}\n";
    var src = try Source.loadFromSlice(gpa, "t.zig", s);
    defer src.deinit(gpa);
    var cfg = Config.default(); // max = 5
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

test "stays silent on a fn with a body and few params" {
    const gpa = std.testing.allocator;
    const s = "pub fn small(a: u8, b: u8) void {\n    _ = a;\n    _ = b;\n}\n";
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

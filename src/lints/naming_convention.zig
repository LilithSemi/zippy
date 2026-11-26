//! Flags declaration names that don't follow Zig's conventional casing:
//! function declarations should be `camelCase` and type-holding declarations
//! (`const Name = struct/union/enum/opaque {...}`) should be `TitleCase`.
//!
//! This walks the whole node table rather than following a specific parent
//! chain, so it catches functions and type decls at any nesting depth
//! (top-level, inside a container, inside a block) with one loop.
//!
//! Detection is deliberately conservative: a name is only flagged as "not
//! camelCase" if it starts uppercase, and "not TitleCase" if it starts
//! lowercase -- underscores past the first character, digits, etc. are left
//! alone. A false positive here (flagging correct code) is worse than a
//! false negative, so ambiguous cases (empty names, anonymous decls) are
//! skipped rather than guessed at.
const std = @import("std");
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Ast = std.zig.Ast;

pub const name = "naming_convention";
pub const group: Config.Group = .style;
pub const description: []const u8 =
    "Zig convention: functions are camelCase and type declarations " ++
    "(and type-returning functions) are TitleCase. Rename to match so " ++
    "call sites read consistently.";

/// camelCase: starts lowercase and contains no underscore. Zig's builtin
/// identifiers/keywords never reach here (the parser wouldn't have produced
/// a `name_token` for them), so no keyword-list carve-out is needed.
fn isCamelCase(s: []const u8) bool {
    if (s.len == 0) return true;
    if (!std.ascii.isLower(s[0])) return false;
    return std.mem.indexOfScalar(u8, s, '_') == null;
}

/// TitleCase: starts uppercase. Deliberately permissive about everything
/// after the first character (acronyms, digits, underscores) -- the skeleton
/// only enforces the leading-capital rule the brief calls for.
fn isTitleCase(s: []const u8) bool {
    if (s.len == 0) return true;
    return std.ascii.isUpper(s[0]);
}

/// True when `proto`'s return type is exactly the `type` primitive, e.g.
/// `fn ArrayList(comptime T: type) type { ... }`. Such a function is a type
/// constructor (Zig's generics idiom): it produces a type, so by convention
/// it is named TitleCase like the type it returns, not camelCase like an
/// ordinary function. Conservative: only a bare `type` identifier in return
/// position qualifies -- anything else (`!type`, `?type`, a type alias that
/// merely evaluates to `type`, etc.) falls through to the ordinary
/// camelCase rule, since those aren't the plain "this fn returns `type`"
/// shape and guessing further risks a false positive in the other
/// direction.
fn isTypeConstructor(tree: *const Ast, proto: Ast.full.FnProto) bool {
    const return_node = proto.ast.return_type.unwrap() orelse return false;
    if (tree.nodeTag(return_node) != .identifier) return false;
    return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(return_node)), "type");
}

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;
    var fn_buf: [1]Ast.Node.Index = undefined;
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        // `fn_decl` (a fn with a body) delegates `fullFnProto` to its
        // wrapped proto node -- which is *also* a standalone node in the
        // tree, visited separately by this same loop. Skip `fn_decl` here so
        // each function is matched exactly once, via its underlying
        // `fn_proto*` node (present whether or not the fn has a body).
        if (tree.nodeTag(node) == .fn_decl) continue;
        if (tree.fullFnProto(&fn_buf, node)) |proto| {
            const name_tok = proto.name_token orelse continue;
            const ident = tree.tokenSlice(name_tok);
            const start = tree.tokenStart(name_tok);
            const end = start + tree.tokenSlice(name_tok).len;
            if (isTypeConstructor(tree, proto)) {
                if (!isTitleCase(ident)) {
                    try ctx.report(
                        start,
                        end,
                        "function '{s}' returns a type and should be TitleCase",
                        .{ident},
                    );
                }
            } else if (!isCamelCase(ident)) {
                try ctx.report(
                    start,
                    end,
                    "function '{s}' should be camelCase",
                    .{ident},
                );
            }
        } else if (tree.fullVarDecl(node)) |decl| {
            const init_node = decl.ast.init_node.unwrap() orelse continue;
            var container_buf: [2]Ast.Node.Index = undefined;
            if (tree.fullContainerDecl(&container_buf, init_node) != null) {
                // Per Ast.zig's `simple_var_decl` grammar comment ("const
                // name_token: type_expr = init_expr"), the token right after
                // the `var`/`const` keyword (`mut_token`) is always the
                // declaration's name -- true for all of `simple_var_decl`,
                // `aligned_var_decl`, `local_var_decl`, and
                // `global_var_decl`, the four tags `fullVarDecl` covers.
                const name_tok = decl.ast.mut_token + 1;
                const ident = tree.tokenSlice(name_tok);
                if (!isTitleCase(ident)) {
                    const start = tree.tokenStart(name_tok);
                    const end = start + tree.tokenSlice(name_tok).len;
                    try ctx.report(
                        start,
                        end,
                        "type '{s}' should be TitleCase",
                        .{ident},
                    );
                }
            }
        }
    }
}

test "flags snake_case fn and lowercase type, stays silent on good names" {
    const gpa = std.testing.allocator;
    const s =
        \\pub fn Bad_Name() void {}
        \\const myType = struct { a: u8 };
        \\pub fn goodName() void {}
        \\const GoodType = struct { a: u8 };
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
    try std.testing.expectEqual(@as(usize, 2), diags.items.len);
    try std.testing.expect(std.mem.indexOf(u8, diags.items[0].message, "Bad_Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, diags.items[1].message, "myType") != null);
}

test "stays silent on a TitleCase type-constructor function" {
    const gpa = std.testing.allocator;
    const s =
        \\pub fn ArrayList(comptime T: type) type {
        \\    return undefined;
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
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "flags a lowercase type-constructor function as should-be-TitleCase" {
    const gpa = std.testing.allocator;
    const s =
        \\fn arrayList(comptime T: type) type {
        \\    return undefined;
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
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expect(std.mem.indexOf(u8, diags.items[0].message, "arrayList") != null);
}

test "diagnostic span covers exactly the flagged name token" {
    const gpa = std.testing.allocator;
    const s = "fn Bad_Name() void {}\n";
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
    const d = diags.items[0];
    try std.testing.expectEqual(@as(usize, "Bad_Name".len), d.end_offset - d.byte_offset);
}

test "stays silent on an empty file" {
    const gpa = std.testing.allocator;
    var src = try Source.loadFromSlice(gpa, "t.zig", "");
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

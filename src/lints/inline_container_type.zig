//! Flags an anonymous container type (`struct`/`union`/`enum`) written
//! INLINE -- as a param type, return type, or field type -- that has more
//! than `Config.inlineContainerMaxFields` fields (default 3). A container
//! that big deserves a name (a `pub const`) so call sites and other fields
//! can reference it, instead of being buried unnamed in a signature.
//!
//! The key distinction this lint has to get right: a container that IS the
//! init expression of a `const`/`var` decl (e.g. top-level
//! `const Named = struct { ... };`) is ALREADY named by that decl and must
//! be exempt, no matter how many fields it has. Getting this wrong would
//! make the lint fire on every reasonably-sized named struct in the
//! codebase, which is far worse (IronStyle: false positives are worse than
//! false negatives) than missing a rare shape.
//!
//! Two-pass approach: pass 1 walks every var decl (`fullVarDecl`) and
//! records its init node's index in a set -- those nodes are "named" and
//! exempt. Pass 2 walks every container decl (`fullContainerDecl`); any
//! node found in the "named" set is skipped, and the rest are counted for
//! fields (via `fullContainerField`, which distinguishes actual fields from
//! other container members like fns and consts) and reported if the count
//! exceeds the configured max.
//!
//! Pass 1 also records the operand of every `return` statement (`.@"return"`
//! node's `.opt_node`) in the same "named" set. `return struct { ... };` is
//! Zig's generic-factory idiom (`fn List(comptime T: type) type { return
//! struct { ... }; }`) -- the struct IS named, by the function that returns
//! it, exactly like a `const` decl names it. This is a different node than
//! a container written in RETURN-TYPE position (`fn f() struct {...} {...}`,
//! which lives in `proto.ast.return_type`): that shape is still an inline
//! anonymous type annotation with no name anywhere, so it must, and does,
//! keep firing.
const std = @import("std");
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Ast = std.zig.Ast;

pub const name = "inline_container_type";
pub const group: Config.Group = .style;
pub const description: []const u8 =
    "A large anonymous struct/union/enum written inline is hard to " ++
    "name and reuse. Hoist it into a named `pub const` type.";

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;
    const max = ctx.config.inlineContainerMaxFields();

    // Pass 1: collect the init-node index of every var decl (already named
    // by that decl) and the operand-node index of every `return` statement
    // (already named by the function that returns it -- the generic-factory
    // idiom). Either way, a container decl whose node index shows up here is
    // exempt.
    var named = std.AutoHashMap(Ast.Node.Index, void).init(ctx.gpa);
    defer named.deinit();
    {
        var idx: u32 = 0;
        while (idx < tree.nodes.len) : (idx += 1) {
            const node: Ast.Node.Index = @enumFromInt(idx);
            if (tree.fullVarDecl(node)) |decl| {
                if (decl.ast.init_node.unwrap()) |init_node| try named.put(init_node, {});
                continue;
            }
            if (tree.nodeTag(node) == .@"return") {
                if (tree.nodeData(node).opt_node.unwrap()) |operand| try named.put(operand, {});
            }
        }
    }

    // Pass 2: every container decl not in the "named" set is inline. Count
    // its actual fields (skipping fns/consts declared inside it) and report
    // if that count exceeds the configured max.
    var buf: [2]Ast.Node.Index = undefined;
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @enumFromInt(idx);
        const container = tree.fullContainerDecl(&buf, node) orelse continue;
        // The file root node (`.root`) also matches `fullContainerDecl` --
        // that's Zig's "this file is a struct" idiom, where top-level
        // fields are declared directly in the file. The root is already
        // named by the module/file itself (and by extension its import
        // path), so it must never be treated as an inline anonymous
        // container, regardless of field count.
        if (tree.nodeTag(node) == .root) continue;
        if (named.contains(node)) continue;
        var fields: u32 = 0;
        for (container.ast.members) |m| {
            if (tree.fullContainerField(m) != null) fields += 1;
        }
        if (fields > max) {
            const main_token = tree.nodeMainToken(node);
            const start = tree.tokenStart(main_token);
            const end = start + tree.tokenSlice(main_token).len;
            try ctx.report(
                start,
                end,
                "inline anonymous container with {d} fields should be a named pub const (max {d})",
                .{ fields, max },
            );
        }
    }
}

test "flags an inline over-threshold struct return type but not a named one" {
    const gpa = std.testing.allocator;
    const s =
        \\fn f() struct { a: u8, b: u8, c: u8, d: u8 } {
        \\    return .{ .a = 0, .b = 0, .c = 0, .d = 0 };
        \\}
        \\const Named = struct { a: u8, b: u8, c: u8, d: u8 };
        \\
    ;
    var src = try Source.loadFromSlice(gpa, "t.zig", s);
    defer src.deinit(gpa);
    var cfg = Config.default(); // max_fields = 3
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
    try std.testing.expect(std.mem.indexOf(u8, diags.items[0].message, "4 fields") != null);
}

test "stays silent on an inline container at the threshold" {
    const gpa = std.testing.allocator;
    const s =
        \\fn f() struct { a: u8, b: u8, c: u8 } {
        \\    return .{ .a = 0, .b = 0, .c = 0 };
        \\}
        \\
    ;
    var src = try Source.loadFromSlice(gpa, "t.zig", s);
    defer src.deinit(gpa);
    var cfg = Config.default(); // max_fields = 3
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

test "stays silent on a generic-factory return struct, but the return-type shape still fires" {
    const gpa = std.testing.allocator;
    const s =
        \\fn List(comptime T: type) type {
        \\    return struct { a: T, b: T, c: T, d: T };
        \\}
        \\fn f() struct { a: u8, b: u8, c: u8, d: u8 } {
        \\    return .{ .a = 0, .b = 0, .c = 0, .d = 0 };
        \\}
        \\
    ;
    var src = try Source.loadFromSlice(gpa, "t.zig", s);
    defer src.deinit(gpa);
    var cfg = Config.default(); // max_fields = 3
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
    // Only `f`'s return-TYPE struct fires; `List`'s `return struct {...};`
    // is exempt, since it's named by `List` itself.
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expect(std.mem.indexOf(u8, diags.items[0].message, "4 fields") != null);
}

test "stays silent on the file-as-struct root container over the threshold" {
    const gpa = std.testing.allocator;
    const s =
        \\a: u8,
        \\b: u8,
        \\c: u8,
        \\d: u8,
        \\
    ;
    var src = try Source.loadFromSlice(gpa, "t.zig", s);
    defer src.deinit(gpa);
    var cfg = Config.default(); // max_fields = 3
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

test "stays silent on a named container even over the threshold" {
    const gpa = std.testing.allocator;
    const s =
        \\const Named = struct { a: u8, b: u8, c: u8, d: u8, e: u8 };
        \\
    ;
    var src = try Source.loadFromSlice(gpa, "t.zig", s);
    defer src.deinit(gpa);
    var cfg = Config.default(); // max_fields = 3
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

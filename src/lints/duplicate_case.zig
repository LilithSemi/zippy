//! Flags a `switch` arm whose body (`=> body`) is structurally identical to
//! an earlier arm's body in the same switch -- almost always a copy-paste
//! that should either be merged into one arm's value list (`a, b => body`)
//! or was meant to differ and doesn't.
//!
//! Comparison is via `ast_eql.eql`, the shared conservative structural
//! comparator: a pair only fires when the comparator's whitelist positively
//! recognizes both bodies as the same shape (see that module for the
//! tag-by-tag rules), so an unfamiliar or ambiguous body shape is silently
//! skipped rather than guessed at.
//!
//! CAPTURE GUARD: a pair is skipped entirely if EITHER arm has a `|capture|`
//! payload token. A captured payload binds a different runtime value per
//! arm even when the body text is byte-for-byte the same (e.g. `.a => |v|
//! f(v), .b => |v| f(v)`), so "identical body" doesn't mean "mergeable" or
//! even "suspicious" there -- flagging it would be a false positive on
//! completely idiomatic code, which IronStyle treats as worse than missing
//! the (rare) genuinely duplicated captured case.
//!
//! Reports the LATER arm of each matching pair, and only against the FIRST
//! earlier arm it matches (the inner loop `break`s once it reports) -- so a
//! run of N structurally-identical arms yields N-1 diagnostics, one per
//! "this repeats an earlier one", not every pairwise combination.
//!
//! Group `.complexity` (warn by default, not `.correctness`/error): a
//! duplicate arm is a code smell worth a human's attention, but unlike e.g.
//! `discarded_error` it isn't evidence of a swallowed bug, and duplicated
//! bodies are sometimes written deliberately for readability (each case
//! spelled out even though two happen to coincide) -- not severe enough to
//! fail a build by default.
//!
//! Detection-only: no automatic fix. A safe merge would need to combine the
//! arms' value lists, delete one prong, and reconcile any capture/comment on
//! either side -- more machinery than is worth building for a rare finding.
//!
//! Ported from zlint's `duplicate-case` rule (DonIsaac/zlint, MIT) --
//! reimplemented against Zippy's own AST accessors and `ast_eql`, not copied.
const std = @import("std");
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const ast_eql = @import("../ast_eql.zig");
const Ast = std.zig.Ast;

pub const name = "duplicate_case";
pub const group: Config.Group = .complexity;
pub const description: []const u8 =
    "A switch arm's body is structurally identical to an earlier arm's " ++
    "body. Merge them (`a, b => body`) or make them differ. Skipped when " ++
    "either arm captures a payload (`|v|`), since the same body text then " ++
    "acts on a different value per arm.";

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        const sw = tree.fullSwitch(node) orelse continue;
        const cases = sw.ast.cases;
        for (1..cases.len) |j| {
            const cb = tree.fullSwitchCase(cases[j]) orelse continue;
            if (cb.payload_token != null) continue; // capture guard
            for (0..j) |i| {
                const ca = tree.fullSwitchCase(cases[i]) orelse continue;
                if (ca.payload_token != null) continue; // capture guard
                if (!ast_eql.eql(tree, ca.ast.target_expr, cb.ast.target_expr)) continue;
                try reportDuplicate(ctx, tree, ca.ast.target_expr, cb.ast.target_expr);
                break; // report cb once, against the first earlier match
            }
        }
    }
}

/// Reports `later` as a duplicate of `earlier`: the span covers `later`'s
/// full token range, and the message cites `earlier`'s source line so a
/// reader doesn't have to scroll up to find what it repeats.
fn reportDuplicate(
    ctx: *Context,
    tree: *const Ast,
    earlier: Ast.Node.Index,
    later: Ast.Node.Index,
) Context.LintError!void {
    const first_tok = tree.firstToken(later);
    const last_tok = tree.lastToken(later);
    const start = tree.tokenStart(first_tok);
    const end = tree.tokenStart(last_tok) + tree.tokenSlice(last_tok).len;
    const earlier_tok = tree.firstToken(earlier);
    const earlier_line =
        Diagnostic.lineColAt(ctx.source.bytes, tree.tokenStart(earlier_tok)).line;
    try ctx.report(
        start,
        end,
        "duplicate switch case: identical to the case at line {d}; " ++
            "merge them or make them differ",
        .{earlier_line},
    );
}

fn runSrc(gpa: std.mem.Allocator, src_text: []const u8) !usize {
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
        .current_severity = .warn,
    };
    try run(&ctx);
    return diags.items.len;
}

test "flags an else arm identical to a numeric-literal arm" {
    const gpa = std.testing.allocator;
    const s =
        \\pub fn f(n: u8) u8 {
        \\    return switch (n) {
        \\        1 => 1,
        \\        else => 1,
        \\    };
        \\}
        \\
    ;
    try std.testing.expectEqual(@as(usize, 1), try runSrc(gpa, s));
}

test "flags identical commutative-binop arm bodies" {
    const gpa = std.testing.allocator;
    const s =
        \\pub fn f(n: u8, y: u8) u8 {
        \\    return switch (n) {
        \\        1 => y + 1,
        \\        else => 1 + y,
        \\    };
        \\}
        \\
    ;
    try std.testing.expectEqual(@as(usize, 1), try runSrc(gpa, s));
}

test "flags identical call-expression arm bodies" {
    const gpa = std.testing.allocator;
    const s =
        \\pub fn f(n: u8, x: u8) u8 {
        \\    return switch (n) {
        \\        1 => f(x),
        \\        2 => f(x),
        \\        else => 0,
        \\    };
        \\}
        \\fn f(x: u8) u8 { return x; }
        \\
    ;
    try std.testing.expectEqual(@as(usize, 1), try runSrc(gpa, s));
}

test "flags identical block arm bodies" {
    const gpa = std.testing.allocator;
    const s =
        \\pub fn f(n: u8) u8 {
        \\    switch (n) {
        \\        1 => { return 1; },
        \\        else => { return 1; },
        \\    }
        \\}
        \\
    ;
    try std.testing.expectEqual(@as(usize, 1), try runSrc(gpa, s));
}

test "stays silent on distinct numeric-literal arm bodies" {
    const gpa = std.testing.allocator;
    const s =
        \\pub fn f(n: u8) u8 {
        \\    return switch (n) {
        \\        1 => 1,
        \\        2 => 2,
        \\        else => 0,
        \\    };
        \\}
        \\
    ;
    try std.testing.expectEqual(@as(usize, 0), try runSrc(gpa, s));
}

test "stays silent on non-commutative arm bodies that only look similar" {
    const gpa = std.testing.allocator;
    const s =
        \\pub fn f(n: u8, y: u8) u8 {
        \\    return switch (n) {
        \\        1 => y - 1,
        \\        else => 1 - y,
        \\    };
        \\}
        \\
    ;
    try std.testing.expectEqual(@as(usize, 0), try runSrc(gpa, s));
}

test "stays silent when call arms differ by callee" {
    const gpa = std.testing.allocator;
    const s =
        \\pub fn f(n: u8, x: u8) u8 {
        \\    return switch (n) {
        \\        1 => f(x),
        \\        else => g(x),
        \\    };
        \\}
        \\fn f(x: u8) u8 { return x; }
        \\fn g(x: u8) u8 { return x; }
        \\
    ;
    try std.testing.expectEqual(@as(usize, 0), try runSrc(gpa, s));
}

test "stays silent on identical-looking bodies when either arm captures" {
    const gpa = std.testing.allocator;
    const s =
        \\const U = union(enum) { a: u8, b: u8 };
        \\pub fn f(u: U, x: u8) u8 {
        \\    return switch (u) {
        \\        .a => |v| f2(v),
        \\        .b => |v| f2(v),
        \\    } + x;
        \\}
        \\fn f2(v: u8) u8 { return v; }
        \\
    ;
    try std.testing.expectEqual(@as(usize, 0), try runSrc(gpa, s));
}

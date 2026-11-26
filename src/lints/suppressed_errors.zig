//! Flags a `catch` whose body silently swallows the caught error (an empty
//! block) or discards it via `unreachable`. Adapted from zlint's
//! `suppressed-errors` rule (DonIsaac/zlint, MIT) -- reimplemented here from
//! scratch against Zippy's own AST-walking conventions, not copied.
//!
//! This lint is SOUND, unlike `discarded_error`: Zig only lets you write
//! `expr catch ...` when `expr`'s type is an error union (`E!T`), so every
//! `.@"catch"` node this walk finds is provably catching a real error --
//! there is no "is it even an error?" false-positive risk to guard against.
//! The only false positives left are shapes that are legitimately fine to
//! swallow, which is what the three exemptions below are for.
//!
//! Flagged shapes (inspect the `catch` body):
//!   - `catch {}` (including `catch |e| {}`/`catch |_| {}`, and a
//!     comment-only body -- a comment isn't a token, so it parses as the
//!     same empty block) -- the error vanishes with no trace.
//!   - `catch unreachable` and `catch { unreachable; }` -- the error is
//!     turned into undefined behavior on the error path instead of being
//!     handled.
//! A block with two or more statements, or a body that's any other single
//! expression (`catch @panic(...)`, `catch null`, `catch someExpr`), is
//! never flagged -- that's a real (if minimal) handling of the error, not a
//! silent discard.
//!
//! Exemptions (all default OFF, i.e. flag everywhere, per IronStyle "FP is
//! worse than FN" -- a user opts INTO a narrower lint, not out of a wrong
//! default):
//!   - `exempt_tests`: skip a catch textually inside a `test` block. A test
//!     that doesn't care about a specific failure mode swallowing it there
//!     is a common, low-risk idiom; production code isn't affected.
//!   - `exempt_writers`: skip `w.print()/writeAll()/...` (an `std.Io.Writer`-
//!     shaped method call) `catch {}`. Writer errors are almost always
//!     "the underlying sink went away" -- frequently not worth plumbing
//!     through every call site that formats output.
//!   - `exempt_defers`: skip a catch that is the direct expression of a
//!     `defer`/`errdefer` statement. A `defer` block can't propagate an
//!     error (there's nowhere for it to go), so `defer foo() catch {};` is
//!     a pragmatic, deliberate idiom rather than an oversight.
//! Each exemption is narrow and syntactic on purpose: it only recognizes the
//! exact shape it names, so turning one on can't accidentally silence a
//! swallow it wasn't meant to cover.
const std = @import("std");
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Ast = std.zig.Ast;

pub const name = "suppressed_errors";
pub const group: Config.Group = .correctness;
pub const description: []const u8 =
    "`catch {}` silently swallows the caught error; `catch unreachable` " ++
    "discards it into undefined behavior. Handle it, propagate it with " ++
    "`try`, or at least `@panic` on it. `exempt_tests`/`exempt_writers`/" ++
    "`exempt_defers` allow a few common, deliberate escape hatches.";

const msg_swallowed = "caught error silently swallowed by an empty `catch`";
const msg_unreachable =
    "caught error discarded with `unreachable`. Propagate it with `try`, " ++
    "or use `@panic`/handle it";

/// Method names that make a call "writer-shaped" for `exempt_writers`. Name-
/// based (no type resolution available here), so this is a heuristic: it can
/// under-match a differently-named writer wrapper (a false negative, which
/// IronStyle accepts) but can never over-match into a non-writer call unless
/// that call happens to share one of these fairly writer-specific names.
const writer_methods = [_][]const u8{
    "print",
    "write",
    "writeAll",
    "writeByte",
    "writeByteNTimes",
    "writeBytesNTimes",
    "writeStruct",
    "writeStructEndian",
};

fn eqAny(s: []const u8, opts: []const []const u8) bool {
    for (opts) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

/// How a `catch` body classifies, plus enough to point the diagnostic at the
/// right span. `unreachable_in_block` carries the inner `.unreachable_literal`
/// node (the `catch { unreachable; }` case) since that node's token, not the
/// body block's, is what the diagnostic should underline.
const Shape = union(enum) {
    swallowed,
    unreachable_bare,
    unreachable_in_block: Ast.Node.Index,
};

/// Classifies a `catch` body per the file doc comment's "Flagged shapes",
/// returning `null` for anything not flagged (>= 2 statements, or any other
/// single expression).
fn classifyBody(tree: *const Ast, body: Ast.Node.Index) ?Shape {
    return switch (tree.nodeTag(body)) {
        .block_two, .block_two_semicolon => blk: {
            const first, const second = tree.nodeData(body).opt_node_and_opt_node;
            if (second.unwrap() != null) break :blk null; // >= 2 statements
            const first_node = first.unwrap() orelse break :blk .swallowed;
            if (tree.nodeTag(first_node) != .unreachable_literal) break :blk null;
            break :blk .{ .unreachable_in_block = first_node };
        },
        .unreachable_literal => .unreachable_bare,
        else => null,
    };
}

/// True if `caught` is a call `recv.method(...)` where `method` is one of
/// `writer_methods` (see its doc comment). A non-call `caught` (e.g. a block
/// expression) is never writer-exempt, matching zlint's own behavior.
fn isWriterCall(tree: *const Ast, caught: Ast.Node.Index) bool {
    var buf: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buf, caught) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    _, const method_tok = tree.nodeData(call.ast.fn_expr).node_and_token;
    return eqAny(tree.tokenSlice(method_tok), &writer_methods);
}

/// True if `tok` lies inside some `test` block's own token range. There is no
/// "innermost" needed here (unlike `return_stack_local`'s `innermostFn`) --
/// `test` blocks never nest, so any containing match is THE match.
fn inTestDecl(tree: *const Ast, tok: Ast.TokenIndex) bool {
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        if (tree.nodeTag(node) != .test_decl) continue;
        if (tree.firstToken(node) <= tok and tok <= tree.lastToken(node)) return true;
    }
    return false;
}

/// One pass collecting every `defer`/`errdefer` statement's OWN deferred
/// expression node (not anything nested inside it) into a set, for
/// `exempt_defers`. Built only when that knob is on -- see `run`.
fn buildDeferSet(
    gpa: std.mem.Allocator,
    tree: *const Ast,
) std.mem.Allocator.Error!std.AutoHashMapUnmanaged(Ast.Node.Index, void) {
    var set: std.AutoHashMapUnmanaged(Ast.Node.Index, void) = .empty;
    errdefer set.deinit(gpa);
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        switch (tree.nodeTag(node)) {
            .@"defer", .@"errdefer" => try set.put(gpa, tree.nodeData(node).node, {}),
            else => {},
        }
    }
    return set;
}

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;
    const exempt_defers = ctx.config.suppressedErrorsExemptDefers();
    const exempt_writers = ctx.config.suppressedErrorsExemptWriters();
    const exempt_tests = ctx.config.suppressedErrorsExemptTests();

    var defer_set: std.AutoHashMapUnmanaged(Ast.Node.Index, void) = .empty;
    defer defer_set.deinit(ctx.gpa);
    if (exempt_defers) defer_set = try buildDeferSet(ctx.gpa, tree);

    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        if (tree.nodeTag(node) != .@"catch") continue;
        const caught, const body = tree.nodeData(node).node_and_node;
        const catch_tok = tree.nodeMainToken(node);

        const shape = classifyBody(tree, body) orelse continue;

        // Cheap-first: a hash lookup, then a tag-only call check, then the
        // O(n) test-ancestor scan -- so a catch that's never exempt never
        // pays for the more expensive checks.
        if (exempt_defers and defer_set.contains(node)) continue;
        if (exempt_writers and isWriterCall(tree, caught)) continue;
        if (exempt_tests and inTestDecl(tree, catch_tok)) continue;

        switch (shape) {
            .swallowed => {
                const last_tok = tree.lastToken(body);
                const start = tree.tokenStart(catch_tok);
                const end = tree.tokenStart(last_tok) + tree.tokenSlice(last_tok).len;
                try ctx.report(start, end, msg_swallowed, .{});
            },
            .unreachable_bare => {
                const tok = tree.nodeMainToken(body);
                const start = tree.tokenStart(tok);
                try ctx.report(start, start + tree.tokenSlice(tok).len, msg_unreachable, .{});
            },
            .unreachable_in_block => |inner| {
                const tok = tree.nodeMainToken(inner);
                const start = tree.tokenStart(tok);
                try ctx.report(start, start + tree.tokenSlice(tok).len, msg_unreachable, .{});
            },
        }
    }
}

fn countDiags(gpa: std.mem.Allocator, cfg: *Config, src_text: []const u8) !usize {
    var src = try Source.loadFromSlice(gpa, "t.zig", src_text);
    defer src.deinit(gpa);
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
    };
    try run(&ctx);
    return diags.items.len;
}

const src_g = "fn g() !void { return; }\n";

test "flags catch {}" {
    var cfg = Config.default();
    const s = "pub fn f() void {\n    g() catch {};\n}\n" ++ src_g;
    try std.testing.expectEqual(@as(usize, 1), try countDiags(std.testing.allocator, &cfg, s));
}

test "flags catch |_| {}" {
    var cfg = Config.default();
    const s = "pub fn f() void {\n    g() catch |_| {};\n}\n" ++ src_g;
    try std.testing.expectEqual(@as(usize, 1), try countDiags(std.testing.allocator, &cfg, s));
}

test "flags a comment-only catch block" {
    var cfg = Config.default();
    const s = "pub fn f() void {\n    g() catch {\n        // ignored\n    };\n}\n" ++ src_g;
    try std.testing.expectEqual(@as(usize, 1), try countDiags(std.testing.allocator, &cfg, s));
}

test "flags catch unreachable" {
    var cfg = Config.default();
    const s = "pub fn f() void {\n    g() catch unreachable;\n}\n" ++ src_g;
    try std.testing.expectEqual(@as(usize, 1), try countDiags(std.testing.allocator, &cfg, s));
}

test "flags catch { unreachable; }" {
    var cfg = Config.default();
    const s = "pub fn f() void {\n    g() catch { unreachable; };\n}\n" ++ src_g;
    try std.testing.expectEqual(@as(usize, 1), try countDiags(std.testing.allocator, &cfg, s));
}

test "stays silent on catch @panic(...)" {
    var cfg = Config.default();
    const s = "pub fn f() void {\n    g() catch @panic(\"x\");\n}\n" ++ src_g;
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, &cfg, s));
}

test "stays silent on catch null" {
    var cfg = Config.default();
    const s = "pub fn f() void {\n    g() catch null;\n}\n" ++ "fn g() !?u8 { return null; }\n";
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, &cfg, s));
}

test "stays silent on a single non-unreachable statement" {
    var cfg = Config.default();
    const s = "pub fn f() void {\n    g() catch { h(); };\n}\n" ++ src_g ++ "fn h() void {}\n";
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, &cfg, s));
}

test "stays silent on a two-statement catch block" {
    var cfg = Config.default();
    const s = "pub fn f() void {\n    g() catch { h(); h(); };\n}\n" ++ src_g ++ "fn h() void {}\n";
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, &cfg, s));
}

test "exempt_tests silences a catch in a test; default flags it" {
    const s = "test \"t\" {\n    g() catch {};\n}\n" ++ src_g;
    var default_cfg = Config.default();
    try std.testing.expectEqual(
        @as(usize, 1),
        try countDiags(std.testing.allocator, &default_cfg, s),
    );

    const gpa = std.testing.allocator;
    var exempt_cfg = try Config.loadFromSlice(
        gpa,
        ".{ .lints = .{ .suppressed_errors = .{ .exempt_tests = true } } }",
    );
    try std.testing.expectEqual(@as(usize, 0), try countDiags(gpa, &exempt_cfg, s));
}

test "exempt_writers silences a writer-shaped call; default flags it" {
    const s = "pub fn f(w: anytype) void {\n    w.writeAll(\"x\") catch {};\n}\n";
    var default_cfg = Config.default();
    try std.testing.expectEqual(
        @as(usize, 1),
        try countDiags(std.testing.allocator, &default_cfg, s),
    );

    const gpa = std.testing.allocator;
    var exempt_cfg = try Config.loadFromSlice(
        gpa,
        ".{ .lints = .{ .suppressed_errors = .{ .exempt_writers = true } } }",
    );
    try std.testing.expectEqual(@as(usize, 0), try countDiags(gpa, &exempt_cfg, s));
}

test "exempt_writers doesn't exempt a non-call caught expression" {
    // A parenthesized (grouped-expression) catch target is never call-shaped
    // at the AST level, so it stays flagged even with `exempt_writers` on.
    const gpa = std.testing.allocator;
    const s = "pub fn f() void {\n    (g()) catch {};\n}\n" ++ src_g;
    var exempt_cfg = try Config.loadFromSlice(
        gpa,
        ".{ .lints = .{ .suppressed_errors = .{ .exempt_writers = true } } }",
    );
    try std.testing.expectEqual(@as(usize, 1), try countDiags(gpa, &exempt_cfg, s));
}

test "exempt_defers silences a defer's direct catch; default flags it" {
    const s = "pub fn f() void {\n    defer g() catch {};\n}\n" ++ src_g;
    var default_cfg = Config.default();
    try std.testing.expectEqual(
        @as(usize, 1),
        try countDiags(std.testing.allocator, &default_cfg, s),
    );

    const gpa = std.testing.allocator;
    var exempt_cfg = try Config.loadFromSlice(
        gpa,
        ".{ .lints = .{ .suppressed_errors = .{ .exempt_defers = true } } }",
    );
    try std.testing.expectEqual(@as(usize, 0), try countDiags(gpa, &exempt_cfg, s));
}

test "exempt_defers also silences an errdefer's direct catch" {
    const gpa = std.testing.allocator;
    const s = "pub fn f() void {\n    errdefer g() catch {};\n}\n" ++ src_g;
    var exempt_cfg = try Config.loadFromSlice(
        gpa,
        ".{ .lints = .{ .suppressed_errors = .{ .exempt_defers = true } } }",
    );
    try std.testing.expectEqual(@as(usize, 0), try countDiags(gpa, &exempt_cfg, s));
}

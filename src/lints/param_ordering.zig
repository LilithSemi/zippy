//! Flags a function whose leading parameters don't follow the canonical
//! order: `self`, then a `comptime <name>: type` generic parameter, then
//! `io`, then the allocator, then everything else -- with the `io`/allocator
//! positions configurable via
//! `Config.paramOrderingIo`/`Config.paramOrderingAllocator`.
//!
//! Each parameter is classified into a `Key{ bucket, pos }`
//! (`self` < a `comptime … : type` generic < `front`-anchored resources <
//! `other` < `back`-anchored resources, then by configured `pos` within a
//! bucket). A function is
//! compliant iff its parameters' keys are non-decreasing left-to-right; the
//! FIRST parameter whose key drops below the one before it is reported
//! (one diagnostic per function -- later misorderings in the same
//! parameter list are consequences of the first, not separate bugs).
//!
//! Detection is AST-only (name + type text), and deliberately conservative:
//! `self`/`this` (case-sensitive, underscores stripped) is `self`; a param
//! named `io` OR typed `std.Io`/`Io` (exact type text) is `io`; a param
//! named `allocator`/`alloc`/`gpa`/`arena` (underscores stripped) OR whose
//! type text ends in `Allocator` is the allocator; a `comptime <name>: type`
//! generic type parameter (the `comptime` keyword AND type text exactly
//! `type`) leads, right after `self` -- but a comptime VALUE param (e.g.
//! `comptime fmt: []const u8`) is NOT special-cased and stays `other`;
//! everything else -- including ambiguous names -- is `other`, so this only
//! ever fires on a clear key decrease, never on a guess.
//!
//! A method's receiver must be named `self`/`this` to be recognized as the
//! `self` anchor. A value receiver under any other name (e.g.
//! `fn deinit(d: Diagnostic, gpa: Allocator)`) is classified `other`, so the
//! allocator is then expected before it -- i.e. this lint also nudges
//! receivers toward the conventional `self`/`this` name (name detection is
//! deliberate: without type resolution there is no other way to tell a value
//! receiver apart from an ordinary by-value argument).
const std = @import("std");
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Ast = std.zig.Ast;

pub const name = "param_ordering";
pub const group: Config.Group = .style;
pub const description: []const u8 =
    "A function's leading parameters should follow a canonical order " ++
    "(`self`, then `io`, then the allocator, then the rest -- positions are " ++
    "configurable). Name a method receiver `self`/`this` so it is recognized " ++
    "as the anchor. Consistent ordering makes call sites easier to read.";

const Bucket = enum(u8) { self = 0, comptime_type = 1, front = 2, other = 3, back = 4 };

/// A parameter's sort key. A function is compliant iff its params' keys are
/// non-decreasing by `(bucket, pos)` lexicographically.
const Key = struct {
    bucket: Bucket,
    pos: isize,
    fn less(a: Key, b: Key) bool {
        if (a.bucket != b.bucket) return @backingInt(a.bucket) < @backingInt(b.bucket);
        return a.pos < b.pos;
    }
};

/// `pos >= 0` -> front bucket at that position; `pos < 0` -> back bucket.
fn keyForPos(pos: isize) Key {
    return if (pos >= 0) .{ .bucket = .front, .pos = pos } else .{ .bucket = .back, .pos = pos };
}

fn coreName(n: []const u8) []const u8 {
    var t = n;
    while (t.len > 0 and t[0] == '_') t = t[1..];
    while (t.len > 0 and t[t.len - 1] == '_') t = t[0 .. t.len - 1];
    return t;
}
fn eqAny(s: []const u8, opts: []const []const u8) bool {
    for (opts) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

/// Source text of a param's type expression, or "" for `anytype`/none.
fn typeText(bytes: []const u8, tree: *const Ast, type_expr: ?Ast.Node.Index) []const u8 {
    const node = type_expr orelse return "";
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    const start = tree.tokenStart(first);
    const end = tree.tokenStart(last) + @as(u32, @intCast(tree.tokenSlice(last).len));
    return bytes[start..end];
}

/// A `comptime <name>: type` parameter (a generic type parameter). Deliberately
/// NOT a comptime VALUE param like `comptime fmt: []const u8` or `comptime len:
/// usize` -- those stay `other`, so a format-string-style param isn't forced to
/// the front. A type parameter conventionally leads (after `self`), so it gets
/// its own bucket ahead of `io`/the allocator.
fn isComptimeType(tree: *const Ast, param: Ast.full.FnProto.Param, ty: []const u8) bool {
    const tok = param.comptime_noalias orelse return false;
    if (tree.tokenTag(tok) != .keyword_comptime) return false; // could be `noalias`
    return std.mem.eql(u8, ty, "type");
}

/// Classify a param into its sort key (see the file doc comment for the
/// name/type detection heuristics).
fn classify(
    bytes: []const u8,
    tree: *const Ast,
    param: Ast.full.FnProto.Param,
    io_pos: isize,
    alloc_pos: isize,
) Key {
    const nm = if (param.name_token) |t| coreName(tree.tokenSlice(t)) else "";
    const ty = typeText(bytes, tree, param.type_expr);
    if (eqAny(nm, &.{ "self", "this" })) return .{ .bucket = .self, .pos = 0 };
    if (isComptimeType(tree, param, ty)) return .{ .bucket = .comptime_type, .pos = 0 };
    if (std.mem.eql(u8, nm, "io") or eqAny(ty, &.{ "std.Io", "Io" })) return keyForPos(io_pos);
    if (eqAny(nm, &.{ "allocator", "alloc", "gpa", "arena" }) or
        std.mem.endsWith(u8, ty, "Allocator")) return keyForPos(alloc_pos);
    return .{ .bucket = .other, .pos = 0 };
}

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;
    const bytes = ctx.source.bytes;
    const io_pos = ctx.config.paramOrderingIo();
    const alloc_pos = ctx.config.paramOrderingAllocator();
    var fn_buf: [1]Ast.Node.Index = undefined;
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        if (tree.nodeTag(node) == .fn_decl) continue; // match each fn once
        const proto = tree.fullFnProto(&fn_buf, node) orelse continue;

        var it = proto.iterate(tree);
        var prev_key: ?Key = null;
        var prev_name: []const u8 = "";
        while (it.next()) |param| {
            const nm = if (param.name_token) |t| tree.tokenSlice(t) else "parameter";
            const k = classify(bytes, tree, param, io_pos, alloc_pos);
            if (prev_key) |pk| {
                if (Key.less(k, pk)) {
                    // `param` sorts before the one before it -> misplaced.
                    const fallback = if (param.type_expr) |te|
                        tree.firstToken(te)
                    else
                        (proto.name_token orelse proto.ast.fn_token);
                    const rep_tok = param.name_token orelse fallback;
                    const start = tree.tokenStart(rep_tok);
                    const end = start + @as(u32, @intCast(tree.tokenSlice(rep_tok).len));
                    try ctx.report(
                        start,
                        end,
                        "parameter '{s}' should come before '{s}'",
                        .{ nm, prev_name },
                    );
                    break; // one diagnostic per function
                }
            }
            prev_key = k;
            prev_name = nm;
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
        .current_severity = .warn,
    };
    try run(&ctx);
    return diags.items.len;
}

test "default: io before allocator is clean; allocator before io flags" {
    const gpa = std.testing.allocator;
    var cfg = Config.default();
    const clean = "pub fn f(io: std.Io, gpa: std.mem.Allocator, p: u8) void {}\n";
    try std.testing.expectEqual(@as(usize, 0), try countDiags(gpa, &cfg, clean));
    const bad = "pub fn f(gpa: std.mem.Allocator, io: std.Io, p: u8) void {}\n";
    try std.testing.expectEqual(@as(usize, 1), try countDiags(gpa, &cfg, bad));
}
test "default: two allocators before io flags; allocator after other flags" {
    const gpa = std.testing.allocator;
    var cfg = Config.default();
    const two_allocs =
        "pub fn f(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io) void {}\n";
    try std.testing.expectEqual(@as(usize, 1), try countDiags(gpa, &cfg, two_allocs));
    const alloc_after_other = "pub fn f(x: u8, allocator: std.mem.Allocator) void {}\n";
    try std.testing.expectEqual(@as(usize, 1), try countDiags(gpa, &cfg, alloc_after_other));
}
test "self anchors the front; io absent packs the allocator up" {
    const gpa = std.testing.allocator;
    var cfg = Config.default();
    const self_io_gpa = "pub fn f(self: *T, io: std.Io, gpa: std.mem.Allocator) void {}\n";
    try std.testing.expectEqual(@as(usize, 0), try countDiags(gpa, &cfg, self_io_gpa));
    const self_gpa = "pub fn f(self: *T, gpa: std.mem.Allocator) void {}\n";
    try std.testing.expectEqual(@as(usize, 0), try countDiags(gpa, &cfg, self_gpa));
    const self_gpa_io = "pub fn f(self: *T, gpa: std.mem.Allocator, io: std.Io) void {}\n";
    try std.testing.expectEqual(@as(usize, 1), try countDiags(gpa, &cfg, self_gpa_io));
}
test "io detected by TYPE not just name; std.Io.Dir is not io" {
    const gpa = std.testing.allocator;
    var cfg = Config.default();
    // `s: std.Io` (named s, typed std.Io) is io -> must precede the allocator.
    const typed_io = "pub fn f(gpa: std.mem.Allocator, s: std.Io) void {}\n";
    try std.testing.expectEqual(@as(usize, 1), try countDiags(gpa, &cfg, typed_io));
    // `dir: std.Io.Dir` is `other`, not io -> clean.
    const dir_type = "pub fn f(gpa: std.mem.Allocator, dir: std.Io.Dir) void {}\n";
    try std.testing.expectEqual(@as(usize, 0), try countDiags(gpa, &cfg, dir_type));
}
test "no false flags on other-only params or tiny fns" {
    const gpa = std.testing.allocator;
    var cfg = Config.default();
    const others = "pub fn f(a: u8, b: u8, c: u8) void {}\n";
    try std.testing.expectEqual(@as(usize, 0), try countDiags(gpa, &cfg, others));
    const one_alloc = "pub fn f(gpa: std.mem.Allocator) void {}\n";
    try std.testing.expectEqual(@as(usize, 0), try countDiags(gpa, &cfg, one_alloc));
    try std.testing.expectEqual(@as(usize, 0), try countDiags(gpa, &cfg, "pub fn f() void {}\n"));
}
test "configurable: allocator = -1 requires the allocator last" {
    const gpa = std.testing.allocator;
    var cfg = try Config.loadFromSlice(
        gpa,
        ".{ .lints = .{ .param_ordering = .{ .allocator = -1 } } }",
    );
    const alloc_last = "pub fn f(io: std.Io, x: u8, gpa: std.mem.Allocator) void {}\n";
    try std.testing.expectEqual(@as(usize, 0), try countDiags(gpa, &cfg, alloc_last));
    const alloc_not_last = "pub fn f(io: std.Io, gpa: std.mem.Allocator, x: u8) void {}\n";
    try std.testing.expectEqual(@as(usize, 1), try countDiags(gpa, &cfg, alloc_not_last));
}

test "comptime type parameter leads (after self), before io/allocator" {
    const gpa = std.testing.allocator;
    var cfg = Config.default();
    // A generic type param first, then the allocator -> clean.
    const type_first = "pub fn f(comptime T: type, gpa: std.mem.Allocator, x: T) void {}\n";
    try std.testing.expectEqual(@as(usize, 0), try countDiags(gpa, &cfg, type_first));
    // self, then comptime type, then io, then allocator -> clean.
    const with_self = "pub fn f(self: *X, comptime T: type, io: std.Io," ++
        " gpa: std.mem.Allocator) void {}\n";
    try std.testing.expectEqual(@as(usize, 0), try countDiags(gpa, &cfg, with_self));
    // Allocator before the type param -> flags (the type param should lead).
    const alloc_first = "pub fn f(gpa: std.mem.Allocator, comptime T: type) void {}\n";
    try std.testing.expectEqual(@as(usize, 1), try countDiags(gpa, &cfg, alloc_first));
}
test "a comptime VALUE param (not `: type`) stays `other`, not bucketed to the front" {
    const gpa = std.testing.allocator;
    var cfg = Config.default();
    // `comptime fmt: []const u8` is a value, not a type -> classified `other`,
    // so it stays where it is; the allocator need not precede it.
    const val = "pub fn f(gpa: std.mem.Allocator, comptime fmt: []const u8) void {}\n";
    try std.testing.expectEqual(@as(usize, 0), try countDiags(gpa, &cfg, val));
}

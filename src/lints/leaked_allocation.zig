//! Flags a local bound to an allocator-call result (`const x = a.alloc(...)`)
//! that is used only in place (`x[i]`, `x.len`, `_ = x;`) and never freed,
//! returned, stored, or otherwise handed off -- the allocation is leaked the
//! moment the enclosing scope exits.
//!
//! ## Detection
//! Built entirely on the shared `alloc_track` substrate: `alloc_track.analyze`
//! finds every allocator-bound local in the file and classifies EVERY
//! reference to it into a `RefRole` (`contained`/`release`/`free`/
//! `reassign`). This lint's own logic is a single check per tracked local:
//! `alloc_track.isContainedOnly` -- true iff every one of its references is
//! `.contained`. Per `alloc_track`'s soundness rule (see its file doc),
//! `.release` is the DEFAULT for any reference shape the substrate doesn't
//! specifically recognize as `.contained`, so a false `.contained` verdict
//! (and thus a false leak report here) can only happen if the substrate's
//! classifier itself has a gap -- never because this lint guesses. Any
//! `free`/`release`/`reassign` reference anywhere suppresses the report: a
//! free obviously frees it, and an escape (`release`) means SOME other code
//! now owns the allocation and this lint has no way to know whether that
//! code frees it -- assuming leak would be the false positive IronStyle
//! forbids, so it stays silent instead (false-negative biased, by design).
const std = @import("std");
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Semantic = @import("../Semantic.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const alloc_track = @import("../alloc_track.zig");

pub const name = "leaked_allocation";
pub const group: Config.Group = .memory;
pub const description: []const u8 =
    "An allocator-bound local that is only ever used in place (indexed, " ++
    "read, or discarded) and never freed, returned, or passed onward leaks " ++
    "the moment its scope exits. Free it with `defer <allocator>.free(...)`, " ++
    "or return/hand off ownership if the caller should own it instead.";

const leak_msg = "allocation is never freed or transferred; add " ++
    "`defer <allocator>.free(...)` or return/hand off ownership";

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;
    const tracked = try alloc_track.analyze(ctx.gpa, ctx.semantic, tree);
    defer alloc_track.free(ctx.gpa, tracked);

    for (tracked) |t| {
        if (!alloc_track.isContainedOnly(t)) continue;
        const start = tree.tokenStart(t.name_token);
        const end = start + @as(u32, @intCast(tree.tokenSlice(t.name_token).len));
        try ctx.report(start, end, leak_msg, .{});
    }
}

fn countDiags(gpa: std.mem.Allocator, src_text: []const u8) !usize {
    var src = try Source.loadFromSlice(gpa, "t.zig", src_text);
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);
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
        .semantic = &sema,
    };
    try run(&ctx);
    return diags.items.len;
}

const leaked_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    x[0] = 1;
    \\}
    \\
;

test "flags an allocation used only in place, never freed" {
    try std.testing.expectEqual(@as(usize, 1), try countDiags(std.testing.allocator, leaked_src));
}

const freed_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    x[0] = 1;
    \\    defer a.free(x);
    \\}
    \\
;

test "clean: defer a.free(x) suppresses the leak" {
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, freed_src));
}

const returned_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) ![]u8 {
    \\    const x = a.alloc(u8, 4) catch return error.OutOfMemory;
    \\    return x;
    \\}
    \\
;

test "clean: returning the allocation suppresses the leak" {
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, returned_src));
}

const passed_src =
    \\const std = @import("std");
    \\fn foo(v: []u8) void {
    \\    _ = v;
    \\}
    \\pub fn f(a: std.mem.Allocator) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    foo(x);
    \\}
    \\
;

test "clean: passing the allocation to another fn suppresses the leak" {
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, passed_src));
}

const deinit_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    x.deinit();
    \\}
    \\
;

test "clean: x.deinit() suppresses the leak" {
    try std.testing.expectEqual(@as(usize, 0), try countDiags(std.testing.allocator, deinit_src));
}

const reslice_returned_src =
    \\const std = @import("std");
    \\pub fn g(a: std.mem.Allocator, n: usize) ![]u8 {
    \\    const x = try a.alloc(u8, 8);
    \\    return x[0..n];
    \\}
    \\
;

test "clean: return x[0..n] (reslice-and-return) does not leak (FIX C1)" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, reslice_returned_src),
    );
}

const non_alloc_src =
    \\fn compute() u8 {
    \\    return 1;
    \\}
    \\pub fn f() void {
    \\    const y = compute();
    \\    _ = y;
    \\}
    \\
;

test "clean: a non-alloc local is never tracked, let alone flagged" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, non_alloc_src),
    );
}

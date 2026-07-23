//! Flags a later use of an allocation after it has already been freed
//! (`a.free(x); ...; x[0] = 1;`), and a straight-line double free
//! (`a.free(x); a.free(x);`). Both build on the same `alloc_track` substrate
//! as `leaked_allocation`, over the same `Tracked`/`Event` data --
//! `alloc_track.analyze` already classified every reference to an
//! allocator-bound local into a `RefRole` (`contained`/`release`/`free`/
//! `reassign`) with its token, enclosing scope, whether it sits inside a
//! `defer`/`errdefer`, and whether it runs UNCONDITIONALLY within its own
//! scope.
//!
//! ## CONTROL-FLOW-BLIND: the guards are load-bearing
//! This module has no data-flow analysis -- it only compares token positions
//! and scope ids among a symbol's events. Three guards keep that safe (see
//! `alloc_track`'s own soundness rule for why a false positive is the
//! cardinal sin here):
//! - SAME SCOPE ONLY: a free/use pair is only ever compared when both
//!   `Event.scope` are IDENTICAL. A free nested inside `if (c) { ... }` lives
//!   in that block's own scope, so it never "reaches" a use in the
//!   surrounding scope -- conservative, but correct: this module can't tell
//!   whether the `if` actually ran, so it never guesses.
//! - BOTH SIDES UNCONDITIONAL: `Semantic` only creates a scope for
//!   `if`/`while`/`for` WITH a capture or braces, so a BRACELESS conditional
//!   body (`if (!c) a.free(x);`) shares its enclosing block's scope with
//!   everything after it -- same-scope alone can't tell that free apart from
//!   an unconditional one further down. Requiring `Event.unconditional_in_
//!   scope` on BOTH the free and the use/free being compared closes that
//!   gap without needing `Semantic` to grow new scopes for braceless bodies.
//! - NO REASSIGN BETWEEN: a `.reassign` event strictly between a free and a
//!   later use means the local was rebound to a fresh value first
//!   (`free(x); x = alloc(...); use(x);`) -- the "old" allocation was freed,
//!   but `x` no longer refers to it by the time of the later reference, so
//!   that pattern is never flagged.
//! Missing cross-branch/cross-scope cases is expected and fine
//! (false-negative-safe); this only ever fires on same-block straight-line
//! patterns it can prove.
//!
//! A `defer`/`errdefer` free is EXCLUDED from BOTH checks below on purpose:
//! its body runs unconditionally at scope exit, so a use-after-free can
//! never be proven against it the same way (see `checkUseAfterFree`'s own
//! doc), and double-free detection against a `defer` needs real
//! control-flow reasoning this module doesn't have -- see
//! `checkDoubleFree`'s doc for why that shape was dropped rather than
//! guessed at.
const std = @import("std");
const Ast = std.zig.Ast;
const Config = @import("../Config.zig");
const Context = @import("../Context.zig");
const Semantic = @import("../Semantic.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const alloc_track = @import("../alloc_track.zig");

pub const name = "use_after_free";
pub const group: Config.Group = .memory;
pub const description: []const u8 =
    "A use of an allocator-bound local after it has already been freed, " ++
    "or freeing it a second time, is undefined behavior. Only fires on " ++
    "same-block straight-line patterns it can prove -- move the free later, " ++
    "or don't free until every use of the value is done.";

/// `tree` plus the run-wide dedup set, bundled (per `too_many_params`' own
/// advice) so `reportOnce` and the two check functions below stay under the
/// param-count limit instead of threading both through every call.
const Reporter = struct {
    tree: *const Ast,
    reported: *std.AutoHashMapUnmanaged(Ast.TokenIndex, void),
};

/// Reports at `token`'s span, but only the first time this call site sees
/// `token` -- several of the checks below can independently notice the same
/// offending reference (e.g. more than one earlier free reaching the same
/// use), and the spec calls for at most one diagnostic per offending token.
fn reportOnce(
    ctx: *Context,
    rep: Reporter,
    token: Ast.TokenIndex,
    comptime fmt: []const u8,
    args: anytype,
) Context.LintError!void {
    if (rep.reported.contains(token)) return;
    try rep.reported.put(ctx.gpa, token, {});
    const start = rep.tree.tokenStart(token);
    const end = start + @as(u32, @intCast(rep.tree.tokenSlice(token).len));
    try ctx.report(start, end, fmt, args);
}

/// Whether any `.reassign` event in `events` has a token strictly between
/// `lo` and `hi` (both exclusive) -- a rebind of the local between a free
/// and a later reference means that later reference is to the NEW value, not
/// the freed one.
fn reassignBetween(
    events: []const alloc_track.Event,
    lo: Ast.TokenIndex,
    hi: Ast.TokenIndex,
) bool {
    for (events) |e| {
        if (e.role != .reassign) continue;
        if (e.token > lo and e.token < hi) return true;
    }
    return false;
}

/// USE-AFTER-FREE: a non-defer, UNCONDITIONAL free `f`, and a same-scope,
/// later, UNCONDITIONAL `.contained` or `.release` reference `u` with no
/// `.reassign` strictly between them. `f.in_defer` frees never reach this
/// loop at all (see the file doc). The `unconditional_in_scope` checks on
/// BOTH `f` and `u` matter because a braceless conditional body shares its
/// enclosing scope: without them, `if (!c) a.free(x); if (c) x[0] = 1;`
/// (mutually exclusive, never actually a use-after-free) would same-scope
/// match and false-flag.
fn checkUseAfterFree(
    ctx: *Context,
    rep: Reporter,
    t: alloc_track.Tracked,
    sym_name: []const u8,
) Context.LintError!void {
    for (t.events) |f| {
        if (f.role != .free or f.in_defer or !f.unconditional_in_scope) continue;
        for (t.events) |u| {
            if (u.role != .contained and u.role != .release) continue;
            if (u.scope != f.scope) continue;
            if (u.token <= f.token) continue;
            if (!u.unconditional_in_scope) continue;
            if (reassignBetween(t.events, f.token, u.token)) continue;
            try reportOnce(ctx, rep, u.token, "use of `{s}` after it was freed", .{sym_name});
        }
    }
}

/// DOUBLE-FREE: two NON-defer, UNCONDITIONAL frees `f1`/`f2` of the same
/// symbol, in the SAME scope, `f2` strictly later, with no `.reassign`
/// between them -- report `f2`. The `unconditional_in_scope` requirement
/// mirrors `checkUseAfterFree`'s: `if (c) a.free(x); if (!c) a.free(x);`
/// (braceless, mutually exclusive) shares one scope but must not flag.
///
/// A `defer`/`errdefer` free coexisting with another free used to be
/// flagged here too (a former "shape (a)"), but that shape was unsound and
/// has been REMOVED: a `defer` isn't ARMED until control actually reaches
/// it, so `if (fail) { a.free(x); return; } defer a.free(x);` frees the
/// allocation exactly once on every path, and `errdefer` doesn't run at all
/// on a success return -- reporting either as a double-free was itself a
/// false positive this module can't reliably distinguish from a real one
/// without control-flow reasoning it doesn't have. `defer a.free(x);
/// a.free(x);` (an explicit free that races the defer) is consequently a
/// documented false-negative for now; a future slice may re-add that shape
/// once it can be proven sound.
fn checkDoubleFree(
    ctx: *Context,
    rep: Reporter,
    t: alloc_track.Tracked,
    sym_name: []const u8,
) Context.LintError!void {
    for (t.events) |f1| {
        if (f1.role != .free or f1.in_defer or !f1.unconditional_in_scope) continue;
        for (t.events) |f2| {
            if (f2.role != .free or f2.in_defer or !f2.unconditional_in_scope) continue;
            if (f2.token <= f1.token) continue;
            if (f2.scope != f1.scope) continue;
            if (reassignBetween(t.events, f1.token, f2.token)) continue;
            try reportOnce(ctx, rep, f2.token, "`{s}` is freed twice", .{sym_name});
        }
    }
}

pub fn run(ctx: *Context) Context.LintError!void {
    const tree = &ctx.source.ast;
    const tracked = try alloc_track.analyze(ctx.gpa, ctx.semantic, tree);
    defer alloc_track.free(ctx.gpa, tracked);

    var reported: std.AutoHashMapUnmanaged(Ast.TokenIndex, void) = .empty;
    defer reported.deinit(ctx.gpa);
    const rep: Reporter = .{ .tree = tree, .reported = &reported };

    for (tracked) |t| {
        const sym_name = ctx.semantic.symbol(t.symbol).name;
        try checkUseAfterFree(ctx, rep, t, sym_name);
        try checkDoubleFree(ctx, rep, t, sym_name);
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
        .current_severity = .@"error",
        .semantic = &sema,
    };
    try run(&ctx);
    return diags.items.len;
}

const uaf_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    a.free(x);
    \\    x[0] = 1;
    \\}
    \\
;

test "flags a use after the allocation was freed" {
    try std.testing.expectEqual(@as(usize, 1), try countDiags(std.testing.allocator, uaf_src));
}

const double_free_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    a.free(x);
    \\    a.free(x);
    \\}
    \\
;

test "flags a straight-line double free" {
    try std.testing.expectEqual(
        @as(usize, 1),
        try countDiags(std.testing.allocator, double_free_src),
    );
}

const defer_double_free_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    defer a.free(x);
    \\    a.free(x);
    \\}
    \\
;

// FIX C3: shape (a) (a defer free coexisting with another free) was
// unsound and has been removed -- see `checkDoubleFree`'s doc. This is now
// a documented false-negative, not a report.
test "clean (FIX C3): defer free plus an explicit free is no longer flagged" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, defer_double_free_src),
    );
}

const early_free_then_defer_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator, fail: bool) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    if (fail) {
    \\        a.free(x);
    \\        return;
    \\    }
    \\    defer a.free(x);
    \\    x[0] = 1;
    \\}
    \\
;

// FIX C3: an early explicit free (nested, mutually exclusive with the
// defer's own path) followed by a `defer` free frees exactly once on every
// path -- must never be flagged as a double free.
test "clean (FIX C3): early free-then-return, plus a defer free, is not a double free" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, early_free_then_defer_src),
    );
}

const braceless_mutually_exclusive_double_free_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator, c: bool) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    if (c) a.free(x);
    \\    if (!c) a.free(x);
    \\}
    \\
;

// FIX C2: both frees are braceless conditional bodies sharing the fn's own
// scope -- mutually exclusive at runtime, so this must not be flagged even
// though both frees land in the same `Event.scope`.
test "clean (FIX C2): braceless mutually-exclusive frees are not a double free" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, braceless_mutually_exclusive_double_free_src),
    );
}

const freed_once_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    a.free(x);
    \\}
    \\
;

test "clean: freed once with no later use" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, freed_once_src),
    );
}

const use_before_free_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    x[0] = 1;
    \\    a.free(x);
    \\}
    \\
;

test "clean: use before the free is not a use-after-free" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, use_before_free_src),
    );
}

const nested_scope_free_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator, c: bool) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    if (c) {
    \\        a.free(x);
    \\        return;
    \\    }
    \\    x[0] = 1;
    \\}
    \\
;

test "clean: free in a nested scope never reaches a use in the outer scope" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, nested_scope_free_src),
    );
}

const reassigned_between_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) void {
    \\    var x = a.alloc(u8, 4) catch return;
    \\    a.free(x);
    \\    x = a.alloc(u8, 4) catch return;
    \\    x[0] = 1;
    \\}
    \\
;

test "clean: a reassign between the free and the use revives the local" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, reassigned_between_src),
    );
}

const braceless_mutually_exclusive_uaf_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator, c: bool) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    if (!c) a.free(x);
    \\    if (c) x[0] = 1;
    \\}
    \\
;

// FIX C2: the free and the use are both braceless conditional bodies
// sharing the fn's own scope, and are mutually exclusive (`c`/`!c`) -- must
// not be flagged even though same-scope alone would match them.
test "clean (FIX C2): braceless mutually-exclusive free and use" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, braceless_mutually_exclusive_uaf_src),
    );
}

const reset_then_use_src =
    \\const std = @import("std");
    \\const W = struct {
    \\    pub fn reset(self: *W) void {
    \\        _ = self;
    \\    }
    \\    pub fn render(self: *W) void {
    \\        _ = self;
    \\    }
    \\};
    \\pub fn f(a: std.mem.Allocator) void {
    \\    const w = a.create(W) catch return;
    \\    w.reset();
    \\    w.render();
    \\}
    \\
;

// FIX I4: `reset` doesn't deallocate `w` -- a later method call on it is not
// a use-after-free.
test "clean (FIX I4): w.reset() then w.render() is not a use-after-free" {
    try std.testing.expectEqual(
        @as(usize, 0),
        try countDiags(std.testing.allocator, reset_then_use_src),
    );
}

const deinit_then_use_src =
    \\const std = @import("std");
    \\const W = struct {
    \\    pub fn deinit(self: *W) void {
    \\        _ = self;
    \\    }
    \\    pub fn render(self: *W) void {
    \\        _ = self;
    \\    }
    \\};
    \\pub fn f(a: std.mem.Allocator) void {
    \\    const w = a.create(W) catch return;
    \\    w.deinit();
    \\    w.render();
    \\}
    \\
;

// FIX I4: `deinit` DOES deallocate `w` -- a later method call is a real
// use-after-free, and must still be flagged.
test "flags (FIX I4): w.deinit() then w.render() is a real use-after-free" {
    try std.testing.expectEqual(
        @as(usize, 1),
        try countDiags(std.testing.allocator, deinit_then_use_src),
    );
}

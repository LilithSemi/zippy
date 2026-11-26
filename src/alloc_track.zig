//! Shared allocation-tracking substrate for the upcoming `leaked_allocation`
//! and `use_after_free` lints. Finds every local bound to an allocator-call
//! result (`analyze`, via the internal `findAllocLocals`) and classifies
//! every later reference to it into a `RefRole`
//! (`contained`/`release`/`free`/`reassign`) so a lint can ask "was this
//! allocation ever freed, or did it escape" without re-deriving the AST
//! plumbing itself. Intraprocedural, built on `Semantic`'s scope/reference
//! tables, no data-flow analysis -- see the per-function doc comments below
//! for what each step catches and (more importantly) what it deliberately
//! does not try to catch.
//!
//! ## Soundness rule (read this before touching `classifyRole`)
//! `RefRole`'s DEFAULT is `.release`, not `.contained`. An allocation only
//! counts as "never escaped" (`leaked_allocation`'s trigger, a later slice)
//! when EVERY reference to it is `.contained` -- so a false `.contained` on a
//! reference that actually frees, returns, or stores the value would cause a
//! false leak/use-after-free report on someone's CORRECT code. IronStyle
//! treats a false positive as the cardinal sin (heavy false-negatives are
//! fine), so `classifyRole`'s fallback arm -- any parent shape this module
//! doesn't explicitly recognize -- returns `.release`, never `.contained`.
//! Extending the recognized-shapes list is always safe to defer; loosening
//! the default is not.
//!
//! ## `parentOf`: a stronger containment check than `Semantic.zig`'s
//! `Semantic.zig`'s `innermostScopeId` finds "the smallest node containing a
//! single TOKEN" by scanning a curated `creators` list whose members (fn/
//! block/container/...) each own a unique leading marker token, so a
//! creator's `firstToken` is never shared with one of its own descendants.
//! `parentOf` here has to run over EVERY node tag, including several with no
//! leading marker of their own -- `field_access`, `call`/`call_one`,
//! `array_access`, `assign` (and the compound-assign family), `catch` all
//! take their `firstToken` from their LEFTMOST OPERAND (confirmed against
//! 0.16's `Ast.zig` `firstToken` dispatch table before writing this: these
//! tags fall into its `node_and_node[0]`/`node_and_token[0]` descent group,
//! not the "return `nodeMainToken(n)` directly" group `address_of`/`@"try"`
//! are in). That means a single-token containment check would let a call's
//! own leftmost descendant (e.g. the bare `a` in `a.free(x)`) "outrank" the
//! call itself as a smaller-span match -- walking DOWN into a child instead
//! of UP to the parent, which breaks both the transparent-wrapper unwind and
//! the `defer`-ancestor walk below (both call `parentOf` again on a
//! non-leaf `parent`, not just on the original leaf `.identifier`).
//! Requiring the candidate to contain `node`'s WHOLE range (`firstToken`
//! AND `lastToken`), not just its first token, rules out descendants -- a
//! descendant's range is a strict subset of `node`'s, never a superset --
//! while still reducing to the exact single-token check for the common case
//! of a leaf `.identifier` (whose own range is one token, so "contains my
//! whole range" and "contains my first token" coincide).
const std = @import("std");
const Ast = std.zig.Ast;
const Semantic = @import("Semantic.zig");

/// How a single reference to a tracked allocation is used. See the file
/// doc's soundness rule: `.release` is the fallback for anything this module
/// doesn't specifically recognize, never `.contained`.
pub const RefRole = enum {
    /// Used strictly in place -- an array/slice base (`x[i]`), or discarded
    /// (`_ = x;`, itself the idiom for "silence the unused-var error, I'm
    /// not really using this") -- never freed, stored, or passed onward.
    contained,
    /// Passed, returned, stored, or otherwise handed off in a way that may
    /// transfer ownership -- the DEFAULT for anything not specifically
    /// recognized as `.contained`/`.free`/`.reassign`.
    release,
    /// A free-shaped call: `x.deinit()`/`x.free()`/... (`x` the receiver of
    /// a free-named method) or `alloc.free(x)`/`alloc.destroy(x)` (`x`
    /// passed as the argument).
    free,
    /// `x = ...` -- `x` is the ASSIGNMENT TARGET, not a use of the old
    /// value. A `free` earlier and a `reassign` later means the old
    /// allocation was revived under a new value, not left dangling.
    reassign,
};

/// One classified reference to a `Tracked` symbol.
pub const Event = struct {
    /// The reference's own identifier token (not the declaration's).
    token: Ast.TokenIndex,
    /// The reference's own `.identifier` AST node.
    node: Ast.Node.Index,
    role: RefRole,
    /// The reference's innermost enclosing scope (`sema.nodeScope(node)`) --
    /// lets a later lint ask "is this free and that use in the same
    /// straight-line block" without re-deriving it.
    scope: Semantic.Scope.Id,
    /// Whether an ancestor of this reference is a `.@"defer"`/`.@"errdefer"`
    /// -- a defer's body runs unconditionally at scope exit, which matters
    /// for double-free detection (a later slice).
    in_defer: bool,
    /// Whether this reference is reached UNCONDITIONALLY within its own
    /// enclosing scope -- no `if`/`while`/`for`/`switch`/`catch`/`orelse`
    /// sits between it and the AST node that OWNS its scope. `Semantic`
    /// only creates a scope for `if`/`while`/`for` WITH a capture or braces
    /// (see `Semantic.zig`), so a BRACELESS conditional body
    /// (`if (!c) a.free(x);`) has no scope of its own -- it shares the
    /// enclosing block's scope with everything after it, which would
    /// otherwise let a same-scope guard treat it as if it always runs. A
    /// later lint (`use_after_free`, a later slice) requires this to be
    /// `true` on BOTH sides of a free/use or free/free pair before
    /// reporting, since same-scope alone can't tell a conditional free
    /// apart from an unconditional one.
    unconditional_in_scope: bool,
};

/// An allocation-bound local and every reference `analyze` found to it.
pub const Tracked = struct {
    symbol: Semantic.Symbol.Id,
    /// The `var`/`const` declaration node that bound it to an alloc call.
    decl: Ast.Node.Index,
    /// The declaration's own name token (for a diagnostic's span).
    name_token: Ast.TokenIndex,
    /// Owned by `analyze`'s caller; free via `free`, not `gpa.free` directly
    /// (a `Tracked` doesn't carry the allocator it was built with).
    events: []Event,
};

/// True iff every reference to `t` is `.contained` -- i.e. the allocation is
/// used only in place and never freed, returned, stored, passed onward, or
/// reassigned. A `Tracked` with zero events (declared, never referenced
/// again) is vacuously "contained-only" too -- that's still a leak (or dead
/// code some other lint should catch), never a case this needs to special-
/// case away.
pub fn isContainedOnly(t: Tracked) bool {
    for (t.events) |e| {
        if (e.role != .contained) return false;
    }
    return true;
}

/// Finds every allocation-bound local in `tree` and classifies every
/// reference to it. The only failure mode is OOM (`Semantic`/`Ast` accessors
/// used here return `null`/`false` on a shape they don't recognize rather
/// than erroring), matching `Semantic.build`'s own contract.
pub fn analyze(
    gpa: std.mem.Allocator,
    sema: *const Semantic,
    tree: *const Ast,
) std.mem.Allocator.Error![]Tracked {
    const locals = try findAllocLocals(gpa, sema, tree);
    defer gpa.free(locals);

    var callee_set = try buildCalleeSet(gpa, tree);
    defer callee_set.deinit(gpa);

    // Maps a tracked symbol back to its index in `locals`/`events` so the
    // single whole-tree identifier scan below can file each resolved
    // reference into the right bucket in one O(nodes) pass, rather than
    // re-scanning the tree once per tracked local.
    var sym_index: std.AutoHashMapUnmanaged(Semantic.Symbol.Id, usize) = .empty;
    defer sym_index.deinit(gpa);
    for (locals, 0..) |l, i| try sym_index.put(gpa, l.symbol, i);

    const events = try gpa.alloc(std.ArrayListUnmanaged(Event), locals.len);
    defer gpa.free(events);
    for (events) |*e| e.* = .empty;
    // Safe even after some entries below are handed off via `toOwnedSlice`
    // (that leaves the list empty, and `deinit` on an empty list is a
    // no-op) -- see the matching note on `out`'s errdefer.
    errdefer for (events) |*e| e.deinit(gpa);

    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        if (tree.nodeTag(node) != .identifier) continue;
        const tok = tree.nodeMainToken(node);
        const scope = sema.nodeScope(node);
        const name = tree.tokenSlice(tok);
        const resolved = sema.resolveBinding(scope, name, &.{}) orelse continue;
        const list_idx = sym_index.get(resolved) orelse continue;
        try events[list_idx].append(gpa, .{
            .token = tok,
            .node = node,
            .role = classifyRole(tree, &callee_set, node),
            .scope = scope,
            .in_defer = isInDefer(tree, node),
            .unconditional_in_scope = isUnconditionalInScope(sema, tree, node),
        });
    }

    var out: std.ArrayListUnmanaged(Tracked) = .empty;
    errdefer {
        for (out.items) |t| gpa.free(t.events);
        out.deinit(gpa);
    }
    try out.ensureTotalCapacityPrecise(gpa, locals.len);
    for (locals, 0..) |l, i| {
        out.appendAssumeCapacity(.{
            .symbol = l.symbol,
            .decl = l.decl,
            .name_token = l.name_token,
            .events = try events[i].toOwnedSlice(gpa),
        });
    }
    return out.toOwnedSlice(gpa);
}

/// Frees every `Tracked.events` slice, then `tracked` itself. Mirrors
/// `Semantic.deinit`'s shape (a plain free function taking the allocator
/// explicitly, since `Tracked` doesn't carry one).
pub fn free(gpa: std.mem.Allocator, tracked: []Tracked) void {
    for (tracked) |t| gpa.free(t.events);
    gpa.free(tracked);
}

// --- Alloc detection ---------------------------------------------------

/// A candidate found by `findAllocLocals`, before its references are
/// classified. Keeping `decl`/`name_token` here (rather than re-deriving
/// them from `Symbol` later) avoids a second `fullVarDecl` dispatch per
/// tracked local in `analyze`.
const AllocLocal = struct {
    symbol: Semantic.Symbol.Id,
    decl: Ast.Node.Index,
    name_token: Ast.TokenIndex,
};

/// Allocator methods that hand back OWNED memory the caller becomes
/// responsible for. Deliberately excludes read-only queries (`resize`,
/// `remap`) and anything that doesn't allocate -- a false ADD here risks
/// tracking (and thus potentially "leak"-flagging) a local that was never
/// really an allocation in the first place.
const alloc_methods = [_][]const u8{
    "alloc",        "allocSentinel",           "allocWithOptions",
    "alignedAlloc", "allocWithOptionsRetAddr", "allocBytesAligned",
    "create",       "alignedCreate",           "dupe",
    "dupeSentinel", "print",                   "printSentinel",
    "realloc",      "reallocAdvanced",
};

/// Name-only (no type info) heuristic for "this identifier is probably an
/// `std.mem.Allocator`". Underscores are stripped from both ends first so a
/// leading/trailing-underscore convention (`_a`, `alloc_`) still matches --
/// AST-only detection has no type to confirm with, so staying permissive on
/// spelling (while strict on the fixed name SET) is what keeps this from
/// missing real allocator locals under a house naming convention.
const allocator_like_names = [_][]const u8{
    "allocator", "alloc", "gpa", "arena", "a", "ally",
};

/// Method names, on the OBJECT side (`x.<name>()`), that this module treats
/// as freeing `x`. Deliberately restricted to methods that actually
/// DEALLOCATE `x`'s storage -- `x.reset()`/`x.clearAndFree()`/`x.close()`
/// invalidate what `x` currently holds without freeing `x` itself, so a
/// later `x.render()` after one of those is NOT a use-after-free; including
/// them here would false-flag exactly that. `use_after_free` classifies a
/// call to any OTHER method on a tracked local as `.release` instead (a
/// later slice), which suppresses `leaked_allocation` without wrongly
/// arming the use-after-free check.
const free_receiver_methods = [_][]const u8{ "deinit", "deinitAll", "free", "destroy" };

/// Method names, on the ALLOCATOR side (`alloc.<name>(x)`, `x` the
/// argument), that this module treats as freeing `x`. Narrower than
/// `free_receiver_methods` on purpose: `alloc.dupe(x)` passes `x` as data to
/// read, not to free, so only the two allocator methods that actually take
/// back ownership of their argument belong here.
const free_arg_methods = [_][]const u8{ "free", "destroy" };

fn nameInList(list: []const []const u8, name: []const u8) bool {
    for (list) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn stripUnderscores(name: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = name.len;
    while (start < end and name[start] == '_') start += 1;
    while (end > start and name[end - 1] == '_') end -= 1;
    return name[start..end];
}

fn isAllocatorLikeName(name: []const u8) bool {
    return nameInList(&allocator_like_names, stripUnderscores(name));
}

/// Whether `node` (a call's receiver expression) looks like an allocator:
/// a bare identifier from the fixed name set, or a `field_access` whose
/// RIGHTMOST field is allocator-like or ends "Allocator"/"allocator" (e.g.
/// `self.gpa`, `ctx.child_allocator`, `world.entityAllocator`). Never
/// resolves the identifier through `Semantic` -- this is a pure spelling
/// heuristic, same tradeoff `hidden_allocator.zig` and `no_print.zig` make
/// for their own receiver/callee checks.
fn isAllocatorLike(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .identifier => isAllocatorLikeName(tree.tokenSlice(tree.nodeMainToken(node))),
        .field_access => blk: {
            const field_tok = tree.nodeData(node).node_and_token[1];
            const field_name = tree.tokenSlice(field_tok);
            break :blk isAllocatorLikeName(field_name) or
                std.mem.endsWith(u8, field_name, "Allocator") or
                std.mem.endsWith(u8, field_name, "allocator");
        },
        else => false,
    };
}

/// `try`/`catch` are the only wrappers an alloc call's initializer can sit
/// behind that this module unwraps -- `a.alloc(...)` returns `!Ptr`, so
/// `try a.alloc(...)` and `a.alloc(...) catch <handler>` are both the
/// overwhelmingly common real-world spellings. Confirmed against 0.16's
/// `Ast.zig`: `.@"try"`'s data is a bare `.node` (the operand); `.@"catch"`'s
/// is `.node_and_node` with `[0]` the left (attempted) expression.
fn unwrapAllocInit(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    return switch (tree.nodeTag(node)) {
        .@"try" => tree.nodeData(node).node,
        .@"catch" => tree.nodeData(node).node_and_node[0],
        else => node,
    };
}

/// Whether `init_node` (a var-decl's initializer, already unwrapped through
/// `try`/`catch`) is `<allocator-like>.<alloc-method>(...)`.
fn isAllocCall(tree: *const Ast, init_node: Ast.Node.Index) bool {
    const unwrapped = unwrapAllocInit(tree, init_node);
    var buf: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buf, unwrapped) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const recv, const method_tok = tree.nodeData(call.ast.fn_expr).node_and_token;
    if (!nameInList(&alloc_methods, tree.tokenSlice(method_tok))) return false;
    return isAllocatorLike(tree, recv);
}

/// Scope kinds a `variable` symbol must live in to be tracked -- a plain
/// function/block/loop/`catch` payload body. Deliberately excludes
/// `.container` (top-level/struct-field allocs are rare and their lifetime
/// isn't this module's business) and `.comptime_`/`.test_` (comptime
/// allocation has different rules; test-block leaks are noise, not signal,
/// per the same reasoning `no_print`'s `allow_tests` uses).
fn isEligibleScopeKind(kind: Semantic.Scope.Kind) bool {
    return switch (kind) {
        .function, .block, .loop, .catch_ => true,
        .container, .comptime_, .test_ => false,
    };
}

/// Every `variable` symbol whose declaration initializes it directly from an
/// allocator call (through an optional `try`/`catch`). `Symbol` doesn't
/// track a decl's name token itself, so this reaches into `fullVarDecl` once
/// per candidate to grab it (`mut_token + 1` -- see `Semantic.zig`'s
/// `declareVar`, which does the same thing when first declaring it).
fn findAllocLocals(
    gpa: std.mem.Allocator,
    sema: *const Semantic,
    tree: *const Ast,
) std.mem.Allocator.Error![]AllocLocal {
    var out: std.ArrayListUnmanaged(AllocLocal) = .empty;
    errdefer out.deinit(gpa);

    var id: Semantic.Symbol.Id = 0;
    while (id < sema.symbols.items.len) : (id += 1) {
        const sym = sema.symbol(id);
        if (sym.kind != .variable) continue;
        if (!isEligibleScopeKind(sema.scopeKind(sym.scope))) continue;
        const full_var = tree.fullVarDecl(sym.decl) orelse continue;
        const init_node = full_var.ast.init_node.unwrap() orelse continue;
        if (!isAllocCall(tree, init_node)) continue;
        try out.append(gpa, .{
            .symbol = id,
            .decl = sym.decl,
            .name_token = full_var.ast.mut_token + 1,
        });
    }
    return out.toOwnedSlice(gpa);
}

// --- parentOf + callee_set ----------------------------------------------

/// The immediate AST parent of `node`: the node `M != node` with the
/// smallest token span whose range `[firstToken(M), lastToken(M)]` fully
/// contains `node`'s OWN range (not just its first token) -- see the file
/// doc for why the full-range check matters here (unlike
/// `Semantic.zig`'s single-token version, which only ever needs to run on
/// leaf nodes). `null` only for `node == .root` (nothing contains it) or a
/// node this scan somehow can't place, neither of which occurs for a real
/// `.identifier` reference or any of its real ancestors.
fn parentOf(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    var best: ?Ast.Node.Index = null;
    var best_span: u32 = std.math.maxInt(u32);

    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const m: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        if (m == node) continue;
        const m_first = tree.firstToken(m);
        const m_last = tree.lastToken(m);
        if (m_first > first or m_last < last) continue;
        const span = m_last - m_first;
        if (span < best_span) {
            best_span = span;
            best = m;
        }
    }
    return best;
}

/// Every call node's callee (`fullCall(&buf, n).ast.fn_expr`), so
/// `classifyRole` can tell `x.deinit` used AS a call (`x.deinit()`) apart
/// from a plain field READ (`x.len`) that merely happens to share the same
/// `field_access` shape.
fn buildCalleeSet(
    gpa: std.mem.Allocator,
    tree: *const Ast,
) std.mem.Allocator.Error!std.AutoHashMapUnmanaged(Ast.Node.Index, void) {
    var set: std.AutoHashMapUnmanaged(Ast.Node.Index, void) = .empty;
    errdefer set.deinit(gpa);

    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        switch (tree.nodeTag(node)) {
            .call, .call_comma, .call_one, .call_one_comma => {},
            else => continue,
        }
        var buf: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buf, node) orelse continue;
        try set.put(gpa, call.ast.fn_expr, {});
    }
    return set;
}

// --- Classification -------------------------------------------------------

/// Bound on how many `.grouped_expression`/`.@"try"`/`.@"catch"` layers
/// `classifyRole` unwraps before giving up and returning the DEFAULT
/// `.release` (see the file doc's soundness rule). Real code never nests
/// these anywhere near this deep -- hitting the bound only ever means a
/// pathological/generated input, not a real classification miss.
const max_unwrap_hops: u32 = 8;

/// Bound on how far `isInDefer` walks `parentOf` looking for a
/// `.@"defer"`/`.@"errdefer"` ancestor. See `max_unwrap_hops` for why a
/// generous-but-finite bound is safe here too.
const max_defer_walk_hops: u32 = 64;

fn isTransparentWrapper(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .grouped_expression, .@"try", .@"catch" => true,
        else => false,
    };
}

/// Whether `node` is the discard identifier `_`. Only meaningful as an
/// assignment's LHS (`_ = expr;`) -- see `classifyByParent`'s `.assign`
/// case for why it gets special treatment.
fn isDiscardIdentifier(tree: *const Ast, node: Ast.Node.Index) bool {
    if (tree.nodeTag(node) != .identifier) return false;
    return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "_");
}

/// Whether `fn_expr` (a call's callee expression) is `<x>.free`/`<x>.destroy`
/// -- the allocator-side free idiom, `alloc.free(target)`/
/// `alloc.destroy(target)`, as opposed to `target.deinit()` (handled
/// separately, on the `.field_access`-as-object path in `classifyByParent`).
fn isFreeArgCallee(tree: *const Ast, fn_expr: Ast.Node.Index) bool {
    if (tree.nodeTag(fn_expr) != .field_access) return false;
    const field_tok = tree.nodeData(fn_expr).node_and_token[1];
    return nameInList(&free_arg_methods, tree.tokenSlice(field_tok));
}

/// The ref-classification table itself (file doc has the "why"; this is the
/// "what"). `cur` is the node that literally appears as `parent`'s child --
/// after `classifyRole` has already unwound any transparent wrapper, `cur`
/// may be that wrapper rather than the original `.identifier` reference.
fn classifyByParent(
    tree: *const Ast,
    callee_set: *const std.AutoHashMapUnmanaged(Ast.Node.Index, void),
    cur: Ast.Node.Index,
    parent: Ast.Node.Index,
) RefRole {
    switch (tree.nodeTag(parent)) {
        .array_access => {
            const arr, _ = tree.nodeData(parent).node_and_node;
            if (arr == cur) return .contained;
        },

        .slice_open, .slice, .slice_sentinel => {
            if (tree.fullSlice(parent)) |fs| {
                if (fs.ast.sliced == cur) {
                    // `x[a..b]` produces a slice that ALIASES `x`'s
                    // storage -- unlike `x[i]` (`.array_access`, a value
                    // copy), the RESULT here can itself escape
                    // (`return x[0..n]`, `foo(x[0..n])`), so `x` being the
                    // sliced operand does NOT make this reference
                    // `.contained` on its own. Instead classify the SLICE
                    // NODE's own role by ITS parent -- `_ = x[0..n];` still
                    // lands on `.contained` (discard assign), `x[0..n][i]`
                    // still lands on `.contained` too (outer array_access),
                    // but `return x[0..n];` correctly becomes `.release`.
                    return classifyRole(tree, callee_set, parent);
                }
            }
        },

        .field_access => {
            const object, const field_tok = tree.nodeData(parent).node_and_token;
            if (object == cur) {
                if (!callee_set.contains(parent)) {
                    const field_name = tree.tokenSlice(field_tok);
                    if (std.mem.eql(u8, field_name, "ptr")) {
                        // `x.ptr` hands out the raw pointer into `x`'s
                        // storage -- the same aliasing/escape risk as a
                        // reslice above, so recurse the same way instead
                        // of treating it as a plain value read.
                        return classifyRole(tree, callee_set, parent);
                    }
                    return .contained; // `x.len`, or any other field read
                }
                const method = tree.tokenSlice(field_tok);
                return if (nameInList(&free_receiver_methods, method)) .free else .release;
            }
        },

        .call, .call_comma, .call_one, .call_one_comma => {
            var buf: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buf, parent) orelse return .release;
            if (call.ast.fn_expr == cur) return .release; // called AS a value: unusual, be safe
            for (call.ast.params) |p| {
                if (p == cur) {
                    return if (isFreeArgCallee(tree, call.ast.fn_expr)) .free else .release;
                }
            }
        },

        .@"return" => {
            if (tree.nodeData(parent).opt_node.unwrap()) |operand| {
                if (operand == cur) return .release;
            }
        },

        .address_of => {
            if (tree.nodeData(parent).node == cur) return .release;
        },

        .struct_init_one,
        .struct_init_one_comma,
        .struct_init,
        .struct_init_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .array_init_one,
        .array_init_one_comma,
        .array_init,
        .array_init_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        => return .release, // stored into a struct/array literal: escapes

        .assign => {
            const lhs, const rhs = tree.nodeData(parent).node_and_node;
            if (lhs == cur) return .reassign;
            if (rhs == cur) {
                // `_ = x;` is the discard idiom -- silencing an unused-var
                // error, not handing `x` off anywhere. Treating it as
                // `.release` would make it suppress `leaked_allocation`
                // (a later slice) on exactly the code that lint exists to
                // catch: "allocated it, discarded the value, never freed
                // it".
                if (isDiscardIdentifier(tree, lhs)) return .contained;
                return .release;
            }
        },

        .assign_mul,
        .assign_div,
        .assign_mod,
        .assign_add,
        .assign_sub,
        .assign_shl,
        .assign_shl_sat,
        .assign_shr,
        .assign_bit_and,
        .assign_bit_xor,
        .assign_bit_or,
        .assign_mul_wrap,
        .assign_add_wrap,
        .assign_sub_wrap,
        .assign_mul_sat,
        .assign_add_sat,
        .assign_sub_sat,
        => {
            // `_` can only ever be the LHS of a plain `.assign` (Zig's
            // grammar rejects `_ += x`), so no discard carve-out is needed
            // for the compound-assign family.
            const lhs, const rhs = tree.nodeData(parent).node_and_node;
            if (lhs == cur) return .reassign;
            if (rhs == cur) return .release;
        },

        else => {},
    }
    return .release; // DEFAULT -- see the file doc's soundness rule
}

/// Classifies a single reference `ref` (a resolved `.identifier` node) into
/// a `RefRole`, unwinding any transparent wrapper (`(x)`, `try x`,
/// `x catch ...`) between `ref` and the parent that actually determines its
/// role.
fn classifyRole(
    tree: *const Ast,
    callee_set: *const std.AutoHashMapUnmanaged(Ast.Node.Index, void),
    ref: Ast.Node.Index,
) RefRole {
    var cur = ref;
    var parent = parentOf(tree, cur) orelse return .release;

    var hops: u32 = 0;
    while (hops < max_unwrap_hops and isTransparentWrapper(tree.nodeTag(parent))) : (hops += 1) {
        cur = parent;
        parent = parentOf(tree, cur) orelse return .release;
    }

    return classifyByParent(tree, callee_set, cur, parent);
}

/// Whether an ancestor of `ref` is a `.@"defer"`/`.@"errdefer"` node, walked
/// via `parentOf` (bounded -- see `max_defer_walk_hops`).
fn isInDefer(tree: *const Ast, ref: Ast.Node.Index) bool {
    var cur = ref;
    var hops: u32 = 0;
    while (hops < max_defer_walk_hops) : (hops += 1) {
        const parent = parentOf(tree, cur) orelse return false;
        switch (tree.nodeTag(parent)) {
            .@"defer", .@"errdefer" => return true,
            else => {},
        }
        cur = parent;
    }
    return false;
}

/// Bound on how far `isUnconditionalInScope` walks `parentOf` from a
/// reference up to the AST node that owns its own enclosing scope. See
/// `max_defer_walk_hops` for why a generous-but-finite bound is safe here.
const max_unconditional_walk_hops: u32 = 64;

/// AST tags whose body/arm executes CONDITIONALLY. Walking from a reference
/// up toward its own scope's node and crossing one of these means the
/// reference does NOT unconditionally run whenever that scope is entered --
/// this is deliberately broader than just `if`/`while`/`for`: a
/// `switch_case` arm only runs for its matching case, and `catch`/`orelse`'s
/// fallback only runs on error/null, so a free tucked into either is just as
/// conditional as one behind a braceless `if`.
fn isConditionalTag(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .if_simple,
        .@"if",
        .while_simple,
        .while_cont,
        .@"while",
        .for_simple,
        .@"for",
        .switch_case_one,
        .switch_case_inline_one,
        .switch_case,
        .switch_case_inline,
        .@"catch",
        .@"orelse",
        .@"switch",
        .switch_comma,
        => true,
        else => false,
    };
}

/// Whether `ref` is reached UNCONDITIONALLY within its own enclosing scope
/// -- see the `Event.unconditional_in_scope` doc for why this matters.
/// `Semantic` only creates a scope for `if`/`while`/`for` WITH a capture or
/// braces, so a braceless conditional body shares its enclosing block's
/// scope with everything after it; the same-scope guard alone can't tell
/// that free apart from an unconditional one further down the block, so
/// this walks `parentOf` from `ref` up to the node that OWNS its scope
/// (`sema.scopeNode(sema.nodeScope(ref))`) and fails the moment it crosses
/// a conditional-tagged ancestor BEFORE reaching that scope node. Hitting
/// the hop bound without reaching the scope node is treated as conditional
/// (`false`) rather than unconditional -- see the file doc's soundness
/// rule: this field gates a report, so its own default must lean toward
/// NOT reporting, never toward reporting.
fn isUnconditionalInScope(sema: *const Semantic, tree: *const Ast, ref: Ast.Node.Index) bool {
    const scope_node = sema.scopeNode(sema.nodeScope(ref));
    var cur = ref;
    var hops: u32 = 0;
    while (hops < max_unconditional_walk_hops) : (hops += 1) {
        const parent = parentOf(tree, cur) orelse return true;
        if (parent == scope_node) return true;
        if (isConditionalTag(tree.nodeTag(parent))) return false;
        cur = parent;
    }
    return false;
}

// --- Tests -----------------------------------------------------------------

const Source = @import("Source.zig");

/// Bundles the three values every test needs alive together (`Source` owns
/// the bytes/tree `Semantic` and `Tracked` both borrow/reference) so each
/// test is a two-line setup + one `defer`, matching the fixture pattern
/// `Semantic.zig`'s own tests use.
const Fixture = struct {
    src: Source,
    sema: Semantic,
    tracked: []Tracked,

    fn init(gpa: std.mem.Allocator, src_text: []const u8) !Fixture {
        var src = try Source.loadFromSlice(gpa, "t.zig", src_text);
        errdefer src.deinit(gpa);
        var sema = try Semantic.build(gpa, &src);
        errdefer sema.deinit(gpa);
        const tracked = try analyze(gpa, &sema, &src.ast);
        return .{ .src = src, .sema = sema, .tracked = tracked };
    }

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        free(gpa, self.tracked);
        self.sema.deinit(gpa);
        self.src.deinit(gpa);
    }
};

const alloc_param_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    _ = x;
    \\}
    \\
;

test "a var bound to <allocator>.alloc(...) via catch is tracked" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.init(gpa, alloc_param_src);
    defer fx.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), fx.tracked.len);
}

const try_alloc_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) !void {
    \\    const x = try a.alloc(u8, 4);
    \\    _ = x;
    \\}
    \\
;

test "a var bound to <allocator>.alloc(...) via try is tracked" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.init(gpa, try_alloc_src);
    defer fx.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), fx.tracked.len);
}

const non_allocator_receiver_src =
    \\pub fn f(list: u8) void {
    \\    const y = list.create();
    \\    _ = y;
    \\}
    \\
;

test "list.create() is NOT tracked (receiver is not allocator-like)" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.init(gpa, non_allocator_receiver_src);
    defer fx.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), fx.tracked.len);
}

const array_index_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    x[0] = 1;
    \\}
    \\
;

test "role: x[0] (array-access base) is contained" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.init(gpa, array_index_src);
    defer fx.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), fx.tracked.len);
    try std.testing.expectEqual(@as(usize, 1), fx.tracked[0].events.len);
    try std.testing.expectEqual(RefRole.contained, fx.tracked[0].events[0].role);
}

const reslice_return_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator, n: usize) ![]u8 {
    \\    const x = try a.alloc(u8, n);
    \\    return x[0..n];
    \\}
    \\
;

test "role: return x[0..n] (reslice-and-return) is release, not contained (FIX C1)" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.init(gpa, reslice_return_src);
    defer fx.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), fx.tracked[0].events.len);
    try std.testing.expectEqual(RefRole.release, fx.tracked[0].events[0].role);
    try std.testing.expect(!isContainedOnly(fx.tracked[0]));
}

const reslice_discard_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator, n: usize) !void {
    \\    const x = try a.alloc(u8, n);
    \\    _ = x[0..n];
    \\}
    \\
;

test "role: _ = x[0..n] (reslice, discarded) is still contained" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.init(gpa, reslice_discard_src);
    defer fx.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), fx.tracked[0].events.len);
    try std.testing.expectEqual(RefRole.contained, fx.tracked[0].events[0].role);
    try std.testing.expect(isContainedOnly(fx.tracked[0]));
}

const free_arg_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    a.free(x);
    \\}
    \\
;

test "role: a.free(x) (allocator-side free arg) is free" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.init(gpa, free_arg_src);
    defer fx.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), fx.tracked[0].events.len);
    try std.testing.expectEqual(RefRole.free, fx.tracked[0].events[0].role);
    try std.testing.expect(!fx.tracked[0].events[0].in_defer);
}

const deinit_method_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) void {
    \\    const x = a.create(u8) catch return;
    \\    x.destroy(a);
    \\}
    \\
;

test "role: x.destroy(a) (object-side free method) is free" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.init(gpa, deinit_method_src);
    defer fx.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), fx.tracked[0].events.len);
    try std.testing.expectEqual(RefRole.free, fx.tracked[0].events[0].role);
}

const return_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) ![]u8 {
    \\    const x = a.alloc(u8, 4) catch return error.OutOfMemory;
    \\    return x;
    \\}
    \\
;

test "role: return x is release" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.init(gpa, return_src);
    defer fx.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), fx.tracked[0].events.len);
    try std.testing.expectEqual(RefRole.release, fx.tracked[0].events[0].role);
}

const passed_to_fn_src =
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

test "role: foo(x) (arg to an unrelated fn) is release" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.init(gpa, passed_to_fn_src);
    defer fx.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), fx.tracked[0].events.len);
    try std.testing.expectEqual(RefRole.release, fx.tracked[0].events[0].role);
}

const struct_field_assign_src =
    \\const std = @import("std");
    \\const S = struct { f: []u8 };
    \\pub fn f(a: std.mem.Allocator) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    var s: S = undefined;
    \\    s.f = x;
    \\}
    \\
;

test "role: s.f = x (assign RHS, non-discard LHS) is release" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.init(gpa, struct_field_assign_src);
    defer fx.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), fx.tracked[0].events.len);
    try std.testing.expectEqual(RefRole.release, fx.tracked[0].events[0].role);
}

const reassign_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) void {
    \\    var x = a.alloc(u8, 4) catch return;
    \\    var z: []u8 = undefined;
    \\    x = z;
    \\}
    \\
;

test "role: x = z (assign LHS) is reassign" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.init(gpa, reassign_src);
    defer fx.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), fx.tracked[0].events.len);
    try std.testing.expectEqual(RefRole.reassign, fx.tracked[0].events[0].role);
}

test "role: _ = x (discard) is contained, not release" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.init(gpa, alloc_param_src);
    defer fx.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), fx.tracked[0].events.len);
    try std.testing.expectEqual(RefRole.contained, fx.tracked[0].events[0].role);
}

const defer_free_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    defer a.free(x);
    \\}
    \\
;

test "defer a.free(x): free event with in_defer = true" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.init(gpa, defer_free_src);
    defer fx.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), fx.tracked[0].events.len);
    try std.testing.expectEqual(RefRole.free, fx.tracked[0].events[0].role);
    try std.testing.expect(fx.tracked[0].events[0].in_defer);
}

test "isContainedOnly: true when every event is contained" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.init(gpa, array_index_src);
    defer fx.deinit(gpa);
    try std.testing.expect(isContainedOnly(fx.tracked[0]));
}

const contained_then_freed_src =
    \\const std = @import("std");
    \\pub fn f(a: std.mem.Allocator) void {
    \\    const x = a.alloc(u8, 4) catch return;
    \\    x[0] = 1;
    \\    a.free(x);
    \\}
    \\
;

test "isContainedOnly: false once any release/free event exists" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.init(gpa, contained_then_freed_src);
    defer fx.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), fx.tracked[0].events.len);
    try std.testing.expect(!isContainedOnly(fx.tracked[0]));
}

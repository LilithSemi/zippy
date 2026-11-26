//! A per-file scope tree built over a parsed `Source`. This is the substrate
//! for Zippy's semantic-analysis lints (rules that need to know "is this
//! identifier inside a function that returns an error union" rather than
//! just "what does this AST node look like"). Modeled after zlint's
//! `src/Semantic/` module (DonIsaac, MIT) -- reimplemented in IronStyle
//! (plain `ArrayListUnmanaged`s rather than zlint's SoA `MultiArrayList`, to
//! keep rule-writing code readable over squeezing out the last byte).
//!
//! Phase A builds the scope tree + `node_scope` map (every AST node's
//! innermost enclosing scope) and the symbol table (every declaration,
//! bound by name into its declaring scope's `bindings` map). Phase B then
//! walks every identifier USE in the file and resolves it against that
//! table via `resolveBinding`, recording a `Ref` and appending it to the
//! resolved symbol's `references` list -- this is what lets a later lint
//! ask "is this decl ever used" instead of guessing from a token count.
//!
//! ## How scopes are assigned
//! Zig's `std.zig.Ast` has no generic "iterate children" API -- child access
//! is dispatched per node tag via `fullX` helpers. Rather than hand-write a
//! recursive descent over every one of the ~150 node tags, `build` uses the
//! same token-range-containment trick `lints/return_stack_local.zig` already
//! uses for its `innermostFn`/`innermostScope` helpers: AST node token
//! ranges nest exactly like scopes do (a child node's tokens always fall
//! strictly inside its parent's), so "the innermost scope containing node N"
//! is exactly "the scope-creating node with the smallest token range that
//! contains N's first token, other than N itself". This is O(nodes *
//! scope-creating nodes) rather than O(nodes), which is worse than a real
//! descent, but every other node-range scan in this codebase already takes
//! that shape and file sizes keep it well under linting-latency budgets.
//!
//! The "other than N itself" exclusion is what makes a scope-creating node's
//! OWN entry in `node_scope` resolve to its ENCLOSING scope rather than the
//! scope it creates -- e.g. `nodeScope(fn_decl_node)` is the container scope
//! the function is declared in, not the function's own scope. That matches
//! the design's declaration rule ("a `fn_decl` symbol is declared in the
//! ENCLOSING container scope, not the fn's own scope") and falls out for
//! free instead of needing special-casing later.
const std = @import("std");
const Ast = std.zig.Ast;
const Source = @import("Source.zig");
const Semantic = @This();

scopes: std.ArrayListUnmanaged(Scope),
/// Indexed by `@intFromEnum(node)`; every AST node has an entry, including
/// nodes produced by parse-error recovery, so a malformed-but-parsed file
/// never causes an out-of-bounds lookup.
node_scope: []Scope.Id,
/// Every declared symbol, in discovery order. Indexed by `Symbol.Id`.
symbols: std.ArrayListUnmanaged(Symbol),
/// One name->symbol map per scope (`bindings.len == scopes.items.len`),
/// indexed by `Scope.Id`. A name resolves in a given scope by looking here
/// first, then walking to `parentScope` on a miss (Phase B, a later slice).
bindings: []std.StringHashMapUnmanaged(Symbol.Id),
/// Every resolved identifier USE, in visitation order (Phase B). Indexed by
/// `Ref.Id`; a symbol's `references` list holds indices into this.
refs: std.ArrayListUnmanaged(Ref),
gpa: std.mem.Allocator,

pub const Scope = struct {
    /// `null` only for the root container scope (id 0) -- every other scope
    /// nests inside the file's implicit top-level struct.
    parent: ?Id,
    /// The AST node that created this scope (a `fn_decl`, a block, ...).
    node: Ast.Node.Index,
    kind: Kind,

    pub const Id = u32;

    pub const Kind = enum {
        /// A struct/union/enum/opaque literal, including the implicit
        /// top-level container that is the whole file.
        container,
        function,
        block,
        /// Reserved for a future slice (loop-body-specific queries, e.g.
        /// `break`/`continue` validity); Phase A never creates one -- a
        /// `while`/`for` gets a `block`-kind capture scope instead when it
        /// binds a payload, same as `if`/`switch`.
        loop,
        comptime_,
        test_,
        /// The RHS of a `catch |err| ...`, scoped to the error payload.
        catch_,
    };

    pub fn isContainer(k: Kind) bool {
        return k == .container;
    }
};

/// A named binding introduced by a declaration node: a top-level/local
/// `const`/`var`, a `fn`, a fn parameter, a container field, or a payload
/// capture (`|x|`). This slice (Phase A) only DECLARES symbols -- reference
/// lists stay empty until Phase B (a later slice) walks identifier uses and
/// fills them in; the field is present now so that later slice doesn't need
/// to reshape this struct.
pub const Symbol = struct {
    /// BORROWS the source's bytes (a token slice) -- never duped, so it's
    /// only valid as long as the `Source` that produced it outlives `self`.
    name: []const u8,
    /// The AST node that introduced this binding: the `var_decl`/`fn_decl`/
    /// container-field node, or (for params and captures, which have no
    /// dedicated declaration node of their own) the enclosing construct's
    /// node.
    decl: Ast.Node.Index,
    /// The scope this name is bound in -- looked up via `bindings[scope]`.
    scope: Scope.Id,
    kind: Kind,
    visibility: Visibility,
    /// Indices into `Semantic.refs` for every USE Phase B resolved back to
    /// this symbol. Empty means "never referenced" -- the signal `unused_decl`
    /// hardening (a later slice) needs. Order is visitation order, not
    /// source order (Phase B walks the node array, not a control-flow path).
    references: std.ArrayListUnmanaged(Ref.Id) = .empty,

    pub const Id = u32;

    pub const Kind = enum { variable, function, parameter, field, capture };

    /// Whether `pub` preceded the declaration. Container fields have no
    /// `pub` syntax in Zig -- they're always treated as `.public` (a field
    /// is never hidden by scope the way a top-level decl can be).
    pub const Visibility = enum { public, private };
};

/// A resolved identifier USE: `token` is the identifier's own token (not its
/// declaration's), `symbol` is the binding it resolved to. A `.field_access`
/// chain's FIELD token (e.g. `print` in `std.debug.print`) is never a `Ref`
/// -- only the base object identifier (`std`) is, since a field name isn't a
/// scope binding at all.
pub const Ref = struct {
    token: Ast.TokenIndex,
    symbol: Symbol.Id,

    pub const Id = u32;
};

/// A node that opens a new scope over some sub-tree, discovered by scanning
/// node tags once up front. Kept separate from `Scope` because a `Scope`'s
/// `parent` isn't known until every creator's own enclosing scope has been
/// resolved (see `build`).
///
/// `start_token` narrows the token range `innermostScopeId` treats as
/// "inside this scope" to something SMALLER than the whole node, for a
/// capture-bearing construct (`if`/`while`/`for`/switch-case/`catch` with a
/// `|x|` payload). Those scopes are created over the WHOLE node (so
/// `homeless_try` etc. can still ask "what node made this scope"), but the
/// CONDITION/LHS that precedes the `|x|` -- e.g. the `cached` in
/// `if (cached) |cached| ...` -- is lexically part of the OUTER scope, not
/// the capture's: it's evaluated before the capture even exists. Left
/// `null` (defaulting to `tree.firstToken(node)` in `innermostScopeId`) for
/// every other creator kind, whose containment range is genuinely the whole
/// node.
const Creator = struct {
    node: Ast.Node.Index,
    kind: Scope.Kind,
    start_token: ?Ast.TokenIndex = null,
};

/// The whole-file container scope `build` always creates first.
const root_scope: Scope.Id = 0;

/// The only failure mode is OOM: every AST accessor used here (`fullIf`,
/// `fullWhile`, ...) returns `null` rather than an error on a shape it
/// doesn't recognize, so a malformed-but-parsed tree still yields a
/// partial-but-sound scope tree -- worst case a node's scope is coarser
/// (an ancestor's) than a fully correct descent would give it, never a
/// crash or a bogus scope.
pub fn build(gpa: std.mem.Allocator, source: *const Source) std.mem.Allocator.Error!Semantic {
    const tree = &source.ast;

    var creators: std.ArrayListUnmanaged(Creator) = .empty;
    defer creators.deinit(gpa);

    // Node 0 is `.root` (see `Ast.Node.Index`); it's handled as the
    // built-in root scope below rather than as a discovered creator.
    var idx: u32 = 1;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        if (scopeKindFor(tree, node)) |kind| {
            try creators.append(gpa, .{
                .node = node,
                .kind = kind,
                .start_token = captureStartToken(tree, node),
            });
        }
    }

    const node_scope = try gpa.alloc(Scope.Id, tree.nodes.len);
    errdefer gpa.free(node_scope);

    idx = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        node_scope[idx] = innermostScopeId(tree, creators.items, node);
    }

    var scopes: std.ArrayListUnmanaged(Scope) = .empty;
    errdefer scopes.deinit(gpa);
    try scopes.ensureTotalCapacityPrecise(gpa, creators.items.len + 1);
    scopes.appendAssumeCapacity(.{ .parent = null, .node = .root, .kind = .container });
    for (creators.items) |c| {
        // A creator's own `node_scope` entry (computed above, excluding
        // itself) IS the scope it's declared in -- see the file doc.
        scopes.appendAssumeCapacity(.{
            .parent = node_scope[@backingInt(c.node)],
            .node = c.node,
            .kind = c.kind,
        });
    }

    var symbols: std.ArrayListUnmanaged(Symbol) = .empty;
    errdefer freeSymbols(gpa, &symbols);

    const bindings = try gpa.alloc(std.StringHashMapUnmanaged(Symbol.Id), scopes.items.len);
    for (bindings) |*b| b.* = .empty;
    errdefer freeBindings(gpa, bindings);

    // A second pass over every node, this time declaring symbols. Kept
    // separate from the creator scan above (rather than folded in) because
    // declaration depends on the FINISHED `scopes` list -- a fn's params
    // need to look up the fn's own scope id (`Declarer.scopeIdOfNode`),
    // which only exists once every creator has been turned into a `Scope`.
    const declarer: Declarer = .{
        .gpa = gpa,
        .tree = tree,
        .scopes = scopes.items,
        .symbols = &symbols,
        .bindings = bindings,
    };
    idx = 1;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        try declarer.declareNode(node, node_scope[idx]);
    }

    // Phase B: resolve every identifier USE now that every declaration (from
    // ANYWHERE in the file, including textually-later ones) is already in
    // `bindings` -- this is what makes forward references resolve. Runs as
    // its own pass, after Phase A fully completes, rather than being folded
    // into the declarer loop above, precisely so a use appearing before its
    // decl still finds it.
    var refs: std.ArrayListUnmanaged(Ref) = .empty;
    errdefer refs.deinit(gpa);
    idx = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        // A declaration's OWN name (e.g. the `foo` in `fn foo()`) is a
        // token, never a `.identifier` NODE, so this loop only ever sees
        // USE sites -- no need to exclude decl-name nodes explicitly. Same
        // reasoning covers a `.field_access` chain: only its base object is
        // an `.identifier` node, the member tokens (`debug`, `print` in
        // `std.debug.print`) are plain tokens on the `.field_access` node,
        // never nodes of their own, so they're never visited here.
        if (tree.nodeTag(node) != .identifier) continue;
        const tok = tree.nodeMainToken(node);
        const name = tree.tokenSlice(tok);
        const sym_id = resolveBindingImpl(
            .{ .scopes = scopes.items, .bindings = bindings, .symbols = symbols.items },
            node_scope[idx],
            name,
            &.{},
        ) orelse continue;
        const ref_id: Ref.Id = @intCast(refs.items.len);
        try refs.append(gpa, .{ .token = tok, .symbol = sym_id });
        try symbols.items[sym_id].references.append(gpa, ref_id);
    }

    return .{
        .scopes = scopes,
        .node_scope = node_scope,
        .symbols = symbols,
        .bindings = bindings,
        .refs = refs,
        .gpa = gpa,
    };
}

pub fn deinit(self: *Semantic, gpa: std.mem.Allocator) void {
    freeSymbols(gpa, &self.symbols);
    freeBindings(gpa, self.bindings);
    self.refs.deinit(gpa);
    self.scopes.deinit(gpa);
    gpa.free(self.node_scope);
}

fn freeSymbols(gpa: std.mem.Allocator, symbols: *std.ArrayListUnmanaged(Symbol)) void {
    for (symbols.items) |*sym| sym.references.deinit(gpa);
    symbols.deinit(gpa);
}

fn freeBindings(gpa: std.mem.Allocator, bindings: []std.StringHashMapUnmanaged(Symbol.Id)) void {
    for (bindings) |*b| b.deinit(gpa);
    gpa.free(bindings);
}

/// The scope kind `node` creates, or `null` if it doesn't open one. A
/// capture-less `if`/`while`/switch-case creates nothing (its `then`/`else`
/// bodies stay in whatever scope already surrounds the statement) -- only a
/// payload (`|x|`) needs somewhere to bind the captured name.
fn scopeKindFor(tree: *const Ast, node: Ast.Node.Index) ?Scope.Kind {
    return switch (tree.nodeTag(node)) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => .container,

        .fn_decl => .function,

        // A `for` loop's capture (`for (items) |item|`) is mandatory syntax,
        // not optional like `if`/`while`'s -- `full.For.payload_token` is a
        // plain `TokenIndex`, never null -- so `for_simple`/`@"for"` join the
        // unconditional block tags here rather than needing a payload check.
        .block,
        .block_semicolon,
        .block_two,
        .block_two_semicolon,
        .for_simple,
        .@"for",
        => .block,

        .@"comptime" => .comptime_,

        .test_decl => .test_,

        .@"catch" => if (catchHasPayload(tree, node)) .catch_ else null,

        .if_simple, .@"if" => ifKind(tree, node),

        .while_simple, .while_cont, .@"while" => whileKind(tree, node),

        .switch_case_one,
        .switch_case_inline_one,
        .switch_case,
        .switch_case_inline,
        => switchCaseKind(tree, node),

        else => null,
    };
}

/// `if (cond) |x| ...` binds `x` only over the branch(es) that can see it;
/// this slice doesn't yet split `then`/`else` into separate scopes (see the
/// file doc's note on Phase A's token-range-containment approach), so a
/// captured `if` gets one `block`-kind scope over the whole node.
fn ifKind(tree: *const Ast, node: Ast.Node.Index) ?Scope.Kind {
    const full_if = tree.fullIf(node) orelse return null;
    return if (full_if.payload_token != null) .block else null;
}

/// See `ifKind` -- same reasoning applies to a `while (cond) |x| ...` capture.
fn whileKind(tree: *const Ast, node: Ast.Node.Index) ?Scope.Kind {
    const full_while = tree.fullWhile(node) orelse return null;
    return if (full_while.payload_token != null) .block else null;
}

/// See `ifKind` -- same reasoning applies to a `switch` case's `|x|` capture.
fn switchCaseKind(tree: *const Ast, node: Ast.Node.Index) ?Scope.Kind {
    const full_case = tree.fullSwitchCase(node) orelse return null;
    return if (full_case.payload_token != null) .block else null;
}

/// `.@"catch"`'s payload isn't exposed via a `fullX` helper -- per its tag
/// doc in `Ast.zig`, "the error payload is determined by looking at the next
/// token after the `catch` token": present iff that token is a `|`.
fn catchHasPayload(tree: *const Ast, node: Ast.Node.Index) bool {
    const catch_token = tree.nodeMainToken(node);
    return tree.tokenTag(catch_token + 1) == .pipe;
}

/// The payload token (`|x|`'s `x`, or a leading `*` for a by-pointer
/// capture) for a capture-bearing `node`, or `null` for every other creator
/// kind -- see `Creator.start_token`'s doc for why this matters. Mirrors
/// `Declarer.declareCaptures`'s dispatch (same tags, same `fullX`
/// accessors) but only needs the ONE token, not the whole capture list.
fn captureStartToken(tree: *const Ast, node: Ast.Node.Index) ?Ast.TokenIndex {
    return switch (tree.nodeTag(node)) {
        .if_simple, .@"if" => (tree.fullIf(node) orelse return null).payload_token,
        .while_simple, .while_cont, .@"while" => blk: {
            break :blk (tree.fullWhile(node) orelse return null).payload_token;
        },
        .for_simple, .@"for" => (tree.fullFor(node) orelse return null).payload_token,
        .switch_case_one,
        .switch_case_inline_one,
        .switch_case,
        .switch_case_inline,
        => (tree.fullSwitchCase(node) orelse return null).payload_token,
        .@"catch" => if (catchHasPayload(tree, node)) tree.nodeMainToken(node) + 2 else null,
        else => null,
    };
}

/// Everything the declaration-collection pass needs threaded through it,
/// bundled into one receiver so each `declareX` method stays under the
/// project's max-params lint (splitting these into positional params
/// would push several methods past it). Built once per `build` call and
/// passed by value (it's five small fields, all pointers/slices).
const Declarer = struct {
    gpa: std.mem.Allocator,
    tree: *const Ast,
    /// The FINISHED scope list -- a fn's params need to look up the fn's
    /// own scope id (`scopeIdOfNode`), which only exists once every
    /// creator has already been turned into a `Scope`.
    scopes: []const Scope,
    symbols: *std.ArrayListUnmanaged(Symbol),
    bindings: []std.StringHashMapUnmanaged(Symbol.Id),

    /// Declares whatever symbol(s) `node` introduces, if any. `enclosing`
    /// is `node`'s OWN `node_scope` entry -- for a plain `const`/`var`/
    /// field this IS the declaring scope; for `fn_decl` it's the ENCLOSING
    /// (container) scope per the file doc, so the fn's params need a
    /// separate lookup for the fn's own scope (see `declareFn`). Most
    /// nodes declare nothing, so the common case is a single tag-switch
    /// dispatch plus a `fullVarDecl` miss.
    fn declareNode(
        self: Declarer,
        node: Ast.Node.Index,
        enclosing: Scope.Id,
    ) std.mem.Allocator.Error!void {
        switch (self.tree.nodeTag(node)) {
            .fn_decl => try self.declareFn(node, enclosing),

            .container_field_init,
            .container_field_align,
            .container_field,
            => try self.declareField(node, enclosing),

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
            => try self.declareCaptures(node),

            else => if (self.tree.fullVarDecl(node)) |full_var| {
                try self.declareVar(full_var, node, enclosing);
            },
        }
    }

    /// `fn_decl` symbol goes in `enclosing` (the container it's declared
    /// in); its params go in the fn's OWN scope, found by scanning
    /// `scopes` for the entry this `fn_decl` created (Task 1 always
    /// creates exactly one -- see `scopeKindFor`). A `null` name/param
    /// name (parse error, or `anytype` with no bound name) is skipped
    /// rather than guessed at.
    fn declareFn(
        self: Declarer,
        node: Ast.Node.Index,
        enclosing: Scope.Id,
    ) std.mem.Allocator.Error!void {
        var buf: [1]Ast.Node.Index = undefined;
        const full_proto = self.tree.fullFnProto(&buf, node) orelse return;

        if (full_proto.name_token) |name_tok| {
            const visibility: Symbol.Visibility = if (full_proto.visib_token != null)
                .public
            else
                .private;
            try self.declareSymbol(.{
                .name = self.tree.tokenSlice(name_tok),
                .decl = node,
                .scope = enclosing,
                .kind = .function,
                .visibility = visibility,
            });
        }

        const fn_scope = self.scopeIdOfNode(node) orelse return;
        var it = full_proto.iterate(self.tree);
        while (it.next()) |param| {
            const name_tok = param.name_token orelse continue;
            try self.declareSymbol(.{
                .name = self.tree.tokenSlice(name_tok),
                .decl = node,
                .scope = fn_scope,
                .kind = .parameter,
                .visibility = .private,
            });
        }
    }

    /// Tuple-like fields (`struct { u8, u32 }`) have no name token to bind
    /// -- `full.ContainerField.ast.tuple_like` says so, so those are
    /// skipped.
    fn declareField(
        self: Declarer,
        node: Ast.Node.Index,
        enclosing: Scope.Id,
    ) std.mem.Allocator.Error!void {
        const full_field = self.tree.fullContainerField(node) orelse return;
        if (full_field.ast.tuple_like) return;
        try self.declareSymbol(.{
            .name = self.tree.tokenSlice(full_field.ast.main_token),
            .decl = node,
            .scope = enclosing,
            .kind = .field,
            .visibility = .public,
        });
    }

    /// `full.VarDecl` has no name-token field -- per Zig's grammar the
    /// name always immediately follows the `const`/`var` keyword, so
    /// `mut_token + 1` is the name IFF that token is actually an
    /// identifier (a parse-error-recovered tree might not have one there).
    fn declareVar(
        self: Declarer,
        full_var: Ast.full.VarDecl,
        node: Ast.Node.Index,
        enclosing: Scope.Id,
    ) std.mem.Allocator.Error!void {
        const name_tok = full_var.ast.mut_token + 1;
        if (self.tree.tokenTag(name_tok) != .identifier) return;
        const visibility: Symbol.Visibility = if (full_var.visib_token != null)
            .public
        else
            .private;
        try self.declareSymbol(.{
            .name = self.tree.tokenSlice(name_tok),
            .decl = node,
            .scope = enclosing,
            .kind = .variable,
            .visibility = visibility,
        });
    }

    /// Dispatches to whichever `fullX` accessor `node`'s tag needs to
    /// reach its payload token(s), then declares each captured name into
    /// the scope THIS node created (Task 1 creates one whenever a payload
    /// is present -- see `scopeKindFor`). A capture-less node (no
    /// payload) declares nothing.
    fn declareCaptures(self: Declarer, node: Ast.Node.Index) std.mem.Allocator.Error!void {
        const first_token: Ast.TokenIndex = switch (self.tree.nodeTag(node)) {
            .if_simple, .@"if" => blk: {
                const full_if = self.tree.fullIf(node) orelse return;
                break :blk full_if.payload_token orelse return;
            },
            .while_simple, .while_cont, .@"while" => blk: {
                const full_while = self.tree.fullWhile(node) orelse return;
                break :blk full_while.payload_token orelse return;
            },
            .for_simple, .@"for" => (self.tree.fullFor(node) orelse return).payload_token,
            .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => blk: {
                const full_case = self.tree.fullSwitchCase(node) orelse return;
                break :blk full_case.payload_token orelse return;
            },
            .@"catch" => blk: {
                if (!catchHasPayload(self.tree, node)) return;
                break :blk self.tree.nodeMainToken(node) + 2;
            },
            else => return,
        };
        const scope_id = self.scopeIdOfNode(node) orelse return;
        try self.declareCaptureList(node, scope_id, first_token);
    }

    /// Walks a payload's token list starting at the first token after the
    /// opening `|` (an identifier, or a `*` immediately followed by one
    /// for a by-pointer capture), declaring one `capture` symbol per
    /// name, comma-separated (`|x, i|`), until a non-comma token ends the
    /// list.
    fn declareCaptureList(
        self: Declarer,
        decl_node: Ast.Node.Index,
        scope_id: Scope.Id,
        first_token: Ast.TokenIndex,
    ) std.mem.Allocator.Error!void {
        var tok = first_token;
        while (true) {
            if (self.tree.tokenTag(tok) == .asterisk) tok += 1;
            if (self.tree.tokenTag(tok) != .identifier) break;
            try self.declareSymbol(.{
                .name = self.tree.tokenSlice(tok),
                .decl = decl_node,
                .scope = scope_id,
                .kind = .capture,
                .visibility = .private,
            });
            tok += 1;
            if (self.tree.tokenTag(tok) != .comma) break;
            tok += 1;
        }
    }

    /// Appends `Symbol` to `symbols` and binds `name -> its id` in
    /// `bindings[scope]`. If `name` already exists in that scope (only
    /// possible on a malformed-but-parsed tree -- valid Zig rejects
    /// redeclaration), last-writer-wins on the binding; the earlier
    /// `Symbol` stays in `symbols` (just unreachable via `bindings`),
    /// which is harmless.
    fn declareSymbol(self: Declarer, spec: SymbolSpec) std.mem.Allocator.Error!void {
        const id: Symbol.Id = @intCast(self.symbols.items.len);
        try self.symbols.append(self.gpa, .{
            .name = spec.name,
            .decl = spec.decl,
            .scope = spec.scope,
            .kind = spec.kind,
            .visibility = spec.visibility,
        });
        try self.bindings[spec.scope].put(self.gpa, spec.name, id);
    }

    /// Finds the scope id whose `Scope.node == node` (the scope THIS node
    /// created, as opposed to `node_scope[node]` which is the ENCLOSING
    /// scope -- see the file doc). Only called for a handful of node
    /// kinds per file (fns, payload-bearing constructs), so a linear scan
    /// over `scopes` (which Task 1's own doc already signs off on for
    /// similarly-rare lookups) is plenty fast.
    fn scopeIdOfNode(self: Declarer, node: Ast.Node.Index) ?Scope.Id {
        for (self.scopes, 0..) |s, i| {
            if (s.node == node) return @intCast(i);
        }
        return null;
    }
};

/// The arguments to `Declarer.declareSymbol`, bundled into a struct so the
/// method itself stays within the project's max-params lint.
const SymbolSpec = struct {
    name: []const u8,
    decl: Ast.Node.Index,
    scope: Scope.Id,
    kind: Symbol.Kind,
    visibility: Symbol.Visibility,
};

/// The id of the innermost scope enclosing `node`: the smallest-span
/// creator (other than `node` itself) whose token range contains `node`'s
/// first token, or `root_scope` if none does. Excluding `node` itself is
/// what sends a creator's own entry to its PARENT scope rather than the
/// scope it creates -- see the file doc.
///
/// A capture-bearing creator's containment range starts at `c.start_token`
/// (the payload token) rather than the node's own first token, so a token
/// BEFORE the `|x|` -- the `if`/`while` condition, the `switch`/`catch` LHS
/// -- is never considered "inside" the capture scope it lexically precedes.
/// The span used to pick the SMALLEST (innermost) match is measured from
/// that same `start`, not `first`, so a capture scope's reported span
/// reflects its real (smaller) range and still loses to a genuinely
/// narrower nested scope in the comparison below.
fn innermostScopeId(tree: *const Ast, creators: []const Creator, node: Ast.Node.Index) Scope.Id {
    const tok = tree.firstToken(node);
    var best: ?Scope.Id = null;
    var best_span: u32 = std.math.maxInt(u32);
    for (creators, 0..) |c, creator_idx| {
        if (c.node == node) continue;
        const start = c.start_token orelse tree.firstToken(c.node);
        const last = tree.lastToken(c.node);
        if (tok < start or tok > last) continue;
        const span = last - start;
        if (span < best_span) {
            best_span = span;
            // Scope ids: 0 is the root, creator `i` (0-based) is id `i + 1`
            // (see the matching push order in `build`).
            best = @intCast(creator_idx + 1);
        }
    }
    return best orelse root_scope;
}

pub fn nodeScope(self: *const Semantic, node: Ast.Node.Index) Scope.Id {
    return self.node_scope[@backingInt(node)];
}

/// Convenience accessor so callers can write `sema.symbol(id).name` instead
/// of reaching into `sema.symbols.items` directly.
pub fn symbol(self: *const Semantic, id: Symbol.Id) *const Symbol {
    return &self.symbols.items[id];
}

/// Resolves `name` starting at `scope` and walking up the parent chain
/// (nearest-declaring-scope-wins, i.e. shadowing), skipping any binding
/// whose `Symbol.Kind` is in `exclude` (e.g. `no_print`, a later slice,
/// excludes `.variable` so a local `const print = ...` doesn't shadow a
/// wanted `fn print` the way a plain lookup would). Returns `null` if no
/// scope on the walk (up to and including the root container) binds it.
pub fn resolveBinding(
    self: *const Semantic,
    scope: Scope.Id,
    name: []const u8,
    exclude: []const Symbol.Kind,
) ?Symbol.Id {
    return resolveBindingImpl(
        .{ .scopes = self.scopes.items, .bindings = self.bindings, .symbols = self.symbols.items },
        scope,
        name,
        exclude,
    );
}

/// The three parallel tables `resolveBindingImpl` walks, bundled into one
/// value so the function itself stays within the project's max-params lint
/// (mirrors the `Declarer`/`SymbolSpec` bundling used above, in Phase A).
const Tables = struct {
    scopes: []const Scope,
    bindings: []const std.StringHashMapUnmanaged(Symbol.Id),
    symbols: []const Symbol,
};

/// The free-function core of `resolveBinding`, taking a plain `Tables`
/// rather than `*const Semantic` so Phase B (inside `build`) can call it
/// before a `Semantic` value exists to call the method on.
fn resolveBindingImpl(
    tables: Tables,
    scope: Scope.Id,
    name: []const u8,
    exclude: []const Symbol.Kind,
) ?Symbol.Id {
    var current: ?Scope.Id = scope;
    while (current) |scope_id| : (current = tables.scopes[scope_id].parent) {
        const sym_id = tables.bindings[scope_id].get(name) orelse continue;
        if (!kindExcluded(exclude, tables.symbols[sym_id].kind)) return sym_id;
    }
    return null;
}

fn kindExcluded(exclude: []const Symbol.Kind, kind: Symbol.Kind) bool {
    for (exclude) |k| {
        if (k == kind) return true;
    }
    return false;
}

pub fn parentScope(self: *const Semantic, id: Scope.Id) ?Scope.Id {
    return self.scopes.items[id].parent;
}

pub fn scopeKind(self: *const Semantic, id: Scope.Id) Scope.Kind {
    return self.scopes.items[id].kind;
}

pub fn scopeNode(self: *const Semantic, id: Scope.Id) Ast.Node.Index {
    return self.scopes.items[id].node;
}

/// Walks `id`, then its parent, then its parent's parent, ... up to and
/// including the root container scope. Used by rules like `homeless_try`
/// that need to answer "what's the nearest enclosing function/test/etc",
/// skipping past plain `block`/`loop`/`catch_` scopes along the way.
pub const ParentIterator = struct {
    semantic: *const Semantic,
    current: ?Scope.Id,

    pub fn next(self: *ParentIterator) ?Scope.Id {
        const id = self.current orelse return null;
        self.current = self.semantic.parentScope(id);
        return id;
    }
};

pub fn iterParents(self: *const Semantic, id: Scope.Id) ParentIterator {
    return .{ .semantic = self, .current = id };
}

fn findIdentifierNode(tree: *const Ast, name: []const u8) ?Ast.Node.Index {
    var idx: u32 = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        if (tree.nodeTag(node) != .identifier) continue;
        if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name)) return node;
    }
    return null;
}

const fn_body_src =
    \\pub fn f() void {
    \\    const x = 1;
    \\    _ = x;
    \\}
    \\
;

test "identifier inside a fn body resolves block -> function -> root container" {
    const gpa = std.testing.allocator;
    var src = try Source.loadFromSlice(gpa, "t.zig", fn_body_src);
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);

    const use_x = findIdentifierNode(&src.ast, "x").?;
    var kinds: std.ArrayList(Scope.Kind) = .empty;
    defer kinds.deinit(gpa);
    var it = sema.iterParents(sema.nodeScope(use_x));
    while (it.next()) |scope_id| try kinds.append(gpa, sema.scopeKind(scope_id));

    try std.testing.expectEqualSlices(
        Scope.Kind,
        &.{ .block, .function, .container },
        kinds.items,
    );
}

const comptime_src =
    \\comptime {
    \\    const y = 1;
    \\    _ = y;
    \\}
    \\
;

test "comptime block's body resolves through a comptime_ scope" {
    const gpa = std.testing.allocator;
    var src = try Source.loadFromSlice(gpa, "t.zig", comptime_src);
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);

    const use_y = findIdentifierNode(&src.ast, "y").?;
    const block_scope = sema.nodeScope(use_y);
    try std.testing.expectEqual(Scope.Kind.block, sema.scopeKind(block_scope));
    const comptime_scope = sema.parentScope(block_scope).?;
    try std.testing.expectEqual(Scope.Kind.comptime_, sema.scopeKind(comptime_scope));
}

const test_decl_src =
    \\test "t" {
    \\    const z = 1;
    \\    _ = z;
    \\}
    \\
;

test "test block's body resolves through a test_ scope" {
    const gpa = std.testing.allocator;
    var src = try Source.loadFromSlice(gpa, "t.zig", test_decl_src);
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);

    const use_z = findIdentifierNode(&src.ast, "z").?;
    const block_scope = sema.nodeScope(use_z);
    try std.testing.expectEqual(Scope.Kind.block, sema.scopeKind(block_scope));
    const test_scope = sema.parentScope(block_scope).?;
    try std.testing.expectEqual(Scope.Kind.test_, sema.scopeKind(test_scope));
}

const catch_payload_src =
    \\pub fn f() void {
    \\    const v = g() catch |e| blk: {
    \\        _ = e;
    \\        break :blk 0;
    \\    };
    \\    _ = v;
    \\}
    \\fn g() !u8 {
    \\    return 1;
    \\}
    \\
;

test "catch |e| resolves the payload through a catch_ scope" {
    const gpa = std.testing.allocator;
    var src = try Source.loadFromSlice(gpa, "t.zig", catch_payload_src);
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);

    const use_e = findIdentifierNode(&src.ast, "e").?;
    const block_scope = sema.nodeScope(use_e);
    try std.testing.expectEqual(Scope.Kind.block, sema.scopeKind(block_scope));
    const catch_scope = sema.parentScope(block_scope).?;
    try std.testing.expectEqual(Scope.Kind.catch_, sema.scopeKind(catch_scope));
}

test "root scope is a parentless container" {
    const gpa = std.testing.allocator;
    var src = try Source.loadFromSlice(gpa, "t.zig", "const x = 1;\n");
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);

    try std.testing.expectEqual(Scope.Kind.container, sema.scopeKind(root_scope));
    try std.testing.expect(Scope.isContainer(sema.scopeKind(root_scope)));
    try std.testing.expectEqual(@as(?Scope.Id, null), sema.parentScope(root_scope));
    try std.testing.expectEqual(Ast.Node.Index.root, sema.scopeNode(root_scope));
}

/// Finds the first scope of `kind`, in creation order. Only meaningful in
/// tests with exactly one scope of the kind under test.
fn findScopeByKind(sema: *const Semantic, kind: Scope.Kind) ?Scope.Id {
    for (sema.scopes.items, 0..) |s, i| {
        if (s.kind == kind) return @intCast(i);
    }
    return null;
}

test "a top-level pub fn declares a public function symbol in the root scope" {
    const gpa = std.testing.allocator;
    var src = try Source.loadFromSlice(gpa, "t.zig", "pub fn foo() void {}\n");
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);

    const id = sema.bindings[root_scope].get("foo").?;
    const sym = sema.symbols.items[id];
    try std.testing.expectEqualStrings("foo", sym.name);
    try std.testing.expectEqual(Symbol.Kind.function, sym.kind);
    try std.testing.expectEqual(Symbol.Visibility.public, sym.visibility);
    try std.testing.expectEqual(root_scope, sym.scope);
}

test "a top-level const declares a private variable symbol" {
    const gpa = std.testing.allocator;
    var src = try Source.loadFromSlice(gpa, "t.zig", "const bar = 1;\n");
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);

    const id = sema.bindings[root_scope].get("bar").?;
    const sym = sema.symbols.items[id];
    try std.testing.expectEqual(Symbol.Kind.variable, sym.kind);
    try std.testing.expectEqual(Symbol.Visibility.private, sym.visibility);
}

test "a fn parameter is a parameter symbol declared in the function's own scope" {
    const gpa = std.testing.allocator;
    var src = try Source.loadFromSlice(gpa, "t.zig", "fn f(a: u8) void {}\n");
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);

    const fn_scope = findScopeByKind(&sema, .function).?;
    const id = sema.bindings[fn_scope].get("a").?;
    const sym = sema.symbols.items[id];
    try std.testing.expectEqual(Symbol.Kind.parameter, sym.kind);
    try std.testing.expectEqual(fn_scope, sym.scope);
}

const struct_field_src =
    \\const S = struct {
    \\    x: u8,
    \\};
    \\
;

test "a struct field declares a field symbol in the struct's own container scope" {
    const gpa = std.testing.allocator;
    var src = try Source.loadFromSlice(gpa, "t.zig", struct_field_src);
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);

    var struct_scope: ?Scope.Id = null;
    for (sema.scopes.items, 0..) |s, i| {
        if (s.kind == .container and s.parent != null) struct_scope = @intCast(i);
    }
    const id = sema.bindings[struct_scope.?].get("x").?;
    const sym = sema.symbols.items[id];
    try std.testing.expectEqual(Symbol.Kind.field, sym.kind);
    try std.testing.expectEqual(Symbol.Visibility.public, sym.visibility);
    try std.testing.expectEqual(struct_scope.?, sym.scope);
}

test "a catch |e| capture declares a capture symbol in a catch_ scope" {
    const gpa = std.testing.allocator;
    var src = try Source.loadFromSlice(gpa, "t.zig", catch_payload_src);
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);

    const catch_scope = findScopeByKind(&sema, .catch_).?;
    const id = sema.bindings[catch_scope].get("e").?;
    const sym = sema.symbols.items[id];
    try std.testing.expectEqual(Symbol.Kind.capture, sym.kind);
    try std.testing.expectEqual(catch_scope, sym.scope);
}

const forward_ref_src =
    \\fn a() void {
    \\    b();
    \\}
    \\fn b() void {}
    \\
;

test "a decl is bound regardless of use order (forward references)" {
    const gpa = std.testing.allocator;
    var src = try Source.loadFromSlice(gpa, "t.zig", forward_ref_src);
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);

    const id = sema.bindings[root_scope].get("b").?;
    const sym = sema.symbols.items[id];
    try std.testing.expectEqual(Symbol.Kind.function, sym.kind);
    try std.testing.expectEqualStrings("b", sym.name);
    // The call-site `b()` inside `a` is textually BEFORE `fn b`'s own
    // declaration -- Phase B still resolves it because Phase A already
    // bound every decl (including later ones) before Phase B ever runs.
    try std.testing.expect(sym.references.items.len > 0);
    const ref = sema.refs.items[sym.references.items[0]];
    try std.testing.expectEqual(id, ref.symbol);
}

const param_used_in_nested_block_src =
    \\fn f(a: u8) void {
    \\    {
    \\        _ = a;
    \\    }
    \\}
    \\
;

test "resolveBinding walks up the parent chain: a param used in a nested block" {
    const gpa = std.testing.allocator;
    var src = try Source.loadFromSlice(gpa, "t.zig", param_used_in_nested_block_src);
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);

    const fn_scope = findScopeByKind(&sema, .function).?;
    const param_id = sema.bindings[fn_scope].get("a").?;
    const param_sym = sema.symbols.items[param_id];
    try std.testing.expectEqual(Symbol.Kind.parameter, param_sym.kind);
    try std.testing.expect(param_sym.references.items.len > 0);
    const ref = sema.refs.items[param_sym.references.items[0]];
    try std.testing.expectEqual(param_id, ref.symbol);
}

const shadowing_src =
    \\const x = 1;
    \\fn f() void {
    \\    const x = 2;
    \\    _ = x;
    \\}
    \\
;

test "shadowing: a use resolves to the NEAREST enclosing binding" {
    const gpa = std.testing.allocator;
    var src = try Source.loadFromSlice(gpa, "t.zig", shadowing_src);
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);

    const outer_id = sema.bindings[root_scope].get("x").?;
    // The inner `const x` lives in the fn BODY block scope -- scan every
    // non-root scope's bindings for an "x" that isn't the outer one.
    var inner_id: ?Symbol.Id = null;
    for (sema.scopes.items, 0..) |_, i| {
        if (@as(Scope.Id, @intCast(i)) == root_scope) continue;
        if (sema.bindings[i].get("x")) |cand| {
            if (cand != outer_id) inner_id = cand;
        }
    }
    try std.testing.expect(inner_id != null and inner_id.? != outer_id);
    const inner_sym_id = inner_id.?;

    const inner_sym = sema.symbols.items[inner_sym_id];
    const outer_sym = sema.symbols.items[outer_id];
    try std.testing.expect(inner_sym.references.items.len > 0);
    const ref = sema.refs.items[inner_sym.references.items[0]];
    try std.testing.expectEqual(inner_sym_id, ref.symbol);
    // The OUTER `x` is shadowed for every use inside `f` -- it must stay
    // unreferenced, or `unused_decl` hardening (a later slice) would MISS a
    // genuinely-dead top-level decl.
    try std.testing.expectEqual(@as(usize, 0), outer_sym.references.items.len);
}

const exclude_variable_only_src = "const print = 1;\n";

test "resolveBinding exclude filter: a variable-only binding is skipped" {
    const gpa = std.testing.allocator;
    var src = try Source.loadFromSlice(gpa, "t.zig", exclude_variable_only_src);
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);

    const found = sema.resolveBinding(root_scope, "print", &.{.variable});
    try std.testing.expectEqual(@as(?Symbol.Id, null), found);
    // A plain (unfiltered) lookup DOES find it -- confirms the exclusion,
    // not a lookup bug, is what produced `null` above.
    try std.testing.expect(sema.resolveBinding(root_scope, "print", &.{}) != null);
}

const exclude_finds_function_src = "fn print() void {}\n";

test "resolveBinding exclude filter: a non-excluded kind still resolves" {
    const gpa = std.testing.allocator;
    var src = try Source.loadFromSlice(gpa, "t.zig", exclude_finds_function_src);
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);

    const found = sema.resolveBinding(root_scope, "print", &.{.variable}).?;
    try std.testing.expectEqual(Symbol.Kind.function, sema.symbols.items[found].kind);
}

const used_and_unused_src =
    \\const bar = 1;
    \\const baz = 2;
    \\fn f() void {
    \\    _ = bar;
    \\}
    \\
;

test "a used top-level const has references; an unused one stays empty" {
    const gpa = std.testing.allocator;
    var src = try Source.loadFromSlice(gpa, "t.zig", used_and_unused_src);
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);

    const bar_id = sema.bindings[root_scope].get("bar").?;
    const baz_id = sema.bindings[root_scope].get("baz").?;
    try std.testing.expect(sema.symbols.items[bar_id].references.items.len > 0);
    try std.testing.expectEqual(@as(usize, 0), sema.symbols.items[baz_id].references.items.len);
}

const capture_shadows_condition_src =
    \\const cached = @as(?u8, null);
    \\pub fn get() u8 {
    \\    if (cached) |cached| return cached;
    \\    return 0;
    \\}
    \\
;

test "an if condition identifier that reuses the capture's name resolves to the OUTER binding" {
    // Regression for FIX I2: the capture scope used to span the WHOLE `if`
    // node (starting at the `if` keyword), so the CONDITION `cached` --
    // lexically BEFORE the `|cached|` payload even exists -- was wrongly
    // contained by it and resolved to the capture instead of the outer
    // `const cached`. That made the outer decl look zero-referenced and got
    // it deleted by `unused_decl --fix` even though it's genuinely read by
    // the condition. Giving the capture scope a `start_token` at the
    // payload (not the `if` keyword) excludes the condition from it.
    const gpa = std.testing.allocator;
    var src = try Source.loadFromSlice(gpa, "t.zig", capture_shadows_condition_src);
    defer src.deinit(gpa);
    var sema = try Semantic.build(gpa, &src);
    defer sema.deinit(gpa);

    const outer_id = sema.bindings[root_scope].get("cached").?;
    // Only the CONDITION `cached` can possibly resolve to the outer decl --
    // the `return cached` inside the branch is shadowed by the capture -- so
    // this being non-empty pins the condition resolving to the OUTER symbol.
    try std.testing.expect(sema.symbols.items[outer_id].references.items.len > 0);

    // And the capture itself still binds and is used by `return cached`,
    // proving the capture scope's own body wasn't broken by the change.
    var capture_id: ?Symbol.Id = null;
    for (sema.scopes.items, 0..) |s, i| {
        if (s.kind != .block) continue;
        if (sema.bindings[i].get("cached")) |cand| {
            if (cand != outer_id) capture_id = cand;
        }
    }
    try std.testing.expect(capture_id != null);
    try std.testing.expect(sema.symbols.items[capture_id.?].references.items.len > 0);
}

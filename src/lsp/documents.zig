//! In-memory store of the documents an LSP client currently has open, plus
//! the bridge that re-lints them via the EXISTING `Linter` (unchanged) and
//! maps `Diagnostic`s to LSP-shaped results.
//!
//! Ownership: `Documents` owns every byte reachable from a `Doc` it holds --
//! `uri`, `path`, `text`, the resolved `Config`, and `last_diags` (including
//! each diagnostic's `message`). `deinit`/`close` free all of it. Re-linting
//! (`lint`) frees the previous `last_diags` set (messages then the slice)
//! before installing the new one, so no diagnostic set is ever leaked across
//! edits. `toLspDiagnostics`'s returned `LspDiagnostic`s borrow their
//! `.message` string from the `Doc` they were built from (`.source` and
//! `.code` are process-lifetime statics, not doc-scoped) -- the caller frees
//! only the returned slice, never `.message`, and must not hold onto it past
//! the next `lint`/`close` on that doc.
const std = @import("std");
const Source = @import("../Source.zig");
const Config = @import("../Config.zig");
const Linter = @import("../Linter.zig");
const Diagnostic = @import("../Diagnostic.zig");
const cli = @import("../cli.zig");
const protocol = @import("protocol.zig");
const position = @import("position.zig");

const line_width = @import("../lints/line_width.zig");
const naming_convention = @import("../lints/naming_convention.zig");
const too_many_params = @import("../lints/too_many_params.zig");
const redundant_else = @import("../lints/redundant_else.zig");
const discarded_error = @import("../lints/discarded_error.zig");
const inline_container_type = @import("../lints/inline_container_type.zig");

/// A single open document plus everything derived from it. See the module
/// doc comment for the ownership contract -- every field here is owned by
/// whichever `Documents` holds this `Doc` and freed by that store.
pub const Doc = struct {
    /// The LSP URI the client opened this document under (e.g.
    /// `file:///a/b.zig`), verbatim.
    uri: []const u8,
    /// Best-effort filesystem path derived from `uri` via `uriToPath`,
    /// resolved once at `open` time (the URI's scheme/authority never
    /// changes across `change` calls, so there is no need to recompute it
    /// per-lint). Used only as the `Diagnostic.path` label passed to
    /// `Source.loadFromSlice` -- `protocol.LspDiagnostic` has no path field,
    /// so this never reaches the wire and imprecision here (see `uriToPath`)
    /// is harmless in practice.
    path: []const u8,
    /// The document's current full text, replaced wholesale on `change`
    /// (this skeleton only supports full-document sync, not incremental
    /// ranges).
    text: []const u8,
    /// Config resolved once at `open` time by walking up from `path`'s
    /// directory for the nearest `zippy.zon` (see `resolveConfig`).
    config: Config,
    /// The diagnostics from the most recent `lint` call; empty until the
    /// first `lint`. Owned (including each `.message`); replaced (old set
    /// freed first) by every `lint` call.
    last_diags: []Diagnostic = &.{},
};

/// The store's own errors, distinct from whatever `Allocator.Error`/
/// `Config`/`Linter` errors also propagate through these functions.
pub const DocumentsError = error{DocumentNotFound};

/// The in-memory document store. See the module doc comment for the
/// ownership contract.
pub const Documents = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Keyed by `Doc.uri` (the exact same slice stored in the value's
    /// pointee, not a second copy -- see `open`), so no separate key
    /// allocation is needed. Values are heap-boxed `*Doc` (not `Doc`
    /// directly) so that a `*Doc` returned by `get` stays valid across a
    /// later `open`/`close` that grows/rehashes the map -- rehashing only
    /// moves the `*Doc` pointer values around, never the `Doc` payloads
    /// they point to.
    docs: std.StringHashMapUnmanaged(*Doc) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Documents {
        return .{ .gpa = gpa, .io = io, .docs = .empty };
    }

    /// Frees every doc's owned memory, then the map's own storage.
    pub fn deinit(self: *Documents) void {
        var it = self.docs.valueIterator();
        while (it.next()) |doc| self.freeDoc(doc.*);
        self.docs.deinit(self.gpa);
    }

    /// Registers a newly-opened document: dupes `uri`/`text`, derives and
    /// dupes a best-effort filesystem `path` from `uri`, resolves the
    /// nearest `zippy.zon` (or `Config.default()`), and stores it with an
    /// empty `last_diags` (callers `lint` separately to populate it, per
    /// this module's tests).
    ///
    /// Re-opening an already-open `uri` (a client re-sending `didOpen`)
    /// replaces the prior entry, freeing its owned memory first rather than
    /// leaking it.
    pub fn open(self: *Documents, uri: []const u8, text: []const u8) !void {
        if (self.docs.fetchRemove(uri)) |kv| self.freeDoc(kv.value);

        const owned_uri = try self.gpa.dupe(u8, uri);
        errdefer self.gpa.free(owned_uri);
        const owned_path = uriToPath(self.gpa, owned_uri) catch try self.gpa.dupe(u8, owned_uri);
        errdefer self.gpa.free(owned_path);
        const owned_text = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(owned_text);
        var config = try self.resolveConfig(owned_path);
        errdefer config.deinit(self.gpa);

        const doc = try self.gpa.create(Doc);
        errdefer self.gpa.destroy(doc);
        doc.* = .{
            .uri = owned_uri,
            .path = owned_path,
            .text = owned_text,
            .config = config,
            .last_diags = &.{},
        };

        try self.docs.put(self.gpa, owned_uri, doc);
    }

    /// Replaces `uri`'s text wholesale (full-document sync). Does NOT
    /// re-lint -- callers call `lint` afterward, same as `open`, so a
    /// caller that wants to batch several rapid edits before re-linting can.
    pub fn change(
        self: *Documents,
        uri: []const u8,
        text: []const u8,
    ) (DocumentsError || std.mem.Allocator.Error)!void {
        const doc = self.docs.get(uri) orelse return error.DocumentNotFound;
        const owned_text = try self.gpa.dupe(u8, text);
        self.gpa.free(doc.text);
        doc.text = owned_text;
    }

    /// Drops `uri` entirely, freeing all of its owned memory. A no-op if
    /// `uri` isn't currently open (matches a client sending `didClose` for
    /// something it never successfully opened).
    pub fn close(self: *Documents, uri: []const u8) void {
        if (self.docs.fetchRemove(uri)) |kv| self.freeDoc(kv.value);
    }

    /// Returns a pointer to `uri`'s `Doc`, or `null` if it isn't open.
    ///
    /// The `Doc` itself is heap-boxed (the map stores `*Doc`, not `Doc`), so
    /// this pointer stays valid across any subsequent `open`/`close` call on
    /// a DIFFERENT `uri`, even one that grows/rehashes the map -- rehashing
    /// only moves the `*Doc` pointer values around, never the `Doc` payload
    /// this pointer points to. It is invalidated only by closing (or
    /// re-`open`ing) THIS SAME `uri`, which frees this `Doc`.
    pub fn get(self: *Documents, uri: []const u8) ?*Doc {
        return self.docs.get(uri);
    }

    /// Re-lints `doc`: reparses `doc.text` via `Source.loadFromSlice` (the
    /// existing, unmodified `Source`/`Linter`), runs every enabled lint
    /// against `doc.config`, and replaces `doc.last_diags` -- freeing the
    /// previous set's messages (then the slice) first so re-linting never
    /// leaks the prior diagnostics.
    pub fn lint(self: *Documents, doc: *Doc) !void {
        var src = try Source.loadFromSlice(self.gpa, doc.path, doc.text);
        defer src.deinit(self.gpa);

        var diags: std.ArrayList(Diagnostic) = .empty;
        errdefer {
            for (diags.items) |d| self.gpa.free(d.message);
            diags.deinit(self.gpa);
        }
        try Linter.run(self.gpa, &src, &doc.config, &diags);

        freeDiagMessages(self.gpa, doc.last_diags);
        self.gpa.free(doc.last_diags);
        // Leave `doc.last_diags` in a safe, re-freeable empty state before
        // the fallible `toOwnedSlice` below -- if it errors (OOM), the two
        // frees above have already happened, so `doc.last_diags` must not
        // still point at the freed slice (that would be a double-free/UAF
        // on the next `lint`/`close`/`deinit`/`hoverAt`/`toLspDiagnostics`).
        doc.last_diags = &.{};
        doc.last_diags = try diags.toOwnedSlice(self.gpa);
    }

    /// Resolves the `Config` to lint `path` with: walks up from `path`'s
    /// directory for the nearest `zippy.zon` (reusing `cli.loadNearestConfigFrom`
    /// unchanged), falling back to `Config.default()` if `path` has no
    /// parent directory to start from (e.g. a bare `/`).
    fn resolveConfig(self: *Documents, path: []const u8) !Config {
        const dir = std.fs.path.dirname(path) orelse return Config.default();
        return cli.loadNearestConfigFrom(self.io, self.gpa, dir);
    }

    /// Frees every piece of memory a `Doc` owns (see the module doc
    /// comment), then the heap-boxed `Doc` itself. `doc` is the `*Doc`
    /// callers get either straight out of the map (`fetchRemove`'s
    /// `.value`) or a dereferenced iterator value -- either way it is the
    /// same pointer `open` allocated with `gpa.create(Doc)`, so it is this
    /// function's job to `gpa.destroy` it, not just clear its fields.
    fn freeDoc(self: *Documents, doc: *Doc) void {
        self.gpa.free(doc.uri);
        self.gpa.free(doc.path);
        self.gpa.free(doc.text);
        doc.config.deinit(self.gpa);
        freeDiagMessages(self.gpa, doc.last_diags);
        self.gpa.free(doc.last_diags);
        self.gpa.destroy(doc);
    }
};

fn freeDiagMessages(gpa: std.mem.Allocator, diags: []const Diagnostic) void {
    for (diags) |d| gpa.free(d.message);
}

/// Converts a `file://` URI to a filesystem path, keeping the leading `/`
/// (e.g. `file:///a/b.zig` -> `/a/b.zig`). The returned slice is a fresh
/// allocation owned by the caller.
///
/// Percent-decoding is deliberately NOT performed: a URI containing
/// percent-escapes (e.g. a path with a space, sent as `%20`) resolves to a
/// path with the literal `%20` still in it rather than a decoded space. This
/// is a real but narrow gap left for a follow-up task -- the resulting path
/// is only ever used as a diagnostic label and as a starting point for the
/// `zippy.zon` walk-up (see `resolveConfig`), neither of which is
/// correctness-critical for the LSP skeleton.
fn uriToPath(gpa: std.mem.Allocator, uri: []const u8) ![]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.UnsupportedUriScheme;
    return gpa.dupe(u8, uri[prefix.len..]);
}

/// Maps each of `doc.last_diags` to an LSP diagnostic: `range` from
/// `position.offsetToPosition` (start/end) under the negotiated `enc`,
/// severity mapped (`.@"error"` -> 1, `.warn` -> 2; `.off` never appears --
/// `Linter.run` filters `.off`-severity lints out before constructing a
/// `Diagnostic`), `source` fixed to `"zippy"`, and `code`/`message` borrowed
/// from the diagnostic.
///
/// The returned slice is owned by the caller (free with `gpa`). Of the
/// three string fields, only `.message` borrows from `doc` (it is the
/// diagnostic's owned message, freed/replaced on the doc's next `lint`) and
/// so stays valid only as long as `doc` isn't re-linted or closed; `.source`
/// is the static literal `"zippy"` and `.code` is `d.lint`, a process
/// lifetime static (a lint module's `pub const name`) -- neither of those
/// two is doc-scoped.
pub fn toLspDiagnostics(
    gpa: std.mem.Allocator,
    doc: *const Doc,
    enc: position.Encoding,
) ![]protocol.LspDiagnostic {
    const out = try gpa.alloc(protocol.LspDiagnostic, doc.last_diags.len);
    errdefer gpa.free(out);
    for (doc.last_diags, 0..) |d, i| {
        out[i] = .{
            .range = .{
                .start = position.offsetToPosition(doc.text, d.byte_offset, enc),
                .end = position.offsetToPosition(doc.text, d.end_offset, enc),
            },
            .severity = severityToLsp(d.severity),
            .source = "zippy",
            .code = d.lint,
            .message = d.message,
        };
    }
    return out;
}

fn severityToLsp(s: Diagnostic.Severity) u8 {
    return switch (s) {
        // `Linter.run` resolves severity before constructing a `Diagnostic`
        // and skips any lint resolved to `.off`, so an `.off`-severity
        // `Diagnostic` reaching here would be a programmer error, not a
        // real case to map -- same reasoning as `Diagnostic.levelName`.
        .off => unreachable,
        .@"error" => 1,
        .warn => 2,
    };
}

/// What `hoverAt` returns: the covering diagnostic's own message and lint
/// name, plus that lint's general `description` (looked up via
/// `descriptionFor`). All three are borrowed (see `toLspDiagnostics`'s
/// ownership note -- same rule applies here).
pub const HoverInfo = struct {
    message: []const u8,
    lint: []const u8,
    description: []const u8,
};

/// Finds the first of `doc.last_diags` whose `[byte_offset, end_offset)`
/// span covers `byte_offset`, returning its message/lint plus that lint's
/// description. `null` if no diagnostic covers the offset.
pub fn hoverAt(doc: *const Doc, byte_offset: usize) ?HoverInfo {
    for (doc.last_diags) |d| {
        if (byte_offset >= d.byte_offset and byte_offset < d.end_offset) {
            return .{
                .message = d.message,
                .lint = d.lint,
                .description = descriptionFor(d.lint) orelse "",
            };
        }
    }
    return null;
}

/// Looks up a lint's `description` by `name`, matching against the same six
/// lint modules `Linter.registry` runs. Not derived FROM `registry` itself
/// because `LintEntry` only carries a `run` function pointer, not the
/// module's `description` constant -- this is a small parallel lookup
/// instead of widening `LintEntry`'s shape for a field only the LSP side
/// needs. `"parse"` (the pseudo-lint name `Linter.run` uses for AST parse
/// errors) intentionally has no entry here and resolves to `null`.
fn descriptionFor(lint_name: []const u8) ?[]const u8 {
    inline for (.{
        line_width,
        naming_convention,
        too_many_params,
        redundant_else,
        discarded_error,
        inline_container_type,
    }) |mod| {
        if (std.mem.eql(u8, lint_name, mod.name)) return mod.description;
    }
    return null;
}

test "open then lint yields expected diagnostics with spans" {
    const gpa = std.testing.allocator;
    var docs: Documents = .init(gpa, std.testing.io);
    defer docs.deinit();
    try docs.open("file:///t.zig", "fn Bad_Name() void {}\n");
    const doc = docs.get("file:///t.zig").?;
    try docs.lint(doc);
    try std.testing.expect(doc.last_diags.len >= 1);
    var found = false;
    for (doc.last_diags) |d| {
        if (std.mem.eql(u8, d.lint, "naming_convention")) found = true;
    }
    try std.testing.expect(found);
}

test "hoverAt returns the covering diagnostic's description" {
    const gpa = std.testing.allocator;
    var docs: Documents = .init(gpa, std.testing.io);
    defer docs.deinit();
    try docs.open("file:///t.zig", "fn Bad_Name() void {}\n");
    const doc = docs.get("file:///t.zig").?;
    try docs.lint(doc);
    // byte offset 4 is inside "Bad_Name"
    const info = hoverAt(doc, 4).?;
    try std.testing.expect(std.mem.indexOf(u8, info.description, "camelCase") != null);
}

test "hoverAt outside any diagnostic span returns null" {
    const gpa = std.testing.allocator;
    var docs: Documents = .init(gpa, std.testing.io);
    defer docs.deinit();
    try docs.open("file:///t.zig", "fn Bad_Name() void {}\n");
    const doc = docs.get("file:///t.zig").?;
    try docs.lint(doc);
    // way past the end of the text.
    try std.testing.expect(hoverAt(doc, 1000) == null);
}

test "toLspDiagnostics ranges match offsetToPosition of the diagnostic span" {
    const gpa = std.testing.allocator;
    var docs: Documents = .init(gpa, std.testing.io);
    defer docs.deinit();
    try docs.open("file:///t.zig", "fn Bad_Name() void {}\n");
    const doc = docs.get("file:///t.zig").?;
    try docs.lint(doc);

    const lsp_diags = try toLspDiagnostics(gpa, doc, .utf16);
    defer gpa.free(lsp_diags);
    try std.testing.expect(lsp_diags.len == doc.last_diags.len);
    for (lsp_diags, doc.last_diags) |ld, d| {
        const expected_start = position.offsetToPosition(doc.text, d.byte_offset, .utf16);
        const expected_end = position.offsetToPosition(doc.text, d.end_offset, .utf16);
        try std.testing.expectEqual(expected_start.line, ld.range.start.line);
        try std.testing.expectEqual(expected_start.character, ld.range.start.character);
        try std.testing.expectEqual(expected_end.line, ld.range.end.line);
        try std.testing.expectEqual(expected_end.character, ld.range.end.character);
        try std.testing.expectEqualStrings("zippy", ld.source);
        try std.testing.expectEqualStrings(d.lint, ld.code);
        try std.testing.expectEqualStrings(d.message, ld.message);
    }
}

test "change replaces text and re-lint reflects it" {
    const gpa = std.testing.allocator;
    var docs: Documents = .init(gpa, std.testing.io);
    defer docs.deinit();
    try docs.open("file:///t.zig", "fn Bad_Name() void {}\n");
    const doc1 = docs.get("file:///t.zig").?;
    try docs.lint(doc1);
    try std.testing.expect(doc1.last_diags.len >= 1);

    try docs.change("file:///t.zig", "fn goodName() void {}\n");
    const doc2 = docs.get("file:///t.zig").?;
    try std.testing.expectEqualStrings("fn goodName() void {}\n", doc2.text);
    try docs.lint(doc2);
    for (doc2.last_diags) |d| {
        try std.testing.expect(!std.mem.eql(u8, d.lint, "naming_convention"));
    }
}

test "close drops the doc" {
    const gpa = std.testing.allocator;
    var docs: Documents = .init(gpa, std.testing.io);
    defer docs.deinit();
    try docs.open("file:///t.zig", "fn Bad_Name() void {}\n");
    const doc = docs.get("file:///t.zig").?;
    try docs.lint(doc);
    docs.close("file:///t.zig");
    try std.testing.expect(docs.get("file:///t.zig") == null);
}

test "open/change/close cycle leaves no leaks" {
    const gpa = std.testing.allocator;
    var docs: Documents = .init(gpa, std.testing.io);
    defer docs.deinit();
    try docs.open("file:///a.zig", "fn Bad_Name() void {}\n");
    try docs.open("file:///b.zig", "fn ok() void {}\n");
    const a = docs.get("file:///a.zig").?;
    try docs.lint(a);
    const b = docs.get("file:///b.zig").?;
    try docs.lint(b);
    try docs.change("file:///a.zig", "fn stillBad_Name() void {}\n");
    const a2 = docs.get("file:///a.zig").?;
    try docs.lint(a2);
    docs.close("file:///b.zig");
    try std.testing.expect(docs.get("file:///b.zig") == null);
    try std.testing.expect(docs.get("file:///a.zig") != null);
}

test "get's *Doc pointer stays valid across a map rehash from later opens" {
    const gpa = std.testing.allocator;
    var docs: Documents = .init(gpa, std.testing.io);
    defer docs.deinit();

    try docs.open("file:///first.zig", "fn Bad_Name() void {}\n");
    const first = docs.get("file:///first.zig").?;

    // Open enough further docs to force the backing map to grow/rehash at
    // least once. Under the old `StringHashMapUnmanaged(Doc)` representation
    // this would move `first`'s `Doc` payload to a new backing array,
    // leaving the `first` pointer above dangling (UAF).
    var buf: [32]u8 = undefined;
    for (0..64) |i| {
        const uri = try std.fmt.bufPrint(&buf, "file:///more{d}.zig", .{i});
        try docs.open(uri, "fn ok() void {}\n");
    }

    // `first` must still point at the SAME, still-valid `Doc`: its owned
    // fields read back correctly, and it's still safe to lint through it.
    try std.testing.expectEqualStrings("file:///first.zig", first.uri);
    try std.testing.expectEqualStrings("fn Bad_Name() void {}\n", first.text);
    try docs.lint(first);
    try std.testing.expect(first.last_diags.len >= 1);

    // And `get` for the same uri returns the identical pointer.
    try std.testing.expect(docs.get("file:///first.zig").? == first);
}

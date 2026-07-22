//! Plain structs mirroring the LSP/JSON-RPC message shapes Zippy's server
//! speaks, (de)serialized directly by `std.json` -- no methods, no logic.
//! Field names intentionally match the LSP spec's camelCase JSON keys
//! (e.g. `textDocument`, `contentChanges`) rather than Zig's usual
//! snake_case, because `std.json.parseFromSlice`/`Stringify.value` map
//! struct fields to JSON object keys by exact name with no renaming step.
//!
//! Incoming messages are parsed with
//! `std.json.parseFromSlice(T, gpa, slice, .{ .ignore_unknown_fields = true })`
//! -- real clients send many fields these structs don't model (e.g.
//! `languageId`/`version` on `TextDocumentItem`), so unknown fields must be
//! ignored rather than rejected. Outgoing messages are emitted with
//! `std.json.Stringify.value`/`valueAlloc` and
//! `.{ .emit_null_optional_fields = false }` so absent optionals don't
//! appear as `"field":null` in the wire output.
const std = @import("std");

pub const Position = struct { line: u32, character: u32 };
pub const Range = struct { start: Position, end: Position };
pub const LspDiagnostic = struct {
    range: Range,
    severity: u8,
    source: []const u8,
    code: []const u8,
    message: []const u8,
};
pub const PublishDiagnosticsParams = struct {
    uri: []const u8,
    diagnostics: []const LspDiagnostic,
};
pub const TextDocumentItem = struct { uri: []const u8, text: []const u8 };
pub const DidOpenParams = struct { textDocument: TextDocumentItem };
pub const VersionedTextDocumentIdentifier = struct { uri: []const u8 };
pub const TextDocumentContentChangeEvent = struct { text: []const u8 };
pub const DidChangeParams = struct {
    textDocument: VersionedTextDocumentIdentifier,
    contentChanges: []const TextDocumentContentChangeEvent,
};
pub const TextDocumentIdentifier = struct { uri: []const u8 };
pub const DidCloseParams = struct { textDocument: TextDocumentIdentifier };
pub const DidSaveParams = struct { textDocument: TextDocumentIdentifier };
pub const HoverParams = struct {
    textDocument: TextDocumentIdentifier,
    position: Position,
};
pub const MarkupContent = struct { kind: []const u8 = "markdown", value: []const u8 };
pub const Hover = struct { contents: MarkupContent };

pub const TextEdit = struct { range: Range, newText: []const u8 };

/// `textDocument/codeAction`'s `context`: the client's own diagnostics for the
/// range and an optional `only` kind filter. Both default empty so a client
/// that omits either still parses.
pub const CodeActionContext = struct {
    diagnostics: []const LspDiagnostic = &.{},
    only: []const []const u8 = &.{},
};
pub const CodeActionParams = struct {
    textDocument: TextDocumentIdentifier,
    range: Range,
    context: CodeActionContext = .{},
};

/// The opaque blob round-tripped between `textDocument/codeAction` (which
/// computes it) and `codeAction/resolve` (which turns it into a `WorkspaceEdit`).
/// Self-contained -- resolve never has to touch the live document -- so it
/// carries the already-resolved LSP `range` and `newText`, not byte offsets.
pub const CodeActionData = struct {
    uri: []const u8,
    range: Range,
    newText: []const u8,
};

/// Serializes as `{"changes":{"<uri>":[<edits>]}}` -- the LSP `WorkspaceEdit`
/// `changes`-map form. A custom `jsonStringify` is required because the map key
/// is a runtime value (the document uri), which a fixed-field Zig struct can't
/// express. The `changes` form (rather than `documentChanges`) needs no client
/// capability, so it works in every editor.
pub const WorkspaceEdit = struct {
    uri: []const u8,
    edits: []const TextEdit,
    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("changes");
        try jws.beginObject();
        try jws.objectField(self.uri);
        try jws.write(self.edits);
        try jws.endObject();
        try jws.endObject();
    }
};

/// A code action as first returned by `textDocument/codeAction`: no `edit` yet
/// (the client must call `codeAction/resolve` to get it -- see `CodeActionData`).
pub const UnresolvedCodeAction = struct {
    title: []const u8,
    kind: []const u8,
    diagnostics: []const LspDiagnostic,
    data: CodeActionData,
};
/// The same action after `codeAction/resolve`, now carrying its `edit`.
pub const ResolvedCodeAction = struct {
    title: []const u8,
    kind: []const u8,
    edit: WorkspaceEdit,
};

test "parse DidOpenParams ignoring unknown fields" {
    const gpa = std.testing.allocator;
    const src =
        \\{"textDocument":{"uri":"file:///a.zig","languageId":"zig",
        \\"version":1,"text":"const x=1;"}}
    ;
    const parsed = try std.json.parseFromSlice(
        DidOpenParams,
        gpa,
        src,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("file:///a.zig", parsed.value.textDocument.uri);
    try std.testing.expectEqualStrings("const x=1;", parsed.value.textDocument.text);
}

test "stringify PublishDiagnosticsParams" {
    const gpa = std.testing.allocator;
    const p: PublishDiagnosticsParams = .{
        .uri = "file:///a.zig",
        .diagnostics = &.{.{
            .range = .{
                .start = .{ .line = 0, .character = 6 },
                .end = .{ .line = 0, .character = 7 },
            },
            .severity = 2,
            .source = "zippy",
            .code = "naming_convention",
            .message = "bad name",
        }},
    };
    const out = try std.json.Stringify.valueAlloc(gpa, p, .{ .emit_null_optional_fields = false });
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"naming_convention\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"character\":6") != null);
}

test "parse CodeActionParams with context.only and unknown fields ignored" {
    const gpa = std.testing.allocator;
    const src =
        \\{"textDocument":{"uri":"file:///t.zig"},
        \\"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},
        \\"context":{"diagnostics":[],"only":["quickfix"],"triggerKind":1}}
    ;
    const parsed = try std.json.parseFromSlice(
        CodeActionParams,
        gpa,
        src,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("file:///t.zig", parsed.value.textDocument.uri);
    try std.testing.expectEqual(@as(u32, 5), parsed.value.range.end.character);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.context.only.len);
    try std.testing.expectEqualStrings("quickfix", parsed.value.context.only[0]);
}

test "WorkspaceEdit serializes as a changes-map keyed by the document uri" {
    const gpa = std.testing.allocator;
    const we: WorkspaceEdit = .{
        .uri = "file:///t.zig",
        .edits = &.{.{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 1, .character = 0 },
            },
            .newText = "",
        }},
    };
    const out = try std.json.Stringify.valueAlloc(gpa, we, .{ .emit_null_optional_fields = false });
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"changes\":{\"file:///t.zig\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"newText\":\"\"") != null);
}

test "UnresolvedCodeAction stringifies with data and without an edit key" {
    const gpa = std.testing.allocator;
    const a: UnresolvedCodeAction = .{
        .title = "remove unused declaration",
        .kind = "quickfix",
        .diagnostics = &.{},
        .data = .{
            .uri = "file:///t.zig",
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 1, .character = 0 },
            },
            .newText = "",
        },
    };
    const out = try std.json.Stringify.valueAlloc(gpa, a, .{ .emit_null_optional_fields = false });
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"quickfix\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"data\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"edit\"") == null);
}

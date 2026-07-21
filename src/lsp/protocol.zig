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

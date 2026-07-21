//! Byte offset <-> LSP `Position{line, character}` conversion.
//!
//! LSP positions are line/character pairs, not byte offsets, and the LSP
//! spec lets the *character* unit be negotiated per-client: UTF-16 code
//! units by default, or UTF-8 bytes if the client advertises
//! `general.positionEncodings` with `"utf-8"`. Zippy's `Diagnostic`s and
//! internal `Source` machinery work in byte offsets throughout, so this
//! module is the single place that translates between the two worlds for
//! `textDocument/publishDiagnostics` and `textDocument/hover`.
const std = @import("std");
const protocol = @import("protocol.zig");

/// Which unit `Position.character` is measured in, per the negotiated LSP
/// encoding (see module doc comment).
pub const Encoding = enum { utf8, utf16 };

/// Converts a byte offset into `bytes` to a `Position`.
///
/// `line` is the count of `\n` bytes strictly before `byte_offset`.
/// `character` is the width of `bytes[line_start..byte_offset]` in the
/// requested `enc` (UTF-8 bytes, or UTF-16 code units with astral
/// codepoints counted as 2 per the surrogate-pair rule).
///
/// `byte_offset` is clamped to `bytes.len` rather than asserted, since
/// callers may pass offsets derived from a document that changed underneath
/// them (edits racing diagnostics); returning the end-of-document position
/// is safer than panicking the long-lived server loop.
pub fn offsetToPosition(bytes: []const u8, byte_offset: usize, enc: Encoding) protocol.Position {
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < byte_offset and i < bytes.len) : (i += 1) {
        if (bytes[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    const end = @min(byte_offset, bytes.len);
    const col_bytes = bytes[line_start..end];
    const character: u32 = switch (enc) {
        .utf8 => @intCast(col_bytes.len),
        .utf16 => utf16Len(col_bytes),
    };
    return .{ .line = line, .character = character };
}

/// Width of a run of UTF-8 bytes (assumed to contain no `\n`) in UTF-16
/// code units: 1 per BMP codepoint, 2 per astral codepoint (surrogate
/// pair). Malformed UTF-8 is recovered from, not panicked on -- LSP text is
/// expected to be valid UTF-8, but a bad lead byte or a multi-byte sequence
/// truncated at the end of the buffer must count as one unit and advance one
/// byte rather than crash the server loop. `std.unicode.Utf8Iterator` is
/// deliberately not used here: its `nextCodepointSlice` panics on an invalid
/// lead byte and slices out of bounds on a truncated tail, which is exactly
/// the crash this function exists to avoid.
fn utf16Len(utf8: []const u8) u32 {
    var i: usize = 0;
    var units: u32 = 0;
    while (i < utf8.len) {
        const seq = std.unicode.utf8ByteSequenceLength(utf8[i]) catch {
            i += 1;
            units += 1;
            continue;
        };
        const remaining = utf8.len - i;
        if (seq > remaining) {
            i += 1;
            units += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(utf8[i .. i + seq]) catch {
            i += 1;
            units += 1;
            continue;
        };
        units += std.unicode.utf16CodepointSequenceLength(cp) catch 1;
        i += seq;
    }
    return units;
}

/// Converts a `Position` back to a byte offset into `bytes` -- the inverse
/// of `offsetToPosition`, used by hover to turn the client's cursor
/// position back into a byte offset for lint/diagnostic lookup.
///
/// Advances to the start of `pos.line` (a `line` past the last `\n`
/// clamps to end-of-document), then walks `pos.character` columns in `enc`
/// from there. A malformed UTF-8 lead byte, or a multi-byte sequence
/// truncated by the end of the buffer, is treated as a one-byte, one-column
/// codepoint and skipped rather than causing a panic or a mis-decode,
/// matching `offsetToPosition`'s recovery behavior so the two stay inverses
/// of each other even over slightly-invalid input. A truncated tail is
/// never decoded (decoding it would dispatch on the clamped slice length
/// and risk mis-reading a truncated 4-byte lead as a valid shorter
/// codepoint); it is simply counted as malformed, same as an outright bad
/// lead byte.
pub fn positionToOffset(bytes: []const u8, pos: protocol.Position, enc: Encoding) usize {
    var line: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len and line < pos.line) : (i += 1) {
        if (bytes[i] == '\n') line += 1;
    }
    var col: u32 = 0;
    while (i < bytes.len and bytes[i] != '\n' and col < pos.character) {
        const seq = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            i += 1;
            col += 1;
            continue;
        };
        const remaining = bytes.len - i;
        if (seq > remaining) {
            i += 1;
            col += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(bytes[i..][0..seq]) catch {
            i += 1;
            col += 1;
            continue;
        };
        col += switch (enc) {
            .utf8 => @as(u32, seq),
            .utf16 => std.unicode.utf16CodepointSequenceLength(cp) catch 1,
        };
        i += seq;
    }
    return i;
}

test "offsetToPosition ascii" {
    const s = "abc\ndef";
    const p = offsetToPosition(s, 5, .utf8); // 'e' -> line 1, char 1
    try std.testing.expectEqual(@as(u32, 1), p.line);
    try std.testing.expectEqual(@as(u32, 1), p.character);
}

test "offsetToPosition non-ascii utf8 vs utf16 columns" {
    // "é" is 2 UTF-8 bytes, 1 UTF-16 unit. Byte offset 3 is just after "aé" on line 0.
    const s = "aé x"; // bytes: 'a'(1) 'é'(2) ' '(1) 'x'(1)
    const off: usize = 3; // start of the space
    try std.testing.expectEqual(@as(u32, 3), offsetToPosition(s, off, .utf8).character); // bytes
    try std.testing.expectEqual(@as(u32, 2), offsetToPosition(s, off, .utf16).character); // units
}

test "positionToOffset inverts offsetToPosition (utf16, non-ascii)" {
    const s = "aé x\nyz";
    const enc: Encoding = .utf16;
    const off: usize = 3;
    const pos = offsetToPosition(s, off, enc);
    try std.testing.expectEqual(off, positionToOffset(s, pos, enc));
}

test "astral codepoint counts as 2 utf16 units, 4 utf8 bytes" {
    // U+1F600 GRINNING FACE: 4 UTF-8 bytes, 2 UTF-16 code units (surrogate pair).
    const s = "a😀b";
    const off: usize = 5; // just after the emoji: 'a'(1) + emoji(4)
    try std.testing.expectEqual(@as(u32, 5), offsetToPosition(s, off, .utf8).character);
    // a(1) + emoji(2) = 3 units
    try std.testing.expectEqual(@as(u32, 3), offsetToPosition(s, off, .utf16).character);

    const pos = offsetToPosition(s, off, .utf16);
    try std.testing.expectEqual(off, positionToOffset(s, pos, .utf16));
}

test "offsetToPosition and positionToOffset on a later line" {
    const s = "abc\ndéf\nghi";
    // 'f' is on line 1: "d"(1) "é"(2 bytes/1 unit) "f" -> byte offset of 'f'
    const off = std.mem.indexOf(u8, s, "f").?;
    const p_utf8 = offsetToPosition(s, off, .utf8);
    try std.testing.expectEqual(@as(u32, 1), p_utf8.line);
    try std.testing.expectEqual(@as(u32, 3), p_utf8.character); // d(1) + é(2 bytes)

    const p_utf16 = offsetToPosition(s, off, .utf16);
    try std.testing.expectEqual(@as(u32, 1), p_utf16.line);
    try std.testing.expectEqual(@as(u32, 2), p_utf16.character); // d(1) + é(1 unit)

    try std.testing.expectEqual(off, positionToOffset(s, p_utf8, .utf8));
    try std.testing.expectEqual(off, positionToOffset(s, p_utf16, .utf16));
}

test "positionToOffset recovers from malformed utf8 without panicking" {
    const s = "a\xffb";
    const pos: protocol.Position = .{ .line = 0, .character = 3 };
    // 'a'(1) + invalid byte(1) + 'b'(1) -> offset 3
    try std.testing.expectEqual(@as(usize, 3), positionToOffset(s, pos, .utf8));
}

test "offsetToPosition recovers from malformed utf8 lead byte without panicking (utf16)" {
    const s = "a\xffb";
    // 'a'(1 unit) + invalid lead byte(1 unit) + 'b'(1 unit) -> character 3
    const p = offsetToPosition(s, 3, .utf16);
    try std.testing.expectEqual(@as(u32, 0), p.line);
    try std.testing.expectEqual(@as(u32, 3), p.character);
}

test "offsetToPosition recovers from truncated utf8 tail at buffer end without panicking (utf16)" {
    const s = "a\xC3"; // 'a' followed by a lead byte whose continuation byte is missing
    const p = offsetToPosition(s, 2, .utf16);
    try std.testing.expectEqual(@as(u32, 0), p.line);
    try std.testing.expectEqual(@as(u32, 2), p.character);
}

test "offsetToPosition recovers from malformed utf8 lead byte without panicking (utf8)" {
    const s = "a\xffb";
    const p = offsetToPosition(s, 3, .utf8);
    try std.testing.expectEqual(@as(u32, 0), p.line);
    try std.testing.expectEqual(@as(u32, 3), p.character);
}

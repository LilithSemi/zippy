//! Framed read/write of LSP messages over `std.Io.Reader`/`Writer`.
//!
//! LSP frames a JSON-RPC message as ASCII headers, a blank line, then the
//! body: `Content-Length: N\r\n\r\n<N bytes of JSON>`. This module knows only
//! that framing - it has no JSON knowledge and returns/accepts raw bytes.
const std = @import("std");

/// Errors specific to malformed framing (in addition to whatever `r`/`w`
/// report). These are fail-loud: a client that sends a header block with no
/// `Content-Length` is broken and callers must not silently proceed.
pub const FrameError = error{ MissingContentLength, ContentTooLarge };

/// Upper bound on a frame's `Content-Length`. Real LSP messages (JSON-RPC
/// requests/responses/notifications) are never anywhere near this large; a
/// value above it means the header is malformed or the peer is hostile. We
/// fail loud with a named error before allocating rather than let a
/// wire-controlled length drive an unbounded (or absurdly large) allocation.
pub const max_content_len = 64 * 1024 * 1024;

/// Reads one `Content-Length`-framed LSP message from `r` and returns its
/// JSON body, allocated with `gpa` (caller frees).
///
/// Returns `null` only on a clean EOF - the stream ended before any header
/// bytes (complete or partial) were read this call, which is the normal way
/// a client closes its side of the connection. An EOF that happens after
/// headers have started - a *partial* first header line with no trailing
/// `\n` (e.g. a peer that writes `"Content-Length: 5"` then closes), a
/// truncated header block after a full first line, or a truncated body - is
/// a real failure and is propagated as `error.EndOfStream`, not swallowed
/// into `null`. The partial-first-line case is distinguished from a clean
/// EOF via `r.bufferedLen()`: `takeDelimiterInclusive` only leaves bytes
/// buffered-but-unconsumed when it read something before hitting EOF
/// without finding the delimiter, so a nonzero length there means a real
/// (if short) fragment of a frame arrived.
pub fn readMessage(gpa: std.mem.Allocator, r: *std.Io.Reader) !?[]u8 {
    var content_len: ?usize = null;
    var read_any = false;
    while (true) {
        // Read a header line up to and including '\n'. EOF before any
        // header bytes -- complete or partial -- were seen this call is the
        // normal end-of-stream; EOF partway through a header block (whether
        // mid-line or between lines) means the peer hung up mid-message,
        // which is a fault, not a clean shutdown.
        const line = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                if (!read_any and r.bufferedLen() == 0) return null;
                return err;
            },
            else => return err,
        };
        read_any = true;
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) break; // blank line: headers done
        const prefix = "Content-Length:";
        if (std.mem.startsWith(u8, trimmed, prefix)) {
            const num = std.mem.trim(u8, trimmed[prefix.len..], " ");
            content_len = try std.fmt.parseInt(usize, num, 10);
        }
        // Other headers (e.g. Content-Type) are ignored.
    }
    const len = content_len orelse return FrameError.MissingContentLength;
    if (len > max_content_len) return FrameError.ContentTooLarge;
    const body = try gpa.alloc(u8, len);
    errdefer gpa.free(body);
    try r.readSliceAll(body);
    return body;
}

/// Writes `body` to `w` framed as a `Content-Length` LSP message.
pub fn writeMessage(w: *std.Io.Writer, body: []const u8) !void {
    try w.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try w.writeAll(body);
}

test "write then read a framed message round-trips" {
    const gpa = std.testing.allocator;
    // write into a growable buffer
    var alloc: std.Io.Writer.Allocating = .init(gpa);
    defer alloc.deinit();
    try writeMessage(&alloc.writer, "{\"jsonrpc\":\"2.0\"}");
    const framed = alloc.written();
    try std.testing.expect(std.mem.startsWith(u8, framed, "Content-Length: 17\r\n\r\n"));

    // read it back
    var r: std.Io.Reader = .fixed(framed);
    const body = (try readMessage(gpa, &r)).?;
    defer gpa.free(body);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\"}", body);

    // second read hits EOF -> null
    try std.testing.expect((try readMessage(gpa, &r)) == null);
}

test "readMessage returns null on a truly empty stream (clean EOF)" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("");
    try std.testing.expect((try readMessage(gpa, &r)) == null);
}

test "readMessage propagates EndOfStream on a header line truncated before Content-Length" {
    const gpa = std.testing.allocator;
    // A header line with no Content-Length and no blank line, then EOF.
    // Header bytes were consumed this call, so EOF here is a truncated
    // frame, not a clean shutdown, and must not be swallowed into null.
    var r: std.Io.Reader = .fixed("X-Foo: 1\r\n");
    try std.testing.expectError(error.EndOfStream, readMessage(gpa, &r));
}

test "readMessage propagates EndOfStream on a partial FIRST header line before EOF" {
    const gpa = std.testing.allocator;
    // No trailing '\n' at all: the peer wrote a fragment of a header line
    // then closed. Before this fix, `read_any` was still false here (no
    // full line was ever read), so this was indistinguishable from a
    // truly empty stream and incorrectly returned `null` -- contradicting
    // this function's own doc comment. `r.bufferedLen() != 0` now catches
    // it: those partial bytes are still sitting in the reader's buffer.
    var r: std.Io.Reader = .fixed("Content-Length: 5");
    try std.testing.expectError(error.EndOfStream, readMessage(gpa, &r));
}

test "readMessage returns error.ContentTooLarge for an absurd Content-Length" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("Content-Length: 999999999999\r\n\r\n");
    try std.testing.expectError(error.ContentTooLarge, readMessage(gpa, &r));
}

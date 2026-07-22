//! The JSON-RPC-over-stdio dispatch loop, lifecycle, and per-method
//! handlers that tie `transport`/`protocol`/`position`/`documents` together
//! into Zippy's `lsp` subcommand server.
//!
//! # Envelope handling
//! Every framed body is parsed into a small `Envelope{id, method, params}`
//! with `id`/`params` kept as `std.json.Value` rather than a fixed type:
//! `id` must be echoed back verbatim in replies (it can be a string,
//! integer, or absent), and `params` shape differs per `method`, so it is
//! re-parsed into the right struct per handler via
//! `std.json.parseFromValue(T, gpa, params, .{ .ignore_unknown_fields =
//! true })`. This mirrors how `protocol.zig` already parses top-level
//! bodies with `parseFromSlice`.
//!
//! # Robustness (long-lived loop, never crashes)
//! A malformed message must never end the loop: an envelope that fails to
//! parse, or has no `method`, is logged to stderr (`std.log.scoped(.zippy_lsp)`) and
//! skipped. A handler error for a REQUEST (non-null `id`) is logged and
//! turned into a JSON-RPC reply -- `-32602 InvalidParams` when the handler
//! reports a params-parse failure, `-32603 InternalError` otherwise; a
//! handler error for a NOTIFICATION (`id == null`) is logged and skipped.
//! Even a reply-write failure is caught, logged, and the loop continues --
//! it's treated like any other per-message fault rather than assumed to
//! mean the transport is unusable. A `transport`-level error (a genuinely
//! broken byte stream -- a malformed frame, a truncated header, a failed
//! stdin read -- surfaced as `readMessage` returning an error) is different
//! in kind: it desynchronizes the byte stream with no safe resync point, so
//! there is no message to drop and keep going -- the loop must end. But
//! ending must still be observable and graceful, not an unhandled error
//! propagating out as a crash: it is logged via `log.warn` like every other
//! recovered fault, and `serve` returns its normal `u8` exit code rather
//! than an error. A clean EOF or `exit` end the loop the same way, just
//! without the warning. The one exception is `error.OutOfMemory`, which
//! `readMessage`'s error set also includes: on a hosted target that is a
//! programmer error (a miscalculation or a leak), not a client-side
//! transport fault, so it is never treated as a recoverable framing
//! failure -- it propagates out of `serve` instead.
//!
//! # Flush discipline
//! Every reply/notification is written with `transport.writeMessage` and
//! then `w.flush()`ed immediately -- editors read replies as they arrive on
//! a pipe with no independent flush signal, so a buffered-but-unflushed
//! reply is indistinguishable from a hung server.
const std = @import("std");
const transport = @import("transport.zig");
const protocol = @import("protocol.zig");
const position = @import("position.zig");
const documents = @import("documents.zig");
const Documents = documents.Documents;

/// Scoped so a test root (`src/root.zig`) can suppress just these recovery
/// logs -- the robustness tests deliberately feed malformed input and would
/// otherwise spam `zig build test` output -- while the real `zippy lsp`
/// binary (`src/main.zig`'s root, which sets no such suppression) keeps
/// seeing them at the default level. See the module doc comment's
/// "Robustness" section for why these must never be swallowed outright.
const log = std.log.scoped(.zippy_lsp);

/// JSON-RPC / LSP error codes this server sends, named per the JSON-RPC 2.0
/// spec and the LSP base protocol rather than left as magic numbers at each
/// call site.
const method_not_found: i64 = -32601;
const invalid_params: i64 = -32602;
const internal_error: i64 = -32603;
const server_not_initialized: i64 = -32002;

/// The JSON-RPC envelope every incoming message is first parsed into. `id`
/// and `params` are kept as `std.json.Value` -- see the module doc comment.
/// `ignore_unknown_fields` is required at the call site since real clients
/// send a `jsonrpc` field (and sometimes more) this struct doesn't model.
const Envelope = struct {
    id: ?std.json.Value = null,
    method: ?[]const u8 = null,
    params: std.json.Value = .null,
};

/// Just enough of `initialize`'s `params` to negotiate the position
/// encoding: `capabilities.general.positionEncodings`. Every level defaults
/// to empty/absent so a client that omits `capabilities` (or `general`, or
/// `positionEncodings`) entirely still parses -- `negotiateEncoding` falls
/// back to UTF-16 (the LSP default) whenever "utf-8" isn't present.
const InitializeEncodingParams = struct {
    capabilities: struct {
        general: struct {
            positionEncodings: []const []const u8 = &.{},
        } = .{},
    } = .{},
};

/// Runs the dispatch loop until the client sends `exit`, reading framed
/// messages from `r` and writing framed replies/notifications to `w`.
///
/// Returns the process exit code per the LSP spec: `0` if `shutdown`
/// preceded `exit`, `1` otherwise (a client that exits without shutting
/// down first, a transport EOF before either arrived, or a framing fault
/// that ended the loop early -- see the module doc comment's "Robustness"
/// section for why a framing fault ends the loop gracefully instead of
/// propagating as an error).
pub fn serve(io: std.Io, gpa: std.mem.Allocator, r: *std.Io.Reader, w: *std.Io.Writer) !u8 {
    var server: Server = .{
        .gpa = gpa,
        .w = w,
        .initialized = false,
        .shutdown_requested = false,
        .docs = .init(gpa, io),
    };
    defer server.docs.deinit();

    while (true) {
        // `readMessage`'s inferred error set mixes two different kinds of
        // failure: real transport/framing faults (a desynchronized byte
        // stream, a truncated header, a broken stdin read) and
        // `error.OutOfMemory` from its internal `gpa.alloc`. Only the former
        // are client-side faults safe to recover from by ending the loop
        // gracefully. `OutOfMemory` on a hosted target is a programmer
        // error -- a miscalculation or a leak -- not something the client
        // did, so it must fail loud and propagate rather than be rebranded
        // as a "transport error" and swallowed into a graceful exit.
        const body = transport.readMessage(gpa, r) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                log.warn("terminating: transport error: {t}", .{err});
                break;
            },
        } orelse break; // clean EOF
        defer gpa.free(body);
        const should_exit = server.handleMessage(body) catch |err| blk: {
            log.warn("dropping message after error: {t}", .{err});
            break :blk false;
        };
        if (should_exit) break;
    }
    return if (server.shutdown_requested) @as(u8, 0) else @as(u8, 1);
}

/// Holds everything a message handler needs. See the module doc comment for
/// the dispatch/robustness design this struct's methods implement.
const Server = struct {
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    initialized: bool,
    shutdown_requested: bool,
    encoding: position.Encoding = .utf16,
    docs: Documents,

    /// Parses and dispatches one message body. Returns `true` only for
    /// `exit`, telling `serve` to stop the loop; every other path -- a
    /// no-op notification, a reply already sent, a swallowed error --
    /// returns `false` so the loop keeps reading. See the module doc
    /// comment for exactly which failures are recovered here vs. left to
    /// propagate to `serve`'s own catch.
    fn handleMessage(self: *Server, body: []const u8) !bool {
        const parsed_envelope = std.json.parseFromSlice(
            Envelope,
            self.gpa,
            body,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            log.warn("malformed message ignored: {t}", .{err});
            return false;
        };
        defer parsed_envelope.deinit();
        const env = parsed_envelope.value;
        const method = env.method orelse {
            log.warn("message with no method ignored", .{});
            return false;
        };

        if (std.mem.eql(u8, method, "exit")) return true;

        if (!self.initialized and !std.mem.eql(u8, method, "initialize")) {
            if (env.id) |request_id| {
                try self.sendError(request_id, server_not_initialized, "server not initialized");
            }
            return false;
        }

        self.dispatch(method, env.id, env.params) catch |err| {
            log.warn("'{s}' failed: {t}", .{ method, err });
            if (env.id) |request_id| {
                // A handler that maps a `parseFromValue` failure to
                // `error.InvalidParams` gets the JSON-RPC-correct
                // -32602 reply; anything else falls back to -32603
                // since dispatch can't otherwise tell a bad-params
                // error apart from an internal one.
                const is_invalid_params = err == error.InvalidParams;
                const code: i64 = if (is_invalid_params) invalid_params else internal_error;
                const message = if (is_invalid_params) "invalid params" else "internal error";
                try self.sendError(request_id, code, message);
            }
        };
        return false;
    }

    /// Routes an already-envelope-parsed message to its handler. `id` is
    /// `null` for notifications; the three request methods that need to
    /// reply (`initialize`/`hover`/`shutdown`) log-and-drop rather than
    /// unwrap a missing id -- a request with no id is a malformed message,
    /// not something worth panicking the loop over.
    fn dispatch(
        self: *Server,
        method: []const u8,
        id: ?std.json.Value,
        params: std.json.Value,
    ) !void {
        if (std.mem.eql(u8, method, "initialize")) {
            const request_id = id orelse return logMissingId(method);
            return self.handleInitialize(request_id, params);
        }
        if (std.mem.eql(u8, method, "initialized")) return;
        if (std.mem.eql(u8, method, "textDocument/didOpen")) return self.handleDidOpen(params);
        if (std.mem.eql(u8, method, "textDocument/didChange")) return self.handleDidChange(params);
        if (std.mem.eql(u8, method, "textDocument/didSave")) return self.handleDidSave(params);
        if (std.mem.eql(u8, method, "textDocument/didClose")) return self.handleDidClose(params);
        if (std.mem.eql(u8, method, "textDocument/hover")) {
            const request_id = id orelse return logMissingId(method);
            return self.handleHover(request_id, params);
        }
        if (std.mem.eql(u8, method, "shutdown")) {
            const request_id = id orelse return logMissingId(method);
            return self.handleShutdown(request_id);
        }
        // Unknown method: a request gets MethodNotFound; an unknown
        // notification (no id, so no reply channel) is simply ignored.
        if (id) |request_id| try self.sendError(request_id, method_not_found, "method not found");
    }

    fn handleInitialize(self: *Server, id: std.json.Value, params: std.json.Value) !void {
        self.encoding = negotiateEncoding(self.gpa, params);
        self.initialized = true;
        const Result = struct {
            capabilities: struct {
                positionEncoding: []const u8,
                textDocumentSync: struct { openClose: bool, change: u8, save: bool },
                hoverProvider: bool,
            },
            serverInfo: struct { name: []const u8 },
        };
        const result: Result = .{
            .capabilities = .{
                .positionEncoding = if (self.encoding == .utf8) "utf-8" else "utf-16",
                .textDocumentSync = .{ .openClose = true, .change = 1, .save = true },
                .hoverProvider = true,
            },
            .serverInfo = .{ .name = "zippy" },
        };
        try self.sendResult(id, result);
    }

    fn handleDidOpen(self: *Server, params: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(
            protocol.DidOpenParams,
            self.gpa,
            params,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        const p = parsed.value;
        try self.docs.open(p.textDocument.uri, p.textDocument.text);
        // `open` just inserted this uri unconditionally on success, so it
        // must be found here -- a `null` would mean `Documents.open`
        // regressed its own invariant, not a client-triggerable state.
        const doc = self.docs.get(p.textDocument.uri).?;
        try self.docs.lint(doc);
        try self.publishDiagnostics(doc);
    }

    fn handleDidChange(self: *Server, params: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(
            protocol.DidChangeParams,
            self.gpa,
            params,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        const p = parsed.value;
        if (p.contentChanges.len == 0) return;
        // Full-document sync only: the LAST entry is the whole new text.
        const text = p.contentChanges[p.contentChanges.len - 1].text;
        try self.docs.change(p.textDocument.uri, text);
        const doc = self.docs.get(p.textDocument.uri) orelse return;
        try self.docs.lint(doc);
        try self.publishDiagnostics(doc);
    }

    fn handleDidSave(self: *Server, params: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(
            protocol.DidSaveParams,
            self.gpa,
            params,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        const doc = self.docs.get(parsed.value.textDocument.uri) orelse return;
        try self.docs.lint(doc);
        try self.publishDiagnostics(doc);
    }

    fn handleDidClose(self: *Server, params: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(
            protocol.DidCloseParams,
            self.gpa,
            params,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        const uri = parsed.value.textDocument.uri;
        self.docs.close(uri);
        // The doc is gone, so this is sent directly (not via
        // `publishDiagnostics`, which reads a live `*Doc`): an empty
        // diagnostics list clears the editor's squiggles for `uri`.
        const empty: protocol.PublishDiagnosticsParams = .{ .uri = uri, .diagnostics = &.{} };
        try self.sendNotification("textDocument/publishDiagnostics", empty);
    }

    fn handleHover(self: *Server, id: std.json.Value, params: std.json.Value) !void {
        const parsed = std.json.parseFromValue(
            protocol.HoverParams,
            self.gpa,
            params,
            .{ .ignore_unknown_fields = true },
        ) catch return error.InvalidParams;
        defer parsed.deinit();
        const p = parsed.value;
        const doc = self.docs.get(p.textDocument.uri) orelse
            return self.sendResult(id, std.json.Value.null);
        const offset = position.positionToOffset(doc.text, p.position, self.encoding);
        const info = documents.hoverAt(doc, offset) orelse
            return self.sendResult(id, std.json.Value.null);
        const value = try std.fmt.allocPrint(
            self.gpa,
            "**{s}**: {s}\n\n{s}",
            .{ info.lint, info.message, info.description },
        );
        defer self.gpa.free(value);
        const hover: protocol.Hover = .{ .contents = .{ .kind = "markdown", .value = value } };
        try self.sendResult(id, hover);
    }

    fn handleShutdown(self: *Server, id: std.json.Value) !void {
        self.shutdown_requested = true;
        try self.sendResult(id, std.json.Value.null);
    }

    /// Lints `doc` having already been re-linted by the caller, then sends
    /// a `textDocument/publishDiagnostics` notification for it. Shared by
    /// `didOpen`/`didChange`/`didSave`.
    fn publishDiagnostics(self: *Server, doc: *documents.Doc) !void {
        const lsp_diags = try documents.toLspDiagnostics(self.gpa, doc, self.encoding);
        defer self.gpa.free(lsp_diags);
        const p: protocol.PublishDiagnosticsParams = .{ .uri = doc.uri, .diagnostics = lsp_diags };
        try self.sendNotification("textDocument/publishDiagnostics", p);
    }

    /// Sends a successful JSON-RPC response `{jsonrpc, id, result}`. `result`
    /// is `anytype` so callers can pass either a real result struct or
    /// `std.json.Value.null` for "no result" (e.g. `shutdown`, a hover miss)
    /// -- using `Value.null` rather than a Zig `null` literal ensures
    /// `"result":null` is actually emitted instead of the field being
    /// dropped by `emit_null_optional_fields = false`.
    fn sendResult(self: *Server, id: std.json.Value, result: anytype) !void {
        const Response = struct {
            jsonrpc: []const u8 = "2.0",
            id: std.json.Value,
            result: @TypeOf(result),
        };
        try self.send(Response{ .id = id, .result = result });
    }

    /// Sends a JSON-RPC error response `{jsonrpc, id, error: {code, message}}`.
    fn sendError(self: *Server, id: std.json.Value, code: i64, message: []const u8) !void {
        const Response = struct {
            jsonrpc: []const u8 = "2.0",
            id: std.json.Value,
            @"error": struct { code: i64, message: []const u8 },
        };
        try self.send(Response{ .id = id, .@"error" = .{ .code = code, .message = message } });
    }

    /// Sends a JSON-RPC notification `{jsonrpc, method, params}` (no `id`).
    fn sendNotification(self: *Server, method: []const u8, params: anytype) !void {
        const Notification = struct {
            jsonrpc: []const u8 = "2.0",
            method: []const u8,
            params: @TypeOf(params),
        };
        try self.send(Notification{ .method = method, .params = params });
    }

    /// Stringifies `msg` and writes it framed to `self.w`, flushing
    /// immediately -- see the module doc comment's flush-discipline note.
    fn send(self: *Server, msg: anytype) !void {
        const out = try std.json.Stringify.valueAlloc(
            self.gpa,
            msg,
            .{ .emit_null_optional_fields = false },
        );
        defer self.gpa.free(out);
        try transport.writeMessage(self.w, out);
        try self.w.flush();
    }
};

/// Picks the negotiated position encoding from `initialize`'s `params`:
/// UTF-8 if the client's `capabilities.general.positionEncodings` lists
/// `"utf-8"`, UTF-16 (the LSP default) otherwise -- including when `params`
/// doesn't parse as an object at all (a client that sent `initialize` with
/// no/malformed `params` still gets a usable default rather than failing
/// the handshake).
fn negotiateEncoding(gpa: std.mem.Allocator, params: std.json.Value) position.Encoding {
    const parsed = std.json.parseFromValue(
        InitializeEncodingParams,
        gpa,
        params,
        .{ .ignore_unknown_fields = true },
    ) catch return .utf16;
    defer parsed.deinit();
    for (parsed.value.capabilities.general.positionEncodings) |enc| {
        if (std.mem.eql(u8, enc, "utf-8")) return .utf8;
    }
    return .utf16;
}

fn logMissingId(method: []const u8) void {
    log.warn("request '{s}' has no id, dropping", .{method});
}

test "golden conversation: initialize, didOpen, publishDiagnostics, hover, shutdown, exit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Build a client-input stream of framed messages.
    var input: std.Io.Writer.Allocating = .init(gpa);
    defer input.deinit();
    try transport.writeMessage(&input.writer,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize",
        \\"params":{"capabilities":{"general":{"positionEncodings":["utf-8"]}}}}
    );
    try transport.writeMessage(&input.writer,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    );
    try transport.writeMessage(&input.writer,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":
        \\{"textDocument":{"uri":"file:///t.zig","text":"fn Bad_Name() void {}\n"}}}
    );
    try transport.writeMessage(&input.writer,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":
        \\{"textDocument":{"uri":"file:///t.zig"},"position":{"line":0,"character":4}}}
    );
    try transport.writeMessage(
        &input.writer,
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"shutdown\"}",
    );
    try transport.writeMessage(&input.writer, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    var r: std.Io.Reader = .fixed(input.written());
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try serve(io, gpa, &r, &out.writer);
    try std.testing.expectEqual(@as(u8, 0), code);
    const o = out.written();
    // initialize result advertises utf-8 + hoverProvider
    try std.testing.expect(std.mem.indexOf(u8, o, "\"positionEncoding\":\"utf-8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, o, "\"hoverProvider\":true") != null);
    // a publishDiagnostics for the bad name
    try std.testing.expect(std.mem.indexOf(u8, o, "textDocument/publishDiagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, o, "naming_convention") != null);
    // hover response mentions camelCase (the description)
    try std.testing.expect(std.mem.indexOf(u8, o, "camelCase") != null);
}

test "a malformed JSON message doesn't end the loop -- shutdown+exit still reach it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var input: std.Io.Writer.Allocating = .init(gpa);
    defer input.deinit();
    try transport.writeMessage(
        &input.writer,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
    );
    try transport.writeMessage(&input.writer, "{ this is not json");
    try transport.writeMessage(
        &input.writer,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}",
    );
    try transport.writeMessage(&input.writer, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    var r: std.Io.Reader = .fixed(input.written());
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try serve(io, gpa, &r, &out.writer);
    try std.testing.expectEqual(@as(u8, 0), code);
}

test "a request before initialize gets ServerNotInitialized" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var input: std.Io.Writer.Allocating = .init(gpa);
    defer input.deinit();
    try transport.writeMessage(
        &input.writer,
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":
        \\{"textDocument":{"uri":"file:///t.zig"},"position":{"line":0,"character":0}}}
        ,
    );
    // `shutdown` is itself a request, and `initialize` was never sent, so
    // it too is rejected with ServerNotInitialized -- `shutdown_requested`
    // never gets set, so `exit` returns 1, not 0. This confirms the gate
    // applies uniformly to every request but `initialize`, per spec.
    try transport.writeMessage(
        &input.writer,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}",
    );
    try transport.writeMessage(&input.writer, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    var r: std.Io.Reader = .fixed(input.written());
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try serve(io, gpa, &r, &out.writer);
    try std.testing.expectEqual(@as(u8, 1), code);
    const o = out.written();
    try std.testing.expect(std.mem.indexOf(u8, o, "-32002") != null);
    // both the hover AND the shutdown request were rejected.
    var occurrences: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOf(u8, o[idx..], "-32002")) |found| {
        occurrences += 1;
        idx += found + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), occurrences);
}

test "exit without a prior shutdown returns 1" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var input: std.Io.Writer.Allocating = .init(gpa);
    defer input.deinit();
    try transport.writeMessage(&input.writer, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    var r: std.Io.Reader = .fixed(input.written());
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try serve(io, gpa, &r, &out.writer);
    try std.testing.expectEqual(@as(u8, 1), code);
}

test "a framing fault with no prior shutdown ends the loop gracefully with exit 1" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // A header block with no Content-Length, framing-invalid per
    // `transport.FrameError.MissingContentLength` -- no initialize or
    // shutdown precedes it. Before this fix, the `try` in `serve`'s loop
    // would propagate this out as an error-return-trace crash instead of
    // the normal `u8` exit code the rest of the loop uses.
    var r: std.Io.Reader = .fixed("X-Foo: 1\r\n\r\n");
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try serve(io, gpa, &r, &out.writer);
    try std.testing.expectEqual(@as(u8, 1), code);
}

test "OutOfMemory from readMessage propagates out of serve instead of being swallowed" {
    const io = std.testing.io;
    // A well-formed frame -- readMessage's very first allocation is the
    // `gpa.alloc(u8, len)` for the body, so failing the allocator's first
    // call reproduces the OOM path without any framing fault involved.
    // `serve`'s `Server` construction and `Documents.init` do not allocate,
    // so this is guaranteed to be the allocation `readMessage` makes.
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    const gpa = failing.allocator();
    var r: std.Io.Reader = .fixed("Content-Length: 2\r\n\r\n{}");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.OutOfMemory, serve(io, gpa, &r, &out.writer));
}

test "didChange live-relints: a clean open then a bad change publishes a fresh diagnostic" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var input: std.Io.Writer.Allocating = .init(gpa);
    defer input.deinit();
    try transport.writeMessage(
        &input.writer,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
    );
    try transport.writeMessage(&input.writer,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":
        \\{"textDocument":{"uri":"file:///t.zig","text":"pub const x = 1;\n"}}}
    );
    try transport.writeMessage(&input.writer,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":
        \\{"textDocument":{"uri":"file:///t.zig"},
        \\"contentChanges":[{"text":"fn Bad_Name() void {}\n"}]}}
    );
    try transport.writeMessage(
        &input.writer,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}",
    );
    try transport.writeMessage(&input.writer, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    var r: std.Io.Reader = .fixed(input.written());
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try serve(io, gpa, &r, &out.writer);
    try std.testing.expectEqual(@as(u8, 0), code);

    const o = out.written();
    const first_pub = std.mem.indexOf(u8, o, "textDocument/publishDiagnostics").?;
    const second_pub = std.mem.indexOfPos(
        u8,
        o,
        first_pub + 1,
        "textDocument/publishDiagnostics",
    ).?;
    // The initial open of a clean buffer publishes an empty diagnostics
    // list -- no naming_convention finding yet.
    const first_msg = o[first_pub..second_pub];
    try std.testing.expect(std.mem.indexOf(u8, first_msg, "\"diagnostics\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_msg, "naming_convention") == null);
    // didChange to the bad buffer re-lints live and publishes the finding.
    try std.testing.expect(std.mem.indexOf(u8, o[second_pub..], "naming_convention") != null);
}

test "didClose clears diagnostics: closing a doc with a finding publishes an empty list" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var input: std.Io.Writer.Allocating = .init(gpa);
    defer input.deinit();
    try transport.writeMessage(
        &input.writer,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
    );
    try transport.writeMessage(&input.writer,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":
        \\{"textDocument":{"uri":"file:///c.zig","text":"fn Bad_Name() void {}\n"}}}
    );
    try transport.writeMessage(&input.writer,
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":
        \\{"textDocument":{"uri":"file:///c.zig"}}}
    );
    try transport.writeMessage(
        &input.writer,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}",
    );
    try transport.writeMessage(&input.writer, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    var r: std.Io.Reader = .fixed(input.written());
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try serve(io, gpa, &r, &out.writer);
    try std.testing.expectEqual(@as(u8, 0), code);

    const o = out.written();
    const first_pub = std.mem.indexOf(u8, o, "textDocument/publishDiagnostics").?;
    const second_pub = std.mem.indexOfPos(
        u8,
        o,
        first_pub + 1,
        "textDocument/publishDiagnostics",
    ).?;
    // didOpen on the bad buffer publishes the naming_convention finding.
    try std.testing.expect(
        std.mem.indexOf(u8, o[first_pub..second_pub], "naming_convention") != null,
    );
    // didClose publishes an empty diagnostics list for that same uri,
    // clearing the editor's squiggles.
    const second_msg = o[second_pub..];
    try std.testing.expect(std.mem.indexOf(u8, second_msg, "\"diagnostics\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_msg, "file:///c.zig") != null);
}

test "didSave re-lints and republishes diagnostics for the saved doc" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var input: std.Io.Writer.Allocating = .init(gpa);
    defer input.deinit();
    try transport.writeMessage(
        &input.writer,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
    );
    try transport.writeMessage(&input.writer,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":
        \\{"textDocument":{"uri":"file:///s.zig","text":"fn Bad_Name() void {}\n"}}}
    );
    try transport.writeMessage(&input.writer,
        \\{"jsonrpc":"2.0","method":"textDocument/didSave","params":
        \\{"textDocument":{"uri":"file:///s.zig"}}}
    );
    try transport.writeMessage(
        &input.writer,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}",
    );
    try transport.writeMessage(&input.writer, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    var r: std.Io.Reader = .fixed(input.written());
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try serve(io, gpa, &r, &out.writer);
    try std.testing.expectEqual(@as(u8, 0), code);

    // Both the didOpen and the didSave re-lint publish the finding --
    // two separate publishDiagnostics notifications go out.
    const o = out.written();
    var occurrences: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOf(u8, o[idx..], "textDocument/publishDiagnostics")) |found| {
        occurrences += 1;
        idx += found + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), occurrences);
    try std.testing.expect(std.mem.indexOf(u8, o, "naming_convention") != null);
}

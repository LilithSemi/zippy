//! Library root. Aggregates every module so `zig build test` runs all tests.
const std = @import("std");

// Diagnostic, Source, Config, Linter, and cli modules land in later tasks.
// Each is uncommented here as its task lands so `zig build test` picks up
// its tests automatically via refAllDecls below.
pub const Diagnostic = @import("Diagnostic.zig");
pub const Source = @import("Source.zig");
pub const Config = @import("Config.zig");
pub const Linter = @import("Linter.zig");
pub const Semantic = @import("Semantic.zig");
pub const alloc_track = @import("alloc_track.zig");
pub const ast_eql = @import("ast_eql.zig");
pub const fix = @import("fix.zig");
pub const paths = @import("paths.zig");
pub const suppress = @import("suppress.zig");
pub const cli = @import("cli.zig");
pub const build_manifest = @import("build/manifest.zig");
pub const build_reachable = @import("build/reachable.zig");
pub const build_dead_file = @import("build/dead_file.zig");
pub const build_bsp = @import("build/bsp.zig");
pub const build_bsp_test = @import("build/bsp_test.zig");
pub const build_mode = @import("build/mode.zig");
pub const build_e2e_test = @import("build/e2e_test.zig");
pub const lsp_protocol = @import("lsp/protocol.zig");
pub const lsp_transport = @import("lsp/transport.zig");
pub const lsp_position = @import("lsp/position.zig");
pub const lsp_documents = @import("lsp/documents.zig");
pub const lsp_server = @import("lsp/server.zig");

// `zig build test` runs the default test runner (`lib/zig/compiler/test_runner.zig`),
// which is the real `@import("root")` for this compilation -- not this file --
// so a `pub const std_options` declared here would silently do nothing
// (`std.log.logEnabled` only ever consults the actual root's `std_options`).
// The one lever this file *can* pull is `std.testing.log_level`, the
// runner's own knob for its default `logFn`: it's a plain global, read
// fresh on every `std.log.*` call and never reset between tests when `zig
// build test` drives the runner over its `--listen=-` protocol (only the
// interactive `mainTerminal` path resets it, and that's not what `zig
// build test` uses). Lowering it to `.err` here, before
// `std.testing.refAllDecls` pulls in every other module's tests, silences
// the `.warn`-level recovery logs that `lsp/server.zig`'s robustness tests
// deliberately trigger by feeding malformed input (see that module's doc
// comment) -- without touching `src/main.zig`'s root, so the real `zippy
// lsp` binary keeps logging those at the default level.
test {
    std.testing.log_level = .err;
    std.testing.refAllDecls(@This());
}

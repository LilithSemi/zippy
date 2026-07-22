//! The linter driver: given a parsed `Source` and a `Config`, emits parse
//! errors as diagnostics, then runs each registered lint whose resolved
//! severity isn't `.off`.
//!
//! Severity is resolved here, once per lint, *before* the lint runs -- not
//! inside the lint itself. That keeps every lint a pure "did I see the
//! pattern" function: it never reads `Config` to decide whether it's
//! enabled, so there's no way for a lint's own logic to disagree with the
//! user's config about whether it should fire.
const std = @import("std");
const Source = @import("Source.zig");
const Config = @import("Config.zig");
const Diagnostic = @import("Diagnostic.zig");
const Context = @import("Context.zig");
const line_width = @import("lints/line_width.zig");
const naming_convention = @import("lints/naming_convention.zig");
const too_many_params = @import("lints/too_many_params.zig");
const redundant_else = @import("lints/redundant_else.zig");
const discarded_error = @import("lints/discarded_error.zig");
const inline_container_type = @import("lints/inline_container_type.zig");
const unused_decl = @import("lints/unused_decl.zig");
const return_stack_local = @import("lints/return_stack_local.zig");
const hidden_allocator = @import("lints/hidden_allocator.zig");
const param_ordering = @import("lints/param_ordering.zig");
const suppressed_errors = @import("lints/suppressed_errors.zig");
const suppress = @import("suppress.zig");

pub const LintEntry = struct {
    name: []const u8,
    group: Config.Group,
    run: *const fn (*Context) Context.LintError!void,
};

// Filled in as lint tasks land.
pub const registry = [_]LintEntry{
    .{ .name = line_width.name, .group = line_width.group, .run = line_width.run },
    .{
        .name = naming_convention.name,
        .group = naming_convention.group,
        .run = naming_convention.run,
    },
    .{ .name = too_many_params.name, .group = too_many_params.group, .run = too_many_params.run },
    .{ .name = redundant_else.name, .group = redundant_else.group, .run = redundant_else.run },
    .{ .name = discarded_error.name, .group = discarded_error.group, .run = discarded_error.run },
    .{
        .name = inline_container_type.name,
        .group = inline_container_type.group,
        .run = inline_container_type.run,
    },
    .{ .name = unused_decl.name, .group = unused_decl.group, .run = unused_decl.run },
    .{
        .name = return_stack_local.name,
        .group = return_stack_local.group,
        .run = return_stack_local.run,
    },
    .{
        .name = hidden_allocator.name,
        .group = hidden_allocator.group,
        .run = hidden_allocator.run,
    },
    .{
        .name = param_ordering.name,
        .group = param_ordering.group,
        .run = param_ordering.run,
    },
    .{
        .name = suppressed_errors.name,
        .group = suppressed_errors.group,
        .run = suppressed_errors.run,
    },
};

pub fn run(
    gpa: std.mem.Allocator,
    source: *const Source,
    config: *const Config,
    diags: *std.ArrayList(Diagnostic),
) !void {
    // 1. Parse errors, rendered via the AST's own messages. These always
    // report regardless of config -- a file that doesn't parse can't be
    // meaningfully linted, so this isn't a lint a user can turn off.
    for (source.ast.errors) |err| {
        var buf: std.Io.Writer.Allocating = .init(gpa);
        defer buf.deinit();
        try source.ast.renderError(err, &buf.writer);
        const off = source.ast.tokenStart(err.token);
        const off_end = off + source.ast.tokenSlice(err.token).len;
        const msg = try gpa.dupe(u8, buf.written());
        errdefer gpa.free(msg);
        try diags.append(gpa, .{
            .path = source.path,
            .byte_offset = off,
            .end_offset = off_end,
            .severity = .@"error",
            .lint = "parse",
            .message = msg,
        });
    }

    // 2. Lints. No arena here: `Context.report` dupes messages with `gpa`
    // directly, so every diagnostic (parse error or lint) has one uniform
    // owner and lifetime -- the caller of `run` frees each `diags` item
    // with `Diagnostic.deinit(gpa)` exactly once (message plus any owned
    // `fix.replacement`), with no separate arena teardown to order relative
    // to that.
    var ctx: Context = .{
        .gpa = gpa,
        .source = source,
        .config = config,
        .diags = diags,
    };
    for (registry) |entry| {
        const sev = config.severityFor(entry.name, entry.group);
        if (sev == .off) continue;
        ctx.current_lint = entry.name;
        ctx.current_severity = sev;
        try entry.run(&ctx);
    }

    // 3. Inline suppression: drop each diagnostic a `// zippy:ignore` directive
    // mutes. Parse errors (lint "parse") are NEVER suppressible -- a file that
    // doesn't parse can't be meaningfully linted, so a user can't turn that off.
    // Compiler `[zig]` errors and `dead_file` are added in `build/mode.zig`, not
    // here, so they never reach this filter (also non-suppressible, by design).
    var sup = try suppress.Suppressions.scan(gpa, source.bytes, &source.ast);
    defer sup.deinit(gpa);
    var w: usize = 0;
    for (diags.items) |d| {
        const is_parse = std.mem.eql(u8, d.lint, "parse");
        const muted = !is_parse and
            sup.suppressed(d.lint, Diagnostic.lineColAt(source.bytes, d.byte_offset).line);
        if (muted) {
            d.deinit(gpa); // free the dropped diag's message + any owned replacement
        } else {
            diags.items[w] = d;
            w += 1;
        }
    }
    diags.shrinkRetainingCapacity(w);
}

test "run emits a parse error for malformed source" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.zig", .data = "const x = ;\n" });
    const p = try tmp.dir.realPathFileAlloc(io, "bad.zig", gpa);
    defer gpa.free(p);

    var src = try Source.load(io, gpa, p);
    defer src.deinit(gpa);
    const cfg = Config.default();

    var diags: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diags.items) |d| gpa.free(d.message);
        diags.deinit(gpa);
    }
    try run(gpa, &src, &cfg, &diags);
    try std.testing.expect(diags.items.len >= 1);
    try std.testing.expectEqualStrings("parse", diags.items[0].lint);
}

test "every registered lint has a non-empty description" {
    try std.testing.expect(line_width.description.len > 0);
    try std.testing.expect(naming_convention.description.len > 0);
    try std.testing.expect(too_many_params.description.len > 0);
    try std.testing.expect(redundant_else.description.len > 0);
    try std.testing.expect(discarded_error.description.len > 0);
    try std.testing.expect(inline_container_type.description.len > 0);
    try std.testing.expect(unused_decl.description.len > 0);
    try std.testing.expect(return_stack_local.description.len > 0);
    try std.testing.expect(hidden_allocator.description.len > 0);
    try std.testing.expect(param_ordering.description.len > 0);
    try std.testing.expect(suppressed_errors.description.len > 0);
}

fn runSrc(gpa: std.mem.Allocator, src_text: []const u8) !std.ArrayList(Diagnostic) {
    var source = try Source.loadFromSlice(gpa, "t.zig", src_text);
    defer source.deinit(gpa);
    const cfg = Config.default();
    var diags: std.ArrayList(Diagnostic) = .empty;
    errdefer {
        for (diags.items) |d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try run(gpa, &source, &cfg, &diags);
    return diags;
}

fn countLint(diags: []const Diagnostic, lint: []const u8) usize {
    var c: usize = 0;
    for (diags) |d| {
        if (std.mem.eql(u8, d.lint, lint)) c += 1;
    }
    return c;
}

test "inline suppression drops a matching diagnostic" {
    const gpa = std.testing.allocator;
    // discarded_error fires on `_ = g()`; the standalone directive above mutes it.
    const src = "pub fn f() void {\n    // zippy:ignore discarded_error\n    _ = g();\n}\n" ++
        "pub fn g() u8 {\n    return 0;\n}\n";
    var diags = try runSrc(gpa, src);
    defer {
        for (diags.items) |d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 0), countLint(diags.items, "discarded_error"));
}

test "a non-matching directive leaves the diagnostic firing" {
    const gpa = std.testing.allocator;
    // directive names a DIFFERENT lint, so discarded_error still fires.
    const src = "pub fn f() void {\n    // zippy:ignore naming_convention\n    _ = g();\n}\n" ++
        "pub fn g() u8 {\n    return 0;\n}\n";
    var diags = try runSrc(gpa, src);
    defer {
        for (diags.items) |d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 1), countLint(diags.items, "discarded_error"));
}

test "parse errors are never suppressed" {
    const gpa = std.testing.allocator;
    // A syntactically broken file plus a directive naming `parse` -- the parse
    // error must survive (a file that doesn't parse can't be muted).
    const src = "// zippy:ignore parse\nconst x = ;\n";
    var diags = try runSrc(gpa, src);
    defer {
        for (diags.items) |d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try std.testing.expect(countLint(diags.items, "parse") >= 1);
}

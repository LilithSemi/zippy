//! Loads a `.zig` file from disk and owns its parsed form: the raw,
//! null-terminated bytes plus the `std.zig.Ast` built from them. Lints walk
//! `ast` and slice `bytes` directly, so both must outlive every lint that
//! runs against this `Source` -- that's why `Source` owns them and frees
//! them together in `deinit`.
const std = @import("std");
const Source = @This();

path: []const u8,
bytes: [:0]const u8,
ast: std.zig.Ast,

/// Guards against accidentally trying to lint something that isn't a normal
/// source file (e.g. a misidentified binary or a huge generated blob).
const max_bytes = 16 * 1024 * 1024;

/// `path` is used only to open the file; its lifetime is the caller's
/// responsibility and is not copied. `std.zig.Ast.parse` requires a
/// sentinel-terminated buffer, so the read must produce `[:0]const u8`.
///
/// `io` is threaded in by the caller rather than grabbed from a global, so
/// the loader stays agnostic about the runtime's `Io` implementation and can
/// later participate in concurrent linting without a hidden dependency.
pub fn load(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Source {
    const bytes = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(max_bytes),
        .of(u8),
        0, // sentinel
    );
    errdefer gpa.free(bytes);
    const ast = try std.zig.Ast.parse(gpa, bytes, .zig);
    return .{ .path = path, .bytes = bytes, .ast = ast };
}

/// Test-only helper: builds a `Source` from an in-memory slice instead of a
/// file on disk, so lint unit tests can exercise `run` against fixture
/// strings without a temp directory or an `Io` implementation. `bytes` is
/// duped (with a sentinel) rather than borrowed, so the returned `Source`
/// owns its memory exactly like `load` does and `deinit` works identically.
pub fn loadFromSlice(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) !Source {
    const owned = try gpa.dupeZ(u8, bytes);
    errdefer gpa.free(owned);
    const ast = try std.zig.Ast.parse(gpa, owned, .zig);
    return .{ .path = path, .bytes = owned, .ast = ast };
}

pub fn deinit(self: *Source, gpa: std.mem.Allocator) void {
    self.ast.deinit(gpa);
    gpa.free(self.bytes);
}

test "load parses a valid file with no parse errors" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Write a temp file.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ok.zig", .data = "const x = 1;\n" });

    // `Source.load` opens by path via the process cwd, so the temp file's
    // relative path isn't enough -- resolve it to an absolute path first.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var file = try tmp.dir.openFile(io, "ok.zig", .{});
    const path_len = try file.realPath(io, &path_buf);
    file.close(io);
    const p = try gpa.dupe(u8, path_buf[0..path_len]);
    defer gpa.free(p);

    var src = try Source.load(io, gpa, p);
    defer src.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), src.ast.errors.len);
}

//! What builder mode learns from the build graph: the module roots each
//! compile step uses and the compiler errors it reports.

pub const Root = struct {
    path: []const u8,
    module: []const u8,
    step: []const u8,
    target: []const u8,
    /// True when a dependency package owns this module. The build graph sets
    /// this, not the file location: a dependency can live under the project
    /// tree (for example `zig-pkg/uefi-<hash>/`), so a path prefix check
    /// cannot tell it apart from project code.
    is_dependency: bool = false,
};

pub const CompileError = struct {
    path: []const u8,
    line: u32,
    col: u32,
    span_start: u32,
    span_end: u32,
    message: []const u8,
};

pub const Manifest = struct {
    project_root: []const u8,
    roots: []const Root,
    errors: []const CompileError = &.{},
    /// Root directories of the dependency packages in `roots`.
    /// `dead_file.find` skips them.
    dep_dirs: []const []const u8 = &.{},
};

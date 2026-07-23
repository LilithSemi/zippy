# zippy

Clippy for Zig. A linter that, like `cargo clippy`, drives your build system and
lints exactly what actually compiles.

Requires Zig 0.16.0.

## What it does

Run `zippy` with no arguments inside a project that has a `build.zig`. Zippy runs
your build with an embedded custom build runner, walks the real compile graph, and
lints exactly the source files that are actually compiled (following
`@import`/`@embedFile` reachability from the real roots). It also:

- surfaces the Zig compiler's own errors (type errors, undeclared identifiers,
  unused locals) merged inline with the lints, tagged `[zig]`, so one run gives
  you both,
- flags `.zig` files present in the tree but part of no compilation (`dead_file`),
- ships as a single static binary (the build runner is embedded, written to a
  temp file at run time, so there is no sidecar to install).

Output reads like `zig build` errors, so editors and CI that already parse Zig
diagnostics keep working.

## Usage

```
zippy                       # builder mode: build the project and lint what compiles
zippy --fix                 # also apply any automatic fixes to the working tree
zippy lsp                   # run as a Language Server over stdio
zippy --help                # full flag list
```

Flags:

- `--color=auto|always|never` controls ANSI color (`auto` colors only on a TTY
  with `NO_COLOR` unset).
- `--fix` applies each diagnostic's automatic fix, if it has one. It refuses to
  touch a file with uncommitted git changes unless `--allow-dirty` is also given,
  and writes each file atomically.
- `--allow-dirty` lets `--fix` edit files with uncommitted git changes.

Building from source:

```
zig build          # produces zig-out/bin/zippy
zig build test     # runs the test suite
```

## Lints

Every lint belongs to a group. A per-lint override beats a per-group override
beats the group default, resolved in that order (most specific wins).
`correctness` and `memory` default to `error`; `style`, `complexity`, and
`unused` default to `warn`.

Many lints go beyond matching the syntax tree: Zippy builds a per-file semantic
model (scopes, symbols, and reference lists) so a lint can ask "what does this
name actually resolve to" and "is this declaration ever used". That is what lets
`no_print` ignore your own `fn print`, `unused_decl` see through shadowing, and
the memory lints follow an allocation through the function that owns it.

**style** (default `warn`)

- `line_width`: a source line longer than the configured maximum.
- `naming_convention`: functions should be camelCase, type declarations
  TitleCase.
- `inline_container_type`: a large anonymous struct/union/enum written inline
  where a named type would be clearer.
- `param_ordering`: leading parameters should follow a convention: `self`, then
  an `io` (`std.Io`), then the allocator, then the rest. The `io`/allocator
  positions are configurable.
- `no_print`: `std.debug.print` in non-test code (use `std.log`). Shadow-aware,
  so it never flags your own `fn print` or a differently-bound `print`.
- `useless_error_return`: a function that returns `!T` but whose body can never
  actually produce an error. Drop the `!` so callers stop handling a
  non-existent error.

**complexity** (default `warn`)

- `too_many_params`: a function with more than the configured number of
  parameters.
- `redundant_else`: an `else` after an if-branch that always returns, breaks, or
  continues. Fixable: `--fix` removes the `else` and dedents its body.
- `duplicate_case`: two `switch` prongs with structurally identical bodies
  (commutativity-aware, so `x + 1` and `1 + x` count as the same).

**correctness** (default `error`)

- `discarded_error`: `_ = call();` throws away a call's result, which may be an
  unhandled error.
- `suppressed_errors`: a `catch {}` or `catch unreachable` that silently swallows
  an error. Exemptions for tests, writer calls, and `defer` are configurable.
- `homeless_try`: `try` used where the enclosing function does not return an
  error union (and it is not a `test`), which the compiler rejects anyway.

**memory** (default `error`)

- `return_stack_local`: `return &x` where `x` is a function-local variable yields
  a pointer into a stack frame that is destroyed on return.
- `hidden_allocator`: reaching for a global allocator (`std.heap.page_allocator`
  and friends) instead of taking an `std.mem.Allocator` parameter. Only `main`
  may originate a root allocator.
- `use_after_free`: a use of an allocation after it was freed, or a double free,
  within one function.
- `unsafe_undefined`: `= undefined` outside the cases where it is idiomatic.
  Array var-decls, `test` blocks, and destructors (`deinit`/`destroy`/`reset`)
  are each exempt by a configurable toggle; `x == undefined` always flags.
- `leaked_allocation`: a local allocation that is used in place and never freed
  or handed off. Defaults to `warn` (a leak is a resource bug, not unsafety),
  even though its group defaults to `error`.

**unused** (default `warn`)

- `unused_decl`: a private (non-`pub`) top-level declaration nothing in its file
  references. Fixable: `--fix` deletes it.
- `dead_file`: a `.zig` file in the tree that no compilation reaches (builder
  mode only).

The memory lints are deliberately conservative: they follow allocations only
within a single function and stay silent the moment ownership could leave through
a path they cannot prove, so they miss cases rather than raise a false alarm.

Zig compiler errors also appear, tagged `[zig]`, and are always shown.

## Configuration

Zippy reads the nearest `zippy.zon`, walking up from the current directory. With
none found, built-in defaults apply. A per-lint override beats a per-group
override beats the group default.

```zig
.{
    .default_severity = .warn,
    .groups = .{
        .style = .warn,
        .memory = .@"error",
    },
    .lints = .{
        .line_width = .{ .max = 100 },
        .too_many_params = .{ .max = 5 },
        // some lints take options beyond a severity:
        .param_ordering = .{ .io = 0, .allocator = 1 },
        .unsafe_undefined = .{ .allow_tests = true, .allow_destructors = true },
        // silence one lint everywhere without disabling its whole group
        .dead_file = .{ .severity = .off },
    },
}
```

Each severity is `off`, `warn`, or `error`. A run exits `1` if any
`error`-severity diagnostic fired, `0` otherwise, and `2` if Zippy itself failed
(a bad `zippy.zon`, a build that did not build, or an internal error).

## Inline suppression

Mute a lint at a specific spot with a `// zippy:ignore` comment. A standalone
comment mutes the next line. A trailing comment mutes its own line. A bare
directive with no names mutes every lint on the target line.

```zig
// zippy:ignore hidden_allocator
const gpa = std.heap.page_allocator;

const gpa = std.heap.page_allocator; // zippy:ignore hidden_allocator

// zippy:ignore discarded_error too_many_params
```

Zig compiler errors and parse errors are never suppressible. A real build error
should not be silenceable.

## Editor integration

`zippy lsp` runs a Language Server over stdio, giving live diagnostics on every
edit, hover text with each lint's rationale, and quick-fix code actions (the same
fixes `--fix` applies, offered per diagnostic).

## Status

Early and moving fast (version `0.1.0`). The lint set, fix coverage, and
memory-safety analysis are growing. Correctness bias throughout: a lint prefers a
missed case over a false positive.

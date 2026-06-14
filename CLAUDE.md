# zed — guidance for working in this repo

`zed` (zig-editor) is a terminal-based, modal code editor written in Zig, in the
spirit of nvim and helix. This file is the contract for every change made here.

## Engineering principles (read first, applies to every change)

These four rules override convenience. When they conflict with "just make it
work", they win.

1. **Think before coding** — state your assumptions out loud, ask when unsure,
   never guess. Reading two files is cheaper than rewriting one.
2. **Simplicity first** — write the minimum code that solves the problem,
   nothing extra. No premature abstractions, no "while-we're-here" refactors.
3. **Surgical changes** — every changed line must trace back to the user's
   request. If you can't justify a hunk in a one-line PR comment, drop it from
   the diff.
4. **Goal-driven** — turn vague instructions into verifiable success criteria
   before starting. "Make training faster" is not a goal; "AMP wired, cuDNN
   benchmark on, throughput ≥ 1.5× baseline on the v8n smoke" is.

## Project rules

- **Zig only, no third-party dependencies.** The standard library plus Zig's own
  package management is the entire toolbox. Do not add external packages. Keep
  the dependency surface as small as possible.
- **Idiomatic, modern Zig.** Follow current Zig conventions for the toolchain in
  `build.zig.zon` (`minimum_zig_version`). No legacy/deprecated APIs.
- **Fast to compile and fast to run.** Keep build times low; prefer plain data
  and functions over heavy comptime. Favour `ReleaseFast`/`ReleaseSafe` for
  shipping. Profile before optimising (see below).
- **Spend as few CPU cycles as possible.** The editor is event-driven: it blocks
  in `poll(2)` when idle (zero CPU), renders only when state changed, reuses the
  frame buffer (no per-frame allocation) and writes each frame in one syscall.
  Any change that adds idle wakeups, per-frame allocations or extra redraws must
  be justified against this.
- **Robust and multi-platform.** Target POSIX terminals (Linux, macOS, BSD)
  today; keep OS-specific code isolated (currently `term.zig`) so other
  platforms can be added without touching the core. Handle errors, never crash
  on bad input (e.g. malformed UTF-8 is rendered, not fatal).
- **Modular.** One clear responsibility per file (see Architecture). New
  concerns get new modules rather than swelling existing ones.
- **No dead code.** Remove unused code, scaffolding and TODO stubs as soon as
  they stop earning their place. Don't keep a "legacy" path alongside a new one.
- **Human-friendly errors.** User-facing messages are plain English with a hint
  ("not a terminal — run zed in an interactive terminal"), never a raw error
  enum dumped at the user.
- **Traceable via logs.** Diagnostics go through `std.log` into a file enabled
  with `--log <path>` (off by default, costs one null check when off). Keep the
  editor fully diagnosable from the log alone.
- **Great CLI experience.** `--help`/`--version` are complete and correct, exit
  codes are meaningful (2 = usage error, 1 = runtime error), and the tool is
  pleasant from the first run.
- **Unicode-correct.** Text is UTF-8 throughout. Cursor movement and rendering
  are codepoint- and display-width-aware (CJK = 2 cells, combining = 0). Never
  split a codepoint.
- **Profile, don't guess.** Use `log.Span` to time hot paths (render, input) in
  microseconds; it is a no-op when logging is off. Measure before and after any
  performance change.

## Git

- Commit as the repo owner (Aashish Gupta), with **short, to-the-point** messages
  in imperative mood (e.g. "Add UTF-8 display-width handling").
- Keep commits focused and surgical, matching the principles above.
- Upstream remote is added by the owner later; don't assume one exists.

## Architecture

Source is `src/`, one responsibility per module:

| File          | Responsibility |
|---------------|----------------|
| `main.zig`    | Composition root: CLI → logging → buffer → terminal → editor; failure handling. |
| `cli.zig`     | Argument parsing and the help/version text. |
| `log.zig`     | File logging (custom `std.log` sink) and the `Span` profiling primitive. |
| `term.zig`    | POSIX terminal control: raw mode, alternate screen, window size, event-driven input. |
| `key.zig`     | Decoding raw input bytes into `Key` events (text, arrows, navigation). |
| `unicode.zig` | UTF-8 decoding, codepoint boundaries, display width. |
| `buffer.zig`  | The document: line storage, load/save, UTF-8-aware edits. |
| `editor.zig`  | State, modal input dispatch, viewport, rendering. |

Data flow: `term` reads bytes → `key` decodes them → `editor` mutates `buffer`
and renders a frame back through `term`. `unicode` is shared by `buffer` and
`editor`; `log` is used everywhere.

## Build, test, run

```sh
zig build                       # debug build -> zig-out/bin/zed
zig build -Doptimize=ReleaseFast
zig build run -- [file]         # run the editor
zig build test                  # unit tests (pure logic; no tty needed)
```

Interactive behaviour can't be unit-tested without a terminal, so integration
checks live in `tools/` and drive the editor through a pseudo-terminal:

```sh
zig build
python3 tools/pty_test.py "$PWD/zig-out/bin/zed" /tmp/zed_it.txt   # edit/save/quit
python3 tools/cpu_test.py "$PWD/zig-out/bin/zed" /tmp/zed.txt /tmp/zed.log  # idle CPU + profiling
```

(Python is dev-only tooling for spawning a pty; the editor itself has no runtime
dependencies.)

## Editor usage

Modal, vi-like. Normal mode: `h j k l` move, `0`/`$` line ends, `gg`/`G`
top/bottom, `i`/`a`/`o`/`O` insert, `x` delete, `:` command line. Command line:
`:w` write, `:q` quit (blocked if unsaved), `:wq`/`:x` write-and-quit, `:q!`
force quit, `:w <name>` write to a path. Insert mode: type to edit, `Esc` to
return to normal mode. Tabs are stored verbatim and rendered at `tab_width`
(currently 4) in `editor.zig`.

## Zig 0.16 notes (the std API moved a lot here)

- Entry point is `pub fn main(init: std.process.Init) !void`; get the allocator,
  arena, `Io` and args from `init` (`init.gpa`, `init.arena.allocator()`,
  `init.io`, `init.minimal.args.toSlice(arena)`).
- `std.ArrayList(T)` is **unmanaged**: `.empty` to construct, pass the allocator
  to `append`/`appendSlice`/`deinit`, etc.
- Filesystem moved under `std.Io`: `std.Io.Dir.cwd().readFileAlloc(io, path, gpa,
  limit)` / `.writeFile(io, .{ .sub_path, .data })`.
- `std.posix` lost `write`/`isatty`/`close`/`open`; use raw syscalls
  (`posix.system.write`, `posix.system.close`) and `posix.tcgetattr` (which
  returns `error.NotATerminal`) for tty detection. `std.posix.poll` swallows
  EINTR, so we call the raw `posix.system.poll` to see SIGWINCH.
- Route logging via `pub const std_options = log.options;` in `main.zig`.

## Known gaps / future work (keep this honest)

- Windows console support (the `term.zig` compile-time gate marks the spot).
- Large-file performance: lines are a flat array; a rope/gap buffer is the next
  step if profiling shows it's needed.
- A resize landing in the tiny window between the resize check and entering
  `poll` is noticed on the next keypress (a self-pipe would close the race).
- Undo/redo, search, syntax highlighting, multiple buffers — not yet built.

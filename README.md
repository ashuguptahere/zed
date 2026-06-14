# zed

A fast, terminal-based, modal code editor written in **pure Zig** — no
third-party dependencies, just the standard library. Inspired by `nvim` and
`helix`.

> `zed` here means **zig-editor**.

## Status

Early but working. It opens a file (or an empty buffer), edits modally with
vi-like keys, handles Unicode, and saves — all while using **zero CPU when
idle**.

## Features

- Modal editing: normal / insert / command modes
- Movement: `h j k l`, `0` `$`, `gg` `G`, arrows, Home/End, PageUp/Down
- Editing: insert (`i` `a` `o` `O`), delete (`x`, Backspace, Delete), line
  split/join
- Commands: `:w`, `:q`, `:wq`/`:x`, `:q!`, `:w <name>`
- UTF-8 throughout, with correct display width for wide (CJK) and zero-width
  (combining) characters, and tab expansion
- Line numbers, a status bar, horizontal/vertical scrolling, live window resize
- Event-driven input loop: blocks in `poll(2)` when idle, renders only on change,
  one write per frame
- Diagnostic logging and microsecond profiling via `--log`
- Friendly CLI: `--help`, `--version`, meaningful exit codes, clear errors

## Build & run

Requires Zig `0.16.0`.

```sh
zig build                          # -> zig-out/bin/zed
zig build -Doptimize=ReleaseFast   # optimized build
zig build run -- path/to/file      # build and run
zig build test                     # run unit tests
```

## Usage

```sh
zed                 # empty buffer
zed file.txt        # open a file (created on save if missing)
zed --log zed.log file.txt   # open with diagnostics written to zed.log
```

Normal mode keys:

| Key            | Action |
|----------------|--------|
| `h j k l`      | Move left / down / up / right |
| `0` `$`        | Start / end of line |
| `gg` `G`       | First / last line |
| `i` `a`        | Insert before / after the cursor |
| `o` `O`        | Open a line below / above |
| `x`            | Delete the character under the cursor |
| `:`            | Command line |

Command line: `:w` write, `:q` quit, `:wq` / `:x` write and quit, `:q!` quit
without saving, `:w <name>` write to a path. Press `Esc` to leave insert or
command mode.

## Project layout

See [`CLAUDE.md`](CLAUDE.md) for the module map, engineering principles, and
contributor guidance. Integration tests that drive the editor through a
pseudo-terminal live in [`tools/`](tools/).

## Platform support

POSIX terminals (Linux, macOS, BSD). Windows console support is planned; the
OS-specific code is isolated in `src/term.zig`.

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

- Modal editing: normal / insert / visual / command modes
- A comprehensive **vim keymap**:
  - Motions: `h j k l`, `w W b B e E`, `0 ^ $`, `gg G {n}G`, `f F t T` + `; ,`,
    `%`, `H M L`, `Ctrl-d/u/f/b`, arrows
  - Counts and operators: `d c y`, `> <`, doubled `dd cc yy`, `D C Y x X s S`,
    `r ~ J`, e.g. `3dw`, `d2j`, `ci"`, `da(`, `diw`
  - Registers and paste: `"a`, `p` / `P` (linewise & charwise)
  - Undo `u`, redo `Ctrl-r`, repeat `.`
  - Visual `v` / `V` with `d c y x > <`
  - Search `/ ? n N * #` (literal, wraps)
  - Marks `m` `` ` `` `'` and macros `q…q` / `@`
  - Built-ins (no plugins): auto-pairs, comment toggle (`gcc` / `gc{motion}`)
  - Multiple cursors: `Ctrl-n` / `Ctrl-p` add carets below/above; edits apply to all
  - Surround (`ys`/`cs`/`ds`, visual `S`) and blockwise visual (`Ctrl-v` + `I`/`A`)
  - Pickers via a `Space` which-key menu: `Space f` fuzzy file finder,
    `Space /` global content search
- Commands: `:w`, `:q`, `:wq`/`:x`, `:q!`, `:w <name>`, `:{number}`, `ZZ`/`ZQ`
- AstroNvim/Helix-style look: Tokyo Night true-colour theme, syntax
  highlighting, a powerline statusline (mode block, separators, segments),
  relative+absolute line numbers, cursorline, and indent guides
  (a nerd font is recommended for the statusline glyphs)
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
zig build                          # -> zig-out/bin/zed (+ man page under share/man)
zig build -Doptimize=ReleaseFast   # optimized build
zig build run -- path/to/file      # build and run
zig build test                     # run unit tests
man ./doc/zed.1                    # read the manual
```

## Usage

```sh
zed                 # empty buffer
zed file.txt        # open a file (created on save if missing)
zed --log zed.log file.txt   # open with diagnostics written to zed.log
```

Keys are vim-style — `h j k l` move, `dd`/`dw`/`ciw`/`yyp` edit, `v`/`V` select,
`/` searches, `u`/`Ctrl-r` undo/redo, `.` repeats, `q`/`@` record/replay macros.
The full keymap is in [`CLAUDE.md`](CLAUDE.md#editor-usage).

Command line: `:w` write, `:q` quit, `:wq` / `:x` write and quit, `:q!` quit
without saving, `:w <name>` write to a path, `:{number}` go to a line. Press
`Esc` to leave insert, visual or command mode.

## Project layout

See [`CLAUDE.md`](CLAUDE.md) for the module map, engineering principles, and
contributor guidance. Integration tests that drive the editor through a
pseudo-terminal live in [`tools/`](tools/).

## Platform support

POSIX terminals (Linux, macOS, BSD). Windows console support is planned; the
OS-specific code is isolated in `src/term.zig`.

# zed

A fast, terminal-based, modal code editor written in **Zig**, inspired by
`nvim` and `helix`. Batteries included — the features you'd install plugins
for are built in — with no Zig package dependencies: just the standard
library plus a vendored tree-sitter runtime + grammars (C, compiled by the
build) for structural syntax highlighting. The editor itself has **zero
runtime dependencies**.

> `zed` here means **zig-editor**.

## Philosophy

- **Batteries included** (like Helix): LSP, tree-sitter, pickers, git signs,
  surround, comments, multiple cursors, splits and themes work out of the box.
  No plugin manager, no setup.
- **Vim/AstroNvim keybindings** (unlike Helix): the classic
  operator-then-motion grammar, plus a `Space` leader with a which-key popup.
- **One documented config file**, everything optional: `zed --init-config`
  writes it with every setting, its default, and an explanation.
- **Fast and idle-free**: an event-driven core that blocks in `poll(2)` — an
  idle editor uses **zero CPU**; each frame is built once and written with one
  syscall. The idle-CPU budget is enforced by a test (`tools/scenarios/cpu.zig`).

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
  - Search `/ ? n N * #` — incremental (jumps as you type) with match highlighting
  - Marks `m` `` ` `` `'` and macros `q…q` / `@`
  - Built-ins (no plugins): auto-pairs, comment toggle (`gcc` / `gc{motion}`),
    surround (`ys`/`cs`/`ds`, visual `S`), blockwise visual (`Ctrl-v` + `I`/`A`),
    multiple cursors (`Ctrl-n` / `Ctrl-p` add carets; edits apply to all)
- **LSP**, auto-launched per filetype (`zls`, `clangd`, `pylsp`,
  `typescript-language-server`; any server via `--lsp <cmd>`); one client per
  open buffer, so different languages run side by side:
  - diagnostics in the gutter/statusline with `]d` / `[d` navigation
  - completion (`Ctrl-n` in insert), signature help (on `(` and `,`),
    hover (`K` / `Ctrl-k`), goto definition (`gd`)
  - rename (`gr`), code actions (`ga`, including `executeCommand`/`applyEdit`),
    document symbols (`Space o`), inlay hints rendered as virtual text
- **Pickers** via the `Space` which-key menu: `Space f` fuzzy file finder,
  `Space /` project-wide content search, `Space o` symbols, `Space t` themes —
  one consistent UI (`Ctrl-n/p` move, `Enter` opens, `Esc` cancels)
- **Multiple buffers and windows**: `:e`, `:bn`/`:bp`/`:bd`/`:ls`;
  `:split`/`:vsplit` and `Ctrl-w` navigation; every buffer keeps its own
  cursor, undo history, highlighting and language server
- **Themes**: `tokyonight` (default), `gruvbox`, `catppuccin`, `nord`,
  `onedark` — set in the config, switch live with `:theme <name>` or `Space t`
- AstroNvim/Helix-style look: true-colour syntax highlighting (tree-sitter for
  Zig/C/Python/JSON/JS/TS/Rust/Go/HTML/Markdown, a built-in lexer otherwise),
  a powerline statusline, relative+absolute line numbers, cursorline, indent
  guides, and a git change gutter
- UTF-8 throughout, with correct display width for wide (CJK) and zero-width
  (combining) characters, and tab expansion
- Event-driven input loop: blocks in `poll(2)` when idle, renders only on
  change, one write per frame
- Diagnostic logging and microsecond profiling via `--log`
- Friendly CLI: `--help`, `--version`, `--tutor`, `--init-config`, meaningful
  exit codes, clear errors

## Build & run

Requires Zig `0.16.0`.

```sh
zig build                          # -> zig-out/bin/zed (+ man page under share/man)
zig build -Doptimize=ReleaseFast   # optimized build
zig build run -- path/to/file      # build and run
zig build test                     # unit tests (pure logic)
zig build itest                    # pty integration tests (drive the real editor)
man ./doc/zed.1                    # read the manual
```

## Usage

```sh
zed                 # empty buffer
zed file.txt        # open a file (created on save if missing)
zed --tutor         # interactive tutorial, in the vimtutor tradition
zed --log zed.log file.txt   # open with diagnostics written to zed.log
```

Keys are vim-style — `h j k l` move, `dd`/`dw`/`ciw`/`yyp` edit, `v`/`V`
select, `/` searches, `u`/`Ctrl-r` undo/redo, `.` repeats, `q`/`@`
record/replay macros, `Space` opens the leader menu. The full keymap is in
[`CLAUDE.md`](CLAUDE.md#editor-usage) and `man zed`.

## Configuration

One file: `~/.config/zed/config` (or `$XDG_CONFIG_HOME/zed/config`;
`--config <path>` overrides). Create it fully documented with:

```sh
zed --init-config
```

Format is `key = value` with `#` comments; unknown keys are ignored and a
missing file just means defaults. Settings today: `theme`, `tab_width`,
`nerd_font`.

> **Icons look broken?** The powerline statusline separators are Nerd Font
> glyphs (private-use codepoints). Terminal applications cannot ship fonts —
> your terminal emulator picks the font — so either select a
> [Nerd Font](https://www.nerdfonts.com) in your terminal, or set
> `nerd_font = false` for a flat statusline that renders correctly in any font.

## Project layout

See [`CLAUDE.md`](CLAUDE.md) for the module map, engineering principles, and
contributor guidance. Integration tests that drive the editor through a real
pseudo-terminal live in [`tools/`](tools/) — all Zig, no test-time
dependencies.

## Platform support

POSIX terminals (Linux, macOS, BSD). Windows console support is planned; the
OS-specific code is isolated in `src/term.zig`.

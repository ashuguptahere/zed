# zedit

A fast, terminal-based, modal code editor written in **Zig**, inspired by
`nvim` and `helix`. Batteries included — the features you'd install plugins
for are built in — with no Zig package dependencies: just the standard
library plus a vendored tree-sitter runtime + grammars (C, compiled by the
build) for structural syntax highlighting. The editor itself has **zero
runtime dependencies**.

> `zedit` here means **zig-editor**.

## Philosophy

- **Batteries included** (like Helix): LSP, tree-sitter, pickers, git signs,
  surround, comments, multiple cursors, splits and themes work out of the box.
  No plugin manager, no setup.
- **Vim/AstroNvim keybindings** (unlike Helix): the classic
  operator-then-motion grammar, plus a `Space` leader with a which-key popup.
- **One documented config file**, everything optional: `zedit --init-config`
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
    document symbols (`Space l s`), inlay hints rendered as virtual text
- **Pickers** via the AstroNvim-style `Space` leader tree with nested
  which-key menus: `Space f f` find files, `Space f w` find words (grep),
  `Space f b` buffers, `Space f t` themes; `Space l …` language tools — one
  consistent UI (`Ctrl-n/p` move, `Enter` opens, `Esc` cancels, `Ctrl-r`
  refreshes). The file list is cached per session with per-path char-bitmask
  prefiltering and incremental query narrowing — the same tricks that make
  Zed's finder feel instant
- **Multiple buffers and windows**: `:e`, `:bn`/`:bp`/`:bd`/`:ls`;
  `:split`/`:vsplit` and `Ctrl-w` navigation; every buffer keeps its own
  cursor, undo history, highlighting and language server
- **Themes**: `tokyonight` (default), `gruvbox`, `catppuccin`, `nord`,
  `onedark` — set in the config, switch live with `:theme <name>` or `Space f t`
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
zig build                          # -> zig-out/bin/zedit (+ man page under share/man)
zig build -Doptimize=ReleaseFast   # optimized build
zig build run -- path/to/file      # build and run
zig build test                     # unit tests (pure logic)
zig build itest                    # pty integration tests (drive the real editor)
man ./doc/zedit.1                    # read the manual
```

## Usage

```sh
zedit                 # empty buffer
zedit file.txt        # open a file (created on save if missing)
zedit --tutor         # interactive tutorial, in the vimtutor tradition
zedit --log zedit.log file.txt   # open with diagnostics written to zedit.log
```

Keys are vim-style — `h j k l` move, `dd`/`dw`/`ciw`/`yyp` edit, `v`/`V`
select, `/` searches, `u`/`Ctrl-r` undo/redo, `.` repeats, `q`/`@`
record/replay macros, `Space` opens the leader menu. The full keymap is in
[`CLAUDE.md`](CLAUDE.md#editor-usage) and `man zedit`.

## Configuration

One file: `~/.config/zedit/config` (or `$XDG_CONFIG_HOME/zedit/config`;
`--config <path>` overrides). Create it fully documented with:

```sh
zedit --init-config
```

Format is `key = value` with `#` comments; unknown keys are ignored and a
missing file just means defaults. Settings today: `theme`, `tab_width`,
`nerd_font`.

> **Icons look broken?** The powerline statusline separators are Nerd Font
> glyphs (private-use codepoints). Terminal applications cannot ship fonts —
> your terminal emulator picks the font — so either select a
> [Nerd Font](https://www.nerdfonts.com) in your terminal, or set
> `nerd_font = false` for a flat statusline that renders correctly in any font.

## Benchmarks

`zig build bench -Doptimize=ReleaseFast` measures zedit against helix and
neovim through real pseudo-terminals (clean configs for all). On this
machine (medians):

| metric | zedit | helix 25.07.1 | nvim 0.12.4 |
|---|---|---|---|
| startup → interactive | **7.5 ms** | 28.4 ms | 10.5 ms |
| open 10 MB / 200k lines | 36.6 ms | 36.6 ms | **10.8 ms** |
| keypress → response | **0.13 ms** | 0.57 ms | **0.13 ms** |
| file picker open (this repo) | 5.9 cold / **4.6 ms** warm | 5.2 ms | n/a (no builtin) |

Honest notes: nvim wins large-file open (flat line array vs their tree —
a rope is on our roadmap); the warm-picker advantage grows with project size
since zedit skips the filesystem walk entirely after the first open.

## Project layout

See [`CLAUDE.md`](CLAUDE.md) for the module map, engineering principles, and
contributor guidance. Integration tests that drive the editor through a real
pseudo-terminal live in [`tools/`](tools/) — all Zig, no test-time
dependencies.

## Platform support

POSIX terminals (Linux, macOS, BSD). Windows console support is planned; the
OS-specific code is isolated in `src/term.zig`.

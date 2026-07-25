# zedit


> `zedit` here means **zig-editor**.

## Philosophy

 **Vim/AstroNvim keybindings** (unlike Helix): the classic
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
  - Registers and paste: `"a`, `p` / `P` (linewise & charwise); `"+`/`"*`
    talk to the **system clipboard via OSC 52** — works over SSH
  - Undo `u`, redo `Ctrl-r`, repeat `.`
  - Visual `v` / `V` with `d c y x > <`
  - Search `/ ? n N * #` — **regex** (modern syntax, linear-time engine, no
    catastrophic backtracking), incremental (jumps as you type), highlighted;
    `*`/`#` match whole words
  - `:%s/pat/rep/g` substitution with ranges (`%`, `n,m`), flags `g`/`i`,
    `&` and `\1`–`\9` in replacements — behaviour pinned to real-nvim outputs
  - Marks `m` `` ` `` `'` and macros `q…q` / `@`
  - Jumplist: `Ctrl-o` / `Ctrl-i` walk back and forward through jumps
    (searches, `G`, marks, `gd`, buffer switches — cross-buffer)
  - Text objects incl. paragraphs (`ip`/`ap`, `{`/`}`), also in visual mode
  - Tree-sitter structural objects: `af`/`if` (function), `ac`/`ic` (class,
    struct, impl), and `]f`/`[f` to step between functions
  - Built-ins (no plugins): autoindent, auto-pairs, comment toggle (`gcc` / `gc{motion}`),
    surround (`ys`/`cs`/`ds`, visual `S`), blockwise visual (`Ctrl-v` + `I`/`A`),
    multiple cursors (`Ctrl-n` / `Ctrl-p` add carets; edits apply to all)
- **LSP**, auto-launched per filetype (`zls`, `clangd`, `pylsp`,
  `typescript-language-server`; any server via `--lsp <cmd>`); one client per
  open buffer, so different languages run side by side:
  - diagnostics in the gutter/statusline **and inline at end of line** (dim,
    severity-coloured; `inline_diagnostics = false` to silence), with `]d` /
    `[d` navigation
  - completion that pops up as you type (debounced; `Ctrl-n` on demand) and
    is **fuzzy** matched — `mplt` finds `mockComplete`
  - workspace symbol search (`Space l S`) and a diagnostics list
    (`Space l D`) across all open buffers
  - snippets with tabstops (`Tab`/`Shift-Tab` between placeholders, typing
    replaces them), `textEdit` ranges and auto-import `additionalTextEdits`
  - signature help (on `(` and `,`),
    hover (`K` / `Ctrl-k`), goto definition (`gd`), implementation (`gi`) and
    type definition (`gy`)
  - rename (`gr`), find references (`Space l R`), code actions (`ga`,
    including `executeCommand`/`applyEdit`), document symbols (`Space l s`),
    inlay hints rendered as virtual text
  - formatting (`Space l f` / `:format`) with format-on-save (config
    `format_on_save`), and full WorkspaceEdit support: cross-file, multi-line
    rename/code-action edits — other buffers are edited in place, unopened
    files load in the background, `:wa` writes them all
- **Pickers** via the AstroNvim-style `Space` leader tree with nested
  which-key menus: `Space f f` find files, `Space f w` find words (grep),
  `Space f b` buffers, `Space f t` themes; `Space l …` language tools — one
  consistent UI (`Ctrl-n/p` move, `Enter` opens, `Esc` cancels, `Ctrl-r`
  refreshes). The file list is cached per session with per-path char-bitmask
  prefiltering and incremental query narrowing — the same tricks that make
  Zed's finder feel instant
- **Startup screen** listing recently opened files and directories (`j`/`k`,
  `Enter`, `1`-`9`), stored in `~/.local/state/zedit/recent`
- **Remote editing over SSH**: `zedit ssh://host/path/file`, `:e ssh://…` or
  `:ssh host` — no agent installed on the remote, no extra dependencies; a
  remote directory opens the fuzzy picker over it and `:w` writes back
- **Mouse wheel scrolling** (SGR mouse; Shift+drag still selects text in
  your terminal), with vim's centring on long jumps so scrolling doesn't drag
  the cursor around
- **Partial commands shown as you type them** (`d`, `di`, `2d`, `"ay`, `^W`) in
  the statusline, vim's `showcmd`
- **Command line** with Tab completion (command names, `:e`/`:w` paths,
  `:theme` names — nvim wildmenu semantics, popup included) and per-kind
  history on Up/Down with vim's prefix filtering
- **Multiple buffers and windows**: `:e`, `:bn`/`:bp`/`:bd`/`:ls`;
  `:split`/`:vsplit` and `Ctrl-w` navigation; every buffer keeps its own
  cursor, undo history, highlighting and language server
- **File-tree sidebar** (`Space e`): browse and open files, expand
  directories; lives on the left or right (config `sidebar = left|right`)
- **One search layout everywhere**: tree on the left, results in the middle,
  and a live tree-sitter-highlighted **preview** of the selection on the right
  (`Ctrl-d`/`Ctrl-u` or the wheel scroll it) — `zedit <dir>` opens into it
- **Buffer tabs** along the top when more than one file is open; click one to
  switch
- **Git diff views**: `Space g d` inline unified diff (coloured +/- lines) in
  a split, `Space g s` the index version side by side with changed/added/
  removed lines tinted vimdiff-style in both panes — plus the always-on
  gutter change signs
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

## Install

Prebuilt binaries (Linux x86_64/aarch64 as static musl executables that run
on any distribution, macOS x86_64/aarch64) are attached to every tagged
[GitHub release](../../releases) — download, `tar xzf`, and put `bin/zedit`
on your PATH. Built by CI with `-Doptimize=ReleaseFast -Dstrip`.

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
`nerd_font`, `sidebar`, `relative_numbers`, `large_file_mb`, `autoindent`,
`buffer_tabs`, `auto_completion`, `completion_delay_ms`,
`inline_diagnostics`, `format_on_save`.

Every CLI option has a short and a long form (`-h/--help`, `-v/--version`,
`-l/--log`, `-s/--lsp`, `-c/--config`, `-t/--tutor`, `-b/--benchmark`,
`-u/--check-update`, `--init-config`); `zedit <dir>` opens the file picker in that directory, and
`zedit --benchmark [file]` prints open/search/serialize timings without
needing a terminal. Releases are versioned by the `VERSION` file and
documented in [CHANGELOG.md](CHANGELOG.md).

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
| startup → interactive | **5.8 ms** | 27.9 ms | 10.8 ms |
| open 10 MB — first paint | **1.2 ms** | 31.5 ms | 3.2 ms |
| open 10 MB — fully settled | **9.7 ms** | 34.8 ms | 10.2 ms |
| keypress → response | **0.12 ms** | 0.28 ms | 0.18 ms |
| `/` search in 10 MB — cold / repeat | **5.1 / 5.1 ms** | 1943 / 20.0 ms | 51.6 / 14.7 ms |
| file picker open (this repo) | **6.2 cold / 4.6 ms warm** | 1941 ms cold | n/a (no builtin) |

Two notes on reading this table honestly. The search and picker columns used
to show helix at ~4.4 ms; that was a bug in *our* harness, which began counting
silence the moment the key was sent and so scored an editor that had not
answered yet as having finished instantly. It now waits for a first response
before timing the settle, which is why helix's numbers moved so far. An
independent probe puts helix's first search of this file at ~520 ms and its
repeat searches at 15–22 ms, so treat the cold figure as the right order of
magnitude rather than an exact one. zedit's search costs the same cold and
warm because it builds no index to warm up. On a 476 MB file zedit searches in ~196 ms
against nvim's 217 ms and helix's 1753 ms. The picker opens before its project
walk finishes and streams results in, so on a 20k-file tree it is on screen in
0.5 ms where helix takes ~1.1 s.

Buffer loading is zero-copy (one shared byte buffer; lines are slices that
convert to owned storage on first edit), so the big-file number fell from
36.6 ms to 14.3 ms. Honest notes: nvim still edges the large-file open — the
remaining ~4 ms is the up-front read+line-scan that nvim defers; the
warm-picker advantage grows with project size since zedit skips the
filesystem walk entirely after the first open. A feature-by-feature
comparison against both editors lives in [doc/COMPARISON.md](doc/COMPARISON.md).

### Huge files

Files up to 2 GB open without ceremony. Above the configurable
`large_file_mb` threshold (default 64 MB) zedit switches to **large-file
mode**: highlighting, LSP and git signs are skipped so nothing downstream
chokes — the same strategy VSCode uses, minus the scary dialog. Loading stays
zero-copy, and while a file is unedited, `/` search scans the whole buffer in
one SIMD pass instead of line-by-line. Measured on a **476 MB / 10M-line**
file (same pty methodology):

| | open | `/` search across the file |
|---|---|---|
| **zedit** | 375 ms | **196 ms** |
| nvim 0.12 (`-u NONE`) | **103 ms** | 217 ms |
| helix 25.07 | 459 ms | 1753 ms |

(How others do it: vim/nvim use their block-based memline with lazy work —
that's the open-time win; helix loads into a rope; VSCode's JS string model
is why it struggles and disables features around ~50 MB. zedit reads once,
indexes lines in one vectorized pass, and edits copy-on-write per line.
nvim's remaining open-time edge is deferred line indexing — on the list.)

## SSH

zedit is built to feel local over a remote shell:

- **Clipboard out**: `"+y` sends an OSC 52 escape through the connection, so
  the *local* terminal's clipboard gets the text — no X11 forwarding, no
  xclip/wl-copy on the server.
- **Clipboard in**: your terminal's paste arrives via **bracketed paste** and
  is inserted literally — multi-line pastes don't trigger auto-pairs or get
  executed as commands.
- **Bandwidth**: rendering is row-diffed — a keystroke re-sends only the rows
  that changed, not the whole screen — and input handling reassembles escape
  sequences that SSH splits across small reads.

## Project layout

See [`CLAUDE.md`](CLAUDE.md) for the module map, engineering principles, and
contributor guidance. Integration tests that drive the editor through a real
pseudo-terminal live in [`tools/`](tools/) — all Zig, no test-time
dependencies.

## Platform support

POSIX terminals (Linux, macOS, BSD). Windows console support is planned; the
OS-specific code is isolated in `src/term.zig`.

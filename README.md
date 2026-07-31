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
  - Soft wrap (on by default, `soft_wrap = false` to scroll sideways instead):
    breaks at word boundaries, keeps the line's indent on continuation rows,
    optional `wrap_column`, and `gj`/`gk`/`g0`/`g$` for screen-row movement
  - Undo *tree*: editing after an undo branches instead of discarding, and
    `g-`/`g+`, `:earlier`/`:later` (changes, time or file writes) and the
    `:undolist` picker reach every state; `persistent_undo` keeps it across
    sessions
  - Tree-sitter structural objects: `af`/`if` (function), `ac`/`ic` (class,
    struct, impl), `aa`/`ia` (argument, with its comma), `aC`/`iC` (comment,
    across a run of comment lines), and `]f`/`[f` to step between functions
  - Built-ins (no plugins): autoindent (the syntax tree's own indent rules for
    Zig/C/Python/Rust/Go/JS/TS, so Enter after `{` or `def f():` steps in),
    auto-pairs, comment toggle (`gcc` / `gc{motion}`),
    surround (`ys`/`cs`/`ds`, visual `S`), blockwise visual (`Ctrl-v` + `I`/`A`/`c`,
    `$` to each line's own end, and a rectangular `p`/`P`),
    multiple cursors (`Ctrl-n` / `Ctrl-p` add carets; edits apply to all),
    **buffer-word completion** — with no language server installed the popup
    still fills from the identifiers in your open buffers (vim's keyword
    completion; `buffer_completion = false` turns it off)
- **LSP**, auto-launched per filetype (`zls`, `clangd`, `pylsp`,
  `typescript-language-server`; any server via `--lsp <cmd>`); one client per
  open buffer, so different languages run side by side:
  - diagnostics in the gutter/statusline **and inline at end of line** (dim,
    severity-coloured; `inline_diagnostics = false` to silence), with `]d` /
    `[d` navigation
  - completion that pops up as you type (debounced; `Ctrl-n` on demand) and
    is **fuzzy** matched — `mplt` finds `mockComplete`; when no server is
    installed for the filetype the statusline says which one to install and
    the popup falls back to words from the open buffers
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
  which-key menus: `Space f f` find files, `Space f w` find words (regex grep,
  same syntax as `/`),
  `Space f b` buffers, `Space f t` themes, `Space f u` the undo tree;
  **Folds**: `zf{motion}` collapses a range to one row, `zo`/`zc`/`za` open
  and close, `zR`/`zM` all of them — and `j`/`k` step over a closed fold as
  though it were one line;
  `Ctrl-q` in a picker sends every result to the **quickfix list** (`]q`/`[q`
  to walk it, `:copen` to see it);
  `Space n …` new buffer / file / folder (a path like `src/net/http.zig`
  creates the directories on the way); `Space d …` a **debugger** (breakpoints,
  start/continue, step over/into/out — DAP, so `lldb-dap`, `debugpy` and
  `dlv dap` all work); `Space t` an **embedded terminal** (a real
  shell in a split — nvim's mode split, `Ctrl-\`` to toggle it open and shut, `Ctrl-\ Ctrl-n` back to normal, with
  5000 rows of scrollback the wheel and `Ctrl-u`/`Ctrl-d` page through);
  `Space S …` sessions (save/load/delete this
  directory's open files, cursors, splits and tree state — explicit both ways,
  never on launch or exit); `Space b …` buffers (picker,
  next/previous, close others); `Space u …` UI toggles (wrap, numbers, inline
  diagnostics, tabs, autoindent, completion, format-on-save, mouse — flipped
  for the session, the config file untouched); `Space l …` language tools — one
  consistent UI (`Ctrl-n/p` move, `Enter` opens, `Esc` cancels, `Ctrl-r`
  refreshes). Fuzzy queries are multi-term (helix-style): spaces split the
  query and every term must match, in any order — `render editor` finds
  `src/editor/render.zig` (the grep picker stays pure regex: a space is a
  literal there, `foo.*bar` asks for order) — and a files query with no
  match hints at `Space f w`, the *content* search. The file list is cached
  per session with per-path char-bitmask
  prefiltering and incremental query narrowing — the same tricks that make
  Zed's finder feel instant
- **Startup screen** listing recently opened files and directories (`j`/`k`,
  `Enter`, `1`-`9`), stored in `~/.local/state/zedit/recent`
- **Remote editing over SSH**: `zedit ssh://host/path/file`, `:e ssh://…` or
  `:ssh host` — no agent installed on the remote, no extra dependencies; a
  remote directory opens the fuzzy picker over it and `:w` writes back
  atomically (temp file + rename, so a dropped connection never leaves a
  half-written file)
- **Mouse support** (SGR, config `mouse`): **click to move the cursor** — into
  another split, which it focuses first — and **drag to select** (the press
  anchors, motion extends, release finishes, leaving an ordinary visual
  selection for `d`/`y`/`c`); a click with an operator pending applies it over
  the clicked range, all pinned to real nvim's `mouse=a`. **Double click
  selects the word, triple click the line**, quadruple one blockwise cell, and
  the fifth click starts over — vim's cycle, its *mouse* word (punctuation
  goes through `%`, so double-clicking a bracket takes the whole pair) and its
  `mousetime` window, derived from the previous click rather than from any
  timer. Dragging on from a multi-click extends by whole words, lines or a
  rectangle. A gesture begun in insert mode is nvim's **Insert Visual**:
  `(insert) VISUAL` on the statusline, and whatever ends the selection returns
  to insert. The **wheel scrolls the window under the pointer** without moving
  focus. Plus tab clicks and explorer clicks — in the pickers too (`zedit .`
  starts in one): click a result row to select it, click it again to open, so
  a double-click opens from anywhere. Clicks land correctly through soft wrap,
  tabs, wide CJK cells, inlay hints and the diff views. **Shift+drag** is your
  terminal's own selection, and `mouse = false` turns reporting off entirely
- **Partial commands shown as you type them** (`d`, `di`, `2d`, `"ay`, `^W`) in
  the statusline, vim's `showcmd`
- **Command line** with fish-style inline suggestions (the rest of the best
  history or command-name match as dim ghost text; `Right`/`End` at the end
  of the line accepts, Enter always runs only what you typed — config
  `cmdline_suggestions`), mid-line editing (`Left`/`Right`, `Home`/`End`,
  `Ctrl-b`/`Ctrl-e`, `Delete` under the cursor, `Ctrl-w` word erase,
  `Ctrl-u` erase-to-start, `Ctrl-r{reg}` to insert a register; typing
  inserts at the cursor — all nvim-pinned),
  Tab completion (command names, `:e`/`:w` paths, `:theme` names — nvim
  wildmenu semantics, popup included: only the text *before* the cursor is
  completed and the tail is kept, `Left`/`Right` select matches, and in
  a path popup `Down` descends into the selected directory while `Up`
  re-completes in the parent) and per-kind history on Up/Down with
  vim's prefix filtering. A line wider than the terminal wraps onto further
  rows, the command-line area growing upward over the window, as nvim's does
- **Multiple buffers and windows**: `:e`, `:bn`/`:bp`/`:bd`/`:ls`, `]b`/`[b`
  to cycle (counts work: `2]b`), a `Space b` Buffers menu;
  `:split`/`:vsplit` and `Ctrl-w` navigation; every buffer keeps its own
  cursor, undo history, highlighting and language server. `:bd` follows
  vim: the last buffer is replaced by an empty `[No Name]` (the window
  stays), a dirty buffer refuses unless forced with `:bd!`
- **File-tree sidebar** (`Space e`, VS Code's three-state cycle: open +
  focus → refocus an open tree → close a focused one): browse and open
  files, expand directories — by key (`l`/`h` or Right/Left, VS Code's tree
  arrows) or by mouse (a single click toggles a
  directory or opens a file, VS Code-style); `a` creates a file and `A` a
  folder, making any missing directories on the way (`a` then
  `src/new/mod.zig` works with no `src/new` yet — and so does `:w` to such a
  path); lives on the left or right
  (config `sidebar = left|right`), and follows you — switching buffers
  reveals and selects the active file in the tree
- **One search layout everywhere**: tree on the left, results in the middle,
  and a live tree-sitter-highlighted **preview** of the selection on the right
  (`Ctrl-d`/`Ctrl-u` or the wheel scroll it) — `zedit <dir>` opens into it
- **A powerline title bar** along the top (VS Code-style, even for one file):
  the explorer's header over the sidebar, one tab per open buffer beside it —
  the active tab accent-coloured, unsaved ones dotted; click a tab to switch or its `✕` to close it
  (config `buffer_tabs = false` removes the row and puts the filename back in
  the statusline)
- **Git diff views**: `Space g d` inline unified diff (coloured +/- lines) in
  a split, `Space g s` the index version side by side — panes row-aligned with
  tinted filler rows (VS Code-style, deletions before line 1 included),
  scrolled in lockstep, changed/added/
  removed lines tinted vimdiff-style, both the diff buffer and the index
  pane read-only, focus staying
  on your file — and `Space g l` the VS Code/Zed line-by-line view: the old
  lines woven into your own buffer's window as red virtual rows above the
  lines that replaced them (no split, no second buffer, still fully
  editable, cursor motion skips the woven rows); any key pressed again
  closes its view, and the three views swap for each other per file — plus
  the always-on gutter change signs
- **Themes**: `tokyonight` (default), `gruvbox`, `catppuccin`, `nord`,
  `onedark` — set in the config, switch live with `:theme <name>` or the
  `Space f t` picker, which previews each theme as you move and saves the one
  you pick so it survives a restart
- AstroNvim/Helix-style look: true-colour syntax highlighting (tree-sitter for
  Zig/C/Python/JSON/JS/TS/Rust/Go/HTML/Markdown, a built-in lexer otherwise),
  a powerline statusline, relative+absolute line numbers, cursorline, indent
  guides, and a git change gutter
- **Language injections**: a fenced code block in Markdown is highlighted as
  the language its info string names, and a `<script>` body as JavaScript —
  each region parsed by that grammar, not approximated. The grammars' own
  query predicates (`#match?`, `#eq?`, `#any-of?`) are evaluated too, so a
  capture fires only where its query says it should
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
`buffer_completion`, `inline_diagnostics`, `soft_wrap`, `wrap_indent`,
`wrap_column`, `persistent_undo`, `format_on_save`, `cmdline_suggestions`,
`mouse`, `mousetime`.

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

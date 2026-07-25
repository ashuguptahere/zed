# zedit — guidance for working in this repo

`zedit` (zig-editor) is a terminal-based, modal code editor written in Zig, in the
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
5. **YAGNI** — build features when they reach the roadmap, never
   speculatively; prefer an algorithm or a closed-form computation over a
   loop, and a `std` call over hand-rolled code (audits sweep for both).
6. **Every feature ships with its checklist** — regression tests in the same
   commit, the docs sweep (README/CLAUDE.md/man/tutor/COMPARISON/CHANGELOG),
   a `TODO.md` update, and for anything perf- or input-relevant: a security
   pass (untrusted bytes stay inert), a benchmark run (`zig build bench`,
   `zedit --benchmark`) and `log.Span` profiling before/after.

## Project rules

- **Minimal dependencies.** Prefer the standard library; no Zig *package*
  dependencies. The one native dependency is the tree-sitter runtime + grammar,
  **vendored** as C under `vendor/` and compiled by `build.zig` (it links libc).
  This earns its place by giving real structural highlighting; adding more must
  clear the same bar. The LSP client is pure Zig (std only), and the per-line
  lexer (`syntax.zig`) remains the fallback for languages without a grammar.
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
  ("not a terminal — run zedit in an interactive terminal"), never a raw error
  enum dumped at the user.
- **Traceable via logs.** Diagnostics go through `std.log` into a file enabled
  with `--log <path>` (off by default, costs one null check when off). Keep the
  editor fully diagnosable from the log alone.
- **Great CLI experience.** `--help`/`--version` are complete and correct,
  every option has a short and a long form, exit codes are meaningful (2 =
  usage error, 1 = runtime error), a directory argument opens the file picker
  there, and `--benchmark` self-times the hot paths. The tool is pleasant from
  the first run.
- **Versioned + changelogged.** The `VERSION` file is the single source of
  truth (embedded into `--version` at build time); every user-visible change
  lands in `CHANGELOG.md` in the same commit.
- **Tracked in `TODO.md`.** The working tracker: in-progress, next (the
  COMPARISON shortlist), recurring per-feature checklist, known gaps, and the
  chronological done-list. Update it with every landed change.
- **Unicode-correct.** Text is UTF-8 throughout. Cursor movement and rendering
  are codepoint- and display-width-aware (CJK = 2 cells, combining = 0). Never
  split a codepoint.
- **Untrusted bytes stay inert.** Anything that reaches the terminal from
  outside the editor (buffer content, file names, LSP text, pastes) goes
  through the control-character sanitizer (`emitSanitized`/`isControlCp`) —
  C0/C1/DEL render as `?`, never as live escape sequences.
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
| `term.zig`    | POSIX terminal control: raw mode, alternate screen, bracketed paste, window size, event-driven input. |
| `key.zig`     | Decoding raw input bytes into `Key` events (text, arrows, navigation). |
| `unicode.zig` | UTF-8 decoding, codepoint boundaries, display width. |
| `buffer.zig`  | The document: zero-copy load (lines borrow from one shared buffer, copy-on-write on first edit), save, UTF-8-aware edits. |
| `motion.zig`  | Pure cursor motions, word/WORD rules, find-char, `%`, text objects. |
| `register.zig`| Vim registers (named/unnamed, linewise flag) for yank/delete/paste. |
| `undo.zig`    | Undo/redo as capped buffer snapshots. |
| `regex.zig`   | Regex engine: Pike VM (Thompson NFA), linear time, captures; modern "very magic" syntax. |
| `search.zig`  | Buffer search (`/ ? n N * #`): regex-powered, with a whole-source SIMD fast path for literal patterns while the buffer is unedited. |
| `theme.zig`   | Colour palettes (Tokyo Night default + Gruvbox/Catppuccin/Nord/One Dark), the active-theme global, 24-bit SGR helpers. |
| `config.zig`  | The single documented config file (`~/.config/zedit/config`): parse, apply, standard path, `--init-config` default text. |
| `syntax.zig`  | Dependency-free per-line lexer producing per-byte styles. |
| `fuzzy.zig`   | Subsequence scorer for the pickers. |
| `git.zig`     | Git change signs for the gutter (parses `git diff -U0`). |
| `snippet.zig` | LSP snippet parsing: `$1`, `${1:placeholder}`, `${1|a,b|}`, `$0`, escapes → plain text + tabstops. |
| `recent.zig`  | The recently-opened list behind the startup screen (XDG state file). |
| `remote.zig`  | Editing over SSH: `ssh://user@host/path` parsing, read/write/list via one `ssh` per operation. |
| `lsp.zig`     | Minimal LSP client: JSON-RPC over a server's stdio (diagnostics, hover, goto, completion, signature help; incremental or full doc sync per the server's capabilities). |
| `treesitter.zig` | Tree-sitter highlighting via the vendored C runtime + grammar (incremental parse, visible-range `highlights.scm` query, compiled queries shared process-wide). |
| `editor.zig`  | State, the vim command interpreter, multiple cursors, multiple buffers + windows (splits), pickers, LSP, tree-sitter, viewport, themed rendering. |

Vendored C lives under `vendor/` (`tree-sitter/` runtime, plus `tree-sitter-zig`,
`-c`, `-python`, `-json`, `-javascript`, `-typescript`, `-rust`, `-go`, `-html`, `-markdown` (block + inline) grammars, each with
`parser.c`, an optional `scanner.c`, and `highlights.scm`); `build.zig` compiles
them with `-D_GNU_SOURCE` and links libc. Adding a grammar is one entry in the
`grammars` list in `build.zig` plus a case in `treesitter.zig` (TypeScript keeps
its grammar under `typescript/` with a sibling `common/scanner.h`, and its query
layers on JavaScript's).

The pure, error-prone logic (motions, search) lives in its own unit-tested
modules; `editor.zig` is the stateful orchestrator (mode machine, operators,
registers, undo, visual, macros, marks, dot-repeat, rendering).

Data flow: `term` reads bytes → `key` decodes them → `editor` mutates `buffer`
and renders a frame back through `term`. `unicode` is shared by `buffer` and
`editor`; `log` is used everywhere.

## Build, test, run

```sh
zig build                       # debug build -> zig-out/bin/zedit
zig build -Doptimize=ReleaseFast
zig build run -- [file]         # run the editor
zig build test                  # unit tests (pure logic; no tty needed)
zig build itest                 # pty integration tests (drives the built editor)
zig build bench -Doptimize=ReleaseFast   # benchmark vs helix/nvim (if installed)
```

CI runs `zig build test` + `zig build itest` on every push
(`.github/workflows/ci.yml`); pushing a `v*` tag cross-compiles stripped
ReleaseFast binaries for Linux x86_64/aarch64 (static musl) and macOS
x86_64/aarch64 and attaches them to a GitHub release (`release.yml`).

Compiling a grammar's `highlights.scm` costs 3–14 ms, so the compiled queries
are cached per grammar for the life of the process (`query_cache` in
`treesitter.zig`) and shared by every buffer and the picker preview — opening
ten files of one language compiles its query once, not ten times.

Build times: the vendored tree-sitter C (19 translation units) is compiled
**once** into a static library that every artifact links — attaching the C
sources to each module instead made `zig build test` re-pay the whole C build
(measured on 8 cores: cold build 3.13 s → 2.86 s, `zig build test` 2.80 s →
1.38 s, parser objects 22 → 11). Keep it that way when adding grammars: they
go on `ts_mod`, not on a consumer module. On Apple Silicon the same C compile
dominates a cold build, so also check that Zig itself is the native aarch64
build (an x86_64 Zig runs under Rosetta and is several times slower), and that
`.zig-cache` sits on a local APFS volume excluded from Spotlight/antivirus
scanning rather than in iCloud Drive or on a network share.

`zig build` also installs the man page to `zig-out/share/man/man1/zedit.1`
(source: `doc/zedit.1`); view it with `man ./doc/zedit.1`.

Interactive behaviour can't be unit-tested without a terminal, so integration
checks live in `tools/` and drive the built editor through a real pseudo-terminal
(all Zig — no runtime or test-time dependency beyond the toolchain). `zig build
itest` builds `zedit` plus a `mock_lsp` server, then runs the `itest` harness:

- `tools/harness.zig` — the pty harness (`Session.spawn`/`drain`/`send`, output
  capture + ANSI stripping, temp dirs, file helpers, `/proc` CPU sampling).
- `tools/mock_lsp.zig` — a stub language server for the LSP scenario.
- `tools/itest.zig` — the runner; `tools/scenarios/*.zig` are the suites (vim,
  vim_compat, feature, multicursor, extra, search, treesitter, picker, git,
  windows, sidebar, config, cmdline, robust, ssh, remote, lsp, cpu), each a
  `pub fn run(ctx: *harness.Ctx) !void`.
  `vim_compat` asserts byte-for-byte agreement with expected outputs generated
  by driving real Neovim headlessly — extend it the same way when porting more
  upstream behaviours (ask nvim, not memory).
- `tools/bench.zig` — `zig build bench -Doptimize=ReleaseFast` compares zedit
  with helix/nvim (if on PATH) through real ptys: startup, 10 MB file open,
  keypress latency, picker-open (cold/warm).

The editor itself has no runtime dependencies.

## Editor usage

Modal, vi-like, with a comprehensive vim keymap. A command is `[count]` then
either a motion (move) or `[register]` `operator` `[count]` motion/text-object.

- **Motions:** `h j k l`, `w W b B e E`, `0 ^ $`, `gg G {n}G`, `f F t T` + `; ,`,
  `%`, `{ }` (paragraph, jump motions), `H M L`, `Ctrl-d/u/f/b`,
  arrows/Home/End/PageUp/Down. The normal-mode cursor never sits past the
  last character (vim's rule), so `$x`/`$dh`/`$d{` act on it. A jump landing
  more than half a window away redraws with the cursor **centred** (vim's rule,
  nvim-verified) — so it is not glued to the bottom row where every wheel notch
  would drag it along. The mouse wheel
  scrolls the viewport 3 lines and carries the cursor with it, keeping its
  screen row (owner's choice over nvim's drag-at-the-edge rule, which stranded
  the cursor at the bottom of the page; at the top or bottom of the file
  nothing moves at all). SGR mouse reporting, wheel only — clicks are ignored,
  and text selection still works with the terminal's Shift+drag.
- **Operators:** `d` `c` `y`, `> <` (indent), doubled `dd cc yy >> <<`; `D C Y`,
  `x X s S`, `r` `~` `J`. `cw`/`cW` act like `ce`/`cE`.
- **Text objects:** `iw aw iW aW`, `ip ap` (paragraph, linewise — `ap` takes
  the trailing blank lines, or the leading ones when nothing trails),
  `i( i[ i{ i< i" i' i\`` and `a…` variants (plus `b`/`B` aliases), e.g.
  `ciw`, `di"`, `da(`, `dap`. Objects work in visual mode too (`vip`, `vi(` —
  paragraph objects switch the selection to V-LINE, as vim does).
- **Registers/paste:** `"a` selects a register; `p`/`P` paste (linewise/charwise).
  `"+` / `"*` are the system clipboard: yanks there are sent to the terminal
  as OSC 52 (sets the local clipboard, even over SSH); pastes use the
  register's shadow copy. Terminal pastes arrive via bracketed paste and
  insert literally (no auto-pairs, single undo step; works in insert, normal,
  the command line and pickers).
- **Undo:** `u`, redo `Ctrl-r`. **Repeat:** `.` repeats the last change.
- **Visual:** `v` (char), `V` (line), `Ctrl-v` (block); move to extend, `o`
  swaps ends, then `d c y x > <`. In block mode `I`/`A` insert at the left/right
  edge of every selected line (via the multi-cursor machinery).
- **Search:** `/pat` `?pat` (incremental — jumps live as you type, `Esc`
  cancels and restores the cursor), `n N`, `*` `#` (whole-word, `\<word\>`).
  Matches are highlighted; wraps. Patterns are modern regexes (regex.zig:
  `. [..] * + ? ( ) | ^ $ \w \d \s \b \< \>` — Helix/ripgrep style, not
  vim's magic mode); a plain word behaves exactly as before.
- **Marks/macros:** `m{a-z}`, `` `{a-z} ``, `'{a-z}`; `q{a-z}…q` records, `@{a-z}`
  / `{n}@a` replays.
- **Jumplist:** `Ctrl-o` / `Ctrl-i` (also `Tab`) walk back/forward through
  jump-motions — `G`/`gg`/`{n}G`, `H M L`, `%`, committed searches (back to the
  origin), `n N * #`, mark jumps, `:{n}`, and every buffer switch (`:e`,
  `:bn/:bp`, pickers, `gd`). Entries are per position across buffers (capped at
  100, same-line entries replaced); closing a buffer purges its entries.
  Behaviour pinned to nvim ground truth in `vim_compat`.
- **Insert:** `i I a A o O` (and `c`/`s` entries), `Esc` to normal. Auto-pairs:
  typing an opener inserts its closer; typing the closer steps over it.
  Autoindent (config `autoindent`, on by default): `o`/`O`/Enter/`cc` inherit
  the current line's leading whitespace, and an auto-indent left blank is
  stripped on leaving the line (vim's rule; nvim-verified in `vim_compat`).
- **Built-ins (no plugins):** `gcc` / `gc{motion}` comment toggling, auto-pairs.
- **Surround:** `ys{motion}{char}` (e.g. `ysiw)`), `cs{old}{new}` (e.g. `cs"'`),
  `ds{char}`, `yss{char}` for the whole line, and `S{char}` in visual mode.
- **Multiple cursors:** `Ctrl-n` / `Ctrl-p` add a caret on the line below/above
  (one per line); movement, `x`, and `i`/`a`/`I`/`A` + typing apply to every
  caret; `Esc` collapses back to one.
- **Pickers (AstroNvim-style leader tree, leader = `Space`):** pressing `Space`
  shows a which-key popup with nested groups (submenus get their own popup):
  `Space f` = Find (`f f` files, `f w` words/grep, `f b` buffers, `f t`
  themes); `Space l` = Language tools (`l a` code action, `l r` rename, `l R`
  references, `l s` document symbols, `l d` line diagnostic, `l f` format);
  `Space g` = Git (`g d` inline diff,
  `g s` side-by-side); `Space e` file explorer, `Space c` close buffer,
  `Space w` write, `Space q` quit. In a picker: type to filter, `Ctrl-n`/`Ctrl-p` or
  arrows to move, `Enter` to open, `Esc` to cancel, and `Ctrl-r` re-walks the
  project (the file list is cached per session — the Zed-style warm picker:
  opening does no filesystem work after the first walk, candidates are
  prefiltered with per-path char bitmasks, and extending the query narrows the
  previous result set instead of rescoring everything).
  Every picker uses one layout: the file tree on its side (when open), the
  results next to it, and — for pickers that name a file (`f f`, `f b`,
  `f w`, references) — a **live preview** of the selection on the right,
  tree-sitter highlighted and scrolled to the matching line. `Ctrl-d` /
  `Ctrl-u` and the mouse wheel scroll the preview itself (it stops at the end
  of the file), independently of the selection. `zedit <dir>` opens
  straight into that view (tree + search + preview), which is what an empty
  session shows instead of a blank buffer. The preview is skipped for remote
  entries (an ssh round trip per keystroke) and on narrow terminals, where the
  results take the full width.
  Note the three search scopes: `/` searches the current buffer, `Space f w`
  searches file *contents* across the project, `Space f f` matches file *names*.
- **Command line:** `:w` write, `:q` quit (closes the window if more than one;
  blocked if unsaved on the last), `:wq`/`:x`, `:q!`, `:qa` quit all (refuses
  while any buffer is dirty — nvim's E37, nvim-verified; `:qa!` discards),
  `:wa` write all dirty buffers (failed saves are named, never silent),
  `:w <name>`, `:format` LSP-format the document,
  `:{number}` goto line, `:$`; `ZZ`/`ZQ`. **Tab completion** (nvim
  `wildmode=full` semantics, pinned by pty probes of the real thing): Tab
  completes command names, `:e`/`:w` file paths (a unique directory gets a
  trailing `/` and the next Tab descends into it; hidden files only offered
  when the prefix starts with `.`) and `:theme` names; multiple matches show a
  vertical popup and Tab/Shift-Tab cycle the ring [matches…, original text]; a
  unique match completes silently. **History** (nvim-verified in
  `vim_compat`): `:` and `/ ?` keep separate 100-entry histories; Up/Down
  recall entries filtered by the typed prefix (edits keep the browse position,
  updating the filter), Down past the newest restores the typed line,
  `Ctrl-p`/`Ctrl-n` recall unfiltered, duplicates move to newest, and an
  Esc-abandoned line is remembered too (vim's rule).
- **Sidebar (`Space e`):** a file-tree of the cwd on the configured side
  (config `sidebar = left|right`), which carves its width off the window
  tiling. Focused keys: `j`/`k` move, `Enter`/`l` expand a directory or open a
  file (focus returns to the buffer), `h` collapse/parent, `g`/`G` top/bottom,
  `R` refresh, `Space` opens the leader menu (it works the same with the tree
  focused), `Esc` unfocus (stays open), `q` or `Space e` close. Hidden and
  ignored directories (`.git`, `zig-out`, …) are skipped, like the picker.
- **Git diff views:** `Space g d` / `:diff` opens the file's unified diff
  (worktree vs index) in a horizontal split, coloured by the `.diff` lexer
  (`+` green, `-` red, `@@` hunk headers); `Space g s` / `:vdiff` opens the
  index version side by side in a vertical split with normal syntax
  highlighting — the same base the gutter signs compare against — and both
  panes tint changed/added/removed lines vimdiff-style (25% of the git
  add/change/delete colour blended into the theme background via `mixColor`;
  the index pane carries old-side signs from `git.computeOldSide`). Both are
  named scratch buffers (`[diff] name`, `name (index)`) closable with
  `:close`/`Space c`.
- **Startup screen:** launched with no file, zedit shows the recently-opened
  list (files and directories, newest first) with the leaf name first and the
  location dimmed and middle-elided. `j`/`k` or arrows select, `Enter` opens,
  `1`-`9` jump straight to an entry, `q` quits; any other key dismisses the
  screen and acts normally. The list lives in `$XDG_STATE_HOME/zedit/recent`
  (`~/.local/state/zedit/recent`), capped at 30, de-duplicated, and entries
  whose local path has disappeared are pruned on load (`recent.zig`).
- **Remote editing (SSH):** `zedit ssh://[user@]host[:port]/path` — or `:e
  ssh://…`, or `:ssh [user@]host[/dir]` from inside the editor — edits files on
  another machine with no agent installed there (unlike VS Code Remote-SSH):
  each operation is one `ssh` invocation (`cat` to read, `cat >` to write,
  `find` to list a directory for the picker). Remote paths are single-quoted
  for the remote shell (`remote.shellQuote`), `BatchMode=yes` means a missing
  key fails fast instead of hanging on a prompt, and `ControlMaster` reuses one
  connection per session. A remote directory opens the file picker over it;
  `:w` writes back to the same URL.
- **Update check:** `:update` (or `--check-update`) compares this build with
  the newest `v*` release tag via one `git ls-remote`. On demand only — zedit
  never contacts the network by itself.
- **Buffer tabs:** open files appear as tabs across the top (active
  highlighted, unsaved marked with `●`), shown only when more than one is open
  so a single-file session keeps every row. **Clicking a tab** switches to that
  buffer; clicks anywhere else are ignored so the terminal's own text selection
  keeps working. Config `buffer_tabs = false` turns them off.
- **Buffers & windows:** several files can be open at once, each with its own
  cursor, undo, tree-sitter and LSP. `:e <file>` opens (or, in the picker,
  `Enter`) a file in the active window — already-open files are reused, not
  reloaded. `:bn`/`:bp` cycle the active window through buffers, `:bd` closes
  one, `:ls` lists them. Split the view with `:split`/`:vsplit` (or `Ctrl-w s`/
  `Ctrl-w v`), move focus with `Ctrl-w w`/`h`/`j`/`k`/`l`, and `:close`/`Ctrl-w
  c` / `:only` manage them. Splits tile evenly in one orientation; each window
  shows any buffer (the same buffer can be open in two windows). Per-window
  status lines appear when more than one window is open.
- **LSP:** a language server is launched per filetype (`zls`, `clangd`, `pylsp`,
  `typescript-language-server`), or any command via `--lsp`. Diagnostics show as
  gutter signs + a statusline message/count; `K` hovers (`Ctrl-k` in insert
  mode), `gd` goes to definition, `gi` to the implementation, `gy` to the type
  definition, `gr` renames the symbol under the cursor
  (prompts on the command line, pre-filled with the identifier), `Space l R`
  lists references in a picker ("path:line: text", Enter jumps there), `ga`
  lists code actions for the current line in a picker and applies the chosen
  one, and `]d`/`[d` jump to the next/previous diagnostic line (wrapping;
  `[count]` repeats). Each diagnostic's message also renders inline at the end
  of its line as dim, severity-coloured virtual text (config
  `inline_diagnostics`, default on; errors red, warnings yellow, info/hints in
  the comment colour) — so every problem on screen is visible at once, not just
  the cursor's line. WorkspaceEdits (rename, code actions, server-initiated
  applyEdit) apply to **every** file they touch — the active buffer as one
  undoable change, other open buffers in place, unopened files loaded into
  background buffers (left dirty; `:wa` saves them) — and edits may be
  multi-line (a whole-document formatting edit with the end one past the last
  line is clamped). `Space l f` / `:format` request LSP formatting, and
  `format_on_save = true` (config, default on) formats before every `:w` with
  a bounded ~1s wait, skipped when the server doesn't advertise formatting. Inlay hints (type/parameter annotations) render
  inline as dim virtual text — requested for the document on load and after each
  edit, drawn without touching the buffer (the cursor's screen column accounts
  for hints to its left). Completion pops up on its own while typing an identifier — the debounce
  (config `completion_delay_ms`, 150 ms) is the only timer zedit ever arms, and
  it is armed *only* while typing, so an idle editor still blocks in `poll(2)`
  at zero CPU; `auto_completion = false` restores manual-only behaviour.
  `Ctrl-n` requests it on demand either way (popup: `Ctrl-n`/`Ctrl-p` or
  arrows to move, `Tab`/`Enter` to accept, `Esc` to dismiss). The list is
  filtered **fuzzily** and ranked with the pickers' scorer (`fuzzy.zig`), so
  `mplt` finds `mockComplete`. Accepting an item honours the server's own
  `textEdit` range (rather than guessing the identifier prefix) and applies any
  `additionalTextEdits` (auto-imports). **Snippets** (`insertTextFormat: 2`,
  which zedit now advertises support for) expand their placeholders and start a
  tabstop session: `Tab`/`Shift-Tab` walk the stops, the first keystroke at an
  untouched placeholder replaces it, and `Esc` leaves the text as ordinary
  content (`snippet.zig` does the parsing). Typing `(` or `,`
  in insert mode requests signature help, shown as a one-line popup above the
  cursor with the active parameter emphasized (`Ctrl-p` cycles overloads, with
  an `(i/n)` counter; dismissed with `Esc`). Edits are sent as incremental
  `didChange` ranges when the server advertises it, else full-document.
  Best-effort: no server installed simply means no LSP. Its stdout is polled
  alongside the terminal, so an idle editor still uses no CPU.

## Appearance

The renderer aims for an AstroNvim/Helix look: true-colour themes in
`theme.zig` (Tokyo Night default, plus Gruvbox, Catppuccin Mocha, Nord and One
Dark — set in the config, or live via `:theme` / the `Space f t` picker), a
powerline statusline (coloured mode block, separators, the command as typed
right-aligned beside the position — vim's 'showcmd', but the finished command
stays readable until the next one starts, and yields its width to a status
message — plus file/filetype/position/percent segments — a nerd font is recommended for the
glyphs, and the config's `nerd_font = false` swaps in a flat statusline for
any font), syntax highlighting (tree-sitter for 10 languages (Zig/C/Python/JSON/JS/TS/Rust/Go/HTML/Markdown) via
`treesitter.zig`, the `syntax.zig` lexer otherwise), relative+absolute line numbers, a
cursorline, indent guides, and a git change gutter (add/change/delete signs
from `git diff`, recomputed on load and save). All colour is emitted as 24-bit
SGR; the frame is still built once and written in a single syscall, and
rendering still only happens on change. Frames are built as positioned,
colour-independent row segments and diffed against the previous frame — only
changed rows are written. A popup is painted over rows the diff cannot know
about, so those rows — and only those — are invalidated for the next frame:
dismissing the which-key menu costs ~1.5 KB instead of a full 3.2 KB repaint.
Full frames are still written in the picker and after a resize, which keeps
slow SSH links snappy. Input reads complete
escape sequences split across chunks (SSH delivers small reads) before
decoding.

Runtime configuration is one documented file (see `config.zig`): theme,
`tab_width`, `nerd_font`, `sidebar` (left/right), `relative_numbers`,
`large_file_mb`, `autoindent`, `buffer_tabs`, `auto_completion`,
`completion_delay_ms`, `inline_diagnostics`, `format_on_save`; `zedit --init-config` writes
the annotated default.
`zedit --tutor` opens the embedded interactive tutorial (`doc/tutor.txt`,
embedded via `build.zig`).

Tabs are stored verbatim and rendered at `tab_width` (currently 4) in
`editor.zig`.

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
- Large-file performance: loading is zero-copy with copy-on-write lines
  (`buffer.zig`, 2 GB cap), and above the config's `large_file_mb` (64 MB
  default) highlighting/LSP/git signs are skipped ("large-file mode"). A
  476 MB / 10M-line file opens in ~375 ms and `/`-searches in ~196 ms (nvim:
  103/217, helix: 459/1753). nvim still opens faster via lazy line indexing —
  adopt that (or a rope) only if it matters in practice.
- A resize landing in the tiny window between the resize check and entering
  `poll` is noticed on the next keypress (a self-pipe would close the race).
- Vim gaps: paragraph objects/motions treat only truly empty lines as
  boundaries (vim's rule; `nroff`-style paragraph macros in `'paragraphs'`
  aren't supported), and there are no sentence objects (`is`/`as`, `(`/`)`).
  The trickier dot-repeat/macro interactions are not (fully)
  implemented; autoindent is vim's 'autoindent' only (no smartindent/
  tree-sitter indent queries). Cmdline completion covers command names,
  `:e`/`:w` paths and `:theme` (not every command's arguments), and the
  wildmenu's special file-navigation keys (Down = enter directory, Up = parent
  directory while the popup is open) are not implemented — Up/Down are always
  history. The cmdline cursor is end-of-line only (no `Left`/`Right` editing
  within the line). In-buffer search/`:s` are regex, but the syntax is
  modern ("very magic"-like), not vim's magic mode — `\(` groups etc. differ.
- Highlighting is a per-line lexer (no cross-line block comments; a handful of
  languages). Tree-sitter is the upgrade path now that deps are allowed.
- Multi-cursor is one-caret-per-line (column editing); it does not do
  per-caret line splits/joins or arbitrary selection-based multi-edit.
- The project-wide grep picker is literal, not regex (in-buffer search is regex). Statusline separators assume a nerd font.
- Windows/splits use a flat even tiling in one orientation at a time (a split
  re-tiles all windows; no nested/mixed layouts or per-window resizing). Only
  the active window has live LSP polling and an editable selection/search/inlay
  overlay; inactive windows render from their cached state.
- Block paste of a blockwise yank is charwise (not a true rectangular paste);
  block `A` on lines shorter than the block does not pad with spaces.
- LSP does diagnostics/hover/goto/references/completion/signature help/rename/
  code actions/formatting/inlay hints/document symbols with incremental (or
  full) document sync, including `textEdit`/`additionalTextEdits` completions
  and snippet expansion. Snippet tabstops track edits as you type: stops later
  on the line shift by what an edit adds or removes, and a line split (Enter)
  or join (backspace at column 0) moves the later stops with the text — only a
  multi-line paste, which the simple model cannot follow, ends the session.
  `${1|a,b,c|}` inserts the first alternative and offers the rest on
  `Ctrl-n`/`Ctrl-p` (the statusline lists them); nested placeholders are
  flattened to their text, and variables (`$TM_FILENAME`) resolve to their
  default or to nothing. Snippet text is remote input, so brace nesting is depth-capped
  (a hostile server cannot recurse the parser into a stack overflow) and the
  expanded text passes through the render sanitizer like any other content. Document symbols
  are flattened (nested `DocumentSymbol[]` or flat `SymbolInformation[]`) into a
  picker that jumps to the selected symbol. Inlay hints are
  requested for the whole document (re-requested per edit, not debounced) and
  rendered inline; horizontal-scroll interaction with hints is approximate.
  WorkspaceEdits apply across files and support multi-line edits; document
  create/rename/delete operations in `documentChanges` are skipped, and
  references are capped at 1000. The references picker shows line text only for
  files already open in a buffer. Formatting sends `tabSize` = config
  `tab_width`, `insertSpaces = true`; format-on-save is a bounded synchronous
  wait (~1s), gated on the server advertising `documentFormattingProvider` —
  there is no external (non-LSP) formatter support.
  Code actions are requested for the current line with an empty diagnostics
  context (diagnostic ranges aren't stored); command-based actions run via
  `workspace/executeCommand`, and a server-initiated `workspace/applyEdit` is
  applied (and answered).
  Signature help triggers on `(`/`,`; `Ctrl-p` cycles overloads when the server
  returns several.
- Tree-sitter highlighting is wired for Zig, C, Python, JSON, JavaScript, TypeScript, Rust,
  Go, HTML and Markdown (the vendored grammars); other files use the lexer. Parsing is incremental (the prior
  tree is reused via a prefix/suffix diff) and the highlight query runs only over the
  visible byte range (re-run on edit or scroll), so per-keystroke work is
  O(screen) not O(document). Query predicates (`#match?`/`#eq?`) are not
  evaluated. Full tree-sitter injections aren't implemented; Markdown instead
  uses two highlight layers (block grammar + inline grammar, the latter filling
  bytes the block layer left plain), and HTML doesn't highlight embedded JS/CSS.
  Adding a grammar = vendor its `parser.c` + `highlights.scm` and extend
  `treesitter.zig`.
- The picker preview is a glance, not a view: capped at 256 KB per file,
  tree-sitter only up to 64 KB (the lexer covers bigger files), and skipped for
  remote entries. The parse happens *after* the picker's first frame, so
  opening it stays fast; previewing a language whose grammar has not been
  compiled yet costs a one-off 3–14 ms on the following frame. The tabline
  lists buffers in open order with no reordering, and mouse support is still
  wheel + tabline clicks only (no click-to-move-cursor or drag selection).
- The sidebar tree is flat-file only (no rename/create/delete operations from
  the tree), rebuilt on expand/toggle rather than watched; the side-by-side
  diff tints changed lines in both panes but has no aligned filler lines or
  synced scrolling like vimdiff. The inline diff buffer is a static snapshot.
  Mouse support is wheel-scrolling only (no click-to-move or drag selection),
  and the wheel scrolls the focused window, not the one under the pointer.
- Remote editing is whole-file over ssh: every read/write moves the entire file
  (no partial or incremental transfer), there is no remote LSP/tree-sitter
  beyond what the local process computes on the fetched text, no remote git
  signs, and no remote sidebar. Writes are `cat >` (not atomic — a failed
  transfer can truncate; a temp-file-plus-rename upgrade is the fix if it
  matters). `BatchMode=yes` means password-only hosts fail instead of
  prompting: use keys or an agent. The update check reads tags from a
  hard-coded release URL.
- Roadmap (agreed with the owner): port further tranches of Neovim behavioural
  tests via headless ground truth (see `vim_compat`), and work down
  `doc/COMPARISON.md` — the verified feature-gap analysis vs Helix/Neovim
  (shortlist: regex + `:%s`, jumplist, OSC 52 clipboard, autoindent, LSP
  references/formatting/cross-file edits, cmdline completion + history, and
  paragraph objects/motions, inline diagnostics, auto/fuzzy completion and
  snippets — the whole shortlist is now done). `TODO.md` tracks what is next. Large-file open is
  14.3 ms vs nvim's 10.7 (was 36.6) after the copy-on-write buffer; the last
  ~4 ms is the eager read+scan nvim defers — mmap or lazy line indexing if it
  ever matters.

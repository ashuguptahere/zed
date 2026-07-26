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
5. **YAGNI, thoroughly and heavily.** Build features when they reach the
   roadmap, never speculatively. Concretely: no abstraction until it has two
   real callers (a second *imagined* caller does not count); no config knob,
   parameter, or field that nothing sets; no pub that only re-exports; no
   wrapper that only delegates; delete dead code the moment it stops earning
   its place rather than keeping it "in case". Prefer an algorithm or a
   closed-form computation over a loop, and a `std` call over hand-rolled
   code. The 2026-07 repo-wide audit removed 722 lines of exactly these —
   treat its findings as precedent, and sweep again periodically.
6. **No feature without a test. No exceptions.** A change to behaviour that
   lands without a test in the *same commit* is not finished, however obvious
   it looks. Concretely:
   - Pure logic (motions, search, regex, undo, snippets, config) gets a unit
     test in its own module; anything interactive gets a pty scenario under
     `tools/scenarios/`.
   - Vim behaviour is pinned to **real nvim**, driven through a pty — never
     from memory, and never through `-c` arguments, which join undo blocks and
     hide exactly what is under test.
   - **Every new config setting** gets a test that the key actually does
     something. `config.zig`'s completeness test walks `Settings` at comptime
     and fails if a field is missing from the annotated default text or is not
     read by the parser, so those two can never be forgotten again.
   - After writing a test, **check that it fails without the fix** (stash the
     change, or plant the old behaviour back). A test that passes either way
     proves nothing.
7. **Every feature ships with the rest of its checklist** — the docs sweep
   (README/CLAUDE.md/man/tutor/COMPARISON/CHANGELOG), a `VERSION` bump, a
   `TODO.md` update, and for anything perf- or input-relevant: a security
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
- **Never block the first frame on work the user did not ask for.** The file
  is read in two phases (`Buffer.loadPartial` reads a 256 KB head, the run
  loop pulls the tail in after the first paint), and the project walk behind
  the picker runs in ~2 ms slices between loop iterations, streaming results
  into an already-visible picker. Measured: first paint on an 8.2 MB file
  2.9 ms (nvim 3.8 ms), picker visible on a 20k-file tree in 0.5 ms (helix
  1.1 s). Neither uses a thread — the loop simply keeps a zero timeout while
  work remains and returns to blocking in `poll(2)` when it is done, so an
  idle editor still costs nothing.
- **Paint first, decorate after.** Nothing that merely *annotates* the text may
  sit between launch and the first frame — nor between `:e` and *its* first
  frame, which is the same rule applied to every later open (`decorate_pending`
  in `editor.zig`; opening a 300 KB source file went from 34 ms to 0.6 ms to
  first paint): syntax highlighting, git signs and
  the LSP handshake all run after the initial paint, and a second frame brings
  them in. This took first paint on a 320 KB source file from 48 ms to 0 ms.
  Benchmarks therefore report first paint *and* settled time — a settle-only
  metric punishes progressive rendering.
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
- **Few allocations, pooled and reused.** Hot paths allocate as little as
  possible and reuse what they have, in the spirit of Ghostty's terminal
  buffers: the picker keeps all row text in one byte arena addressed by
  `u32` offsets (`PickItem` is 20 bytes, not two slices), rows are formatted
  into stack buffers rather than `allocPrint`, closing a picker *retains*
  capacity instead of freeing, and compiled tree-sitter queries are shared
  process-wide. Measured on a 4000-file tree: −22% peak RSS across picker
  cycles and a faster filter. Prefer "clear and reuse" over "free and
  reallocate", and keep per-item allocations out of loops that can run
  thousands of times.
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
- **Versioned + changelogged, every single change.** The `VERSION` file is the
  single source of truth (embedded into `--version` at build time). Bump it and
  add the `CHANGELOG.md` section **in the same commit as the code** — a commit
  that changes behaviour and leaves `VERSION` alone is incomplete.
  `build.zig.zon`'s `.version` carries a copy for package metadata, and the
  build **enforces** the pair: a comptime check in `build.zig` reads both
  files and fails the build with a clear message when they disagree — bump
  them together. Semantic
  `MAJOR.MINOR.PATCH`, with one standing rule from the owner:
  - **MAJOR stays 0.** Do not release 1.0.0 until the owner says so.
  - **MINOR** for anything a user would notice: a feature, a new key or
    command, a changed default, a behavioural fix (`0.4.0` → `0.5.0`).
  - **PATCH** for what a user would not: internal fixes, performance,
    refactors, docs, tests, tooling (`0.5.0` → `0.5.1`).
  - One version per commit, and the `CHANGELOG.md` heading (`## X.Y.Z - date`)
    goes above the previous one with the entries filed under `### Added`,
    `### Changed`, `### Fixed`, `### Performance` or `### Security`.
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
| `buffer.zig`  | The document: two-phase zero-copy load (`loadPartial` indexes a head so the screen can paint, `loadRest` fills the tail), a lazy `u32` line index over one shared buffer, per-line storage materialised on the first edit, save, UTF-8-aware edits. |
| `motion.zig`  | Pure cursor motions, word/WORD rules, find-char, `%`, text objects. |
| `register.zig`| Vim registers (named/unnamed, linewise flag) for yank/delete/paste. |
| `undo.zig`    | Undo history as a tree of edits — each state the diff from its parent (branches, `g-`/`g+`, `:earlier`/`:later`), optionally kept on disk. |
| `regex.zig`   | Regex engine: Pike VM (Thompson NFA), linear time, captures; modern "very magic" syntax. |
| `search.zig`  | Buffer search (`/ ? n N * #`): regex-powered, with a whole-source SIMD memmem fast path for literal patterns while the buffer is unedited. |
| `theme.zig`   | Colour palettes (Tokyo Night default + Gruvbox/Catppuccin/Nord/One Dark), the active-theme global, 24-bit SGR helpers. |
| `config.zig`  | The single documented config file (`~/.config/zedit/config`): parse, apply, standard path, `--init-config` default text. |
| `syntax.zig`  | Dependency-free per-line lexer producing per-byte styles. |
| `fuzzy.zig`   | Subsequence scorer for the pickers. |
| `git.zig`     | Git change signs for the gutter (parses `git diff -U0`; skips the subprocess entirely outside a work tree). |
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

**Measure what a user waits for.** `waitQuiet` alone cannot time an editor:
it starts counting silence immediately, so anything slower to respond than the
quiet window scores as instant. Always require a first response before timing
the settle, and report cold and warm separately where a first operation builds
something.

**Measure in ReleaseFast.** `zig build test` and `zig build itest` reinstall
`zig-out/bin/zedit` as a *Debug* build, which is ~6x slower — rebuild with
`zig build -Doptimize=ReleaseFast` before any ad-hoc timing, or the numbers
are meaningless. (`zig build bench` builds its own ReleaseFast artifacts.)

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

- **Motions:** `h j k l`, `w W b B e E`, `0 ^ $`, `gg G {n}G`, `f F t T` + `; ,`
  (counted: `3fa` lands on the third, `d2fa` multiplies the counts),
  `%`, `{ }` (paragraph, jump motions), `H M L`, `Ctrl-d/u/f/b`,
  arrows/Home/End/PageUp/Down (arrows and `<BS>` take counts like
  `h j k l`; Home/End ignore them — nvim-probed). With soft wrap on, `gj`/`gk` step a *screen*
  row and `g0`/`g$` reach the ends of one, while `j`/`k`/`0`/`$` keep their
  buffer-line meaning (vim's split). `H M L`, `Ctrl-d/u/f/b` and the wheel all
  count screen rows, so they land where they look like they should on wrapped
  text. The normal-mode cursor never sits past the
  last character (vim's rule), so `$x`/`$dh`/`$d{` act on it. A jump landing
  more than half a window away redraws with the cursor **centred** (vim's rule,
  nvim-verified) — so it is not glued to the bottom row where every wheel notch
  would drag it along. The mouse wheel
  scrolls the viewport 3 lines and carries the cursor with it, keeping its
  screen row (owner's choice over nvim's drag-at-the-edge rule, which stranded
  the cursor at the bottom of the page; at the top or bottom of the file
  nothing moves at all). SGR mouse reporting: the wheel, tab clicks and
  explorer clicks act — in the picker view too (the `zedit .` startup;
  result rows select then open, see Pickers); every other mouse report —
  releases, right/middle buttons, drags — decodes to an inert key swallowed
  before command dispatch, so it can never reach showcmd or reset a pending
  operator or count the wheel would keep. Command and visual modes swallow
  clicks whole (a click must not cancel an operator). A plain click or drag
  in the text area stays unbound, and text selection still works with the
  terminal's Shift+drag (which bypasses mouse reporting entirely).
- **Operators:** `d` `c` `y`, `> <` (indent), doubled `dd cc yy >> <<`; `D C Y`,
  `x X s S`, `r` `~` `J`. `cw`/`cW` act like `ce`/`cE`.
- **Structural objects (tree-sitter):** `af`/`if` select a function (whole, or
  just its body), `ac`/`ic` a class/struct/impl/enum, `aa`/`ia` an argument or
  parameter (`aa` swallowing the comma that joins it to a neighbour — the one
  after it, or the one before it for the last item — so the list stays valid)
  and `aC`/`iC` a comment (`aC` extends over a run of comment lines at the same
  column and is linewise when the comment owns its lines; `iC` is the text
  without the delimiter), resolved from the
  syntax tree rather than by counting braces — so `daf`, `dif`, `yac`, `vif`
  work per the language's real grammar. `]f`/`[f` jump to the next/previous
  function (jump motions, so `Ctrl-o` returns). The node names come from the
  vendored grammars themselves; languages without a grammar simply have no
  such objects. `aa` reads the grammar's own list nodes (`argument_list`,
  `formal_parameters`, …) and takes whichever named child holds the cursor, so
  a nested call or a comma inside a string cannot fool it. The search prunes subtrees that cannot contain a match and
  returns at the first hit, comparing grammar symbol ids rather than type
  names — `]f` on a 320 KB file costs ~0.4 ms, against 12 ms for a naive
  full-tree walk.
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
- **Undo (a tree, not a line):** `u` and `Ctrl-r` step along the current
  branch, but a change made *after* an undo starts a new branch instead of
  discarding the old one. `g-`/`g+` (counts work: `3g-`) walk every state in
  the order it was made, across branches, which is how work stranded by an
  undo-then-edit is reached again; `:earlier`/`:later` do the same from the
  command line, taking a count, a span (`:earlier 10s`, `2m`, `1h`) or a
  number of file writes (`:earlier 1f` — "what I had when I last saved"), and
  clamping to the oldest/newest state rather than refusing. `:undolist` opens
  the states in a picker — current one marked, branch points flagged — and
  Enter jumps to the chosen one. With `persistent_undo` (config, off by
  default, vim's `undofile`) the tree is written to
  `$XDG_STATE_HOME/zedit/undo` on every save and picked up when the file is
  next opened, so `u` still reaches yesterday's changes; each write also
  prunes sibling undo files untouched for 90 days (logged), so the state
  directory cannot grow forever. **"Modified" is undo-state identity**, not
  a touched-flag: every history move recomputes the buffer's dirty flag as
  "current state ≠ the state at the last write" (`History.last_saved`,
  vim's `b_u_save_nr`) — so undoing back to what is on disk lets `:q` exit,
  undoing *past* the write stays modified even when the text matches, and
  retyping identical text by hand stays modified too (identity, not
  content; all four cases nvim-pinned). `:wa` marks every written buffer's
  state; a pruned saved state means travel stays conservatively dirty until
  the next write. All nvim-verified in
  `vim_compat`.
  **Repeat:** `.` repeats the last change.
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
  `Space b` = Buffers (`b b` the buffer picker — same as `f b` — `b n`/`b p`
  next/previous, `b c` close — same as `Space c`);
  `Space f` = Find (`f f` files, `f w` words/grep, `f b` buffers, `f t`
  themes); `Space l` = Language tools (`l a` code action, `l r` rename, `l R`
  references, `l s` document symbols, `l S` workspace symbols, `l d` line
  diagnostic, `l D` all diagnostics, `l f` format);
  `Space g` = Git (`g d` inline diff,
  `g s` side-by-side, `g l` line diff); `Space e` file explorer, `Space c` close buffer,
  `Space w` write, `Space q` quit. In a picker: type to filter, `Ctrl-n`/`Ctrl-p` or
  arrows to move, `Enter` to open, `Esc` to cancel, and `Ctrl-r` re-walks the
  project (the file list is cached per session — the Zed-style warm picker:
  opening does no filesystem work after the first walk, candidates are
  prefiltered with per-path char bitmasks, and extending the query narrows the
  previous result set instead of rescoring everything — the grep picker narrows
  the same way, filtering the hits it already has rather than re-reading every
  file, so a keystroke costs 4 µs once the scan has covered the project).
  Every picker uses one layout: the title bar on row 1 (when enabled), the
  file tree on its side (when open), the prompt and
  results next to it (selected row on the theme's `ui_sel` background), and —
  for pickers that name a file (`f f`, `f b`,
  `f w`, references) — a **live preview** of the selection on the right,
  tree-sitter highlighted and scrolled to the matching line. `Ctrl-d` /
  `Ctrl-u` and the mouse wheel scroll the preview itself (it stops at the end
  of the file), independently of the selection. The mouse works in a picker
  too (`pickerClick`, sharing the renderer's geometry via `pickerLayout` —
  the tabline's draw-here-click-here invariant): a click on a result row
  selects it (the preview follows), a click on the already-selected row
  opens it — so a double-click opens from anywhere, with no double-click
  timer — while explorer rows toggle/open exactly as in normal mode (a
  file-open closes the picker first) and a tab click closes the picker and
  lands on that buffer; the prompt row and the preview stay inert, so
  terminal text selection keeps working there. `zedit <dir>` opens
  straight into that view (tree + search + preview), which is what an empty
  session shows instead of a blank buffer. The preview is skipped for remote
  entries (an ssh round trip per keystroke) and on narrow terminals, where the
  results take the full width.
  Note the three search scopes: `/` searches the current buffer, `Space f w`
  searches file *contents* across the project, `Space f f` matches file *names*.
  The grep picker takes the same modern regexes as `/` (case-sensitive,
  matched per line). A plain-string query keeps the literal fast path:
  indexOf matching, and extending it narrows the hits already on screen. A
  genuine regex is not a subset of its prefix, so each change means a full
  rescan (~35 ms on a zedit-sized tree, measured) — it runs through the shared
  typing-pause debounce (`due_kind = .grep`, the completion/wsymbol timer),
  keeping keystrokes at microseconds and idle CPU at zero. While the pattern
  is mid-typing invalid (a lone `(`, a trailing `\`), the last good results
  stay put and a dim `(incomplete)` tag sits beside the query.
- **Command line:** `:w` write, `:q` quit (closes the window if more than one;
  blocked if unsaved on the last), `:wq`/`:x`, `:q!`, `:qa` quit all (refuses
  while any buffer is dirty — nvim's E37, nvim-verified; `:qa!` discards),
  `:wa` write all dirty buffers (failed saves are named, never silent),
  `:w <name>` (naming a previously-unnamed buffer detects its filetype and
  starts highlighting + LSP on the spot), `:format` LSP-format the document,
  `:{number}` goto line, `:$`; `ZZ`/`ZQ`. **Tab completion** (nvim
  `wildmode=full` semantics, pinned by pty probes of the real thing): Tab
  completes command names, `:e`/`:w` file paths (a unique directory gets a
  trailing `/` and the next Tab descends into it; hidden files only offered
  when the prefix starts with `.`) and `:theme` names; multiple matches show a
  vertical popup and Tab/Shift-Tab cycle the ring [matches…, original text]
  (`Left`/`Right` select too, like nvim's wildmenu); a
  unique match completes silently. While a *path* popup is open, `Down`
  descends into the selected directory (re-completing inside it; on a file it
  just closes the popup) and `Up` re-completes in the parent directory —
  nvim's wildmenu file-navigation keys, pty-probed; with any other popup, or
  none, Up/Down stay history. **Mid-line editing** (nvim-pinned in
  `vim_compat`): the cmdline cursor moves with `Left`/`Right`,
  `Home`/`End` (vim's `Ctrl-b`/`Ctrl-e` too); typed and pasted text inserts
  at the cursor, backspace deletes before it (a no-op at column 0 of a
  non-empty line; an empty line still cancels), and history recall or wild
  cycling puts the cursor at end-of-line (vim's rule). **History**
  (nvim-verified in
  `vim_compat`): `:` and `/ ?` keep separate 100-entry histories; Up/Down
  recall entries filtered by the typed prefix (edits keep the browse position,
  updating the filter), Down past the newest restores the typed line,
  `Ctrl-p`/`Ctrl-n` recall unfiltered, duplicates move to newest, and an
  Esc-abandoned line is remembered too (vim's rule). **Inline suggestions**
  (fish-style, config `cmdline_suggestions`, on by default): while typing
  after `:` (or `/ ?`), the rest of the newest history entry strictly
  extending the typed text — else, for `:`, the first command name that
  does — shows as dim ghost text after the cursor; `Right`/`End` at
  end-of-line accepts it (mid-line they only move the cursor, and the ghost
  hides until the cursor is back at the end — fish's rule),
  every edit recomputes it, Enter always runs only the typed text, and the
  ghost hides while the wildmenu ring has the line. The rename prompt never
  ghosts (no history, and command names make no sense there). No filesystem
  I/O per keystroke (Tab completion covers paths) and no timers; the ghost is
  drawn dim (`fg_dim`) through the render sanitizer like any untrusted text.
- **Sidebar (`Space e`):** a file-tree of the cwd on the configured side
  (config `sidebar = left|right`), which carves its width off the window
  tiling. Its "EXPLORER" header lives in the title bar when that row is shown
  (drawn by the sidebar itself only when `buffer_tabs = false`); the selected
  row uses the theme's `ui_sel` background while focused and
  `mixColor(bg_dark, ui_sel, 50)` unfocused — never `cursorline`, which
  equals `bg_dark` in Nord and made the selection invisible. While the tree
  is open, every buffer switch **reveals** the active file: ancestor
  directories expand (relative to the cwd), the row is selected and scrolled
  into view; files outside the cwd (or remote/scratch) leave the tree alone.
  Focused keys: `j`/`k` move, `Enter`/`l` expand a directory or open a
  file (focus returns to the buffer), `h` collapse/parent, `g`/`G` top/bottom,
  `R` refresh, `Space` opens the leader menu (it works the same with the tree
  focused), `Esc` unfocus (stays open), `q` or `Space e` close. The tree is
  also **mouse-clickable** (no prior focus needed): a single click on a row
  selects it and acts exactly as Enter — a directory toggles, a file opens
  with focus back in the buffer (VS Code's rule) — while a click on the
  EXPLORER header or the empty space below the tree just focuses it; the
  hit-test and `renderSidebar` share one geometry source (`sb_tree_top` +
  `sbRows` + `sb_scroll`, the tabline invariant), so a row can never be
  drawn at one place and clicked at another. Hidden and
  ignored directories (`.git`, `zig-out`, …) are skipped, like the picker.
- **Git diff views:** `Space g d` / `:diff` opens the file's unified diff
  (worktree vs index) in a horizontal split, coloured by the `.diff` lexer
  (`+` green, `-` red, `@@` hunk headers) — a **read-only** scratch ("diff
  view is read-only"); `Space g s` / `:vdiff` opens the
  index version side by side in a vertical split with normal syntax
  highlighting — the same base the gutter signs compare against. Focus stays
  on the **worktree pane** (the file you edit); the index pane is a
  **read-only snapshot** (any mutating command answers "index snapshot is
  read-only" — so, like the diff scratch, it can never go dirty, block
  `:q`/`:qa`, or be written out with `:w <name>`). The panes are **row-aligned** through the diff's hunk
  pairs (`git.computeHunks`; one `git diff` feeds alignment and both panes'
  tint rows via `git.signsFromHunks`): where one side has lines the other
  lacks, the shorter side renders virtual **filler rows** — tinted git-add in
  the index pane, git-delete in the worktree pane, blank gutter, in no
  buffer, never under the cursor — so matching text sits level, VS Code
  style. Both panes **scroll in lockstep**: the unfocused pane's top is
  derived from the focused pane's top through the alignment map every frame
  (`syncDiffPanes`, which also pulls that pane's bookmarked cursor into the
  synced view so focusing it later never yanks the pair to a stale row), wheel
  and `Ctrl-d/u/f/b` included; crossing the pair with `Ctrl-w w` lands the
  cursor on the aligned row, and opening the view keeps the cursor where the
  user was. Soft wrap is forced
  off inside a visible pair (a wrapped line would break row alignment;
  horizontal scrolling still works there). Changed/added/removed lines tint
  vimdiff-style in both panes (25% of the git colour into the theme
  background via `mixColor`). A hunk whose deletion precedes line 1
  (`@@ -1,N +0,0 @@`, up to a total deletion) sits *above* buffer row 0 in
  display space, so a pane whose top is row 0 anchors at display row 0 —
  cursor-clamped (`paneDisplayTop`, shared by render, scroll, cursor row and
  `H`/`M`/`L`) — rather than hiding the old lines above the viewport.
  Pressing the key again — from either pane —
  **toggles the view closed** (windows and scratch doc both; `Space g d`
  toggles the inline diff the same way). Both toggles key on a *visible*
  window — a scratch left windowless by `:bn`/`:close` is destroyed and the
  view reopens, never a phantom "diff closed" — and a file with no changes
  reports "no changes" instead of opening a split. `Space g l` / `:ldiff` is
  the third view — VS Code/Zed's **line-by-line diff**, woven into the
  file's own window: no split, no scratch, no second buffer, just a
  rendering mode. Each hunk's old (deleted/changed-from) lines render as
  red-tinted virtual rows *above* the lines that replaced them (dim `-` in
  the gutter, no line number, sanitized text, clipped rather than wrapped,
  never under the cursor — `j`/`k`, `H`/`M`/`L` and scrolling step across
  real lines only, sharing the pair view's leading-gap clamp for a deletion
  before line 1), while added/changed lines keep their green/changed tint on
  their real rows; the buffer stays fully editable throughout. The old text
  comes from the same one `git diff -U0` the signs use (`git.LineDiff`
  retains the `-` bodies, and a `:w` refresh derives the signs from the
  weave's own hunks — one subprocess, not two). The weave is document
  state, so it shows in every window of the file (`:split` included) and
  survives `:bn`-and-back. Pressing the key again toggles the weave off.
  The three views are **exclusive per
  file**: opening one closes the others first, so they can never stack into a
  third window, and each split view re-tiles in its own orientation. All of
  them reflect the file as last saved, like the gutter signs; all refresh on
  `:w` (a weave with no changes left simply closes).
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
  each operation is one `ssh` invocation (`cat` to read, `cat` into a temp
  file renamed over the target to write — atomic, so a dropped connection
  can never leave a half-written file — and `find` to list a directory for
  the picker). Remote paths are single-quoted
  for the remote shell (`remote.shellQuote`), `BatchMode=yes` means a missing
  key fails fast instead of hanging on a prompt, and `ControlMaster` reuses one
  connection per session. A remote directory opens the file picker over it;
  `:w` writes back to the same URL.
- **Update check:** `:update` (or `--check-update`) compares this build with
  the newest `v*` release tag via one `git ls-remote`. On demand only — zedit
  never contacts the network by itself.
- **Title bar:** one powerline row across the top (config `buffer_tabs`,
  default on — always shown while enabled, VS Code-style, even for a single
  file): an "EXPLORER" segment spanning the sidebar's columns when it is open
  (accent bg while the tree has focus, else the statusline segment colours,
  ending in a powerline separator), then one tab per open buffer over the
  text area — the active tab an accent segment (`mode_normal` bg), inactive
  ones dim on `status_bg` with thin separators between them, unsaved marked
  with `●`. `nerd_font = false` degrades to the flat look (no separator
  glyphs, zero width budgeted for them). While the bar is up the filename
  leaves the statusline (see below). **Clicking a tab** switches to that
  buffer — the renderer and `tabAt` share one geometry helper (`tabArea` +
  `tabCells`), so a tab can never be drawn at one place and clicked at
  another; a click on the EXPLORER segment focuses the tree (see the
  sidebar bullet), and clicks anywhere else are ignored so the terminal's
  own text selection keeps working. `buffer_tabs = false`
  removes the row entirely and restores the statusline filename.
- **Buffers & windows:** several files can be open at once, each with its own
  cursor, undo, tree-sitter and LSP. `:e <file>` opens (or, in the picker,
  `Enter`) a file in the active window — already-open files are reused, not
  reloaded, and opening on top of an *untouched* `[No Name]` buffer (unnamed,
  unmodified, empty, shown in no other window) replaces it, vim's rule
  (nvim-verified) — a `zedit .` session does not keep its startup buffer in
  `:ls`. `:bn`/`:bp` and `]b`/`[b` cycle the active window through buffers
  (`]b` takes a count: `2]b` skips one), `:bd` closes
  one, `:ls` lists them. `:bd` on the *last* buffer replaces it with a fresh
  empty `[No Name]` and the window stays (vim's rule, nvim-verified — and
  that fresh buffer is adopted by the next `:e`, closing the cycle); a dirty
  buffer refuses with "no write since last change" (nvim's E89) unless
  forced with `:bd!`, which discards. `Space c` / `Space b c` route through
  the same close. Split the view with `:split`/`:vsplit` (or `Ctrl-w s`/
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
  lists references in a picker ("path:line: text", Enter jumps there),
  `Space l S` searches **workspace symbols** (the query goes to the server,
  which matches across files zedit has never opened; re-asked after the same
  typing pause auto-completion uses), `Space l D` lists **every diagnostic**
  across the open buffers tagged by severity, `ga`
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
powerline title bar (EXPLORER segment + buffer tabs, see above) and statusline
(coloured mode block, separators, the command as typed
right-aligned beside the position — vim's 'showcmd', capturing the *decoded*
key, never raw bytes: characters and control keys read back as text (`^W`),
while special keys (arrows, Esc, paging) execute at once and render nothing,
nvim's rule pty-probed — an arrow used to smear `^[[B` across the indicator;
the finished command
stays readable until the next one starts, and yields its width to a status
message — plus filetype/position/percent segments; the filename+dirty segment
appears only when the title bar is off, since the active tab already shows it
— a nerd font is recommended for the
glyphs, and the config's `nerd_font = false` swaps in a flat statusline whose
width budgets drop the separator cells, painting edge to edge in any font),
syntax highlighting (tree-sitter for 10 languages (Zig/C/Python/JSON/JS/TS/Rust/Go/HTML/Markdown) via
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
`completion_delay_ms`, `inline_diagnostics`, `soft_wrap`, `wrap_indent`,
`wrap_column`, `persistent_undo`, `format_on_save`, `cmdline_suggestions`;
`zedit --init-config` writes the annotated default.
`zedit --tutor` opens the embedded interactive tutorial (`doc/tutor.txt`,
embedded via `build.zig`).

Tabs are stored verbatim and rendered at `tab_width` (currently 4) in
`editor.zig`.

**Soft wrap** (`soft_wrap`, on by default as in vim) draws a line too long for
the window on further screen rows, each marked with a dim `↳` in the gutter,
instead of scrolling the view sideways; `soft_wrap = false` restores the
horizontal scrolling. A row breaks at the last space that fits rather than
mid-word (a word wider than the row is still broken), continuation rows repeat
the line's indent so a wrapped line hangs under its own first character
(`wrap_indent`, on, capped at half the window — vim's `breakindent`), and
`wrap_column` wraps at a column narrower than the window. One layout is
computed per line per frame and every row of that line is drawn from it. The top of a window is always the start of a buffer
line — nvim's default too, its `smoothscroll` being the exception — which
keeps the viewport a single `top` index. Two costs had to be contained,
because a wrapped line is drawn once per row it fills: the per-line syntax
styling is computed once and reused across the row's segments (`style_row`),
and the line-width scan behind the row count stops after a window's worth of
columns (`displayWidthUpTo`). Without the first, a 1.8 MB single-line file
cost 82 ms a frame; with it, 4 ms — the same as with wrap off.

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
- Large-file performance: loading is zero-copy with a lazy line index —
  opening records one `u32` offset per line instead of a 32-byte tagged union,
  and `lines` is only materialised by the first edit, so reading, searching,
  rendering and saving never pay for it (8.2 MB file: open 6.85 → 4.65 ms,
  peak RSS 32.3 → 18.5 MB). Literal search uses a first-byte/last-byte SIMD
  memmem (`search.zig`), and the whole-source path is authoritative — a miss
  returns immediately instead of re-walking every line, which used to cost
  301 ms on 8.2 MB (`buffer.zig`, 2 GB cap), and above the config's `large_file_mb` (64 MB
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
  `:e`/`:w` paths and `:theme` (not every command's arguments). The cmdline
  cursor moves (Left/Right/Home/End/Ctrl-b/Ctrl-e, insert-at-cursor), but
  there is no `Delete`-under-cursor, no `Ctrl-w`/`Ctrl-u` word/line erase and
  no `c_CTRL-R` register insertion; Tab mid-line completes the whole line
  (nvim, probed, completes only the text before the cursor and keeps the
  tail), and a cmdline longer than the row is clipped with the cursor pinned
  to the last cell (nvim scrolls it horizontally). In-buffer search/`:s` are regex, but the syntax is
  modern ("very magic"-like), not vim's magic mode — `\(` groups etc. differ.
- Highlighting is a per-line lexer (no cross-line block comments; a handful of
  languages). Tree-sitter is the upgrade path now that deps are allowed.
- Soft wrap has no per-language wrap column and no hard wrapping (vim's
  `textwidth` reflowing as you type) — `wrap_column` is display-only.
  `gj`/`gk` are cursor motions; as operator targets (`dgj`) they act charwise
  rather than vim's screen-linewise. A line is capped at 256 screen rows.
- The undo tree stores each state as the diff from its parent (prefix/suffix
  trimmed), with the current text materialised beside it, so memory is O(sum of
  edits) and a step costs one small edit. The root still holds the whole text,
  and every edit still serialises the buffer to compute its diff — that last
  O(file) cost per keystroke is the remaining one (10.9 ms on a 7.6 MB file),
  and removing it means the edit path reporting its own ranges. Capped at 256
  states. On disk the root's text is *not* stored — the anchor state is the
  file itself, and the diffs run both ways, so a 200-change session on an
  8.6 MB file is a 1.5 KB undo file rather than a second copy of the file. The
  anchor's length and hash are stored and checked, so a file edited by another
  program gets no history rather than someone else's past. Undo files whose
  mtime is over 90 days old are pruned (each removal logged) whenever a
  sibling is written — the only moment zedit touches the directory, so an
  editor with `persistent_undo` off never scans it.
- Multi-cursor is one-caret-per-line (column editing); it does not do
  per-caret line splits/joins or arbitrary selection-based multi-edit.
- The grep picker's regex runs per line — a pattern cannot match across a
  newline — and a literal query's narrowing compares against the row text as
  stored, which is capped at 120 bytes: a match hiding past that column on a
  very long line is dropped where a rescan would have kept it (the row could
  not have shown it either). Statusline separators assume a nerd font.
- Windows/splits use a flat even tiling in one orientation at a time (a split
  re-tiles all windows; no nested/mixed layouts or per-window resizing). Only
  the active window has live LSP polling and an editable selection/search/inlay
  overlay; inactive windows render from their cached state.
- Block paste of a blockwise yank is charwise (not a true rectangular paste);
  block `A` on lines shorter than the block does not pad with spaces.
- LSP does diagnostics/hover/goto (definition, implementation, type)/
  references/completion/signature help/rename/code actions/formatting/inlay
  hints/document + workspace symbols with incremental (or
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
  references and workspace symbols are capped at 1000 each. The diagnostics
  picker covers the *open* buffers — the servers only push diagnostics for
  documents zedit has opened. The references picker shows line text only for
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
  `treesitter.zig` (and, for `af`/`ac` to work there, its node names in
  `functionKinds`/`typeKinds`/`listKinds`/`commentKinds` in `editor.zig`). Structural objects currently
  cover Zig, C, Python, Rust, Go, JavaScript and TypeScript; `ia`/`aa` and
  `iC`/`aC` cover the same languages (comments also in HTML). There is no
  sentence object.
- The picker preview is a glance, not a view: capped at 256 KB per file,
  tree-sitter only up to 64 KB (the lexer covers bigger files), and skipped for
  remote entries. The parse happens *after* the picker's first frame, so
  opening it stays fast; previewing a language whose grammar has not been
  compiled yet costs a one-off 3–14 ms on the following frame. The title bar
  lists buffers in open order with no reordering, and mouse support is still
  wheel + tab clicks + explorer clicks + picker result-row clicks only (no
  click-to-move-cursor or drag selection — a plain click or drag in the text
  area stays unbound).
- The sidebar tree is flat-file only (no rename/create/delete operations from
  the tree), rebuilt on expand/toggle rather than watched (reveal-on-switch
  rebuilds only when it has to expand an ancestor). The side-by-side diff's
  alignment and tints reflect the file as last *saved* (they refresh on `:w`,
  like the gutter signs — unsaved edits shift rows until then), the index
  pane's tree-sitter highlighting covers only the viewport it last had focus
  in (lockstep-scrolled rows beyond it render plain until refocused), and the
  inline diff buffer is a static snapshot (read-only, like the index pane —
  "diff view is read-only"). A pane's stored top is a buffer row, so when a leading deletion
  gap (`@@ -1,N +0,0 @@`) is taller than the window only its tail shows
  (cursor-clamped) and the rows above cannot be scrolled into — the full fix
  is a display-space pane top (a per-Win leading-filler offset); the line
  diff's leading block clamps the same way, and its woven rows above the
  top row hide once scrolled past, like a pair's fillers. The same
  buffer-row top means a woven block taller than the window shows only its
  head: `j` across it jumps the view (the landing line becomes the top) and
  its tail can never be scrolled into — the display-space top is the fix
  here too. The weave's
  anchors are buffer rows fixed at the last save (exactly the signs' model):
  unsaved edits shift lines out from under them until `:w`, its virtual rows
  render unwrapped (clipped, always from column 0), and the wheel and
  `Ctrl-d/u/f/b` still
  count buffer lines, so a step across a woven block moves the view
  further than it looks. Mouse
  support is wheel + tab clicks + explorer clicks + picker result-row clicks
  (no click-to-move or drag
  selection), and the wheel scrolls the focused window, not the one under the
  pointer.
- Remote editing is whole-file over ssh: every read/write moves the entire file
  (no partial or incremental transfer), there is no remote LSP/tree-sitter
  beyond what the local process computes on the fetched text, no remote git
  signs, and no remote sidebar. Writes stream into a `.zedit.tmp.*` file
  beside the target and rename it into place in the same ssh invocation, so
  a failed transfer never truncates the target (at worst the temp file is
  left behind when the connection dies before the cleanup can run). A
  directory target is refused up front (`mv` would move the temp into it),
  and rename semantics mean a symlinked target is replaced by a regular
  file — the standard atomic-save tradeoff (vim's `backupcopy=yes` is the
  model that preserves symlinks; adopt it only if it matters).
  `BatchMode=yes` means password-only hosts fail instead of
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

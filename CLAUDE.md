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
     `tools/scenarios/`. A **new module's tests only run once it is listed in
     `main.zig`'s `test {}` aggregator** — Zig analyses a top-level `@import`
     lazily, so an unlisted module's tests are silently skipped and the step
     still says "all passed". `multi.zig` shipped that way for an hour; a
     deliberately failing canary is how it was noticed.
   - **Never read the screen straight after `drain`.** It hands its budget
     back as soon as *any* output flows, so the capture can hold half a
     frame — and the half it is missing is the end, which is where every
     overlay is drawn. A row read from one is missing its tail and reads
     exactly like a rendering bug; that cost an hour once. `drainUntil` waits
     for the thing being asserted and then for the output to go quiet.
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
| `term.zig`    | POSIX terminal control: raw mode, alternate screen, bracketed paste, window size, event-driven input, and the child pty behind the embedded terminal. |
| `key.zig`     | Decoding raw input bytes into `Key` events (text, arrows, navigation). |
| `unicode.zig` | UTF-8 decoding, codepoint boundaries, display width. |
| `buffer.zig`  | The document: two-phase zero-copy load (`loadPartial` indexes a head so the screen can paint, `loadRest` fills the tail), a lazy `u32` line index over one shared buffer, per-line storage materialised on the first edit, save, UTF-8-aware edits. |
| `motion.zig`  | Pure cursor motions, word/WORD rules, find-char, `%`, text objects, the double-click mouse word, the `gx` target. |
| `exrange.zig` | Ex addresses and ranges (`%`, `.`, `$`, `'a`, `/pat/`, `+n`, `,` and `;`), parsed away from the buffer that gives them meaning. |
| `register.zig`| Vim registers (named/unnamed; charwise/linewise/blockwise kind + block width) for yank/delete/paste. |
| `undo.zig`    | Undo history as a tree of edits — each state the diff from its parent (branches, `g-`/`g+`, `:earlier`/`:later`), optionally kept on disk. |
| `regex.zig`   | Regex engine: Pike VM (Thompson NFA), linear time, captures; modern "very magic" syntax. |
| `search.zig`  | Buffer search (`/ ? n N * #`): regex-powered, with a whole-source SIMD memmem fast path for literal patterns while the buffer is unedited. |
| `theme.zig`   | Colour palettes (Tokyo Night default + Gruvbox/Catppuccin/Nord/One Dark), the active-theme global, 24-bit SGR helpers. |
| `config.zig`  | The single documented config file (`~/.config/zedit/config`): parse, apply, standard path, `--init-config` default text. |
| `syntax.zig`  | Dependency-free per-line lexer producing per-byte styles. |
| `fuzzy.zig`   | Subsequence scorer for the pickers, plus the space-separated multi-term rule (`scoreTerms`) and the prefilter's query mask. |
| `git.zig`     | Git change signs for the gutter (parses `git diff -U0`; skips the subprocess entirely outside a work tree). |
| `complete.zig` | Buffer-word completion candidates: identifiers harvested from the open buffers (the fallback when no server answers). |
| `snippet.zig` | LSP snippet parsing: `$1`, `${1:placeholder}`, `${1|a,b|}`, `$0`, escapes → plain text + tabstops. |
| `recent.zig`  | The recently-opened list behind the startup screen (XDG state file). |
| `jsonrpc.zig` | The `Content-Length`-framed JSON transport `lsp.zig` and `dap.zig` share: framing only, with control inverted (`nextFrame`) so each caller stays an ordinary loop. |
| `dap.zig`     | Debug Adapter Protocol client: launch, breakpoints, stop/step, the stack frame the program stopped in; plus the breakpoint set, which outlives a session. |
| `vt.zig`      | Terminal emulator: bytes from a child process in, a grid of styled cells out (pure, unit-tested — no pty, no rendering). |
| `ui.zig`      | Chrome geometry: a 1-based `Rect`, the ways of placing one against the screen (centred, right-edge), the inset a border costs, and the box-drawing glyphs. Pure — the caller draws. |
| `notify.zig`  | Corner toast notifications: a fixed, allocation-free queue with its own expiry deadline (pure — the editor draws them and owns the clock). |
| `fold.zig`    | Folds: which line ranges are collapsed, which rows that hides, and how they move when the text does. |
| `quickfix.zig`| The quickfix list: file positions kept so `]q`/`[q` can walk them long after the picker that found them is gone. |
| `multi.zig`   | The multibuffer's one hard rule: which runs of which files one editable buffer shows — hits padded with context, grouped by file, overlapping *and* touching runs merged so no source line is ever shown, or written back, twice. |
| `session.zig` | Per-directory sessions: the open files + cursors, the split layout and the tree's state, serialised to an XDG state file. |
| `remote.zig`  | Editing over SSH: `ssh://user@host/path` parsing, read/write/list via one `ssh` per operation. |
| `lsp.zig`     | Minimal LSP client: JSON-RPC over a server's stdio (diagnostics, hover, goto, completion, signature help; incremental or full doc sync per the server's capabilities). |
| `treesitter.zig` | Tree-sitter highlighting via the vendored C runtime + grammar (incremental parse, visible-range `highlights.scm` query, language injections, `#match?`/`#eq?` predicates, `indents.scm`; compiled queries + predicate regexes shared process-wide), plus the structural queries the editor asks of a tree: the object spans, `]f`/`[f`, and `crumbs` — the enclosing symbol path behind the breadcrumbs. |
| `editor.zig`  | State, the vim command interpreter, multiple cursors, multiple buffers + windows (splits), pickers, LSP, tree-sitter, viewport, themed rendering. |

Vendored C lives under `vendor/` (`tree-sitter/` runtime, plus `tree-sitter-zig`,
`-c`, `-python`, `-json`, `-javascript`, `-typescript`, `-rust`, `-go`, `-html`, `-markdown` (block + inline) grammars, each with
`parser.c`, an optional `scanner.c`, and `highlights.scm`, plus an optional
`injections.scm` and `indents.scm`); `build.zig` compiles
them with `-D_GNU_SOURCE` and links libc. Adding a grammar is one entry in the
`grammars` list in `build.zig`, one row in `syntax.zig`'s `languages` table
(extensions, fence tags, statusline name, LSP id, server, adapter) and a case
in `specFor` in `treesitter.zig` (TypeScript keeps
its grammar under `typescript/` with a sibling `common/scanner.h`, and its
highlight *and* indent queries layer on JavaScript's).

The pure, error-prone logic (motions, search) lives in its own unit-tested
modules; `editor.zig` is the stateful orchestrator (mode machine, operators,
registers, undo, visual, macros, marks, dot-repeat, rendering).

Data flow: `term` reads bytes → `key` decodes them → `editor` mutates `buffer`
and renders a frame back through `term`. `unicode` is shared by `buffer` and
`editor`; `log` is used everywhere.

## Build, test, run

```sh
zig build                       # debug build -> zig-out/bin/zedit (host only)
zig build -Doptimize=ReleaseFast
zig build run -- [file]         # run the editor
zig build test                  # unit tests (pure logic; no tty needed)
zig build itest                 # pty integration tests (~2 min, suites in parallel)
zig build itest -- git sidebar  # ... just those suites, serially, in-process
zig build bench -Doptimize=ReleaseFast   # benchmark vs helix/nvim (if installed)
```

**Keep pty cases hermetic.** An editing case must not depend on what is
installed on the machine running it: `runEdit` passes `--lsp ""` so no
language server starts, because opening a file otherwise launches whatever
server exists for its filetype. A Rust indent case that never mentioned LSP
hung on CI for months of commits for exactly this reason. Scenarios that
*are* about LSP spawn the mock explicitly.

**Assert the outcome, not the schedule.** A pty check that waits a fixed
number of milliseconds and then looks encodes how fast the machine is; CI is
slower than a workstation, so such a test goes red for reasons that have
nothing to do with the code (it happened to the handshake-window completion
test). Where an outcome arrives *eventually*, poll for it in slices up to a
generous deadline and fail on the deadline. Fixed budgets are right only for
"this must NOT happen" checks, where waiting longer cannot change the answer.

**Measure what a user waits for.** `waitQuiet` alone cannot time an editor:
it starts counting silence immediately, so anything slower to respond than the
quiet window scores as instant. Always require a first response before timing
the settle, and report cold and warm separately where a first operation builds
something.

**Measure in ReleaseFast.** `zig build test` and `zig build itest` reinstall
`zig-out/bin/zedit` as a *Debug* build, which is ~6x slower — rebuild with
`zig build -Doptimize=ReleaseFast` before any ad-hoc timing, or the numbers
are meaningless. (`zig build bench` builds its own ReleaseFast artifacts.)

A local build targets the host and nothing else (`b.standardTargetOptions`),
so no developer pays for cross-compilation; only the release workflow's matrix
passes `-Dtarget=`, producing the four published platforms.

CI runs `zig build test` + `zig build itest` on every push
(`.github/workflows/ci.yml`); pushing a `v*` tag cross-compiles stripped
ReleaseFast binaries for Linux x86_64/aarch64 (static musl) and macOS
x86_64/aarch64 and attaches them to a GitHub release (`release.yml`).

Compiling a grammar's `highlights.scm` costs 3–14 ms, so the compiled queries
— highlights, `injections.scm` and `indents.scm` alike, together with the
predicate regexes parsed out of each — are cached per query source for the
life of the process (`query_cache` in `treesitter.zig`) and shared by every
buffer and the picker preview: opening ten files of one language compiles its
query once, not ten times.

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
  (Both `itest` runs and the scenarios use fixed `/tmp/zedit_it_*` paths, so
  two suites must never run at once — they clobber each other's files.)
- `tools/mock_dap.zig` — a stub debug adapter for the debug scenario, so the
  suite needs no lldb-dap or debugpy installed anywhere.
- `tools/itest.zig` — the runner. With **no filter** it farms each suite out
  to a child process, 12 at a time, and reports each as it lands; with a
  filter it runs those suites serially in-process, which is also what a child
  does. The suites are independent (each owns its own `/tmp/zedit_it_*`
  files), so this is safe — but it does mean **two full runs must never
  overlap**, since both would use those same paths. Parallelism took the run
  from 714 s to 127 s; the floor is now the longest single suite
  (`vim_compat`, 283 checks, ~126 s), because the cost is process startup, not
  waiting: `drain` gives its budget back as soon as output flows. Per-suite
  timings print as `--- name: N checks in M ms`, which is how that was
  found. (argv[4..] filters suites by name; a failing
  run reprints every failed check as `suite: name` at the **tail**, because a
  CI log is read and pasted from the bottom, where the per-check `[FAIL]` line
  has long scrolled away — and under `GITHUB_ACTIONS` also emits each as a
  `::error::` workflow command, which becomes a check annotation the API
  serves for a public repo *without* a token, where the log body needs one); `tools/scenarios/*.zig` are the suites (vim,
  vim_compat, feature, multicursor, extra, search, treesitter, indent, picker,
  git, windows, sidebar, mouse, titlebar, config, cmdline, robust, remote, ssh,
  lsp, bufcomplete, cpu, wrap, undotree, session, terminal, debug, quickfix,
  fold, view, ex), each a
  `pub fn run(ctx: *harness.Ctx) !void`. `view` is the viewport suite
  (`zz`/`zt`/`zb`): it asserts which buffer lines the window ends up showing,
  against numbers read out of a real nvim at the same 22 text rows.
  `vim_compat` asserts byte-for-byte agreement with expected outputs generated
  by driving real Neovim headlessly — extend it the same way when porting more
  upstream behaviours (ask nvim, not memory).
- `tools/bench.zig` — `zig build bench -Doptimize=ReleaseFast` compares zedit
  with helix/nvim (if on PATH) through real ptys: startup, 10 MB file open,
  keypress latency, picker-open (cold/warm).

The editor itself has no runtime dependencies.

## Editor usage

**This whole section describes `keymap = vim`.** The shipped default is
`vscode`, a non-modal table documented under Appearance — but vim is the
editor everything below is about and everything in `vim_compat` is pinned to,
so read it as "with `keymap = vim` set".

Modal, vi-like, with a comprehensive vim keymap. A command is `[count]` then
either a motion (move) or `[register]` `operator` `[count]` motion/text-object.

- **Motions:** `h j k l`, `w W b B e E`, `0 ^ $`, `gg G {n}G`, `f F t T` + `; ,`
  (counted: `3fa` lands on the third, `d2fa` multiplies the counts),
  `%`, `{ }` (paragraph, jump motions), `H M L`, `Ctrl-d/u/f/b`,
  arrows/Home/End/PageUp/Down (arrows and `<BS>` take counts like
  `h j k l`; Home/End ignore them — nvim-probed). Counts work **inside visual
  mode** too (`v3l`, `v2j`, `v3w`; `v3G` is a line number, not a repeat).
  nvim's `'startofline'` is off, so `G`, `gg`, `{n}G`, `H`, `M`, `L` and a
  linewise delete (`dd`, `dj`, `Vd`) all keep the cursor's **display column**
  rather than snapping to the first non-blank — `nvim#sol1`-`sol12`. With soft wrap on, `j`/`k` step a *screen* row **on a line that actually
  wraps** —
  a deliberate divergence from vim, where they always move a buffer line: on
  wrapped prose vim's rule reads as the cursor skipping, because one press
  crosses however many rows the line happened to fill. `gj`/`gk` still work
  and are now the same thing. Only as a *cursor* motion: with an operator
  pending they stay linewise, so `dj` takes two whole lines rather than a
  screen row's worth of characters. The gate is the *current* line rather
  than "wrap is on", because on a one-row line the two are the same movement
  except that the screen form is charwise and exact, and would quietly drop
  the goal column a `k` after a click past a short line's end depends on.
  `g0`/`g$` reach the ends of a screen row,
  while `0`/`$` keep their buffer-line meaning. `H M L`, `Ctrl-d/u/f/b` and the wheel all
  count screen rows, so they land where they look like they should on wrapped
  text. The normal-mode cursor never sits past the
  last character (vim's rule), so `$x`/`$dh`/`$d{` act on it. A jump landing
  more than half a window away redraws with the cursor **centred** (vim's rule,
  nvim-verified) — so it is not glued to the bottom row where every wheel notch
  would drag it along. The mouse wheel
  scrolls the window **under the pointer** — focused or not, and it never
  moves focus (nvim's rule, pty-probed). A window's *status row* counts as
  part of it (`winUnder`, which is `winAt` plus that row — nvim scrolls the
  window a status line belongs to even when the focus is elsewhere, probed);
  cells no window owns at all (the explorer, the title bar, the command line)
  scroll the focused one, where nvim picks its bottom-most window. It moves that
  window's viewport 3 **screen rows** and carries its cursor with it, keeping
  its screen row. Screen rows, not buffer lines: `winStepRows(…, display =
  true)` counts the rows that belong to no buffer line — a diff pair's fillers
  and the line view's woven old lines — because a viewport step that ignored
  them travelled a different distance whenever it crossed a hunk, which is the
  jumping a scroll past a change showed. The paging motions (`Ctrl-d/u/f/b`) count those rows too, as of 0.38.0 — a
  half-page that ignored them travelled a different distance depending on
  whether it crossed a hunk, which is the same jumping the wheel had. `H`/`M`/`L`
  keep `display = false` and vim's line-based meaning (owner's choice over nvim's drag-at-the-edge rule, which stranded
  the cursor at the bottom of the page; at the top or bottom of the file
  nothing moves at all). The scroll runs on the `Win` (`mouseScroll` saves the
  active window's mirrored viewport out and loads it back, and
  `winLineAfterRows`/`winLineRows`/`winLineLayout`/`winTextCols` take the
  window rather than reading the Editor mirror), so no window's state can go
  stale; inside a visible diff pair the notch is routed to the pane that
  drives the lockstep (`wheelWin`), because `syncDiffPanes` derives the other
  pane's top from it every frame. SGR mouse reporting (modes 1002 + 1006, config
  `mouse`, on by default — `false` never emits the enable sequence and makes
  even a stray report inert): the wheel, tab clicks, explorer clicks and
  picker result rows act (see Pickers), and so do the three left-button
  events — press, motion-while-held, release. Every other report (other
  buttons, any modifier, the horizontal tilt axis, extra buttons, malformed
  noise) decodes to an inert key swallowed before command dispatch, so it can
  never reach showcmd or reset a pending operator or count the wheel would
  keep. Modifiers stay unbound on purpose: nvim gives Alt+drag and Ctrl+click
  meanings of their own that zedit does not implement. Shift+mouse never
  arrives at all — every terminal keeps it for its own selection, which is
  how text is copied out and the reason no Shift binding could ever fire.
- **Click and drag (nvim `mouse=a`, pty-pinned in `vim_compat`):** a left
  click in a window's text area moves the cursor there, focusing that window
  first when it is not the active one. It adds no jumplist entry, discards a
  pending count, ends an open selection and lets insert mode continue; with an
  *operator* pending it is that operator's motion — exclusive charwise, which
  `buildSpan` turns linewise by vim's usual column-0 rule. Holding the button
  and moving selects: the press anchors (never the first motion, which already
  lands a cell away), each crossed cell extends, the release finishes and
  leaves an ordinary charwise visual selection for `d`/`y`/`c`; a drag that
  never leaves its cell stays a plain click, and one that wanders off the
  window keeps extending inside it, clamped to what is on screen. The screen →
  buffer inverse replays the renderer's own row walk (`RowWalk`/`nextRow`,
  the `tabArea` invariant applied to the text area), so wrap segments and
  their hanging indent, diff-pair fillers, line-diff woven rows and `~` rows
  resolve exactly as they were drawn — a virtual row snapping to the nearest
  real line rather than inventing a position — and the column inverse accounts
  for the gutter (which reads as column 0, as in nvim), tabs, wide cells and
  inlay hints. `goal_col` keeps the *clicked* column, not the clamped one, so
  clicking past a short line and pressing `j` lands where the pointer was.
- **Multi-click gestures (nvim-pinned, `vim_compat`):** clicking the same cell
  again within `mousetime` (config, 500 ms, vim's name and value) counts up
  through vim's **period-4** cycle — 2 = the word (charwise), 3 = the whole
  line (linewise, newline included, whatever column), 4 = one blockwise cell —
  and the fifth click is a plain one again. The count is derived from the
  previous press's timestamp and cell when the next arrives (`clickCount`), so
  **no timer is armed**; one column off or one millisecond late restarts the
  chain, and a replay (macro, dot-repeat) starts its own chain rather than
  chaining with the press that recorded it. *Every* press counts, wherever it
  lands — vim decides the count in the input layer, before the click is routed
  — so a press on chrome (a status row, the command line, the title bar, the
  explorer) breaks a chain in two rather than passing through it
  (nvim-probed). The word is vim's *mouse* word
  (`motion.mouseWord`), not `iw`: blanks and keyword characters take their
  run, punctuation first tries `%` (an item at or after the click on that
  line wins, and the selection runs from the click to its match — backwards or
  across lines), and otherwise groups only with its own class, so `->`/`*=`
  are one and `.,;` is three (`motion.mouseClass`, with vim's `utf_class`
  ranges for multibyte, so CJK does not group with an adjacent Latin word).
  Dragging on from a multi-click extends by whole words / lines / a rectangle
  in either direction, the clicked word always kept whole (`dragWord`) — which
  is also what stops the release collapsing a double click's selection.
- **Insert Visual:** a gesture begun in insert mode is nvim's Insert Visual —
  `(insert) VISUAL` on the statusline, and whatever ends the selection (`Esc`,
  `v`, an operator, a plain click) returns to **insert** where it left the
  cursor, so typing continues (`ins_visual`, cleared by `enterVisual` so it
  can never outlive its selection).
- **Selecting motions (Helix-style):** `e` and `b` in normal mode move *and*
  leave what they travelled over selected, so the next key acts on it (`ed`
  deletes the word, `ee` reaches two). Only these two: Helix's model is that
  every motion selects, which would change what `d`, `.`, visual mode and four
  hundred nvim-pinned checks all mean. With an operator pending they are plain
  motions, because `de` must delete the word rather than select it and wait.
- **Operators:** `d` `c` `y`, `> <` (indent), `=` (re-indent), `gu` `gU` `g~`
  (case), doubled
  `dd cc yy >> << ==` and `guu`/`gUU`/`g~~` (also the long `gUgU` spelling,
  which doubles in the `g` prefix since the second `g` has already been
  eaten); `D C Y`,
  `x X s S`, `r` `~` `J`, `gJ`. `cw`/`cW` act like `ce`/`cE`. `gJ` is the
  literal join — unlike `J` it neither strips the next line's indent nor
  inserts a separator, so `abc` + `    def` is `abc    def`. `J` itself
  inserts exactly one space, and none at all where the first line already
  ends in white space or the next opens with `)` (both nvim-probed, and both
  wrong here until 0.48.0 — writing `gJ`'s tests beside `J`'s is what
  exposed them).
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
- **Sentences:** `(` / `)` move to the previous/next sentence start (counted),
  and `is` / `as` are text objects for one. A sentence ends at `.`, `!` or `?`
  followed by any number of `)`, `]`, `"`, `'` and then a space, a tab or the
  end of the line — vim's rule. `as` takes the whitespace after the sentence,
  or, when it ends the line, the whitespace before it instead (the same
  asymmetry `ap` has). All nvim-pinned (`nvim#sn1`-`sn11`); the rules are pure
  and unit-tested in `motion.zig`.
- **Text objects:** `iw aw iW aW`, `ip ap` (paragraph, linewise — `ap` takes
  the trailing blank lines, or the leading ones when nothing trails),
  `i( i[ i{ i< i" i' i\`` and `a…` variants (plus `b`/`B` aliases), e.g.
  `ciw`, `di"`, `da(`, `dap`. Objects work in visual mode too (`vip`, `vi(` —
  paragraph objects switch the selection to V-LINE, as vim does).
- **Registers/paste:** `"a` selects a register (in visual mode too). In
  *visual* mode `p`/`P` **replace the selection** with the register, and what
  was replaced becomes the unnamed register — all four register-kind ×
  selection-kind combinations nvim-pinned (`nvim#vp1`-`vp8`), including a
  linewise register dropped into a charwise selection, which splits the line.
  In normal mode `p`/`P`
  paste it back the way it was taken — charwise, linewise, or **blockwise** as
  a rectangle: one register line per buffer line at one display column,
  padding a line too short to reach it, growing the file when the block
  outlasts it, and laying the block side by side under a count (`3p`). A
  register line is squared up to the block's width only when something follows
  it on that line, which is vim's rule and why a paste at end-of-line stays
  ragged. `"+` / `"*` are the system clipboard: yanks there are sent to the terminal
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
  **Repeat:** `.` repeats the last change. `[count].` *replaces* the change's
  leading count rather than repeating the change that many times (`3x` then
  `2.` removes five characters, not nine; the substitute goes after a
  `"{reg}` prefix, which vim keeps — a count in front of it would fuse with
  the register's own digits), `.` never records itself (so `..` works and a
  macro may record one), and a cursor movement mid-insert splits the change
  as vim does — `.` then repeats only the text typed after the move, as a
  plain insert.
- **Visual:** `v` (char), `V` (line), `Ctrl-v` (block); move to extend, `o`
  swaps ends, then `d c y x > <`. In block mode `I`/`A` insert at the left/right
  edge of every selected line (via the multi-cursor machinery), with vim's
  asymmetry on lines that do not reach the block: `A` pads one out with
  spaces, while `I` and `c` skip it. A `[count]` types the text that many
  times at *every* caret (`3A`, `3I`); the repeat runs before the carets are
  collapsed, which is the only moment they still exist. `$` extends the block to each line's own
  end — and keeps doing so as `j`/`k` grow it — so `$A` appends at every
  line's end and pads nothing; any motion naming a column ends it. `y`/`d`/`x`
  fill a blockwise register (see Registers/paste). `u`/`U`/`~` recase the
  selection, and so do `gu`/`gU`/`g~`; `gJ` joins the selected lines with no
  separator. **`gv` puts the last selection back**, in the mode it had —
  called from visual mode it *swaps*, which is vim's rule there. The
  coordinates are what is remembered, not the characters: `vlld` then `gv`
  selects whatever moved into the three columns the delete emptied
  (nvim-probed). Every key that could end visual mode records the selection
  first, at the top of the dispatch, so no exit path can forget to — the `g`
  prefix being the one exception, which is how `gv` sees the *previous*
  selection rather than the one it is standing in. `g` in visual mode now
  waits for its second key as vim does; it used to jump to line 1 on the
  bare `g`. The prefix carries the screen-line motions too — `g0`, `g$`,
  `gj`, `gk` extend the selection like any other motion — because those had
  only ever worked by accident (the bare `g` jumped, then the second key
  applied from line 1), and a prefix that did not know them would have
  swallowed them silently instead.
- **The rest of visual mode.** `Ctrl-A`/`Ctrl-X` bump the number on every
  selected line, and `g Ctrl-A`/`g Ctrl-X` *step* the amount line by line —
  `1 1 1 1` becomes `2 3 4 5` — with only lines that hold a number advancing
  the step, and the whole selection one undoable change. `D`/`X`/`Y`/`C`/`R`
  are the forms that take whole *lines* however the selection was made, so
  `vlD` deletes the line rather than the two characters under it. `J` joins
  the selected lines (`gJ` without the separator), `r` replaces every
  character in the selection, `gq` reflows it, and `O` swaps a block's
  *horizontal* corner where `o` swaps the whole one. `v`/`V`/`Ctrl-V` each
  stop visual mode when it is already their kind, `Ctrl-C` stops it outright,
  and `Q` does nothing — vim is explicit that it does not start Ex mode here.
  `S` keeps zedit's surround rather than vim's change-lines, which `C` and
  `R` both provide.
- **`it`/`at`:** the innermost markup tag block, matched *textually* rather
  than through a grammar so it works in any file that happens to hold markup
  — a template, a docstring, a string literal — not only where one was
  vendored. Both ends come back **exclusive**, like `objSentence`: an
  inclusive end cannot say "up to the `<`, line breaks and all", and `dit`
  over a tag whose content owns whole lines would leave them behind.
- **`:[range]!cmd`** hands the range to a command's stdin and puts what it
  writes back in its place; visual `!` prefills the range, so `!sort` over a
  selection is the classic use. This is the one place zedit runs a *shell*
  (`sh -c`), because pipes and redirection are the point and the command line
  is the user's own — nothing from a file or a language server reaches it.
  Its output is read before the wait, so a command writing more than a pipe
  buffer cannot deadlock against it.
- **Search:** `/pat` `?pat` (incremental — jumps live as you type, `Esc`
  cancels and restores the cursor), `n N`, `*` `#` (whole-word, `\<word\>`).
  Matches are highlighted; wraps. Patterns are modern regexes (regex.zig:
  `. [..] * + ? ( ) | ^ $ \w \d \s \b \< \>` — Helix/ripgrep style, not
  vim's magic mode); a plain word behaves exactly as before.
- **Marks/macros:** `m{a-z}`, `` `{a-z} ``, `'{a-z}`; `q{a-z}…q` records, `@{a-z}`
  / `{n}@a` replays, and `@@` repeats the last macro (counted too). A replay
  stops at the first command that fails — a motion with nowhere to go, a find
  or a committed search with no match — instead of running the keys after it;
  a count stops with it. The abort is scoped to that replay, so the next key
  typed runs normally, and the *incremental* search does not raise it (a
  replayed `/pat` must not abort while typing its own pattern).
- **Where the cursor sits on screen (`zz`/`zt`/`zb`):** put the cursor's line
  at the centre, the top or the bottom of the window without moving the
  cursor itself. nvim's arithmetic, pty-probed on a 22-row window: `zt` tops
  at the cursor line, `zz` keeps `(rows-1)/2` lines above it — the same
  `centredTop` a long jump already uses — and `zb` keeps `rows-1`. All three
  clamp at the *start* of the buffer and none at the end, so `zt` near EOF
  deliberately leaves a screen of `~`. Counted like every other viewport
  move: display rows inside a diff pair, screen rows under soft wrap, buffer
  lines otherwise.
- **`gx`:** hand the URL or file name under the cursor to the desktop's own
  handler (`xdg-open`, `open` on macOS) — a stock nvim 0.12 default. The
  target is vim's `<cfile>`: the run of `isfname` bytes plus the few a URL
  needs (`:?&`), with brackets, parens, quotes and whitespace deliberately
  *out*, so a markdown `[text](url)` yields the url alone and trailing
  sentence punctuation is dropped (`motion.targetUnderCursor`, unit-tested).
  Buffer content is untrusted, so it leaves as one argv element — no shell
  ever parses it — and a target starting with `-` is refused rather than
  reaching the handler as a flag. `term.openExternal` forks *twice* so the
  grandchild is orphaned and reaped by init: the editor never blocks on a
  browser starting and no zombie accumulates.
- **The bracket namespace.** `] `/`[ ` add blank lines without moving the
  cursor; `]'`/`['` and `` ]` ``/`` [` `` step between marks (linewise to the
  first non-blank, or exactly); `])`/`[(` and `]}`/`[{` leave the enclosing
  bracket, counting depth so a balanced pair in between is skipped;
  `]]`/`[[` and `][`/`[]` are vim's sections — a brace in **column 0**, with
  the crossed spelling vim uses, running to the file's ends when there is
  none; `]/`/`[/` (and `]*`/`[*`) reach a C comment's ends; `]#`/`[#` the
  preprocessor conditional around the cursor, nesting counted; `]p`/`[p` and
  `]P`/`[P` paste linewise with each line's indent replaced by the current
  line's; `]m`/`[m` land on the brace that opens a member; `]z`/`[z` on the
  ends of the fold the cursor is in; `]c`/`[c` is vim's diff-mode change
  motion, which here is the git hunk `]g`/`[g` already walks; and
  `]D`/`[D`, `]Q`/`[Q`, `]B`/`[B` take the *last* or *first* of a list
  rather than the next.
  Not implemented: `[s`/`]s` (spell, the same missing dictionary as `z=`),
  and the `'include'`/`'define'` family — `[d`/`]d`, `[i`/`]i`, `[D`/`]D`,
  `[I`/`]I` and the `Ctrl-D`/`Ctrl-I` forms all search *included files*, a
  concept zedit has no notion of. `[l`/`]l`, `[a`/`]a` and `[t`/`]t` want a
  location list, an argument list and tags, none of which exist. `[f`/`]f`
  and `[d`/`]d` keep zedit's own meanings (functions and diagnostics), as
  the naming note has it.
- **Jumplist:** `Ctrl-o` / `Ctrl-i` (also `Tab`) walk back/forward through
  jump-motions — `G`/`gg`/`{n}G`, `H M L`, `%`, committed searches (back to the
  origin), `n N * #`, mark jumps, `:{n}`, and every buffer switch (`:e`,
  `:bn/:bp`, pickers, `gd`). Entries are per position across buffers (capped at
  100, same-line entries replaced); closing a buffer purges its entries.
  Behaviour pinned to nvim ground truth in `vim_compat`.
- **Replace (`R`):** typing overwrites what is already there instead of
  pushing it right, `Esc` returns to normal one column back as insert does.
  Vim's model exactly: each overwritten character is pushed on a stack and
  **backspace pops it back**, so a session can be walked all the way to the
  text it started from. Past the end of the line typing appends, and
  backspace over one of those removes it rather than restoring anything. With
  the stack empty — the cursor has walked back past where the session began —
  backspace only moves, changing no text (nvim-probed with `\x08`, since a
  pty swallows `\x7f` when there is nothing to restore). `Enter` breaks the
  line without replacing anything and ends the run backspace can reach. A
  `[count]` types the text that many times, overwriting each time (`3Rab` on
  `abcdefghij` gives `abababghij`), `.` repeats the whole session and the
  session is one undo step.
- **Virtual replace (`gR`):** the same session, except a keystroke covers
  display *columns* rather than characters — so typing over a tab shrinks it
  instead of destroying it, and the tab only goes once every column it drew
  has been covered. `virtualCover` measures each character as the walk passes
  it, so deleting one never invalidates the widths of those after it, and the
  byte run it returns can span several codepoints once a tab is finally
  consumed. Backspace puts back whatever the keystroke covered, a swallowed
  tab included. The statusline says `VREPLACE`, as vim's does. With no tab in
  reach `gR` is exactly `R`, which is most of what makes it cheap: one flag,
  one width walk, and everything else — the stack, counts, dot, undo — is
  already there.
- **The rest of the `g` namespace.** `ge`/`gE` back to the end of the
  previous word (counted, inclusive); `g_` the last non-blank `count-1` lines
  down; `g^` the first non-blank of the *screen* row; `gm`/`gM` the middle of
  the window / of the line's own text; `go` byte N, counting the line break
  that ends each line; `g'`/`` g` `` the mark jump with the jumplist left
  alone; `g*`/`g#` search without the `\<`/`\>` bounds `*`/`#` add;
  `gn`/`gN` select the next/previous match of the last search, so `dgn`
  deletes it and `.` moves on to the one after; `g?` rot13 (with `g??` and
  `g?g?`); `gI` insert at column 1; `gp`/`gP` paste leaving the cursor
  *after* what was pasted, which is what lets repeated `gp` stack;
  `g&` run the last `:s` again over every line, flags and all; `g8` the
  UTF-8 bytes of the character under the cursor; `gf`/`gF` open the file
  named under the cursor (the same reader `gx` uses, so a quoted path or a
  markdown link yields the path alone; `gF` also honours a trailing `:line`);
  `g;`/`g,` walk the **change list**, which every `pushUndo` records, one
  entry per line as vim does; `gD` the LSP declaration; `gq`/`gw` reflow to
  `wrap_column` (79 when it is 0, vim's own fallback for `textwidth=0`) —
  `gq` ends on the last line it made, `gw` puts the cursor back, and that is
  the whole difference; `g<Down>`/`g<Up>`/`g<Home>`/`g<End>` alias
  `gj`/`gk`/`g0`/`g$`; `g Ctrl-G` reports the position in every unit.

  **What is deliberately not bound**, so it is not looked for again:
  `gt`/`gT`/`g<Tab>` need tab pages, a layout container above windows that
  zedit does not have; `gh`/`gH`/`g Ctrl-H`/`gV` need Select mode; `gQ` is Ex
  mode; `g@` needs `'operatorfunc'`, i.e. scripting, a stated non-goal; `g]`
  and `g Ctrl-]` need tags; `g<` needs a message history; `g Ctrl-A` is a
  vim debug build's memory profile; `g<LeftMouse>` and friends are Ctrl-click
  aliases, and mouse modifiers stay unbound on purpose. `gs` *sleeps the
  editor*, which contradicts the rule that zedit never blocks — it is the one
  entry left out on principle rather than for want of machinery. Four more
  keep zedit's AstroNvim meaning rather than vim's: `ga` is a code action
  (`g8` answers "what is this character" instead), `gi` is goto
  implementation, `gr` is rename and `gd` is goto definition.
- **Insert:** `i I a A o O` (and `c`/`s` entries), `Esc` to normal. Auto-pairs:
  typing an opener inserts its closer; typing the closer steps over it.
  Autoindent (config `autoindent`, on by default): `o`/`O`/Enter/`cc` inherit
  the current line's leading whitespace, and an auto-indent left blank is
  stripped on leaving the line (vim's rule; nvim-verified in `vim_compat`).
  With a grammar that ships an `indents.scm` (Zig, C, Python, Rust, Go, JS,
  TS) the syntax tree takes over: the new line inherits from the line it
  *follows* — the current one for `o`/Enter, the one above for `O`/`cc` —
  plus one level per block that line *opens*, so Enter after
  `void f(void) {` or `def f():` lands one step in
  rather than flush with its opener, and nesting stacks. Enter counts only the
  text *before* the cursor, so an opener the split pushes onto the new line
  opens nothing — C's `{`, which is the opener's first byte, and Python's `:`,
  which is its last (nvim-verified, as are the `#c*`/`#p*` cases in the
  `indent` scenario — driven through nvim-treesitter's own indent module; the
  `#f*`/`#b*` fallback cases are pinned against plain nvim instead). The unit is
  a tab where the surrounding code is tab-indented, else `tab_width` spaces.
  Only `@indent.begin` is evaluated — there is no `@indent.end`/`@indent.dedent`
  (a Python `return` keeps the block's indent where nvim dedents) and no
  `@indent.align` (a wrapped expression is not aligned to its opening paren) —
  and whenever the tree cannot answer (no grammar, no indent query for it,
  `O`/`cc` on the first line, or a **blank** line to follow — which carries no
  indent and opens nothing) it is vim's plain copy rule, right down to
  `O`/`cc` reading their *own* line again. A tree a revision behind the buffer
  is *not* one of those cases: a batch of keys arriving with no frame between
  them (a `.` repeat, a macro replay, a paste, plain fast typing) catches the
  parse up on the spot, so the same keys always produce the same indent
  whatever the terminal did with them.
- **Built-ins (no plugins):** `gcc` / `gc{motion}` comment toggling, auto-pairs.
- **Surround:** `ys{motion}{char}` (e.g. `ysiw)`), `cs{old}{new}` (e.g. `cs"'`),
  `ds{char}`, `yss{char}` for the whole line, and `S{char}` in visual mode.
- **Multiple cursors:** `Ctrl-n` / `Ctrl-p` add a caret on the line below/above
  (one per line); movement, `x`, and `i`/`a`/`I`/`A` + typing apply to every
  caret; `Esc` collapses back to one.
- **Pickers (AstroNvim-style leader tree, leader = `Space`):** pressing `Space`
  shows a which-key popup — drawn in the **bottom right** via `ui.rightEdge`,
  where helix puts its keymap infobox, rather than over the first characters
  of every line — with nested groups (submenus get their own popup):
  `Space b` = Buffers (`b b` the buffer picker — same as `f b` — `b n`/`b p`
  next/previous, `b c` **close others** — AstroNvim's `bc`, which refuses
  while any of them is unsaved and names it; it used to duplicate `Space c`);
  `Space f` = Find (`f f` files, `f w` words/grep, `f b` buffers, `f t`
  themes, `f u` the undo tree — `:undolist`'s picker, which had no key —
  and `f C` the **command palette**, AstroNvim's `<leader>fC`); `Space l` = Language tools (`l a` code action, `l r` rename, `l R`
  references, `l s` document symbols, `l S` workspace symbols, `l d` line
  diagnostic, `l D` all diagnostics, `l f` format, `l p`/`l P` **peek
  definition / references**);
  `Space g` = Git (`g d` inline diff,
  `g s` side-by-side, `g l` line diff); `Space d` = Debug (`d b` breakpoint,
  `d c` start/continue, `d n`/`d i`/`d o` step, `d q` stop); `Space t` = a terminal; `Space S` = Session for this
  working directory (`S s` save, `S l` load, `S d` delete — also
  `:session save|load|delete`); `Space e` file explorer; `Space n` = New (`n b` an
  empty buffer — AstroNvim's `<leader>n`, the buffer it replaces stays open;
  `n f` a new file and `n d` a new folder, the same prompts the explorer's
  `a`/`A` open but reachable without the tree, and both take a whole path so
  `src/net/http.zig` makes the directories on the way);
  `Space x` = the Quickfix list (`x q` open it, `x n`/`x p` step, `x c`
  close — AstroNvim's `<leader>x`; the list was complete and reachable only
  by typing `:copen`, and `:cnext`/`:cprev` had no key either);
  `Space h` the startup screen (AstroNvim's `<leader>h`, which could not be
  returned to once any key had dismissed it);
  `Space c` close buffer,
  `Space w` write, `Space q` quit. Group labels say what the group *makes*: `Space n` reads
  "New file/folder …" and its entries "New file (a/b/c.zig ok)" / "New folder
  (a/b/c ok)", because a user hunting for how to create a file scans for the
  word "file" — a label reading "new …" is a feature nobody finds. `Space b b`
  is gone: it duplicated `Space f b` exactly, and AstroNvim's buffer picker is
  the `f b` one. In a picker: type to filter, `Ctrl-n`/`Ctrl-p` or
  arrows to move, `Enter` to open, `Esc` to cancel, and `Ctrl-r` re-walks the
  project. Fuzzy queries are multi-term, helix-style (`fuzzy.scoreTerms`):
  the query splits on spaces and every term must match independently, in any
  order, the per-term scores summing (so the shorter-candidate tiebreak
  carries over). The two pickers that do not match client-side are the
  exceptions: the grep picker's query is one regex, where a space is a
  literal and `foo.*bar` expresses order, and the workspace-symbol picker
  hands the query — spaces and all — to the language server, which owns the
  matching and shows every row it returns. (The file list is
  cached per session — the Zed-style warm picker:
  opening does no filesystem work after the first walk, candidates are
  prefiltered with per-path char bitmasks, and extending the query narrows the
  previous result set instead of rescoring everything — the grep picker narrows
  the same way, filtering the hits it already has rather than re-reading every
  file, so a keystroke costs 4 µs once the scan has covered the project —
  narrowing stays sound with multi-term queries, since appended bytes only
  ever extend the last term or add one, both of which shrink the match set.)
  **The picker is a floating window** (`ui.centered`), helix-style: a rounded
  border with the picker's name sunk into the top edge and `Esc to close`
  into the bottom, the editor still painted behind it, and a click anywhere
  outside dismissing it — a border promises a thing you can close, and the
  mouse has to keep that promise. It is centred over the *text*, never over
  the file tree, so a `zedit <dir>` session still shows the tree it is there
  to browse. On a terminal too small for a border (`ui.centered` returns
  null) the picker takes the whole view as it always did. Because
  `pickerLayout` feeds the renderer *and* the click hit-test, the box
  propagated to both at once — the draw-here-click-here invariant paying for
  itself. Every picker uses one layout: the title bar on row 1 (when enabled), the
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
  opens it — so a double-click opens from anywhere, without going near the
  click counter (a picker click never touches it) — while explorer rows
  toggle/open exactly as in normal mode (a
  file-open closes the picker first) and a tab click closes the picker and
  lands on that buffer; the prompt row and the preview stay inert, so
  terminal text selection keeps working there. `zedit <dir>` opens
  straight into that view (tree + search + preview), which is what an empty
  session shows instead of a blank buffer. The preview is skipped for remote
  entries (an ssh round trip per keystroke) and on narrow terminals, where the
  results take the full width.
  Note the three search scopes: `/` searches the current buffer, `Space f w`
  searches file *contents* across the project, `Space f f` matches file *names*
  — a `zedit <dir>` session says so in a one-time status line, and a files
  query with zero matches shows a dim hint row pointing at `Space f w` (with
  nothing to preview, those results take the full width — but only once a
  query has been typed: before that the pane stays reserved, so a cold
  `zedit <dir>`, which paints before the walk delivers a row, does not
  re-lay itself out a frame later). A status message
  raised while a picker is up owns the view's **bottom row**, dim — the
  picker has no statusline of its own — and `pickerLayout` reserves that row
  instead of painting over the list, so the renderer and the click hit-test
  keep agreeing on which rows are results.
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
  `:{number}` goto line, `:$`; `ZZ`/`ZQ`.
- **Ex ranges (`:[range]cmd`, `exrange.zig`):** every address vim writes —
  `%`, `.`, `$`, a line number, `'a`, `'<`/`'>`, `/pat/`, `?pat?`, `+n`/`-n`
  offsets that repeat and add up, joined by `,` or by `;` (which moves the
  cursor to the first address before reading the second). Parsing is pure and
  unit-tested; only resolution needs the buffer. Out-of-range addresses
  **clamp** where vim raises E16, and a backwards range is swapped silently
  where vim asks first — both because "never crash on bad input" outranks the
  error message, and both nvim-pinned at the result.
  The commands that take one: `d`, `y`, `>`, `<`, `j`, `s`, `normal`, `g`/`v`.
  A range with no command moves to its last line (`:5`, `:$`, `:1,5`), which
  is where the old `:{number}` special case went. Putting a range in front of
  a command that takes none says so rather than dropping it.
  **`:[range]g/pat/cmd`** and **`:v`** (inverse) are vim's two passes: collect
  every matching line first, then run the command on each, so a command that
  inserts or deletes cannot disturb a search still in progress. The remaining
  targets move by the *line count's* change rather than the buffer's edit
  log — `settleFolds` drains that log after every key and `:normal` feeds
  keys, so it is empty by the time this could read it. That assumes the
  command changed lines at or after the one it ran on, which is what vim's
  real marks would track exactly. Defaults to the whole file; `:g` with no
  command reports the match count, since there is no `:p` to print with.
  **`:[range]normal[!] {keys}`** feeds the keys through the same `replayBytes`
  a macro uses — once at the cursor with no range, once per line from column 0
  with one — and appends the implicit `<Esc>` vim does, so `:%normal A!`
  leaves normal mode. `!` is accepted and ignored: there are no mappings to
  suppress. `execLine` is depth-capped at 8, so `:g/x/g/y/d` terminates.
  **Tab completion** (nvim
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
  none, Up/Down stay history. Completion applies to the text **before the
  cursor** and keeps whatever follows it — the ring, the stem restore and the
  directory keys all put the tail back and leave the cursor between the two
  (nvim, probed). **Mid-line editing** (nvim-pinned in
  `vim_compat`): the cmdline cursor moves with `Left`/`Right`,
  `Home`/`End` (vim's `Ctrl-b`/`Ctrl-e` too); typed and pasted text inserts
  at the cursor, backspace deletes before it (a no-op at column 0 of a
  non-empty line; an empty line still cancels), and history recall or wild
  cycling puts the cursor at end-of-line (vim's rule). `Delete` takes the
  character *under* the cursor — at end-of-line the one before it, and on an
  empty line it cancels like backspace; `Ctrl-w` erases the word before the
  cursor together with the whitespace it skipped over (vim's classes: a
  punctuation run is a word of its own, and kana/kanji/ASCII never merge —
  the pure rule is unit-tested as `wordEraseStart`); `Ctrl-u` erases from the
  start of the line to the cursor, keeping the tail, and never cancels;
  `Ctrl-r{reg}` inserts a register (`a`-`z`, `"`, `+`/`*`) at the cursor,
  drawing vim's `"` at the cursor while it waits, with Esc abandoning the
  prompt and an unknown or empty register inserting nothing. A multi-line
  register inserts one CR per interior line break and drops the trailing one
  (nvim shows `^M`; zedit's sanitizer shows `?`, since register text is
  untrusted). A line **wider than the row wraps upward** over the window
  rather than scrolling sideways (nvim's command-line area growing, probed):
  the block is bottom-anchored at the status row, the rows above it are an
  overlay the next frame repaints, the wildmenu popup sits above the whole
  block, and the ghost continues on the cursor's row. Rows break on
  codepoint boundaries by display cells, so a wide char that would straddle
  the edge starts the next row and vim's `>` marks the cell it left over
  (`cmdRowSplit`, unit-tested; on a terminal narrower than the char itself
  it is taken anyway, since no row could hold it and a row that consumes
  nothing would never let the layout advance). **History**
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
  tiling. `Space e` is VS Code's three-state cycle: closed → open + focused;
  open but unfocused → refocus it (no rebuild — selection and scroll survive,
  the keyboard route back into an Esc'd tree); open + focused → close.
  Its "EXPLORER" header lives in the title bar when that row is shown
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
  **`]g`/`[g` step between hunks** — counted, wrapping at both ends, and no
  jumplist entry (its sibling `]d` takes none either). A hunk *starts* where
  a signed line follows an unsigned one, so a five-line change is one stop
  rather than five; the signs `git.computeHunks` already produces for the
  gutter and all three views are the whole source, so the motion costs one
  pass over that map and no extra subprocess.
- **Debugger (`Space d`, `:debug`):** a DAP client (`dap.zig`) speaking the
  same `Content-Length` framing as LSP — shared in `jsonrpc.zig`. `Space d b`
  toggles a breakpoint on the cursor's line, `d B` clears them all, `d c`
  starts or continues, `d n`/`d i`/`d o` step over/into/out, `d q` ends the
  session. `:debug <program> [args]` launches: the adapter comes from `--dap`
  or a per-filetype default (`lldb-dap` for C/Zig/Rust, `debugpy` for Python,
  `dlv dap` for Go), exactly as the language server does. Breakpoints are
  **editor** state, not session state — set them before anything runs, and
  they survive the program exiting; the set is sorted and deduplicated
  (`dap.Breakpoints`, unit-tested) because DAP replaces a file's whole list on
  every change. They render as a `●` in the gutter, ahead of the diagnostic
  and git signs, and the one the program is stopped on turns amber. A `stopped`
  event triggers a `stackTrace`, whose top frame's file and line is where the
  cursor goes. The adapter's stdout is polled with everything else, so a
  stopped session costs zero CPU. Everything the adapter sends is untrusted
  and reaches the screen through the usual sanitizer. Absent: variables and
  scopes, watches, REPL evaluation, conditional and function breakpoints,
  attach, and multiple threads (`stopped` names one and steps go to it).
- **Embedded terminal (`Space t`, `:terminal`):** a real shell on its own pty
  in a horizontal split, with zedit as its terminal emulator. `vt.zig` is the
  emulator — a pure state machine (grid in cells, no pty, no rendering) so the
  parser is unit-testable, covering the C0 controls, cursor movement, erase,
  insert/delete of lines and characters, scrolling regions, xterm's deferred
  wrap, and SGR colour (the 16 ANSI colours, the 256-cube and truecolour);
  `term.zig` owns the OS half (`posix_openpt` + fork + exec, resize, reap).
  Modes follow nvim: keys go to the child in **Terminal** mode, `Ctrl-\`
  `Ctrl-n` returns to normal, and `i`/`a`/`o` go back in. The child is told
  `TERM=xterm`, deliberately not `xterm-256color`, because claiming the latter
  invites the alternate screen and mouse reporting that `vt.zig` does not
  implement. Several terminals can be open at once, named `t1`, `t2`, … and listed on
  their **own tab row** across the top of the pane they share — VS Code's and
  Zed's panel, where terminals are their own list rather than buffers mixed in
  with the files (they are kept out of the buffer tabline for the same
  reason). Each tab carries the same `✕` — clicking it closes that terminal,
  and the pane stays as long as another is open — and `Space t` adds another.
  A shell that exits (`exit` at the prompt) closes its terminal on the spot,
  as in VS Code and Zed: waiting for a keypress to dismiss something already
  finished is a second thing to do for no reason. The grid is read-only to buffer commands (`dd` answers
  "this is a terminal — i types into it") so it can never go dirty and block
  `:q`, and an exited shell keeps its last output on screen until any key
  dismisses the window. Everything the child writes is untrusted: escapes
  become emulator state rather than text, and a C1 control that survives into
  the grid renders as `?` through the same sanitizer as buffer content.
  The pty is polled alongside stdin and the language server (`waitReady`
  takes all three), so an idle shell still costs zero CPU — pty-verified,
  including after the shell exits. Reading back: the wheel in Terminal mode,
  and `Ctrl-u`/`Ctrl-d` in normal mode over the window, page through a
  **scrollback** of 5000 rows — rows that leave the top of the *screen*, not a
  scrolling region's (those are a full-screen program redrawing in place, and
  keeping them would fill the history with noise). Any new output snaps the
  view back to live, and a width change drops the history rather than
  reinterpreting rows of the old width. **Queries are answered.** A shell asks what terminal it is talking to, and
  one that never replies is not a slow terminal but a broken one: fish sends
  XTGETTCAP as a device-control string (`ESC P +q<hex> ST`) and a Primary
  Device Attributes report (`ESC [ c`), and with neither handled the DCS
  payload printed on screen as `+q696e646e` while fish waited ten seconds for
  the DA answer and then disabled features. DCS is now consumed (and XTGETTCAP
  answered "no such capability", which is faster than a timeout), and
  `ESC[c`/`ESC[>c`/`ESC[5n`/`ESC[6n` get proper replies. `vt.zig` stays free
  of I/O: it accumulates the answer in `reply`, and the editor writes it to
  the pty after each feed. Absent by design: the
  alternate screen (a full-screen program draws over the shell's output
  instead of restoring it), and any mouse or bracketed-paste mode of its own.
- **The rest of the `z` namespace.** `z<CR>`/`z.`/`z-` are `zt`/`zz`/`zb`
  plus the line's first non-blank, which is the only thing separating them;
  `z+` starts on the line below the window and `z^` on the one above it, then
  behave like those two — both call `scroll()` first, since a burst of keys
  (`50Gz+` in one read) reaches the handler before the frame that would have
  settled the viewport. `zh`/`zl`, `zH`/`zL` (half a screen), `zs`/`ze` and
  `z<Left>`/`z<Right>` scroll sideways, and do nothing while soft wrap is on
  — which is exactly what vim documents them as needing. `zp`/`zP` are the
  blockwise pastes that add **no padding** to a short line, and `zy` the yank
  that drops each segment's trailing blanks (`block_pad`, and the trim in
  `blockYank`). Fold-wise: `zA`/`zC`/`zO` act recursively, `zD` deletes a fold
  and everything nested in it, `zF` folds N lines, `zj`/`zk` step between
  folds, `zv` opens just enough to see the cursor, and `zi`/`zn`/`zN` are
  'foldenable'.
  **`foldlevel` is real state now** (`fold.zig`): a fold is closed when its
  nesting depth exceeds the level, which is what `zm`/`zr` move, `zM`/`zR`
  drive to the ends and `zX`/`zx` re-apply — while `zo`/`zc`/`za` set one
  fold's flag directly and stand until the level moves again. vim's model,
  nvim-probed with `foldclosed()`.
  Not implemented: the **spell family** (`z=` `zg` `zG` `zw` `zW` and the
  `zu*` undos) needs a dictionary and a suggestion engine, and
  `z{height}<CR>` sets an *absolute* window height where zedit's windows
  carry relative weights on purpose — an absolute height means something
  different on every terminal, which is the reason the weights exist.
- **Folds (`zf`, `zo`/`zc`/`za`, `zR`/`zM`, `zd`/`zE`):** `zf{motion}`
  collapses the lines the motion covered into a single header row —
  `▸ N lines: text`, the header's own text with what it hides — and the body
  is simply not drawn. `zo` opens, `zc` closes, `za` toggles, `zR`/`zM` act on
  every fold, `zd` removes the innermost one and `zE` all of them. Nesting
  works: `closedAt` returns the *outermost* closed fold covering a row,
  because that is the header on screen. `j`/`k` treat a closed fold as one
  line — landing on its header, and stepping off from the line after its end —
  so escaping a fold takes one press, not one per hidden line, and the cursor
  can never sit on a row that is not drawn. Folding is not editing: it works
  on a read-only buffer (folding a diff view to read it is reasonable) and
  never marks one dirty. Folds move with the text: `buffer.zig` *records* each
  line insertion and removal (`LineEdit`, three call sites — `splitLine`,
  `insertLineAt`, `removeLineAt`) and the editor drains that log into every
  document's fold set after each key, so a fold keeps covering the same lines
  when an edit above it shifts them and is dropped when its lines are deleted.
  The rules are unit-tested in `fold.zig` away from any screen. No
  `foldmethod`/`foldlevel` settings, no fold column, and no persistence —
  vim loses manual folds on close too.
- **Quickfix list (`Ctrl-q`, `]q`/`[q`, `:copen`):** a picker finds things and
  then forgets them; the quickfix list keeps them. `Ctrl-q` in the grep,
  references or diagnostics picker sends **every** result to the list
  (Telescope's binding), `]q`/`[q` walk it — counted, wrapping at both ends,
  each jump recorded in the jumplist so `Ctrl-o` comes back — and `:copen`
  shows it in a horizontal split as a read-only report where `Enter` opens the
  entry under the cursor. The list window is opened *in the window above it*,
  vim's rule: replacing the list with the file would lose the very thing being
  worked through. `:cclose`, `:cnext`/`:cprev`, `:cfirst`/`:clast` and
  `:cc {n}` round it out. The list is editor state, not per-document, and the
  entries own their strings — they outlive the picker, and the files they name
  need not be open.
  **`:cedit` / `Space x e` opens the list as a *multibuffer*** — Zed's idea,
  and the editable rendering of the list zedit already had. Every hit's
  surroundings (two lines each side) are stitched into one ordinary,
  *editable* buffer under a `── path:line` header per excerpt, and one `:w`
  writes every file it touched. Overlapping and touching runs merge
  (`multi.spans`, unit-tested), so no source line is ever shown twice — two
  excerpts sharing a line would each write the other's edit away. The
  excerpts pair with the header rows **in order**, which is what makes
  inserting and deleting lines inside one need no bookkeeping at all: the
  body is whatever now lies between two headers. A header that was edited or
  removed breaks that pairing and the write refuses by name rather than
  guessing. Each excerpt also remembers the source lines it was built from,
  so a file changed behind the multibuffer's back is reported, not clobbered
  — and after a successful write the excerpts *are* the files, so a second
  `:w` is a no-op. Multiple cursors work across excerpts for free: they are
  ordinary buffer lines. Limits: no per-excerpt syntax highlighting (the
  buffer is one document of mixed languages, so it renders plain), 200
  excerpts per list, and `:w <name>` is refused — the stitched view belongs
  to no file. The list is **sorted by file then line** when a picker
  fills it: results arrive in project-walk order, which is the filesystem's,
  so an unsorted list walked the same matches in a different sequence on a
  different machine (CI caught exactly that). `openFile` takes a **0-based row** while an entry's line
  is 1-based; both this and the debugger's stop location got that wrong at
  first, and `placeAt`'s clamp to the last row hid it whenever the target sat
  near the end of a file.
- **Sessions (`Space S`, `:session`):** the open files with their cursors,
  the split layout and whether the tree was open, saved per working directory
  under `$XDG_STATE_HOME/zedit/sessions/<hash of the cwd>` (the cwd itself is
  stored inside and checked, so a hash collision cannot restore the wrong
  project). Restoring reopens the files, remakes the splits and gives window
  *i* the *i*-th file — a three-pane session comes back as three panes showing
  what they showed, not the same buffer three times. Both directions are
  **explicit**: nothing is saved on exit and nothing is restored on launch, so
  the "never do work the user did not ask for" rule holds. A restore refuses
  while any buffer is unsaved (naming it) rather than closing over the work,
  a file that has since disappeared is skipped and counted in the message
  rather than being fatal, and an unknown directive in the file is ignored so
  a session written by a later version still restores what this one
  understands. Only a *visible* file's cursor comes back: the editor keeps a
  cursor per window, not per buffer, so a buffer on screen nowhere has none to
  restore (it is still saved, for when there are enough panes). The file cap
  is 200, which bounds what a malformed session can make the parser allocate.
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
- **Breadcrumbs:** the enclosing symbol path — `Outer › helper` — dim in
  whatever the tabs leave of the **title bar row**, which is where VS Code and
  Zed put it. Not a row of its own: a terminal row is scarcer than a GUI one,
  and spending one on decoration would also have moved every viewport number
  the `view` and `vim_compat` suites pin against real nvim. It reads out of
  the syntax tree (`treesitter.crumbs` walks the ancestors of the node under
  the cursor), so it costs no language server and no allocation — each name
  span goes back through `posOfByte` and is sliced from its line, since
  serialising the buffer per frame would be an O(file) copy in the render
  path. The kinds are the structural-object tables (`ac`/`af`), so a language
  that gains those gains breadcrumbs with it and one with no grammar simply
  has no path. Where a name *lives* differs per grammar, and `nameSpan`'s four
  rules were dumped out of the vendored trees rather than assumed: a `name`
  field (Python, Rust, Go, JS/TS, Zig's functions), a `declarator` field (C,
  where the identifier is inside a `function_declarator`), the first direct
  identifier child (Rust's `impl Thing`), and failing those the *parent*'s
  (Zig's `const Foo = struct {…}`, and C's `typedef struct {…} Foo`).
  Consecutive crumbs with the same name span collapse — JavaScript's
  `class_body` is in the object table and rule 4 hands it its class's name.
  The file name is not repeated in the path: the active tab beside it says
  that already. With `buffer_tabs = false` there is no title bar and so no
  breadcrumb, and with enough tabs to fill the row it is simply not drawn.
- **Sticky scroll** (config `sticky_scroll`, on): the lines that *open* the
  scopes you are inside — the struct, the function — pinned to the top rows
  while you scroll through them, on the statusline's segment background so
  they read as chrome rather than as text that scrolled oddly. The same
  ancestor walk as the breadcrumbs, asked where each scope starts
  (`treesitter.scopeStarts`) instead of what it is called.
  It is an **overlay**, drawn over rows the window has already emitted, so
  the viewport is untouched: `top`, `H`/`M`/`L`, every paging motion and the
  screen-to-buffer click inverse all mean exactly what they meant, which is
  what the whole vim-compat suite is pinned against — and a pty check asserts
  the last visible line is the same with the pins and without. The price is
  that pinned rows cover text, so **they yield to the cursor** rather than the
  other way round: at most `cy - top` rows are drawn (and never more than a
  third of the window), so scrolling until the cursor reaches the top row
  simply leaves none. VS Code scrolls the view instead; this keeps a promise
  that matters more here. Short of room the **innermost** scopes are kept —
  which function you are in the middle of is what scrolling took away
  (nvim-treesitter-context's `trim_scope = 'outer'` default, the same call).
  The frame carrying pinned rows is written whole and its covered rows
  dropped from the diff base, like every other overlay. Skipped in a diff
  pair and the line-diff weave, which have virtual rows of their own, and in
  inactive windows, which have no live tree.
- **Title bar:** one powerline row across the top (config `buffer_tabs`,
  default on — always shown while enabled, VS Code-style, even for a single
  file): an "EXPLORER" segment spanning the sidebar's columns when it is open
  (accent bg while the tree has focus, else the statusline segment colours —
  a flat box like the tabs beside it, with no separator glyph: the colour
  change is the boundary), then one tab per open buffer over the
  text area — each a **flat box**, a padded run of its own background, the
  same shape the terminal tabs use: no powerline separator between them,
  because the colour change already reads as the boundary and an arrow
  between every pair made a row of tabs look like a breadcrumb trail rather
  than a set of them. (The EXPLORER header keeps its separator, being a
  The active tab is
  an accent segment (`mode_normal` bg), inactive ones dim on `status_bg`,
  unsaved marked with `●`. `nerd_font = false` still degrades the header
  separator and the statusline to the flat look. While the bar is up the filename
  leaves the statusline (see below). **Clicking a tab's `✕`** closes that buffer (a terminal tab ends its
  shell); the box is always drawn rather than shown on hover, because hover
  needs mouse mode 1003, which reports every pointer movement and would wake
  an idle editor thousands of times a minute — two columns cost nothing.
  **Clicking a tab** switches to that
  buffer — the renderer and `tabAt` share one geometry helper (`tabArea` +
  `tabCells`), so a tab can never be drawn at one place and clicked at
  another; a click on the EXPLORER segment focuses the tree (see the
  sidebar bullet), and clicks anywhere else are ignored so the terminal's
  own text selection keeps working. `buffer_tabs = false`
  removes the row entirely and restores the statusline filename.
- **Notifications (`notify.zig`):** the things that *happened* — "copied 6
  bytes to the clipboard", "cannot open locked.txt" — stack as toasts in the
  top right under the title bar, AstroNvim's nvim-notify position, and expire
  on their own after 3 s. The statusline still says what the *state* is; a
  toast says what just happened, which is why it is not a wrapper around
  `setStatus`. The queue is fixed-size and allocation-free (3 slots, 96 bytes
  of text, truncated on a codepoint boundary), and its text goes through the
  render sanitizer like any other untrusted content. The expiry does **not**
  cost idle CPU: `nextDeadline` hands the main loop one point in time to wake
  for, `pollTimeout` takes the sooner of that and the completion debounce, and
  with nothing showing there is no deadline at all — so an idle editor is back
  to blocking in `poll(2)` for ever (pty-checked: under 20 ms of CPU over 2 s
  idle after a toast).
- **The Ctrl namespace.** `Ctrl-a`/`Ctrl-x` add or subtract from the number
  at or after the cursor — vim's rules, nvim-probed: a leading `-` belongs to
  it, `0x` makes it hexadecimal, leading zeros keep the written width (`0042`
  → `0043`, and nvim's default `nrformats` has no octal, so `007` → `008`),
  and the cursor ends on the number's last character. The finding rule is
  pure and unit-tested (`motion.numberAt`), including the case the first
  attempt got wrong: a cursor sitting on a hex *letter*, which no forward
  scan for a decimal digit ever reaches.
  `Ctrl-e`/`Ctrl-y` scroll one line, taking the cursor only when it would
  otherwise leave the screen; `Ctrl-g` names the file and says where in it
  the cursor is; `Ctrl-^` flips to the buffer shown before this one.
  `Ctrl-w` gained `t`/`b` (first/last window), `p` (the *last accessed* one,
  which is not the previous one in the tiling), `W`, `x` (swap), `r`/`R`
  (rotate), `H`/`J`/`K`/`L` (move to an end — the tiling is flat and
  single-orientation, so each pair means one end), `n`, `f`/`F`, `d`/`i`
  (split then goto definition/declaration), `^`, and `_`/`|` which maximise
  along an axis, that being the honest reading of an absolute size on a
  relative layout.
  **`Ctrl-z` suspends** (`term.suspendSelf`): everything the editor took goes
  back before the process stops — raw mode, the alternate screen, mouse
  reporting, bracketed paste and the window background, which is exactly
  `restore` — and is taken again when the shell continues us, with the window
  size re-read and the whole frame redrawn since the shell has been writing
  over the primary screen. The signal is *raised* rather than left to the
  terminal driver, because raw mode turns `ISIG` off: Ctrl-Z reaches zedit as
  a byte, which is why this is a key handler at all.
  Testing it needed the harness to learn job control (`job_control` in
  `SpawnOpts`): its child is a session leader whose parent lives in another
  session, so its process group is **orphaned**, and POSIX requires a stop
  signal sent to an orphaned group to be discarded. A test written against
  the plain spawn passed with the `raise` deleted. The option adds the middle
  process a shell would have — session stub forks the job into its own group
  and hands it the terminal with `tcsetpgrp`, SIGTTOU ignored across the call
  as every shell does.
  Not implemented: `Ctrl-t` and `Ctrl-]` want tags, `Ctrl-<Tab>` wants tab
  pages, and `<Help>`/`<F1>` want a help system. `Ctrl-h`/`j`/`k`/`l`, `Ctrl-n`/`Ctrl-p` and `<Space>` keep
  zedit's meanings (window navigation, multiple cursors, the leader) over
  vim's plain motions, as they always have.
- **Window navigation (`Ctrl-h`/`j`/`k`/`l`):** AstroNvim's window keys, moving
  focus directionally rather than cycling, with the **file tree as the window
  beyond the edge it is docked to** — so `Ctrl-h` steps into the explorer and
  `Ctrl-l` steps back out (mirrored for `sidebar = right`). They do not wrap:
  `Ctrl-w w` is the cycle, this is a direction. The keys are `0x08` and `0x0a`
  on the wire — the same bytes as Ctrl-h and Ctrl-j have always been — and a
  terminal sends `0x7f` for Backspace and `0x0d` for Enter, so the pairs are
  distinguishable, which is how nvim binds `<C-h>`/`<C-j>` at all. `key.zig`
  decodes them apart and the editor turns them back into Backspace/Enter
  everywhere except normal mode, so insert mode, the command line, the pickers
  and the prompts are untouched (pty-pinned both ways).
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
  forced with `:bd!`, which discards. `Space c` routes through the same close
  (`Space b c` closes every *other* buffer instead). Split the view with `:split`/`:vsplit` (or `Ctrl-w s`/
  `Ctrl-w v`), move focus with `Ctrl-w w`/`h`/`j`/`k`/`l`, and `:close`/`Ctrl-w
  c` / `:only` manage them. Splits tile evenly in one orientation; each window
  shows any buffer (the same buffer can be open in two windows). Per-window
  status lines appear when more than one window is open.
- **LSP:** a language server is launched per filetype (`zls`, `clangd`, `pylsp`,
  `typescript-language-server`), or any command via `--lsp`. Diagnostics show as
  gutter signs + a statusline message/count; `K` hovers (`Ctrl-k` in insert
  mode), `gd` goes to definition, `gi` to the implementation, `gy` to the type
  definition — **into another file when the server names one**, which they
  did not until 0.63.0: the uri came back, was freed unread, and the line was
  applied to whatever buffer was open, so a cross-file `gd` silently moved
  the cursor to that line number in the file you were already in.
  `Space l p` **peeks** it instead — VS Code's `Alt+F12`, which a terminal
  cannot deliver — showing the definition in a floating window over the file
  being read rather than jumping there and relying on `Ctrl-o` to come back.
  The window owns the keyboard while it is up (`Enter` takes the jump for
  real, `Esc`/`q` close, `j`/`k`/`Ctrl-d`/`Ctrl-u`/the wheel scroll, a click
  outside dismisses it) and borrows the picker's preview cache: the same
  read, the same shared tree-sitter highlighter, because it is the same job —
  show a region of another file quickly without opening it.
  `Space l P` **peeks the references** — VS Code's `Shift+F12` — which is the
  same window holding more than one place: the title counts them (`(2/5
  references)`), `n`/`p` (or `Tab`/`Shift-Tab`) step and the view follows,
  wrapping, and `Ctrl-q` sends the whole set to the quickfix list, the
  binding a picker already has for the same reason. A single-place peek says
  "only one definition" rather than pretending to step. What it deliberately
  does *not* draw is VS Code's side list of the references: `Space l R` **is**
  that list, with a fuzzy prompt and a preview, and a second copy of it would
  be duplication rather than a feature. The difference between the two is
  therefore real — `l R` is for finding one among many, `l P` for reading
  them where they are.
  `gr` renames the symbol under the cursor
  (prompts on the command line, pre-filled with the identifier), `Space l R`
  lists references in a picker ("path:line: text", Enter jumps there),
  `Space l S` searches **workspace symbols** (the query goes to the server,
  which matches across files zedit has never opened; re-asked after the same
  typing pause auto-completion uses), `Space l D` lists **every diagnostic**
  across the open buffers tagged by severity, `ga`
  lists code actions for the current line in a picker and applies the chosen
  one, and `]d`/`[d` jump to the next/previous diagnostic line (wrapping;
  `[count]` repeats). `]e`/`[e` and `]w`/`[w` do the same restricted to
  **errors** and **warnings** (AstroNvim's keys): `]d` walks every severity,
  so a file carrying two hundred hints buries its errors and no key reached
  them. The filter is one argument on `lsp.nextDiagLine`, not a second walk. Each diagnostic's message also renders inline at the end
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
  arrows to move, **`Tab`** to accept, `Esc` to dismiss — and `Esc` **also
  leaves insert mode**, a deliberate divergence from vim and nvim, where it
  only closes the popup. There the popup is something you asked for with
  `Ctrl-n`, so eating the key is fair; here it appears by itself after a
  typing pause, which made "press Esc, be in normal mode" true or false
  depending on how long you had paused. The suite could not see it either:
  `sendKeys` types at 90 ms, just under `completion_delay_ms`, so every other
  editing test types faster than a human and never raises a popup at all). `Enter` is a
  newline, never an accept — typing a word that happens to raise the popup and
  pressing Enter for a new line must not silently insert whatever was
  highlighted (VS Code's `acceptSuggestionOnEnter: off`, and helix's rule). **With no
  server** — none installed for the filetype, or one that returns nothing —
  the same popup fills from the identifiers in the open buffers (vim's
  keyword completion, `complete.zig`; config `buffer_completion`, on by
  default): the current buffer first, then the others, deduplicated, ranked
  with `fuzzy.score`, and never offering the word being typed at the cursor.
  The scan walks **outward from the cursor line** so the caps keep the
  *nearest* words (top-down filled all 200 slots a thousand lines above the
  cursor, and the name on the line you just wrote was never offered). It runs
  on the same debounce (never per keystroke) and is bounded three ways —
  1000 lines each way, 128 KB of text, 200 candidates, the byte budget shared
  across every buffer. The byte budget is the one that always bites: `cap`
  limits what is *kept*, but dedup costs a scan of the kept list per word
  *examined*, so a file with a small vocabulary used to scan megabytes —
  measured at 82 ms a harvest, now 2.3 ms worst case (78–144 µs on ordinary
  source). The words are *copied* into a reused byte arena, because the popup
  outlives the buffer edits made while it is open. A server that exited or
  crashed counts as "no server" too, so completion keeps working instead of
  posting requests into a dead pipe.
  When the filetype *has* a known server that failed to launch, the
  statusline says so once for the document ("no language server for python
  (install pylsp); completing from open buffers"); a filetype with no known
  server stays silent. The list is
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
  **The handshake never blocks.** A server that is *starting* counts as a
  server, not as none: a completion asked for in that window waits and retries
  rather than being dropped (`lspStarting`), and no request is sent before
  `initialize` is answered — the first inlay-hint request waits for readiness
  (`lsp_opened`).
   `initialize` is sent at spawn and the reply
  is picked up by the ordinary poll loop, which then sends `initialized` and
  `didOpen`; until it lands, `Client.ready()` is false and every request path
  treats the server as absent. It used to wait up to four seconds inline —
  the file was painted, so the editor *looked* ready while ignoring every
  keystroke, which is the decorate-after-paint rule broken one step later.
  rust-analyzer routinely takes that long, so the freeze was real and only
  showed where a slow server happened to be installed (pinned by the `lsp`
  scenario's `--slow-init` mock).
  Best-effort: no server installed simply means no LSP. Its stdout is polled
  alongside the terminal, so an idle editor still uses no CPU.

## Appearance

The renderer aims for an AstroNvim/Helix look: true-colour themes in
`theme.zig` (Tokyo Night default, plus Gruvbox, Catppuccin Mocha, Nord and One
Dark — set in the config, or live via `:theme` / the `Space f t` picker,
which **previews as you move**: the editor repaints in each theme, `Esc` puts
back the one that was showing, and `Enter` writes `theme = <name>` to the
config so the choice survives a restart. The write edits that one line and
leaves comments, blank lines and every other setting alone — the config is
the user's file, not ours to regenerate — and a commented-out
`# theme = …` is left as it is with the real setting appended, since
uncommenting someone's line changes more than the one thing they asked for
(`config.setKeyIn`, unit-tested including `wrap` vs `wrap_column`)), a
powerline title bar (EXPLORER segment + buffer tabs, see above) and statusline
(coloured mode block, separators, the command as typed
right-aligned beside the position — vim's 'showcmd', capturing the *decoded*
key, never raw bytes: characters and control keys read back as text (`^W`),
and special keys render their **name** (`<Down>`, `<Esc>`, `<PageDown>`,
`<BS>`) and hold it until the next key — a deliberate divergence from nvim,
which shows nothing for them, made because the user could not tell an arrow
press from a dropped one; what nvim's rule really forbids is the *raw bytes*,
and an arrow used to smear `^[[B` across the indicator;
the finished command
stays readable until the next one starts, and yields its width to a status
message — plus filetype/position/percent segments; the filename+dirty segment
appears only when the title bar is off, since the active tab already shows it
— a nerd font is recommended for the
glyphs, and the config's `nerd_font = false` swaps in a flat statusline whose
width budgets drop the separator cells, painting edge to edge in any font),
syntax highlighting (tree-sitter for 10 languages (Zig/C/Python/JSON/JS/TS/Rust/Go/HTML/Markdown) via
`treesitter.zig`, with language injections — a python-tagged fenced block in
Markdown is highlighted as Python, a `<script>` body as JavaScript — and the grammars' own
query predicates honoured; the `syntax.zig` lexer otherwise), relative+absolute line numbers, a
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

**The window padding matches the theme.** A terminal window is rarely an
exact multiple of the cell size, so a few pixels are left over along the
bottom and right edges — painted by the terminal in *its* background colour,
which is the strip that showed through beside a themed editor. Every cell of
the grid is painted (measured: no row, and no cell, is ever left on the
default background), so the fix is not in the renderer: zedit asks the
terminal for its background (`OSC 11 ; ? ST`), paints the window in the
theme's (`OSC 11 ; rgb:…`), and restores the original on the way out —
including the panic path, which is why the state lives in `term.zig` rather
than the editor. `setBackground` is idempotent, so `render` simply calls it
every frame and a theme change (the picker's live preview included) is
picked up with no notification path. A terminal that ignores the query is
never recoloured at all: no answer, no change. Config `sync_background`.
The reply arrives on stdin like any other input, which is why `key.zig`
decodes OSC at all — before it did, `ESC ]` read as the Escape *key* and the
rest of the report was typed into the buffer as text.

**Window sizes are relative.** `Ctrl-w +`/`-`/`<`/`>` resize the focused
window by a cell or a count, `Ctrl-w =` evens them up, and the difference is
taken from the other windows a cell at a time so none is squeezed below one.
A `Win` carries a `weight` rather than a size, and `layout` divides the axis
by weight (`share`) — so a layout survives a terminal resize and means the
same on any screen. That is what makes it worth persisting: `:winsave`
writes the proportions to the config as `split_sizes` (normalised to sum to
the window count, so they read `1,2` rather than `41,82`), and a later split
with that many windows picks them up by itself. A plain split still tiles
evenly: the new window inherits its parent's weight, so nothing changes until
a resize or a saved layout says otherwise.

**The keymap (`keymap = vscode | zed | vim`), and `vscode` is the default.**
Out of the box the editor is **non-modal**: it starts able to type, letters
are always text, and the commands live on chords — `Ctrl-s` save, `Ctrl-p`
files, `Ctrl-f` find, `Ctrl-h` replace, `Ctrl-z`/`Ctrl-y` undo/redo,
`Ctrl-c`/`Ctrl-x`/`Ctrl-v` clipboard, `Ctrl-a` select all, `Ctrl-/` comment,
`Ctrl-b` explorer, `Ctrl-w` close, `Ctrl-d` select the word and then each
next match; Shift+arrows select, Ctrl+arrows move by
word, Ctrl+Home/End reach the file's ends, Alt+Up/Down move a line and
Shift+Alt+Up/Down copy it. `Esc` drops a selection or closes a popup and
never leaves you unable to type. `zed` is the same table under its own name:
Zed ships VS Code's bindings on Linux by design, and a user who reaches for
one should not be told about the other. `keymap = vim` is the modal editor
this file otherwise describes, unchanged — and `zedit --keymap <name>`
(`-k`) picks one for a single run without touching the config, which is also
how the pty suite says which editor each of its 1750 checks is testing. The
tutor forces `vim` whatever the config says: it teaches modal editing, and
under the default its first instruction ("press j") would type a letter into
lesson 1.

It is an *emulation, not a hybrid* — under `vscode` the vim commands are
genuinely not reachable, which is the point. What it does **not** do, all
recorded rather than papered over:
  * **A selection includes the cell under the caret**, because that is zedit's
    visual model. VS Code's caret sits between characters, so a selection here
    is one character wider at that end, and `Esc` leaves the caret one further
    on. Making it exact means changing the visual model every vim check is
    pinned against, which is a bigger change than it looks.
  * **A multi-selection lives within one line** and is built only by
    `Ctrl-D`. VS Code also has `Ctrl+Shift+L` (all occurrences at once),
    `Ctrl+K Ctrl+D` (skip this one) and Alt+click; Helix builds a set from a
    regex over the current selection. None of those are here.
  * **`Ctrl+Shift+…` chords are unavailable**, because a terminal cannot tell
    `Ctrl+Shift+P` from `Ctrl+P` — the shift bit never reaches the
    application for a letter. The command palette is reached the way VS Code
    also offers (`Ctrl-p` then `>`); project search has no key of its own.
  Undo granularity is also coarser than VS Code's: everything typed since the
  last command is one step, where VS Code breaks on word boundaries and
  pauses.

**The command palette (`Space f C`, or `>` in the file picker).** A
searchable list of every command with the key that runs it — VS Code's
`Ctrl+Shift+P`, Helix's `Space ?` and AstroNvim's `<leader>fC`, which is
three editors agreeing. One `commands` table in `editor.zig` holds the title,
the binding under *each* keymap and what to run; the palette shows the
binding for the keymap in force, because telling a VS Code user to press
`Space f f` is worse than telling them nothing. `Run` is a union rather than
one enum: most commands already have an ex spelling (`.ex = "vsplit"`), the
ones taking an argument open the command line pre-filled (`.prompt =
"theme "` — guessing the argument is worse than handing over the prompt),
the `Space u` flags are `.toggle` with a pointer to the setting, and only the
key-only actions need an `Act` arm, each one call to the function the key
handler already calls. The fuzzy filter matches the title *and* the
spelling, so `vsplit` finds "Split window vertically". The `>` route is VS
Code's own Quick Open prefix and is how the palette is reached under the
non-modal keymap, where `Ctrl+Shift+P` cannot reach the application at all.

**The multi-selection model.** `extra` holds `Sel { head, anchor }` rather
than a bare `Pos`, so a secondary caret can *cover* text: `Ctrl-D` selects
the word under the cursor, and each further press finds the next occurrence
(`search.nextLiteral` from the furthest selection on, so presses walk
forward) and adds it. Typing replaces every selection at once, backspace
deletes them (`deleteSelections` works back to front, so an earlier deletion
cannot move a later one), and `Esc` collapses to a single caret. The
dedupe checks the **primary** selection as well as the extras: `nextLiteral`
wraps, so on a file with one match the search comes straight back to where it
started and would otherwise stack a second selection on the same text. The
renderer asks `extraSelRange` once per row, not per cell, and overlapping
extras on a row merge into the span they jointly cover — all a highlight
needs. `SelSpan` is the ordered pair; the name avoids the renderer's existing
per-row `SelRange`.

  `key.zig` grew a `modified` tag to make any of this possible — Shift+Left
  and Ctrl+Right had never been decoded at all. It is deliberately a separate
  tag rather than a payload on `up`/`down`/`left`/`right`, which are matched
  bare in about a hundred places.

Runtime configuration is one documented file (see `config.zig`): keymap, theme,
`tab_width`, `nerd_font`, `sidebar` (left/right), `relative_numbers`,
`large_file_mb`, `autoindent`, `buffer_tabs`, `auto_completion`,
`completion_delay_ms`, `inline_diagnostics`, `soft_wrap`, `wrap_indent`,
`wrap_column`, `sticky_scroll`, `persistent_undo`, `format_on_save`,
`cmdline_suggestions`,
`buffer_completion`, `mouse`, `mousetime`, `sync_background`, `split_sizes`;
`zedit --init-config` writes the annotated default; `zedit --reset`
resets an existing one back to it, keeping what was there as `config.bak`.
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
  aren't supported). The `g` namespace covers `gg gc gd gr gi gy ga g- g+ gj
  gk g0 g$ gu gU g~ gJ gv gx`; still absent from vim's ~50 are `gf`/`gF`
  (edit the file under the cursor), `g;`/`g,` (the changelist), `gq`/`gw`
  (reflow), `gn`/`gN`, `ge`/`gE`, `gI`, `g*`/`g#`, `go`, `gt`/`gT` (tab
  pages), `g&`, `gR` and `gm`/`gM`. The `z` namespace covers the folds plus
  `zz`/`zt`/`zb`; absent are `zj`/`zk` (move between folds), the recursive
  `zA`/`zC`/`zO`/`zD`, `zm`/`zr`/`zi`, the spelling `z=`/`zg`/`zw` and the
  horizontal `zh`/`zl`/`zH`/`zL`. Brackets cover `]d [d`, `]e [e`, `]w [w`,
  `]b [b`, `]f [f`, `]q [q`, `]g [g`; absent are `[ `/`] ` (add a blank
  line), `[D`/`]D` (first/last diagnostic), the location list `[l`/`]l` and
  matchit's `[%`/`]%`.
  `[count]` before an insert types the text that many times, as vim does —
  the plain family (`3a`, `3i`, `3A`, `3I`, `3o`, `3O`, `nvim#ic1`-`ic10`) and
  the blockwise `3A`/`3I`, where every caret repeats it (`nvim#bc1`-`bc9`). Dot-repeat and macros
  are otherwise nvim-pinned (the `nvim#dm*` tranche in `vim_compat`), counted
  repeats included as far as a *leading* count goes: `[count].` replaces it
  rather than re-running the change, which is what the operator+click case
  needed — its replayed screen cell is re-resolved from a cursor the previous
  replay already moved. A count typed *after* the operator (`d2w`) is still
  multiplied by the new one, since telling a count from an argument in the
  recorded bytes needs vim's normalised redo buffer rather than string
  surgery. Autoindent is vim's 'autoindent' plus the grammar's
  `@indent.begin` nodes (see the Insert section) — there is no smartindent and
  no `@indent.align`. `=` re-indents (`=G`, `==`, `=j`, visual `=`): each line
  follows the nearest non-blank line above it plus the blocks that line opens,
  minus a level when the line itself starts with `}`, `)` or `]`. That dedent
  is the one place such a rule exists, and why `=` has code of its own rather
  than reusing the insert path — the indent engine only ever answered "what
  follows this line". Pinned against nvim's cindent (`c-eq1`-`c-eq8` in
  `indent`), which it matches byte for byte once the file already uses tabs,
  since zedit takes its unit from the surrounding code. Where the tree has nothing to say the copy rule wins outright, so
  `o` *on* a blank line inside a block starts at column 0 (plain vim's answer,
  pinned as `ts-indent#b4`) where nvim-treesitter would indent to the block —
  pty-probed, and the one measured disagreement with it. Cmdline completion covers command names,
  `:e`/`:w` paths and `:theme` (not every command's arguments). The cmdline
  has vim's editing keys (cursor motion, `Delete`, `Ctrl-w`/`Ctrl-u`,
  `c_CTRL-R`, completion of the text before the cursor, upward wrapping), but
  not `q:`/`c_CTRL-F` (the cmdline window), `c_CTRL-R c_CTRL-R`'s literal
  variants or the expression register `=`; `Ctrl-w`'s classes cover
  whitespace/punctuation/word/hiragana/katakana/CJK rather than vim's whole
  `utf_class` table; and a wrapped line taller than the whole screen shows
  the rows around the cursor (nvim's own behaviour there is a full-screen
  redraw that was not pinned). In-buffer search/`:s` are regex, but the syntax is
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
  not have shown it either). Multi-term fuzzy queries have no operators
  beyond the space: every term is a plain fuzzy subsequence, with no negation
  (`!term`), no exact/anchored term and no per-term case rule — and the grep
  picker is not term-split at all, since a space is a legal literal in a
  regex. Statusline separators assume a nerd font.
- Windows/splits use a flat even tiling in one orientation at a time (a split
  re-tiles all windows; no nested/mixed layouts or per-window resizing). Only
  the active window has live LSP polling and an editable selection/search/inlay
  overlay; inactive windows render from their cached state.
- Blockwise paste is a true rectangle, block `A`/`I` pad and skip as vim does,
  and a block edge covers a wide character or a tab whole —.
  Every alignment rule is in display columns, tabs included: a block pasted
  *into* a tab now breaks it into the spaces it was drawing, so the rectangle
  lands on the column it was aimed at.
- Buffer-word completion is a flat word list, not vim's full `'complete'`
  machinery: no completion from included files, tags or the dictionary, and
  no `Ctrl-x` sub-modes. Proximity decides which words are *collected*
  (outward from the cursor until a cap is hit), but the fuzzy score alone
  ranks them, so a nearer match does not outrank a better-scoring far one.
  The harvest reaches 1000 lines each way, 128 KB and 200 candidates, so a
  word further out in a very large file is not offered. A word must start
  with an ASCII letter or `_` to be collected (it may continue with any
  non-ASCII bytes, so `café_count` is kept whole, but `über` is skipped) —
  proper Unicode identifier classification would need a character table.
  `Ctrl-n` with no prefix under the cursor offers nothing, where vim would
  list every keyword.
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
  O(screen) not O(document). **Injections** are real: a grammar's
  `injections.scm` marks regions written in another language and each is
  parsed by that grammar into a child layer (`ts_parser_set_included_ranges`,
  so byte offsets stay document offsets). Markdown fences pick their language
  from the info string when it names one of the ten vendored grammars, its
  inline spans and table cells go to markdown-inline (the old hardcoded second
  layer, now just another injection, and scoped to those nodes rather than to
  the whole file), and an HTML `<script>` body is JavaScript. Regions are
  collected from the *visible* range only, so a fenced block below the fold
  costs nothing; layers are kept and reparsed incrementally (the runtime diffs
  the included ranges against the old tree), never rebuilt per keystroke.
  That bounds *which* nodes are injected, not how far one reaches, so a region
  running past **64 KB** (~1600 lines; the same limit the picker preview puts
  on tree-sitter) is **clipped to the visible range** — a 3.3 MB `<script>`
  starts on screen and used to hand its whole length to the JavaScript parser
  on every keystroke, 88.6 ms a key against 1.5 ms clipped. Under the cap the
  region is parsed whole, which is what keeps a code block running off the
  bottom of the screen highlighted from its real start, and only a frame's
  first and last region can straddle the viewport, so the work per layer is
  the screen plus at most two caps.
  Limits: injection depth is 1 (a child layer's own `injections.scm` is not
  run, so a `<script>` inside a markdown ```html fence is plain HTML — this is
  also what makes the recursion terminate by construction); at most 6 injected
  languages and 64 regions each are live at once — markdown's inline layer is
  one of those six, so a screen showing more than five fence languages loses
  the sixth, and one holding more than 64 separate inline spans (a run of
  one-line paragraphs) loses the last of them; autoindent inside an injected
  region uses the *host* grammar's indent query, which for markdown means
  vim's copy rule; `<style>` stays plain because **no CSS grammar is
  vendored**; and the
  `#offset!` / `#gsub!` / `injection.combined` directives upstream queries use
  are not implemented (which is why the two `injections.scm` files here are
  hand-written for this subset rather than copied from nvim-treesitter).
  **Query predicates** are evaluated against the captured node's text:
  `#eq?` (string or capture), `#any-of?`, `#match?`, their `#not-` forms, and
  `#lua-match?` when the Lua pattern means the same thing as the regex (no
  `%` escape, no `()` capture, no `-` lazy repeat — which covers all three the
  Zig query uses). Each `#match?` regex is compiled once, beside the compiled
  query in the process-wide cache, never per node; `regex.zig`'s Pike VM does
  the matching. `#is?`/`#is-not?` (which need a locals query) and unknown
  predicates are ignored, leaving their pattern firing as before.
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
  lists buffers in open order with no reordering. Mouse gestures stop after
  the four-click cycle and its drags: no Alt+drag blockwise (nvim gives it a
  different anchor rule, and many terminals eat Alt), no edge auto-scroll
  while dragging (1002 reports nothing while the pointer is stationary, so it
  would need a repeat timer — and the completion debounce is the only timer
  zedit arms), and no drag-to-resize splits. The double click's `%` step uses
  zedit's own `%`, which matches `([{` only: nvim also matches C comment
  items (`/* */`) and preprocessor conditionals, so double-clicking the `/` of
  a comment takes `/*` here and the whole comment there. `motion.mouseClass`
  carries vim's `utf_class` ranges only where they change an outcome
  (punctuation blocks, kana, CJK, Hangul); everything else above Latin-1 is a
  keyword character, where vim's table is finer. Multi-clicks apply in normal
  and insert mode (vim's gate); with an *operator* pending the press is the
  operator's motion whatever the count, and in a picker a click keeps the
  picker's own select-then-open rule. A click *is* dot-repeatable when it
  consumed a pending operator (`d`+click then `.`), the way vim's redo stores
  the screen position — see the counted-repeat gap under Vim gaps above. One
  deliberate disagreement with nvim, measured: when a multi-click press and
  the drag after it arrive in the *same* read, nvim loses the gesture's anchor
  and acts on the word/line under the drag alone, while zedit keeps it — the
  answer nvim itself gives for the same gesture delivered in separate reads,
  which is what a terminal sends for a human drag. zedit processes every event
  in a burst (the input-boundary carry), so the two agree except in that race.
- The sidebar tree is flat-file only (no rename/create/delete operations from
  the tree), rebuilt on open/expand rather than watched (reveal-on-switch
  rebuilds only when it has to expand an ancestor, and `Space e` refocusing an
  already-open tree deliberately rebuilds nothing — a file created meanwhile
  stays out of it until `R`). The side-by-side diff's
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
  unsaved edits shift lines out from under them until `:w`, and its virtual rows
  render unwrapped (clipped, always from column 0). A click in either view
  resolves through the same row
  walk the renderer used, so it lands on the line it looks like — but a click
  on a virtual row (a pair's filler, a woven old line) snaps to the nearest
  real line, since those rows live in no buffer. Scrolling counts what is on
  screen: the wheel since 0.28.0 and `Ctrl-d/u/f/b` since 0.38.0 both step
  *display* rows, so a notch or a half-page that crosses a woven block or a
  pair's fillers travels the same distance as one that does not. `H`/`M`/`L`
  still count buffer lines, keeping vim's meaning.
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

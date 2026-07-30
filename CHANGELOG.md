# Changelog

Notable changes to zedit. Dates are commit dates.

## 0.32.3 - 2026-07-30

### Changed

- A failed editing case now records its `got`/`want` alongside the check name,
  so the CI annotation carries the actual value and not just "this failed".
  The open CI-only failure is `indent: ts-indent#r1 rust fn body`, which
  passes on every local configuration tried — the value CI produces is the
  next thing needed, and the log it is printed in cannot be read without a
  token.

## 0.32.2 - 2026-07-30

### Changed

- A failing `zig build itest` on GitHub Actions now emits each failed check as
  a `::error::` workflow command as well as printing it. Those become check
  annotations, which the API serves for a public repository **without** a
  token — where the log body needs one. The CI-only failure that is still open
  could not be read from outside the runner at all; now it can.

## 0.32.1 - 2026-07-30

### Changed

- `lsp.zig` now uses the shared `jsonrpc.Transport` rather than its own copy
  of the `Content-Length` framing — the follow-up promised when the module was
  added for `dap.zig` and deliberately kept out of that commit. One
  implementation, 47 fewer lines, and `alive()`/`outFd()` are methods on both
  clients now instead of a field on one and a method on the other. No
  behaviour change; the LSP scenarios are the check.

## 0.32.0 - 2026-07-30

### Added

- **A debugger** (`Space d`, `:debug`) — a Debug Adapter Protocol client, so
  `lldb-dap`, `debugpy` and `dlv dap` all work without zedit knowing anything
  about a particular debugger. The last of the "one app, not five" items.

  `Space d b` toggles a breakpoint on the cursor's line, `d B` clears them
  all, `d c` starts or continues, `d n`/`d i`/`d o` step over/into/out and
  `d q` ends the session. `:debug <program> [args]` launches; the adapter
  comes from `--dap` or a per-filetype default, exactly as the language server
  does.

  Breakpoints are **editor** state, not session state: they are set before
  anything runs and survive the program exiting. The set is sorted and
  deduplicated per file (`dap.Breakpoints`, unit-tested) because DAP replaces
  a file's whole list on every change. They render as a `●` in the gutter,
  ahead of the diagnostic and git signs, and the one the program is stopped on
  turns amber.

  A `stopped` event triggers a `stackTrace`, and its top frame's file and line
  is where the cursor goes — so the program stopping opens the right file at
  the right place.

  Not implemented (TODO.md): variables and scopes, watches, REPL evaluation,
  conditional and function breakpoints, attach, and multiple threads.

- **`jsonrpc.zig`**, the `Content-Length`-framed JSON transport LSP and DAP
  share. Only the framing — what a message *means* stays with each protocol —
  and control is inverted (`nextFrame` rather than a callback) so a caller
  stays an ordinary loop. `lsp.zig` still carries its own copy; converting it
  is deliberately a separate change, so a regression in the most-tested
  subsystem in the editor cannot hide inside a new feature.

- **`--dap <cmd>`** (`-D`), mirroring `--lsp`.

### Changed

- `waitReady` now takes a slice of extra descriptors rather than a fixed pair,
  since the editor may be waiting on a language server, a shell and a debug
  adapter at once. A null entry costs nothing, so an editor running none of
  them still blocks on stdin alone — a stopped debug session is measured at
  zero CPU in the scenario, like the idle shell.

## 0.31.0 - 2026-07-30

### Added

- **An embedded terminal** (`Space t`, `:terminal`): a real shell on its own
  pty in a horizontal split, with zedit as its terminal emulator. No more
  leaving the editor to run a command — one of the "one app, not five" goals.

  `vt.zig` is the emulator and is deliberately **pure** — bytes in, a grid of
  styled cells out, no pty and no rendering — so the state machine is
  unit-testable, which is the only way something this fiddly stays correct
  (26 tests). It covers the C0 controls, cursor movement, erase, insert and
  delete of lines and characters, scrolling regions, xterm's deferred wrap (so
  a line exactly as wide as the window does not scroll a row early),
  double-width characters, UTF-8 split across reads, and SGR colour: the 16
  ANSI colours, the 256-colour cube and 24-bit truecolour. Escapes it does not
  know are consumed and dropped rather than printed — the difference between
  an unsupported feature and a screen of garbage.

  `term.zig` owns the OS half: `posix_openpt` + fork + exec of `$SHELL`,
  window-size propagation (so the shell redraws its prompt when the split
  changes), and reaping.

  Modes follow nvim exactly: keys go to the child in **Terminal** mode,
  `Ctrl-\ Ctrl-n` returns to normal, `i`/`a`/`o` go back in. A second
  `Space t` focuses the shell already open rather than stacking another. The
  grid is read-only to buffer commands, so it can never go dirty and block
  `:q`, and an exited shell keeps its last output on screen until any key
  dismisses the window.

  The child is told `TERM=xterm`, not `xterm-256color`, on purpose: claiming
  the latter invites the alternate screen and mouse reporting that `vt.zig`
  does not implement.

### Security

- Everything the shell writes is untrusted input. Escape sequences become
  emulator state rather than text, and a C1 control that reaches the grid
  renders as `?` through the same sanitizer as buffer content — pinned by a
  scenario that has the child print a raw U+009B (the 8-bit CSI) and asserts
  the byte never reaches the outer terminal.

### Performance

- The shell's pty is polled alongside stdin and the language server
  (`waitReady` now takes all three fds), so an idle shell still costs **zero
  CPU** — measured through `/proc` in the scenario, both at the prompt and
  after the shell exits. A pty that reports end-of-file before its child is
  reapable is treated as finished, because leaving it in the poll set would
  spin the loop; on Linux `waitpid` wins that race in practice, so that guard
  is for macOS and the BSDs and is not exercised by CI (recorded in TODO.md
  rather than claimed as covered).

## 0.30.0 - 2026-07-30

### Added

- **Sessions** (`Space S s` / `l` / `d`, `:session save|load|delete`): the
  open files with their cursors, the split layout and whether the file tree
  was open, saved per working directory under
  `$XDG_STATE_HOME/zedit/sessions/<hash of the cwd>`. The cwd is stored inside
  the file and checked on load, so a hash collision cannot restore the wrong
  project, and unknown directives are skipped so a session written by a later
  version still restores what this one understands.

  Restoring reopens the files, remakes the splits and gives window *i* the
  *i*-th file — a three-pane session comes back as three panes showing what
  they showed, not the same buffer three times.

  Both directions are explicit: nothing is saved on exit and nothing is
  restored on launch, keeping the promise that zedit never does work the user
  did not ask for. A load refuses while any buffer is unsaved and names it,
  rather than closing over the work; a file that has since disappeared is
  skipped and counted in the message rather than being fatal; and the 200-file
  cap bounds what a malformed session can make the parser allocate.

### Fixed

- **The pty test harness dropped the tail of a long burst.** `Session.send`
  ignored `write`'s return value, and a pty master can accept less than it was
  given when the slave has not drained — the mouse suite's boundary sweep
  sends 2 KB in one call. It now loops, polling for writability between
  attempts. Not reproduced locally (no partial write was observed even on half
  a core), so this is not confirmed to be the CI-only failure that is still
  open — but ignoring a write's return value is a bug wherever it appears, and
  a dropped keystroke would look exactly like an editor fault on whichever
  machine happened to schedule it that way. The editor's own `Terminal.write`
  was already correct.

## 0.29.0 - 2026-07-30

### Added

- **`Space f u` opens the undo tree** and **`Space n` a new empty buffer**
  (AstroNvim's `<leader>n`; the buffer it replaces stays open). Both were
  already implemented — `:undolist` and the empty-buffer machinery `:bd` uses
  on the last buffer — and simply had no key, which is the discoverability
  gap the leader tree is supposed to close.

### Changed

- A local `zig build` targets the host and nothing else, as it already did
  (`b.standardTargetOptions`); only the release workflow's matrix passes
  `-Dtarget=` for the four published platforms. Written down in `CLAUDE.md`
  so it is not re-litigated.

## 0.28.0 - 2026-07-30

### Added

- **`Space u` — UI toggles.** The AstroNvim leader group that was missing:
  `u n` relative numbers, `u w` soft wrap, `u d` inline diagnostics, `u t`
  buffer tabs, `u i` autoindent, `u c` auto completion, `u f` format on save,
  `u m` mouse reporting. Each flips the config field of that name for the
  session and reports the new state; the config file is never written, and
  the mouse toggle also tells the terminal, so turning it off hands the
  pointer back for the terminal's own text selection.
- **New file and folder from the explorer.** `a` creates a file, `A` a
  folder, prompting on the command line pre-filled with the selected row's
  directory (inside it when that row is an expanded directory, beside it
  otherwise). Every missing directory in the name is created on the way —
  `src/new/mod.zig` with no `src/new` yet — then the tree expands to reveal
  the new row, and a new file opens for editing.
- **`:w` creates missing parent directories**, the way VS Code's save does:
  `:w notes/2026/today.md` under no `notes/` writes the file and both
  directories. Only after the write has actually failed with `FileNotFound`,
  so an ordinary save still costs one syscall and a typo inside an existing
  directory is still an error.
- **VS Code's tree arrows.** Right expands a directory (or opens a file),
  Left collapses it — the pair `l`/`h` already bound.
- **The itest runner takes suite names** (`zig build itest -- git sidebar`):
  the full run is over ten minutes, too slow a loop for one scenario under
  repair.

### Changed

- **`Space b c` is now "close all buffers except this one"** — AstroNvim's
  own meaning for `bc`. It used to be a second way to spell `Space c`, which
  is the redundancy that prompted this. It refuses while any of the other
  buffers is unsaved, naming it, rather than discarding work.
- **The showcmd indicator names special keys.** An arrow, Esc or a paging key
  now renders as `<Down>`, `<Esc>`, `<PageDown>`, `<BS>` and holds until the
  next key, where nvim shows nothing at all. A deliberate divergence: a press
  that leaves no trace is indistinguishable from one the terminal dropped.
  What nvim's rule really forbids is the *raw bytes*, and the guard that
  `^[[B` can never reach the indicator stays pinned.

### Fixed

- **Scrolling past a change no longer jumps.** The wheel moves the viewport
  three *screen* rows, so its step now counts the rows that belong to no
  buffer line — a diff pair's filler rows and the line view's woven old
  lines. Counting buffer lines made a notch that crossed a hunk travel
  further than one that did not (measured: seven rows against three over a
  four-line deletion), which is the jumping. Cursor motions (`Ctrl-d/u/f/b`,
  `H`/`M`/`L`) keep vim's line-based meaning, which is what the first attempt
  at this got wrong.
- **A new which-key group can no longer be added and left invisible.** The
  key dispatch, the popup and its title read one table (`whichKeyMenu`); the
  render gate listing the leader states separately is what once hid
  `Space g`, and it hid `Space u` for exactly as long as it took to run the
  test.

### Changed (internal)

- A failing `zig build itest` reprints every failed check as `suite: name` at
  the tail of the run. A CI log is read — and pasted — from the bottom, where
  the per-check `[FAIL]` line has long scrolled away, so `1 failed` on its own
  was a bug report nobody could act on.

## 0.27.0 - 2026-07-29

### Added

- **Tree-sitter language injections.** A grammar's `injections.scm` marks
  regions written in *another* language, and each is parsed by that language's
  grammar into a child layer whose captures fill those bytes — real injection,
  via `ts_parser_set_included_ranges` so node offsets stay document offsets.
  A fenced code block in Markdown picks its language from the info string when
  it names one of the ten vendored grammars (```python highlights as Python,
  not as one long string literal), and the body of an HTML `<script>` element
  is JavaScript. Markdown's inline spans are now an injection like any other:
  the hardcoded "second layer over the whole document" is gone, replaced by
  the general mechanism, and markdown-inline parses only the `(inline)` nodes
  and table cells — which the block grammar keeps out of `(inline)`, so a
  table's `**bold**` is styled now where it never was — instead of the entire
  file. `@none` (markdown's `code_fence_content`) now
  *clears* what an outer pattern painted, which is what stops a fence from
  staying green under the injected colours.
  - Regions are collected from the **visible range only**, so a fenced block
    below the fold costs nothing until it is scrolled to and per-keystroke
    work stays O(screen). A region that merely *starts* on screen is clipped
    to it once it runs past 64 KB — see Performance below.
  - Layers are **kept and reparsed incrementally** — the same parser and the
    same compiled query across edits and scrolls; the runtime diffs the
    included ranges against the old tree and re-lexes only what moved.
  - Limits, all documented: injection depth 1, at most 6 injected languages
    and 64 regions each on screen at once, no CSS grammar vendored (so
    `<style>` bodies stay plain HTML), and no `#offset!` / `#gsub!` /
    `injection.combined` directives — which is why the two `injections.scm`
    files are hand-written for zedit's subset rather than copied from
    nvim-treesitter, whose versions lean on all three.
- **Query predicates are evaluated.** `#eq?` (against a string or another
  capture), `#any-of?`, `#match?`, the `#not-` form of each, and `#lua-match?`
  when the Lua pattern means exactly what the same regex would (no `%` escape,
  no `()` capture, no `-` lazy repeat — which covers all three the Zig query
  uses). Matching goes through `regex.zig`'s Pike VM, and each predicate's
  regex is compiled **once**, stored beside the compiled query in the
  process-wide cache, never per node. Predicates that need machinery zedit
  does not have (`#is-not? local`, which wants a locals query) and unknown
  ones are ignored, leaving their pattern firing exactly as before.
- **Tree-sitter indent queries** behind the existing `autoindent` setting.
  Zig, C, Python, Rust, Go, JavaScript and TypeScript ship an `indents.scm`;
  `o`, `O`, Enter and `cc` add one level for every block the line the new one
  *follows* opens, so Enter after `void f(void) {` or `def f():` lands one
  step in and nesting stacks. The indent unit is a tab where the surrounding
  code is tab-indented (a gofmt'd file indents with tabs) and `tab_width`
  spaces otherwise. Enter counts only the text before the cursor, so an opener
  the split pushes onto the new line opens nothing — C's `{`, the opener's
  first byte, and Python's `:`, its last. Where the tree cannot answer —
  no grammar, no indent query, `O`/`cc` on the first line, or a blank line to
  follow — it is vim's plain copy rule, unchanged.

### Changed

- Predicate evaluation **removes** a large amount of over-highlighting that
  was there before: every Zig identifier matched the query's
  `((identifier) @type (#lua-match? @type "^[A-Z_]…"))` and
  `(#eq? @variable.builtin "_")` patterns, every Python and Rust identifier
  its `@constant`/`@constructor` patterns, and so on — the predicate was the
  only thing meant to keep them off, and it was not being run.

### Fixed

- Markdown fenced code blocks no longer render as one undifferentiated string
  literal.
- **The same keys now produce the same indent however the input is chunked.**
  The syntax indent gave up ("the tree is a revision behind") whenever several
  keys reached the interpreter without a frame between them, and silently fell
  back to vim's copy rule — so `.` disagreed with the change it repeated, a
  macro replay disagreed with its own recording, and typing fast enough that
  the terminal batched the bytes disagreed with typing slowly. `obar<Esc>` on
  `void g(void) {` gave `    bar` typed and `bar` replayed. The parse is now
  caught up on the spot instead, which costs nothing in the steady state (one
  key, one frame, tree already current). In a *batch* it costs one reparse per
  indent key rather than the one the next frame owed: each `o` changes the
  buffer, so the next one cannot be answered from the tree the previous one
  left. Measured: a 50-repeat `o`+text macro in one input burst is 3.3 ms on a
  100-byte file, 39 ms on 150 KB and 419 ms on 1.5 MB — ~8.4 ms a key, which
  is one `tsReparse` of that file, and the O(document) serialisation there is
  the known gap CLAUDE.md already records. Correct indentation was judged
  worth it; typing normally (one key, one frame) pays none of it. Pinned by
  `ts-indent#x1`-`#x4`, which are deliberately single-chunk.
- **`O` and `cc` above a blank line keep the block's indent.** The line above
  is the one the syntax model reads; a blank one carries no indent and opens no
  block, so the new line landed at column 0 — losing the indent for the very
  common "blank line inside a block" shape, and doing *worse* than the plain
  'autoindent' this replaced. It now falls back to vim's rule (copy the
  cursor's own line) there, which is what real nvim gives. Pinned by
  `ts-indent#b1`-`#b4`.

### Performance

- **An injected region far bigger than the screen is clipped to it.**
  Collecting regions from the visible range bounds *which* nodes are injected,
  not how far one reaches: a node that merely starts on screen handed its
  whole length to its parser on **every keystroke**, which is exactly the
  O(document) work the visible-range restriction exists to avoid. Measured in
  ReleaseFast on a 3.3 MB HTML file that is one `<script>` — the injected
  range was bytes 20..3,337,802 with bytes 0..1,852 on screen — typing cost
  **88.6 ms a key against 0.27 ms** before injections existed. A region over
  64 KB (~1600 lines, the same limit zedit already puts on tree-sitter in the
  picker preview) is now cut to the visible range, so the same file is
  **1.5 ms** a key; a region under the cap is still parsed whole, which is
  what keeps a code block running off the bottom of the screen highlighted
  from its real start. Only a frame's first and last region can straddle the
  viewport, so the work per layer is the screen plus at most two caps. A
  7.4 MB markdown file that is one python fence went from 4629 ms a key
  (before injections) to 1695 ms, having been 2337 ms without the clip.
- Editing markdown got **4.3× cheaper**. The old inline layer re-parsed the
  *entire document* on every keystroke; as an injection it parses only the
  `(inline)` regions on screen. Measured in ReleaseFast on a 1400-line
  markdown file with five python fences, over a 40-line window, as the mean of
  200 single-character edits: reparse + `queryRange` **50.1 ms → 11.6 ms**
  (the injected layer's share is 1.2 ms; the 10.1 ms left is the markdown
  *block* grammar's own incremental parse, unchanged by this work).
- Predicate evaluation costs +21 µs per keystroke on a 1400-line Zig file
  (139.9 → 160.9 µs for reparse + query over a 40-line window) — the regexes
  are compiled once per query, and the work is O(screen) like the query it
  gates. `zig build bench` is unchanged within run-to-run noise: startup
  5.6 → 5.6 ms, 10 MB open 10.0 → 9.6 ms, big-file first paint 1.3 → 1.0 ms,
  keypress 0.12 → 0.12 ms, picker-open cold 7.3 → 6.3 ms.

## 0.26.0 - 2026-07-29

### Added

- **True rectangular block paste.** A blockwise yank or delete now records a
  *blockwise* register (`register.zig` grew a `Kind` — charwise / linewise /
  blockwise — and the block's display `width`), and `p`/`P` lay it back in as
  a rectangle instead of splicing it charwise. Every rule below was probed
  from real nvim (`-u NONE -i NONE -n --noplugin`) through a pty before it was
  written:
  - the column is the cursor's for `P` and the cell after it for `p` — both
    column 0 on an empty line;
  - a line too short to reach that column is padded with spaces, measured in
    *display* columns, so a tab counts for `tab_width`;
  - the buffer grows new lines when the block outlasts it (`G$p` of a
    two-row block on the last line appends a padded second row);
  - a count lays the block **side by side** rather than stacking it: `3p` of
    "ab"/"cd" on "xy" gives "xabababy";
  - a register line is squared up to the block's width only when something
    follows it on that line — its own tail, or a further repetition — which
    is why a paste at end-of-line stays ragged and leaves the pad trailing;
  - the cursor lands on the rectangle's first cell.
  Blockwise `d`/`x` now fill the register at all — they previously deleted
  the block and recorded nothing, so a following `p` pasted stale text.
- **Block `A` pads short lines; `I` and `c` skip them.** vim's asymmetry,
  nvim-verified: `A` pads a line that stops short of the append column out
  with spaces so the text lands in one straight column, while `I` and `c`
  leave such a line untouched (a line ending *exactly* at the left edge still
  counts). `$` in blockwise visual is now tracked as its own state: the block
  follows each line's own end as `j`/`k` grow it, `$A` appends there and pads
  nothing, `$I`/`$c` still work off the left edge, and any motion that names
  a column ends it.
- `"{reg}` now selects a register in **visual** mode as it does in normal
  mode, for every selection kind (`<C-v>jl"ay` then `"ap` round-trips a
  rectangle through register `a`). It was ignored there before.
- `@@` repeats the last macro played, and takes a count (`2@@`).

### Fixed

- `[count].` now **replaces** the recorded count instead of repeating the
  whole change that many times: `3x` then `2.` removes five characters, as in
  vim, where it removed nine. The substituted count goes *after* a `"{reg}`
  prefix, which vim copies across untouched — written in front of it the two
  digit runs fused, so `3.` after `"a2dd` ran as `32dd` and took the whole
  file. (A count typed *after* the operator, `d2w`, is still multiplied
  rather than replaced; see TODO.md.)
- A blockwise yank, delete or change now records the block's width in spaces
  for a line that stops **before** the block's left edge, as vim's
  `endspaces` does, instead of recording nothing there. Only a paste with
  nothing after it on the line showed the difference — the squaring-up
  covered the rest — so `G$p` of such a rectangle came out one row short of
  its own width. A `$` block's spaces run one wider still, its right edge
  sitting one past the longest line's end. All nvim-pinned; a row ending
  *exactly* at the left edge still yanks empty.
- `"A` appending to a register now keeps the kind the register already had —
  only a linewise addition overrides it — so appending to a rectangle leaves
  a rectangle, one row longer and at its original width, rather than
  flattening it to charwise. A blockwise register gains a whole row; only a
  charwise one has its last line joined to the addition (nvim-verified).
- A block's right edge is now the **last** cell of the character an endpoint
  sits on, not its first, so a selection ending on a double-width character
  or a tab covers it whole: `<C-v>jl` over "漢字ab" deletes the two wide
  characters (it used to leave half the pair behind and yank a stray space),
  and `<C-v>j` then `A` on a line ending in a tab appends past the tab
  instead of before it. Pre-existing, and reached by every blockwise
  operator.
- `.` no longer records *itself* as the last change. A second `.` used to
  repeat the repeat and then stall on the recursion guard, which also broke
  any macro that recorded a `.`.
- A cursor movement mid-insert now splits the change the way vim's
  `ResetRedobuff` + `"1i"` does, so `.` repeats only the text typed after the
  move, as a plain insert: `A` `XY` `<Left>` `Z` `<Esc>` then `.` inserts a
  bare "Z" at the cursor rather than appending "XZY" at the line's end.
  (Backspace does not split a change — only movement does.)
- A blockwise `A` leaves the cursor on the block's **top-left** corner, not
  the append column it was typing at. That is what makes `.` re-apply the
  same rectangle instead of one shifted right by its own width.
- A macro replay now **stops at the first command that fails** — a motion
  with nowhere to go, a find or a committed search with no match — instead of
  running the keys after it; a count stops with it. The abort is scoped to
  the replay it happened in, and the *incremental* search deliberately does
  not raise it, or a replayed `/pat` would abort part-way through typing its
  own pattern and strand the prompt open.
- Typed `j`/`k` in visual mode no longer clobber the goal column. The arrows
  were guarded but the letters were not, so a blockwise selection crossing an
  empty line collapsed to column 0; nvim keeps curswant and stays square.
- The blockwise-visual cursor may sit one column past a short line's end
  (vim's rule), so a block can be built wider than the line under it and `$`
  can mean "past every line's end".

## 0.25.0 - 2026-07-29

### Added

- **The command line's last vim keys**, each rule probed from real nvim
  (`-u NONE -i NONE -n --noplugin`) through a pty before it was written:
  - `Delete` removes the character **under** the cursor — but at the end of
    the line the one *before* it (nvim's `c_<Del>`: ":s/a/XY" + Del ran
    ":s/a/X"), and on an empty line it cancels the command line exactly as
    backspace does.
  - `Ctrl-w` erases the word before the cursor, **including the whitespace it
    skipped over** (":foo bar  " → ":foo "), by vim's character classes: a
    punctuation run is a word of its own (":foo..." → ":foo", ":foo.bar" →
    ":foo."), and hiragana, katakana, CJK and ASCII never merge into one word
    (":foo ab日本" → ":foo ab"). A no-op at column 0; it never cancels the
    line.
  - `Ctrl-u` erases everything between the start of the line and the cursor,
    **keeping the tail** (":abcdef" + 3 Lefts → ":def") — and, unlike
    backspace, never cancels an empty line.
  - `Ctrl-r{register}` inserts a register at the cursor: `a`-`z`, the unnamed
    `"`, and the clipboard `+`/`*`. vim's `"` is drawn at the cursor while the
    name is awaited, Esc there abandons the prompt and keeps the line, and an
    unknown or empty register inserts nothing and swallows the key. A register
    holding several lines inserts one separator per interior line break and
    drops the trailing one, matching what nvim puts on the line; register text
    is untrusted, so it renders through the same sanitizer as everything else
    (nvim shows the separator as `^M`, zedit as `?`, and an escape sequence in
    a yanked line can never reach the terminal live).

### Changed

- **Tab completes only the text before the cursor** and keeps the rest of the
  line, with the cursor between the two — nvim's rule, and the one divergence
  the earlier wildmenu work had recorded (":e alXY" + 2 Lefts + Tab now gives
  ":e alpha.txtXY", not ":e alpha.txt"). The whole ring follows: cycling,
  the restore of the typed stem, and the path popup's `Down`/`Up` directory
  navigation all put the tail back.
- **A command line wider than the row now wraps** onto further screen rows,
  the command-line area growing upward over the window, instead of clipping
  with the cursor pinned to the last cell. This is what nvim does — the probe
  that was expected to show a horizontal scroll showed wrapping instead (a
  20-column pane painted ":0123456789012345678" then "901234", the cursor on
  the lower row). The block is bottom-anchored at the status row, the rows it
  covers are treated as an overlay so the next frame repaints them, the
  wildmenu popup moves above the whole block, and the inline suggestion
  continues on the cursor's row. Each row still breaks on a codepoint
  boundary by display cells, so a wide char that would straddle the edge
  starts the next row rather than being torn — and the cell it leaves over
  carries vim's `>` marker (probed: a 20-column pane painted
  ":日本語のファイル名>" then "がとても長い"). On a terminal narrower than a
  wide character, where no row could ever hold it, the char is taken anyway
  rather than leaving the layout unable to advance.

## 0.24.0 - 2026-07-29

### Added

- **Double click selects the word, triple click the line** (quadruple one
  blockwise cell, and the fifth click starts the cycle again — vim's period-4
  cycle, not the usual three). The click count is derived when a press
  arrives, from the previous press's timestamp and screen cell: the chain
  continues only while each click lands on the *same* cell inside `mousetime`
  of the one before it, so **no timer is armed** and an idle editor still
  blocks in `poll(2)` at zero CPU. Every press counts, wherever it lands (vim
  decides the count in the input layer), so a click on a status row, the
  command line, the title bar or the explorer breaks a chain in two rather
  than passing through it. The double click takes vim's *mouse* word,
  which is not `iw`: blanks and keyword characters take their run, punctuation
  first tries `%` — when there is a bracket at or after the click on that line
  the selection runs from the click to its match, backwards or across lines —
  and otherwise groups only with its own class, so `->` and `*=` select as one
  while `.,;` selects one character at a time. Multibyte text follows vim's
  `utf_class` ranges: `你好world` selects `你好`, `naïve` selects whole. A
  click past the end of a line clamps to its last word; a triple click takes
  the whole line (newline included) whatever column it lands in. Dragging
  after a multi-click extends by whole words, whole lines or a real rectangle,
  in both directions, with the clicked word always kept whole.
- **Insert Visual**: a mouse gesture begun in insert mode now behaves as it
  does in nvim. The statusline reads `(insert) VISUAL`, and whatever ends the
  selection — `Esc`, `v`, an operator, or a plain click — lands back in insert
  where it left the cursor, so typing simply continues. A second `Esc` leaves
  insert as usual.
- Config `mousetime` (default `500`, milliseconds — vim's name and value): how
  far apart two clicks at one cell may be and still chain. `0` turns
  multi-clicks off entirely.

### Changed

- **The wheel scrolls the window under the pointer**, not the focused one, and
  never moves focus (nvim's rule, pty-probed; the hovered window's cursor
  travels with its viewport, as zedit's wheel has always done). The scroll
  runs on the `Win` — the active window's mirrored viewport is saved out first
  and loaded back after — so one path serves every window and the mirror
  cannot go stale. Inside a visible side-by-side diff pair the notch is routed
  to the pane that drives the lockstep, so the partner still follows through
  the alignment map. A window's status row counts as part of it (`winUnder`),
  as in nvim; cells no window owns at all (the explorer, the title bar, the
  command line) still scroll the focused window. `lineAfterRows`, `lineRows`,
  `lineLayout` and `textCols` gained `*Win` variants for this, with the
  active-window wrappers kept for their existing callers.

## 0.23.1 - 2026-07-29

### Fixed

- More vertical splits than the terminal has columns (or horizontal splits than it has rows) gave a window zero width, which underflowed the row painter's `gw - 1` and aborted the editor. Window geometry is now floored at one legal cell, so a tiling accident degrades instead of crashing. Found by the mouse review, which correctly scoped it out as pre-existing and mouse-independent.

## 0.23.0 - 2026-07-29

### Added

- **Click to move the cursor, drag to select.** zedit now asks the terminal
  for motion-while-pressed reports (DEC mode 1002 alongside 1006, replacing
  1000), and decodes press, drag and release as three distinct events. A left
  click in a window's text area puts the cursor there — focusing that window
  first when it is not the active one — and holding the button down extends a
  charwise selection from the press cell, leaving an ordinary visual selection
  that `d`/`y`/`c` and the rest act on. Every rule is pinned to real nvim's
  `mouse=a`, driven through a pty: no jumplist entry, a pending count
  discarded, an open selection ended, insert mode continued, and a pending
  *operator* applied over the clicked range as an exclusive charwise motion
  (linewise by vim's column-0 rule). `goal_col` keeps the clicked column, not
  the clamped one, so clicking past a short line and pressing `j` lands where
  the pointer was.
- Clicks resolve through the renderer's own row walk, lifted out of
  `renderWindow` into a re-runnable `RowWalk`/`nextRow` the hit-test replays —
  the `tabArea` draw-here-click-here invariant, applied to the hardest case.
  So a click lands correctly on a soft-wrapped continuation row (hanging
  indent included, and the padding past a word break stays on its own row),
  on a tab or either cell of a wide CJK character, on a line carrying inlay
  hints, and in the diff views, where a virtual row (a pair's filler, a woven
  old line) snaps to the nearest real line instead of inventing a position.
  The gutter reads as column 1, as in nvim.
- Config `mouse` (default `true`). `mouse = false` never emits the enable
  sequence, so the terminal keeps the mouse entirely — including its own
  click-drag selection, which any tracking mode takes over — and a stray
  report from a terminal another program left in tracking mode stays inert.

### Fixed

- **A read that filled the input buffer exactly decoded a split escape
  sequence as its fragments** — a bare Esc dropping you out of insert mode
  and the tail running as commands or landing in the document. The completion
  wait that repairs a short read had nowhere to put the rest, so the
  unfinished tail is now held back and prepended to the next read instead.
  Mouse drags made this routine rather than theoretical: one drag across an
  80-column window is ~900 bytes of reports. The input buffer also grew from
  256 bytes to 1 KB, so a whole drag arrives in one read and costs one frame.
- **An exclusive motion ending in column 0 built the wrong span, and aborted
  the editor when the end sat on line 2.** vim's rule steps such an end back
  to the end of the previous line, but the two halves of that step were
  written into one struct literal whose result location *is* the value being
  read — so the row was already updated when the column was computed, giving
  the length of the line before the one wanted, and underflowing outright at
  row 1. `d}` onto a blank second line crashed; `d`+click at column 0 of line
  2 crashed; between lines of different lengths the delete simply stopped at
  the wrong column. Pinned against nvim in `vim_compat` (`nvim#m24`–`m27`),
  with and without the mouse.
- **`.` after an operator+click repeated the wrong change.** A press that
  consumes a pending operator makes a change, but it returned before the
  dot-capture wrapper, so the click never entered the repeat register and `.`
  silently re-ran whatever change came before it. It is captured now, and
  replays the recorded screen cell exactly as vim's redo does.
- **A mouse press left the pending command on the showcmd indicator.** `d`
  then a click executed the delete but kept showing `d`, and the next command
  appended to it (`3` then read `d3`). A press acts at once, like an arrow
  key, so it clears the indicator — pty-probed against nvim, which blanks that
  cell for both `d`+click and `3`+click.

### Changed

- Modified mouse reports (Shift/Alt/Ctrl), the horizontal tilt axis and the
  extra buttons stay inert rather than acting as their plain counterparts —
  nvim gives Alt+drag and Ctrl+click meanings of their own that zedit does not
  implement. Shift+mouse never reaches an application in any terminal tested;
  it is how text is selected for the terminal's own clipboard.

## 0.22.0 - 2026-07-28

### Added

- Buffer-word completion (`complete.zig`, config `buffer_completion`, on by
  default): when no language server answers — none installed for the
  filetype, or one that returns an empty list — the completion popup fills
  from the identifiers already in the open buffers, vim's keyword
  completion. The current buffer is harvested first, then the others;
  duplicates keep their first occurrence, the word being typed is never
  offered as its own completion, and the list is fuzzy-ranked with the
  pickers' scorer. Accepting works exactly as an LSP item does minus the
  server bits (replace the typed prefix; no `additionalTextEdits`, no
  snippet). The harvest runs on the existing completion debounce, never per
  keystroke, walks outward from the cursor line so the nearest words win,
  and is bounded three ways (1000 lines each way, 128 KB of text, 200
  candidates), so no timer was added and a huge file cannot stall typing:
  2.3 ms worst case, 78–144 µs on ordinary source.
- A missing-server hint: opening a file whose filetype *has* a known server
  (`zls`, `clangd`, `pylsp`, `typescript-language-server`, `rust-analyzer`,
  `gopls`) that fails to launch now says so in the statusline — "no language
  server for python (install pylsp); completing from open buffers" — once
  for the document, instead of leaving "nothing completes" unexplained. A
  filetype with no known server stays silent.

### Fixed

- Typing inside an existing word no longer offers that word back as a
  completion: the whole identifier at the cursor is excluded, not just the
  prefix before it.
- A language server whose next response *replaced* its completion list with
  an empty one could leave the open popup indexing items that no longer
  existed; the following frame read past the end of the list and killed the
  editor. The popup is now dropped the moment a response lands, and reopened
  from whichever list fills it.
- A language server that exited or crashed after the handshake silently took
  completion with it — the request went into a dead pipe and no popup ever
  came, with no fallback. A dead client now counts as "no server", so the
  buffer words take over.
- Buffer-word completion offered words from a thousand lines above the cursor
  instead of the ones beside it: the scan read its window top-down and the
  200-candidate cap filled before it ever reached the cursor's line. It now
  walks outward from the cursor.
- Bounded the harvest by bytes as well as lines. The candidate cap does not
  bound the *work* — deduplication scans the kept list once per word
  examined, so a file whose vocabulary never reaches the cap scanned every
  line of its window: 82 ms on each typing pause, measured, against 2.3 ms
  now.

## 0.21.0 - 2026-07-28

### Added

- Multi-term fuzzy queries in every client-filtered picker (files, buffers,
  themes, document symbols, references, diagnostics, code actions, undo
  list), helix-style: the query splits on spaces and every term must match
  independently, in any order — `render editor` finds
  `src/editor/render.zig` — with the per-term scores summed. Two pickers do
  their own matching and are unchanged: the grep picker (`Space f w`) is
  pure regex, where a space is a literal and `foo.*bar` expresses ordering,
  and the workspace-symbol picker (`Space l S`) forwards the query verbatim,
  spaces included, to the language server that matches it.
- Content-search discoverability: a `zedit <dir>` session opens the file
  picker with a one-time status line naming the scopes ("type to match file
  NAMES — Space f w searches file contents"), and a files-picker query with
  zero matches shows a dim hint row pointing at `Space f w` instead of a
  silently empty list.

### Changed

- `Space e` is now VS Code's three-state cycle: closed → open + focused;
  open but unfocused → refocus it (no rebuild — selection and scroll
  survive), which restores a keyboard route into an `Esc`-unfocused tree;
  open + focused → close. `Esc` (unfocus), `q` (close) and mouse clicks are
  unchanged.
- Status messages set while a picker is open (the scope hint, a remote
  listing's file count) now paint the picker's bottom row dim; they used to
  be invisible because the picker view has no statusline. The row is
  *reserved* while a message is up rather than painted over the list, so no
  result is hidden under it — and a click there selects nothing.

## 0.20.0 - 2026-07-26

### Added

- `:bd!` / `:bdelete!`: close the current buffer discarding its unsaved
  changes, now that a dirty `:bd` refuses (see Fixed).

### Fixed

- Mouse clicks work in the picker view (the `zedit .` startup screen and
  every later picker): a click on a result row selects it (the live preview
  follows), a click on the already-selected row opens it — a double-click
  opens from anywhere, with no double-click timer — explorer rows toggle
  directories or open files under the live picker, and a buffer-tab click
  closes the picker and lands on that buffer. The prompt row and the preview
  pane stay inert, so terminal text selection keeps working there. Every
  such click used to be silently swallowed by the mouse handler's mode gate
  (command/visual modes still swallow clicks — a click must not cancel an
  operator). The renderer and the hit-test share one geometry helper
  (`pickerLayout`), so a row can never be drawn at one place and clicked at
  another.
- `:bd` on the last buffer now replaces it with a fresh empty `[No Name]`
  buffer and the window stays (vim's rule, nvim-verified; the replacement is
  adopted by the next `:e`, so no phantom buffer lingers) instead of
  refusing with "cannot close the last buffer" — and a buffer with unsaved
  changes now refuses with "no write since last change" (nvim's E89 parity)
  instead of silently discarding the edits when other buffers were open.
  `Space c` / `Space b c` inherit the refusal.
- Arrow keys and `<BS>` in normal mode take a count, exactly like
  `h`/`l`/`k`/`j` (nvim-probed: `3<Right>` moves three columns, `2<Down>`
  two lines; `<Home>`/`<End>` keep ignoring it, vim's rule). The count was
  silently consumed and the arrow moved one step.
- The showcmd indicator records the decoded key, never raw input bytes:
  arrows, Esc, Home/End and paging keys execute and render nothing (nvim's
  rule, pty-probed) instead of smearing `^[[B` / `^[` / `^[[6~` across the
  statusline. Control keys keep their `^W`-style caret display; macro
  recording and dot-repeat still capture raw bytes, so special keys keep
  replaying.
- The modified flag now tracks *which undo state* is on disk (vim's
  `b_u_save_nr`, all four rules nvim-pinned): undoing back to the last-saved
  state lets `:q`/`:qa` exit, undoing past it stays modified even when the
  text matches, retyping identical text stays modified, and `:wa` marks
  every buffer it writes. Undoing every change used to leave the buffer
  "modified" forever, with `:q` refusing on text identical to the file.

## 0.19.0 - 2026-07-26

### Changed

- The unified-diff scratch (`Space g d` / `:diff`) is read-only, like the
  side-by-side view's index pane: edits, pastes and `:w <name>` are refused
  with "diff view is read-only", so a viewed diff can never turn into a
  dirty buffer that blocks `:qa`. The toggle and motions are unchanged.
- With `persistent_undo` on, writing an undo file now also prunes sibling
  undo files in `$XDG_STATE_HOME/zedit/undo` untouched for 90 days (each
  removal is logged), so the state directory no longer grows forever.
  Only files named exactly as zedit names them (16 hex digits + `.undo`)
  are ever candidates, and nothing is scanned unless an undo file is being
  written.

### Fixed

- Remote writes (`:w` over ssh) stream into a temp file beside the target
  and rename it into place in the same single ssh invocation — a transfer
  that fails partway can no longer truncate the remote file (at worst a
  `.zedit.tmp.*` file is left beside it; on a clean failure it is removed).
  A remote target that is an existing directory is refused ("write failed")
  rather than the rename dropping the temp file inside it and claiming
  success. A failed remote write now reports "ssh transfer failed" instead
  of a raw error name.

## 0.18.0 - 2026-07-26

### Added

- A third git diff view, the line-by-line one VS Code and Zed show:
  `Space g l` / `:ldiff` weaves each hunk's old (deleted / changed-from)
  lines into the file's own window as red-tinted virtual rows above the
  lines that replaced them, with added/changed lines tinted on their real
  rows. No split, no scratch, no second buffer — a rendering mode of the
  window, and the file stays fully editable. The woven rows carry a dim
  `-` in the gutter and no line number, render unwrapped (clipped) and
  sanitized, and the cursor can never land on one: `j`/`k`, `H`/`M`/`L`
  and scrolling step across real lines only, and a deletion before line 1
  (up to a total deletion) shows above row 0 with the side view's
  cursor clamp. The old text comes from the same `git diff -U0` the
  gutter signs use, and a `:w` refresh feeds the weave *and* the signs
  from one run of it (one subprocess, not two); like the signs, the
  weave reflects the file as last saved and refreshes on `:w` (closing
  when no changes remain).
  Pressing the key again toggles the weave off, and the three diff views
  are exclusive per file — opening any one closes the others first.

## 0.17.0 - 2026-07-26

### Added

- The file-tree explorer is mouse-clickable: a single click on a row selects
  it and acts exactly as Enter does — a directory expands or collapses, a
  file opens with focus returning to the buffer (VS Code's single-click
  rule) — with no need to focus the tree first. Clicking the EXPLORER
  header (or its title-bar segment) or the empty space below the tree
  focuses the tree without changing the selection. Clicks resolve through
  the same geometry the renderer draws from (title-bar row, sidebar side,
  scroll offset), clicks in the text area remain unbound, and the
  terminal's own Shift+drag text selection is unaffected.

### Fixed

- The release half of every mouse click was decoded as an unrecognized
  key: its raw bytes smeared `^[[<…m` into the statusline's showcmd
  indicator, and — like any unrecognized key — it reset a pending operator
  or count that the wheel (and the press itself) deliberately preserves,
  so `d`, click, `w` no longer deleted a word. Non-acting mouse reports
  (releases, drags, right/middle buttons) now decode to a dedicated inert
  key the editor swallows whole, before showcmd, dot-repeat and command
  dispatch.

## 0.16.0 - 2026-07-26

### Fixed

- The side-by-side diff view can now show a hunk whose deletion precedes
  line 1: deleting a file's first lines hid them above the viewport, and a
  *total* deletion rendered an entirely empty index pane (the aligned rows
  sat above buffer row 0, which the buffer-row viewport top could never
  reach). A pane whose top is row 0 now anchors at display row 0, clamped so
  the cursor stays on screen when the gap is taller than the window — in
  that case only the gap's tail is reachable (known gap).
- The two git diff views are now exclusive per file: opening one closes the
  other first. `Space g s` then `Space g d` used to stack a third window and
  flip the whole tiling to rows, leaving the "side-by-side" pair stacked
  even after closing the inline diff.
- Both diff toggles key on a *visible* window: after `:bn` or `:close` moved
  the window off the scratch, `Space g d` / `Space g s` used to report "diff
  closed" while changing nothing on screen (a phantom toggle) — they now
  destroy the stale scratch and reopen the view.
- A buffer born empty (`zedit brandnew.py`, `:e newfile.c`) never
  highlighted: the first keystroke's reparse handed tree-sitter the old
  empty tree without `ts_tree_edit` (an API-contract violation), freezing a
  stale zero-length parse forever — and the active-but-empty highlighter
  also shadowed the lexer fallback. The empty↔non-empty transitions now
  compute a real incremental edit.
- `:w name.py` on an unnamed buffer now detects the filetype from the new
  name and starts highlighting and LSP immediately (the buffer used to stay
  plain "text" until reopened).
- Opening a file on top of an untouched `[No Name]` buffer (unnamed,
  unmodified, empty, shown in no other window) now replaces it — vim's rule,
  nvim-verified — so `zedit .` plus a picker pick no longer leaves a stray
  `[No Name]` in `:ls` and the tab bar. A modified unnamed buffer is kept,
  exactly like nvim.
- `build.zig.zon`'s `.version` said 0.2.0 while `VERSION` said 0.15.0; the
  copy is now correct, and a comptime check in `build.zig` fails the build
  with a clear message whenever the two files disagree.

## 0.15.0 - 2026-07-26

### Added

- Mid-line command-line editing: the cmdline cursor moves with
  `Left`/`Right` and `Home`/`End` (vim's `Ctrl-b`/`Ctrl-e` too), typed and
  pasted text inserts at the cursor, and backspace deletes before it (a
  no-op at the start of a non-empty line; an empty line still cancels).
  History recall and wildmenu cycling put the cursor at the end of the
  line. All pinned to real nvim through a pty (`vim_compat` nvim#e1–e9).
  The inline suggestion follows fish exactly: it renders only with the
  cursor at end-of-line, where `Right`/`End` accept it — mid-line they
  only move the cursor.
- Wildmenu directory-navigation keys (nvim `'wildmenu'`, pty-probed):
  while a `:e`/`:w` path popup is open, `Down` descends into the selected
  directory and re-completes inside it (on a file it just closes the
  popup), `Up` re-completes in the parent directory, and `Left`/`Right`
  select the previous/next match for every completion kind. With any
  other popup — where real nvim recalls history filtered by the completed
  line, exactly what zedit already did — or none, Up/Down stay history.

### Fixed

- The typed command line was clipped to the row in bytes, not display
  cells: wide (CJK) characters could tear a codepoint into `?` and leave
  stale cells at the end of the row. Both the typed text and the ghost now
  clip by cells on codepoint boundaries through one helper.
- The wildmenu popup rows had the same byte clip: a CJK filename wider
  than the popup was torn mid-codepoint into `?` and its row's padding
  miscounted. Popup rows now clip through the same cell-based helper.
- A command line longer than the row sent the terminal a cursor column
  past the right edge; the cursor now pins to the last cell (the line
  itself still clips — no horizontal cmdline scroll yet).

## 0.14.0 - 2026-07-26

### Added

- The project-wide grep picker (`Space f w`) matches regexes, with the same
  modern syntax the in-buffer `/` search uses (case-sensitive, matched per
  line — a pattern cannot span a newline). A plain-string query is unchanged:
  it keeps the literal indexOf fast path, extending it still narrows the hits
  in place, and the walk-streaming/500-hit-cap resume behave exactly as
  before. A genuine regex cannot narrow (a longer pattern is not a subset),
  so it rescans the project — measured with `log.Span` at ~35 ms per rescan
  on this repository (ReleaseFast), too slow per keystroke, so the rescan
  runs through the existing shared typing-pause debounce (the completion/
  workspace-symbol timer; a query change costs 1–4 µs and idle CPU stays
  zero). While the pattern is mid-typing invalid (a lone `(`, a trailing
  `\`), the picker keeps the last good results and shows a dim
  `(incomplete)` tag beside the query instead of flashing empty. `Ctrl-r`
  (re-walk) resets the hits and the scan cursor with the cache it discards,
  so a regex or mid-typing-invalid query re-greps the new walk from the
  start instead of resuming mid-way through it; and the debounce is checked
  inside the walk loop too, so a rescan armed while the walk streams fires
  after one typing pause rather than waiting for the whole walk.

## 0.13.0 - 2026-07-26

### Added

- Fish-style inline suggestions on the command line: as you type after `:`
  (or `/` `?`), the rest of the newest history entry extending the typed
  text — or, for `:`, the first matching command name — appears as dim
  ghost text after the cursor. `Right` or `End` accepts it; `Enter` always
  runs only what you typed, and the ghost hides while the Tab wildmenu has
  the line. The rename prompt never ghosts. Recomputed only on edits (no
  timers, no filesystem I/O — idle CPU stays zero) and drawn through the
  control-byte sanitizer, so hostile history bytes stay inert.
  `cmdline_suggestions = false` turns it off.

### Fixed

- A pty test that broke when the version hit 0.12.0 (its "no absolute line
  numbers" needle matched the version string in the startup status).

## 0.12.0 - 2026-07-26

### Changed

- The side-by-side git diff (`Space g s` / `:vdiff`) was reworked into a real
  two-pane diff view:
  - **Focus stays on the worktree pane** — the file you edit — instead of the
    index snapshot.
  - The index pane is **read-only**: every buffer-mutating command (operators,
    insert, paste, undo, `:s`, `:w <name>`, …) answers "index snapshot is
    read-only" and does nothing, so the snapshot can never be edited into
    lying, go dirty and block `:q`/`:qa`, or be written out to a file.
  - The panes are **row-aligned, VS Code-style**: one `git diff` provides the
    hunk pairs (`git.computeHunks`; the gutter-sign maps now derive from the
    same parse), and where one side has lines the other lacks, the shorter
    side renders virtual **filler rows** — tinted with the git-add colour in
    the index pane (additions) and git-delete in the worktree pane
    (deletions), blank gutter, in no buffer, never under the cursor — so
    matching text sits level across the panes.
  - The panes **scroll in lockstep**: the unfocused pane's viewport derives
    from the focused one through the alignment map every frame — wheel,
    `Ctrl-d/u/f/b`, everything — and `Ctrl-w w` across the pair lands the
    cursor on the aligned row. Opening the view keeps the cursor (and
    viewport) where it was, entering a pane from a third window pulls its
    bookmarked cursor into the synced view instead of yanking the pair to a
    stale row, and `:bd` on the compared file turns the leftover snapshot
    into an ordinary scratch (alignment and tint rows dropped). Soft wrap is
    forced off inside a visible pair (a wrapped line would shear the row
    alignment; horizontal scrolling still works there).
  - `Space g s` (and `:vdiff`) **toggles**: pressed again — from either pane,
    even after `:close` left the scratch lingering — it closes the split *and*
    destroys the snapshot. `Space g d` / `:diff` toggles the inline diff the
    same way. A file with no changes reports "no changes" instead of opening
    a split.
  - Alignment and tints refresh when the file is saved, like the gutter signs.

### Added

- One powerline **title bar** on the top row, replacing the separate tabline and sidebar header that fought over it (with the tree open, the header physically overdrew the tabs, and clicking the header switched to the invisible tab under it). The bar shows an EXPLORER segment spanning the sidebar's columns (accent-coloured while the tree has focus) and one powerline tab per open buffer — the active tab an accent segment, inactive ones dim, unsaved ones dotted. Shown whenever `buffer_tabs = true` (the default), including single-file sessions, VS Code-style; `false` removes the row and returns the filename to the statusline. The renderer and the click hit-test share one geometry helper, so tabs are clicked exactly where they are drawn — with the sidebar on either side or closed — and clicks on the EXPLORER segment do nothing. The bar renders in the picker view too, with the prompt and results below it.
- **Reveal in explorer**: while the sidebar is open, switching buffers (`:e`, pickers, `:bn`/`:bp`, `]b`/`[b`, tab clicks, jumplist) expands the active file's ancestor directories, selects its row and scrolls it into view. Files outside the cwd (or remote/scratch buffers) leave the tree alone.
- `]b` / `[b` cycle to the next/previous buffer (AstroNvim's keys; counts work: `2]b`), and a new `Space b` Buffers which-key group: `b` the buffer picker, `n` next, `p` previous, `c` close.
- A `ui_sel` colour in every theme for selected UI rows (picker results, sidebar tree): the palette's visual-selection tone, guaranteed distinct from `cursorline` and `bg_dark` by a test. In Nord, `cursorline == bg_dark` had made the sidebar's unfocused selection literally invisible; the unfocused tree selection now uses a `mixColor(bg_dark, ui_sel, 50)` dim that stays visible everywhere.

### Changed

- While the title bar is visible the statusline drops its filename+dirty segment (the active tab already shows both); `buffer_tabs = false` keeps the old statusline exactly.

### Fixed

- Flat-mode (`nerd_font = false`) statusline was painted 4 cells short of the right edge: the width budget charged one cell per powerline separator even when the separators were empty strings.
- A status message containing a multi-byte character (the startup hint's em dash) shifted the statusline's right half by the byte/width difference; the middle segment is now clipped by display cells on a codepoint boundary.
- With `buffer_tabs = false`, opening the sidebar in a terminal narrower than 18 columns crashed: the sidebar's own "EXPLORER" header assumed at least 9 columns of width. The label now clips to the sidebar.

## 0.10.0 - 2026-07-26

### Fixed

- Opening a file from the file picker parked the cursor on a seemingly random line ("line 29"): the picker row's `line` field holds the project-walk cache index for the files picker, and the open path mistook it for a line number (clamped to the file's last line). The preview pane was scrolled to the same wrong place. Files now open at the top, like `:e`; the grep/reference/diagnostic/symbol pickers keep their real line jumps.
- Binary files (e.g. `.DS_Store`) rendered as rows overflowing the terminal and wrapping back around: a NUL byte was counted as zero cells but drawn as one `?`, so the width accounting never stopped the row at the window edge.

### Security

- Invalid UTF-8 bytes reached the terminal raw: the sanitizer checked the *decoded* codepoint (U+FFFD, not a control) rather than the malformed byte itself, so bytes 0x80–0xFF in file content, previews, tab labels or LSP text were emitted verbatim — and 0x80–0x9F are live 8-bit control codes (CSI!) on some terminals. Every sanitizer site now renders a malformed byte as one `?`. Pinned by a pty test that decodes the raw output stream and asserts no invalid byte escapes and no row exceeds the window.

## 0.9.0 - 2026-07-26

### Changed

- Applied a repo-wide over-engineering audit: 81 verified findings, net −722 lines, no behaviour change (one tiny fix below rode along, which is why this is a minor bump). Highlights: Editor.init's 145 lines of constant field assignments became field defaults on the struct (init is now 26 lines); the hand-rolled JSON serializers in the LSP client became `std.json.Stringify` calls (−102 lines); the undo-file parser's bespoke byte reader became `std.Io.Reader.fixed`; six copy-pasted scenario helpers (`case`, `join`, run-and-free, ANSI-strip) merged into the pty harness; the XDG path builder, monotonic-ms clock and fd write loop each collapsed from three copies to one shared function; ten picker openers share one prologue; and ~30 hand-rolled loops now use the std function that already did the job (`std.ascii.isDigit`/`toLower`, `@memset`, `std.mem.swap`/`trimStart`/`indexOfNone`/`replaceOwned`, `std.math.log10_int`, `std.StaticStringMap`, `std.Io.Dir.access`/`statFile`). Two `Theme` fields no palette distinguished (`char_`, `indent_guide`) were removed. The measured perf machinery (SIMD search, picker arena, frame diffing, style cache) was deliberately left untouched; the benchmark table is unchanged.

### Fixed

- An escaped `\$` in a snippet without tabstops was left as a literal backslash-dollar instead of being unescaped; noticed while removing the pre-scan that caused it.

## 0.8.0 - 2026-07-26

### Added

- Soft wrap breaks at the last space that fits rather than mid-word (a word wider than the row is still broken), and continuation rows repeat the line's indent so a wrapped line hangs under its own first character — `wrap_indent`, on by default, capped at half the window, vim's `breakindent`. New `wrap_column` wraps at a column narrower than the window. `gj`/`gk`/`g0`/`g$` and the cursor's screen position follow the real break points rather than assuming fixed-width rows.

### Fixed

- A wrapped row was drawn to the window edge rather than to its break point, so the word at the break appeared on both rows.

## 0.7.1 - 2026-07-26

### Fixed

- `config.zig` now has a completeness test that walks `Settings` at comptime and fails if a field is missing from the text `--init-config` writes or is not read by the parser — a setting could previously reach the struct and silently ignore what the user put in their config.
- Tests for the three settings that had none: `tab_width` (a tab renders that wide), `buffer_tabs` (the tabline appears and `= false` hides it) and `completion_delay_ms`.
- A regression test for `:e` painting before it decorates, which shipped in 0.3.0 without one. It asserts the order of bytes in the stream rather than a timing, so it cannot be flaky: the text and the git sign arrive in different frames.

## 0.7.0 - 2026-07-26

### Added

- `persistent_undo` (config, off by default — vim's `undofile`): the undo tree is written to `$XDG_STATE_HOME/zedit/undo` on every save and picked up when the file is next opened, so `u`, `g-` and `:undolist` still reach changes made in an earlier session. The root's text is not stored — the state the history is anchored to is the file itself, and the diffs run both ways — so a 200-change session on an 8.6 MB file is a 1,484-byte undo file rather than a second copy of the file, and `:w` costs the same as it did (55–57 ms either way). The anchor's length and hash are recorded and checked, so a file edited by another program gets no history rather than someone else's past, and the file is created readable only by its owner. Nothing prunes old undo files, which is part of why it is off by default.

## 0.6.0 - 2026-07-25

### Added

- `:earlier Nf` / `:later Nf` count file *writes* rather than changes, so `:earlier 1f` is "what I had when I last saved" without counting keystrokes. Running past the first (or last) write lands on the oldest (or newest) state, the clamp vim applies. Five cases pinned against real nvim.

## 0.5.2 - 2026-07-25

### Performance

- The undo tree stores each state as the difference from its parent — the offset where they diverge plus the bytes on either side of the change — rather than a copy of the whole buffer, and keeps the current text materialised so a step applies one small edit instead of rebuilding anything. Jumping across branches walks up to the common ancestor and back down, every move proportional to what changed. 300 single-character changes in a 7.6 MB file held 295 MB before and 43 MB now; edit latency is unchanged at 10.9 ms (it is the whole-buffer serialise on each edit, which this does not touch).

## 0.5.1 - 2026-07-25

### Changed

- Versioning is now per commit: `VERSION` is bumped and a `CHANGELOG.md` section added alongside the code that changes, minor for anything a user notices and patch for anything they do not (the rule is written down in `CLAUDE.md`). The work between 0.2.0 and here had been landing in the changelog without ever moving `VERSION`, so it is split into the releases above.

## 0.5.0 - 2026-07-25

### Added

- Undo is now a tree rather than a line: a change made after an undo starts a branch instead of discarding what was undone. `g-`/`g+` (with counts) walk every state in the order it was made, across branches; `:earlier`/`:later` take a count or a span (`10s`, `2m`, `1h`) and clamp to the oldest/newest state; `:undolist` lists every state in a picker, marking the current one and flagging branch points, and Enter jumps to the one chosen. Ten cases pinned against real nvim. A "change" that leaves the text identical no longer costs an undo step.

## 0.4.0 - 2026-07-25

### Added

- Soft wrap (`soft_wrap`, on by default as in vim): a line too long for the window continues on the next screen row, marked with a dim `↳` in the gutter, instead of scrolling the view sideways. `gj`/`gk`/`g0`/`g$` move by screen row; `j`/`k`/`0`/`$` keep their buffer-line meaning; `H`/`M`/`L`, `Ctrl-d`/`u`/`f`/`b` and the mouse wheel count screen rows. `soft_wrap = false` restores horizontal scrolling.

### Performance

- A line's syntax styling is computed once per frame rather than once per screen row it fills, and the row-count width scan stops after a window's worth of columns. Soft wrap draws a long line several times per frame, which made both O(line) costs visible: a 1.8 MB single-line file went from 82 ms a frame to 4 ms, matching the unwrapped cost.

## 0.3.1 - 2026-07-25

### Performance

- The grep picker narrows instead of rescanning: extending a query can only shrink its hit set, so it filters the hits already found rather than re-reading every project file on each keystroke. Once the scan has covered the project a keystroke costs 4 us instead of ~6 ms (measured with `log.Span` on this repository; the interaction benchmark's warm grep went 18.1 ms to 10.7 ms). A shorter query still rescans, and a narrowing that frees room under the 500-hit cap resumes the scan, so the results are the ones a rescan would give.

## 0.3.0 - 2026-07-25

### Added

- Argument and comment text objects: `aa`/`ia` select the argument or parameter under the cursor (`aa` takes the comma joining it to a neighbour, so the list stays valid) and `aC`/`iC` a comment (`aC` extends over a run of comment lines at the same column and is linewise when the comment owns its lines). Both read the grammar's own node names, so a nested call or a comma inside a string cannot fool them.

### Fixed

- Visual-mode "around" objects behaved like their "inner" twins — `va(` selected the same text as `vi(`, for every object. The pending key was read back after it had been cleared. Pinned against headless nvim.
- `[count]f`/`t`/`F`/`T` and `[count];` ignored the count (`3fa` went to the first `a`), and a count typed after an operator (`d3fa`) did not multiply with one typed before it. Pinned against headless nvim.
- The grep picker (`Space f w`) searched only the files the project walk had delivered so far — which, on the first open, is none, since the picker deliberately opens before the walk runs. It now resumes as each slice arrives.

### Performance

- `:e` (and opening from a picker) now paints the file before decorating it, the rule the first frame already followed: the parse, the `git diff` and the language-server handshake used to run first, so a 300 KB source file took 34 ms to appear. It now appears in 0.6 ms and is highlighted a frame later.

## 0.2.1 - 2026-07-25

### Performance

- Opening a file no longer spawns `git` when the file is not inside a work tree — a few `stat` calls replace a ~1.2 ms subprocess — and `loadPartial` no longer scans the not-yet-read tail of its own allocation. Together these took the 10 MB file from first paint to fully settled from 8 ms to 4 ms, and the settled benchmark from 13.3 ms to 9.7 ms (nvim: 10.2 ms).
- Fixed a benchmark bug that flattered other editors: `waitQuiet` started counting silence as soon as the key was sent, so an editor slower to respond than the quiet window scored as if it had finished immediately. Search and picker measurements now wait for a first response, and search is reported cold and warm.

## 0.2.0 - 2026-07-25

### Added

- Versioning and this changelog: the `VERSION` file is embedded into `--version` at build time.
- `zedit <dir>` enters the directory and starts in the fuzzy file picker (it used to fail with a raw `IsDir` error).
- Every CLI option now has a short form (`-l/--log`, `-s/--lsp`, `-c/--config`, `-t/--tutor`, `-b/--benchmark`).
- `--benchmark [file]`: a headless self-benchmark timing open, whole-buffer literal and regex search, and serialize.
- Mouse wheel scrolling (SGR mouse reporting; wheel-only, clicks ignored, Shift+drag still selects).
- Side-by-side git diff view tints changed/added/removed lines vimdiff-style in both panes (old-side hunk ranges tint the index pane).
- GitHub CI: tests on every push; tagged `v*` pushes release stripped ReleaseFast binaries for Linux x86_64/aarch64 (static musl) and macOS x86_64/aarch64.
- `TODO.md`: the working tracker (done in order, in progress, next, recurring per-feature checklist).
- Vim semantics pinned to ground truth: a `vim_compat` integration suite asserts byte-for-byte agreement with real Neovim driven headlessly, covering operators, autoindent, the jumplist, `:s`, and cmdline completion.
- AstroNvim-style `Space` leader tree with nested which-key popups (Find, Language tools, Git groups), grown alongside each feature below.
- Themed UI: five true-colour palettes (Tokyo Night default, Gruvbox, Catppuccin Mocha, Nord, One Dark) with live `:theme` switching, a powerline statusline, relative+absolute line numbers, cursorline, and indent guides.
- One documented config file (`~/.config/zedit/config`) with `--init-config` to write the annotated default (theme, `tab_width`, `nerd_font`, `sidebar`, `relative_numbers`, `large_file_mb`, `autoindent`, `format_on_save`), plus an embedded interactive tutorial via `--tutor`.
- Pickers for files, project-wide grep, buffers, and themes — one consistent UI with Zed-style warm caching: the file list is cached per session, candidates are prefiltered with per-path char bitmasks, and extending the query narrows the previous result set.
- Multiple cursors: `Ctrl-n` / `Ctrl-p` add a caret per line; movement and edits apply to every caret.
- Surround (`ys`/`cs`/`ds`, visual `S`) and blockwise visual (`Ctrl-v` with `I`/`A` column insert).
- Built-in editing niceties: auto-pairs and comment toggling (`gcc` / `gc{motion}`) — no plugins.
- Regex engine (`regex.zig`, Pike VM / Thompson NFA — linear time, no catastrophic backtracking) powering incremental highlighted search (`/ ? n N * #`) and `:[range]s/pat/rep/[gi]` substitution with `&` and `\1`–`\9` captures.
- Jumplist: `Ctrl-o` / `Ctrl-i` walk back and forward through jumps (searches, `G`, marks, `gd`, buffer switches — cross-buffer, capped at 100).
- Multiple buffers and windows: `:e`, `:bn`/`:bp`/`:bd`/`:ls`, `:split`/`:vsplit` with `Ctrl-w` navigation; each buffer keeps its own cursor, undo history, highlighting, and language server.
- File-tree sidebar (`Space e`) on the configured side, skipping hidden/ignored directories.
- Git integration: an always-on change gutter (signs from `git diff -U0`), an inline unified diff view (`Space g d`), and a side-by-side index view (`Space g s`).
- LSP client (pure Zig, JSON-RPC over stdio), auto-launched per filetype: diagnostics with `]d` / `[d` navigation, hover (`K`, and `Ctrl-k` in insert mode), goto definition, completion popup, and signature help with overload cycling (`Ctrl-p`, `(i/n)` counter).
- More LSP: rename (`gr`), code actions (`ga`, including `workspace/executeCommand` and server-initiated `applyEdit`), a document-symbols picker, and inlay hints rendered as dim virtual text.
- LSP references picker (`Space l R`), formatting (`Space l f` / `:format`) with format-on-save, and full cross-file multi-line WorkspaceEdit support — other open buffers edited in place, unopened files loaded as background buffers, written together with `:wa`.
- Tree-sitter syntax highlighting for 10 languages — Zig, C, Python, JSON, JavaScript, TypeScript, Rust, Go, HTML, and Markdown (block + inline layers) — via vendored C grammars; the dependency-free lexer remains the fallback.
- First-class SSH support: `"+` / `"*` reach the system clipboard via OSC 52, terminal pastes arrive through bracketed paste (literal, single undo step), and frames are row-diffed so only changed rows are written.
- Autoindent (vim's 'autoindent'): `o`/`O`/Enter/`cc` inherit indentation, and blank auto-indents are stripped on leaving the line.
- Command-line Tab completion (command names, `:e`/`:w` paths, `:theme` names — nvim wildmenu semantics) and per-kind `:` / `/` history with prefix filtering.
- A man page (`doc/zedit.1`), installed by the build.
- A pty benchmark suite (`zig build bench`) comparing zedit with helix and nvim: startup, 10 MB open, keypress latency, picker open.
- `doc/COMPARISON.md`: a verified feature-gap analysis vs Helix and Neovim driving the roadmap.

### Changed

- Renamed the editor from `zed` to `zedit` (zig-editor).
- Ported the pty test harnesses from Python to Zig — `zig build itest` now needs nothing beyond the toolchain.

- Tree-sitter structural text objects: `af`/`if` (function), `ac`/`ic` (class, struct, impl, enum) and `]f`/`[f` to jump between functions, resolved from the syntax tree instead of brace counting. Covers Zig, C, Python, Rust, Go, JavaScript and TypeScript; the search is pruned so `]f` costs ~0.4 ms on a 320 KB file.
- Workspace symbol search (`Space l S`): the typed query goes to the language server, which matches across files that were never opened, and Enter jumps to the symbol.
- Diagnostics picker (`Space l D`): every diagnostic across the open buffers, tagged by severity, with Enter jumping to the line.
- Picker rows now live in one byte arena addressed by offsets instead of two heap allocations each, are formatted into stack buffers, and keep their capacity when the picker closes. Measured over a 4000-file tree: peak memory across picker cycles −22% (984 KB → 768 KB) and filtering slightly faster.
- The picker preview is tree-sitter highlighted and scrollable on its own (`Ctrl-d` / `Ctrl-u` or the mouse wheel, stopping at the end of the file).
- Clicking a buffer tab switches to it.
- Compiled tree-sitter highlight queries are shared for the life of the process instead of being rebuilt per buffer: compiling one costs 3–14 ms, so opening many files of a language (or previewing them) now pays it once. This is what keeps picker-open at ~6 ms with a highlighted preview, against ~19 ms for the naive version.
- One consistent search layout: every picker now shows the file tree on its side, the results beside it, and a live syntax-highlighted preview of the selected file (scrolled to the matching line for grep and references). `zedit <dir>` opens straight into that view.
- Open buffers are listed as tabs across the top when more than one is open, with the active one highlighted and unsaved ones marked (`buffer_tabs` config).
- Mouse-wheel scrolling now carries the cursor with the viewport, keeping its screen row, so scrolling to the top of a file no longer strands it at the bottom of the page.
- The statusline keeps the finished command visible (`diw`, `2dd`, `"ayy`) until the next one starts, instead of clearing the instant it runs; a status message still takes precedence for the space.
- `Space` opens the leader menu while the file explorer has focus, as it does everywhere else.
- Dismissing a popup repaints only the rows it covered rather than the whole screen (3155 → 1481 bytes for the which-key menu), which is what made it feel sluggish over SSH.
- `gi` and `gy` jump to a symbol's implementation and type definition.
- Snippet tabstops now survive line splits and joins, and choice placeholders (`${1|a,b,c|}`) offer their alternatives on `Ctrl-n`/`Ctrl-p` instead of silently using the first.
- Snippet completions: items the server marks as snippets expand their placeholders and start a tabstop session — `Tab`/`Shift-Tab` walk the stops, the first keystroke at an untouched placeholder replaces it, `Esc` ends the session. Completion items also honour the server's `textEdit` range instead of guessing the identifier prefix, and apply `additionalTextEdits` (auto-imports). zedit now advertises `snippetSupport`, so servers offer them at all.
- Completion now pops up on its own while typing (debounced by `completion_delay_ms`, default 150 ms; `auto_completion = false` restores manual-only) and the list is fuzzy-matched and ranked with the pickers' scorer — `mplt` finds `mockComplete`. The debounce is armed only while typing, so an idle editor still blocks in `poll(2)` at zero CPU.
- Partial commands are shown as you type them at the right of the statusline (vim's `showcmd`): `d`, `di`, `2d`, `"ay`, `^W`, cleared the instant the command executes; the macro-recording marker shares the slot.
- Inline diagnostics: each LSP diagnostic's message renders after the code on its line as dim, severity-coloured virtual text (config `inline_diagnostics`, on by default), so every problem on screen is visible at once.
- Remote editing over SSH: `zedit ssh://[user@]host[:port]/path`, `:e ssh://…` and `:ssh host[/dir]` edit files on another machine with nothing installed there — one `ssh` per operation (`cat` to read, `cat >` to write, `find` to list a directory into the fuzzy picker), remote paths shell-quoted, `BatchMode=yes` so a prompting host fails fast, and `ControlMaster` connection reuse.
- Startup screen listing recently opened files and directories (`j`/`k`, `Enter`, `1`-`9`), backed by `$XDG_STATE_HOME/zedit/recent` — capped, de-duplicated, with vanished paths pruned on load.
- `:update` / `--check-update`: compare this build with the newest published release tag (one `git ls-remote`), on demand only.
- Paragraph motions and text objects: `{` / `}` (jump motions) and linewise `ip` / `ap` with counts, available in visual mode too — 16 cases pinned to real nvim.

### Security

- Control bytes from untrusted sources (file content, LSP hover/inlay/completion text, file names, pasted command-line text) are rendered as `?` placeholders instead of being written raw to the terminal, closing the classic escape-sequence injection where a hostile file could retitle the screen or trigger terminal query replies that arrive as synthetic keystrokes.

### Fixed


- Long jumps (`G`, `100G`, a search hit) now redraw with the cursor centred, as vim does. It used to land on the bottom row, so every mouse-wheel notch immediately dragged it — wheel scrolling now matches nvim exactly at equal window heights.
- The normal-mode cursor no longer sits past the last character (vim's rule), fixing a whole class of off-by-one bugs after `$`: `$x` did nothing, and `$dh` / `$d0` / `$db` / `$dF` all deleted one character too many.
- `:qa` now refuses to quit while any buffer has unsaved changes (nvim's E37 behaviour, pinned in `vim_compat`); `:qa!` discards.
- `:wa` names failed saves ("1 written, 1 failed — ro.txt: permission denied") instead of skipping them silently; `:w` failures read as plain English instead of raw error enums.
- An explicit `--config` or `--log` path that cannot be opened is reported instead of silently ignored, and LSP spawn/handshake/exit, config loads, git-sign and tree-sitter fallbacks are all traceable in the `--log` file.
- `:e` now detects the new file's language instead of keeping the previous buffer's.
- Mangled roff escapes in the jumplist man-page entry.

### Performance


- Files are read in two phases: a 256 KB head is indexed and painted, and the rest is pulled in right after the first frame. First paint on an 8.2 MB file went from 7.4 ms to 2.9 ms — sooner than nvim (3.8 ms).
- The picker opens before its project walk has run and streams results in, ~2 ms of walking per loop iteration. On a 20k-file tree the picker is visible in 0.5 ms (helix, which uses background threads for the same job, takes ~1.1 s on that tree).

- Startup paints the text before decorating it: syntax highlighting, git signs and the LSP handshake now run after the first frame instead of in front of it. First paint on a 320 KB source file went from 48 ms to 0 ms, and on an 8.2 MB file from 7 ms to 4 ms.
- The benchmark reports first paint alongside settled time, since a settle-only number penalises exactly this kind of progressive rendering.

- Literal search now uses a first-byte/last-byte SIMD scan, and the whole-source fast path is authoritative instead of falling through to a per-line rescan when there is no match: on an 8.2 MB file a miss went from 301 ms to 0.37 ms, and a search with 205k matches from 18.6 ms to 7.1 ms. The head-to-head 10 MB search dropped 7.9 → 5.1 ms.
- Opening a file builds a lazy `u32` line index rather than a 32-byte record per line; per-line storage is materialised only by the first edit, so reading, searching, rendering and saving skip it entirely. An 8.2 MB file opens in 4.65 ms instead of 6.85 ms and uses 18.5 MB instead of 32.3 MB.

- The vendored tree-sitter C is compiled once into a shared static library instead of once per artifact: `zig build test` no longer re-pays the whole C build (8-core measurements: 2.80 s → 1.38 s; cold build 3.13 s → 2.86 s; 22 → 11 parser objects).

- Zero-copy buffer loading: lines borrow from one shared read buffer and copy on first edit.
- Huge-file handling: files up to 2 GB open, and above `large_file_mb` (64 MB default) highlighting, LSP, and git signs are skipped; literal search takes a one-pass whole-source SIMD fast path (a 476 MB / 10M-line file opens in ~375 ms and searches in ~196 ms).
- Tree-sitter reparsing is incremental (the prior tree is reused) and highlight queries run only over the visible range, keeping per-keystroke work O(screen), not O(document).

## 0.1.0 - 2026-06-15

### Added

- Initial modal terminal editor in pure Zig: normal/insert/visual/command modes, an event-driven core that blocks in `poll(2)` (zero idle CPU), single-syscall frames, UTF-8-correct movement and rendering, and a friendly CLI (`--help`, `--version`, `--log`).
- Comprehensive vim keybindings: the `[count]` operator-then-motion grammar (`d c y`, `> <`, doubled forms), motions (`w b e`, `f t`, `%`, `gg G H M L`…), text objects (`iw`, `i(`, `a"`…), registers and paste, undo/redo, dot-repeat, visual mode, marks, and macros.

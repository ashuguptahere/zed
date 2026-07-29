# TODO

The working tracker for zedit. Items move to **Done** (newest last, so the
list reads chronologically) when they land with tests + docs + changelog in
the same commit. `doc/COMPARISON.md` holds the verified feature-gap analysis
behind the roadmap items.

## In progress

- (nothing — pick the next item below)

## Next (in order)

1. [ ] **The CI-only test failure.** `zig build itest` is green locally
       (including pinned to two cores with `taskset`, to rule out a load
       race), but CI reports `1093 passed, 1 failed`. The run now reprints
       every failed check as `suite: name` at the tail (0.28.0), so the next
       CI log names it — that is the blocker, not the fix.
2. [ ] **The terminal's own colour at the far right / far bottom.** Traced as
       far as the code allows: every render branch pads to its window's width
       (`emitFillerRow`, `emitDeletedRow`, `past_eof`, `emitLine`), the
       tiling's last window absorbs the division remainder in both
       orientations (`layout`), and all three `\x1b[K` sites set the theme
       background first — so no *cell* is left unpainted. What is left is the
       sub-cell strip gnome-terminal keeps when the window size is not an
       exact multiple of the cell size; no TUI can paint it, and nvim shows
       it too. The one real fix is OSC 11 (set the terminal's default
       background to the theme's on entry, OSC 111 to restore on exit,
       including the panic/signal paths) — invasive enough to want the owner's
       say-so first, and worth confirming against a screenshot that the strip
       is thinner than one character cell.
3. [ ] **Which-key coverage of what already exists.** Done for the undo tree
       (`Space f u`) and a new buffer (`Space n`) in 0.29.0. Still unbound:
       `g-`/`g+` and `:earlier` (time travel), and window/split management,
       which `Ctrl-w` covers the vim way — decide whether a leader group is
       wanted at all before adding one.
4. [ ] **A verified AstroNvim/Helix keymap gap analysis**, updating
       `doc/COMPARISON.md` — key by key, not from memory.
5. [ ] **Session / workspace save + restore** (open buffers, windows,
       cursors, the tree's expanded set).
6. [ ] **Embedded terminal** — a VT emulator in a window. Large, multi-batch.
7. [ ] **Debugger** — a DAP client (breakpoints, stepping, variables).
       Large, multi-batch. No package management (agreed with the owner).

Local builds are host-only already (`b.standardTargetOptions`); the release
workflow's matrix passes `-Dtarget=` for the cross-compiled artifacts, so
there is nothing to change there.


## Recurring (every feature / significant change)

- [ ] Allocation discipline: no per-item heap allocation in loops that can run
      thousands of times; format into stack buffers, clear-and-reuse instead of
      free-and-reallocate (see the picker arena in `editor.zig`).

- [ ] Regression tests in the same commit (unit + pty itest; vim behaviour
      pinned via real nvim through a pty — never from memory), and each one
      checked to *fail* without the change. A new config setting gets a test
      that the key does something; `config.zig`'s comptime completeness test
      already fails if it is undocumented or unparsed.
- [ ] Docs sweep: README, CLAUDE.md, man page, tutor, COMPARISON, CHANGELOG.
- [ ] Security pass: no raw untrusted bytes to the terminal, argv-array
      spawns only, no secrets; audit sweep periodically.
- [ ] Benchmark + profile: `zig build bench -Doptimize=ReleaseFast` and
      `zedit --benchmark` before/after perf-relevant changes; `log.Span`
      numbers for hot paths. No perf claim without a measurement.

## Later / known gaps (tracked in CLAUDE.md + COMPARISON.md)

- [ ] Windows console support (`term.zig` gate marks the spot).
- [ ] Nested/mixed window layouts and per-window resizing.
- [ ] Side-by-side diff: a leading deletion gap taller than the window shows
      only its tail (the pane top is a buffer row, clamped to keep the cursor
      on screen; a display-space pane top would make the whole gap reachable).
- [ ] `[count]` before an insert command (`3a`, `3A`, `3i`, and blockwise
      `3A`) types the text that many times in vim; zedit types it once
      (nvim: `3a` `X` Esc on "abc" → "aXXXbc", zedit → "aXbc"). The whole
      family shares one rule — repeat the insert session's text on Esc — so
      it wants doing once, with its own nvim-pinned tranche.
- [ ] `p`/`P` in visual mode (replace the selection with a register) is not
      implemented at all — no selection kind, blockwise included (nvim:
      `<C-v>jly` `jj0` `vl` `p` gives "11cd" / "22efgh"; zedit leaves the
      buffer untouched). Separate from the rectangular paste, which is done.
- [ ] Pasting a block *into* the middle of a tab resolves to the tab's own
      boundary instead of splitting the tab into spaces. Probed with
      `tabstop=4` on "11\n22\nabcd\n\tZ": `<C-v>jly` `jjl` `P` gives nvim
      " 22   Z" on the last line, zedit "22\tZ". Needs vim's virtual-column
      machinery (`coladvance`), so it is its own piece of work rather than a
      patch to the paste. (A block *edge* on a tab is handled: it covers the
      tab whole, as vim does — `nvim#bp37`/`nvim#bi17`.)
- [ ] `[count].` replaces only a *leading* count. A count typed after the
      operator is still multiplied by the new one: nvim's `d2w` then `3.`
      deletes three words and `2d2w` then `3.` also three, where zedit deletes
      six in both (probed on "a b c d e f g h i j k l m"). vim can do it
      because its redo buffer holds one normalised count; zedit replays the
      recorded *bytes*, and there `2` in `d2w` is indistinguishable from the
      `2` in `f2` or `r2` without parsing the command. Fixing it means
      capturing the count beside the keys at record time — its own tranche,
      with the `[count]`-before-insert family above.
- [ ] A bare `/` or `?` (Enter on an empty pattern) clears the last search
      where vim repeats it (nvim: `/X` then `qq` `/` Enter `x` `q` `gg0` `@q`
      deletes the X on line 1; zedit's replay finds nothing and — since the
      empty commit now counts as a failed search — stops before the `x`).
      Two lines in `searchPreview`, but it wants the nvim-pinned case that
      goes with it.
- [ ] `G`/`gg` go to the line's first non-blank; nvim keeps the cursor's
      column (its `'startofline'` is off by default). Probed: on
      "foo\nbarbaz", `ll` `G` `x` gives "babaz" in nvim, "arbaz" in zedit.
      Affects every jump that lands on a new line, so it wants its own pass.
- [ ] Tree-sitter depth, the rest of it: `@indent.end`/`@indent.dedent`
      (a Python `return` should dedent; nvim-treesitter does) and
      `@indent.align` (align a wrapped expression to its opening paren), an
      `=` re-indent operator, nested injections (depth is 1 today), a CSS
      grammar so an HTML `<style>` body stops being plain, and the
      `#offset!`/`#gsub!`/`injection.combined` directives upstream queries
      use. `#is?`/`#is-not?` want a locals query. Also `o` *on* a blank line
      inside a block: zedit keeps plain vim's column 0 (the tree has nothing
      to say about a blank line), nvim-treesitter indents to the block —
      pty-probed, pinned as `ts-indent#b4`.
- [ ] Remote: remote git signs/sidebar, partial transfers for huge remote
      files.
- [ ] Mouse gestures beyond the four-click cycle: Alt+drag blockwise (a
      different anchor rule — the pre-click cursor — and many terminals eat
      Alt), edge auto-scroll while dragging (needs a repeat timer; the
      completion debounce is the only timer zedit arms), drag-to-resize
      splits.
- [ ] The wheel's step counts buffer lines inside the diff views (as
      `Ctrl-d/u/f/b` do): `winLineAfterRows` branches only on soft wrap, not
      on a pair's fillers or the line diff's woven rows.
- [ ] A linewise visual operator leaves the cursor in the wrong column
      (found while reviewing the mouse work, pre-dates it, reproduces without
      the mouse): nvim keeps the column across `Vd` and moves it to 0 across
      `Vy`; zedit does the opposite for both. Needs its own nvim-pinned
      tranche in `vim_compat`, since `dd`/`cc`/`>` and the operator-pending
      path share the rule.
- [ ] More nvim ground-truth test tranches (the linewise-visual cursor column
      above; operator-pending `gj`/`gk`; sentence objects).

## Done (chronological)

- [x] `Space u` UI toggles, explorer `a`/`A` new file/folder with missing
      directories created, `:w` doing the same, VS Code's tree arrows,
      `Space b c` = close others, showcmd naming special keys, the wheel
      counting virtual rows over a diff (the scroll jumping), one table
      behind every which-key group, and an itest runner that names its
      failures and takes suite filters. (0.28.0)
- [x] `Space f u` (undo tree) and `Space n` (new buffer): two features that
      existed with no key. (0.29.0)

- [x] Modal editor core: event-driven zero-idle-CPU loop, single-syscall
      frames, UTF-8-correct movement/rendering, friendly CLI. (0.1.0)
- [x] Comprehensive vim keybindings: operators, motions, text objects,
      registers, undo/redo, dot-repeat, visual, marks, macros. (0.1.0)
- [x] Themed UI: 5 true-colour palettes, powerline statusline, line numbers,
      cursorline, indent guides; `:theme` + picker.
- [x] Syntax highlighting: per-line lexer, then tree-sitter for 10 languages
      (incremental parse, visible-range queries).
- [x] Multiple cursors (one caret per line), surround, blockwise visual,
      auto-pairs, comment toggling.
- [x] Pickers (files/grep/buffers/themes) with Zed-style warm caching and
      char-bitmask prefiltering.
- [x] LSP: diagnostics, hover, goto, completion, signature help + overload
      cycling, rename, code actions + executeCommand/applyEdit, document
      symbols, inlay hints — per-buffer clients.
- [x] Config file (single, documented; `--init-config`), `--tutor`, man page.
- [x] vim_compat suite: byte-for-byte agreement with headless nvim.
- [x] Multiple buffers & windows (splits), file-tree sidebar, git gutter +
      inline/side-by-side diff views.
- [x] Benchmark suite vs helix/nvim (`zig build bench`); zedit wins startup,
      keypress latency, big-file search.
- [x] Zero-copy buffer loading (CoW lines); huge-file mode (2 GB cap,
      `large_file_mb`), SIMD whole-source literal search.
- [x] Shortlist #1: regex engine (Pike VM) — `/ ? n N * #` + `:%s` with
      captures.
- [x] Shortlist #2: jumplist (`Ctrl-o`/`Ctrl-i`, cross-buffer).
- [x] Shortlist #3: SSH first-class — OSC 52 clipboard, bracketed paste,
      row-diffed rendering.
- [x] Shortlist #4: autoindent (vim rule, blank-strip, nvim-verified).
- [x] Shortlist #5: LSP references picker, formatting + format-on-save,
      cross-file multi-line WorkspaceEdits, `:wa`.
- [x] Shortlist #6: cmdline Tab completion (nvim wildmenu semantics) +
      `:`/`/` history with prefix filtering.
- [x] Directory open (`zedit .` → file picker), short+long CLI flags,
      `--benchmark` self-test.
- [x] VERSION file + CHANGELOG.md; both part of the per-feature workflow.
- [x] Security: control-byte sanitization of all untrusted render paths
      (escape-injection class), hostile-file regression test.
- [x] Data-safety: `:qa` refuses on dirty buffers (nvim E37), `:wa` names
      failed saves, plain-English error messages, full log traceability.
- [x] Dead-code audit sweep (8 findings removed; std reimplementations
      replaced with std calls).
- [x] Side-by-side git diff change tinting in both panes (+ colour-pinned
      tests for the inline view's green/red).
- [x] Mouse wheel scrolling (SGR mouse mode, nvim's 3-line step).
- [x] Shortlist #7: paragraph motions `{` `}` + linewise `ip`/`ap` objects
      (counts, visual mode); 16 nvim-pinned cases, which also exposed the
      cursor-past-EOL bug behind `$x`/`$dh`/`$db` (fixed + 5 more cases).
- [x] GitHub CI (tests every push) + release pipeline (tag push → stripped
      ReleaseFast binaries: Linux x86_64/aarch64 static musl, macOS
      x86_64/aarch64) — all four targets verified cross-compiling locally.
- [x] Purged `new.py` (and a stray file named `"`) from the working tree and
      all 45 commits of history; `.gitignore` guards against a repeat.
- [x] Remote editing over SSH (`ssh://` URLs, `:ssh`, remote picker, write
      back) with shell-quoting proven by an injection test.
- [x] Startup screen with recently opened files/directories (`recent.zig`,
      XDG state file, pruning + dedup).
- [x] `:update` / `--check-update` against the newest release tag.
- [x] Shortlist #8: inline diagnostics (dim severity-coloured virtual text
      after the code; `inline_diagnostics` config, on by default).
- [x] Streaming load (256 KB head painted, tail read after the first frame:
      8.2 MB first paint 7.4 → 2.9 ms) and a streaming picker (project walk in
      ~2 ms slices into an open picker: 20k-file tree visible in 0.5 ms).
- [x] SIMD literal search (miss 301 ms → 0.37 ms; 10 MB search 7.9 → 5.1 ms)
      and lazy line indexing (8.2 MB open 6.85 → 4.65 ms, RSS 32 → 18 MB).
- [x] Tree-sitter structural objects `af`/`if`, `ac`/`ic` and `]f`/`[f`
      (node names read off the vendored grammars).
- [x] Workspace symbols picker (`Space l S`, server-side query) and
      diagnostics picker (`Space l D`), built on a rewritten picker store:
      one offset-addressed arena, stack formatting, retained capacity
      (−22% peak RSS on a 4000-file tree). Ghostty-inspired.
- [x] Preview polish (tree-sitter highlighting, Ctrl-d/Ctrl-u + wheel
      scrolling) and tabline click-to-select; compiled highlight queries are
      now shared process-wide, which kept picker-open at ~6 ms.
- [x] Picker layout: tree + results + live file preview, used by every
      picker; `zedit <dir>` opens into it. Buffer tabs along the top.
- [x] UX batch: wheel scrolling carries the cursor (owner's choice), the
      finished command stays on the statusline, `Space` works in the explorer,
      and dismissing a popup repaints only its rows (3155 → 1481 bytes).
- [x] Snippet polish: tabstops survive splits/joins; choice placeholders
      cycle with Ctrl-n/Ctrl-p. Goto implementation (`gi`) / type
      definition (`gy`).
- [x] Shortlist #10: snippets (`snippet.zig` parser, tabstop session,
      Tab/Shift-Tab, type-to-replace) + `textEdit` / `additionalTextEdits`.
      **The COMPARISON shortlist is now complete.**
- [x] Shortlist #9: auto-triggered (debounced) + fuzzy-ranked completion
      (`auto_completion`, `completion_delay_ms`; idle CPU still zero).
- [x] Scroll/jump centring fixed (nvim-verified): wheel scrolling no longer
      drags the cursor from the bottom row; 4 pinned cases.
- [x] `showcmd`: the partial command shown as typed in the statusline.
- [x] Build speed: tree-sitter C compiled once into a static library shared by
      all artifacts (`zig build test` 2.80 s → 1.38 s on 8 cores).
- [x] Beat nvim on settled time (13.3 → 9.7 ms vs 10.2) by dropping the
      uninitialised-tail scan in `loadPartial` and the `git diff` subprocess
      outside a work tree; fixed the `waitQuiet` benchmark bug that had been
      scoring slow editors as instant, and split search into cold/warm
      (zedit 5.1/5.1, nvim 51.6/14.7, helix 1943/20.0). zedit now leads every
      column.
- [x] Argument (`aa`/`ia`) and comment (`aC`/`iC`) text objects from the
      syntax tree. Writing them turned up three bugs, each now pinned to
      headless-nvim ground truth: visual-mode `a` objects behaved like `i`
      ones, counted find-char (`3fa`, `d3fa`, `2;`) ignored the count, and the
      grep picker missed every file the project walk had not yet delivered.
- [x] Fixed: file picker opened at the walk-cache index instead of line 1
      (preview scrolled wrong too); NUL width accounting (binary rows
      overflowed the terminal); malformed UTF-8 bytes leaked raw to the
      terminal past the sanitizer (8-bit CSI class) — all pty-pinned.
- [x] Repo-wide over-engineering audit applied: 81 verified findings, net
      −722 lines (init field-defaults, std.json serializers, shared
      xdgPath/nowMs/writeAll helpers, harness dedup, ~30 hand-rolled loops
      replaced with std calls). Benchmarks and all 401 checks unchanged.
- [x] Soft wrap: word breaks, indent retention (`wrap_indent`) and a
      `wrap_column`, with the screen-line motions following the real break
      points. Found and fixed a row being drawn past its break point.
- [x] Undo persistence (`persistent_undo`, off by default): the tree written
      to XDG state on save, restored on open, anchored to the file by length +
      hash so a stale history is refused. 1.5 KB for a 200-change session on an
      8.6 MB file; no measurable cost to `:w`.
- [x] Undo states stored as diffs against their parent, not whole-buffer
      copies (300 changes in a 7.6 MB file: 295 MB -> 43 MB), and
      `:earlier Nf` / `:later Nf` counted in file writes (5 nvim-pinned cases).
- [x] Undo tree: branches instead of discarding, `g-`/`g+`, `:earlier`/
      `:later` (counts and time spans, clamped), `:undolist` picker. Ten
      nvim-pinned cases; no measurable cost to edit latency on a 10 MB file
      (2.1 ms/keystroke either way).
- [x] Soft wrap (`soft_wrap`, on by default): continuation rows with a `↳`
      gutter marker, `gj`/`gk`/`g0`/`g$`, and screen-row counting for `H`/`M`/
      `L`, `Ctrl-d`/`u`/`f`/`b` and the wheel. Drawing a line once per row it
      fills exposed two O(line) costs per row; caching the styling and
      bounding the width scan took a 1.8 MB one-line file from 82 ms a frame
      to 4 ms.
- [x] Grep picker narrows instead of rescanning (~6 ms -> 4 µs per keystroke
      once the project has been scanned); equivalence pinned by tests that
      fail against a naive display-text filter.
- [x] `:e` paints before decorating (34 ms -> 0.6 ms to first pixel on a
      300 KB source file); the benchmark's new first-pixel column found it.
- [x] Cold/warm interaction benchmark table (`zig build bench`) covering every
      picker, the explorer, both diff views, `:e` and search.
- [x] Confirmed the toolchain is current: Zig 0.16.0 is the latest stable
      (master is 0.17.0-dev), so no upgrade was needed.
- [x] One powerline title bar on row 1 (EXPLORER segment + buffer tabs,
      shared geometry for drawing and clicks; VS Code-style always-on under
      `buffer_tabs`), the filename leaving the statusline while it shows,
      reveal-in-explorer on every buffer switch, `]b`/`[b` + the `Space b`
      Buffers group, and a `ui_sel` theme colour so selected picker/sidebar
      rows stay visible in every palette (Nord's selection was invisible).
      Fixed the flat-mode statusline painting 4 cells short, a byte-vs-
      width clip that shifted the bar when a message held an em dash, and a
      crash opening the sidebar under 18 columns with `buffer_tabs = false`
      (the "EXPLORER" header assumed 9 columns; it now clips).
- [x] Side-by-side diff rework (owner request): focus stays on the worktree
      pane, the index snapshot is read-only ("index snapshot is read-only";
      kills the dirty-scratch-blocks-`:qa` and `:w <name>` foot-guns),
      VS Code-style row alignment via `git.computeHunks` (one `git diff`
      feeds hunks + both sign maps) with tinted virtual filler rows (git-add
      in the index pane, git-delete in the worktree pane, blank gutter),
      lockstep scrolling derived through the alignment map every frame (wrap
      forced off in a visible pair), aligned-cursor `Ctrl-w w`, and
      `Space g s`/`Space g d` toggling their views closed from either pane
      ("no changes" instead of an empty split). Review round fixed: opening
      the view no longer yanks the cursor to the top, entering a pane from a
      third window pulls its stale cursor into the synced view instead of
      yanking the pair, `:bd` on the compared file strips the orphaned
      snapshot's alignment/tint state, and a malformed zero-start hunk header
      saturates instead of underflowing. 31 pty checks (edge hunks at line
      1/EOF, untracked file, third-window focus among them) + hunk/alignment
      unit tests incl. malformed headers.
- [x] Fish-style inline suggestions on the command line (owner request):
      dim ghost text after the cursor from the newest matching history entry
      (or a command name for `:`), Right/End accepts, Enter runs only the
      typed text, hidden while the wildmenu cycles, sanitized, no per-key
      filesystem I/O or timers; `cmdline_suggestions` config. Also made a
      cmdline paste behave like typing (it now invalidates the wildmenu ring
      and updates the history filter). 18 pty checks, 11 proven fail-without
      (incl. narrow-pty/CJK clip, accepted-search-ghost live jump); fixed the
      pre-existing "relative numbers by default" check that the 0.12.0
      version string had broken.
- [x] Regex project-wide grep picker: `Space f w` takes the same modern
      regexes as `/` (compiled once per query change, matched per line;
      the pure-literal `.lit` fast path with in-place narrowing, walk
      streaming and 500-hit-cap resume kept byte-for-byte). Regex changes
      full-rescan through the shared typing-pause debounce (`due_kind =
      .grep`) — measured ~35 ms per rescan on this repo in ReleaseFast vs
      1–4 µs per keystroke — and a mid-typing invalid pattern keeps the last
      good results with a dim `(incomplete)` prompt tag. `Ctrl-r` resets the
      hits/scan cursor with the cache it discards (a regex or invalid query
      cannot regrep synchronously and would otherwise resume mid-way through
      the new walk), and the debounce fires inside the walk loop too, not
      only from the post-walk poll. 17 pty checks, 9 proven fail-without
      (\d class, alternation across files, `^` anchor, invalid-keeps-results
      + tag + recompile, Ctrl-r-under-invalid-query reset); the three
      literal-narrowing checks and the mid-walk streaming check pass
      unchanged.
- [x] Cmdline mid-line editing + wildmenu directory-navigation keys (the two
      remaining cmdline gaps) and a CJK clip fix: a cursor column
      (Left/Right/Home/End/Ctrl-b/Ctrl-e, insert-at-cursor,
      backspace-before-cursor, recall/completion leave it at end-of-line;
      ghost renders/accepts only at end-of-line, fish's rule); while a path
      popup is open Down descends into the selected directory, Up
      re-completes in the parent, Left/Right select matches (non-path popups:
      Up/Down are plain filtered history recall — probed nvim already matched
      zedit's existing behaviour there); the typed cmdline row now clips by
      display cells on codepoint boundaries (shared `clipCells` with the
      ghost) instead of bytes. 9 nvim-pinned `vim_compat` cases (tmux-pty
      ground truth, incl. BS-at-col-0 no-op and recall-cursor-at-end) + 14
      pty checks (Screen-model hardware-cursor column, ghost hidden
      mid-line, dir descend/parent, history-with-popup-closed guard,
      CJK row fill), 16 proven fail-without. Review pass re-probed nvim
      (M1/M8/M9/W1b/W2/W4 confirmed byte-for-byte), pinned Enter-mid-line
      runs the whole line (nvim#e10), fixed the wildmenu popup's byte clip
      (same cell-based helper as the cmdline row) and pinned the overflow
      cursor to the last cell (both proven fail-without), and added
      search-prompt mid-line, CJK backspace, ghost-reappear, Left/Right
      match-select, Tab-after-descend and root-parent checks (+15 checks).
- [x] Root-caused audit batch (5 fixes, each proven fail-without): (1) the
      side-by-side diff can show hunks whose deletion precedes line 1
      (`paneDisplayTop` anchors a row-0 pane top at display row 0,
      cursor-clamped, routed through render/scroll/cursor-row/H-M-L; total
      deletion no longer shows an empty index pane — residual known gap: a
      gap taller than the window shows only its tail); (2) the two diff
      views are exclusive per file and *both* toggles key on a visible
      window (no third window, no orientation clobber, no phantom "diff
      closed" from either `Space g d` or `Space g s` after `:bn`/`:close`);
      (3) born-empty buffers highlight: reparse computes the
      incremental edit for empty↔non-empty transitions instead of handing
      tree-sitter an unedited old tree (api.h contract), and `:w name.py`
      on an unnamed buffer now detects filetype + starts TS/LSP; (4) `:e`/
      picker-open on an untouched `[No Name]` buffer replaces it (vim's
      rule, nvim-verified; modified/split-visible/tutor buffers kept);
      (5) `build.zig.zon` version corrected to match `VERSION`, with a
      comptime build check that fails on any future mismatch (proven by
      planting one). 2 new unit tests + 20 pty checks failing before /
      passing after; full suites green (152 unit, 571 itest).
- [x] Explorer mouse clicks (owner request): a single click on a tree row
      selects it and acts as Enter — a directory toggles, a file opens with
      focus back in the buffer (VS Code's rule) — and a click on the
      EXPLORER header/title-bar segment or the space below the tree focuses
      it, no prior focus needed. Hit-test and renderer share one geometry
      source (`sb_tree_top` + `sbRows` + `sb_scroll`, the tabline
      invariant); left/right sidebar, scrolled trees and the title-bar row
      all resolve through it. Text-area clicks stay unbound (pinned with a
      Screen-model cursor assertion) and Shift+drag terminal selection is
      untouched. 17 new pty checks, behavioural ones proven fail-without.
- [x] Review fix for the above: a click's *release* half decoded as
      `unknown`, smearing its raw bytes (`^[[<…m`) into showcmd and
      resetting pending operators/counts the wheel preserves. Non-acting
      mouse reports (release, drag, right/middle buttons) now decode to an
      inert `mouse_other` swallowed in `feedKey` before capture/dispatch.
      Unit-pinned in key.zig; scenarios now send press+release pairs the
      way real terminals do, plus new pins: boundary rows/columns on both
      sidebar sides at 80 and 16 columns, clicks swallowed in visual mode
      and under an open picker, deleted-file click (`:e` new-file rule),
      fast double-clicks in one write, and operator preservation across a
      click (wheel parity). Fix checks proven fail-without; suites green
      (unit + 605 itest).
- [x] Line-by-line diff view (owner request: "line by line view which
      vscode/zed has"): `Space g l` / `:ldiff` weaves each hunk's old lines
      into the file's own window as red virtual rows above their
      replacements — no split, no scratch, the buffer stays editable.
      `git.LineDiff` retains the `-` bodies from the same single
      `git diff -U0` parse the signs use (`above(row)` anchors old text at
      new-side rows); the renderer injects the rows before each anchored
      line (dim `-` gutter, no number, sanitized, unwrapped/clipped, still
      row-diffed), added/changed lines tint on their real rows (a pure
      deletion's survivor is deliberately not tinted — the woven rows carry
      it), and cursor/scroll geometry (`cursorScreenRow`, `lineAtScreenRow`,
      a scroll nudge, `ldLeadingSkip` for a pre-line-1 deletion) skips the
      virtual rows so the cursor can never land on one. Refreshes on `:w`
      like the signs (closing when no changes remain); the three diff views
      are exclusive per file, both ways. Unit tests for the `-U0` body
      parse/anchors/padding; 20 pty checks (weave positions/tints/gutter,
      j-skip, save re-anchor, three-way exclusivity, no-changes, total
      deletion, :qa) — 18 proven fail-without, the rest trivially-true
      guards. Review hardening: a `:w` refresh with the weave open now
      derives the gutter signs from the weave's own hunks — one `git diff`
      subprocess instead of two (strace-verified: open +1, `Space g l` +1,
      `:w` +1), clearing the signs when the weave closes clean; 17 more pty
      checks (leading line-1 / EOF anchors, soft-wrap cursor-row geometry,
      a 200-line block taller than the window crossed both ways, woven-text
      ESC sanitization raw-stream assert, clean-save closing weave + signs,
      weave surviving splits/`:bn` — pinned as doc state, shown per
      window); known gaps now name the tall-block limit (buffer-row top:
      only the head shows, `j` across jumps the view) and that
      `Ctrl-d/u/f/b` count buffer lines like the wheel. Row-diff deltas
      (~1.1 KB per cursor move with the weave up) and zero idle CPU
      measured. Suites green (unit + 648 itest).
- [x] Three safety items in one sweep. (1) Atomic remote writes: `:w` over
      ssh streams into a `.zedit.tmp.<random>` file beside the target and
      renames it into place in the same single ssh invocation
      (`[ ! -d target ] && cat > tmp && mv -f -- tmp target || { rm -f --
      tmp; exit 1; }`, both paths shell-quoted), so a transfer that dies
      partway can never truncate the remote file; a failed write reports
      "ssh transfer failed", and a target that is an existing directory is
      refused up front (the review caught `mv` moving the temp *into* it
      and exiting 0 — a "successful" write that created nothing at the
      asked-for path). (2) Undo-file pruning: writing an undo file (the
      only moment zedit touches the state dir) prunes siblings whose mtime
      is over 90 days old — a named constant, not a knob — logging each
      removal; only names `filePath` itself generates (exactly 16 hex
      digits + `.undo`) are ever candidates, so foreign files are never
      touched, and nothing is scanned unless persistent_undo writes
      (measured: a 1000-entry dir scans in ~1.8 ms ReleaseFast, per undo
      write). (3) The `Space g d` unified-diff scratch is read-only via a
      `Doc.read_only` flag set by `openScratch` (the index snapshot's
      `diff_of` check keeps its own message): edits, pastes and `:w <name>`
      answer "diff view is read-only", so a viewed diff can never dirty
      into a `:qa` blocker; an orphaned index snapshot now stays read-only
      too; the `Space g l` weave stays editable by design. Unit test for
      the prune policy (shape gate, boundary, future mtime); pty checks for
      the odd-path tmp+rename round trip, no-temp-leftover, one-ssh-spawn-
      per-write (counted via the mock ssh's invocation log), a failed
      remote write leaving the target untouched, the directory-target
      refusal, 90-day prune vs fresh, foreign and symlinked siblings (an
      undo-named symlink is neither followed nor deleted), and the scratch
      rejecting edits/pastes/`:w` while still toggling and never blocking
      `:qa` — all proven fail-without. Suites green (unit + 666 itest).
- [x] Four root-caused fixes in one sweep. (1) Picker clicks: `mouseClick`'s
      mode gate swallowed every click in the picker view (the whole
      `zedit .` startup) — new `pickerClick` route: result rows select on
      the first click and open on a click at the already-selected row
      (double-click opens, no timer), explorer clicks delegate to `sbClick`
      (with `sbActivate` closing the picker before a file-open), tab clicks
      close the picker and land on the buffer, prompt/preview stay inert;
      the layout block is extracted into `pickerLayout`, shared by
      `renderPickerBody` and the hit-test (the tabline's draw-here-
      click-here invariant), and `pickerKey`'s unreachable wheel arms are
      gone. (2) `:bd` vim parity (nvim-probed): the last clean buffer is
      replaced by a fresh `[No Name]` (window stays, adopted by the next
      `:e`), dirty refuses with "no write since last change" (E89 parity —
      it used to silently discard with 2+ buffers), and `:bd!`/`:bdelete!`
      discards; `Space c`/`Space b c` inherit the refusal. (3) showcmd
      captures the *decoded* key, not raw bytes: arrows/Esc/paging render
      nothing and clear the indicator (nvim pty-probed) instead of smearing
      `^[[B`; `^W`-style caret display stays; macro/dot raw capture
      untouched (replay proven by scenario). (4) Modified = undo-state
      identity of the last write (`History.last_saved`, vim's
      `b_u_save_nr`, four nvim-pinned cases): undo back to the saved state
      clears dirty so `:q` exits, past it stays dirty, manual retype stays
      dirty, `:wa` marks every written buffer, prune of the saved node
      stays conservatively dirty, persistent-undo load anchors it. Unit
      tests (4 new in undo.zig) + pty scenarios (picker/windows/feature/
      undotree/sidebar), every behavioural check proven fail-without
      (10/11/6/3+3 targeted failures with each fix planted out). Suites
      green (unit + 706 itest).
- [x] Review sweep over the four fixes: normal-mode arrows/`<BS>` now take
      a count like `h j k l` (nvim-probed `3<Right>`/`2<Down>`/`2<BS>`;
      `<Home>` ignores it — the count used to be consumed and dropped),
      pty scenario in feature.zig proven fail-without (1 targeted FAIL,
      706 pass with the old arms planted back). Independently re-probed:
      `:bd` on the sole [No Name] (nvim keeps one, no error — matches),
      `:bd` with the buffer in two windows (both fall back — matches),
      `:qa` after `:bd`, `:w` mid-undo-chain + `g-`/`g+` dirty flags, and
      cross-session persistent-undo (undo into the old session dirties,
      redo back to the anchor cleans — nvim `:ls` `+` parity). Picker
      clicks probed at every boundary column, all picker kinds,
      sidebar=right and a 16-column terminal. Suites green (unit + 707
      itest).
- [x] Three picker/explorer UX items (owner-approved): (1) `Space e` is
      VS Code's three-state cycle — closed → open+focused, open+unfocused →
      refocus (no rebuild, selection survives), focused → close. (2)
      Space-separated multi-term fuzzy queries (`fuzzy.scoreTerms`) in every
      fuzzy picker via the shared `refilter`; grep stays pure regex (space
      is a literal, `foo.*bar` orders); the char-bitmask prefilter masks
      only non-space query chars (`fuzzy.queryMask`), extend-narrows argued
      sound with terms. (3) Content-search discoverability: one-time scope
      status on `zedit <dir>` (picker now renders status on its bottom
      row — reserved, not painted over the list, so no result hides under
      it), dim zero-match hint row in the files picker only. Unit tests in
      fuzzy.zig + pty scenarios (sidebar/picker), each proven fail-without
      by planting the old behaviour back and recording the failures: the
      two-state `sidebarToggle` (4 sidebar checks + 3 titlebar), a rebuild
      in the refocus branch (1), `scoreTerms` bypassed to `score` (2 unit +
      6 pty), a per-term score bonus (the byte-identity unit test), the
      scope status removed (1) and the hint row removed (1). Also pinned:
      multi-term in a *non*-files picker (buffers, so the claim covers the
      shared `refilter` and not just the narrowing path) and the grep
      picker's space staying literal — `alpha beta` finds the adjacent
      words, not the line holding both in the other order, with
      `beta.*alpha` for order. Docs swept including `doc/COMPARISON.md`.
      (UNRELEASED)
- [x] Defect pass over the three items above. Fixed: (a) the picker's new
      status row landed *on* the last result row — `pickerLayout` now
      reserves it, `pickerClick` rejects it, and the preview stops a row
      short, so the renderer and the hit-test cannot disagree (two clicks
      on that row used to open a result nobody could see); (b) the status
      text is clipped with the shared `clipCells`, which counts the cells
      `emitSanitized` actually paints, instead of a hand-rolled loop —
      remote destinations and file names reach that row; (c) `previewKind`
      collapsed the pane whenever *nothing was selected*, which on a cold
      `zedit <dir>` is the first frame, re-laying the picker out one frame
      later — it now keys on a typed query; (d) the startup greeting is
      suppressed for a session that starts in the picker, where it would
      cost a remote listing a result row. Documented: the workspace-symbol
      picker is server-matched, so multi-term does not apply and its query
      (spaces included) is forwarded verbatim — the CHANGELOG had claimed
      otherwise. Verified by hand: the `Space e` cycle leaves a
      side-by-side diff pair untouched (refocus assigns one bool), works
      with `sidebar = right`, and the status/hint rows survive 16- and
      3-column terminals; `Space e` inside a picker types into the query
      (a leading space is just a term separator), which is the sane
      reading. Bench unchanged against a clean HEAD build: startup
      5.7→5.6 ms, keypress 0.12→0.12 ms, picker-open 6.1/4.7→6.2/4.7 ms
      cold/warm. (UNRELEASED)
- [x] Buffer-word completion (`complete.zig`, config `buffer_completion`) —
      the owner's report was "no completion when creating a new file (python
      on mac)": completion was LSP-only, so with no pylsp installed the popup
      never appeared and nothing said why. The popup now falls back to the
      identifiers in the open buffers (vim's keyword completion) when no
      server answers or a server returns nothing: outward from the cursor
      line through the current buffer, then the others, deduplicated,
      fuzzy-ranked, never offering the word being typed. The harvest runs on
      the existing completion debounce (no new timer) and is bounded three
      ways — 1000 lines each way, 128 KB of text, 200 candidates, the byte
      budget shared across buffers — and the words are copied into a reused
      arena because buffer lines move under an open popup. Plus a
      missing-server hint in the statusline ("no language server for python
      (install pylsp); completing from open buffers"), once per document,
      silent for filetypes with no known server. Found and fixed on the way:
      excluding only the typed *prefix* let the word under the cursor
      complete itself (typing `x` in front of `aaa` offered `xaaa`, and the
      popup then swallowed the following Esc) — the whole identifier at the
      cursor is excluded now.
      Four more came out of the adversarial review: (1) a server response
      that replaced its list with an empty one left the popup indexing items
      that were gone, and the next frame read off the end and **killed the
      editor** — the popup is dropped as each response lands now; (2) a
      server that died after the handshake took completion with it (request
      into a dead pipe, no popup, no fallback) — a dead client counts as "no
      server"; (3) the scan read its window top-down, so the 200-candidate
      cap filled a thousand lines above the cursor and the word on the line
      you just wrote was never offered — it walks outward from the cursor
      now; (4) the cap bounds candidates, not work — dedup scans the kept
      list once per word *examined*, so a file whose vocabulary never reaches
      the cap scanned its whole window at **82 ms per typing pause**
      (measured, 4000x3 KB lines / 199 distinct words) — a 128 KB byte budget
      brings that to 2.3 ms.
      17 pty checks in `tools/scenarios/bufcomplete.zig` (each proven to fail
      without the change by planting the old behaviour) plus 10 harvester
      unit tests; `mock_lsp` gained `--nocomp` (empty result), `--thenempty`
      (items, then empty) and `--die` (exits after the handshake).
      Measured (ReleaseFast, `log.Span` "buffer completion"): 10 MB / 186k
      lines 1.4 ms on the first harvest at a new position, then ~22 us;
      78-144 us on `src/editor.zig`; 2.3 ms on the adversarial
      low-vocabulary file. One harvest per typing pause, never per keystroke.
      Idle CPU still 0.0 ms over 3 s (`cpu` scenario). (UNRELEASED)

- [x] Mouse: click to move the cursor, drag to select (owner request, three
      empirical probes as input). The terminal is now asked for
      motion-while-pressed (DEC 1002 + 1006, replacing 1000 — a strict
      superset, and the probe measured that plain-drag terminal selection was
      *already* gone under 1000, so nothing was lost), and `key.zig` decodes
      press / drag / release as three events by masking the button field in
      order (extra buttons, modifiers, wheel-vs-tilt, then the button) rather
      than comparing it for equality. Modified reports stay inert on purpose:
      nvim gives Alt+drag and Ctrl+click meanings of their own that zedit does
      not implement, so binding them to the plain gesture would be silently
      wrong. Shift+mouse never reaches an application at all.
      The screen→buffer inverse is the renderer's own loop, lifted out of
      `renderWindow` into `RowWalk`/`nextRow` and replayed by `winHit` — the
      `tabArea`/`pickerLayout`/`sbRows` draw-here-click-here invariant applied
      to the hardest case (four independent row-consuming mechanisms, two of
      them hunk-driven and order-dependent, so there is no closed form). A
      virtual row (diff-pair filler, woven old line, `~`) snaps to the nearest
      real line; the column inverse handles the gutter (column 1, nvim's
      rule), tabs, wide cells, wrap segments with their hanging indent and the
      padding past a word break, and inlay hints.
      Every vim-shaped rule was generated from real nvim through a pty (`-u
      NONE -i NONE -n --noplugin`, `:set mouse=a` typed, never `-c`) and lives
      in `vim_compat` as 19 cases: operator-pending click, backwards ranges,
      the exclusive→linewise rule, linewise yank, count discarded, visual
      ended, insert continued, curswant kept at the *clicked* column, clamping
      past EOL/EOF, the drag anchored at the press, release-extends, jitter
      stays normal, V→drag→charwise, and no jumplist entry. Two of the probes'
      recommendations were dropped against that ground truth: modifier
      masking (see above) and clamping the anchor of a drag begun in insert
      mode — nvim keeps it one past the last character (`getpos("v")` probed
      out of band), so zedit does too.
      Prerequisite fix in the same change: a read that filled `inbuf` exactly
      skipped the completion wait, so an escape sequence straddling the
      boundary decoded as its fragments (a bare Esc leaving insert mode, the
      tail running as commands). The unfinished tail is now carried into the
      next read; `inbuf` also went 256 B → 1 KB so a whole drag is one read
      and one frame. Config `mouse` (default true) turns reporting off
      entirely.
      Tests: 38 pty checks in the new `tools/scenarios/mouse.zig`, 19
      nvim-pinned cases in `vim_compat`, an inlay-hint click in `lsp`, two
      updated `sidebar` pins, `completePrefixLen` unit tests and a rewritten
      `key.zig` decoder suite — each behavioural piece proven to fail with the
      old behaviour planted back. 752 → 811 itest checks, all green.
      Measured (ReleaseFast, 8.7 MB / 200k lines): a full 80-column drag is
      864 bytes and 76 reports on the wire (vs 22 bytes under 1000); decoding
      and applying the whole chunk costs 234 us median (3.1 us/report) plus
      **one** 74 us render, because `processInput` coalesces a read into a
      single frame; 4.6 us/report end to end from `/proc`. Idle CPU still 0 —
      1002 reports nothing while the mouse is still. `zig build bench`
      unchanged within noise (startup 5.7→5.6 ms, keypress 0.12 ms both).
      Known gaps recorded: no double/triple-click word/line select, no
      Alt+drag blockwise, no edge auto-scroll while dragging, no drag-resize,
      and a drag begun in insert mode leaves plain visual (nvim's Insert
      Visual returns to insert). (UNRELEASED)

- [x] Adversarial review of the above, three defects found and fixed
      (UNRELEASED):
      1. `buildSpan`'s exclusive→column-0 step read `end.row` *after* the
         same struct literal had already written it — the literal's result
         location is `end` itself. So the step used the length of the line
         before the one it meant (a wrong-length delete between lines of
         different widths) and underflowed when the end sat on row 1,
         aborting the editor. Pre-existing and reachable with no mouse at all
         (`d}` onto a blank second line), which is how it stayed hidden:
         `nvim#m4` covered the shape but its fixture's lines were all ten
         characters wide, so the wrong length was the right one. Now pinned
         both ways in `vim_compat` (`nvim#m24`–`m27`).
      2. `.` after an operator+click repeated the *previous* change: the
         press returned before the dot-capture wrapper, so the click never
         reached the repeat register. It is captured now when it consumes an
         operator, replaying the recorded screen cell as vim's redo does
         (`nvim#m22`/`m23`).
      3. A press left the pending command on showcmd, and the next command
         appended to it (`d`+click then `3` read `d3`). A press clears it,
         like any other key that acts at once — nvim blanks that cell for
         `d`+click and `3`+click alike (pty-probed).
      Verification added: an exhaustive draw-here-click-here sweep (every
      plain ASCII cell the renderer drew, across soft-wrapped rows with
      hanging indent and a mid-word break, tab stops, a horizontally scrolled
      window and a vertical split — 389 cells, all landing under the pointer);
      a read-boundary sweep that puts the split on *each byte* of a CSI, SS3,
      drag report and paste fence (28 offsets; 30 of them fail with the carry
      removed); modified-gesture inertness; `mouse = false` asserted against
      the raw stream for every tracking mode, not just 1002; a resize
      mid-drag; a drag into the explorer with the release outside the text
      area; and `Session.resize` in the harness to drive real SIGWINCH.
      811 → 834 itest checks, all green.

- [x] Mouse gestures + a pointer-aware wheel (owner request, two empirical
      nvim probes as input). **Double click selects the word, triple click the
      line**, quadruple one blockwise cell, fifth starts over — vim's period-4
      cycle, derived from the previous press's timestamp and cell (`mousetime`
      config, 500 ms) so **no timer is armed**. The word is vim's *mouse* word
      (`motion.mouseWord`/`mouseClass`), not `iw`: `%` first on punctuation
      (from the click to the match, backwards or across lines), else the
      same-class run, with the C-operator group set and vim's `utf_class`
      ranges for multibyte. Dragging on extends by whole words / lines / a
      rectangle — which is also what keeps a release from collapsing the
      selection. **Insert Visual**: a gesture begun in insert reads
      `(insert) VISUAL` and returns to insert when it ends (Esc, `v`, an
      operator, a click). **The wheel scrolls the window under the pointer**
      without moving focus: the wheel keys carry coordinates now, the scroll
      runs on the `Win` (mirror saved out and loaded back) through new
      `winLineAfterRows`/`winLineRows`/`winLineLayout`/`winTextCols`, and
      inside a diff pair the notch is routed to the pane that drives the
      lockstep (a naive `ix.top` write is erased by `syncDiffPanes` — probed).
      A replayed press starts its own click chain, so a macro reproduces what
      it recorded instead of chaining with it.
      Two defects caught in adversarial review and fixed in the same change,
      both re-probed against nvim: *every* press decides the click count (it
      was derived only for presses that reached a window, so a click on the
      explorer or the command row passed straight through a chain and the next
      click selected a word), and a window's status row belongs to that window
      for the wheel (`winUnder`; nvim scrolls the window a status line belongs
      to, zedit scrolled the focused one).
      27 new nvim-pinned `vim_compat` cases (every extent, the cycle, the
      punctuation/`%`/multibyte rules, word-wise drags, Insert Visual, macro
      replay, the chain broken by a press on chrome), 28 pty checks in
      `mouse.zig` (timing window both ways, the config key both ways,
      statusline labels, gutter/`~`/wrapped-row geometry, the wheel over each
      window, over a status row and over unowned cells, the diff pair) and 4
      `motion.zig` unit tests. Each behavioural piece proven to fail with the
      old behaviour planted back (18 plants, 0 unexplained failures). Suites
      green: unit + 893 itest.
      Known gaps recorded: no Alt+drag blockwise, no edge auto-scroll, no
      drag-to-resize; the double click's `%` matches brackets only (nvim also
      matches C comment items); `utf_class` is approximated above Latin-1.
      (UNRELEASED)

- [x] The last command-line gaps, every rule probed from real nvim through a
      tmux pty first: `Delete` (under the cursor; at end-of-line the character
      *before* it; on an empty line it cancels like backspace), `Ctrl-w`
      (erases the word before the cursor plus the whitespace it skipped, by
      vim's character classes — punctuation runs alone, kana/kanji/ASCII never
      merge), `Ctrl-u` (erases to the start of the line, keeps the tail, never
      cancels), `c_CTRL-R{reg}` (registers `a`-`z`, `"`, `+`/`*` inserted at
      the cursor, vim's `"` drawn while the name is awaited, Esc abandons,
      unknown/empty inserts nothing, a multi-line register inserts one CR per
      interior break and drops the trailing one), Tab completing only the text
      *before* the cursor with the tail kept across the ring, the stem restore
      and the directory keys, and — the probe that overturned the plan — a
      line wider than the row **wrapping upward** over the window, which is
      what nvim does instead of scrolling the command line sideways.
      23 new nvim-pinned `vim_compat` cases, 33 pty checks in `cmdline.zig`
      (wrap geometry and shrink repaint, popup above the block, ghost on the
      cursor's row, sanitized register text, the pending-register prompt, the
      mid-line completion rows) and a `wordEraseStart` unit test carrying the
      nvim transcripts. Each behaviour proven to fail with the old code
      planted back. Suites green: unit + itest.
      Known gaps recorded: no `q:` cmdline window, no `c_CTRL-R c_CTRL-R`
      literal variants or `=` register, `Ctrl-w`'s classes approximate
      `utf_class` above the CJK blocks, and a wrapped line taller than the
      screen shows the rows around the cursor.
      Adversarial review (nvim re-probed independently) found two defects in
      the wrapping, both fixed here: the cell a straddling double-width char
      leaves over must carry vim's `>` (nvim paints
      ":日本語のファイル名>", zedit padded a space), and a row that could
      only ever take what *fits* never advanced on a terminal narrower than
      a wide char — a one-column pane spun at 100% CPU and stopped answering
      keys, `:q!` included (measured: 213 CPU ticks in 2 s, state R; now 0
      ticks, state S). Both proven to fail with the old code planted back;
      `cmdRowSplit` carries the rule with a unit test and three pty checks.
      (UNRELEASED)

- [x] Blockwise registers, rectangular paste, block `A`/`I` padding, and a
      dot-repeat/macro tranche — 76 new nvim-pinned cases in `vim_compat`,
      48 of them proven to fail against the pre-change binary.
      `register.zig` grew a `Kind` (charwise/linewise/blockwise) plus the
      block's display `width`, since a yank slices each row ragged and only
      the width can square it back up. `p`/`P` of a blockwise register now
      lay the rectangle in: the column is the cursor's for `P` and the next
      cell for `p` (both 0 on an empty line), a line too short for it is
      padded with spaces *in display columns*, the buffer grows new lines
      when the block outlasts it, a count lays the block side by side, and a
      register line is squared up to the width only when something follows
      it — which is why a paste at end-of-line leaves the pad bare and
      trailing. Blockwise `d`/`x` fill the register at all now (they filled
      nothing before). Block `A` pads a short line out to the append column
      and `$A` appends at each line's own end instead; `I` and `c` *skip* a
      line that never reaches the left edge (vim's asymmetry). Four
      geometry bugs fell out on the way and are fixed: typed `j`/`k` in
      visual mode clobbered the goal column (arrows were guarded, letters
      were not), so a block collapsed to column 0 across an empty line; the
      blockwise cursor could not sit one past a short line's end; `$` was
      not tracked at all; and `"{reg}` was ignored in visual mode for every
      selection kind. Dot-repeat/macros: `[count].` now *replaces* the
      recorded count instead of repeating the change that many times
      (`3x` then `2.` removes five, not nine); `.` no longer records itself
      (a second `.` used to repeat the repeat and then stall, which also
      broke a macro that recorded one); a cursor movement mid-insert splits
      the change as vim's `ResetRedobuff`+`"1i"` does, so `.` repeats only
      the text typed after it; a blockwise `A` leaves the cursor on the
      block's top-left corner, which is what makes `.` re-apply the same
      rectangle rather than one shifted right by its own width; `@@` repeats
      the last macro and takes a count; and a replay now stops at the first
      command that fails (a motion that cannot move, a find or a committed
      search with no match) instead of running the rest. The abort is scoped
      to the replay — the incremental search deliberately does not raise it,
      or a replayed `/pat` would abort while typing its own pattern and
      leave the prompt open. Suites green: unit + itest (1027 passed).
      Gaps recorded above, all with transcripts: `[count]` before an insert
      command, visual-mode `p`, and `G`/`gg` not keeping the column.
      (UNRELEASED)

- [x] Adversarial review of the above, re-probed against nvim from scratch
      (~90 fresh probes, every rule re-derived rather than trusted). The
      pinned rules all held; four defects did not, and are fixed with
      nvim-pinned cases (`nvim#bp26`–`bp37`, `nvim#bi16`–`bi17`,
      `nvim#dm8a`–`dm8b`, plus a `register.zig` unit test):
      a blockwise `y`/`d`/`c` recorded **nothing** for a line stopping before
      the block's left edge, where vim records the block's width in spaces
      (its `endspaces`) — invisible wherever the paste has a tail to square
      up against, but `G$p` of such a rectangle came out short; a `$` block's
      run is one wider still, its right edge sitting one past the longest
      line's end. `"A` flattened a blockwise register to charwise, where vim
      keeps the register's own kind unless the addition is linewise, appends
      it as a new row and keeps the original width. `[count].` wrote the
      substituted count in *front* of a `"{reg}` prefix, fusing the two digit
      runs — `3.` after `"a2dd` ran as `32dd` and deleted the whole file
      (it now goes after the prefix, matching nvim exactly). And a block's
      right edge was the *first* cell of the character under the endpoint
      rather than its last, so a selection ending on a double-width character
      or a tab took half of it: `<C-v>jl` `d` over "漢字ab" left a stray
      space where nvim deletes both characters, and block `A` on a tab line
      landed before the tab. That last one predates the block work and
      reaches every blockwise operator; fixing it also closed the block-`A`
      half of the tab divergence, which is now narrowed to pasting *into* a
      tab. Suites green: unit + itest (1045 passed). New gaps recorded above
      with transcripts: `[count].` after an operator-side count, and a bare
      `/` not repeating the last pattern. (UNRELEASED)

- [x] Tree-sitter depth: real language injections, query predicates and
      indent queries (UNRELEASED). Injections replace the two-layer markdown
      approximation outright — a grammar's `injections.scm` marks regions,
      each is parsed by the named grammar into a child layer through
      `ts_parser_set_included_ranges`, and markdown-inline is now just one of
      those. A fenced block picks its language from the info string; an HTML
      `<script>` body is JavaScript. Regions come from the *visible* range
      only and layers are reparsed incrementally (same parser, same compiled
      query), so per-keystroke work stays O(screen). Measured (ReleaseFast,
      1400-line markdown with five python fences, 40-line window, mean of 200
      single-character edits): reparse+query **50.1 ms -> 11.6 ms**, because
      the old two-layer path re-parsed the *whole document* with
      markdown-inline on every keystroke while the injected layer parses only
      the ~11 `(inline)` regions on screen (1.2 ms); the 10.1 ms that remains
      is the markdown *block* grammar's own incremental parse, untouched. On
      a 1400-line Zig file (no injections) the same measurement goes 139.9 ->
      160.9 us, the +21 us being predicate evaluation, itself O(screen).
      `zig build bench` unchanged within noise: startup 5.6 -> 5.6 ms,
      10 MB open 10.0 -> 9.6 ms, big-file first paint 1.3 -> 1.0 ms, keypress
      0.12 -> 0.12 ms, picker-open cold 7.3 -> 6.3 ms. Predicates (`#eq?`/`#any-of?`/`#match?`/`#not-*`
      and `#lua-match?` where it means the same as a regex) run through
      `regex.zig`, compiled once per query beside the cached query — which
      also removed a lot of quiet over-highlighting, since *every* Zig,
      Python and Rust identifier was matching patterns that only their
      predicate was ever meant to let through. Indent queries for
      Zig/C/Python/Rust/Go/JS/TS add one level per block the reference line
      opens; the `#c*`/`#p*` cases in the new `indent` suite are ground
      truth from real nvim driven through nvim-treesitter's indent module,
      the `#f*`/`#b*` fallback cases against plain nvim, and the
      Zig/Go/Rust/JS/TS ones are zedit's own documented expectations (no
      parsers on this machine to ask).
      Suites green: unit + itest. Gaps recorded above:
      `@indent.end`/`@indent.dedent`/`@indent.align`, nested injections, a
      CSS grammar, and the `#offset!`/`#gsub!` directives.
      Adversarial review afterwards found and fixed two real defects, both
      now pinned (`ts-indent#x1`-`#x4`, `#b1`-`#b4`):
      the indent gave up whenever the tree was a revision behind, which is
      *every* batch of keys arriving without a frame between them — so `.`,
      macros and fast typing silently fell back to the copy rule and the same
      keys produced different files; and `O`/`cc` above a blank line lost the
      block's indent entirely, doing worse than the plain 'autoindent' it
      replaced (nvim gives the block indent; verified against real nvim).
      The review also measured the feature independently against HEAD: first
      paint unchanged (1.85 ms on both an 88 KB fenced markdown and a 57 KB
      script-heavy HTML), preview keystroke 0.33 -> 0.32 ms, RSS over 40 `:e`
      cycles flat and *lower* (40.8 -> 24.9 MB), markdown keystroke
      70.4 -> 4.1 ms, and `ts_query_new` called zero extra times across ten
      highlighters of the same language (the cache is genuinely
      process-wide). The two costs the feature does add: an HTML settle of
      5.7 -> 10.8 ms (the JavaScript layer, which is the feature) and a
      markdown `Ctrl-d` of 0.6 -> 1.4 ms (parsing the fences newly scrolled
      into view).
      Also corrected: CLAUDE.md/CHANGELOG said "16 regions each" where the
      code caps at 64.
      An inventory pass after that re-derived every claim from the code and
      from real nvim, and closed what it found:
      * The one claim nothing pinned was the one the markdown speed-up rests
        on — that markdown-inline parses the `(inline)` nodes rather than the
        document. Handing it the whole file back (exactly the old behaviour)
        broke *no* test. Two unit tests now pin it: the layers' actual
        `included_ranges`, and that injections are collected from the visible
        range only.
      * `ts-indent#p8` was filed as nvim ground truth and was not: real nvim
        (both with nvim-treesitter and with plain 'autoindent') leaves
        `def f(|):` + Enter at column 0, where zedit indented. The cause was
        real — `upto` only narrowed the query's byte range, which excludes
        C's `{` (the opener's first byte) but never Python's `:` (its last),
        so "Enter counts only the text before the cursor" was true for brace
        languages alone. An `@indent.begin` node that starts and ends on the
        line now has to *end* inside the counted prefix.
      * `ts-indent#b4` genuinely disagrees with nvim-treesitter (`o` on a
        blank line inside a block: vim's column 0 vs the block's indent). Left
        as vim's answer and recorded as a gap rather than left implied.
      * The "layers are reused, not rebuilt" test compares parser pointers and
        does *not* fail when every layer is rebuilt per frame — the C
        allocator hands the freed block straight back. Left for the
        performance pass, which owns that claim.
      * markdown's `injections.scm` claimed nvim's inline rule verbatim while
        dropping its `(pipe_table_cell)` alternative, so a table cell's
        `**bold**` was never styled. Alternative restored, pinned.
      * Every node type named by the new `indents.scm`/`injections.scm` files
        was checked against the vendored `parser.c` symbol tables (all
        present; a missing one would fail `ts_query_new` and silently switch
        the feature off, which the loader test now catches).
      A performance + robustness pass after *that* measured everything again
      against a HEAD build and found one real defect, now fixed and pinned:
      **a region far bigger than the screen was handed to its parser whole,
      every keystroke.** Collecting regions from the visible range bounds
      which nodes are injected, not how far one reaches, so a 3.3 MB HTML
      file that is one `<script>` gave the javascript layer bytes
      20..3,337,802 with 0..1,852 on screen — 88.6 ms a key against 0.27 ms
      before injections existed, which is precisely the O(document) work the
      restriction exists to prevent. A region over 64 KB is now clipped to the
      visible range (1.5 ms a key); under the cap it is still parsed whole, so
      a block running off the bottom of the screen keeps its real start.
      Everything else measured clean against HEAD: `zig build bench`
      unchanged, `ts_query_new` called 9 times for a session that opens ten
      zig files and a markdown with five fence languages (2 for zig +
      markdown/markdown-inline/injections + one per fence language) and never
      again across scrolling, editing or 20 `:bn`; layers built 17 and stable;
      RSS flat over 50 `:e` cycles; markdown keystrokes 10x cheaper than HEAD
      at every size (50 KB 46.8 -> 3.8 ms, 2 MB 2045 -> 200 ms) with the
      residue being the markdown *block* grammar's own O(document) reparse,
      which HEAD has too; markdown/HTML decorate 2236 -> 454 ms. Robustness
      sweep (unterminated fence, unvendored/empty info string, injection at
      byte 0 and at EOF, CRLF, invalid UTF-8 inside a fence, 10 MB of fences,
      one giant `<script>`, a fence's info string edited live python -> zig ->
      nonsense -> python, a region deleted out from under its layer): no
      crash, no hang, clean exit, correct fallback in every case, and
      markdown -> html -> js terminates at depth 1 as documented.
      Also closed, having been left for this pass: the "layers are reused, not
      rebuilt" test compared parser pointers, which a per-frame rebuild
      passes (the C allocator returns the freed parser). `Layer.built` counts
      constructions and the test pins it, which does fail on a planted
      rebuild.
      Two costs measured and accepted, neither a defect: a full-page scroll in
      markdown is 0.38 -> 0.94 ms (parsing the fences newly on screen),
      constant in document size — 0.99/1.01/0.99/1.01 ms at
      50 KB/500 KB/2 MB/10 MB; and the indent catch-up reparse costs one
      `tsReparse` per indent key in an input *burst*, not the one the next
      frame owed (each `o` changes the buffer, so the next cannot read the
      tree the previous one left). A 50-repeat `o` macro in one burst: 3.3 ms
      at 100 B, 39 ms at 150 KB, 419 ms at 1.5 MB. The CHANGELOG and the
      comment in `tsOpenIndents` claimed the batch cost was one reparse; both
      corrected. The driver is `tsReparse`'s O(document) serialisation, which
      is already a recorded gap; typing normally (one key, one frame) pays
      none of it.

- [ ] Found while reviewing, left alone as unrelated to the mouse work: a
      window narrowed to zero columns aborts in `renderWindow`
      (`emitSpaces(w.gw - 1)`), reachable with more vertical splits than the
      terminal has columns (5 `:vsplit`s in a 3-column terminal) and with no
      mouse involved. The fix belongs in `layout()` — floor a window's width
      and height at 1 — rather than in the one subtraction that happens to
      notice.

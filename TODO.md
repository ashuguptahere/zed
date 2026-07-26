# TODO

The working tracker for zedit. Items move to **Done** (newest last, so the
list reads chronologically) when they land with tests + docs + changelog in
the same commit. `doc/COMPARISON.md` holds the verified feature-gap analysis
behind the roadmap items.

## In progress

- (nothing — pick the next item below)

## Next (in order)


The shortlist is done; these are the next-highest gaps from
`doc/COMPARISON.md`, in rough priority order.


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

- [ ] Undo files are never pruned; a long-lived state directory only grows.
      Vim has the same gap, but an age or size cap would be better.

- [ ] Windows console support (`term.zig` gate marks the spot).
- [ ] Regex project-wide grep picker (in-buffer search is regex already).
- [ ] Nested/mixed window layouts and per-window resizing.
- [ ] True rectangular block paste; block `A` padding on short lines.
- [ ] Tree-sitter injections (Markdown uses two layers; HTML JS/CSS plain),
      query predicates (`#match?`/`#eq?`), tree-sitter indent queries.
- [ ] Cmdline: wildmenu directory-navigation keys, mid-line cursor editing.
- [ ] Remote: atomic remote writes (temp file + rename instead of `cat >`),
      remote git signs/sidebar, partial transfers for huge remote files.
- [ ] More nvim ground-truth test tranches (dot-repeat/macro edge cases).

## Done (chronological)

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

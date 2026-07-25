# TODO

The working tracker for zedit. Items move to **Done** (newest last, so the
list reads chronologically) when they land with tests + docs + changelog in
the same commit. `doc/COMPARISON.md` holds the verified feature-gap analysis
behind the roadmap items.

## In progress

- (nothing — pick the next item below)

## Next (in order)

- [ ] Shortlist #9: auto-triggered + fuzzy completion (reuse fuzzy.zig).
- [ ] Shortlist #10: snippets / `textEdit` completions.

## Recurring (every feature / significant change)

- [ ] Regression tests in the same commit (unit + pty itest; vim behaviour
      pinned via headless nvim ground truth — never from memory).
- [ ] Docs sweep: README, CLAUDE.md, man page, tutor, COMPARISON, CHANGELOG.
- [ ] Security pass: no raw untrusted bytes to the terminal, argv-array
      spawns only, no secrets; audit sweep periodically.
- [ ] Benchmark + profile: `zig build bench -Doptimize=ReleaseFast` and
      `zedit --benchmark` before/after perf-relevant changes; `log.Span`
      numbers for hot paths. No perf claim without a measurement.

## Later / known gaps (tracked in CLAUDE.md + COMPARISON.md)

- [ ] Windows console support (`term.zig` gate marks the spot).
- [ ] nvim-style lazy line indexing (or a rope) if the large-file open gap
      (14.3 ms vs nvim 10.7) ever matters in practice.
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
- [x] Confirmed the toolchain is current: Zig 0.16.0 is the latest stable
      (master is 0.17.0-dev), so no upgrade was needed.

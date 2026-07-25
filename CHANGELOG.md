# Changelog

Notable changes to zedit. Dates are commit dates.

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

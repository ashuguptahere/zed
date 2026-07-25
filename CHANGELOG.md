# Changelog

Notable changes to zedit. Dates are commit dates.

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

- Inline diagnostics: each LSP diagnostic's message renders after the code on its line as dim, severity-coloured virtual text (config `inline_diagnostics`, on by default), so every problem on screen is visible at once.
- Remote editing over SSH: `zedit ssh://[user@]host[:port]/path`, `:e ssh://…` and `:ssh host[/dir]` edit files on another machine with nothing installed there — one `ssh` per operation (`cat` to read, `cat >` to write, `find` to list a directory into the fuzzy picker), remote paths shell-quoted, `BatchMode=yes` so a prompting host fails fast, and `ControlMaster` connection reuse.
- Startup screen listing recently opened files and directories (`j`/`k`, `Enter`, `1`-`9`), backed by `$XDG_STATE_HOME/zedit/recent` — capped, de-duplicated, with vanished paths pruned on load.
- `:update` / `--check-update`: compare this build with the newest published release tag (one `git ls-remote`), on demand only.
- Paragraph motions and text objects: `{` / `}` (jump motions) and linewise `ip` / `ap` with counts, available in visual mode too — 16 cases pinned to real nvim.

### Security

- Control bytes from untrusted sources (file content, LSP hover/inlay/completion text, file names, pasted command-line text) are rendered as `?` placeholders instead of being written raw to the terminal, closing the classic escape-sequence injection where a hostile file could retitle the screen or trigger terminal query replies that arrive as synthetic keystrokes.

### Fixed

- The normal-mode cursor no longer sits past the last character (vim's rule), fixing a whole class of off-by-one bugs after `$`: `$x` did nothing, and `$dh` / `$d0` / `$db` / `$dF` all deleted one character too many.
- `:qa` now refuses to quit while any buffer has unsaved changes (nvim's E37 behaviour, pinned in `vim_compat`); `:qa!` discards.
- `:wa` names failed saves ("1 written, 1 failed — ro.txt: permission denied") instead of skipping them silently; `:w` failures read as plain English instead of raw error enums.
- An explicit `--config` or `--log` path that cannot be opened is reported instead of silently ignored, and LSP spawn/handshake/exit, config loads, git-sign and tree-sitter fallbacks are all traceable in the `--log` file.
- `:e` now detects the new file's language instead of keeping the previous buffer's.
- Mangled roff escapes in the jumplist man-page entry.

### Performance

- Zero-copy buffer loading: lines borrow from one shared read buffer and copy on first edit.
- Huge-file handling: files up to 2 GB open, and above `large_file_mb` (64 MB default) highlighting, LSP, and git signs are skipped; literal search takes a one-pass whole-source SIMD fast path (a 476 MB / 10M-line file opens in ~375 ms and searches in ~196 ms).
- Tree-sitter reparsing is incremental (the prior tree is reused) and highlight queries run only over the visible range, keeping per-keystroke work O(screen), not O(document).

## 0.1.0 - 2026-06-15

### Added

- Initial modal terminal editor in pure Zig: normal/insert/visual/command modes, an event-driven core that blocks in `poll(2)` (zero idle CPU), single-syscall frames, UTF-8-correct movement and rendering, and a friendly CLI (`--help`, `--version`, `--log`).
- Comprehensive vim keybindings: the `[count]` operator-then-motion grammar (`d c y`, `> <`, doubled forms), motions (`w b e`, `f t`, `%`, `gg G H M L`…), text objects (`iw`, `i(`, `a"`…), registers and paste, undo/redo, dot-repeat, visual mode, marks, and macros.

# zedit vs Helix vs Neovim — feature comparison

A working document for the batteries-included roadmap. Compared against
**Helix 25.07.1** and **Neovim 0.12.4** (their docs + changelogs), verified
against zedit's actual feature set (CLAUDE.md), last re-verified 2026-07-30. Performance
comparisons live in README.md's Benchmarks section (`zig build bench`).

Legend: importance is judged for zedit's goal — an AstroNvim-keybinding,
batteries-included editor.

## The shortlist (both editors have it, zedit doesn't — highest leverage)

1. ~~**Regex search + `:%s` substitution**~~ — **DONE** (regex.zig Pike VM;
   `/ ? n N * #` are regex, `:[range]s/pat/rep/[gi]` with captures; the grep
   picker takes the same regexes too, per line, with a debounced rescan).
2. ~~**Jumplist** `Ctrl-o`/`Ctrl-i`~~ — **DONE** (cross-buffer, nvim-verified;
   records G/search/marks/%/buffer switches/gd).
3. ~~**System clipboard**~~ — **DONE** (`"+`/`"*` via OSC 52 + bracketed
   paste in; works over SSH with zero dependencies).
4. ~~**Autoindent**~~ — **DONE** (`o`/`O`/Enter/`cc` inherit indent, blank
   auto-indents stripped, nvim-verified) — and now tree-sitter indent queries
   on top for Zig/C/Python/Rust/Go/JS/TS (one level per block the line opens;
   C and Python cases pinned against nvim-treesitter's own indent module).
   `@indent.end`/`@indent.align` and an `=` re-indent operator are still open.
5. ~~**LSP: find references, formatting (+ format-on-save), cross-file /
   multi-line WorkspaceEdits**~~ — **DONE** (`Space l R` references picker,
   `Space l f`/`:format`, `format_on_save` config; rename/code-action/applyEdit
   WorkspaceEdits apply to every file — open buffers in place, unopened files
   loaded as background buffers, saved with `:wa`).
6. ~~**Command-line completion** for `:e`/`:theme`/commands + history~~ —
   **DONE** (Tab/Shift-Tab wildmenu with nvim `wildmode=full` ring semantics
   pinned by pty probes; separate `:` / `/` histories on Up/Down with prefix
   filtering, Ctrl-p/n unfiltered — nvim-verified in `vim_compat`; later
   rounds added the wildmenu's Left/Right match selection and Down/Up
   directory navigation for path popups, plus mid-line cursor editing —
   both pty-probed against real nvim).
7. ~~**Paragraph text objects/motions** `ip`/`ap`/`{`/`}`~~ — **DONE**
   (linewise `ip`/`ap` with counts, `{`/`}` as jump motions, visual-mode
   objects; 16 nvim-verified cases — which also uncovered and fixed the
   cursor-past-EOL bug behind `$x`/`$dh`/`$db`).
8. ~~**Inline diagnostic text** at end of line~~ — **DONE** (dim,
   severity-coloured virtual text after the code; config
   `inline_diagnostics`, on by default).
9. ~~**Auto-triggered + fuzzy completion**~~ — **DONE** (debounced popup while
   typing, `auto_completion` / `completion_delay_ms` config; the list is fuzzy
   filtered and ranked with `fuzzy.zig`).
10. ~~**Snippets / `textEdit` completions**~~ — **DONE** (`snippet.zig` parses
    the LSP grammar; Tab/Shift-Tab walk tabstops, typing replaces a
    placeholder; `textEdit` ranges and `additionalTextEdits` honoured).

**The shortlist is complete.** Remaining gaps are tracked in the sections
below and prioritised in `TODO.md`.

---

## Helix features zedit LACKS

**Editing model**
- Multiple selections as the core model — Helix's `s` (select regex inside selection), `S` (split on regex), keep/remove selections by regex, copy-selection-to-next-line `C`, rotate/align/trim/merge selections; zedit's multicursor is one-caret-per-line column editing only — **high** (this is also Helix's answer to bulk edits)
- ~~Regex search~~ — **DONE** (`regex.zig` Pike VM; `/ ? n N * #` and the grep picker are all regex)
- ~~`:%s` equivalent~~ — **DONE** as vim's `:[range]s/pat/rep/[gi]` with captures; Helix's *select-in-selection* route (`%` + `s` + `c`) still has no equivalent, since that needs the multiple-selection model above — **medium**
- Indentation handling — ~~autoindent on `o`/`O`/Enter via tree-sitter indent queries~~ **DONE** (`autoindent` + `indents.scm` for 7 languages, `@indent.begin` only); the `=` re-indent operator is still missing — **medium**
- ~~System clipboard integration~~ — **DONE** (`"+`/`"*` via OSC 52 out and bracketed paste in, so it works over SSH with nothing installed; no xclip/wl-copy provider layer, which OSC 52 makes unnecessary)
- Shell integration — pipe selections through commands (`|`, `!`, `$`), insert command output — **medium** (the embedded terminal covers "run a command", not "filter this selection")
- Tree-sitter selection expand/shrink and sibling/child navigation (`Alt-o`/`Alt-i` etc.) — **medium**
- Increment/decrement numbers (`Ctrl-a`/`Ctrl-x`) — **low**
- Autosave — focus-lost and after-delay auto-save — **low**
- Case commands beyond `~` (explicit upper/lower) and `:reflow` text wrapping — **low**

**LSP**
- ~~Find references~~ — **DONE** (`Space l R` picker; Helix's `gr` slot stays rename in zedit)
- ~~Formatting~~ — **DONE** (`Space l f` / `:format`, `format_on_save` config; external non-LSP formatters still absent) — remaining: **low**
- ~~Cross-file / multi-line workspace edits~~ — **DONE** (full WorkspaceEdit application across files, multi-line edits)
- ~~Goto implementation / type definition (`gi`, `gy`)~~ — **DONE**
- ~~Workspace symbols picker~~ — **DONE** (`Space l S`, server-side query)
- ~~Diagnostics pickers~~ — **DONE** (`Space l D` lists every diagnostic across the open buffers)
- ~~Snippets / `textEdit` completions with tabstop jumping~~ — **DONE** (`snippet.zig`)
- ~~Auto-triggered completion (idle timeout)~~ — **DONE** (debounced; `auto_completion` config)
- Multiple language servers per language — zedit launches exactly one per filetype — **low**
- LSP progress messages in statusline; document colors — **low** (inline/end-of-line diagnostic text is **DONE**)

**UI**
- ~~Jumplist~~ — **DONE** (`Ctrl-o`/`Ctrl-i`, cross-buffer, nvim-pinned); a jumplist *picker* is still absent — **low**
- Command palette (`Space ?` — searchable list of every command with its binding) — **medium**
- ~~Bufferline~~ — **DONE** (the powerline title bar: one clickable tab per buffer, active accented, unsaved dotted)
- Registers UI — `Ctrl-r` register insertion is **DONE on the command line** only; no register *picker* and no insert-mode `Ctrl-r` — **medium**
- Jump labels (`gw` two-char labeled jumps) — **medium**
- ~~Mouse support (click to move, drag select, scroll)~~ — **DONE**
  (mode 1002; click-to-move + focus-follows-click, drag-to-select anchored at
  the press, double/triple/quadruple-click word/line/block with vim's
  `mousetime` cycle and word-wise drag, Insert Visual, and a wheel that
  scrolls the window under the pointer — all nvim-pinned; no Alt+drag
  blockwise, no edge auto-scroll while dragging, no drag-to-resize)
- Statusline configuration (user-arranged left/center/right segments) — zedit's is fixed (only `nerd_font` toggle) — **low**
- Rulers, whitespace rendering, per-mode cursor shapes, configurable gutters — **low**

**Other**
- ~~Undo tree with time travel~~ — **DONE** (branching history, `g-`/`g+`,
  `:earlier`/`:later` with counts, time spans and file writes, `:undolist`
  picker, and optional on-disk persistence, which Helix does not have) —
  **done**
- ~~Soft-wrap (with wrap indicators, indent retention, `text-width`)~~ —
  **DONE** (`soft_wrap` on by default, `↳` continuation marker, word breaks,
  `wrap_indent`, `wrap_column`, and `gj`/`gk`/`g0`/`g$`)
- Smart-case search + configurable wrap-around — **medium**
- ~~Tree-sitter textobjects~~ — **DONE** for functions, types, parameters and comments (`af`/`if`, `ac`/`ic`, `aa`/`ia`, `aC`/`iC`, `]f`/`[f`); Helix's set is still larger — **low**
- EditorConfig support (25.07) — **low**
- Surround on auto-detected *closest* pair (Helix `m`-mode pair detection via tree-sitter; zedit surround requires naming the char) — **low**
- ~~DAP debugging~~ — **DONE** for the core loop (breakpoints, launch, stop, step over/into/out, jump-to-stop, via any stdio adapter); variables, scopes, watches, REPL evaluation, conditional breakpoints, attach and multiple threads remain — **low**
- Language breadth — Helix ships grammars/queries for 200+ languages and `--health` per-language capability reporting; zedit has 10 grammars + a fallback lexer — **medium**

## Notable Helix CHANGELOG items zedit could adopt

1. **EditorConfig support** (25.07) — respect `.editorconfig` for tab width/final newline; cheap and standard.
2. **Cycle multiple LSP hover responses `A-n`/`A-p`** (25.07) — zedit already has a hover popup to extend.
3. **Incomplete LSP completion (`isIncomplete`) handling** (25.07) — correctness fix for zedit's existing completion popup.
4. ~~**Inline display for LSP diagnostics**~~ (25.01) — **DONE** (`inline_diagnostics`).
5. **Path completion in insert mode** (25.01) — server-independent completion win.
6. ~~**Snippet tabstop rendering and jumping**~~ (25.01) — **DONE**.
7. **Continue line comments on `o`/`O`/Enter** (25.01) — small polish on zedit's existing comment support.
8. **Configurable/runtime-switchable clipboard providers** (25.01) — the clean way to add system clipboard.
9. **Keybindings defined as macros in config** (25.01) — user remapping with zedit's existing macro machinery.
10. **Auto-save after delay / on focus lost** (24.07).
11. **Write via temporary file (atomic saves)** (24.07) — robustness for `buffer.zig` save.
12. **Picker of files changed in VCS** (24.07) — natural extension of zedit's git.zig.
13. **Tree-sitter-powered matching brackets** (24.07) — upgrade zedit's `%` beyond character scanning.
14. **Block comment toggling** (24.03) — complements `gcc` line comments.
15. **Track long-lived diagnostic sources + LSP diagnostic tags** (24.03) — better diagnostics fidelity (deprecated/unused rendering).

## Helix features zedit ALREADY HAS (verified)

Per `/home/origo/Desktop/zed/CLAUDE.md`:
- Tree-sitter highlighting with incremental parsing (10 languages; Helix has far more, but the mechanism is there)
- LSP: diagnostics (gutter + statusline), hover, goto definition, completion popup, signature help *with overload cycling* (Helix only added cycling in 24.07), rename, code actions, inlay hints, document-symbols picker, `]d`/`[d` diagnostic navigation, incremental didChange sync
- Fuzzy pickers: files, project-wide content grep, buffers, themes — with a warm cached file list, and Helix's space-separated **multi-term** queries (every term must match, in any order; the grep picker stays one regex)
- Which-key leader popup with nested groups (≈ Helix space-mode hints)
- File-tree sidebar (`Space e`, a three-state open/refocus/close cycle) — Helix stable has only a directory *picker*, no tree
- Git gutter signs plus inline, side-by-side and woven line-by-line diff views (the diff views exceed Helix)
- Multiple buffers + windows/splits with `Ctrl-w` focus/management
- Surround (`ys`/`cs`/`ds`/visual `S` ≈ Helix `ms`/`mr`/`md`), comment toggling, auto-pairs
- Multiple cursors (restricted one-per-line vs Helix's full selection model)
- Macros, registers, vim marks (Helix has no marks), dot-repeat, visual block, incremental search with match highlighting
- Themes (5) + single config file, `--tutor`, `--log`, powerline statusline, relative line numbers, cursorline, indent guides
- Live file preview in every picker (tree-sitter highlighted, independently scrollable) — Helix previews only in some pickers
- Snippet completion with tabstops, fuzzy-ranked auto-completion, workspace-symbol search and a cross-buffer diagnostics list
- Buffer-word completion when no language server answers (vim's keyword completion, fuzzy-ranked across every open buffer) — Helix has no server-free completion at all
- Structural text objects from the syntax tree (`af`/`if`, `ac`/`ic`, `aa`/`ia`, `aC`/`iC`, `]f`/`[f`) — Helix's tree-sitter object set is larger, but the mechanism is there
- Fish-style inline suggestions on the command line (history/command-name ghost text, Right/End to accept) — neither Helix nor stock Neovim ships this
- A vim-complete command line otherwise: mid-line editing, `Delete`, `Ctrl-w`/`Ctrl-u` erase, `Ctrl-r{reg}` register insertion, wildmenu completion of the text before the cursor, per-kind history, and nvim's upward-wrapping line when it outgrows the row (Helix's prompt has no register insertion and no wildmenu)
- Mouse: click to move the cursor, drag to select, double/triple-click word/line selection with word-wise drag, wheel scrolling the window under the pointer; buffer tabs along the top; a recently-opened startup screen; `:update` against the release tags
- Remote editing over plain SSH (`ssh://host/path`) with nothing installed on the far side — neither Helix nor stock Neovim does this
- An embedded terminal (`Space t`): a real shell on its own pty in a split, emulated by `vt.zig` — Helix has no terminal at all
- A debugger (`Space d`): a DAP client with breakpoints, launch, stop and stepping — Helix's DAP support is experimental
- Per-directory sessions (`Space S`) restoring the open files, cursors, splits and tree state — Helix has no session persistence
- UI toggles (`Space u`) flipping wrap, numbers, tabs, diagnostics, autoindent, completion, format-on-save and mouse reporting for the session

---

# zedit feature-gap report

Ground truth: `/home/origo/Desktop/zed/CLAUDE.md` (note: the on-disk version is newer than commonly summarized — zedit already has a config file, 5 themes, a sidebar file explorer, git diff views, an AstroNvim-style nested leader tree, and a `--tutor`). Neovim data: local NVIM v0.12.4 runtime docs (`news.txt` = 0.12, `news-0.11.txt`, `news-0.10.txt`).

## Vim/Neovim core features zedit LACKS

- ~~**Regex search & `:%s` substitution with ranges**~~ — **DONE** (`/`, `*` and the project grep are regex, `:[range]s/pat/rep/[gi]` with captures and `\<...\>`); the syntax is modern "very magic" rather than vim's magic mode, and there is no incremental `:s` preview ('inccommand') — **low**
- **Global/ex commands (`:g`, `:v`, `:normal`, general `{range}cmd`)** — the command line only knows `:w :q :e :bn :split :{n}` etc.; no ex address machinery to hang `:g/pat/d` or `:'<,'>normal @q` on — **med** (depends on regex landing first)
- **Changelist (`g;`/`g,`) and `''`** — ~~the jumplist~~ is **DONE** (`Ctrl-o`/`Ctrl-i`, cross-buffer, recording `G`/search/marks/`%`/buffer switches/`gd`, nvim-pinned), but there is no *change* list and no `''` back-to-previous-position — **med**
- **smartindent and the `=` operator** — ~~autoindent~~ is **DONE** (vim's copy rule plus the grammar's `@indent.begin` for 7 languages), but there is no smartindent, no `@indent.end`/`@indent.dedent`/`@indent.align`, and no `=` re-indent operator — **med**
- **Folding (`zf zo zc za`, foldexpr)** — no fold support of any kind, despite tree-sitter and LSP (both of which Neovim uses as fold providers) already being in-tree — **med**
- **Missing text objects: `it`/`at` (tags), `is`/`as` (sentence)** — ~~`ip`/`ap` and the `{` `}` motions~~ are **DONE**; the `(` `)` sentence motions are not — **med** for `it/at` (the HTML grammar is already vendored), low for sentences
- **`gq`/`gw` formatting ('textwidth')** — no reflow operator; painful for prose/comments/markdown — **med**
- **Spell checking ('spell', `]s`, `z=`)** — absent — **low**
- **Last-position mark `'"`** — ~~sessions~~ are **DONE** (`Space S`, one per working directory: open files, cursors, splits, tree state; explicit both ways) and ~~`:oldfiles`~~ is the startup screen's recent list, but reopening a file does not restore where you were in it — **low**
- ~~**Persistent undo ('undofile') and undo tree (`g-`/`g+`, `:earlier`)**~~ — **DONE** (a real branching tree, `g-`/`g+`, `:earlier`/`:later` with counts/spans/file-writes, `:undolist` picker, and `persistent_undo` on disk)
- ~~**Cmdline completion & history**~~ — **DONE** (nvim `wildmode=full` Tab completion of command names, `:e`/`:w` paths and `:theme`, a wildmenu popup with nvim's file-navigation keys, per-kind history with prefix filtering, and fish-style inline suggestions on top); `q:` (the cmdline window) is still absent — **low**
- **Count with insert (`3ifoo<Esc>`, `5o`)** — grammar is documented as `[count]` + motion/operator only; insert-entry counts aren't claimed anywhere — **low**
- **Replace mode (`R`, `gR`)** — single-char `r` exists, sustained overtype doesn't — **med**
- **Window resizing/rotation (`Ctrl-w + - < > = _ |`, `Ctrl-w r x H J K L`)** — splits are a flat, even, single-orientation tiling; no per-window resize and no nested/mixed layouts (in "Known gaps") — **med**
- **Tab pages (`:tabnew`, `gt`/`gT`)** — no second layout container above windows; the bufferline (the AstroNvim substitute) **is** there now — **low** (buffers+splits+tabs cover most of it)
- **Autocommands / user hooks / key remapping** — ~~format-on-save~~ is **DONE** as a setting (`format_on_save`, on by default), but there is still no keybinding customization and no general filetype/event hook (`FileType`, `BufWritePre`); by design there is no scripting — **med** (keymap remapping is the commonly missed subset)
- ~~**Terminal buffer (`:terminal`)**~~ — **DONE** (`Space t` / `:terminal`: a real shell on its own pty in a split, `vt.zig` emulating it, nvim's Terminal-mode split with `Ctrl-\ Ctrl-n`); no scrollback and no alternate screen yet — **low**
- ~~**System clipboard (`"+`/`"*` registers)**~~ — **DONE** (OSC 52 out, bracketed paste in; works over SSH)
- **Quickfix/location list (`:copen`, `]q`, `:cnext`)** — grep/diagnostics only exist as transient pickers/signs; no persistent, walkable result list — **med**
- ~~**Soft line wrap ('wrap')**~~ — **DONE** (`soft_wrap` on by default, `↳` marker, word breaks, `wrap_indent`, `wrap_column`, `gj`/`gk`/`g0`/`g$`)
- **`Ctrl-a`/`Ctrl-x` number increment** — absent — **low**

## Notable Neovim 0.10–0.12 changelog items zedit could adopt

1. **Inline diagnostic virtual text + `virtual_lines` + `current_line` mode (0.11)** — zedit shows only gutter signs/statusline; it already renders inlay-hint virtual text, so the machinery for end-of-line diagnostic text exists. Highest-leverage UI adoption.
2. **Declarative LSP config + auto-enable (`vim.lsp.config()`/`enable()`, 0.11; `root_markers` priority + `workspace_required`, 0.12)** — replace the hardcoded 4-server table with config-file server definitions and root-marker-based workspace detection.
3. **OSC 52 clipboard (provider in 0.10, default fallback even without SSH in 0.11)** — gives zedit `"+` with zero dependencies and zero syscalls beyond the existing frame write; perfectly on-brand.
4. **Async tree-sitter parsing (0.11)** — Neovim moved parsing off the input path for large buffers; zedit parses synchronously per keystroke (incremental, but still blocking).
5. **Built-in snippet expansion + completion side effects (`vim.snippet` 0.10; snippet/`additionalTextEdits` handling built into LSP completion in 0.11)** — directly addresses zedit's "no snippets/`textEdit` completions" gap.
6. ~~**`'autocomplete'` — auto-triggered insert completion (0.12)**~~ — **DONE** (debounced as-you-type popup; and it now works with no server at all, filling from buffer words like nvim's `Ctrl-n`).
7. **Fuzzy completion filtering (`completeopt=fuzzy`, 0.11)** — zedit already ships `fuzzy.zig` for pickers; apply it to the completion popup.
8. **LSP/inlay-hint request de-duplication — new requests cancel in-flight ones (0.11 perf)** — zedit's own docs flag "re-requested per edit, not debounced"; this is Neovim's exact fix.
9. **Default LSP keymap cluster `grr grn gra gri gO` + `Ctrl-s` signature help (0.11), `grt grx` (0.12)** — zedit's `gr` = rename conflicts with Neovim's `gr` prefix; aligning now is cheap, later is breaking.
10. **unimpaired-style bracket maps `[b ]b [q ]q [<Space> ]<Space>` (0.11)** — zedit has `]d [d` and (done) `]b [b` for buffer cycling; the quickfix/blank-line maps remain.
11. **Tree-sitter incremental selection `v_an`/`v_in` + sibling expansion `]N [N` (0.12)** — helix-style expand-selection built on the tree zedit already maintains.
12. **Viewport-only `semanticTokens/range` (0.12)** — LSP semantic highlighting requested for the visible screen only; matches zedit's O(screen) highlight philosophy exactly.
13. **Extended grapheme clusters per UAX#29 (0.11)** — proper ZWJ emoji width handling; a direct upgrade for zedit's "Unicode-correct" contract in `unicode.zig`.
14. **Project-local config: `'exrc'` loaded from parent directories (0.12)** — a per-project `zedit` config file alongside the global one.
15. **`:Undotree` bundled undo-tree visualizer (0.12)** — worth noting as the direction for `undo.zig` once history becomes a tree rather than capped snapshots.

(Not worth adopting: `vim.pack` plugin manager (0.12) — contradicts zedit's no-plugin design; terminal reflow/OSC 8/synchronized-output items (0.11/0.12) are now *relevant* — `:terminal` exists as of 0.31.0 — but wait on scrollback and the alternate screen.)

## Neovim/AstroNvim features zedit ALREADY HAS (verified)

- **Built-in commenting `gcc`/`gc{motion}`** (Neovim 0.10 parity) and **auto-pairs**
- **`]d`/`[d` diagnostic navigation with count** (0.10 default maps) plus a line-diagnostic view (`Space l d`)
- **LSP core:** diagnostics (gutter + statusline), hover `K`, `gd`, rename, code actions (incl. `executeCommand` and server-initiated `applyEdit`), completion popup, signature help with overload cycling, document symbols picker, **inlay hints as virtual text** (0.10 parity), incremental `didChange` sync — with documented single-file/single-line limits
- **Tree-sitter highlighting, incremental + viewport-scoped queries**, 10 languages, real **language injections** (Markdown fences pick the language from the info string, markdown-inline and HTML `<script>` are injections like any other; visible-range scoped, layers reused across reparses) and **query predicates** (`#match?`/`#eq?`/`#any-of?`/`#not-*`/`#lua-match?`, each regex compiled once per query) — no CSS grammar, so `<style>` stays plain
- **Tree-sitter indent queries** for Zig/C/Python/Rust/Go/JS/TS behind `autoindent` (`@indent.begin` only; no `@indent.end`/`@indent.dedent`/`@indent.align`)
- **AstroNvim-style leader UX:** which-key popup with nested groups — `Space f` find, `l` language, `g` git, `b` buffers, `u` UI toggles, `S` session, `d` debug, plus `e` explorer, `t` terminal, `n` new buffer, `c` close, `w` write, `q` quit (one table drives the dispatch and the popup, so a group cannot be added to one and forgotten in the other)
- **toggleterm-equivalent** embedded terminal (`Space t` / `:terminal`) with nvim's Terminal-mode split (`Ctrl-\ Ctrl-n` out, `i` back in)
- **nvim-dap-equivalent** debugger (`Space d` / `:debug`): breakpoints in the gutter, launch through any stdio adapter, stop/step, and the cursor following the stop location
- **resession-equivalent** per-directory sessions (`Space S` / `:session`), explicit both ways — nothing is saved on exit or restored on launch
- **Telescope-equivalents:** fuzzy file finder, project content grep (regex, per line), buffer picker, theme picker — with a warm cached file list and space-separated multi-term queries
- **gitsigns-equivalent** gutter signs, plus inline unified diff, side-by-side index diff, and a VS Code-style in-buffer line-by-line diff (old lines woven in as virtual rows)
- **neo-tree-equivalent** sidebar file explorer (navigation/open by key or mouse, VS Code's tree arrows, `a`/`A` to create a file or folder with any missing directories made on the way, and reveal of the active file on buffer switch; no rename/delete, not watched)
- **Vim core:** motions/operators/registers/marks/macros/dot-repeat, text objects (word + bracket/quote), visual char/line/block (rectangular block paste, block `I`/`A`/`c` with vim's short-line padding/skipping, `$` blocks; no visual-mode `p`), surround, incremental highlighted literal search (incsearch+hlsearch defaults)
- **Multiple cursors** (one-per-line column editing — beyond stock Neovim)
- **Buffers + splits:** `:e :bn :bp :bd :bd! :ls` (vim's `:bd` rules: the last buffer becomes `[No Name]`, dirty refuses without `!`), `:split`/`:vsplit`, `Ctrl-w` focus/close/only (flat tiling, no resize)
- **Appearance:** true-colour themes (Tokyo Night + 4 more, live-switchable), powerline statusline, relative+absolute numbers, cursorline, indent guides
- **Config file** (`~/.config/zedit/config`) and an embedded **`--tutor`** (vimtutor equivalent)
- **Bufferline-equivalent** powerline title bar across the top (buffer tabs — click to switch, unsaved marker — plus the explorer header), always on by default, VS Code-style
- **Telescope-preview-equivalent** live file preview beside every picker that names a file, tree-sitter highlighted and scrollable with `Ctrl-d`/`Ctrl-u` or the wheel
- **Alpha/dashboard-equivalent** startup screen listing recently opened files and directories
- **Mouse** (mode 1002): click to move the cursor (focusing the split it lands in), drag to select, double-click word / triple-click line / quadruple-click cell with word-wise drag extension and Insert Visual, wheel scrolling (3-line step, the window under the pointer), tab clicks, explorer clicks and picker result-row clicks (select, then click-again opens); **`:update`** checks the release tags on demand
- **Remote editing over SSH** (`ssh://host/path`, `:ssh`) with no agent on the remote host — beyond Neovim's built-in netrw/scp handling
- Explicitly **not** yet AstroNvim-complete: no notify-style popups, no mason-style server install/management, and only the active window gets live LSP/overlay rendering.

---

## Non-goals (deliberate)

- A plugin manager / scripting runtime (nvim 0.12 `vim.pack`) — contradicts
  the batteries-included design; features land in the editor instead.
- Full vim emulation trivia (`:smile`) — vim-compat is driven by the
  nvim-verified `vim_compat` test suite, not completionism.

## Naming note

Neovim 0.11 claimed `gr*` as an LSP prefix (`grn` rename, `grr` references,
`gra` action). zedit's `gr` = rename follows older muscle memory; references
therefore live on `Space l R` (the AstroNvim slot), not `grr`. Revisit if the
`gr` conflict ever becomes breaking.

# zedit vs Helix vs Neovim vs VS Code / Zed / Focus — feature comparison

A working document for the batteries-included roadmap. Performance comparisons
live in README.md's Benchmarks section (`zig build bench`).

## How this document was verified

Last re-verified **2026-08-02**. The analysis was made against zedit 0.47.4;
**0.48.0 then acted on it**, so section 1.5 lists what shipped and the
inventories below describe the editor as it now stands. The point of the pass
was to stop comparing from memory. What each claim rests on:

| Compared against | Version | Ground truth used |
|---|---|---|
| Neovim | 0.12.4 (local) | `nvim --clean --headless` dumping `nvim_get_keymap` for n/x/i/o/c (91 default maps), plus `/usr/share/nvim/runtime/doc/index.txt` — 473 indexed normal-mode commands |
| AstroNvim | v6.0 (local) | live `nvim_get_keymap` dump of the running config (267 mappings), cross-checked against `_astrocore_mappings.lua` + `_astrolsp_mappings.lua` |
| Helix | 25.07.1 (local) | `book/src/keymap.md` at the matching upstream tag — the exact source of the installed binary |
| zedit | 0.47.4 → 0.48.0 | the dispatch switches in `src/editor.zig` read directly (`normalKey`, `normalCtrl`, `.g_prefix`, `.fold_prefix`, `.bracket_next/prev`, the which-key tables) |
| VS Code / Zed / Focus | current | **vendor documentation only.** Not installed here, nothing driven, nothing measured. Treat every claim in those sections as a lead to check, not a verified fact. |

The four editors in the top half are all installed on this machine and were
interrogated. The three in the bottom half were not — that asymmetry is
deliberate and is marked wherever it matters.

---

## The shortlist (both Helix and Neovim have it, zedit didn't)

1. ~~**Regex search + `:%s` substitution**~~ — **DONE** (regex.zig Pike VM;
   `/ ? n N * #` are regex, `:[range]s/pat/rep/[gi]` with captures; the grep
   picker takes the same regexes too, per line, with a debounced rescan).
2. ~~**Jumplist** `Ctrl-o`/`Ctrl-i`~~ — **DONE** (cross-buffer, nvim-verified).
3. ~~**System clipboard**~~ — **DONE** (`"+`/`"*` via OSC 52 + bracketed paste
   in; works over SSH with zero dependencies).
4. ~~**Autoindent**~~ — **DONE** (`o`/`O`/Enter/`cc` inherit indent, blank
   auto-indents stripped, nvim-verified) — plus tree-sitter indent queries for
   Zig/C/Python/Rust/Go/JS/TS.
5. ~~**LSP: find references, formatting (+ format-on-save), cross-file /
   multi-line WorkspaceEdits**~~ — **DONE**.
6. ~~**Command-line completion** for `:e`/`:theme`/commands + history~~ —
   **DONE** (nvim `wildmode=full` ring semantics pinned by pty probes).
7. ~~**Paragraph text objects/motions** `ip`/`ap`/`{`/`}`~~ — **DONE**.
8. ~~**Inline diagnostic text** at end of line~~ — **DONE**.
9. ~~**Auto-triggered + fuzzy completion**~~ — **DONE**.
10. ~~**Snippets / `textEdit` completions**~~ — **DONE**.

**The shortlist is complete.** What follows is what replaced it.

---

# Part 1 — The verified keymap gap analysis

This is TODO item 4, done key by key rather than from memory. Four claims in
the previous revision of this document were wrong, and are corrected below:
it said the `=` re-indent operator, the `(`/`)` sentence motions, window
resizing and `[count]`-before-insert were all missing. All four had landed.
That is exactly why this pass was scheduled.

## 1.1 What zedit actually binds

Read off the dispatch switches, not the docs:

- **Motions** `h j k l w W b B e E 0 ^ _ $ G % { } ( ) H M L f F t T ; ,`
  and arrows/Home/End/PageUp/PageDown.
- **Operators** `d c y > < =` and `gu gU g~` (doubled `dd cc yy >> << ==`,
  `guu gUU g~~`), `gc`.
- **Immediate edits** `x X D C Y s S r ~ J gJ p P u`.
- **Insert entries** `i I a A o O` (+ `c`/`s`).
- **Prefixes** `g` `z` `Z` `[` `]` `"` `m` `` ` `` `'` `q` `@` `Ctrl-w`.
- **`g` namespace (49):** `gg gc gd gr gi gy ga g- g+ gj gk g0 g$`, plus
  `gu gU g~ gJ gv gx` (0.48.0), `gR` (0.52.0), and `ge gE g_ g^ gm gM go g'
  g` g* g# gn gN g? gI gp gP g& g8 gf gF g; g, gD gq gw` with the
  `g<Down>/<Up>/<Home>/<End>` aliases and `g Ctrl-G` (0.53.0).
- **`z` namespace (40):** `zf zo zc za zR zM zd zE`, `zz zt zb` (0.48.0),
  and `z<CR> z. z- z+ z^ zA zC zD zF zO zX zx zi zj zk zm zn zN zr zv zh zl
  zH zL zs ze zp zP zy z<Left> z<Right>` (0.54.0). Plus `ZZ`/`ZQ`.
- **Brackets (20 pairs):** `]d [d`, `]b [b`, `]f [f`, `]q [q`, `]e [e`,
  `]w [w`, `]g [g` (0.48.0), and `] [ `(space)`, ]' [', ]` [`, ]) [(, ]} [{,
  ]] [[, ][ [], ]/ [/, ]* [*, ]# [#, ]p [p, ]P [P, ]m [m, ]z [z, ]c [c,
  ]D [D, ]Q [Q, ]B [B` (0.55.0).
- **Ctrl (normal):** `Ctrl-r v n p f b d u w o i` + `Ctrl-h/j/k/l`.
- **Leader (`Space`), 9 groups:** `f`(5) `l`(8) `g`(3) `d`(7) `b`(3) `u`(8)
  `S`(3) `n`(3) `x`(4, 0.48.0), plus `e c w q t h` (`h` 0.48.0).
- **Search/visual/cmdline** `/ ? n N * # v V Ctrl-v : .`

## 1.2 vs Neovim 0.12.4 — namespace coverage

Counted against `index.txt`'s 473 normal-mode entries:

| Namespace | nvim | zedit | Missing that a user would actually reach for |
|---|---:|---:|---|
| `g…` | ~50 | 49 | `gt`/`gT`/`g<Tab>` (tab pages), `gh`/`gH`/`gV` (Select mode), `gQ` (Ex mode), `g@` (`'operatorfunc'`, i.e. scripting), `g]` (tags), `g<` (message history), `gs` (sleeps the editor — left out on principle). Four keep zedit's AstroNvim meaning over vim's: `ga`, `gi`, `gr`, `gd` |
| `z…` | ~44 | 40 | the spell family (`z=` `zg` `zG` `zw` `zW` `zug` `zuG` `zuw` `zuW`) needs a dictionary and a suggestion engine; `z{height}<CR>` sets an absolute window height, where zedit's layout is weight-based on purpose |
| `[…` / `]…` | 22 pairs | 20 pairs | `[s`/`]s` (spell), `[d`/`]d`/`[i`/`]i`/`[D`/`]D`/`[I`/`]I` + the `Ctrl-D`/`Ctrl-I` forms (`'include'`/`'define'` search through included files), `[l`/`]l` (location list), `[a`/`]a` (arglist), `[t`/`]t` (tags). `[f`/`]f` and `[d`/`]d` keep zedit's meanings — functions and diagnostics |

**Stock nvim 0.12 defaults zedit does not have** (from the `--clean` dump, so
these are things a user gets with *no config at all*): `gO` (document
symbols), `<C-W>d` (diagnostics under cursor), `[ `/`] `, `[D`/`]D`, the
matchit set (`[%` `]%` `g%` `a%`), and the tree-sitter incremental-selection
set (`an`/`in` objects, `]n`/`[n`/`]N`/`[N` sibling motions).

**The `gr` collision is now concrete.** nvim 0.12 ships `grn grr gra gri grt
grx` and `gO` as defaults. zedit's `gr` = rename shadows the entire prefix,
and AstroNvim v6.0 *keeps* nvim's (it only defines them itself when running
on nvim < 0.11). So zedit diverges from both. Decide once: keep `gr` = rename
and accept it, or move to the cluster.

## 1.3 vs AstroNvim v6.0 — the leader tree, key by key

AstroNvim binds ~150 leader keys across 11 groups; zedit binds 40 across 8.
Where both bind a key, **zedit agrees with AstroNvim everywhere it claims
to**, which is the good news. The disagreements and holes:

**Groups zedit has, with the keys AstroNvim has and zedit doesn't:**

| Group | zedit | AstroNvim also has |
|---|---|---|
| `Space f` Find | `f w b t u` | `c` word under cursor, `<CR>` **resume last picker**, `o`/`O` old files, `r` registers, `k` keymaps, `C` commands, `l` lines in buffer, `g` git files, `T` TODOs, `h` help, `m` man, `'` marks, `p` projects, `n` notifications |
| `Space l` Language | `a r R s S d D f` | `A` source action, `l`/`L` codelens, `i` LSP info, `w` workspace diagnostics |
| `Space b` Buffers | `n p c` | `b` picker, `d` close from tabline, `C` close all, `l`/`r` close left/right, `bs*` five sort orders, `\` / `\|` open in split |
| `Space d` Debug | `b B c n i o q` | `C` conditional breakpoint, `E` evaluate, `h` hover, `p` pause, `r` restart, `R` REPL, `s` run to cursor, `u` toggle UI, `Q` terminate |
| `Space u` UI | `n w d t i c f m` | ~20 more (spell, conceal, signcolumn, foldcolumn, indent guides, statusline, background, paste, notifications, autopairs, inlay hints, autoformat, semantic tokens, zen mode, …) |
| `Space S` Session | `s l d` | `t` per-tab, `.`/`S`/`F`/`D` the dirsession family, `l` load *last* |
| `Space g` Git | `d s l` (three diff views) | `t` status, `b` branches, `c`/`C` commits, `o` browse, `T` stash |

**Groups AstroNvim has that zedit has no key for at all:**

- **`Space x` — Quickfix/Lists.** Was the clearest instance of TODO item 3:
  a complete quickfix list reachable only by typing `:copen`. **Done in
  0.48.0** as `x q`/`x n`/`x p`/`x c`; zedit has no location list, so
  AstroNvim's `xl` has no counterpart.
- **`Space h` — Home screen.** zedit *had* a startup screen and no way back
  to it once dismissed. **Done in 0.48.0.**
- `Space p` — Packages. Correctly absent: no plugin manager is a stated
  non-goal.

**Non-leader AstroNvim keys zedit lacks:** `>b`/`<b` move buffer left/right in
the tabline, `]e`/`[e` next/prev **error**, `]w`/`[w` next/prev **warning**
(zedit's `]d`/`[d` are any-severity only), `gco`/`gcO` add comment
below/above, `gl` hover diagnostics, `Space /` comment alias, `|`/`\` split
shortcuts, `<C-S>` force write, `<C-Q>` force quit, `<C-Up/Down/Left/Right>`
resize splits (zedit uses `Ctrl-w +-<>`), visual `Tab`/`S-Tab` indent staying
in visual mode.

**One agreement worth recording.** AstroNvim maps `j`/`k` to
`v:count == 0 ? 'gj' : 'j'` — screen-line movement unless a count is given.
CLAUDE.md describes zedit's wrapped-line `j`/`k` as "a deliberate divergence
from vim"; it is in fact **AstroNvim's default**, which is a much stronger
justification than the doc currently gives it. The gate differs slightly
(zedit keys on whether the current line actually wraps, AstroNvim on whether a
count was typed) — worth pinning that difference in `vim_compat` rather than
leaving it implicit.

## 1.4 vs Helix 25.07.1 — key by key

Helix's model differs enough that most of its keymap can't be diffed one to
one; these are the entries that name a capability zedit could have:

| Helix key | Command | zedit |
|---|---|---|
| `Space ?` | `command_palette` | **done in 0.61.0** as `Space f C` (AstroNvim's key), or `>` in the file picker |
| `Space '` | `last_picker` | **absent** (AstroNvim's `Space f<CR>` is the same idea — two editors agree) |
| `Space j` | `jumplist_picker` | absent (the jumplist itself is done) |
| `Space g` | `changed_file_picker` | absent — a picker of VCS-modified files |
| `Ctrl-a` / `Ctrl-x` | increment / decrement | **done in 0.56.0** |
| `Ctrl-z` | suspend to the shell | **done in 0.57.0** |
| `Alt-o` / `Alt-i` | expand / shrink selection | absent (nvim 0.12 has this too, as `an`/`in`) |
| `Alt-n` / `Alt-p` | next / prev sibling node | absent |
| `\|` `!` `$` `Alt-\|` | shell pipe / insert output / keep-pipe | **absent** — no way to filter text through a command |
| `&` / `_` | align / trim selections | absent |
| `s` / `S` / `K` / `C` | select-regex-in-selection, split, keep, copy selection to next line | absent — needs the multi-selection model |
| `]g` / `[g` | goto next/prev **change (git hunk)** | **done in 0.48.0** |
| `]c` / `[c` | next/prev comment | absent (the `aC`/`iC` objects exist) |
| `]a` / `[a` | next/prev parameter | absent (the `aa`/`ia` objects exist) |
| `]p` / `[p` | next/prev paragraph | `{`/`}` cover it |
| `]Space` / `[Space` | add newline below/above | absent (nvim's `] `/`[ `) |
| `z` view mode | `zz`/`zt`/`zb`/`zm` equivalents | `zz`/`zt`/`zb` **done in 0.48.0**; no `zm`/sticky mode |
| `Ctrl-s` | save selection to jumplist | absent |
| `gw` | two-char labelled jump | absent |
| `m` match mode | surround/textobject minor mode | zedit uses vim's `ys`/`cs`/`ds` — deliberate |

## 1.5 What this pass found that no tracker had — **all shipped in 0.48.0**

Ranked as found. Every one is now implemented, nvim-pinned where vim has an
opinion, and listed here as the record of what the sweep was worth.

1. **`zz` / `zt` / `zb` were missing entirely** — the `fold_prefix` dispatch
   handled `f o c a R M d E` and fell through to nothing else. The biggest
   daily-use gap found. Now nvim's exact arithmetic, pinned in the new `view`
   suite against numbers read out of a real nvim at the same 22 text rows.
2. **No leader key reached the quickfix list.** Now `Space x` (open, next,
   previous, close) — AstroNvim's `<leader>x`.
3. **No git-hunk motion.** Now `]g`/`[g`, over the hunks `git.computeHunks`
   was already producing for the signs and all three diff views. A hunk of
   any length is one stop.
4. **`gv`** — reselect the previous visual area; swaps when used from visual
   mode. It reselects the *coordinates*, as vim does.
5. **`gu` / `gU` / `g~`** case operators, with the doubled and `gUgU` forms,
   sharing one `caseRange` with the visual `u`/`U`/`~` that already existed.
6. **Severity-filtered diagnostic motions** — `]e`/`[e`, `]w`/`[w`, as one
   argument on `lsp.nextDiagLine`.
7. **`Space h`** brings the startup screen back.
8. **`gx`** opens the URL or path under the cursor via `xdg-open`/`open`,
   through a double fork so the editor neither blocks nor collects zombies.
9. **`gJ`** joins without a separator.

Writing `gJ`'s tests beside `J`'s also exposed **two pre-existing bugs in
`J` itself**: vim inserts no space where the first line already ends in white
space, and none before a `)`. zedit did both wrong, and only the pairing made
it visible — which is the argument for pinning a new key against the old one
it resembles.

The one thing here that is *not* a fix: the `j`/`k` soft-wrap gate (1.3) is
now pinned in `wrap`, but as a characterization test. It records existing
behaviour and passes with or without any change, deliberately.

---

# Part 2 — Helix and Neovim, by feature

## Helix features zedit LACKS

**Editing model**
- Multiple selections as the core model (`s` select-regex-in-selection, `S`
  split, keep/remove by regex, rotate/align/trim/merge) — **medium**, down
  from high in 0.60.0: zedit now carries a *set* of selections rather than a
  set of carets, and `Ctrl-D` under the non-modal keymap adds one at the next
  match (Helix's `C` idea, VS Code's binding). What Helix still has and zedit
  does not is building that set from a **regex over the current selection**,
  and the operations that reorder or merge one once made.
- Shell integration — ~~filter a selection through a command~~ **DONE** in
  0.58.0 as `:[range]!cmd`, with visual `!` prefilling the range. Helix's
  `|` (pipe-to) and `$` (keep-if) variants are still absent — **low**
- Tree-sitter selection expand/shrink and sibling navigation (`Alt-o`/`Alt-i`,
  `Alt-n`/`Alt-p`) — **medium** (nvim 0.12 ships this as a default too)
- ~~Increment/decrement numbers (`Ctrl-a`/`Ctrl-x`)~~ — **DONE** (decimal, hex, negative, leading-zero width, counted)
- Autosave (focus-lost, after-delay) — **low**
- `:reflow` text wrapping — **low** (explicit case commands are done: `gu`/`gU`/`g~`)

**LSP** — everything on the old list is done (references, formatting,
cross-file WorkspaceEdits, `gi`/`gy`, workspace symbols, diagnostics pickers,
snippets, auto-completion). Remaining: multiple language servers per language
(**low**), LSP progress in the statusline, document colors (**low**).

**UI**
- ~~Command palette (`Space ?`)~~ — **DONE** in 0.61.0 as `Space f C`, and as
  `>` typed into the file picker (VS Code's Quick Open prefix, which is the
  route under the non-modal keymap). It shows the binding for the keymap in
  force, and is filtered on the title *and* the command's spelling.
- Register picker and insert-mode `Ctrl-r` — cmdline `Ctrl-r` is done — **medium**
- Jump labels (`gw`) — **medium**
- Jumplist picker — **low**
- Statusline configuration, rulers, whitespace rendering, per-mode cursor
  shapes, configurable gutters — **low**

**Other**
- Smart-case search + configurable wrap-around — **medium**
- EditorConfig support — **low**
- Surround on the auto-detected closest pair — **low**
- Language breadth — Helix ships 200+ grammars and `--health` per-language
  reporting (verified: `hx --health` prints a per-language capability table);
  zedit has 10 grammars + a fallback lexer — **medium**
- DAP: variables, scopes, watches, REPL, conditional breakpoints, attach,
  multiple threads — **low**

## Vim/Neovim core features zedit LACKS

- ~~**Ex range machinery — `:g`, `:v`, `:normal`, general `{range}cmd`**~~ —
  **DONE in 0.50.0** (`exrange.zig`: `%`, `.`, `$`, line numbers, `'a`,
  `'<`/`'>`, `/pat/`, `?pat?`, `+n`/`-n`, `,` and `;`; ranges on `d y > < j s
  normal g v`; `:g`/`:v` in vim's two passes; `:normal` through the macro
  replay path). `:s` moved onto the shared parser, so there is one address
  parser rather than two. Still absent from the family: `:cfile`/`:grep` and
  the location list, which now have somewhere to hang — **low**
- ~~**Replace mode (`R`, `gR`)**~~ — **DONE** (0.51.0 and 0.52.0): overwrite
  typing, the backspace-restores stack, counts, dot-repeat, one undo step,
  and virtual replace, where a keystroke covers display columns so a tab
  shrinks rather than dying. 32 nvim-pinned cases between them.
- **Changelist (`g;`/`g,`) and `''`** — **medium**
- **`gq`/`gw` reflow + `'textwidth'`** — painful for prose and comments — **medium**
- **Autocommands / user hooks / key remapping** — `format_on_save` is a
  setting; there is no keymap customization and no filetype/event hook. No
  scripting is by design; **keymap remapping is the commonly-missed subset** —
  **medium**
- **Nested/mixed window layouts** — tiling is flat, one orientation at a time
  (resizing itself is done: `Ctrl-w +`/`-`/`<`/`>`/`=`, `:winsave`,
  `split_sizes`) — **medium**
- **Location list** (the per-window quickfix variant), `:cfile`/`:grep` — **low**
- **Tab pages** (`:tabnew`, `gt`/`gT`) — buffers + splits + the tabline cover
  most of it — **low**
- **Spell checking** (`'spell'`, `]s`, `z=`) — **low**
- **Last-position mark `'"`** — reopening a file does not restore where you
  were in it (sessions restore cursors for *visible* files only) — **low**
- **`q:` cmdline window** — **low**
- Folding: no `foldmethod`/`foldexpr`, no tree-sitter/LSP fold providers, no
  fold column, no `zj`/`zk`/`zA`/`zC`/`zO` — manual folds are done — **low**
- ~~`it`/`at` tag objects~~ — **DONE** in 0.58.0, matched textually rather
  than through the grammar so they work in any file holding markup
- No `'inccommand'` live `:s` preview — **low**
- In-buffer search/`:s` are regex but "very magic"-style, not vim's magic mode
  — deliberate — **low**

## Notable Neovim 0.10–0.12 items zedit could adopt

1. **Declarative LSP config + auto-enable** (`vim.lsp.config()`/`enable()`,
   `root_markers`, `workspace_required`) — replace the hardcoded server table
   with config-file definitions and root-marker workspace detection.
2. **Async tree-sitter parsing (0.11)** — zedit parses synchronously per
   keystroke (incremental, but on the input path).
3. **Tree-sitter incremental selection `an`/`in` + sibling `]n`/`[n` (0.12)** —
   now a *default* mapping, so users arrive expecting it.
4. **LSP/inlay-hint request de-duplication (0.11)** — new requests cancel
   in-flight ones; zedit's own docs flag "re-requested per edit, not debounced".
5. **Viewport-only `semanticTokens/range` (0.12)** — matches zedit's O(screen)
   highlighting philosophy exactly.
6. **Project-local config (`'exrc'`, 0.12)** — a per-project `zedit` config
   beside the global one. (Focus does this too — see Part 3.)
7. **Extended grapheme clusters per UAX#29 (0.11)** — ZWJ emoji width; a
   direct upgrade for `unicode.zig`.
8. **Incomplete completion (`isIncomplete`) handling** — correctness fix for
   the existing popup.
9. **`gx`, `[ `/`] `, `[D`/`]D`, `<C-W>d`** — stock 0.12 defaults, listed in 1.5.
10. **Continue line comments on `o`/`O`/Enter** — small polish on `gcc`.
11. **Block comment toggling** — complements line comments.
12. **Tree-sitter-powered `%`** — upgrade beyond character scanning (would also
    fix the documented double-click `%` divergence on `/* */`).

Not worth adopting: `vim.pack` (0.12) — a plugin manager contradicts the
batteries-included design.

## What zedit ALREADY HAS (re-verified this pass)

Against Helix 25.07.1 and Neovim 0.12.4 + AstroNvim v6.0 as installed. Where
an AstroNvim equivalence is claimed it was checked against v6.0's real
mapping table, not from memory.

**Beyond Helix**
- Marks, macros, registers, dot-repeat, visual block — Helix has no marks
- File-tree sidebar (`Space e`, three-state cycle) — Helix stable has only a
  directory picker
- Git gutter signs **plus** inline, side-by-side and woven line-by-line diff
  views — the diff views exceed Helix
- Buffer-word completion with no language server at all — Helix has no
  server-free completion
- Fish-style inline cmdline suggestions; register insertion (`Ctrl-r`) and a
  wildmenu on the command line — Helix's prompt has neither
- An embedded terminal (`Space t`) — Helix has none
- Per-directory sessions, an undo tree with on-disk persistence, remote
  editing over plain SSH, a startup screen, `:update` — none in Helix
- Live file preview in every picker that names a file — Helix previews in some

**Parity with Helix**
- Tree-sitter highlighting with incremental parsing, real injections and
  query predicates (10 languages vs Helix's 200+ — the mechanism, not the
  breadth)
- LSP: diagnostics, hover, goto definition/implementation/type, references,
  completion, signature help with overload cycling, rename, code actions,
  inlay hints, document + workspace symbols, formatting, incremental sync
- Fuzzy pickers with Helix's space-separated multi-term queries
- Which-key leader popup with nested groups (≈ Helix's space mode)
- Surround, comment toggling, auto-pairs, soft wrap, folds, structural
  text objects (`af`/`if`, `ac`/`ic`, `aa`/`ia`, `aC`/`iC`, `]f`/`[f`)
- Mouse: click, drag-select, multi-click cycle, wheel — all nvim-pinned

**Parity with Neovim / AstroNvim** (equivalent plugin named where AstroNvim
supplies it)
- Vim core: motions, operators, registers, marks, macros, dot-repeat, text
  objects, visual char/line/block, incremental highlighted search, jumplist,
  quickfix, `:[range]s///`, folds, sentences, `=` re-indent
- **Telescope** ≈ the file/grep/buffer/theme pickers with a warm cached list
- **neo-tree** ≈ the sidebar (open/create by key or mouse, reveal on switch)
- **gitsigns** ≈ gutter signs (plus two diff views gitsigns has no answer for)
- **toggleterm** ≈ the embedded terminal with nvim's Terminal-mode split
- **nvim-dap** ≈ the DAP client (breakpoints, launch, stop, step)
- **resession** ≈ per-directory sessions, explicit both ways
- **bufferline** ≈ the powerline title bar with clickable tabs
- **alpha/dashboard** ≈ the startup screen
- **which-key** ≈ the leader popup, from one table that drives dispatch too
- nvim 0.10 parity: `gcc`/`gc{motion}`, `]d`/`[d` with counts, inlay hints as
  virtual text, `]b`/`[b`, `]q`/`[q`
- AstroNvim's `Ctrl-h/j/k/l` window navigation, `Space u` UI toggles,
  `Space b c` close-others, `gy` type definition, `Space l R` references
- **Not** AstroNvim-complete: no mason-style server management (non-goal), no
  plugin manager (non-goal), only the active window gets live LSP polling

---

# Part 3 — VS Code, Zed and Focus

**Read this part differently.** None of these three is installed here; nothing
below was driven, measured or pinned. Every entry is a lead from vendor
documentation, for the owner to verify before deciding. They are grouped by
how well they fit zedit's existing machinery, because the cheap ones are the
ones already half-built.

## 3.1 Zed

Zed's genuinely distinctive idea, and the strongest single candidate in this
whole document:

- ~~**Multibuffers.**~~ **DONE** in 0.62.0 as `:cedit` / `Space x e`. A
  project search, the diagnostics list or find-all-references goes to the
  quickfix list (`Ctrl-q`), and that list opens as *one editable buffer*
  stitched from excerpts across many files; one `:w` writes them all, and
  multiple cursors work across excerpts because they are ordinary buffer
  lines. It landed small for exactly the predicted reason: the quickfix list
  already kept file+line entries that outlive the picker, so this is the
  editable rendering of a list zedit already had, not a new subsystem.
  What Zed has and this does not: per-excerpt syntax highlighting (one
  document of mixed languages renders plain), excerpts that expand on
  demand, and opening one directly from a search without the list step.
- **Outline panel** — a persistent symbol tree, rather than a
  fire-and-forget picker (zedit has `Space l s`). Zed notes it is especially
  useful for navigating a multibuffer.
- **Tab switcher by recency** (`Ctrl-Tab`, MRU order) — zedit's `]b`/`[b` and
  the tabline are both in *open* order.
- **Project panel showing git status** — zedit's sidebar shows neither status
  nor any git information.
- **Searchable settings editor** — zedit has one documented config file and a
  `Space u` toggle group; a searchable view of every setting is the gap.
- Worth noting as validation rather than a gap: Zed's vim mode is "tested
  against Neovim", which is precisely zedit's `vim_compat` method — and Zed
  describes its own vim mode as "a work in progress" with "fundamental parts
  still missing", where zedit's is pinned byte-for-byte.

## 3.2 VS Code

- ~~**Multi-cursor by *match*, not by line.**~~ **DONE** in 0.60.0: `Ctrl+D`
  selects the word and each further press adds a selection at the next
  occurrence, so typing, backspace and `Esc` act on all of them. This was the
  highest-value item in this section — the most-used multi-cursor gesture in
  the world, which zedit could not express at all. Still absent: `Ctrl+Shift+L`
  (select all occurrences at once — a terminal does not pass the shift bit for
  a Ctrl+letter, so that key is indistinguishable from `Ctrl+L`),
  `Ctrl+K Ctrl+D` (skip this match), a selection that
  spans more than one line, and Alt+click to place a caret.
- ~~**Command palette** (`Ctrl+Shift+P`)~~ — **DONE** in 0.61.0. Not on that
  key, which a terminal cannot deliver: on `Ctrl+P` then `>`, which is VS
  Code's own second route to it, and on `Space f C` under the vim keymap.
- ~~**Peek definition / references**~~ (`Alt+F12`, `Shift+F12`) — **DONE**,
  the definition in 0.63.0 as `Space l p` and the references in 0.64.0 as
  `Space l P` (neither real key can reach a terminal application): a floating
  window over the file being read, `Enter` to take the jump, `Esc` to drop
  it, and for references a counted title with `n`/`p` walking them in place
  and `Ctrl-q` sending the set to the quickfix list. Writing the first found
  that cross-file `gd` had never worked — the server's uri was freed unread
  and the line applied to the buffer already open. One deliberate
  difference: VS Code draws a side list of the references beside the source,
  where zedit leaves that to `Space l R`, which already *is* that list with a
  fuzzy prompt and a preview.
- **Breadcrumbs + sticky scroll** — the enclosing symbol path shown above the
  text, and the enclosing scope pinned to the top row while scrolling. zedit
  has the tree for both already.
- **Timeline / local history** — per-file edit history independent of git.
  zedit's undo tree with `persistent_undo` is most of the machinery; this is
  the view of it.
- **Auto save** (`afterDelay`, `onFocusChange`) **and hot exit** — Helix wants
  the first too.
- **Fold by level** (`Ctrl+K Ctrl+2` folds every level-2 region) — zedit has
  `zR`/`zM` (all/none) and nothing between.
- **Regex replace case modifiers** (`\u$1`, `\U`, `\l`, `\L`) — a small,
  self-contained addition to `:s` and `regex.zig`.
- **Format on paste / on type** — zedit has format-on-save only.
- **Column selection mode** — a mode where plain drag is blockwise; zedit has
  `Ctrl-v` and deliberately no Alt+drag.

## 3.3 Focus (written in Jai)

Focus is the closest editor here to zedit's own philosophy — "minimize input
latency and maximize responsiveness", explicitly "for people who value
simplicity, are sensitive to input latency and do not require heavy language
support". Most of what it does, zedit already does. The exception is one
feature-shaped hole:

- **Build-command integration.** Focus ships: a configurable build command per
  project, a **compiler-error regex** to parse its output, an error panel
  shown on completion, optional auto-jump to the first error, a configurable
  working directory, and a command timeout.
  **Why it fits zedit specifically:** zedit has a quickfix list with no
  external producer — Part 2 lists "`:cfile`/`:grep` populating it from an
  external command" as a gap, and vim's answer is `:make` + `'errorformat'`.
  Focus is independent evidence that a batteries-included editor with no
  plugin system needs this built in. It is also the one item here that is
  *more* useful to zedit than to its originator, because zedit already has
  the list, the picker and `]q`/`[q` to walk it.
- **Per-project config layered over a global one** — the same idea as nvim's
  `'exrc'` (Part 2, item 6). Two independent votes for project-local config.
- **Project switching that re-applies configuration** — zedit's per-directory
  sessions restore files, cursors and layout, but not settings.

Deliberately absent in Focus, and worth noting as *shared* positions rather
than gaps: heavy language support, and multi-codepoint Unicode (where zedit
goes further — UTF-8 throughout, display-width-aware, malformed bytes
rendered rather than fatal).

**One competitive datum, unverified.** Focus documents editing becoming laggy
above ~100,000 lines and a hard 2 GB file limit. zedit's own measured numbers
(a 476 MB / 10M-line file opening in ~375 ms and searching in ~196 ms, 2 GB
cap) suggest zedit is ahead here — but that is a comparison of zedit's
measurements against Focus's prose, not a benchmark. If it matters, run one.

## 3.4 Ranked candidate shortlist from Part 3

For the owner to accept or reject, cheapest-first within each tier:

**Tier 1 — fits machinery that already exists**
1. Build command + error regex → the quickfix list (Focus; vim's `:make`)
2. ~~`Ctrl-D`-style add-cursor-at-next-match~~ — done in 0.60.0
3. ~~Command palette~~ — done in 0.61.0
4. Fold by level; regex replace case modifiers

**Tier 2 — new surface, high payoff**
5. ~~Multibuffer editing of the quickfix list~~ — done in 0.62.0
6. ~~Peek definition~~ — done in 0.63.0
7. Breadcrumbs / sticky scroll (VS Code, Zed)
8. Project-local config (Focus, nvim `'exrc'`)

**Tier 3 — worth having, no urgency**
9. Outline panel, git status in the sidebar, MRU tab switching (Zed)
10. Timeline view over the existing undo tree, auto-save (VS Code)

---

## Non-goals (deliberate)

- A plugin manager / scripting runtime (nvim's `vim.pack`, VS Code's
  extension marketplace, Zed's WASM extensions) — contradicts the
  batteries-included design; features land in the editor instead.
- Full vim emulation trivia (`:smile`) — vim-compat is driven by the
  nvim-verified `vim_compat` suite, not completionism.
- AI assistance / collaboration (Zed's agent panel, channels, screen sharing)
  — outside the scope of a terminal modal editor as scoped with the owner.

## Naming note

Neovim 0.11 claimed `gr*` as an LSP prefix and 0.12 ships `grn grr gra gri
grt grx` plus `gO` as defaults (verified in the `--clean` dump). AstroNvim
v6.0 defers to them. zedit's `gr` = rename follows older muscle memory and
shadows the whole prefix; references live on `Space l R`. This is now a
two-editor divergence rather than one — decide before it becomes breaking.

# zed — guidance for working in this repo

`zed` (zig-editor) is a terminal-based, modal code editor written in Zig, in the
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

## Project rules

- **Minimal dependencies.** Prefer the standard library; no Zig *package*
  dependencies. The one native dependency is the tree-sitter runtime + grammar,
  **vendored** as C under `vendor/` and compiled by `build.zig` (it links libc).
  This earns its place by giving real structural highlighting; adding more must
  clear the same bar. The LSP client is pure Zig (std only), and the per-line
  lexer (`syntax.zig`) remains the fallback for languages without a grammar.
- **Idiomatic, modern Zig.** Follow current Zig conventions for the toolchain in
  `build.zig.zon` (`minimum_zig_version`). No legacy/deprecated APIs.
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
- **No dead code.** Remove unused code, scaffolding and TODO stubs as soon as
  they stop earning their place. Don't keep a "legacy" path alongside a new one.
- **Human-friendly errors.** User-facing messages are plain English with a hint
  ("not a terminal — run zed in an interactive terminal"), never a raw error
  enum dumped at the user.
- **Traceable via logs.** Diagnostics go through `std.log` into a file enabled
  with `--log <path>` (off by default, costs one null check when off). Keep the
  editor fully diagnosable from the log alone.
- **Great CLI experience.** `--help`/`--version` are complete and correct, exit
  codes are meaningful (2 = usage error, 1 = runtime error), and the tool is
  pleasant from the first run.
- **Unicode-correct.** Text is UTF-8 throughout. Cursor movement and rendering
  are codepoint- and display-width-aware (CJK = 2 cells, combining = 0). Never
  split a codepoint.
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
| `term.zig`    | POSIX terminal control: raw mode, alternate screen, window size, event-driven input. |
| `key.zig`     | Decoding raw input bytes into `Key` events (text, arrows, navigation). |
| `unicode.zig` | UTF-8 decoding, codepoint boundaries, display width. |
| `buffer.zig`  | The document: line storage, load/save, UTF-8-aware edits. |
| `motion.zig`  | Pure cursor motions, word/WORD rules, find-char, `%`, text objects. |
| `register.zig`| Vim registers (named/unnamed, linewise flag) for yank/delete/paste. |
| `undo.zig`    | Undo/redo as capped buffer snapshots. |
| `search.zig`  | Literal substring search (`/ ? n N * #`). |
| `theme.zig`   | Colour palette (Tokyo Night) and 24-bit SGR helpers. |
| `syntax.zig`  | Dependency-free per-line lexer producing per-byte styles. |
| `fuzzy.zig`   | Subsequence scorer for the pickers. |
| `git.zig`     | Git change signs for the gutter (parses `git diff -U0`). |
| `lsp.zig`     | Minimal LSP client: JSON-RPC over a server's stdio (diagnostics, hover, goto). |
| `treesitter.zig` | Tree-sitter highlighting via the vendored C runtime + grammar (FFI + `highlights.scm` query). |
| `editor.zig`  | State, the vim command interpreter, multiple cursors, pickers, LSP, tree-sitter, viewport, themed rendering. |

Vendored C lives under `vendor/` (`tree-sitter/` runtime, `tree-sitter-zig/`
grammar + `highlights.scm`); `build.zig` compiles `lib.c` and the grammar's
`parser.c` with `-D_GNU_SOURCE` and links libc.

The pure, error-prone logic (motions, search) lives in its own unit-tested
modules; `editor.zig` is the stateful orchestrator (mode machine, operators,
registers, undo, visual, macros, marks, dot-repeat, rendering).

Data flow: `term` reads bytes → `key` decodes them → `editor` mutates `buffer`
and renders a frame back through `term`. `unicode` is shared by `buffer` and
`editor`; `log` is used everywhere.

## Build, test, run

```sh
zig build                       # debug build -> zig-out/bin/zed
zig build -Doptimize=ReleaseFast
zig build run -- [file]         # run the editor
zig build test                  # unit tests (pure logic; no tty needed)
```

`zig build` also installs the man page to `zig-out/share/man/man1/zed.1`
(source: `doc/zed.1`); view it with `man ./doc/zed.1`. The first build compiles
the vendored tree-sitter C (~6s extra cold; cached afterwards).

Interactive behaviour can't be unit-tested without a terminal, so integration
checks live in `tools/` and drive the editor through a pseudo-terminal:

```sh
zig build
python3 tools/pty_test.py "$PWD/zig-out/bin/zed" /tmp/zed_it.txt   # edit/save/quit
python3 tools/cpu_test.py "$PWD/zig-out/bin/zed" /tmp/zed.txt /tmp/zed.log  # idle CPU + profiling
```

(Python is dev-only tooling for spawning a pty; the editor itself has no runtime
dependencies.)

## Editor usage

Modal, vi-like, with a comprehensive vim keymap. A command is `[count]` then
either a motion (move) or `[register]` `operator` `[count]` motion/text-object.

- **Motions:** `h j k l`, `w W b B e E`, `0 ^ $`, `gg G {n}G`, `f F t T` + `; ,`,
  `%`, `H M L`, `Ctrl-d/u/f/b`, arrows/Home/End/PageUp/Down.
- **Operators:** `d` `c` `y`, `> <` (indent), doubled `dd cc yy >> <<`; `D C Y`,
  `x X s S`, `r` `~` `J`. `cw`/`cW` act like `ce`/`cE`.
- **Text objects:** `iw aw iW aW`, `i( i[ i{ i< i" i' i\`` and `a…` variants
  (plus `b`/`B` aliases), e.g. `ciw`, `di"`, `da(`.
- **Registers/paste:** `"a` selects a register; `p`/`P` paste (linewise/charwise).
- **Undo:** `u`, redo `Ctrl-r`. **Repeat:** `.` repeats the last change.
- **Visual:** `v` (char), `V` (line), `Ctrl-v` (block); move to extend, `o`
  swaps ends, then `d c y x > <`. In block mode `I`/`A` insert at the left/right
  edge of every selected line (via the multi-cursor machinery).
- **Search:** `/pat` `?pat` (incremental — jumps live as you type, `Esc`
  cancels and restores the cursor), `n N`, `*` `#`. Matches are highlighted.
  Literal (not regex), wraps.
- **Marks/macros:** `m{a-z}`, `` `{a-z} ``, `'{a-z}`; `q{a-z}…q` records, `@{a-z}`
  / `{n}@a` replays.
- **Insert:** `i I a A o O` (and `c`/`s` entries), `Esc` to normal. Auto-pairs:
  typing an opener inserts its closer; typing the closer steps over it.
- **Built-ins (no plugins):** `gcc` / `gc{motion}` comment toggling, auto-pairs.
- **Surround:** `ys{motion}{char}` (e.g. `ysiw)`), `cs{old}{new}` (e.g. `cs"'`),
  `ds{char}`, `yss{char}` for the whole line, and `S{char}` in visual mode.
- **Multiple cursors:** `Ctrl-n` / `Ctrl-p` add a caret on the line below/above
  (one per line); movement, `x`, and `i`/`a`/`I`/`A` + typing apply to every
  caret; `Esc` collapses back to one.
- **Pickers (which-key leader = `Space`):** pressing `Space` shows a which-key
  popup; `Space f` fuzzy file finder, `Space /` (or `Space s`) global literal
  content search, `Space w` write, `Space q` quit. In a picker: type to filter,
  `Ctrl-n`/`Ctrl-p` or arrows to move, `Enter` to open, `Esc` to cancel.
  Opening a file is blocked while the current buffer has unsaved changes.
  Note the three search scopes: `/` searches the current buffer, `Space /`
  searches file *contents* across the project, `Space f` matches file *names*.
- **Command line:** `:w` write, `:q` quit (blocked if unsaved), `:wq`/`:x`,
  `:q!`, `:w <name>`, `:{number}` goto line, `:$`; `ZZ`/`ZQ`.
- **LSP:** a language server is launched per filetype (`zls`, `clangd`, `pylsp`,
  `typescript-language-server`), or any command via `--lsp`. Diagnostics show as
  gutter signs + a statusline message/count; `K` hovers, `gd` goes to definition.
  Best-effort: no server installed simply means no LSP. Its stdout is polled
  alongside the terminal, so an idle editor still uses no CPU.

## Appearance

The renderer aims for an AstroNvim/Helix look: a Tokyo Night true-colour theme
(`theme.zig`), a powerline statusline (coloured mode block, separators,
file/filetype/position/percent segments — a nerd font is recommended for the
glyphs), syntax highlighting (tree-sitter for Zig via `treesitter.zig`, the
`syntax.zig` lexer otherwise), relative+absolute line numbers, a
cursorline, indent guides, and a git change gutter (add/change/delete signs
from `git diff`, recomputed on load and save). All colour is emitted as 24-bit
SGR; the frame is still built once and written in a single syscall, and
rendering still only happens on change.

Tabs are stored verbatim and rendered at `tab_width` (currently 4) in
`editor.zig`.

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
- Large-file performance: lines are a flat array; a rope/gap buffer is the next
  step if profiling shows it's needed.
- A resize landing in the tiny window between the resize check and entering
  `poll` is noticed on the next keypress (a self-pipe would close the race).
- Vim gaps: blockwise visual (`Ctrl-v`), regex and `:%s` substitution,
  autoindent, and the trickier dot-repeat/macro interactions are not (fully)
  implemented. `*`/search are literal, not regex.
- Highlighting is a per-line lexer (no cross-line block comments; a handful of
  languages). Tree-sitter is the upgrade path now that deps are allowed.
- Multi-cursor is one-caret-per-line (column editing); it does not do
  per-caret line splits/joins or arbitrary selection-based multi-edit.
- Pickers are single-buffer (opening replaces the buffer) and global search is
  literal, not regex. Statusline separators assume a nerd font.
- Block paste of a blockwise yank is charwise (not a true rectangular paste);
  block `A` on lines shorter than the block does not pad with spaces.
- LSP is full-document sync with diagnostics/hover/goto; no completion,
  signature help, rename or cross-file definition jumps yet.
- Tree-sitter highlighting is wired for Zig only (the one vendored grammar);
  other languages use the lexer. Parsing is whole-document on each change (not
  incremental yet), and query predicates (`#match?`/`#eq?`) are not evaluated.
  Adding a grammar = vendor its `parser.c` + `highlights.scm` and extend
  `treesitter.zig`. Multiple buffers/windows and config files — not yet built.

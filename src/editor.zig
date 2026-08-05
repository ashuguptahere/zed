//! The editor: state, the vim-style command interpreter, and rendering.
//!
//! The loop is event-driven. It renders only when something changed and then
//! blocks in the terminal layer waiting for input, so an idle editor uses no
//! CPU. Each frame is built into a reused buffer and pushed to the terminal in
//! a single write to avoid flicker and minimise syscalls.
//!
//! Command handling models vim: a key is fed through a small state machine that
//! accumulates a count, an optional register, an optional operator and finally
//! a motion / text object. Motions are resolved once and routed through
//! `doMotion`, which either moves the cursor or applies the pending operator —
//! so every motion works the same for plain movement and for `d`/`c`/`y`.

const std = @import("std");
const term = @import("term.zig");
const buffer = @import("buffer.zig");
const key = @import("key.zig");
const unicode = @import("unicode.zig");
const log = @import("log.zig");
const motion = @import("motion.zig");
const register = @import("register.zig");
const undo = @import("undo.zig");
const exrange = @import("exrange.zig");
const search = @import("search.zig");
const theme = @import("theme.zig");
const syntax = @import("syntax.zig");
const fuzzy = @import("fuzzy.zig");
const git = @import("git.zig");
const lsp = @import("lsp.zig");
const treesitter = @import("treesitter.zig");
const config = @import("config.zig");
const cli = @import("cli.zig");
const recent = @import("recent.zig");
const session = @import("session.zig");
const vt = @import("vt.zig");
const dap = @import("dap.zig");
const quickfix = @import("quickfix.zig");
const multi = @import("multi.zig");
const fold = @import("fold.zig");
const notify = @import("notify.zig");
const ui = @import("ui.zig");
const snippet = @import("snippet.zig");
const remote = @import("remote.zig");
const regex = @import("regex.zig");
const complete = @import("complete.zig");
const ansi = term.ansi;
const Allocator = std.mem.Allocator;
const Pos = buffer.Pos;
const Color = theme.Color;

// Powerline separators (private-use glyphs that need a Nerd Font; the config's
// `nerd_font = false` swaps them for a flat statusline) and the indent guide.
fn sepRight() []const u8 {
    return if (config.settings.nerd_font) "\u{E0B0}" else "";
}
fn sepLeft() []const u8 {
    return if (config.settings.nerd_font) "\u{E0B2}" else "";
}
/// Cells one powerline separator occupies — 0 in flat (`nerd_font = false`)
/// mode, where the glyphs are empty strings. Width budgets must use this
/// rather than a hardcoded 1 or the row is painted short of its edge.
fn sepCells() usize {
    return if (config.settings.nerd_font) 1 else 0;
}
const indent_glyph = "\u{2502}";

/// Cells a tab advances to (config `tab_width`). Tabs are stored verbatim and
/// expanded on render.
fn tabWidth() usize {
    return config.settings.tab_width;
}

pub const Mode = enum {
    normal,
    insert,
    replace, // `R`: typing overwrites rather than inserts
    visual,
    visual_line,
    visual_block,
    command,
    picker,
    terminal, // keys go to the embedded shell (nvim's Terminal mode)

    fn label(self: Mode) []const u8 {
        return switch (self) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .replace => "REPLACE",
            .visual => "VISUAL",
            .visual_line => "V-LINE",
            .visual_block => "V-BLOCK",
            .command => "COMMAND",
            .picker => "PICKER",
            .terminal => "TERMINAL",
        };
    }
};

const PickerKind = enum { files, grep, code_action, symbol, wsymbol, diagnostic, theme, buffer, reference, undo, command };
/// A picker row. Text lives in one shared byte arena (`picker_text`) and is
/// referenced by offset, so populating 20k results costs one growing buffer
/// instead of 40k small allocations — and closing the picker resets the arena
/// while *keeping* its capacity, so reopening allocates nothing at all. The
/// record is 20 bytes (against 40 for two slices), which keeps the fuzzy
/// filter's scan cache-friendly. This is the pooled, offset-addressed shape
/// Ghostty uses for terminal cells, applied to the thing zedit allocates most.
const PickItem = struct {
    display_at: u32,
    display_len: u32,
    path_at: u32,
    path_len: u32,
    line: u32,
};

/// A snippet tabstop resolved to a buffer position (`len` is the placeholder
/// still sitting there, which the first keystroke at the stop removes).
const SnipStop = struct {
    row: usize,
    col: usize,
    len: usize,
    choices: ?[]u8 = null, // owned: "a,b,c" from ${N|a,b,c|}
    choice: usize = 0, // which alternative is currently in the buffer
};

/// One command-line completion candidate: `text` is the full replacement
/// command line; `text[show..]` is what the wildmenu displays.
const WildItem = struct { text: []u8, show: usize };

/// One visible row of the file-tree sidebar (a flattened view of the tree:
/// expanded directories contribute their children right below themselves).
const SbEntry = struct { path: []u8, depth: u8, is_dir: bool, expanded: bool };
const sidebar_width: usize = 28;

const Operator = enum { none, delete, change, yank, indent_right, indent_left, reindent, comment, surround, fold, upper, lower, toggle_case, rot13, reflow, reflow_keep };

/// Which way `gu`/`gU`/`g~` and visual `u`/`U`/`~` turn a range.
const Case = enum { upper, lower, toggle };

/// One of the editor's secondary selections. `head` is where its cursor is;
/// `anchor` is where it was dragged from, or null when it is a bare caret —
/// which is what the column-editing multicursor (`Ctrl-n`/`Ctrl-p`) makes.
/// A selection with an anchor covers `[min, max]` inclusive, the same rule
/// the primary visual selection follows.
/// An ordered, inclusive span of the buffer — what a selection covers.
/// (`SelRange` is taken by the renderer's per-row byte range.)
pub const SelSpan = struct { from: Pos, to: Pos };

pub const Sel = struct {
    head: Pos,
    anchor: ?Pos = null,

    /// The inclusive range this selection covers, ordered.
    fn range(self: Sel) SelSpan {
        const a = self.anchor orelse self.head;
        return if (cmpPos(a, self.head) <= 0)
            .{ .from = a, .to = self.head }
        else
            .{ .from = self.head, .to = a };
    }
};

/// A selection remembered so `gv` can put it back. Positions rather than a
/// span, because vim reselects the same *coordinates* even after the text
/// under them changed — `vlld` then `gv` selects whatever now occupies the
/// three columns the delete emptied (nvim-probed).
const Selection = struct { start: Pos, end: Pos, mode: Mode };

/// What the next key supplies an argument for.
const Await = enum {
    none,
    find_f, // f: forward, inclusive, land on char
    find_t, // t: forward, inclusive, land before char
    find_cap_f, // F: backward
    find_cap_t, // T: backward
    replace, // r{char}
    visual_object_inner, // v i{object}
    visual_object_around, // v a{object}
    mark_set, // m{a-z}
    mark_jump_back, // `{a-z} exact
    mark_jump_line, // '{a-z} line
    mark_jump_back_nj, // g`{a-z} — the same, without a jumplist entry
    mark_jump_line_nj, // g'{a-z}
    register, // "{a-z}
    g_prefix, // g then ...
    visual_g, // g then ... in visual mode (gg, gv, gJ, gu/gU/g~)
    visual_z, // z then y in visual mode (zy)
    visual_replace, // r{char} over a selection
    z_prefix, // Z then Z/Q
    fold_prefix, // z then a fold command (f o c a R M d E)
    bracket_next, // ] then d (next diagnostic)
    bracket_prev, // [ then d (previous diagnostic)
    ctrl_w, // Ctrl-w then a window command
    object_inner, // operator i{obj}
    object_around, // operator a{obj}
    macro_record, // q{reg}
    macro_play, // @{reg}
    space_leader, // <space> menu (which-key)
    space_qf, // <space>x — the AstroNvim Quickfix/Lists group
    space_find, // <space>f — the AstroNvim Find group
    space_lang, // <space>l — the AstroNvim Language-tools group
    space_git, // <space>g — the Git group (diff views)
    space_buffer, // <space>b — the Buffers group (picker, next/prev, close)
    space_ui, // <space>u — the UI-toggles group
    space_session, // <space>S — save/load/delete this directory's session
    space_debug, // <space>d — the debugger
    space_new, // <space>n — new buffer / file / folder
    surround_add_char, // ys{motion}{char} / visual S{char}
    surround_delete, // ds{char}
    surround_change_from, // cs{old}...
    surround_change_to, // cs{old}{new}
};

const CmdKind = enum { ex, search_forward, search_backward, rename, new_file, new_dir };

const Find = struct { kind: Await, ch: u21 };

const MotionResult = struct {
    pos: Pos,
    kind: enum { exclusive, inclusive, linewise },
    col_mode: enum { exact, keep_goal, first_non_blank },
};

const Span = struct {
    lines: bool,
    // charwise: [start, end) exclusive, possibly multi-row
    start: Pos = .{ .row = 0, .col = 0 },
    end: Pos = .{ .row = 0, .col = 0 },
    // linewise: inclusive row range
    top: usize = 0,
    bot: usize = 0,
};

/// An open document. The *active* doc's state is mirrored on the Editor for
/// churn-free editing; `swapDocState` swaps it in/out of the Doc on focus
/// change, so an inactive Doc holds the live state and the active Doc's fields
/// are empty placeholders (its real state lives on the Editor). `buf` is the
/// exception — it always lives here, and `Editor.buf` points at the active one.
/// One excerpt of a multibuffer: a run of lines from one file, shown here
/// under a header row and written back where it came from.
///
/// The source is named by path rather than held as a `*Doc`, because a
/// document can be closed (`:bd`) while the multibuffer is still open and
/// a stale pointer is not something to find out about at write time.
/// `orig` is what those lines held when the excerpt was assembled: the
/// write compares against it, so a file changed behind the multibuffer's
/// back is reported rather than clobbered.
const Excerpt = struct {
    path: []u8, // owned
    header: []u8, // owned; the exact row that marks this excerpt
    start: usize, // 0-based first source line
    len: usize, // source lines it covered when assembled
    orig: []u8, // owned; their text then, "\n"-joined, no trailing newline
};

const Multi = struct {
    excerpts: std.ArrayList(Excerpt) = .empty,

    fn deinit(self: *Multi, gpa: Allocator) void {
        for (self.excerpts.items) |e| {
            gpa.free(e.path);
            gpa.free(e.header);
            gpa.free(e.orig);
        }
        self.excerpts.deinit(gpa);
    }
};

const Doc = struct {
    buf: buffer.Buffer,
    name: ?[]u8 = null, // display name for scratch buffers (buf.path == null)
    read_only: bool = false, // rejectReadOnly refuses every mutation (diff views)
    diff_of: ?*Doc = null, // side-by-side index snapshot: the worktree doc it mirrors
    diff_hunks: []git.Hunk = &.{}, // set on the index snapshot: aligns the pair's panes
    line_diff: ?git.LineDiff = null, // `Space g l`: the in-buffer weave of old lines
    /// The quickfix list view: Enter on a line jumps to that entry.
    qf_view: bool = false,
    /// The multibuffer: excerpts of other files, editable here, written back
    /// to them by `:w`. Set only on the one scratch document `:cedit` makes.
    mb: ?Multi = null,
    /// Folded line ranges. Per document, because a fold is about *this* text.
    folds: fold.Set,
    /// An embedded shell (`Space t t`). When set, the window renders this
    /// grid instead of the buffer, and keys go to the child while the editor
    /// is in terminal mode.
    shell: ?Shell = null,
    lang: syntax.Language,
    history: undo.History,
    marks: [26]?Pos = [_]?Pos{null} ** 26,
    /// Where each change happened, oldest first — vim's change list, walked
    /// by `g;` and `g,`. Per document, like the marks beside it.
    changes: std.ArrayList(Pos) = .empty,
    /// Where the `g;`/`g,` walk currently sits; == changes.len when no walk
    /// is in progress, so the first `g;` lands on the newest entry.
    change_idx: usize = 0,
    git_signs: git.Signs,
    lsp: ?lsp.Client = null,
    lsp_rev: u64 = 0,
    lsp_opened: bool = false,
    ts: ?treesitter.Highlighter = null,
    ts_styles: std.ArrayList(syntax.Style) = .empty,
    ts_line_starts: std.ArrayList(usize) = .empty,
    ts_doc_len: usize = 0,
    ts_vis_start: usize = 0,
    ts_rev: u64 = 0,
    ts_q_top: usize = std.math.maxInt(usize),
    ts_q_rows: usize = 0,
};

/// A viewport onto a document. The *active* window's viewport is mirrored on
/// the Editor (`cy/cx/goal_col/top/left`); `g*` is its screen region, recomputed
/// by the layout each frame.
/// A shell on its own pty, plus the screen zedit emulates for it. The two
/// always move together — feeding output, resizing, and dying — so they are
/// one struct rather than two fields on Doc.
const Shell = struct {
    child: term.Child,
    screen: vt.Screen,
    /// Set when the child has exited: the grid is kept so its last output is
    /// still readable, and any key closes the window.
    done: bool = false,

    fn deinit(self: *Shell) void {
        self.child.close();
        self.screen.deinit();
    }
};

/// How many windows `Ctrl-w`'s resize arithmetic will tile at once. Far past
/// any usable split on a real terminal; it exists so the cell arithmetic can
/// stay on the stack.
const max_tiled = 32;

const Win = struct {
    doc: *Doc,
    cy: usize = 0,
    cx: usize = 0,
    goal_col: usize = 0,
    top: usize = 0,
    left: usize = 0,
    gx: usize = 1, // 1-based screen origin
    gy: usize = 1,
    gw: usize = 1,
    gh: usize = 1,
    /// This window's share of the tiling, relative to its siblings'. Only the
    /// ratios matter, so a layout survives a terminal resize and reads the
    /// same on any screen — which is what makes it worth persisting.
    weight: f64 = 1,
};

/// One jumplist entry: where the cursor was before a jump-motion.
const Jump = struct { doc: *Doc, pos: Pos };

/// One positioned, colour-independent frame segment (a screen row of one
/// window / the sidebar / the status bar), for row-diffed rendering.
const Seg = struct { key: usize, start: usize, end: usize = 0 };

/// Everything a window needs to render one frame, resolved from either the
/// Editor mirror (active window) or the window's stored Doc (inactive).
const View = struct {
    buf: *buffer.Buffer,
    active: bool,
    has_ts: bool,
    ts_styles: []const syntax.Style,
    ts_line_starts: []const usize,
    ts_vis_start: usize,
    git: *const git.Signs,
    lang: syntax.Language,
    cy: usize,
    top: usize,
    left: usize,
    gutter: usize,
    cols: usize, // text width = gw - gutter
    wrap: bool, // soft wrap (off for diff-pair panes: it breaks row alignment)
    folds: *const fold.Set, // closed ranges collapse to a single header row
};

pub const Editor = struct {
    gpa: Allocator,
    io: std.Io,
    term: *term.Terminal,
    buf: *buffer.Buffer, // the active document's buffer (= &cur.doc.buf)

    // open documents + windows (multiple buffers / splits)
    docs: std.ArrayList(*Doc),
    wins: std.ArrayList(*Win),
    cur: *Win, // focused window
    d: *Doc, // focused window's document (== cur.doc)
    split_vertical: bool = true, // window tiling orientation (true = side-by-side columns)

    mode: Mode = .normal,
    cy: usize = 0,
    cx: usize = 0,
    goal_col: usize = 0,

    top: usize = 0,
    left: usize = 0,
    win: term.Size = .{ .rows = 24, .cols = 80 },

    // command assembly
    count: usize = 0,
    count2: usize = 0,
    operator: Operator = .none,
    await_arg: Await = .none,
    pending_register: ?u8 = null,
    last_find: ?Find = null,

    // subsystems
    registers: register.Store,
    history: undo.History,
    marks: [26]?Pos = [_]?Pos{null} ** 26,

    // visual
    vstart: Pos = .{ .row = 0, .col = 0 },
    /// Set for the duration of one `visualOperator` call: a linewise yank
    /// lands the cursor differently depending on which end it was on.
    /// `[count]` before an insert command (`3a`, `3i`, `3A`, `3I`, `3o`, `3O`):
    /// vim types the text that many times. The anchor is where the session
    /// started, so the text can be read back out of the buffer on Esc.
    ins_count: usize = 1,
    /// Whether the session is `gR` rather than `R`: typing covers display
    /// *columns*, so a tab shrinks instead of being destroyed.
    repl_virtual: bool = false,
    /// The buffer shown before the current one — vim's alternate file, which
    /// `Ctrl-^` flips back to.
    alt_doc: ?*Doc = null,
    /// The window focused before this one — `Ctrl-w p`, which is the *last
    /// accessed* window rather than the previous one in the tiling.
    prev_win: ?*Win = null,
    /// False while `zp`/`zP` paste: a blockwise paste normally pads a short
    /// line out to the block's column, and these are the variants that do not.
    block_pad: bool = true,
    /// The last `:s`, for `g&` to run again over the whole file.
    last_sub: ?Substitute = null,
    /// What the current Replace-mode session has overwritten, innermost last.
    /// Each entry is the bytes that were there — empty when the typing ran
    /// past the end of the line and appended — so backspace can walk the
    /// session back to the text it started from.
    repl_stack: std.ArrayList([]u8) = .empty,
    ins_anchor: Pos = .{ .row = 0, .col = 0 },
    ins_open_line: bool = false, // `o`/`O`: each repeat brings its own line
    yank_from_visual: bool = false,
    yank_cursor_was_top: bool = false,
    // `$` was pressed in blockwise visual: the block reaches each line's own
    // end rather than a fixed column, and keeps doing so as `j`/`k` grow it.
    vb_dollar: bool = false,
    /// Where a blockwise `A` session must leave the cursor when it ends: vim
    /// puts it back on the block's top-*left* corner, not the append column it
    /// was typing at (nvim-verified), which is what makes `.` re-apply the
    /// same rectangle instead of one shifted right by its own width.
    vb_origin: ?Pos = null,
    // A left button is down and its press landed in a window's text area, so
    // motion reports extend a selection from there. No `*Win` is kept: windows
    // are freed by `:close`/`:only`/a diff teardown, all reachable mid-drag,
    // and a stored pointer would dangle.
    dragging: bool = false,
    // The gesture the pointer is in the middle of. `click_count` is derived
    // when a press arrives, from the previous press's time and cell (vim's
    // `mousetime`) — no timer is armed for it. A double-click also records the
    // word it took, because the drag that may follow extends by whole words.
    click_ms: i64 = 0,
    click_row: u16 = 0,
    click_col: u16 = 0,
    click_count: u32 = 0,
    drag_word: ?motion.Span = null,
    // nvim's Insert Visual: a selection begun from insert mode with the mouse.
    // Only ever set while a visual mode is active (`enterVisual` clears it),
    // and whatever ends the selection lands back in insert.
    ins_visual: bool = false,

    /// How deep `execLine` is nested. `:g` runs its sub-command through the
    /// same dispatch, so `:g/x/g/y/d` has to stop somewhere.
    ex_depth: usize = 0,

    /// The selection `gv` puts back — whatever was last selected, recorded as
    /// visual mode is left. Null until there has been one, which is why `gv`
    /// on a fresh buffer does nothing rather than selecting a stray cell.
    last_vis: ?Selection = null,

    // multiple cursors (one per line; primary stays cy/cx). Empty = single cursor.
    extra: std.ArrayList(Sel) = .empty,

    // surround pending state
    surr_span: ?Span = null,
    surr_from: u8 = 0,

    // jumplist (Ctrl-o / Ctrl-i): positions recorded before jump-motions.
    jumps: std.ArrayList(Jump) = .empty,
    jump_idx: usize = 0, // == jumps.len when at the "live" end

    // search
    last_search: std.ArrayList(u8) = .empty,
    last_search_forward: bool = true,
    /// Whether the live (incremental) search currently has a match. Committing
    /// a search that has none is the failure a macro stops at — the typing on
    /// the way there is not.
    search_hit: bool = false,
    // Compiled form of the pattern being highlighted/jumped (cached per text;
    // null when the pattern is empty or (still) invalid, e.g. mid-typing).
    search_re: ?regex.Regex = null,
    search_re_pat: std.ArrayList(u8) = .empty,
    search_origin: Pos = .{ .row = 0, .col = 0 }, // cursor when a / or ? search began (for incremental preview)
    prev_search: std.ArrayList(u8) = .empty, // last_search saved on entry, restored if cancelled

    // Active snippet session: the tabstops left to visit, where the cursor is
    // in that list, and whether the current placeholder is still untouched (so
    // the first keystroke replaces it, as every snippet-aware editor does).
    snip_stops: std.ArrayList(SnipStop) = .empty,
    snip_idx: usize = 0,
    snip_pristine: bool = false,

    // The editor's one timer: a deadline for a request that should follow a
    // pause in typing (completion, or a workspace-symbol query). The poll in
    // the main loop waits until then instead of forever, fires it, and
    // disarms — so an idle editor still blocks indefinitely (zero CPU).
    comp_due_ms: ?i64 = null,
    /// Corner toasts. Their own deadline, because a toast can be showing while
    /// a completion request is pending and neither may cancel the other.
    toasts: notify.Queue = .{},
    due_kind: enum { completion, wsymbol, grep } = .completion,

    // Picker preview: the file shown beside the results, cached so moving the
    // selection re-reads only when the path actually changes.
    preview_path: ?[]u8 = null,
    preview_text: ?[]u8 = null,
    preview_top: usize = 0, // first line of the file to show (grep/reference hits centre)
    preview_scroll: isize = 0, // lines the reader scrolled, relative to that
    preview_ts: ?treesitter.Highlighter = null, // reused across files of one language
    preview_ts_lang: syntax.Language = .none, // which language `preview_ts` was built for
    preview_warm: bool = false, // the file is loaded but not parsed yet (see render)
    preview_styles: std.ArrayList(syntax.Style) = .empty, // styles for the queried range
    preview_vis: usize = 0, // byte offset the styles start at

    // Rows an overlay (popup) painted over this frame. The next frame must
    // repaint exactly these — the rest can still be diffed, so dismissing a
    // popup costs a few rows instead of the whole screen.
    overlay_top: usize = 0,
    overlay_bot: usize = 0,

    // showcmd: the partial command as typed (vim's 'showcmd'), shown at the
    // right of the statusline and cleared the moment the command completes.
    showcmd: [12]u8 = undefined,
    showcmd_len: usize = 0,
    showcmd_done: bool = false, // holds the finished command until the next one begins

    // command/search line
    cmd: std.ArrayList(u8) = .empty,
    cmd_cur: usize = 0, // cursor: byte index into `cmd`, kept on codepoint boundaries
    cmd_kind: CmdKind = .ex,
    // command-line history (`:` and `/ ?` kept separate, like vim) and
    // Tab-completion state (the "wildmenu").
    ex_hist: std.ArrayList([]u8) = .empty,
    search_hist: std.ArrayList([]u8) = .empty,
    hist_pos: ?usize = null, // index of the recalled entry; null = not navigating
    hist_stash: std.ArrayList(u8) = .empty, // the typed line: history filter + Down-restore
    wild: std.ArrayList(WildItem) = .empty,
    wild_idx: ?usize = null, // selected candidate; null = original text shown
    wild_stem: std.ArrayList(u8) = .empty, // cmd text *before the cursor* when completion started
    wild_tail: std.ArrayList(u8) = .empty, // cmd text after it: kept across the ring (nvim)
    wild_paths: bool = false, // the ring completes :e/:w paths (Up/Down navigate directories)
    cmd_reg: bool = false, // c_CTRL-R typed: the next key names the register
    // Fish-style inline suggestion: what would complete `cmd` (dim ghost text
    // after the cursor; Right/End accepts). Recomputed on every edit of `cmd`.
    ghost: std.ArrayList(u8) = .empty,

    // picker (fuzzy file finder / global search)
    picker_kind: PickerKind = .files,
    picker_items: std.ArrayList(PickItem) = .empty,
    picker_text: std.ArrayList(u8) = .empty, // backing store for every row's strings
    // file-tree sidebar (Space e; side set by the config's `sidebar`)
    sb_open: bool = false,
    sb_focus: bool = false, // keys go to the tree instead of the buffer
    sb_entries: std.ArrayList(SbEntry) = .empty,
    /// Scratch for the new-file prompt's pre-filled directory (reused, so the
    /// prompt costs no allocation per keypress).
    sb_prefill: std.ArrayList(u8) = .empty,
    sb_expanded: std.StringHashMap(void), // owned keys: expanded dir paths
    sb_sel: usize = 0,
    sb_scroll: usize = 0,

    // Recently-opened files/directories (the startup screen) and the remote
    // root when the session was opened on an ssh:// directory.
    recents: recent.List,
    dashboard: bool = false, // showing the startup screen (empty session, no file yet)
    dash_sel: usize = 0,
    remote_root: ?[]u8 = null, // ssh://host/dir the picker lists, when remote

    // Warm file-list cache (the Zed trick: opening the picker does no
    // filesystem work after the first walk; Ctrl-r in the picker refreshes).
    fcache: std.ArrayList([]u8) = .empty, // project file paths, walked once per session
    fcache_masks: std.ArrayList(u64) = .empty, // fuzzy.charMask per path, for prefiltering
    fcache_ready: bool = false,
    /// Set when a freshly opened document still needs the work that only
    /// *decorates* it — highlighting, git signs, the LSP handshake. The run
    /// loop paints the text first and does them on the next pass, the same
    /// rule the first frame follows.
    decorate_pending: bool = false,
    /// An in-progress project walk. The picker opens *before* the walk runs
    /// and the results stream in a chunk per loop iteration, so a huge tree
    /// never blocks the first frame or your typing (helix does this with
    /// background threads; cooperative chunks fit an editor that is otherwise
    /// single-threaded and idle-blocked in poll()).
    walk_dir: ?std.Io.Dir = null,
    walker: ?std.Io.Dir.SelectiveWalker = null,
    /// Which line `style_buf` currently holds styles for, and whose buffer —
    /// a wrapped line is drawn a row at a time and must not be re-styled once
    /// per row.
    style_row: usize = 0,
    style_buf_of: ?*const buffer.Buffer = null,
    prev_query: std.ArrayList(u8) = .empty, // last filtered query (incremental narrowing)
    /// How many `fcache` entries the current grep query has already read. The
    /// walk streams files in while the picker is open, so the grep resumes
    /// from here instead of re-reading the project on every slice.
    grep_scanned: usize = 0,
    /// The compiled grep query (grep patterns are the same modern regexes `/`
    /// uses; a plain string keeps the indexOf fast path via `.lit`). Always
    /// the last pattern that *compiled* — mid-typing an invalid one keeps the
    /// previous regex and its results, and `grep_incomplete` tags the prompt.
    grep_re: ?regex.Regex = null,
    grep_re_pat: std.ArrayList(u8) = .empty, // the pattern `grep_re` came from
    grep_incomplete: bool = false,
    picker_filtered: std.ArrayList(u32) = .empty,
    picker_query: std.ArrayList(u8) = .empty,
    picker_sel: usize = 0,
    picker_scroll: usize = 0,

    // macros
    recording: ?u8 = null,
    macro_buf: std.ArrayList(u8) = .empty,
    replay_depth: usize = 0,
    /// The register `@` last played, which is what `@@` repeats.
    last_macro: ?u8 = null,
    /// The command just run failed the way vim beeps at (a motion that could
    /// not move, a search with no match). A macro replay stops at one instead
    /// of running the rest of its keys; cleared before each key from the
    /// terminal, so it only ever spans one replay.
    failed: bool = false,

    // dot-repeat
    dot_keys: std.ArrayList(u8) = .empty,
    /// The recorded change's effective count, kept beside the keys because the
    /// keys no longer contain it. `[count].` replaces this outright — and a
    /// count typed *after* the operator (`d2w`) is part of it, which is what
    /// string surgery on the recorded bytes could never tell from the `2` in
    /// `f2` or `r2`.
    dot_count: usize = 1,
    dot_count_tmp: usize = 1,
    dot_temp: std.ArrayList(u8) = .empty,
    change_started: bool = false,
    in_dot: bool = false,

    // rendering / io
    frame: std.ArrayList(u8) = .empty,
    // Row-diff state: each frame is built as positioned, colour-independent
    // segments (one per screen row per window/sidebar/status). When nothing
    // overlays them, only segments whose bytes changed since the previous
    // frame are written — a big bandwidth win over SSH.
    seg_marks: std.ArrayList(Seg) = .empty,
    segs_end: usize = 0,
    prev_frame: std.ArrayList(u8) = .empty,
    prev_marks: std.ArrayList(Seg) = .empty,
    prev_valid: bool = false,
    out_frame: std.ArrayList(u8) = .empty,
    status: std.ArrayList(u8) = .empty,
    lang: syntax.Language,
    style_buf: std.ArrayList(syntax.Style) = .empty,
    git_signs: git.Signs,
    cur_fg: ?Color = null,
    cur_bg: ?Color = null,

    // tree-sitter highlighting (lexer fallback when null). The query runs only
    // over the visible byte range; ts_styles holds styles for that range.
    ts: ?treesitter.Highlighter = null,
    ts_styles: std.ArrayList(syntax.Style) = .empty, // styles for [ts_vis_start, ...)
    ts_line_starts: std.ArrayList(usize) = .empty, // whole-document per-line byte offset
    ts_doc_len: usize = 0,
    ts_vis_start: usize = 0, // doc byte offset of the queried region
    ts_rev: u64 = 0, // buffer revision last parsed
    ts_q_top: usize = std.math.maxInt(usize), // viewport top of the last query (sentinel = stale)
    ts_q_rows: usize = 0,

    // language server
    lsp_cmd: ?[]const u8, // override command, else a per-language default
    dap_cmd: ?[]const u8 = null, // --dap: the debug adapter, else a per-language default
    lsp: ?lsp.Client = null,
    lsp_rev: u64 = 0, // buffer revision last sent via didChange
    /// The handshake has completed and the post-handshake requests have gone
    /// out. Reset with the document, since each has its own server.
    lsp_opened: bool = false,
    // completion popup (insert mode)
    comp_open: bool = false,
    comp_filtered: std.ArrayList(usize) = .empty, // indices into the active candidate list
    comp_sel: usize = 0,
    // Buffer-word fallback: identifiers harvested from the open buffers when
    // no language server answers. `comp_words_src` says which list the popup
    // (and `comp_filtered`) is indexing — these words, or the server's items.
    comp_words: complete.Words = .{},
    comp_words_src: bool = false,
    sig_open: bool = false, // signature-help popup is showing (reads lsp.signature)

    // Autoindent: the row whose auto-inserted indent is still untouched (it
    // is stripped when left blank, like vim), and the indent text itself
    // (carried across consecutive Enters even after a strip).
    ai_row: ?usize = null,
    ai_indent: std.ArrayList(u8) = .empty,

    // Bracketed paste (terminal paste, incl. over SSH): content arrives fenced
    // in \x1b[200~ ... \x1b[201~ and is inserted literally.
    pasting: bool = false,
    paste_carry: [8]u8 = undefined, // partial end-marker bytes at a read boundary
    paste_carry_len: usize = 0,

    quit: bool = false,
    /// The debug session, when one is running, and the breakpoints — which
    /// outlive it, since they are placed before anything starts and must
    /// survive the program exiting.
    dbg: ?dap.Client = null,
    /// The 1-based line the program is stopped on, highlighted in the buffer
    /// it belongs to (cleared as soon as it runs on).
    dbg_line: ?usize = null,
    breakpoints: dap.Breakpoints,
    /// The quickfix list: results kept so they can be walked with `]q`/`[q`
    /// long after the picker that found them is gone.
    qf: quickfix.List,
    /// The theme that was active when the theme picker opened, to put back if
    /// the preview is cancelled.
    theme_before: []const u8 = "tokyonight",
    /// Terminal mode saw `Ctrl-\`, waiting to see whether `Ctrl-n` follows
    /// (nvim's escape pair). Any other key sends both to the child.
    term_escape: bool = false,
    // One read's worth of raw input. Sized so a full-window mouse drag (mode
    // 1002 reports one ~13-byte sequence per cell crossed, ~900 bytes across
    // an 80-column window) arrives in a single read and costs a single frame.
    inbuf: [1024]u8 = undefined,
    // An escape sequence the last read could not finish, held back so it is
    // never decoded as its fragments (see `readInput`/`completePrefixLen`).
    carry: [32]u8 = undefined,
    carry_len: usize = 0,

    /// Build a fresh, empty Doc holding `b`; its per-doc state is placeholder
    /// (the active doc's real state lives on the Editor and is swapped in here
    /// only when this doc loses focus).
    fn makeDoc(gpa: Allocator, b: buffer.Buffer) !*Doc {
        const doc = try gpa.create(Doc);
        doc.* = .{
            .buf = b,
            .lang = syntax.detect(b.path),
            .history = undo.History.init(gpa),
            .git_signs = git.Signs.init(gpa),
            .folds = .{ .gpa = gpa },
        };
        return doc;
    }

    fn docLabel(doc: *const Doc) []const u8 {
        return doc.buf.path orelse (doc.name orelse "[No Name]");
    }

    fn freeDocState(doc: *Doc, gpa: Allocator) void {
        if (doc.name) |n| gpa.free(n);
        if (doc.mb) |*m| m.deinit(gpa);
        gpa.free(doc.diff_hunks);
        if (doc.line_diff) |*ld| ld.deinit(gpa);
        doc.history.deinit();
        doc.git_signs.deinit();
        doc.folds.deinit();
        if (doc.ts) |*t| t.deinit();
        doc.ts_styles.deinit(gpa);
        doc.ts_line_starts.deinit(gpa);
        doc.changes.deinit(gpa);
        if (doc.lsp) |*c| c.deinit();
        if (doc.shell) |*s| s.deinit();
    }

    pub fn init(gpa: Allocator, io: std.Io, t: *term.Terminal, buf: buffer.Buffer, lsp_cmd: ?[]const u8, dap_cmd: ?[]const u8) !Editor {
        const doc = try makeDoc(gpa, buf);
        const win = try gpa.create(Win);
        win.* = .{ .doc = doc };
        var docs: std.ArrayList(*Doc) = .empty;
        try docs.append(gpa, doc);
        var wins: std.ArrayList(*Win) = .empty;
        try wins.append(gpa, win);
        return .{
            .gpa = gpa,
            .io = io,
            .term = t,
            .buf = &doc.buf,
            .docs = docs,
            .wins = wins,
            .cur = win,
            .d = doc,
            .registers = register.Store.init(gpa),
            .history = undo.History.init(gpa),
            .sb_expanded = std.StringHashMap(void).init(gpa),
            .recents = .{ .gpa = gpa },
            .breakpoints = .{ .gpa = gpa },
            .qf = .{ .gpa = gpa },
            .lang = syntax.detect(doc.buf.path),
            .git_signs = git.Signs.init(gpa),
            .lsp_cmd = lsp_cmd,
            .dap_cmd = dap_cmd,
        };
    }

    /// Free a document and everything hanging off it. Deliberately *not*
    /// `destroyDoc`, which also unregisters the doc and repairs any diff pair
    /// pointing at it: these callers hold a doc that was never added to
    /// `self.docs` (an append that failed), plus the teardown loop that is
    /// emptying the list anyway.
    fn freeDoc(self: *Editor, doc: *Doc) void {
        doc.buf.deinit();
        freeDocState(doc, self.gpa);
        self.gpa.destroy(doc);
    }

    pub fn deinit(self: *Editor) void {
        if (self.walker) |*w| w.deinit();
        if (self.walk_dir) |*d| d.close(self.io);
        self.clearPreview();
        self.dropPreviewHighlighter();
        self.preview_styles.deinit(self.gpa);
        self.endSnippet();
        self.snip_stops.deinit(self.gpa);
        recent.save(&self.recents, self.io);
        self.recents.deinit();
        if (self.remote_root) |r| self.gpa.free(r);
        self.registers.deinit();
        self.history.deinit();
        self.jumps.deinit(self.gpa);
        self.last_search.deinit(self.gpa);
        if (self.search_re) |*re| re.deinit(self.gpa);
        self.search_re_pat.deinit(self.gpa);
        if (self.grep_re) |*re| re.deinit(self.gpa);
        self.grep_re_pat.deinit(self.gpa);
        self.prev_search.deinit(self.gpa);
        for (self.ex_hist.items) |h| self.gpa.free(h);
        self.ex_hist.deinit(self.gpa);
        for (self.search_hist.items) |h| self.gpa.free(h);
        self.search_hist.deinit(self.gpa);
        self.hist_stash.deinit(self.gpa);
        self.wildClear();
        self.wild.deinit(self.gpa);
        self.wild_stem.deinit(self.gpa);
        self.wild_tail.deinit(self.gpa);
        self.ghost.deinit(self.gpa);
        self.cmd.deinit(self.gpa);
        self.macro_buf.deinit(self.gpa);
        self.dot_keys.deinit(self.gpa);
        self.dot_temp.deinit(self.gpa);
        self.clearReplaceStack();
        self.repl_stack.deinit(self.gpa);
        self.ai_indent.deinit(self.gpa);
        self.frame.deinit(self.gpa);
        self.seg_marks.deinit(self.gpa);
        self.prev_frame.deinit(self.gpa);
        self.prev_marks.deinit(self.gpa);
        self.out_frame.deinit(self.gpa);
        self.status.deinit(self.gpa);
        self.style_buf.deinit(self.gpa);
        self.git_signs.deinit();
        if (self.ts) |*t| t.deinit();
        self.ts_styles.deinit(self.gpa);
        self.ts_line_starts.deinit(self.gpa);
        if (self.lsp) |*c| c.deinit();
        self.comp_filtered.deinit(self.gpa);
        self.comp_words.deinit(self.gpa);
        self.extra.deinit(self.gpa);
        self.freePicker();
        self.picker_items.deinit(self.gpa);
        self.picker_text.deinit(self.gpa);
        self.sbFree();
        self.sb_entries.deinit(self.gpa);
        self.sb_prefill.deinit(self.gpa);
        if (self.dbg) |*d| d.deinit();
        self.breakpoints.deinit();
        self.qf.deinit();
        var xit = self.sb_expanded.keyIterator();
        while (xit.next()) |k| self.gpa.free(k.*);
        self.sb_expanded.deinit();
        for (self.fcache.items) |f| self.gpa.free(f);
        self.fcache.deinit(self.gpa);
        self.fcache_masks.deinit(self.gpa);
        self.prev_query.deinit(self.gpa);
        self.picker_filtered.deinit(self.gpa);
        self.picker_query.deinit(self.gpa);
        // The active doc's real state was freed above (the Editor mirror); each
        // Doc owns its buffer (+ inactive docs own their state placeholders here).
        for (self.docs.items) |doc| self.freeDoc(doc);
        for (self.wins.items) |w| self.gpa.destroy(w);
        self.docs.deinit(self.gpa);
        self.wins.deinit(self.gpa);
    }

    pub fn run(self: *Editor) !void {
        try self.term.enableRaw();
        self.term.installResizeHandler();
        try self.term.enterAltScreen(config.settings.mouse);
        // Ask what colour the window padding is painted in. The answer arrives
        // on stdin like any other input and costs nothing to wait for, because
        // nothing waits: a terminal that never replies simply never has its
        // background touched.
        if (config.settings.sync_background) self.term.write(ansi.query_background) catch {};
        self.win = self.term.size();
        // The greeting belongs to a buffer session: it must neither clobber a
        // status set before the loop starts (the `zedit <dir>` browser's
        // search-scope hint) nor — now that the picker renders the status on
        // its bottom row — cost a remote directory session a result row.
        if (self.status.items.len == 0 and self.mode != .picker)
            self.setStatus("zedit {s} — :q to quit, i to insert", .{@import("cli.zig").version});

        // Paint the text first, then do everything that decorates it. Syntax
        // highlighting (a grammar query compile plus a full parse), the git
        // gutter (a `git diff` subprocess) and the language-server handshake
        // all used to sit between launch and the first frame; none of them
        // change what the *text* says, so they now run after it is on screen
        // and the second frame brings them in. Measured: time to first paint
        // on an 8.2 MB file 7 ms -> 4 ms, and much more on a large source
        // file, where the grammar work alone costs ~14 ms.
        self.scroll();
        try self.render();

        // The rest of a streamed file lands right after that first paint, so
        // everything below (highlighting, git, LSP) sees the whole document.
        self.buf.loadRest(self.io) catch |err| {
            std.log.scoped(.editor).err("finishing the read failed: {s}", .{@errorName(err)});
        };

        self.startTs();
        self.refreshGit();
        self.startLsp();
        self.restoreHistory();
        self.scroll();
        try self.render();

        var needs_render = true;
        while (!self.quit) {
            if (needs_render) {
                self.scroll();
                try self.render();
                needs_render = false;
            }
            // The text is on screen; now bring in what merely annotates it.
            if (self.decorate_pending) {
                self.decorate_pending = false;
                if (self.ts == null) self.startTs();
                self.refreshGit();
                self.startLsp();
                self.restoreHistory();
                needs_render = true;
                continue;
            }
            // A project walk in progress keeps the loop hot: take a slice,
            // stream what it found into an open picker, redraw, repeat. Once
            // it finishes the loop goes back to blocking in poll() forever.
            if (self.walkInProgress()) {
                const grew = self.stepWalk(2000); // ~2 ms per slice
                if (grew and self.mode == .picker) switch (self.picker_kind) {
                    .files => {
                        self.refillFileItems();
                        self.refilter();
                    },
                    .grep => {
                        self.grepMore();
                        self.showAllGrepHits();
                    },
                    else => {},
                };
                // The hot walk loop skips the poll below, so check the
                // debounce here too — otherwise a regex grep rescan armed
                // mid-walk waits for the whole walk instead of one pause.
                if (self.completionDue()) {
                    self.fireDue();
                    needs_render = true;
                    continue;
                }
                if (grew or !self.walkInProgress()) {
                    if (self.mode == .picker) needs_render = true;
                    continue;
                }
            }
            const lsp_fd: ?std.posix.fd_t = if (self.lsp) |*c| (if (c.alive()) c.outFd() else null) else null;
            const ready = try self.term.waitReady(&.{ lsp_fd, self.termFd(), self.dbgFd() }, self.pollTimeout());
            if (self.completionDue()) {
                self.fireDue();
                needs_render = true;
            }
            // A toast whose time is up needs one frame to erase it. `expire`
            // reports whether anything actually went, so a poll that woke for
            // something else does not repaint.
            if (self.toasts.expire(log.nowMs())) needs_render = true;
            if (self.term.takeResize()) {
                self.win = self.term.size();
                self.prev_valid = false; // layout changed; diff base is stale
                needs_render = true;
                continue;
            }
            if (ready.others[0]) {
                if (self.lsp) |*c| c.readAvailable();
                try self.consumeLspResults();
                needs_render = true;
            }
            if (ready.others[1] and self.pumpTerminal()) needs_render = true;
            if (ready.others[2]) {
                if (self.dbg) |*d| d.readAvailable();
                if (self.consumeDebug()) needs_render = true;
            }
            if (ready.input) {
                const chunk = try self.readInput();
                if (chunk.len > 0) {
                    try self.processInput(chunk);
                    self.syncLsp();
                    // A key sent to the shell is echoed back straight away;
                    // draining here shows it in the same frame instead of the
                    // next wake-up, which is what makes typing feel local.
                    _ = self.pumpTerminal();
                    needs_render = true;
                }
            }
        }
    }

    fn readInput(self: *Editor) ![]u8 {
        // Whatever the last read held back leads this one, so a sequence split
        // across the buffer boundary is decoded whole.
        @memcpy(self.inbuf[0..self.carry_len], self.carry[0..self.carry_len]);
        var n = self.carry_len + (try self.term.read(self.inbuf[self.carry_len..])).len;
        self.carry_len = 0;
        // Complete a trailing escape sequence split across reads — over SSH,
        // input regularly arrives in small chunks, and decoding half a CSI
        // sequence would garble arrows, paste fences and friends. A genuine
        // lone Esc press just times out the short wait and stays Esc.
        while (n > 0 and n < self.inbuf.len and
            incompleteEscapeTail(self.inbuf[0..n]) and self.term.waitMore(15))
        {
            n += (try self.term.read(self.inbuf[n..])).len;
        }
        // A read that fills the buffer *exactly* never enters that loop —
        // there is nowhere left to put the rest — so the split has to be
        // repaired the other way round: hold the unfinished tail back and
        // prepend it to the next read. Mouse drags make this routine (one
        // drag across a window is several buffers' worth of reports); before
        // the carry, the fragment decoded as a bare Esc plus loose bytes that
        // ran as commands or landed in the document.
        if (n == self.inbuf.len and incompleteEscapeTail(self.inbuf[0..n])) {
            const keep = completePrefixLen(self.inbuf[0..n], self.term.waitMore(0));
            if (n - keep > 0 and n - keep <= self.carry.len) {
                @memcpy(self.carry[0 .. n - keep], self.inbuf[keep..n]);
                self.carry_len = n - keep;
                return self.inbuf[0..keep];
            }
        }
        return self.inbuf[0..n];
    }

    /// User input from the terminal: decode keys, record macros, dispatch.
    const paste_start_seq = "\x1b[200~";
    const paste_end_seq = "\x1b[201~";

    fn processInput(self: *Editor, chunk: []const u8) !void {
        var sp = log.Span.start();
        var i: usize = 0;
        while (i < chunk.len) {
            if (self.pasting) {
                i += try self.pasteConsume(chunk[i..]);
                continue;
            }
            if (std.mem.startsWith(u8, chunk[i..], paste_start_seq)) {
                self.beginPaste();
                i += paste_start_seq.len;
                continue;
            }
            const d = key.decode(chunk[i..]);
            const raw = chunk[i .. i + d.consumed];
            i += d.consumed;
            if (self.recording != null) self.macro_buf.appendSlice(self.gpa, raw) catch {};
            // A failure only ever aborts the replay it happened in; the next
            // key a person types starts clean. (Recording is not a replay:
            // vim runs the keys as they are typed, error or not.)
            self.failed = false;
            try self.feedKey(d.key, raw);
            if (self.quit) break;
        }
        sp.lap("input");
    }

    fn beginPaste(self: *Editor) void {
        self.pasting = true;
        self.paste_carry_len = 0;
        self.comp_open = false;
        self.sig_open = false;
        if (self.d.diff_of != null or self.d.read_only) return; // read-only: pasteInsert refuses too
        switch (self.mode) {
            .normal, .insert, .visual, .visual_line, .visual_block => self.pushUndo(),
            else => {},
        }
    }

    /// Consume paste-content bytes up to (and including) the end fence,
    /// inserting everything literally. Returns how many bytes were consumed.
    /// A fence split across reads is held in `paste_carry` until resolved.
    fn pasteConsume(self: *Editor, bytes: []const u8) !usize {
        // Resolve carried bytes first: either they complete the end fence, or
        // they were literal content that merely looked like its start.
        if (self.paste_carry_len > 0) {
            const have = self.paste_carry_len;
            const need = paste_end_seq.len - have;
            const take = @min(need, bytes.len);
            if (std.mem.eql(u8, bytes[0..take], paste_end_seq[have .. have + take])) {
                if (take == need) {
                    self.paste_carry_len = 0;
                    self.endPaste();
                    return take;
                }
                @memcpy(self.paste_carry[have .. have + take], bytes[0..take]);
                self.paste_carry_len += take;
                return take; // still a fence prefix; wait for more
            }
            // False alarm: the carry was content. Insert it and rescan `bytes`.
            try self.pasteInsert(self.paste_carry[0..have]);
            self.paste_carry_len = 0;
        }
        if (std.mem.indexOf(u8, bytes, paste_end_seq)) |at| {
            try self.pasteInsert(bytes[0..at]);
            self.endPaste();
            return at + paste_end_seq.len;
        }
        // No fence: keep any trailing fence-prefix for the next read.
        var keep: usize = 0;
        var probe = @min(paste_end_seq.len - 1, bytes.len);
        while (probe > 0) : (probe -= 1) {
            if (std.mem.eql(u8, bytes[bytes.len - probe ..], paste_end_seq[0..probe])) {
                keep = probe;
                break;
            }
        }
        try self.pasteInsert(bytes[0 .. bytes.len - keep]);
        @memcpy(self.paste_carry[0..keep], bytes[bytes.len - keep ..]);
        self.paste_carry_len = keep;
        return bytes.len;
    }

    fn endPaste(self: *Editor) void {
        self.pasting = false;
        self.updateGoal();
    }

    /// Insert pasted bytes literally: no auto-pairs, no key semantics. In the
    /// command line / picker only the first line is taken (they're one-line).
    fn pasteInsert(self: *Editor, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        switch (self.mode) {
            .command => {
                // A paste edits the line exactly like typing: it invalidates
                // the wildmenu ring, updates the history filter and recomputes
                // the inline suggestion.
                const end = std.mem.indexOfAny(u8, bytes, "\r\n") orelse bytes.len;
                try self.cmd.insertSlice(self.gpa, self.cmd_cur, bytes[0..end]);
                self.cmd_cur += end;
                self.cmdEdited();
            },
            .picker => {
                const end = std.mem.indexOfAny(u8, bytes, "\r\n") orelse bytes.len;
                try self.picker_query.appendSlice(self.gpa, bytes[0..end]);
                self.onQueryChange();
            },
            else => {
                if (self.rejectReadOnly()) return;
                var i: usize = 0;
                while (i < bytes.len) {
                    const nl = std.mem.indexOfScalarPos(u8, bytes, i, '\n') orelse bytes.len;
                    var seg = bytes[i..nl];
                    if (seg.len > 0 and seg[seg.len - 1] == '\r') seg = seg[0 .. seg.len - 1];
                    if (seg.len > 0) {
                        try self.buf.insertBytes(self.cy, self.cx, seg);
                        self.cx += seg.len;
                    }
                    if (nl < bytes.len) {
                        try self.buf.splitLine(self.cy, self.cx);
                        self.cy += 1;
                        self.cx = 0;
                    }
                    i = nl + 1;
                }
            },
        }
    }

    /// Replay decoded keys (macros, dot-repeat) without re-recording them.
    /// The explicit error set breaks the inferred-error-set recursion cycle
    /// (replayBytes -> feedKey -> handleKey -> ... -> replayBytes).
    fn replayBytes(self: *Editor, bytes: []const u8) anyerror!void {
        if (self.replay_depth > 64) return; // runaway-recursion guard
        self.replay_depth += 1;
        defer self.replay_depth -= 1;
        // A replayed press must not chain with the one that recorded it, nor a
        // later real click with the last replayed one: the click count is
        // derived from wall-clock time, and a macro is not a person clicking
        // again. Clicks *within* the replay still chain, since the recorded
        // bytes arrive back to back — which is how `@a` reproduces a recorded
        // double-click, exactly as nvim's stored `<2-LeftMouse>` does.
        self.click_ms = 0;
        self.click_count = 0;
        defer {
            self.click_ms = 0;
            self.click_count = 0;
        }
        var i: usize = 0;
        while (i < bytes.len) {
            const d = key.decode(bytes[i..]);
            const raw = bytes[i .. i + d.consumed];
            i += d.consumed;
            try self.feedKey(d.key, raw);
            // vim stops a replay at the first command that fails, so the keys
            // after a motion that could not move never run.
            if (self.quit or self.failed) break;
        }
    }

    /// One key through the dot-repeat capture wrapper and the mode dispatcher.
    fn feedKey(self: *Editor, k_in: key.Key, raw: []const u8) !void {
        // Ctrl-h and Ctrl-j are window navigation in normal mode only, which
        // is where AstroNvim binds them. Everywhere else they are the control
        // codes they have always been — Backspace and a line feed — so insert
        // mode, the command line, the pickers and the prompts are untouched.
        // (The tree has its own key table and gets them as-is; `sidebarKey`
        // routes them into the same directional move, which is how Ctrl-l
        // steps back out of the explorer.)
        const k = switch (k_in) {
            .ctrl => |c| blk: {
                const normal_mode = self.mode == .normal;
                if (c == 'h' and !normal_mode) break :blk key.Key.backspace;
                if (c == 'j' and !normal_mode) break :blk key.Key.enter;
                break :blk k_in;
            },
            else => k_in,
        };
        // `mouse = false` never asks the terminal to report at all; a stray
        // report from a terminal some other program left in tracking mode
        // stays inert too, rather than moving a cursor nobody pointed at.
        if (!config.settings.mouse) switch (k) {
            .mouse_press, .mouse_drag, .mouse_release, .mouse_other, .scroll_up, .scroll_down => return,
            else => {},
        };
        // Mouse wheel: scroll the viewport in the buffer modes; never part of
        // a command, so it bypasses dot-repeat/macro capture entirely.
        switch (k) {
            .mouse_press => |m| {
                // A press acts at once, like an arrow key, so it clears the
                // showcmd indicator instead of leaving the pending command on
                // it — nvim blanks that cell for `d`+click and `3`+click alike
                // (pty-probed). Leaving it set also made the *next* command
                // append to the stale text ("d" then `3` showed `d3`).
                self.showcmd_len = 0;
                self.showcmd_done = false;
                // A press that consumes a pending operator *makes a change*,
                // so it joins the dot capture like any other motion: nvim's
                // redo stores the screen position, which is exactly what
                // replaying the raw report does. Without this, `.` silently
                // repeated whatever change came before instead.
                const change = self.mode == .normal and self.operator != .none and self.await_arg == .none;
                if (change and !self.in_dot) self.dotCapturePre(k, raw);
                try self.mouseClick(m);
                if (change and !self.in_dot) self.dotCapturePost();
                return;
            },
            .mouse_drag => |m| {
                try self.mouseDrag(m);
                return;
            },
            // nvim applies the release coordinates too, so a release away from
            // the last motion is a final extend before the drag ends.
            .mouse_release => |m| {
                try self.mouseDrag(m);
                self.dragging = false;
                return;
            },
            // Other buttons, modified clicks, tilt: inert, like the press that
            // preceded them — never into showcmd, dot-repeat or pending state
            // (a release must not cancel an operator the wheel would keep).
            // Clearing the drag here also self-heals a release a terminal
            // encoded oddly (button 3, "no button"), which would otherwise
            // leave the drag machine armed for ever.
            .mouse_other => {
                self.dragging = false;
                return;
            },
            // The terminal answering the startup background query. Record it
            // as the colour to restore, and the next frame paints the padding
            // in the theme's. Never a keystroke: it must not reach showcmd,
            // dot capture or a pending operator.
            .background => |c| {
                self.term.rememberBackground(c.r, c.g, c.b);
                return;
            },
            .osc_reply => return,
            .scroll_up, .scroll_down => |m, tag| {
                const up = tag == .scroll_up;
                switch (self.mode) {
                    .normal, .insert, .replace, .visual, .visual_line, .visual_block => self.mouseScroll(self.wheelWin(m), up),
                    .picker => self.scrollPreview(if (up) -3 else 3),
                    // Over a shell, the wheel walks its scrollback.
                    .terminal => self.shellScroll(up, 3),
                    .command => {},
                }
                return;
            },
            else => {},
        }
        if (!self.in_dot) self.dotCapturePre(k, raw);
        // showcmd records the *decoded* key, never raw bytes: an arrow's
        // escape sequence must not appear as ^[[B. Characters and control
        // keys read back as text (^W for Ctrl-w, as vim shows).
        //
        // A special key is shown by NAME (`<Down>`, `<Esc>`, `<PageUp>`) —
        // a deliberate divergence from nvim, which renders nothing for them
        // (pty-probed). The owner wants to see the key that just acted, and
        // the indicator already holds a finished command until the next one
        // starts, so a key that executes at once fits the same slot.
        // Dot-repeat (above) and macro capture keep the raw bytes untouched.
        switch (k) {
            .char, .ctrl => self.showcmdPush(raw),
            else => if (keyName(k)) |name| {
                self.showcmdPush(name);
                self.showcmd_done = true; // it acted: hold it until the next key
            } else {
                self.showcmd_len = 0;
                self.showcmd_done = false;
            },
        }
        try self.handleKey(k, raw);
        self.settleFolds();
        if (!self.in_dot) self.dotCapturePost();
        self.showcmdSettle();
    }

    /// What to show in the command indicator for a key that is not text.
    /// Null for keys with nothing worth showing (a mouse report, an unknown
    /// sequence), which clear the indicator instead.
    fn keyName(k: key.Key) ?[]const u8 {
        return switch (k) {
            .up => "<Up>",
            .down => "<Down>",
            .left => "<Left>",
            .right => "<Right>",
            .home => "<Home>",
            .end => "<End>",
            .page_up => "<PageUp>",
            .page_down => "<PageDown>",
            .enter => "<CR>",
            .tab => "<Tab>",
            .shift_tab => "<S-Tab>",
            .backspace => "<BS>",
            .delete => "<Del>",
            .escape => "<Esc>",
            else => null,
        };
    }

    /// Record a key as part of the command being typed. Only the buffer modes
    /// build a command; insert mode and the prompts show their own text.
    fn showcmdPush(self: *Editor, raw: []const u8) void {
        switch (self.mode) {
            .normal, .visual, .visual_line, .visual_block => {},
            .insert, .replace, .command, .picker, .terminal => return,
        }
        if (self.showcmd_done) { // the previous command is still displayed
            self.showcmd_len = 0;
            self.showcmd_done = false;
        }
        for (raw) |b| {
            // Printable keys read back as themselves; control bytes as ^X so
            // Ctrl-w stays legible in the indicator. (Only `.char`/`.ctrl`
            // raw bytes arrive here — never escape sequences.)
            var enc: [2]u8 = undefined;
            const bytes: []const u8 = if (b >= 0x20 and b != 0x7f)
                enc[0..1]
            else blk: {
                enc[0] = '^';
                enc[1] = b + '@';
                break :blk enc[0..2];
            };
            if (bytes.len == 1) enc[0] = b;
            if (self.showcmd_len + bytes.len > self.showcmd.len) {
                // Keep the tail, like vim's 10-column indicator.
                const drop = self.showcmd_len + bytes.len - self.showcmd.len;
                std.mem.copyForwards(u8, self.showcmd[0 .. self.showcmd_len - drop], self.showcmd[drop..self.showcmd_len]);
                self.showcmd_len -= drop;
            }
            @memcpy(self.showcmd[self.showcmd_len..][0..bytes.len], bytes);
            self.showcmd_len += bytes.len;
        }
    }

    /// After a command finishes, keep it on screen (so a whole `diw` or `2dd`
    /// stays readable) and only clear it when the *next* command starts.
    fn showcmdSettle(self: *Editor) void {
        switch (self.mode) {
            .normal, .visual, .visual_line, .visual_block => if (self.atNeutral()) {
                self.showcmd_done = self.showcmd_len > 0;
            },
            .insert, .replace, .command, .picker, .terminal => {
                self.showcmd_len = 0;
                self.showcmd_done = false;
            },
        }
    }

    /// True when screen column `col` belongs to the open sidebar. Those columns
    /// are carved off before the windows tile, so they belong to no `Win` and
    /// the tree's hit-test has to run ahead of the text area's.
    fn inSidebar(self: *Editor, col: usize) bool {
        if (!self.sb_open) return false;
        const x = self.sbX();
        return col >= x and col < x + self.sbWidth();
    }

    /// A left-click. The tabline switches buffers, the way every tabbed
    /// editor behaves, and the explorer acts on its rows: a single click
    /// toggles a directory or opens a file (VS Code's rule), while its
    /// header or the empty space below the tree just focuses it. A click in
    /// a window's text area moves the cursor there (focusing that window
    /// first when it is not the active one) — nvim's `mouse=a`, pty-probed:
    /// no jumplist entry, a pending count discarded, an existing selection
    /// ended, insert mode continued, and a pending *operator* applied over
    /// the clicked range as an exclusive charwise motion. The picker view has
    /// its own route (`pickerClick`); the command line swallows clicks whole
    /// (nvim-verified), and the chrome routes stay normal/insert-only so a
    /// click cannot activate a tree row under a live selection.
    fn mouseClick(self: *Editor, m: key.Mouse) !void {
        self.dragging = false;
        // Every press advances the chain, wherever it lands: vim decides the
        // count in the input layer, before anything routes the click, so a
        // press on chrome (a status line, the command line, another window)
        // breaks a double click in two — nvim-probed. Deriving it only for
        // presses that reach a window let a click on the explorer or the
        // command row *pass through* the chain, and the click after it
        // selected a word.
        const count = self.clickCount(m);
        if (self.mode == .picker) return self.pickerClick(m);
        if (self.mode == .command) return;
        if (self.dashboard) return; // the startup screen owns the keyboard
        if (self.mode == .normal or self.mode == .insert) {
            if (tabsVisible() and m.row == 1) {
                if (self.tabAt(m.col)) |hit| {
                    if (hit.close) return self.closeTab(hit.doc);
                    const doc = hit.doc;
                    if (doc == self.d) return;
                    self.addJump();
                    self.focusDoc(doc);
                    self.clampCursor();
                    self.setStatus("{s}", .{docLabel(doc)});
                    return;
                }
                // Not a tab: the EXPLORER segment (or the filler) — fall
                // through to the sidebar hit-test, which owns those columns.
            }
            if (self.inSidebar(m.col)) return self.sbClick(m.row, m.col);
        }
        const w = self.winAt(m.row, m.col) orelse return; // status rows, cmdline: inert
        // A shell pane's first row is the terminals' own tab row.
        if (w.doc.shell != null and m.row == w.gy) {
            if (self.terminalTabAt(w, m.col)) |hit| {
                if (hit.close) return self.closeTab(hit.doc);
                self.focusWin(w);
                self.focusDoc(hit.doc);
                self.mode = .terminal;
            }
            return;
        }
        try self.clickTo(w, self.winHit(w, m.row, m.col), count);
    }

    /// How many times in a row this cell has been clicked, 1-4 (vim's
    /// multi-click, nvim-probed): the chain continues while each press lands
    /// on the *same* cell within `mousetime` of the one before it — one column
    /// off, or one millisecond late, and it starts again at 1. The count is
    /// computed here, when the press arrives, so no timer is ever armed. Four
    /// is the top of the cycle: a fifth click is a plain one again.
    fn clickCount(self: *Editor, m: key.Mouse) u32 {
        const now = log.nowMs();
        const chained = m.row == self.click_row and m.col == self.click_col and
            now -| self.click_ms < @as(i64, @intCast(config.settings.mousetime));
        self.click_count = if (chained and self.click_count < 4) self.click_count + 1 else 1;
        self.click_ms = now;
        self.click_row = m.row;
        self.click_col = m.col;
        return self.click_count;
    }

    /// Move the cursor to a clicked position and apply the gesture `count`
    /// stands for (1 = move, 2 = the word, 3 = the line, 4 = one blockwise
    /// cell — vim's cycle, nvim-probed). `focusWin` must run first: it
    /// realigns the cursor when the click crosses a diff pair, and the click's
    /// own position has to win over that.
    fn clickTo(self: *Editor, w: *Win, hit: Hit, count: u32) !void {
        self.sb_focus = false; // keys follow the click, not the tree
        if (w != self.cur) {
            self.resetPending(); // an operator never crosses windows
            self.focusWin(w);
        }
        if (self.mode == .normal and self.operator != .none and self.await_arg == .none) {
            // nvim: the click is an exclusive charwise motion for the pending
            // operator, and any count is ignored. `buildSpan` already applies
            // vim's exclusive→previous-line-end→linewise rule.
            self.count = 0;
            self.count2 = 0;
            self.doMotion(.{ .pos = .{ .row = hit.row, .col = hit.col }, .kind = .exclusive, .col_mode = .exact });
            self.clampCursor();
            return; // the operator consumed the click: no drag to start from it
        }
        switch (self.mode) {
            // A click ends the selection — back to insert when the gesture that
            // started it did (nvim's Insert Visual, probed: a click inside one
            // moves the caret and keeps typing).
            .visual, .visual_line, .visual_block => {
                self.mode = if (self.ins_visual) .insert else .normal;
                self.ins_visual = false;
            },
            .insert => {
                self.endSnippet(); // the cursor left the placeholder for good
                self.comp_open = false;
                self.sig_open = false;
            },
            else => {},
        }
        const from_insert = self.mode == .insert;
        self.resetPending();
        self.clearExtra(); // a click collapses to one caret
        self.cy = hit.row;
        self.cx = hit.col;
        // nvim keeps curswant at the *clicked* column, not the clamped one:
        // clicking past a short line and then pressing `j` lands at the
        // clicked column on the longer line below.
        self.goal_col = hit.dcol;
        self.clampCursor();
        self.dragging = true; // motion from here extends a selection
        self.drag_word = null;
        switch (count) {
            2 => { // the word under the pointer, charwise, anchored at its start
                const sp = motion.mouseWord(self.buf, .{ .row = self.cy, .col = self.cx });
                self.cy = sp.start.row;
                self.cx = sp.start.col;
                self.enterVisual(.visual); // anchors at the cursor
                self.cy = sp.end.row;
                self.cx = sp.end.col;
                self.updateGoal();
                self.drag_word = sp; // a drag from here extends by whole words
            },
            3 => self.enterVisual(.visual_line), // the whole line, newline included
            4 => self.enterVisual(.visual_block), // one cell, blockwise
            else => {},
        }
        if (count > 1) self.ins_visual = from_insert;
    }

    /// Motion while the left button is held: extend the selection to here,
    /// entering visual on the first move (nvim-verified — the press alone
    /// stays in normal/insert, so a plain click is a pure cursor move).
    fn mouseDrag(self: *Editor, m: key.Mouse) !void {
        if (!self.dragging) return;
        const w = self.cur;
        // A drag that wanders off the window it started in keeps extending
        // inside it, clamped to what is on screen. nvim extrapolates the row
        // in the origin window's coordinate space instead; that needs a
        // viewport model this hit-test does not have (see Known gaps).
        const row = std.math.clamp(m.row, w.gy, w.gy + self.winTextRows(w) - 1);
        const col = std.math.clamp(m.col, w.gx, w.gx + w.gw - 1);
        const hit = self.winHit(w, row, col);
        // Real mice report a motion for the cell they are already in; nvim
        // stays in normal mode for those, so a click never becomes a
        // selection. The comparison is against the *clamped* position, since
        // that is where the press left the cursor — a click past the end of a
        // short line would otherwise look like a move on its own release.
        const trow = @min(hit.row, self.buf.lineCount() - 1);
        const tcol = @min(hit.col, self.columnLimit(self.buf.line(trow)));
        // A drag after a double-click extends by whole words, so it must run
        // even when the pointer has not left the cell it was pressed in — the
        // release alone would otherwise collapse the selected word to a caret.
        if (trow == self.cy and tcol == self.cx and self.drag_word == null) return;
        const from_insert = self.mode == .insert;
        switch (self.mode) {
            // `enterVisual` anchors at the cursor, which is still where the
            // press left it. From insert that can be the column one past the
            // last character, and nvim keeps it there (probed: `getpos("v")`
            // reports column 4 on a 3-character line) rather than clamping.
            .normal, .insert, .replace => {
                self.enterVisual(.visual);
                self.ins_visual = from_insert; // nvim's Insert Visual
            },
            .visual, .visual_line, .visual_block => {}, // already selecting: extend
            .command, .picker, .terminal => return,
        }
        if (self.drag_word) |anchor| return self.dragWord(anchor, .{ .row = trow, .col = tcol });
        self.cy = hit.row;
        self.cx = hit.col;
        self.goal_col = hit.dcol;
        self.clampCursor();
    }

    /// Extend a double-click's selection by whole words (nvim-probed): the
    /// clicked word always stays selected whole, and the far end snaps to the
    /// start or end of the word under the pointer — a run of blanks included,
    /// so dragging onto the space after a word takes the space with it.
    fn dragWord(self: *Editor, anchor: motion.Span, to: Pos) void {
        const sp = motion.mouseWord(self.buf, to);
        const back = cmpPos(to, anchor.start) < 0;
        const far = if (back) sp.start else if (cmpPos(anchor.end, to) < 0) sp.end else anchor.end;
        const near = if (back) anchor.end else anchor.start;
        self.vstart = near;
        self.cy = far.row;
        self.cx = far.col;
        self.updateGoal();
        self.clampCursor();
    }

    /// A left-click while the picker is up (the whole `zedit .` startup view).
    /// A tab click closes the picker and lands on that buffer (the bar is
    /// visibly rendered, so it must act); explorer clicks delegate to the
    /// tree's own hit-test (a directory toggles under the live picker, a file
    /// opens — `sbActivate` closes the picker first); a result row selects on
    /// the first click (the preview follows, as Ctrl-n) and *opens* when it is
    /// already selected — so a double-click opens from anywhere, with no
    /// double-click timer (SGR carries no click count). The prompt row and the
    /// preview pane stay inert, so terminal text selection keeps working there.
    fn pickerClick(self: *Editor, m: key.Mouse) !void {
        if (tabsVisible() and m.row == 1) {
            if (self.tabAt(m.col)) |hit| {
                self.closePicker();
                if (hit.close) return self.closeTab(hit.doc);
                const doc = hit.doc;
                if (doc != self.d) {
                    self.addJump();
                    self.focusDoc(doc);
                    self.clampCursor();
                    self.setStatus("{s}", .{docLabel(doc)});
                }
            }
            // The EXPLORER segment / filler: inert — the focus grab would be
            // meaningless here (sidebar keys route only in normal mode).
            return;
        }
        if (self.inSidebar(m.col)) return self.sbClick(m.row, m.col);
        const lay = self.pickerLayout();
        // Outside the floating box is outside the picker: clicking there
        // dismisses it, the way clicking off any other floating window does.
        // Without this the border would promise something the mouse did not
        // deliver.
        if (lay.box) |box| {
            if (!box.contains(m.row, m.col)) return self.closePicker();
        }
        if (m.row <= lay.top) return; // the prompt row
        if (m.col < lay.body_x or m.col >= lay.body_x + lay.list_w) return; // the preview
        const shown = m.row - lay.top - 1;
        if (shown >= lay.visible) return; // the status row, when one is up
        const fi = self.picker_scroll + shown;
        if (fi >= self.picker_filtered.items.len) return;
        if (fi == self.picker_sel) return self.pickerOpen();
        self.picker_sel = fi;
    }

    /// The window a wheel notch scrolls: the one under the pointer, whether or
    /// not it has focus (nvim's rule, pty-probed — the wheel never moves
    /// focus), falling back to the focused window for cells no window owns at
    /// all (the sidebar, the title bar, the command line). Inside a visible
    /// side-by-side pair the notch goes to the pane that *drives* the
    /// lockstep, because `syncDiffPanes` derives the other pane's top from it
    /// every frame and would overwrite anything written there directly.
    fn wheelWin(self: *Editor, m: key.Mouse) *Win {
        const w = self.winUnder(m.row, m.col) orelse return self.cur;
        const p = self.diffPairOf(w) orelse return w;
        if (self.cur == p.wt or self.cur == p.ix) return self.cur;
        return p.wt;
    }

    /// Wheel scrolling: move `w`'s viewport three lines (nvim's step) and carry
    /// its cursor with it, so it keeps its row on screen. Scrolling to the top
    /// of the file therefore leaves the cursor near the top, not pinned to the
    /// bottom of the first page (owner's choice over nvim's drag-at-the-edge
    /// rule, which left it stranded).
    ///
    /// The scroll runs on the `Win` — the active window's viewport is saved
    /// out first and loaded back after — so one path serves every window: the
    /// Editor's mirror of the active window cannot go stale, and writing an
    /// inactive window's fields cannot be undone by the next `saveViewport`.
    fn mouseScroll(self: *Editor, w: *Win, up: bool) void {
        const step = 3;
        self.saveViewport();
        defer self.loadViewport();
        const buf = &w.doc.buf;
        const last_line = buf.lineCount() - 1;
        const before = w.top;
        w.top = self.winStepRows(w, w.top, step, up, true); // three *screen* rows
        const moved = if (w.top > before) w.top - before else before - w.top;
        if (moved == 0) return; // already at an end: nothing moves, cursor included
        // Clamped in both directions: an inactive window's bookmarked cursor
        // can outlive the lines it pointed at (another window shortened the
        // buffer), and `buf.line` below must not be handed a stale row.
        w.cy = @min(if (w.top > before) w.cy + moved else w.cy -| moved, last_line);
        const line = buf.line(w.cy);
        w.cx = @min(w.cx, lastColumn(line));
        w.goal_col = displayCol(line, w.cx);
    }

    fn dotCapturePre(self: *Editor, k: key.Key, raw: []const u8) void {
        if (self.mode == .normal and self.atNeutral()) {
            self.dot_temp.clearRetainingCapacity();
            self.dot_count_tmp = 1;
            self.change_started = false;
        }
        // Count digits are recorded as a number, not as keys: a `.` with a new
        // count has to replace *every* count the change had, and `d2w`'s `2`
        // is indistinguishable from `f2`'s in the raw bytes.
        if (self.isCountDigit(k)) return;
        if (self.mode == .normal and (self.count > 0 or self.count2 > 0)) self.dot_count_tmp = self.eff();
        switch (self.mode) {
            .normal, .insert, .replace, .visual, .visual_line, .visual_block => self.dot_temp.appendSlice(self.gpa, raw) catch {},
            .command, .picker, .terminal => {},
        }
    }

    /// Whether this key is about to be swallowed as a count rather than acting.
    /// Mirrors the two places counts accumulate — the leading one in
    /// `normalChar` and the one after an operator in `operatorPendingKey`.
    fn isCountDigit(self: *Editor, k: key.Key) bool {
        if (self.mode != .normal or self.await_arg != .none) return false;
        const c = charByte(k) orelse return false;
        if (self.operator != .none) return (c >= '1' and c <= '9') or (c == '0' and self.count2 > 0);
        return (c >= '1' and c <= '9') or (c == '0' and self.count > 0);
    }

    fn dotCapturePost(self: *Editor) void {
        if (self.mode == .normal and self.atNeutral() and self.change_started) {
            self.dot_keys.clearRetainingCapacity();
            self.dot_keys.appendSlice(self.gpa, self.dot_temp.items) catch {};
            self.dot_count = self.dot_count_tmp;
            self.change_started = false;
        }
    }

    fn atNeutral(self: *Editor) bool {
        return self.count == 0 and self.count2 == 0 and self.operator == .none and
            self.await_arg == .none and self.pending_register == null;
    }

    fn handleKey(self: *Editor, k: key.Key, raw: []const u8) !void {
        self.status.clearRetainingCapacity();
        if (self.dashboard and self.mode == .normal) {
            // Handled keys stay on the screen; anything else dismisses it and
            // falls through to the normal dispatch below.
            if (try self.dashboardKey(k)) return;
            self.dashboard = false;
        }
        // A pending leader menu owns the keyboard even while the explorer has
        // focus, so `Space` works the same in both places.
        if (self.sb_focus and self.mode == .normal and self.await_arg == .none) return self.sidebarKey(k);
        if (try self.keymapKey(k)) return;
        switch (self.mode) {
            .terminal => self.terminalKey(k, raw),
            .normal => try self.normalKey(k),
            .insert => try self.insertKey(k),
            .replace => try self.replaceKey(k),
            .visual, .visual_line, .visual_block => {
                const iv = self.ins_visual;
                try self.visualKey(k);
                // nvim's Insert Visual: whatever ends the selection — Esc, `v`,
                // an operator — puts you back in insert where it left the
                // cursor, so typing continues (probed: `d` then "XX" inserts
                // XX, where plain visual would run them as commands).
                switch (self.mode) {
                    .visual, .visual_line, .visual_block => {},
                    else => if (iv) {
                        self.ins_visual = false;
                        if (self.mode == .normal) self.mode = .insert;
                    },
                }
            },
            .command => try self.commandKey(k),
            .picker => try self.pickerKey(k),
        }
        self.clampCursor();
    }

    // === normal mode =======================================================

    fn normalKey(self: *Editor, k: key.Key) !void {
        if (self.await_arg != .none) return self.awaitKey(k);
        // Enter in the quickfix window jumps to the entry on the cursor's
        // line, as in vim. Everything else there behaves like any read-only
        // buffer, so `j`/`k`/`/` all still work to find the one you want.
        if (self.cur.doc.qf_view and k == .enter) {
            if (self.qf.goTo(self.cy)) |entry| {
                // vim opens the entry in the window *above* the list and
                // leaves the list up — replacing the list with the file would
                // lose the very thing being worked through. With no other
                // window there is nowhere else to go, so it opens in place.
                for (self.wins.items) |w| {
                    if (w.doc.qf_view) continue;
                    self.focusWin(w);
                    break;
                }
                self.qfJump(entry);
            }
            return;
        }
        // VS Code's terminal toggle. The key is whatever the terminal sends
        // for Ctrl-backtick (NUL), which is also Ctrl-Space — they cannot be
        // told apart on the wire, and neither was bound to anything.
        if (k == .ctrl and k.ctrl == ' ') return self.toggleTerminal();
        if (self.cur.doc.shell) |*sh| {
            // Reading back through what a command printed is the main reason
            // to leave Terminal mode, so the paging keys do that here rather
            // than moving a cursor the grid does not have.
            if (k == .ctrl and (k.ctrl == 'u' or k.ctrl == 'd') and !sh.done) {
                self.shellScroll(k.ctrl == 'u', self.shellRows(self.cur) / 2);
                return;
            }
            // An exited shell's grid stays up so its last output is readable;
            // the next key dismisses it (nvim's rule for a finished :terminal).
            if (sh.done) return self.closeTerminal();
            // Every insert-entering key means the same thing over a grid there
            // is no cursor to place in: start typing at the shell.
            if (k == .char) switch (k.char) {
                'i', 'a', 'I', 'A', 'o', 'O' => {
                    self.mode = .terminal;
                    return self.setStatus("terminal", .{});
                },
                else => {},
            };
        }
        if (self.operator != .none) return self.operatorPendingKey(k);
        if (self.extra.items.len > 0) {
            if (try self.multiNormal(k)) return;
            self.clearExtra(); // non-multi command: collapse to one cursor
        }

        switch (k) {
            .char => |c| try self.normalChar(c),
            .ctrl => |c| self.normalCtrl(c),
            // Arrows take a count exactly like h/l/k/j (nvim-probed: `3<Right>`
            // then `x` hits column 4, `2<Down>` lands two lines down; `2<Home>`
            // ignores the count). doMotion consumed the count either way, so
            // dropping it here silently ate `2<Down>`'s 2.
            .left => self.doMotion(self.repeatMotion(.left)),
            .right => self.doMotion(self.repeatMotion(.right)),
            .up => self.doMotion(self.vertical(true, self.eff())),
            .down => self.doMotion(self.vertical(false, self.eff())),
            .home => self.doMotion(.{ .pos = .{ .row = self.cy, .col = 0 }, .kind = .exclusive, .col_mode = .exact }),
            .end => self.doMotion(.{ .pos = .{ .row = self.cy, .col = self.curLine().len }, .kind = .inclusive, .col_mode = .exact }),
            .backspace => self.doMotion(self.repeatMotion(.left)),
            .page_up => self.pageMove(true),
            .page_down => self.pageMove(false),
            .tab => self.jumpForward(), // Ctrl-i arrives as Tab; vim treats them alike
            .escape => self.resetPending(),
            else => self.resetPending(),
        }
    }

    fn normalChar(self: *Editor, c: u21) !void {
        // Count prefix ('0' is a motion unless a count is already building).
        if (c >= '1' and c <= '9' or (c == '0' and self.count > 0)) {
            self.count = self.count * 10 + (c - '0');
            return;
        }
        switch (c) {
            // motions
            'h' => self.doMotion(self.repeatMotion(.left)),
            'l' => self.doMotion(self.repeatMotion(.right)),
            ' ' => self.await_arg = .space_leader, // which-key leader
            // With soft wrap on, `j`/`k` walk *screen* rows — a deliberate
            // divergence from vim, where they always move a buffer line and
            // `gj`/`gk` do this. On wrapped prose vim's rule feels like the
            // cursor skipping, which is what it looks like: one press crosses
            // however many rows the line happened to fill. `gj`/`gk` still
            // work and are now simply the same thing.
            //
            // Only as a *cursor* motion: with an operator pending they stay
            // linewise, because `dj` must delete two whole lines rather than a
            // screen row's worth of characters (`screenVertical` is charwise,
            // which is also why vim's own `dgj` is charwise).
            'j' => self.doMotion(if (self.wrappedHere())
                self.screenVertical(false, self.eff())
            else
                self.vertical(false, self.eff())),
            'k' => self.doMotion(if (self.wrappedHere())
                self.screenVertical(true, self.eff())
            else
                self.vertical(true, self.eff())),
            '0' => self.doMotion(.{ .pos = .{ .row = self.cy, .col = 0 }, .kind = .exclusive, .col_mode = .exact }),
            '^', '_' => self.doMotion(.{ .pos = .{ .row = self.cy, .col = motion.firstNonBlank(self.curLine()) }, .kind = .exclusive, .col_mode = .exact }),
            '$' => self.doMotion(self.endOfLineMotion()),
            'w' => self.doMotion(self.repeatWord(.f, false)),
            'W' => self.doMotion(self.repeatWord(.f, true)),
            'b' => self.selectWord(.b),
            'B' => self.doMotion(self.repeatWord(.b, true)),
            'e' => self.selectWord(.e),
            'E' => self.doMotion(self.repeatWord(.e, true)),
            'G' => self.doMotion(self.gotoLineMotion(if (self.count > 0) self.count - 1 else self.buf.lineCount() - 1)),
            '%' => if (motion.matchPair(self.buf, self.cursor())) |p| {
                if (self.operator == .none) self.addJump();
                self.doMotion(.{ .pos = p, .kind = .inclusive, .col_mode = .exact });
            } else self.resetPending(),
            '{' => self.doMotion(self.paragraphMotion(false)),
            '}' => self.doMotion(self.paragraphMotion(true)),
            '(' => self.doMotion(self.sentenceMotion(false)),
            ')' => self.doMotion(self.sentenceMotion(true)),
            'H' => self.doMotion(self.gotoLineMotion(self.top)),
            'M' => self.doMotion(self.gotoLineMotion(self.lineAtScreenRow(self.textRows() / 2))),
            'L' => self.doMotion(self.gotoLineMotion(self.lineAtScreenRow(self.textRows() - 1))),
            'f' => self.await_arg = .find_f,
            't' => self.await_arg = .find_t,
            'F' => self.await_arg = .find_cap_f,
            'T' => self.await_arg = .find_cap_t,
            ';' => self.repeatFind(false),
            ',' => self.repeatFind(true),
            'g' => self.await_arg = .g_prefix,
            ']' => self.await_arg = .bracket_next, // ]d: next diagnostic
            '[' => self.await_arg = .bracket_prev, // [d: previous diagnostic
            // operators
            'd' => self.operator = .delete,
            'c' => self.operator = .change,
            'y' => self.operator = .yank,
            '>' => self.operator = .indent_right,
            '=' => self.operator = .reindent,
            '<' => self.operator = .indent_left,
            // register / marks / macros
            '"' => self.await_arg = .register,
            'm' => self.await_arg = .mark_set,
            '`' => self.await_arg = .mark_jump_back,
            '\'' => self.await_arg = .mark_jump_line,
            'q' => if (self.recording != null) self.stopMacro() else {
                self.await_arg = .macro_record;
            },
            '@' => self.await_arg = .macro_play,
            // edits that enter insert
            'i' => try self.enterInsert(self.cursor()),
            'I' => try self.enterInsert(.{ .row = self.cy, .col = motion.firstNonBlank(self.curLine()) }),
            'a' => try self.enterInsert(self.afterCursor()),
            'A' => try self.enterInsert(.{ .row = self.cy, .col = self.curLine().len }),
            'o' => try self.openLine(true),
            'O' => try self.openLine(false),
            // immediate edits
            'x' => try self.deleteChars(self.eff(), true),
            'X' => try self.deleteChars(self.eff(), false),
            'D' => try self.changeToLineEnd(false),
            'C' => try self.changeToLineEnd(true),
            'Y' => try self.yankLines(self.eff()),
            's' => try self.substituteChars(self.eff()),
            'S' => try self.changeLines(self.eff()),
            'r' => self.await_arg = .replace,
            'R' => try self.enterReplace(false),
            '~' => try self.toggleCase(self.eff()),
            'J' => try self.joinLines(self.eff(), true),
            'K' => {
                self.lspHover();
                self.resetPending();
            },
            'p' => try self.paste(true, false),
            'P' => try self.paste(false, false),
            'u' => self.undoChange(),
            // visual / search / command
            'v' => self.enterVisual(.visual),
            'V' => self.enterVisual(.visual_line),
            '/' => self.enterCmd(.search_forward),
            '?' => self.enterCmd(.search_backward),
            'n' => self.repeatSearch(true),
            'N' => self.repeatSearch(false),
            '*' => self.searchWord(true, true),
            '#' => self.searchWord(false, true),
            ':' => self.enterCmd(.ex),
            '.' => try self.repeatDot(),
            'Z' => self.await_arg = .z_prefix,
            'z' => self.await_arg = .fold_prefix,
            else => self.resetPending(),
        }
    }

    fn normalCtrl(self: *Editor, c: u8) void {
        switch (c) {
            'r' => self.redoChange(),
            'v' => self.enterVisual(.visual_block), // blockwise visual
            'n' => self.addCursor(true), // add a cursor on the line below
            'p' => self.addCursor(false), // add a cursor on the line above
            'f' => self.pageMove(false),
            'b' => self.pageMove(true),
            'd' => {
                self.cy = self.lineAfterRows(self.cy, self.textRows() / 2, false);
                self.snapColumn();
                self.resetPending();
            },
            'u' => {
                self.cy = self.lineAfterRows(self.cy, self.textRows() / 2, true);
                self.snapColumn();
                self.resetPending();
            },
            'w' => self.await_arg = .ctrl_w, // window command prefix
            'o' => self.jumpBack(), // jumplist back
            'a' => self.incrementNumber(1, self.eff()),
            'x' => self.incrementNumber(-1, self.eff()),
            'e' => self.scrollLines(true, self.eff()),
            'y' => self.scrollLines(false, self.eff()),
            'g' => self.showFileInfo(),
            '^' => self.editAlternate(), // Ctrl-^ (0x1e on the wire)
            'z' => self.suspendEditor(),
            // AstroNvim's window navigation. Directional rather than a cycle,
            // and the explorer is one of the places you can move to, which is
            // the keyboard route into the tree that `Space e` alone gave.
            'h' => self.moveFocus(.left),
            'l' => self.moveFocus(.right),
            'j' => self.moveFocus(.down),
            'k' => self.moveFocus(.up),
            'c' => self.setStatus("Type :q then Enter to quit", .{}),
            else => self.resetPending(),
        }
    }

    /// The key after f/t/F/T/r/m/`/'/"/g/Z/q/@ or operator-pending i/a.
    fn awaitKey(self: *Editor, k: key.Key) !void {
        const a = self.await_arg;
        self.await_arg = .none;
        switch (a) {
            .find_f, .find_t, .find_cap_f, .find_cap_t => {
                const ch = charOf(k) orelse return self.resetPending();
                self.last_find = .{ .kind = a, .ch = ch };
                self.applyFind(a, ch);
            },
            .replace => try self.replaceChars(k),
            .mark_set => {
                if (markIndex(k)) |idx| self.marks[idx] = self.cursor();
                self.resetPending();
            },
            // `\``/`'` record a jump; `g\``/`g'` are the same jump with the
            // jumplist left alone, which is the whole of the difference.
            .mark_jump_back, .mark_jump_back_nj => {
                if (markIndex(k)) |idx| if (self.marks[idx]) |p| {
                    if (a == .mark_jump_back) self.addJump();
                    self.setCursor(p);
                };
                self.resetPending();
            },
            .mark_jump_line, .mark_jump_line_nj => {
                if (markIndex(k)) |idx| if (self.marks[idx]) |p| {
                    if (a == .mark_jump_line) self.addJump();
                    self.cy = @min(p.row, self.buf.lineCount() - 1);
                    self.cx = motion.firstNonBlank(self.curLine());
                    self.updateGoal();
                };
                self.resetPending();
            },
            .register => {
                self.pending_register = charByte(k);
            },
            .g_prefix => {
                if (k == .char and k.char == 'g')
                    self.doMotion(self.gotoLineMotion(if (self.count > 0) self.count - 1 else 0))
                else if (k == .char and k.char == 'c')
                    self.operator = .comment // gc{motion} / gcc
                else if (k == .char and k.char == 'd') {
                    self.lspDefinition(); // gd: goto definition
                    self.resetPending();
                } else if (k == .char and k.char == 'r') {
                    self.enterRename(); // gr: rename symbol (prompts for the new name)
                } else if (k == .char and k.char == 'i') {
                    self.lspImplementation(); // gi: goto implementation
                    self.resetPending();
                } else if (k == .char and k.char == 'y') {
                    self.lspTypeDefinition(); // gy: goto type definition
                    self.resetPending();
                } else if (k == .char and k.char == 'a') {
                    self.lspCodeAction(); // ga: code actions for the current line
                    self.resetPending();
                } else if (k == .char and k.char == '-') {
                    self.timeTravel(self.eff(), true); // g-: one state older
                    self.resetPending();
                } else if (k == .char and k.char == '+') {
                    self.timeTravel(self.eff(), false); // g+: one state newer
                    self.resetPending();
                } else if (k == .char and (k.char == 'U' or k.char == 'u' or k.char == '~')) {
                    const op: Operator = switch (k.char) {
                        'U' => .upper,
                        'u' => .lower,
                        else => .toggle_case,
                    };
                    // `gUgU` is `gUU`: arriving here with the same operator
                    // already pending means the user doubled it the long way.
                    if (self.operator == op) self.applyLinewiseOperator() else self.operator = op;
                } else if (k == .char and k.char == 'R') {
                    try self.enterReplace(true); // gR: virtual replace
                } else if (k == .char and k.char == 'J') {
                    try self.joinLines(self.eff(), false); // gJ: join, no space
                    self.resetPending();
                } else if (k == .char and k.char == 'v') {
                    self.reselect(); // gv: put the last selection back
                    self.resetPending();
                } else if (k == .char and k.char == 'x') {
                    self.openUnderCursor(); // gx: hand it to the system handler
                    self.resetPending();
                } else if (k == .char and k.char == '?') {
                    // g?? and g?g? both double it; the second `g` is eaten
                    // by the prefix, so only the letter reaches here.
                    if (self.operator == .rot13) self.applyLinewiseOperator() else self.operator = .rot13;
                } else if (k == .char and k.char == 'q') {
                    self.operator = .reflow;
                } else if (k == .char and k.char == 'w') {
                    self.operator = .reflow_keep;
                } else if (k == .char and k.char == 'n') {
                    self.selectMatch(true);
                } else if (k == .char and k.char == 'N') {
                    self.selectMatch(false);
                } else if (k == .char and k.char == 'e') {
                    self.doMotion(self.repeatEndBackward(false));
                } else if (k == .char and k.char == 'E') {
                    self.doMotion(self.repeatEndBackward(true));
                } else if (k == .char and k.char == '_') {
                    self.doMotion(self.lastNonBlank(self.eff()));
                } else if (k == .char and k.char == '^') {
                    self.doMotion(self.screenFirstNonBlank());
                } else if (k == .char and k.char == 'm') {
                    self.doMotion(self.middleOfLine(true));
                } else if (k == .char and k.char == 'M') {
                    self.doMotion(self.middleOfLine(false));
                } else if (k == .char and k.char == 'o') {
                    self.doMotion(self.byteOffsetPos(self.eff()));
                } else if (k == .char and k.char == '*') {
                    self.searchWord(true, false); // like `*`, no word bounds
                } else if (k == .char and k.char == '#') {
                    self.searchWord(false, false);
                } else if (k == .char and k.char == '&') {
                    self.repeatSubstituteAll();
                    self.resetPending();
                } else if (k == .char and k.char == '8') {
                    self.showByteValue();
                    self.resetPending();
                } else if (k == .char and k.char == 'I') {
                    try self.enterInsert(.{ .row = self.cy, .col = 0 });
                } else if (k == .char and k.char == 'p') {
                    try self.paste(true, true); // cursor after the paste
                    self.resetPending();
                } else if (k == .char and k.char == 'P') {
                    try self.paste(false, true);
                    self.resetPending();
                } else if (k == .char and k.char == 'f') {
                    self.openFileUnderCursor(false);
                    self.resetPending();
                } else if (k == .char and k.char == 'F') {
                    self.openFileUnderCursor(true);
                    self.resetPending();
                } else if (k == .char and k.char == ';') {
                    self.changeListStep(true, self.eff());
                    self.resetPending();
                } else if (k == .char and k.char == ',') {
                    self.changeListStep(false, self.eff());
                    self.resetPending();
                } else if (k == .char and k.char == 'D') {
                    self.lspDeclaration();
                    self.resetPending();
                } else if (k == .char and (k.char == '\'' or k.char == '`')) {
                    // `g'`/`g\`` jump to a mark without touching the jumplist,
                    // which is the only thing that separates them from `'`/`\``.
                    self.await_arg = if (k.char == '\'') .mark_jump_line_nj else .mark_jump_back_nj;
                } else if (k == .char and k.char == 'j')
                    self.doMotion(self.screenVertical(false, self.eff()))
                else if (k == .char and k.char == 'k')
                    self.doMotion(self.screenVertical(true, self.eff()))
                else if (k == .char and k.char == '0')
                    self.doMotion(self.screenLineEdge(false))
                else if (k == .char and k.char == '$')
                    self.doMotion(self.screenLineEdge(true))
                else if (k == .down)
                    self.doMotion(self.screenVertical(false, self.eff()))
                else if (k == .up)
                    self.doMotion(self.screenVertical(true, self.eff()))
                else if (k == .home)
                    self.doMotion(self.screenLineEdge(false))
                else if (k == .end)
                    self.doMotion(self.screenLineEdge(true))
                else if (k == .ctrl and k.ctrl == 'g') {
                    self.showCursorInfo();
                    self.resetPending();
                } else
                    self.resetPending();
            },
            .visual_replace => {
                self.await_arg = .none;
                if (k == .char) self.visualReplaceChar(k.char);
            },
            .visual_z => {
                self.await_arg = .none;
                if (k == .char and k.char == 'y') {
                    if (self.mode == .visual_block) try self.blockYank(true) else try self.visualOperator(.yank);
                }
            },
            // `g` in visual mode. The selection is still live here, so these
            // act on it rather than taking a motion.
            .visual_g => {
                const n = self.eff();
                self.await_arg = .none;
                if (k == .ctrl) switch (k.ctrl) {
                    // The stepping forms: 1st line +1, 2nd +2, and so on.
                    'a' => self.visualIncrement(1, n, true),
                    'x' => self.visualIncrement(-1, n, true),
                    else => {},
                };
                self.count = 0;
                self.count2 = 0;
                if (k == .char) switch (k.char) {
                    'g' => self.setCursorKeep(.{ .row = 0, .col = 0 }), // gg
                    'v' => self.reselect(), // gv swaps the two selections
                    'U' => try self.visualCase(.upper),
                    'u' => try self.visualCase(.lower),
                    '~' => try self.visualCase(.toggle),
                    // The screen-line motions, which extend the selection
                    // like any other. They worked by accident before — the
                    // bare `g` jumped to line 1 and the second key applied
                    // from there — and making `g` a real prefix would have
                    // swallowed them silently instead (nvim-pinned).
                    '0' => self.setCursorKeep(self.screenLineEdge(false).pos),
                    '$' => self.setCursorKeep(self.screenLineEdge(true).pos),
                    'j' => self.setCursorKeep(self.screenVertical(false, n).pos),
                    'k' => self.setCursorKeep(self.screenVertical(true, n).pos),
                    'q' => { // gq: reflow the selected lines
                        const top = @min(self.vstart.row, self.cy);
                        const bot = @max(self.vstart.row, self.cy);
                        self.mode = .normal;
                        self.reflow(.{ .lines = true, .top = top, .bot = bot }, false);
                    },
                    'J' => { // gJ: join the selected lines, no separator
                        const from = self.vstart.row;
                        const to = self.cy;
                        const top = @min(from, to);
                        self.mode = .normal;
                        self.setCursor(.{ .row = top, .col = 0 });
                        // A one-line selection still joins it to the next,
                        // which is what a bare `gJ` does (nvim-probed).
                        try self.joinLines(@max(from, to) - top + 1, false);
                    },
                    else => {},
                };
            },
            .z_prefix => {
                if (k == .char and k.char == 'Z') {
                    if (try self.write("")) self.quit = true;
                } else if (k == .char and k.char == 'Q') {
                    self.quit = true;
                }
                self.resetPending();
            },
            .fold_prefix => {
                // A leading count belongs to the operator that follows, as it
                // does for `d`/`y`: `3zfj` is `zf3j`.
                const n = self.count;
                self.resetPending();
                if (k == .char) switch (k.char) {
                    'f' => {
                        self.operator = .fold; // zf{motion}
                        self.count = n;
                    },
                    'o' => self.foldSet(false),
                    'c' => self.foldSet(true),
                    'a' => self.foldToggle(),
                    'R' => self.foldAll(false),
                    'M' => self.foldAll(true),
                    'd' => self.foldDelete(),
                    'E' => self.foldClear(),
                    'z' => self.positionView(.centre),
                    't' => self.positionView(.top),
                    'b' => self.positionView(.bottom),
                    // The same three, but also to the line's first non-blank —
                    // which is the only thing separating them (nvim-probed).
                    '.' => {
                        self.positionView(.centre);
                        self.toFirstNonBlank();
                    },
                    '-' => {
                        self.positionView(.bottom);
                        self.toFirstNonBlank();
                    },
                    // `z+` starts on the line below the window, `z^` on the
                    // one above it, then behave like z<CR> and z- from there.
                    '+' => {
                        // These two read the *window*, so it has to be where
                        // it will be drawn: a burst of keys (`50Gz+` in one
                        // read) reaches here before the frame that would
                        // have settled the viewport.
                        self.scroll();
                        self.cy = if (n > 0) @min(n - 1, self.buf.lineCount() - 1) else @min(self.bottomLine() + 1, self.buf.lineCount() - 1);
                        self.positionView(.top);
                        self.toFirstNonBlank();
                    },
                    '^' => {
                        self.scroll();
                        self.cy = if (n > 0) @min(n - 1, self.buf.lineCount() - 1) else self.top -| 1;
                        self.positionView(.bottom);
                        self.toFirstNonBlank();
                    },
                    // Folds, the rest of them.
                    'A' => _ = self.d.folds.toggleRecursive(self.cy),
                    'C' => _ = self.d.folds.setClosedRecursive(self.cy, true),
                    'O' => _ = self.d.folds.setClosedRecursive(self.cy, false),
                    'D' => _ = self.d.folds.removeRecursive(self.cy),
                    'F' => self.foldCreate(self.cy, @min(self.cy + @max(n, 1) - 1, self.buf.lineCount() - 1)),
                    'v' => self.d.folds.reveal(self.cy),
                    'x' => {
                        self.d.folds.applyLevel();
                        self.d.folds.reveal(self.cy);
                    },
                    'X' => self.d.folds.applyLevel(),
                    'm' => self.d.folds.stepLevel(false, @max(n, 1)),
                    'r' => self.d.folds.stepLevel(true, @max(n, 1)),
                    'i' => self.d.folds.enabled = !self.d.folds.enabled,
                    'n' => self.d.folds.enabled = false,
                    'N' => self.d.folds.enabled = true,
                    'j' => if (self.d.folds.nextFold(self.cy, true)) |r| {
                        self.cy = @min(r, self.buf.lineCount() - 1);
                        self.toFirstNonBlank();
                    },
                    'k' => if (self.d.folds.nextFold(self.cy, false)) |r| {
                        self.cy = @min(r, self.buf.lineCount() - 1);
                        self.toFirstNonBlank();
                    },
                    // Horizontal scrolling (soft wrap off).
                    'h' => self.scrollSideways(false, @max(n, 1)),
                    'l' => self.scrollSideways(true, @max(n, 1)),
                    'H' => self.scrollSideways(false, self.textCols() / 2),
                    'L' => self.scrollSideways(true, self.textCols() / 2),
                    's' => self.scrollCursorTo(true),
                    'e' => self.scrollCursorTo(false),
                    // Blockwise paste/yank with no padding (see pasteBlock).
                    'p' => {
                        self.block_pad = false;
                        self.paste(true, false) catch {};
                        self.block_pad = true;
                    },
                    'P' => {
                        self.block_pad = false;
                        self.paste(false, false) catch {};
                        self.block_pad = true;
                    },
                    else => {},
                };
                if (k == .enter) { // z<CR>
                    self.positionView(.top);
                    self.toFirstNonBlank();
                } else if (k == .left) {
                    self.scrollSideways(false, @max(n, 1));
                } else if (k == .right) {
                    self.scrollSideways(true, @max(n, 1));
                }
            },
            .bracket_next, .bracket_prev => {
                const fwd = a == .bracket_next;
                const cnt = self.eff();
                if (k == .char) switch (k.char) {
                    ' ' => self.addBlankLines(fwd, cnt),
                    // Marks, exact and linewise.
                    '\'' => self.markStep(fwd, false),
                    '`' => self.markStep(fwd, true),
                    // Unmatched brackets: `[(`/`])` and `[{`/`]}`.
                    '(', ')' => if (self.unmatchedBracket('(', ')', fwd, cnt)) |p| self.setCursor(p),
                    '{', '}' => if (self.unmatchedBracket('{', '}', fwd, cnt)) |p| self.setCursor(p),
                    // Sections: a brace in column 0. `[[`/`]]` take `{`,
                    // `[]`/`][` take `}` — note the crossed spelling, which
                    // is vim's.
                    '[' => self.setCursor(self.sectionMove(if (fwd) '}' else '{', fwd, cnt)),
                    ']' => self.setCursor(self.sectionMove(if (fwd) '{' else '}', fwd, cnt)),
                    // A C comment's ends.
                    '/', '*' => if (self.commentEdge(fwd)) |p| self.setCursor(p),
                    // The preprocessor conditional around the cursor.
                    '#' => if (self.preprocEdge(fwd)) |p| self.setCursor(p),
                    // A member's opening brace.
                    'm' => self.memberStep(fwd, cnt),
                    // The open fold's own ends.
                    'z' => if (self.d.folds.enclosing(self.cy)) |f|
                        self.setCursor(.{ .row = if (fwd) f.end else f.start, .col = 0 }),
                    // Paste with the indent adjusted to this line.
                    'p', 'P' => self.pasteIndented(fwd and k.char == 'p'),
                    // `]c`/`[c` is vim's diff-mode change motion; zedit's
                    // changes are the git hunks `]g`/`[g` already walk.
                    'c' => self.gotoHunk(fwd),
                    // First/last of a list, rather than next/previous.
                    'D' => self.gotoDiagnosticEnd(fwd),
                    'Q' => self.qfEnd(fwd),
                    'B' => self.docEnd(fwd),
                    else => {},
                };
                if (k == .char and k.char == 'd') self.gotoDiagnostic(a == .bracket_next, null);
                if (k == .char and k.char == 'e') self.gotoDiagnostic(a == .bracket_next, 1); // ]e / [e errors
                if (k == .char and k.char == 'w') self.gotoDiagnostic(a == .bracket_next, 2); // ]w / [w warnings
                if (k == .char and k.char == 'b') self.cycleDoc(a == .bracket_next, self.eff()); // ]b / [b buffers
                if (k == .char and k.char == 'f') self.gotoFunction(a == .bracket_next); // ]f / [f functions
                if (k == .char and k.char == 'q') self.qfStep(a == .bracket_next, self.eff()); // ]q / [q quickfix
                if (k == .char and k.char == 'g') self.gotoHunk(a == .bracket_next); // ]g / [g git hunks
                self.resetPending();
            },
            .ctrl_w => {
                const cnt = self.eff();
                self.resetPending();
                const ch: u8 = switch (k) {
                    .char => |c| if (c < 128) @intCast(c) else 0,
                    .ctrl => |c| c, // Ctrl-w Ctrl-w also cycles
                    else => 0,
                };
                switch (ch) {
                    'v' => self.splitWindow(true), // vertical split (columns)
                    's', 'S', 'n' => self.splitWindow(false), // horizontal split (rows)
                    'c', 'q' => self.closeWindow(),
                    'o' => self.onlyWindow(),
                    'w', 'l', 'j' => self.nextWindow(true),
                    'h', 'k' => self.nextWindow(false),
                    'W' => self.nextWindow(false),
                    // `p` is the *last accessed* window, which is not the
                    // same as the previous one in the tiling order.
                    'p' => self.focusPrevWindow(),
                    // First and last in the tiling, whatever the orientation.
                    't' => self.focusWinAt(0),
                    'b' => self.focusWinAt(self.wins.items.len - 1),
                    // Move this window to the far end, or swap it with the
                    // next — the flat tiling makes both a reorder.
                    'H', 'K' => self.moveWindowTo(0),
                    'L', 'J' => self.moveWindowTo(self.wins.items.len - 1),
                    'x' => self.swapWindow(),
                    'r' => self.rotateWindows(true),
                    'R' => self.rotateWindows(false),
                    // Split, then open what is under the cursor there.
                    'f', 'F' => {
                        self.splitWindow(false);
                        self.openFileUnderCursor(ch == 'F');
                    },
                    'd' => {
                        self.splitWindow(false);
                        self.lspDefinition();
                    },
                    'i' => {
                        self.splitWindow(false);
                        self.lspDeclaration();
                    },
                    '^' => { // Ctrl-w ^: the alternate file in a split
                        self.splitWindow(false);
                        self.editAlternate();
                    },
                    // `_` and `|` maximise along an axis; zedit's windows
                    // carry weights, so "as big as it can be" is the honest
                    // reading of an absolute height on a relative layout.
                    '_' => self.resizeWindow(@intCast(self.win.rows), false),
                    '|' => self.resizeWindow(@intCast(self.win.cols), true),
                    // Resize, vim's keys. A count is the number of cells:
                    // `5Ctrl-w +` grows by five, as `Ctrl-w +` grows by one.
                    '+' => self.resizeWindow(@intCast(cnt), false),
                    '-' => self.resizeWindow(-@as(i64, @intCast(cnt)), false),
                    '>' => self.resizeWindow(@intCast(cnt), true),
                    '<' => self.resizeWindow(-@as(i64, @intCast(cnt)), true),
                    '=' => self.equalizeWindows(),
                    else => {},
                }
            },
            .object_inner, .object_around => try self.applyTextObject(a == .object_around, k),
            .macro_record => {
                if (charByte(k)) |reg| {
                    self.recording = reg;
                    self.macro_buf.clearRetainingCapacity();
                    self.setStatus("recording @{c}", .{reg});
                }
                self.resetPending();
            },
            .macro_play => {
                // `@@` replays whatever `@` last played (vim's rule); before
                // any `@` at all it is simply unknown and does nothing.
                const named = charByte(k) orelse {
                    self.resetPending();
                    return;
                };
                const reg = if (named == '@') (self.last_macro orelse {
                    self.resetPending();
                    return;
                }) else named;
                const n = self.eff();
                self.resetPending();
                try self.playMacro(reg, n);
            },
            // AstroNvim-style leader tree: <space>b Buffers…, <space>f Find…,
            // <space>l Language…, plus the flat <space>w/q/c leaves.
            .space_leader => {
                self.resetPending();
                if (k == .char) switch (k.char) {
                    'b' => self.await_arg = .space_buffer,
                    'f' => self.await_arg = .space_find,
                    'l' => self.await_arg = .space_lang,
                    'g' => self.await_arg = .space_git,
                    'u' => self.await_arg = .space_ui,
                    'n' => self.await_arg = .space_new,
                    'S' => self.await_arg = .space_session,
                    't' => self.openTerminal(), // AstroNvim's <leader>t
                    'd' => self.await_arg = .space_debug,
                    'e' => self.sidebarToggle(), // file explorer (AstroNvim <leader>e)
                    'x' => self.await_arg = .space_qf, // AstroNvim's <leader>x
                    'h' => self.showHome(), // AstroNvim's <leader>h
                    'w' => _ = try self.write(""),
                    'q' => self.doQuit(),
                    'c' => self.closeDoc(false), // close buffer (AstroNvim <leader>c)
                    else => {},
                };
            },
            .space_buffer => {
                self.resetPending();
                if (k == .char) switch (k.char) {
                    'b' => self.openBufferPicker(), // same picker as <space>f b
                    'n' => self.cycleDoc(true, 1), // next buffer (]b)
                    'p' => self.cycleDoc(false, 1), // previous buffer ([b)
                    'c' => self.closeOthers(), // AstroNvim's <leader>bc
                    else => {},
                };
            },
            .space_new => {
                self.resetPending();
                if (k == .char) switch (k.char) {
                    'b' => self.newBuffer(), // AstroNvim's <leader>n
                    'f' => self.enterNewEntry(false),
                    'd' => self.enterNewEntry(true),
                    else => {},
                };
            },
            .space_qf => {
                self.resetPending();
                if (k == .char) switch (k.char) {
                    'q' => self.qfOpen(), // :copen
                    'n' => self.qfStep(true, 1), // :cnext / ]q
                    'p' => self.qfStep(false, 1), // :cprev / [q
                    'c' => self.qfClose(), // :cclose
                    'e' => self.openMultibuffer(), // :cedit — the multibuffer
                    else => {},
                };
            },
            .space_debug => {
                self.resetPending();
                if (k == .char) switch (k.char) {
                    'b' => self.toggleBreakpoint(),
                    'B' => self.clearBreakpoints(),
                    'c' => self.debugContinue(),
                    'n' => self.debugStep(.over),
                    'i' => self.debugStep(.into),
                    'o' => self.debugStep(.out),
                    'q' => self.debugStop(),
                    else => {},
                };
            },
            .space_session => {
                self.resetPending();
                if (k == .char) switch (k.char) {
                    's' => self.sessionSave(),
                    'l' => self.sessionLoad(),
                    'd' => self.sessionDelete(),
                    else => {},
                };
            },
            .space_ui => {
                self.resetPending();
                if (k == .char) switch (k.char) {
                    'n' => self.toggleSetting(&config.settings.relative_numbers, "relative numbers"),
                    'w' => self.toggleSetting(&config.settings.soft_wrap, "soft wrap"),
                    'd' => self.toggleSetting(&config.settings.inline_diagnostics, "inline diagnostics"),
                    't' => self.toggleSetting(&config.settings.buffer_tabs, "buffer tabs"),
                    'i' => self.toggleSetting(&config.settings.autoindent, "autoindent"),
                    'c' => self.toggleSetting(&config.settings.auto_completion, "auto completion"),
                    'f' => self.toggleSetting(&config.settings.format_on_save, "format on save"),
                    'm' => self.toggleMouse(),
                    else => {},
                };
            },
            .space_find => {
                self.resetPending();
                if (k == .char) switch (k.char) {
                    'f' => self.openFilePicker(), // find files
                    'w' => self.openGrepPicker(), // find words
                    'b' => self.openBufferPicker(), // find buffers
                    't' => self.openThemePicker(), // find themes
                    'u' => self.openUndoPicker(), // the undo tree (:undolist)
                    'C' => self.openCommandPalette(), // AstroNvim's <leader>fC
                    else => {},
                };
            },
            .space_lang => {
                self.resetPending();
                if (k == .char) switch (k.char) {
                    'a' => self.lspCodeAction(), // code action
                    'r' => self.enterRename(), // rename symbol
                    'R' => self.lspReferences(), // search references
                    'S' => self.openWorkspaceSymbolPicker(), // project-wide symbols
                    'D' => self.openDiagnosticPicker(), // all diagnostics
                    's' => self.lspDocumentSymbol(), // document symbols
                    'd' => self.lineDiagnostic(), // show the line's diagnostic
                    'f' => self.lspFormat(), // format buffer
                    else => {},
                };
            },
            .space_git => {
                self.resetPending();
                if (k == .char) switch (k.char) {
                    'd' => self.gitDiffInline(), // unified diff in a split
                    's' => self.gitDiffSide(), // HEAD/index version side by side
                    'l' => self.gitDiffLine(), // old lines woven into the buffer's window
                    else => {},
                };
            },
            .surround_add_char => {
                defer self.resetPending();
                if (charByte(k)) |c| try self.surroundAdd(c) else self.surr_span = null;
            },
            .surround_delete => {
                defer self.resetPending();
                if (charByte(k)) |c| try self.surroundDelete(c);
            },
            .surround_change_from => {
                if (charByte(k)) |c| {
                    self.surr_from = c;
                    self.await_arg = .surround_change_to; // keep waiting for the new pair
                } else self.resetPending();
            },
            .surround_change_to => {
                defer self.resetPending();
                if (charByte(k)) |c| try self.surroundChange(self.surr_from, c);
            },
            .visual_object_inner, .visual_object_around => {
                // `a`, not `self.await_arg`: the pending key was cleared on
                // the way into this switch, so reading it back made every
                // visual "around" object behave like its "inner" twin.
                self.visualObject(a == .visual_object_around, k);
            },
            .none => {},
        }
    }

    // === operator pending ==================================================

    fn operatorPendingKey(self: *Editor, k: key.Key) !void {
        if (k == .char) {
            const c = k.char;
            if (c >= '1' and c <= '9' or (c == '0' and self.count2 > 0)) {
                self.count2 = self.count2 * 10 + (c - '0');
                return;
            }
            // Surround: ds / cs / ys (vim-surround). Intercept before motions.
            if (c == 's') switch (self.operator) {
                .delete => {
                    self.operator = .none;
                    self.await_arg = .surround_delete;
                    return;
                },
                .change => {
                    self.operator = .none;
                    self.await_arg = .surround_change_from;
                    return;
                },
                .yank => {
                    self.operator = .surround;
                    return;
                },
                .surround => { // yss: surround the whole line
                    const line = self.curLine();
                    self.beginSurroundAdd(.{ .lines = false, .start = .{ .row = self.cy, .col = 0 }, .end = .{ .row = self.cy, .col = line.len } });
                    return;
                },
                else => {},
            };
            // Doubled operator -> linewise over `total` lines (dd, yy, cc, >>, <<).
            if (self.isDoubled(c)) return self.applyLinewiseOperator();
            if (c == 'i') {
                self.await_arg = .object_inner;
                return;
            }
            if (c == 'a') {
                self.await_arg = .object_around;
                return;
            }
            // cw / cW behave like ce / cE.
            if (self.operator == .change and (c == 'w' or c == 'W'))
                return self.doMotion(self.repeatWord(.e, c == 'W'));
            return self.normalChar(c);
        }
        switch (k) {
            .left => self.doMotion(self.repeatMotion(.left)),
            .right => self.doMotion(self.repeatMotion(.right)),
            .up => self.doMotion(self.vertical(true, self.eff())),
            .down => self.doMotion(self.vertical(false, self.eff())),
            .escape => self.resetPending(),
            else => self.resetPending(),
        }
    }

    fn isDoubled(self: *Editor, c: u21) bool {
        return switch (self.operator) {
            .delete => c == 'd',
            .change => c == 'c',
            .yank => c == 'y',
            .indent_right => c == '>',
            .reindent => c == '=',
            .indent_left => c == '<',
            .comment => c == 'c', // gcc
            .fold => c == 'f', // zff folds this line's... nothing; vim has no zff
            .surround => false, // handled by the 's' intercept (yss)
            // `gUU`/`guu`/`g~~`. The `gUgU` spelling doubles in the `g`
            // prefix instead, where the second `g` has already been eaten.
            .upper => c == 'U',
            .lower => c == 'u',
            .toggle_case => c == '~',
            .rot13 => c == '?', // g?? — and g?g? doubles in the prefix
            .reflow => c == 'q', // gqq
            .reflow_keep => c == 'w', // gww
            .none => false,
        };
    }

    fn applyLinewiseOperator(self: *Editor) void {
        const n = self.eff();
        const top = self.cy;
        const bot = @min(self.cy + n - 1, self.buf.lineCount() - 1);
        self.applyOperator(self.operator, .{ .lines = true, .top = top, .bot = bot });
        self.resetPending();
    }

    fn applyTextObject(self: *Editor, around: bool, k: key.Key) !void {
        const op = self.operator;
        const c = charByte(k) orelse {
            self.resetPending();
            return;
        };
        const span = self.textObjectSpan(around, c) orelse {
            self.resetPending();
            return;
        };
        if (op == .surround) {
            self.beginSurroundAdd(span); // sets the next-key await
            return;
        }
        self.applyOperator(op, span);
        self.resetPending();
    }

    // === surround ==========================================================

    fn beginSurroundAdd(self: *Editor, span: Span) void {
        self.surr_span = span;
        self.count = 0;
        self.count2 = 0;
        self.operator = .none;
        self.pending_register = null;
        self.await_arg = .surround_add_char;
    }

    fn surroundAdd(self: *Editor, c: u8) !void {
        if (self.rejectReadOnly()) return;
        const span = self.surr_span orelse return;
        self.surr_span = null;
        const pair = surroundPair(c) orelse return;
        self.pushUndo();
        try self.buf.insertBytes(span.end.row, span.end.col, pair.close);
        try self.buf.insertBytes(span.start.row, span.start.col, pair.open);
        self.setCursor(span.start);
    }

    fn surroundDelete(self: *Editor, c: u8) !void {
        if (self.rejectReadOnly()) return;
        const sp = self.findSurroundSpan(c) orelse {
            self.setStatus("no surrounding pair", .{});
            return;
        };
        self.pushUndo();
        const close_len = unicode.decode(self.buf.line(sp.end.row)[sp.end.col..]).len;
        try self.buf.deleteInLine(sp.end.row, sp.end.col, sp.end.col + close_len);
        const open_len = unicode.decode(self.buf.line(sp.start.row)[sp.start.col..]).len;
        try self.buf.deleteInLine(sp.start.row, sp.start.col, sp.start.col + open_len);
        self.setCursor(sp.start);
    }

    fn surroundChange(self: *Editor, from: u8, to: u8) !void {
        if (self.rejectReadOnly()) return;
        const sp = self.findSurroundSpan(from) orelse {
            self.setStatus("no surrounding pair", .{});
            return;
        };
        const pair = surroundPair(to) orelse return;
        self.pushUndo();
        const close_len = unicode.decode(self.buf.line(sp.end.row)[sp.end.col..]).len;
        try self.buf.deleteInLine(sp.end.row, sp.end.col, sp.end.col + close_len);
        try self.buf.insertBytes(sp.end.row, sp.end.col, pair.close);
        const open_len = unicode.decode(self.buf.line(sp.start.row)[sp.start.col..]).len;
        try self.buf.deleteInLine(sp.start.row, sp.start.col, sp.start.col + open_len);
        try self.buf.insertBytes(sp.start.row, sp.start.col, pair.open);
        self.setCursor(sp.start);
    }

    /// The pair/quote object identified by `c` (inner, or around with the
    /// delimiters included).
    fn delimObject(self: *Editor, c: u8, around: bool) ?motion.Span {
        return switch (c) {
            '(', ')', 'b' => motion.objPair(self.buf, self.cursor(), '(', ')', around),
            '[', ']' => motion.objPair(self.buf, self.cursor(), '[', ']', around),
            '{', '}', 'B' => motion.objPair(self.buf, self.cursor(), '{', '}', around),
            '<', '>' => motion.objPair(self.buf, self.cursor(), '<', '>', around),
            '"' => motion.objQuote(self.buf, self.cursor(), '"', around),
            '\'' => motion.objQuote(self.buf, self.cursor(), '\'', around),
            '`' => motion.objQuote(self.buf, self.cursor(), '`', around),
            else => null,
        };
    }

    /// The around-span (delimiters inclusive) of the pair identified by `c`.
    fn findSurroundSpan(self: *Editor, c: u8) ?motion.Span {
        return self.delimObject(c, true);
    }

    fn textObjectSpan(self: *Editor, around: bool, c: u8) ?Span {
        if (c == 'f' or c == 'c') return self.treeObjectSpan(around, c == 'f');
        if (c == 'a') return self.treeListItemSpan(around);
        if (c == 'C') return self.treeCommentSpan(around);
        if (c == 't') { // tag block: charwise, ends already exclusive
            const o = motion.objTag(self.buf, self.cursor(), around) orelse return null;
            return .{ .lines = false, .start = o.start, .end = o.end };
        }
        if (c == 's') { // sentence: charwise, its end already exclusive
            const o = motion.objSentence(self.buf, self.cursor(), around) orelse return null;
            return .{ .lines = false, .start = o.start, .end = o.end };
        }
        if (c == 'p') { // paragraph: a linewise object (nvim-verified)
            const r = motion.paraObject(self.buf, self.cy, around, self.eff());
            return .{ .lines = true, .top = r.top, .bot = r.bot };
        }
        const obj: ?motion.Span = switch (c) {
            'w' => motion.objWord(self.buf, self.cursor(), false, around),
            'W' => motion.objWord(self.buf, self.cursor(), true, around),
            else => self.delimObject(c, around),
        };
        const o = obj orelse return null;
        const end_excl = if (o.empty) o.end else Pos{ .row = o.end.row, .col = unicode.nextBoundary(self.buf.line(o.end.row), o.end.col) };
        return .{ .lines = false, .start = o.start, .end = end_excl };
    }

    /// `af`/`if` (function) and `ac`/`ic` (class, struct, impl…) resolved from
    /// the syntax tree, so they follow the language's real structure rather
    /// than brace counting. Null when the language has no grammar or the
    /// cursor is not inside such a node — the caller then does nothing.
    fn treeObjectSpan(self: *Editor, around: bool, want_fn: bool) ?Span {
        var h = if (self.ts) |*x| x else return null;
        const kinds = if (want_fn) functionKinds(self.lang) else typeKinds(self.lang);
        if (kinds.len == 0) return null;
        const at = self.byteOffset(self.cy, self.cx) orelse return null;
        const span = h.enclosing(at, kinds, !around) orelse return null;
        const start = self.posOfByte(span.start) orelse return null;
        const end = self.posOfByte(span.end) orelse return null;
        return .{ .lines = false, .start = start, .end = end };
    }

    /// `ia`/`aa`: the argument or parameter under the cursor, from the syntax
    /// tree. `aa` takes the comma that joins it to a neighbour so the list
    /// stays valid.
    fn treeListItemSpan(self: *Editor, around: bool) ?Span {
        var h = if (self.ts) |*x| x else return null;
        const kinds = listKinds(self.lang);
        if (kinds.len == 0) return null;
        const at = self.byteOffset(self.cy, self.cx) orelse return null;
        const span = h.listItem(at, kinds, around) orelse return null;
        return .{
            .lines = false,
            .start = self.posOfByte(span.start) orelse return null,
            .end = self.posOfByte(span.end) orelse return null,
        };
    }

    /// `iC`/`aC`: the comment under the cursor. `iC` is its text with the
    /// delimiters stripped; `aC` is the whole thing, extended over a run of
    /// comment lines, and linewise when the comment owns its lines (so `daC`
    /// removes them rather than leaving blanks behind).
    fn treeCommentSpan(self: *Editor, around: bool) ?Span {
        var h = if (self.ts) |*x| x else return null;
        const kinds = commentKinds(self.lang);
        if (kinds.len == 0) return null;
        const at = self.byteOffset(self.cy, self.cx) orelse return null;
        const span = h.commentSpan(at, kinds, around) orelse return null;
        var start = self.posOfByte(span.start) orelse return null;
        var end = self.posOfByte(span.end) orelse return null;
        if (around) {
            const before = self.buf.line(start.row)[0..start.col];
            const own_line = std.mem.trim(u8, before, " \t").len == 0;
            if (own_line) return .{ .lines = true, .top = start.row, .bot = end.row };
            // A trailing comment: take the whitespace separating it from the
            // code as well, so `daC` does not leave the line padded.
            start.col = std.mem.trimEnd(u8, before, " \t").len;
            return .{ .lines = false, .start = start, .end = end };
        }
        // Inner: drop the delimiter and the space that conventionally follows.
        const head = self.buf.line(start.row);
        while (start.col < head.len and std.mem.indexOfScalar(u8, "/#-;*!<", head[start.col]) != null) start.col += 1;
        while (start.col < head.len and (head[start.col] == ' ' or head[start.col] == '\t')) start.col += 1;
        const tail = self.buf.line(end.row)[0..end.col];
        if (std.mem.endsWith(u8, tail, "*/")) end.col -= 2;
        end.col = std.mem.trimEnd(u8, self.buf.line(end.row)[0..end.col], " \t").len;
        if (end.row == start.row and end.col < start.col) end.col = start.col;
        return .{ .lines = false, .start = start, .end = end };
    }

    /// `]f` / `[f`: jump to the next or previous function in the file.
    fn gotoFunction(self: *Editor, forward: bool) void {
        var h = if (self.ts) |*x| x else return self.setStatus("no syntax tree for this file", .{});
        const kinds = functionKinds(self.lang);
        if (kinds.len == 0) return self.setStatus("no functions known for this filetype", .{});
        var at = self.byteOffset(self.cy, self.cx) orelse return;
        var n = self.eff();
        while (n > 0) : (n -= 1) {
            const next = h.seekNode(at, kinds, forward) orelse break;
            at = next;
        }
        const p = self.posOfByte(at) orelse return;
        self.addJump();
        self.cy = @min(p.row, self.buf.lineCount() - 1);
        self.cx = @min(p.col, self.curLine().len);
        self.updateGoal();
    }

    /// Document byte offset of (row, col), using the line table tree-sitter
    /// already maintains.
    fn byteOffset(self: *Editor, row: usize, col: usize) ?usize {
        if (row >= self.ts_line_starts.items.len) return null;
        return self.ts_line_starts.items[row] + col;
    }

    /// The inverse: which (row, col) a document byte offset lands on.
    fn posOfByte(self: *Editor, byte: usize) ?Pos {
        const starts = self.ts_line_starts.items;
        if (starts.len == 0) return null;
        var lo: usize = 0;
        var hi: usize = starts.len - 1;
        while (lo < hi) { // binary search: the last line starting at or before `byte`
            const mid = (lo + hi + 1) / 2;
            if (starts[mid] <= byte) lo = mid else hi = mid - 1;
        }
        const line = self.buf.line(lo);
        return .{ .row = lo, .col = @min(byte - starts[lo], line.len) };
    }

    // === motions ===========================================================

    const WordKind = enum { f, b, e };

    fn doMotion(self: *Editor, res: MotionResult) void {
        if (self.operator != .none) {
            const span = self.buildSpan(res);
            if (self.operator == .surround) {
                self.beginSurroundAdd(span);
                return;
            }
            self.applyOperator(self.operator, span);
            self.resetPending();
            return;
        }
        switch (res.col_mode) {
            .exact => {
                self.cy = @min(res.pos.row, self.buf.lineCount() - 1);
                self.cx = res.pos.col;
                self.updateGoal();
            },
            .keep_goal => {
                self.cy = @min(res.pos.row, self.buf.lineCount() - 1);
                self.cx = byteAtDisplayCol(self.curLine(), self.goal_col);
            },
            .first_non_blank => {
                self.cy = @min(res.pos.row, self.buf.lineCount() - 1);
                self.cx = motion.firstNonBlank(self.curLine());
                self.updateGoal();
            },
        }
        self.resetPending();
    }

    fn buildSpan(self: *Editor, res: MotionResult) Span {
        const cur = self.cursor();
        if (res.kind == .linewise) {
            return .{ .lines = true, .top = @min(cur.row, res.pos.row), .bot = @max(cur.row, res.pos.row) };
        }
        var start = cur;
        var end = res.pos;
        if (cmpPos(end, start) < 0) {
            start = res.pos;
            end = cur;
        }
        if (res.kind == .inclusive) {
            end = .{ .row = end.row, .col = unicode.nextBoundary(self.buf.line(end.row), end.col) };
        }
        if (res.kind == .exclusive and end.col == 0 and end.row > start.row) {
            // vim's exclusive rules (:h exclusive, nvim-verified for `d}`): an
            // exclusive motion ending in column 0 stops at the end of the
            // previous line instead — and becomes linewise when the start was
            // at or before its line's first non-blank.
            // `end.row - 1` is bound first: `end = .{ ... }` writes through a
            // result location that *is* `end`, so `.row` lands in `end.row`
            // before `.col` is evaluated — reading `end.row - 1` there gave
            // the line before the one wanted (a wrong-length span), and
            // underflowed outright when the end sat on line 1.
            const prev = end.row - 1;
            end = .{ .row = prev, .col = self.buf.line(prev).len };
            if (start.col <= motion.firstNonBlank(self.buf.line(start.row))) {
                return .{ .lines = true, .top = start.row, .bot = end.row };
            }
        }
        return .{ .lines = false, .start = start, .end = end };
    }

    fn repeatMotion(self: *Editor, comptime which: enum { left, right }) MotionResult {
        var p = self.cursor();
        var i: usize = 0;
        const n = self.eff();
        while (i < n) : (i += 1) {
            const line = self.buf.line(p.row);
            p.col = switch (which) {
                .left => unicode.prevBoundary(line, p.col),
                .right => if (p.col < line.len) unicode.nextBoundary(line, p.col) else p.col,
            };
        }
        return .{ .pos = p, .kind = .exclusive, .col_mode = .exact };
    }

    fn vertical(self: *Editor, up: bool, n: usize) MotionResult {
        const last = self.buf.lineCount() - 1;
        var row = self.cy;
        if (self.d.folds.len() == 0) {
            row = if (up) (if (self.cy > n) self.cy - n else 0) else @min(self.cy + n, last);
        } else {
            // A closed fold is one line to `j`/`k`: stepping onto it lands on
            // its header, and stepping off it starts from the line after its
            // end — otherwise `j` would take `end - start` presses to escape
            // something drawn as a single row.
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const f = self.d.folds.closedAt(row);
                if (up) {
                    const from = if (f) |x| x.start else row;
                    if (from == 0) break;
                    row = self.d.folds.prevVisible(from - 1);
                } else {
                    const from = if (f) |x| x.end else row;
                    if (from >= last) break;
                    row = self.d.folds.nextVisible(from + 1, last);
                }
            }
        }
        if (row == self.cy and n > 0) self.failed = true; // no line to move to
        return .{ .pos = .{ .row = row, .col = 0 }, .kind = .linewise, .col_mode = .keep_goal };
    }

    /// Whether `j`/`k` should walk screen rows: soft wrap is on, the cursor is
    /// on a line that actually fills more than one row, and no operator is
    /// pending.
    ///
    /// The gate is the *current* line rather than "wrap is on", because on a
    /// line that occupies one row the two are the same movement — except that
    /// `screenVertical` is charwise and exact, so it would quietly drop the
    /// goal column that `k` after a click past a short line's end depends on.
    /// Narrowing it to lines that really wrap fixes what the wrapped view got
    /// wrong without touching everything else.
    ///
    /// An operator keeps the linewise form: `dj` must take two whole lines,
    /// not a screen row's worth of characters.
    fn wrappedHere(self: *Editor) bool {
        if (self.operator != .none or !self.wrapping()) return false;
        if (self.textCols() == 0) return false;
        return self.lineLayout(self.cy).n > 1;
    }

    /// `gj` / `gk`: down or up one *screen* row, keeping the column within the
    /// row — so a wrapped line is walked a row at a time instead of skipped
    /// whole. On a line that does not wrap (or with soft wrap off) they are
    /// exactly `j` and `k`.
    fn screenVertical(self: *Editor, up: bool, n: usize) MotionResult {
        const cols = self.textCols();
        if (!self.wrapping() or cols == 0) return self.vertical(up, n);
        var row = self.cy;
        var wl = self.lineLayout(row);
        const here = wl.place(self.cursorDisplayCol());
        var seg = here.seg;
        // The column *on the row*, indent included: what vim keeps as you walk
        // screen lines, so the caret stays under itself.
        const screen_col = here.col;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (up) {
                if (seg > 0) {
                    seg -= 1;
                } else {
                    if (row == 0) break;
                    // A closed fold is one row here too: land on its header
                    // rather than inside something that is not drawn.
                    row = self.d.folds.prevVisible(row - 1);
                    wl = self.lineLayout(row);
                    seg = wl.n - 1;
                }
            } else {
                if (seg + 1 < wl.n) {
                    seg += 1;
                } else {
                    const last = self.buf.lineCount() - 1;
                    const from = if (self.d.folds.closedAt(row)) |f| f.end else row;
                    if (from >= last) break;
                    row = self.d.folds.nextVisible(from + 1, last);
                    wl = self.lineLayout(row);
                    seg = 0;
                }
            }
        }
        const target = wl.starts[seg] + (screen_col -| wl.pad(seg));
        // Nowhere to go is a *failed* motion, which is what stops a macro
        // replay at the end of the buffer — `vertical` has always reported it
        // and `j`/`k` now come through here.
        if (row == self.cy and seg == here.seg and n > 0) self.failed = true;
        return .{
            .pos = .{ .row = row, .col = byteAtDisplayCol(self.buf.line(row), target) },
            .kind = .exclusive,
            .col_mode = .exact,
        };
    }

    /// `g0` / `g$`: the first or last character of the screen row.
    fn screenLineEdge(self: *Editor, end: bool) MotionResult {
        const cols = self.textCols();
        const line = self.curLine();
        if (!self.wrapping() or cols == 0)
            return .{ .pos = .{ .row = self.cy, .col = if (end) line.len else 0 }, .kind = if (end) .inclusive else .exclusive, .col_mode = .exact };
        const wl = self.lineLayout(self.cy);
        const seg = wl.place(self.cursorDisplayCol()).seg;
        const target = if (end)
            (if (seg + 1 < wl.n) wl.starts[seg + 1] - 1 else displayCol(line, line.len))
        else
            wl.starts[seg];
        return .{
            .pos = .{ .row = self.cy, .col = @min(byteAtDisplayCol(line, target), line.len) },
            .kind = if (end) .inclusive else .exclusive,
            .col_mode = .exact,
        };
    }

    fn endOfLineMotion(self: *Editor) MotionResult {
        var row = self.cy;
        const extra = self.eff();
        if (extra > 1) row = @min(self.cy + extra - 1, self.buf.lineCount() - 1);
        return .{ .pos = .{ .row = row, .col = self.buf.line(row).len }, .kind = .inclusive, .col_mode = .exact };
    }

    /// `{` / `}`: to the previous/next paragraph boundary (empty line),
    /// exclusive. At the buffer edges vim lands on the first/last line — the
    /// end lands past the last character for operators (`d}` eats the line),
    /// on it for plain movement.
    fn paragraphMotion(self: *Editor, forward: bool) MotionResult {
        if (self.operator == .none) self.addJump();
        var row = self.cy;
        var hit_edge = false;
        var n = self.eff();
        while (n > 0) : (n -= 1) {
            const next = if (forward) motion.paraForward(self.buf, row) else motion.paraBackward(self.buf, row);
            if (next) |r| {
                row = r;
            } else {
                row = if (forward) self.buf.lineCount() - 1 else 0;
                hit_edge = true;
                break;
            }
        }
        var col: usize = 0;
        if (forward and hit_edge) {
            const line = self.buf.line(row);
            col = if (self.operator == .none) lastColumn(line) else line.len;
        }
        return .{ .pos = .{ .row = row, .col = col }, .kind = .exclusive, .col_mode = .exact };
    }

    /// `(` / `)` — the start of the previous/next sentence. Exclusive and
    /// charwise, and not a jump motion (vim does not record these).
    fn sentenceMotion(self: *Editor, forward: bool) MotionResult {
        var p = self.cursor();
        var i: usize = 0;
        const n = self.eff();
        while (i < n) : (i += 1) {
            const next = if (forward) motion.sentenceForward(self.buf, p) else motion.sentenceBackward(self.buf, p);
            if (next.row == p.row and next.col == p.col) break; // nowhere left to go
            p = next;
        }
        return .{ .pos = p, .kind = .exclusive, .col_mode = .exact };
    }

    fn gotoLineMotion(self: *Editor, row: usize) MotionResult {
        if (self.operator == .none) self.addJump(); // jump-motion, not an operator target
        // The column is kept, not reset to the first non-blank: nvim's
        // 'startofline' is off by default, so `G`, `gg`, `{n}G`, `H`, `M` and
        // `L` all land in the same screen column they left (clamped to the
        // new line). vim's default is the other way; this follows nvim,
        // which is what the whole keymap is pinned to.
        return .{ .pos = .{ .row = @min(row, self.buf.lineCount() - 1), .col = 0 }, .kind = .linewise, .col_mode = .keep_goal };
    }

    /// `ge` / `gE`, counted. Inclusive, like `e` — `dge` takes the character
    /// it lands on.
    fn repeatEndBackward(self: *Editor, big: bool) MotionResult {
        var p = self.cursor();
        var i: usize = 0;
        const n = self.eff();
        while (i < n) : (i += 1) p = motion.wordEndBackward(self.buf, p, big);
        return .{ .pos = p, .kind = .inclusive, .col_mode = .exact };
    }

    fn repeatWord(self: *Editor, which: WordKind, big: bool) MotionResult {
        var p = self.cursor();
        var prev = p;
        var i: usize = 0;
        const n = if (self.operator != .none) self.eff() else self.eff();
        while (i < n) : (i += 1) {
            prev = p;
            p = switch (which) {
                .f => motion.wordForward(self.buf, p, big),
                .b => motion.wordBackward(self.buf, p, big),
                .e => motion.wordEnd(self.buf, p, big),
            };
        }
        // Vim's operator+w special case (:help word-motions): when the last
        // word moved over sits at the end of a line, the operated text ends at
        // that line's end instead of crossing to the next line — so `dw` on the
        // line's last word never joins. Starting on a blank tail or an empty
        // line is not "moving over a word", and does cross (vim joins there).
        if (which == .f and self.operator != .none and p.row > prev.row) {
            const pl = self.buf.line(prev.row);
            const has_word = std.mem.indexOfNone(u8, pl[@min(prev.col, pl.len)..], " \t") != null;
            if (has_word) p = .{ .row = prev.row, .col = pl.len };
        }
        return .{ .pos = p, .kind = if (which == .e) .inclusive else .exclusive, .col_mode = .exact };
    }

    fn applyFind(self: *Editor, kind: Await, ch: u21) void {
        const line = self.curLine();
        const forward = kind == .find_f or kind == .find_t;
        const till = kind == .find_t or kind == .find_cap_t;
        // vim counts occurrences, not hops: `3fa` lands on the third `a` and
        // the whole motion fails (the cursor does not move) when there are
        // fewer than three. `t` counts the same occurrences and only then
        // steps back one, so the intermediate searches must not be
        // till-adjusted or they would stall on the character before each hit.
        var col = self.cx;
        var n = self.eff(); // vim multiplies `2d3fa`: count before × after
        while (n > 0) : (n -= 1) {
            col = motion.findChar(line, col, ch, forward, false) orelse {
                self.failed = true; // vim's find fails outright, count and all
                return self.resetPending();
            };
        }
        if (till) col = if (forward) unicode.prevBoundary(line, col) else unicode.nextBoundary(line, col);
        const inclusive = forward; // forward find/till is inclusive; backward is exclusive
        self.doMotion(.{ .pos = .{ .row = self.cy, .col = col }, .kind = if (inclusive) .inclusive else .exclusive, .col_mode = .exact });
    }

    fn repeatFind(self: *Editor, reverse: bool) void {
        const f = self.last_find orelse {
            self.resetPending();
            return;
        };
        var kind = f.kind;
        if (reverse) kind = switch (f.kind) {
            .find_f => .find_cap_f,
            .find_cap_f => .find_f,
            .find_t => .find_cap_t,
            .find_cap_t => .find_t,
            else => f.kind,
        };
        self.applyFind(kind, f.ch);
    }

    // === operator application ==============================================

    fn applyOperator(self: *Editor, op: Operator, span: Span) void {
        // `y` and `zf` only look at the text, so a read-only buffer allows
        // both — folding a diff view to read it is entirely reasonable.
        if (op != .yank and op != .fold and self.rejectReadOnly()) return;
        switch (op) {
            .indent_right => return self.indent(span, true),
            .indent_left => return self.indent(span, false),
            .reindent => return self.reindent(span),
            .comment => return self.toggleComment(span),
            // A fold covers whole lines whatever the motion was, like `>`.
            .fold => return self.foldCreate(span.top, span.bot),
            .upper => return self.applyCase(span, .upper),
            .lower => return self.applyCase(span, .lower),
            .toggle_case => return self.applyCase(span, .toggle),
            .rot13 => return self.applyRot13(span),
            .reflow => return self.reflow(span, false),
            .reflow_keep => return self.reflow(span, true),
            else => {},
        }
        const text = self.extract(span) catch return;
        defer self.gpa.free(text);
        self.yankTo(text, if (span.lines) .linewise else .charwise, 0);

        if (op == .yank) {
            if (span.lines) {
                self.cy = @min(span.top, self.buf.lineCount() - 1);
                // `yy`/`yj` keep the column; a *visual* linewise yank sends
                // the cursor to column 0 unless it was already the top end of
                // the selection (nvim, probed: `Vy` and `Vjy` give column 0,
                // `Vky` and `Vjoy` keep it).
                if (self.yank_from_visual and !self.yank_cursor_was_top) {
                    self.cx = 0;
                    self.goal_col = 0;
                } else self.clampCursor();
            } else {
                self.setCursor(span.start);
            }
            return;
        }

        self.pushUndo();
        if (op == .change and span.lines) {
            // The replacement line follows the one above it.
            const ref: ?usize = if (span.top > 0) span.top - 1 else null;
            self.setAutoIndentFollowing(span.top, ref, span.top, null);
            self.buf.setLine(span.top, self.ai_indent.items) catch {};
            var i: usize = 0;
            while (i < span.bot - span.top) : (i += 1) self.buf.removeLineAt(span.top + 1);
            self.cy = span.top;
            self.cx = self.buf.line(span.top).len;
            self.goal_col = 0;
            self.mode = .insert;
            return;
        }
        const cur = self.deleteSpan(span);
        self.setCursor(cur);
        if (op == .change) self.mode = .insert;
    }

    fn extract(self: *Editor, span: Span) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        if (span.lines) {
            var r = span.top;
            while (r <= span.bot) : (r += 1) {
                try out.appendSlice(self.gpa, self.buf.line(r));
                try out.append(self.gpa, '\n');
            }
        } else if (span.start.row == span.end.row) {
            try out.appendSlice(self.gpa, self.buf.line(span.start.row)[span.start.col..span.end.col]);
        } else {
            try out.appendSlice(self.gpa, self.buf.line(span.start.row)[span.start.col..]);
            try out.append(self.gpa, '\n');
            var r = span.start.row + 1;
            while (r < span.end.row) : (r += 1) {
                try out.appendSlice(self.gpa, self.buf.line(r));
                try out.append(self.gpa, '\n');
            }
            try out.appendSlice(self.gpa, self.buf.line(span.end.row)[0..span.end.col]);
        }
        return out.toOwnedSlice(self.gpa);
    }

    /// Remove `span` from the buffer; returns where the cursor should land.
    fn deleteSpan(self: *Editor, span: Span) Pos {
        if (span.lines) {
            var i: usize = 0;
            const count = span.bot - span.top + 1;
            while (i < count) : (i += 1) self.buf.removeLineAt(span.top);
            const row = @min(span.top, self.buf.lineCount() - 1);
            // Same 'startofline' rule: the cursor keeps its screen column on
            // whatever line moved up into its place.
            return .{ .row = row, .col = byteAtDisplayCol(self.buf.line(row), self.goal_col) };
        }
        if (span.start.row == span.end.row) {
            self.buf.deleteInLine(span.start.row, span.start.col, span.end.col) catch {};
            return span.start;
        }
        // Multi-line charwise: keep head of start line + tail of end line, drop the middle.
        const tail = self.gpa.dupe(u8, self.buf.line(span.end.row)[span.end.col..]) catch return span.start;
        defer self.gpa.free(tail);
        self.buf.deleteInLine(span.start.row, span.start.col, self.buf.line(span.start.row).len) catch {};
        self.buf.insertBytes(span.start.row, span.start.col, tail) catch {};
        var i: usize = 0;
        const removals = span.end.row - span.start.row;
        while (i < removals) : (i += 1) self.buf.removeLineAt(span.start.row + 1);
        return span.start;
    }

    /// `=` — give every line in the span the indent it should have, rather
    /// than shifting what is there. Each line follows the previous non-blank
    /// one, plus a level for every block that line opens (the grammar's
    /// `indents.scm`, the same query autoindent uses), minus a level when this
    /// line *closes* one. That last part is why `=` needs code of its own: the
    /// indent engine only ever answers "what follows this line", and a `}` has
    /// to come back out.
    ///
    /// Lines are done top-down so each sees the one above it already fixed,
    /// which is what lets a whole nested block settle in one pass.
    fn reindent(self: *Editor, span: Span) void {
        if (self.rejectReadOnly()) return;
        const top = if (span.lines) span.top else @min(span.start.row, span.end.row);
        const bot = @min(if (span.lines) span.bot else @max(span.start.row, span.end.row), self.buf.lineCount() - 1);
        self.pushUndo();
        var r = top;
        while (r <= bot) : (r += 1) {
            const line = self.buf.line(r);
            if (lineIsBlank(line)) continue; // vim leaves a blank line blank
            // The reference is the nearest non-blank line above.
            var ref: ?usize = null;
            var i = r;
            while (i > 0) {
                i -= 1;
                if (!lineIsBlank(self.buf.line(i))) {
                    ref = i;
                    break;
                }
            }
            self.setAutoIndentFollowing(r, ref, r, null);
            const body = line[leadingIndent(line).len..];
            // A line that starts by closing a block sits one level out from
            // what follows its opener.
            if (body.len > 0 and (body[0] == '}' or body[0] == ')' or body[0] == ']')) {
                const unit = self.indentUnit(self.ai_indent.items);
                if (self.ai_indent.items.len >= unit.len)
                    self.ai_indent.shrinkRetainingCapacity(self.ai_indent.items.len - unit.len);
            }
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.gpa);
            out.appendSlice(self.gpa, self.ai_indent.items) catch continue;
            out.appendSlice(self.gpa, body) catch continue;
            if (!std.mem.eql(u8, out.items, line)) self.buf.setLine(r, out.items) catch {};
        }
        self.cy = @min(top, self.buf.lineCount() - 1);
        self.cx = motion.firstNonBlank(self.curLine());
        self.updateGoal();
    }

    fn indent(self: *Editor, span: Span, right: bool) void {
        const top = if (span.lines) span.top else @min(span.start.row, span.end.row);
        const bot = if (span.lines) span.bot else @max(span.start.row, span.end.row);
        self.pushUndo();
        var r = top;
        while (r <= bot) : (r += 1) {
            const line = self.buf.line(r);
            if (right) {
                if (line.len > 0) self.buf.insertBytes(r, 0, "    ") catch {};
            } else {
                var rm: usize = 0;
                while (rm < tabWidth() and rm < line.len and line[rm] == ' ') rm += 1;
                if (rm > 0) self.buf.deleteInLine(r, 0, rm) catch {};
            }
        }
        self.cy = top;
        self.cx = motion.firstNonBlank(self.curLine());
        self.updateGoal();
        self.resetPending();
    }

    fn toggleComment(self: *Editor, span: Span) void {
        const top = if (span.lines) span.top else @min(span.start.row, span.end.row);
        const bot = if (span.lines) span.bot else @max(span.start.row, span.end.row);
        const leader = self.commentLeader();
        self.pushUndo();

        // Comment unless every non-blank line in the range is already commented.
        var all_commented = true;
        var any = false;
        var r = top;
        while (r <= bot) : (r += 1) {
            const line = self.buf.line(r);
            const fnb = motion.firstNonBlank(line);
            if (fnb >= line.len) continue; // blank line: ignore
            any = true;
            if (!std.mem.startsWith(u8, line[fnb..], leader)) all_commented = false;
        }
        const uncomment = any and all_commented;

        r = top;
        while (r <= bot) : (r += 1) {
            const line = self.buf.line(r);
            const fnb = motion.firstNonBlank(line);
            if (fnb >= line.len) continue;
            if (uncomment) {
                var rm = leader.len;
                // Also remove the single space many leaders carry, if present.
                if (fnb + rm < line.len and line[fnb + rm] == ' ') rm += 1;
                self.buf.deleteInLine(r, fnb, fnb + rm) catch {};
            } else {
                self.buf.insertBytes(r, fnb, leader) catch {};
            }
        }
        self.cy = top;
        self.cx = motion.firstNonBlank(self.curLine());
        self.updateGoal();
        self.resetPending();
    }

    fn commentLeader(self: *Editor) []const u8 {
        return switch (self.lang) {
            .python => "# ",
            else => "// ",
        };
    }

    // === immediate edits ===================================================

    fn deleteChars(self: *Editor, n: usize, forward: bool) !void {
        if (self.rejectReadOnly()) return;
        const line = self.curLine();
        if (forward) {
            if (self.cx >= line.len) {
                self.resetPending();
                return;
            }
            var end = self.cx;
            var i: usize = 0;
            while (i < n and end < line.len) : (i += 1) end = unicode.nextBoundary(line, end);
            const span: Span = .{ .lines = false, .start = .{ .row = self.cy, .col = self.cx }, .end = .{ .row = self.cy, .col = end } };
            try self.charwiseDelete(span);
        } else {
            if (self.cx == 0) {
                self.resetPending();
                return;
            }
            var start = self.cx;
            var i: usize = 0;
            while (i < n and start > 0) : (i += 1) start = unicode.prevBoundary(line, start);
            const span: Span = .{ .lines = false, .start = .{ .row = self.cy, .col = start }, .end = .{ .row = self.cy, .col = self.cx } };
            try self.charwiseDelete(span);
        }
        self.resetPending();
    }

    fn charwiseDelete(self: *Editor, span: Span) !void {
        const text = try self.extract(span);
        defer self.gpa.free(text);
        self.yankTo(text, .charwise, 0);
        self.pushUndo();
        self.setCursor(self.deleteSpan(span));
    }

    fn changeToLineEnd(self: *Editor, change: bool) !void {
        if (self.rejectReadOnly()) return;
        const line = self.curLine();
        const span: Span = .{ .lines = false, .start = .{ .row = self.cy, .col = self.cx }, .end = .{ .row = self.cy, .col = line.len } };
        try self.charwiseDelete(span);
        if (change) self.mode = .insert;
        self.resetPending();
    }

    fn yankLines(self: *Editor, n: usize) !void {
        const bot = @min(self.cy + n - 1, self.buf.lineCount() - 1);
        self.applyOperator(.yank, .{ .lines = true, .top = self.cy, .bot = bot });
        self.resetPending();
    }

    fn changeLines(self: *Editor, n: usize) !void {
        const bot = @min(self.cy + n - 1, self.buf.lineCount() - 1);
        self.applyOperator(.change, .{ .lines = true, .top = self.cy, .bot = bot });
        self.resetPending();
    }

    fn substituteChars(self: *Editor, n: usize) !void {
        if (self.rejectReadOnly()) return;
        try self.deleteChars(n, true);
        self.mode = .insert;
    }

    fn replaceChars(self: *Editor, k: key.Key) !void {
        if (self.rejectReadOnly()) return;
        defer self.resetPending();
        const ch = charOf(k) orelse return;
        const n = self.eff();
        // Need n codepoints available from the cursor.
        var avail: usize = 0;
        var p = self.cx;
        const line0 = self.curLine();
        while (p < line0.len) : (avail += 1) p = unicode.nextBoundary(line0, p);
        if (avail < n) return;

        self.pushUndo();
        var enc: [4]u8 = undefined;
        const m = std.unicode.utf8Encode(ch, &enc) catch return;
        var pos = self.cx;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const line = self.curLine();
            const d = unicode.decode(line[pos..]);
            self.buf.deleteInLine(self.cy, pos, pos + d.len) catch {};
            self.buf.insertBytes(self.cy, pos, enc[0..m]) catch {};
            if (i + 1 < n) pos += m;
        }
        self.cx = pos;
        self.updateGoal();
    }

    fn toggleCase(self: *Editor, n: usize) !void {
        if (self.rejectReadOnly()) return;
        self.pushUndo();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const line = self.curLine();
            if (self.cx >= line.len) break;
            const d = unicode.decode(line[self.cx..]);
            const swapped = toggleAscii(d.cp);
            if (swapped != d.cp) {
                var enc: [4]u8 = undefined;
                const m = std.unicode.utf8Encode(swapped, &enc) catch d.len;
                self.buf.deleteInLine(self.cy, self.cx, self.cx + d.len) catch {};
                self.buf.insertBytes(self.cy, self.cx, enc[0..m]) catch {};
            }
            const cur = self.curLine();
            if (self.cx < cur.len) self.cx = unicode.nextBoundary(cur, self.cx);
        }
        self.updateGoal();
        self.resetPending();
    }

    /// `J` (`space = true`) and `gJ` (`space = false`). vim's `gJ` is the
    /// literal join: it neither strips the next line's indent nor inserts a
    /// separator, so `abc` + `    def` becomes `abc    def` where `J` gives
    /// `abc def`. Both leave the cursor at the seam (nvim-pinned).
    fn joinLines(self: *Editor, count: usize, space: bool) !void {
        if (self.rejectReadOnly()) return;
        const joins = if (count > 1) count - 1 else 1;
        self.pushUndo();
        var i: usize = 0;
        while (i < joins) : (i += 1) {
            if (self.cy + 1 >= self.buf.lineCount()) break;
            const cur = self.buf.line(self.cy);
            const cur_len = cur.len;
            const ends_blank = cur_len > 0 and (cur[cur_len - 1] == ' ' or cur[cur_len - 1] == '\t');
            const next = self.gpa.dupe(u8, self.buf.line(self.cy + 1)) catch break;
            defer self.gpa.free(next);
            const rest = if (space) std.mem.trimStart(u8, next, " \t") else next;
            self.buf.removeLineAt(self.cy + 1);
            // vim adds exactly one space, and not at all where there is
            // already trailing white space, where the first line is empty,
            // or where the next line opens with `)` (all nvim-probed).
            const need_space = space and cur_len > 0 and rest.len > 0 and
                !ends_blank and rest[0] != ')';
            self.cx = cur_len;
            if (need_space) {
                self.buf.insertBytes(self.cy, cur_len, " ") catch {};
                self.buf.insertBytes(self.cy, cur_len + 1, rest) catch {};
            } else {
                self.buf.insertBytes(self.cy, cur_len, rest) catch {};
            }
        }
        self.updateGoal();
        self.resetPending();
    }

    fn paste(self: *Editor, after: bool, cursor_after: bool) !void {
        if (self.rejectReadOnly()) return;
        const reg = self.registers.get(self.pending_register) orelse {
            self.resetPending();
            return;
        };
        const n = self.eff();
        self.pushUndo();
        if (reg.kind == .blockwise) {
            self.pasteBlock(reg, after, n);
        } else if (reg.kind == .linewise) {
            var at = if (after) self.cy + 1 else self.cy;
            const first = at;
            var rep: usize = 0;
            while (rep < n) : (rep += 1) {
                var it = std.mem.splitScalar(u8, trimTrailingNewline(reg.text), '\n');
                while (it.next()) |ln| {
                    self.buf.insertLineAt(at, ln) catch {};
                    at += 1;
                }
            }
            // `p` lands on the first pasted line; `gp` on the line after
            // the last, which is what makes repeated `gp` stack pastes.
            self.cy = @min(if (cursor_after) at else first, self.buf.lineCount() - 1);
            self.cx = motion.firstNonBlank(self.curLine());
            self.goal_col = 0;
        } else {
            const line = self.curLine();
            const col = if (after and line.len > 0) unicode.nextBoundary(line, self.cx) else self.cx;
            var rep: usize = 0;
            var insert_col = col;
            while (rep < n) : (rep += 1) {
                insert_col = self.spliceCharwise(reg.text, insert_col);
            }
            // `p` leaves the cursor on the last pasted character, `gp` one
            // past it.
            if (cursor_after)
                self.cx = @min(insert_col, self.curLine().len)
            else if (insert_col > col)
                self.cx = unicode.prevBoundary(self.curLine(), insert_col)
            else
                self.cx = col;
            self.updateGoal();
        }
        self.resetPending();
    }

    /// Blockwise paste: the register's lines go back in as a rectangle — one
    /// register line per buffer line, all starting at the same *display*
    /// column, the buffer growing new lines when the block outlasts it.
    /// Every rule below is nvim-pinned (see `vim_compat`'s nvim#bp cases):
    ///
    ///   * the column is the cursor's for `P` and the cell after it for `p`,
    ///     except on an empty line, where both are column 0;
    ///   * a line too short to reach that column is padded with spaces (in
    ///     display columns, so a tab counts for `tab_width`), which is why a
    ///     paste past the end of a short line leaves trailing whitespace;
    ///   * a register line is padded out to the block's width only when
    ///     something follows it on that line — either the line's own tail or a
    ///     further repetition of a count — so `3p` squares the block up but a
    ///     paste at end-of-line stays ragged;
    ///   * the cursor lands on the first cell of the pasted rectangle.
    /// Replace the tab covering display column `dcol` on `row` with the spaces
    /// it was drawing, so an edit can land in the middle of it. A no-op when
    /// no tab straddles the column — which is every ordinary line.
    fn splitTabAt(self: *Editor, row: usize, dcol: usize) void {
        const line = self.buf.line(row);
        var i: usize = 0;
        var w: usize = 0;
        while (i < line.len) {
            const d = unicode.decode(line[i..]);
            const cw = if (line[i] == '\t') config.settings.tab_width - (w % config.settings.tab_width) else unicode.displayWidth(line[i .. i + d.len]);
            // Only a tab that *starts before* the column and runs past it is
            // in the way; one that begins exactly there is not straddling.
            if (line[i] == '\t' and w < dcol and w + cw > dcol) {
                var sp: std.ArrayList(u8) = .empty;
                defer sp.deinit(self.gpa);
                sp.appendNTimes(self.gpa, ' ', cw) catch return;
                self.buf.deleteInLine(row, i, i + 1) catch return;
                self.buf.insertBytes(row, i, sp.items) catch return;
                return;
            }
            if (w >= dcol) return;
            w += cw;
            i += d.len;
        }
    }

    fn pasteBlock(self: *Editor, reg: register.Register, after: bool, n: usize) void {
        const first = self.curLine();
        const at_byte = if (after and first.len > 0) unicode.nextBoundary(first, self.cx) else self.cx;
        const dcol = displayCol(first, at_byte);

        var pad: std.ArrayList(u8) = .empty;
        defer pad.deinit(self.gpa);
        var row = self.cy;
        var it = std.mem.splitScalar(u8, reg.text, '\n');
        while (it.next()) |seg| : (row += 1) {
            if (row >= self.buf.lineCount()) self.buf.insertLineAt(row, "") catch return;
            // Reach `dcol`, padding a line that stops short of it.
            const line = self.buf.line(row);
            const have = displayCol(line, line.len);
            // `zp`/`zP` are the variants that add no padding at all: a line
            // too short simply takes the block at its own end.
            if (have < dcol and self.block_pad) {
                pad.clearRetainingCapacity();
                pad.appendNTimes(self.gpa, ' ', dcol - have) catch return;
                self.buf.insertBytes(row, line.len, pad.items) catch return;
            }
            // A tab straddling `dcol` has to be broken into spaces first: the
            // block goes *inside* it, and `byteAtDisplayCol` can only land on
            // the tab's own boundary, which is what made a paste there slide
            // to the wrong column.
            self.splitTabAt(row, dcol);
            const col = byteAtDisplayCol(self.buf.line(row), dcol);
            const tail = col < self.buf.line(row).len;

            pad.clearRetainingCapacity();
            const seg_w = displayCol(seg, seg.len);
            var rep: usize = 0;
            while (rep < n) : (rep += 1) {
                pad.appendSlice(self.gpa, seg) catch return;
                // Square the rectangle up for whatever comes after it.
                if ((rep + 1 < n or tail) and seg_w < reg.width and self.block_pad)
                    pad.appendNTimes(self.gpa, ' ', reg.width - seg_w) catch return;
            }
            self.buf.insertBytes(row, col, pad.items) catch return;
        }
        self.cx = byteAtDisplayCol(self.curLine(), dcol);
        self.updateGoal();
    }

    /// Insert charwise register text at (cy, col), splitting lines on '\n'.
    /// Returns the byte offset just past the inserted text on its final line.
    fn spliceCharwise(self: *Editor, text: []const u8, col: usize) usize {
        if (std.mem.indexOfScalar(u8, text, '\n') == null) {
            self.buf.insertBytes(self.cy, col, text) catch {};
            return col + text.len;
        }
        const tail = self.gpa.dupe(u8, self.buf.line(self.cy)[col..]) catch return col;
        defer self.gpa.free(tail);
        self.buf.deleteInLine(self.cy, col, self.buf.line(self.cy).len) catch {};

        var it = std.mem.splitScalar(u8, text, '\n');
        const first = it.next().?;
        self.buf.insertBytes(self.cy, col, first) catch {};
        var row = self.cy;
        var last_len: usize = 0;
        while (it.next()) |seg| {
            row += 1;
            self.buf.insertLineAt(row, seg) catch {};
            last_len = seg.len;
        }
        self.cy = row;
        self.buf.insertBytes(row, last_len, tail) catch {};
        return last_len;
    }

    // === insert / open =====================================================

    fn enterInsert(self: *Editor, pos: Pos) !void {
        if (self.rejectReadOnly()) return;
        self.pushUndo();
        self.setCursor(pos);
        self.mode = .insert;
        self.beginInsertCount(false);
        self.resetPending();
    }

    /// Remember what an insert session was entered with, so Esc can repeat the
    /// typed text `[count]` times. Called after the cursor is in place: the
    /// anchor is where typing starts.
    fn beginInsertCount(self: *Editor, open_line: bool) void {
        self.ins_count = self.eff();
        self.ins_anchor = self.cursor();
        self.ins_open_line = open_line;
    }

    /// The text typed during the session, read straight out of the buffer
    /// between the anchor and the cursor. Null when the cursor moved somewhere
    /// the anchor cannot describe (backwards, or into another line above it) —
    /// vim splits the change on a mid-insert move anyway.
    fn insertedText(self: *Editor) ?[]u8 {
        const a = self.ins_anchor;
        const c = self.cursor();
        if (cmpPos(a, c) > 0) return null;
        if (a.row >= self.buf.lineCount() or c.row >= self.buf.lineCount()) return null;
        var out: std.ArrayList(u8) = .empty;
        if (a.row == c.row) {
            const line = self.buf.line(a.row);
            if (a.col > line.len or c.col > line.len) return null;
            out.appendSlice(self.gpa, line[a.col..c.col]) catch return null;
        } else {
            const first = self.buf.line(a.row);
            if (a.col > first.len) return null;
            out.appendSlice(self.gpa, first[a.col..]) catch return null;
            var r = a.row + 1;
            while (r < c.row) : (r += 1) {
                out.append(self.gpa, '\n') catch return null;
                out.appendSlice(self.gpa, self.buf.line(r)) catch return null;
            }
            const last = self.buf.line(c.row);
            if (c.col > last.len) return null;
            out.append(self.gpa, '\n') catch return null;
            out.appendSlice(self.gpa, last[0..c.col]) catch return null;
        }
        return out.toOwnedSlice(self.gpa) catch null;
    }

    /// On Esc: type the session's text the remaining `[count] - 1` times, as
    /// vim does. `o`/`O` repeat the *line*, so each copy starts a new one.
    fn repeatInsertCount(self: *Editor) void {
        if (self.ins_count <= 1) return;
        const n = self.ins_count;
        self.ins_count = 1; // never repeat a repeat
        const text = self.insertedText() orelse return;
        defer self.gpa.free(text);
        if (text.len == 0 and !self.ins_open_line) return;
        // Blockwise `[count]A` / `[count]I`: every caret typed the same text,
        // so every caret repeats it. Each sits on its own line, so inserting
        // at one cannot move another — the extras are done first only because
        // the primary's insert would otherwise be counted into `insertedText`
        // on a later call.
        if (!std.mem.containsAtLeastScalar(u8, text, 1, '\n')) {
            for (self.extra.items) |*e| {
                var col = e.head.col;
                var k: usize = 1;
                while (k < n) : (k += 1) {
                    if (e.head.row >= self.buf.lineCount()) break;
                    const line = self.buf.line(e.head.row);
                    if (col > line.len) break;
                    self.buf.insertBytes(e.head.row, col, text) catch break;
                    col += text.len;
                }
                e.head.col = col;
            }
        }
        var i: usize = 1;
        while (i < n) : (i += 1) {
            if (self.ins_open_line) self.insertTextAt(self.cy, self.cx, "\n");
            self.insertTextAt(self.cy, self.cx, text);
        }
    }

    fn openLine(self: *Editor, below: bool) !void {
        if (self.rejectReadOnly()) return;
        self.pushUndo();
        // The new line follows the current one for `o` and the one above it for
        // `O`; that is the line whose syntax decides the indent. Computed
        // before the insert shifts rows.
        const ref: ?usize = if (below) self.cy else (if (self.cy > 0) self.cy - 1 else null);
        self.setAutoIndentFollowing(self.cy, ref, self.cy, null);
        const at = if (below) self.cy + 1 else self.cy;
        try self.buf.insertLineAt(at, self.ai_indent.items);
        self.cy = at;
        self.cx = self.buf.line(at).len;
        self.updateGoal();
        self.ai_row = if (config.settings.autoindent) at else null;
        self.mode = .insert;
        self.beginInsertCount(true); // `o`/`O`: each repeat brings its own line
        self.resetPending();
    }

    fn insertKey(self: *Editor, k: key.Key) !void {
        // Moving the cursor mid-insert breaks the change in two, and vim's `.`
        // then repeats only what was typed *after* the move — as a plain `i`,
        // whatever command opened the insert (nvim-verified: `A` `XY` <Left>
        // `Z` <Esc>, then `.` on another line inserts a bare "Z" at the cursor
        // rather than appending "XZY" at its end). Restarting the capture at
        // "i" is exactly vim's `ResetRedobuff` + `"1i"`.
        if (!self.in_dot and !self.comp_open) switch (k) {
            .up, .down, .left, .right, .home, .end => {
                self.dot_temp.clearRetainingCapacity();
                self.dot_temp.append(self.gpa, 'i') catch {};
            },
            else => {},
        };
        // While the completion popup is open it claims navigation/accept keys;
        // text edits fall through and then re-filter the list.
        if (self.comp_open and try self.completionIntercept(k)) return;
        // Inside a snippet, Tab/Shift-Tab walk the tabstops (the popup above
        // gets first refusal, so Tab still accepts a completion), and Esc
        // leaves the snippet as ordinary text.
        if (self.snippetActive()) {
            switch (k) {
                .ctrl => |c| if ((c == 'n' or c == 'p') and !self.comp_open) {
                    if (self.snippetCycleChoice(c == 'n')) return;
                },
                .tab => {
                    self.snippetJump(true);
                    return;
                },
                .shift_tab => {
                    self.snippetJump(false);
                    return;
                },
                .escape => self.endSnippet(), // then fall through to leave insert
                .char, .backspace, .delete => self.snippetConsumePlaceholder(),
                else => {},
            }
        }
        // Remember where the edit is about to happen so the remaining
        // tabstops can be shifted by whatever it inserts or removes.
        const snip_row = self.cy;
        const snip_col = self.cx;
        const snip_rows = self.buf.lineCount();
        const snip_len = self.buf.line(self.cy).len;
        // The signature popup only claims its overload-cycling key (Ctrl-p);
        // everything else falls through so typing/completion still work.
        if (self.sig_open and self.signatureIntercept(k)) return;

        if (self.extra.items.len > 0) {
            switch (k) {
                .escape => {
                    // `[count]A` / `[count]I` repeat at every caret, so this
                    // has to happen while the carets are still here —
                    // `clearExtra` below drops them. `repeatInsertCount`
                    // clears its own count, so the call inside `insertKeyOne`
                    // is then a no-op.
                    self.repeatInsertCount();
                    self.clearExtra();
                    try self.insertKeyOne(k);
                },
                .enter => {
                    self.clearExtra(); // a line split collapses to one cursor
                    try self.insertKeyOne(k);
                },
                .char, .tab, .backspace, .delete => try self.multiInsert(k),
                .up, .down, .left, .right, .home, .end => try self.multiInsertMove(k),
                else => try self.insertKeyOne(k),
            }
        } else {
            try self.insertKeyOne(k);
        }
        if (self.snippetActive()) self.snippetShift(snip_row, snip_col, snip_rows, snip_len);
        if (self.comp_open) self.filterCompletions();
        // Typing an identifier (re)arms the debounce; anything else — a space,
        // Esc, a motion — cancels it, so no stray request goes out.
        switch (k) {
            .char, .backspace => self.armCompletion(),
            else => self.comp_due_ms = null,
        }
        if (self.mode != .insert) self.comp_due_ms = null;
    }

    /// Returns true if the key was consumed by the open completion popup.
    /// Text-editing keys return false so they edit, then `insertKey` re-filters.
    fn completionIntercept(self: *Editor, k: key.Key) !bool {
        switch (k) {
            .ctrl => |c| switch (c) {
                'n' => {
                    self.compMove(true);
                    return true;
                },
                'p' => {
                    self.compMove(false);
                    return true;
                },
                else => {
                    self.comp_open = false;
                    return false;
                },
            },
            .down => {
                self.compMove(true);
                return true;
            },
            .up => {
                self.compMove(false);
                return true;
            },
            .tab => {
                self.acceptCompletion();
                return true;
            },
            // Enter is a newline, never an accept. Typing a word that happens
            // to raise the popup and pressing Enter for a new line must not
            // silently insert whatever was highlighted (VS Code's
            // `acceptSuggestionOnEnter: off`, and Helix's behaviour).
            .enter => {
                self.comp_open = false;
                return false;
            },
            .escape => {
                // Dismiss the popup *and* let Esc through to leave insert
                // mode. A deliberate divergence from vim and nvim, where Esc
                // with a popup up only closes the popup: there, the popup is
                // something you asked for with Ctrl-n, so eating the key is
                // fair. Here it appears on its own after a typing pause, so
                // "press Esc, be in normal mode" would hold or not depending
                // on how long you paused — which is not a rule anyone can
                // keep in their head. The snippet session above already
                // falls through for the same reason.
                self.comp_open = false;
                return false;
            },
            .char, .backspace, .delete => return false, // edit, then re-filter
            else => {
                self.comp_open = false;
                return false;
            },
        }
    }

    /// While the signature popup is open (and completion is not), `Ctrl-p`
    /// cycles to the previous overload, wrapping. Other keys fall through so
    /// typing arguments and requesting completion keep working.
    fn signatureIntercept(self: *Editor, k: key.Key) bool {
        return switch (k) {
            .ctrl => |c| c == 'p' and self.sigCycle(),
            else => false,
        };
    }

    fn sigCycle(self: *Editor) bool {
        const c = if (self.lsp) |*cl| cl else return false;
        const n = c.signatures.items.len;
        if (n <= 1) return false;
        c.sig_active = (c.sig_active + n - 1) % n; // previous overload, wrapping
        return true;
    }

    // === Replace mode (`R`) ================================================

    /// `R` — typing overwrites what is already there. Vim's model exactly:
    /// each overwritten character is pushed onto a stack, and backspace pops
    /// it back, so a session can be walked backwards to the text it started
    /// from. Past the end of the line typing appends instead, and backspace
    /// over one of those removes it rather than restoring anything.
    fn enterReplace(self: *Editor, virtual: bool) !void {
        if (self.rejectReadOnly()) return;
        self.pushUndo();
        self.mode = .replace;
        self.repl_virtual = virtual;
        self.beginInsertCount(false);
        self.clearReplaceStack();
        self.resetPending();
    }

    fn clearReplaceStack(self: *Editor) void {
        for (self.repl_stack.items) |s| self.gpa.free(s);
        self.repl_stack.clearRetainingCapacity();
    }

    /// How many bytes the next typed character covers in a `gR` session: the
    /// characters whose display columns *all* fall inside the `w` columns it
    /// draws. A tab joins them only once every column it draws is covered —
    /// until then it stays put and simply shrinks, which is the whole point
    /// of virtual replace. The walk measures each character as it goes, so
    /// deleting one never invalidates the widths of those after it.
    fn virtualCover(self: *Editor, w: usize) usize {
        const line = self.buf.line(self.cy);
        const start = displayCol(line, self.cx);
        const covered = start + w;
        var col = start;
        var i = self.cx;
        while (i < line.len) {
            const d = unicode.decode(line[i..]);
            const cw = cellWidth(d.cp, col);
            if (col + cw > covered) break;
            col += cw;
            i += d.len;
        }
        return i - self.cx;
    }

    /// Overwrite at the cursor with `cp` and step past it, appending when
    /// there is nothing to overwrite. `record` is false for the `[count]`
    /// repeat, which runs after the session's stack is done with.
    fn replaceCodepoint(self: *Editor, cp: u21, record: bool) !void {
        const line = self.buf.line(self.cy);
        const past_end = self.cx >= line.len;
        // `R` takes exactly the character under the cursor; `gR` takes
        // whatever the typed character's display columns cover, which is
        // nothing at all while a tab still has slack to shrink into.
        const del: usize = if (past_end) 0 else if (self.repl_virtual)
            self.virtualCover(cellWidth(cp, displayCol(line, self.cx)))
        else
            unicode.nextBoundary(line, self.cx) - self.cx;

        if (record) {
            // An empty slice means "nothing was covered" — backspace then
            // deletes the typed character rather than restoring anything.
            try self.repl_stack.append(self.gpa, try self.gpa.dupe(u8, line[self.cx .. self.cx + del]));
        }
        // `del` can span several codepoints once a tab is finally consumed.
        var left = del;
        while (left > 0) {
            const cur = self.buf.line(self.cy);
            const n = unicode.nextBoundary(cur, self.cx) - self.cx;
            try self.buf.deleteForward(self.cy, self.cx);
            left -= @min(n, left);
        }
        self.cx = try self.buf.insertCodepoint(self.cy, self.cx, cp);
        self.updateGoal();
    }

    /// Backspace in Replace mode. Vim puts back what the last keystroke
    /// overwrote; with nothing left on the stack — the cursor has walked back
    /// past where the session began — it only moves, changing no text
    /// (nvim-probed, with `\x08`: `llR<BS>X` gives `aXcdef`).
    fn replaceBackspace(self: *Editor) !void {
        if (self.repl_stack.pop()) |orig| {
            defer self.gpa.free(orig);
            if (self.cx > 0) self.cx = unicode.prevBoundary(self.curLine(), self.cx);
            try self.buf.deleteForward(self.cy, self.cx);
            if (orig.len > 0) try self.buf.insertBytes(self.cy, self.cx, orig);
        } else if (self.cx > 0) {
            self.cx = unicode.prevBoundary(self.curLine(), self.cx);
        }
        self.updateGoal();
    }

    /// On Esc: type the session's text the remaining `[count] - 1` times,
    /// overwriting as it goes — `3Rab` leaves `ababab`, not `ab` and two
    /// inserted copies.
    fn repeatReplaceCount(self: *Editor) void {
        if (self.ins_count <= 1) return;
        const n = self.ins_count;
        self.ins_count = 1; // never repeat a repeat
        const text = self.insertedText() orelse return;
        defer self.gpa.free(text);
        if (text.len == 0) return;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            var j: usize = 0;
            while (j < text.len) {
                const d = unicode.decode(text[j..]);
                j += d.len;
                if (d.cp == '\n') continue; // a repeat never re-splits the line
                self.replaceCodepoint(d.cp, false) catch return;
            }
        }
    }

    fn replaceKey(self: *Editor, k: key.Key) !void {
        if (self.moveKey(k)) {
            // A move ends the run of characters backspace can put back: the
            // stack is only meaningful where the cursor has been typing.
            self.clearReplaceStack();
            return;
        }
        switch (k) {
            .escape => {
                self.repeatReplaceCount();
                self.clearReplaceStack();
                self.mode = .normal;
                if (self.cx > 0) self.cx = unicode.prevBoundary(self.curLine(), self.cx);
                self.updateGoal();
            },
            // vim inserts a line break rather than replacing one: nothing is
            // overwritten, so there is nothing to put back either.
            .enter => {
                try self.buf.splitLine(self.cy, self.cx);
                self.cy += 1;
                self.cx = 0;
                self.goal_col = 0;
                self.clearReplaceStack();
            },
            .backspace => try self.replaceBackspace(),
            .tab => try self.replaceCodepoint('\t', true),
            .char => |c| try self.replaceCodepoint(c, true),
            else => {},
        }
    }

    fn insertKeyOne(self: *Editor, k: key.Key) !void {
        if (self.moveKey(k)) return;
        // Any key other than Enter/Esc means the auto-indent got company;
        // those two check `was_ai` to apply vim's strip-if-left-blank rule.
        const was_ai = self.ai_row;
        self.ai_row = null;
        switch (k) {
            .escape => {
                self.stripBlankAutoIndent(was_ai);
                self.repeatInsertCount();
                self.mode = .normal;
                self.comp_open = false;
                self.sig_open = false;
                if (self.vb_origin) |o| {
                    // A blockwise `A` ends on the block's top-left corner.
                    self.cy = @min(o.row, self.buf.lineCount() - 1);
                    self.cx = byteAtDisplayCol(self.curLine(), o.col);
                    self.vb_origin = null;
                } else if (self.cx > 0) self.cx = unicode.prevBoundary(self.curLine(), self.cx);
                self.updateGoal();
            },
            .enter => {
                // The indent to carry: the pending one when this line is still
                // an untouched auto-indent (which then gets stripped, like
                // vim), else this line's own leading whitespace.
                if (config.settings.autoindent) {
                    if (was_ai != self.cy or !lineIsBlank(self.curLine()))
                        self.setAutoIndentFollowing(self.cy, self.cy, self.cy, self.cx);
                    self.stripBlankAutoIndent(was_ai);
                }
                try self.buf.splitLine(self.cy, self.cx);
                self.cy += 1;
                self.cx = 0;
                self.goal_col = 0;
                if (config.settings.autoindent and self.ai_indent.items.len > 0) {
                    try self.buf.insertBytes(self.cy, 0, self.ai_indent.items);
                    self.cx = self.ai_indent.items.len;
                    self.ai_row = self.cy;
                    self.updateGoal();
                }
            },
            .backspace => try self.insertBackspace(),
            .delete => try self.buf.deleteForward(self.cy, self.cx),
            .tab => {
                self.cx = try self.buf.insertCodepoint(self.cy, self.cx, '\t');
                self.updateGoal();
            },
            .char => |c| {
                try self.insertChar(c);
                // Opening or advancing a call argument list asks for signatures.
                if (c == '(' or c == ',') self.lspSignatureHelp();
            },
            .ctrl => |c| switch (c) {
                'n' => self.requestCompletion(), // request completion
                'k' => self.lspHover(), // hover (parallels normal-mode K)
                else => {},
            },
            else => {},
        }
    }

    /// Insert a codepoint with auto-pairing: opening brackets/quotes insert
    /// their closer, and typing a closer in front of one just steps over it.
    /// Remember that `row` holds a freshly auto-inserted `indent` (copied),
    /// still untouched by the user.
    fn setAutoIndent(self: *Editor, row: usize, text: []const u8) void {
        self.ai_indent.clearRetainingCapacity();
        self.ai_indent.appendSlice(self.gpa, text) catch {};
        self.ai_row = if (config.settings.autoindent) row else null;
    }

    /// Prepare `ai_indent` for a new line at `at` that will *follow* line
    /// `ref`: that line's own leading whitespace (vim's 'autoindent'), plus one
    /// unit for every block it opens according to the grammar's `indents.scm`
    /// — so Enter after `void f(void) {` or `def f():` lands one level in
    /// rather than flush with the opener.
    ///
    /// `upto` limits how much of `ref` counts — Enter passes the cursor column,
    /// because a `{` the split is about to push onto the *new* line has not
    /// opened anything on the old one (nvim-verified: Enter before the brace of
    /// `void f(void) {` leaves the new line at column 0).
    ///
    /// Whenever the syntax tree cannot answer — no grammar, no indent query for
    /// it, no line for the new one to follow (`O`/`cc` on the first line), or a
    /// blank line to follow (which carries no indent and opens nothing) — this
    /// is vim's plain 'autoindent': copy `fallback`'s own leading whitespace,
    /// exactly as before. For `o` and Enter the two rules read the same line
    /// anyway, so a grammar-less file behaves identically either way.
    fn setAutoIndentFollowing(self: *Editor, at: usize, ref: ?usize, fallback: usize, upto: ?usize) void {
        if (!config.settings.autoindent) {
            self.setAutoIndent(at, "");
            return;
        }
        const row = ref orelse return self.setAutoIndent(at, leadingIndent(self.buf.line(fallback)));
        // A blank reference line has no indent to inherit and opens no block,
        // so following it would land the new line at column 0 — losing the
        // block's indent for every `O`/`cc` above a blank line, which is where
        // half of real code puts one. vim (and nvim-treesitter) copy the
        // cursor's own line there, so fall back to that.
        if (lineIsBlank(self.buf.line(row)))
            return self.setAutoIndent(at, leadingIndent(self.buf.line(fallback)));
        var levels = self.tsOpenIndents(row, upto) orelse
            return self.setAutoIndent(at, leadingIndent(self.buf.line(fallback)));
        const base = leadingIndent(self.buf.line(row));
        self.setAutoIndent(at, base);
        if (levels == 0) return;
        const unit = self.indentUnit(base);
        while (levels > 0) : (levels -= 1) self.ai_indent.appendSlice(self.gpa, unit) catch {};
    }

    /// How many indent levels line `row` opens, per the grammar's indent query,
    /// counting only its first `upto` bytes (all of it when null). Null when
    /// the tree cannot answer at all — see `setAutoIndentFollowing`.
    fn tsOpenIndents(self: *Editor, row: usize, upto: ?usize) ?usize {
        // Before anything else: a grammar with no indent query (Markdown,
        // JSON, HTML) can only ever answer null, so it must not pay for the
        // catch-up parse below to find that out.
        if (self.ts == null or self.ts.?.indent == null) return null;
        // A batch of keys — a macro, a `.` repeat, a paste, or simply typing
        // faster than the terminal delivers — reaches the interpreter with no
        // frame in between, so the tree can be a revision behind. Catch it up
        // instead of answering "cannot say": otherwise the very same keys
        // indent differently depending on how the input happened to be
        // chunked, and `.` disagrees with the change it repeats. Costs nothing
        // in the steady state (one key, one frame, tree already current); in a
        // batch it costs one reparse *per indent key*, since each one changes
        // the buffer and the next cannot be answered from the tree the
        // previous one left. Measured: a 50-repeat `o` macro in one burst is
        // 3.3 ms on a 100-byte file and 419 ms on 1.5 MB — ~8.4 ms a key,
        // i.e. one `tsReparse`, whose O(document) serialisation is the gap
        // CLAUDE.md already records. Correct indentation is worth it.
        if (self.ts_rev != self.buf.revision) self.tsReparse();
        if (self.ts_rev != self.buf.revision) return null; // the reparse failed
        var h = if (self.ts) |*x| x else return null;
        if (row >= self.buf.lineCount()) return null;
        const start = self.byteOffset(row, 0) orelse return null;
        const len = self.buf.line(row).len;
        const end = start + @min(upto orelse len, len);
        if (start + len > self.ts_doc_len) return null;
        return h.openIndents(row, start, end);
    }

    /// One indent level's worth of whitespace: a tab where the surrounding
    /// code is tab-indented, else `tab_width` spaces. The reference line's own
    /// indent decides when it has one; otherwise the file's first indented
    /// line does, which is what makes a tab-indented Go file indent with tabs
    /// even though its `func f() {` is flush left.
    fn indentUnit(self: *Editor, base: []const u8) []const u8 {
        const spaces = " " ** 16;
        const wide = spaces[0..@min(config.settings.tab_width, spaces.len)];
        if (base.len > 0) return if (base[base.len - 1] == '\t') "\t" else wide;
        const rows = @min(self.buf.lineCount(), 200);
        var r: usize = 0;
        while (r < rows) : (r += 1) {
            const line = self.buf.line(r);
            if (line.len == 0) continue;
            if (line[0] == '\t') return "\t";
            if (line[0] == ' ') return wide;
        }
        return wide;
    }

    /// vim's autoindent rule: leaving an auto-indented line without typing on
    /// it strips the indent, leaving a truly empty line.
    fn stripBlankAutoIndent(self: *Editor, was_ai: ?usize) void {
        const row = was_ai orelse return;
        if (row != self.cy) return;
        if (!lineIsBlank(self.curLine())) return;
        if (self.curLine().len == 0) return;
        self.buf.setLine(self.cy, "") catch {};
        self.cx = 0;
    }

    fn insertChar(self: *Editor, c: u21) !void {
        const line = self.curLine();
        const next: ?u21 = if (self.cx < line.len) unicode.decode(line[self.cx..]).cp else null;

        if ((isCloser(c) or isQuote(c)) and next != null and next.? == c) {
            self.cx = unicode.nextBoundary(self.curLine(), self.cx);
            self.updateGoal();
            return;
        }
        const close: ?u21 = if (closerFor(c)) |cl| cl else if (isQuote(c)) c else null;
        if (close) |cl| {
            self.cx = try self.buf.insertCodepoint(self.cy, self.cx, c);
            _ = try self.buf.insertCodepoint(self.cy, self.cx, cl);
            self.updateGoal();
            return;
        }
        self.cx = try self.buf.insertCodepoint(self.cy, self.cx, c);
        self.updateGoal();
    }

    fn insertBackspace(self: *Editor) !void {
        const line = self.curLine();
        if (self.cx > 0 and self.cx < line.len) {
            const before = unicode.decode(line[unicode.prevBoundary(line, self.cx)..]).cp;
            const after = unicode.decode(line[self.cx..]).cp;
            if (isPair(before, after)) {
                try self.buf.deleteForward(self.cy, self.cx); // closer
                const p = try self.buf.deleteBackward(self.cy, self.cx); // opener
                self.cy = p.row;
                self.cx = p.col;
                self.updateGoal();
                return;
            }
        }
        const p = try self.buf.deleteBackward(self.cy, self.cx);
        self.cy = p.row;
        self.cx = p.col;
        self.updateGoal();
    }

    fn moveKey(self: *Editor, k: key.Key) bool {
        switch (k) {
            .left => self.cx = unicode.prevBoundary(self.curLine(), self.cx),
            .right => {
                const line = self.curLine();
                if (self.cx < line.len) self.cx = unicode.nextBoundary(line, self.cx);
            },
            .up => {
                if (self.cy > 0) {
                    self.cy -= 1;
                    self.cx = byteAtDisplayCol(self.curLine(), self.goal_col);
                }
                return true;
            },
            .down => {
                if (self.cy + 1 < self.buf.lineCount()) {
                    self.cy += 1;
                    self.cx = byteAtDisplayCol(self.curLine(), self.goal_col);
                }
                return true;
            },
            .home => self.cx = 0,
            .end => self.cx = self.curLine().len,
            else => return false,
        }
        self.updateGoal();
        return true;
    }

    // === visual mode =======================================================

    /// `e` / `b` in normal mode: move, and leave the word travelled over
    /// *selected* — Helix's habit, where a motion tells you what it covered
    /// before you decide what to do with it. Only these two keys: Helix's
    /// model is that every motion selects, which would change what `d`, `.`,
    /// visual mode and four hundred nvim-pinned checks all mean.
    ///
    /// From an existing selection it extends, so `ee` reaches two words. With
    /// an operator pending it is the plain motion, because `de` must delete
    /// the word rather than select it first.
    /// Helix's selecting `e`/`b`: move, and leave what was travelled over
    /// selected. Only the small-word forms are bound — `E`/`B` keep vim's
    /// plain meaning — so there is no WORD variant to parameterise.
    fn selectWord(self: *Editor, kind: WordKind) void {
        if (self.operator != .none) return self.doMotion(self.repeatWord(kind, false));
        const anchor = if (self.mode == .visual) self.vstart else self.cursor();
        self.doMotion(self.repeatWord(kind, false));
        if (self.mode != .visual) self.mode = .visual;
        self.vstart = anchor;
        self.vb_dollar = false;
        self.ins_visual = false;
    }

    fn enterVisual(self: *Editor, m: Mode) void {
        self.mode = m;
        self.vb_dollar = false;
        self.vstart = self.cursor();
        self.resetPending();
        // Plain visual by default; the mouse re-sets this for a gesture that
        // started in insert mode, so the flag can never outlive its selection.
        self.ins_visual = false;
    }

    /// `gv` — put the last selection back, in the mode it had. Called from
    /// visual mode it *swaps*, which is vim's rule there (nvim-probed: `v`
    /// then `gv` lands on the older selection, and the one just abandoned
    /// becomes what the next `gv` returns to). Coordinates are clamped, since
    /// the text they named may have shrunk since — vim reselects the columns,
    /// not the characters that were in them.
    fn reselect(self: *Editor) void {
        const s = self.last_vis orelse return;
        const in_visual = self.mode == .visual or self.mode == .visual_line or self.mode == .visual_block;
        if (in_visual) self.last_vis = .{ .start = self.vstart, .end = self.cursor(), .mode = self.mode };
        self.mode = s.mode;
        self.vstart = self.clampPos(s.start);
        self.vb_dollar = false;
        self.ins_visual = false;
        self.setCursor(self.clampPos(s.end));
    }

    fn clampPos(self: *Editor, p: Pos) Pos {
        const row = @min(p.row, self.buf.lineCount() - 1);
        return .{ .row = row, .col = @min(p.col, self.buf.line(row).len) };
    }

    /// `gx` — hand the URL or path under the cursor to the desktop's handler.
    ///
    /// The target is buffer content, so it is untrusted: it leaves as a
    /// single argv element (no shell ever parses it), and one that would read
    /// as an option is refused rather than passed to the handler as a flag.
    fn openUnderCursor(self: *Editor) void {
        const target = motion.targetUnderCursor(self.curLine(), self.cx) orelse
            return self.setStatus("nothing to open under the cursor", .{});
        if (target[0] == '-')
            return self.setStatus("not opening '{s}': reads as an option", .{target});
        // One stack buffer, NUL-terminated for execvp; a path longer than
        // this is not one worth spawning a browser for.
        var buf: [1024]u8 = undefined;
        if (target.len >= buf.len)
            return self.setStatus("that target is too long to open", .{});
        @memcpy(buf[0..target.len], target);
        buf[target.len] = 0;
        term.openExternal(buf[0..target.len :0]);
        self.notifyToast(.info, "opening {s}", .{target});
    }

    fn visualKey(self: *Editor, k: key.Key) !void {
        if (self.await_arg != .none) return self.awaitKey(k); // v i{obj} / v a{obj}
        // `gv` reselects whatever was last selected, so the selection has to
        // be left behind before any key can end it. Recording here covers
        // every exit path at once — Esc, an operator, a case change, a paste
        // — because all of them arrive as a key. The `g` prefix is the one
        // exception: skipping it is what lets `gv` see the *previous*
        // selection rather than the one it is standing in.
        if (!(k == .char and k.char == 'g'))
            self.last_vis = .{ .start = self.vstart, .end = self.cursor(), .mode = self.mode };
        // Arrows act exactly like h/l/k/j — translate for dispatch only; the
        // goal-column guard below still keys on the original key.
        const kk: key.Key = switch (k) {
            .left => .{ .char = 'h' },
            .right => .{ .char = 'l' },
            .up => .{ .char = 'k' },
            .down => .{ .char = 'j' },
            else => k,
        };
        // A count in visual mode: `v3l`, `v2j`, `v3w` all extend by that many,
        // exactly as the same motions do with an operator. Digits were falling
        // through to the motion dispatch, so every count moved one.
        if (kk == .char and (kk.char >= '1' and kk.char <= '9' or (kk.char == '0' and self.count > 0))) {
            self.count = self.count * 10 + @as(usize, @intCast(kk.char - '0'));
            return;
        }
        const n = self.eff();
        defer {
            // Whatever the key was, it has had its count.
            self.count = 0;
            self.count2 = 0;
        }
        switch (kk) {
            .escape => self.mode = .normal,
            .char => |c| switch (c) {
                'h' => for (0..n) |_| {
                    self.cx = unicode.prevBoundary(self.curLine(), self.cx);
                },
                'l', ' ' => for (0..n) |_| {
                    const line = self.curLine();
                    if (self.cx < line.len) self.cx = unicode.nextBoundary(line, self.cx);
                },
                'j' => for (0..n) |_| {
                    if (self.cy + 1 >= self.buf.lineCount()) break;
                    self.cy += 1;
                    self.cx = byteAtDisplayCol(self.curLine(), self.goal_col);
                },
                'k' => for (0..n) |_| {
                    if (self.cy == 0) break;
                    self.cy -= 1;
                    self.cx = byteAtDisplayCol(self.curLine(), self.goal_col);
                },
                '0' => self.cx = 0,
                '^' => self.cx = motion.firstNonBlank(self.curLine()),
                // `$` in a block extends it to end-of-line — a ragged block
                // that keeps following each line's own end as it grows. The
                // cursor goes one *past* the last character, which is where
                // vim leaves it in blockwise visual (probed: `<C-v>jj$h` then
                // `A` appends one column in from the longest line's end).
                '$' => {
                    self.cx = self.columnLimit(self.curLine());
                    if (self.mode == .visual_block) self.vb_dollar = true;
                },
                'w' => for (0..n) |_| self.setCursorKeep(motion.wordForward(self.buf, self.cursor(), false)),
                'W' => for (0..n) |_| self.setCursorKeep(motion.wordForward(self.buf, self.cursor(), true)),
                'b' => for (0..n) |_| self.setCursorKeep(motion.wordBackward(self.buf, self.cursor(), false)),
                'e' => for (0..n) |_| self.setCursorKeep(motion.wordEnd(self.buf, self.cursor(), false)),
                // `{n}G` is a line number, not a repeat.
                'G' => self.setCursorKeep(.{
                    .row = if (self.count > 0) @min(self.count - 1, self.buf.lineCount() - 1) else self.buf.lineCount() - 1,
                    .col = 0,
                }),
                // `g` waits for its second key here as it does in normal
                // mode — `gg` still goes to line 1, and `gv`/`gJ`/`gU` now
                // reach the rest. (It used to jump on the bare `g`, so `vg`
                // moved where vim waits.)
                'g' => self.await_arg = .visual_g,
                '%' => if (motion.matchPair(self.buf, self.cursor())) |p| self.setCursorKeep(p),
                '(' => for (0..n) |_| self.setCursorKeep(motion.sentenceBackward(self.buf, self.cursor())),
                ')' => for (0..n) |_| self.setCursorKeep(motion.sentenceForward(self.buf, self.cursor())),
                'p', 'P' => try self.visualPaste(),
                'o' => {
                    const tmp = self.vstart;
                    self.vstart = self.cursor();
                    self.cy = tmp.row;
                    self.cx = tmp.col;
                },
                'd', 'x' => if (self.mode == .visual_block) try self.blockDelete() else try self.visualOperator(.delete),
                'y' => if (self.mode == .visual_block) try self.blockYank(false) else try self.visualOperator(.yank),
                // `z` in visual mode exists for `zy` alone.
                'z' => self.await_arg = .visual_z,
                'c', 's' => if (self.mode == .visual_block) try self.blockChange() else try self.visualOperator(.change),
                'I' => if (self.mode == .visual_block) try self.blockInsert(false),
                'A' => if (self.mode == .visual_block) try self.blockInsert(true),
                'S' => self.visualSurround(),
                'U' => try self.visualCase(.upper),
                'u' => try self.visualCase(.lower),
                '~' => try self.visualCase(.toggle),
                '>' => try self.visualOperator(.indent_right),
                '=' => try self.visualOperator(.reindent),
                '<' => try self.visualOperator(.indent_left),
                // Each of the three either switches to its own kind or, when
                // it is already that kind, stops visual mode (vim's rule).
                'V' => self.mode = if (self.mode == .visual_line) .normal else .visual_line,
                'v' => self.mode = if (self.mode == .visual) .normal else .visual,
                // The linewise forms: they take whole lines however the
                // selection was made.
                'D', 'X' => try self.visualLinewise(.delete),
                'Y' => try self.visualLinewise(.yank),
                'C', 'R' => {
                    try self.visualLinewise(.delete);
                    self.buf.insertLineAt(self.cy, "") catch {};
                    try self.enterInsert(.{ .row = self.cy, .col = 0 });
                },
                'J' => {
                    const top = @min(self.vstart.row, self.cy);
                    const bot = @max(self.vstart.row, self.cy);
                    self.mode = .normal;
                    self.setCursor(.{ .row = top, .col = 0 });
                    try self.joinLines(bot - top + 1, true);
                },
                'r' => self.await_arg = .visual_replace,
                // `O` swaps the *horizontal* corner of a block; for the other
                // two kinds it is `o` (nvim-probed).
                'O' => if (self.mode == .visual_block) {
                    const c0 = self.vstart.col;
                    self.vstart.col = self.cx;
                    self.cx = c0;
                } else {
                    const tmp = self.vstart;
                    self.vstart = self.cursor();
                    self.cy = tmp.row;
                    self.cx = tmp.col;
                },
                // vim says `Q` does not start Ex mode here; nor does it here.
                'Q' => {},
                '!' => {
                    // Prefill the range, as vim does, and let `:!` do the rest.
                    self.enterCmd(.ex);
                    self.cmd.appendSlice(self.gpa, "'<,'>!") catch {};
                    self.cmd_cur = self.cmd.items.len;
                },
                'i' => self.await_arg = .visual_object_inner,
                'a' => self.await_arg = .visual_object_around,
                // `"{reg}` picks the register the next y/d/c fills, in visual
                // mode exactly as in normal mode (nvim: `<C-v>jl"ay` then
                // `"ap` round-trips the rectangle through register a).
                '"' => self.await_arg = .register,
                '{' => {
                    const res = self.paragraphMotion(false);
                    self.setCursorKeep(res.pos);
                },
                '}' => {
                    const res = self.paragraphMotion(true);
                    self.setCursorKeep(res.pos);
                },
                ':' => self.enterCmd(.ex),
                else => {},
            },
            .ctrl => |c| switch (c) {
                'a' => self.visualIncrement(1, n, false),
                'x' => self.visualIncrement(-1, n, false),
                'c' => self.mode = .normal, // stop visual, like Esc
                'v' => self.mode = if (self.mode == .visual_block) .normal else .visual_block,
                else => {},
            },
            else => {},
        }
        const moved: enum { vertical, horizontal, other } = switch (kk) {
            .char => |c| switch (c) {
                'j', 'k' => .vertical,
                'h', 'l', ' ', '0', '^', 'w', 'W', 'b', 'e', 'G', 'g', '%', 'o' => .horizontal,
                else => .other,
            },
            else => .other,
        };
        // Any motion that names a column ends a `$` block's "to end-of-line"
        // reach (vim resets curswant); `j`/`k` deliberately keep it, which is
        // how a ragged block grows downwards.
        if (moved == .horizontal) self.vb_dollar = false;
        // Vertical motions keep the goal column, so a block stays square as it
        // crosses a short or empty line. The arrows are translated to `j`/`k`
        // above, so the guard has to key on the *dispatched* key, not the typed
        // one — keying on the typed one let `j` over an empty line collapse the
        // block to column 0, where nvim keeps curswant and stays square.
        if (moved != .vertical) self.updateGoal();
    }

    /// `i`/`a` + object in visual mode: reshape the selection to the object.
    /// Paragraph objects switch to V-LINE (vim makes ip/ap linewise); the
    /// charwise objects select start..end with the cursor on the last char.
    fn visualObject(self: *Editor, around: bool, k: key.Key) void {
        const c = charByte(k) orelse return;
        const span = self.textObjectSpan(around, c) orelse return;
        if (span.lines) {
            self.mode = .visual_line;
            self.vstart = .{ .row = span.top, .col = 0 };
            self.cy = span.bot;
            self.cx = 0;
        } else {
            self.vstart = span.start;
            self.cy = span.end.row;
            self.cx = unicode.prevBoundary(self.buf.line(span.end.row), span.end.col);
        }
        self.updateGoal();
    }

    fn setCursorKeep(self: *Editor, p: Pos) void {
        self.cy = @min(p.row, self.buf.lineCount() - 1);
        self.cx = p.col;
    }

    /// Visual-mode `U`/`u`/`~`: set or toggle the case of the selection
    /// (charwise and linewise; ASCII, like `~` in normal mode).
    /// Recase `[start, end)` — `end` exclusive, the way an operator span
    /// carries it — or whole lines from `start.row` to `end.row` when
    /// `lines`. The one place the transformation lives: `gu`/`gU`/`g~` and
    /// visual `u`/`U`/`~` differ only in how they arrive at the range.
    fn caseRange(self: *Editor, start: Pos, end: Pos, lines: bool, how: Case) !void {
        var row = start.row;
        const last = self.buf.lineCount() - 1;
        while (row <= @min(end.row, last)) : (row += 1) {
            const line = self.buf.line(row);
            var lo: usize = 0;
            var hi: usize = line.len;
            if (!lines) {
                if (row == start.row) lo = @min(start.col, line.len);
                if (row == end.row) hi = @min(end.col, line.len);
            }
            if (lo >= hi) continue;
            const mut = try self.buf.lineMut(row);
            for (mut[lo..hi]) |*ch| {
                ch.* = switch (how) {
                    .upper => std.ascii.toUpper(ch.*),
                    .lower => std.ascii.toLower(ch.*),
                    .toggle => if (std.ascii.isUpper(ch.*)) std.ascii.toLower(ch.*) else std.ascii.toUpper(ch.*),
                };
            }
        }
        self.buf.dirty = true;
        self.buf.revision +%= 1;
    }

    /// `gu{motion}` / `gU{motion}` / `g~{motion}`, and their doubled forms.
    /// The cursor lands at the start of what changed, which is what makes
    /// `gUiww.` recase the next word too (nvim-pinned).
    fn applyCase(self: *Editor, span: Span, how: Case) void {
        self.pushUndo();
        const start: Pos = if (span.lines) .{ .row = span.top, .col = 0 } else span.start;
        const end: Pos = if (span.lines) .{ .row = span.bot, .col = 0 } else span.end;
        self.caseRange(start, end, span.lines, how) catch return;
        self.setCursor(.{ .row = @min(start.row, self.buf.lineCount() - 1), .col = start.col });
    }

    /// `g?{motion}` — rot13. A cipher nobody needs and vim has anyway; it
    /// costs one span walk beside the case operators it sits with.
    fn applyRot13(self: *Editor, span: Span) void {
        self.pushUndo();
        const start: Pos = if (span.lines) .{ .row = span.top, .col = 0 } else span.start;
        const end: Pos = if (span.lines) .{ .row = span.bot, .col = 0 } else span.end;
        const last = self.buf.lineCount() - 1;
        var row = start.row;
        while (row <= @min(end.row, last)) : (row += 1) {
            const line = self.buf.line(row);
            var lo: usize = 0;
            var hi: usize = line.len;
            if (!span.lines) {
                if (row == start.row) lo = @min(start.col, line.len);
                if (row == end.row) hi = @min(end.col, line.len);
            }
            if (lo >= hi) continue;
            const mut = self.buf.lineMut(row) catch return;
            for (mut[lo..hi]) |*ch| {
                const base: u8 = if (ch.* >= 'a' and ch.* <= 'z') 'a' else if (ch.* >= 'A' and ch.* <= 'Z') 'A' else continue;
                ch.* = base + (ch.* - base + 13) % 26;
            }
        }
        self.buf.dirty = true;
        self.buf.revision +%= 1;
        self.setCursor(.{ .row = @min(start.row, self.buf.lineCount() - 1), .col = start.col });
    }

    /// `gn` / `gN` — select the next (previous) match of the last search, so
    /// an operator acts on it: `dgn` deletes it, and `.` repeats that on the
    /// one after. With no operator pending it leaves a visual selection.
    fn selectMatch(self: *Editor, forward: bool) void {
        if (self.last_search.items.len == 0) return self.resetPending();
        var re = regex.Regex.compile(self.gpa, self.last_search.items, false) catch return self.resetPending();
        defer re.deinit(self.gpa);
        // `gn` takes the match the cursor is *inside* before looking on.
        const from: Pos = if (forward and self.cx > 0)
            .{ .row = self.cy, .col = self.cx - 1 }
        else
            self.cursor();
        const hit = (if (forward) search.next(self.buf, from, &re) else search.prev(self.buf, self.cursor(), &re)) orelse
            return self.resetPending();
        const line = self.buf.line(hit.row);
        const m = re.find(line, hit.col) orelse return self.resetPending();
        const ms = m.span;
        const op = self.operator;
        self.operator = .none;
        const span: Span = .{
            .lines = false,
            .start = .{ .row = hit.row, .col = ms.start },
            .end = .{ .row = hit.row, .col = ms.end },
        };
        if (op != .none) {
            self.setCursor(span.start);
            self.applyOperator(op, span);
            self.resetPending();
            return;
        }
        // No operator: leave it selected, as vim does.
        self.setCursor(span.start);
        self.enterVisual(.visual);
        self.setCursor(.{ .row = hit.row, .col = unicode.prevBoundary(line, ms.end) });
    }

    fn visualCase(self: *Editor, how: Case) !void {
        if (self.rejectReadOnly()) return;
        self.pushUndo();
        const linewise = self.mode == .visual_line;
        var start = self.vstart;
        var end = self.cursor();
        if (cmpPos(end, start) < 0) std.mem.swap(Pos, &start, &end);
        // A selection runs *through* its end cell; `caseRange` wants it one
        // past, as an operator span already is.
        end.col = unicode.nextBoundary(self.buf.line(end.row), end.col);
        try self.caseRange(start, end, linewise, how);
        self.mode = .normal;
        self.setCursor(.{ .row = start.row, .col = if (linewise) 0 else start.col });
        self.resetPending();
    }

    fn visualOperator(self: *Editor, op: Operator) !void {
        const linewise = self.mode == .visual_line;
        const a = self.vstart;
        const b = self.cursor();
        var span: Span = undefined;
        if (linewise) {
            span = .{ .lines = true, .top = @min(a.row, b.row), .bot = @max(a.row, b.row) };
        } else {
            var start = a;
            var end = b;
            if (cmpPos(end, start) < 0) {
                start = b;
                end = a;
            }
            end = .{ .row = end.row, .col = unicode.nextBoundary(self.buf.line(end.row), end.col) };
            span = .{ .lines = false, .start = start, .end = end };
        }
        self.mode = .normal;
        self.yank_from_visual = true;
        self.yank_cursor_was_top = a.row > b.row; // the anchor is below: the cursor is the top end
        self.applyOperator(op, span);
        self.yank_from_visual = false;
        self.resetPending();
    }

    /// Visual `p`/`P`: replace the selection with a register, and put what was
    /// replaced into the unnamed register (vim's rule, probed — a following
    /// `p` pastes the text that was overwritten).
    ///
    /// Four combinations, all nvim-probed: the register's kind and the
    /// selection's kind each being charwise or linewise. A linewise register
    /// dropped into a charwise selection *splits* the line, so the text before
    /// the selection, the register's lines and the text after it end up on
    /// lines of their own.
    fn visualPaste(self: *Editor) !void {
        if (self.rejectReadOnly()) return;
        const reg = self.registers.get(self.pending_register) orelse {
            self.mode = .normal;
            self.resetPending();
            return;
        };
        // Copy it out first: deleting the selection overwrites the unnamed
        // register, which is usually the one being pasted from.
        const text = self.gpa.dupe(u8, reg.text) catch return;
        defer self.gpa.free(text);
        const kind = reg.kind;

        const linewise_sel = self.mode == .visual_line;
        const a = self.vstart;
        const b = self.cursor();
        var span: Span = undefined;
        if (linewise_sel) {
            span = .{ .lines = true, .top = @min(a.row, b.row), .bot = @max(a.row, b.row) };
        } else {
            var start = a;
            var end = b;
            if (cmpPos(end, start) < 0) {
                start = b;
                end = a;
            }
            end = .{ .row = end.row, .col = unicode.nextBoundary(self.buf.line(end.row), end.col) };
            span = .{ .lines = false, .start = start, .end = end };
        }
        self.mode = .normal;
        self.pushUndo();

        // What is being replaced becomes the unnamed register.
        const replaced = self.extract(span) catch null;
        if (replaced) |r| {
            defer self.gpa.free(r);
            self.yankTo(r, if (span.lines) .linewise else .charwise, 0);
        }

        const at = self.deleteSpan(span);
        const body = trimTrailingNewline(text);
        if (linewise_sel) {
            // The selected lines are gone; the register goes in their place,
            // as lines either way — a charwise register becomes one line.
            var row = span.top;
            var it = std.mem.splitScalar(u8, body, '\n');
            while (it.next()) |ln| {
                self.buf.insertLineAt(row, ln) catch break;
                row += 1;
            }
            self.cy = @min(span.top, self.buf.lineCount() -| 1);
            self.cx = 0;
            self.goal_col = 0;
        } else if (kind == .linewise) {
            // A charwise hole with linewise text: break the line open around
            // it and drop the register's lines in between.
            self.cy = at.row;
            self.cx = at.col;
            self.buf.splitLine(at.row, at.col) catch {};
            var row = at.row + 1;
            var it = std.mem.splitScalar(u8, body, '\n');
            while (it.next()) |ln| {
                self.buf.insertLineAt(row, ln) catch break;
                row += 1;
            }
            self.cy = @min(at.row + 1, self.buf.lineCount() -| 1);
            self.cx = 0;
            self.goal_col = 0;
        } else {
            self.cy = at.row;
            self.cx = at.col;
            _ = self.spliceCharwise(text, at.col);
            self.cy = at.row;
            self.cx = at.col;
            self.updateGoal();
        }
        self.clampCursor();
        self.resetPending();
    }

    /// Visual `S{char}`: surround the selection.
    fn visualSurround(self: *Editor) void {
        var start = self.vstart;
        var end = self.cursor();
        if (cmpPos(end, start) < 0) std.mem.swap(Pos, &start, &end);
        end = .{ .row = end.row, .col = unicode.nextBoundary(self.buf.line(end.row), end.col) };
        self.mode = .normal;
        self.beginSurroundAdd(.{ .lines = false, .start = start, .end = end });
    }

    // === blockwise visual ==================================================

    const BlockRect = struct {
        top: usize,
        bot: usize,
        left: usize,
        right: usize,

        fn width(r: BlockRect) usize {
            return r.right + 1 - r.left;
        }
    };

    /// The block rectangle in display columns from the anchor and cursor.
    fn blockCols(self: *Editor) BlockRect {
        const a = self.vstart;
        const b = self.cursor();
        const a_line = self.buf.line(a.row);
        const b_line = self.buf.line(b.row);
        const a_dc = displayCol(a_line, a.col);
        const b_dc = displayCol(b_line, b.col);
        return .{
            .top = @min(a.row, b.row),
            .bot = @max(a.row, b.row),
            .left = @min(a_dc, b_dc),
            // The right edge is the *last* cell of the character an endpoint
            // sits on, not its first, so a block ending on a double-width
            // character (or a tab) covers it whole — nvim-verified: `<C-v>jl`
            // over "a漢b" yanks "a漢", and `A` there appends past the 漢.
            .right = @max(endCell(a_line, a.col, a_dc), endCell(b_line, b.col, b_dc)),
        };
    }

    /// Where row `i` of the block starts and ends in bytes. Under `$` the
    /// block was extended to end-of-line, so each row ends at its own.
    fn blockSpan(self: *Editor, r: BlockRect, i: usize) struct { usize, usize } {
        const line = self.buf.line(i);
        return .{
            byteAtDisplayCol(line, r.left),
            if (self.vb_dollar) line.len else byteAtDisplayCol(line, r.right + 1),
        };
    }

    /// The block's text into `out`, rows joined by `\n`. Returns the width to
    /// store with the register: the rectangle's own, or — for a `$` block,
    /// which has no fixed right edge — the widest row it actually took.
    fn blockText(self: *Editor, r: BlockRect, out: *std.ArrayList(u8)) !usize {
        var width = r.width();
        if (self.vb_dollar) {
            width = 0;
            var i = r.top;
            while (i <= r.bot) : (i += 1) {
                const line = self.buf.line(i);
                const lo, const hi = self.blockSpan(r, i);
                if (hi > lo) width = @max(width, displayCol(line, hi) - displayCol(line, lo));
            }
        }
        // A line stopping *before* the block's left edge contributes a run of
        // spaces rather than nothing (vim's `endspaces`) — the block's own
        // width, or one more for a `$` block, whose right edge sits one past
        // the longest line's end. Only a paste with nothing after it on the
        // line shows the difference, since the squaring-up below covers the
        // rest; without them `G$p` of such a block loses the alignment.
        // nvim-verified, and the same for `y`, `d` and `c`. A row at the
        // block's own top or bottom can never be this short: the endpoint
        // sitting on it is what clamped `left` in the first place.
        const short = if (self.vb_dollar) width + 1 else width;
        var i = r.top;
        while (i <= r.bot) : (i += 1) {
            const line = self.buf.line(i);
            if (displayCol(line, line.len) < r.left) {
                try out.appendNTimes(self.gpa, ' ', short);
            } else {
                const lo, const hi = self.blockSpan(r, i);
                if (hi > lo) try out.appendSlice(self.gpa, line[lo..hi]);
            }
            if (i < r.bot) try out.append(self.gpa, '\n');
        }
        return width;
    }

    fn blockDelete(self: *Editor) !void {
        if (self.rejectReadOnly()) return;
        const r = self.blockCols();
        // vim fills the register from a blockwise delete just as from a yank.
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        const w = try self.blockText(r, &out);
        self.yankTo(out.items, .blockwise, w);
        self.pushUndo();
        var i = r.top;
        while (i <= r.bot) : (i += 1) {
            const lo, const hi = self.blockSpan(r, i);
            if (hi > lo) try self.buf.deleteInLine(i, lo, hi);
        }
        self.mode = .normal;
        self.cy = r.top;
        self.cx = byteAtDisplayCol(self.buf.line(r.top), r.left);
        self.updateGoal();
    }

    /// `y` in blockwise visual, and `zy` — which is the same yank with each
    /// segment's trailing whitespace dropped, so pasting it back adds no
    /// blanks the source did not have (nvim-probed via `nvim -s`, which is
    /// the only way to get a Ctrl-V through a pty intact).
    fn blockYank(self: *Editor, trim: bool) !void {
        const r = self.blockCols();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        const w = try self.blockText(r, &out);
        if (trim) {
            var trimmed: std.ArrayList(u8) = .empty;
            defer trimmed.deinit(self.gpa);
            var it = std.mem.splitScalar(u8, out.items, '\n');
            var first = true;
            while (it.next()) |seg| {
                if (!first) try trimmed.append(self.gpa, '\n');
                first = false;
                try trimmed.appendSlice(self.gpa, std.mem.trimEnd(u8, seg, " \t"));
            }
            self.yankTo(trimmed.items, .blockwise, w);
        } else self.yankTo(out.items, .blockwise, w);
        self.mode = .normal;
        self.cy = r.top;
        self.cx = byteAtDisplayCol(self.buf.line(r.top), r.left);
        self.updateGoal();
    }

    /// Block insert/append: place a caret at the left/right edge of every row in
    /// the block, then enter multi-cursor insert (typing replicates to all rows).
    ///
    /// The two are deliberately asymmetric, and both halves are nvim-verified.
    /// `A` *pads* a line too short to reach the append column with spaces, so
    /// the text still lands in one straight column; `I` *skips* a line that
    /// does not reach the left edge, leaving it untouched. Under `$` — the
    /// block extended to end-of-line — `A` appends at each line's own end and
    /// pads nothing, while `I` is unaffected (the left edge is still a column).
    fn blockInsert(self: *Editor, at_right: bool) !void {
        if (self.rejectReadOnly()) return;
        const r = self.blockCols();
        const to_eol = self.vb_dollar and at_right;
        const dcol = if (at_right) r.right + 1 else r.left;
        // `[count]` is read here: `resetPending` below clears it, and so does
        // the visual dispatcher on the way out.
        const count = self.eff();
        self.clearExtra();
        self.mode = .normal;
        self.pushUndo(); // the padding below is part of the same undo step
        self.placeBlockCarets(r, dcol, if (at_right) .pad else .skip, to_eol);
        // `I` already types at the left edge; only `A` has to be walked back.
        if (at_right and self.mode == .insert) self.vb_origin = .{ .row = r.top, .col = r.left };
        // The anchor is the primary caret, which `placeBlockCarets` just put
        // in place; every other caret gets the same text on Esc.
        if (self.mode == .insert) {
            self.ins_count = count;
            self.ins_anchor = self.cursor();
            self.ins_open_line = false;
        }
        self.resetPending();
    }

    fn blockChange(self: *Editor) !void {
        if (self.rejectReadOnly()) return;
        const r = self.blockCols();
        try self.blockDelete(); // sets cursor to (top, left); pushes undo
        // Like `I`, a line that never reached the left edge is left alone.
        self.placeBlockCarets(r, r.left, .skip, false);
    }

    /// What to do with a row of the block too short to reach `dcol`: `A` pads
    /// it out with spaces, `I` and `c` leave it out of the edit entirely.
    const ShortLine = enum { pad, skip };

    /// Put a caret at `dcol` on every row of `r` and enter multi-cursor insert.
    /// The first row that gets one owns the real cursor — with `.skip`, that
    /// need not be the block's top row. If no row qualifies, nothing is
    /// inserted and we stay in normal mode.
    fn placeBlockCarets(self: *Editor, r: BlockRect, dcol: usize, short: ShortLine, to_eol: bool) void {
        var pad: std.ArrayList(u8) = .empty;
        defer pad.deinit(self.gpa);
        var placed = false;
        var i = r.top;
        while (i <= r.bot) : (i += 1) {
            var line = self.buf.line(i);
            if (!to_eol and displayCol(line, line.len) < dcol) {
                if (short == .skip) continue;
                pad.clearRetainingCapacity();
                pad.appendNTimes(self.gpa, ' ', dcol - displayCol(line, line.len)) catch return;
                self.buf.insertBytes(i, line.len, pad.items) catch return;
                line = self.buf.line(i);
            }
            const col = if (to_eol) line.len else byteAtDisplayCol(line, dcol);
            if (placed) {
                self.extra.append(self.gpa, .{ .head = .{ .row = i, .col = col } }) catch {};
            } else {
                self.cy = i;
                self.cx = col;
                placed = true;
            }
        }
        if (!placed) return;
        self.mode = .insert;
        self.updateGoal();
    }

    // === multiple cursors ==================================================

    const Place = enum { at, after, home, end };

    fn clearExtra(self: *Editor) void {
        self.extra.clearRetainingCapacity();
    }

    fn addCursor(self: *Editor, below: bool) void {
        var extreme = self.cy;
        for (self.extra.items) |e| extreme = if (below) @max(extreme, e.head.row) else @min(extreme, e.head.row);
        if (below) {
            if (extreme + 1 >= self.buf.lineCount()) return;
        } else {
            if (extreme == 0) return;
        }
        const nr = if (below) extreme + 1 else extreme - 1;
        if (nr == self.cy) return;
        for (self.extra.items) |e| if (e.head.row == nr) return;
        const col = byteAtDisplayCol(self.buf.line(nr), self.goal_col);
        self.extra.append(self.gpa, .{ .head = .{ .row = nr, .col = col } }) catch return;
        self.setStatus("{d} cursors", .{self.extra.items.len + 1});
        self.resetPending();
    }

    fn dedupeByLine(self: *Editor) void {
        var i: usize = 0;
        while (i < self.extra.items.len) {
            const e = self.extra.items[i];
            var dup = e.head.row == self.cy;
            if (!dup) {
                var j: usize = 0;
                while (j < i) : (j += 1) {
                    if (self.extra.items[j].head.row == e.head.row) {
                        dup = true;
                        break;
                    }
                }
            }
            if (dup) _ = self.extra.orderedRemove(i) else i += 1;
        }
        for (self.extra.items) |*e| {
            const l = self.buf.line(e.head.row);
            if (e.head.col > l.len) e.head.col = l.len;
        }
    }

    /// The vim motion char an arrow/Home/End key stands for (0 = not one).
    fn arrowChar(k: key.Key) u8 {
        return switch (k) {
            .left => 'h',
            .right => 'l',
            .up => 'k',
            .down => 'j',
            .home => '0',
            .end => '$',
            else => 0,
        };
    }

    /// Returns true if the key was handled across all cursors.
    fn multiNormal(self: *Editor, k: key.Key) !bool {
        switch (k) {
            .escape => {
                self.clearExtra();
                self.resetPending();
                return true;
            },
            .ctrl => |c| switch (c) {
                'n' => {
                    self.addCursor(true);
                    return true;
                },
                'p' => {
                    self.addCursor(false);
                    return true;
                },
                else => return false,
            },
            .char => |c| switch (c) {
                'h', 'l', 'j', 'k', '0', '$', 'w', 'b', 'e', 'W', 'B', 'E' => {
                    self.multiMove(@intCast(c));
                    return true;
                },
                'x' => {
                    try self.multiX();
                    return true;
                },
                'i' => {
                    try self.enterInsertMulti(.at);
                    return true;
                },
                'a' => {
                    try self.enterInsertMulti(.after);
                    return true;
                },
                'I' => {
                    try self.enterInsertMulti(.home);
                    return true;
                },
                'A' => {
                    try self.enterInsertMulti(.end);
                    return true;
                },
                else => return false,
            },
            .left, .right, .up, .down, .home, .end => {
                self.multiMove(arrowChar(k));
                return true;
            },
            else => return false,
        }
    }

    /// Is anything selected — the primary, or any secondary with an anchor?
    fn anySelection(self: *Editor) bool {
        if (self.mode == .visual or self.mode == .visual_line or self.mode == .visual_block) return true;
        for (self.extra.items) |e| {
            if (e.anchor != null) return true;
        }
        return false;
    }

    /// The byte range a secondary selection covers on `row`, for the
    /// renderer. Computed once per row rather than per cell, like the primary
    /// selection's — a frame draws thousands of cells and only tens of rows.
    /// Overlapping extras on one row merge into the span they jointly cover,
    /// which is all the highlight needs to know.
    fn extraSelRange(self: *Editor, row: usize) ?struct { lo: usize, hi: usize } {
        var lo: ?usize = null;
        var hi: usize = 0;
        for (self.extra.items) |e| {
            if (e.anchor == null) continue; // a bare caret highlights nothing
            const r = e.range();
            if (row < r.from.row or row > r.to.row) continue;
            const line = self.buf.line(row);
            const a = if (row == r.from.row) r.from.col else 0;
            const b = if (row == r.to.row) @min(unicode.nextBoundary(line, r.to.col), line.len) else line.len;
            if (lo == null or a < lo.?) lo = a;
            if (b > hi) hi = b;
        }
        const l = lo orelse return null;
        return .{ .lo = l, .hi = hi };
    }

    /// `Ctrl-D` — VS Code's add-selection-to-next-match. The first press
    /// selects the word under the cursor; every one after finds the next
    /// occurrence of that text and adds it as another selection, so typing
    /// replaces them all at once.
    fn addNextMatch(self: *Editor) void {
        if (self.mode != .visual) {
            self.selectWord(.e); // the first press: just take the word
            return;
        }
        var a = self.vstart;
        var b = self.cursor();
        if (cmpPos(b, a) < 0) std.mem.swap(Pos, &a, &b);
        if (a.row != b.row) return self.setStatus("multi-selection is within a line", .{});
        const line = self.buf.line(a.row);
        const end = @min(unicode.nextBoundary(line, b.col), line.len);
        const needle = self.gpa.dupe(u8, line[a.col..end]) catch return;
        defer self.gpa.free(needle);
        if (needle.len == 0) return;

        // Search on from the furthest selection so repeated presses walk
        // forward rather than finding the same match again.
        var from = b;
        for (self.extra.items) |e| {
            const r = e.range();
            if (cmpPos(r.to, from) > 0) from = r.to;
        }
        const start = motion.stepForwardPub(self.buf, from);
        const hit = search.nextLiteral(self.buf, start, needle) orelse
            return self.setStatus("no more matches", .{});
        // Already selected? Then every occurrence is taken. The *primary*
        // counts too: `nextLiteral` wraps, so on a file with one match the
        // search comes straight back to where it started, and checking only
        // the extras added a second selection over the very same text.
        if (hit.row == a.row and hit.col == a.col) return self.setStatus("all matches selected", .{});
        for (self.extra.items) |e| {
            const r = e.range();
            if (r.from.row == hit.row and r.from.col == hit.col) return self.setStatus("all matches selected", .{});
        }
        const hline = self.buf.line(hit.row);
        const tail = @min(hit.col + needle.len, hline.len);
        self.extra.append(self.gpa, .{
            .anchor = hit,
            .head = .{ .row = hit.row, .col = unicode.prevBoundary(hline, tail) },
        }) catch return;
        self.setStatus("{d} selections", .{self.extra.items.len + 1});
    }

    /// Delete what every selection covers, leaving a caret where each was —
    /// what typing over a multi-selection does. Back to front, so an earlier
    /// deletion cannot move a later one.
    fn deleteSelections(self: *Editor) void {
        var ranges: std.ArrayList(SelSpan) = .empty;
        defer ranges.deinit(self.gpa);
        for (self.extra.items) |e| {
            if (e.anchor == null) continue;
            ranges.append(self.gpa, e.range()) catch return;
        }
        // The primary too, when it has one.
        if (self.mode == .visual) {
            var a = self.vstart;
            var b = self.cursor();
            if (cmpPos(b, a) < 0) std.mem.swap(Pos, &a, &b);
            ranges.append(self.gpa, .{ .from = a, .to = b }) catch return;
        }
        if (ranges.items.len == 0) return;
        std.mem.sort(SelSpan, ranges.items, {}, struct {
            fn lt(_: void, x: SelSpan, y: SelSpan) bool {
                return cmpPos(x.from, y.from) < 0;
            }
        }.lt);
        var i = ranges.items.len;
        while (i > 0) {
            i -= 1;
            const r = ranges.items[i];
            const line = self.buf.line(r.to.row);
            const end = @min(unicode.nextBoundary(line, r.to.col), line.len);
            _ = self.deleteSpan(.{ .lines = false, .start = r.from, .end = .{ .row = r.to.row, .col = end } });
        }
        // Every selection becomes the caret where its text used to start.
        for (self.extra.items) |*e| {
            if (e.anchor != null) e.* = .{ .head = e.range().from };
        }
        if (self.mode == .visual) {
            var a = self.vstart;
            const b = self.cursor();
            if (cmpPos(b, a) < 0) a = b;
            self.mode = .insert;
            self.setCursor(a);
        }
        self.buf.dirty = true;
    }

    fn multiMove(self: *Editor, c: u8) void {
        self.setCursor(self.movedCaret(self.cursor(), c));
        for (self.extra.items) |*e| e.* = .{ .head = self.movedCaret(e.head, c) };
        self.dedupeByLine();
        self.resetPending();
    }

    fn movedCaret(self: *Editor, p: Pos, c: u8) Pos {
        const line = self.buf.line(p.row);
        return switch (c) {
            'h' => .{ .row = p.row, .col = unicode.prevBoundary(line, p.col) },
            'l' => .{ .row = p.row, .col = if (p.col < line.len) unicode.nextBoundary(line, p.col) else p.col },
            '0' => .{ .row = p.row, .col = 0 },
            '$' => .{ .row = p.row, .col = line.len },
            'w' => motion.wordForward(self.buf, p, false),
            'W' => motion.wordForward(self.buf, p, true),
            'b' => motion.wordBackward(self.buf, p, false),
            'B' => motion.wordBackward(self.buf, p, true),
            'e' => motion.wordEnd(self.buf, p, false),
            'E' => motion.wordEnd(self.buf, p, true),
            'j' => self.vertCaret(p, true),
            'k' => self.vertCaret(p, false),
            else => p,
        };
    }

    fn vertCaret(self: *Editor, p: Pos, down: bool) Pos {
        if (down) {
            if (p.row + 1 >= self.buf.lineCount()) return p;
        } else {
            if (p.row == 0) return p;
        }
        const nr = if (down) p.row + 1 else p.row - 1;
        const goal = displayCol(self.buf.line(p.row), p.col);
        return .{ .row = nr, .col = byteAtDisplayCol(self.buf.line(nr), goal) };
    }

    fn multiX(self: *Editor) !void {
        if (self.rejectReadOnly()) return;
        self.pushUndo();
        if (self.cx < self.curLine().len) try self.buf.deleteForward(self.cy, self.cx);
        for (self.extra.items) |*e| {
            if (e.head.col < self.buf.line(e.head.row).len) try self.buf.deleteForward(e.head.row, e.head.col);
            const nl = self.buf.line(e.head.row);
            if (e.head.col > nl.len) e.head.col = nl.len;
        }
        self.clampCursor();
        self.updateGoal();
        self.resetPending();
    }

    fn enterInsertMulti(self: *Editor, place: Place) !void {
        if (self.rejectReadOnly()) return;
        self.pushUndo();
        self.cx = self.insertCol(self.cy, self.cx, place);
        for (self.extra.items) |*e| e.head.col = self.insertCol(e.head.row, e.head.col, place);
        self.mode = .insert;
        self.updateGoal();
        self.resetPending();
    }

    fn insertCol(self: *Editor, row: usize, col: usize, place: Place) usize {
        const line = self.buf.line(row);
        return switch (place) {
            .at => @min(col, line.len),
            .after => if (col < line.len) unicode.nextBoundary(line, col) else col,
            .home => motion.firstNonBlank(line),
            .end => line.len,
        };
    }

    fn multiInsert(self: *Editor, k: key.Key) !void {
        try self.insertAtCaret(k);
        for (self.extra.items) |*e| {
            const sy = self.cy;
            const sx = self.cx;
            self.cy = e.head.row;
            self.cx = e.head.col;
            try self.insertAtCaret(k);
            e.* = .{ .head = .{ .row = self.cy, .col = self.cx } };
            self.cy = sy;
            self.cx = sx;
        }
        self.dedupeByLine();
        self.updateGoal();
    }

    /// A within-line insert edit for one caret (never changes the line count,
    /// so cursors on other lines stay valid).
    fn insertAtCaret(self: *Editor, k: key.Key) !void {
        switch (k) {
            .char => |c| self.cx = try self.buf.insertCodepoint(self.cy, self.cx, c),
            .tab => self.cx = try self.buf.insertCodepoint(self.cy, self.cx, '\t'),
            .backspace => if (self.cx > 0) {
                const p = try self.buf.deleteBackward(self.cy, self.cx);
                self.cx = p.col;
            },
            .delete => if (self.cx < self.curLine().len) try self.buf.deleteForward(self.cy, self.cx),
            else => {},
        }
    }

    fn multiInsertMove(self: *Editor, k: key.Key) !void {
        const c = arrowChar(k);
        if (c == 0) return;
        self.multiMove(c);
    }

    fn extraColAt(self: *Editor, row: usize) ?usize {
        for (self.extra.items) |e| if (e.head.row == row) return e.head.col;
        return null;
    }

    // === search ============================================================

    fn runSearch(self: *Editor, query: []const u8, forward: bool) void {
        // A bare `/` or `?` repeats the last pattern in the *new* direction —
        // vim's rule. It used to do nothing, which also made a macro replaying
        // one stop as a failed search would.
        if (query.len == 0) {
            if (self.last_search.items.len == 0) return;
            self.last_search_forward = forward;
            if (!self.jumpSearch(forward)) self.failed = true;
            return;
        }
        self.last_search.clearRetainingCapacity();
        self.last_search.appendSlice(self.gpa, query) catch {};
        self.last_search_forward = forward;
        if (!self.jumpSearch(forward)) self.failed = true;
    }

    /// Jump to the next/previous match of the last pattern. Returns false when
    /// there is none — only the *committed* searches treat that as a failure a
    /// macro should stop at; the incremental preview must not, or a replayed
    /// `/pat` would abort halfway through typing its own pattern and leave the
    /// prompt open.
    fn jumpSearch(self: *Editor, forward: bool) bool {
        if (self.last_search.items.len == 0) return false;
        const re = self.compiledPattern(self.last_search.items) orelse return false; // invalid mid-typing
        const hit = if (forward)
            search.next(self.buf, self.cursor(), re)
        else
            search.prev(self.buf, self.cursor(), re);
        if (hit) |p| {
            self.setCursor(p);
            return true;
        }
        self.setStatus("pattern not found: {s}", .{self.last_search.items});
        return false;
    }

    /// Compile-and-cache `pat` (search patterns are modern regexes; a plain
    /// word is still just a literal and keeps the SIMD fast path). Returns
    /// null for empty or invalid patterns — callers treat that as "no match".
    fn compiledPattern(self: *Editor, pat: []const u8) ?*const regex.Regex {
        if (pat.len == 0) return null;
        if (!std.mem.eql(u8, pat, self.search_re_pat.items)) {
            if (self.search_re) |*old| old.deinit(self.gpa);
            self.search_re = regex.Regex.compile(self.gpa, pat, false) catch null;
            self.search_re_pat.clearRetainingCapacity();
            self.search_re_pat.appendSlice(self.gpa, pat) catch {};
        }
        if (self.search_re) |*re| return re;
        return null;
    }

    /// The term to highlight: the live query while typing a search, otherwise
    /// the last committed search.
    fn activeSearchTerm(self: *Editor) []const u8 {
        if (self.mode == .command and self.searching()) return self.cmd.items;
        return self.last_search.items;
    }

    /// Record the current position (vim: before G/gg/H/M/L/%/search/marks/
    /// buffer switches). Entries on the same line are replaced; a new jump
    /// truncates the forward (Ctrl-i) tail.
    fn addJump(self: *Editor) void {
        self.addJumpAt(self.d, self.cursor());
    }

    fn addJumpAt(self: *Editor, doc: *Doc, pos: Pos) void {
        self.jumps.shrinkRetainingCapacity(@min(self.jump_idx, self.jumps.items.len));
        var i: usize = 0;
        while (i < self.jumps.items.len) {
            const j = self.jumps.items[i];
            if (j.doc == doc and j.pos.row == pos.row) {
                _ = self.jumps.orderedRemove(i);
            } else i += 1;
        }
        if (self.jumps.items.len >= 100) _ = self.jumps.orderedRemove(0);
        self.jumps.append(self.gpa, .{ .doc = doc, .pos = pos }) catch {};
        self.jump_idx = self.jumps.items.len;
    }

    /// Ctrl-o: go to the previous jumplist position (recording the live
    /// position first, so Ctrl-i can come back to it).
    fn jumpBack(self: *Editor) void {
        self.resetPending();
        if (self.jump_idx == 0) return self.setStatus("at oldest jump", .{});
        if (self.jump_idx == self.jumps.items.len) {
            self.jumps.append(self.gpa, .{ .doc = self.d, .pos = self.cursor() }) catch return;
        }
        self.jump_idx -= 1;
        self.gotoJump(self.jumps.items[self.jump_idx]);
    }

    /// Ctrl-i / Tab: go forward again.
    fn jumpForward(self: *Editor) void {
        self.resetPending();
        if (self.jump_idx + 1 >= self.jumps.items.len) return self.setStatus("at newest jump", .{});
        self.jump_idx += 1;
        self.gotoJump(self.jumps.items[self.jump_idx]);
    }

    fn gotoJump(self: *Editor, j: Jump) void {
        if (j.doc != self.d) self.focusDoc(j.doc);
        self.cy = @min(j.pos.row, self.buf.lineCount() - 1);
        self.cx = @min(j.pos.col, self.curLine().len);
        self.updateGoal();
    }

    fn repeatSearch(self: *Editor, same_dir: bool) void {
        self.addJump();
        const fwd = if (same_dir) self.last_search_forward else !self.last_search_forward;
        if (!self.jumpSearch(fwd)) self.failed = true;
        self.resetPending();
    }

    /// `*` / `#`: search for the word under the cursor, with vim's whole-word
    /// boundaries (the pattern becomes `\<word\>`, metacharacters escaped).
    fn searchWord(self: *Editor, forward: bool, bounded: bool) void {
        const word = search.wordUnder(self.buf, self.cursor());
        if (word.len == 0) {
            self.resetPending();
            return;
        }
        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(self.gpa);
        if (bounded) pat.appendSlice(self.gpa, "\\<") catch return;
        for (word) |ch| {
            if (std.mem.indexOfScalar(u8, ".\\*+?()[]|^$/<>{}", ch) != null)
                pat.append(self.gpa, '\\') catch return;
            pat.append(self.gpa, ch) catch return;
        }
        if (bounded) pat.appendSlice(self.gpa, "\\>") catch return;
        self.addJump();
        self.runSearch(pat.items, forward);
        self.resetPending();
    }

    // === the non-modal keymaps (vscode / zed) ==============================

    /// True while the editor is answering VS Code's keys rather than vim's.
    fn nonModal() bool {
        return config.settings.keymap != .vim;
    }

    /// A selection under the non-modal keymaps is an ordinary visual
    /// selection; what differs is how it starts and ends. Shift+motion opens
    /// one at the cursor and extends it, and any *unshifted* motion drops it —
    /// which is what makes arrow keys behave the way everyone outside vim
    /// expects.
    fn shiftSelect(self: *Editor, extend: bool) void {
        const in_visual = self.mode == .visual or self.mode == .visual_line or self.mode == .visual_block;
        if (extend) {
            if (!in_visual) {
                const at = self.cursor();
                self.enterVisual(.visual);
                self.vstart = at;
            }
        } else if (in_visual) {
            self.mode = .insert;
        }
    }

    /// Whatever is selected, as text — for `Ctrl-C` / `Ctrl-X`.
    fn selectionText(self: *Editor) ?[]u8 {
        const in_visual = self.mode == .visual or self.mode == .visual_line or self.mode == .visual_block;
        if (!in_visual) return null;
        var a = self.vstart;
        var b = self.cursor();
        if (cmpPos(b, a) < 0) std.mem.swap(Pos, &a, &b);
        const line = self.buf.line(b.row);
        const span: Span = if (self.mode == .visual_line)
            .{ .lines = true, .top = a.row, .bot = b.row }
        else
            .{ .lines = false, .start = a, .end = .{ .row = b.row, .col = unicode.nextBoundary(line, b.col) } };
        return self.extract(span) catch null;
    }

    /// `Alt-Up` / `Alt-Down` — move the current line (or the selected lines)
    /// one row, taking the selection with it. VS Code's, and one of the few
    /// chords with no vim equivalent to delegate to.
    fn moveLines(self: *Editor, down: bool) void {
        if (self.rejectReadOnly()) return;
        const in_visual = self.mode == .visual or self.mode == .visual_line;
        var top = self.cy;
        var bot = self.cy;
        if (in_visual) {
            top = @min(self.vstart.row, self.cy);
            bot = @max(self.vstart.row, self.cy);
        }
        const last = self.buf.lineCount() - 1;
        if (down and bot >= last) return;
        if (!down and top == 0) return;
        self.pushUndo();
        if (down) {
            // Lift the line below the block and drop it above.
            const moved = self.gpa.dupe(u8, self.buf.line(bot + 1)) catch return;
            defer self.gpa.free(moved);
            self.buf.removeLineAt(bot + 1);
            self.buf.insertLineAt(top, moved) catch return;
        } else {
            const moved = self.gpa.dupe(u8, self.buf.line(top - 1)) catch return;
            defer self.gpa.free(moved);
            self.buf.removeLineAt(top - 1);
            self.buf.insertLineAt(bot, moved) catch return;
        }
        self.buf.dirty = true;
        const delta: isize = if (down) 1 else -1;
        self.cy = @intCast(@as(isize, @intCast(self.cy)) + delta);
        if (in_visual) self.vstart.row = @intCast(@as(isize, @intCast(self.vstart.row)) + delta);
        self.clampCursor();
        self.updateGoal();
    }

    /// `Shift-Alt-Up` / `Shift-Alt-Down` — copy the line (or the selected
    /// lines) above or below.
    fn duplicateLines(self: *Editor, down: bool) void {
        if (self.rejectReadOnly()) return;
        const in_visual = self.mode == .visual or self.mode == .visual_line;
        const top = if (in_visual) @min(self.vstart.row, self.cy) else self.cy;
        const bot = if (in_visual) @max(self.vstart.row, self.cy) else self.cy;
        self.pushUndo();
        var copies: std.ArrayList([]u8) = .empty;
        defer {
            for (copies.items) |c| self.gpa.free(c);
            copies.deinit(self.gpa);
        }
        var row = top;
        while (row <= bot) : (row += 1) {
            const c = self.gpa.dupe(u8, self.buf.line(row)) catch return;
            copies.append(self.gpa, c) catch {
                self.gpa.free(c);
                return;
            };
        }
        var at = if (down) bot + 1 else top;
        for (copies.items) |c| {
            self.buf.insertLineAt(at, c) catch return;
            at += 1;
        }
        self.buf.dirty = true;
        if (down) {
            const n = bot - top + 1;
            self.cy += n;
            if (in_visual) self.vstart.row += n;
        }
        self.clampCursor();
        self.updateGoal();
    }

    /// The non-modal dispatch. Returns true when the key was one of these
    /// keymaps' own, so the caller knows not to run the modal path.
    ///
    /// Everything here delegates to a command the editor already had; what is
    /// new is only which key reaches it. Where VS Code has something zedit
    /// does not — `Ctrl-D`'s add-cursor-at-next-match above all — the chord
    /// does the nearest honest thing rather than pretending.
    fn keymapKey(self: *Editor, k: key.Key) !bool {
        if (!nonModal()) return false;
        // The command line, pickers and the shell own the keyboard outright.
        switch (self.mode) {
            .command, .picker, .terminal => return false,
            else => {},
        }

        // Typing over a selection replaces it — every selection, when there
        // is more than one. The key itself then inserts at each caret the
        // deletion left behind, which is the multi-caret path insert mode
        // already takes.
        switch (k) {
            .char, .enter, .tab => if (self.anySelection()) {
                self.pushUndo();
                self.deleteSelections();
                return false;
            },
            .backspace, .delete => if (self.anySelection()) {
                self.pushUndo();
                self.deleteSelections();
                return true; // the selection *was* the deletion
            },
            else => {},
        }

        // An *unmodified* motion collapses a selection, which is what makes
        // arrow keys behave the way everyone outside vim expects. The key
        // itself is then left to the ordinary insert handling.
        switch (k) {
            .left, .right, .up, .down, .home, .end, .page_up, .page_down => {
                self.shiftSelect(false);
                return false;
            },
            else => {},
        }

        switch (k) {
            .modified => |m| {
                // Shift extends a selection; anything else drops it first.
                self.shiftSelect(m.mods.shift);
                switch (m.nav) {
                    // `repeatMotion` and `repeatWord` take their direction at
                    // comptime, so the two sides are written out rather than
                    // selected into.
                    .left => if (m.mods.ctrl)
                        self.doMotion(self.repeatWord(.b, false))
                    else
                        self.doMotion(self.repeatMotion(.left)),
                    .right => if (m.mods.ctrl)
                        self.doMotion(self.repeatWord(.f, false))
                    else
                        self.doMotion(self.repeatMotion(.right)),
                    .up, .down => {
                        // Alt moves the line rather than the cursor; with
                        // Shift as well it copies it.
                        if (m.mods.alt) {
                            if (m.mods.shift) self.duplicateLines(m.nav == .down) else self.moveLines(m.nav == .down);
                            return true;
                        }
                        self.doMotion(self.vertical(m.nav == .up, 1));
                    },
                    .home => if (m.mods.ctrl) {
                        self.setCursor(.{ .row = 0, .col = 0 });
                    } else self.doMotion(.{ .pos = .{ .row = self.cy, .col = 0 }, .kind = .exclusive, .col_mode = .exact }),
                    .end => if (m.mods.ctrl) {
                        const last = self.buf.lineCount() - 1;
                        self.setCursor(.{ .row = last, .col = self.buf.line(last).len });
                    } else self.setCursor(.{ .row = self.cy, .col = self.curLine().len }),
                    .page_up, .page_down => self.pageMove(m.nav == .page_up),
                    .delete => try self.buf.deleteForward(self.cy, self.cx),
                }
                return true;
            },
            .ctrl => |c| switch (c) {
                's' => {
                    _ = try self.write("");
                    return true;
                },
                'p' => {
                    self.openFilePicker();
                    return true;
                },
                'f' => {
                    self.enterCmd(.search_forward);
                    return true;
                },
                'h' => { // VS Code's replace; zedit's is `:%s`
                    self.enterCmd(.ex);
                    self.cmd.appendSlice(self.gpa, "%s/") catch {};
                    self.cmd_cur = self.cmd.items.len;
                    return true;
                },
                'g' => { // goto line
                    self.enterCmd(.ex);
                    return true;
                },
                'z' => {
                    self.undoChange();
                    return true;
                },
                'y' => {
                    self.redoChange();
                    return true;
                },
                'a' => { // select the whole file
                    self.setCursor(.{ .row = 0, .col = 0 });
                    self.enterVisual(.visual_line);
                    const last = self.buf.lineCount() - 1;
                    self.setCursor(.{ .row = last, .col = self.buf.line(last).len });
                    return true;
                },
                'c', 'x' => {
                    if (self.selectionText()) |text| {
                        defer self.gpa.free(text);
                        self.yankTo(text, if (self.mode == .visual_line) .linewise else .charwise, 0);
                        self.osc52Copy(text);
                        if (c == 'x') try self.visualOperator(.delete) else self.mode = .insert;
                    }
                    return true;
                },
                'v' => {
                    try self.paste(true, true);
                    self.mode = .insert;
                    return true;
                },
                'd' => { // select the word, then each next occurrence
                    self.addNextMatch();
                    return true;
                },
                'b' => {
                    self.sidebarToggle();
                    return true;
                },
                'w' => {
                    self.closeDoc(false);
                    return true;
                },
                '/' => { // Ctrl-/ — comment toggle, 0x1f on the wire
                    const in_visual = self.mode == .visual or self.mode == .visual_line;
                    const top = if (in_visual) @min(self.vstart.row, self.cy) else self.cy;
                    const bot = if (in_visual) @max(self.vstart.row, self.cy) else self.cy;
                    if (in_visual) self.mode = .insert;
                    self.toggleComment(.{ .lines = true, .top = top, .bot = bot });
                    return true;
                },
                else => return false,
            },
            .escape => {
                // VS Code's Esc: drop the selection or close a popup, and
                // never leave you unable to type.
                if (self.comp_open or self.sig_open) {
                    self.comp_open = false;
                    self.sig_open = false;
                } else {
                    // Collapse to a caret *after* the selection, which is
                    // where VS Code leaves it — zedit's visual head sits on
                    // the last selected cell, one short of that.
                    if (self.mode == .visual) {
                        const line = self.curLine();
                        if (self.cx < line.len) self.cx = unicode.nextBoundary(line, self.cx);
                    }
                    self.mode = .insert;
                    self.extra.clearRetainingCapacity(); // back to one caret
                    self.updateGoal();
                }
                return true;
            },
            else => return false,
        }
    }

    // === the Ctrl namespace ================================================

    /// `Ctrl-A` / `Ctrl-X` — add or subtract `n` from the number at or after
    /// the cursor. vim's rules, nvim-probed: a leading `-` belongs to the
    /// number, `0x` makes it hexadecimal, leading zeros keep the width
    /// (`0042` becomes `0043`), and the cursor ends on its last character.
    fn incrementNumber(self: *Editor, by: i64, n: usize) void {
        if (self.rejectReadOnly()) return;
        self.pushUndo();
        if (!self.incrementAt(self.cy, self.cx, by * @as(i64, @intCast(n))))
            self.setStatus("no number under or after the cursor", .{});
    }

    /// Bump the number at or after `col` on `row` by `delta`. True when there
    /// was one — the visual forms walk lines and simply skip those without.
    /// The caller has already pushed an undo state, so a selection's worth of
    /// bumps is one change.
    fn incrementAt(self: *Editor, row: usize, col: usize, delta: i64) bool {
        const line = self.buf.line(row);
        const span = motion.numberAt(line, col) orelse return false;
        const text = line[span.start..span.end];

        var body: [64]u8 = undefined; // the digits, unpadded
        var buf: [80]u8 = undefined; // the finished literal
        var neg = false;
        var want: usize = 0; // digits the source had, for keeping its width
        const digits: []const u8 = if (span.hex) blk: {
            const v = std.fmt.parseInt(u64, text[2..], 16) catch return false;
            const nv = @as(u64, @bitCast(@as(i64, @bitCast(v)) +% delta));
            want = text.len - 2;
            break :blk std.fmt.bufPrint(&body, "{x}", .{nv}) catch return false;
        } else blk: {
            const v = std.fmt.parseInt(i64, text, 10) catch return false;
            const nv = v +% delta;
            neg = nv < 0;
            // Leading zeros are inside the span, so the width is kept — but
            // only when the source actually had them (`41` stays two wide by
            // accident, `0042` on purpose).
            const src = if (text.len > 0 and text[0] == '-') text[1..] else text;
            if (src.len > 1 and src[0] == '0') want = src.len;
            break :blk std.fmt.bufPrint(&body, "{d}", .{@abs(nv)}) catch return false;
        };

        const pad = if (want > digits.len) want - digits.len else 0;
        var w: usize = 0;
        if (span.hex) {
            buf[0] = '0';
            buf[1] = 'x';
            w = 2;
        } else if (neg) {
            buf[0] = '-';
            w = 1;
        }
        if (w + pad + digits.len > buf.len) return false;
        var k: usize = 0;
        while (k < pad) : (k += 1) {
            buf[w] = '0';
            w += 1;
        }
        @memcpy(buf[w .. w + digits.len], digits);
        const out: []const u8 = buf[0 .. w + digits.len];

        const owned = self.gpa.dupe(u8, out) catch return false;
        defer self.gpa.free(owned);
        var i = span.end;
        while (i > span.start) : (i -= 1) self.buf.deleteForward(row, span.start) catch return false;
        self.buf.insertBytes(row, span.start, owned) catch return false;
        self.buf.dirty = true;
        // vim leaves the cursor on the number's last character.
        self.cy = row;
        self.cx = span.start + owned.len - 1;
        self.updateGoal();
        return true;
    }

    /// Visual `Ctrl-A`/`Ctrl-X`, and their `g` forms which step the amount
    /// line by line: `g Ctrl-A` over `1 1 1 1` leaves `2 3 4 5`. Only lines
    /// that actually hold a number advance the step (nvim's rule), and the
    /// whole selection is one undoable change.
    fn visualIncrement(self: *Editor, by: i64, n: usize, progressive: bool) void {
        if (self.rejectReadOnly()) return;
        var a = self.vstart;
        var b = self.cursor();
        if (cmpPos(b, a) < 0) std.mem.swap(Pos, &a, &b);
        const charwise = self.mode == .visual;
        self.mode = .normal;
        self.pushUndo();
        var step: i64 = 0;
        var row = a.row;
        while (row <= @min(b.row, self.buf.lineCount() - 1)) : (row += 1) {
            // Charwise starts where the selection did on its first line.
            const from: usize = if (charwise and row == a.row) a.col else 0;
            const mult = if (progressive) step + 1 else 1;
            if (self.incrementAt(row, from, by * @as(i64, @intCast(n)) * mult)) step += 1;
        }
        self.setCursor(.{ .row = a.row, .col = @min(a.col, self.buf.line(a.row).len) });
        self.resetPending();
    }

    /// `D` `X` `Y` `C` `R` in visual — the forms that take whole *lines*
    /// however the selection was made, so `vlD` deletes the line rather than
    /// the two characters under it.
    fn visualLinewise(self: *Editor, op: Operator) !void {
        const top = @min(self.vstart.row, self.cy);
        const bot = @max(self.vstart.row, self.cy);
        self.mode = .normal;
        self.applyOperator(op, .{ .lines = true, .top = top, .bot = bot });
        self.resetPending();
    }

    /// Visual `r` — every character in the selection becomes `ch`, the line
    /// keeping its length.
    fn visualReplaceChar(self: *Editor, ch: u21) void {
        if (self.rejectReadOnly()) return;
        var a = self.vstart;
        var b = self.cursor();
        if (cmpPos(b, a) < 0) std.mem.swap(Pos, &a, &b);
        const linewise = self.mode == .visual_line;
        const block = self.mode == .visual_block;
        const cols = if (block) self.blockCols() else undefined;
        self.mode = .normal;
        self.pushUndo();
        var row = a.row;
        while (row <= @min(b.row, self.buf.lineCount() - 1)) : (row += 1) {
            const line = self.buf.line(row);
            var lo: usize = 0;
            var hi: usize = line.len;
            if (block) {
                lo = @min(byteAtDisplayCol(line, cols.left), line.len);
                hi = @min(unicode.nextBoundary(line, byteAtDisplayCol(line, cols.right)), line.len);
            } else if (!linewise) {
                if (row == a.row) lo = @min(a.col, line.len);
                if (row == b.row) hi = @min(unicode.nextBoundary(line, b.col), line.len);
            }
            var i = lo;
            while (i < hi) {
                const w = unicode.nextBoundary(self.buf.line(row), i) - i;
                self.buf.deleteForward(row, i) catch break;
                i = self.buf.insertCodepoint(row, i, ch) catch break;
                _ = w;
                if (i > hi) break;
            }
        }
        self.buf.dirty = true;
        self.setCursor(.{ .row = a.row, .col = @min(a.col, self.buf.line(a.row).len) });
        self.resetPending();
    }

    /// `Ctrl-E` / `Ctrl-Y` — scroll the window one line without moving the
    /// cursor, which follows only when it would otherwise leave the screen.
    fn scrollLines(self: *Editor, down: bool, n: usize) void {
        // Settle the viewport first: a burst of keys (`50G` then Ctrl-E in
        // one read) arrives before the frame that would have scrolled, and
        // scrolling from a stale top lands somewhere else entirely.
        self.scroll();
        const rows = self.textRows();
        const last = self.buf.lineCount() - 1;
        if (down) self.top = @min(self.top + n, last) else self.top -|= n;
        if (self.cy < self.top) self.cy = self.top;
        const bot = self.lineAtScreenRow(rows - 1);
        if (self.cy > bot) self.cy = bot;
        self.clampCursor();
        self.updateGoal();
    }

    /// `Ctrl-G` — the file, where the cursor is in it, and whether it has
    /// unsaved changes. vim's shortest status line.
    fn showFileInfo(self: *Editor) void {
        const pct = if (self.buf.lineCount() == 0) 0 else (self.cy + 1) * 100 / self.buf.lineCount();
        self.setStatus("\"{s}\"{s} {d} lines --{d}%--", .{
            docLabel(self.d),
            if (self.buf.dirty) " [+]" else "",
            self.buf.lineCount(),
            pct,
        });
    }

    /// `Ctrl-Z` — stop, and pick everything back up when the shell resumes
    /// us. The window may have been resized while we were away and the shell
    /// has printed over the primary screen, so the size is taken again and
    /// the whole frame redrawn rather than diffed against a stale one.
    fn suspendEditor(self: *Editor) void {
        self.term.suspendSelf(config.settings.mouse);
        self.win = self.term.size();
        self.prev_valid = false;
        self.resetPending();
    }

    /// `Ctrl-^` — back to the buffer shown before this one, which is what
    /// makes flipping between two files a single keystroke.
    fn editAlternate(self: *Editor) void {
        const alt = self.alt_doc orelse return self.setStatus("no alternate file", .{});
        for (self.docs.items) |d| {
            if (d == alt) return self.focusDoc(alt);
        }
        self.setStatus("no alternate file", .{});
    }

    // === the bracket namespace =============================================

    /// `[(` `])` `[{` `]}` — the nearest *unmatched* bracket in a direction,
    /// counting depth so a balanced pair in between is skipped. Null when the
    /// cursor is not inside one.
    fn unmatchedBracket(self: *Editor, open: u8, close: u8, forward: bool, n: usize) ?Pos {
        var depth: usize = 0;
        var found: usize = 0;
        var p = self.cursor();
        while (true) {
            const next = if (forward) motion.stepForwardPub(self.buf, p) else motion.stepBackwardPub(self.buf, p);
            if (next.row == p.row and next.col == p.col) return null; // hit an end
            p = next;
            const line = self.buf.line(p.row);
            if (p.col >= line.len) continue;
            const c = line[p.col];
            // Walking *out*: the bracket we came through deepens, the one we
            // are looking for closes the level — and at depth 0 it is ours.
            const inner = if (forward) open else close;
            const outer = if (forward) close else open;
            if (c == inner) {
                depth += 1;
            } else if (c == outer) {
                if (depth == 0) {
                    found += 1;
                    if (found == n) return p;
                } else depth -= 1;
            }
        }
    }

    /// `[[` `]]` `[]` `][` — vim's sections: a `{` (or `}`) in column 0. With
    /// none in the file the motion runs to the start or end of it, which is
    /// what nvim does rather than refusing.
    fn sectionMove(self: *Editor, brace: u8, forward: bool, n: usize) Pos {
        var found: usize = 0;
        var row = self.cy;
        while (true) {
            if (forward) {
                if (row + 1 >= self.buf.lineCount()) return .{ .row = self.buf.lineCount() - 1, .col = 0 };
                row += 1;
            } else {
                if (row == 0) return .{ .row = 0, .col = 0 };
                row -= 1;
            }
            const line = self.buf.line(row);
            if (line.len > 0 and line[0] == brace) {
                found += 1;
                if (found == n) return .{ .row = row, .col = 0 };
            }
        }
    }

    /// `[/` `[*` and `]/` `]*` — the start of the previous C comment, or the
    /// end of the next one.
    fn commentEdge(self: *Editor, forward: bool) ?Pos {
        const needle = if (forward) "*/" else "/*";
        var row = self.cy;
        var col = self.cx;
        while (true) {
            const line = self.buf.line(row);
            if (forward) {
                if (col < line.len) {
                    if (std.mem.indexOfPos(u8, line, col, needle)) |at|
                        return .{ .row = row, .col = at + 1 }; // the `/` of `*/`
                }
                if (row + 1 >= self.buf.lineCount()) return null;
                row += 1;
                col = 0;
            } else {
                const upto = @min(col, line.len);
                if (std.mem.lastIndexOf(u8, line[0..upto], needle)) |at|
                    return .{ .row = row, .col = at };
                if (row == 0) return null;
                row -= 1;
                col = self.buf.line(row).len;
            }
        }
    }

    /// `[#` `]#` — the previous unmatched `#if`/`#else`, or the next
    /// `#else`/`#endif`, counting nesting on the way.
    fn preprocEdge(self: *Editor, forward: bool) ?Pos {
        var depth: usize = 0;
        var row = self.cy;
        while (true) {
            if (forward) {
                if (row + 1 >= self.buf.lineCount()) return null;
                row += 1;
            } else {
                if (row == 0) return null;
                row -= 1;
            }
            const t = std.mem.trimStart(u8, self.buf.line(row), " \t");
            if (t.len == 0 or t[0] != '#') continue;
            const d = std.mem.trimStart(u8, t[1..], " \t");
            const opens = std.mem.startsWith(u8, d, "if");
            const ends = std.mem.startsWith(u8, d, "endif");
            const mid = std.mem.startsWith(u8, d, "else") or std.mem.startsWith(u8, d, "elif");
            // Going up, an `#endif` deepens and an `#if` closes the level;
            // going down it is the other way round.
            const deepen = if (forward) opens else ends;
            const shallow = if (forward) ends else opens;
            if (deepen) {
                depth += 1;
            } else if (shallow) {
                if (depth == 0) return .{ .row = row, .col = 0 };
                depth -= 1;
            } else if (mid and depth == 0) {
                return .{ .row = row, .col = 0 };
            }
        }
    }

    /// `['` `]'` `` [` `` `` ]` `` — the nearest mark before or after the
    /// cursor. `exact` keeps its column; otherwise the first non-blank.
    fn markStep(self: *Editor, forward: bool, exact: bool) void {
        var best: ?Pos = null;
        for (self.marks) |m| {
            const p = m orelse continue;
            const rel = cmpPos(p, self.cursor());
            if (forward and rel <= 0) continue;
            if (!forward and rel >= 0) continue;
            if (best) |b| {
                if (forward and cmpPos(p, b) >= 0) continue;
                if (!forward and cmpPos(p, b) <= 0) continue;
            }
            best = p;
        }
        const p = best orelse return;
        self.cy = @min(p.row, self.buf.lineCount() - 1);
        self.cx = if (exact) @min(p.col, self.curLine().len) else motion.firstNonBlank(self.curLine());
        self.updateGoal();
    }

    /// `[m` `]m` — the previous or next `{`, which is where a member's body
    /// begins (nvim-probed: on a C file it lands on the brace, not the line).
    fn memberStep(self: *Editor, forward: bool, n: usize) void {
        var found: usize = 0;
        var p = self.cursor();
        while (true) {
            const next = if (forward) motion.stepForwardPub(self.buf, p) else motion.stepBackwardPub(self.buf, p);
            if (next.row == p.row and next.col == p.col) return;
            p = next;
            const line = self.buf.line(p.row);
            if (p.col < line.len and line[p.col] == '{') {
                found += 1;
                if (found == n) {
                    self.setCursor(p);
                    return;
                }
            }
        }
    }

    /// `] ` and `[ ` — blank lines below or above, without moving the cursor.
    fn addBlankLines(self: *Editor, below: bool, n: usize) void {
        if (self.rejectReadOnly()) return;
        self.pushUndo();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.buf.insertLineAt(if (below) self.cy + 1 else self.cy, "") catch return;
            if (!below) self.cy += 1; // the cursor's line moved down with it
        }
        self.buf.dirty = true;
    }

    /// `]p` `[p` `]P` `[P` — paste linewise with each line's indent replaced
    /// by the current line's, which is what makes a snippet land level with
    /// where it is going.
    fn pasteIndented(self: *Editor, after: bool) void {
        if (self.rejectReadOnly()) return;
        const reg = self.registers.get(self.pending_register) orelse return;
        const cur = self.curLine();
        const lead = self.gpa.dupe(u8, cur[0..motion.firstNonBlank(cur)]) catch return;
        defer self.gpa.free(lead);
        self.pushUndo();
        var at = if (after) self.cy + 1 else self.cy;
        const first = at;
        var it = std.mem.splitScalar(u8, trimTrailingNewline(reg.text), '\n');
        while (it.next()) |ln| {
            const body = std.mem.trimStart(u8, ln, " \t");
            const joined = std.mem.concat(self.gpa, u8, &.{ lead, body }) catch return;
            defer self.gpa.free(joined);
            self.buf.insertLineAt(at, joined) catch return;
            at += 1;
        }
        self.buf.dirty = true;
        self.cy = @min(first, self.buf.lineCount() - 1);
        self.cx = motion.firstNonBlank(self.curLine());
        self.updateGoal();
    }

    // === the rest of the `g` namespace =====================================

    /// `g_`: the last non-blank of the line `count - 1` lower. An all-blank
    /// line has none, and the cursor goes to column 0 (nvim-probed).
    fn lastNonBlank(self: *Editor, n: usize) MotionResult {
        const row = @min(self.cy + n - 1, self.buf.lineCount() - 1);
        const line = self.buf.line(row);
        var col: usize = 0;
        var i: usize = 0;
        while (i < line.len) : (i = unicode.nextBoundary(line, i)) {
            if (line[i] != ' ' and line[i] != '\t') col = i;
        }
        return .{ .pos = .{ .row = row, .col = col }, .kind = .inclusive, .col_mode = .exact };
    }

    /// `g^`: the first non-blank of the *screen* row, so a wrapped line has
    /// one per row rather than only at its real start.
    fn screenFirstNonBlank(self: *Editor) MotionResult {
        const left = self.screenLineEdge(false).pos;
        const line = self.buf.line(left.row);
        var i = left.col;
        const stop = self.screenLineEdge(true).pos.col;
        while (i < line.len and i <= stop and (line[i] == ' ' or line[i] == '\t'))
            i = unicode.nextBoundary(line, i);
        return .{ .pos = .{ .row = left.row, .col = @min(i, line.len) }, .kind = .exclusive, .col_mode = .exact };
    }

    /// `gm`: the character halfway across the *window*, clamped to the line.
    /// `gM`: halfway along the line's own text.
    fn middleOfLine(self: *Editor, screen: bool) MotionResult {
        const line = self.curLine();
        const target = if (screen) self.textCols() / 2 else displayCol(line, line.len) / 2;
        return .{
            .pos = .{ .row = self.cy, .col = byteAtDisplayCol(line, target) },
            .kind = .exclusive,
            .col_mode = .exact,
        };
    }

    /// `go`: the position of byte `n` (1-based) counting the newline that ends
    /// each line, as vim does.
    fn byteOffsetPos(self: *Editor, n: usize) MotionResult {
        var left = n -| 1;
        var row: usize = 0;
        while (row < self.buf.lineCount()) : (row += 1) {
            const len = self.buf.line(row).len;
            if (left <= len) return .{
                .pos = .{ .row = row, .col = left },
                .kind = .exclusive,
                .col_mode = .exact,
            };
            left -= len + 1; // the line break is a byte too
        }
        const last = self.buf.lineCount() - 1;
        return .{ .pos = .{ .row = last, .col = self.buf.line(last).len }, .kind = .exclusive, .col_mode = .exact };
    }

    /// `g8`: the UTF-8 bytes of the character under the cursor, in hex — vim's
    /// answer to "what exactly is this character".
    fn showByteValue(self: *Editor) void {
        const line = self.curLine();
        if (self.cx >= line.len) return self.setStatus("empty line", .{});
        const d = unicode.decode(line[self.cx..]);
        var buf: [64]u8 = undefined;
        var w: usize = 0;
        for (line[self.cx .. self.cx + d.len]) |b| {
            w += (std.fmt.bufPrint(buf[w..], "{x:0>2} ", .{b}) catch break).len;
        }
        self.setStatus("<{u}> {d}, hex {s}", .{ d.cp, d.cp, std.mem.trimEnd(u8, buf[0..w], " ") });
    }

    /// `g Ctrl-G`: where the cursor is, in every unit vim counts.
    fn showCursorInfo(self: *Editor) void {
        var bytes: usize = 0;
        var row: usize = 0;
        while (row < self.cy) : (row += 1) bytes += self.buf.line(row).len + 1;
        self.setStatus("line {d} of {d}; col {d}; byte {d}", .{
            self.cy + 1,
            self.buf.lineCount(),
            self.cx + 1,
            bytes + self.cx + 1,
        });
    }

    /// `gf` / `gF`: open the file named under the cursor. The name comes from
    /// the same reader `gx` uses, so a quoted path or a markdown link yields
    /// the path alone. `gF` additionally honours a trailing `:line`.
    fn openFileUnderCursor(self: *Editor, with_line: bool) void {
        const target = motion.targetUnderCursor(self.curLine(), self.cx) orelse
            return self.setStatus("no file name under the cursor", .{});
        var name = target;
        var row: usize = 0;
        if (with_line) {
            if (std.mem.lastIndexOfScalar(u8, target, ':')) |at| {
                if (std.fmt.parseInt(usize, target[at + 1 ..], 10) catch null) |n| {
                    name = target[0..at];
                    row = n -| 1;
                }
            }
        }
        // A relative name is relative to the file being edited, as in vim.
        var buf: [1024]u8 = undefined;
        var full = name;
        if (name.len > 0 and name[0] != '/' and !remote.isRemote(name)) {
            if (self.buf.path) |p| {
                if (std.fs.path.dirname(p)) |dir| {
                    full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch name;
                }
            }
        }
        self.openFile(full, row);
    }

    /// `g;` / `g,` — the change list. Every change records where it happened;
    /// these walk that record backwards and forwards, which is how a session
    /// of edits scattered through a file is retraced without marks.
    fn changeListStep(self: *Editor, back: bool, n: usize) void {
        const list = self.d.changes.items;
        if (list.len == 0) return self.setStatus("change list is empty", .{});
        var i: isize = @intCast(self.d.change_idx);
        var k = n;
        while (k > 0) : (k -= 1) {
            const next = if (back) i - 1 else i + 1;
            if (next < 0 or next >= @as(isize, @intCast(list.len))) break;
            i = next;
        }
        self.d.change_idx = @intCast(@max(0, i));
        const p = list[self.d.change_idx];
        self.cy = @min(p.row, self.buf.lineCount() - 1);
        self.cx = @min(p.col, self.curLine().len);
        self.updateGoal();
    }

    /// Record where a change happened, for `g;`. Same-line changes replace the
    /// previous entry rather than filling the list with one stop per keystroke
    /// (vim's rule), and the list is capped like the jumplist.
    fn noteChange(self: *Editor) void {
        const p = self.cursor();
        const list = &self.d.changes;
        if (list.items.len > 0 and list.items[list.items.len - 1].row == p.row) {
            list.items[list.items.len - 1] = p;
        } else {
            if (list.items.len >= 100) _ = list.orderedRemove(0);
            list.append(self.gpa, p) catch return;
        }
        self.d.change_idx = list.items.len; // a fresh change resets the walk
    }

    /// `gq{motion}` / `gw{motion}`: reflow the lines a motion covers to
    /// `wrap_column` (79 when it is 0, vim's own fallback for `textwidth=0`).
    /// Words are never split; the paragraph's leading indent is kept on every
    /// line it produces. `gw` puts the cursor back where it started, which is
    /// the only difference between the two.
    fn reflow(self: *Editor, span: Span, keep_cursor: bool) void {
        const at = self.cursor();
        const width = if (config.settings.wrap_column > 0) config.settings.wrap_column else 79;
        const top = span.top;
        const bot = @min(span.bot, self.buf.lineCount() - 1);
        if (top > bot) return;

        // Gather the words, and the indent the first line carries.
        var words: std.ArrayList([]u8) = .empty;
        defer {
            for (words.items) |w| self.gpa.free(w);
            words.deinit(self.gpa);
        }
        const first = self.buf.line(top);
        const lead = self.gpa.dupe(u8, first[0..motion.firstNonBlank(first)]) catch return;
        defer self.gpa.free(lead);
        var row = top;
        while (row <= bot) : (row += 1) {
            var it = std.mem.tokenizeAny(u8, self.buf.line(row), " \t");
            while (it.next()) |w| {
                const owned = self.gpa.dupe(u8, w) catch return;
                words.append(self.gpa, owned) catch {
                    self.gpa.free(owned);
                    return;
                };
            }
        }
        if (words.items.len == 0) return;

        var out: std.ArrayList([]u8) = .empty;
        defer {
            for (out.items) |l| self.gpa.free(l);
            out.deinit(self.gpa);
        }
        var cur: std.ArrayList(u8) = .empty;
        defer cur.deinit(self.gpa);
        cur.appendSlice(self.gpa, lead) catch return;
        var empty = true;
        for (words.items) |w| {
            // `> width` rather than `>=`: vim fills up to and including the
            // column, breaking only once a word would pass it.
            if (!empty and cur.items.len + 1 + w.len > width) {
                out.append(self.gpa, cur.toOwnedSlice(self.gpa) catch return) catch return;
                cur.appendSlice(self.gpa, lead) catch return;
                empty = true;
            }
            if (!empty) cur.append(self.gpa, ' ') catch return;
            cur.appendSlice(self.gpa, w) catch return;
            empty = false;
        }
        out.append(self.gpa, cur.toOwnedSlice(self.gpa) catch return) catch return;

        self.pushUndo();
        var r = bot;
        while (r > top) : (r -= 1) self.buf.removeLineAt(r);
        self.buf.setLine(top, out.items[0]) catch return;
        var k: usize = 1;
        while (k < out.items.len) : (k += 1) self.buf.insertLineAt(top + k, out.items[k]) catch return;
        self.buf.dirty = true;

        if (keep_cursor) {
            self.cy = @min(at.row, self.buf.lineCount() - 1);
            self.cx = @min(at.col, self.curLine().len);
        } else {
            self.cy = @min(top + out.items.len - 1, self.buf.lineCount() - 1);
            self.cx = 0;
        }
        self.updateGoal();
    }

    /// `g&`: run the last `:s` again over the whole file, keeping its flags.
    fn repeatSubstituteAll(self: *Editor) void {
        const sub = self.last_sub orelse return self.setStatus("no previous substitute", .{});
        self.doSubstitute(.{
            .lo = .{ .base = .{ .line = 1 } },
            .hi = .{ .base = .last },
            .count = 2,
        }, sub);
    }

    // === picker (file finder / global search) ==============================

    /// Load the recently-opened list and, when the session started with no
    /// file, show the startup screen.
    pub fn startSession(self: *Editor, show_dashboard: bool) void {
        self.recents = recent.load(self.gpa, self.io);
        self.dashboard = show_dashboard and self.recents.entries.items.len > 0;
        self.dash_sel = 0;
        // The non-modal keymaps start where their users expect to be: able to
        // type. There is no normal mode to return to under them.
        if (nonModal() and !self.dashboard) {
            self.mode = .insert;
            // `enterInsert` is what normally records the state undo returns
            // to, and it never runs here — without this, `Ctrl-Z` after the
            // first keystrokes has nothing to go back to.
            self.pushUndo();
        }
    }

    /// Record a file or directory in the recently-opened list. Local paths are
    /// stored absolute so the list is meaningful from any working directory.
    pub fn noteRecent(self: *Editor, path: []const u8, kind: recent.Kind) void {
        if (remote.isRemote(path)) return self.recents.touch(kind, path);
        if (path.len > 0 and path[0] == '/') return self.recents.touch(kind, path);
        const cwd = std.process.currentPathAlloc(self.io, self.gpa) catch return;
        defer self.gpa.free(cwd);
        const abs = std.fs.path.join(self.gpa, &.{ cwd, path }) catch return;
        defer self.gpa.free(abs);
        self.recents.touch(kind, abs);
    }

    /// Open the fuzzy file picker (`Space f f`; also the startup view when
    /// zedit is launched on a directory).
    /// Rebuild the file rows from the cache — called as walk slices land.
    fn refillFileItems(self: *Editor) void {
        self.picker_items.clearRetainingCapacity();
        self.picker_text.clearRetainingCapacity();
        self.fillFileItems();
        self.prev_query.clearRetainingCapacity(); // the candidate set grew
    }

    /// Reset the picker state and select `kind` — the shared prologue of
    /// every picker opener.
    fn startPicker(self: *Editor, kind: PickerKind) void {
        self.freePicker();
        self.picker_kind = kind;
        self.picker_sel = 0;
        self.picker_scroll = 0;
    }

    fn openFilePicker(self: *Editor) void {
        self.startPicker(.files);
        self.ensureFileCache(); // starts the walk; does not wait for it
        self.fillFileItems();
        self.refilter();
        self.mode = .picker;
    }

    /// Build picker items from the cached file list; `.line` holds the cache
    /// index so the filter can consult the precomputed mask.
    fn fillFileItems(self: *Editor) void {
        for (self.fcache.items, 0..) |path, i| {
            self.addPickItem(path, path, i);
        }
    }

    fn openGrepPicker(self: *Editor) void {
        self.startPicker(.grep);
        self.ensureFileCache();
        self.mode = .picker;
        self.refilter();
    }

    /// Populate the picker with the server's code actions (titles) and open it.
    /// The action's index is stashed in `PickItem.line` so `pickerOpen` can
    /// apply it.
    fn openCodeActionPicker(self: *Editor) void {
        const client = if (self.lsp) |*c| c else return;
        self.startPicker(.code_action);
        for (client.code_actions.items, 0..) |action, i| {
            self.addPickItem(action.title, action.title, i);
        }
        self.mode = .picker;
        self.refilter();
    }

    /// Populate the picker with the document's symbols (kind tag + indented
    /// name) and open it; the symbol index is stashed in `PickItem.line`.
    fn openSymbolPicker(self: *Editor) void {
        const client = if (self.lsp) |*c| c else return;
        self.startPicker(.symbol);
        const spaces = "                    "; // 20 spaces, sliced by depth
        for (client.symbols.items, 0..) |sym, i| {
            const pad = spaces[0..@min(@as(usize, sym.depth) * 2, spaces.len)];
            var db: [512]u8 = undefined;
            const disp = std.fmt.bufPrint(&db, "{s}{s} {s}", .{ pad, symbolKindName(sym.kind), sym.name }) catch continue;
            self.addPickItem(disp, sym.name, i);
        }
        self.mode = .picker;
        self.refilter();
    }

    /// Populate the picker with the open buffers (`Space f b`); the doc index
    /// is stashed in `PickItem.line`.
    fn openBufferPicker(self: *Editor) void {
        self.startPicker(.buffer);
        for (self.docs.items, 0..) |doc, i| {
            const name = docLabel(doc);
            const mark: []const u8 = if (doc == self.d) "* " else "  ";
            const dirty: []const u8 = if (doc.buf.dirty) " \u{25CF}" else "";
            var db: [512]u8 = undefined;
            const disp = std.fmt.bufPrint(&db, "{s}{s}{s}", .{ mark, name, dirty }) catch continue;
            self.addPickItem(disp, name, i);
        }
        self.mode = .picker;
        self.refilter();
    }

    /// Populate the picker with the built-in theme names and open it.
    /// The theme picker shows the theme, not its name: moving the selection
    /// repaints the whole editor in it. Cancelling puts back the one that was
    /// active when the picker opened — a preview you cannot undo is a trap.
    fn previewTheme(self: *Editor) void {
        if (self.picker_kind != .theme) return;
        if (self.picker_filtered.items.len == 0) return;
        const it = self.picker_items.items[self.picker_filtered.items[self.picker_sel]];
        if (theme.set(self.itemPath(it))) self.prev_valid = false;
    }

    fn openThemePicker(self: *Editor) void {
        self.theme_before = theme.current_name;
        self.startPicker(.theme);
        for (theme.themes) |t| {
            self.addPickItem(t.name, t.name, 0);
        }
        self.mode = .picker;
        self.refilter();
    }

    // === the command palette ===============================================

    /// What running a palette entry does. Most commands already have an ex
    /// spelling, so the table names it rather than duplicating a call; the
    /// rest are the ones that only ever had a key.
    const Run = union(enum) {
        /// Run this ex command line now (no colon).
        ex: []const u8,
        /// Open the command line pre-filled with this text, cursor at the end
        /// — for the commands that take an argument (`:theme `, `:edit `).
        prompt: []const u8,
        /// One of the config flags `Space u` toggles.
        toggle: struct { flag: *bool, name: []const u8 },
        act: Act,
    };

    /// The commands with no ex spelling. Each arm is one call to the function
    /// the key handler already calls — the palette is another way in, never a
    /// second implementation.
    const Act = enum {
        files,        grep,        buffers,     themes,      explorer,
        home,         new_buffer,  new_file,    new_folder,  close_others,
        code_action,  rename,      references,  doc_symbols, ws_symbols,
        line_diag,    all_diags,   breakpoint,  clear_bps,   dbg_continue,
        step_over,    step_into,   step_out,    dbg_stop,    mouse,
        undo,         redo,        comment,
    };

    /// One palette entry: what it is called, how it is spelled on the keyboard
    /// under each keymap, and what it does.
    ///
    /// Both bindings are carried because the palette shows the one that
    /// actually works *here*: telling a VS Code user to press `Space f f` is
    /// worse than telling them nothing. An empty string means the command has
    /// no key under that keymap, which is most of the point of having a
    /// palette — under the non-modal table almost nothing below is on a chord.
    const Cmd = struct {
        title: []const u8,
        vim: []const u8 = "",
        code: []const u8 = "",
        run: Run,
    };

    const commands = [_]Cmd{
        // --- files and buffers ---------------------------------------------
        .{ .title = "Find files", .vim = "Space f f", .code = "Ctrl-p", .run = .{ .act = .files } },
        .{ .title = "Find in project (grep)", .vim = "Space f w", .run = .{ .act = .grep } },
        .{ .title = "Find buffers", .vim = "Space f b", .run = .{ .act = .buffers } },
        .{ .title = "Open file\u{2026}", .vim = ":e", .run = .{ .prompt = "edit " } },
        .{ .title = "Save", .vim = "Space w", .code = "Ctrl-s", .run = .{ .ex = "write" } },
        .{ .title = "Save as\u{2026}", .run = .{ .prompt = "write " } },
        .{ .title = "Save all", .vim = ":wa", .run = .{ .ex = "wall" } },
        .{ .title = "Save and quit", .vim = "ZZ", .run = .{ .ex = "x" } },
        .{ .title = "Quit", .vim = "Space q", .run = .{ .ex = "quit" } },
        .{ .title = "Quit all", .vim = ":qa", .run = .{ .ex = "quitall" } },
        .{ .title = "New empty buffer", .vim = "Space n b", .run = .{ .act = .new_buffer } },
        .{ .title = "New file\u{2026}", .vim = "Space n f", .run = .{ .act = .new_file } },
        .{ .title = "New folder\u{2026}", .vim = "Space n d", .run = .{ .act = .new_folder } },
        .{ .title = "Next buffer", .vim = "]b", .run = .{ .ex = "bnext" } },
        .{ .title = "Previous buffer", .vim = "[b", .run = .{ .ex = "bprevious" } },
        .{ .title = "Close buffer", .vim = "Space c", .code = "Ctrl-w", .run = .{ .ex = "bdelete" } },
        .{ .title = "Close other buffers", .vim = "Space b c", .run = .{ .act = .close_others } },
        .{ .title = "List buffers", .vim = ":ls", .run = .{ .ex = "buffers" } },
        .{ .title = "Edit over SSH\u{2026}", .run = .{ .prompt = "ssh " } },

        // --- windows --------------------------------------------------------
        .{ .title = "Split window", .vim = "Ctrl-w s", .run = .{ .ex = "split" } },
        .{ .title = "Split window vertically", .vim = "Ctrl-w v", .run = .{ .ex = "vsplit" } },
        .{ .title = "Close window", .vim = "Ctrl-w c", .run = .{ .ex = "close" } },
        .{ .title = "Close other windows", .vim = "Ctrl-w o", .run = .{ .ex = "only" } },
        .{ .title = "Save the split layout", .run = .{ .ex = "winsave" } },

        // --- editing --------------------------------------------------------
        .{ .title = "Undo", .vim = "u", .code = "Ctrl-z", .run = .{ .act = .undo } },
        .{ .title = "Redo", .vim = "Ctrl-r", .code = "Ctrl-y", .run = .{ .act = .redo } },
        .{ .title = "Toggle comment", .vim = "gcc", .code = "Ctrl-/", .run = .{ .act = .comment } },
        .{ .title = "Search and replace\u{2026}", .vim = ":%s", .code = "Ctrl-h", .run = .{ .prompt = "%s/" } },
        .{ .title = "Undo history", .vim = "Space f u", .run = .{ .ex = "undolist" } },
        .{ .title = "Go to an earlier state\u{2026}", .run = .{ .prompt = "earlier " } },
        .{ .title = "Go to a later state\u{2026}", .run = .{ .prompt = "later " } },

        // --- appearance and settings ---------------------------------------
        .{ .title = "Toggle explorer", .vim = "Space e", .code = "Ctrl-b", .run = .{ .act = .explorer } },
        .{ .title = "Home screen", .vim = "Space h", .run = .{ .act = .home } },
        .{ .title = "Choose a theme", .vim = "Space f t", .run = .{ .act = .themes } },
        .{ .title = "Set theme\u{2026}", .vim = ":theme", .run = .{ .prompt = "theme " } },
        .{ .title = "Toggle relative numbers", .vim = "Space u n", .run = .{ .toggle = .{ .flag = &config.settings.relative_numbers, .name = "relative numbers" } } },
        .{ .title = "Toggle soft wrap", .vim = "Space u w", .run = .{ .toggle = .{ .flag = &config.settings.soft_wrap, .name = "soft wrap" } } },
        .{ .title = "Toggle inline diagnostics", .vim = "Space u d", .run = .{ .toggle = .{ .flag = &config.settings.inline_diagnostics, .name = "inline diagnostics" } } },
        .{ .title = "Toggle buffer tabs", .vim = "Space u t", .run = .{ .toggle = .{ .flag = &config.settings.buffer_tabs, .name = "buffer tabs" } } },
        .{ .title = "Toggle autoindent", .vim = "Space u i", .run = .{ .toggle = .{ .flag = &config.settings.autoindent, .name = "autoindent" } } },
        .{ .title = "Toggle auto completion", .vim = "Space u c", .run = .{ .toggle = .{ .flag = &config.settings.auto_completion, .name = "auto completion" } } },
        .{ .title = "Toggle format on save", .vim = "Space u f", .run = .{ .toggle = .{ .flag = &config.settings.format_on_save, .name = "format on save" } } },
        .{ .title = "Toggle mouse reporting", .vim = "Space u m", .run = .{ .act = .mouse } },

        // --- language tools -------------------------------------------------
        .{ .title = "Code action", .vim = "Space l a", .run = .{ .act = .code_action } },
        .{ .title = "Rename symbol", .vim = "Space l r", .run = .{ .act = .rename } },
        .{ .title = "Find references", .vim = "Space l R", .run = .{ .act = .references } },
        .{ .title = "Document symbols", .vim = "Space l s", .run = .{ .act = .doc_symbols } },
        .{ .title = "Workspace symbols", .vim = "Space l S", .run = .{ .act = .ws_symbols } },
        .{ .title = "Line diagnostic", .vim = "Space l d", .run = .{ .act = .line_diag } },
        .{ .title = "All diagnostics", .vim = "Space l D", .run = .{ .act = .all_diags } },
        .{ .title = "Format buffer", .vim = "Space l f", .run = .{ .ex = "format" } },

        // --- git ------------------------------------------------------------
        .{ .title = "Diff (inline)", .vim = "Space g d", .run = .{ .ex = "diff" } },
        .{ .title = "Diff (side by side)", .vim = "Space g s", .run = .{ .ex = "vdiff" } },
        .{ .title = "Diff (line view)", .vim = "Space g l", .run = .{ .ex = "ldiff" } },

        // --- the quickfix list ----------------------------------------------
        .{ .title = "Quickfix: open the list", .vim = "Space x q", .run = .{ .ex = "copen" } },
        .{ .title = "Quickfix: next entry", .vim = "]q", .run = .{ .ex = "cnext" } },
        .{ .title = "Quickfix: previous entry", .vim = "[q", .run = .{ .ex = "cprevious" } },
        .{ .title = "Quickfix: close the list", .vim = "Space x c", .run = .{ .ex = "cclose" } },
        .{ .title = "Quickfix: edit every hit as one buffer", .vim = "Space x e", .run = .{ .ex = "cedit" } },

        // --- session, terminal, debugger -------------------------------------
        .{ .title = "Session: save", .vim = "Space S s", .run = .{ .ex = "session save" } },
        .{ .title = "Session: load", .vim = "Space S l", .run = .{ .ex = "session load" } },
        .{ .title = "Session: delete", .vim = "Space S d", .run = .{ .ex = "session delete" } },
        .{ .title = "Terminal", .vim = "Space t", .run = .{ .ex = "terminal" } },
        .{ .title = "Debug: launch\u{2026}", .run = .{ .prompt = "debug " } },
        .{ .title = "Debug: toggle breakpoint", .vim = "Space d b", .run = .{ .act = .breakpoint } },
        .{ .title = "Debug: clear breakpoints", .vim = "Space d B", .run = .{ .act = .clear_bps } },
        .{ .title = "Debug: start / continue", .vim = "Space d c", .run = .{ .act = .dbg_continue } },
        .{ .title = "Debug: step over", .vim = "Space d n", .run = .{ .act = .step_over } },
        .{ .title = "Debug: step into", .vim = "Space d i", .run = .{ .act = .step_into } },
        .{ .title = "Debug: step out", .vim = "Space d o", .run = .{ .act = .step_out } },
        .{ .title = "Debug: stop", .vim = "Space d q", .run = .{ .act = .dbg_stop } },

        // --- zedit itself -----------------------------------------------------
        .{ .title = "Check for updates", .vim = ":update", .run = .{ .ex = "checkupdate" } },
    };

    /// The binding to show for `c` under the keymap in force. A command with
    /// none there shows nothing rather than another editor's key.
    fn cmdBinding(c: Cmd) []const u8 {
        return if (nonModal()) c.code else c.vim;
    }

    /// The text the fuzzy filter matches against: the title *and* the
    /// binding, so `vsplit` finds "Split window vertically" and `Space g`
    /// finds the git group.
    fn cmdMatchText(c: Cmd, buf: []u8) []const u8 {
        const spell: []const u8 = switch (c.run) {
            .ex => |e| e,
            .prompt => |p| p,
            .toggle => |t| t.name,
            .act => "",
        };
        return std.fmt.bufPrint(buf, "{s} {s} {s}", .{ c.title, cmdBinding(c), spell }) catch c.title;
    }

    /// `Space f C`, or `>` typed into the file picker — VS Code's own Quick
    /// Open prefix, which is how the palette is reached under the non-modal
    /// keymap: `Ctrl+Shift+P` cannot be told from `Ctrl+P` by a terminal.
    fn openCommandPalette(self: *Editor) void {
        self.startPicker(.command);
        var disp: [96]u8 = undefined;
        var match: [160]u8 = undefined;
        for (commands, 0..) |c, i| {
            const bind = cmdBinding(c);
            const row = std.fmt.bufPrint(&disp, "{s: <32}{s}", .{ c.title, bind }) catch c.title;
            self.addPickItem(row, cmdMatchText(c, &match), i);
        }
        self.mode = .picker;
        self.refilter();
    }

    /// Run the chosen command. The picker is closed first: several of these
    /// open a picker of their own, and one that opened underneath this one
    /// would be closed by the next Esc rather than shown.
    fn runCommand(self: *Editor, idx: usize) !void {
        if (idx >= commands.len) return;
        switch (commands[idx].run) {
            .ex => |line| try self.execLine(line),
            .prompt => |text| {
                self.enterCmd(.ex);
                self.cmd.appendSlice(self.gpa, text) catch {};
                self.cmd_cur = self.cmd.items.len;
            },
            .toggle => |t| self.toggleSetting(t.flag, t.name),
            .act => |a| switch (a) {
                .files => self.openFilePicker(),
                .grep => self.openGrepPicker(),
                .buffers => self.openBufferPicker(),
                .themes => self.openThemePicker(),
                .explorer => self.sidebarToggle(),
                .home => self.showHome(),
                .new_buffer => self.newBuffer(),
                .new_file => self.enterNewEntry(false),
                .new_folder => self.enterNewEntry(true),
                .close_others => self.closeOthers(),
                .code_action => self.lspCodeAction(),
                .rename => self.enterRename(),
                .references => self.lspReferences(),
                .doc_symbols => self.lspDocumentSymbol(),
                .ws_symbols => self.openWorkspaceSymbolPicker(),
                .line_diag => self.lineDiagnostic(),
                .all_diags => self.openDiagnosticPicker(),
                .breakpoint => self.toggleBreakpoint(),
                .clear_bps => self.clearBreakpoints(),
                .dbg_continue => self.debugContinue(),
                .step_over => self.debugStep(.over),
                .step_into => self.debugStep(.into),
                .step_out => self.debugStep(.out),
                .dbg_stop => self.debugStop(),
                .mouse => self.toggleMouse(),
                .undo => self.undoChange(),
                .redo => self.redoChange(),
                .comment => self.toggleComment(.{ .lines = true, .top = self.cy, .bot = self.cy }),
            },
        }
    }

    /// Reset the picker. Nothing is freed: the arena and the index arrays keep
    /// their capacity for the next open, so a warm picker performs no
    /// allocation at all.
    fn freePicker(self: *Editor) void {
        self.picker_items.clearRetainingCapacity();
        self.picker_text.clearRetainingCapacity();
        self.picker_filtered.clearRetainingCapacity();
        self.picker_query.clearRetainingCapacity();
        self.prev_query.clearRetainingCapacity();
        self.grep_scanned = 0;
    }

    /// Append a row. `display` is what the list shows, `path` what opening it
    /// acts on (or an index stashed in `line` for the action/symbol pickers).
    fn addPickItem(self: *Editor, display: []const u8, path: []const u8, line: usize) void {
        const d_at: u32 = @intCast(self.picker_text.items.len);
        self.picker_text.appendSlice(self.gpa, display) catch return;
        const p_at: u32 = @intCast(self.picker_text.items.len);
        self.picker_text.appendSlice(self.gpa, path) catch return;
        self.picker_items.append(self.gpa, .{
            .display_at = d_at,
            .display_len = @intCast(display.len),
            .path_at = p_at,
            .path_len = @intCast(path.len),
            .line = @intCast(line),
        }) catch {};
    }

    fn itemDisplay(self: *const Editor, it: PickItem) []const u8 {
        return self.picker_text.items[it.display_at..][0..it.display_len];
    }

    fn itemPath(self: *const Editor, it: PickItem) []const u8 {
        return self.picker_text.items[it.path_at..][0..it.path_len];
    }

    fn closePicker(self: *Editor) void {
        // A cancelled theme preview goes back to what was on screen before it
        // opened. `pickerOpen` re-applies the chosen theme straight after this
        // returns, so Enter is unaffected.
        if (self.picker_kind == .theme and !std.mem.eql(u8, theme.current_name, self.theme_before)) {
            _ = theme.set(self.theme_before);
            self.prev_valid = false;
        }
        self.freePicker();
        self.mode = .normal;
    }

    /// Walk the cwd once per session into the warm cache (files + fuzzy masks),
    /// skipping build/VCS directories. Subsequent picker opens are free of
    /// filesystem work; `Ctrl-r` in a picker refreshes.
    /// Begin (or resume) the project walk without blocking. Returns straight
    /// away; `stepWalk` does the work a slice at a time.
    fn ensureFileCache(self: *Editor) void {
        if (self.fcache_ready or self.walker != null) return;
        if (self.remote_root) |root| {
            var sp = log.Span.start();
            self.fillRemoteCache(root); // one ssh call; nothing to chunk
            self.fcache_ready = true;
            sp.lap("remote-file-list");
            return;
        }
        var dir = std.Io.Dir.cwd().openDir(self.io, ".", .{ .iterate = true }) catch {
            self.fcache_ready = true;
            return;
        };
        self.walker = dir.walkSelectively(self.gpa) catch {
            dir.close(self.io);
            self.fcache_ready = true;
            return;
        };
        self.walk_dir = dir;
    }

    fn walkInProgress(self: *const Editor) bool {
        return self.walker != null;
    }

    /// Walk for at most `budget_us`, then hand control back so input stays
    /// responsive. Returns true when it produced new entries.
    fn stepWalk(self: *Editor, budget_us: i64) bool {
        var w = if (self.walker) |*x| x else return false;
        var sp = log.Span.start();
        const deadline = log.nowMs() * 1000 + budget_us;
        const before = self.fcache.items.len;
        var done = false;
        var checked: usize = 0;
        while (true) {
            const maybe = w.next(self.io) catch {
                done = true;
                break;
            };
            const entry = maybe orelse {
                done = true;
                break;
            };
            if (entry.kind == .directory) {
                if (!ignoredDir(entry.basename)) w.enter(self.io, entry) catch {};
                continue;
            }
            if (entry.kind != .file) continue;
            if (self.fcache.items.len >= 20000) {
                done = true;
                break;
            }
            const p = self.gpa.dupe(u8, entry.path) catch continue;
            self.fcache.append(self.gpa, p) catch {
                self.gpa.free(p);
                done = true;
                break;
            };
            self.fcache_masks.append(self.gpa, fuzzy.charMask(p)) catch break;
            // Check the clock every so often rather than per entry.
            checked += 1;
            if (checked % 512 == 0 and log.nowMs() * 1000 >= deadline) break;
        }
        if (done) {
            w.deinit();
            self.walker = null;
            if (self.walk_dir) |*d| d.close(self.io);
            self.walk_dir = null;
            self.fcache_ready = true;
            sp.lap("file-walk-done");
        }
        return self.fcache.items.len != before;
    }

    /// Fill the picker cache from a remote directory (one ssh call). Entries
    /// keep the full `ssh://host/dir/path` URL so opening one just works.
    fn fillRemoteCache(self: *Editor, root: []const u8) void {
        const target = remote.parse(root) orelse return;
        const out = remote.listFiles(self.gpa, self.io, target) catch {
            self.setStatus("cannot list {s} (ssh failed — see --log)", .{root});
            return;
        };
        defer self.gpa.free(out);
        const base = std.mem.trimEnd(u8, root, "/");
        var it = std.mem.splitScalar(u8, out, '\n');
        while (it.next()) |line| {
            const rel = std.mem.trim(u8, line, " \r");
            if (rel.len == 0) continue;
            const tail = if (std.mem.startsWith(u8, rel, "./")) rel[2..] else rel;
            if (tail.len == 0) continue;
            if (self.fcache.items.len >= 20000) break;
            var ub: [1024]u8 = undefined;
            const built = std.fmt.bufPrint(&ub, "{s}/{s}", .{ base, tail }) catch continue;
            const url = self.gpa.dupe(u8, built) catch break; // the cache owns it
            self.fcache.append(self.gpa, url) catch {
                self.gpa.free(url);
                break;
            };
            self.fcache_masks.append(self.gpa, fuzzy.charMask(url)) catch break;
        }
    }

    fn refreshFileCache(self: *Editor) void {
        if (self.walker) |*w| { // abandon a walk already running
            w.deinit();
            self.walker = null;
            if (self.walk_dir) |*d| d.close(self.io);
            self.walk_dir = null;
        }
        for (self.fcache.items) |f| self.gpa.free(f);
        self.fcache.clearRetainingCapacity();
        self.fcache_masks.clearRetainingCapacity();
        self.fcache_ready = false;
        self.ensureFileCache();
    }

    fn onQueryChange(self: *Editor) void {
        self.picker_sel = 0;
        if (self.picker_kind == .wsymbol) {
            // The server does the matching, so ask it again once typing pauses
            // — the same debounce auto-completion uses, and the same single
            // timer, so an idle picker still costs nothing.
            self.due_kind = .wsymbol;
            self.comp_due_ms = log.nowMs() + @as(i64, @intCast(config.settings.completion_delay_ms));
            return;
        }
        self.picker_scroll = 0;
        self.refilter();
    }

    fn refilter(self: *Editor) void {
        // Whatever ends up selected is what the theme picker shows — on
        // opening and while typing, not only when the arrows move. The first
        // theme in the list was being named but not applied.
        defer self.previewTheme();
        var sp = log.Span.start();
        if (self.picker_kind == .grep) {
            const gq = self.picker_query.items;
            self.compileGrep(gq);
            if (self.grep_incomplete) {
                // Mid-typing an invalid pattern (a lone '(', a trailing '\'):
                // keep the last good results on screen — the prompt carries a
                // dim "(incomplete)" tag until the pattern compiles again.
                sp.lap("refilter");
                return;
            }
            if (self.grep_re != null and self.grep_re.?.lit == null) {
                // A genuine regex is not a subset of its prefix, so every
                // keystroke means a full rescan — ~35 ms on a zedit-sized
                // tree (measured) — far too slow to run synchronously. Share
                // the completion debounce and rescan once typing pauses; the
                // previous results stay put until then.
                self.due_kind = .grep;
                self.comp_due_ms = log.nowMs() + @as(i64, @intCast(config.settings.completion_delay_ms));
                sp.lap("refilter");
                return;
            }
            if (self.due_kind == .grep) self.comp_due_ms = null; // stale regex rescan
            // Extending a literal grep can only shrink its hit set — a line
            // holding the longer query already held the shorter one — so
            // filter the hits already on screen instead of re-reading the
            // project. That is the same narrowing the file picker does, and
            // the difference between re-reading every file on every keystroke
            // and touching no file at all.
            const narrow = self.prev_query.items.len > 0 and gq.len > self.prev_query.items.len and
                std.mem.startsWith(u8, gq, self.prev_query.items);
            if (narrow) self.narrowGrepHits(gq) else self.regrep();
            // Files the walk delivered since — and, when a narrowing freed
            // room under the 500-hit cap, the ones an earlier pass stopped
            // short of. Both are no-ops once the walk is done and nothing
            // was capped, which is the common case.
            self.grepMore();
            self.showAllGrepHits();
            self.prev_query.clearRetainingCapacity();
            self.prev_query.appendSlice(self.gpa, gq) catch {};
            sp.lap("refilter");
            return;
        }
        const q = self.picker_query.items;
        // Incremental narrowing: extending the query can only shrink the match
        // set, so rescore just the current survivors instead of every item.
        // Still sound with multi-term (space-separated) queries: appended
        // bytes either extend the last term — matching a longer subsequence
        // implies its prefix matched — or, after a space, start a new term,
        // which is one more constraint. Either way every match of "ab c" was
        // already a match of "ab", so the survivors contain them all.
        const narrow = self.picker_kind == .files and self.prev_query.items.len > 0 and
            q.len > self.prev_query.items.len and std.mem.startsWith(u8, q, self.prev_query.items);
        var survivors: std.ArrayList(u32) = .empty;
        defer survivors.deinit(self.gpa);
        if (narrow) survivors.appendSlice(self.gpa, self.picker_filtered.items) catch {};

        self.picker_filtered.clearRetainingCapacity();
        if (q.len == 0) {
            var i: u32 = 0;
            while (i < self.picker_items.items.len) : (i += 1) self.picker_filtered.append(self.gpa, i) catch {};
        } else {
            // The mask covers only the query's non-space characters: spaces
            // separate terms, and each term's chars must all appear in a
            // matching candidate — so their union must too.
            const qmask = fuzzy.queryMask(q);
            var scored: std.ArrayList(Scored) = .empty;
            defer scored.deinit(self.gpa);
            const n = if (narrow) survivors.items.len else self.picker_items.items.len;
            var k: usize = 0;
            while (k < n) : (k += 1) {
                const i: u32 = if (narrow) survivors.items[k] else @intCast(k);
                const it = self.picker_items.items[i];
                // Char-bag prefilter (files only — `.line` indexes the cache).
                if (self.picker_kind == .files and it.line < self.fcache_masks.items.len and
                    !fuzzy.maskMatches(self.fcache_masks.items[it.line], qmask)) continue;
                if (fuzzy.scoreTerms(self.itemPath(it), q)) |s| scored.append(self.gpa, .{ .idx = i, .score = s }) catch {};
            }
            std.mem.sort(Scored, scored.items, {}, scoredLess);
            for (scored.items) |s| self.picker_filtered.append(self.gpa, s.idx) catch {};
        }
        self.prev_query.clearRetainingCapacity();
        self.prev_query.appendSlice(self.gpa, q) catch {};
        self.clampSel();
        sp.lap("refilter");
    }

    /// Compile-and-cache the grep pattern (same modern regex syntax as `/`,
    /// case-sensitive). A pattern that does not compile — the user is mid-way
    /// through typing a group or an escape — keeps the previous regex *and*
    /// the results it produced, and only raises `grep_incomplete`.
    fn compileGrep(self: *Editor, pat: []const u8) void {
        self.grep_incomplete = false;
        if (pat.len == 0) {
            if (self.grep_re) |*old| old.deinit(self.gpa);
            self.grep_re = null;
            self.grep_re_pat.clearRetainingCapacity();
            return;
        }
        if (self.grep_re != null and std.mem.eql(u8, pat, self.grep_re_pat.items)) return;
        const re = regex.Regex.compile(self.gpa, pat, false) catch {
            self.grep_incomplete = true;
            return;
        };
        if (self.grep_re) |*old| old.deinit(self.gpa);
        self.grep_re = re;
        self.grep_re_pat.clearRetainingCapacity();
        self.grep_re_pat.appendSlice(self.gpa, pat) catch {};
    }

    /// The debounced regex rescan: once typing has paused, re-read the
    /// project with the compiled pattern. A full pass costs ~35 ms on a
    /// zedit-sized tree (measured with `log.Span`), which is why it must not
    /// run per keystroke; literal queries never come through here.
    fn grepRescan(self: *Editor) void {
        self.comp_due_ms = null;
        if (self.mode != .picker or self.picker_kind != .grep) return; // closed before the pause
        var sp = log.Span.start();
        self.regrep();
        self.showAllGrepHits();
        // The items answer the *compiled* pattern — the live query may
        // already have grown an invalid suffix the tag is reporting.
        self.prev_query.clearRetainingCapacity();
        self.prev_query.appendSlice(self.gpa, self.grep_re_pat.items) catch {};
        sp.lap("grep-rescan");
    }

    fn regrep(self: *Editor) void {
        self.picker_items.clearRetainingCapacity();
        self.picker_text.clearRetainingCapacity();
        self.grep_scanned = 0;
        self.grepMore();
    }

    /// Drop the hits that no longer match the extended query, keeping the rest
    /// in place. `grep_scanned` is untouched: the invariant is still "these are
    /// the matches in the files scanned so far", now for the longer query.
    ///
    /// The comparison is against the line text as stored, which the row
    /// formatting caps at 120 bytes — a match hiding past that column on a
    /// very long line is dropped here where a rescan would have kept it. The
    /// row could never have shown it either.
    fn narrowGrepHits(self: *Editor, q: []const u8) void {
        var kept: usize = 0;
        for (self.picker_items.items) |it| {
            if (std.mem.indexOf(u8, self.itemGrepText(it), q) == null) continue;
            self.picker_items.items[kept] = it;
            kept += 1;
        }
        self.picker_items.items.len = kept;
    }

    /// The line text of a grep row: its display is "path:line: text", and both
    /// the path and the line number are on the item, so the prefix can be
    /// stepped over exactly rather than searched for.
    fn itemGrepText(self: *const Editor, it: PickItem) []const u8 {
        const disp = self.itemDisplay(it);
        var i: usize = @min(it.path_len + 1, disp.len); // past "path:"
        while (i < disp.len and disp[i] >= '0' and disp[i] <= '9') i += 1;
        if (i + 2 <= disp.len and disp[i] == ':' and disp[i + 1] == ' ') i += 2;
        return disp[i..];
    }

    /// Grep the `fcache` entries not yet covered by the current query and
    /// append their matches. Called once per query change and again for each
    /// slice the project walk delivers — without this a grep started before
    /// the walk finished would silently cover only the files found so far.
    fn grepMore(self: *Editor) void {
        // A regex rescan is pending: the items on screen still answer the
        // previous pattern, so appending matches of the new one would mix
        // result sets — the rescan covers these files when it fires.
        if (self.comp_due_ms != null and self.due_kind == .grep) return;
        const re = if (self.grep_re) |*r| r else return;
        const lit = re.lit; // matching runs per line; multi-line patterns can't match
        for (self.fcache.items[self.grep_scanned..]) |fpath| {
            if (self.picker_items.items.len >= 500) break;
            self.grep_scanned += 1;
            const data = std.Io.Dir.cwd().readFileAlloc(self.io, fpath, self.gpa, .limited(1 << 20)) catch continue;
            defer self.gpa.free(data);
            var line_no: usize = 1;
            var it = std.mem.splitScalar(u8, data, '\n');
            while (it.next()) |ln| : (line_no += 1) {
                if (self.picker_items.items.len >= 500) break;
                if (lit) |l| {
                    if (std.mem.indexOf(u8, ln, l) == null) continue;
                } else if (re.find(ln, 0) == null) continue;
                var s = ln;
                while (s.len > 0 and (s[0] == ' ' or s[0] == '\t')) s = s[1..];
                const text = s[0..@min(s.len, 120)];
                var db: [512]u8 = undefined;
                const disp = std.fmt.bufPrint(&db, "{s}:{d}: {s}", .{ fpath, line_no, text }) catch continue;
                self.addPickItem(disp, fpath, line_no);
            }
        }
    }

    /// Grep hits are already the answer to the query, so every item shows.
    fn showAllGrepHits(self: *Editor) void {
        self.picker_filtered.clearRetainingCapacity();
        var i: u32 = 0;
        while (i < self.picker_items.items.len) : (i += 1) self.picker_filtered.append(self.gpa, i) catch {};
        self.clampSel();
    }

    fn clampSel(self: *Editor) void {
        if (self.picker_sel >= self.picker_filtered.items.len)
            self.picker_sel = if (self.picker_filtered.items.len == 0) 0 else self.picker_filtered.items.len - 1;
    }

    fn selDelta(self: *Editor, down: bool) void {
        if (self.picker_filtered.items.len == 0) return;
        defer self.previewTheme(); // themes apply as the selection moves
        if (down) {
            if (self.picker_sel + 1 < self.picker_filtered.items.len) self.picker_sel += 1;
        } else {
            if (self.picker_sel > 0) self.picker_sel -= 1;
        }
    }

    fn pickerKey(self: *Editor, k: key.Key) !void {
        // Telescope's binding: keep every result instead of choosing one.
        if (k == .ctrl and k.ctrl == 'q') return self.qfFromPicker();
        switch (k) {
            .escape => self.closePicker(),
            .enter => try self.pickerOpen(),
            .backspace => {
                if (self.picker_query.items.len > 0) {
                    self.picker_query.items.len = unicode.prevBoundary(self.picker_query.items, self.picker_query.items.len);
                    self.onQueryChange();
                }
            },
            .char => |c| {
                // VS Code's Quick Open prefix: `>` on an empty query turns
                // the file picker into the command palette. It is the only
                // route there under the non-modal keymap, where the real key
                // (`Ctrl+Shift+P`) cannot be told from `Ctrl+P` by a terminal.
                if (c == '>' and self.picker_kind == .files and self.picker_query.items.len == 0)
                    return self.openCommandPalette();
                var enc: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &enc) catch return;
                try self.picker_query.appendSlice(self.gpa, enc[0..n]);
                self.onQueryChange();
            },
            .up => self.selDelta(false),
            .down => self.selDelta(true),
            // (the wheel never reaches here: feedKey scrolls the preview)
            .ctrl => |c| switch (c) {
                'p' => self.selDelta(false),
                'n' => self.selDelta(true),
                // Ctrl-d / Ctrl-u page the preview pane itself.
                'd' => self.scrollPreview(@intCast(self.win.rows / 2)),
                'u' => self.scrollPreview(-@as(isize, @intCast(self.win.rows / 2))),
                'c' => self.closePicker(),
                'r' => if (self.picker_kind == .files or self.picker_kind == .grep) {
                    // Re-walk the project (picks up files created since the
                    // session's cached walk) and refilter with the same query.
                    self.refreshFileCache();
                    if (self.picker_kind == .files) {
                        self.picker_items.clearRetainingCapacity();
                        self.picker_text.clearRetainingCapacity();
                        self.fillFileItems();
                    } else {
                        // The hits and the scan cursor refer to the cache
                        // just thrown away; a regex or mid-typing-invalid
                        // query skips the immediate regrep below, so reset
                        // here or the grep would resume mid-way through the
                        // new walk and mix the two caches' results.
                        self.picker_items.clearRetainingCapacity();
                        self.picker_text.clearRetainingCapacity();
                        self.picker_filtered.clearRetainingCapacity();
                        self.grep_scanned = 0;
                    }
                    self.prev_query.clearRetainingCapacity(); // force a full rescore
                    self.onQueryChange();
                },
                else => {},
            },
            else => {},
        }
    }

    fn pickerOpen(self: *Editor) !void {
        if (self.picker_filtered.items.len == 0) {
            self.closePicker();
            return;
        }
        const it = self.picker_items.items[self.picker_filtered.items[self.picker_sel]];
        if (self.picker_kind == .code_action) {
            const idx = it.line; // the action index stashed at population time
            self.closePicker();
            return self.applyCodeAction(idx);
        }
        if (self.picker_kind == .undo) {
            const seq = it.line;
            self.closePicker();
            if (!self.history.goToSeq(self.buf, &self.cy, &self.cx, seq)) return self.setStatus("that state is gone", .{});
            self.setStatus("state {d}", .{seq});
            self.afterHistoryMove();
            return;
        }
        if (self.picker_kind == .command) {
            const idx = it.line; // the table index stashed at population time
            self.closePicker();
            return self.runCommand(idx);
        }
        if (self.picker_kind == .symbol) {
            const idx = it.line; // the symbol index stashed at population time
            self.closePicker();
            self.jumpToSymbol(idx);
            return;
        }
        if (self.picker_kind == .theme) {
            var name_buf: [64]u8 = undefined;
            const tp = self.itemPath(it);
            const n = @min(tp.len, name_buf.len);
            @memcpy(name_buf[0..n], tp[0..n]);
            self.closePicker();
            _ = theme.set(name_buf[0..n]);
            self.theme_before = theme.current_name; // chosen: nothing to restore
            self.prev_valid = false;
            // Remember it: a theme picked and lost on restart is a setting
            // that does not work.
            config.saveKey(self.gpa, self.io, "theme", name_buf[0..n]) catch |err| {
                self.setStatus("theme: {s} (not saved: {s})", .{ name_buf[0..n], @errorName(err) });
                return;
            };
            self.setStatus("theme: {s} — saved", .{name_buf[0..n]});
            return;
        }
        if (self.picker_kind == .buffer) {
            const idx = it.line; // the doc index stashed at population time
            self.closePicker();
            if (idx < self.docs.items.len) {
                self.addJump();
                self.focusDoc(self.docs.items[idx]);
                self.placeAt(self.cy);
            }
            return;
        }
        const path = self.gpa.dupe(u8, self.itemPath(it)) catch return;
        defer self.gpa.free(path);
        // `.line` is 1-based only for the kinds that name a source line; the
        // files picker stores its cache index there (for the prefilter), which
        // must not be mistaken for a place to put the cursor.
        const line: usize = if (self.picker_kind == .files) 0 else if (it.line > 0) it.line - 1 else 0;
        self.closePicker();
        self.openFile(path, line);
    }

    /// Swap the per-document state between the Editor mirror and `doc`. Calling
    /// it for the old active doc saves the live state into it; calling it for
    /// the new doc loads that doc's state into the mirror. `buf` is not swapped
    /// (it lives in the Doc; `self.buf` is repointed by the caller).
    fn swapDocState(self: *Editor, doc: *Doc) void {
        std.mem.swap(syntax.Language, &self.lang, &doc.lang);
        std.mem.swap(undo.History, &self.history, &doc.history);
        std.mem.swap([26]?Pos, &self.marks, &doc.marks);
        std.mem.swap(git.Signs, &self.git_signs, &doc.git_signs);
        std.mem.swap(?lsp.Client, &self.lsp, &doc.lsp);
        std.mem.swap(u64, &self.lsp_rev, &doc.lsp_rev);
        std.mem.swap(bool, &self.lsp_opened, &doc.lsp_opened);
        std.mem.swap(?treesitter.Highlighter, &self.ts, &doc.ts);
        std.mem.swap(std.ArrayList(syntax.Style), &self.ts_styles, &doc.ts_styles);
        std.mem.swap(std.ArrayList(usize), &self.ts_line_starts, &doc.ts_line_starts);
        std.mem.swap(usize, &self.ts_doc_len, &doc.ts_doc_len);
        std.mem.swap(usize, &self.ts_vis_start, &doc.ts_vis_start);
        std.mem.swap(u64, &self.ts_rev, &doc.ts_rev);
        std.mem.swap(usize, &self.ts_q_top, &doc.ts_q_top);
        std.mem.swap(usize, &self.ts_q_rows, &doc.ts_q_rows);
    }

    /// Make `doc` the active document, moving the live per-doc state in/out of
    /// the Editor mirror. Tree-sitter is preserved across switches; a doc with
    /// none yet (freshly opened) gets it built here. Does not touch windows.
    fn loadDoc(self: *Editor, doc: *Doc) void {
        if (doc == self.d) return;
        self.swapDocState(self.d); // save active -> old doc
        self.d = doc;
        self.swapDocState(self.d); // load new doc -> mirror
        self.buf = &doc.buf;
        if (self.ts == null and !self.decorate_pending) self.startTs();
    }

    /// Point the active window at `doc` (e.g. `:e`, `:bn`).
    fn focusDoc(self: *Editor, doc: *Doc) void {
        if (doc == self.cur.doc) return;
        self.alt_doc = self.cur.doc; // what `Ctrl-^` flips back to
        self.loadDoc(doc);
        self.cur.doc = doc;
        self.comp_open = false;
        self.sig_open = false;
        self.sbReveal(); // keep the explorer pointing at the active file
    }

    fn winIndex(self: *Editor, w: *Win) usize {
        for (self.wins.items, 0..) |it, i| if (it == w) return i;
        return 0;
    }

    /// Move focus to window `w`, swapping its document in if different.
    fn focusWin(self: *Editor, w: *Win) void {
        if (w == self.cur) return;
        self.prev_win = self.cur; // what `Ctrl-w p` goes back to
        const prev = self.cur;
        const prev_cy = self.cy;
        self.saveViewport();
        self.loadDoc(w.doc);
        self.cur = w;
        self.loadViewport();
        self.comp_open = false;
        self.sig_open = false;
        self.clearExtra();
        // Crossing a diff pair lands the cursor on the row aligned with where
        // it was (vimdiff's cursorbind) — not on the pane's stale own cursor,
        // which would yank both lockstepped panes to wherever that was.
        if (self.diffPairOf(w)) |p| {
            const partner = if (w == p.wt) p.ix else p.wt;
            if (partner == prev) {
                const d = git.displayRow(p.hunks, partner == p.wt, prev_cy);
                self.cy = @min(git.rowAtOrAfter(p.hunks, w == p.wt, d), self.buf.lineCount() - 1);
                self.cx = 0;
                self.goal_col = 0;
                self.clampCursor();
            }
        }
    }

    const Dir = enum { left, right, up, down };

    /// Move focus one window in `dir`, treating the file tree as the window
    /// beyond the edge it is docked to. The tiling is flat and one orientation
    /// at a time, so "left" and "right" step the list when the split is
    /// vertical and "up"/"down" step it when the split is horizontal; the
    /// other axis only ever reaches the tree.
    fn moveFocus(self: *Editor, dir: Dir) void {
        const side: Dir = if (config.settings.sidebar == .left) .left else .right;
        const back: Dir = if (side == .left) .right else .left;
        // Out of the tree, back to the text.
        if (self.sb_focus) {
            if (dir == back) self.sb_focus = false;
            return;
        }
        const n = self.wins.items.len;
        const idx = self.winIndex(self.cur);
        // Into the tree: only from the window on the tree's side, and only
        // when the split does not already have a window that way to go to.
        if (dir == side and self.sb_open) {
            const at_edge = !self.split_vertical or idx == (if (side == .left) 0 else n - 1);
            if (at_edge) {
                self.sb_focus = true;
                return;
            }
        }
        if (n <= 1) return;
        const along = if (self.split_vertical) (dir == .left or dir == .right) else (dir == .up or dir == .down);
        if (!along) return;
        const forward = dir == .right or dir == .down;
        // No wrap: `Ctrl-w w` is the cycle, this is a direction, and wrapping
        // would make Ctrl-l at the last window jump back to the first.
        if (forward and idx + 1 < n) {
            self.focusWin(self.wins.items[idx + 1]);
        } else if (!forward and idx > 0) {
            self.focusWin(self.wins.items[idx - 1]);
        }
    }

    /// `Ctrl-w p` — back to the last window that had focus.
    fn focusPrevWindow(self: *Editor) void {
        const w = self.prev_win orelse return;
        for (self.wins.items) |x| {
            if (x == w) return self.focusWin(w);
        }
    }

    /// `Ctrl-w t` / `Ctrl-w b` — the first or last window in the tiling.
    fn focusWinAt(self: *Editor, i: usize) void {
        if (i < self.wins.items.len) self.focusWin(self.wins.items[i]);
    }

    /// `Ctrl-w H/J/K/L` — move this window to one end of the tiling. The
    /// layout is flat and single-orientation, so "far left" and "very top"
    /// are the same move; the pair that means the other end likewise.
    fn moveWindowTo(self: *Editor, to: usize) void {
        const n = self.wins.items.len;
        if (n <= 1) return;
        const from = self.winIndex(self.cur);
        if (from == to) return;
        const w = self.wins.orderedRemove(from);
        self.wins.insert(self.gpa, @min(to, self.wins.items.len), w) catch {
            self.wins.insert(self.gpa, from, w) catch {};
            return;
        };
        self.layout();
    }

    /// `Ctrl-w x` — swap this window with the next (the previous, when it is
    /// already last), which is what vim does with no count.
    fn swapWindow(self: *Editor) void {
        const n = self.wins.items.len;
        if (n <= 1) return;
        const i = self.winIndex(self.cur);
        const j = if (i + 1 < n) i + 1 else i - 1;
        std.mem.swap(*Win, &self.wins.items[i], &self.wins.items[j]);
        self.layout();
    }

    /// `Ctrl-w r` / `Ctrl-w R` — rotate the tiling one place.
    fn rotateWindows(self: *Editor, down: bool) void {
        const n = self.wins.items.len;
        if (n <= 1) return;
        if (down) {
            const last = self.wins.orderedRemove(n - 1);
            self.wins.insert(self.gpa, 0, last) catch return;
        } else {
            const first = self.wins.orderedRemove(0);
            self.wins.append(self.gpa, first) catch return;
        }
        self.layout();
    }

    fn nextWindow(self: *Editor, forward: bool) void {
        const n = self.wins.items.len;
        if (n <= 1) return;
        const idx = self.winIndex(self.cur);
        const ni = if (forward) (idx + 1) % n else (idx + n - 1) % n;
        self.focusWin(self.wins.items[ni]);
    }

    /// Split the active window (sharing its document), focusing the new split.
    fn splitWindow(self: *Editor, vert: bool) void {
        self.saveViewport();
        const w = self.gpa.create(Win) catch return;
        w.* = self.cur.*; // same doc + viewport
        const idx = self.winIndex(self.cur) + 1;
        self.wins.insert(self.gpa, idx, w) catch {
            self.gpa.destroy(w);
            return;
        };
        self.split_vertical = vert;
        // The new window inherits its parent's weight (copied with the rest of
        // the Win above), so a default split still tiles evenly — vim halves
        // the parent instead, which is a change of its own and not one this
        // asked for.
        self.cur = w; // focus the new split
        self.applyConfigSizes();
    }

    /// Close the active window (its document stays open). Refuses the last one.
    fn closeWindow(self: *Editor) void {
        if (self.wins.items.len <= 1) {
            self.setStatus("cannot close last window", .{});
            return;
        }
        const idx = self.winIndex(self.cur);
        const old = self.cur;
        const ni = if (idx + 1 < self.wins.items.len) idx + 1 else idx - 1;
        const target = self.wins.items[ni];
        _ = self.wins.orderedRemove(idx);
        self.gpa.destroy(old);
        self.cur = target;
        self.loadDoc(target.doc);
        self.loadViewport();
        self.comp_open = false;
        self.sig_open = false;
        self.clearExtra();
    }

    /// Close every window but the active one.
    fn onlyWindow(self: *Editor) void {
        var i: usize = 0;
        while (i < self.wins.items.len) {
            const w = self.wins.items[i];
            if (w == self.cur) {
                i += 1;
                continue;
            }
            _ = self.wins.orderedRemove(i);
            self.gpa.destroy(w);
        }
    }

    /// Cycle the active window `count` documents forward or back
    /// (`:bn` / `:bp`, `]b` / `[b` — where `2]b` skips one).
    fn cycleDoc(self: *Editor, forward: bool, count: usize) void {
        const n = self.docs.items.len;
        if (n <= 1) return;
        self.addJump();
        const idx = self.docIndex(self.d);
        const step = count % n;
        const ni = if (forward) (idx + step) % n else (idx + n - step) % n;
        self.focusDoc(self.docs.items[ni]);
        self.placeAt(self.cy);
        self.setStatus("{s}", .{docLabel(self.d)});
    }

    /// Open `path` in the active window: focus its doc if already open, else
    /// load it into a new doc (with its own LSP/tree-sitter/undo).
    ///
    /// `line` is a **0-based row**, as `placeAt` takes — not the 1-based line
    /// number a user or a protocol talks in. Both the quickfix list and the
    /// debugger got that wrong, and `placeAt`'s clamp to the last row hid it
    /// whenever the target was near the end of the file.
    fn openFile(self: *Editor, path: []const u8, line: usize) void {
        self.addJump();
        self.noteRecent(path, .file);
        self.dashboard = false;
        // vim's rule (nvim-verified): opening a file on top of an *untouched*
        // [No Name] buffer replaces it instead of leaving it in :ls — a
        // `zedit .` session must not carry its startup buffer forever. Kept
        // when it is modified, non-empty (--tutor), a named scratch, or still
        // shown in another window; destroyed only after focus has moved off it.
        const prev = self.d;
        var prev_wins: usize = 0;
        for (self.wins.items) |w| {
            if (w.doc == prev) prev_wins += 1;
        }
        const adopt = prev.buf.path == null and prev.name == null and
            !prev.buf.dirty and prev.buf.lineCount() == 1 and
            prev.buf.line(0).len == 0 and prev_wins == 1;
        for (self.docs.items) |doc| {
            const p = doc.buf.path orelse continue; // `prev` can never match: it has no path
            if (std.mem.eql(u8, p, path)) {
                self.focusDoc(doc);
                if (adopt) self.destroyDoc(prev);
                self.placeAt(line);
                // The doc's own copy, not `path`: focusDoc's reveal may
                // rebuild the sidebar entries that own the argument.
                self.setStatus("switched to {s}", .{doc.buf.path orelse ""});
                return;
            }
        }
        const nb = buffer.Buffer.load(self.gpa, self.io, path) catch |err| {
            self.setStatus("cannot open {s}: {s}", .{ path, saveErrorReason(err) });
            self.notifyToast(.err, "cannot open {s}", .{std.fs.path.basename(path)});
            std.log.scoped(.editor).err("open failed: {s}: {s}", .{ path, @errorName(err) });
            return;
        };
        const doc = makeDoc(self.gpa, nb) catch {
            var b = nb;
            b.deinit();
            self.setStatus("out of memory", .{});
            return;
        };
        self.docs.append(self.gpa, doc) catch {
            self.freeDoc(doc);
            return;
        };
        // Paint before decorating, exactly as the first frame does: a 300 KB
        // source file took 34 ms to appear because the parse, the `git diff`
        // and the server handshake all ran before the redraw.
        self.decorate_pending = true;
        self.focusDoc(doc);
        if (adopt) self.destroyDoc(prev);
        self.clearExtra();
        self.placeAt(line);
        self.setStatus("opened {s}", .{self.buf.path orelse ""});
    }

    fn placeAt(self: *Editor, line: usize) void {
        self.cy = @min(line, self.buf.lineCount() - 1);
        self.cx = 0;
        self.top = 0;
        self.left = 0;
        self.goal_col = 0;
    }

    /// Persist the active window's mirrored viewport back into its Win struct
    /// (so it survives focus changes and is available for rendering).
    fn saveViewport(self: *Editor) void {
        self.cur.cy = self.cy;
        self.cur.cx = self.cx;
        self.cur.goal_col = self.goal_col;
        self.cur.top = self.top;
        self.cur.left = self.left;
    }

    fn loadViewport(self: *Editor) void {
        self.cy = self.cur.cy;
        self.cx = self.cur.cx;
        self.goal_col = self.cur.goal_col;
        self.top = self.cur.top;
        self.left = self.cur.left;
    }

    /// The picker view's geometry: the prompt row, how many rows sit below
    /// it, and where the result list's columns run. Shared by
    /// `renderPickerBody` and the click hit-test (`pickerClick`) so a row can
    /// never be drawn at one place and clicked at another — the tabline's
    /// invariant (`tabArea`), applied here.
    const PickerLayout = struct {
        top: usize, // the prompt's screen row (results start one below)
        visible: usize, // result rows below the prompt
        body_x: usize, // first column of the prompt/results
        body_w: usize, // width beside the sidebar
        list_w: usize, // the results' width (rest is the preview)
        preview: bool,
        status: bool, // the bottom row is the status message's, not a result's
        /// The floating box, when the terminal is big enough for one. Null on
        /// a small screen, where the picker takes the whole view as it always
        /// did — a border costs two rows and two columns a 40x10 terminal
        /// cannot spare.
        box: ?ui.Rect = null,
    };

    /// The chrome geometry the popups share: the whole terminal, minus the
    /// title bar and the status/command row.
    fn chromeScreen(self: *Editor) ui.Screen {
        const side = if (self.sb_open) self.sbWidth() else 0;
        return .{
            .rows = self.win.rows,
            .cols = self.win.cols,
            .top_reserved = if (tabsVisible()) 1 else 0,
            .bottom_reserved = 1,
            .left_reserved = if (config.settings.sidebar == .left) side else 0,
            .right_reserved = if (config.settings.sidebar == .right) side else 0,
        };
    }
    fn pickerLayout(self: *Editor) PickerLayout {
        // The title bar keeps row 1 in the picker view too; the prompt and
        // results shift below it.
        const top = 1 + @as(usize, if (tabsVisible()) 1 else 0);
        const rows: usize = self.win.rows;
        // A status message set while the picker is up (the `zedit <dir>` scope
        // hint, a remote listing's file count) owns the bottom row — the
        // picker view has no statusline of its own. Reserving the row here
        // rather than painting over the list is what keeps the rows the
        // renderer draws and the rows the click hit-test resolves one set:
        // otherwise the last result would be hidden under the message and
        // still open when clicked.
        const status = self.status.items.len > 0;
        // Columns: [sidebar] [list] [preview]
        const side_w = if (self.sb_open) self.sbWidth() else 0;
        const body_w = self.win.cols -| side_w;
        // A preview needs room for both panes; below that the results get the
        // whole width rather than two unreadable columns.
        // Float it, helix-style, so it reads as a window over the editor
        // rather than a mode the editor has entered — which is the whole point
        // of the border: something with an edge is something you can close.
        // Roomy but not full-bleed; the text around it is the cue.
        if (ui.centered(self.chromeScreen(), (self.win.cols * 4) / 5, (self.win.rows * 4) / 5, 4)) |box| {
            const in = box.inner();
            const pv = self.previewKind() != .none and in.w >= 60;
            return .{
                .top = in.y,
                // One row of the inside is the prompt; the rest are results.
                .visible = @max(1, in.h -| 1),
                .body_x = in.x,
                .body_w = in.w,
                .list_w = if (pv) @max(in.w / 2, 24) else in.w,
                .preview = pv,
                // The message goes on the editor's own statusline, which is
                // still on screen behind the box — nothing to reserve.
                .status = false,
                .box = box,
            };
        }
        const wants_preview = self.previewKind() != .none and body_w >= 40;
        return .{
            .top = top,
            .visible = @max(1, (rows -| top) -| @as(usize, @intFromBool(status))),
            .body_x = if (self.sb_open and config.settings.sidebar == .left) side_w + 1 else 1,
            .body_w = body_w,
            .list_w = if (wants_preview) @max(body_w / 2, 24) else body_w,
            .preview = wants_preview,
            .status = status,
        };
    }

    /// The picker screen: the file tree on its configured side (when open),
    /// the results next to it, and — for anything that names a file — a live
    /// preview of the selection on the right, Helix-style. Every picker uses
    /// this same layout, so searching looks the same wherever you start it.
    fn klabelFor(kind: PickerKind) []const u8 {
        return switch (kind) {
            .files => " FILES ",
            .grep => " SEARCH ",
            .code_action => " ACTIONS ",
            .symbol => " SYMBOLS ",
            .theme => " THEMES ",
            .buffer => " BUFFERS ",
            .reference => " REFERENCES ",
            .wsymbol => " WORKSPACE SYMBOLS ",
            .diagnostic => " DIAGNOSTICS ",
            .undo => " UNDO TREE ",
            .command => " COMMANDS ",
        };
    }

    /// The ordinary editor view, painted under a floating picker.
    fn renderBehindPicker(self: *Editor) !void {
        self.layout();
        if (tabsVisible()) try self.renderTitleBar();
        for (self.wins.items) |w| try self.renderWindow(w);
        if (self.sb_open) try self.renderSidebar();
        self.beginSeg(self.win.rows, 1);
        try self.emitFmt("\x1b[{d};1H", .{self.win.rows});
        try self.renderStatus();
        self.closeSegs();
    }

    /// A rounded box: border, an optional title in the top edge and an
    /// optional hint in the bottom one, and a cleared inside. Shared by every
    /// floating thing, so they cannot drift apart.
    fn drawBox(self: *Editor, box: ui.Rect, title: []const u8, hint: []const u8) !void {
        const th = theme.current;
        if (box.w < 4 or box.h < 3) return;
        self.markOverlayRows(box.y, box.bottom());
        try self.setBg(th.bg);
        try self.setFg(th.mode_normal);
        // Top edge, with the title sunk into it.
        try self.emitFmt("\x1b[{d};{d}H", .{ box.y, box.x });
        try self.emit(ui.border.top_left);
        var drawn: usize = 0;
        const tw = @min(unicode.displayWidth(title), box.w -| 4);
        if (tw > 0) {
            try self.emit(ui.border.horizontal);
            try self.setBg(th.mode_command);
            try self.setFg(th.bg);
            try self.emitSanitized(title[0..@min(title.len, tw)]);
            try self.setBg(th.bg);
            try self.setFg(th.mode_normal);
            drawn = 1 + tw;
        }
        while (drawn + 2 < box.w) : (drawn += 1) try self.emit(ui.border.horizontal);
        try self.emit(ui.border.top_right);
        // Sides, clearing the inside as they go.
        var r: usize = box.y + 1;
        while (r < box.bottom()) : (r += 1) {
            try self.emitFmt("\x1b[{d};{d}H", .{ r, box.x });
            try self.setFg(th.mode_normal);
            try self.emit(ui.border.vertical);
            try self.setBg(th.bg);
            try self.emitSpaces(box.w - 2);
            try self.setFg(th.mode_normal);
            try self.emit(ui.border.vertical);
        }
        // Bottom edge, with the hint that says how to leave.
        try self.emitFmt("\x1b[{d};{d}H", .{ box.bottom(), box.x });
        try self.emit(ui.border.bottom_left);
        const hw = @min(unicode.displayWidth(hint), box.w -| 6);
        var used: usize = 0;
        while (used + 3 + hw < box.w - 1) : (used += 1) try self.emit(ui.border.horizontal);
        if (hw > 0) {
            try self.emit(ui.border.horizontal);
            try self.setFg(th.fg_dim);
            try self.emitSanitized(hint[0..@min(hint.len, hw)]);
            try self.setFg(th.mode_normal);
            try self.emit(ui.border.horizontal);
        }
        try self.emit(ui.border.bottom_right);
    }

    fn renderPickerBody(self: *Editor) !void {
        const th = theme.current;
        const rows: usize = self.win.rows;
        const lay = self.pickerLayout();
        const top = lay.top;
        const visible = lay.visible;
        const body_x = lay.body_x;
        const list_w = lay.list_w;
        const wants_preview = lay.preview;
        const prev_x = body_x + list_w;
        const prev_w = if (wants_preview) lay.body_w - list_w else 0;

        if (self.picker_sel < self.picker_scroll) self.picker_scroll = self.picker_sel;
        if (self.picker_sel >= self.picker_scroll + visible) self.picker_scroll = self.picker_sel - visible + 1;

        if (lay.box) |box| {
            // Float over the editor: paint the ordinary view first, so the
            // file being edited stays visible around the box and the picker
            // reads as a window sitting on top of it — the affordance that
            // says "this closes and you get your editor back".
            try self.renderBehindPicker();
            try self.drawBox(box, klabelFor(self.picker_kind), " Esc to close ");
        } else {
            // Small terminal: no room for a border, so the picker takes the
            // whole view as it always did.
            try self.setBg(th.bg);
            var clr: usize = 1;
            while (clr <= rows) : (clr += 1) {
                try self.emitFmt("\x1b[{d};1H", .{clr});
                try self.emit(ansi.clear_line_right);
            }
            if (self.sb_open) try self.renderSidebar();
            if (tabsVisible()) try self.renderTitleBar();
        }

        const klabel = klabelFor(self.picker_kind);

        // Prompt. Inside a box the title is already in the border, so the
        // prompt is just a caret — repeating "FILES" on the row below the tab
        // that says FILES is noise.
        try self.emitFmt("\x1b[{d};{d}H", .{ top, body_x });
        var label_w: usize = 0;
        if (lay.box == null) {
            try self.setBg(th.mode_command);
            try self.setFg(th.bg);
            try self.emit(klabel);
            label_w = klabel.len;
        }
        try self.setBg(th.bg);
        try self.setFg(th.mode_normal);
        try self.emit(if (lay.box == null) " " else "\u{203a} "); // ›
        label_w += if (lay.box == null) 1 else 2;
        try self.setFg(th.fg);
        const qmax = list_w -| (label_w + 1);
        try self.emitSanitized(self.picker_query.items[0..@min(self.picker_query.items.len, qmax)]);
        // Mid-typing an invalid regex: a dim tag beside the query says why
        // the results are not moving (they are the last good pattern's).
        if (self.picker_kind == .grep and self.grep_incomplete) {
            const tag = " (incomplete)";
            if (unicode.displayWidth(self.picker_query.items) + tag.len <= qmax) {
                try self.setFg(th.fg_dim);
                try self.emit(tag);
                try self.setFg(th.fg);
            }
        }

        // Results.
        var shown: usize = 0;
        while (shown < visible) : (shown += 1) {
            const fi = self.picker_scroll + shown;
            const selected = fi == self.picker_sel and fi < self.picker_filtered.items.len;
            try self.emitFmt("\x1b[{d};{d}H", .{ shown + top + 1, body_x });
            try self.setBg(if (selected) th.ui_sel else th.bg);
            var used: usize = 0;
            if (fi < self.picker_filtered.items.len) {
                const it = self.picker_items.items[self.picker_filtered.items[fi]];
                try self.setFg(if (selected) th.mode_normal else th.fg_dim);
                try self.emit(if (selected) "\u{25B6} " else "  ");
                try self.setFg(if (selected) th.fg else th.fg_dim);
                const maxw = list_w -| 3;
                const disp = self.itemDisplay(it);
                const text = disp[0..@min(disp.len, maxw)];
                try self.emitSanitized(text);
                used = 2 + unicode.displayWidth(text);
            } else if (fi == 0 and self.picker_kind == .files and self.picker_query.items.len > 0) {
                // Zero file-name matches: point at the other search scope
                // before the user concludes the file is missing (this picker
                // matches *names*; `Space f w` searches contents).
                const hint = "no file names match \u{2014} Space f w searches contents";
                const ascii = "no file names match"; // safe to byte-slice
                const maxw = list_w -| 3;
                const text = if (unicode.displayWidth(hint) <= maxw) hint else ascii[0..@min(ascii.len, maxw)];
                try self.setFg(th.fg_dim);
                try self.emit("  ");
                try self.emitSanitized(text);
                used = 2 + unicode.displayWidth(text);
            }
            if (used < list_w) try self.emitSpaces(list_w - used);
        }

        // The status row (`pickerLayout` already kept it out of the list) is
        // the bottom one, so the preview stops a row short of it.
        // The preview's last row. Inside a floating box that is the box's own
        // bottom edge, not the screen's — passing the screen height painted
        // the preview straight through the border and over the statusline.
        const prev_bot = if (lay.box != null) top + visible else rows -| @as(usize, @intFromBool(lay.status));
        if (wants_preview) try self.renderPreview(prev_x, prev_w, top, prev_bot);

        // A status message set while the picker is up — the `zedit <dir>`
        // scope hint, a remote listing's file count — paints that row dim:
        // the picker view has no statusline, and the next keystroke clears it
        // (`handleKey`). Clipped and sanitized like any other outside text: a
        // remote destination and a file name both reach here.
        if (lay.status) {
            try self.emitFmt("\x1b[{d};{d}H", .{ rows, body_x });
            try self.setBg(th.bg);
            try self.setFg(th.fg_dim);
            const cut = clipCells(self.status.items, lay.body_w);
            try self.emitSanitized(self.status.items[0..cut.bytes]);
            try self.emitSpaces(lay.body_w - cut.cells);
        }

        // The width the prompt *actually* took, not a second guess at it: in a
        // floating box the prompt is a two-cell caret, not the picker's name,
        // and recomputing it here put the caret six columns from the text it
        // was supposed to be sitting after.
        try self.emitFmt("\x1b[{d};{d}H", .{ top, body_x + label_w + unicode.displayWidth(self.picker_query.items) });
        try self.emit(ansi.show_cursor);
    }

    const PreviewKind = enum { none, file, line };

    /// Whether the current picker's selection names something previewable:
    /// a file (file picker, buffers) or a file *and line* (grep, references).
    fn previewKind(self: *Editor) PreviewKind {
        // Remote entries are not previewed (that would be an ssh round trip
        // per keystroke), so they keep the full width for the results.
        if (self.remote_root != null) return .none;
        if (self.picker_sel < self.picker_filtered.items.len) {
            const it = self.picker_items.items[self.picker_filtered.items[self.picker_sel]];
            if (remote.isRemote(self.itemPath(it))) return .none;
        } else if (self.picker_query.items.len > 0) {
            // A query nothing matches: there is nothing to preview, so the
            // results — and the files picker's no-match hint — take the full
            // width. With no query typed yet the pane stays reserved, because
            // a cold `zedit <dir>` paints its first frame before the walk has
            // delivered a single row and the list must not re-lay itself out
            // under the reader a frame later.
            return .none;
        }
        return switch (self.picker_kind) {
            .files => .file,
            .buffer => .file,
            .grep, .reference => .line,
            .diagnostic, .wsymbol => .line,
            .theme, .code_action, .symbol, .undo, .command => .none,
        };
    }

    /// Drop the previewed file. The highlighter is deliberately kept: building
    /// one compiles the grammar's highlight query, which costs ~14 ms, so it
    /// is reused for every later file of the same language (see `warmPreview`).
    fn clearPreview(self: *Editor) void {
        if (self.preview_path) |p| self.gpa.free(p);
        if (self.preview_text) |t| self.gpa.free(t);
        self.preview_path = null;
        self.preview_text = null;
        self.preview_styles.clearRetainingCapacity();
    }

    fn dropPreviewHighlighter(self: *Editor) void {
        if (self.preview_ts) |*h| h.deinit();
        self.preview_ts = null;
        self.preview_ts_lang = .none;
    }

    /// Load the selected entry's file into the preview cache (only when the
    /// path changed — moving the selection within one file is free).
    fn ensurePreview(self: *Editor) void {
        if (self.picker_sel >= self.picker_filtered.items.len) return self.clearPreview();
        const it = self.picker_items.items[self.picker_filtered.items[self.picker_sel]];
        const ipath = self.itemPath(it);
        self.preview_top = if (self.previewKind() == .line and it.line > 0) it.line - 1 else 0;
        if (self.preview_path) |p| {
            if (std.mem.eql(u8, p, ipath)) return; // already loaded
        }
        self.clearPreview();
        self.preview_scroll = 0; // a new file starts at its own beginning
        // A preview is a convenience: skip anything that would cost a round
        // trip or a huge read.
        if (remote.isRemote(ipath)) return;
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, ipath, self.gpa, .limited(256 << 10)) catch return;
        self.preview_path = self.gpa.dupe(u8, ipath) catch null;
        self.preview_text = text;

        // The parse is deliberately *not* done here: compiling the grammar's
        // highlight query and parsing the file costs ~14 ms, which would sit
        // between the picker keystroke and its first frame. `warmPreview`
        // does it after that frame is on screen, so the picker still opens in
        // ~5 ms and the colours arrive with the next redraw.
        self.preview_warm = text.len <= (64 << 10);
    }

    /// Parse the previewed file for tree-sitter highlighting. Called after the
    /// frame has been written, never before it.
    fn warmPreview(self: *Editor) void {
        if (!self.preview_warm) return;
        self.preview_warm = false;
        const path = self.preview_path orelse return;
        const text = self.preview_text orelse return;
        const lang = syntax.detect(path);
        if (self.preview_ts == null or self.preview_ts_lang != lang) {
            self.dropPreviewHighlighter();
            var sp = log.Span.start();
            self.preview_ts = treesitter.Highlighter.init(self.gpa, lang);
            self.preview_ts_lang = lang;
            sp.lap("preview-ts-init");
        }
        var sp2 = log.Span.start();
        if (self.preview_ts) |*h| h.reparse(text); // cheap: the query is already compiled
        sp2.lap("preview-ts-parse");
    }

    /// Scroll the preview pane itself (`Ctrl-d` / `Ctrl-u`, or the wheel while
    /// the picker is open), independently of the selection.
    fn scrollPreview(self: *Editor, lines: isize) void {
        if (self.previewKind() == .none) return;
        self.preview_scroll += lines;
        const floor = -@as(isize, @intCast(self.preview_top));
        if (self.preview_scroll < floor) self.preview_scroll = floor; // not past line 1
    }

    /// Draw the preview pane: the selected file, syntax-highlighted, scrolled
    /// so a matched line (grep, references) sits in view and marked.
    fn renderPreview(self: *Editor, x: usize, w: usize, top: usize, rows: usize) !void {
        const th = theme.current;
        self.ensurePreview();

        try self.emitFmt("\x1b[{d};{d}H", .{ top, x });
        try self.setBg(th.status_seg_bg);
        try self.setFg(th.status_seg_fg);
        const name: []const u8 = if (self.preview_path) |p| std.fs.path.basename(p) else "";
        try self.emit(" ");
        try self.emitSanitized(name[0..@min(name.len, w -| 2)]);
        if (unicode.displayWidth(name) + 1 < w) try self.emitSpaces(w - unicode.displayWidth(name) - 1);

        const text = self.preview_text orelse return;
        const body_rows = rows -| top;
        // Centre the target line when the entry named one, then apply whatever
        // the reader scrolled on top of that.
        const centred = if (self.preview_top > body_rows / 2) self.preview_top - body_rows / 2 else 0;
        var first = @as(usize, @intCast(@max(0, @as(isize, @intCast(centred)) + self.preview_scroll)));
        // Stop at the end of the file: keep a few lines on screen rather than
        // scrolling into blank space, and remember the clamp so holding the
        // key does not build up an offset that has to be unwound.
        const n_lines = std.mem.count(u8, text, "\n") + 1;
        const max_first = n_lines -| @min(n_lines, 3);
        if (first > max_first) {
            first = max_first;
            self.preview_scroll = @as(isize, @intCast(first)) - @as(isize, @intCast(centred));
        }
        const lang = if (self.preview_path) |p| syntax.detect(p) else .none;
        self.queryPreviewStyles(text, first, body_rows);

        var line_no: usize = 0;
        var offset: usize = 0; // byte offset of the line, for the style lookup
        var row: usize = top + 1;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| : (line_no += 1) {
            defer offset += line.len + 1;
            if (line_no < first) continue;
            if (row > rows) break;
            const hit = self.previewKind() == .line and line_no == self.preview_top;
            try self.emitFmt("\x1b[{d};{d}H", .{ row, x });
            try self.setBg(if (hit) th.cursorline else th.bg);
            try self.setFg(th.fg_dim);
            var nb: [8]u8 = undefined;
            const num = std.fmt.bufPrint(&nb, "{d: >4} ", .{line_no + 1}) catch "     ";
            try self.emit(num);
            try self.emitPreviewLine(line, lang, w -| num.len, offset);
            row += 1;
        }
    }

    /// Run the tree-sitter query over just the lines the preview shows, the
    /// same visible-range trick the editor uses so cost is O(pane), not
    /// O(file). No-op when the file was too big to parse (the lexer covers it).
    fn queryPreviewStyles(self: *Editor, text: []const u8, first: usize, rows: usize) void {
        if (self.preview_warm) return; // not parsed yet: this frame uses the lexer
        var h = if (self.preview_ts) |*x| x else return;
        var start: usize = 0;
        var line_no: usize = 0;
        var i: usize = 0;
        while (i < text.len and line_no < first) : (i += 1) {
            if (text[i] == '\n') {
                line_no += 1;
                start = i + 1;
            }
        }
        var end = start;
        var shown: usize = 0;
        while (end < text.len and shown < rows) : (end += 1) {
            if (text[end] == '\n') shown += 1;
        }
        self.preview_styles.resize(self.gpa, end - start) catch return;
        h.queryRange(start, end, self.preview_styles.items);
        self.preview_vis = start;
    }

    /// One preview line, lexer-highlighted and clipped (no tree-sitter here:
    /// the preview is a glance, not an editable view).
    fn emitPreviewLine(self: *Editor, line: []const u8, lang: syntax.Language, w: usize, offset: usize) !void {
        self.style_buf.resize(self.gpa, line.len) catch {};
        const styled = self.style_buf.items.len == line.len;
        if (styled) {
            if (self.preview_ts != null and !self.preview_warm) {
                // Tree-sitter styles, sliced out of the queried range.
                for (self.style_buf.items, 0..) |*s, i| {
                    const abs = offset + i;
                    s.* = if (abs >= self.preview_vis and abs - self.preview_vis < self.preview_styles.items.len)
                        self.preview_styles.items[abs - self.preview_vis]
                    else
                        .normal;
                }
            } else {
                syntax.highlight(lang, line, self.style_buf.items);
            }
        }
        var used: usize = 0;
        var i: usize = 0;
        while (i < line.len and used < w) {
            const d = unicode.decode(line[i..]);
            const cw = if (d.cp == '\t') @min(tabWidth(), w - used) else unicode.width(d.cp);
            if (used + cw > w) break;
            try self.setFg(if (styled) self.styleColor(self.style_buf.items[i]) else theme.current.fg);
            if (d.cp == '\t') {
                try self.emitSpaces(cw);
            } else {
                try self.emit(if (isControlCp(d.cp) or invalidDecode(d)) "?" else line[i .. i + d.len]);
            }
            used += cw;
            i += d.len;
        }
        if (used < w) try self.emitSpaces(w - used);
    }

    // === command line ======================================================

    fn enterCmd(self: *Editor, kind: CmdKind) void {
        self.mode = .command;
        self.cmd_kind = kind;
        self.cmd.clearRetainingCapacity();
        self.cmd_cur = 0;
        self.hist_pos = null;
        self.cmd_reg = false;
        self.wildClear();
        self.ghostUpdate(); // empty line: clears any suggestion left behind
        if (kind != .ex) {
            // Remember where we started so the search can preview live and be
            // cancelled, and save the previous pattern to restore on cancel.
            self.search_origin = self.cursor();
            self.prev_search.clearRetainingCapacity();
            self.prev_search.appendSlice(self.gpa, self.last_search.items) catch {};
        }
        self.resetPending();
    }

    fn searching(self: *Editor) bool {
        return self.cmd_kind == .search_forward or self.cmd_kind == .search_backward;
    }

    /// The command-line prompt string for the current kind (ASCII, so its byte
    /// length is also its display width).
    fn cmdPrompt(self: *Editor) []const u8 {
        return switch (self.cmd_kind) {
            .ex => ":",
            .search_forward => "/",
            .search_backward => "?",
            .rename => "rename: ",
            .new_file => "new file: ",
            .new_dir => "new folder: ",
        };
    }

    /// Start an LSP rename: prompt on the command line, pre-filled with the
    /// identifier under the cursor (which is what gets renamed).
    fn enterRename(self: *Editor) void {
        defer self.resetPending();
        if (self.lsp == null) return self.setStatus("no language server", .{});
        self.mode = .command;
        self.cmd_kind = .rename;
        self.cmd.clearRetainingCapacity();
        self.cmd.appendSlice(self.gpa, self.identUnderCursor()) catch {};
        self.cmd_cur = self.cmd.items.len;
        self.cmd_reg = false;
        // The rename prompt never ghosts (it has no history, and command
        // names make no sense there); this clears any stale `:` suggestion.
        self.ghostUpdate();
    }

    /// The identifier spanning the cursor on the current line (empty if none).
    fn identUnderCursor(self: *Editor) []const u8 {
        const line = self.curLine();
        var start = self.cx;
        while (start > 0) {
            const p = unicode.prevBoundary(line, start);
            if (!isIdentCp(unicode.decode(line[p..]).cp)) break;
            start = p;
        }
        var end = self.cx;
        while (end < line.len) {
            const d = unicode.decode(line[end..]);
            if (!isIdentCp(d.cp)) break;
            end += d.len;
        }
        return line[start..end];
    }

    fn commandKey(self: *Editor, k: key.Key) !void {
        // c_CTRL-R: the key after it names the register (nvim draws a `"` at
        // the cursor while it waits — probe R8). Esc, or anything that is not
        // a register name, abandons the prompt and keeps the line (probe R9).
        if (self.cmd_reg) {
            self.cmd_reg = false;
            switch (k) {
                .char => |c| self.cmdInsertRegister(c),
                else => {},
            }
            return;
        }
        switch (k) {
            .escape => self.cmdCancel(),
            .enter => {
                const kind = self.cmd_kind;
                self.pushHistory();
                self.wildClear();
                self.mode = .normal;
                switch (kind) {
                    .ex => try self.execEx(),
                    // The cursor already moved live; record the origin so
                    // Ctrl-o returns to where the search began.
                    .search_forward, .search_backward => {
                        self.addJumpAt(self.d, self.search_origin);
                        // A bare `/` or `?` repeats the last pattern, in the
                        // direction just given (vim's rule). The incremental
                        // preview has nothing to show for an empty pattern, so
                        // the jump only happens here, on commit.
                        if (self.cmd.items.len == 0) {
                            self.runSearch("", kind == .search_forward);
                        } else if (!self.search_hit) self.failed = true; // E486: no match
                    },
                    .rename => self.lspRename(),
                    .new_file, .new_dir => self.createEntry(kind == .new_dir),
                }
            },
            .backspace => {
                if (self.cmd.items.len == 0) {
                    self.cmdCancel();
                } else if (self.cmd_cur > 0) {
                    // Delete the codepoint before the cursor; at the start of
                    // a non-empty line this is a no-op (nvim, probe M8).
                    const p = unicode.prevBoundary(self.cmd.items, self.cmd_cur);
                    self.cmd.replaceRange(self.gpa, p, self.cmd_cur - p, "") catch {};
                    self.cmd_cur = p;
                    self.cmdEdited();
                }
            },
            .delete => self.cmdDelete(),
            .tab => self.wildNext(true),
            .shift_tab => self.wildNext(false),
            // While a path-completion popup is open, Up/Down navigate
            // directories (nvim 'wildmenu', probes W1/W2/W6); any other popup
            // falls through to plain history recall, which is exactly what
            // nvim does there (probes W5c/W5e — the completed line filters).
            .up => if (self.wildPathsActive()) self.wildParent() else self.histRecall(true, true),
            .down => if (self.wildPathsActive()) self.wildDescend() else self.histRecall(false, true),
            .ctrl => |c| switch (c) {
                // vim's c_CTRL-P/c_CTRL-N: history without the prefix filter.
                'p' => self.histRecall(true, false),
                'n' => self.histRecall(false, false),
                // vim's c_CTRL-B/c_CTRL-E: line start / line end.
                'b' => self.cmd_cur = 0,
                'e' => self.cmdEnd(),
                // vim's c_CTRL-W / c_CTRL-U / c_CTRL-R.
                'w' => self.cmdEraseWord(),
                'u' => self.cmdEraseToStart(),
                'r' => self.cmd_reg = true,
                else => {},
            },
            .char => |c| {
                var enc: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &enc) catch return;
                try self.cmd.insertSlice(self.gpa, self.cmd_cur, enc[0..len]);
                self.cmd_cur += len;
                self.cmdEdited();
            },
            // While the wildmenu popup is open, Left/Right select the
            // previous/next match (nvim, probes W3a-W3d); otherwise they move
            // the cursor, and Right at end-of-line accepts the inline
            // suggestion (fish — mid-line it only moves, never accepts).
            .left => if (self.wild.items.len > 0) self.wildNext(false) else {
                self.cmd_cur = unicode.prevBoundary(self.cmd.items, self.cmd_cur);
            },
            .right => if (self.wild.items.len > 0) self.wildNext(true) else if (self.cmd_cur < self.cmd.items.len) {
                self.cmd_cur = unicode.nextBoundary(self.cmd.items, self.cmd_cur);
            } else self.acceptGhost(),
            .home => self.cmd_cur = 0,
            .end => self.cmdEnd(),
            else => {},
        }
    }

    /// Leave the command line without running it (Esc, backspace or Delete on
    /// an empty line): a search restores its previous pattern and cursor, and
    /// the abandoned line is remembered in the history too (vim's rule).
    fn cmdCancel(self: *Editor) void {
        if (self.searching()) {
            self.last_search.clearRetainingCapacity();
            self.last_search.appendSlice(self.gpa, self.prev_search.items) catch {};
            self.setCursor(self.search_origin);
        }
        self.pushHistory();
        self.wildClear();
        self.mode = .normal;
    }

    /// Everything an edit of the command line implies: the wildmenu ring no
    /// longer describes the line (nvim, probes W26-W29), the history filter
    /// follows the new text, a search previews live and the inline suggestion
    /// is recomputed. Every path that changes `cmd` ends here.
    fn cmdEdited(self: *Editor) void {
        self.cmd_reg = false; // an edit (e.g. a paste) ends a pending c_CTRL-R
        self.wildClear();
        self.histEdited();
        if (self.searching()) self.searchLive();
        self.ghostUpdate();
    }

    /// c_<Del>: delete the character under the cursor — but at end-of-line the
    /// one *before* it (nvim probe D3b: ":s/a/XY" + Del ran ":s/a/X"), and on
    /// an empty line it cancels the command line exactly as backspace does
    /// (probe D8: ':' + Del left normal mode, where the next 'q' showed as a
    /// pending register in 'showcmd').
    fn cmdDelete(self: *Editor) void {
        if (self.cmd.items.len == 0) return self.cmdCancel();
        if (self.cmd_cur < self.cmd.items.len) {
            const n = unicode.nextBoundary(self.cmd.items, self.cmd_cur);
            self.cmd.replaceRange(self.gpa, self.cmd_cur, n - self.cmd_cur, "") catch {};
        } else {
            const p = unicode.prevBoundary(self.cmd.items, self.cmd_cur);
            self.cmd.replaceRange(self.gpa, p, self.cmd_cur - p, "") catch {};
            self.cmd_cur = p;
        }
        self.cmdEdited();
    }

    /// c_CTRL-W: erase the word before the cursor — the whitespace in front of
    /// it goes too (nvim probe W2: ":foo bar " -> ":foo "). A no-op at column
    /// 0 (probe W9); it never cancels the line (probes W19/W20).
    fn cmdEraseWord(self: *Editor) void {
        if (self.cmd_cur == 0) return;
        const start = wordEraseStart(self.cmd.items, self.cmd_cur);
        self.cmd.replaceRange(self.gpa, start, self.cmd_cur - start, "") catch {};
        self.cmd_cur = start;
        self.cmdEdited();
    }

    /// c_CTRL-U: erase everything between the start of the line and the
    /// cursor, keeping the tail (nvim probe U2: ":abcdef" + 3 Lefts + Ctrl-U
    /// left ":def"). A no-op at column 0, and it never cancels the line —
    /// unlike backspace, an empty line stays open (probes U3/U4).
    fn cmdEraseToStart(self: *Editor) void {
        if (self.cmd_cur == 0) return;
        self.cmd.replaceRange(self.gpa, 0, self.cmd_cur, "") catch {};
        self.cmd_cur = 0;
        self.cmdEdited();
    }

    /// c_CTRL-R: insert a register's contents at the cursor — named `a`-`z`,
    /// the unnamed `"`, and the clipboard `+`/`*` (its shadow copy). An
    /// unknown or empty register inserts nothing and swallows the key, leaving
    /// the line untouched (nvim probes R5/R6).
    ///
    /// A linewise register ends in a newline, which vim drops; an interior one
    /// becomes a literal CR — nvim renders that "^M" (probe R3:
    /// ":xhello world^Msecond line"), zedit '?', because register text is
    /// untrusted and goes through the same sanitizer as the rest of the line.
    fn cmdInsertRegister(self: *Editor, name: u21) void {
        if (name > 0x7f) return;
        const reg = self.registers.get(@intCast(name)) orelse return;
        var text = reg.text;
        if (text.len > 0 and text[text.len - 1] == '\n') text = text[0 .. text.len - 1];
        if (text.len == 0) return;
        const at = self.cmd_cur;
        self.cmd.insertSlice(self.gpa, at, text) catch return;
        for (self.cmd.items[at..][0..text.len]) |*b| {
            if (b.* == '\n') b.* = '\r';
        }
        self.cmd_cur = at + text.len;
        self.cmdEdited();
    }

    /// End / Ctrl-e: to end-of-line; already there, accept the ghost (fish).
    fn cmdEnd(self: *Editor) void {
        if (self.cmd_cur < self.cmd.items.len) {
            self.cmd_cur = self.cmd.items.len;
        } else self.acceptGhost();
    }

    /// Accept the inline suggestion (Right/End/Ctrl-e at end-of-line). With
    /// no ghost it is a no-op, and while the wildmenu ring holds the line the
    /// ghost is hidden, so it cannot be accepted either.
    fn acceptGhost(self: *Editor) void {
        if (self.wild.items.len > 0 or self.ghost.items.len == 0) return;
        self.cmd.appendSlice(self.gpa, self.ghost.items) catch return;
        self.cmd_cur = self.cmd.items.len;
        self.histEdited();
        if (self.searching()) self.searchLive();
        self.ghostUpdate();
    }

    /// Put a completion on the line: `head` replaces the text before the
    /// cursor, the tail the completion started with follows it, and the cursor
    /// sits between them. nvim completes only the text before the cursor and
    /// keeps the rest (probe T1: ":e alXY" + Left Left + Tab left
    /// ":e alpha.txtXY" with the cursor after ".txt"; probe T3: cycling past
    /// the last match restored ":e alXY", tail included).
    fn setCmdHead(self: *Editor, head: []const u8) void {
        self.cmd.clearRetainingCapacity();
        self.cmd.appendSlice(self.gpa, head) catch {};
        self.cmd.appendSlice(self.gpa, self.wild_tail.items) catch {};
        self.cmd_cur = head.len;
        if (self.searching()) self.searchLive();
        self.ghostUpdate();
    }

    /// Replace the command line's content (history recall). The cursor goes to
    /// end-of-line (vim's rule, probe M9).
    fn setCmd(self: *Editor, text: []const u8) void {
        if (text.ptr != self.cmd.items.ptr) {
            self.cmd.clearRetainingCapacity();
            self.cmd.appendSlice(self.gpa, text) catch {};
        }
        self.cmd_cur = self.cmd.items.len;
        if (self.searching()) self.searchLive();
        self.ghostUpdate();
    }

    /// Recompute the command line's inline suggestion (fish-style "ghost"):
    /// the newest history entry that strictly extends the typed text, else —
    /// for `:` — the first command name that does. Runs on every edit of
    /// `cmd`; a scan over at most 100 history entries plus the command-name
    /// table, and never any filesystem I/O (Tab completion covers paths).
    /// The rename prompt gets no ghost: it has no history (`historyList`
    /// returns null) and command names make no sense there.
    fn ghostUpdate(self: *Editor) void {
        self.ghost.clearRetainingCapacity();
        if (!config.settings.cmdline_suggestions) return;
        const typed = self.cmd.items;
        if (typed.len == 0) return; // an empty prompt suggests nothing (fish)
        if (self.historyList()) |list| {
            var i = list.items.len;
            while (i > 0) {
                i -= 1;
                const entry = list.items[i];
                if (entry.len > typed.len and std.mem.startsWith(u8, entry, typed)) {
                    self.ghost.appendSlice(self.gpa, entry[typed.len..]) catch {};
                    return;
                }
            }
        }
        if (self.cmd_kind != .ex) return;
        for (command_names) |name| {
            if (name.len > typed.len and std.mem.startsWith(u8, name, typed)) {
                self.ghost.appendSlice(self.gpa, name[typed.len..]) catch {};
                return;
            }
        }
    }

    /// Editing mid-browse updates the history filter to the new line but keeps
    /// the browse position, so Up continues older from here (vim's rule).
    fn histEdited(self: *Editor) void {
        if (self.hist_pos == null) return;
        self.hist_stash.clearRetainingCapacity();
        self.hist_stash.appendSlice(self.gpa, self.cmd.items) catch {};
    }

    /// The history list for the current command-line kind (vim keeps `:` and
    /// search histories separate); rename prompts have none.
    fn historyList(self: *Editor) ?*std.ArrayList([]u8) {
        return switch (self.cmd_kind) {
            .ex => &self.ex_hist,
            .search_forward, .search_backward => &self.search_hist,
            .rename, .new_file, .new_dir => null,
        };
    }

    /// Record the executed command line: duplicates move to newest (vim's
    /// rule), the list is capped, aborted lines are never added.
    fn pushHistory(self: *Editor) void {
        if (self.cmd.items.len == 0) return;
        const list = self.historyList() orelse return;
        for (list.items, 0..) |h, i| {
            if (std.mem.eql(u8, h, self.cmd.items)) {
                self.gpa.free(h);
                _ = list.orderedRemove(i);
                break;
            }
        }
        const owned = self.gpa.dupe(u8, self.cmd.items) catch return;
        list.append(self.gpa, owned) catch {
            self.gpa.free(owned);
            return;
        };
        if (list.items.len > 100) {
            self.gpa.free(list.items[0]);
            _ = list.orderedRemove(0);
        }
    }

    /// Walk the history (Up/Down). `filtered` recalls only entries starting
    /// with the line as typed before navigation began (vim's Up/Down);
    /// Ctrl-p/Ctrl-n pass false for plain recall. Down past the newest entry
    /// restores the typed line. All nvim-verified in `vim_compat`.
    fn histRecall(self: *Editor, up: bool, filtered: bool) void {
        const list = self.historyList() orelse return;
        self.wildClear();
        if (self.hist_pos == null) {
            self.hist_stash.clearRetainingCapacity();
            self.hist_stash.appendSlice(self.gpa, self.cmd.items) catch {};
        }
        const prefix = if (filtered) self.hist_stash.items else "";
        if (up) {
            var i = self.hist_pos orelse list.items.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.startsWith(u8, list.items[i], prefix)) {
                    self.hist_pos = i;
                    self.setCmd(list.items[i]);
                    return;
                }
            }
            // nothing older matches: keep the current line (vim beeps)
        } else {
            var i = (self.hist_pos orelse return) + 1;
            while (i < list.items.len) : (i += 1) {
                if (std.mem.startsWith(u8, list.items[i], prefix)) {
                    self.hist_pos = i;
                    self.setCmd(list.items[i]);
                    return;
                }
            }
            self.hist_pos = null;
            self.setCmd(self.hist_stash.items);
        }
    }

    fn wildClear(self: *Editor) void {
        for (self.wild.items) |w| self.gpa.free(w.text);
        self.wild.clearRetainingCapacity();
        self.wild_idx = null;
    }

    /// Tab / Shift-Tab: complete the `:` line (vim 'wildmode=full'): the first
    /// Tab computes the candidates and takes the first (last, backward); each
    /// further Tab cycles, and stepping past the end restores the typed text.
    fn wildNext(self: *Editor, forward: bool) void {
        if (self.cmd_kind != .ex) return;
        self.hist_pos = null;
        if (self.wild.items.len == 0) {
            self.wildCompute();
            if (self.wild.items.len == 0) return;
            if (self.wild.items.len == 1) {
                // A unique match completes silently — no popup, no cycle ring
                // (nvim); the next Tab recomputes from the new text, which is
                // what descends into a just-completed directory.
                self.setCmdHead(self.wild.items[0].text);
                self.wildClear();
                return;
            }
            self.wild_idx = if (forward) 0 else self.wild.items.len - 1;
            self.setCmdHead(self.wild.items[self.wild_idx.?].text);
            return;
        }
        const n = self.wild.items.len;
        if (self.wild_idx) |i| {
            if (forward) {
                self.wild_idx = if (i + 1 < n) i + 1 else null;
            } else {
                self.wild_idx = if (i > 0) i - 1 else null;
            }
        } else {
            self.wild_idx = if (forward) 0 else n - 1;
        }
        if (self.wild_idx) |i| self.setCmdHead(self.wild.items[i].text) else self.setCmdHead(self.wild_stem.items);
    }

    /// Build the completion candidates for the current `:` line: command names
    /// for the first word, then per-command arguments (paths for :e/:w, theme
    /// names for :theme).
    fn wildCompute(self: *Editor) void {
        self.wildClear();
        self.wild_paths = false;
        // Only the text before the cursor is completed; the rest is put back
        // after every candidate (nvim, probe T1).
        self.wild_stem.clearRetainingCapacity();
        self.wild_stem.appendSlice(self.gpa, self.cmd.items[0..self.cmd_cur]) catch return;
        self.wild_tail.clearRetainingCapacity();
        self.wild_tail.appendSlice(self.gpa, self.cmd.items[self.cmd_cur..]) catch return;
        const raw = self.wild_stem.items;
        if (std.mem.indexOfScalar(u8, raw, ' ')) |sp| {
            const cmd0 = raw[0..sp];
            const head = raw[0 .. sp + 1];
            const arg = raw[sp + 1 ..];
            if (eql(cmd0, "theme")) {
                self.wildThemes(head, arg);
            } else if (eql(cmd0, "e") or eql(cmd0, "edit") or eql(cmd0, "w") or eql(cmd0, "write")) {
                self.wild_paths = true;
                self.wildPaths(head, arg);
            }
        } else {
            self.wildCommands(raw);
        }
    }

    /// A path-completion popup is on screen — the state in which Up/Down are
    /// nvim's wildmenu directory-navigation keys rather than history.
    fn wildPathsActive(self: *Editor) bool {
        return self.wild.items.len > 0 and self.wild_paths;
    }

    /// Down in a path popup: descend into the selected directory and
    /// re-complete inside it, first match selected (nvim probes W1/W1b); on
    /// a file it just closes the popup, keeping the line (probe W4). The
    /// selected candidate is already on the line, so "is it a directory?"
    /// is its trailing '/'.
    fn wildDescend(self: *Editor) void {
        const line = self.cmd.items[0..self.cmd_cur]; // the completion, not the kept tail
        const is_dir = line.len > 0 and line[line.len - 1] == '/';
        self.wildClear();
        if (is_dir) self.wildNext(true);
    }

    /// Up in a path popup: re-complete in the parent of the ring's directory,
    /// dropping the typed basename — "e sub/in" lists "", "e al" lists "../"
    /// — first match selected (nvim probes W2/W6).
    fn wildParent(self: *Editor) void {
        const stem = self.wild_stem.items;
        const sp = std.mem.indexOfScalar(u8, stem, ' ') orelse return;
        const head = stem[0 .. sp + 1];
        const arg = stem[sp + 1 ..];
        const dir = if (std.mem.lastIndexOfScalar(u8, arg, '/')) |s| arg[0 .. s + 1] else "";
        var buf: [1088]u8 = undefined;
        const line = blk: {
            if (dir.len == 0) break :blk std.fmt.bufPrint(&buf, "{s}../", .{head});
            if (eql(dir, "/")) break :blk std.fmt.bufPrint(&buf, "{s}/", .{head}); // the root is its own parent
            if (std.mem.endsWith(u8, dir, "../")) break :blk std.fmt.bufPrint(&buf, "{s}{s}../", .{ head, dir });
            const last = std.mem.lastIndexOfScalar(u8, dir[0 .. dir.len - 1], '/');
            const parent = if (last) |s| dir[0 .. s + 1] else "";
            break :blk std.fmt.bufPrint(&buf, "{s}{s}", .{ head, parent });
        } catch return;
        self.wildClear();
        self.setCmdHead(line);
        self.wildNext(true);
    }

    fn wildAdd(self: *Editor, text: []const u8, show: usize) void {
        const owned = self.gpa.dupe(u8, text) catch return;
        self.wild.append(self.gpa, .{ .text = owned, .show = show }) catch self.gpa.free(owned);
    }

    /// Every completable command, by its full name (all are also accepted
    /// spelled out by execEx; the short forms still work typed by hand).
    const command_names = [_][]const u8{
        "bdelete", "bnext",   "bprevious", "buffers", "cclose", "cfirst", "clast", "close",
        "cedit",   "cnext",   "copen",     "cprev",   "debug",  "diff",   "earlier",
        "edit",    "format", "later",     "ldiff",    "ls",    "only",   "quit",
        "quitall", "session", "split",    "terminal", "theme", "undolist", "vdiff",
        "vsplit",  "wall",    "winsave",  "wq",       "write",    "x",
    };

    fn wildCommands(self: *Editor, prefix: []const u8) void {
        for (command_names) |name| {
            if (std.mem.startsWith(u8, name, prefix)) self.wildAdd(name, 0);
        }
    }

    fn wildThemes(self: *Editor, head: []const u8, prefix: []const u8) void {
        var buf: [64]u8 = undefined;
        for (theme.themes) |t| {
            if (!std.mem.startsWith(u8, t.name, prefix)) continue;
            const text = std.fmt.bufPrint(&buf, "{s}{s}", .{ head, t.name }) catch continue;
            self.wildAdd(text, head.len);
        }
    }

    /// Path completion for `:e` / `:w`: list the argument's directory, keep
    /// entries matching the basename typed so far (hidden ones only when the
    /// prefix itself starts with '.'), mark directories with a trailing '/'.
    fn wildPaths(self: *Editor, head: []const u8, arg: []const u8) void {
        const slash = std.mem.lastIndexOfScalar(u8, arg, '/');
        const dir_part = if (slash) |s| arg[0 .. s + 1] else "";
        const prefix = if (slash) |s| arg[s + 1 ..] else arg;
        const open_path = if (dir_part.len == 0) "." else dir_part;

        var dir = std.Io.Dir.cwd().openDir(self.io, open_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file and entry.kind != .directory) continue;
            if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
            if (entry.name[0] == '.' and (prefix.len == 0 or prefix[0] != '.')) continue;
            if (self.wild.items.len >= 500) break;
            var buf: [1024]u8 = undefined;
            const tail: []const u8 = if (entry.kind == .directory) "/" else "";
            const text = std.fmt.bufPrint(&buf, "{s}{s}{s}{s}", .{ head, dir_part, entry.name, tail }) catch continue;
            self.wildAdd(text, head.len + dir_part.len);
        }
        std.mem.sort(WildItem, self.wild.items, {}, struct {
            fn less(_: void, a: WildItem, b: WildItem) bool {
                return std.mem.lessThan(u8, a.text, b.text);
            }
        }.less);
    }

    /// Incremental search: jump to the first match from the original cursor as
    /// the query changes, so the result previews live (Helix-style).
    fn searchLive(self: *Editor) void {
        self.last_search.clearRetainingCapacity();
        self.last_search.appendSlice(self.gpa, self.cmd.items) catch {};
        self.last_search_forward = self.cmd_kind == .search_forward;
        self.setCursor(self.search_origin);
        self.search_hit = self.cmd.items.len > 0 and self.jumpSearch(self.last_search_forward);
    }

    fn execEx(self: *Editor) !void {
        const raw = std.mem.trim(u8, self.cmd.items, " ");
        if (raw.len == 0) return;
        try self.execLine(raw);
    }

    /// One ex command, from the command line or from `:g`'s second pass.
    fn execLine(self: *Editor, line: []const u8) anyerror!void {
        const raw = std.mem.trim(u8, line, " ");
        if (raw.len == 0) return;
        // `:g/x/g/y/d` would otherwise recurse without end.
        if (self.ex_depth > 8) return self.setStatus("commands nested too deeply", .{});
        self.ex_depth += 1;
        defer self.ex_depth -= 1;

        // Split the leading range off first, so every command below sees only
        // its own text. `:5`, `:$` and `:%s/…` all come through here, which is
        // why there is no longer a special case for any of them.
        const parsed = exrange.parse(raw);
        const rest = parsed.rest;

        // A range with no command moves to its last line: `:5`, `:$`, `:1,5`.
        if (rest.len == 0) {
            if (parsed.range.count == 0) return;
            const lr = self.resolveRange(parsed.range, false) orelse
                return self.setStatus("invalid range", .{});
            self.addJump();
            self.cy = lr.hi;
            self.cx = motion.firstNonBlank(self.curLine());
            self.updateGoal();
            return;
        }

        if (try self.execRanged(parsed.range, rest)) return;

        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        const cmd = it.next() orelse return;
        const arg = std.mem.trim(u8, rest[cmd.len..], " ");

        if (eql(cmd, "w") or eql(cmd, "write")) {
            _ = try self.write(arg);
        } else if (eql(cmd, "q") or eql(cmd, "quit")) {
            self.doQuit();
        } else if (eql(cmd, "q!") or eql(cmd, "quit!")) {
            if (self.wins.items.len > 1) self.closeWindow() else self.quit = true;
        } else if (eql(cmd, "qa") or eql(cmd, "quitall")) {
            for (self.docs.items) |doc| {
                if (doc.buf.dirty) return self.setStatus("unsaved changes — :wa or :qa!", .{});
            }
            self.quit = true;
        } else if (eql(cmd, "qa!") or eql(cmd, "quitall!")) {
            self.quit = true;
        } else if (eql(cmd, "wq") or eql(cmd, "x")) {
            if (try self.write(arg)) self.doQuit();
        } else if (eql(cmd, "e") or eql(cmd, "edit")) {
            if (arg.len > 0) self.openFile(arg, 0) else self.setStatus("usage: :e <file>", .{});
        } else if (eql(cmd, "sp") or eql(cmd, "split")) {
            self.splitWindow(false);
        } else if (eql(cmd, "vs") or eql(cmd, "vsp") or eql(cmd, "vsplit")) {
            self.splitWindow(true);
        } else if (eql(cmd, "winsave")) {
            try self.saveWindowSizes();
        } else if (eql(cmd, "clo") or eql(cmd, "close")) {
            self.closeWindow();
        } else if (eql(cmd, "on") or eql(cmd, "only")) {
            self.onlyWindow();
        } else if (eql(cmd, "copen") or eql(cmd, "cope")) {
            self.qfOpen();
        } else if (eql(cmd, "cedit") or eql(cmd, "ced")) {
            self.openMultibuffer();
        } else if (eql(cmd, "cclose") or eql(cmd, "ccl")) {
            self.qfClose();
        } else if (eql(cmd, "cnext") or eql(cmd, "cn")) {
            self.qfStep(true, 1);
        } else if (eql(cmd, "cprev") or eql(cmd, "cp") or eql(cmd, "cprevious")) {
            self.qfStep(false, 1);
        } else if (eql(cmd, "cfirst") or eql(cmd, "cfir")) {
            if (self.qf.goTo(0)) |x| self.qfJump(x) else self.setStatus("quickfix list is empty", .{});
        } else if (eql(cmd, "clast") or eql(cmd, "cla")) {
            if (self.qf.goTo(self.qf.len() -| 1)) |x| self.qfJump(x) else self.setStatus("quickfix list is empty", .{});
        } else if (eql(cmd, "cc")) {
            const n = std.fmt.parseInt(usize, arg, 10) catch 0;
            if (n == 0) return self.setStatus("usage: :cc <n>", .{});
            if (self.qf.goTo(n - 1)) |x| self.qfJump(x) else self.setStatus("no entry {d}", .{n});
        } else if (eql(cmd, "debug")) {
            self.startDebug(arg);
        } else if (eql(cmd, "term") or eql(cmd, "terminal")) {
            self.openTerminal();
        } else if (eql(cmd, "session")) {
            if (eql(arg, "save")) {
                self.sessionSave();
            } else if (eql(arg, "load")) {
                self.sessionLoad();
            } else if (eql(arg, "delete")) {
                self.sessionDelete();
            } else self.setStatus("usage: :session save | load | delete", .{});
        } else if (eql(cmd, "bn") or eql(cmd, "bnext")) {
            self.cycleDoc(true, 1);
        } else if (eql(cmd, "bp") or eql(cmd, "bprev") or eql(cmd, "bprevious")) {
            self.cycleDoc(false, 1);
        } else if (eql(cmd, "bd") or eql(cmd, "bdelete")) {
            self.closeDoc(false);
        } else if (eql(cmd, "bd!") or eql(cmd, "bdelete!")) {
            self.closeDoc(true);
        } else if (eql(cmd, "ls") or eql(cmd, "buffers")) {
            self.listBuffers();
        } else if (eql(cmd, "wa") or eql(cmd, "wall")) {
            self.writeAll();
        } else if (eql(cmd, "format") or eql(cmd, "fmt")) {
            self.lspFormat();
        } else if (eql(cmd, "ssh")) {
            // `:ssh host[:port][/dir]` — browse a remote machine's files.
            if (arg.len == 0) return self.setStatus("usage: :ssh [user@]host[/dir]", .{});
            self.openRemote(arg);
        } else if (eql(cmd, "update") or eql(cmd, "checkupdate")) {
            self.checkForUpdate();
        } else if (eql(cmd, "earlier") or eql(cmd, "ea")) {
            self.historyCommand(arg, true);
        } else if (eql(cmd, "later") or eql(cmd, "lat")) {
            self.historyCommand(arg, false);
        } else if (eql(cmd, "undolist") or eql(cmd, "undol")) {
            self.openUndoPicker();
        } else if (eql(cmd, "diff")) {
            self.gitDiffInline();
        } else if (eql(cmd, "vdiff")) {
            self.gitDiffSide();
        } else if (eql(cmd, "ldiff")) {
            self.gitDiffLine();
        } else if (eql(cmd, "theme")) {
            if (arg.len == 0) {
                self.openThemePicker();
            } else if (theme.set(arg)) {
                self.setStatus("theme: {s}", .{arg});
            } else {
                self.setStatus("unknown theme: {s} (try :theme with no argument)", .{arg});
            }
        } else {
            self.setStatus("unknown command: {s}", .{cmd});
        }
    }

    // === ex ranges =========================================================

    /// A resolved range: 0-based inclusive rows, already clamped to the buffer.
    const LineRange = struct { lo: usize, hi: usize };

    /// The line a parsed address names, 0-based. Null only when the address
    /// names nothing at all — an unset mark, a pattern that does not occur —
    /// which is the one case a command has to refuse rather than guess at.
    ///
    /// Everything else clamps rather than erroring: vim answers `:100` on a
    /// five-line file with E16, zedit takes it to the last line, which is
    /// what its `:{n}` has always done and what "never crash on bad input"
    /// asks for.
    fn resolveAddr(self: *Editor, a: exrange.Addr) ?usize {
        const last = self.buf.lineCount() - 1;
        const base: usize = switch (a.base) {
            .current => self.cy,
            .last => last,
            // Line 0 is vim's "before the first line". Every command that
            // takes a range here acts on real lines, so it means the first.
            .line => |n| if (n == 0) 0 else @min(n - 1, last),
            .mark => |m| blk: {
                // `'<` / `'>` are the ends of the last selection rather than
                // marks proper — the same record `gv` reselects from.
                if (m == '<' or m == '>') {
                    const s = self.last_vis orelse return null;
                    const top = @min(s.start.row, s.end.row);
                    const bot = @max(s.start.row, s.end.row);
                    break :blk @min(if (m == '<') top else bot, last);
                }
                if (m < 'a' or m > 'z') return null;
                break :blk @min((self.marks[m - 'a'] orelse return null).row, last);
            },
            .fwd => |pat| self.searchLine(pat, true) orelse return null,
            .bwd => |pat| self.searchLine(pat, false) orelse return null,
        };
        const shifted = @as(i64, @intCast(base)) + a.offset;
        return @intCast(std.math.clamp(shifted, 0, @as(i64, @intCast(last))));
    }

    /// The row of the next/previous line matching `pat`, for the `/pat/` and
    /// `?pat?` address forms. Case-sensitive, like `/` itself.
    fn searchLine(self: *Editor, pat: []const u8, forward: bool) ?usize {
        var re = regex.Regex.compile(self.gpa, pat, false) catch return null;
        defer re.deinit(self.gpa);
        const hit = if (forward)
            search.next(self.buf, self.cursor(), &re)
        else
            search.prev(self.buf, self.cursor(), &re);
        return if (hit) |h| h.row else null;
    }

    /// Resolve a whole range. `whole` is what *no* range means for the command
    /// asking: `:g` defaults to the file, `:d` to the cursor's line.
    fn resolveRange(self: *Editor, r: exrange.Range, whole: bool) ?LineRange {
        if (r.count == 0) return if (whole)
            .{ .lo = 0, .hi = self.buf.lineCount() - 1 }
        else
            .{ .lo = self.cy, .hi = self.cy };

        const lo = self.resolveAddr(r.lo) orelse return null;
        // `;` moves the cursor to the first address before the second is
        // read, so `:.;+2` counts its offset from there and not from where
        // the cursor started. `,` leaves the cursor alone.
        const saved = self.cy;
        if (r.semicolon) self.cy = lo;
        defer if (r.semicolon) {
            self.cy = saved;
        };
        const hi = self.resolveAddr(r.hi) orelse return null;
        // vim asks before running a backwards range; zedit just swaps.
        return if (lo <= hi) .{ .lo = lo, .hi = hi } else .{ .lo = hi, .hi = lo };
    }

    /// The commands that take a leading range. Returns true when `rest` was
    /// one of them, so `execEx` knows whether to fall through to the rest of
    /// its table.
    fn execRanged(self: *Editor, range: exrange.Range, rest: []const u8) !bool {
        // `:g` / `:v` — the delimiter is whatever follows the name, so these
        // are matched by prefix rather than by tokenising on spaces.
        if (globalSpec(rest, "g", "global")) |spec| {
            try self.exGlobal(range, spec, false);
            return true;
        }
        if (globalSpec(rest, "v", "vglobal")) |spec| {
            try self.exGlobal(range, spec, true);
            return true;
        }
        // `:[range]s/pat/rep/[flags]`, now sharing the one address parser.
        if (rest.len > 0 and rest[0] == 's') {
            if (parseSubstitute(rest)) |sub| {
                self.doSubstitute(range, sub);
                return true;
            }
        }

        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        const name = it.next() orelse return false;
        const arg = std.mem.trim(u8, rest[name.len..], " ");

        // `:normal` takes its keys verbatim — no trimming, no tokenising,
        // since a leading space is a legal key.
        if (eql(name, "normal") or eql(name, "norm") or
            eql(name, "normal!") or eql(name, "norm!"))
        {
            const after = rest[name.len..];
            const keys = if (after.len > 0 and after[0] == ' ') after[1..] else after;
            try self.exNormal(range, keys);
            return true;
        }

        const lr = self.resolveRange(range, false) orelse {
            self.setStatus("invalid range", .{});
            return true;
        };
        const span: Span = .{ .lines = true, .top = lr.lo, .bot = lr.hi };

        if (rest.len > 0 and rest[0] == '!') {
            self.filterRange(range, std.mem.trim(u8, rest[1..], " "));
            return true;
        }
        if (eql(name, "d") or eql(name, "delete")) {
            self.applyOperator(.delete, span);
        } else if (eql(name, "y") or eql(name, "yank")) {
            self.applyOperator(.yank, span);
        } else if (eql(name, ">")) {
            self.applyOperator(.indent_right, span);
        } else if (eql(name, "<")) {
            self.applyOperator(.indent_left, span);
        } else if (eql(name, "j") or eql(name, "join")) {
            if (self.rejectReadOnly()) return true;
            self.cy = lr.lo;
            self.cx = 0;
            // A single-line range still joins it to the next, as `:j` does.
            try self.joinLines(lr.hi - lr.lo + 1, true);
        } else {
            // Not a ranged command. A range in front of one that takes none
            // is vim's E481; say so rather than silently dropping it.
            if (range.count > 0 and !eql(name, "s")) {
                self.setStatus("no range allowed for :{s}", .{name});
                return true;
            }
            return false;
        }
        _ = arg;
        return true;
    }

    /// `:g/pat/cmd` written any of the ways vim accepts it. Returns the text
    /// after the command name (starting with the delimiter), or null when
    /// `rest` is some other command that merely starts with the same letter.
    fn globalSpec(rest: []const u8, short: []const u8, long: []const u8) ?[]const u8 {
        for ([_][]const u8{ long, short }) |name| {
            if (!std.mem.startsWith(u8, rest, name)) continue;
            const after = rest[name.len..];
            // A delimiter must follow, and it cannot be a letter or a space —
            // otherwise `:global` would swallow `:go` and `:v` every `:vs`.
            if (after.len == 0) continue;
            const d = after[0];
            if (std.ascii.isAlphanumeric(d) or d == ' ' or d == '!') continue;
            return after;
        }
        return null;
    }

    /// `:[range]!cmd` — hand the range to a command's stdin and put what it
    /// writes back in their place. Visual `!` prefills the range and lands
    /// here; the classic use is `:'<,'>!sort`.
    ///
    /// The command line is the user's own, so this is the one place zedit
    /// runs a *shell*: `sh -c` is what makes pipes and redirection work, and
    /// is exactly what vim does. Nothing from a file or a language server
    /// ever reaches it.
    fn filterRange(self: *Editor, range: exrange.Range, cmd: []const u8) void {
        if (cmd.len == 0) return self.setStatus("usage: :[range]!command", .{});
        if (self.rejectReadOnly()) return;
        const lr = self.resolveRange(range, false) orelse
            return self.setStatus("invalid range", .{});

        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(self.gpa);
        var row = lr.lo;
        while (row <= @min(lr.hi, self.buf.lineCount() - 1)) : (row += 1) {
            input.appendSlice(self.gpa, self.buf.line(row)) catch return;
            input.append(self.gpa, '\n') catch return;
        }

        const cmd_z = self.gpa.dupe(u8, cmd) catch return;
        defer self.gpa.free(cmd_z);
        var child = std.process.spawn(self.io, .{
            .argv = &.{ "sh", "-c", cmd_z },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return self.setStatus("cannot run: {s}", .{cmd});

        child.stdin.?.writeStreamingAll(self.io, input.items) catch {};
        child.stdin.?.close(self.io);
        child.stdin = null;
        // Read what it wrote before waiting: a command that outputs more than
        // a pipe buffer would block on the write while we blocked on the wait.
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        var rbuf: [16 << 10]u8 = undefined;
        while (true) {
            const n = child.stdout.?.readStreaming(self.io, &.{&rbuf}) catch break;
            if (n == 0) break;
            out.appendSlice(self.gpa, rbuf[0..n]) catch break;
        }
        _ = child.wait(self.io) catch {};

        self.pushUndo();
        var r = @min(lr.hi, self.buf.lineCount() - 1);
        while (r > lr.lo) : (r -= 1) self.buf.removeLineAt(r);
        var at = lr.lo;
        var first = true;
        var it = std.mem.splitScalar(u8, trimTrailingNewline(out.items), '\n');
        while (it.next()) |ln| {
            if (first) {
                self.buf.setLine(at, ln) catch return;
                first = false;
            } else {
                at += 1;
                self.buf.insertLineAt(at, ln) catch return;
            }
        }
        if (first) self.buf.setLine(lr.lo, "") catch {}; // the command ate it all
        self.buf.dirty = true;
        self.cy = @min(lr.lo, self.buf.lineCount() - 1);
        self.cx = motion.firstNonBlank(self.curLine());
        self.updateGoal();
    }

    /// `:[range]g/pat/cmd` and its inverse. Vim's two passes: find every
    /// matching line first, then run the command on each — so a command that
    /// inserts or deletes lines cannot disturb the search that is still
    /// going. The line numbers are kept up to date through the buffer's own
    /// edit log, the same record folds move by; it is read but never cleared
    /// here, so the fold drain at the end of the key still sees everything.
    fn exGlobal(self: *Editor, range: exrange.Range, spec: []const u8, invert: bool) !void {
        if (self.rejectReadOnly()) return;
        const delim = spec[0];
        var i: usize = 1;
        const pat_start = i;
        while (i < spec.len and spec[i] != delim) : (i += 1) {
            if (spec[i] == '\\' and i + 1 < spec.len) i += 1;
        }
        const pat = spec[pat_start..i];
        if (pat.len == 0) return self.setStatus("usage: :g/pattern/command", .{});
        const sub_raw = if (i < spec.len) std.mem.trim(u8, spec[i + 1 ..], " ") else "";

        const lr = self.resolveRange(range, true) orelse
            return self.setStatus("invalid range", .{});

        var re = regex.Regex.compile(self.gpa, pat, false) catch
            return self.setStatus("invalid pattern: {s}", .{pat});
        defer re.deinit(self.gpa);

        var rows: std.ArrayList(usize) = .empty;
        defer rows.deinit(self.gpa);
        var row = lr.lo;
        while (row <= @min(lr.hi, self.buf.lineCount() - 1)) : (row += 1) {
            const hit = re.find(self.buf.line(row), 0) != null;
            if (hit != invert) try rows.append(self.gpa, row);
        }
        if (rows.items.len == 0) return self.setStatus("no lines match {s}", .{pat});

        // No command: report, since zedit has no `:p` to print them with.
        if (sub_raw.len == 0)
            return self.setStatus("{d} line{s} match", .{ rows.items.len, if (rows.items.len == 1) "" else "s" });

        // The sub-command is a slice of the command line, which running it
        // may overwrite (`:g/x/normal :w<CR>` re-enters the command line).
        const sub = try self.gpa.dupe(u8, sub_raw);
        defer self.gpa.free(sub);

        var n: usize = 0;
        while (n < rows.items.len) : (n += 1) {
            if (rows.items[n] >= self.buf.lineCount()) continue; // gone already
            self.cy = rows.items[n];
            self.cx = 0;
            const before = self.buf.lineCount();
            try self.execLine(sub);
            // Whatever the command did to the line count moves every target
            // still to come. Counting lines rather than reading the buffer's
            // edit log is deliberate: `settleFolds` drains that log after
            // *every* key, and `:normal` feeds keys, so it is empty by the
            // time we would look. The assumption is that the command changed
            // lines at or after the one it ran on, which is what vim's real
            // marks would track exactly.
            const delta = @as(i64, @intCast(self.buf.lineCount())) - @as(i64, @intCast(before));
            if (delta != 0) for (rows.items[n + 1 ..]) |*t| {
                t.* = @intCast(@max(0, @as(i64, @intCast(t.*)) + delta));
            };
            if (self.failed or self.quit) break;
        }
        self.clampCursor();
    }

    /// `:[range]normal[!] {keys}` — the keys run as if typed. With no range
    /// they run once where the cursor is; with one, once per line, from
    /// column 0. `replayBytes` already guards its own recursion and stops at
    /// the first command that fails, which is what vim does here too.
    fn exNormal(self: *Editor, range: exrange.Range, keys: []const u8) !void {
        if (keys.len == 0) return self.setStatus("usage: :normal {{keys}}", .{});
        const owned = try self.gpa.dupe(u8, keys);
        defer self.gpa.free(owned);

        if (range.count == 0) {
            try self.runNormalKeys(owned);
            return;
        }
        const lr = self.resolveRange(range, false) orelse
            return self.setStatus("invalid range", .{});

        // One line at a time, tracking what the keys do to the numbering —
        // `:%normal dd` must not skip every other line. The count is taken
        // before and after rather than read from the buffer's edit log,
        // which `settleFolds` has already drained: it runs after every key,
        // and feeding keys is exactly what this does.
        var row = lr.lo;
        var remaining = lr.hi - lr.lo + 1;
        while (remaining > 0) : (remaining -= 1) {
            if (row >= self.buf.lineCount()) break;
            self.cy = row;
            self.cx = 0;
            const before = self.buf.lineCount();
            try self.runNormalKeys(owned);
            if (self.failed or self.quit) break;
            const delta = @as(i64, @intCast(self.buf.lineCount())) - @as(i64, @intCast(before));
            const next = @as(i64, @intCast(row)) + 1 + delta;
            if (next < 0) break;
            row = @intCast(next);
        }
        self.clampCursor();
    }

    /// Feed one batch of keys and make sure normal mode is where they end —
    /// vim appends the implicit `<Esc>` that `:normal ifoo` relies on.
    fn runNormalKeys(self: *Editor, keys: []const u8) !void {
        try self.replayBytes(keys);
        if (self.mode != .normal) try self.replayBytes("\x1b");
    }

    const Substitute = struct {
        pat: []const u8,
        rep: []const u8,
        global: bool, // g flag: every occurrence on the line
        icase: bool, // i flag
    };

    /// Recognise `s/pat/rep/[flags]` — the range has already been taken off
    /// by `exrange.parse`, so this only has to read the command itself. The
    /// separator is `/`, escapable as `\/`. Null when `raw` is not a
    /// substitution at all.
    fn parseSubstitute(raw: []const u8) ?Substitute {
        var i: usize = 0;
        if (i >= raw.len or raw[i] != 's') return null;
        i += 1;
        if (i >= raw.len or raw[i] != '/') return null;
        i += 1;
        // Split pattern / replacement on unescaped '/'.
        const pat_start = i;
        while (i < raw.len and raw[i] != '/') : (i += 1) {
            if (raw[i] == '\\' and i + 1 < raw.len) i += 1; // skip escaped char
        }
        if (i >= raw.len) return null; // no closing separator after the pattern
        const pat = raw[pat_start..i];
        i += 1;
        const rep_start = i;
        while (i < raw.len and raw[i] != '/') : (i += 1) {
            if (raw[i] == '\\' and i + 1 < raw.len) i += 1;
        }
        const rep = raw[rep_start..i];
        var global = false;
        var icase = false;
        if (i < raw.len) { // consume '/', then flags
            i += 1;
            for (raw[i..]) |f| switch (f) {
                'g' => global = true,
                'i' => icase = true,
                else => return null,
            };
        }
        if (pat.len == 0) return null;
        return .{ .pat = pat, .rep = rep, .global = global, .icase = icase };
    }

    /// Apply a parsed `:s` as a single undoable change. The replacement
    /// understands `&` (whole match), `\1`-`\9` (groups), `\\`, `\&` and `\/`.
    fn doSubstitute(self: *Editor, range: exrange.Range, sub: Substitute) void {
        if (self.rejectReadOnly()) return;
        var re = regex.Regex.compile(self.gpa, sub.pat, sub.icase) catch {
            self.setStatus("invalid pattern: {s}", .{sub.pat});
            return;
        };
        defer re.deinit(self.gpa);

        const lr = self.resolveRange(range, false) orelse
            return self.setStatus("invalid range", .{});
        self.last_sub = sub; // `g&` runs this again over the whole file
        const lo = lr.lo;
        const hi = lr.hi;

        self.pushUndo();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        var n_subs: usize = 0;
        var changed_lines: usize = 0;
        var last_changed = self.cy;

        var row = lo;
        while (row <= hi) : (row += 1) {
            const line = self.buf.line(row);
            out.clearRetainingCapacity();
            var at: usize = 0;
            var n_here: usize = 0;
            while (at <= line.len) {
                const m = re.find(line, at) orelse break;
                out.appendSlice(self.gpa, line[at..m.span.start]) catch break;
                expandReplacement(&out, self.gpa, sub.rep, line, m) catch break;
                n_here += 1;
                if (m.span.end > m.span.start) {
                    at = m.span.end;
                } else {
                    // Zero-width match: keep the next byte and move past it.
                    if (m.span.start < line.len) out.append(self.gpa, line[m.span.start]) catch break;
                    at = m.span.start + 1;
                }
                if (!sub.global) break;
            }
            if (n_here == 0) continue;
            out.appendSlice(self.gpa, line[at..]) catch continue;
            self.buf.setLine(row, out.items) catch continue;
            n_subs += n_here;
            changed_lines += 1;
            last_changed = row;
        }

        if (n_subs == 0) {
            self.setStatus("no matches: {s}", .{sub.pat});
            return;
        }
        self.cy = last_changed;
        self.cx = motion.firstNonBlank(self.curLine());
        self.updateGoal();
        self.setStatus("{d} substitution(s) on {d} line(s)", .{ n_subs, changed_lines });
    }

    /// Show the open documents in the status line (`:ls`).
    fn listBuffers(self: *Editor) void {
        var b: [512]u8 = undefined;
        var n: usize = 0;
        for (self.docs.items, 0..) |doc, i| {
            const mark: []const u8 = if (doc == self.d) "*" else "";
            const name = std.fs.path.basename(docLabel(doc));
            const seg = std.fmt.bufPrint(b[n..], "{d}{s}:{s}  ", .{ i + 1, mark, name }) catch break;
            n += seg.len;
        }
        self.setStatus("{s}", .{b[0..n]});
    }

    /// A plain-English reason for a failed save (raw enum only as last resort).
    fn saveErrorReason(err: anyerror) []const u8 {
        return switch (err) {
            error.AccessDenied, error.PermissionDenied => "permission denied",
            error.NoSpaceLeft => "no space left on device",
            error.IsDir => "that is a directory",
            error.ReadOnlyFileSystem => "read-only file system",
            error.FileTooBig => "file too large",
            error.SshFailed => "ssh transfer failed",
            else => @errorName(err),
        };
    }

    fn write(self: *Editor, arg: []const u8) !bool {
        if (self.d.mb != null) {
            // `:w` here means "put the excerpts back"; `:w <name>` would mean
            // saving the stitched view itself, which belongs to no file.
            if (arg.len > 0) {
                self.setStatus("multibuffer: :w writes the files it came from", .{});
                return false;
            }
            return self.mbWrite();
        }
        // Includes `:w <name>`: a read-only diff view is never written out.
        if (self.rejectReadOnly()) return false;
        self.formatBeforeSave();
        const was_unnamed = self.buf.path == null;
        if (arg.len > 0) try self.buf.setPath(arg);
        self.buf.save(self.io) catch |err| switch (err) {
            error.NoFileName => {
                self.setStatus("no file name — use :w <name>", .{});
                return false;
            },
            else => {
                self.setStatus("write failed: {s}", .{saveErrorReason(err)});
                std.log.scoped(.editor).err("write failed: {s}: {s}", .{ self.buf.path orelse "<unnamed>", @errorName(err) });
                return false;
            },
        };
        // `:w name.py` naming a previously-unnamed buffer decides its language:
        // detect it and bring up highlighting and LSP, as opening the file would
        // (the filetype used to stay "text" until the file was reopened).
        if (was_unnamed and self.buf.path != null) {
            self.lang = syntax.detect(self.buf.path);
            if (self.ts == null) self.startTs();
            if (self.lsp == null) self.startLsp();
        }
        self.setStatus("\"{s}\" written", .{self.buf.path orelse ""});
        self.history.markSaved(self.buf, self.cy, self.cx); // for `:earlier 1f`
        self.persistHistory();
        self.refreshGit();
        return true;
    }

    /// `:wa` — write every dirty, file-backed document (cross-file edits leave
    /// background buffers dirty until saved). Failures are named, never silent.
    fn writeAll(self: *Editor) void {
        self.formatBeforeSave(); // format-on-save covers the active document
        var n: usize = 0;
        var failed: usize = 0;
        var why: []const u8 = "";
        var who: []const u8 = "";
        for (self.docs.items) |doc| {
            if (!doc.buf.dirty) continue;
            doc.buf.save(self.io) catch |err| {
                failed += 1;
                if (failed == 1) {
                    why = saveErrorReason(err);
                    who = doc.buf.path orelse docLabel(doc);
                }
                std.log.scoped(.editor).err("write failed: {s}: {s}", .{ doc.buf.path orelse "<unnamed>", @errorName(err) });
                continue;
            };
            // Record the written state, so undoing back to it reads as clean
            // (`:qa` after undo+redo must not refuse). The active doc's
            // History lives in the Editor mirror (`swapDocState`); background
            // docs record at 0,0, as `applyDocEdits` does.
            if (doc == self.d) {
                self.history.markSaved(&doc.buf, self.cy, self.cx);
            } else {
                doc.history.markSaved(&doc.buf, 0, 0);
            }
            n += 1;
        }
        self.refreshGit();
        if (failed > 0) {
            self.setStatus("{d} written, {d} failed — {s}: {s}", .{ n, failed, who, why });
        } else {
            self.setStatus("{d} buffer(s) written", .{n});
        }
    }

    fn doQuit(self: *Editor) void {
        if (self.wins.items.len > 1) { // close the window; the document stays open
            self.closeWindow();
            return;
        }
        if (self.buf.dirty) {
            self.setStatus("unsaved changes — :w to save or :q! to discard", .{});
            return;
        }
        self.quit = true;
    }

    fn docIndex(self: *Editor, doc: *Doc) usize {
        for (self.docs.items, 0..) |it, i| if (it == doc) return i;
        return 0;
    }

    /// Close the active document (`:bd`). Windows showing it fall back to
    /// another open document; the last buffer is replaced by an empty
    /// [No Name] one and the window stays (vim's rule, nvim-verified). A
    /// dirty buffer refuses without force (nvim's E89; `:bd!` discards).
    fn closeDoc(self: *Editor, force: bool) void {
        const victim = self.d;
        if (victim.buf.dirty and !force)
            return self.setStatus("no write since last change — :bd! to override", .{});
        const repl: *Doc = if (self.docs.items.len == 1)
            (self.makeEmptyDoc() orelse return self.setStatus("out of memory", .{}))
        else blk: {
            for (self.docs.items) |doc| if (doc != victim) break :blk doc;
            unreachable;
        };
        self.loadDoc(repl); // swaps victim's live state back into its Doc
        for (self.wins.items) |w| {
            if (w.doc == victim) w.doc = repl;
        }
        self.destroyDoc(victim);
        self.clearExtra();
        self.placeAt(self.cy);
        self.setStatus("{s}", .{docLabel(self.d)});
    }

    /// A fresh, unnamed, empty document, appended to the open list. Null on
    /// allocation failure (the caller reports it). Shared by `:bd` on the last
    /// buffer and `Space n`.
    fn makeEmptyDoc(self: *Editor) ?*Doc {
        const b = buffer.Buffer.initEmpty(self.gpa) catch return null;
        const doc = makeDoc(self.gpa, b) catch {
            var bb = b;
            bb.deinit();
            return null;
        };
        self.docs.append(self.gpa, doc) catch { // same teardown as openFile's
            self.freeDoc(doc);
            return null;
        };
        return doc;
    }

    /// `Space n` — AstroNvim's <leader>n: an empty unnamed buffer in the
    /// active window. The buffer it replaces stays open (this is not a close),
    /// and `:w <name>` names it, detecting its filetype on the spot.
    fn newBuffer(self: *Editor) void {
        const doc = self.makeEmptyDoc() orelse return self.setStatus("out of memory", .{});
        self.loadDoc(doc);
        self.cur.doc = doc;
        self.clearExtra();
        self.placeAt(0);
        self.setStatus("{s}", .{docLabel(doc)});
    }

    /// Remove `victim` from the open documents and free it. Every window (and
    /// the focus) must already point elsewhere.
    fn destroyDoc(self: *Editor, victim: *Doc) void {
        _ = self.docs.orderedRemove(self.docIndex(victim));
        for (self.docs.items) |doc| {
            if (doc.diff_of != victim) continue;
            // The orphaned snapshot is an ordinary scratch now: drop the
            // pair's alignment and its old-side tint rows (which live in the
            // mirror while the snapshot is the active doc).
            doc.diff_of = null;
            self.gpa.free(doc.diff_hunks);
            doc.diff_hunks = &.{};
            if (doc == self.d) self.git_signs.clearRetainingCapacity() else doc.git_signs.clearRetainingCapacity();
        }
        var ji: usize = 0;
        while (ji < self.jumps.items.len) {
            if (self.jumps.items[ji].doc == victim) {
                _ = self.jumps.orderedRemove(ji);
                if (self.jump_idx > ji) self.jump_idx -= 1;
            } else ji += 1;
        }
        if (self.jump_idx > self.jumps.items.len) self.jump_idx = self.jumps.items.len;
        self.freeDoc(victim);
    }

    // === undo / macros / dot ===============================================

    fn pushUndo(self: *Editor) void {
        self.noteChange();
        self.history.record(self.buf, self.cy, self.cx);
        self.change_started = true;
        // Every insert session starts with one of these, so a block `A`'s
        // pending cursor-origin can never outlive its own session (the block
        // path sets it again straight after its push).
        self.vb_origin = null;
    }

    /// The diff views' documents are read-only: the index snapshot mirrors
    /// repository state (edits would desync the pair's alignment), and the
    /// unified-diff scratch is a static report — editing either could only
    /// produce a dirty scratch blocking `:q`. Every buffer-mutating command
    /// calls this first; true means the command was refused and reported.
    fn rejectReadOnly(self: *Editor) bool {
        if (self.d.diff_of != null) {
            self.setStatus("index snapshot is read-only", .{});
        } else if (self.d.shell != null) {
            self.setStatus("this is a terminal — i types into it", .{});
        } else if (self.d.read_only) {
            self.setStatus("diff view is read-only", .{});
        } else return false;
        self.resetPending();
        return true;
    }

    /// Recompute the git change signs for the current file (best-effort).
    fn refreshGit(self: *Editor) void {
        if (self.isLargeFile()) return;
        if (self.buf.path) |p| {
            // The line-diff weave follows the same save-refresh contract, and
            // its parse keeps the hunk headers, so one `git diff` run feeds
            // the weave and the gutter signs both. A file with no remaining
            // changes closes the view (nothing left to weave) and has no
            // signs either way.
            if (self.d.line_diff != null) {
                self.clearLineDiff(self.d);
                self.d.line_diff = git.computeLineDiff(self.gpa, self.io, p);
                if (self.d.line_diff) |ld| {
                    git.signsFromHunks(ld.hunks, true, &self.git_signs);
                } else {
                    self.git_signs.clearRetainingCapacity();
                }
            } else {
                git.compute(self.gpa, self.io, p, &self.git_signs);
            }
            // A saved worktree file re-aligns its open side-by-side view: the
            // snapshot's hunks and tint rows follow the same diff the gutter
            // signs just did.
            for (self.docs.items) |doc| {
                if (doc.diff_of != self.d) continue;
                self.gpa.free(doc.diff_hunks);
                doc.diff_hunks = git.computeHunks(self.gpa, self.io, p);
                git.signsFromHunks(doc.diff_hunks, false, &doc.git_signs);
            }
        } else if (self.d.diff_of == null) {
            self.git_signs.clearRetainingCapacity();
        }
    }

    // === tree-sitter highlighting ==========================================

    /// Whether the active document is in large-file mode (config
    /// `large_file_mb`): highlighting, LSP and git signs are skipped so huge
    /// files open instantly and nothing downstream chokes on them.
    fn isLargeFile(self: *Editor) bool {
        return docIsLarge(self.d);
    }

    fn docIsLarge(doc: *const Doc) bool {
        const src = doc.buf.source orelse return false;
        return src.len > config.settings.large_file_mb << 20;
    }

    fn startTs(self: *Editor) void {
        if (self.isLargeFile()) return;
        self.ts = treesitter.Highlighter.init(self.gpa, self.lang);
        if (self.ts != null) self.tsReparse();
    }

    /// Keep highlighting current: reparse on a content change, then (re)run the
    /// query if the content or the visible viewport changed. Both are O(visible)
    /// in the common case. Call after `scroll`, so `self.top` is current.
    fn tsUpdate(self: *Editor) void {
        if (self.ts == null) return;
        if (self.ts_rev != self.buf.revision) self.tsReparse();
        const rows = self.textRows();
        if (self.top != self.ts_q_top or rows != self.ts_q_rows) self.tsQuery(self.top, rows);
    }

    /// Incrementally reparse and rebuild the per-line byte offsets. Marks the
    /// query stale so the next `tsUpdate` re-queries the visible range.
    fn tsReparse(self: *Editor) void {
        var h = if (self.ts) |*x| x else return;
        const content = self.buf.toBytes(self.gpa) catch return;
        defer self.gpa.free(content);
        h.reparse(content);
        self.ts_doc_len = content.len;

        self.ts_line_starts.clearRetainingCapacity();
        var off: usize = 0;
        var row: usize = 0;
        const rows = self.buf.lineCount();
        self.ts_line_starts.ensureTotalCapacity(self.gpa, rows) catch {};
        while (row < rows) : (row += 1) {
            self.ts_line_starts.append(self.gpa, off) catch {};
            off += self.buf.line(row).len + 1; // + newline
        }
        self.ts_rev = self.buf.revision;
        self.ts_q_top = std.math.maxInt(usize); // force a requery
    }

    /// Run the highlight query over just the visible lines' byte range.
    fn tsQuery(self: *Editor, top: usize, rows: usize) void {
        var h = if (self.ts) |*x| x else return;
        const lc = self.buf.lineCount();
        if (top >= self.ts_line_starts.items.len) return;
        const last = @min(top + rows, lc); // exclusive
        const start_byte = self.ts_line_starts.items[top];
        const end_byte = if (last < self.ts_line_starts.items.len) self.ts_line_starts.items[last] else self.ts_doc_len;
        self.ts_styles.resize(self.gpa, end_byte - start_byte) catch return;
        h.queryRange(start_byte, end_byte, self.ts_styles.items);
        self.ts_vis_start = start_byte;
        self.ts_q_top = top;
        self.ts_q_rows = rows;
    }

    // === language server ===================================================

    /// Spawn a language server for the current file (best-effort; no server or
    /// no command simply leaves LSP disabled).
    fn startLsp(self: *Editor) void {
        if (self.isLargeFile()) {
            self.setStatus("large file: highlighting, LSP and git signs disabled", .{});
            return;
        }
        const path = self.buf.path orelse return;

        var argv_store: [8][]const u8 = undefined;
        var argc: usize = 0;
        if (self.lsp_cmd) |cmd| {
            var it = std.mem.tokenizeScalar(u8, cmd, ' ');
            while (it.next()) |tok| {
                if (argc < argv_store.len) {
                    argv_store[argc] = tok;
                    argc += 1;
                }
            }
        } else if (syntax.server(self.lang)) |def| {
            for (def) |a| {
                argv_store[argc] = a;
                argc += 1;
            }
        }
        if (argc == 0) return;

        const cwd = std.process.currentPathAlloc(self.io, self.gpa) catch return;
        defer self.gpa.free(cwd);

        // Build the file:// URI and an absolute path.
        var uri_buf: std.ArrayList(u8) = .empty;
        defer uri_buf.deinit(self.gpa);
        uri_buf.appendSlice(self.gpa, "file://") catch return;
        if (path.len > 0 and path[0] == '/') {
            uri_buf.appendSlice(self.gpa, path) catch return;
        } else {
            uri_buf.appendSlice(self.gpa, cwd) catch return;
            uri_buf.append(self.gpa, '/') catch return;
            uri_buf.appendSlice(self.gpa, path) catch return;
        }

        const content = self.buf.toBytes(self.gpa) catch return;
        defer self.gpa.free(content);

        self.lsp = lsp.Client.start(self.gpa, self.io, argv_store[0..argc], cwd, uri_buf.items, syntax.lspId(self.lang), content);
        if (self.lsp) |*c| {
            self.lsp_rev = self.buf.revision;
            _ = c;
            // No request may go out yet: the handshake is asynchronous now, so
            // `initialize` has not been answered and a real server rejects
            // anything sent before `initialized`. The first inlay-hint request
            // is made by `consumeLspResults` the moment the server is ready.
            self.setStatus("language server started", .{});
        } else if (self.lsp_cmd == null) {
            // This filetype has a known server and it is not installed: say so,
            // so "nothing completes" is explained rather than silent. Once per
            // document, since this runs once per document (the decorate pass
            // after its first paint) and never on the typing path. A filetype
            // with no known server stays quiet.
            self.setStatus("no language server for {s} (install {s}){s}", .{
                syntax.lspId(self.lang),
                argv_store[0],
                if (config.settings.buffer_completion) "; completing from open buffers" else "",
            });
        }
    }

    /// Tell the server about edits, but only when the content actually changed
    /// (the client picks incremental vs. full based on the server's capability).
    fn syncLsp(self: *Editor) void {
        var client = if (self.lsp) |*c| c else return;
        if (!client.ready() or self.buf.revision == self.lsp_rev) return;
        const content = self.buf.toBytes(self.gpa) catch return;
        defer self.gpa.free(content);
        client.didChange(content);
        client.requestInlayHints(self.buf.lineCount()); // refresh hints for the new text
        self.lsp_rev = self.buf.revision;
    }

    /// Act on responses pushed by the server: hover, goto-definition, and a
    /// completion list (which opens the popup).
    fn consumeLspResults(self: *Editor) !void {
        var client = if (self.lsp) |*c| c else return;
        // The handshake just landed: ask for the things that could not be
        // asked at spawn time. Once only — `syncLsp` refreshes hints per edit.
        if (client.ready() and !self.lsp_opened) {
            self.lsp_opened = true;
            client.requestInlayHints(self.buf.lineCount());
        }
        if (client.takeHover()) |text| {
            defer self.gpa.free(text);
            const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
            self.setStatus("{s}", .{text[0..line_end]});
        }
        if (client.takeDefinition()) |loc| {
            defer self.gpa.free(loc.uri);
            self.addJump();
            self.cy = @min(loc.line, self.buf.lineCount() - 1);
            self.cx = @min(loc.col, self.curLine().len);
            self.updateGoal();
        }
        if (client.comp_ready) {
            client.comp_ready = false;
            // The response replaced the server's list wholesale, so an open
            // popup is now indexing items that are gone. Drop it first: the
            // branches below reopen it from whichever list they fill, and the
            // fallback is allowed to decline (`buffer_completion = false`, or
            // no prefix under the cursor) without leaving the popup pointed
            // past the end of an empty list.
            self.comp_open = false;
            self.comp_filtered.clearRetainingCapacity();
            if (self.mode == .insert) {
                if (client.completions.items.len > 0) {
                    self.comp_words_src = false; // the server's list wins
                    self.comp_open = true;
                    self.comp_sel = 0;
                    self.filterCompletions();
                } else {
                    self.bufferComplete(); // nothing from the server: use the buffers
                }
            }
        }
        if (client.sig_ready) {
            client.sig_ready = false;
            // Show it while inserting; an empty result just closes the popup.
            self.sig_open = self.mode == .insert and client.signatures.items.len > 0;
        }
        if (client.rename_ready) {
            client.rename_ready = false;
            try self.applyRename(client);
        }
        if (client.ca_ready) {
            client.ca_ready = false;
            if (self.mode == .normal) {
                if (client.code_actions.items.len > 0) self.openCodeActionPicker() else self.setStatus("no code actions", .{});
            }
        }
        if (client.sym_ready) {
            client.sym_ready = false;
            if (self.mode == .normal) {
                if (client.symbols.items.len > 0) self.openSymbolPicker() else self.setStatus("no symbols", .{});
            }
        }
        if (client.apply_ready) {
            client.apply_ready = false;
            _ = try self.applyWorkspaceEdits(client.server_files.items); // workspace/applyEdit
            client.clearServerFiles();
        }
        if (client.wsym_ready) {
            client.wsym_ready = false;
            if (self.mode == .picker and self.picker_kind == .wsymbol) self.fillWorkspaceSymbols();
        }
        if (client.refs_ready) {
            client.refs_ready = false;
            if (self.mode == .normal) {
                if (client.references.items.len > 0) self.openReferencePicker() else self.setStatus("no references", .{});
            }
        }
        if (client.fmt_ready) {
            client.fmt_ready = false;
            if (client.fmt_edits.items.len == 0) {
                self.setStatus("format: no changes", .{});
            } else {
                const n = try self.applyEdits(client.fmt_edits.items);
                self.setStatus("formatted ({d} edit(s))", .{n});
            }
        }
    }

    /// Codepoint column of the cursor (an approximation of the UTF-16 column
    /// LSP wants; exact for ASCII/BMP text).
    fn charCol(self: *Editor) usize {
        const line = self.curLine();
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.cx and i < line.len) {
            i = unicode.nextBoundary(line, i);
            n += 1;
        }
        return n;
    }

    fn lspHover(self: *Editor) void {
        if (self.lsp) |*c| c.requestHover(self.cy, self.charCol());
    }

    /// `gD` — the symbol's *declaration*, which AstroNvim also puts here.
    fn lspDeclaration(self: *Editor) void {
        const client = if (self.lsp) |*c| c else return self.setStatus("no language server", .{});
        client.requestDeclaration(self.cy, self.charCol());
    }

    fn lspDefinition(self: *Editor) void {
        if (self.lsp) |*c| c.requestDefinition(self.cy, self.charCol());
    }

    /// `gi` — jump to the implementation(s) of the symbol under the cursor.
    fn lspImplementation(self: *Editor) void {
        const client = if (self.lsp) |*c| c else return self.setStatus("no language server", .{});
        client.requestImplementation(self.cy, self.charCol());
    }

    /// `gy` — jump to the *type* of the symbol under the cursor.
    fn lspTypeDefinition(self: *Editor) void {
        const client = if (self.lsp) |*c| c else return self.setStatus("no language server", .{});
        client.requestTypeDefinition(self.cy, self.charCol());
    }

    fn lspDocumentSymbol(self: *Editor) void {
        if (self.lsp) |*c| c.requestDocumentSymbol();
    }

    /// Move the cursor to the picked symbol's position.
    fn jumpToSymbol(self: *Editor, idx: usize) void {
        const client = if (self.lsp) |*c| c else return;
        if (idx >= client.symbols.items.len) return;
        const sym = client.symbols.items[idx];
        self.addJump();
        self.cy = @min(sym.line, self.buf.lineCount() - 1);
        self.cx = @min(byteAtCharCol(self.curLine(), sym.col), self.curLine().len);
        self.updateGoal();
    }

    /// Display width of inlay hints on `row` rendered to the left of byte
    /// `upto` — added to the cursor's screen column so it tracks the virtual
    /// text.
    fn inlayCols(self: *Editor, row: usize, upto: usize) usize {
        const client = if (self.lsp) |*c| c else return 0;
        const line = self.buf.line(row);
        var sum: usize = 0;
        for (client.inlay_hints.items) |hint| {
            if (hint.line != row) continue;
            if (byteAtCharCol(line, hint.col) <= upto) sum += unicode.displayWidth(hint.text);
        }
        return sum;
    }

    /// Jump to the next/previous diagnostic line (]d / [d), wrapping. `[count]`
    /// repeats. The landed line's message shows via the statusline (lspMiddle).
    /// `]d`/`[d` walk every diagnostic; `]e`/`[e` and `]w`/`[w` restrict the
    /// walk to errors and warnings (AstroNvim's keys). `sev` is the LSP
    /// severity: 1 error, 2 warning, null any.
    fn gotoDiagnostic(self: *Editor, forward: bool, sev: ?u8) void {
        const client = if (self.lsp) |*c| c else return self.setStatus("no language server", .{});
        var line: ?usize = null;
        var from = self.cy;
        var n = self.eff();
        while (n > 0) : (n -= 1) {
            const next = client.nextDiagLine(from, forward, sev) orelse break;
            line = next;
            from = next;
        }
        const target = line orelse return self.setStatus("no {s}diagnostics", .{switch (sev orelse 0) {
            1 => "error ",
            2 => "warning ",
            else => "",
        }});
        self.cy = @min(target, self.buf.lineCount() - 1);
        self.cx = motion.firstNonBlank(self.curLine());
        self.updateGoal();
    }

    /// The first line of the next/previous changed hunk, wrapping at both
    /// ends. A hunk *starts* where a signed line follows an unsigned one, so
    /// a five-line change is one stop rather than five — the signs are
    /// already there for the gutter and all three diff views, and this is
    /// the motion that was missing over them.
    fn hunkStart(self: *Editor, from: usize, forward: bool) ?usize {
        var near: ?usize = null;
        var wrap: ?usize = null;
        var it = self.git_signs.keyIterator();
        while (it.next()) |k| {
            const line = k.*;
            if (line > 0 and self.git_signs.contains(line - 1)) continue; // mid-hunk
            if (forward) {
                if (line > from and (near == null or line < near.?)) near = line;
                if (wrap == null or line < wrap.?) wrap = line;
            } else {
                if (line < from and (near == null or line > near.?)) near = line;
                if (wrap == null or line > wrap.?) wrap = line;
            }
        }
        return near orelse wrap;
    }

    /// `]D` / `[D`: the first or last diagnostic in the buffer, rather than
    /// the next one — nvim 0.12 binds both pairs.
    fn gotoDiagnosticEnd(self: *Editor, last: bool) void {
        const client = if (self.lsp) |*c| c else return self.setStatus("no language server", .{});
        var best: ?usize = null;
        for (client.diags.items) |d| {
            if (best == null or (if (last) d.line > best.? else d.line < best.?)) best = d.line;
        }
        const target = best orelse return self.setStatus("no diagnostics", .{});
        self.cy = @min(target, self.buf.lineCount() - 1);
        self.cx = motion.firstNonBlank(self.curLine());
        self.updateGoal();
    }

    /// `]Q` / `[Q`: the last or first quickfix entry, rather than the next.
    fn qfEnd(self: *Editor, last: bool) void {
        if (self.qf.len() == 0) return self.setStatus("quickfix list is empty", .{});
        self.qf.idx = if (last) self.qf.len() - 1 else 0;
        self.qfJump(self.qf.entries.items[self.qf.idx]);
    }

    /// `]B` / `[B`: the last or first buffer.
    fn docEnd(self: *Editor, last: bool) void {
        if (self.docs.items.len == 0) return;
        self.focusDoc(self.docs.items[if (last) self.docs.items.len - 1 else 0]);
    }

    /// `]g` / `[g` — jump to the next/previous hunk. Counted, and no jumplist
    /// entry, exactly as its sibling `]d` behaves.
    fn gotoHunk(self: *Editor, forward: bool) void {
        var line: ?usize = null;
        var from = self.cy;
        var n = self.eff();
        while (n > 0) : (n -= 1) {
            const next = self.hunkStart(from, forward) orelse break;
            line = next;
            from = next;
        }
        const target = line orelse return self.setStatus("no changes", .{});
        self.cy = @min(target, self.buf.lineCount() - 1);
        self.cx = motion.firstNonBlank(self.curLine());
        self.updateGoal();
    }

    /// Show the current line's diagnostic in the statusline (`Space l d`).
    fn lineDiagnostic(self: *Editor) void {
        const client = if (self.lsp) |*c| c else return self.setStatus("no language server", .{});
        if (client.messageAt(self.cy)) |msg| {
            const end = std.mem.indexOfScalar(u8, msg, '\n') orelse msg.len;
            self.setStatus("{s}", .{msg[0..end]});
        } else {
            self.setStatus("no diagnostic on this line", .{});
        }
    }

    /// Send the rename request with the name typed on the command line.
    fn lspRename(self: *Editor) void {
        const name = std.mem.trim(u8, self.cmd.items, " ");
        if (name.len == 0) return self.setStatus("rename: empty name", .{});
        if (self.lsp) |*c| c.requestRename(self.cy, self.charCol(), name);
    }

    fn lspCodeAction(self: *Editor) void {
        const client = if (self.lsp) |*c| c else return;
        const line = self.buf.line(self.cy);
        var cols: usize = 0;
        var i: usize = 0;
        while (i < line.len) : (cols += 1) i = unicode.nextBoundary(line, i);
        client.requestCodeAction(self.cy, 0, self.cy, cols); // the whole current line
    }

    /// Apply the picked code action: its WorkspaceEdit (across files), then run
    /// its command (if any) via executeCommand — the server's resulting
    /// workspace/applyEdit is handled asynchronously.
    fn applyCodeAction(self: *Editor, idx: usize) !void {
        const client = if (self.lsp) |*c| c else return;
        if (idx >= client.code_actions.items.len) return;
        const action = client.code_actions.items[idx];
        if (action.files.items.len > 0) _ = try self.applyWorkspaceEdits(action.files.items);
        if (action.command) |cmd| client.executeCommand(cmd, action.arguments);
        if (action.files.items.len == 0 and action.command == null) {
            self.setStatus("'{s}': nothing to apply", .{action.title});
        } else {
            self.setStatus("applied: {s}", .{action.title});
        }
    }

    fn lspReferences(self: *Editor) void {
        const client = if (self.lsp) |*c| c else return self.setStatus("no language server", .{});
        client.requestReferences(self.cy, self.charCol());
    }

    /// Request LSP formatting for the whole document (`Space l f` / `:format`);
    /// the edits are applied when the response arrives.
    fn lspFormat(self: *Editor) void {
        const client = if (self.lsp) |*c| c else return self.setStatus("no language server", .{});
        self.syncLsp(); // the server must see the latest text first
        client.requestFormatting(config.settings.tab_width);
    }

    /// Format-on-save: synchronously request + apply formatting before a write.
    /// Bounded (~1s) so a stuck server cannot hang `:w`; skipped for servers
    /// that don't advertise formatting.
    fn formatBeforeSave(self: *Editor) void {
        if (!config.settings.format_on_save) return;
        const client = if (self.lsp) |*c| c else return;
        if (!client.ready() or !client.can_format) return;
        self.syncLsp();
        client.fmt_ready = false;
        client.requestFormatting(config.settings.tab_width);
        var tries: usize = 100;
        while (!client.fmt_ready and client.alive() and tries > 0) : (tries -= 1) client.pump(10);
        if (!client.fmt_ready) return; // timed out; save the text as-is
        client.fmt_ready = false;
        if (client.fmt_edits.items.len > 0) _ = self.applyEdits(client.fmt_edits.items) catch 0;
    }

    /// `Space l S` — symbols across the whole project. The query goes to the
    /// server (it does the matching over files zedit has never opened), so
    /// each keystroke re-asks after the same pause auto-completion uses.
    fn openWorkspaceSymbolPicker(self: *Editor) void {
        if (self.lsp == null) return self.setStatus("no language server", .{});
        self.startPicker(.wsymbol);
        self.mode = .picker;
        self.refilter();
        self.sendWorkspaceSymbolQuery();
        self.setStatus("workspace symbols: type to search", .{});
    }

    fn sendWorkspaceSymbolQuery(self: *Editor) void {
        self.comp_due_ms = null;
        const client = if (self.lsp) |*c| c else return;
        client.requestWorkspaceSymbol(self.picker_query.items);
    }

    /// Rebuild the workspace-symbol rows from the server's answer.
    fn fillWorkspaceSymbols(self: *Editor) void {
        const client = if (self.lsp) |*c| c else return;
        const cwd = std.process.currentPathAlloc(self.io, self.gpa) catch return;
        defer self.gpa.free(cwd);
        self.picker_items.clearRetainingCapacity();
        self.picker_text.clearRetainingCapacity();
        for (client.wsymbols.items) |s| {
            const abs = uriToPath(self.gpa, s.uri) orelse continue;
            defer self.gpa.free(abs);
            const rel = relativeTo(cwd, abs);
            var db: [512]u8 = undefined;
            const disp = std.fmt.bufPrint(&db, "{s} {s}  {s}:{d}", .{
                symbolKindName(s.kind), s.name, rel, s.line + 1,
            }) catch continue;
            self.addPickItem(disp, rel, s.line + 1);
        }
        // The server already matched the query, so show every row it returned.
        self.picker_filtered.clearRetainingCapacity();
        var i: u32 = 0;
        while (i < self.picker_items.items.len) : (i += 1) self.picker_filtered.append(self.gpa, i) catch {};
        self.clampSel();
    }

    /// `Space l D` — every diagnostic the servers have reported for the open
    /// buffers, most severe first, grouped by file.
    fn openDiagnosticPicker(self: *Editor) void {
        self.startPicker(.diagnostic);
        const cwd = std.process.currentPathAlloc(self.io, self.gpa) catch return;
        defer self.gpa.free(cwd);

        var found: usize = 0;
        for (self.docs.items) |doc| {
            // The active document's client lives on the Editor mirror.
            const client = if (doc == self.d) (if (self.lsp) |*c| c else null) else (if (doc.lsp) |*c| c else null);
            const cl = client orelse continue;
            const path = doc.buf.path orelse continue;
            const rel = relativeTo(cwd, path);
            for (cl.diags.items) |d| {
                var db: [512]u8 = undefined;
                const end = std.mem.indexOfScalar(u8, d.message, '\n') orelse d.message.len;
                const disp = std.fmt.bufPrint(&db, "{s} {s}:{d}: {s}", .{
                    severityTag(d.severity), rel, d.line + 1, d.message[0..end],
                }) catch continue;
                self.addPickItem(disp, rel, d.line + 1);
                found += 1;
            }
        }
        if (found == 0) {
            self.freePicker();
            self.mode = .normal;
            return self.setStatus("no diagnostics", .{});
        }
        self.mode = .picker;
        self.refilter();
    }

    /// Populate the picker with a references result — "path:line: text", with
    /// line text for already-open documents — and open it (Enter jumps there).
    fn openReferencePicker(self: *Editor) void {
        const client = if (self.lsp) |*c| c else return;
        const cwd = std.process.currentPathAlloc(self.io, self.gpa) catch return;
        defer self.gpa.free(cwd);
        self.startPicker(.reference);
        for (client.references.items) |ref| {
            const abs = uriToPath(self.gpa, ref.uri) orelse continue;
            defer self.gpa.free(abs);
            const rel = relativeTo(cwd, abs);
            const text = self.openDocLine(cwd, abs, ref.line);
            var db: [512]u8 = undefined;
            const disp = std.fmt.bufPrint(&db, "{s}:{d}: {s}", .{ rel, ref.line + 1, std.mem.trim(u8, text, " \t") }) catch continue;
            self.addPickItem(disp, rel, ref.line + 1);
        }
        self.mode = .picker;
        self.refilter();
    }

    /// Line `row` of the open document backed by `abs` ("" when the file isn't
    /// open — references into unopened files show path:line only).
    fn openDocLine(self: *Editor, cwd: []const u8, abs: []const u8, row: usize) []const u8 {
        for (self.docs.items) |doc| {
            const p = doc.buf.path orelse continue;
            if (!samePath(cwd, p, abs)) continue;
            if (row < doc.buf.lineCount()) return doc.buf.line(row);
            return "";
        }
        return "";
    }

    /// Apply a rename's WorkspaceEdit across every file it touches.
    fn applyRename(self: *Editor, client: *lsp.Client) !void {
        if (client.rename_files.items.len == 0) return self.setStatus("rename: no changes", .{});
        const nfiles = client.rename_files.items.len;
        const n = try self.applyWorkspaceEdits(client.rename_files.items);
        if (nfiles > 1) {
            self.setStatus("renamed {d} in {d} files (:wa saves)", .{ n, nfiles });
        } else {
            self.setStatus("renamed {d} occurrence(s)", .{n});
        }
    }

    /// Apply a WorkspaceEdit's per-file groups: the active document directly,
    /// other open documents in place, and not-yet-open files into background
    /// buffers (left dirty for `:w` / `:wa`). Returns the edits applied.
    fn applyWorkspaceEdits(self: *Editor, files: []lsp.FileEdits) !usize {
        const cwd = std.process.currentPathAlloc(self.io, self.gpa) catch return 0;
        defer self.gpa.free(cwd);
        var applied: usize = 0;
        for (files) |*f| {
            if (f.edits.items.len == 0) continue;
            const abs = uriToPath(self.gpa, f.uri) orelse continue;
            defer self.gpa.free(abs);
            const doc = self.docForPath(cwd, abs) orelse continue;
            applied += try self.applyDocEdits(doc, f.edits.items);
        }
        return applied;
    }

    /// The open document backed by `abs`, or the file freshly loaded into a
    /// background document (listed in `:ls`, not focused).
    fn docForPath(self: *Editor, cwd: []const u8, abs: []const u8) ?*Doc {
        for (self.docs.items) |doc| {
            const p = doc.buf.path orelse continue;
            if (samePath(cwd, p, abs)) return doc;
        }
        const nb = buffer.Buffer.load(self.gpa, self.io, abs) catch return null;
        const doc = makeDoc(self.gpa, nb) catch {
            var b = nb;
            b.deinit();
            return null;
        };
        self.docs.append(self.gpa, doc) catch {
            self.freeDoc(doc);
            return null;
        };
        return doc;
    }

    /// Apply edits to one document as an undoable change. The active document
    /// goes through `applyEdits` (its history/LSP live on the Editor mirror);
    /// background documents record their own history and sync their own server.
    fn applyDocEdits(self: *Editor, doc: *Doc, edits: []lsp.TextEdit) !usize {
        if (doc == self.d) return self.applyEdits(edits);
        doc.history.record(&doc.buf, 0, 0);
        const n = applyEditsToBuf(&doc.buf, edits);
        for (self.wins.items) |w| { // keep inactive viewports in bounds
            if (w.doc != doc) continue;
            w.cy = @min(w.cy, doc.buf.lineCount() - 1);
            w.cx = @min(w.cx, doc.buf.line(w.cy).len);
            w.top = @min(w.top, w.cy);
        }
        if (doc.lsp) |*c| {
            if (c.ready() and doc.buf.revision != doc.lsp_rev) {
                const content = doc.buf.toBytes(self.gpa) catch return n;
                defer self.gpa.free(content);
                c.didChange(content);
                doc.lsp_rev = doc.buf.revision;
            }
        }
        return n;
    }

    /// Apply a set of WorkspaceEdit `TextEdit`s to the current buffer as one
    /// undoable change. Returns the number applied.
    fn applyEdits(self: *Editor, edits: []lsp.TextEdit) !usize {
        self.pushUndo();
        const applied = applyEditsToBuf(self.buf, edits);
        self.clampCursor();
        self.updateGoal();
        self.syncLsp(); // notify the server of the applied edits
        return applied;
    }

    /// The language server, if one is attached *and still running*. A server
    /// that exited or crashed answers nothing, so completion must treat it
    /// exactly like one that was never installed rather than wait forever.
    fn liveLsp(self: *Editor) ?*lsp.Client {
        const c = if (self.lsp) |*cl| cl else return null;
        // `ready`, not `alive`: the handshake no longer blocks, so there is a
        // window where the server is spawned but has not answered
        // `initialize` and would reject anything sent to it.
        return if (c.ready()) c else null;
    }

    /// Ask for completions (the debounce fired, or `Ctrl-n`): the language
    /// server when one is running, else the words already in the open buffers.
    /// A server that answers with an empty list falls back the same way, in
    /// `consumeLspResults`.
    /// The language server is spawned but has not finished its handshake — so
    /// it is neither usable yet nor absent. See `requestCompletion`.
    fn lspStarting(self: *Editor) bool {
        const c = if (self.lsp) |*cl| cl else return false;
        return c.handshaking();
    }

    fn requestCompletion(self: *Editor) void {
        self.comp_due_ms = null;
        // A server still in its handshake is not the same as no server. The
        // handshake stopped blocking in 0.33.0, which opened a window where a
        // request fired here was dropped and nothing ever asked again — type
        // fast enough after opening a file and the completion you asked for
        // simply never came. Wait for it instead. Bounded: a server that dies
        // stops being alive, and the buffer-word fallback takes over.
        if (self.lspStarting()) {
            self.due_kind = .completion;
            self.comp_due_ms = log.nowMs() + 30;
            return;
        }
        const client = self.liveLsp() orelse return self.bufferComplete();
        self.syncLsp(); // the server must see the text this completes against
        client.requestCompletion(self.cy, self.charCol());
    }

    /// Fill the popup from identifiers already in the open buffers — vim's
    /// keyword completion, and the reason completion works at all when no
    /// language server is installed.
    fn bufferComplete(self: *Editor) void {
        if (!config.settings.buffer_completion or self.mode != .insert) return;
        if (self.completionPrefix().len == 0) return;
        var sp = log.Span.start();
        self.harvestWords(self.completionWord());
        self.comp_words_src = true;
        self.comp_sel = 0;
        self.comp_open = self.comp_words.count() > 0;
        if (self.comp_open) self.filterCompletions(); // closes it again if nothing matches
        sp.lap("buffer completion");
    }

    /// How much text a harvest reads, and how many candidates it keeps. These
    /// are what stops a huge file from stalling the keystroke after the popup:
    /// the scan is bounded work near the cursor, not a walk of the document.
    /// The byte budget is the one that always bites — a file with a small
    /// vocabulary never reaches `harvest_cap`, so `harvest_reach` alone left
    /// the scan free to read megabytes (and one minified line can be megabytes
    /// on its own): 82 ms a harvest, measured, against 2.3 ms now. 128 KB is
    /// far past where ordinary source hits the cap.
    const harvest_reach: usize = 1000; // lines each way from the cursor
    const harvest_bytes: usize = 128 * 1024;
    const harvest_cap: usize = 200;

    /// Refill `comp_words` for this request: the current buffer first (so its
    /// words win a duplicate), then the other open buffers. One byte budget
    /// spans the whole harvest, so ten open buffers cost what one does.
    fn harvestWords(self: *Editor, skip: []const u8) void {
        self.comp_words.reset();
        var budget: usize = harvest_bytes;
        if (self.harvestBuf(self.buf, self.cy, skip, &budget)) return;
        for (self.docs.items) |doc| {
            if (&doc.buf == self.buf) continue;
            if (self.harvestBuf(&doc.buf, 0, skip, &budget)) return;
        }
    }

    /// Harvest outward from `centre` — that line, then the one above, then the
    /// one below, up to `harvest_reach` each way — spending at most `budget`
    /// bytes. Outward, not top-of-window-down, is what makes the caps select
    /// the *nearest* words: scanning the window in line order filled all 200
    /// slots a thousand lines above the cursor, so the identifier on the line
    /// you just wrote was never offered. Returns true when the scan is over:
    /// the candidate cap is full, or the budget is spent.
    fn harvestBuf(self: *Editor, b: *const buffer.Buffer, centre: usize, skip: []const u8, budget: *usize) bool {
        const n = b.lineCount();
        if (n == 0) return false;
        const start = @min(centre, n - 1);
        if (self.harvestLine(b, start, skip, budget)) return true;
        var d: usize = 1;
        while (d <= harvest_reach) : (d += 1) {
            const up = d <= start;
            const down = start + d < n;
            if (!up and !down) break; // both directions exhausted
            if (up and self.harvestLine(b, start - d, skip, budget)) return true;
            if (down and self.harvestLine(b, start + d, skip, budget)) return true;
        }
        return false;
    }

    /// One line into the candidate list; true when the scan should stop.
    fn harvestLine(self: *Editor, b: *const buffer.Buffer, row: usize, skip: []const u8, budget: *usize) bool {
        const text = b.line(row);
        if (self.comp_words.addLine(self.gpa, text, skip, harvest_cap, budget.*)) return true;
        if (text.len >= budget.*) return true;
        budget.* -= text.len;
        return false;
    }

    /// How long the main loop may block: forever unless a completion request
    /// is scheduled, which is the only timer zedit ever arms.
    fn pollTimeout(self: *Editor) i32 {
        // The sooner of the debounce and the next toast expiry. Still no timer
        // at all when neither is armed, so an idle editor blocks in poll(2).
        var due: ?i64 = self.comp_due_ms;
        if (self.toasts.nextDeadline()) |d| due = if (due) |x| @min(x, d) else d;
        const at = due orelse return -1;
        const left = at - log.nowMs();
        return if (left <= 0) 0 else @intCast(@min(left, std.math.maxInt(i32)));
    }

    /// Raise a corner notification. Deliberately not a wrapper around
    /// `setStatus`: the statusline answers "what is the state", a toast
    /// answers "what just happened", and the two want different lifetimes.
    fn notifyToast(self: *Editor, level: notify.Level, comptime fmt: []const u8, args: anytype) void {
        var b: [notify.max_text]u8 = undefined;
        const text = std.fmt.bufPrint(&b, fmt, args) catch b[0..];
        self.toasts.push(level, text, log.nowMs(), notify.default_ttl_ms);
    }

    /// True when the debounce has elapsed (the caller then sends the request).
    fn completionDue(self: *Editor) bool {
        const due = self.comp_due_ms orelse return false;
        return log.nowMs() >= due;
    }

    /// Fire the action the shared debounce timer was armed for.
    fn fireDue(self: *Editor) void {
        switch (self.due_kind) {
            .completion => self.requestCompletion(),
            .wsymbol => self.sendWorkspaceSymbolQuery(),
            .grep => self.grepRescan(),
        }
    }

    /// Arm the auto-completion debounce after an identifier keystroke. Typing
    /// on keeps pushing the deadline out, so a request only goes out when the
    /// typist pauses — one round trip per pause, not per character.
    fn armCompletion(self: *Editor) void {
        if (!config.settings.auto_completion) return;
        if (self.mode != .insert) return;
        // A server mid-handshake counts as a server here: it is about to be
        // one, and refusing to arm the timer is how the request went missing.
        if (self.liveLsp() == null and !self.lspStarting() and !config.settings.buffer_completion) return;
        if (self.completionPrefix().len == 0) {
            self.comp_due_ms = null;
            return;
        }
        self.due_kind = .completion;
        self.comp_due_ms = log.nowMs() + @as(i64, @intCast(config.settings.completion_delay_ms));
    }

    fn lspSignatureHelp(self: *Editor) void {
        self.comp_open = false; // a call-argument list isn't an identifier completion
        // Flush the just-typed "(" or "," first, so the server sees it before
        // it computes the signature (this keystroke's edit is still pending).
        self.syncLsp();
        if (self.lsp) |*c| c.requestSignatureHelp(self.cy, self.charCol());
    }

    /// The identifier run immediately before the cursor (what completion filters
    /// on and what `acceptCompletion` replaces).
    fn completionPrefix(self: *Editor) []const u8 {
        const line = self.curLine();
        var start = self.cx;
        while (start > 0) {
            const p = unicode.prevBoundary(line, start);
            if (!isIdentCp(unicode.decode(line[p..]).cp)) break;
            start = p;
        }
        return line[start..self.cx];
    }

    /// The whole identifier the cursor sits in — the prefix plus whatever
    /// follows it on the line. This is the word being typed, and it is never a
    /// candidate for completing itself (typing inside `value` must not offer
    /// `value` back).
    fn completionWord(self: *Editor) []const u8 {
        const line = self.curLine();
        const start = self.cx - self.completionPrefix().len;
        var end = self.cx;
        while (end < line.len) {
            const d = unicode.decode(line[end..]);
            if (!isIdentCp(d.cp)) break;
            end += d.len;
        }
        return line[start..end];
    }

    fn compMove(self: *Editor, down: bool) void {
        const n = self.comp_filtered.items.len;
        if (n == 0) return;
        if (down) {
            if (self.comp_sel + 1 < n) self.comp_sel += 1;
        } else if (self.comp_sel > 0) self.comp_sel -= 1;
    }

    /// How many candidates the popup is showing, from whichever source filled
    /// it: the server's items, or the words harvested from the open buffers.
    fn compCount(self: *const Editor) usize {
        if (self.comp_words_src) return self.comp_words.count();
        return if (self.lsp) |*c| c.completions.items.len else 0;
    }

    /// Candidate `i`'s text in the active source (see `compCount`).
    fn compLabel(self: *const Editor, i: usize) []const u8 {
        if (self.comp_words_src) return self.comp_words.get(i);
        return if (self.lsp) |*c| c.completions.items[i].label else "";
    }

    /// Rebuild the visible list from the prefix under the cursor, fuzzily:
    /// `mc` matches `mockComplete`, and candidates are ranked by the same
    /// scorer the pickers use (consecutive runs and word starts win).
    fn filterCompletions(self: *Editor) void {
        self.comp_filtered.clearRetainingCapacity();
        const prefix = self.completionPrefix();
        const qmask = fuzzy.charMask(prefix);
        var scored: std.ArrayList(Scored) = .empty;
        defer scored.deinit(self.gpa);
        const n = self.compCount();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (prefix.len == 0) {
                self.comp_filtered.append(self.gpa, i) catch {};
                continue;
            }
            const label = self.compLabel(i);
            if (!fuzzy.maskMatches(fuzzy.charMask(label), qmask)) continue; // cheap reject
            const s = fuzzy.score(label, prefix) orelse continue;
            scored.append(self.gpa, .{ .idx = @intCast(i), .score = s }) catch {};
        }
        if (prefix.len > 0) {
            std.mem.sort(Scored, scored.items, {}, scoredLess);
            for (scored.items) |s| self.comp_filtered.append(self.gpa, s.idx) catch {};
        }
        if (self.comp_filtered.items.len == 0) {
            self.comp_open = false;
        } else if (self.comp_sel >= self.comp_filtered.items.len) {
            self.comp_sel = self.comp_filtered.items.len - 1;
        }
    }

    /// Insert the selected candidate. The server's own `textEdit` range wins
    /// over our identifier-prefix guess; `additionalTextEdits` (auto-imports)
    /// are applied too; and a snippet item expands its placeholders and starts
    /// a tabstop session.
    fn acceptCompletion(self: *Editor) void {
        defer self.comp_open = false;
        if (self.comp_sel >= self.comp_filtered.items.len) return;
        const idx = self.comp_filtered.items[self.comp_sel];

        // A buffer word is plain text: replace the typed prefix with it, and
        // that is the whole story — no server range, no snippet, no imports.
        if (self.comp_words_src) {
            const word = self.comp_words.get(idx);
            const start = self.cx - self.completionPrefix().len;
            self.pushUndo();
            self.buf.deleteInLine(self.cy, start, self.cx) catch {};
            self.insertTextAt(self.cy, start, word);
            self.updateGoal();
            self.syncLsp();
            return;
        }

        const client = if (self.lsp) |*c| c else return;
        const item = client.completions.items[idx];

        // Where the completion replaces text.
        var row = self.cy;
        var start = self.cx - self.completionPrefix().len;
        var end = self.cx;
        if (item.edit) |e| {
            if (e.start_line == e.end_line and e.start_line < self.buf.lineCount()) {
                row = e.start_line;
                const line = self.buf.line(row);
                start = @min(byteAtCharCol(line, e.start_char), line.len);
                end = @min(@max(byteAtCharCol(line, e.end_char), start), line.len);
            }
        }

        // Snippet items expand first; plain items insert as-is.
        var parsed: ?snippet.Parsed = null;
        defer if (parsed) |*p| p.deinit(self.gpa);
        var text = item.insert;
        if (item.is_snippet) {
            parsed = snippet.parse(self.gpa, item.insert) catch null;
            if (parsed) |p| text = p.text;
        }

        self.pushUndo();
        self.buf.deleteInLine(row, start, end) catch {};
        self.insertTextAt(row, start, text);

        if (parsed) |p| {
            self.beginSnippet(row, start, text, p.stops);
        } else {
            self.updateGoal();
        }

        // Auto-imports and friends land outside the completion range; apply
        // them after, so the positions above are not disturbed.
        if (item.extra.len > 0) _ = applyEditsToBuf(self.buf, item.extra);
        self.syncLsp();
    }

    /// Insert `text` at (row, col), splitting lines on newlines, and leave the
    /// cursor just past it.
    fn insertTextAt(self: *Editor, row: usize, col: usize, text: []const u8) void {
        var r = row;
        var c = col;
        var it = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (it.next()) |part| {
            if (!first) {
                self.buf.splitLine(r, c) catch return;
                r += 1;
                c = 0;
            }
            first = false;
            if (part.len > 0) {
                self.buf.insertBytes(r, c, part) catch return;
                c += part.len;
            }
        }
        self.cy = r;
        self.cx = c;
    }

    /// Start a tabstop session for text just inserted at (row, col), and jump
    /// to the first stop.
    fn beginSnippet(self: *Editor, row: usize, col: usize, text: []const u8, stops: []const snippet.Stop) void {
        self.snip_stops.clearRetainingCapacity();
        for (stops) |s| {
            const pos = offsetToPos(row, col, text, s.offset);
            const owned: ?[]u8 = if (s.choices) |c| (self.gpa.dupe(u8, c) catch null) else null;
            self.snip_stops.append(self.gpa, .{
                .row = pos.row,
                .col = pos.col,
                .len = s.len,
                .choices = owned,
            }) catch {
                if (owned) |o| self.gpa.free(o);
            };
        }
        self.snip_idx = 0;
        if (self.snip_stops.items.len == 0) {
            self.updateGoal();
            return;
        }
        self.gotoSnipStop(0);
    }

    fn gotoSnipStop(self: *Editor, idx: usize) void {
        if (idx >= self.snip_stops.items.len) return self.endSnippet();
        const s = self.snip_stops.items[idx];
        self.snip_idx = idx;
        self.cy = @min(s.row, self.buf.lineCount() - 1);
        self.cx = @min(s.col, self.buf.line(self.cy).len);
        self.snip_pristine = s.len > 0;
        self.updateGoal();
        if (s.choices) |c| self.setStatus("^n/^p choices: {s}", .{c});
    }

    /// Cycle a choice tabstop (`${1|a,b,c|}`) through its alternatives,
    /// swapping the text in the buffer as it goes.
    fn snippetCycleChoice(self: *Editor, forward: bool) bool {
        if (!self.snippetActive()) return false;
        const s = self.snip_stops.items[self.snip_idx];
        const list = s.choices orelse return false;

        const n = std.mem.count(u8, list, ",") + 1;
        if (n <= 1) return false;
        const next = if (forward) (s.choice + 1) % n else (s.choice + n - 1) % n;

        var pick: []const u8 = "";
        var i: usize = 0;
        var it2 = std.mem.splitScalar(u8, list, ',');
        while (it2.next()) |c| : (i += 1) {
            if (i == next) pick = c;
        }

        const line = self.buf.line(s.row);
        const end = @min(s.col + s.len, line.len);
        if (end < s.col) return false;
        self.buf.deleteInLine(s.row, s.col, end) catch return false;
        self.buf.insertBytes(s.row, s.col, pick) catch return false;

        const old_len = end - s.col;
        for (self.snip_stops.items) |*o| {
            if (o.row == s.row and o.col > s.col) {
                o.col = o.col + pick.len -| old_len;
            }
        }
        self.snip_stops.items[self.snip_idx].len = pick.len;
        self.snip_stops.items[self.snip_idx].choice = next;
        self.snip_pristine = true; // typing still replaces the whole choice
        self.cy = s.row;
        self.cx = s.col;
        self.updateGoal();
        self.setStatus("^n/^p choices: {s}", .{list});
        return true;
    }

    fn endSnippet(self: *Editor) void {
        for (self.snip_stops.items) |s| {
            if (s.choices) |c| self.gpa.free(c);
        }
        self.snip_stops.clearRetainingCapacity();
        self.snip_idx = 0;
        self.snip_pristine = false;
    }

    fn snippetActive(self: *Editor) bool {
        return self.snip_stops.items.len > 0;
    }

    /// Tab / Shift-Tab inside a snippet: move to the next / previous tabstop.
    fn snippetJump(self: *Editor, forward: bool) void {
        if (forward) {
            if (self.snip_idx + 1 >= self.snip_stops.items.len) return self.endSnippet();
            self.gotoSnipStop(self.snip_idx + 1);
        } else if (self.snip_idx > 0) {
            self.gotoSnipStop(self.snip_idx - 1);
        }
    }

    /// Keep the remaining tabstops pointing at the right text after an edit at
    /// (row, col): stops later on that line move by the number of bytes the
    /// edit added or removed. A split or join (Enter, a joining backspace)
    /// changes the line numbering, which this simple model does not track, so
    /// it ends the session rather than jumping somewhere wrong.
    fn snippetShift(self: *Editor, row: usize, col: usize, rows_before: usize, len_before: usize) void {
        const rows_after = self.buf.lineCount();
        if (rows_after == rows_before + 1) return self.snippetSplit(row, col);
        if (rows_after + 1 == rows_before) return self.snippetJoin(row);
        if (rows_after != rows_before) return self.endSnippet(); // multi-line paste
        if (row >= self.buf.lineCount()) return self.endSnippet();
        const len_after = self.buf.line(row).len;
        if (len_after == len_before) return;
        for (self.snip_stops.items) |*s| {
            if (s.row != row or s.col < col) continue;
            if (len_after > len_before) {
                s.col += len_after - len_before;
            } else {
                s.col -|= len_before - len_after;
            }
        }
    }

    /// A line split at (row, col) — Enter inside a snippet: everything after
    /// the split point moves down a line, so the stops follow it.
    fn snippetSplit(self: *Editor, row: usize, col: usize) void {
        for (self.snip_stops.items) |*s| {
            if (s.row > row) {
                s.row += 1;
            } else if (s.row == row and s.col >= col) {
                s.row += 1;
                s.col -= col;
            }
        }
    }

    /// A join (backspace at column 0) — the cursor now sits where the two
    /// lines met, so stops from the removed line move up and across.
    fn snippetJoin(self: *Editor, row: usize) void {
        if (row == 0) return self.endSnippet();
        const at = self.cx; // the join point, where the cursor landed
        for (self.snip_stops.items) |*s| {
            if (s.row == row) {
                s.row -= 1;
                s.col += at;
            } else if (s.row > row) {
                s.row -= 1;
            }
        }
    }

    /// The first text typed at an untouched placeholder replaces it, so the
    /// hint text never has to be deleted by hand. Later stops on the same line
    /// shift by what was removed.
    fn snippetConsumePlaceholder(self: *Editor) void {
        if (!self.snip_pristine or !self.snippetActive()) return;
        self.snip_pristine = false;
        const s = self.snip_stops.items[self.snip_idx];
        if (s.len == 0) return;
        const line = self.buf.line(s.row);
        const end = @min(s.col + s.len, line.len);
        if (end <= s.col) return;
        self.buf.deleteInLine(s.row, s.col, end) catch return;
        self.cy = s.row;
        self.cx = s.col;
        for (self.snip_stops.items) |*o| {
            if (o.row == s.row and o.col > s.col) o.col -= (end - s.col);
        }
        self.snip_stops.items[self.snip_idx].len = 0;
    }

    /// Store yanked/deleted text in the pending register. Writes to the
    /// clipboard registers (`"+` / `"*`) are also sent to the terminal as an
    /// OSC 52 sequence, which sets the *local* system clipboard even over SSH.
    fn yankTo(self: *Editor, text: []const u8, kind: register.Kind, width: usize) void {
        self.registers.set(self.pending_register, text, kind, width) catch {};
        if (register.Store.isClipboard(self.pending_register)) self.osc52Copy(text);
    }

    fn osc52Copy(self: *Editor, text: []const u8) void {
        const max_raw = 1 << 20; // terminals cap OSC 52 payloads; 1 MiB is generous
        if (text.len > max_raw) {
            self.setStatus("clipboard: too large for OSC 52 ({d} bytes)", .{text.len});
            return;
        }
        const enc = std.base64.standard.Encoder;
        const b64 = self.gpa.alloc(u8, enc.calcSize(text.len)) catch return;
        defer self.gpa.free(b64);
        _ = enc.encode(b64, text);
        var seq: std.ArrayList(u8) = .empty;
        defer seq.deinit(self.gpa);
        seq.appendSlice(self.gpa, "\x1b]52;c;") catch return;
        seq.appendSlice(self.gpa, b64) catch return;
        seq.append(self.gpa, 0x07) catch return; // BEL terminator
        self.term.write(seq.items) catch {};
        self.setStatus("copied {d} bytes to the system clipboard", .{text.len});
        self.notifyToast(.info, "copied {d} bytes to the clipboard", .{text.len});
    }

    fn undoChange(self: *Editor) void {
        if (self.rejectReadOnly()) return;
        if (!self.history.undo(self.buf, &self.cy, &self.cx)) self.setStatus("already at oldest change", .{});
        self.clampCursor();
        self.updateGoal();
        self.resetPending();
    }

    fn redoChange(self: *Editor) void {
        if (self.rejectReadOnly()) return;
        if (!self.history.redo(self.buf, &self.cy, &self.cx)) self.setStatus("already at newest change", .{});
        self.clampCursor();
        self.updateGoal();
        self.resetPending();
    }

    /// The document's absolute path, which is what its undo file is keyed on.
    /// Null for a scratch or remote buffer: there is nothing stable to key on.
    fn absPathOf(self: *Editor, out: []u8) ?[]const u8 {
        const p = self.buf.path orelse return null;
        if (remote.isRemote(p)) return null;
        if (p.len > 0 and p[0] == '/') return std.fmt.bufPrint(out, "{s}", .{p}) catch null;
        const cwd = std.process.currentPathAlloc(self.io, self.gpa) catch return null;
        defer self.gpa.free(cwd);
        return std.fmt.bufPrint(out, "{s}/{s}", .{ cwd, p }) catch null;
    }

    /// Write the undo tree beside the file's state entry (config
    /// `persistent_undo`, off by default). Best-effort: a history that cannot
    /// be written is not worth interrupting a save for.
    fn persistHistory(self: *Editor) void {
        if (!config.settings.persistent_undo) return;
        var abs_buf: [1024]u8 = undefined;
        const abs = self.absPathOf(&abs_buf) orelse return;
        var file_buf: [768]u8 = undefined;
        const file = undo.filePath(&file_buf, abs) orelse return;
        self.history.writeTo(self.io, file, abs);
    }

    /// Bring back the undo tree written by an earlier session — but only if it
    /// ends on the text actually in the file. Anything could have edited it in
    /// between, and a history of a different past is worse than none.
    fn restoreHistory(self: *Editor) void {
        if (!config.settings.persistent_undo or self.history.cur != null) return;
        var abs_buf: [1024]u8 = undefined;
        const abs = self.absPathOf(&abs_buf) orelse return;
        var file_buf: [768]u8 = undefined;
        const file = undo.filePath(&file_buf, abs) orelse return;
        const now = self.buf.toBytes(self.gpa) catch return;
        defer self.gpa.free(now);
        // The history is anchored to the text it was written against; if the
        // file has moved on, `readFrom` says so by returning nothing.
        const loaded = undo.History.readFrom(self.gpa, self.io, file, abs, now) orelse {
            std.log.scoped(.editor).debug("no usable undo history for {s}", .{abs});
            return;
        };
        self.history.deinit();
        self.history = loaded;
        std.log.scoped(.editor).debug("undo history restored for {s}", .{abs});
    }

    /// `g-` / `g+` and `:earlier` / `:later` with a plain count: step through
    /// the states in the order they were made, across branches. This is how a
    /// change stranded by an undo-then-edit is reached again.
    fn timeTravel(self: *Editor, count: usize, back: bool) void {
        if (self.rejectReadOnly()) return;
        const moved = self.history.travel(self.buf, &self.cy, &self.cx, count, back);
        if (moved == 0) {
            self.setStatus("already at {s} change", .{if (back) "oldest" else "newest"});
        } else {
            self.setStatus("{d} change{s} {s}", .{ moved, if (moved == 1) "" else "s", if (back) "back" else "forward" });
        }
        self.afterHistoryMove();
    }

    /// `:earlier 10s` / `:later 2m`: the same, counted in time.
    fn timeTravelSpan(self: *Editor, ms: i64, back: bool) void {
        if (self.rejectReadOnly()) return;
        if (self.history.travelTime(self.buf, &self.cy, &self.cx, ms, back)) {
            self.setStatus("moved {s} {d}s", .{ if (back) "back" else "forward", @divTrunc(ms, 1000) });
        } else {
            self.setStatus("already at {s} change", .{if (back) "oldest" else "newest"});
        }
        self.afterHistoryMove();
    }

    fn afterHistoryMove(self: *Editor) void {
        self.clampCursor();
        self.updateGoal();
        self.resetPending();
    }

    /// `:earlier` / `:later`: a count of changes, or a span with an `s`/`m`/`h`
    /// suffix (vim's `f` — counted in file writes — is not implemented).
    fn historyCommand(self: *Editor, arg: []const u8, back: bool) void {
        const a = std.mem.trim(u8, arg, " ");
        if (a.len == 0) return self.timeTravel(1, back);
        const suffix = a[a.len - 1];
        const scale: ?i64 = switch (suffix) {
            's' => 1000,
            'm' => 60 * 1000,
            'h' => 60 * 60 * 1000,
            else => null,
        };
        const writes = suffix == 'f';
        const digits = if (scale == null and !writes) a else a[0 .. a.len - 1];
        const n = std.fmt.parseInt(u32, digits, 10) catch
            return self.setStatus("usage: :{s} [count | Ns | Nm | Nh | Nf]", .{if (back) "earlier" else "later"});
        if (writes) {
            // Counted in file writes, which is how you get back to "what I had
            // when I last saved" without counting keystrokes.
            if (self.history.travelWrites(self.buf, &self.cy, &self.cx, n, back)) {
                self.setStatus("{d} write{s} {s}", .{ n, if (n == 1) "" else "s", if (back) "back" else "forward" });
            } else {
                self.setStatus("already at {s} change", .{if (back) "oldest" else "newest"});
            }
            self.afterHistoryMove();
        } else if (scale) |ms| self.timeTravelSpan(@as(i64, n) * ms, back) else self.timeTravel(n, back);
    }

    /// `:undolist`: every state in the tree, oldest first, in a picker that
    /// jumps to the chosen one. The sequence number is stashed in `line`.
    fn openUndoPicker(self: *Editor) void {
        var entries: std.ArrayList(undo.Entry) = .empty;
        defer entries.deinit(self.gpa);
        self.history.list(self.buf, self.cy, self.cx, &entries) catch return self.setStatus("out of memory", .{});
        if (entries.items.len == 0) return self.setStatus("no changes yet", .{});
        self.startPicker(.undo);
        const now = log.nowMs();
        for (entries.items) |e| {
            var b: [96]u8 = undefined;
            const secs = @divTrunc(now - e.time_ms, 1000);
            const row = std.fmt.bufPrint(&b, "{s}{d:>4}  {d}s ago{s}", .{
                if (e.current) "\u{25B8} " else "  ",
                e.seq,
                secs,
                if (e.branch) "  (branch)" else "",
            }) catch continue;
            self.addPickItem(row, "", e.seq);
            if (e.current) self.picker_sel = self.picker_items.items.len - 1;
        }
        self.mode = .picker;
        self.refilter();
    }

    // === folds =============================================================

    /// `zf{motion}` — fold the lines the motion covered, closed, and put the
    /// cursor on the header so it is not left inside something invisible.
    fn foldCreate(self: *Editor, top: usize, bot: usize) void {
        if (bot <= top) return self.setStatus("a fold needs more than one line", .{});
        self.d.folds.add(top, bot);
        self.cy = top;
        self.updateGoal();
        self.prev_valid = false;
        self.setStatus("folded {d} lines", .{bot - top + 1});
    }

    fn foldSet(self: *Editor, closed: bool) void {
        if (!self.d.folds.setClosed(self.cy, closed))
            return self.setStatus("no fold here", .{});
        self.afterFoldChange();
    }

    fn foldToggle(self: *Editor) void {
        if (!self.d.folds.toggle(self.cy)) return self.setStatus("no fold here", .{});
        self.afterFoldChange();
    }

    fn foldAll(self: *Editor, closed: bool) void {
        if (self.d.folds.len() == 0) return self.setStatus("no folds", .{});
        self.d.folds.setAll(closed);
        self.afterFoldChange();
        self.setStatus("{s} {d} folds", .{ if (closed) "closed" else "opened", self.d.folds.len() });
    }

    fn foldDelete(self: *Editor) void {
        if (!self.d.folds.removeAt(self.cy)) return self.setStatus("no fold here", .{});
        self.afterFoldChange();
        self.setStatus("fold removed", .{});
    }

    fn foldClear(self: *Editor) void {
        const n = self.d.folds.len();
        if (n == 0) return self.setStatus("no folds", .{});
        self.d.folds.clear();
        self.afterFoldChange();
        self.setStatus("removed {d} folds", .{n});
    }

    /// Move every document's folds by the lines its buffer just gained or
    /// lost, so a fold keeps covering the same text. Every document, not just
    /// the active one: a workspace edit from a language server rewrites files
    /// that are open but not on screen.
    fn settleFolds(self: *Editor) void {
        for (self.docs.items) |doc| {
            const edits = doc.buf.takeLineEdits();
            if (edits.len == 0) continue;
            // The active document's folds live on the Doc either way — only
            // the buffer is mirrored on the Editor.
            for (edits) |ed| doc.folds.shift(ed.at, ed.delta);
            doc.buf.clearLineEdits();
            if (doc == self.d) self.cy = doc.folds.prevVisible(self.cy);
        }
    }

    /// The cursor must never sit on a hidden line, and the whole frame changes
    /// when a fold opens or closes.
    fn afterFoldChange(self: *Editor) void {
        self.cy = self.d.folds.prevVisible(self.cy);
        self.clampCursor();
        self.prev_valid = false;
    }

    // === the quickfix list =================================================

    /// `]q` / `[q` — walk the list, opening each entry where it points. The
    /// jump is a jump: `Ctrl-o` comes back.
    fn qfStep(self: *Editor, forward: bool, count: usize) void {
        if (self.qf.len() == 0) return self.setStatus("quickfix list is empty", .{});
        const entry = self.qf.step(forward, count) orelse return;
        self.qfJump(entry);
    }

    fn qfJump(self: *Editor, entry: quickfix.Entry) void {
        self.addJump();
        self.openFile(entry.path, entry.line - 1); // 1-based entry -> 0-based row
        self.cx = @min(entry.col, self.curLine().len);
        self.updateGoal();
        self.setStatus("({d} of {d}) {s}", .{ self.qf.idx + 1, self.qf.len(), docLabel(self.d) });
    }

    /// `Ctrl-q` in a picker — keep every result that names a file position,
    /// instead of choosing one and losing the rest. Telescope's binding, and
    /// the reason the quickfix list exists at all.
    fn qfFromPicker(self: *Editor) void {
        const what: []const u8 = switch (self.picker_kind) {
            .grep => "grep",
            .reference => "references",
            .diagnostic => "diagnostics",
            else => return self.setStatus("nothing here to send to the quickfix list", .{}),
        };
        self.qf.clear();
        self.qf.setTitle(what);
        for (self.picker_filtered.items) |idx| {
            const it = self.picker_items.items[idx];
            const path = self.picker_text.items[it.path_at .. it.path_at + it.path_len];
            const text = self.picker_text.items[it.display_at .. it.display_at + it.display_len];
            if (path.len == 0) continue;
            self.qf.add(path, it.line, 0, text);
        }
        // The walk hands results back in filesystem order; `]q` should visit
        // them in file order, the same on every machine.
        self.qf.sort();
        self.closePicker();
        if (self.qf.len() == 0) return self.setStatus("no results to keep", .{});
        self.setStatus("{d} {s} result{s} in the quickfix list — ]q / [q to walk them", .{
            self.qf.len(), what, if (self.qf.len() == 1) "" else "s",
        });
    }

    /// `:copen` — the list as a read-only scratch in a horizontal split, one
    /// line per entry. Enter on a line jumps to it, as in vim.
    fn qfOpen(self: *Editor) void {
        if (self.qf.len() == 0)
            return self.setStatus("quickfix list is empty (Ctrl-q in a picker)", .{});
        for (self.wins.items) |w| { // already up: focus it rather than stacking
            if (w.doc.qf_view) {
                self.focusWin(w);
                return;
            }
        }
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        for (self.qf.entries.items) |it| {
            const rel = self.cwdRelative(it.path) orelse it.path;
            text.print(self.gpa, "{s}:{d}: {s}\n", .{ rel, it.line, it.text }) catch break;
        }
        var label: [128]u8 = undefined;
        const name = std.fmt.bufPrint(&label, "[quickfix] {s}", .{self.qf.title.items}) catch "[quickfix]";
        self.openScratch(name, text.items, .none, false);
        if (!self.d.read_only) return; // openScratch failed and said so
        self.d.qf_view = true;
        self.placeAt(self.qf.idx);
        self.setStatus("{d} entries — Enter jumps, :cclose closes", .{self.qf.len()});
    }

    /// `Space h` — back to the startup screen. It is shown at launch on an
    /// empty session and, until now, could never be reached again once any
    /// key had dismissed it (AstroNvim's `<leader>h`).
    fn showHome(self: *Editor) void {
        if (self.recents.entries.items.len == 0)
            return self.setStatus("no recently opened files yet", .{});
        self.dashboard = true;
        self.dash_sel = 0;
        self.prev_valid = false; // it paints the whole screen
    }

    fn qfClose(self: *Editor) void {
        for (self.wins.items) |w| {
            if (!w.doc.qf_view) continue;
            const doc = w.doc;
            self.focusWin(w);
            if (self.wins.items.len > 1) self.closeWindow() else return self.setStatus("cannot close last window", .{});
            for (self.wins.items) |other| {
                if (other.doc == doc) return; // still shown somewhere
            }
            self.destroyDoc(doc);
            self.clearExtra();
            self.placeAt(self.cy);
            return;
        }
        self.setStatus("no quickfix window", .{});
    }

    // === the debugger ======================================================

    fn dbgFd(self: *Editor) ?std.posix.fd_t {
        const d = if (self.dbg) |*x| x else return null;
        return if (d.alive()) d.outFd() else null;
    }

    /// `Space d b` — a breakpoint on the cursor's line. They belong to the
    /// file, not to a session: set them before anything runs, and they survive
    /// the program exiting.
    fn toggleBreakpoint(self: *Editor) void {
        const path = self.buf.path orelse return self.setStatus("no file name — save it first", .{});
        const line = self.cy + 1; // DAP counts from 1
        const on = self.breakpoints.toggle(path, line);
        self.pushBreakpoints(path);
        self.setStatus("breakpoint {s} at line {d}", .{ if (on) "set" else "cleared", line });
    }

    fn clearBreakpoints(self: *Editor) void {
        const n = self.breakpoints.total();
        if (n == 0) return self.setStatus("no breakpoints", .{});
        var it = self.breakpoints.files.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.clearRetainingCapacity();
            if (self.dbg) |*d| d.setBreakpoints(entry.key_ptr.*, &.{});
        }
        self.setStatus("cleared {d} breakpoint{s}", .{ n, if (n == 1) "" else "s" });
    }

    /// Tell a running adapter this file's whole set (DAP replaces per file).
    fn pushBreakpoints(self: *Editor, path: []const u8) void {
        const d = if (self.dbg) |*x| x else return;
        if (!d.alive()) return;
        d.setBreakpoints(path, self.breakpoints.linesFor(path));
    }

    const Step = enum { over, into, out };

    /// `Space d c` — continue a stopped program, or start one. Starting needs
    /// a program to run, which only `:debug <program>` can name.
    fn debugContinue(self: *Editor) void {
        const d = if (self.dbg) |*x| x else
            return self.setStatus("no debug session — :debug <program> starts one", .{});
        if (!d.alive()) return self.setStatus("the debug session has ended", .{});
        if (d.state != .stopped) return self.setStatus("already running", .{});
        d.cont();
        self.setStatus("continuing", .{});
    }

    fn debugStep(self: *Editor, how: Step) void {
        const d = if (self.dbg) |*x| x else return self.setStatus("no debug session", .{});
        if (!d.alive()) return self.setStatus("the debug session has ended", .{});
        if (d.state != .stopped) return self.setStatus("the program is running — it must stop first", .{});
        switch (how) {
            .over => d.next(),
            .into => d.stepIn(),
            .out => d.stepOut(),
        }
    }

    fn debugStop(self: *Editor) void {
        if (self.dbg) |*d| {
            d.deinit();
            self.dbg = null;
            self.dbg_line = null;
            self.setStatus("debug session ended", .{});
        } else self.setStatus("no debug session", .{});
    }

    /// `:debug <program> [args]` — start an adapter for the current filetype
    /// and launch `program` under it.
    fn startDebug(self: *Editor, arg: []const u8) void {
        if (arg.len == 0) return self.setStatus("usage: :debug <program> [args]", .{});
        if (self.dbg != null) self.debugStop();
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        if (self.dap_cmd) |cmd| {
            var it = std.mem.tokenizeScalar(u8, cmd, ' ');
            while (it.next()) |w| argv.append(self.gpa, w) catch return;
        } else {
            const def = syntax.adapter(self.lang) orelse
                return self.setStatus("no debug adapter for this filetype — pass --dap <command>", .{});
            argv.appendSlice(self.gpa, def) catch return;
        }
        var parts = std.mem.tokenizeScalar(u8, arg, ' ');
        const program = parts.next() orelse return self.setStatus("usage: :debug <program> [args]", .{});
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.gpa);
        while (parts.next()) |a| args.append(self.gpa, a) catch return;

        var client = dap.Client.spawn(self.gpa, self.io, argv.items) catch |err|
            return self.setStatus("could not start {s}: {s}", .{ argv.items[0], @errorName(err) });
        // The handshake is a round trip; waiting briefly here means the
        // `initialized` event has usually arrived by the time the user's next
        // key does, without the editor ever blocking for long.
        client.pump(500);
        client.launch(program, args.items);
        var it = self.breakpoints.files.iterator();
        while (it.next()) |entry| client.setBreakpoints(entry.key_ptr.*, entry.value_ptr.items);
        client.configurationDone();
        self.dbg = client;
        self.setStatus("debugging {s}", .{program});
    }

    /// Act on whatever the adapter said: when it stops, go to the line.
    /// Returns true when the screen needs redrawing.
    fn consumeDebug(self: *Editor) bool {
        const d = if (self.dbg) |*x| x else return false;
        if (!d.takeChanged()) return false;
        switch (d.state) {
            .stopped => {
                if (d.where) |w| {
                    if (w.path.len > 0) {
                        self.openFile(w.path, w.line - 1); // DAP counts from 1
                        self.dbg_line = w.line;
                        self.setStatus("stopped ({s}) at {s}:{d}", .{ w.reason, docLabel(self.d), w.line });
                    }
                }
            },
            .exited => {
                self.dbg_line = null;
                self.setStatus("the program exited", .{});
            },
            else => self.dbg_line = null,
        }
        return true;
    }

    // === the embedded terminal =============================================

    /// The pty of a *visible* shell, for the poll loop. Only one is polled —
    /// the active window's — which keeps the loop's fd set fixed and means a
    /// backgrounded shell costs nothing until it is looked at again.
    fn termFd(self: *Editor) ?std.posix.fd_t {
        const sh = if (self.cur.doc.shell) |*s| s else return null;
        return if (sh.done) null else sh.child.fd;
    }

    /// `Space t t` / `:terminal` — a shell in a horizontal split, in Terminal
    /// mode so typing goes straight to it. Opening one while a shell window is
    /// already visible focuses that instead of stacking another (VS Code's
    /// rule, and the same "toggle, don't stack" the diff views follow).
    /// The next free terminal name: t1, t2, t3 … Reusing a number that has
    /// been closed keeps the list short and stable, which is what a name is
    /// for — `t7` beside `t2` with nothing between them reads as a bug.
    fn nextTerminalName(self: *Editor) [8]u8 {
        var n: usize = 1;
        outer: while (n < 999) : (n += 1) {
            var want: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&want, "t{d}", .{n}) catch break;
            for (self.docs.items) |doc| {
                if (doc.shell == null) continue;
                if (std.mem.eql(u8, doc.name orelse "", s)) continue :outer;
            }
            var out: [8]u8 = [_]u8{0} ** 8;
            @memcpy(out[0..s.len], s);
            return out;
        }
        return [_]u8{ 't', '1', 0, 0, 0, 0, 0, 0 };
    }

    /// Open *another* terminal. Several can be up at once, and the row above
    /// them names each one — VS Code's and Zed's panel, where the terminals
    /// are their own list rather than buffers mixed in with the files.
    fn openTerminal(self: *Editor) void {
        // Already showing one: add the new terminal to that pane rather than
        // splitting the window again.
        const existing: ?*Win = blk: {
            for (self.wins.items) |w| {
                if (w.doc.shell != null) break :blk w;
            }
            break :blk null;
        };
        const doc = self.makeEmptyDoc() orelse return self.setStatus("out of memory", .{});
        const nb = self.nextTerminalName();
        doc.name = self.gpa.dupe(u8, std.mem.sliceTo(&nb, 0)) catch null;
        doc.read_only = true; // nothing edits the grid through buffer commands
        if (existing) |w| {
            self.focusWin(w); // reuse the pane the terminals live in
        } else self.splitWindow(false); // horizontal, below
        self.focusDoc(doc);
        self.layout(); // the new window's size, before the shell is told it
        const rows: u16 = @intCast(@max(1, self.winTextRows(self.cur)));
        const cols: u16 = @intCast(@max(1, winTextCols(self.cur)));
        var argv = [_:null]?[*:0]const u8{ term.userShell(), null };
        const child = term.spawnChild(&argv, null, rows, cols) catch |err| {
            self.closeWindow();
            self.freeDoc(doc);
            return self.setStatus("could not start a shell: {s}", .{@errorName(err)});
        };
        const screen = vt.Screen.init(self.gpa, rows, cols) catch {
            var ch = child;
            ch.close();
            self.closeWindow();
            self.freeDoc(doc);
            return self.setStatus("out of memory", .{});
        };
        doc.shell = .{ .child = child, .screen = screen };
        self.mode = .terminal;
        self.setStatus("terminal — Ctrl-\\ Ctrl-n for normal mode", .{});
    }

    /// Walk the shell's scrollback. Used by the wheel in Terminal mode and by
    /// `Ctrl-u`/`Ctrl-d` in normal mode over a terminal window, which is where
    /// a reader who has stopped typing will reach for it.
    fn shellScroll(self: *Editor, back: bool, rows: usize) void {
        const sh = if (self.cur.doc.shell) |*s| s else return;
        if (!sh.screen.scrollView(rows, back)) {
            if (back) {
                self.setStatus("top of the scrollback", .{});
            } else self.setStatus("already at the live output", .{});
            return;
        }
        self.prev_valid = false;
        if (sh.screen.back == 0) {
            self.setStatus("live", .{});
        } else self.setStatus("scrolled back {d} lines", .{sh.screen.back});
    }

    /// A click on a tab's `✕`. Closing the *active* buffer is the ordinary
    /// close; closing another one must not disturb where you are, so it is
    /// focused, closed, and focus returns to where it was — unless that was
    /// the buffer just closed.
    fn closeTab(self: *Editor, doc: *Doc) void {
        if (doc.shell != null) return self.closeTerminalDoc(doc);
        if (doc == self.d) return self.closeDoc(false);
        const keep = self.d;
        self.focusDoc(doc);
        self.closeDoc(false);
        // `closeDoc` refuses a dirty buffer and says so; only go back when it
        // actually went.
        for (self.docs.items) |d| {
            if (d == doc) return; // still open: the close was refused
        }
        self.focusDoc(keep);
        self.clampCursor();
    }

    /// Ctrl-backtick — open the terminal, or close it if one is showing.
    /// VS Code's and Zed's rule: one key both ways, from either mode.
    fn toggleTerminal(self: *Editor) void {
        for (self.wins.items) |w| {
            if (w.doc.shell == null) continue;
            self.focusWin(w);
            self.closeTerminal();
            return;
        }
        self.openTerminal();
    }

    /// Drain whatever the shell has written into its grid. Returns true when
    /// something changed, so the loop knows to render.
    fn pumpTerminal(self: *Editor) bool {
        const sh = if (self.cur.doc.shell) |*s| s else return false;
        if (sh.done) return false;
        var buf: [8192]u8 = undefined;
        var any = false;
        // Read until the pty is empty: one wake-up can carry a screenful, and
        // stopping after 8 KB would leave the rest for the *next* key.
        while (true) {
            const chunk = sh.child.read(&buf);
            if (chunk.len == 0) break;
            sh.screen.feed(chunk);
            // Queries the child sent get their answers written straight back:
            // a shell that asks what terminal this is and hears nothing waits
            // out its timeout (fish gives it ten seconds) and then turns
            // features off.
            const reply = sh.screen.takeReply();
            if (reply.len > 0) {
                sh.child.write(reply);
                sh.screen.clearReply();
            }
            any = true;
            if (chunk.len < buf.len) break;
        }
        if (sh.child.reap()) {
            sh.done = true;
            any = true;
            if (self.mode == .terminal) self.mode = .normal;
            // `exit` at the prompt closes the terminal, as it does in VS Code
            // and Zed — waiting for a keypress to dismiss a dead shell is a
            // second thing to do for something already finished.
            self.closeTerminalDoc(self.cur.doc);
            self.setStatus("terminal closed", .{});
        }
        return any;
    }

    /// Keep the shell's idea of its window in step with the split's.
    /// Rows the shell's grid gets: the window's text rows less the tab row
    /// above it.
    fn shellRows(self: *Editor, w: *Win) usize {
        return self.winTextRows(w) -| 1;
    }

    fn syncTerminalSize(self: *Editor, w: *Win) void {
        const sh = if (w.doc.shell) |*s| s else return;
        if (sh.done) return;
        const rows: u16 = @intCast(@max(1, self.shellRows(w)));
        const cols: u16 = @intCast(@max(1, winTextCols(w)));
        if (rows == sh.screen.rows and cols == sh.screen.cols) return;
        sh.screen.resize(rows, cols) catch return;
        sh.child.resize(rows, cols);
    }

    /// Close the terminal showing in the active window.
    fn closeTerminal(self: *Editor) void {
        self.closeTerminalDoc(self.cur.doc);
    }

    /// Close one terminal. With others still open the pane stays and shows a
    /// sibling — closing the whole panel because one of several finished is
    /// not what a tab row implies. The last one takes the pane with it.
    fn closeTerminalDoc(self: *Editor, doc: *Doc) void {
        if (doc.shell == null) return;
        var sibling: ?*Doc = null;
        for (self.docs.items) |d| {
            if (d != doc and d.shell != null) sibling = d;
        }
        if (sibling) |next| {
            for (self.wins.items) |w| {
                if (w.doc == doc) w.doc = next;
            }
            if (self.d == doc) self.loadDoc(next);
            self.destroyDoc(doc);
            self.clearExtra();
            self.placeAt(0);
            return;
        }
        // The last terminal: the pane goes with it.
        const was_active = self.cur.doc == doc;
        if (!was_active) {
            for (self.wins.items) |w| {
                if (w.doc == doc) self.focusWin(w);
            }
        }
        self.mode = .normal;
        if (self.wins.items.len > 1) {
            self.closeWindow();
        } else {
            // The only window: leave a real buffer behind rather than nothing.
            const repl = self.makeEmptyDoc() orelse return;
            self.loadDoc(repl);
            self.cur.doc = repl;
        }
        for (self.wins.items) |w| {
            if (w.doc == doc) return; // still shown elsewhere: keep it alive
        }
        self.destroyDoc(doc);
        self.clearExtra();
        self.placeAt(self.cy);
    }

    /// Terminal mode: every key is the child's, except nvim's `Ctrl-\ Ctrl-n`
    /// which returns to normal mode without disturbing the shell.
    fn terminalKey(self: *Editor, k: key.Key, raw: []const u8) void {
        const sh = if (self.cur.doc.shell) |*s| s else {
            self.mode = .normal;
            return;
        };
        if (sh.done) return self.closeTerminal();
        // `Ctrl-\` is byte 0x1c, which `key.zig` does not decode as a ctrl
        // letter (its range stops at 0x1a), so the raw byte is what to match.
        // The same toggle closes it from inside, as in VS Code.
        if (k == .ctrl and k.ctrl == ' ') return self.toggleTerminal();
        const ctrl_backslash = raw.len == 1 and raw[0] == 0x1c;
        if (self.term_escape) {
            self.term_escape = false;
            if (k == .ctrl and k.ctrl == 'n') {
                self.mode = .normal;
                return self.setStatus("normal mode — i returns to the terminal", .{});
            }
            sh.child.write("\x1c"); // not the pair: the child gets its Ctrl-\
        }
        if (ctrl_backslash) {
            self.term_escape = true;
            return;
        }
        sh.child.write(termBytes(k, raw));
    }

    /// What a key looks like on the wire to a child process. Most keys are
    /// their own bytes; the special ones get the sequences a `TERM=xterm`
    /// program expects, which is what zedit tells the child it is.
    fn termBytes(k: key.Key, raw: []const u8) []const u8 {
        return switch (k) {
            .up => "\x1b[A",
            .down => "\x1b[B",
            .right => "\x1b[C",
            .left => "\x1b[D",
            .home => "\x1b[H",
            .end => "\x1b[F",
            .page_up => "\x1b[5~",
            .page_down => "\x1b[6~",
            .delete => "\x1b[3~",
            .backspace => "\x7f",
            .enter => "\r",
            .tab => "\t",
            .shift_tab => "\x1b[Z",
            .escape => "\x1b",
            else => raw, // text and control keys: their own bytes
        };
    }

    // === sessions ==========================================================

    /// `Space S s` / `:session save` — remember this directory's open files,
    /// their cursors, the split layout and whether the tree was open. Only
    /// file-backed documents go in: an unnamed buffer has nothing to reopen,
    /// and a diff snapshot is derived state that rebuilds itself.
    fn sessionSave(self: *Editor) void {
        const cwd = std.process.currentPathAlloc(self.io, self.gpa) catch
            return self.setStatus("cannot read the working directory", .{});
        defer self.gpa.free(cwd);
        self.saveViewport(); // the active window's cursor lives in the mirror

        var s = session.Session{
            .gpa = self.gpa,
            .windows = self.wins.items.len,
            .split_vertical = self.split_vertical,
            .sidebar = self.sb_open,
        };
        defer s.deinit();
        for (self.docs.items) |doc| {
            if (doc.diff_of != null) continue; // an index snapshot, not a file
            const path = doc.buf.path orelse continue;
            if (doc == self.d) s.active = s.entries.items.len;
            // A cursor belongs to a *window*, not to a document: take it from
            // the first window showing this one (saveViewport above put the
            // active window's back), and 0,0 for a buffer on screen nowhere.
            var cy: usize = 0;
            var cx: usize = 0;
            for (self.wins.items) |w| {
                if (w.doc != doc) continue;
                cy = w.cy;
                cx = w.cx;
                break;
            }
            const owned = self.gpa.dupe(u8, path) catch break;
            s.entries.append(self.gpa, .{ .path = owned, .line = cy, .col = cx }) catch {
                self.gpa.free(owned);
                break;
            };
        }
        if (s.entries.items.len == 0) return self.setStatus("nothing to save: no files open", .{});
        session.save(self.io, cwd, &s) catch |err|
            return self.setStatus("could not save the session: {s}", .{@errorName(err)});
        self.setStatus("session saved ({d} file{s})", .{
            s.entries.items.len,
            if (s.entries.items.len == 1) "" else "s",
        });
    }

    /// `Space S l` / `:session load` — reopen what was saved here. Refuses
    /// while anything is unsaved rather than closing over the user's work,
    /// and a file that has since disappeared is skipped, not fatal.
    fn sessionLoad(self: *Editor) void {
        const cwd = std.process.currentPathAlloc(self.io, self.gpa) catch
            return self.setStatus("cannot read the working directory", .{});
        defer self.gpa.free(cwd);
        for (self.docs.items) |doc| {
            if (doc.buf.dirty) return self.setStatus("no write since last change: {s}", .{docLabel(doc)});
        }
        var s = session.load(self.gpa, self.io, cwd) orelse
            return self.setStatus("no session saved for this directory", .{});
        defer s.deinit();

        self.onlyWindow(); // one window to open into; splits are remade below
        var opened: std.ArrayList(*Doc) = .empty;
        defer opened.deinit(self.gpa);
        var missing: usize = 0;
        var active: usize = 0; // index into `opened`
        for (s.entries.items, 0..) |entry, i| {
            if (std.Io.Dir.cwd().access(self.io, entry.path, .{})) |_| {} else |_| {
                missing += 1;
                continue;
            }
            self.openFile(entry.path, 0);
            if (i == s.active) active = opened.items.len; // its file may be gone
            opened.append(self.gpa, self.d) catch break;
        }
        if (opened.items.len == 0) return self.setStatus("session files are all gone", .{});
        if (active >= opened.items.len) active = 0;

        // Remake the splits, then give window i the i-th file — a two-pane
        // session comes back as two panes showing what it showed, not the
        // same buffer twice.
        var made: usize = 1;
        while (made < s.windows and made < opened.items.len) : (made += 1) self.splitWindow(s.split_vertical);
        if (self.wins.items.len > 1) self.split_vertical = s.split_vertical;
        for (self.wins.items, 0..) |w, i| w.doc = opened.items[@min(i, opened.items.len - 1)];

        // Focus the window holding the saved active file (the first one, when
        // there are fewer windows than files), and put its cursor back. Only
        // a *visible* file's cursor can be restored: the editor keeps a cursor
        // per window, not per buffer, so a buffer on screen nowhere has none.
        self.cur = self.wins.items[@min(active, self.wins.items.len - 1)];
        self.d = self.cur.doc; // loadDoc's precondition: swap from the right doc
        self.buf = &self.d.buf;
        self.loadDoc(opened.items[active]);
        self.cur.doc = opened.items[active];
        const entry = s.entries.items[@min(s.active, s.entries.items.len - 1)];
        self.cy = @min(entry.line, self.buf.lineCount() -| 1);
        self.cx = @min(entry.col, self.curLine().len);
        self.goal_col = self.cx;
        self.saveViewport();
        if (s.sidebar and !self.sb_open) self.sidebarToggle();
        self.sb_focus = false;
        self.clearExtra();
        self.placeAt(self.cy);
        self.prev_valid = false;
        const n = opened.items.len;
        if (missing > 0) {
            self.setStatus("session restored: {d} file{s}, {d} gone", .{ n, if (n == 1) "" else "s", missing });
        } else {
            self.setStatus("session restored ({d} file{s})", .{ n, if (n == 1) "" else "s" });
        }
    }

    /// `Space S d` / `:session delete` — forget this directory's session.
    fn sessionDelete(self: *Editor) void {
        const cwd = std.process.currentPathAlloc(self.io, self.gpa) catch
            return self.setStatus("cannot read the working directory", .{});
        defer self.gpa.free(cwd);
        if (session.delete(self.io, cwd)) {
            self.setStatus("session deleted", .{});
        } else {
            self.setStatus("no session saved for this directory", .{});
        }
    }

    /// `Space u …` — flip a boolean setting for this session and say so. The
    /// config file is not touched: a toggle is for the next five minutes, not
    /// for every session (edit the file for that).
    fn toggleSetting(self: *Editor, flag: *bool, name: []const u8) void {
        flag.* = !flag.*;
        self.prev_valid = false; // geometry may have changed (tabs, wrap)
        self.setStatus("{s}: {s}", .{ name, if (flag.*) "on" else "off" });
    }

    /// The mouse toggle also has to tell the terminal, since reporting is a
    /// mode we asked it to enter — turning it off hands the pointer back for
    /// the terminal's own text selection, which is why a user wants the key.
    fn toggleMouse(self: *Editor) void {
        const on = !config.settings.mouse;
        config.settings.mouse = on;
        self.term.write(if (on) term.ansi.enable_mouse else term.ansi.disable_mouse) catch {};
        self.setStatus("mouse reporting: {s}", .{if (on) "on" else "off"});
    }

    /// `Space b c` — AstroNvim's "close all buffers except this one". Refuses
    /// if any of them is unsaved, naming it, rather than discarding work.
    fn closeOthers(self: *Editor) void {
        const keep = self.d;
        var dirty: ?*Doc = null;
        for (self.docs.items) |doc| {
            if (doc != keep and doc.buf.dirty) dirty = doc;
        }
        if (dirty) |doc| return self.setStatus("no write since last change: {s}", .{docLabel(doc)});
        // Every window must point at `keep` before anything is freed — a
        // split still showing a victim would be a dangling doc pointer.
        for (self.wins.items) |w| {
            if (w.doc != keep) w.doc = keep;
        }
        var closed: usize = 0;
        while (true) {
            var victim: ?*Doc = null;
            for (self.docs.items) |doc| {
                if (doc != keep) victim = doc;
            }
            const v = victim orelse break;
            self.destroyDoc(v);
            closed += 1;
        }
        if (closed == 0) return self.setStatus("no other buffers", .{});
        self.clearExtra();
        self.placeAt(self.cy);
        self.setStatus("closed {d} buffer{s}", .{ closed, if (closed == 1) "" else "s" });
    }

    fn stopMacro(self: *Editor) void {
        // The closing 'q' was recorded by processInput; drop it.
        if (self.macro_buf.items.len > 0) self.macro_buf.items.len -= 1;
        const reg = self.recording.?;
        self.registers.set(reg, self.macro_buf.items, .charwise, 0) catch {};
        self.recording = null;
        self.setStatus("recorded @{c}", .{reg});
    }

    fn playMacro(self: *Editor, reg: u8, times: usize) !void {
        self.last_macro = reg; // what a later `@@` means
        const r = self.registers.get(reg) orelse return;
        // Copy: replaying may overwrite the register.
        const keys = self.gpa.dupe(u8, r.text) catch return;
        defer self.gpa.free(keys);
        var i: usize = 0;
        // A failed command aborts the rest of the replay *and* the remaining
        // repetitions — vim stops at the error rather than ploughing on
        // (nvim-verified: `qq` `jx` `q` on the last line replays the `j`,
        // which fails, and leaves the `x` unrun).
        while (i < times and !self.failed) : (i += 1) try self.replayBytes(keys);
    }

    fn repeatDot(self: *Editor) !void {
        if (self.dot_keys.items.len == 0) {
            self.resetPending();
            return;
        }
        // `[count].` *replaces* the original count rather than repeating the
        // whole change (nvim-verified: `3x` then `2.` removes five characters,
        // not nine), so a fresh count rewrites the recorded keys' leading one.
        // A leading `0` is the column motion, never a count. The count belongs
        // *after* a `"{reg}` prefix, which vim copies across untouched: writing
        // it in front instead would glue the two digit runs of `"a2dd` into one
        // and turn `3.` into `32dd`.
        // The recorded keys carry no count at all, so replaying is simply
        // "this many, then those keys": a new count replaces the recorded one
        // outright — including a count that was typed after the operator,
        // which the old byte-editing could not even see. The count goes
        // *after* a `"{reg}` prefix, which vim keeps.
        const count = if (self.count > 0) self.count else self.dot_count;
        var keys: std.ArrayList(u8) = .empty;
        defer keys.deinit(self.gpa);
        const recorded_keys: []const u8 = self.dot_keys.items;
        const head: usize = if (recorded_keys.len >= 2 and recorded_keys[0] == '"') 2 else 0;
        keys.appendSlice(self.gpa, recorded_keys[0..head]) catch return;
        if (count > 1) keys.print(self.gpa, "{d}", .{count}) catch return;
        keys.appendSlice(self.gpa, recorded_keys[head..]) catch return;
        const recorded: []const u8 = keys.items;
        self.resetPending();
        self.in_dot = true;
        defer self.in_dot = false;
        try self.replayBytes(recorded);
        // `.` is not itself a change: leaving `change_started` set would make
        // the capture below record "." as the last change, and every further
        // `.` would then only repeat itself.
        self.change_started = false;
    }

    // === cursor / counts helpers ==========================================

    fn cursor(self: *Editor) Pos {
        return .{ .row = self.cy, .col = self.cx };
    }

    fn curLine(self: *Editor) []const u8 {
        return self.buf.line(self.cy);
    }

    fn afterCursor(self: *Editor) Pos {
        const line = self.curLine();
        return .{ .row = self.cy, .col = if (self.cx < line.len) unicode.nextBoundary(line, self.cx) else self.cx };
    }

    fn setCursor(self: *Editor, p: Pos) void {
        self.cy = @min(p.row, self.buf.lineCount() - 1);
        const line = self.curLine();
        self.cx = @min(p.col, line.len);
        self.updateGoal();
    }

    fn snapColumn(self: *Editor) void {
        self.cx = byteAtDisplayCol(self.curLine(), self.goal_col);
    }

    fn updateGoal(self: *Editor) void {
        self.goal_col = displayCol(self.curLine(), self.cx);
    }

    /// Step `n` screen rows from buffer line `row`. `display` also counts the
    /// rows that belong to no buffer line — a diff pair's fillers and the line
    /// view's woven old lines — which is what a *viewport* step must do: with
    /// them uncounted, a notch travels a different distance every time it
    /// crosses a hunk, which is the jumping a scroll past a change shows.
    /// Cursor motions leave them out, keeping vim's line-based meaning.
    fn winStepRows(self: *Editor, w: *Win, row: usize, n: usize, up: bool, display: bool) usize {
        const last = w.doc.buf.lineCount() - 1;
        const virt: ?*const git.LineDiff = if (display) (if (w.doc.line_diff) |*x| x else null) else null;
        const pair = if (display) self.diffPairOf(w) else null;
        if (!self.winWrap(w) and virt == null and pair == null)
            return if (up) row -| n else @min(row + n, last);
        var r = row;
        var used: usize = 0;
        while (used < n) {
            if (up) {
                if (r == 0) break;
                r -= 1;
            } else {
                if (r >= last) break;
                r += 1;
            }
            used += self.winRowsForLine(w, r, virt, pair);
        }
        return r;
    }

    /// Screen rows buffer line `row` is worth in this window: its own wrapped
    /// rows plus the virtual rows drawn immediately above it (woven old lines,
    /// or a diff pair's fillers), which the renderer emits before the line.
    fn winRowsForLine(self: *Editor, w: *Win, row: usize, virt: ?*const git.LineDiff, pair: ?DiffPair) usize {
        var rows = self.winLineRows(w, row);
        if (virt) |x| rows += x.above(row).len;
        if (pair) |p| {
            // The gap between this line's display row and the previous line's
            // is the fillers the alignment inserts between them.
            const new_side = w.doc.diff_of == null;
            const here = git.displayRow(p.hunks, new_side, row);
            const prev = git.displayRow(p.hunks, new_side, row -| 1);
            if (row > 0 and here > prev) rows += here - prev - 1;
        }
        return rows;
    }

    /// The buffer line `n` screen rows away, for the paging motions. With soft
    /// wrap a tall line is worth several rows, so a page covers fewer lines
    /// than there are rows on screen — which is what makes `Ctrl-f` land where
    /// it looks like it should.
    ///
    /// `display = true`, so a diff pair's filler rows and the line view's woven
    /// rows count too: they are on screen, and a half-page that ignored them
    /// travelled a different distance depending on whether it crossed a hunk —
    /// the jumping a scroll past a change shows. The wheel was fixed for this
    /// in 0.28.0 and the paging keys were left behind.
    fn lineAfterRows(self: *Editor, row: usize, n: usize, up: bool) usize {
        return self.winStepRows(self.cur, row, n, up, true);
    }

    fn pageMove(self: *Editor, up: bool) void {
        self.cy = self.lineAfterRows(self.cy, self.textRows(), up);
        self.snapColumn();
        self.resetPending();
    }

    /// The count a command should act on: the one typed before the operator
    /// times the one typed after it, which is vim's rule (`2d3j` is six lines
    /// below the cursor, not two or three). Outside operator-pending mode
    /// `count2` is always 0, so this is just the leading count.
    ///
    /// There used to be a second helper returning only `count`, and the char
    /// motions used it — so `d3j` deleted two lines where vim deletes four,
    /// while `d2fa` (which went through the other one) was right. One
    /// function now, because two spellings of "the count" is exactly how they
    /// drifted apart.
    fn eff(self: *Editor) usize {
        const a = if (self.count == 0) 1 else self.count;
        const b = if (self.count2 == 0) 1 else self.count2;
        return a * b;
    }

    fn resetPending(self: *Editor) void {
        self.count = 0;
        self.count2 = 0;
        self.operator = .none;
        self.await_arg = .none;
        self.pending_register = null;
    }

    /// Keep the cursor in bounds. In the buffer-command modes vim never lets it
    /// sit past the last character (so `$` lands ON it and `x`/`dh`/`d{` after
    /// `$` act on the right character — nvim-verified); insert mode and the
    /// prompts legitimately use the one-past-end column.
    fn clampCursor(self: *Editor) void {
        if (self.cy >= self.buf.lineCount()) self.cy = self.buf.lineCount() - 1;
        const limit = self.columnLimit(self.curLine());
        if (self.cx > limit) self.cx = limit;
    }

    /// The furthest column the cursor may sit at on `line` in the current mode.
    fn columnLimit(self: *Editor, line: []const u8) usize {
        return switch (self.mode) {
            .normal, .visual, .visual_line => lastColumn(line),
            // Blockwise visual reaches one column past the last character, so
            // a block can be built one wider than the short line under it and
            // `$` can mean "past every line's end" (nvim-verified).
            // Replace mode reaches one past the last character too: typing
            // there appends rather than overwriting.
            .visual_block, .insert, .replace, .command, .picker, .terminal => line.len,
        };
    }

    // === viewport ==========================================================

    // Viewport metrics refer to the active window (set by the last layout).
    fn textRows(self: *Editor) usize {
        return self.winTextRows(self.cur);
    }

    fn textCols(self: *Editor) usize {
        return winTextCols(self.cur);
    }

    /// Columns of `w` left for text once its gutter is taken off. Per window:
    /// the gutter is sized from that window's own line count, so two splits
    /// over files of different lengths have different text widths.
    fn winTextCols(w: *Win) usize {
        const g = gutterFor(w.doc.buf.lineCount());
        return if (w.gw > g) w.gw - g else 1;
    }

    fn gutterWidth(self: *Editor) usize {
        return gutterFor(self.buf.lineCount());
    }

    /// Soft-wrap: a line too long for the window continues on the next screen
    /// row instead of scrolling the view sideways (vim's `wrap`). The top of a
    /// window is always the start of a buffer line, which is also nvim's
    /// default — partial scrolling of a tall line is its `smoothscroll`.
    fn wrapping(self: *Editor) bool {
        return self.winWrap(self.cur);
    }

    /// The most screen rows one buffer line may occupy. Bounds the layout scan
    /// so a minified file costs O(screen), and bounds the stack array below.
    const max_wrap_rows = 256;

    /// How a line is spread over screen rows: the display column each row
    /// starts at, and the indent drawn in front of every continuation row so a
    /// wrapped line stays under its own first character (vim's `breakindent`).
    /// A row is broken at the last space that fits rather than mid-word, unless
    /// a single word is longer than the row.
    const WrapLayout = struct {
        starts: [max_wrap_rows]u32,
        n: usize,
        indent: usize,

        /// The screen row of a display column, and the column within it.
        fn place(self: WrapLayout, dcol: usize) struct { seg: usize, col: usize } {
            var seg: usize = 0;
            while (seg + 1 < self.n and self.starts[seg + 1] <= dcol) seg += 1;
            return .{ .seg = seg, .col = dcol - self.starts[seg] + self.pad(seg) };
        }

        /// Cells of indent in front of row `seg` (never the first).
        fn pad(self: WrapLayout, seg: usize) usize {
            return if (seg == 0) 0 else self.indent;
        }
    };

    /// Lay out `line` for a window `cols` wide. `cur_col` is the cursor's
    /// display column when it is on this line: at a wrap boundary the caret
    /// needs a continuation row of its own to sit on, as it does in vim while
    /// you type past the edge.
    fn layoutLine(line: []const u8, cols: usize, cur_col: ?usize, wrap: bool, cap_rows: usize) WrapLayout {
        var out: WrapLayout = .{ .starts = undefined, .n = 1, .indent = 0 };
        out.starts[0] = 0;
        if (!wrap or cols < 4) return out;
        const cap = @min(@max(cap_rows, 1), max_wrap_rows);

        // Wrap at the configured column when it is narrower than the window.
        const limit = if (config.settings.wrap_column > 0) @min(config.settings.wrap_column, cols) else cols;
        var width = displayWidthUpTo(line, cap * limit);
        if (cur_col) |cc| width = @max(width, cc + 1);
        if (width <= limit) return out;

        if (config.settings.wrap_indent) {
            const first = motion.firstNonBlank(line);
            // A line that is all indent has nothing to hang under, and an
            // indent past half the window would leave no room for text.
            if (first < line.len) out.indent = @min(displayCol(line, first), limit / 2);
        }

        var start: usize = 0;
        while (out.n < cap) {
            const avail = limit - out.pad(out.n); // rows after the first are narrower
            const hard = start + avail;
            if (hard >= width) break;
            const brk = lastBreakBefore(line, start, hard);
            out.starts[out.n] = @intCast(brk);
            out.n += 1;
            start = brk;
        }
        return out;
    }

    /// The display column to break at: just after the last space in
    /// `(from, upto]`, or `upto` when a single word fills the row.
    fn lastBreakBefore(line: []const u8, from: usize, upto: usize) usize {
        const start_byte = byteAtDisplayCol(line, from);
        var i = byteAtDisplayCol(line, upto);
        while (i > start_byte) {
            i -= 1;
            if (line[i] != ' ' and line[i] != '\t') continue;
            const after = displayCol(line, i + 1);
            if (after > from and after <= upto) return after;
            break; // the space is at or before this row's start: no usable one
        }
        return upto; // one word wider than the row: break it
    }

    /// The layout of buffer line `row` in window `w`. Only the active window
    /// knows where the cursor is (the Editor mirrors its viewport), so only it
    /// gives the caret a continuation row of its own — the same split
    /// `buildView`/`nextRow` make when they render an inactive window.
    fn winLineLayout(self: *Editor, w: *Win, row: usize) WrapLayout {
        if (row >= w.doc.buf.lineCount()) return .{ .starts = .{0} ** max_wrap_rows, .n = 1, .indent = 0 };
        const active = w == self.cur;
        return layoutLine(
            w.doc.buf.line(row),
            winTextCols(w),
            if (active and row == self.cy) self.cursorDisplayCol() else null,
            self.winWrap(w),
            @max(1, self.winTextRows(w)),
        );
    }

    /// Rows window `w` spends on buffer line `row`.
    fn winLineRows(self: *Editor, w: *Win, row: usize) usize {
        if (!self.winWrap(w)) return 1;
        return self.winLineLayout(w, row).n;
    }

    fn lineLayout(self: *Editor, row: usize) WrapLayout {
        return self.winLineLayout(self.cur, row);
    }

    fn lineRows(self: *Editor, row: usize) usize {
        return self.winLineRows(self.cur, row);
    }

    fn cursorDisplayCol(self: *Editor) usize {
        return displayCol(self.curLine(), self.cx) + self.inlayCols(self.cy, self.cx);
    }

    /// Which wrapped segment of its own line the cursor sits on.
    fn cursorSeg(self: *Editor) usize {
        if (!self.wrapping()) return 0;
        return self.lineLayout(self.cy).place(self.cursorDisplayCol()).seg;
    }

    /// The highest viewport top that still shows segment `seg` of line `row`,
    /// given `rows` of space. Walks up from the cursor rather than down from
    /// the current top, so a jump across a huge file costs O(rows), not
    /// O(distance).
    fn topShowing(self: *Editor, row: usize, seg: usize, rows: usize) usize {
        var used = seg + 1;
        var t = row;
        while (t > 0) {
            const h = self.lineRows(t - 1);
            if (used + h > rows) break;
            used += h;
            t -= 1;
        }
        return t;
    }

    /// The buffer line displayed `n` screen rows below the top of the window
    /// (clamped to the last line) — what `H`, `M` and `L` count in.
    fn lineAtScreenRow(self: *Editor, n: usize) usize {
        const last = self.buf.lineCount() - 1;
        if (self.diffPairOf(self.cur)) |p| { // skip over this pane's filler rows
            const new_side = self.cur == p.wt;
            const dtop = self.diffDisplayTop(p);
            return @min(git.rowAtOrAfter(p.hunks, new_side, dtop + n), last);
        }
        if (self.d.line_diff) |*ld| { // a row in a woven block counts for the line below it
            var used: usize = if (self.top == 0) ld.above(0).len - self.ldLeadingSkip(ld) else 0;
            var row = self.top;
            while (true) {
                if (used > n) return row; // n landed in the block above `row`
                const rows = self.lineRows(row);
                if (used + rows > n) return row;
                used += rows;
                if (row >= last) return last;
                row += 1;
                used += ld.above(row).len;
            }
        }
        if (!self.wrapping()) return @min(self.top + n, last);
        var row = self.top;
        var used: usize = 0;
        while (row < last) {
            const h = self.lineRows(row);
            if (used + h > n) break;
            used += h;
            row += 1;
        }
        return row;
    }

    /// Screen rows from the top of the window to the cursor.
    fn cursorScreenRow(self: *Editor) usize {
        if (self.diffPairOf(self.cur)) |p| { // count the pane's filler rows too
            const new_side = self.cur == p.wt;
            return git.displayRow(p.hunks, new_side, self.cy) -| self.diffDisplayTop(p);
        }
        // The line-diff view weaves virtual rows above lines; every one
        // between the top and the cursor pushes the cursor down a row.
        var woven: usize = 0;
        if (self.d.line_diff) |*ld| {
            var r = self.top;
            while (r < self.cy) : (r += 1) woven += ld.above(r + 1).len;
            if (self.top == 0) woven += ld.above(0).len - self.ldLeadingSkip(ld);
        }
        if (!self.wrapping()) return self.cy -| self.top + woven;
        var used: usize = 0;
        var row = self.top;
        while (row < self.cy) : (row += 1) used += self.lineRows(row);
        return used + self.cursorSeg() + woven;
    }

    /// Rows of a leading woven block (old lines above buffer row 0) hidden
    /// so the cursor stays on screen — the line-diff view's analogue of
    /// `paneDisplayTop`'s clamp. Zero unless the top is row 0. Active
    /// window only: an inactive window shows the block from its start.
    fn ldLeadingSkip(self: *Editor, ld: *const git.LineDiff) usize {
        if (self.top != 0) return 0;
        const gap = ld.above(0).len;
        if (gap == 0) return 0;
        // The cursor's screen row with the whole block shown.
        var csr: usize = gap;
        var r: usize = 0;
        while (r < self.cy) : (r += 1) csr += self.lineRows(r) + ld.above(r + 1).len;
        csr += self.cursorSeg();
        return @min(gap, csr -| (self.textRows() -| 1));
    }

    /// The cursor's column within the window's text area.
    fn cursorScreenCol(self: *Editor) usize {
        const cur = self.cursorDisplayCol();
        if (!self.wrapping()) return cur -| self.left;
        return self.lineLayout(self.cy).place(cur).col;
    }

    /// Keep the cursor visible. Vim's rule (nvim-verified): a move that lands
    /// within half a window of the edge scrolls just far enough, but a longer
    /// jump redraws with the cursor *centred* — so after `100G` the cursor sits
    /// mid-screen, not glued to the bottom row where every wheel notch would
    /// drag it along.
    fn scroll(self: *Editor) void {
        if (self.diffPairOf(self.cur)) |p| return self.scrollDiffPane(p);
        if (self.wrapping()) self.scrollWrapped() else self.scrollFlat();
        // The line-diff view's woven rows sit between the top and the
        // cursor, so the flat/wrapped rules above can leave the cursor's
        // *visual* row past the window: nudge the top down until it fits.
        // (A block above row 0 clamps via ldLeadingSkip instead — there is
        // no top above row 0 to give back.)
        if (self.d.line_diff != null) {
            const rows = self.textRows();
            while (self.top < self.cy and self.cursorScreenRow() >= rows) self.top += 1;
        }
    }

    fn scrollFlat(self: *Editor) void {
        const rows = self.textRows();
        const half = rows / 2;
        if (self.cy < self.top) {
            self.top = if (self.top - self.cy > half) self.centredTop(rows) else self.cy;
        } else if (self.cy >= self.top + rows) {
            const bot = self.top + rows - 1;
            self.top = if (self.cy - bot > half) self.centredTop(rows) else self.cy - rows + 1;
        }
        self.scrollHorizontal();
    }

    /// The same rule counted in aligned display rows: a diff pane's screen
    /// rows include its partner's filler rows, so keeping the cursor visible
    /// means keeping its *display* row inside the window.
    fn scrollDiffPane(self: *Editor, p: DiffPair) void {
        const new_side = self.cur == p.wt;
        const rows = self.textRows();
        const half = rows / 2;
        const dcy = git.displayRow(p.hunks, new_side, self.cy);
        const dtop = self.diffDisplayTop(p);
        if (dcy < dtop) {
            const want = if (dtop - dcy > half) dcy -| (rows -| 1) / 2 else dcy;
            self.top = git.rowAtOrAfter(p.hunks, new_side, want);
        } else if (dcy >= dtop + rows) {
            const bot = dtop + rows - 1;
            const want = if (dcy - bot > half) dcy -| (rows -| 1) / 2 else dcy - rows + 1;
            self.top = git.rowAtOrAfter(p.hunks, new_side, want);
        }
        self.scrollHorizontal();
    }

    fn scrollHorizontal(self: *Editor) void {
        const cols = self.textCols();
        const cur = displayCol(self.curLine(), self.cx) + self.inlayCols(self.cy, self.cx);
        if (cur < self.left) self.left = cur;
        if (cur >= self.left + cols) self.left = cur - cols + 1;
    }

    /// The same rule counted in screen rows: with wrap there is no horizontal
    /// scrolling, and one buffer line can be worth many rows.
    fn scrollWrapped(self: *Editor) void {
        self.left = 0;
        const rows = self.textRows();
        const seg = self.cursorSeg();
        if (self.cy < self.top) {
            self.top = if (self.top - self.cy > rows / 2) self.topShowing(self.cy, seg, (rows + 1) / 2) else self.cy;
            return;
        }
        const min_top = self.topShowing(self.cy, seg, rows);
        if (self.top < min_top)
            self.top = if (min_top - self.top > rows / 2) self.topShowing(self.cy, seg, (rows + 1) / 2) else min_top;
    }

    /// The viewport top that centres the cursor line: nvim keeps
    /// `(rows-1)/2` lines above it, clamped at the start of the buffer.
    fn centredTop(self: *Editor, rows: usize) usize {
        return self.cy -| (rows -| 1) / 2;
    }

    /// The cursor to this line's first non-blank — what `z<CR>`, `z.` and
    /// `z-` add over `zt`, `zz` and `zb`.
    fn toFirstNonBlank(self: *Editor) void {
        self.cx = motion.firstNonBlank(self.curLine());
        self.updateGoal();
    }

    /// The last buffer line the window is showing, for `z+`.
    fn bottomLine(self: *Editor) usize {
        return self.lineAtScreenRow(self.textRows() - 1);
    }

    /// `zh`/`zl` (N columns), `zH`/`zL` (half a screen) and `z<Left>`/
    /// `z<Right>`. Horizontal scrolling only exists with soft wrap off, which
    /// is exactly what vim documents these as needing; with wrap on they do
    /// nothing, as there is nowhere sideways to go.
    fn scrollSideways(self: *Editor, right: bool, n: usize) void {
        if (self.wrapping()) return;
        const cols = self.textCols();
        if (right) self.left += n else self.left -|= n;
        // The cursor follows only as far as it must to stay on screen, which
        // is what leaves it put when the scroll was small (nvim-probed).
        const cur = displayCol(self.curLine(), self.cx);
        if (cur < self.left)
            self.cx = byteAtDisplayCol(self.curLine(), self.left)
        else if (cur >= self.left + cols)
            self.cx = byteAtDisplayCol(self.curLine(), self.left + cols - 1);
        self.updateGoal();
    }

    /// `zs` / `ze`: scroll so the cursor sits at the left or right edge.
    fn scrollCursorTo(self: *Editor, start: bool) void {
        if (self.wrapping()) return;
        const cur = displayCol(self.curLine(), self.cx);
        self.left = if (start) cur else cur -| (self.textCols() - 1);
    }

    /// `zz`/`zt`/`zb` — put the cursor's line at the centre, the top or the
    /// bottom of the window. nvim's arithmetic, pty-probed against a 22-row
    /// window: `zt` tops at the cursor line, `zz` keeps `(rows-1)/2` lines
    /// above it (which is `centredTop`, the rule a long jump already uses)
    /// and `zb` keeps `rows-1`. All three clamp at the *start* of the buffer
    /// and none clamps at the end, so `zt` near EOF deliberately leaves a
    /// screen of `~` rows — vim scrolls past the last line for these.
    ///
    /// Counted the way every other viewport move is counted: display rows
    /// inside a diff pair (the partner's filler rows are rows too), screen
    /// rows under soft wrap, buffer lines otherwise. `scroll` cannot fight
    /// any of the three, since each leaves the cursor inside the window.
    fn positionView(self: *Editor, where: enum { top, centre, bottom }) void {
        const rows = self.textRows();
        if (self.diffPairOf(self.cur)) |p| {
            const side = self.cur == p.wt;
            const d = git.displayRow(p.hunks, side, self.cy);
            self.top = git.rowAtOrAfter(p.hunks, side, switch (where) {
                .top => d,
                .centre => d -| (rows -| 1) / 2,
                .bottom => d -| (rows -| 1),
            });
        } else if (self.wrapping()) {
            const seg = self.cursorSeg();
            self.top = switch (where) {
                .top => self.cy,
                // `topShowing(.., n)` is the highest top that still fits the
                // cursor's segment in `n` rows — so a full window puts it on
                // the last row, and half a window puts it in the middle.
                .centre => self.topShowing(self.cy, seg, (rows + 1) / 2),
                .bottom => self.topShowing(self.cy, seg, rows),
            };
        } else {
            self.top = switch (where) {
                .top => self.cy,
                .centre => self.centredTop(rows),
                .bottom => self.cy -| (rows -| 1),
            };
        }
    }

    // === git diff views ====================================================

    /// `Space g d` / `:diff`: the current file's unified diff (worktree vs
    /// index) in a horizontal split, highlighted by the `.diff` lexer.
    /// Pressed again — for the same file, or inside the diff itself — it
    /// closes the view (split and scratch both).
    fn gitDiffInline(self: *Editor) void {
        const path = self.buf.path orelse {
            // Inside the inline diff scratch itself: toggle it closed.
            if (self.d.name) |n| if (std.mem.startsWith(u8, n, "[diff] ")) {
                for (self.docs.items) |doc| {
                    if (doc != self.d) return self.closeDiffScratch(self.d, doc);
                }
            };
            return self.setStatus("no file to diff", .{});
        };
        var nb: [300]u8 = undefined;
        const label = std.fmt.bufPrint(&nb, "[diff] {s}", .{std.fs.path.basename(path)}) catch "[diff]";
        for (self.docs.items) |doc| { // toggle: this file's diff is already open
            if (doc.buf.path == null and doc.name != null and std.mem.eql(u8, doc.name.?, label)) {
                // Only a *visible* diff toggles closed. A scratch left with no
                // window (`:bn` moved the window off it) is stale: destroy it
                // and fall through to reopen — not a phantom "diff closed"
                // that changes nothing on screen.
                for (self.wins.items) |w| {
                    if (w.doc == doc) return self.closeDiffScratch(doc, self.d);
                }
                self.destroyDoc(doc);
                break;
            }
        }
        // The three diff views are exclusive per file: opening one closes
        // the others first, so they can never stack into a third window,
        // and the split starts from the pre-diff layout with the
        // orientation this view sets.
        self.clearLineDiff(self.d);
        for (self.docs.items) |doc| {
            if (doc.diff_of == self.d) {
                self.closeDiffScratch(doc, self.d);
                self.setStatus("", .{}); // the open below replaces it, not a close
                break;
            }
        }
        const res = std.process.run(self.gpa, self.io, .{
            .argv = &.{ "git", "diff", "--no-color", "--", path },
            .stdout_limit = .limited(8 << 20),
            .stderr_limit = .limited(64 << 10),
        }) catch return self.setStatus("git not available", .{});
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);
        switch (res.term) {
            .exited => |code| if (code != 0) return self.setStatus("not a git repository", .{}),
            else => return,
        }
        if (std.mem.trim(u8, res.stdout, " \t\r\n").len == 0) return self.setStatus("no changes", .{});
        self.openScratch(label, res.stdout, .diff, false);
    }

    /// `Space g s` / `:vdiff`: the file's index (staged) version side by side
    /// with the working copy — the same base the gutter signs compare against.
    /// Focus stays on the worktree pane (the file you edit); the index pane is
    /// a read-only snapshot. Pressed again — from either pane — it closes the
    /// view. The panes are row-aligned through the diff's hunks (see
    /// `renderWindow`) and scroll in lockstep.
    fn gitDiffSide(self: *Editor) void {
        // Toggle: this file's pair is already open — close it instead, from
        // whichever side. Like the inline toggle, only a *visible* snapshot
        // counts: one left windowless (`:bn`/`:close` moved its window away)
        // is stale — destroy it and fall through to reopen, not a phantom
        // "diff closed" that changes nothing on screen.
        if (self.d.diff_of) |wt| return self.closeDiffScratch(self.d, wt);
        for (self.docs.items) |doc| {
            if (doc.diff_of == self.d) {
                for (self.wins.items) |w| {
                    if (w.doc == doc) return self.closeDiffScratch(doc, self.d);
                }
                self.destroyDoc(doc);
                break;
            }
        }
        const path = self.buf.path orelse return self.setStatus("no file to diff", .{});
        // The three diff views are exclusive per file (see gitDiffInline):
        // an open inline diff or line-diff weave closes before the pair
        // opens, so the vertical split starts from the pre-diff layout.
        self.clearLineDiff(self.d);
        var db: [300]u8 = undefined;
        const dlabel = std.fmt.bufPrint(&db, "[diff] {s}", .{std.fs.path.basename(path)}) catch "[diff]";
        for (self.docs.items) |doc| {
            if (doc.buf.path == null and doc.name != null and std.mem.eql(u8, doc.name.?, dlabel)) {
                self.closeDiffScratch(doc, self.d);
                self.setStatus("", .{}); // the open below replaces it, not a close
                break;
            }
        }
        var sb: [300]u8 = undefined;
        const spec = std.fmt.bufPrint(&sb, ":./{s}", .{path}) catch return;
        const res = std.process.run(self.gpa, self.io, .{
            .argv = &.{ "git", "show", spec },
            .stdout_limit = .limited(8 << 20),
            .stderr_limit = .limited(64 << 10),
        }) catch return self.setStatus("git not available", .{});
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);
        switch (res.term) {
            .exited => |code| if (code != 0) return self.setStatus("file is not tracked by git", .{}),
            else => return,
        }
        // One `git diff` feeds the row alignment and both panes' tint rows.
        const hunks = git.computeHunks(self.gpa, self.io, path);
        if (hunks.len == 0) {
            self.gpa.free(hunks);
            return self.setStatus("no changes", .{});
        }
        var nb: [300]u8 = undefined;
        const label = std.fmt.bufPrint(&nb, "{s} (index)", .{std.fs.path.basename(path)}) catch "(index)";
        const wt = self.d; // the worktree document being compared
        const wt_win = self.cur;
        self.openScratch(label, res.stdout, syntax.detect(path), true);
        if (self.d == wt) { // scratch failed to open
            self.gpa.free(hunks);
            return;
        }
        self.d.diff_of = wt;
        self.d.diff_hunks = hunks;
        // Old-side change rows tint the index pane; the worktree pane reuses
        // its normal gutter signs (same hunks, new side).
        git.signsFromHunks(hunks, false, &self.git_signs);
        self.focusWin(wt_win); // the worktree pane is the one you edit
        // focusWin's pair-crossing remap mapped the cursor from the fresh
        // scratch (row 0) — put it back where the user actually was: opening
        // the view must not move their place in the file.
        self.cy = wt_win.cy;
        self.cx = wt_win.cx;
        self.goal_col = wt_win.goal_col;
    }

    /// `Space g l` / `:ldiff`: the line-by-line diff VS Code and Zed show —
    /// the old (deleted / changed-from) lines woven into the file's own
    /// window as red-tinted virtual rows above the lines that replaced
    /// them, while added/changed lines keep their tint on the real rows. No
    /// split, no scratch, no second buffer: a rendering mode of the window,
    /// and the file stays fully editable. Pressed again it toggles the
    /// weave off. Like the gutter signs, the woven rows reflect the file as
    /// last saved and refresh on `:w`.
    fn gitDiffLine(self: *Editor) void {
        if (self.d.line_diff != null) {
            self.clearLineDiff(self.d);
            return self.setStatus("diff closed", .{});
        }
        const path = self.buf.path orelse return self.setStatus("no file to diff", .{});
        if (self.isLargeFile()) return self.setStatus("file too large to diff", .{});
        // The three diff views are exclusive per file: opening this one
        // closes the side-by-side pair and the unified-diff scratch first.
        for (self.docs.items) |doc| {
            if (doc.diff_of == self.d) {
                self.closeDiffScratch(doc, self.d);
                break;
            }
        }
        var nb: [300]u8 = undefined;
        const label = std.fmt.bufPrint(&nb, "[diff] {s}", .{std.fs.path.basename(path)}) catch "[diff]";
        for (self.docs.items) |doc| {
            if (doc.buf.path == null and doc.name != null and std.mem.eql(u8, doc.name.?, label)) {
                self.closeDiffScratch(doc, self.d);
                break;
            }
        }
        self.setStatus("", .{}); // an exclusivity close above said "diff closed"
        self.d.line_diff = git.computeLineDiff(self.gpa, self.io, path) orelse
            return self.setStatus("no changes", .{});
    }

    /// Drop `doc`'s line-diff weave: the toggle's off half, the other diff
    /// views' exclusivity, and the refresh-on-save recompute.
    fn clearLineDiff(self: *Editor, doc: *Doc) void {
        if (doc.line_diff) |*ld| {
            ld.deinit(self.gpa);
            doc.line_diff = null;
        }
    }

    /// The toggle's close half: remove every window showing a diff scratch
    /// *and* destroy the scratch document — the two halves `:close` and
    /// `Space c` each do alone. `wt` is what a window that cannot be removed
    /// (the last one) shows instead.
    fn closeDiffScratch(self: *Editor, scratch: *Doc, wt: *Doc) void {
        var i: usize = 0;
        while (i < self.wins.items.len) {
            const w = self.wins.items[i];
            if (w.doc != scratch) {
                i += 1;
                continue;
            }
            if (self.wins.items.len == 1) { // the only window: show the file instead
                self.focusWin(w);
                self.focusDoc(wt);
                break;
            }
            _ = self.wins.orderedRemove(i);
            if (self.cur == w) {
                const target = self.wins.items[if (i < self.wins.items.len) i else i - 1];
                self.cur = target;
                self.loadDoc(target.doc);
                self.loadViewport();
            }
            self.gpa.destroy(w);
        }
        if (self.d == scratch) self.focusDoc(wt);
        self.destroyDoc(scratch);
        self.clearExtra();
        self.clampCursor();
        self.setStatus("diff closed", .{});
    }

    /// Open `content` as a named scratch document in a new split (vertical or
    /// horizontal). Scratch docs have no path and are read-only: both diff
    /// views are reports of repository state, and an editable copy could only
    /// dirty into a `:q`-blocking orphan (`rejectReadOnly` — the index
    /// snapshot's `diff_of` check answers first with its own message).
    /// A registered, read-only document holding `content`. The caller decides
    /// where it is shown: the diff and quickfix views split, the multibuffer
    /// takes the window it was opened from (it is edited, and a half window
    /// is a poor place to refactor in).
    fn makeScratchDoc(self: *Editor, label: []const u8, content: []const u8, lang: syntax.Language) ?*Doc {
        const nb = buffer.Buffer.fromBytes(self.gpa, content) catch return null;
        const doc = makeDoc(self.gpa, nb) catch {
            var b = nb;
            b.deinit();
            return null;
        };
        doc.lang = lang;
        doc.read_only = true;
        doc.name = self.gpa.dupe(u8, label) catch null;
        self.docs.append(self.gpa, doc) catch {
            self.freeDoc(doc);
            return null;
        };
        return doc;
    }

    fn openScratch(self: *Editor, label: []const u8, content: []const u8, lang: syntax.Language, vert: bool) void {
        const doc = self.makeScratchDoc(label, content, lang) orelse return;
        self.splitWindow(vert);
        self.focusDoc(doc);
        self.clearExtra();
        self.placeAt(0);
    }

    // === the multibuffer ===================================================

    /// How many lines of a file show around each hit, and how many excerpts
    /// one multibuffer will build. The cap bounds what a 10,000-hit grep can
    /// make the editor assemble; what it drops is reported, never silent.
    const mb_context = 2;
    const mb_cap = 200;
    /// The row that opens an excerpt. Written out and compared byte for byte,
    /// so a body line would have to *be* one of these to be mistaken for one —
    /// and even then the count would not match and the write would refuse.
    const mb_marker = "\u{2500}\u{2500} ";

    /// `:cedit` / `Space x e` — the quickfix list as one editable buffer.
    ///
    /// Zed's multibuffer: every hit's surroundings stitched together, edited
    /// in one place, and `:w` writing every file it touched. It is the
    /// editable rendering of a list zedit already keeps, which is why it is
    /// this small.
    fn openMultibuffer(self: *Editor) void {
        if (self.qf.len() == 0)
            return self.setStatus("quickfix list is empty (Ctrl-q in a picker)", .{});
        for (self.wins.items) |w| { // already up: focus it rather than stacking
            if (w.doc.mb != null) {
                self.focusWin(w);
                return;
            }
        }
        const cwd = std.process.currentPathAlloc(self.io, self.gpa) catch
            return self.setStatus("cannot read the working directory", .{});
        defer self.gpa.free(cwd);

        var hits: std.ArrayList(multi.Hit) = .empty;
        defer hits.deinit(self.gpa);
        for (self.qf.entries.items) |e|
            hits.append(self.gpa, .{ .path = e.path, .line = e.line - 1 }) catch break;
        const spans = multi.spans(self.gpa, hits.items, mb_context, mb_cap) catch
            return self.setStatus("out of memory building the multibuffer", .{});
        defer self.gpa.free(spans);

        var mb: Multi = .{};
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        var skipped: usize = 0;
        for (spans) |sp| {
            const abs = self.absPath(cwd, sp.path) orelse continue;
            defer self.gpa.free(abs);
            const doc = self.docForPath(cwd, abs) orelse {
                skipped += 1;
                continue;
            };
            const last = doc.buf.lineCount() - 1;
            if (sp.start > last) {
                skipped += 1;
                continue;
            }
            const end = @min(sp.end, last);
            const body = self.linesOf(&doc.buf, sp.start, end - sp.start + 1) orelse {
                skipped += 1;
                continue;
            };
            defer self.gpa.free(body);
            const rel = self.cwdRelative(sp.path) orelse sp.path;
            const header = std.fmt.allocPrint(self.gpa, "{s}{s}:{d}", .{ mb_marker, rel, sp.start + 1 }) catch break;
            mb.excerpts.append(self.gpa, .{
                .path = self.gpa.dupe(u8, sp.path) catch break,
                .header = header,
                .start = sp.start,
                .len = end - sp.start + 1,
                .orig = self.gpa.dupe(u8, body) catch break,
            }) catch break;
            text.appendSlice(self.gpa, header) catch break;
            text.append(self.gpa, '\n') catch break;
            text.appendSlice(self.gpa, body) catch break;
            text.append(self.gpa, '\n') catch break;
        }
        if (mb.excerpts.items.len == 0) {
            mb.deinit(self.gpa);
            return self.setStatus("nothing to edit — no listed file could be read", .{});
        }

        var label: [128]u8 = undefined;
        const name = std.fmt.bufPrint(&label, "[multibuffer] {s}", .{self.qf.title.items}) catch "[multibuffer]";
        const doc = self.makeScratchDoc(name, text.items, .none) orelse {
            mb.deinit(self.gpa);
            return;
        };
        doc.read_only = false; // the whole point: it is edited
        doc.mb = mb;
        self.focusDoc(doc);
        self.clearExtra();
        self.placeAt(0);
        const dropped = self.qf.len() -| spans.len;
        if (skipped > 0 or dropped > 0) {
            self.setStatus("{d} excerpts ({d} unreadable, {d} past the {d}-excerpt cap) — :w writes them all", .{ mb.excerpts.items.len, skipped, dropped, mb_cap });
        } else {
            self.setStatus("{d} excerpts from the list — edit here, :w writes every file", .{mb.excerpts.items.len});
        }
    }

    /// `path` made absolute against `cwd`, which is what `docForPath` wants
    /// and what a quickfix entry (relative, from the project walk) is not.
    fn absPath(self: *Editor, cwd: []const u8, path: []const u8) ?[]u8 {
        if (path.len > 0 and path[0] == '/') return self.gpa.dupe(u8, path) catch null;
        return std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ cwd, path }) catch null;
    }

    /// `:w` on a multibuffer — put every excerpt back where it came from and
    /// write those files. One save for the whole refactor, which is the
    /// feature.
    ///
    /// The excerpts are paired with the header rows *in order*, so inserting
    /// and deleting lines inside an excerpt needs no bookkeeping at all: the
    /// body is simply whatever now lies between two headers. A header that
    /// was edited or removed breaks that pairing, and the write refuses
    /// rather than guessing which lines belonged to which file.
    fn mbWrite(self: *Editor) bool {
        const mb = &self.d.mb.?;
        const cwd = std.process.currentPathAlloc(self.io, self.gpa) catch {
            self.setStatus("cannot read the working directory", .{});
            return false;
        };
        defer self.gpa.free(cwd);

        // Find each excerpt's header row, in order. Every row that is not a
        // header belongs to the excerpt above it.
        var rows: std.ArrayList(usize) = .empty;
        defer rows.deinit(self.gpa);
        var row: usize = 0;
        while (row < self.buf.lineCount()) : (row += 1) {
            if (std.mem.startsWith(u8, self.buf.line(row), mb_marker))
                rows.append(self.gpa, row) catch return false;
        }
        // Count first, then contents: a deleted header makes every later one
        // pair with the wrong excerpt, and "this header is not the one I
        // expected" is a poor way to say "one of them is gone".
        if (rows.items.len != mb.excerpts.items.len) {
            self.setStatus("a header line was added or removed — undo it, or :bd! to discard", .{});
            return false;
        }
        for (rows.items, mb.excerpts.items) |r, ex| {
            if (std.mem.eql(u8, self.buf.line(r), ex.header)) continue;
            self.setStatus("a header line was edited — undo it, or :bd! to discard", .{});
            return false;
        }

        // One file at a time: its excerpts are adjacent, since the spans were
        // grouped by file when the buffer was built. Excerpt `e` is header
        // `e` — that pairing is what the checks above just established.
        var written: usize = 0;
        var unchanged: usize = 0;
        var stale: usize = 0;
        var failed: usize = 0;
        var who: []const u8 = "";
        var i: usize = 0;
        while (i < mb.excerpts.items.len) {
            var j = i;
            while (j + 1 < mb.excerpts.items.len and
                std.mem.eql(u8, mb.excerpts.items[j + 1].path, mb.excerpts.items[i].path)) j += 1;
            defer i = j + 1;

            const abs = self.absPath(cwd, mb.excerpts.items[i].path) orelse continue;
            defer self.gpa.free(abs);
            const doc = self.docForPath(cwd, abs) orelse {
                failed += 1;
                if (who.len == 0) who = mb.excerpts.items[i].path;
                continue;
            };

            var edits: std.ArrayList(lsp.TextEdit) = .empty;
            defer {
                for (edits.items) |e| self.gpa.free(e.text);
                edits.deinit(self.gpa);
            }
            var any_stale = false;
            for (i..j + 1) |e| {
                const ex = &mb.excerpts.items[e];
                // The source lines as they are *now*: if they no longer match
                // what the excerpt was built from, someone else has edited the
                // file and writing this back would silently undo them.
                const now = self.linesOf(&doc.buf, ex.start, ex.len) orelse {
                    any_stale = true;
                    break;
                };
                defer self.gpa.free(now);
                if (!std.mem.eql(u8, now, ex.orig)) {
                    any_stale = true;
                    break;
                }
                const body = self.mbBody(rows.items, e) orelse continue;
                defer self.gpa.free(body);
                if (std.mem.eql(u8, body, ex.orig)) continue; // untouched
                const owned = self.gpa.dupe(u8, body) catch continue;
                edits.append(self.gpa, .{
                    .start_line = @intCast(ex.start),
                    .start_char = 0,
                    .end_line = @intCast(ex.start + ex.len - 1),
                    .end_char = std.math.maxInt(u32), // clamped to the line's end
                    .text = owned,
                }) catch self.gpa.free(owned);
            }
            if (any_stale) {
                stale += 1;
                if (who.len == 0) who = mb.excerpts.items[i].path;
                continue;
            }
            if (edits.items.len == 0) {
                unchanged += 1;
                continue;
            }
            // Never the active document — that is this multibuffer — so the
            // background path in `applyDocEdits` is the one that runs.
            _ = self.applyDocEdits(doc, edits.items) catch {
                failed += 1;
                if (who.len == 0) who = mb.excerpts.items[i].path;
                continue;
            };
            doc.buf.save(self.io) catch |err| {
                failed += 1;
                if (who.len == 0) who = mb.excerpts.items[i].path;
                std.log.scoped(.editor).err("multibuffer write failed: {s}: {s}", .{ mb.excerpts.items[i].path, @errorName(err) });
                continue;
            };
            doc.history.markSaved(&doc.buf, 0, 0);
            written += 1;
            // Each excerpt now *is* what its file holds, so a second `:w` is a
            // no-op rather than a stale-file complaint. The lengths move too:
            // an excerpt that grew by a line covers one more source line, and
            // the ones after it in the same file shift by the same amount.
            var shift: i64 = 0;
            for (i..j + 1) |e| {
                const ex = &mb.excerpts.items[e];
                const body = self.mbBody(rows.items, e) orelse continue;
                ex.start = @intCast(@as(i64, @intCast(ex.start)) + shift);
                const new_len = std.mem.count(u8, body, "\n") + 1;
                shift += @as(i64, @intCast(new_len)) - @as(i64, @intCast(ex.len));
                ex.len = new_len;
                self.gpa.free(ex.orig);
                ex.orig = body;
            }
        }

        if (stale > 0) {
            self.setStatus("{s} changed since this was opened — {d} file(s) not written", .{ who, stale });
            return false;
        }
        if (failed > 0) {
            self.setStatus("write failed: {s} ({d} written)", .{ who, failed });
            return false;
        }
        self.history.markSaved(self.buf, self.cy, self.cx);
        self.buf.dirty = false;
        self.setStatus("{d} file(s) written, {d} unchanged", .{ written, unchanged });
        self.refreshGit();
        return true;
    }

    /// `len` lines of `buf` from `start`, "\n"-joined; null when the buffer
    /// no longer reaches that far. Owned by the caller.
    fn linesOf(self: *Editor, buf: *buffer.Buffer, start: usize, len: usize) ?[]u8 {
        if (start + len > buf.lineCount()) return null;
        var out: std.ArrayList(u8) = .empty;
        for (start..start + len) |r| {
            if (r > start) out.append(self.gpa, '\n') catch break;
            out.appendSlice(self.gpa, buf.line(r)) catch break;
        }
        return out.toOwnedSlice(self.gpa) catch null;
    }

    /// The rows between header `k` and the next header (or the end of the
    /// buffer), "\n"-joined. Owned by the caller.
    fn mbBody(self: *Editor, rows: []const usize, k: usize) ?[]u8 {
        if (k >= rows.len) return null;
        const from = rows[k] + 1;
        const to = if (k + 1 < rows.len) rows[k + 1] else self.buf.lineCount();
        var out: std.ArrayList(u8) = .empty;
        for (from..to) |r| {
            if (r > from) out.append(self.gpa, '\n') catch break;
            out.appendSlice(self.gpa, self.buf.line(r)) catch break;
        }
        return out.toOwnedSlice(self.gpa) catch null;
    }

    // === file-tree sidebar =================================================

    fn sbFree(self: *Editor) void {
        for (self.sb_entries.items) |e| self.gpa.free(e.path);
        self.sb_entries.clearRetainingCapacity();
    }

    /// Rebuild the flattened tree: the cwd's entries, with expanded directories
    /// contributing their children inline (directories first, alphabetical).
    fn sbRebuild(self: *Editor) void {
        self.sbFree();
        self.sbAddDir(".", 0);
        if (self.sb_sel >= self.sb_entries.items.len and self.sb_entries.items.len > 0)
            self.sb_sel = self.sb_entries.items.len - 1;
    }

    fn sbAddDir(self: *Editor, dir_path: []const u8, depth: u8) void {
        if (depth > 16 or self.sb_entries.items.len > 5000) return; // sanity bounds
        const Tmp = struct { name: []u8, is_dir: bool };
        var tmp: std.ArrayList(Tmp) = .empty;
        defer {
            for (tmp.items) |t| self.gpa.free(t.name);
            tmp.deinit(self.gpa);
        }
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            const is_dir = entry.kind == .directory;
            if (!is_dir and entry.kind != .file) continue;
            if (is_dir and ignoredDir(entry.name)) continue;
            const name = self.gpa.dupe(u8, entry.name) catch continue;
            tmp.append(self.gpa, .{ .name = name, .is_dir = is_dir }) catch {
                self.gpa.free(name);
                break;
            };
        }
        std.mem.sort(Tmp, tmp.items, {}, struct {
            fn less(_: void, a: Tmp, b: Tmp) bool {
                if (a.is_dir != b.is_dir) return a.is_dir; // directories first
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);

        for (tmp.items) |t| {
            const path = if (std.mem.eql(u8, dir_path, "."))
                (self.gpa.dupe(u8, t.name) catch continue)
            else
                (std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ dir_path, t.name }) catch continue);
            const expanded = t.is_dir and self.sb_expanded.contains(path);
            self.sb_entries.append(self.gpa, .{ .path = path, .depth = depth, .is_dir = t.is_dir, .expanded = expanded }) catch {
                self.gpa.free(path);
                return;
            };
            if (expanded) self.sbAddDir(path, depth + 1);
        }
    }

    /// `Space e` — VS Code's three-state cycle: closed → open + focused;
    /// open but unfocused → just refocus it (no rebuild — selection and
    /// scroll survive, and it is the keyboard route back into an Esc'd
    /// tree); open + focused → close.
    fn sidebarToggle(self: *Editor) void {
        if (!self.sb_open) {
            self.sb_open = true;
            self.sb_focus = true;
            self.sbRebuild();
        } else if (!self.sb_focus) {
            self.sb_focus = true;
        } else {
            self.sb_open = false;
            self.sb_focus = false;
        }
    }

    fn sidebarKey(self: *Editor, k: key.Key) !void {
        const n = self.sb_entries.items.len;
        switch (k) {
            .escape => self.sb_focus = false, // keep it open, focus the buffer
            // The same window navigation as everywhere else, so the way out of
            // the tree is the way in, reversed.
            .ctrl => |c| switch (c) {
                'h' => self.moveFocus(.left),
                'l' => self.moveFocus(.right),
                'j' => self.moveFocus(.down),
                'k' => self.moveFocus(.up),
                else => {},
            },
            .down => self.sbMove(1),
            .up => self.sbMove(-1),
            // VS Code's tree keys: Right expands (or opens a file), Left
            // collapses — the same pair `l`/`h` bind to.
            .right => try self.sbActivate(),
            .left => self.sbCollapse(),
            .enter => try self.sbActivate(),
            .char => |c| switch (c) {
                'j' => self.sbMove(1),
                'k' => self.sbMove(-1),
                'g' => self.sb_sel = 0,
                'G' => self.sb_sel = if (n > 0) n - 1 else 0,
                'l' => try self.sbActivate(),
                'h' => self.sbCollapse(),
                'a' => self.enterNewEntry(false), // new file (neo-tree's key)
                'A' => self.enterNewEntry(true), // new folder
                'R' => self.sbRebuild(),
                ' ' => self.await_arg = .space_leader, // the leader menu works here too
                'q' => {
                    self.sb_open = false;
                    self.sb_focus = false;
                },
                else => {},
            },
            else => {},
        }
    }

    fn sbMove(self: *Editor, delta: i64) void {
        const n = self.sb_entries.items.len;
        if (n == 0) return;
        const cur = @as(i64, @intCast(self.sb_sel)) + delta;
        self.sb_sel = @intCast(@max(0, @min(cur, @as(i64, @intCast(n - 1)))));
    }

    /// Enter/l: expand or collapse a directory; open a file in the active
    /// window (returning focus to the buffer).
    fn sbActivate(self: *Editor) !void {
        if (self.sb_sel >= self.sb_entries.items.len) return;
        const e = self.sb_entries.items[self.sb_sel];
        if (e.is_dir) {
            self.sbToggleDir(e.path);
        } else {
            // A file opened from the tree while the picker is up (a click in
            // the `zedit .` view) must close the picker first: `openFile`
            // never touches the mode, and the picker would repaint over the
            // freshly opened file.
            if (self.mode == .picker) self.closePicker();
            self.openFile(e.path, 0);
            self.sb_focus = false;
        }
    }

    /// h: collapse the selected directory, or jump to the parent entry.
    fn sbCollapse(self: *Editor) void {
        if (self.sb_sel >= self.sb_entries.items.len) return;
        const e = self.sb_entries.items[self.sb_sel];
        if (e.is_dir and e.expanded) {
            self.sbToggleDir(e.path);
            return;
        }
        if (e.depth == 0) return;
        var i = self.sb_sel;
        while (i > 0) : (i -= 1) {
            if (self.sb_entries.items[i - 1].depth < e.depth) {
                self.sb_sel = i - 1;
                return;
            }
        }
    }

    /// `a` / `A` in the tree — prompt for a new file or folder, pre-filled with
    /// the selected row's directory so typing the leaf name is enough (VS
    /// Code's rule; the prompt is editable, so a deeper path works too).
    fn enterNewEntry(self: *Editor, is_dir: bool) void {
        self.mode = .command;
        self.cmd_kind = if (is_dir) .new_dir else .new_file;
        self.cmd.clearRetainingCapacity();
        self.cmd.appendSlice(self.gpa, self.sbTargetDir()) catch {};
        self.cmd_cur = self.cmd.items.len;
        self.cmd_reg = false;
        self.ghostUpdate(); // no history here either: clear any stale `:` ghost
    }

    /// Where a new entry goes: inside the selected row when it is an expanded
    /// directory, else beside it. Returned with a trailing `/`, or empty for
    /// the project root.
    fn sbTargetDir(self: *Editor) []const u8 {
        if (self.sb_sel >= self.sb_entries.items.len) return "";
        const e = self.sb_entries.items[self.sb_sel];
        if (e.is_dir and e.expanded) {
            self.sb_prefill.clearRetainingCapacity();
            self.sb_prefill.appendSlice(self.gpa, e.path) catch return "";
            self.sb_prefill.append(self.gpa, '/') catch return "";
            return self.sb_prefill.items;
        }
        const parent = std.fs.path.dirname(e.path) orelse return "";
        self.sb_prefill.clearRetainingCapacity();
        self.sb_prefill.appendSlice(self.gpa, parent) catch return "";
        self.sb_prefill.append(self.gpa, '/') catch return "";
        return self.sb_prefill.items;
    }

    /// Create what the prompt names. Intermediate directories are created too
    /// (`a` then `src/new/mod.zig` works with no `src/new` in the tree), the
    /// tree is rebuilt with the new entry revealed, and a new *file* is opened
    /// so it can be typed into straight away.
    fn createEntry(self: *Editor, is_dir: bool) void {
        const raw = std.mem.trim(u8, self.cmd.items, " \t/");
        if (raw.len == 0) return self.setStatus("no name given", .{});
        const path = self.gpa.dupe(u8, raw) catch return self.setStatus("out of memory", .{});
        defer self.gpa.free(path);
        const cwd = std.Io.Dir.cwd();
        if (cwd.access(self.io, path, .{})) |_| {
            return self.setStatus("already exists: {s}", .{path});
        } else |_| {}
        const dir = if (is_dir) path else (std.fs.path.dirname(path) orelse "");
        if (dir.len > 0) cwd.createDirPath(self.io, dir) catch |err|
            return self.setStatus("could not create {s}: {s}", .{ dir, @errorName(err) });
        if (!is_dir) cwd.writeFile(self.io, .{ .sub_path = path, .data = "" }) catch |err|
            return self.setStatus("could not create {s}: {s}", .{ path, @errorName(err) });
        // Every ancestor must be expanded for the new row to be visible.
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, i, '/')) |slash| : (i = slash + 1) {
            self.sbExpand(path[0..slash]);
        }
        if (is_dir) self.sbExpand(path);
        if (self.sb_open) { // no point rebuilding a tree nobody is looking at
            self.sbRebuild();
            for (self.sb_entries.items, 0..) |e, idx| {
                if (std.mem.eql(u8, e.path, path)) self.sb_sel = idx;
            }
        }
        if (is_dir) {
            self.setStatus("created {s}/", .{path});
        } else {
            self.openFile(path, 0);
            self.sb_focus = false;
            self.setStatus("created {s}", .{path});
        }
    }

    /// Reveal the active document in the explorer: expand its ancestor
    /// directories, select its row, and let the next render scroll to it.
    /// Files outside the cwd (absolute elsewhere, remote, scratch) leave the
    /// tree alone. Runs on every buffer switch (`focusDoc`), so it only
    /// rebuilds the tree when a directory actually needs expanding.
    fn sbReveal(self: *Editor) void {
        if (!self.sb_open) return;
        const path = self.d.buf.path orelse return;
        const rel = self.cwdRelative(path) orelse return;
        if (self.sbSelect(rel)) return; // already in the tree: just select it
        var changed = false;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel, i, '/')) |slash| : (i = slash + 1) {
            const dir = rel[0..slash];
            if (self.sb_expanded.contains(dir)) continue;
            const owned = self.gpa.dupe(u8, dir) catch return;
            self.sb_expanded.put(owned, {}) catch {
                self.gpa.free(owned);
                return;
            };
            changed = true;
        }
        if (!changed) return; // nothing to expand and no row: e.g. an ignored dir
        self.sbRebuild();
        _ = self.sbSelect(rel);
    }

    /// Select the tree row for cwd-relative file path `rel`, if present.
    fn sbSelect(self: *Editor, rel: []const u8) bool {
        for (self.sb_entries.items, 0..) |e, i| {
            if (!e.is_dir and std.mem.eql(u8, e.path, rel)) {
                self.sb_sel = i;
                return true;
            }
        }
        return false;
    }

    /// `path` as the cwd-relative form the sidebar tree uses (a slice of the
    /// argument), or null when it points outside the cwd (remote, `..`, or an
    /// absolute path elsewhere).
    fn cwdRelative(self: *Editor, path: []const u8) ?[]const u8 {
        var p = path;
        if (remote.isRemote(p)) return null;
        if (std.mem.startsWith(u8, p, "./")) p = p[2..];
        if (p.len > 0 and p[0] == '/') {
            const cwd = std.process.currentPathAlloc(self.io, self.gpa) catch return null;
            defer self.gpa.free(cwd);
            if (p.len <= cwd.len + 1 or !std.mem.startsWith(u8, p, cwd) or p[cwd.len] != '/') return null;
            return p[cwd.len + 1 ..];
        }
        if (std.mem.startsWith(u8, p, "../") or std.mem.eql(u8, p, "..")) return null;
        return p;
    }

    fn sbToggleDir(self: *Editor, path: []const u8) void {
        if (self.sb_expanded.fetchRemove(path)) |kv| {
            self.gpa.free(kv.key);
        } else self.sbExpand(path);
        self.sbRebuild();
    }

    /// Mark directory `path` (cwd-relative) expanded; the caller rebuilds.
    fn sbExpand(self: *Editor, path: []const u8) void {
        if (self.sb_expanded.contains(path)) return;
        const owned = self.gpa.dupe(u8, path) catch return;
        self.sb_expanded.put(owned, {}) catch self.gpa.free(owned);
    }

    /// The sidebar's 1-based screen x origin (its width is `sbWidth`).
    fn sbX(self: *Editor) usize {
        if (config.settings.sidebar == .left) return 1;
        return self.win.cols - self.sbWidth() + 1;
    }

    /// Tree-row geometry, shared by `renderSidebar` and the click hit-test
    /// (`sbClick`) so a row can never be drawn at one place and clicked at
    /// another — the tabline's invariant, applied here. Tree rows start on
    /// screen row `sb_tree_top` (row 1 is the title bar, or the sidebar's
    /// own header when `buffer_tabs = false` — either way the tree starts
    /// one row down) and there are `sbRows` of them (the command line keeps
    /// the last screen row).
    const sb_tree_top: usize = 2;
    fn sbRows(self: *Editor) usize {
        return if (self.win.rows > 2) self.win.rows - 2 else 1;
    }

    /// A left-click inside the sidebar's columns. A tree row selects its
    /// entry and activates it exactly as Enter does (`sbActivate`: a
    /// directory toggles, a file opens and hands focus back — VS Code's
    /// single-click rule); the header row (the EXPLORER title-bar segment)
    /// and the empty space below the last entry just focus the tree. The
    /// focus grab is normal-mode only, because sidebar keys route only
    /// there — lighting the header in insert mode would lie. Clicks outside
    /// the sidebar (or with it closed) do nothing.
    fn sbClick(self: *Editor, row: usize, col: usize) !void {
        if (!self.sb_open) return;
        const x = self.sbX();
        if (col < x or col >= x + self.sbWidth()) return;
        if (row >= sb_tree_top and row < sb_tree_top + self.sbRows()) {
            const idx = self.sb_scroll + (row - sb_tree_top);
            if (idx < self.sb_entries.items.len) {
                self.sb_sel = idx;
                if (self.mode == .normal) self.sb_focus = true;
                return self.sbActivate();
            }
            // Below the last entry: just the focus grab.
        } else if (row != 1) return; // the command-line row
        if (self.mode == .normal) self.sb_focus = true;
    }

    fn sbWidth(self: *Editor) usize {
        const cols: usize = self.win.cols;
        return @min(sidebar_width, cols / 2);
    }

    /// Draw the sidebar: the flattened tree with the selection highlighted
    /// (`ui_sel`, dimmed while the sidebar lacks focus). Its "EXPLORER"
    /// header lives in the title bar when that row is shown; otherwise this
    /// draws it, as before the title bar existed.
    fn renderSidebar(self: *Editor) !void {
        const th = theme.current;
        const x = self.sbX();
        const w = self.sbWidth();
        const rows = self.sbRows();
        if (self.sb_sel < self.sb_scroll) self.sb_scroll = self.sb_sel;
        if (self.sb_sel >= self.sb_scroll + rows) self.sb_scroll = self.sb_sel - rows + 1;

        if (!tabsVisible()) {
            self.beginSeg(1, x);
            try self.emitFmt("\x1b[1;{d}H", .{x});
            try self.setBg(if (self.sb_focus) th.mode_command else th.status_seg_bg);
            try self.setFg(if (self.sb_focus) th.bg else th.status_seg_fg);
            const hdr = " EXPLORER";
            const shown = @min(hdr.len, w); // a <9-col sidebar clips the label
            try self.emit(hdr[0..shown]);
            try self.emitSpaces(w - shown);
        }

        var r: usize = 0;
        while (r < rows) : (r += 1) {
            const idx = self.sb_scroll + r;
            self.beginSeg(sb_tree_top + r, x);
            try self.emitFmt("\x1b[{d};{d}H", .{ sb_tree_top + r, x });
            const selected = idx == self.sb_sel and idx < self.sb_entries.items.len;
            // The selected row must stay visible without focus too: Nord's
            // cursorline == bg_dark once made it vanish there (hence ui_sel).
            try self.setBg(if (selected and self.sb_focus) th.ui_sel else if (selected) mixColor(th.bg_dark, th.ui_sel, 50) else th.bg_dark);
            if (idx < self.sb_entries.items.len) {
                const e = self.sb_entries.items[idx];
                const name = std.fs.path.basename(e.path);
                const pad = @min(@as(usize, e.depth) * 2 + 1, w);
                try self.emitSpaces(pad);
                const glyph: []const u8 = if (!e.is_dir) "  " else if (e.expanded) "\u{25BE} " else "\u{25B8} ";
                try self.setFg(if (e.is_dir) th.function else if (selected) th.fg else th.fg_dim);
                try self.emit(glyph);
                var used = pad + 2;
                const shown = @min(name.len, if (w > used) w - used else 0);
                try self.emitSanitized(name[0..shown]);
                used += shown;
                if (used < w) try self.emitSpaces(w - used);
            } else {
                try self.emitSpaces(w);
            }
        }
    }

    // === windows / layout ==================================================

    /// Tile the windows over the text area (all but the bottom command line).
    /// One orientation at a time (even split); the last window takes the
    /// remainder so the screen is fully covered.
    /// Whether the title bar (EXPLORER segment + buffer tabs) is on screen:
    /// whenever the config allows it, even for a single buffer — VS Code's
    /// rule, so the bar never pops in and out as files open and close.
    /// `buffer_tabs = false` removes the row and puts the filename back in
    /// the statusline.
    fn tabsVisible() bool {
        return config.settings.buffer_tabs;
    }

    fn layout(self: *Editor) void {
        const tab_h: usize = if (tabsVisible()) 1 else 0;
        const total_rows = if (self.win.rows > 1 + tab_h) self.win.rows - 1 - tab_h else 1; // command line + tabs
        const cols: usize = self.win.cols;
        // The sidebar carves its width off the chosen side; windows tile the rest.
        const sb_w: usize = if (self.sb_open) self.sbWidth() else 0;
        const avail = if (cols > sb_w) cols - sb_w else 1;
        const x0: usize = if (config.settings.sidebar == .left) 1 + sb_w else 1;
        const n = self.wins.items.len;
        // Every window gets at least one legal cell. More splits than the
        // terminal has columns (or rows) used to hand the row painter a
        // zero-width window, whose `gw - 1` underflowed and aborted the
        // editor — a tiling accident must degrade, never crash.
        if (self.split_vertical and n > 1) {
            var x: usize = x0;
            for (self.wins.items, 0..) |w, i| {
                const want = if (i == n - 1) (if (x0 + avail > x) x0 + avail - x else 1) else self.share(i, avail);
                w.gx = @min(x, cols);
                w.gy = 1 + tab_h;
                w.gw = @max(1, @min(want, cols + 1 -| w.gx));
                w.gh = total_rows;
                x += want;
            }
        } else {
            var y: usize = 1 + tab_h;
            for (self.wins.items, 0..) |w, i| {
                const want = if (i == n - 1) (if (total_rows + 1 + tab_h > y) total_rows + tab_h - y + 1 else 1) else self.share(i, total_rows);
                w.gx = x0;
                w.gy = @min(y, self.win.rows);
                w.gw = avail;
                w.gh = @max(1, @min(want, self.win.rows -| w.gy));
                y += want;
            }
        }
    }

    /// Window `i`'s slice of `total` cells along the tiling axis, from its
    /// weight. At least one cell each, and never so greedy that the windows
    /// after it could not get one — a tiling accident must degrade, not crash.
    fn share(self: *Editor, i: usize, total: usize) usize {
        const n = self.wins.items.len;
        var sum: f64 = 0;
        for (self.wins.items) |w| sum += w.weight;
        if (!(sum > 0) or !std.math.isFinite(sum)) return @max(1, total / @max(1, n));
        const want: f64 = @as(f64, @floatFromInt(total)) * self.wins.items[i].weight / sum;
        const rest = n - i - 1; // windows still to be placed, one cell minimum
        const cap = if (total > rest + 1) total - rest - 1 else 1;
        if (!(want >= 1)) return 1;
        return @min(cap, @as(usize, @intFromFloat(@round(want))));
    }

    /// Resize the active window by `delta` cells along the tiling axis, taking
    /// the difference from (or giving it to) its siblings a cell at a time so
    /// none is squeezed below one. Weights are then just the resulting sizes:
    /// relative, so the split holds its proportions through a terminal resize.
    fn resizeWindow(self: *Editor, delta: i64, vertical_axis: bool) void {
        const n = self.wins.items.len;
        if (n < 2) return self.setStatus("only one window", .{});
        if (vertical_axis != self.split_vertical) {
            if (self.split_vertical) {
                self.setStatus("windows are side by side — use Ctrl-w < and >", .{});
            } else self.setStatus("windows are stacked — use Ctrl-w + and -", .{});
            return;
        }
        if (n > max_tiled) return self.setStatus("too many windows to resize", .{});
        var cells: [max_tiled]i64 = undefined;
        var total: i64 = 0;
        var me: usize = 0;
        for (self.wins.items, 0..) |w, i| {
            cells[i] = @intCast(if (self.split_vertical) w.gw else w.gh);
            total += cells[i];
            if (w == self.cur) me = i;
        }
        // Room to give: everyone else down to one cell.
        const floor_all: i64 = @intCast(n - 1);
        const want = std.math.clamp(cells[me] + delta, 1, @max(1, total - floor_all));
        var move = want - cells[me];
        // Spread the change over the others one cell at a time, nearest first,
        // so a `Ctrl-w +` in a three-way split does not flatten the far window.
        var guard: usize = 0;
        while (move != 0 and guard < 4096) : (guard += 1) {
            var acted = false;
            var step: usize = 1;
            while (step < n) : (step += 1) {
                const j = if (me + step < n) me + step else me + step - n;
                if (j == me) continue;
                if (move > 0 and cells[j] > 1) {
                    cells[j] -= 1;
                    cells[me] += 1;
                    move -= 1;
                    acted = true;
                } else if (move < 0) {
                    cells[j] += 1;
                    cells[me] -= 1;
                    move += 1;
                    acted = true;
                }
                if (move == 0) break;
            }
            if (!acted) break; // nothing left to take
        }
        for (self.wins.items, 0..) |w, i| w.weight = @floatFromInt(@max(1, cells[i]));
    }

    /// Every window the same size again (vim's `Ctrl-w =`).
    fn equalizeWindows(self: *Editor) void {
        for (self.wins.items) |w| w.weight = 1;
        self.setStatus("windows equalized", .{});
    }

    /// Apply `split_sizes` from the config when it names exactly this many
    /// windows. Called after a split, so a saved layout comes back by itself.
    fn applyConfigSizes(self: *Editor) void {
        const n = self.wins.items.len;
        var have: usize = 0;
        for (config.settings.split_sizes) |v| {
            if (v <= 0) break;
            have += 1;
        }
        if (have != n) return;
        for (self.wins.items, 0..) |w, i| w.weight = config.settings.split_sizes[i];
    }

    /// Write the current proportions to the config file, so the next session
    /// splits the same way. Normalised to sum to the window count, which keeps
    /// the numbers readable (`1,2` rather than `41,82`) and, being relative,
    /// correct on any terminal.
    fn saveWindowSizes(self: *Editor) !void {
        const n = self.wins.items.len;
        if (n < 2) return self.setStatus("only one window — nothing to save", .{});
        if (n > config.settings.split_sizes.len)
            return self.setStatus("too many windows to save (at most {d})", .{config.settings.split_sizes.len});
        var sum: f64 = 0;
        for (self.wins.items) |w| sum += w.weight;
        if (!(sum > 0)) return;
        var buf: [128]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        for (self.wins.items, 0..) |w, i| {
            if (i > 0) out.writeByte(',') catch break;
            out.print("{d:.2}", .{w.weight * @as(f64, @floatFromInt(n)) / sum}) catch break;
        }
        const text = out.buffered();
        config.saveKey(self.gpa, self.io, "split_sizes", text) catch |e| {
            self.setStatus("could not save window sizes: {s}", .{@errorName(e)});
            return;
        };
        // Keep the running settings in step, so a later `:winsave`-free split
        // in this same session picks the layout up too.
        config.settings.split_sizes = config.parseSizes(text);
        self.setStatus("window sizes saved ({s})", .{text});
    }

    fn buildView(self: *Editor, w: *Win) View {
        const doc = w.doc;
        const g = gutterFor(doc.buf.lineCount());
        const cols = winTextCols(w);
        const large = docIsLarge(doc);
        const wrap = self.winWrap(w);
        if (w == self.cur) return .{
            .buf = self.buf,
            .active = true,
            .has_ts = self.ts != null,
            .ts_styles = self.ts_styles.items,
            .ts_line_starts = self.ts_line_starts.items,
            .ts_vis_start = self.ts_vis_start,
            .git = &self.git_signs,
            .lang = if (large) .none else self.lang,
            .cy = self.cy,
            .top = self.top,
            .left = self.left,
            .gutter = g,
            .cols = cols,
            .wrap = wrap,
            .folds = &doc.folds,
        };
        return .{
            .buf = &doc.buf,
            .active = false,
            .has_ts = doc.ts != null,
            .ts_styles = doc.ts_styles.items,
            .ts_line_starts = doc.ts_line_starts.items,
            .ts_vis_start = doc.ts_vis_start,
            .git = &doc.git_signs,
            .lang = if (large) .none else doc.lang,
            .cy = w.cy,
            .top = w.top,
            .left = w.left,
            .gutter = g,
            .cols = cols,
            .wrap = wrap,
            .folds = &doc.folds,
        };
    }

    /// Rows of `w` available for buffer text (its bottom row is a status line
    /// when more than one window is open).
    fn winTextRows(self: *Editor, w: *Win) usize {
        if (self.wins.items.len > 1) return if (w.gh > 1) w.gh - 1 else 1;
        return w.gh;
    }

    /// Whether `w` takes part in a visible side-by-side diff pair — the index
    /// snapshot pane itself, or a worktree pane some visible index pane
    /// mirrors — or shows the line-diff weave. All get vimdiff-style
    /// change-line tinting.
    fn diffTinted(self: *Editor, w: *Win) bool {
        if (w.doc.diff_of != null or w.doc.line_diff != null) return true;
        for (self.wins.items) |other| {
            if (other.doc.diff_of == w.doc) return true;
        }
        return false;
    }

    /// A fully visible side-by-side pair: the worktree window, the index
    /// window, and the hunks that align their rows.
    const DiffPair = struct { wt: *Win, ix: *Win, hunks: []const git.Hunk };

    /// The visible pair `w` belongs to. Null unless *both* panes are on screen
    /// with hunks to align — a lone pane renders like any other window.
    fn diffPairOf(self: *Editor, w: *Win) ?DiffPair {
        if (w.doc.diff_of) |wt_doc| {
            if (w.doc.diff_hunks.len == 0) return null;
            if (self.cur.doc == wt_doc) return .{ .wt = self.cur, .ix = w, .hunks = w.doc.diff_hunks };
            for (self.wins.items) |other| {
                if (other.doc == wt_doc) return .{ .wt = other, .ix = w, .hunks = w.doc.diff_hunks };
            }
            return null;
        }
        for (self.wins.items) |other| {
            if (other.doc.diff_of == w.doc and other.doc.diff_hunks.len > 0)
                return .{ .wt = w, .ix = other, .hunks = other.doc.diff_hunks };
        }
        return null;
    }

    /// The pair's shared viewport top in aligned display-row space, derived
    /// every frame from the focused pane (or the worktree pane when neither
    /// side has focus) — the two panes scroll as one without duplicated state.
    fn diffDisplayTop(self: *Editor, p: DiffPair) usize {
        if (self.cur == p.ix) return self.paneDisplayTop(p, p.ix, false, self.top, self.cy);
        if (self.cur == p.wt) return self.paneDisplayTop(p, p.wt, true, self.top, self.cy);
        return self.paneDisplayTop(p, p.wt, true, p.wt.top, p.wt.cy);
    }

    /// Display top of a pane anchored at buffer row `top`. Buffer row 0
    /// anchors at display row 0, not at its own display row: a deletion
    /// before the first line (`@@ -1,N +0,0 @@`, new.start == 0) puts N
    /// aligned rows *above* buffer row 0, which a buffer-row top could never
    /// reach — the whole index pane sat above the viewport on a total
    /// deletion. The cursor still wins when that gap is taller than the
    /// window (only the gap's tail shows; see Known gaps).
    fn paneDisplayTop(self: *Editor, p: DiffPair, w: *Win, new_side: bool, top: usize, cy: usize) usize {
        const dtop = git.displayRow(p.hunks, new_side, top);
        if (top > 0) return dtop;
        const dcy = git.displayRow(p.hunks, new_side, cy);
        return @min(dtop, dcy -| (self.winTextRows(w) -| 1));
    }

    /// Carry the derived top back onto the unfocused pane's Win each frame, so
    /// a later focus switch starts from where the pane actually is.
    fn syncDiffPanes(self: *Editor) void {
        for (self.wins.items) |w| {
            if (w.doc.diff_of == null) continue;
            const p = self.diffPairOf(w) orelse continue;
            const dtop = self.diffDisplayTop(p);
            const partner = if (self.cur == p.ix) p.wt else p.ix;
            if (partner == self.cur) continue;
            const lines = partner.doc.buf.lineCount();
            partner.top = @min(git.rowAtOrAfter(p.hunks, partner == p.wt, dtop), lines - 1);
            // Pull the pane's bookmarked cursor into the synced viewport (vim's
            // rule for scrollbound windows): focusing it later must never yank
            // the lockstepped pair back to a stale row.
            const pd = git.displayRow(p.hunks, partner == p.wt, partner.cy);
            if (pd < dtop or pd >= dtop + self.winTextRows(partner)) partner.cy = partner.top;
        }
    }

    /// Soft wrap for window `w`: forced off while it takes part in a visible
    /// diff pair — a wrapped line fills several screen rows and would break
    /// the panes' row alignment (horizontal scrolling still works there).
    fn winWrap(self: *Editor, w: *Win) bool {
        return config.settings.soft_wrap and self.diffPairOf(w) == null;
    }

    /// What one screen row of a window's text area shows. A window's rows are
    /// consumed by four independent mechanisms — diff-pair fillers, line-diff
    /// woven rows, soft-wrap segments and `~` rows past EOF — and only the
    /// first two are hunk-driven, so there is no closed form for the inverse.
    const RowSlot = union(enum) {
        line: struct { row: usize, seg: usize },
        /// A closed fold's header: one row standing in for `lines` of text.
        folded: struct { row: usize, lines: usize },
        filler, // a diff-pair virtual row: the other side has lines this one lacks
        woven: []const u8, // a line-diff old line, drawn above the line that replaced it
        past_eof, // a `~` row
    };

    /// The state `renderWindow` carries down a window's rows. `rowWalk` seeds
    /// it and `nextRow` advances it, so the renderer and the click hit-test
    /// (`winHit`) resolve every row through the very same code — a row can
    /// never be drawn at one place and clicked at another (the tabline's
    /// `tabArea` invariant, applied to the text area).
    const RowWalk = struct {
        // per-window constants
        pair: ?DiffPair,
        new_side: bool,
        dtop: usize,
        ld: ?*const git.LineDiff,
        lskip: usize,
        text_rows: usize,
        // loop-carried state
        vlines: []const []const u8 = &.{}, // the woven block above `file_row`
        vi: usize = 0, // next woven line to draw from it
        vrow: usize = std.math.maxInt(usize), // the row `vlines` was fetched for
        r: usize = 0, // rows emitted so far
        file_row: usize,
        seg: usize = 0,
        wl: WrapLayout = .{ .starts = .{0} ** max_wrap_rows, .n = 1, .indent = 0 },
    };

    fn rowWalk(self: *Editor, w: *Win, view: *const View) RowWalk {
        // A visible diff pair renders in aligned display rows: each screen row
        // resolves through the hunks to a buffer row or a virtual filler, so
        // matching text sits level across the panes (VS Code style).
        const pair = self.diffPairOf(w);
        // The line-diff view (`Space g l`): old lines woven in as virtual
        // rows above the lines that replaced them (exclusive with a pair).
        const ld: ?*const git.LineDiff = if (pair == null)
            (if (w.doc.line_diff) |*x| x else null)
        else
            null;
        return .{
            .pair = pair,
            .new_side = if (pair) |p| w == p.wt else false,
            .dtop = if (pair) |p| self.diffDisplayTop(p) else 0,
            .ld = ld,
            .lskip = if (ld) |x| (if (view.active) self.ldLeadingSkip(x) else 0) else 0,
            .text_rows = self.winTextRows(w),
            .file_row = view.top,
        };
    }

    /// Resolve screen row `rw.r` and advance the walk. With soft wrap one
    /// buffer line can fill several screen rows, so the walk is over
    /// (line, segment) pairs; without it every line is one row and `seg`
    /// never leaves 0. `rw.wl` is left holding the returned line's layout.
    fn nextRow(self: *Editor, rw: *RowWalk, view: *const View) RowSlot {
        if (rw.pair) |p| switch (git.slotAt(p.hunks, rw.new_side, rw.dtop + rw.r)) {
            .filler => return .filler,
            .row => |br| rw.file_row = br,
        };
        if (rw.ld) |x| {
            if (rw.seg == 0 and rw.file_row != rw.vrow and rw.file_row <= view.buf.lineCount()) {
                rw.vrow = rw.file_row;
                rw.vlines = x.above(rw.file_row);
                // The block above the top row is above the viewport when
                // scrolled (like a pair's fillers); at row 0 the leading
                // clamp decides how much of it shows.
                rw.vi = if (rw.file_row != view.top) 0 else if (view.top == 0) @min(rw.lskip, rw.vlines.len) else rw.vlines.len;
            }
            if (rw.vi < rw.vlines.len) {
                const text = rw.vlines[rw.vi];
                rw.vi += 1;
                return .{ .woven = text };
            }
        }
        if (rw.file_row >= view.buf.lineCount()) {
            rw.file_row += 1;
            return .past_eof;
        }
        // A closed fold is one row: draw its header and step over the body.
        if (view.folds.closedAt(rw.file_row)) |fd| {
            rw.file_row = fd.end + 1;
            rw.seg = 0;
            return .{ .folded = .{ .row = fd.start, .lines = fd.end - fd.start + 1 } };
        }
        const row = rw.file_row;
        const seg = rw.seg;
        if (seg == 0) {
            // One layout per line, reused for each row it fills.
            rw.wl = layoutLine(
                view.buf.line(row),
                view.cols,
                if (view.active and row == view.cy) self.cursorDisplayCol() else null,
                view.wrap,
                @max(1, rw.text_rows),
            );
        }
        rw.seg += 1;
        if (rw.seg >= rw.wl.n) {
            rw.seg = 0;
            rw.file_row += 1;
        }
        return .{ .line = .{ .row = row, .seg = seg } };
    }

    /// A resolved click: the buffer position under a screen cell, plus the
    /// display column that was clicked (which is what vim's curswant keeps —
    /// it may sit past the end of a short line).
    const Hit = struct { row: usize, col: usize, dcol: usize };

    /// The window whose box covers this cell, status row included. The
    /// sidebar's columns, the title bar and the command line belong to no
    /// window, so they fall outside every one.
    fn winUnder(self: *Editor, row: usize, col: usize) ?*Win {
        for (self.wins.items) |w| {
            if (row < w.gy or row >= w.gy + w.gh) continue;
            if (col < w.gx or col >= w.gx + w.gw) continue;
            return w;
        }
        return null;
    }

    /// The window whose *text* area covers this cell — `winUnder` without the
    /// status line it wears when more than one window is open. Clicks use this
    /// one: a click on a status row is inert (nvim resizes with it; zedit does
    /// not), while a wheel notch there scrolls the window it belongs to.
    fn winAt(self: *Editor, row: usize, col: usize) ?*Win {
        const w = self.winUnder(row, col) orelse return null;
        return if (row < w.gy + self.winTextRows(w)) w else null;
    }

    /// The buffer position under a screen cell of `w` — the inverse of
    /// `renderWindow`, replayed through the very same `nextRow` walk, so the
    /// two can never disagree about which row shows which line. Rows that are
    /// in no buffer snap to a real line rather than inventing one: a diff-pair
    /// filler to the next line that side actually has, a woven old line to the
    /// line it sits above (what `lineAtScreenRow` already does for `H`/`M`/`L`),
    /// a `~` row to the last line. The gutter resolves to column 0, as in nvim.
    fn winHit(self: *Editor, w: *Win, row: usize, col: usize) Hit {
        const view = self.buildView(w);
        const want = row - w.gy;
        var rw = self.rowWalk(w, &view);
        var slot: RowSlot = .past_eof;
        while (rw.r <= want) : (rw.r += 1) slot = self.nextRow(&rw, &view);

        const last = view.buf.lineCount() - 1;
        const line_row: usize = switch (slot) {
            .line => |l| l.row,
            .filler => @min(git.rowAtOrAfter(rw.pair.?.hunks, rw.new_side, rw.dtop + want), last),
            .woven => @min(rw.vrow, last),
            // Clicking a fold lands on its header, which is the only line of
            // it on screen — the body has no cell to have been clicked.
            .folded => |f| f.row,
            .past_eof => last,
        };
        const seg: usize = switch (slot) {
            .line => |l| l.seg,
            else => 0,
        };
        const line = view.buf.line(line_row);
        if (col < w.gx + view.gutter) return .{ .row = line_row, .col = 0, .dcol = 0 };
        // A snapped row's layout is not the one the walk left behind.
        const wl = switch (slot) {
            .line => rw.wl,
            else => layoutLine(line, view.cols, null, view.wrap, @max(1, rw.text_rows)),
        };
        const wincol = col - w.gx - view.gutter;
        var d: usize = undefined;
        if (!view.wrap) {
            d = view.left + wincol;
        } else {
            // A continuation row draws `pad` cells of hanging indent before its
            // text, and ends at the word break rather than at the window edge —
            // the cells past it belong to no character, so they must resolve
            // into this row instead of the next one.
            d = if (wincol < wl.pad(seg)) wl.starts[seg] else wl.starts[seg] + (wincol - wl.pad(seg));
            if (seg + 1 < wl.n and d >= wl.starts[seg + 1]) d = wl.starts[seg + 1] - 1;
        }
        const b = if (view.active) self.byteAtRenderedCol(line_row, line, d) else byteAtDisplayCol(line, d);
        return .{ .row = line_row, .col = b, .dcol = d -| (if (view.active) self.inlayCols(line_row, b) else 0) };
    }

    /// Inverse of `cursorDisplayCol`: the byte whose rendered span covers
    /// display column `d`, inlay-hint virtual text included. Only the active
    /// window draws hints, so only it needs this. The scan stops once the
    /// pure column passes `d` (hints only ever push text further right), so
    /// it costs a window's width, not a line's length.
    fn byteAtRenderedCol(self: *Editor, row: usize, line: []const u8, d: usize) usize {
        if (self.lsp == null or self.inlayCols(row, line.len) == 0) return byteAtDisplayCol(line, d);
        var i: usize = 0;
        var dc: usize = 0;
        var best: usize = 0;
        while (true) {
            if (dc + self.inlayCols(row, i) > d) break;
            best = i;
            if (i >= line.len) break;
            const dec = unicode.decode(line[i..]);
            dc += cellWidth(dec.cp, dc);
            i += dec.len;
        }
        return best;
    }

    fn renderWindow(self: *Editor, w: *Win) !void {
        if (w.doc.shell != null) {
            try self.renderTerminalTabs(w);
            try self.renderShell(w);
            if (self.wins.items.len > 1) try self.emitWinStatus(w, self.buildView(w));
            return;
        }
        const th = theme.current;
        const view = self.buildView(w);
        const text_rows = self.winTextRows(w);
        const tinted = self.diffTinted(w);
        var rw = self.rowWalk(w, &view);
        while (rw.r < text_rows) : (rw.r += 1) {
            self.beginSeg(w.gy + rw.r, w.gx);
            try self.emitFmt("\x1b[{d};{d}H", .{ w.gy + rw.r, w.gx });
            switch (self.nextRow(&rw, &view)) {
                .filler => try self.emitFillerRow(w, rw.new_side),
                .woven => |text| try self.emitDeletedRow(&view, text),
                .past_eof => {
                    try self.setBg(th.bg);
                    try self.setFg(th.fg_dim);
                    try self.emit("~");
                    try self.emitSpaces(w.gw - 1);
                },
                .folded => |f| try self.emitFoldRow(&view, f.row, f.lines),
                .line => |l| {
                    const is_cur = view.active and l.row == view.cy;
                    var row_bg = if (is_cur) th.cursorline else th.bg;
                    if (tinted and !is_cur) {
                        if (view.git.get(l.row)) |sign| {
                            // In the line view a pure deletion is *shown* by its
                            // woven rows; tinting the surviving neighbour too
                            // would mark unchanged text as changed.
                            if (rw.ld == null or sign != .deleted) row_bg = mixColor(th.bg, switch (sign) {
                                .added => th.git_add,
                                .changed => th.git_change,
                                .deleted => th.git_delete,
                            }, 25);
                        }
                    }
                    try self.setBg(row_bg);
                    if (l.seg == 0) try self.emitGutter(&view, l.row) else try self.emitWrapGutter(&view);
                    try self.emitLine(&view, l.row, row_bg, l.seg, rw.wl);
                },
            }
        }
        if (self.wins.items.len > 1) try self.emitWinStatus(w, view);
    }

    /// The embedded shell's grid: one screen row per grid row, cells emitted
    /// with the child's own colours. Everything the child wrote is untrusted,
    /// so codepoints go through the same control-character rule as buffer
    /// text — `vt.zig` has already turned escapes into state rather than
    /// leaving them in the grid, and this is the second line of defence.
    fn renderShell(self: *Editor, w: *Win) !void {
        const th = theme.current;
        const sh = &w.doc.shell.?;
        self.syncTerminalSize(w);
        const rows = self.shellRows(w);
        var y: usize = 0;
        while (y < rows) : (y += 1) {
            // Row `w.gy` is the terminals' tab row, so the grid starts below it.
            self.beginSeg(w.gy + 1 + y, w.gx);
            try self.emitFmt("\x1b[{d};{d}H", .{ w.gy + 1 + y, w.gx });
            var x: usize = 0;
            var last: ?vt.Attr = null;
            while (x < w.gw) : (x += 1) {
                const c = sh.screen.viewAt(y, x);
                if (last == null or !c.attr.eql(last.?)) {
                    // reverse video swaps the pair, which is how a shell draws
                    // its selection and a `less` status line.
                    const fg = c.attr.fg orelse th.fg;
                    const bg = c.attr.bg orelse th.bg;
                    try self.setFg(if (c.attr.reverse) bg else (if (c.attr.dim) mixColor(bg, fg, 60) else fg));
                    try self.setBg(if (c.attr.reverse) fg else bg);
                    last = c.attr;
                }
                if (c.wide_tail) continue; // drawn by the wide cell before it
                if (c.cp == ' ') {
                    try self.emit(" ");
                } else if (isControlCp(c.cp)) {
                    try self.emit("?");
                } else {
                    var b: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(c.cp, &b) catch {
                        try self.emit("?");
                        continue;
                    };
                    try self.emit(b[0..n]);
                }
            }
        }
    }

    /// The terminals' own tab row, on the first line of the pane they share —
    /// VS Code's and Zed's panel, where terminals are their own list rather
    /// than buffers mixed in with the open files. Each is named `t1`, `t2`, …
    /// and carries the same `✕` the buffer tabs do.
    fn renderTerminalTabs(self: *Editor, w: *Win) !void {
        const th = theme.current;
        self.beginSeg(w.gy, w.gx);
        try self.emitFmt("\x1b[{d};{d}H", .{ w.gy, w.gx });
        var used: usize = 0;
        for (self.docs.items) |doc| {
            if (doc.shell == null) continue;
            const name = doc.name orelse "t?";
            const cells = 2 + unicode.displayWidth(name) + close_cells;
            if (used + cells > w.gw) break;
            const here = doc == w.doc;
            try self.setBg(if (here) th.mode_normal else th.status_bg);
            try self.setFg(if (here) th.bg else th.fg_dim);
            try self.emit(" ");
            try self.emitSanitized(name);
            try self.emit(" \u{2715} ");
            used += cells;
        }
        try self.setBg(th.status_bg);
        try self.emitSpaces(w.gw -| used);
    }

    /// Which terminal a click on that row lands on, and whether it hit the
    /// close box. Shares the geometry above, so a tab cannot be drawn in one
    /// place and clicked in another.
    fn terminalTabAt(self: *Editor, w: *Win, col: usize) ?TabHit {
        var x = w.gx;
        for (self.docs.items) |doc| {
            if (doc.shell == null) continue;
            const name = doc.name orelse "t?";
            const cells = 2 + unicode.displayWidth(name) + close_cells;
            if (x + cells > w.gx + w.gw) break;
            if (col >= x and col < x + cells) return .{ .doc = doc, .close = col >= x + cells - close_cells };
            x += cells;
        }
        return null;
    }

    /// A closed fold, as one row: the line number of its header, then the
    /// header's own text with a count of what it hides. Vim's `foldtext`
    /// shape, dimmed and on the cursorline background when the cursor is on
    /// it, so a fold reads as a summary rather than as content.
    fn emitFoldRow(self: *Editor, view: *const View, row: usize, lines: usize) !void {
        const th = theme.current;
        const is_cur = view.active and view.cy >= row and view.cy < row + lines;
        try self.setBg(if (is_cur) th.cursorline else th.bg);
        try self.emitGutter(view, row);
        try self.setFg(th.fg_dim);
        var used: usize = 0;
        var buf: [48]u8 = undefined;
        const head = std.fmt.bufPrint(&buf, "\u{25B8} {d} lines: ", .{lines}) catch "\u{25B8} ";
        try self.emit(head);
        used += unicode.displayWidth(head);
        // The header's own text, leading blanks trimmed: what the fold is
        // *of* matters more than how it was indented.
        const text = std.mem.trimStart(u8, view.buf.line(row), " \t");
        var i: usize = 0;
        while (i < text.len and used < view.cols) {
            const d = unicode.decode(text[i..]);
            const cw = unicode.width(d.cp);
            if (used + cw > view.cols) break;
            try self.emit(if (isControlCp(d.cp) or invalidDecode(d)) "?" else text[i .. i + d.len]);
            used += cw;
            i += d.len;
        }
        if (used < view.cols) try self.emitSpaces(view.cols - used);
    }

    /// A virtual filler row in a diff pane: where the other side has lines
    /// this one lacks. It lives in no buffer — blank gutter, no line number,
    /// the cursor never lands on it — and carries the tint of the change it
    /// stands for: git-delete on the worktree side, git-add on the index side.
    fn emitFillerRow(self: *Editor, w: *Win, new_side: bool) !void {
        const th = theme.current;
        try self.setBg(mixColor(th.bg, if (new_side) th.git_delete else th.git_add, 25));
        try self.emitSpaces(w.gw);
    }

    /// One woven old line in the line-diff view: a red-tinted virtual row
    /// showing text the worktree no longer has. It lives in no buffer — a
    /// dim `-` in the gutter, no line number, the cursor never lands on it —
    /// and is drawn unwrapped, clipped at the window edge. The text comes
    /// from `git diff` output: untrusted bytes, sanitized like buffer text.
    fn emitDeletedRow(self: *Editor, view: *const View, text: []const u8) !void {
        const th = theme.current;
        try self.setBg(mixColor(th.bg, th.git_delete, 25));
        try self.setFg(th.fg_dim);
        try self.emit("-");
        try self.emitSpaces(view.gutter - 1);
        try self.setFg(th.fg);
        var dc: usize = 0;
        var i: usize = 0;
        while (i < text.len and dc < view.cols) {
            const d = unicode.decode(text[i..]);
            const w = cellWidth(d.cp, dc);
            if (dc + w > view.cols) break;
            if (d.cp == '\t' or d.cp == ' ') {
                try self.emitSpaces(w);
            } else {
                try self.emit(if (isControlCp(d.cp) or invalidDecode(d)) "?" else text[i .. i + d.len]);
            }
            dc += w;
            i += d.len;
        }
        try self.emitSpaces(view.cols - dc);
    }

    /// A per-window status line (filename + position), drawn on the window's
    /// bottom region row. Only used when more than one window is open.
    fn emitWinStatus(self: *Editor, w: *Win, view: View) !void {
        const th = theme.current;
        self.beginSeg(w.gy + w.gh - 1, w.gx);
        try self.emitFmt("\x1b[{d};{d}H", .{ w.gy + w.gh - 1, w.gx });
        const active = w == self.cur;
        try self.setBg(if (active) th.status_seg_bg else th.status_bg);
        try self.setFg(if (active) th.status_seg_fg else th.fg_dim);
        const name = docLabel(w.doc);
        const dirty = if (view.buf.dirty) " \u{25CF}" else "";
        var nb: [320]u8 = undefined;
        const seg = std.fmt.bufPrint(&nb, " {s}{s}  {d}:{d} ", .{ name, dirty, view.cy + 1, view.left + 1 }) catch " ";
        const shown = @min(seg.len, w.gw);
        try self.emit(seg[0..shown]);
        if (shown < w.gw) try self.emitSpaces(w.gw - shown);
    }

    /// The gutter of a wrapped continuation row: no line number (it is the
    /// same line), just a dim marker so a wrapped line reads differently from
    /// a new one.
    fn emitWrapGutter(self: *Editor, view: *const View) !void {
        if (view.gutter == 0) return;
        try self.setFg(theme.current.cursorline);
        try self.emitSpaces(view.gutter - 2);
        try self.emit("\u{21B3}"); // ↳
        try self.emit(" ");
    }

    fn gutterFor(line_count: usize) usize {
        const digits = @as(usize, std.math.log10_int(line_count)) + 1; // lineCount() is never 0
        return @max(digits, 3) + 2; // git sign column + numbers + trailing space
    }

    // === rendering =========================================================

    fn segKey(row: usize, col: usize) usize {
        return row * 100_000 + col;
    }

    /// Start a new diffable segment at the current frame position. Resets the
    /// SGR dedupe state so every segment carries its own colours and can be
    /// skipped or replayed independently.
    fn beginSeg(self: *Editor, row: usize, col: usize) void {
        if (self.seg_marks.items.len > 0) {
            self.seg_marks.items[self.seg_marks.items.len - 1].end = self.frame.items.len;
        }
        self.seg_marks.append(self.gpa, .{ .key = segKey(row, col), .start = self.frame.items.len }) catch {};
        self.cur_fg = null;
        self.cur_bg = null;
    }

    fn closeSegs(self: *Editor) void {
        if (self.seg_marks.items.len > 0) {
            self.seg_marks.items[self.seg_marks.items.len - 1].end = self.frame.items.len;
        }
        self.segs_end = self.frame.items.len;
    }

    /// Write the built frame: whole when the previous frame can't be diffed
    /// against, else only the segments whose bytes changed.
    fn writeFrame(self: *Editor, diffable: bool) !void {
        defer {
            std.mem.swap(std.ArrayList(u8), &self.frame, &self.prev_frame);
            std.mem.swap(std.ArrayList(Seg), &self.seg_marks, &self.prev_marks);
            if (diffable) {
                self.prev_valid = true;
            } else {
                // An overlay was painted over the recorded rows, so the screen
                // no longer matches them: drop just those from the diff base.
                // Everything else still diffs, which keeps dismissing a popup
                // cheap on a slow link.
                self.dropOverlayMarks();
                self.prev_valid = true;
            }
        }

        const full = !diffable or !self.prev_valid or self.seg_marks.items.len == 0;
        if (full) {
            try self.term.write(self.frame.items);
            return;
        }
        self.out_frame.clearRetainingCapacity();
        const first = self.seg_marks.items[0].start;
        try self.out_frame.appendSlice(self.gpa, self.frame.items[0..first]);
        for (self.seg_marks.items) |seg| {
            const bytes = self.frame.items[seg.start..seg.end];
            if (self.prevSegBytes(seg.key)) |old| {
                if (std.mem.eql(u8, old, bytes)) continue; // unchanged row
            }
            try self.out_frame.appendSlice(self.gpa, bytes);
        }
        try self.out_frame.appendSlice(self.gpa, self.frame.items[self.segs_end..]);
        try self.term.write(self.out_frame.items);
    }

    /// Forget the diff base for rows an overlay covered (see `writeFrame`).
    fn dropOverlayMarks(self: *Editor) void {
        if (self.overlay_bot == 0) return;
        var i: usize = 0;
        while (i < self.prev_marks.items.len) {
            const row = self.prev_marks.items[i].key / 100000;
            if (row >= self.overlay_top and row <= self.overlay_bot) {
                _ = self.prev_marks.orderedRemove(i);
            } else i += 1;
        }
        self.overlay_top = 0;
        self.overlay_bot = 0;
    }

    fn prevSegBytes(self: *Editor, seg_key: usize) ?[]const u8 {
        for (self.prev_marks.items) |seg| {
            if (seg.key == seg_key) return self.prev_frame.items[seg.start..seg.end];
        }
        return null;
    }

    fn render(self: *Editor) !void {
        var sp = log.Span.start();
        // Keep the window padding on the theme's background. Idempotent, so
        // this is a comparison per frame until a theme actually changes.
        if (config.settings.sync_background)
            self.term.setBackground(theme.current.bg.r, theme.current.bg.g, theme.current.bg.b);
        self.style_buf_of = null; // styles are per frame; the text may have changed
        self.frame.clearRetainingCapacity();
        self.cur_fg = null;
        self.cur_bg = null;
        try self.emit(ansi.hide_cursor);
        try self.emit(ansi.cursor_home);
        try self.emit(ansi.reset_attrs);

        self.seg_marks.clearRetainingCapacity();
        if (self.mode == .picker) {
            try self.renderPickerBody();
            try self.term.write(self.frame.items);
            self.prev_valid = false; // the picker paints the whole screen
            sp.lap("render");
            // Now that the picker is on screen, parse the previewed file so
            // the next frame can colour it — see `warmPreview`.
            if (self.preview_warm) {
                self.warmPreview();
                self.frame.clearRetainingCapacity();
                self.cur_fg = null;
                self.cur_bg = null;
                try self.emit(ansi.hide_cursor);
                try self.renderPickerBody();
                try self.term.write(self.frame.items);
            }
            return;
        }

        if (self.dashboard) {
            try self.renderDashboard();
            try self.emit(ansi.reset_attrs);
            try self.term.write(self.frame.items);
            self.prev_valid = false; // the dashboard paints the whole screen
            sp.lap("render");
            return;
        }

        self.layout();
        self.scroll(); // active window viewport
        self.tsUpdate(); // query the active doc's visible range (needs scrolled top)
        self.saveViewport(); // mirror back into the active Win for rendering
        self.syncDiffPanes(); // lockstep: derive the unfocused diff pane's top

        if (tabsVisible()) try self.renderTitleBar();
        for (self.wins.items) |w| try self.renderWindow(w);
        if (self.sb_open) try self.renderSidebar();

        const gutter = self.gutterWidth();
        // Bottom command/status line.
        self.beginSeg(self.win.rows, 1);
        try self.emitFmt("\x1b[{d};1H", .{self.win.rows});
        try self.renderStatus();
        self.closeSegs();
        // Overlays draw on top of already-emitted rows, so frames showing one
        // are written whole (and the next plain frame repaints beneath them).
        // A command line wider than the row wraps upward over the windows
        // (nvim), which is exactly such an overlay.
        var overlay = self.sig_open or self.comp_open or
            (self.mode == .command and self.cmdBlock().height > 1);
        if (self.mode == .command and self.wild.items.len > 0) {
            try self.renderWildMenu();
            overlay = true;
        }
        if (self.whichKeyMenu() != null) {
            try self.renderWhichKey();
            overlay = true;
        }
        if (self.sig_open) try self.renderSignature(gutter);
        if (self.comp_open) try self.renderCompletion(gutter);
        if (self.toasts.visible().len > 0) {
            try self.renderToasts();
            overlay = true;
        }
        try self.emit(ansi.reset_attrs);
        try self.placeCursor(gutter);
        try self.emit(ansi.show_cursor);
        try self.writeFrame(!overlay);
        sp.lap("render");
    }

    // The AstroNvim-style leader tree, shown by the which-key popup.
    const WhichKey = struct { key: []const u8, desc: []const u8 };
    const leader_keys = [_]WhichKey{
        .{ .key = "n", .desc = "New file/folder \u{2026}" },
        .{ .key = "f", .desc = "Find \u{2026}" },
        .{ .key = "b", .desc = "Buffers \u{2026}" },
        .{ .key = "l", .desc = "Language tools \u{2026}" },
        .{ .key = "g", .desc = "Git \u{2026}" },
        .{ .key = "d", .desc = "Debug \u{2026}" },
        .{ .key = "S", .desc = "Session \u{2026}" },
        .{ .key = "u", .desc = "UI toggles \u{2026}" },
        .{ .key = "x", .desc = "Quickfix list \u{2026}" },
        .{ .key = "t", .desc = "Terminal" },
        .{ .key = "e", .desc = "Explorer" },
        .{ .key = "h", .desc = "Home screen" },
        .{ .key = "c", .desc = "Close buffer" },
        .{ .key = "w", .desc = "Write (save)" },
        .{ .key = "q", .desc = "Quit" },
    };
    /// `Space n` — making things. The file and folder entries are the same
    /// prompts the explorer's `a`/`A` open, reachable without the tree: they
    /// take a whole path, so `src/net/http.zig` creates both directories and
    /// the file (VS Code's rule).
    const new_keys = [_]WhichKey{
        .{ .key = "f", .desc = "New file (a/b/c.zig ok)" },
        .{ .key = "d", .desc = "New folder (a/b/c ok)" },
        .{ .key = "b", .desc = "New empty buffer" },
    };
    /// `Space d` — the debugger. AstroNvim's `<leader>d` keys, restricted to
    /// what is actually implemented (see TODO.md for what is not).
    const debug_keys = [_]WhichKey{
        .{ .key = "b", .desc = "toggle breakpoint" },
        .{ .key = "B", .desc = "clear breakpoints" },
        .{ .key = "c", .desc = "start / continue" },
        .{ .key = "n", .desc = "step over" },
        .{ .key = "i", .desc = "step into" },
        .{ .key = "o", .desc = "step out" },
        .{ .key = "q", .desc = "stop session" },
    };
    /// `Space S` — the session for this working directory. Explicit both
    /// ways: nothing is saved or restored unless a key says so.
    const session_keys = [_]WhichKey{
        .{ .key = "s", .desc = "save session" },
        .{ .key = "l", .desc = "load session" },
        .{ .key = "d", .desc = "delete session" },
    };
    /// `Space u` — the settings a user flips while working. Each is the config
    /// key of the same name, read afresh every frame, so flipping it needs no
    /// reload and does not touch the config file.
    const ui_keys = [_]WhichKey{
        .{ .key = "n", .desc = "relative numbers" },
        .{ .key = "w", .desc = "soft wrap" },
        .{ .key = "d", .desc = "inline diagnostics" },
        .{ .key = "t", .desc = "buffer tabs" },
        .{ .key = "i", .desc = "autoindent" },
        .{ .key = "c", .desc = "auto completion" },
        .{ .key = "f", .desc = "format on save" },
        .{ .key = "m", .desc = "mouse reporting" },
    };
    const buffer_keys = [_]WhichKey{
        .{ .key = "n", .desc = "next buffer" },
        .{ .key = "p", .desc = "previous buffer" },
        .{ .key = "c", .desc = "close others" },
    };
    const find_keys = [_]WhichKey{
        .{ .key = "f", .desc = "find files" },
        .{ .key = "w", .desc = "find words" },
        .{ .key = "b", .desc = "find buffers" },
        .{ .key = "t", .desc = "find themes" },
        .{ .key = "u", .desc = "undo history" },
        .{ .key = "C", .desc = "find commands" },
    };
    const lang_keys = [_]WhichKey{
        .{ .key = "a", .desc = "code action" },
        .{ .key = "r", .desc = "rename symbol" },
        .{ .key = "R", .desc = "references" },
        .{ .key = "s", .desc = "document symbols" },
        .{ .key = "S", .desc = "workspace symbols" },
        .{ .key = "d", .desc = "line diagnostic" },
        .{ .key = "D", .desc = "all diagnostics" },
        .{ .key = "f", .desc = "format buffer" },
    };
    /// `Space x` — the quickfix list. It was complete and reachable only by
    /// typing `:copen`; AstroNvim puts it on `<leader>x`, and `:cnext`/
    /// `:cprev` had no key of their own either.
    const qf_keys = [_]WhichKey{
        .{ .key = "q", .desc = "open the list" },
        .{ .key = "n", .desc = "next entry" },
        .{ .key = "p", .desc = "previous entry" },
        .{ .key = "c", .desc = "close the list" },
        .{ .key = "e", .desc = "edit as one buffer" },
    };
    const git_keys = [_]WhichKey{
        .{ .key = "d", .desc = "diff (inline)" },
        .{ .key = "s", .desc = "diff (side by side)" },
        .{ .key = "l", .desc = "diff (line view)" },
    };

    // The startup screen: a title, the recently-opened list, and the keys that
    // matter on an empty session. Shown only when zedit starts with no file
    // and there is history to show; any other key dismisses it.
    const dash_title = "zedit";

    fn renderDashboard(self: *Editor) !void {
        const th = theme.current;
        const rows = self.win.rows;
        const cols = self.win.cols;
        try self.setBg(th.bg);
        try self.setFg(th.fg);
        // Clear the screen ourselves (this frame is written whole).
        var r: usize = 1;
        while (r <= rows) : (r += 1) {
            try self.emitFmt("\x1b[{d};1H", .{r});
            try self.emit(ansi.clear_line_right);
        }

        const shown = @min(self.recents.entries.items.len, if (rows > 12) rows - 10 else 3);
        const block_h = shown + 6; // title, version, blank, heading, list, hint
        var row = if (rows > block_h) (rows - block_h) / 2 else 1;
        const left_pad = if (cols > 52) (cols - 52) / 2 else 0;

        try self.emitFmt("\x1b[{d};{d}H", .{ row, left_pad + 1 });
        try self.setFg(th.mode_normal);
        try self.emit(dash_title);
        try self.setFg(th.fg_dim);
        try self.emitFmt("  {s}", .{cli.version});
        row += 2;

        try self.emitFmt("\x1b[{d};{d}H", .{ row, left_pad + 1 });
        try self.setFg(th.comment);
        try self.emit("Recent");
        row += 1;

        const avail = if (cols > left_pad + 6) cols - left_pad - 6 else 20;
        for (self.recents.entries.items[0..shown], 0..) |e, i| {
            try self.emitFmt("\x1b[{d};{d}H", .{ row + i, left_pad + 1 });
            const selected = i == self.dash_sel;
            try self.setBg(if (selected) th.selection else th.bg);
            try self.setFg(th.mode_command);
            try self.emitFmt(" {d} ", .{i + 1}); // 1-9 jump straight to an entry

            // Name first so it survives clipping, then the location dimmed.
            const split = dashSplit(e);
            try self.setFg(if (e.kind == .dir) th.type_ else th.fg);
            const name_w = @min(split.name.len, avail);
            try self.emitSanitized(split.name[0..name_w]);
            if (split.where.len > 0 and avail > name_w + 2) {
                try self.setFg(th.fg_dim);
                try self.emit("  ");
                const room = avail - name_w - 2;
                // Long locations lose their *middle*, keeping the root and the
                // parent directory legible.
                if (split.where.len <= room) {
                    try self.emitSanitized(split.where);
                } else if (room > 4) {
                    const head = room / 2 - 1;
                    try self.emitSanitized(split.where[0..head]);
                    try self.emit("\u{2026}");
                    try self.emitSanitized(split.where[split.where.len - (room - head - 1) ..]);
                }
            }
            try self.setBg(th.bg);
            try self.emit(ansi.clear_line_right);
        }
        row += shown + 1;

        try self.emitFmt("\x1b[{d};{d}H", .{ row, left_pad + 1 });
        try self.setFg(th.fg_dim);
        try self.emit("j/k select   Enter open   1-9 jump   Space f f files   q quit");
    }

    /// A recent entry split for display: the leaf name (always shown) and
    /// where it lives (dimmed, elided when long). `$HOME` shortens to `~`, and
    /// a remote entry keeps its `ssh://host/...` prefix so the machine is
    /// obvious at a glance.
    const DashSplit = struct { name: []const u8, where: []const u8 };

    fn dashSplit(e: recent.Entry) DashSplit {
        const p = e.path;
        const cut = std.mem.lastIndexOfScalar(u8, p, '/') orelse return .{ .name = p, .where = "" };
        // A directory's own name is its leaf; its location is the parent.
        const name = if (cut + 1 < p.len) p[cut + 1 ..] else p;
        var where = if (cut == 0) "/" else p[0..cut];
        if (std.c.getenv("HOME")) |home_z| {
            const home = std.mem.sliceTo(home_z, 0);
            if (home.len > 1 and std.mem.startsWith(u8, where, home)) {
                // Reuse the tail so no allocation is needed while rendering.
                where = where[home.len - 1 ..];
            }
        }
        return .{ .name = name, .where = where };
    }

    /// Keys while the startup screen is up. Returns false for keys it does not
    /// own, so the caller dismisses the screen and dispatches them normally —
    /// the screen never gets in the way of editing.
    fn dashboardKey(self: *Editor, k: key.Key) !bool {
        const n = self.recents.entries.items.len;
        switch (k) {
            .char => |c| switch (c) {
                'j' => {
                    if (self.dash_sel + 1 < n) self.dash_sel += 1;
                    return true;
                },
                'k' => {
                    if (self.dash_sel > 0) self.dash_sel -= 1;
                    return true;
                },
                'q' => {
                    self.quit = true;
                    return true;
                },
                '1'...'9' => {
                    const idx = c - '1';
                    if (idx < n) {
                        self.dash_sel = idx;
                        try self.openRecent(idx);
                    }
                    return true;
                },
                else => return false,
            },
            .down => {
                if (self.dash_sel + 1 < n) self.dash_sel += 1;
                return true;
            },
            .up => {
                if (self.dash_sel > 0) self.dash_sel -= 1;
                return true;
            },
            .enter => {
                try self.openRecent(self.dash_sel);
                return true;
            },
            else => return false,
        }
    }

    /// Open recent entry `idx`: a file directly, a directory by entering it
    /// (locally) or listing it over ssh, then showing the file picker.
    fn openRecent(self: *Editor, idx: usize) !void {
        if (idx >= self.recents.entries.items.len) return;
        const e = self.recents.entries.items[idx];
        const path = self.gpa.dupe(u8, e.path) catch return;
        defer self.gpa.free(path);
        self.dashboard = false;
        switch (e.kind) {
            .file => self.openFile(path, 0),
            .dir => self.enterDir(path),
        }
    }

    /// Make `path` the picker's root: a local directory becomes the working
    /// directory; a remote one is listed over ssh.
    fn enterDir(self: *Editor, path: []const u8) void {
        if (remote.isRemote(path)) {
            self.setRemoteRoot(path);
            self.openFilePicker();
            return;
        }
        std.process.setCurrentPath(self.io, path) catch {
            self.setStatus("cannot enter {s}", .{path});
            return;
        };
        self.noteRecent(path, .dir);
        self.refreshFileCache();
        self.openFilePicker();
    }

    /// Open a remote directory as the session's picker root (`zedit ssh://…`).
    pub fn openRemoteDir(self: *Editor, url: []const u8) void {
        self.setRemoteRoot(url);
        self.openBrowser();
    }

    /// The view for "opened on a directory": the file tree on the left and the
    /// picker (with its preview) filling the rest, so an empty session lands
    /// somewhere useful instead of on a blank buffer.
    pub fn openBrowser(self: *Editor) void {
        if (!self.sb_open) {
            self.sb_open = true;
            self.sbRebuild();
        }
        self.sb_focus = false; // typing goes to the search box
        self.openFilePicker();
        // One-time scope hint (the next keystroke clears it): a directory
        // session lands here, where "search" too easily reads as content
        // search. Remote sessions skip it — no remote grep exists.
        if (self.remote_root == null)
            self.setStatus("type to match file NAMES \u{2014} Space f w searches file contents", .{});
    }

    /// Record the working directory in the recent list (`zedit .`).
    pub fn noteRecentCwd(self: *Editor) void {
        const cwd = std.process.currentPathAlloc(self.io, self.gpa) catch return;
        defer self.gpa.free(cwd);
        self.recents.touch(.dir, cwd);
    }

    /// `:ssh [user@]host[:port][/dir]`: point the picker at a remote machine.
    /// A bare host browses its home directory (`~`, which the remote shell
    /// expands), otherwise the given directory.
    fn openRemote(self: *Editor, spec: []const u8) void {
        var url: std.ArrayList(u8) = .empty;
        defer url.deinit(self.gpa);
        if (!remote.isRemote(spec)) url.appendSlice(self.gpa, remote.scheme) catch return;
        url.appendSlice(self.gpa, spec) catch return;
        // No path given: browse the login directory.
        const after_scheme = url.items[remote.scheme.len..];
        if (std.mem.indexOfScalar(u8, after_scheme, '/') == null) url.appendSlice(self.gpa, "/.") catch return;
        const target = remote.parse(url.items) orelse return self.setStatus("bad ssh target: {s}", .{spec});
        self.setStatus("connecting to {s}…", .{target.dest});
        self.render() catch {};
        if (!remote.isDir(self.gpa, self.io, target)) {
            // Not a directory: treat it as a file to open.
            self.openFile(url.items, 0);
            return;
        }
        self.setRemoteRoot(url.items);
        self.openFilePicker();
        self.setStatus("{s}: {d} files", .{ target.dest, self.fcache.items.len });
    }

    /// `:update` — ask the release remote for its newest `v*` tag and compare
    /// it with this build's version.
    fn checkForUpdate(self: *Editor) void {
        switch (fetchNewestTag(self.gpa, self.io)) {
            .no_git => self.setStatus("update check failed (git not available?)", .{}),
            .no_network => self.setStatus("update check failed (no network?)", .{}),
            .failed => self.setStatus("update check failed", .{}),
            .no_release => self.setStatus("no releases published yet", .{}),
            .tag => |newest| {
                defer self.gpa.free(newest);
                switch (compareVersions(newest, cli.version)) {
                    .gt => self.setStatus("update available: {s} (you have {s})", .{ newest, cli.version }),
                    else => self.setStatus("up to date ({s})", .{cli.version}),
                }
            },
        }
    }

    fn setRemoteRoot(self: *Editor, url: []const u8) void {
        if (self.remote_root) |r| self.gpa.free(r);
        self.remote_root = self.gpa.dupe(u8, url) catch null;
        self.noteRecent(url, .dir);
        self.refreshFileCache();
    }

    /// The powerline title bar across screen row 1: an "EXPLORER" segment
    /// spanning the sidebar's columns (when it is open) and one tab per open
    /// buffer over the text area — the active one an accent-coloured segment,
    /// inactive ones dim on `status_bg`, dirty ones marked with a dot.
    /// The screen width one tab occupies, including its trailing powerline
    /// separator. The renderer and the click hit-test both use this, so a tab
    /// can never be drawn at one place and clicked at another.
    /// The cells a tab occupies: a leading space, the name, the dirty dot when
    /// there is one, then the close box (`close_cells`) and the separator.
    /// A buffer tab is a flat box — a padded run of its own background, the
    /// same shape the terminal tabs use. No powerline separator between them:
    /// the colour change already reads as the boundary, and an arrow between
    /// every pair made a row of tabs look like a breadcrumb trail rather than
    /// a set of them. The EXPLORER header keeps its separator, since that is
    /// a transition *into* the tabs rather than one between them.
    fn tabCells(doc: *Doc) usize {
        const name = std.fs.path.basename(docLabel(doc));
        return 2 + unicode.displayWidth(name) + @as(usize, if (doc.buf.dirty) 2 else 0) +
            close_cells;
    }

    /// ` ✕` — the click target that closes a buffer, VS Code's and Zed's tab
    /// button. Always drawn rather than shown on hover: hovering needs mouse
    /// mode 1003, which reports *every* pointer movement and would wake the
    /// editor thousands of times while it should be idle. A visible button
    /// costs two columns and no wake-ups.
    const close_cells: usize = 2;

    /// Where the tabs live on row 1: their first column and the width they
    /// may use — the text area, beside the sidebar's columns. Shared by the
    /// renderer and `tabAt` (the invariant above).
    const TabArea = struct { x0: usize, w: usize };
    fn tabArea(self: *Editor) TabArea {
        const sb_w: usize = if (self.sb_open) self.sbWidth() else 0;
        const x0: usize = if (self.sb_open and config.settings.sidebar == .left) sb_w + 1 else 1;
        return .{ .x0 = x0, .w = self.win.cols - sb_w };
    }

    /// The document whose tab covers 1-based screen column `col`, if any.
    /// Clicks on the EXPLORER segment or the filler resolve to null.
    /// What a click on the tab row lands on: a buffer, and whether it hit that
    /// tab's close box rather than its name.
    const TabHit = struct { doc: *Doc, close: bool };

    fn tabAt(self: *Editor, col: usize) ?TabHit {
        const area = self.tabArea();
        var x = area.x0;
        for (self.docs.items) |doc| {
            if (doc.shell != null) continue; // terminals have their own row
            const w = tabCells(doc);
            if (x + w > area.x0 + area.w) break;
            if (col >= x and col < x + w) {
                // The close box is the last two cells of the tab.
                const box_start = x + w - close_cells;
                return .{ .doc = doc, .close = col >= box_start };
            }
            x += w;
        }
        return null;
    }

    /// A tab's segment colour: the accent for the active buffer (the mode
    /// block's aesthetic — unmistakable), the statusline base for the rest.
    fn tabBg(self: *Editor, doc: *Doc) Color {
        const th = theme.current;
        return if (doc == self.d) th.mode_normal else th.status_bg;
    }

    fn renderTitleBar(self: *Editor) !void {
        const th = theme.current;
        const area = self.tabArea();
        const sb_w: usize = if (self.sb_open) self.sbWidth() else 0;
        const hdr_bg = if (self.sb_focus) th.mode_command else th.status_seg_bg;
        const hdr_fg = if (self.sb_focus) th.bg else th.status_seg_fg;
        const hdr = " EXPLORER";

        self.beginSeg(1, 1);
        try self.emitFmt("\x1b[1;1H", .{});

        if (self.sb_open and config.settings.sidebar == .left) {
            // The EXPLORER segment spans the sidebar width, ending in a
            // separator that transitions into the first tab's colour.
            // A flat box, like the tabs beside it: the colour change is the
            // boundary, so the arrow that used to end the header is gone too.
            const shown = @min(hdr.len, sb_w);
            try self.setBg(hdr_bg);
            try self.setFg(hdr_fg);
            try self.emit(hdr[0..shown]);
            try self.emitSpaces(sb_w -| shown);
        }

        var used: usize = 0;
        for (self.docs.items) |doc| {
            if (doc.shell != null) continue; // terminals get their own row
            const w = tabCells(doc);
            if (used + w > area.w) break;
            const bg = self.tabBg(doc);
            try self.setBg(bg);
            try self.setFg(if (doc == self.d) th.bg else th.fg_dim);
            try self.emit(" ");
            try self.emitSanitized(std.fs.path.basename(docLabel(doc)));
            if (doc.buf.dirty) try self.emit(" \u{25CF}");
            try self.emit(" \u{2715}"); // ✕ — click it to close this buffer
            try self.emit(" ");
            used += w;
        }

        try self.setBg(th.status_bg);
        const fill = area.w - used;
        if (self.sb_open and config.settings.sidebar == .right) {
            // Mirrored: filler, a left-pointing separator, then the segment.
            if (sepCells() > 0 and fill > 0) {
                try self.emitSpaces(fill - 1);
                try self.setFg(hdr_bg);
                try self.emit(sepLeft());
            } else {
                try self.emitSpaces(fill);
            }
            try self.setBg(hdr_bg);
            try self.setFg(hdr_fg);
            const shown = @min(hdr.len, sb_w);
            try self.emit(hdr[0..shown]);
            try self.emitSpaces(sb_w - shown);
        } else {
            try self.emitSpaces(fill);
        }
        self.closeSegs();
    }

    /// Draw the completion candidates ("wildmenu") as a vertical popup just
    /// above the command line, the selected one highlighted — the look of
    /// nvim's cmdline popup menu.
    fn renderWildMenu(self: *Editor) !void {
        const th = theme.current;
        const items = self.wild.items;
        // Sit above the command line, which is more than one row when it wraps.
        const rows: usize = self.cmdBlock().top;
        const height = @min(items.len, 8);
        if (rows < height + 2) return;

        // Scroll the window to keep the selection visible.
        const sel = self.wild_idx orelse 0;
        var first: usize = 0;
        if (sel >= height) first = sel - height + 1;
        if (first + height > items.len) first = items.len - height;

        var width: usize = 12;
        for (items) |w| width = @max(width, unicode.displayWidth(w.text[w.show..]) + 2);
        width = @min(width, self.win.cols -| 1);
        // Anchor at the column of the token being completed (nvim's pum).
        const anchor = @min(self.cmdPrompt().len + items[0].show + 1, self.win.cols -| width);

        self.markOverlayRows(rows - height, rows - 1);
        var i: usize = 0;
        while (i < height) : (i += 1) {
            const idx = first + i;
            try self.emitFmt("\x1b[{d};{d}H", .{ rows - height + i, anchor });
            const selected = self.wild_idx != null and idx == self.wild_idx.?;
            try self.setBg(if (selected) th.mode_command else th.status_seg_bg);
            try self.setFg(if (selected) th.bg else th.status_seg_fg);
            const w = items[idx];
            const shown = w.text[w.show..];
            try self.emit(" ");
            // Clip by display cells on a codepoint boundary (same helper as
            // the cmdline row): a byte clip tears wide names into '?' and
            // counts cells the row never painted.
            const clip = clipCells(shown, width -| 2);
            try self.emitSanitized(shown[0..clip.bytes]);
            const used = 1 + clip.cells;
            if (used < width) try self.emitSpaces(width - used);
        }
    }

    /// The popup's title and contents for the pending leader state, or null
    /// when no leader menu is up. The single source of truth: the render gate
    /// and the popup both read it, so a new group added to the key dispatch
    /// cannot be forgotten in the renderer — which is exactly what happened to
    /// `Space g`, and would have happened again to `Space u`.
    fn whichKeyMenu(self: *Editor) ?struct { title: []const u8, keys: []const WhichKey } {
        return switch (self.await_arg) {
            .space_leader => .{ .title = " SPACE", .keys = &leader_keys },
            .space_find => .{ .title = " SPACE f", .keys = &find_keys },
            .space_lang => .{ .title = " SPACE l", .keys = &lang_keys },
            .space_git => .{ .title = " SPACE g", .keys = &git_keys },
            .space_buffer => .{ .title = " SPACE b", .keys = &buffer_keys },
            .space_ui => .{ .title = " SPACE u", .keys = &ui_keys },
            .space_session => .{ .title = " SPACE S", .keys = &session_keys },
            .space_debug => .{ .title = " SPACE d", .keys = &debug_keys },
            .space_new => .{ .title = " SPACE n", .keys = &new_keys },
            .space_qf => .{ .title = " SPACE x", .keys = &qf_keys },
            else => null,
        };
    }

    /// Draw the which-key popup for the pending leader menu, anchored above the
    /// status bar.
    fn renderWhichKey(self: *Editor) !void {
        const th = theme.current;
        const m = self.whichKeyMenu() orelse return;
        const menu = m.keys;
        const title = m.title;
        const width: usize = 26;
        // Bottom right, where helix puts its keymap infobox: the left of the
        // screen is where the text the keys are about starts, and a menu there
        // covers the first characters of every line under it. `ui.rightEdge`
        // is the same placement the notification stack uses, from the top.
        const box = ui.rightEdge(self.chromeScreen(), width, menu.len + 1, false) orelse return;
        const top = box.y;
        const left = box.x;
        self.markOverlayRows(box.y, box.bottom());

        try self.emitFmt("\x1b[{d};{d}H", .{ top, left });
        try self.setBg(th.mode_command);
        try self.setFg(th.bg);
        try self.emit(title);
        try self.emitSpaces(width - title.len);

        for (menu, 0..) |it, i| {
            try self.emitFmt("\x1b[{d};{d}H", .{ top + 1 + i, left });
            try self.setBg(th.status_seg_bg);
            try self.setFg(th.mode_normal);
            try self.emitFmt("  {s}  ", .{it.key});
            try self.setFg(th.status_seg_fg);
            try self.emit(it.desc);
            const used = 2 + it.key.len + 2 + unicode.displayWidth(it.desc);
            if (used < width) try self.emitSpaces(width - used);
        }
    }

    /// Corner notifications, stacked under the title bar in the top right —
    /// where AstroNvim's nvim-notify puts them, and out of the way of both the
    /// text's left margin and the statusline. Newest at the bottom of the
    /// stack, so a line does not jump as the one above it expires.
    fn renderToasts(self: *Editor) !void {
        const th = theme.current;
        const list = self.toasts.visible();
        if (list.len == 0) return;
        // Widest message, capped so a toast never takes more than half the
        // screen; 2 for the mark, 2 for the padding either side.
        var text_w: usize = 0;
        for (list) |t| text_w = @max(text_w, unicode.displayWidth(t.text()));
        var mark_w: usize = 1;
        for (list) |t| mark_w = @max(mark_w, unicode.displayWidth(t.level.mark()));
        const chrome = mark_w + 3; // " <mark> " plus a trailing space
        const box_w = @min(@max(text_w + chrome, 12), @max(12, self.win.cols / 2));
        const box = ui.rightEdge(self.chromeScreen(), box_w, list.len, true) orelse return;
        const top = box.y;
        const left = box.x;
        self.markOverlayRows(box.y, box.bottom());
        for (list, 0..) |t, i| {
            // No diagnostic colours in the palette; the git triple is the
            // red/amber/green one every theme already defines.
            const fg = switch (t.level) {
                .debug => th.fg_dim, // machinery: present, but never loud
                .info => th.git_add,
                .warn => th.git_change,
                .err => th.git_delete,
            };
            try self.emitFmt("\x1b[{d};{d}H", .{ top + i, left });
            try self.setBg(th.status_seg_bg);
            try self.setFg(fg);
            try self.emitFmt(" {s} ", .{t.level.mark()});
            // Pad a narrow mark out to the widest, so every row's text starts
            // in the same column whatever mix of levels is showing.
            if (unicode.displayWidth(t.level.mark()) < mark_w)
                try self.emitSpaces(mark_w - unicode.displayWidth(t.level.mark()));
            try self.setFg(th.status_seg_fg);
            // Toast text can carry a filename or a server's words, so it goes
            // through the same sanitizer as any other untrusted content.
            const cut = clipCells(t.text(), box_w - chrome);
            try self.emitSanitized(t.text()[0..cut.bytes]);
            const used = chrome - 1 + cut.cells;
            if (used < box_w) try self.emitSpaces(box_w - used);
        }
    }


    /// One-line signature-help popup, anchored just above the cursor (or below
    /// if it is on the top row), with the active parameter emphasized.
    fn renderSignature(self: *Editor, gutter: usize) !void {
        const th = theme.current;
        const client = if (self.lsp) |*c| c else return;
        const sigs = client.signatures.items;
        if (sigs.len == 0) return;
        const sig = sigs[client.sig_active];
        const label = sig.label[0 .. std.mem.indexOfScalar(u8, sig.label, '\n') orelse sig.label.len];
        if (label.len == 0) return;

        const cur_row = self.cur.gy + self.cursorScreenRow(); // 1-based screen row of cursor
        const row = if (cur_row > 1) cur_row - 1 else cur_row + 1;
        self.markOverlayRows(row, row);
        const cur_col = self.cur.gx + gutter + self.cursorScreenCol();
        const col = @max(@as(usize, 1), cur_col);
        if (col > self.win.cols) return;
        const avail = self.win.cols - col + 1; // cells from `col` to the screen edge

        try self.emitFmt("\x1b[{d};{d}H", .{ row, col });
        try self.setBg(th.status_seg_bg);
        try self.emit(" ");
        // Emit the label a codepoint at a time, switching colour over the active
        // parameter's byte range; clip to the available width.
        var used: usize = 1; // the leading space
        var i: usize = 0;
        while (i < label.len) {
            const d = unicode.decode(label[i..]);
            const w = unicode.width(d.cp);
            if (used + w >= avail) break;
            const in_param = sig.active_start != sig.active_end and i >= sig.active_start and i < sig.active_end;
            try self.setFg(if (in_param) th.builtin else th.status_seg_fg);
            try self.emit(if (isControlCp(d.cp) or invalidDecode(d)) "?" else label[i .. i + d.len]);
            used += w;
            i += d.len;
        }
        // An "(i/n)" counter, dim, when there is more than one overload to cycle.
        if (sigs.len > 1) {
            var cb: [32]u8 = undefined;
            const counter = std.fmt.bufPrint(&cb, " ({d}/{d})", .{ client.sig_active + 1, sigs.len }) catch "";
            if (used + counter.len < avail) {
                try self.setFg(th.fg_dim);
                try self.emit(counter);
                used += counter.len;
            }
        }
        try self.setFg(th.status_seg_fg);
        if (used < avail) try self.emit(" ");
    }

    /// Completion popup, anchored under the cursor (or above if near the bottom).
    fn renderCompletion(self: *Editor, gutter: usize) !void {
        const th = theme.current;
        const items = self.comp_filtered.items;
        if (items.len == 0) return;

        const rows = self.textRows();
        const max_h: usize = 8;
        const height = @min(items.len, max_h);

        // Scroll the window so the selection is visible.
        const first = if (self.comp_sel >= height) self.comp_sel - height + 1 else 0;

        // Longest visible label sets the box width (capped).
        var width: usize = 10;
        var vi: usize = 0;
        while (vi < height and first + vi < items.len) : (vi += 1) {
            const label = self.compLabel(items[first + vi]);
            width = @max(width, @min(label.len + 2, 40));
        }

        const rel = self.cursorScreenRow(); // cursor row within the window (0-based)
        // Below the cursor if it fits in the window, else above.
        const start_row = if (rel + 1 + height <= rows)
            self.cur.gy + rel + 1
        else if (rel >= height)
            self.cur.gy + rel - height
        else
            self.cur.gy;
        const col = @max(@as(usize, 1), self.cur.gx + gutter + self.cursorScreenCol());
        self.markOverlayRows(start_row, start_row + height - 1);

        var i: usize = 0;
        while (i < height) : (i += 1) {
            const idx = first + i;
            const selected = idx == self.comp_sel;
            try self.emitFmt("\x1b[{d};{d}H", .{ start_row + i, col });
            try self.setBg(if (selected) th.selection else th.status_seg_bg);
            try self.setFg(if (selected) th.fg else th.status_seg_fg);
            const label = self.compLabel(items[idx]);
            try self.emit(" ");
            const shown = @min(label.len, width - 1);
            try self.emitSanitized(label[0..shown]);
            if (shown + 1 < width) try self.emitSpaces(width - shown - 1);
        }
    }

    fn emitGutter(self: *Editor, view: *const View, file_row: usize) !void {
        const th = theme.current;
        const gutter = view.gutter;
        const ndigits = gutter - 2;
        const is_cur = view.active and file_row == view.cy;

        // Leftmost column, in priority order: a breakpoint (the user put it
        // there deliberately and must be able to see it), then an LSP
        // diagnostic, then a git sign.
        var sign_drawn = false;
        if (view.buf.path) |p| {
            if (self.breakpoints.has(p, file_row + 1)) {
                // Filled while the program is stopped on it, so the stop is
                // visible at a glance among the other breakpoints.
                const here = view.active and self.dbg_line == file_row + 1;
                try self.setFg(if (here) th.git_change else th.git_delete);
                try self.emit("\u{25CF}"); // ●
                sign_drawn = true;
            }
        }
        if (!sign_drawn and view.active) {
            if (self.lsp) |*c| {
                if (c.severityAt(file_row)) |sev| {
                    try self.setFg(if (sev == 1) th.git_delete else th.git_change); // error=red, warn=yellow
                    try self.emit("\u{25CF}"); // ●
                    sign_drawn = true;
                }
            }
        }
        if (!sign_drawn) {
            if (view.git.get(file_row)) |s| {
                try self.setFg(switch (s) {
                    .added => th.git_add,
                    .changed => th.git_change,
                    .deleted => th.git_delete,
                });
                try self.emit(switch (s) {
                    .added, .changed => "\u{2502}", // │
                    .deleted => "\u{2581}", // ▁
                });
            } else {
                try self.emit(" ");
            }
        }

        // Absolute number on the cursor line, relative distance elsewhere
        // (config `relative_numbers = false` makes every number absolute).
        const rel = config.settings.relative_numbers;
        const num = if (is_cur or !rel) file_row + 1 else if (file_row > view.cy) file_row - view.cy else view.cy - file_row;
        var nb: [20]u8 = undefined;
        const ns = std.fmt.bufPrint(&nb, "{d}", .{num}) catch unreachable;
        try self.setFg(if (is_cur) th.gutter_active else th.gutter);
        try self.emitSpaces(ndigits - ns.len);
        try self.emit(ns);
        try self.emit(" ");
    }

    fn emitLine(self: *Editor, view: *const View, row: usize, row_bg: Color, seg: usize, wl: WrapLayout) !void {
        const th = theme.current;
        const line = view.buf.line(row);
        const cols = view.cols;
        // Styling a line is O(line); with soft wrap the same line is drawn once
        // per screen row it fills, so the result is kept until another line (or
        // another buffer) needs the buffer. On a 1.8 MB single-line file this
        // is the difference between 430 ms and a few ms per frame.
        const styled = self.style_row == row and self.style_buf_of == view.buf and self.style_buf.items.len == line.len;
        if (!styled) self.style_buf.resize(self.gpa, line.len) catch {};
        if (!styled and self.style_buf.items.len == line.len) {
            self.style_row = row;
            self.style_buf_of = view.buf;
            if (view.has_ts and row < view.ts_line_starts.len) {
                // Tree-sitter: read this line's styles out of the visible-range
                // buffer, which starts at document byte `ts_vis_start`.
                const lstart = view.ts_line_starts[row];
                for (self.style_buf.items, 0..) |*s, i| {
                    const abs = lstart + i;
                    s.* = if (abs >= view.ts_vis_start and abs - view.ts_vis_start < view.ts_styles.len)
                        view.ts_styles[abs - view.ts_vis_start]
                    else
                        .normal;
                }
            } else {
                syntax.highlight(view.lang, line, self.style_buf.items);
            }
        }

        // Selection / multi-cursor / search / inlay apply to the active window only.
        const sel = if (view.active) self.selectionRange(row) else null;
        const ecol = if (view.active) self.extraColAt(row) else null;
        const xsel = if (view.active) self.extraSelRange(row) else null;
        const first_nb = motion.firstNonBlank(line);
        const indent_cols = displayCol(line, first_nb);

        // Inlay hints on this row: byte offset within the line + virtual text,
        // sorted by position so they can be emitted as the byte-walk reaches them.
        var hbyte: [32]usize = undefined;
        var htext: [32][]const u8 = undefined;
        var hint_n: usize = 0;
        if (view.active) {
            if (self.lsp) |*client| {
                for (client.inlay_hints.items) |hint| {
                    if (hint.line != row or hint_n >= hbyte.len) continue;
                    hbyte[hint_n] = byteAtCharCol(line, hint.col);
                    htext[hint_n] = hint.text;
                    hint_n += 1;
                }
                var a: usize = 1;
                while (a < hint_n) : (a += 1) { // insertion sort (lists are tiny)
                    var b = a;
                    while (b > 0 and hbyte[b - 1] > hbyte[b]) : (b -= 1) {
                        std.mem.swap(usize, &hbyte[b - 1], &hbyte[b]);
                        std.mem.swap([]const u8, &htext[b - 1], &htext[b]);
                    }
                }
            }
        }
        var hi: usize = 0;

        // Search-match ranges on this line (for highlighting).
        var mstarts: [64]usize = undefined;
        var mends: [64]usize = undefined;
        var mcount: usize = 0;
        const search_re: ?*const regex.Regex = if (view.active) self.compiledPattern(self.activeSearchTerm()) else null;
        if (search_re) |re| {
            var off: usize = 0;
            while (mcount < mstarts.len and off <= line.len) {
                const m = re.find(line, off) orelse break;
                if (m.span.end > m.span.start) { // zero-width matches aren't highlightable
                    mstarts[mcount] = m.span.start;
                    mends[mcount] = m.span.end;
                    mcount += 1;
                }
                off = if (m.span.end > m.span.start) m.span.end else m.span.start + 1;
            }
        }
        var mi: usize = 0;

        // Wrapping renders the slice of the line belonging to this screen row,
        // after the indent a continuation row hangs under; otherwise the window
        // is the horizontal scroll position. Everything below clips to
        // [left, right), so this is the whole of it.
        const pad = if (view.wrap) wl.pad(seg) else 0;
        const left = if (view.wrap) wl.starts[seg] else view.left;
        const usable = cols - pad;
        // A row ends where the next one begins — at the word break, not at the
        // window edge — so a wrapped word is drawn once, and a `wrap_column`
        // narrower than the window is honoured.
        const right = if (view.wrap and seg + 1 < wl.n) wl.starts[seg + 1] else left + usable;
        if (pad > 0) {
            try self.setBg(row_bg);
            try self.emitSpaces(pad);
        }
        var dc: usize = 0;
        var i: usize = 0;
        while (i < line.len) {
            // Inlay hints positioned before the char at byte i (advances dc so
            // the line still clips correctly at the screen edge).
            while (hi < hint_n and hbyte[hi] == i) : (hi += 1)
                try self.emitInlayText(htext[hi], &dc, left, right, row_bg);
            const d = unicode.decode(line[i..]);
            const w = cellWidth(d.cp, dc);
            const start = dc;
            const byte = i;
            dc += w;
            const bytes = line[i .. i + d.len];
            i += d.len;

            if (start + w <= left) continue;
            if (start >= right) break;

            const is_extra = if (ecol) |ec| byte == ec else false;
            const selected = (if (sel) |s| (byte >= s.lo and byte < s.hi) else false) or
                (if (xsel) |x| (byte >= x.lo and byte < x.hi) else false);
            while (mi < mcount and byte >= mends[mi]) mi += 1;
            const in_match = mi < mcount and byte >= mstarts[mi] and byte < mends[mi];
            try self.setBg(if (is_extra) th.mode_normal else if (selected) th.selection else if (in_match) th.match else row_bg);

            if (d.cp == '\t' or d.cp == ' ' or start < left or start + w > right) {
                var c = if (start < left) left else start;
                while (c < start + w and c < right) : (c += 1) {
                    if (byte < first_nb and c % tabWidth() == 0 and c < indent_cols) {
                        try self.setFg(th.cursorline);
                        try self.emit(indent_glyph);
                    } else {
                        try self.emit(" ");
                    }
                }
            } else {
                const stl = if (byte < self.style_buf.items.len) self.style_buf.items[byte] else .normal;
                try self.setFg(if (is_extra) th.bg else if (in_match) th.fg else self.styleColor(stl));
                try self.emit(if (isControlCp(d.cp) or invalidDecode(d)) "?" else bytes);
            }
        }
        // Inlay hints anchored at end-of-line (e.g. return-type hints).
        while (hi < hint_n) : (hi += 1)
            try self.emitInlayText(htext[hi], &dc, left, right, row_bg);

        // Inline diagnostic: the server's message for this line, dim and
        // severity-coloured after the code (helix/nvim's virtual text).
        if (view.active and config.settings.inline_diagnostics) {
            if (self.diagnosticInline(row)) |diag| {
                try self.emitDiagnosticText(diag.text, diag.severity, &dc, left, right, row_bg);
            }
        }

        // Pad the rest of the window's text width with the row background, so a
        // window never leaks stale cells or the contents of a neighbour to its
        // right. A secondary cursor sitting at end-of-line is drawn here.
        const eol_cursor = if (ecol) |ec| ec == line.len else false;
        const eol_col = if (eol_cursor) displayCol(line, line.len) else 0; // O(line): only when needed
        var shown: usize = if (dc > left) @min(dc - left, usable) else 0;
        while (shown < usable) : (shown += 1) {
            const at_cursor = eol_cursor and (left + shown == eol_col);
            try self.setBg(if (at_cursor) th.mode_normal else row_bg);
            try self.emit(" ");
        }
    }

    const InlineDiag = struct { text: []const u8, severity: u8 };

    /// The diagnostic to show inline on `row`: the message's first line
    /// (multi-line server messages would break the row).
    fn diagnosticInline(self: *Editor, row: usize) ?InlineDiag {
        const client = if (self.lsp) |*c| c else return null;
        const msg = client.messageAt(row) orelse return null;
        const end = std.mem.indexOfScalar(u8, msg, '\n') orelse msg.len;
        if (end == 0) return null;
        return .{ .text = msg[0..end], .severity = client.severityAt(row) orelse 1 };
    }

    /// Emit an inline diagnostic after the code: a separator, then the message
    /// in a dimmed severity colour, clipped to the window like any virtual
    /// text. Never touches the buffer, so it cannot be edited or saved.
    fn emitDiagnosticText(self: *Editor, text: []const u8, severity: u8, dc: *usize, left: usize, right: usize, row_bg: Color) !void {
        const th = theme.current;
        const base = switch (severity) {
            1 => th.git_delete, // error
            2 => th.git_change, // warning
            else => th.comment, // info / hint
        };
        try self.setBg(row_bg);
        try self.setFg(mixColor(th.bg, base, 70)); // subordinate to the code
        try self.emitVirtual("  \u{25B8} ", dc, left, right); // ▸
        try self.emitVirtual(text, dc, left, right);
    }

    /// Emit virtual (non-buffer) text one codepoint at a time, advancing the
    /// rendered column and clipping to [left, right). Control bytes are
    /// sanitized — an LSP message is untrusted input.
    fn emitVirtual(self: *Editor, text: []const u8, dc: *usize, left: usize, right: usize) !void {
        var j: usize = 0;
        while (j < text.len) {
            const d = unicode.decode(text[j..]);
            const w = cellWidth(d.cp, dc.*);
            const start = dc.*;
            dc.* += w;
            const bytes = text[j .. j + d.len];
            j += d.len;
            if (start + w <= left) continue;
            if (start >= right) break;
            try self.emit(if (isControlCp(d.cp) or invalidDecode(d)) "?" else bytes);
        }
    }

    /// Emit inlay-hint virtual text (dim), one codepoint at a time, advancing
    /// the rendered column `dc` and clipping to the visible window [left, right).
    fn emitInlayText(self: *Editor, text: []const u8, dc: *usize, left: usize, right: usize, row_bg: Color) !void {
        try self.setBg(row_bg);
        try self.setFg(theme.current.comment);
        try self.emitVirtual(text, dc, left, right);
    }

    fn styleColor(_: *Editor, s: syntax.Style) Color {
        const th = theme.current;
        return switch (s) {
            .normal => th.fg,
            .comment => th.comment,
            .keyword => th.keyword,
            .type_ => th.type_,
            .builtin => th.builtin,
            .function => th.function,
            .string_ => th.string_,
            .char_ => th.string_,
            .number => th.number,
            .operator => th.operator,
            .preproc => th.preproc,
            .diff_add => th.git_add,
            .diff_del => th.git_delete,
        };
    }

    fn setFg(self: *Editor, c: Color) !void {
        if (self.cur_fg) |f| {
            if (f.r == c.r and f.g == c.g and f.b == c.b) return;
        }
        var b: [24]u8 = undefined;
        try self.emit(c.fg(&b));
        self.cur_fg = c;
    }

    fn setBg(self: *Editor, c: Color) !void {
        if (self.cur_bg) |f| {
            if (f.r == c.r and f.g == c.g and f.b == c.b) return;
        }
        var b: [24]u8 = undefined;
        try self.emit(c.bg(&b));
        self.cur_bg = c;
    }

    const SelRange = struct { lo: usize, hi: usize };

    fn selectionRange(self: *Editor, row: usize) ?SelRange {
        if (self.mode == .visual_block) {
            const rr = self.blockCols();
            if (row < rr.top or row > rr.bot) return null;
            const line = self.buf.line(row);
            return .{ .lo = byteAtDisplayCol(line, rr.left), .hi = byteAtDisplayCol(line, rr.right + 1) };
        }
        if (self.mode != .visual and self.mode != .visual_line) return null;
        var a = self.vstart;
        var b = self.cursor();
        if (cmpPos(b, a) < 0) {
            const tmp = a;
            a = b;
            b = tmp;
        }
        if (row < a.row or row > b.row) return null;
        if (self.mode == .visual_line) return .{ .lo = 0, .hi = self.buf.line(row).len };
        const line = self.buf.line(row);
        const lo = if (row == a.row) a.col else 0;
        const hi = if (row == b.row) unicode.nextBoundary(line, b.col) else line.len;
        return .{ .lo = lo, .hi = hi };
    }

    /// The command line's screen block. nvim never scrolls the command line
    /// sideways: a line wider than the row wraps onto further rows and the
    /// command-line area grows *upward* over the window. Probe H1 (20 columns,
    /// ":0123456789012345678901234") painted ":0123456789012345678" on one row
    /// and "901234" on the next, with the cursor at column 6 of it; probe H9
    /// filled three rows. So the block is `height` rows ending at the last
    /// screen row.
    const CmdBlock = struct {
        height: usize, // screen rows it covers
        top: usize, // 1-based screen row it starts at
        first: usize, // wrapped row drawn at `top` (non-zero only past the screen)
        cur_row: usize, // wrapped row the cursor is on
        cur_col: usize, // 0-based column within that row
    };

    fn cmdBlock(self: *Editor) CmdBlock {
        const cols = @max(self.win.cols, 1);
        const promptw = @min(self.cmdPrompt().len, cols - 1);
        var off: usize = 0;
        var row: usize = 0;
        var cur_row: usize = 0;
        var cur_col: usize = promptw;
        // Each row takes as much as fits in its cells — `cmdRowSplit` is the
        // same break the renderer makes, so a wide char that would straddle
        // the edge starts the next row instead of being torn.
        while (true) {
            const budget = if (row == 0) cols - promptw else cols;
            const seg = cmdRowSplit(self.cmd.items[off..], budget, budget == cols);
            const end = off + seg.bytes;
            if (self.cmd_cur >= off and self.cmd_cur <= end) {
                const before = clipCells(self.cmd.items[off..self.cmd_cur], budget);
                cur_row = row;
                cur_col = (if (row == 0) promptw else 0) + before.cells;
                // A cursor past the last cell of a full row belongs to the row
                // below (probe H6: a line filling the row exactly left the
                // cursor at column 0 of the next one).
                if (cur_col >= cols) {
                    cur_row += 1;
                    cur_col = 0;
                }
            }
            if (end >= self.cmd.items.len) break;
            off = end;
            row += 1;
        }
        const need = @max(row + 1, cur_row + 1);
        const height = @min(need, self.win.rows);
        var first = need - height; // bottom-anchored: the tail of a huge line
        if (cur_row < first) first = cur_row; // …but never off the cursor's row
        return .{
            .height = height,
            .top = self.win.rows + 1 - height,
            .first = first,
            .cur_row = cur_row,
            .cur_col = cur_col,
        };
    }

    /// Paint the command line over its block, bottom row last. The typed text
    /// and the ghost are clipped to each row by display cells on codepoint
    /// boundaries (a byte clip underfills the row on wide chars and can tear a
    /// codepoint), and every byte goes through the render sanitizer.
    fn renderCmdline(self: *Editor) !void {
        const th = theme.current;
        const cols = @max(self.win.cols, 1);
        const blk = self.cmdBlock();
        // The rows above the status line belong to the windows: mark them so
        // the next frame repaints them instead of trusting the diff.
        if (blk.height > 1) self.markOverlayRows(blk.top, self.win.rows - 1);
        const prompt = self.cmdPrompt();
        const promptw = @min(prompt.len, cols - 1);

        var off: usize = 0;
        var row: usize = 0;
        while (row < blk.first + blk.height) : (row += 1) {
            const budget = if (row == 0) cols - promptw else cols;
            const seg = cmdRowSplit(self.cmd.items[off..], budget, budget == cols);
            if (row >= blk.first) {
                try self.emitFmt("\x1b[{d};1H", .{blk.top + row - blk.first});
                try self.setBg(th.status_bg);
                try self.setFg(th.fg);
                if (row == 0) try self.emit(prompt[0..promptw]);
                try self.emitSanitized(self.cmd.items[off..][0..seg.bytes]);
                var pad = budget - seg.cells;
                // A row cut short by a double-width char that did not fit
                // keeps a spare cell, and vim marks it '>' (nvim probe, 20
                // columns: ":012345678901234567日本" painted
                // ":012345678901234567>" then "日本").
                if (pad > 0 and off + seg.bytes < self.cmd.items.len) {
                    try self.emit(">");
                    pad -= 1;
                }
                // Inline suggestion: the rest of the best match, dim, painted
                // after the terminal cursor — so on the cursor's row, only
                // with the cursor at end-of-line (fish hides suggestions
                // mid-line) and never while the wildmenu ring holds the line.
                if (row == blk.cur_row and self.wild.items.len == 0 and
                    self.ghost.items.len > 0 and self.cmd_cur == self.cmd.items.len)
                {
                    const g = clipCells(self.ghost.items, pad);
                    try self.setFg(th.fg_dim);
                    try self.emitSanitized(self.ghost.items[0..g.bytes]);
                    pad -= g.cells;
                }
                try self.emitSpaces(pad);
            }
            off += seg.bytes;
        }
        // While c_CTRL-R waits for a register name, vim draws a `"` at the
        // cursor (probe R8: ":abc" + Ctrl-R rendered ':abc"').
        if (self.cmd_reg) {
            try self.emitFmt("\x1b[{d};{d}H", .{ blk.top + blk.cur_row - blk.first, blk.cur_col + 1 });
            try self.setBg(th.status_bg);
            try self.setFg(th.fg);
            try self.emit("\"");
        }
    }

    fn renderStatus(self: *Editor) !void {
        const th = theme.current;
        const cols: usize = self.win.cols;

        // Command / search line: the prompt across the bar — over several rows
        // when the line is wider than one (see `renderCmdline`).
        if (self.mode == .command) return try self.renderCmdline();

        const accent = self.modeColor();
        const label = self.modeLabel();

        // Left: [ MODE ] file — but the file (and its dirty dot) lives in the
        // title bar's tab when that row is shown, so it leaves the statusline.
        try self.setBg(accent);
        try self.setFg(th.bg);
        try self.emitFmt(" {s} ", .{label});
        var fb: [320]u8 = undefined;
        var fileseg: []const u8 = "";
        if (tabsVisible()) {
            try self.setBg(th.status_bg);
            try self.setFg(accent);
            try self.emit(sepRight());
        } else {
            try self.setBg(th.status_seg_bg);
            try self.setFg(accent);
            try self.emit(sepRight());
            const fname = docLabel(self.d);
            const dirty = if (self.buf.dirty) " \u{25CF}" else "";
            fileseg = std.fmt.bufPrint(&fb, " {s}{s} ", .{ fname, dirty }) catch " ";
            try self.setBg(th.status_seg_bg);
            try self.setFg(th.status_seg_fg);
            try self.emitSanitized(fileseg);
            try self.setBg(th.status_bg);
            try self.setFg(th.status_seg_bg);
            try self.emit(sepRight());
        }

        // Separators are 0 cells wide in flat (nerd_font = false) mode; the
        // widths must say so or the bar is painted short of the right edge.
        const file_w = if (tabsVisible()) 0 else unicode.displayWidth(fileseg) + sepCells();
        const left_w = (label.len + 2) + sepCells() + file_w;

        // Right: filetype + position | percentage
        var rb: [96]u8 = undefined;
        const rseg = std.fmt.bufPrint(&rb, " {s}  Ln {d}, Col {d} ", .{
            syntax.name(self.lang), self.cy + 1, displayCol(self.curLine(), self.cx) + 1,
        }) catch " ";
        var pb: [16]u8 = undefined;
        const lines = self.buf.lineCount();
        const pct: usize = if (lines <= 1) 100 else (self.cy * 100) / (lines - 1);
        const pctseg = std.fmt.bufPrint(&pb, " {d}% ", .{pct}) catch " ";
        const right_w = sepCells() + rseg.len + sepCells() + pctseg.len;

        // Middle: status message on the left, the partial command (showcmd)
        // right-aligned against the position segment, as vim places it.
        var mb: [256]u8 = undefined;
        const middle = if (self.status.items.len > 0)
            self.status.items
        else if (self.lspMiddle(&mb)) |m|
            m
        else if (self.extra.items.len > 0)
            (std.fmt.bufPrint(&mb, "{d} cursors", .{self.extra.items.len + 1}) catch "")
        else
            "";
        var pb2: [32]u8 = undefined;
        // A *finished* command yields the width to a status message; a pending
        // one keeps its slot, since it tells you the editor is waiting on you.
        const pending = if (middle.len > 0 and self.showcmd_done and self.recording == null)
            ""
        else
            self.pendingKeys(&pb2);
        const mid_w = if (cols > left_w + right_w) cols - left_w - right_w else 0;
        try self.setBg(th.status_bg);
        try self.setFg(th.fg_dim);
        // Reserve nothing when no command is pending, so status messages keep
        // the full width they had before the indicator existed.
        const pend_w = if (pending.len == 0) 0 else @min(pending.len + 1, mid_w);
        // Clip the message by display cells on a codepoint boundary — slicing
        // by bytes painted the bar short whenever a message held a multi-byte
        // character (an em dash cost two cells of the right edge).
        var mshow: usize = 0; // bytes taken
        var mcells: usize = 0; // cells they cover
        while (mshow < middle.len) {
            const d = unicode.decode(middle[mshow..]);
            const w = unicode.width(d.cp);
            if (mcells + w > mid_w - pend_w) break;
            mshow += d.len;
            mcells += w;
        }
        try self.emitSanitized(middle[0..mshow]);
        try self.emitSpaces(mid_w - mcells - pend_w);
        if (pend_w > 0) {
            try self.setFg(th.builtin); // the indicator stands out from messages
            try self.emitSanitized(pending[0 .. pend_w - 1]);
            try self.setFg(th.fg_dim);
            try self.emit(" ");
        }

        try self.setBg(th.status_bg);
        try self.setFg(th.status_seg_bg);
        try self.emit(sepLeft());
        try self.setBg(th.status_seg_bg);
        try self.setFg(th.status_seg_fg);
        try self.emit(rseg);
        try self.setBg(th.status_seg_bg);
        try self.setFg(accent);
        try self.emit(sepLeft());
        try self.setBg(accent);
        try self.setFg(th.bg);
        try self.emit(pctseg);
    }

    /// Statusline middle content from the language server: the diagnostic on
    /// the current line, else a count of errors/warnings, else null.
    fn lspMiddle(self: *Editor, buf: []u8) ?[]const u8 {
        const client = if (self.lsp) |*c| c else return null;
        if (client.messageAt(self.cy)) |msg| {
            const end = std.mem.indexOfScalar(u8, msg, '\n') orelse msg.len;
            return std.fmt.bufPrint(buf, "\u{25CF} {s}", .{msg[0..end]}) catch msg[0..end];
        }
        const c = client.counts();
        if (c.errors > 0 or c.warnings > 0) {
            return std.fmt.bufPrint(buf, "E:{d} W:{d}", .{ c.errors, c.warnings }) catch null;
        }
        return null;
    }

    /// The mode as the statusline shows it. A selection the mouse began in
    /// insert mode is nvim's Insert Visual, which it writes as
    /// `-- (insert) VISUAL --`; leaving it returns to insert.
    fn modeLabel(self: *Editor) []const u8 {
        // vim distinguishes the two replace modes on the statusline, and so
        // does this: `R` is REPLACE, `gR` is VREPLACE.
        if (self.mode == .replace and self.repl_virtual) return "VREPLACE";
        if (!self.ins_visual) return self.mode.label();
        return switch (self.mode) {
            .visual => "(insert) VISUAL",
            .visual_line => "(insert) V-LINE",
            .visual_block => "(insert) V-BLOCK",
            else => self.mode.label(),
        };
    }

    fn modeColor(self: *Editor) Color {
        const th = theme.current;
        return switch (self.mode) {
            .normal => th.mode_normal,
            // Replace is a kind of typing, and shares insert's colour as it
            // does in AstroNvim's statusline.
            .insert, .replace => th.mode_insert,
            .visual, .visual_line, .visual_block => th.mode_visual,
            .command, .picker => th.mode_command,
            .terminal => th.mode_insert, // typing goes somewhere: insert's colour
        };
    }

    /// The statusline's right-hand indicator: a macro-recording marker plus the
    /// keys of the command being typed (vim's 'showcmd' — `d`, `di`, `2d`,
    /// `"a3y`, `^W` …), which clears as soon as the command runs.
    fn pendingKeys(self: *Editor, buf: []u8) []const u8 {
        var i: usize = 0;
        if (self.recording) |reg| i += (std.fmt.bufPrint(buf[i..], "REC @{c}  ", .{reg}) catch return buf[0..i]).len;
        const keys = self.showcmd[0..self.showcmd_len];
        const room = buf.len - i;
        const n = @min(keys.len, room);
        @memcpy(buf[i..][0..n], keys[keys.len - n ..]);
        return buf[0 .. i + n];
    }

    fn placeCursor(self: *Editor, gutter: usize) !void {
        var row: usize = undefined;
        var col: usize = undefined;
        if (self.mode == .command) {
            // Inside the (possibly wrapped) command-line block — the same
            // layout the renderer painted, so the cursor is always on the cell
            // the next character will take.
            const blk = self.cmdBlock();
            row = blk.top + blk.cur_row - blk.first;
            col = blk.cur_col + 1;
        } else if (self.cur.doc.shell) |*sh| {
            // In a terminal the caret belongs to the *shell*, not to the empty
            // scratch buffer behind the grid — otherwise it sits at the
            // window's top-left corner while you type at the prompt, which is
            // exactly where it is not. Scrolled back through the history, the
            // live cursor moves down the view by however far back it is.
            const r = sh.screen.cy + sh.screen.back;
            row = self.cur.gy + 1 + @min(r, self.shellRows(self.cur) -| 1);
            col = self.cur.gx + @min(sh.screen.cx, self.cur.gw -| 1);
        } else if (self.sb_focus) {
            // On the sidebar's selected row.
            row = sb_tree_top + (self.sb_sel -| self.sb_scroll);
            col = self.sbX() + 1;
        } else {
            // Relative to the active window's screen region.
            row = self.cur.gy + self.cursorScreenRow();
            col = self.cur.gx + gutter + self.cursorScreenCol();
        }
        try self.emitFmt("\x1b[{d};{d}H", .{ row, col });
    }

    /// Record that an overlay covered screen rows [top, bot] (1-based), so the
    /// next frame repaints them instead of trusting the diff.
    fn markOverlayRows(self: *Editor, top: usize, bot: usize) void {
        if (self.overlay_bot == 0) {
            self.overlay_top = top;
            self.overlay_bot = bot;
            return;
        }
        self.overlay_top = @min(self.overlay_top, top);
        self.overlay_bot = @max(self.overlay_bot, bot);
    }

    fn emit(self: *Editor, bytes: []const u8) !void {
        try self.frame.appendSlice(self.gpa, bytes);
    }

    /// Emit text that originates outside the editor (buffer content, file
    /// names, LSP labels, status text) with control codepoints replaced, so
    /// untrusted bytes can never inject terminal escapes.
    fn emitSanitized(self: *Editor, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) {
            const d = unicode.decode(text[i..]);
            const bytes = text[i .. i + d.len];
            i += d.len;
            if (d.cp == '\t') {
                try self.emit(" ");
            } else if (isControlCp(d.cp) or invalidDecode(d)) {
                try self.emit("?");
            } else {
                try self.emit(bytes);
            }
        }
    }

    fn emitFmt(self: *Editor, comptime fmt: []const u8, args: anytype) !void {
        var b: [64]u8 = undefined;
        try self.emit(try std.fmt.bufPrint(&b, fmt, args));
    }

    fn emitSpaces(self: *Editor, n: usize) !void {
        try self.frame.appendNTimes(self.gpa, ' ', n);
    }

    fn setStatus(self: *Editor, comptime fmt: []const u8, args: anytype) void {
        self.status.clearRetainingCapacity();
        var b: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&b, fmt, args) catch return;
        self.status.appendSlice(self.gpa, s) catch {};
    }
};

// === free helpers ==========================================================

fn cmpPos(a: Pos, b: Pos) i32 {
    if (a.row != b.row) return if (a.row < b.row) -1 else 1;
    if (a.col != b.col) return if (a.col < b.col) -1 else 1;
    return 0;
}

fn charOf(k: key.Key) ?u21 {
    return switch (k) {
        .char => |c| c,
        .tab => '\t',
        else => null,
    };
}

/// True when `buf` ends in the middle of an escape sequence (a bare ESC, or a
/// CSI/SS3 introducer whose final byte hasn't arrived yet).
fn incompleteEscapeTail(buf: []const u8) bool {
    const idx = std.mem.lastIndexOfScalar(u8, buf, 0x1b) orelse return false;
    const tail = buf[idx..];
    if (tail.len == 1) return true; // lone ESC: maybe a sequence, maybe the key
    // OSC (`ESC ] … BEL` / `ESC ] … ST`) is unfinished until its terminator.
    // The ST case already resolves through the ESC of the ST itself; a
    // BEL-terminated reply split across reads needs this.
    if (tail[1] == ']') return std.mem.indexOfScalar(u8, tail, 0x07) == null;
    if (tail[1] != '[' and tail[1] != 'O') return false; // ESC+other: complete
    if (tail.len == 2) return true; // introducer without its body yet
    if (tail[1] == 'O') return false; // SS3 is exactly three bytes
    for (tail[2..]) |b| {
        if (b >= 0x40 and b <= 0x7e) return false; // CSI final byte seen
    }
    return true;
}

/// How many bytes of a full input buffer can be decoded now. A trailing escape
/// sequence that is definitely unfinished is excluded, so `readInput` can hold
/// it back for the next read instead of handing the decoder its fragments.
/// A lone trailing ESC is the Escape *key* — unless the terminal already has
/// more input queued behind it (`more_pending`), which is the same judgement
/// the short `waitMore` wait makes when the buffer has room to spare.
fn completePrefixLen(buf: []const u8, more_pending: bool) usize {
    if (!incompleteEscapeTail(buf)) return buf.len;
    const idx = std.mem.lastIndexOfScalar(u8, buf, 0x1b) orelse return buf.len;
    if (buf.len - idx == 1 and !more_pending) return buf.len;
    return idx;
}

/// The leading whitespace (spaces/tabs) of a line.
fn leadingIndent(line: []const u8) []const u8 {
    return line[0..motion.firstNonBlank(line)]; // one definition of "blank"
}

fn lineIsBlank(line: []const u8) bool {
    return leadingIndent(line).len == line.len;
}

fn charByte(k: key.Key) ?u8 {
    return switch (k) {
        .char => |c| if (c < 0x80) @intCast(c) else null,
        else => null,
    };
}

fn markIndex(k: key.Key) ?usize {
    const b = charByte(k) orelse return null;
    if (b >= 'a' and b <= 'z') return b - 'a';
    return null;
}

fn isIdentCp(cp: u21) bool {
    return cp == '_' or (cp >= '0' and cp <= '9') or (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z') or cp >= 0x80;
}

/// Character classes for the command line's word erase — vim's `mb_get_class`,
/// with the buckets that occur in practice: whitespace, ASCII punctuation,
/// word characters (ASCII identifiers plus Latin/Greek/Cyrillic letters, nvim
/// probes W21/W22) and one class per CJK block, so kana and kanji never merge
/// into one word (probes W23/W24).
fn cmdWordClass(cp: u21) u8 {
    if (cp == ' ' or cp == '\t') return 0;
    if (cp < 0x80) return if (isIdentCp(cp)) 2 else 1;
    return switch (cp) {
        0x2000...0x206f => 1, // general punctuation
        0x3040...0x309f => 3, // hiragana
        0x30a0...0x30ff => 4, // katakana
        0x4e00...0x9fff => 5, // CJK ideographs
        else => 2,
    };
}

/// Where c_CTRL-W erases back to from byte offset `at`: over the whitespace
/// in front of the cursor, then over the whole run of one character class.
/// nvim transcripts: ":foo bar" -> ":foo " (W1), ":foo bar  " -> ":foo " (W3),
/// ":foo.bar" -> ":foo." (W4), ":foo..." -> ":foo" (W5), ":   " -> ":" (W15),
/// ":foo ab日本" -> ":foo ab" (W17).
fn wordEraseStart(text: []const u8, at: usize) usize {
    var i = at;
    while (i > 0) {
        const p = unicode.prevBoundary(text, i);
        if (cmdWordClass(unicode.decode(text[p..]).cp) != 0) break;
        i = p;
    }
    if (i == 0) return 0;
    const cls = cmdWordClass(unicode.decode(text[unicode.prevBoundary(text, i)..]).cp);
    while (i > 0) {
        const p = unicode.prevBoundary(text, i);
        if (cmdWordClass(unicode.decode(text[p..]).cp) != cls) break;
        i = p;
    }
    return i;
}

/// A short label for an LSP SymbolKind, shown before each symbol in the picker.
fn symbolKindName(kind: u8) []const u8 {
    return switch (kind) {
        2 => "module",
        3 => "namespace",
        4 => "package",
        5 => "class",
        6 => "method",
        7 => "property",
        8 => "field",
        9 => "ctor",
        10 => "enum",
        11 => "interface",
        12 => "fn",
        13 => "var",
        14 => "const",
        22 => "enum-member",
        23 => "struct",
        25 => "operator",
        26 => "typeparam",
        else => "·",
    };
}

/// Byte offset of the `char`-th codepoint on a line (inverse of `charCol`,
/// sharing its BMP approximation of LSP's UTF-16 columns).
fn byteAtCharCol(line: []const u8, char: usize) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < line.len and n < char) : (n += 1) i = unicode.nextBoundary(line, i);
    return i;
}

/// Expand a `:s` replacement into `out`: `&` = the whole match, `\1`-`\9` =
/// capture groups (absent groups expand empty), `\\` `\&` `\/` are literals.
fn expandReplacement(out: *std.ArrayList(u8), gpa: Allocator, rep: []const u8, line: []const u8, m: regex.Match) !void {
    var i: usize = 0;
    while (i < rep.len) : (i += 1) {
        const c = rep[i];
        if (c == '&') {
            try out.appendSlice(gpa, line[m.span.start..m.span.end]);
        } else if (c == '\\' and i + 1 < rep.len) {
            i += 1;
            const e = rep[i];
            if (e >= '1' and e <= '9') {
                if (m.groups[e - '1']) |g| try out.appendSlice(gpa, line[g.start..g.end]);
            } else {
                try out.append(gpa, e); // \\ \& \/ and any other escaped literal
            }
        } else {
            try out.append(gpa, c);
        }
    }
}

/// Apply LSP `TextEdit`s to `buf`, last-position-first so earlier positions
/// stay valid. Handles multi-line ranges and multi-line replacement text.
/// Returns the number applied.
fn applyEditsToBuf(buf: *buffer.Buffer, edits: []lsp.TextEdit) usize {
    std.mem.sort(lsp.TextEdit, edits, {}, textEditAfter);
    var applied: usize = 0;
    for (edits) |e| {
        if (applyOneEdit(buf, e)) applied += 1;
    }
    return applied;
}

fn applyOneEdit(buf: *buffer.Buffer, e: lsp.TextEdit) bool {
    const nlines = buf.lineCount();
    if (e.start_line >= nlines or e.end_line < e.start_line) return false;
    const sline = buf.line(e.start_line);
    const sb = @min(byteAtCharCol(sline, e.start_char), sline.len);
    // Servers may put the end one past the last line (whole-document edits);
    // clamp it to the end of the last line.
    const past_end = e.end_line >= nlines;
    const end_line: usize = if (past_end) nlines - 1 else e.end_line;
    if (e.start_line == end_line and !past_end and std.mem.indexOfScalar(u8, e.text, '\n') == null) {
        const eb = byteAtCharCol(sline, e.end_char);
        if (eb < sb or eb > sline.len) return false;
        buf.deleteInLine(e.start_line, sb, eb) catch return false;
        buf.insertBytes(e.start_line, sb, e.text) catch return false;
        return true;
    }
    // Multi-line range and/or replacement: rebuild the region as
    // prefix ++ text ++ suffix, then split it back into lines.
    const eline = buf.line(end_line);
    const eb = if (past_end) eline.len else @min(byteAtCharCol(eline, e.end_char), eline.len);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(buf.gpa);
    joined.appendSlice(buf.gpa, sline[0..sb]) catch return false;
    joined.appendSlice(buf.gpa, e.text) catch return false;
    joined.appendSlice(buf.gpa, eline[eb..]) catch return false;

    var row = end_line;
    while (row > e.start_line) : (row -= 1) buf.removeLineAt(row);
    var it = std.mem.splitScalar(u8, joined.items, '\n');
    buf.setLine(e.start_line, it.first()) catch return false;
    var at: usize = e.start_line + 1;
    while (it.next()) |part| : (at += 1) {
        buf.insertLineAt(at, part) catch return false;
    }
    return true;
}

/// Decode a file:// URI into a filesystem path (percent-decoded). Null for
/// non-file URIs (untitled:, jar:, …).
fn uriToPath(gpa: Allocator, uri: []const u8) ?[]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return null;
    const enc = uri["file://".len..];
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var i: usize = 0;
    while (i < enc.len) {
        if (enc[i] == '%' and i + 2 < enc.len) {
            const hi = std.fmt.charToDigit(enc[i + 1], 16) catch 255;
            const lo = std.fmt.charToDigit(enc[i + 2], 16) catch 255;
            if (hi != 255 and lo != 255) {
                out.append(gpa, hi * 16 + lo) catch return null;
                i += 3;
                continue;
            }
        }
        out.append(gpa, enc[i]) catch return null;
        i += 1;
    }
    return out.toOwnedSlice(gpa) catch null;
}

/// Whether `doc_path` (as stored on a buffer — possibly relative to `cwd`)
/// names the same file as the absolute path `abs`.
fn samePath(cwd: []const u8, doc_path: []const u8, abs: []const u8) bool {
    if (doc_path.len > 0 and doc_path[0] == '/') return std.mem.eql(u8, doc_path, abs);
    return abs.len == cwd.len + 1 + doc_path.len and
        std.mem.startsWith(u8, abs, cwd) and abs[cwd.len] == '/' and
        std.mem.endsWith(u8, abs, doc_path);
}

/// What asking the release remote for its newest tag produced. The tag is
/// owned by the caller.
pub const UpdateCheck = union(enum) {
    tag: []u8,
    no_git, // git could not be run
    no_network, // ls-remote failed
    failed, // ls-remote killed/signalled (or out of memory)
    no_release, // no `v*` tags published
};

/// Ask the release remote for its newest `v*` tag: one `git ls-remote` call,
/// on demand only — zedit never phones home on its own. Shared by `:update`
/// (statusline) and main.zig's `--check-update` (stdout/exit codes).
pub fn fetchNewestTag(gpa: std.mem.Allocator, io: std.Io) UpdateCheck {
    const url = "https://github.com/ashuguptahere/zed.git";
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "git", "ls-remote", "--tags", "--refs", url },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(8 << 10),
    }) catch return .no_git;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) {
            std.log.scoped(.editor).warn("ls-remote failed: {s}", .{std.mem.trim(u8, res.stderr, " \n")});
            return .no_network;
        },
        else => return .failed,
    }
    const newest = newestTag(res.stdout) orelse return .no_release;
    return .{ .tag = gpa.dupe(u8, newest) catch return .failed };
}

/// The highest `refs/tags/vX.Y.Z` in `git ls-remote` output (the `v` stripped).
/// Null when the output holds no version tags.
fn newestTag(text: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const marker = "refs/tags/v";
        const at = std.mem.indexOf(u8, line, marker) orelse continue;
        const tag = std.mem.trim(u8, line[at + marker.len ..], " \t\r");
        if (tag.len == 0) continue;
        if (best == null or compareVersions(tag, best.?) == .gt) best = tag;
    }
    return best;
}

/// Compare dotted numeric versions ("0.10.1" > "0.9.9"), ignoring any suffix.
pub fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    var ita = std.mem.splitScalar(u8, a, '.');
    var itb = std.mem.splitScalar(u8, b, '.');
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const pa = numPrefix(ita.next() orelse "0");
        const pb = numPrefix(itb.next() orelse "0");
        if (pa != pb) return if (pa > pb) .gt else .lt;
    }
    return .eq;
}

fn numPrefix(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) break;
        n = n * 10 + (c - '0');
    }
    return n;
}

/// The buffer position `offset` bytes into text that was inserted at
/// (row, col) — used to place snippet tabstops after insertion.
fn offsetToPos(row: usize, col: usize, text: []const u8, offset: usize) Pos {
    var r = row;
    var c = col;
    var i: usize = 0;
    while (i < offset and i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            r += 1;
            c = 0;
        } else c += 1;
    }
    return .{ .row = r, .col = c };
}

/// `path` relative to `cwd` when it sits underneath it, else unchanged —
/// borrowed, never allocated.
fn relativeTo(cwd: []const u8, path: []const u8) []const u8 {
    if (path.len > cwd.len + 1 and std.mem.startsWith(u8, path, cwd) and path[cwd.len] == '/')
        return path[cwd.len + 1 ..];
    return path;
}

fn severityTag(sev: u8) []const u8 {
    return switch (sev) {
        1 => "E",
        2 => "W",
        3 => "I",
        else => "H",
    };
}

/// Linear blend of two colours: `pct`% of `b` into `a` (integer math, no
/// floats — used for the diff panes' change-line tint against any theme).
fn mixColor(a: theme.Color, b: theme.Color, pct: u16) theme.Color {
    return .{
        .r = @intCast((@as(u16, a.r) * (100 - pct) + @as(u16, b.r) * pct) / 100),
        .g = @intCast((@as(u16, a.g) * (100 - pct) + @as(u16, b.g) * pct) / 100),
        .b = @intCast((@as(u16, a.b) * (100 - pct) + @as(u16, b.b) * pct) / 100),
    };
}

/// Grammar node names for the structural text objects, taken from the
/// vendored grammars themselves (dumped with `ts_node_string`, not guessed).
/// `af`/`if` use the function list, `ac`/`ic` the type list.
fn functionKinds(lang: syntax.Language) []const []const u8 {
    return switch (lang) {
        .zig => &.{"function_declaration"},
        .c => &.{"function_definition"},
        .python => &.{"function_definition"},
        .rust => &.{"function_item"},
        .go => &.{ "function_declaration", "method_declaration" },
        .javascript, .typescript => &.{ "function_declaration", "method_definition", "arrow_function", "function_expression" },
        else => &.{},
    };
}

fn typeKinds(lang: syntax.Language) []const []const u8 {
    return switch (lang) {
        .zig => &.{"struct_declaration"},
        .c => &.{ "struct_specifier", "union_specifier", "enum_specifier" },
        .python => &.{"class_definition"},
        .rust => &.{ "struct_item", "enum_item", "impl_item", "trait_item" },
        .go => &.{"type_declaration"},
        .javascript, .typescript => &.{ "class_declaration", "class_body" },
        else => &.{},
    };
}

/// The list nodes holding arguments and parameters, for `ia`/`aa`. Dumped
/// from the vendored grammars with `ts_node_string` — Zig calls them
/// `parameters`/`arguments`, C and Go `parameter_list`/`argument_list`,
/// JS/TS `formal_parameters`/`arguments`, and Python mixes the two.
fn listKinds(lang: syntax.Language) []const []const u8 {
    return switch (lang) {
        .zig, .rust => &.{ "parameters", "arguments" },
        .c, .go => &.{ "parameter_list", "argument_list" },
        .python => &.{ "parameters", "lambda_parameters", "argument_list" },
        .javascript, .typescript => &.{ "formal_parameters", "arguments" },
        else => &.{},
    };
}

/// Comment nodes, for `iC`/`aC`. Rust is the odd one out: it splits line and
/// block comments into separate node types.
fn commentKinds(lang: syntax.Language) []const []const u8 {
    return switch (lang) {
        .rust => &.{ "line_comment", "block_comment" },
        .zig, .c, .python, .go, .javascript, .typescript, .html => &.{"comment"},
        else => &.{},
    };
}

/// Codepoints that must never reach the terminal raw — C0 controls, DEL and
/// C1 controls (U+0080–U+009F, 8-bit CSI et al.). A hostile file or language
/// server could otherwise inject escape sequences whose terminal *replies*
/// come back as synthetic keystrokes (the classic pager-injection class).
fn isControlCp(cp: u21) bool {
    return cp < 0x20 or cp == 0x7f or (cp >= 0x80 and cp <= 0x9f);
}

/// A malformed byte: `decode` reports it as U+FFFD consuming one byte (a
/// genuine U+FFFD in the text decodes with len 3). It must render as `?` —
/// emitting the raw byte would leak 0x80-0x9F (8-bit CSI!) to the terminal
/// and desynchronise the width accounting from what the terminal displays.
fn invalidDecode(d: unicode.Decoded) bool {
    return d.cp == 0xFFFD and d.len == 1;
}

/// The longest prefix of `text` that renders in at most `cells` display
/// cells, cut on a codepoint boundary — counting the cells `emitSanitized`
/// actually paints (controls and invalid bytes become a one-cell '?').
fn clipCells(text: []const u8, cells: usize) struct { bytes: usize, cells: usize } {
    var b: usize = 0;
    var used: usize = 0;
    while (b < text.len) {
        const d = unicode.decode(text[b..]);
        const w: usize = if (isControlCp(d.cp) or invalidDecode(d)) 1 else unicode.width(d.cp);
        if (used + w > cells) break;
        b += d.len;
        used += w;
    }
    return .{ .bytes = b, .cells = used };
}

/// How much of `text` one command-line row of `budget` cells takes. Normally
/// the longest prefix that fits, so a double-width char that would straddle
/// the edge starts the next row. `whole_row` says the budget is a full screen
/// row: there, when even one codepoint does not fit (a terminal narrower than
/// a wide char), it is taken anyway — the next row would be no wider, and a
/// row that consumes nothing loops the layout and the renderer forever.
fn cmdRowSplit(text: []const u8, budget: usize, whole_row: bool) struct { bytes: usize, cells: usize } {
    const seg = clipCells(text, budget);
    if (seg.bytes > 0 or text.len == 0 or !whole_row) return .{ .bytes = seg.bytes, .cells = seg.cells };
    return .{ .bytes = unicode.nextBoundary(text, 0), .cells = 0 };
}

fn textEditAfter(_: void, a: lsp.TextEdit, b: lsp.TextEdit) bool {
    if (a.start_line != b.start_line) return a.start_line > b.start_line;
    return a.start_char > b.start_char;
}

fn toggleAscii(cp: u21) u21 {
    if (cp >= 'a' and cp <= 'z') return cp - 'a' + 'A';
    if (cp >= 'A' and cp <= 'Z') return cp - 'A' + 'a';
    return cp;
}

fn isQuote(cp: u21) bool {
    return cp == '"' or cp == '\'' or cp == '`';
}

fn isCloser(cp: u21) bool {
    return cp == ')' or cp == ']' or cp == '}';
}

fn closerFor(cp: u21) ?u21 {
    return switch (cp) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        else => null,
    };
}

fn isPair(open: u21, close: u21) bool {
    if (closerFor(open)) |c| return c == close;
    return isQuote(open) and open == close;
}

const Pair = struct { open: []const u8, close: []const u8 };

/// The delimiter strings to add for a surround character.
fn surroundPair(c: u8) ?Pair {
    return switch (c) {
        '(', ')', 'b' => .{ .open = "(", .close = ")" },
        '[', ']' => .{ .open = "[", .close = "]" },
        '{', '}', 'B' => .{ .open = "{", .close = "}" },
        '<', '>' => .{ .open = "<", .close = ">" },
        '"' => .{ .open = "\"", .close = "\"" },
        '\'' => .{ .open = "'", .close = "'" },
        '`' => .{ .open = "`", .close = "`" },
        else => null,
    };
}

fn lastColumn(line: []const u8) usize {
    if (line.len == 0) return 0;
    return unicode.prevBoundary(line, line.len);
}

const Scored = struct { idx: u32, score: i32 };

fn scoredLess(_: void, a: Scored, b: Scored) bool {
    return a.score > b.score; // higher score first
}

fn ignoredDir(name: []const u8) bool {
    const ignore = [_][]const u8{ ".git", "zig-cache", ".zig-cache", "zig-out", "node_modules", "target", ".cache" };
    for (ignore) |g| if (std.mem.eql(u8, name, g)) return true;
    return name.len > 0 and name[0] == '.'; // hidden directories
}

fn trimTrailingNewline(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\n') return s[0 .. s.len - 1];
    return s;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn cellWidth(cp: u21, col: usize) usize {
    if (cp == '\t') return tabWidth() - (col % tabWidth());
    return unicode.width(cp);
}

/// The last display cell the character at byte `col` occupies, given that its
/// first is `dc`. One past the end of a line is a one-cell virtual position,
/// and a zero-width (combining) character owns no cell of its own.
fn endCell(line: []const u8, col: usize, dc: usize) usize {
    if (col >= line.len) return dc;
    const w = cellWidth(unicode.decode(line[col..]).cp, dc);
    return if (w == 0) dc else dc + w - 1;
}

fn displayCol(line: []const u8, upto: usize) usize {
    var dc: usize = 0;
    var i: usize = 0;
    while (i < upto and i < line.len) {
        const d = unicode.decode(line[i..]);
        dc += cellWidth(d.cp, dc);
        i += d.len;
    }
    return dc;
}

/// Display width of `line`, abandoned once it passes `limit`. Soft wrap only
/// ever needs to know how many screen rows a line fills, and a window has a
/// bounded number of rows — so a minified one-line file costs O(screen) per
/// frame here instead of O(document).
fn displayWidthUpTo(line: []const u8, limit: usize) usize {
    var dc: usize = 0;
    var i: usize = 0;
    while (i < line.len and dc <= limit) {
        const d = unicode.decode(line[i..]);
        dc += cellWidth(d.cp, dc);
        i += d.len;
    }
    return dc;
}

fn byteAtDisplayCol(line: []const u8, target: usize) usize {
    var dc: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const d = unicode.decode(line[i..]);
        const w = cellWidth(d.cp, dc);
        if (dc + w > target) break;
        dc += w;
        i += d.len;
    }
    return i;
}

test "newestTag picks the highest release tag" {
    const out =
        "abc123\trefs/tags/v0.1.0\n" ++
        "def456\trefs/tags/v0.10.2\n" ++
        "aaa111\trefs/tags/v0.9.9\n" ++
        "bbb222\trefs/heads/main\n";
    try std.testing.expectEqualStrings("0.10.2", newestTag(out).?);
    try std.testing.expect(newestTag("abc\trefs/heads/main\n") == null);
}

test "compareVersions orders numerically, not lexically" {
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("0.10.0", "0.9.9"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("0.2.0", "0.2.0"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("0.2.0", "0.2.1"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("1.2", "1.2.0"));
}

test "mixColor blends toward the tint" {
    const a = theme.Color{ .r = 0, .g = 0, .b = 0 };
    const b = theme.Color{ .r = 200, .g = 100, .b = 40 };
    const m = mixColor(a, b, 25);
    try std.testing.expectEqual(@as(u8, 50), m.r);
    try std.testing.expectEqual(@as(u8, 25), m.g);
    try std.testing.expectEqual(@as(u8, 10), m.b);
    const full = mixColor(a, b, 100);
    try std.testing.expectEqual(@as(u8, 200), full.r);
}

test "isControlCp classifies injection-capable codepoints" {
    try std.testing.expect(isControlCp(0x1b)); // ESC
    try std.testing.expect(isControlCp(0x9b)); // C1 CSI
    try std.testing.expect(isControlCp(0x07)); // BEL
    try std.testing.expect(isControlCp(0x7f)); // DEL
    try std.testing.expect(!isControlCp('a'));
    try std.testing.expect(!isControlCp(0xa0)); // NBSP is printable
    try std.testing.expect(!isControlCp(0x4E16)); // CJK
}

test "applyEditsToBuf handles multi-line ranges and text" {
    const gpa = std.testing.allocator;
    var b = try buffer.Buffer.fromBytes(gpa, "one\ntwo\nthree\n");
    defer b.deinit();
    // Replace from mid-line 0 to mid-line 2 with two lines of new text.
    var edits = [_]lsp.TextEdit{.{ .start_line = 0, .start_char = 2, .end_line = 2, .end_char = 3, .text = @constCast("X\nY") }};
    try std.testing.expectEqual(@as(usize, 1), applyEditsToBuf(&b, &edits));
    try std.testing.expectEqual(@as(usize, 2), b.lineCount());
    try std.testing.expectEqualStrings("onX", b.line(0));
    try std.testing.expectEqualStrings("Yee", b.line(1));
}

test "applyEditsToBuf clamps an end one past the last line" {
    const gpa = std.testing.allocator;
    var b = try buffer.Buffer.fromBytes(gpa, "aa\nbb\n");
    defer b.deinit();
    // zls-style whole-document edit: end = (lineCount, 0).
    var edits = [_]lsp.TextEdit{.{ .start_line = 0, .start_char = 0, .end_line = 2, .end_char = 0, .text = @constCast("xx\nyy") }};
    try std.testing.expectEqual(@as(usize, 1), applyEditsToBuf(&b, &edits));
    try std.testing.expectEqual(@as(usize, 2), b.lineCount());
    try std.testing.expectEqualStrings("xx", b.line(0));
    try std.testing.expectEqualStrings("yy", b.line(1));
}

test "applyEditsToBuf applies edits last-first" {
    const gpa = std.testing.allocator;
    var b = try buffer.Buffer.fromBytes(gpa, "a b a\n");
    defer b.deinit();
    var edits = [_]lsp.TextEdit{
        .{ .start_line = 0, .start_char = 0, .end_line = 0, .end_char = 1, .text = @constCast("xyz") },
        .{ .start_line = 0, .start_char = 4, .end_line = 0, .end_char = 5, .text = @constCast("xyz") },
    };
    try std.testing.expectEqual(@as(usize, 2), applyEditsToBuf(&b, &edits));
    try std.testing.expectEqualStrings("xyz b xyz", b.line(0));
}

test "uriToPath decodes file URIs" {
    const gpa = std.testing.allocator;
    const p = uriToPath(gpa, "file:///tmp/a%20b.txt").?;
    defer gpa.free(p);
    try std.testing.expectEqualStrings("/tmp/a b.txt", p);
    try std.testing.expectEqual(@as(?[]u8, null), uriToPath(gpa, "untitled:x"));
}

test "samePath matches relative doc paths against absolute ones" {
    try std.testing.expect(samePath("/home/u", "src/a.zig", "/home/u/src/a.zig"));
    try std.testing.expect(samePath("/home/u", "/tmp/a.zig", "/tmp/a.zig"));
    try std.testing.expect(!samePath("/home/u", "r.txt", "/home/u/bar.txt"));
}

test "displayCol expands tabs" {
    try std.testing.expectEqual(@as(usize, tabWidth()), displayCol("\tx", 1));
    try std.testing.expectEqual(@as(usize, 2), displayCol("ab", 2));
    try std.testing.expectEqual(@as(usize, 2), displayCol("世", 3));
}

test "byteAtDisplayCol round-trips with displayCol" {
    const line = "a\tbc";
    const off = byteAtDisplayCol(line, tabWidth());
    try std.testing.expectEqual(@as(usize, 2), off);
    try std.testing.expectEqual(@as(usize, tabWidth()), displayCol(line, off));
}

test "wordEraseStart follows nvim's c_CTRL-W word rule" {
    const eq = std.testing.expectEqual;
    // Ground truth: real nvim (`-u NONE -i NONE -n --noplugin`) driven through
    // a tmux pty, the command line typed and its rendered row read back —
    //   ":foo bar"      + Ctrl-W -> ":foo "       (probe W1)
    //   ":foo bar  "    + Ctrl-W -> ":foo "       (W3: the skipped blanks go too)
    //   ":foo.bar"      + Ctrl-W -> ":foo."       (W4: the word only)
    //   ":foo..."       + Ctrl-W -> ":foo"        (W5: a punctuation run)
    //   ":e /tmp/foo"   + Ctrl-W -> ":e /tmp/"    (W10)
    //   ":   "          + Ctrl-W -> ":"           (W15: blanks alone)
    //   ":foo ab日本"   + Ctrl-W -> ":foo ab"     (W17: CJK is its own class)
    //   ":foo 日本ab"   + Ctrl-W -> ":foo 日本"   (W18)
    //   ":foo あい日本" + Ctrl-W -> ":foo あい"   (W23: kana ≠ kanji)
    //   ":foo bär"      + Ctrl-W -> ":foo "       (W21: Latin letters are word)
    //   ":foo bar_baz42"+ Ctrl-W -> ":foo "       (W11: one identifier)
    try eq(@as(usize, 4), wordEraseStart("foo bar", 7));
    try eq(@as(usize, 4), wordEraseStart("foo bar  ", 9));
    try eq(@as(usize, 4), wordEraseStart("foo.bar", 7));
    try eq(@as(usize, 3), wordEraseStart("foo...", 6));
    try eq(@as(usize, 7), wordEraseStart("e /tmp/foo", 10));
    try eq(@as(usize, 0), wordEraseStart("   ", 3));
    try eq(@as(usize, 6), wordEraseStart("foo ab日本", 12));
    try eq(@as(usize, 10), wordEraseStart("foo 日本ab", 12));
    try eq(@as(usize, 10), wordEraseStart("foo あい日本", 16));
    try eq(@as(usize, 4), wordEraseStart("foo bär", 8));
    try eq(@as(usize, 4), wordEraseStart("foo bar_baz42", 13));
    // Mid-line: only the run before the cursor is taken (probe W8,
    // ":abc def" + 2 Lefts -> ":abc ef").
    try eq(@as(usize, 4), wordEraseStart("abc def", 5));
    // Column 0 has nothing to erase (probe W9).
    try eq(@as(usize, 0), wordEraseStart("abc def", 0));
}

test "cmdRowSplit breaks a command-line row where nvim does" {
    const eq = std.testing.expectEqual;
    // A row takes whole codepoints only, by display cells.
    try eq(@as(usize, 3), cmdRowSplit("abcdef", 3, true).bytes);
    try eq(@as(usize, 3), cmdRowSplit("abcdef", 3, true).cells);
    // Ground truth: real nvim (`-u NONE -i NONE -n --noplugin`) in a
    // 20-column tmux pty. ":012345678901234567日本" painted
    // ":012345678901234567>" and "日本" — the wide char that would straddle
    // the edge starts the next row and vim marks the leftover cell '>'. So
    // the split stops one cell short and the caller has a cell to mark.
    const straddle = cmdRowSplit("012345678901234567日本", 19, false);
    try eq(@as(usize, 18), straddle.bytes);
    try eq(@as(usize, 18), straddle.cells);
    // The same char on a row that is not wide enough for it at all: the next
    // row would be no wider, so it is consumed here. Without this the layout
    // never advances and the editor spins at 100% CPU on a one-column
    // terminal (it does not budge for `:q!` either).
    const one_col = cmdRowSplit("日本", 1, true);
    try eq(@as(usize, 3), one_col.bytes);
    try eq(@as(usize, 0), one_col.cells);
    // …but only on a whole row: with the prompt taking the first cell, the
    // char still moves to the next row instead.
    try eq(@as(usize, 0), cmdRowSplit("日本", 1, false).bytes);
    // Nothing left to take is not a stall.
    try eq(@as(usize, 0), cmdRowSplit("", 1, true).bytes);
}

test "completePrefixLen holds back a split escape sequence" {
    const eq = std.testing.expectEqual;
    // Nothing unfinished: the whole buffer is decodable.
    try eq(@as(usize, 4), completePrefixLen("abcd", false));
    try eq(@as(usize, 6), completePrefixLen("ab\x1b[3~", false));
    try eq(@as(usize, 13), completePrefixLen("ab\x1b[<32;15;4M", false));
    // An unfinished CSI tail is held back whatever the terminal has queued.
    try eq(@as(usize, 2), completePrefixLen("ab\x1b[<32;15", false));
    try eq(@as(usize, 2), completePrefixLen("ab\x1b[<32;15", true));
    try eq(@as(usize, 2), completePrefixLen("ab\x1b[", false));
    try eq(@as(usize, 2), completePrefixLen("ab\x1bO", false));
    // A lone trailing ESC is the Escape key — unless more input is already
    // queued behind it, in which case it introduces a sequence.
    try eq(@as(usize, 3), completePrefixLen("ab\x1b", false));
    try eq(@as(usize, 2), completePrefixLen("ab\x1b", true));
    // ESC followed by an ordinary byte is complete (Alt-x, not a CSI).
    try eq(@as(usize, 4), completePrefixLen("ab\x1bx", true));
}

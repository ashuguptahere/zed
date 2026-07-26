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
const snippet = @import("snippet.zig");
const remote = @import("remote.zig");
const regex = @import("regex.zig");
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
/// The thin variant, for a transition between two same-coloured segments
/// (adjacent inactive tabs in the title bar).
fn sepRightThin() []const u8 {
    return if (config.settings.nerd_font) "\u{E0B1}" else "";
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
    visual,
    visual_line,
    visual_block,
    command,
    picker,

    fn label(self: Mode) []const u8 {
        return switch (self) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .visual => "VISUAL",
            .visual_line => "V-LINE",
            .visual_block => "V-BLOCK",
            .command => "COMMAND",
            .picker => "PICKER",
        };
    }
};

const PickerKind = enum { files, grep, code_action, symbol, wsymbol, diagnostic, theme, buffer, reference, undo };
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

const Operator = enum { none, delete, change, yank, indent_right, indent_left, comment, surround };

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
    register, // "{a-z}
    g_prefix, // g then ...
    z_prefix, // Z then Z/Q
    bracket_next, // ] then d (next diagnostic)
    bracket_prev, // [ then d (previous diagnostic)
    ctrl_w, // Ctrl-w then a window command
    object_inner, // operator i{obj}
    object_around, // operator a{obj}
    macro_record, // q{reg}
    macro_play, // @{reg}
    space_leader, // <space> menu (which-key)
    space_find, // <space>f — the AstroNvim Find group
    space_lang, // <space>l — the AstroNvim Language-tools group
    space_git, // <space>g — the Git group (diff views)
    space_buffer, // <space>b — the Buffers group (picker, next/prev, close)
    surround_add_char, // ys{motion}{char} / visual S{char}
    surround_delete, // ds{char}
    surround_change_from, // cs{old}...
    surround_change_to, // cs{old}{new}
};

const CmdKind = enum { ex, search_forward, search_backward, rename };

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
const Doc = struct {
    buf: buffer.Buffer,
    name: ?[]u8 = null, // display name for scratch buffers (buf.path == null)
    diff_of: ?*Doc = null, // side-by-side index snapshot: the worktree doc it mirrors
    diff_hunks: []git.Hunk = &.{}, // set on the index snapshot: aligns the pair's panes
    lang: syntax.Language,
    history: undo.History,
    marks: [26]?Pos = [_]?Pos{null} ** 26,
    git_signs: git.Signs,
    lsp: ?lsp.Client = null,
    lsp_rev: u64 = 0,
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

    // multiple cursors (one per line; primary stays cy/cx). Empty = single cursor.
    extra: std.ArrayList(Pos) = .empty,

    // surround pending state
    surr_span: ?Span = null,
    surr_from: u8 = 0,

    // jumplist (Ctrl-o / Ctrl-i): positions recorded before jump-motions.
    jumps: std.ArrayList(Jump) = .empty,
    jump_idx: usize = 0, // == jumps.len when at the "live" end

    // search
    last_search: std.ArrayList(u8) = .empty,
    last_search_forward: bool = true,
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
    wild_stem: std.ArrayList(u8) = .empty, // cmd content when completion started
    wild_paths: bool = false, // the ring completes :e/:w paths (Up/Down navigate directories)
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

    // dot-repeat
    dot_keys: std.ArrayList(u8) = .empty,
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
    lsp: ?lsp.Client = null,
    lsp_rev: u64 = 0, // buffer revision last sent via didChange
    // completion popup (insert mode)
    comp_open: bool = false,
    comp_filtered: std.ArrayList(usize) = .empty, // indices into lsp.completions matching the prefix
    comp_sel: usize = 0,
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
    inbuf: [256]u8 = undefined,

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
        };
        return doc;
    }

    fn docLabel(doc: *const Doc) []const u8 {
        return doc.buf.path orelse (doc.name orelse "[No Name]");
    }

    fn freeDocState(doc: *Doc, gpa: Allocator) void {
        if (doc.name) |n| gpa.free(n);
        gpa.free(doc.diff_hunks);
        doc.history.deinit();
        doc.git_signs.deinit();
        if (doc.ts) |*t| t.deinit();
        doc.ts_styles.deinit(gpa);
        doc.ts_line_starts.deinit(gpa);
        if (doc.lsp) |*c| c.deinit();
    }

    pub fn init(gpa: Allocator, io: std.Io, t: *term.Terminal, buf: buffer.Buffer, lsp_cmd: ?[]const u8) !Editor {
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
            .lang = syntax.detect(doc.buf.path),
            .git_signs = git.Signs.init(gpa),
            .lsp_cmd = lsp_cmd,
        };
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
        self.ghost.deinit(self.gpa);
        self.cmd.deinit(self.gpa);
        self.macro_buf.deinit(self.gpa);
        self.dot_keys.deinit(self.gpa);
        self.dot_temp.deinit(self.gpa);
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
        self.extra.deinit(self.gpa);
        self.freePicker();
        self.picker_items.deinit(self.gpa);
        self.picker_text.deinit(self.gpa);
        self.sbFree();
        self.sb_entries.deinit(self.gpa);
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
        for (self.docs.items) |doc| {
            doc.buf.deinit();
            freeDocState(doc, self.gpa);
            self.gpa.destroy(doc);
        }
        for (self.wins.items) |w| self.gpa.destroy(w);
        self.docs.deinit(self.gpa);
        self.wins.deinit(self.gpa);
    }

    pub fn run(self: *Editor) !void {
        try self.term.enableRaw();
        self.term.installResizeHandler();
        try self.term.enterAltScreen();
        self.win = self.term.size();
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
            const lsp_fd: ?std.posix.fd_t = if (self.lsp) |*c| (if (c.alive) c.out_fd else null) else null;
            const ready = try self.term.waitReady(lsp_fd, self.pollTimeout());
            if (self.completionDue()) {
                self.fireDue();
                needs_render = true;
            }
            if (self.term.takeResize()) {
                self.win = self.term.size();
                self.prev_valid = false; // layout changed; diff base is stale
                needs_render = true;
                continue;
            }
            if (ready.other) {
                if (self.lsp) |*c| c.readAvailable();
                try self.consumeLspResults();
                needs_render = true;
            }
            if (ready.input) {
                const chunk = try self.readInput();
                if (chunk.len > 0) {
                    try self.processInput(chunk);
                    self.syncLsp();
                    needs_render = true;
                }
            }
        }
    }

    fn readInput(self: *Editor) ![]u8 {
        var n = (try self.term.read(self.inbuf[0..])).len;
        // Complete a trailing escape sequence split across reads — over SSH,
        // input regularly arrives in small chunks, and decoding half a CSI
        // sequence would garble arrows, paste fences and friends. A genuine
        // lone Esc press just times out the short wait and stays Esc.
        while (n > 0 and n < self.inbuf.len and
            incompleteEscapeTail(self.inbuf[0..n]) and self.term.waitMore(15))
        {
            n += (try self.term.read(self.inbuf[n..])).len;
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
        if (self.d.diff_of != null) return; // read-only: pasteInsert refuses too
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
                self.wildClear();
                const end = std.mem.indexOfAny(u8, bytes, "\r\n") orelse bytes.len;
                try self.cmd.insertSlice(self.gpa, self.cmd_cur, bytes[0..end]);
                self.cmd_cur += end;
                self.histEdited();
                if (self.searching()) self.searchLive();
                self.ghostUpdate();
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
    fn replayBytes(self: *Editor, bytes: []const u8) error{OutOfMemory}!void {
        if (self.replay_depth > 64) return; // runaway-recursion guard
        self.replay_depth += 1;
        defer self.replay_depth -= 1;
        var i: usize = 0;
        while (i < bytes.len) {
            const d = key.decode(bytes[i..]);
            const raw = bytes[i .. i + d.consumed];
            i += d.consumed;
            try self.feedKey(d.key, raw);
            if (self.quit) break;
        }
    }

    /// One key through the dot-repeat capture wrapper and the mode dispatcher.
    fn feedKey(self: *Editor, k: key.Key, raw: []const u8) !void {
        // Mouse wheel: scroll the viewport in the buffer modes; never part of
        // a command, so it bypasses dot-repeat/macro capture entirely.
        switch (k) {
            .mouse_press => |m| {
                try self.mouseClick(m);
                return;
            },
            // Releases, drags and other buttons: inert, like the press that
            // preceded them — never into showcmd, dot-repeat or pending state
            // (a release must not cancel an operator the wheel would keep).
            .mouse_other => return,
            .scroll_up, .scroll_down => {
                switch (self.mode) {
                    .normal, .insert, .visual, .visual_line, .visual_block => self.mouseScroll(k == .scroll_up),
                    .picker => self.scrollPreview(if (k == .scroll_up) -3 else 3),
                    .command => {},
                }
                return;
            },
            else => {},
        }
        if (!self.in_dot) self.dotCapturePre(raw);
        self.showcmdPush(raw);
        try self.handleKey(k);
        if (!self.in_dot) self.dotCapturePost();
        self.showcmdSettle();
    }

    /// Record a key as part of the command being typed. Only the buffer modes
    /// build a command; insert mode and the prompts show their own text.
    fn showcmdPush(self: *Editor, raw: []const u8) void {
        switch (self.mode) {
            .normal, .visual, .visual_line, .visual_block => {},
            .insert, .command, .picker => return,
        }
        if (self.showcmd_done) { // the previous command is still displayed
            self.showcmd_len = 0;
            self.showcmd_done = false;
        }
        for (raw) |b| {
            // Printable keys read back as themselves; control bytes as ^X so
            // Ctrl-w or Esc stay legible in the indicator.
            var enc: [2]u8 = undefined;
            const bytes: []const u8 = if (b >= 0x20 and b != 0x7f)
                enc[0..1]
            else blk: {
                enc[0] = '^';
                enc[1] = if (b == 0x1b) '[' else b + '@';
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
            .insert, .command, .picker => {
                self.showcmd_len = 0;
                self.showcmd_done = false;
            },
        }
    }

    /// A left-click. The tabline switches buffers, the way every tabbed
    /// editor behaves, and the explorer acts on its rows: a single click
    /// toggles a directory or opens a file (VS Code's rule), while its
    /// header or the empty space below the tree just focuses it. Clicks
    /// anywhere else — the text area included — are ignored, so terminal
    /// text selection keeps working.
    fn mouseClick(self: *Editor, m: key.Mouse) !void {
        if (self.mode != .normal and self.mode != .insert) return;
        if (tabsVisible() and m.row == 1) {
            if (self.tabAt(m.col)) |doc| {
                if (doc == self.d) return;
                self.addJump();
                self.focusDoc(doc);
                self.clampCursor();
                self.setStatus("{s}", .{docLabel(doc)});
                return;
            }
            // Not a tab: the EXPLORER segment (or the filler) — fall through
            // to the sidebar hit-test, which owns those columns.
        }
        try self.sbClick(m.row, m.col);
    }

    /// Wheel scrolling: move the viewport three lines (nvim's step) and carry
    /// the cursor with it, so it keeps its row on screen. Scrolling to the top
    /// of the file therefore leaves the cursor near the top, not pinned to the
    /// bottom of the first page (owner's choice over nvim's drag-at-the-edge
    /// rule, which left it stranded).
    fn mouseScroll(self: *Editor, up: bool) void {
        const step = 3;
        const last_line = self.buf.lineCount() - 1;
        const before = self.top;
        self.top = self.lineAfterRows(self.top, step, up); // three *screen* rows
        const moved = if (self.top > before) self.top - before else before - self.top;
        if (moved == 0) return; // already at an end: nothing moves, cursor included
        self.cy = if (self.top > before) @min(self.cy + moved, last_line) else self.cy -| moved;
        self.cx = @min(self.cx, lastColumn(self.curLine()));
        self.updateGoal();
    }

    fn dotCapturePre(self: *Editor, raw: []const u8) void {
        if (self.mode == .normal and self.atNeutral()) {
            self.dot_temp.clearRetainingCapacity();
            self.change_started = false;
        }
        switch (self.mode) {
            .normal, .insert, .visual, .visual_line, .visual_block => self.dot_temp.appendSlice(self.gpa, raw) catch {},
            .command, .picker => {},
        }
    }

    fn dotCapturePost(self: *Editor) void {
        if (self.mode == .normal and self.atNeutral() and self.change_started) {
            self.dot_keys.clearRetainingCapacity();
            self.dot_keys.appendSlice(self.gpa, self.dot_temp.items) catch {};
            self.change_started = false;
        }
    }

    fn atNeutral(self: *Editor) bool {
        return self.count == 0 and self.count2 == 0 and self.operator == .none and
            self.await_arg == .none and self.pending_register == null;
    }

    fn handleKey(self: *Editor, k: key.Key) !void {
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
        switch (self.mode) {
            .normal => try self.normalKey(k),
            .insert => try self.insertKey(k),
            .visual, .visual_line, .visual_block => try self.visualKey(k),
            .command => try self.commandKey(k),
            .picker => try self.pickerKey(k),
        }
        self.clampCursor();
    }

    // === normal mode =======================================================

    fn normalKey(self: *Editor, k: key.Key) !void {
        if (self.await_arg != .none) return self.awaitKey(k);
        if (self.operator != .none) return self.operatorPendingKey(k);
        if (self.extra.items.len > 0) {
            if (try self.multiNormal(k)) return;
            self.clearExtra(); // non-multi command: collapse to one cursor
        }

        switch (k) {
            .char => |c| try self.normalChar(c),
            .ctrl => |c| self.normalCtrl(c),
            .left => self.doMotion(.{ .pos = self.left1(), .kind = .exclusive, .col_mode = .exact }),
            .right => self.doMotion(.{ .pos = self.afterCursor(), .kind = .exclusive, .col_mode = .exact }),
            .up => self.doMotion(self.vertical(true, 1)),
            .down => self.doMotion(self.vertical(false, 1)),
            .home => self.doMotion(.{ .pos = .{ .row = self.cy, .col = 0 }, .kind = .exclusive, .col_mode = .exact }),
            .end => self.doMotion(.{ .pos = .{ .row = self.cy, .col = self.curLine().len }, .kind = .inclusive, .col_mode = .exact }),
            .backspace => self.doMotion(.{ .pos = self.left1(), .kind = .exclusive, .col_mode = .exact }),
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
            'j' => self.doMotion(self.vertical(false, self.eff())),
            'k' => self.doMotion(self.vertical(true, self.eff())),
            '0' => self.doMotion(.{ .pos = .{ .row = self.cy, .col = 0 }, .kind = .exclusive, .col_mode = .exact }),
            '^', '_' => self.doMotion(.{ .pos = .{ .row = self.cy, .col = motion.firstNonBlank(self.curLine()) }, .kind = .exclusive, .col_mode = .exact }),
            '$' => self.doMotion(self.endOfLineMotion()),
            'w' => self.doMotion(self.repeatWord(.f, false)),
            'W' => self.doMotion(self.repeatWord(.f, true)),
            'b' => self.doMotion(self.repeatWord(.b, false)),
            'B' => self.doMotion(self.repeatWord(.b, true)),
            'e' => self.doMotion(self.repeatWord(.e, false)),
            'E' => self.doMotion(self.repeatWord(.e, true)),
            'G' => self.doMotion(self.gotoLineMotion(if (self.count > 0) self.count - 1 else self.buf.lineCount() - 1)),
            '%' => if (motion.matchPair(self.buf, self.cursor())) |p| {
                if (self.operator == .none) self.addJump();
                self.doMotion(.{ .pos = p, .kind = .inclusive, .col_mode = .exact });
            } else self.resetPending(),
            '{' => self.doMotion(self.paragraphMotion(false)),
            '}' => self.doMotion(self.paragraphMotion(true)),
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
            '~' => try self.toggleCase(self.eff()),
            'J' => try self.joinLines(self.eff()),
            'K' => {
                self.lspHover();
                self.resetPending();
            },
            'p' => try self.paste(true),
            'P' => try self.paste(false),
            'u' => self.undoChange(),
            // visual / search / command
            'v' => self.enterVisual(.visual),
            'V' => self.enterVisual(.visual_line),
            '/' => self.enterCmd(.search_forward),
            '?' => self.enterCmd(.search_backward),
            'n' => self.repeatSearch(true),
            'N' => self.repeatSearch(false),
            '*' => self.searchWord(true),
            '#' => self.searchWord(false),
            ':' => self.enterCmd(.ex),
            '.' => try self.repeatDot(),
            'Z' => self.await_arg = .z_prefix,
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
            .mark_jump_back => {
                if (markIndex(k)) |idx| if (self.marks[idx]) |p| {
                    self.addJump();
                    self.setCursor(p);
                };
                self.resetPending();
            },
            .mark_jump_line => {
                if (markIndex(k)) |idx| if (self.marks[idx]) |p| {
                    self.addJump();
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
                } else if (k == .char and k.char == 'j')
                    self.doMotion(self.screenVertical(false, self.total()))
                else if (k == .char and k.char == 'k')
                    self.doMotion(self.screenVertical(true, self.total()))
                else if (k == .char and k.char == '0')
                    self.doMotion(self.screenLineEdge(false))
                else if (k == .char and k.char == '$')
                    self.doMotion(self.screenLineEdge(true))
                else
                    self.resetPending();
            },
            .z_prefix => {
                if (k == .char and k.char == 'Z') {
                    if (try self.write("")) self.quit = true;
                } else if (k == .char and k.char == 'Q') {
                    self.quit = true;
                }
                self.resetPending();
            },
            .bracket_next, .bracket_prev => {
                if (k == .char and k.char == 'd') self.gotoDiagnostic(a == .bracket_next);
                if (k == .char and k.char == 'b') self.cycleDoc(a == .bracket_next, self.eff()); // ]b / [b buffers
                if (k == .char and k.char == 'f') self.gotoFunction(a == .bracket_next); // ]f / [f functions
                self.resetPending();
            },
            .ctrl_w => {
                self.resetPending();
                const ch: u8 = switch (k) {
                    .char => |c| if (c < 128) @intCast(c) else 0,
                    .ctrl => |c| c, // Ctrl-w Ctrl-w also cycles
                    else => 0,
                };
                switch (ch) {
                    'v' => self.splitWindow(true), // vertical split (columns)
                    's' => self.splitWindow(false), // horizontal split (rows)
                    'c', 'q' => self.closeWindow(),
                    'o' => self.onlyWindow(),
                    'w', 'l', 'j' => self.nextWindow(true),
                    'h', 'k', 'p' => self.nextWindow(false),
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
                const reg = charByte(k) orelse {
                    self.resetPending();
                    return;
                };
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
                    'e' => self.sidebarToggle(), // file explorer (AstroNvim <leader>e)
                    'w' => _ = try self.write(""),
                    'q' => self.doQuit(),
                    'c' => self.closeDoc(), // close buffer (AstroNvim <leader>c)
                    else => {},
                };
            },
            .space_buffer => {
                self.resetPending();
                if (k == .char) switch (k.char) {
                    'b' => self.openBufferPicker(), // same picker as <space>f b
                    'n' => self.cycleDoc(true, 1), // next buffer (]b)
                    'p' => self.cycleDoc(false, 1), // previous buffer ([b)
                    'c' => self.closeDoc(), // same as <space>c
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
            .up => self.doMotion(self.vertical(true, self.total())),
            .down => self.doMotion(self.vertical(false, self.total())),
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
            .indent_left => c == '<',
            .comment => c == 'c', // gcc
            .surround => false, // handled by the 's' intercept (yss)
            .none => false,
        };
    }

    fn applyLinewiseOperator(self: *Editor) void {
        const n = self.total();
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
        if (c == 'p') { // paragraph: a linewise object (nvim-verified)
            const r = motion.paraObject(self.buf, self.cy, around, self.total());
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
            end = .{ .row = end.row - 1, .col = self.buf.line(end.row - 1).len };
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

    fn left1(self: *Editor) Pos {
        return .{ .row = self.cy, .col = unicode.prevBoundary(self.curLine(), self.cx) };
    }

    fn vertical(self: *Editor, up: bool, n: usize) MotionResult {
        const row = if (up) (if (self.cy > n) self.cy - n else 0) else @min(self.cy + n, self.buf.lineCount() - 1);
        return .{ .pos = .{ .row = row, .col = 0 }, .kind = .linewise, .col_mode = .keep_goal };
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
                    row -= 1;
                    wl = self.lineLayout(row);
                    seg = wl.n - 1;
                }
            } else {
                if (seg + 1 < wl.n) {
                    seg += 1;
                } else {
                    if (row + 1 >= self.buf.lineCount()) break;
                    row += 1;
                    wl = self.lineLayout(row);
                    seg = 0;
                }
            }
        }
        const target = wl.starts[seg] + (screen_col -| wl.pad(seg));
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

    fn gotoLineMotion(self: *Editor, row: usize) MotionResult {
        if (self.operator == .none) self.addJump(); // jump-motion, not an operator target
        return .{ .pos = .{ .row = @min(row, self.buf.lineCount() - 1), .col = 0 }, .kind = .linewise, .col_mode = .first_non_blank };
    }

    fn repeatWord(self: *Editor, which: WordKind, big: bool) MotionResult {
        var p = self.cursor();
        var prev = p;
        var i: usize = 0;
        const n = if (self.operator != .none) self.total() else self.eff();
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
        var n = self.total(); // vim multiplies `2d3fa`: count before × after
        while (n > 0) : (n -= 1) {
            col = motion.findChar(line, col, ch, forward, false) orelse return self.resetPending();
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
        if (op != .yank and self.rejectReadOnly()) return;
        switch (op) {
            .indent_right => return self.indent(span, true),
            .indent_left => return self.indent(span, false),
            .comment => return self.toggleComment(span),
            else => {},
        }
        const text = self.extract(span) catch return;
        defer self.gpa.free(text);
        self.yankTo(text, span.lines);

        if (op == .yank) {
            if (span.lines) {
                self.cy = @min(span.top, self.buf.lineCount() - 1);
            } else {
                self.setCursor(span.start);
            }
            return;
        }

        self.pushUndo();
        if (op == .change and span.lines) {
            const keep = if (config.settings.autoindent) leadingIndent(self.buf.line(span.top)) else "";
            self.setAutoIndent(span.top, keep);
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
            return .{ .row = row, .col = motion.firstNonBlank(self.buf.line(row)) };
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
        self.yankTo(text, false);
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

    fn joinLines(self: *Editor, count: usize) !void {
        if (self.rejectReadOnly()) return;
        const joins = if (count > 1) count - 1 else 1;
        self.pushUndo();
        var i: usize = 0;
        while (i < joins) : (i += 1) {
            if (self.cy + 1 >= self.buf.lineCount()) break;
            const cur_len = self.buf.line(self.cy).len;
            const next = self.gpa.dupe(u8, self.buf.line(self.cy + 1)) catch break;
            defer self.gpa.free(next);
            const rest = std.mem.trimStart(u8, next, " \t");
            self.buf.removeLineAt(self.cy + 1);
            const need_space = cur_len > 0 and rest.len > 0;
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

    fn paste(self: *Editor, after: bool) !void {
        if (self.rejectReadOnly()) return;
        const reg = self.registers.get(self.pending_register) orelse {
            self.resetPending();
            return;
        };
        const n = self.eff();
        self.pushUndo();
        if (reg.linewise) {
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
            self.cy = @min(first, self.buf.lineCount() - 1);
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
            // Cursor on the last pasted character.
            if (insert_col > col) self.cx = unicode.prevBoundary(self.curLine(), insert_col) else self.cx = col;
            self.updateGoal();
        }
        self.resetPending();
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
        self.resetPending();
    }

    fn openLine(self: *Editor, below: bool) !void {
        if (self.rejectReadOnly()) return;
        self.pushUndo();
        const inherit = if (config.settings.autoindent) leadingIndent(self.curLine()) else "";
        self.setAutoIndent(self.cy, inherit); // copy before the insert shifts rows
        const at = if (below) self.cy + 1 else self.cy;
        try self.buf.insertLineAt(at, self.ai_indent.items);
        self.cy = at;
        self.cx = self.buf.line(at).len;
        self.updateGoal();
        self.ai_row = if (config.settings.autoindent) at else null;
        self.mode = .insert;
        self.resetPending();
    }

    fn insertKey(self: *Editor, k: key.Key) !void {
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
            .tab, .enter => {
                self.acceptCompletion();
                return true;
            },
            .escape => {
                self.comp_open = false;
                return true; // dismiss only; stay in insert mode
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

    fn insertKeyOne(self: *Editor, k: key.Key) !void {
        if (self.moveKey(k)) return;
        // Any key other than Enter/Esc means the auto-indent got company;
        // those two check `was_ai` to apply vim's strip-if-left-blank rule.
        const was_ai = self.ai_row;
        self.ai_row = null;
        switch (k) {
            .escape => {
                self.stripBlankAutoIndent(was_ai);
                self.mode = .normal;
                self.comp_open = false;
                self.sig_open = false;
                if (self.cx > 0) self.cx = unicode.prevBoundary(self.curLine(), self.cx);
                self.updateGoal();
            },
            .enter => {
                // The indent to carry: the pending one when this line is still
                // an untouched auto-indent (which then gets stripped, like
                // vim), else this line's own leading whitespace.
                if (config.settings.autoindent) {
                    if (was_ai != self.cy or !lineIsBlank(self.curLine())) {
                        self.ai_indent.clearRetainingCapacity();
                        self.ai_indent.appendSlice(self.gpa, leadingIndent(self.curLine())) catch {};
                    }
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
                'n' => self.lspCompletion(), // request completion
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

    fn enterVisual(self: *Editor, m: Mode) void {
        self.mode = m;
        self.vstart = self.cursor();
        self.resetPending();
    }

    fn visualKey(self: *Editor, k: key.Key) !void {
        if (self.await_arg != .none) return self.awaitKey(k); // v i{obj} / v a{obj}
        // Arrows act exactly like h/l/k/j — translate for dispatch only; the
        // goal-column guard below still keys on the original key.
        const kk: key.Key = switch (k) {
            .left => .{ .char = 'h' },
            .right => .{ .char = 'l' },
            .up => .{ .char = 'k' },
            .down => .{ .char = 'j' },
            else => k,
        };
        switch (kk) {
            .escape => self.mode = .normal,
            .char => |c| switch (c) {
                'h' => self.cx = unicode.prevBoundary(self.curLine(), self.cx),
                'l', ' ' => {
                    const line = self.curLine();
                    if (self.cx < line.len) self.cx = unicode.nextBoundary(line, self.cx);
                },
                'j' => if (self.cy + 1 < self.buf.lineCount()) {
                    self.cy += 1;
                    self.cx = byteAtDisplayCol(self.curLine(), self.goal_col);
                },
                'k' => if (self.cy > 0) {
                    self.cy -= 1;
                    self.cx = byteAtDisplayCol(self.curLine(), self.goal_col);
                },
                '0' => self.cx = 0,
                '^' => self.cx = motion.firstNonBlank(self.curLine()),
                '$' => self.cx = lastColumn(self.curLine()),
                'w' => self.setCursorKeep(motion.wordForward(self.buf, self.cursor(), false)),
                'W' => self.setCursorKeep(motion.wordForward(self.buf, self.cursor(), true)),
                'b' => self.setCursorKeep(motion.wordBackward(self.buf, self.cursor(), false)),
                'e' => self.setCursorKeep(motion.wordEnd(self.buf, self.cursor(), false)),
                'G' => self.setCursorKeep(.{ .row = self.buf.lineCount() - 1, .col = 0 }),
                'g' => self.setCursorKeep(.{ .row = 0, .col = 0 }),
                '%' => if (motion.matchPair(self.buf, self.cursor())) |p| self.setCursorKeep(p),
                'o' => {
                    const tmp = self.vstart;
                    self.vstart = self.cursor();
                    self.cy = tmp.row;
                    self.cx = tmp.col;
                },
                'd', 'x' => if (self.mode == .visual_block) try self.blockDelete() else try self.visualOperator(.delete),
                'y' => if (self.mode == .visual_block) try self.blockYank() else try self.visualOperator(.yank),
                'c', 's' => if (self.mode == .visual_block) try self.blockChange() else try self.visualOperator(.change),
                'I' => if (self.mode == .visual_block) try self.blockInsert(false),
                'A' => if (self.mode == .visual_block) try self.blockInsert(true),
                'S' => self.visualSurround(),
                'U' => try self.visualCase(.upper),
                'u' => try self.visualCase(.lower),
                '~' => try self.visualCase(.toggle),
                '>' => try self.visualOperator(.indent_right),
                '<' => try self.visualOperator(.indent_left),
                'V' => self.mode = .visual_line,
                'v' => self.mode = .visual,
                'i' => self.await_arg = .visual_object_inner,
                'a' => self.await_arg = .visual_object_around,
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
            else => {},
        }
        if (k != .up and k != .down) self.updateGoal();
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
    fn visualCase(self: *Editor, how: enum { upper, lower, toggle }) !void {
        if (self.rejectReadOnly()) return;
        self.pushUndo();
        const linewise = self.mode == .visual_line;
        var start = self.vstart;
        var end = self.cursor();
        if (cmpPos(end, start) < 0) std.mem.swap(Pos, &start, &end);

        var row = start.row;
        while (row <= end.row) : (row += 1) {
            const line = self.buf.line(row);
            var lo: usize = 0;
            var hi: usize = line.len;
            if (!linewise) {
                if (row == start.row) lo = start.col;
                if (row == end.row) hi = @min(unicode.nextBoundary(line, end.col), line.len);
            }
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
        self.applyOperator(op, span);
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

    const BlockRect = struct { top: usize, bot: usize, left: usize, right: usize };

    /// The block rectangle in display columns from the anchor and cursor.
    fn blockCols(self: *Editor) BlockRect {
        const a = self.vstart;
        const b = self.cursor();
        const a_dc = displayCol(self.buf.line(a.row), a.col);
        const b_dc = displayCol(self.buf.line(b.row), b.col);
        return .{
            .top = @min(a.row, b.row),
            .bot = @max(a.row, b.row),
            .left = @min(a_dc, b_dc),
            .right = @max(a_dc, b_dc),
        };
    }

    fn blockDelete(self: *Editor) !void {
        if (self.rejectReadOnly()) return;
        const r = self.blockCols();
        self.pushUndo();
        var i = r.top;
        while (i <= r.bot) : (i += 1) {
            const line = self.buf.line(i);
            const lo = byteAtDisplayCol(line, r.left);
            const hi = byteAtDisplayCol(line, r.right + 1);
            if (hi > lo) try self.buf.deleteInLine(i, lo, hi);
        }
        self.mode = .normal;
        self.cy = r.top;
        self.cx = byteAtDisplayCol(self.buf.line(r.top), r.left);
        self.updateGoal();
    }

    fn blockYank(self: *Editor) !void {
        const r = self.blockCols();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        var i = r.top;
        while (i <= r.bot) : (i += 1) {
            const line = self.buf.line(i);
            const lo = byteAtDisplayCol(line, r.left);
            const hi = byteAtDisplayCol(line, r.right + 1);
            try out.appendSlice(self.gpa, line[lo..hi]);
            if (i < r.bot) try out.append(self.gpa, '\n');
        }
        self.yankTo(out.items, false);
        self.mode = .normal;
        self.cy = r.top;
        self.cx = byteAtDisplayCol(self.buf.line(r.top), r.left);
        self.updateGoal();
    }

    /// Block insert/append: place a caret at the left/right edge of every row in
    /// the block, then enter multi-cursor insert (typing replicates to all rows).
    fn blockInsert(self: *Editor, at_right: bool) !void {
        if (self.rejectReadOnly()) return;
        const r = self.blockCols();
        const dc = if (at_right) r.right + 1 else r.left;
        self.clearExtra();
        self.cy = r.top;
        self.cx = byteAtDisplayCol(self.buf.line(r.top), dc);
        var i = r.top + 1;
        while (i <= r.bot) : (i += 1) {
            self.extra.append(self.gpa, .{ .row = i, .col = byteAtDisplayCol(self.buf.line(i), dc) }) catch {};
        }
        self.mode = .normal;
        try self.enterInsertMulti(.at);
    }

    fn blockChange(self: *Editor) !void {
        if (self.rejectReadOnly()) return;
        const r = self.blockCols();
        try self.blockDelete(); // sets cursor to (top, left); pushes undo
        self.cy = r.top;
        self.cx = byteAtDisplayCol(self.buf.line(r.top), r.left);
        var i = r.top + 1;
        while (i <= r.bot) : (i += 1) {
            self.extra.append(self.gpa, .{ .row = i, .col = byteAtDisplayCol(self.buf.line(i), r.left) }) catch {};
        }
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
        for (self.extra.items) |e| extreme = if (below) @max(extreme, e.row) else @min(extreme, e.row);
        if (below) {
            if (extreme + 1 >= self.buf.lineCount()) return;
        } else {
            if (extreme == 0) return;
        }
        const nr = if (below) extreme + 1 else extreme - 1;
        if (nr == self.cy) return;
        for (self.extra.items) |e| if (e.row == nr) return;
        const col = byteAtDisplayCol(self.buf.line(nr), self.goal_col);
        self.extra.append(self.gpa, .{ .row = nr, .col = col }) catch return;
        self.setStatus("{d} cursors", .{self.extra.items.len + 1});
        self.resetPending();
    }

    fn dedupeByLine(self: *Editor) void {
        var i: usize = 0;
        while (i < self.extra.items.len) {
            const e = self.extra.items[i];
            var dup = e.row == self.cy;
            if (!dup) {
                var j: usize = 0;
                while (j < i) : (j += 1) {
                    if (self.extra.items[j].row == e.row) {
                        dup = true;
                        break;
                    }
                }
            }
            if (dup) _ = self.extra.orderedRemove(i) else i += 1;
        }
        for (self.extra.items) |*e| {
            const l = self.buf.line(e.row);
            if (e.col > l.len) e.col = l.len;
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

    fn multiMove(self: *Editor, c: u8) void {
        self.setCursor(self.movedCaret(self.cursor(), c));
        for (self.extra.items) |*e| e.* = self.movedCaret(e.*, c);
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
            if (e.col < self.buf.line(e.row).len) try self.buf.deleteForward(e.row, e.col);
            const nl = self.buf.line(e.row);
            if (e.col > nl.len) e.col = nl.len;
        }
        self.clampCursor();
        self.updateGoal();
        self.resetPending();
    }

    fn enterInsertMulti(self: *Editor, place: Place) !void {
        if (self.rejectReadOnly()) return;
        self.pushUndo();
        self.cx = self.insertCol(self.cy, self.cx, place);
        for (self.extra.items) |*e| e.col = self.insertCol(e.row, e.col, place);
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
            self.cy = e.row;
            self.cx = e.col;
            try self.insertAtCaret(k);
            e.* = .{ .row = self.cy, .col = self.cx };
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
        for (self.extra.items) |e| if (e.row == row) return e.col;
        return null;
    }

    // === search ============================================================

    fn runSearch(self: *Editor, query: []const u8, forward: bool) void {
        if (query.len == 0) return;
        self.last_search.clearRetainingCapacity();
        self.last_search.appendSlice(self.gpa, query) catch {};
        self.last_search_forward = forward;
        self.jumpSearch(forward);
    }

    fn jumpSearch(self: *Editor, forward: bool) void {
        if (self.last_search.items.len == 0) return;
        const re = self.compiledPattern(self.last_search.items) orelse return; // invalid mid-typing
        const hit = if (forward)
            search.next(self.buf, self.cursor(), re)
        else
            search.prev(self.buf, self.cursor(), re);
        if (hit) |p| {
            self.setCursor(p);
        } else {
            self.setStatus("pattern not found: {s}", .{self.last_search.items});
        }
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
        self.jumpSearch(fwd);
        self.resetPending();
    }

    /// `*` / `#`: search for the word under the cursor, with vim's whole-word
    /// boundaries (the pattern becomes `\<word\>`, metacharacters escaped).
    fn searchWord(self: *Editor, forward: bool) void {
        const word = search.wordUnder(self.buf, self.cursor());
        if (word.len == 0) {
            self.resetPending();
            return;
        }
        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(self.gpa);
        pat.appendSlice(self.gpa, "\\<") catch return;
        for (word) |ch| {
            if (std.mem.indexOfScalar(u8, ".\\*+?()[]|^$/<>{}", ch) != null)
                pat.append(self.gpa, '\\') catch return;
            pat.append(self.gpa, ch) catch return;
        }
        pat.appendSlice(self.gpa, "\\>") catch return;
        self.addJump();
        self.runSearch(pat.items, forward);
        self.resetPending();
    }

    // === picker (file finder / global search) ==============================

    /// Load the recently-opened list and, when the session started with no
    /// file, show the startup screen.
    pub fn startSession(self: *Editor, show_dashboard: bool) void {
        self.recents = recent.load(self.gpa, self.io);
        self.dashboard = show_dashboard and self.recents.entries.items.len > 0;
        self.dash_sel = 0;
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

    pub fn openFilePicker(self: *Editor) void {
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
    fn openThemePicker(self: *Editor) void {
        self.startPicker(.theme);
        for (theme.themes) |t| {
            self.addPickItem(t.name, t.name, 0);
        }
        self.mode = .picker;
        self.refilter();
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
            const qmask = fuzzy.charMask(q);
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
                if (fuzzy.score(self.itemPath(it), q)) |s| scored.append(self.gpa, .{ .idx = i, .score = s }) catch {};
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
        if (down) {
            if (self.picker_sel + 1 < self.picker_filtered.items.len) self.picker_sel += 1;
        } else {
            if (self.picker_sel > 0) self.picker_sel -= 1;
        }
    }

    fn pickerKey(self: *Editor, k: key.Key) !void {
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
                var enc: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &enc) catch return;
                try self.picker_query.appendSlice(self.gpa, enc[0..n]);
                self.onQueryChange();
            },
            .up => self.selDelta(false),
            .down => self.selDelta(true),
            .scroll_up => self.scrollPreview(-3), // the wheel scrolls the preview
            .scroll_down => self.scrollPreview(3),
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
            self.setStatus("theme: {s}", .{name_buf[0..n]});
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
        self.cur = w; // focus the new split
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
            doc.buf.deinit();
            freeDocState(doc, self.gpa);
            self.gpa.destroy(doc);
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

    /// The picker screen: the file tree on its configured side (when open),
    /// the results next to it, and — for anything that names a file — a live
    /// preview of the selection on the right, Helix-style. Every picker uses
    /// this same layout, so searching looks the same wherever you start it.
    fn renderPickerBody(self: *Editor) !void {
        const th = theme.current;
        const cols: usize = self.win.cols;
        const rows: usize = self.win.rows;
        // The title bar keeps row 1 in the picker view too; the prompt and
        // results shift below it.
        const tab_h: usize = if (tabsVisible()) 1 else 0;
        const top = 1 + tab_h; // the prompt's row
        const visible = if (rows > top) rows - top else 1;

        // Columns: [sidebar] [list] [preview]
        const side_w = if (self.sb_open) self.sbWidth() else 0;
        const body_x = if (self.sb_open and config.settings.sidebar == .left) side_w + 1 else 1;
        const body_w = cols -| side_w;
        // A preview needs room for both panes; below that the results get the
        // whole width rather than two unreadable columns.
        const wants_preview = self.previewKind() != .none and body_w >= 40;
        const list_w = if (wants_preview) @max(body_w / 2, 24) else body_w;
        const prev_x = body_x + list_w;
        const prev_w = if (wants_preview) body_w - list_w else 0;

        if (self.picker_sel < self.picker_scroll) self.picker_scroll = self.picker_sel;
        if (self.picker_sel >= self.picker_scroll + visible) self.picker_scroll = self.picker_sel - visible + 1;

        // Clear the whole screen once; the panes then paint over it.
        try self.setBg(th.bg);
        var clr: usize = 1;
        while (clr <= rows) : (clr += 1) {
            try self.emitFmt("\x1b[{d};1H", .{clr});
            try self.emit(ansi.clear_line_right);
        }
        if (self.sb_open) try self.renderSidebar();
        if (tab_h > 0) try self.renderTitleBar();

        const klabel = switch (self.picker_kind) {
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
        };

        // Prompt.
        try self.emitFmt("\x1b[{d};{d}H", .{ top, body_x });
        try self.setBg(th.mode_command);
        try self.setFg(th.bg);
        try self.emit(klabel);
        try self.setBg(th.bg);
        try self.setFg(th.fg);
        try self.emit(" ");
        const qmax = list_w -| (klabel.len + 2);
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
            }
            if (used < list_w) try self.emitSpaces(list_w - used);
        }

        if (wants_preview) try self.renderPreview(prev_x, prev_w, top, rows);

        const promptw = klabel.len + 1;
        try self.emitFmt("\x1b[{d};{d}H", .{ top, body_x + promptw + unicode.displayWidth(self.picker_query.items) });
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
        }
        return switch (self.picker_kind) {
            .files => .file,
            .buffer => .file,
            .grep, .reference => .line,
            .diagnostic, .wsymbol => .line,
            .theme, .code_action, .symbol, .undo => .none,
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
        switch (k) {
            .escape => {
                if (self.searching()) {
                    // Cancel: restore the previous pattern and the original cursor.
                    self.last_search.clearRetainingCapacity();
                    self.last_search.appendSlice(self.gpa, self.prev_search.items) catch {};
                    self.setCursor(self.search_origin);
                }
                self.pushHistory(); // an abandoned line is remembered too (vim)
                self.wildClear();
                self.mode = .normal;
            },
            .enter => {
                const kind = self.cmd_kind;
                self.pushHistory();
                self.wildClear();
                self.mode = .normal;
                switch (kind) {
                    .ex => try self.execEx(),
                    // The cursor already moved live; record the origin so
                    // Ctrl-o returns to where the search began.
                    .search_forward, .search_backward => self.addJumpAt(self.d, self.search_origin),
                    .rename => self.lspRename(),
                }
            },
            .backspace => {
                self.wildClear();
                if (self.cmd.items.len == 0) {
                    try self.commandKey(.escape);
                } else if (self.cmd_cur > 0) {
                    // Delete the codepoint before the cursor; at the start of
                    // a non-empty line this is a no-op (nvim, probe M8).
                    const p = unicode.prevBoundary(self.cmd.items, self.cmd_cur);
                    self.cmd.replaceRange(self.gpa, p, self.cmd_cur - p, "") catch {};
                    self.cmd_cur = p;
                    self.histEdited();
                    if (self.searching()) self.searchLive();
                    self.ghostUpdate();
                }
            },
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
                else => {},
            },
            .char => |c| {
                self.wildClear();
                var enc: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &enc) catch return;
                try self.cmd.insertSlice(self.gpa, self.cmd_cur, enc[0..len]);
                self.cmd_cur += len;
                self.histEdited();
                if (self.searching()) self.searchLive();
                self.ghostUpdate();
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

    /// Replace the command line's content (history recall / completion). The
    /// cursor goes to end-of-line (vim's rule, probe M9).
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
            .rename => null,
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
                self.setCmd(self.wild.items[0].text);
                self.wildClear();
                return;
            }
            self.wild_idx = if (forward) 0 else self.wild.items.len - 1;
            self.setCmd(self.wild.items[self.wild_idx.?].text);
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
        if (self.wild_idx) |i| self.setCmd(self.wild.items[i].text) else self.setCmd(self.wild_stem.items);
    }

    /// Build the completion candidates for the current `:` line: command names
    /// for the first word, then per-command arguments (paths for :e/:w, theme
    /// names for :theme).
    fn wildCompute(self: *Editor) void {
        self.wildClear();
        self.wild_paths = false;
        self.wild_stem.clearRetainingCapacity();
        self.wild_stem.appendSlice(self.gpa, self.cmd.items) catch return;
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
        const line = self.cmd.items;
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
        self.setCmd(line);
        self.wildNext(true);
    }

    fn wildAdd(self: *Editor, text: []const u8, show: usize) void {
        const owned = self.gpa.dupe(u8, text) catch return;
        self.wild.append(self.gpa, .{ .text = owned, .show = show }) catch self.gpa.free(owned);
    }

    /// Every completable command, by its full name (all are also accepted
    /// spelled out by execEx; the short forms still work typed by hand).
    const command_names = [_][]const u8{
        "bdelete", "bnext",  "bprevious", "buffers", "close",  "diff", "earlier",
        "edit",    "format", "later",     "ls",      "only",   "quit", "quitall",
        "split",   "theme",  "undolist",  "vdiff",   "vsplit", "wall", "wq",
        "write",   "x",
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
        if (self.cmd.items.len > 0) self.jumpSearch(self.last_search_forward);
    }

    fn execEx(self: *Editor) !void {
        const raw = std.mem.trim(u8, self.cmd.items, " ");
        if (raw.len == 0) return;

        // :[range]s/pat/rep/[flags] — try substitution first, since its range
        // can start with digits that would otherwise read as :<number>.
        if (parseSubstitute(raw)) |sub| return self.doSubstitute(sub);

        // :<number> jumps to a line.
        if (raw[0] >= '0' and raw[0] <= '9') {
            const ln = std.fmt.parseInt(usize, raw, 10) catch return;
            self.addJump();
            self.cy = if (ln == 0) 0 else @min(ln - 1, self.buf.lineCount() - 1);
            self.cx = motion.firstNonBlank(self.curLine());
            self.updateGoal();
            return;
        }
        if (eql(raw, "$")) {
            self.addJump();
            self.cy = self.buf.lineCount() - 1;
            self.cx = motion.firstNonBlank(self.curLine());
            return;
        }

        var it = std.mem.tokenizeScalar(u8, raw, ' ');
        const cmd = it.next() orelse return;
        const arg = std.mem.trim(u8, raw[cmd.len..], " ");

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
        } else if (eql(cmd, "clo") or eql(cmd, "close")) {
            self.closeWindow();
        } else if (eql(cmd, "on") or eql(cmd, "only")) {
            self.onlyWindow();
        } else if (eql(cmd, "bn") or eql(cmd, "bnext")) {
            self.cycleDoc(true, 1);
        } else if (eql(cmd, "bp") or eql(cmd, "bprev") or eql(cmd, "bprevious")) {
            self.cycleDoc(false, 1);
        } else if (eql(cmd, "bd") or eql(cmd, "bdelete")) {
            self.closeDoc();
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

    const Substitute = struct {
        lo: ?usize, // 1-based inclusive; null = current line
        hi: ?usize,
        whole: bool, // '%' range
        pat: []const u8,
        rep: []const u8,
        global: bool, // g flag: every occurrence on the line
        icase: bool, // i flag
    };

    /// Recognise `[%|n|n,m]s/pat/rep/[flags]` (separator is `/`, escapable as
    /// `\/`). Returns null when `raw` is not a substitution at all.
    fn parseSubstitute(raw: []const u8) ?Substitute {
        var i: usize = 0;
        var lo: ?usize = null;
        var hi: ?usize = null;
        var whole = false;
        if (i < raw.len and raw[i] == '%') {
            whole = true;
            i += 1;
        } else if (i < raw.len and std.ascii.isDigit(raw[i])) {
            const s = i;
            while (i < raw.len and std.ascii.isDigit(raw[i])) i += 1;
            lo = std.fmt.parseInt(usize, raw[s..i], 10) catch return null;
            hi = lo;
            if (i < raw.len and raw[i] == ',') {
                i += 1;
                const s2 = i;
                while (i < raw.len and std.ascii.isDigit(raw[i])) i += 1;
                if (i == s2) return null;
                hi = std.fmt.parseInt(usize, raw[s2..i], 10) catch return null;
            }
        }
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
        return .{ .lo = lo, .hi = hi, .whole = whole, .pat = pat, .rep = rep, .global = global, .icase = icase };
    }

    /// Apply a parsed `:s` as a single undoable change. The replacement
    /// understands `&` (whole match), `\1`-`\9` (groups), `\\`, `\&` and `\/`.
    fn doSubstitute(self: *Editor, sub: Substitute) void {
        if (self.rejectReadOnly()) return;
        var re = regex.Regex.compile(self.gpa, sub.pat, sub.icase) catch {
            self.setStatus("invalid pattern: {s}", .{sub.pat});
            return;
        };
        defer re.deinit(self.gpa);

        const last_row = self.buf.lineCount() - 1;
        var lo: usize = if (sub.whole) 0 else if (sub.lo) |n| @min(n -| 1, last_row) else self.cy;
        var hi: usize = if (sub.whole) last_row else if (sub.hi) |n| @min(n -| 1, last_row) else self.cy;
        if (lo > hi) std.mem.swap(usize, &lo, &hi);

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
            else => @errorName(err),
        };
    }

    fn write(self: *Editor, arg: []const u8) !bool {
        if (self.d.diff_of != null) { // includes `:w <name>`: never write the snapshot out
            self.setStatus("index snapshot is read-only", .{});
            return false;
        }
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
    /// another open document; refuses to close the last buffer.
    fn closeDoc(self: *Editor) void {
        if (self.docs.items.len <= 1) {
            self.setStatus("cannot close the last buffer", .{});
            return;
        }
        const victim = self.d;
        var repl: *Doc = self.docs.items[0];
        for (self.docs.items) |doc| {
            if (doc != victim) {
                repl = doc;
                break;
            }
        }
        self.loadDoc(repl); // swaps victim's live state back into its Doc
        for (self.wins.items) |w| {
            if (w.doc == victim) w.doc = repl;
        }
        self.destroyDoc(victim);
        self.clearExtra();
        self.placeAt(self.cy);
        self.setStatus("{s}", .{docLabel(self.d)});
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
        victim.buf.deinit();
        freeDocState(victim, self.gpa);
        self.gpa.destroy(victim);
    }

    // === undo / macros / dot ===============================================

    fn pushUndo(self: *Editor) void {
        self.history.record(self.buf, self.cy, self.cx);
        self.change_started = true;
    }

    /// The side-by-side index snapshot is read-only: it mirrors repository
    /// state, and edits would desync the pair's alignment (and leave a dirty
    /// scratch blocking `:q`). Every buffer-mutating command calls this first;
    /// true means the command was refused and reported.
    fn rejectReadOnly(self: *Editor) bool {
        if (self.d.diff_of == null) return false;
        self.setStatus("index snapshot is read-only", .{});
        self.resetPending();
        return true;
    }

    /// Recompute the git change signs for the current file (best-effort).
    fn refreshGit(self: *Editor) void {
        if (self.isLargeFile()) return;
        if (self.buf.path) |p| {
            git.compute(self.gpa, self.io, p, &self.git_signs);
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
        } else if (defaultServer(self.lang)) |def| {
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

        self.lsp = lsp.Client.start(self.gpa, self.io, argv_store[0..argc], cwd, uri_buf.items, langId(self.lang), content);
        if (self.lsp) |*c| {
            self.lsp_rev = self.buf.revision;
            c.requestInlayHints(self.buf.lineCount());
            self.setStatus("language server started", .{});
        }
    }

    /// Tell the server about edits, but only when the content actually changed
    /// (the client picks incremental vs. full based on the server's capability).
    fn syncLsp(self: *Editor) void {
        var client = if (self.lsp) |*c| c else return;
        if (!client.alive or self.buf.revision == self.lsp_rev) return;
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
            if (self.mode == .insert and client.completions.items.len > 0) {
                self.comp_open = true;
                self.comp_sel = 0;
                self.filterCompletions();
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
    fn gotoDiagnostic(self: *Editor, forward: bool) void {
        const client = if (self.lsp) |*c| c else return self.setStatus("no language server", .{});
        var line: ?usize = null;
        var from = self.cy;
        var n = self.eff();
        while (n > 0) : (n -= 1) {
            const next = client.nextDiagLine(from, forward) orelse break;
            line = next;
            from = next;
        }
        const target = line orelse return self.setStatus("no diagnostics", .{});
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
        if (!client.alive or !client.can_format) return;
        self.syncLsp();
        client.fmt_ready = false;
        client.requestFormatting(config.settings.tab_width);
        var tries: usize = 100;
        while (!client.fmt_ready and client.alive and tries > 0) : (tries -= 1) client.pump(10);
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
            doc.buf.deinit();
            freeDocState(doc, self.gpa);
            self.gpa.destroy(doc);
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
            if (c.alive and doc.buf.revision != doc.lsp_rev) {
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

    fn lspCompletion(self: *Editor) void {
        self.comp_due_ms = null;
        self.syncLsp(); // the server must see the text this completes against
        if (self.lsp) |*c| c.requestCompletion(self.cy, self.charCol());
    }

    /// How long the main loop may block: forever unless a completion request
    /// is scheduled, which is the only timer zedit ever arms.
    fn pollTimeout(self: *Editor) i32 {
        const due = self.comp_due_ms orelse return -1;
        const left = due - log.nowMs();
        return if (left <= 0) 0 else @intCast(@min(left, std.math.maxInt(i32)));
    }

    /// True when the debounce has elapsed (the caller then sends the request).
    fn completionDue(self: *Editor) bool {
        const due = self.comp_due_ms orelse return false;
        return log.nowMs() >= due;
    }

    /// Fire the action the shared debounce timer was armed for.
    fn fireDue(self: *Editor) void {
        switch (self.due_kind) {
            .completion => self.lspCompletion(),
            .wsymbol => self.sendWorkspaceSymbolQuery(),
            .grep => self.grepRescan(),
        }
    }

    /// Arm the auto-completion debounce after an identifier keystroke. Typing
    /// on keeps pushing the deadline out, so a request only goes out when the
    /// typist pauses — one round trip per pause, not per character.
    fn armCompletion(self: *Editor) void {
        if (!config.settings.auto_completion) return;
        if (self.mode != .insert or self.lsp == null) return;
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

    fn compMove(self: *Editor, down: bool) void {
        const n = self.comp_filtered.items.len;
        if (n == 0) return;
        if (down) {
            if (self.comp_sel + 1 < n) self.comp_sel += 1;
        } else if (self.comp_sel > 0) self.comp_sel -= 1;
    }

    /// Rebuild the visible list from the prefix under the cursor, fuzzily:
    /// `mc` matches `mockComplete`, and candidates are ranked by the same
    /// scorer the pickers use (consecutive runs and word starts win).
    fn filterCompletions(self: *Editor) void {
        self.comp_filtered.clearRetainingCapacity();
        const client = if (self.lsp) |*c| c else {
            self.comp_open = false;
            return;
        };
        const prefix = self.completionPrefix();
        const qmask = fuzzy.charMask(prefix);
        var scored: std.ArrayList(Scored) = .empty;
        defer scored.deinit(self.gpa);
        for (client.completions.items, 0..) |it, i| {
            if (prefix.len == 0) {
                self.comp_filtered.append(self.gpa, i) catch {};
                continue;
            }
            if (!fuzzy.maskMatches(fuzzy.charMask(it.label), qmask)) continue; // cheap reject
            const s = fuzzy.score(it.label, prefix) orelse continue;
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
        const client = if (self.lsp) |*c| c else return;
        if (self.comp_sel >= self.comp_filtered.items.len) return;
        const item = client.completions.items[self.comp_filtered.items[self.comp_sel]];

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
    fn yankTo(self: *Editor, text: []const u8, linewise: bool) void {
        self.registers.set(self.pending_register, text, linewise) catch {};
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

    fn stopMacro(self: *Editor) void {
        // The closing 'q' was recorded by processInput; drop it.
        if (self.macro_buf.items.len > 0) self.macro_buf.items.len -= 1;
        const reg = self.recording.?;
        self.registers.set(reg, self.macro_buf.items, false) catch {};
        self.recording = null;
        self.setStatus("recorded @{c}", .{reg});
    }

    fn playMacro(self: *Editor, reg: u8, times: usize) !void {
        const r = self.registers.get(reg) orelse return;
        // Copy: replaying may overwrite the register.
        const keys = self.gpa.dupe(u8, r.text) catch return;
        defer self.gpa.free(keys);
        var i: usize = 0;
        while (i < times) : (i += 1) try self.replayBytes(keys);
    }

    fn repeatDot(self: *Editor) !void {
        if (self.dot_keys.items.len == 0) {
            self.resetPending();
            return;
        }
        const times = self.eff();
        const keys = self.gpa.dupe(u8, self.dot_keys.items) catch return;
        defer self.gpa.free(keys);
        self.resetPending();
        self.in_dot = true;
        defer self.in_dot = false;
        var i: usize = 0;
        while (i < times) : (i += 1) try self.replayBytes(keys);
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

    /// The buffer line `n` screen rows away from `row`. With soft wrap a tall
    /// line is worth several rows, so a page covers fewer lines than there are
    /// rows on screen — which is what makes `Ctrl-f` land where it looks like
    /// it should.
    fn lineAfterRows(self: *Editor, row: usize, n: usize, up: bool) usize {
        const last = self.buf.lineCount() - 1;
        if (!self.wrapping()) return if (up) row -| n else @min(row + n, last);
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
            used += self.lineRows(r);
        }
        return r;
    }

    fn pageMove(self: *Editor, up: bool) void {
        self.cy = self.lineAfterRows(self.cy, self.textRows(), up);
        self.snapColumn();
        self.resetPending();
    }

    fn eff(self: *Editor) usize {
        return if (self.count == 0) 1 else self.count;
    }

    fn total(self: *Editor) usize {
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
        const line = self.curLine();
        const limit = switch (self.mode) {
            .normal, .visual, .visual_line, .visual_block => lastColumn(line),
            .insert, .command, .picker => line.len,
        };
        if (self.cx > limit) self.cx = limit;
    }

    // === viewport ==========================================================

    // Viewport metrics refer to the active window (set by the last layout).
    fn textRows(self: *Editor) usize {
        return self.winTextRows(self.cur);
    }

    fn textCols(self: *Editor) usize {
        const g = self.gutterWidth();
        return if (self.cur.gw > g) self.cur.gw - g else 1;
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

    /// The layout of buffer line `row` in the active window.
    fn lineLayout(self: *Editor, row: usize) WrapLayout {
        if (row >= self.buf.lineCount()) return .{ .starts = .{0} ** max_wrap_rows, .n = 1, .indent = 0 };
        return layoutLine(
            self.buf.line(row),
            self.textCols(),
            if (row == self.cy) self.cursorDisplayCol() else null,
            self.wrapping(),
            @max(1, self.textRows()),
        );
    }

    /// Rows the active window spends on buffer line `row`.
    fn lineRows(self: *Editor, row: usize) usize {
        if (!self.wrapping()) return 1;
        return self.lineLayout(row).n;
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
        if (!self.wrapping()) return self.cy -| self.top;
        var used: usize = 0;
        var row = self.top;
        while (row < self.cy) : (row += 1) used += self.lineRows(row);
        return used + self.cursorSeg();
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
        if (self.wrapping()) return self.scrollWrapped();
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
        // The two diff views are exclusive per file: opening one closes the
        // other first, so they can never stack into a third window, and the
        // split starts from the pre-diff layout with the orientation this
        // view sets.
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
        // The two diff views are exclusive per file (see gitDiffInline): an
        // open inline diff closes before the pair opens, so the vertical
        // split starts from the pre-diff layout.
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
    /// horizontal). Scratch docs have no path; `:w <name>` can still save them.
    fn openScratch(self: *Editor, label: []const u8, content: []const u8, lang: syntax.Language, vert: bool) void {
        const nb = buffer.Buffer.fromBytes(self.gpa, content) catch return;
        const doc = makeDoc(self.gpa, nb) catch {
            var b = nb;
            b.deinit();
            return;
        };
        doc.lang = lang;
        doc.name = self.gpa.dupe(u8, label) catch null;
        self.docs.append(self.gpa, doc) catch {
            doc.buf.deinit();
            freeDocState(doc, self.gpa);
            self.gpa.destroy(doc);
            return;
        };
        self.splitWindow(vert);
        self.focusDoc(doc);
        self.clearExtra();
        self.placeAt(0);
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

    /// `Space e`: open + focus the sidebar, or close it when already open.
    fn sidebarToggle(self: *Editor) void {
        if (self.sb_open) {
            self.sb_open = false;
            self.sb_focus = false;
        } else {
            self.sb_open = true;
            self.sb_focus = true;
            self.sbRebuild();
        }
    }

    fn sidebarKey(self: *Editor, k: key.Key) !void {
        const n = self.sb_entries.items.len;
        switch (k) {
            .escape => self.sb_focus = false, // keep it open, focus the buffer
            .down => self.sbMove(1),
            .up => self.sbMove(-1),
            .enter => try self.sbActivate(),
            .char => |c| switch (c) {
                'j' => self.sbMove(1),
                'k' => self.sbMove(-1),
                'g' => self.sb_sel = 0,
                'G' => self.sb_sel = if (n > 0) n - 1 else 0,
                'l' => try self.sbActivate(),
                'h' => self.sbCollapse(),
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
        } else {
            const owned = self.gpa.dupe(u8, path) catch return;
            self.sb_expanded.put(owned, {}) catch {
                self.gpa.free(owned);
                return;
            };
        }
        self.sbRebuild();
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
        if (self.split_vertical and n > 1) {
            const each = avail / n;
            var x: usize = x0;
            for (self.wins.items, 0..) |w, i| {
                const ww = if (i == n - 1) (if (x0 + avail > x) x0 + avail - x else 1) else each;
                w.gx = x;
                w.gy = 1 + tab_h;
                w.gw = ww;
                w.gh = total_rows;
                x += ww;
            }
        } else {
            const each = if (n > 0) total_rows / n else total_rows;
            var y: usize = 1 + tab_h;
            for (self.wins.items, 0..) |w, i| {
                const wh = if (i == n - 1) (if (total_rows + 1 + tab_h > y) total_rows + tab_h - y + 1 else 1) else each;
                w.gx = x0;
                w.gy = y;
                w.gw = avail;
                w.gh = wh;
                y += wh;
            }
        }
    }

    fn buildView(self: *Editor, w: *Win) View {
        const doc = w.doc;
        const g = gutterFor(doc.buf.lineCount());
        const cols = if (w.gw > g) w.gw - g else 1;
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
    /// mirrors. Paired panes get vimdiff-style change-line tinting.
    fn diffTinted(self: *Editor, w: *Win) bool {
        if (w.doc.diff_of != null) return true;
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

    fn renderWindow(self: *Editor, w: *Win) !void {
        const th = theme.current;
        const view = self.buildView(w);
        const text_rows = self.winTextRows(w);
        const tinted = self.diffTinted(w);
        // A visible diff pair renders in aligned display rows: each screen row
        // resolves through the hunks to a buffer row or a virtual filler, so
        // matching text sits level across the panes (VS Code style).
        const pair = self.diffPairOf(w);
        const new_side = if (pair) |p| w == p.wt else false;
        const dtop = if (pair) |p| self.diffDisplayTop(p) else 0;
        var r: usize = 0;
        var file_row = view.top;
        // With soft wrap one buffer line can fill several screen rows, so the
        // walk is over (line, segment) pairs; without it every line is one row
        // and `seg` never leaves 0.
        var seg: usize = 0;
        var wl: WrapLayout = .{ .starts = .{0} ** max_wrap_rows, .n = 1, .indent = 0 };
        while (r < text_rows) : (r += 1) {
            self.beginSeg(w.gy + r, w.gx);
            try self.emitFmt("\x1b[{d};{d}H", .{ w.gy + r, w.gx });
            if (pair) |p| switch (git.slotAt(p.hunks, new_side, dtop + r)) {
                .filler => {
                    try self.emitFillerRow(w, new_side);
                    continue;
                },
                .row => |br| file_row = br,
            };
            if (file_row >= view.buf.lineCount()) {
                try self.setBg(th.bg);
                try self.setFg(th.fg_dim);
                try self.emit("~");
                try self.emitSpaces(w.gw - 1);
                file_row += 1;
                continue;
            }
            const is_cur = view.active and file_row == view.cy;
            var row_bg = if (is_cur) th.cursorline else th.bg;
            if (tinted and !is_cur) {
                if (view.git.get(file_row)) |sign| {
                    row_bg = mixColor(th.bg, switch (sign) {
                        .added => th.git_add,
                        .changed => th.git_change,
                        .deleted => th.git_delete,
                    }, 25);
                }
            }
            try self.setBg(row_bg);
            if (seg == 0) {
                // One layout per line, reused for each row it fills.
                wl = layoutLine(
                    view.buf.line(file_row),
                    view.cols,
                    if (is_cur) self.cursorDisplayCol() else null,
                    view.wrap,
                    @max(1, text_rows),
                );
                try self.emitGutter(&view, file_row);
            } else try self.emitWrapGutter(&view);
            try self.emitLine(&view, file_row, row_bg, seg, wl);
            seg += 1;
            if (seg >= wl.n) {
                seg = 0;
                file_row += 1;
            }
        }
        if (self.wins.items.len > 1) try self.emitWinStatus(w, view);
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
        var overlay = self.sig_open or self.comp_open;
        if (self.mode == .command and self.wild.items.len > 0) {
            try self.renderWildMenu();
            overlay = true;
        }
        switch (self.await_arg) {
            .space_leader, .space_find, .space_lang, .space_git, .space_buffer => {
                try self.renderWhichKey();
                overlay = true;
            },
            else => {},
        }
        if (self.sig_open) try self.renderSignature(gutter);
        if (self.comp_open) try self.renderCompletion(gutter);
        try self.emit(ansi.reset_attrs);
        try self.placeCursor(gutter);
        try self.emit(ansi.show_cursor);
        try self.writeFrame(!overlay);
        sp.lap("render");
    }

    // The AstroNvim-style leader tree, shown by the which-key popup.
    const WhichKey = struct { key: []const u8, desc: []const u8 };
    const leader_keys = [_]WhichKey{
        .{ .key = "b", .desc = "Buffers \u{2026}" },
        .{ .key = "f", .desc = "Find \u{2026}" },
        .{ .key = "l", .desc = "Language tools \u{2026}" },
        .{ .key = "g", .desc = "Git \u{2026}" },
        .{ .key = "e", .desc = "explorer" },
        .{ .key = "c", .desc = "close buffer" },
        .{ .key = "w", .desc = "write (save)" },
        .{ .key = "q", .desc = "quit" },
    };
    const buffer_keys = [_]WhichKey{
        .{ .key = "b", .desc = "find buffers" },
        .{ .key = "n", .desc = "next buffer" },
        .{ .key = "p", .desc = "previous buffer" },
        .{ .key = "c", .desc = "close buffer" },
    };
    const find_keys = [_]WhichKey{
        .{ .key = "f", .desc = "find files" },
        .{ .key = "w", .desc = "find words" },
        .{ .key = "b", .desc = "find buffers" },
        .{ .key = "t", .desc = "find themes" },
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
    const git_keys = [_]WhichKey{
        .{ .key = "d", .desc = "diff (inline)" },
        .{ .key = "s", .desc = "diff (side by side)" },
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
    fn tabCells(doc: *Doc) usize {
        const name = std.fs.path.basename(docLabel(doc));
        return 2 + unicode.displayWidth(name) + @as(usize, if (doc.buf.dirty) 2 else 0) + sepCells();
    }

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
    fn tabAt(self: *Editor, col: usize) ?*Doc {
        const area = self.tabArea();
        var x = area.x0;
        for (self.docs.items) |doc| {
            const w = tabCells(doc);
            if (x + w > area.x0 + area.w) break;
            if (col >= x and col < x + w) return doc;
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
            const shown = @min(hdr.len, sb_w -| sepCells());
            try self.setBg(hdr_bg);
            try self.setFg(hdr_fg);
            try self.emit(hdr[0..shown]);
            try self.emitSpaces(sb_w -| sepCells() -| shown);
            if (sepCells() > 0) {
                const first_bg = if (self.docs.items.len > 0 and tabCells(self.docs.items[0]) <= area.w)
                    self.tabBg(self.docs.items[0])
                else
                    th.status_bg;
                try self.setBg(first_bg);
                try self.setFg(hdr_bg);
                try self.emit(sepRight());
            }
        }

        var used: usize = 0;
        for (self.docs.items, 0..) |doc, i| {
            const w = tabCells(doc);
            if (used + w > area.w) break;
            const bg = self.tabBg(doc);
            try self.setBg(bg);
            try self.setFg(if (doc == self.d) th.bg else th.fg_dim);
            try self.emit(" ");
            try self.emitSanitized(std.fs.path.basename(docLabel(doc)));
            if (doc.buf.dirty) try self.emit(" \u{25CF}");
            try self.emit(" ");
            used += w;
            if (sepCells() > 0) {
                // The transition cell: a solid arrow between different
                // colours, a thin chevron between same-coloured tabs.
                const next_bg = if (i + 1 < self.docs.items.len and used + tabCells(self.docs.items[i + 1]) <= area.w)
                    self.tabBg(self.docs.items[i + 1])
                else
                    th.status_bg; // the filler
                if (bg.r == next_bg.r and bg.g == next_bg.g and bg.b == next_bg.b) {
                    try self.setFg(th.fg_dim);
                    try self.emit(sepRightThin());
                } else {
                    try self.setBg(next_bg);
                    try self.setFg(bg);
                    try self.emit(sepRight());
                }
            }
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
        const rows: usize = self.win.rows;
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

    /// Draw the which-key popup for the pending leader menu (`Space`, `Space f`
    /// or `Space l`), anchored above the status bar.
    fn renderWhichKey(self: *Editor) !void {
        const th = theme.current;
        const menu: []const WhichKey = switch (self.await_arg) {
            .space_leader => &leader_keys,
            .space_find => &find_keys,
            .space_lang => &lang_keys,
            .space_git => &git_keys,
            .space_buffer => &buffer_keys,
            else => return,
        };
        const title: []const u8 = switch (self.await_arg) {
            .space_leader => " SPACE",
            .space_find => " SPACE f",
            .space_lang => " SPACE l",
            .space_git => " SPACE g",
            .space_buffer => " SPACE b",
            else => unreachable,
        };
        const width: usize = 26;
        const rows: usize = self.win.rows;
        const height = menu.len + 1;
        if (rows < height + 2) return;
        const top = rows - height - 1; // 1-based; leave the status bar at the bottom
        self.markOverlayRows(top, top + height);

        try self.emitFmt("\x1b[{d};1H", .{top});
        try self.setBg(th.mode_command);
        try self.setFg(th.bg);
        try self.emit(title);
        try self.emitSpaces(width - title.len);

        for (menu, 0..) |it, i| {
            try self.emitFmt("\x1b[{d};1H", .{top + 1 + i});
            try self.setBg(th.status_seg_bg);
            try self.setFg(th.mode_normal);
            try self.emitFmt("  {s}  ", .{it.key});
            try self.setFg(th.status_seg_fg);
            try self.emit(it.desc);
            const used = 2 + it.key.len + 2 + unicode.displayWidth(it.desc);
            if (used < width) try self.emitSpaces(width - used);
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
        const client = if (self.lsp) |*c| c else return;
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
            const label = client.completions.items[items[first + vi]].label;
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
            const label = client.completions.items[items[idx]].label;
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

        // Leftmost column: an LSP diagnostic sign (active window only) takes
        // priority over a git sign.
        var sign_drawn = false;
        if (view.active) {
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
            const selected = if (sel) |s| (byte >= s.lo and byte < s.hi) else false;
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

    fn renderStatus(self: *Editor) !void {
        const th = theme.current;
        const cols: usize = self.win.cols;

        // Command / search line: a simple prompt across the bar.
        if (self.mode == .command) {
            try self.setBg(th.status_bg);
            try self.setFg(th.fg);
            const prompt = self.cmdPrompt();
            try self.emit(prompt);
            const room = if (cols > prompt.len) cols - prompt.len else 0;
            // Both the typed text and the ghost are clipped to the row by
            // display cells on codepoint boundaries (a byte clip underfills
            // the row on wide chars and can tear a codepoint).
            const line = clipCells(self.cmd.items, room);
            try self.emitSanitized(self.cmd.items[0..line.bytes]);
            var pad = room - line.cells;
            // Inline suggestion: the rest of the best match, dim, painted
            // after the terminal cursor. Shown only with the cursor at
            // end-of-line (fish hides suggestions mid-line) and hidden while
            // the wildmenu ring holds the line.
            if (self.wild.items.len == 0 and self.ghost.items.len > 0 and self.cmd_cur == self.cmd.items.len) {
                const g = clipCells(self.ghost.items, pad);
                try self.setFg(th.fg_dim);
                try self.emitSanitized(self.ghost.items[0..g.bytes]);
                pad -= g.cells;
            }
            try self.emitSpaces(pad);
            return;
        }

        const accent = self.modeColor();
        const label = self.mode.label();

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
            langName(self.lang), self.cy + 1, displayCol(self.curLine(), self.cx) + 1,
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

    fn modeColor(self: *Editor) Color {
        const th = theme.current;
        return switch (self.mode) {
            .normal => th.mode_normal,
            .insert => th.mode_insert,
            .visual, .visual_line, .visual_block => th.mode_visual,
            .command, .picker => th.mode_command,
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
            row = self.win.rows;
            // A line longer than the row is clipped (no horizontal cmdline
            // scroll), so pin the cursor to the last cell rather than sending
            // the terminal a column past the edge.
            col = @min(self.cmdPrompt().len + 1 + unicode.displayWidth(self.cmd.items[0..self.cmd_cur]), self.win.cols);
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
    if (tail[1] != '[' and tail[1] != 'O') return false; // ESC+other: complete
    if (tail.len == 2) return true; // introducer without its body yet
    if (tail[1] == 'O') return false; // SS3 is exactly three bytes
    for (tail[2..]) |b| {
        if (b >= 0x40 and b <= 0x7e) return false; // CSI final byte seen
    }
    return true;
}

/// The leading whitespace (spaces/tabs) of a line.
fn leadingIndent(line: []const u8) []const u8 {
    return line[0 .. std.mem.indexOfNone(u8, line, " \t") orelse line.len];
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

fn langName(l: syntax.Language) []const u8 {
    return switch (l) {
        .zig => "zig",
        .c => "c",
        .python => "python",
        .javascript => "js",
        .typescript => "ts",
        .json => "json",
        .rust => "rust",
        .go => "go",
        .html => "html",
        .markdown => "md",
        .diff => "diff",
        .none => "text",
    };
}

/// LSP languageId for a detected language.
fn langId(l: syntax.Language) []const u8 {
    return switch (l) {
        .zig => "zig",
        .c => "c",
        .python => "python",
        .javascript => "javascript",
        .typescript => "typescript",
        .json => "json",
        .rust => "rust",
        .go => "go",
        .html => "html",
        .markdown => "markdown",
        .diff => "diff",
        .none => "plaintext",
    };
}

/// Default language-server command per language (used when --lsp is not given).
fn defaultServer(l: syntax.Language) ?[]const []const u8 {
    return switch (l) {
        .zig => &.{"zls"},
        .c => &.{"clangd"},
        .python => &.{"pylsp"},
        .javascript, .typescript => &.{ "typescript-language-server", "--stdio" },
        .rust => &.{"rust-analyzer"},
        .go => &.{"gopls"},
        else => null,
    };
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

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
const ansi = term.ansi;
const Allocator = std.mem.Allocator;
const Pos = buffer.Pos;
const Color = theme.Color;

// Powerline separators and the indent-guide glyph (nerd font recommended).
const sep_right = "\u{E0B0}";
const sep_left = "\u{E0B2}";
const indent_glyph = "\u{2502}";

/// Spaces a tab advances to. Tabs are stored verbatim and expanded on render.
const tab_width = 4;

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

const PickerKind = enum { files, grep };
const PickItem = struct { display: []u8, path: []u8, line: usize };

const Operator = enum { none, delete, change, yank, indent_right, indent_left, comment, surround };

/// What the next key supplies an argument for.
const Await = enum {
    none,
    find_f, // f: forward, inclusive, land on char
    find_t, // t: forward, inclusive, land before char
    find_cap_f, // F: backward
    find_cap_t, // T: backward
    replace, // r{char}
    mark_set, // m{a-z}
    mark_jump_back, // `{a-z} exact
    mark_jump_line, // '{a-z} line
    register, // "{a-z}
    g_prefix, // g then ...
    z_prefix, // Z then Z/Q
    object_inner, // operator i{obj}
    object_around, // operator a{obj}
    macro_record, // q{reg}
    macro_play, // @{reg}
    space_leader, // <space> menu (which-key)
    surround_add_char, // ys{motion}{char} / visual S{char}
    surround_delete, // ds{char}
    surround_change_from, // cs{old}...
    surround_change_to, // cs{old}{new}
};

const CmdKind = enum { ex, search_forward, search_backward };

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

pub const Editor = struct {
    gpa: Allocator,
    io: std.Io,
    term: *term.Terminal,
    buf: buffer.Buffer,

    mode: Mode,
    cy: usize,
    cx: usize,
    goal_col: usize,

    top: usize,
    left: usize,
    win: term.Size,

    // command assembly
    count: usize,
    count2: usize,
    operator: Operator,
    await_arg: Await,
    pending_register: ?u8,
    last_find: ?Find,

    // subsystems
    registers: register.Store,
    history: undo.History,
    marks: [26]?Pos,

    // visual
    vstart: Pos,

    // multiple cursors (one per line; primary stays cy/cx). Empty = single cursor.
    extra: std.ArrayList(Pos),

    // surround pending state
    surr_span: ?Span,
    surr_from: u8,

    // search
    last_search: std.ArrayList(u8),
    last_search_forward: bool,
    search_origin: Pos, // cursor when a / or ? search began (for incremental preview)
    prev_search: std.ArrayList(u8), // last_search saved on entry, restored if cancelled

    // command/search line
    cmd: std.ArrayList(u8),
    cmd_kind: CmdKind,

    // picker (fuzzy file finder / global search)
    picker_kind: PickerKind,
    picker_items: std.ArrayList(PickItem),
    picker_files: std.ArrayList([]u8),
    picker_filtered: std.ArrayList(usize),
    picker_query: std.ArrayList(u8),
    picker_sel: usize,
    picker_scroll: usize,

    // macros
    recording: ?u8,
    macro_buf: std.ArrayList(u8),
    replay_depth: usize,

    // dot-repeat
    dot_keys: std.ArrayList(u8),
    dot_temp: std.ArrayList(u8),
    change_started: bool,
    in_dot: bool,

    // rendering / io
    frame: std.ArrayList(u8),
    status: std.ArrayList(u8),
    lang: syntax.Language,
    style_buf: std.ArrayList(syntax.Style),
    git_signs: git.Signs,
    cur_fg: ?Color,
    cur_bg: ?Color,

    // tree-sitter highlighting (lexer fallback when null). The query runs only
    // over the visible byte range; ts_styles holds styles for that range.
    ts: ?treesitter.Highlighter,
    ts_styles: std.ArrayList(syntax.Style), // styles for [ts_vis_start, ...)
    ts_line_starts: std.ArrayList(usize), // whole-document per-line byte offset
    ts_doc_len: usize,
    ts_vis_start: usize, // doc byte offset of the queried region
    ts_rev: u64, // buffer revision last parsed
    ts_q_top: usize, // viewport top of the last query (sentinel = stale)
    ts_q_rows: usize,

    // language server
    lsp_cmd: ?[]const u8, // override command, else a per-language default
    lsp: ?lsp.Client,
    lsp_rev: u64, // buffer revision last sent via didChange
    // completion popup (insert mode)
    comp_open: bool,
    comp_filtered: std.ArrayList(usize), // indices into lsp.completions matching the prefix
    comp_sel: usize,
    sig_open: bool, // signature-help popup is showing (reads lsp.signature)

    quit: bool,
    inbuf: [256]u8,

    pub fn init(gpa: Allocator, io: std.Io, t: *term.Terminal, buf: buffer.Buffer, lsp_cmd: ?[]const u8) Editor {
        return .{
            .gpa = gpa,
            .io = io,
            .term = t,
            .buf = buf,
            .mode = .normal,
            .cy = 0,
            .cx = 0,
            .goal_col = 0,
            .top = 0,
            .left = 0,
            .win = .{ .rows = 24, .cols = 80 },
            .count = 0,
            .count2 = 0,
            .operator = .none,
            .await_arg = .none,
            .pending_register = null,
            .last_find = null,
            .registers = register.Store.init(gpa),
            .history = undo.History.init(gpa),
            .marks = [_]?Pos{null} ** 26,
            .vstart = .{ .row = 0, .col = 0 },
            .extra = .empty,
            .surr_span = null,
            .surr_from = 0,
            .last_search = .empty,
            .last_search_forward = true,
            .search_origin = .{ .row = 0, .col = 0 },
            .prev_search = .empty,
            .cmd = .empty,
            .cmd_kind = .ex,
            .picker_kind = .files,
            .picker_items = .empty,
            .picker_files = .empty,
            .picker_filtered = .empty,
            .picker_query = .empty,
            .picker_sel = 0,
            .picker_scroll = 0,
            .recording = null,
            .macro_buf = .empty,
            .replay_depth = 0,
            .dot_keys = .empty,
            .dot_temp = .empty,
            .change_started = false,
            .in_dot = false,
            .frame = .empty,
            .status = .empty,
            .lang = syntax.detect(buf.path),
            .style_buf = .empty,
            .git_signs = git.Signs.init(gpa),
            .cur_fg = null,
            .cur_bg = null,
            .ts = null,
            .ts_styles = .empty,
            .ts_line_starts = .empty,
            .ts_doc_len = 0,
            .ts_vis_start = 0,
            .ts_rev = 0,
            .ts_q_top = std.math.maxInt(usize),
            .ts_q_rows = 0,
            .lsp_cmd = lsp_cmd,
            .lsp = null,
            .lsp_rev = 0,
            .comp_open = false,
            .comp_filtered = .empty,
            .comp_sel = 0,
            .sig_open = false,
            .quit = false,
            .inbuf = undefined,
        };
    }

    pub fn deinit(self: *Editor) void {
        self.registers.deinit();
        self.history.deinit();
        self.last_search.deinit(self.gpa);
        self.prev_search.deinit(self.gpa);
        self.cmd.deinit(self.gpa);
        self.macro_buf.deinit(self.gpa);
        self.dot_keys.deinit(self.gpa);
        self.dot_temp.deinit(self.gpa);
        self.frame.deinit(self.gpa);
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
        self.picker_files.deinit(self.gpa);
        self.picker_filtered.deinit(self.gpa);
        self.picker_query.deinit(self.gpa);
        self.buf.deinit();
    }

    pub fn run(self: *Editor) !void {
        try self.term.enableRaw();
        self.term.installResizeHandler();
        try self.term.enterAltScreen();
        self.win = self.term.size();
        self.refreshGit();
        self.setStatus("zed {s} — :q to quit, i to insert", .{@import("cli.zig").version});

        self.startTs();

        // Paint the file before starting the language server, whose handshake
        // can block briefly.
        self.scroll();
        try self.render();
        self.startLsp();

        var needs_render = true;
        while (!self.quit) {
            if (needs_render) {
                self.scroll();
                try self.render();
                needs_render = false;
            }
            const lsp_fd: ?std.posix.fd_t = if (self.lsp) |*c| (if (c.alive) c.out_fd else null) else null;
            const ready = try self.term.waitReady(lsp_fd);
            if (self.term.takeResize()) {
                self.win = self.term.size();
                needs_render = true;
                continue;
            }
            if (ready.other) {
                if (self.lsp) |*c| c.processReadable();
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
        if (n == 1 and self.inbuf[0] == 0x1b and self.term.waitMore(25)) {
            n += (try self.term.read(self.inbuf[n..])).len;
        }
        return self.inbuf[0..n];
    }

    /// User input from the terminal: decode keys, record macros, dispatch.
    fn processInput(self: *Editor, chunk: []const u8) !void {
        var sp = log.Span.start();
        var i: usize = 0;
        while (i < chunk.len) {
            const d = key.decode(chunk[i..]);
            const raw = chunk[i .. i + d.consumed];
            i += d.consumed;
            if (self.recording != null) self.macro_buf.appendSlice(self.gpa, raw) catch {};
            try self.feedKey(d.key, raw);
            if (self.quit) break;
        }
        sp.lap("input");
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
        if (!self.in_dot) self.dotCapturePre(raw);
        try self.handleKey(k);
        if (!self.in_dot) self.dotCapturePost();
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
            .left => self.moveAndReset(.{ .pos = self.left1(), .kind = .exclusive, .col_mode = .exact }),
            .right => self.moveAndReset(.{ .pos = self.right1(), .kind = .exclusive, .col_mode = .exact }),
            .up => self.doMotion(self.vertical(true, 1)),
            .down => self.doMotion(self.vertical(false, 1)),
            .home => self.moveAndReset(.{ .pos = .{ .row = self.cy, .col = 0 }, .kind = .exclusive, .col_mode = .exact }),
            .end => self.moveAndReset(.{ .pos = .{ .row = self.cy, .col = self.curLine().len }, .kind = .inclusive, .col_mode = .exact }),
            .backspace => self.moveAndReset(.{ .pos = self.left1(), .kind = .exclusive, .col_mode = .exact }),
            .page_up => self.pageMove(true),
            .page_down => self.pageMove(false),
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
            '%' => if (motion.matchPair(&self.buf, self.cursor())) |p| self.doMotion(.{ .pos = p, .kind = .inclusive, .col_mode = .exact }) else self.resetPending(),
            'H' => self.doMotion(self.gotoLineMotion(self.top)),
            'M' => self.doMotion(self.gotoLineMotion(self.top + self.textRows() / 2)),
            'L' => self.doMotion(self.gotoLineMotion(@min(self.top + self.textRows() - 1, self.buf.lineCount() - 1))),
            'f' => self.await_arg = .find_f,
            't' => self.await_arg = .find_t,
            'F' => self.await_arg = .find_cap_f,
            'T' => self.await_arg = .find_cap_t,
            ';' => self.repeatFind(false),
            ',' => self.repeatFind(true),
            'g' => self.await_arg = .g_prefix,
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
                self.cy = @min(self.cy + self.textRows() / 2, self.buf.lineCount() - 1);
                self.snapColumn();
                self.resetPending();
            },
            'u' => {
                const half = self.textRows() / 2;
                self.cy = if (self.cy > half) self.cy - half else 0;
                self.snapColumn();
                self.resetPending();
            },
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
                if (markIndex(k)) |idx| if (self.marks[idx]) |p| self.setCursor(p);
                self.resetPending();
            },
            .mark_jump_line => {
                if (markIndex(k)) |idx| if (self.marks[idx]) |p| {
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
                } else
                    self.resetPending();
            },
            .z_prefix => {
                if (k == .char and k.char == 'Z') {
                    if (try self.write(self.cmdArgNone())) self.quit = true;
                } else if (k == .char and k.char == 'Q') {
                    self.quit = true;
                }
                self.resetPending();
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
            .space_leader => {
                self.resetPending();
                if (k == .char) switch (k.char) {
                    'f' => self.openFilePicker(),
                    '/', 's' => self.openGrepPicker(),
                    'w' => _ = try self.write(""),
                    'q' => self.doQuit(),
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
        const span = self.surr_span orelse return;
        self.surr_span = null;
        const pair = surroundPair(c) orelse return;
        self.pushUndo();
        try self.buf.insertBytes(span.end.row, span.end.col, pair.close);
        try self.buf.insertBytes(span.start.row, span.start.col, pair.open);
        self.setCursor(span.start);
    }

    fn surroundDelete(self: *Editor, c: u8) !void {
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

    /// The around-span (delimiters inclusive) of the pair identified by `c`.
    fn findSurroundSpan(self: *Editor, c: u8) ?motion.Span {
        return switch (c) {
            '(', ')', 'b' => motion.objPair(&self.buf, self.cursor(), '(', ')', true),
            '[', ']' => motion.objPair(&self.buf, self.cursor(), '[', ']', true),
            '{', '}', 'B' => motion.objPair(&self.buf, self.cursor(), '{', '}', true),
            '<', '>' => motion.objPair(&self.buf, self.cursor(), '<', '>', true),
            '"' => motion.objQuote(&self.buf, self.cursor(), '"', true),
            '\'' => motion.objQuote(&self.buf, self.cursor(), '\'', true),
            '`' => motion.objQuote(&self.buf, self.cursor(), '`', true),
            else => null,
        };
    }

    fn textObjectSpan(self: *Editor, around: bool, c: u8) ?Span {
        const obj: ?motion.Span = switch (c) {
            'w' => motion.objWord(&self.buf, self.cursor(), false, around),
            'W' => motion.objWord(&self.buf, self.cursor(), true, around),
            '(', ')', 'b' => motion.objPair(&self.buf, self.cursor(), '(', ')', around),
            '[', ']' => motion.objPair(&self.buf, self.cursor(), '[', ']', around),
            '{', '}', 'B' => motion.objPair(&self.buf, self.cursor(), '{', '}', around),
            '<', '>' => motion.objPair(&self.buf, self.cursor(), '<', '>', around),
            '"' => motion.objQuote(&self.buf, self.cursor(), '"', around),
            '\'' => motion.objQuote(&self.buf, self.cursor(), '\'', around),
            '`' => motion.objQuote(&self.buf, self.cursor(), '`', around),
            else => null,
        };
        const o = obj orelse return null;
        const end_excl = if (o.empty) o.end else Pos{ .row = o.end.row, .col = unicode.nextBoundary(self.buf.line(o.end.row), o.end.col) };
        return .{ .lines = false, .start = o.start, .end = end_excl };
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

    fn moveAndReset(self: *Editor, res: MotionResult) void {
        self.doMotion(res);
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

    fn right1(self: *Editor) Pos {
        const line = self.curLine();
        return .{ .row = self.cy, .col = if (self.cx < line.len) unicode.nextBoundary(line, self.cx) else self.cx };
    }

    fn vertical(self: *Editor, up: bool, n: usize) MotionResult {
        const row = if (up) (if (self.cy > n) self.cy - n else 0) else @min(self.cy + n, self.buf.lineCount() - 1);
        return .{ .pos = .{ .row = row, .col = 0 }, .kind = .linewise, .col_mode = .keep_goal };
    }

    fn endOfLineMotion(self: *Editor) MotionResult {
        var row = self.cy;
        const extra = self.eff();
        if (extra > 1) row = @min(self.cy + extra - 1, self.buf.lineCount() - 1);
        return .{ .pos = .{ .row = row, .col = self.buf.line(row).len }, .kind = .inclusive, .col_mode = .exact };
    }

    fn gotoLineMotion(self: *Editor, row: usize) MotionResult {
        return .{ .pos = .{ .row = @min(row, self.buf.lineCount() - 1), .col = 0 }, .kind = .linewise, .col_mode = .first_non_blank };
    }

    fn repeatWord(self: *Editor, which: WordKind, big: bool) MotionResult {
        var p = self.cursor();
        var i: usize = 0;
        const n = if (self.operator != .none) self.total() else self.eff();
        while (i < n) : (i += 1) {
            p = switch (which) {
                .f => motion.wordForward(&self.buf, p, big),
                .b => motion.wordBackward(&self.buf, p, big),
                .e => motion.wordEnd(&self.buf, p, big),
            };
        }
        return .{ .pos = p, .kind = if (which == .e) .inclusive else .exclusive, .col_mode = .exact };
    }

    fn applyFind(self: *Editor, kind: Await, ch: u21) void {
        const line = self.curLine();
        const forward = kind == .find_f or kind == .find_t;
        const till = kind == .find_t or kind == .find_cap_t;
        if (motion.findChar(line, self.cx, ch, forward, till)) |col| {
            const inclusive = forward; // forward find/till is inclusive; backward is exclusive
            self.doMotion(.{ .pos = .{ .row = self.cy, .col = col }, .kind = if (inclusive) .inclusive else .exclusive, .col_mode = .exact });
        } else {
            self.resetPending();
        }
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
        switch (op) {
            .indent_right => return self.indent(span, true),
            .indent_left => return self.indent(span, false),
            .comment => return self.toggleComment(span),
            else => {},
        }
        const text = self.extract(span) catch return;
        defer self.gpa.free(text);
        self.registers.set(self.pending_register, text, span.lines) catch {};

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
            self.buf.setLine(span.top, "") catch {};
            var i: usize = 0;
            while (i < span.bot - span.top) : (i += 1) self.buf.removeLineAt(span.top + 1);
            self.cy = span.top;
            self.cx = 0;
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
                while (rm < tab_width and rm < line.len and line[rm] == ' ') rm += 1;
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
        try self.registers.set(self.pending_register, text, false);
        self.pushUndo();
        self.setCursor(self.deleteSpan(span));
    }

    fn changeToLineEnd(self: *Editor, change: bool) !void {
        const line = self.curLine();
        const span: Span = .{ .lines = false, .start = .{ .row = self.cy, .col = self.cx }, .end = .{ .row = self.cy, .col = line.len } };
        const text = try self.extract(span);
        defer self.gpa.free(text);
        try self.registers.set(self.pending_register, text, false);
        self.pushUndo();
        self.setCursor(self.deleteSpan(span));
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
        try self.deleteChars(n, true);
        self.mode = .insert;
    }

    fn replaceChars(self: *Editor, k: key.Key) !void {
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
        const joins = if (count > 1) count - 1 else 1;
        self.pushUndo();
        var i: usize = 0;
        while (i < joins) : (i += 1) {
            if (self.cy + 1 >= self.buf.lineCount()) break;
            const cur_len = self.buf.line(self.cy).len;
            const next = self.gpa.dupe(u8, self.buf.line(self.cy + 1)) catch break;
            defer self.gpa.free(next);
            var start: usize = 0;
            while (start < next.len and (next[start] == ' ' or next[start] == '\t')) start += 1;
            self.buf.removeLineAt(self.cy + 1);
            const need_space = cur_len > 0 and next.len > start;
            self.cx = cur_len;
            if (need_space) {
                self.buf.insertBytes(self.cy, cur_len, " ") catch {};
                self.buf.insertBytes(self.cy, cur_len + 1, next[start..]) catch {};
            } else {
                self.buf.insertBytes(self.cy, cur_len, next[start..]) catch {};
            }
        }
        self.updateGoal();
        self.resetPending();
    }

    fn paste(self: *Editor, after: bool) !void {
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
        self.pushUndo();
        self.setCursor(pos);
        self.mode = .insert;
        self.resetPending();
    }

    fn openLine(self: *Editor, below: bool) !void {
        self.pushUndo();
        const at = if (below) self.cy + 1 else self.cy;
        try self.buf.insertLineAt(at, "");
        self.cy = at;
        self.cx = 0;
        self.goal_col = 0;
        self.mode = .insert;
        self.resetPending();
    }

    fn insertKey(self: *Editor, k: key.Key) !void {
        // While the completion popup is open it claims navigation/accept keys;
        // text edits fall through and then re-filter the list.
        if (self.comp_open and try self.completionIntercept(k)) return;
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
        if (self.comp_open) self.filterCompletions();
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
        switch (k) {
            .escape => {
                self.mode = .normal;
                self.comp_open = false;
                self.sig_open = false;
                if (self.cx > 0) self.cx = unicode.prevBoundary(self.curLine(), self.cx);
                self.updateGoal();
            },
            .enter => {
                try self.buf.splitLine(self.cy, self.cx);
                self.cy += 1;
                self.cx = 0;
                self.goal_col = 0;
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
        switch (k) {
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
                'w' => self.setCursorKeep(motion.wordForward(&self.buf, self.cursor(), false)),
                'W' => self.setCursorKeep(motion.wordForward(&self.buf, self.cursor(), true)),
                'b' => self.setCursorKeep(motion.wordBackward(&self.buf, self.cursor(), false)),
                'e' => self.setCursorKeep(motion.wordEnd(&self.buf, self.cursor(), false)),
                'G' => self.setCursorKeep(.{ .row = self.buf.lineCount() - 1, .col = 0 }),
                'g' => self.setCursorKeep(.{ .row = 0, .col = 0 }),
                '%' => if (motion.matchPair(&self.buf, self.cursor())) |p| self.setCursorKeep(p),
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
                '>' => try self.visualOperator(.indent_right),
                '<' => try self.visualOperator(.indent_left),
                'V' => self.mode = .visual_line,
                'v' => self.mode = .visual,
                ':' => self.enterCmd(.ex),
                else => {},
            },
            .left => self.cx = unicode.prevBoundary(self.curLine(), self.cx),
            .right => {
                const line = self.curLine();
                if (self.cx < line.len) self.cx = unicode.nextBoundary(line, self.cx);
            },
            .up => if (self.cy > 0) {
                self.cy -= 1;
                self.cx = byteAtDisplayCol(self.curLine(), self.goal_col);
            },
            .down => if (self.cy + 1 < self.buf.lineCount()) {
                self.cy += 1;
                self.cx = byteAtDisplayCol(self.curLine(), self.goal_col);
            },
            else => {},
        }
        if (k != .up and k != .down) self.updateGoal();
    }

    fn setCursorKeep(self: *Editor, p: Pos) void {
        self.cy = @min(p.row, self.buf.lineCount() - 1);
        self.cx = p.col;
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
        if (cmpPos(end, start) < 0) {
            const tmp = start;
            start = end;
            end = tmp;
        }
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
        try self.registers.set(self.pending_register, out.items, false);
        self.mode = .normal;
        self.cy = r.top;
        self.cx = byteAtDisplayCol(self.buf.line(r.top), r.left);
        self.updateGoal();
    }

    /// Block insert/append: place a caret at the left/right edge of every row in
    /// the block, then enter multi-cursor insert (typing replicates to all rows).
    fn blockInsert(self: *Editor, at_right: bool) !void {
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
            .left => {
                self.multiMove('h');
                return true;
            },
            .right => {
                self.multiMove('l');
                return true;
            },
            .up => {
                self.multiMove('k');
                return true;
            },
            .down => {
                self.multiMove('j');
                return true;
            },
            .home => {
                self.multiMove('0');
                return true;
            },
            .end => {
                self.multiMove('$');
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
            'w' => motion.wordForward(&self.buf, p, false),
            'W' => motion.wordForward(&self.buf, p, true),
            'b' => motion.wordBackward(&self.buf, p, false),
            'B' => motion.wordBackward(&self.buf, p, true),
            'e' => motion.wordEnd(&self.buf, p, false),
            'E' => motion.wordEnd(&self.buf, p, true),
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
        const c: u8 = switch (k) {
            .left => 'h',
            .right => 'l',
            .up => 'k',
            .down => 'j',
            .home => '0',
            .end => '$',
            else => 0,
        };
        if (c == 0) return;
        self.setCursor(self.movedCaret(self.cursor(), c));
        for (self.extra.items) |*e| e.* = self.movedCaret(e.*, c);
        self.dedupeByLine();
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
        const hit = if (forward)
            search.next(&self.buf, self.cursor(), self.last_search.items)
        else
            search.prev(&self.buf, self.cursor(), self.last_search.items);
        if (hit) |p| {
            self.setCursor(p);
        } else {
            self.setStatus("pattern not found: {s}", .{self.last_search.items});
        }
    }

    /// The term to highlight: the live query while typing a search, otherwise
    /// the last committed search.
    fn activeSearchTerm(self: *Editor) []const u8 {
        if (self.mode == .command and self.searching()) return self.cmd.items;
        return self.last_search.items;
    }

    fn repeatSearch(self: *Editor, same_dir: bool) void {
        const fwd = if (same_dir) self.last_search_forward else !self.last_search_forward;
        self.jumpSearch(fwd);
        self.resetPending();
    }

    fn searchWord(self: *Editor, forward: bool) void {
        const word = search.wordUnder(&self.buf, self.cursor());
        if (word.len == 0) {
            self.resetPending();
            return;
        }
        self.runSearch(word, forward);
        self.resetPending();
    }

    // === picker (file finder / global search) ==============================

    fn openFilePicker(self: *Editor) void {
        self.freePicker();
        self.picker_kind = .files;
        self.picker_sel = 0;
        self.picker_scroll = 0;
        self.walkInto(.files);
        self.refilter();
        self.mode = .picker;
    }

    fn openGrepPicker(self: *Editor) void {
        self.freePicker();
        self.picker_kind = .grep;
        self.picker_sel = 0;
        self.picker_scroll = 0;
        self.walkInto(.grep);
        self.mode = .picker;
        self.refilter();
    }

    fn freePicker(self: *Editor) void {
        for (self.picker_items.items) |it| {
            self.gpa.free(it.display);
            self.gpa.free(it.path);
        }
        self.picker_items.clearRetainingCapacity();
        for (self.picker_files.items) |f| self.gpa.free(f);
        self.picker_files.clearRetainingCapacity();
        self.picker_filtered.clearRetainingCapacity();
        self.picker_query.clearRetainingCapacity();
    }

    fn closePicker(self: *Editor) void {
        self.freePicker();
        self.mode = .normal;
    }

    /// Collect candidate files under the cwd, skipping build/VCS directories.
    fn walkInto(self: *Editor, kind: PickerKind) void {
        var dir = std.Io.Dir.cwd().openDir(self.io, ".", .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var w = dir.walkSelectively(self.gpa) catch return;
        defer w.deinit();
        while (true) {
            const maybe = w.next(self.io) catch break;
            const entry = maybe orelse break;
            if (entry.kind == .directory) {
                if (!ignoredDir(entry.basename)) w.enter(self.io, entry) catch {};
                continue;
            }
            if (entry.kind != .file) continue;
            const count = if (kind == .files) self.picker_items.items.len else self.picker_files.items.len;
            if (count >= 5000) break;
            const p = self.gpa.dupe(u8, entry.path) catch continue;
            if (kind == .files) {
                const disp = self.gpa.dupe(u8, entry.path) catch {
                    self.gpa.free(p);
                    continue;
                };
                self.picker_items.append(self.gpa, .{ .display = disp, .path = p, .line = 0 }) catch {
                    self.gpa.free(p);
                    self.gpa.free(disp);
                };
            } else {
                self.picker_files.append(self.gpa, p) catch self.gpa.free(p);
            }
        }
    }

    fn onQueryChange(self: *Editor) void {
        self.picker_sel = 0;
        self.picker_scroll = 0;
        self.refilter();
    }

    fn refilter(self: *Editor) void {
        self.picker_filtered.clearRetainingCapacity();
        if (self.picker_kind == .grep) {
            self.regrep();
            var i: usize = 0;
            while (i < self.picker_items.items.len) : (i += 1) self.picker_filtered.append(self.gpa, i) catch {};
            self.clampSel();
            return;
        }
        const q = self.picker_query.items;
        if (q.len == 0) {
            var i: usize = 0;
            while (i < self.picker_items.items.len) : (i += 1) self.picker_filtered.append(self.gpa, i) catch {};
        } else {
            var scored: std.ArrayList(Scored) = .empty;
            defer scored.deinit(self.gpa);
            for (self.picker_items.items, 0..) |it, i| {
                if (fuzzy.score(it.path, q)) |s| scored.append(self.gpa, .{ .idx = i, .score = s }) catch {};
            }
            std.mem.sort(Scored, scored.items, {}, scoredLess);
            for (scored.items) |s| self.picker_filtered.append(self.gpa, s.idx) catch {};
        }
        self.clampSel();
    }

    fn regrep(self: *Editor) void {
        for (self.picker_items.items) |it| {
            self.gpa.free(it.display);
            self.gpa.free(it.path);
        }
        self.picker_items.clearRetainingCapacity();
        const q = self.picker_query.items;
        if (q.len == 0) return;
        for (self.picker_files.items) |fpath| {
            if (self.picker_items.items.len >= 500) break;
            const data = std.Io.Dir.cwd().readFileAlloc(self.io, fpath, self.gpa, .limited(1 << 20)) catch continue;
            defer self.gpa.free(data);
            var line_no: usize = 1;
            var it = std.mem.splitScalar(u8, data, '\n');
            while (it.next()) |ln| : (line_no += 1) {
                if (self.picker_items.items.len >= 500) break;
                if (std.mem.indexOf(u8, ln, q) == null) continue;
                var s = ln;
                while (s.len > 0 and (s[0] == ' ' or s[0] == '\t')) s = s[1..];
                const text = s[0..@min(s.len, 120)];
                const disp = std.fmt.allocPrint(self.gpa, "{s}:{d}: {s}", .{ fpath, line_no, text }) catch continue;
                const pp = self.gpa.dupe(u8, fpath) catch {
                    self.gpa.free(disp);
                    continue;
                };
                self.picker_items.append(self.gpa, .{ .display = disp, .path = pp, .line = line_no }) catch {
                    self.gpa.free(disp);
                    self.gpa.free(pp);
                };
            }
        }
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
            .ctrl => |c| switch (c) {
                'p' => self.selDelta(false),
                'n' => self.selDelta(true),
                'c' => self.closePicker(),
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
        const path = self.gpa.dupe(u8, it.path) catch return;
        defer self.gpa.free(path);
        const line = if (it.line > 0) it.line - 1 else 0;
        self.closePicker();
        self.openFile(path, line);
    }

    fn openFile(self: *Editor, path: []const u8, line: usize) void {
        if (self.buf.dirty) {
            self.setStatus("unsaved changes — :w before opening another file", .{});
            return;
        }
        const nb = buffer.Buffer.load(self.gpa, self.io, path) catch {
            self.setStatus("cannot open {s}", .{path});
            return;
        };
        self.buf.deinit();
        self.buf = nb;
        self.lang = syntax.detect(self.buf.path);
        if (self.ts) |*t| t.deinit();
        self.startTs();
        self.history.deinit();
        self.history = undo.History.init(self.gpa);
        self.clearExtra();
        self.cy = @min(line, self.buf.lineCount() - 1);
        self.cx = 0;
        self.top = 0;
        self.left = 0;
        self.goal_col = 0;
        self.refreshGit();
        self.setStatus("opened {s}", .{self.buf.path orelse ""});
    }

    fn renderPickerBody(self: *Editor) !void {
        const th = theme.current;
        const cols: usize = self.win.cols;
        const rows: usize = self.win.rows;
        const visible = if (rows > 1) rows - 1 else 1;

        if (self.picker_sel < self.picker_scroll) self.picker_scroll = self.picker_sel;
        if (self.picker_sel >= self.picker_scroll + visible) self.picker_scroll = self.picker_sel - visible + 1;

        // Prompt line.
        const klabel = if (self.picker_kind == .files) " FILES " else " SEARCH ";
        try self.setBg(th.mode_command);
        try self.setFg(th.bg);
        try self.emit(klabel);
        try self.setBg(th.bg);
        try self.setFg(th.fg);
        try self.emit(" ");
        try self.emit(self.picker_query.items);
        try self.emit(ansi.clear_line_right);
        try self.emit("\r\n");

        // Results.
        var shown: usize = 0;
        while (shown < visible) : (shown += 1) {
            const fi = self.picker_scroll + shown;
            const selected = fi == self.picker_sel and fi < self.picker_filtered.items.len;
            try self.setBg(if (selected) th.cursorline else th.bg);
            if (fi < self.picker_filtered.items.len) {
                const it = self.picker_items.items[self.picker_filtered.items[fi]];
                try self.setFg(if (selected) th.mode_normal else th.fg_dim);
                try self.emit(if (selected) "\u{25B6} " else "  ");
                try self.setFg(if (selected) th.fg else th.fg_dim);
                const maxw = if (cols > 2) cols - 2 else 0;
                try self.emit(it.display[0..@min(it.display.len, maxw)]);
            }
            try self.setBg(if (selected) th.cursorline else th.bg);
            try self.emit(ansi.clear_line_right);
            if (shown + 1 < visible) try self.emit("\r\n");
        }

        const promptw = klabel.len + 1;
        try self.emitFmt("\x1b[{d};{d}H", .{ 1, promptw + unicode.displayWidth(self.picker_query.items) + 1 });
        try self.emit(ansi.show_cursor);
    }

    // === command line ======================================================

    fn enterCmd(self: *Editor, kind: CmdKind) void {
        self.mode = .command;
        self.cmd_kind = kind;
        self.cmd.clearRetainingCapacity();
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

    fn commandKey(self: *Editor, k: key.Key) !void {
        switch (k) {
            .escape => {
                if (self.searching()) {
                    // Cancel: restore the previous pattern and the original cursor.
                    self.last_search.clearRetainingCapacity();
                    self.last_search.appendSlice(self.gpa, self.prev_search.items) catch {};
                    self.setCursor(self.search_origin);
                }
                self.mode = .normal;
            },
            .enter => {
                const kind = self.cmd_kind;
                self.mode = .normal;
                switch (kind) {
                    .ex => try self.execEx(),
                    // Search was already applied incrementally; nothing to do.
                    .search_forward, .search_backward => {},
                }
            },
            .backspace => {
                if (self.cmd.items.len == 0) {
                    try self.commandKey(.escape);
                } else {
                    self.cmd.items.len = unicode.prevBoundary(self.cmd.items, self.cmd.items.len);
                    if (self.searching()) self.searchLive();
                }
            },
            .char => |c| {
                var enc: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &enc) catch return;
                try self.cmd.appendSlice(self.gpa, enc[0..len]);
                if (self.searching()) self.searchLive();
            },
            else => {},
        }
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

        // :<number> jumps to a line.
        if (raw[0] >= '0' and raw[0] <= '9') {
            const ln = std.fmt.parseInt(usize, raw, 10) catch return;
            self.cy = if (ln == 0) 0 else @min(ln - 1, self.buf.lineCount() - 1);
            self.cx = motion.firstNonBlank(self.curLine());
            self.updateGoal();
            return;
        }
        if (eql(raw, "$")) {
            self.cy = self.buf.lineCount() - 1;
            self.cx = motion.firstNonBlank(self.curLine());
            return;
        }

        var it = std.mem.tokenizeScalar(u8, raw, ' ');
        const cmd = it.next() orelse return;
        const arg = std.mem.trim(u8, raw[cmd.len..], " ");

        if (eql(cmd, "w")) {
            _ = try self.write(arg);
        } else if (eql(cmd, "q")) {
            self.doQuit();
        } else if (eql(cmd, "q!")) {
            self.quit = true;
        } else if (eql(cmd, "wq") or eql(cmd, "x")) {
            if (try self.write(arg)) self.quit = true;
        } else {
            self.setStatus("unknown command: {s}", .{cmd});
        }
    }

    fn cmdArgNone(_: *Editor) []const u8 {
        return "";
    }

    fn write(self: *Editor, arg: []const u8) !bool {
        if (arg.len > 0) try self.buf.setPath(arg);
        self.buf.save(self.io) catch |err| switch (err) {
            error.NoFileName => {
                self.setStatus("no file name — use :w <name>", .{});
                return false;
            },
            else => {
                self.setStatus("write failed: {s}", .{@errorName(err)});
                std.log.scoped(.editor).err("write failed: {s}", .{@errorName(err)});
                return false;
            },
        };
        self.setStatus("\"{s}\" written", .{self.buf.path orelse ""});
        self.refreshGit();
        return true;
    }

    fn doQuit(self: *Editor) void {
        if (self.buf.dirty) {
            self.setStatus("unsaved changes — :w to save or :q! to discard", .{});
            return;
        }
        self.quit = true;
    }

    // === undo / macros / dot ===============================================

    fn pushUndo(self: *Editor) void {
        self.history.record(&self.buf, self.cy, self.cx);
        self.change_started = true;
    }

    /// Recompute the git change signs for the current file (best-effort).
    fn refreshGit(self: *Editor) void {
        if (self.buf.path) |p| {
            git.compute(self.gpa, self.io, p, &self.git_signs);
        } else {
            self.git_signs.clearRetainingCapacity();
        }
    }

    // === tree-sitter highlighting ==========================================

    fn startTs(self: *Editor) void {
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
        for (self.buf.lines.items) |ln| {
            self.ts_line_starts.append(self.gpa, off) catch {};
            off += ln.items.len + 1; // + newline
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
        if (self.lsp != null) {
            self.lsp_rev = self.buf.revision;
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

    fn lspCompletion(self: *Editor) void {
        if (self.lsp) |*c| c.requestCompletion(self.cy, self.charCol());
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

    /// Rebuild the visible completion list from the prefix under the cursor;
    /// closes the popup if nothing matches.
    fn filterCompletions(self: *Editor) void {
        self.comp_filtered.clearRetainingCapacity();
        const client = if (self.lsp) |*c| c else {
            self.comp_open = false;
            return;
        };
        const prefix = self.completionPrefix();
        for (client.completions.items, 0..) |it, i| {
            if (prefix.len == 0 or startsWithCI(it.label, prefix)) self.comp_filtered.append(self.gpa, i) catch {};
        }
        if (self.comp_filtered.items.len == 0) {
            self.comp_open = false;
        } else if (self.comp_sel >= self.comp_filtered.items.len) {
            self.comp_sel = self.comp_filtered.items.len - 1;
        }
    }

    /// Replace the prefix under the cursor with the selected completion.
    fn acceptCompletion(self: *Editor) void {
        defer self.comp_open = false;
        const client = if (self.lsp) |*c| c else return;
        if (self.comp_sel >= self.comp_filtered.items.len) return;
        const item = client.completions.items[self.comp_filtered.items[self.comp_sel]];
        const start = self.cx - self.completionPrefix().len;
        self.buf.deleteInLine(self.cy, start, self.cx) catch {};
        self.buf.insertBytes(self.cy, start, item.insert) catch {};
        self.cx = start + item.insert.len;
        self.updateGoal();
    }

    fn undoChange(self: *Editor) void {
        if (!self.history.undo(&self.buf, &self.cy, &self.cx)) self.setStatus("already at oldest change", .{});
        self.clampCursor();
        self.updateGoal();
        self.resetPending();
    }

    fn redoChange(self: *Editor) void {
        if (!self.history.redo(&self.buf, &self.cy, &self.cx)) self.setStatus("already at newest change", .{});
        self.clampCursor();
        self.updateGoal();
        self.resetPending();
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

    fn pageMove(self: *Editor, up: bool) void {
        const delta = self.textRows();
        if (up) {
            self.cy = if (self.cy > delta) self.cy - delta else 0;
        } else {
            self.cy = @min(self.cy + delta, self.buf.lineCount() - 1);
        }
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

    fn clampCursor(self: *Editor) void {
        if (self.cy >= self.buf.lineCount()) self.cy = self.buf.lineCount() - 1;
        const line = self.curLine();
        if (self.cx > line.len) self.cx = line.len;
    }

    // === viewport ==========================================================

    fn textRows(self: *Editor) usize {
        const rows: usize = self.win.rows;
        return if (rows > 1) rows - 1 else 1;
    }

    fn textCols(self: *Editor) usize {
        const cols: usize = self.win.cols;
        const g = self.gutterWidth();
        return if (cols > g) cols - g else 1;
    }

    fn gutterWidth(self: *Editor) usize {
        var n = self.buf.lineCount();
        var digits: usize = 1;
        while (n >= 10) : (n = n / 10) digits += 1;
        return @max(digits, 3) + 2; // git sign column + numbers + trailing space
    }

    fn scroll(self: *Editor) void {
        const rows = self.textRows();
        if (self.cy < self.top) self.top = self.cy;
        if (self.cy >= self.top + rows) self.top = self.cy - rows + 1;

        const cols = self.textCols();
        const cur = displayCol(self.curLine(), self.cx);
        if (cur < self.left) self.left = cur;
        if (cur >= self.left + cols) self.left = cur - cols + 1;
    }

    // === rendering =========================================================

    fn render(self: *Editor) !void {
        var sp = log.Span.start();
        const th = theme.current;
        self.tsUpdate();
        self.frame.clearRetainingCapacity();
        self.cur_fg = null;
        self.cur_bg = null;
        try self.emit(ansi.hide_cursor);
        try self.emit(ansi.cursor_home);
        try self.emit(ansi.reset_attrs);

        if (self.mode == .picker) {
            try self.renderPickerBody();
            try self.term.write(self.frame.items);
            sp.lap("render");
            return;
        }

        const rows = self.textRows();
        const gutter = self.gutterWidth();
        const cols = self.textCols();

        var r: usize = 0;
        while (r < rows) : (r += 1) {
            const file_row = self.top + r;
            const is_cur = file_row == self.cy;
            const row_bg = if (is_cur) th.cursorline else th.bg;
            try self.setBg(row_bg);
            if (file_row < self.buf.lineCount()) {
                try self.emitGutter(file_row, gutter, is_cur);
                try self.emitLine(file_row, self.buf.line(file_row), cols, row_bg);
            } else {
                try self.setFg(th.fg_dim);
                try self.emit("~");
            }
            try self.setBg(row_bg);
            try self.emit(ansi.clear_line_right);
            try self.emit("\r\n");
        }

        try self.renderStatus();
        if (self.await_arg == .space_leader) try self.renderWhichKey();
        if (self.sig_open) try self.renderSignature(gutter);
        if (self.comp_open) try self.renderCompletion(gutter);
        try self.emit(ansi.reset_attrs);
        try self.placeCursor(gutter);
        try self.emit(ansi.show_cursor);
        try self.term.write(self.frame.items);
        sp.lap("render");
    }

    const WhichKey = struct { key: []const u8, desc: []const u8 };
    const leader_keys = [_]WhichKey{
        .{ .key = "f", .desc = "find file" },
        .{ .key = "s", .desc = "search in files" },
        .{ .key = "/", .desc = "search in files" },
        .{ .key = "w", .desc = "write (save)" },
        .{ .key = "q", .desc = "quit" },
    };

    /// Draw the which-key popup for the Space leader, anchored above the status bar.
    fn renderWhichKey(self: *Editor) !void {
        const th = theme.current;
        const width: usize = 26;
        const rows: usize = self.win.rows;
        const height = leader_keys.len + 1;
        if (rows < height + 2) return;
        const top = rows - height - 1; // 1-based; leave the status bar at the bottom

        var b: [16]u8 = undefined;
        try self.emit(try std.fmt.bufPrint(&b, "\x1b[{d};1H", .{top}));
        try self.setBg(th.mode_command);
        try self.setFg(th.bg);
        try self.emit(" SPACE");
        try self.emitSpaces(width - 6);

        for (leader_keys, 0..) |it, i| {
            try self.emit(try std.fmt.bufPrint(&b, "\x1b[{d};1H", .{top + 1 + i}));
            try self.setBg(th.status_seg_bg);
            try self.setFg(th.mode_normal);
            try self.emitFmt("  {s}  ", .{it.key});
            try self.setFg(th.status_seg_fg);
            try self.emit(it.desc);
            const used = 2 + it.key.len + 2 + it.desc.len;
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

        const cur_row = (self.cy - self.top) + 1; // 1-based screen row of cursor
        const row = if (cur_row > 1) cur_row - 1 else cur_row + 1;
        const cur_col = gutter + (displayCol(self.curLine(), self.cx) - self.left) + 1;
        const col = @max(@as(usize, 1), cur_col);
        if (col > self.win.cols) return;
        const avail = self.win.cols - col + 1; // cells from `col` to the screen edge

        var b: [16]u8 = undefined;
        try self.emit(try std.fmt.bufPrint(&b, "\x1b[{d};{d}H", .{ row, col }));
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
            try self.emit(label[i .. i + d.len]);
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

        const cur_row = (self.cy - self.top) + 1; // 1-based screen row of cursor
        const cur_col = gutter + (displayCol(self.curLine(), self.cx) - self.left) + 1;
        // Below the cursor if it fits, else above.
        const start_row = if (cur_row + height < rows) cur_row + 1 else (if (cur_row > height) cur_row - height else 1);
        const col = @max(@as(usize, 1), cur_col);

        var b: [16]u8 = undefined;
        var i: usize = 0;
        while (i < height) : (i += 1) {
            const idx = first + i;
            const selected = idx == self.comp_sel;
            try self.emit(try std.fmt.bufPrint(&b, "\x1b[{d};{d}H", .{ start_row + i, col }));
            try self.setBg(if (selected) th.selection else th.status_seg_bg);
            try self.setFg(if (selected) th.fg else th.status_seg_fg);
            const label = client.completions.items[items[idx]].label;
            try self.emit(" ");
            const shown = @min(label.len, width - 1);
            try self.emit(label[0..shown]);
            if (shown + 1 < width) try self.emitSpaces(width - shown - 1);
        }
    }

    fn emitGutter(self: *Editor, file_row: usize, gutter: usize, is_cur: bool) !void {
        const th = theme.current;
        const ndigits = gutter - 2;

        // Leftmost column: an LSP diagnostic sign takes priority over a git sign.
        var sign_drawn = false;
        if (self.lsp) |*c| {
            if (c.severityAt(file_row)) |sev| {
                try self.setFg(if (sev == 1) th.git_delete else th.git_change); // error=red, warn=yellow
                try self.emit("\u{25CF}"); // ●
                sign_drawn = true;
            }
        }
        if (!sign_drawn) {
            if (self.git_signs.get(file_row)) |s| {
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

        // Absolute number on the current line, relative distance elsewhere.
        const num = if (is_cur) file_row + 1 else if (file_row > self.cy) file_row - self.cy else self.cy - file_row;
        var nb: [20]u8 = undefined;
        const ns = std.fmt.bufPrint(&nb, "{d}", .{num}) catch unreachable;
        try self.setFg(if (is_cur) th.gutter_active else th.gutter);
        try self.emitSpaces(ndigits - ns.len);
        try self.emit(ns);
        try self.emit(" ");
    }

    fn emitLine(self: *Editor, row: usize, line: []const u8, cols: usize, row_bg: Color) !void {
        const th = theme.current;
        self.style_buf.resize(self.gpa, line.len) catch {};
        if (self.style_buf.items.len == line.len) {
            if (self.ts != null and row < self.ts_line_starts.items.len) {
                // Tree-sitter: read this line's styles out of the visible-range
                // buffer, which starts at document byte `ts_vis_start`.
                const lstart = self.ts_line_starts.items[row];
                for (self.style_buf.items, 0..) |*s, i| {
                    const abs = lstart + i;
                    s.* = if (abs >= self.ts_vis_start and abs - self.ts_vis_start < self.ts_styles.items.len)
                        self.ts_styles.items[abs - self.ts_vis_start]
                    else
                        .normal;
                }
            } else {
                syntax.highlight(self.lang, line, self.style_buf.items);
            }
        }

        const sel = self.selectionRange(row);
        const ecol = self.extraColAt(row);
        const first_nb = motion.firstNonBlank(line);
        const indent_cols = displayCol(line, first_nb);

        // Search-match ranges on this line (for highlighting).
        var mstarts: [64]usize = undefined;
        var mcount: usize = 0;
        const needle = self.activeSearchTerm();
        if (needle.len > 0) {
            var off: usize = 0;
            while (mcount < mstarts.len) {
                const idx = std.mem.indexOfPos(u8, line, off, needle) orelse break;
                mstarts[mcount] = idx;
                mcount += 1;
                off = idx + needle.len;
            }
        }
        var mi: usize = 0;

        const left = self.left;
        const right = left + cols;
        var dc: usize = 0;
        var i: usize = 0;
        while (i < line.len) {
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
            while (mi < mcount and byte >= mstarts[mi] + needle.len) mi += 1;
            const in_match = mi < mcount and byte >= mstarts[mi] and byte < mstarts[mi] + needle.len;
            try self.setBg(if (is_extra) th.mode_normal else if (selected) th.selection else if (in_match) th.match else row_bg);

            if (d.cp == '\t' or d.cp == ' ' or start < left or start + w > right) {
                var c = if (start < left) left else start;
                while (c < start + w and c < right) : (c += 1) {
                    if (byte < first_nb and c % tab_width == 0 and c < indent_cols) {
                        try self.setFg(th.indent_guide);
                        try self.emit(indent_glyph);
                    } else {
                        try self.emit(" ");
                    }
                }
            } else {
                const stl = if (byte < self.style_buf.items.len) self.style_buf.items[byte] else .normal;
                try self.setFg(if (is_extra) th.bg else if (in_match) th.fg else self.styleColor(stl));
                try self.emit(bytes);
            }
        }
        // A secondary cursor sitting at end-of-line has no char to invert.
        if (ecol) |ec| {
            if (ec == line.len) {
                const eol = displayCol(line, line.len);
                if (eol >= left and eol < right) {
                    try self.setBg(th.mode_normal);
                    try self.emit(" ");
                }
            }
        }
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
            .char_ => th.char_,
            .number => th.number,
            .operator => th.operator,
            .preproc => th.preproc,
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
            const prompt: []const u8 = switch (self.cmd_kind) {
                .ex => ":",
                .search_forward => "/",
                .search_backward => "?",
            };
            try self.emit(prompt);
            const shown = @min(self.cmd.items.len, if (cols > 0) cols - 1 else 0);
            try self.emit(self.cmd.items[0..shown]);
            try self.emitSpaces(cols - 1 - shown);
            return;
        }

        const accent = self.modeColor();
        const label = self.mode.label();

        // Left: [ MODE ] file
        try self.setBg(accent);
        try self.setFg(th.bg);
        try self.emitFmt(" {s} ", .{label});
        try self.setBg(th.status_seg_bg);
        try self.setFg(accent);
        try self.emit(sep_right);

        var fb: [320]u8 = undefined;
        const fname = self.buf.path orelse "[No Name]";
        const dirty = if (self.buf.dirty) " \u{25CF}" else "";
        const fileseg = std.fmt.bufPrint(&fb, " {s}{s} ", .{ fname, dirty }) catch " ";
        try self.setBg(th.status_seg_bg);
        try self.setFg(th.status_seg_fg);
        try self.emit(fileseg);
        try self.setBg(th.status_bg);
        try self.setFg(th.status_seg_bg);
        try self.emit(sep_right);

        const left_w = (label.len + 2) + 1 + unicode.displayWidth(fileseg) + 1;

        // Right: filetype + position | percentage
        var rb: [96]u8 = undefined;
        const rseg = std.fmt.bufPrint(&rb, " {s}  Ln {d}, Col {d} ", .{
            langName(self.lang), self.cy + 1, displayCol(self.curLine(), self.cx) + 1,
        }) catch " ";
        var pb: [16]u8 = undefined;
        const lines = self.buf.lineCount();
        const pct: usize = if (lines <= 1) 100 else (self.cy * 100) / (lines - 1);
        const pctseg = std.fmt.bufPrint(&pb, " {d}% ", .{pct}) catch " ";
        const right_w = 1 + rseg.len + 1 + pctseg.len;

        // Middle: status message, else the in-progress command (showcmd).
        var mb: [256]u8 = undefined;
        const middle = if (self.status.items.len > 0)
            self.status.items
        else if (self.lspMiddle(&mb)) |m|
            m
        else if (self.extra.items.len > 0)
            (std.fmt.bufPrint(&mb, "{d} cursors", .{self.extra.items.len + 1}) catch "")
        else
            self.pendingKeys(&mb);
        const mid_w = if (cols > left_w + right_w) cols - left_w - right_w else 0;
        try self.setBg(th.status_bg);
        try self.setFg(th.fg_dim);
        const mshow = @min(middle.len, mid_w);
        try self.emit(middle[0..mshow]);
        try self.emitSpaces(mid_w - mshow);

        try self.setBg(th.status_bg);
        try self.setFg(th.status_seg_bg);
        try self.emit(sep_left);
        try self.setBg(th.status_seg_bg);
        try self.setFg(th.status_seg_fg);
        try self.emit(rseg);
        try self.setBg(th.status_seg_bg);
        try self.setFg(accent);
        try self.emit(sep_left);
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

    fn pendingKeys(self: *Editor, buf: []u8) []const u8 {
        var i: usize = 0;
        if (self.recording) |reg| i += (std.fmt.bufPrint(buf[i..], "REC @{c}  ", .{reg}) catch return buf[0..i]).len;
        if (self.pending_register) |reg| i += (std.fmt.bufPrint(buf[i..], "\"{c}", .{reg}) catch return buf[0..i]).len;
        if (self.count > 0) i += (std.fmt.bufPrint(buf[i..], "{d}", .{self.count}) catch return buf[0..i]).len;
        const opc: ?u8 = switch (self.operator) {
            .delete => 'd',
            .change => 'c',
            .yank => 'y',
            .indent_right => '>',
            .indent_left => '<',
            .comment => 'g',
            .surround => 's',
            .none => null,
        };
        if (opc) |c| {
            if (i < buf.len) {
                buf[i] = c;
                i += 1;
            }
        }
        if (self.count2 > 0) i += (std.fmt.bufPrint(buf[i..], "{d}", .{self.count2}) catch return buf[0..i]).len;
        return buf[0..i];
    }

    fn placeCursor(self: *Editor, gutter: usize) !void {
        var row: usize = undefined;
        var col: usize = undefined;
        if (self.mode == .command) {
            row = self.win.rows;
            col = 2 + unicode.displayWidth(self.cmd.items);
        } else {
            row = (self.cy - self.top) + 1;
            const cur = displayCol(self.curLine(), self.cx);
            col = gutter + (cur - self.left) + 1;
        }
        try self.emitFmt("\x1b[{d};{d}H", .{ row, col });
    }

    fn emit(self: *Editor, bytes: []const u8) !void {
        try self.frame.appendSlice(self.gpa, bytes);
    }

    fn emitFmt(self: *Editor, comptime fmt: []const u8, args: anytype) !void {
        var b: [64]u8 = undefined;
        try self.emit(try std.fmt.bufPrint(&b, fmt, args));
    }

    fn emitSpaces(self: *Editor, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) try self.frame.append(self.gpa, ' ');
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

fn startsWithCI(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len > haystack.len) return false;
    for (prefix, 0..) |c, i| {
        if (lowerAscii(haystack[i]) != lowerAscii(c)) return false;
    }
    return true;
}

fn lowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c - 'A' + 'a' else c;
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

const Scored = struct { idx: usize, score: i32 };

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
    if (cp == '\t') return tab_width - (col % tab_width);
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

test "displayCol expands tabs" {
    try std.testing.expectEqual(@as(usize, tab_width), displayCol("\tx", 1));
    try std.testing.expectEqual(@as(usize, 2), displayCol("ab", 2));
    try std.testing.expectEqual(@as(usize, 2), displayCol("世", 3));
}

test "byteAtDisplayCol round-trips with displayCol" {
    const line = "a\tbc";
    const off = byteAtDisplayCol(line, tab_width);
    try std.testing.expectEqual(@as(usize, 2), off);
    try std.testing.expectEqual(@as(usize, tab_width), displayCol(line, off));
}

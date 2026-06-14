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
const ansi = term.ansi;
const Allocator = std.mem.Allocator;
const Pos = buffer.Pos;

/// Spaces a tab advances to. Tabs are stored verbatim and expanded on render.
const tab_width = 4;

pub const Mode = enum {
    normal,
    insert,
    visual,
    visual_line,
    command,

    fn label(self: Mode) []const u8 {
        return switch (self) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .visual => "VISUAL",
            .visual_line => "V-LINE",
            .command => "COMMAND",
        };
    }
};

const Operator = enum { none, delete, change, yank, indent_right, indent_left };

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

    // search
    last_search: std.ArrayList(u8),
    last_search_forward: bool,

    // command/search line
    cmd: std.ArrayList(u8),
    cmd_kind: CmdKind,

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
    quit: bool,
    inbuf: [256]u8,

    pub fn init(gpa: Allocator, io: std.Io, t: *term.Terminal, buf: buffer.Buffer) Editor {
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
            .last_search = .empty,
            .last_search_forward = true,
            .cmd = .empty,
            .cmd_kind = .ex,
            .recording = null,
            .macro_buf = .empty,
            .replay_depth = 0,
            .dot_keys = .empty,
            .dot_temp = .empty,
            .change_started = false,
            .in_dot = false,
            .frame = .empty,
            .status = .empty,
            .quit = false,
            .inbuf = undefined,
        };
    }

    pub fn deinit(self: *Editor) void {
        self.registers.deinit();
        self.history.deinit();
        self.last_search.deinit(self.gpa);
        self.cmd.deinit(self.gpa);
        self.macro_buf.deinit(self.gpa);
        self.dot_keys.deinit(self.gpa);
        self.dot_temp.deinit(self.gpa);
        self.frame.deinit(self.gpa);
        self.status.deinit(self.gpa);
        self.buf.deinit();
    }

    pub fn run(self: *Editor) !void {
        try self.term.enableRaw();
        self.term.installResizeHandler();
        try self.term.enterAltScreen();
        self.win = self.term.size();
        self.setStatus("zed {s} — :q to quit, i to insert", .{@import("cli.zig").version});

        var needs_render = true;
        while (!self.quit) {
            if (needs_render) {
                self.scroll();
                try self.render();
                needs_render = false;
            }
            const ready = try self.term.waitForInput();
            if (self.term.takeResize()) {
                self.win = self.term.size();
                needs_render = true;
                continue;
            }
            if (!ready) continue;
            const chunk = try self.readInput();
            if (chunk.len == 0) continue;
            try self.processInput(chunk);
            needs_render = true;
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
            .normal, .insert, .visual, .visual_line => self.dot_temp.appendSlice(self.gpa, raw) catch {},
            .command => {},
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
            .visual, .visual_line => try self.visualKey(k),
            .command => try self.commandKey(k),
        }
        self.clampCursor();
    }

    // === normal mode =======================================================

    fn normalKey(self: *Editor, k: key.Key) !void {
        if (self.await_arg != .none) return self.awaitKey(k);
        if (self.operator != .none) return self.operatorPendingKey(k);

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
            'l', ' ' => self.doMotion(self.repeatMotion(.right)),
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
                else
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
        defer self.resetPending();
        const c = charByte(k) orelse return;
        const span = self.textObjectSpan(around, c) orelse return;
        self.applyOperator(op, span);
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
        if (self.moveKey(k)) return;
        switch (k) {
            .escape => {
                self.mode = .normal;
                if (self.cx > 0) self.cx = unicode.prevBoundary(self.curLine(), self.cx);
                self.updateGoal();
            },
            .enter => {
                try self.buf.splitLine(self.cy, self.cx);
                self.cy += 1;
                self.cx = 0;
                self.goal_col = 0;
            },
            .backspace => {
                const p = try self.buf.deleteBackward(self.cy, self.cx);
                self.cy = p.row;
                self.cx = p.col;
                self.updateGoal();
            },
            .delete => try self.buf.deleteForward(self.cy, self.cx),
            .tab => {
                self.cx = try self.buf.insertCodepoint(self.cy, self.cx, '\t');
                self.updateGoal();
            },
            .char => |c| {
                self.cx = try self.buf.insertCodepoint(self.cy, self.cx, c);
                self.updateGoal();
            },
            else => {},
        }
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
                'd', 'x' => try self.visualOperator(.delete),
                'y' => try self.visualOperator(.yank),
                'c', 's' => try self.visualOperator(.change),
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

    // === command line ======================================================

    fn enterCmd(self: *Editor, kind: CmdKind) void {
        self.mode = .command;
        self.cmd_kind = kind;
        self.cmd.clearRetainingCapacity();
        self.resetPending();
    }

    fn commandKey(self: *Editor, k: key.Key) !void {
        switch (k) {
            .escape => self.mode = .normal,
            .enter => {
                const kind = self.cmd_kind;
                self.mode = .normal;
                switch (kind) {
                    .ex => try self.execEx(),
                    .search_forward => self.runSearch(self.cmd.items, true),
                    .search_backward => self.runSearch(self.cmd.items, false),
                }
            },
            .backspace => {
                if (self.cmd.items.len == 0) {
                    self.mode = .normal;
                } else {
                    self.cmd.items.len = unicode.prevBoundary(self.cmd.items, self.cmd.items.len);
                }
            },
            .char => |c| {
                var enc: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &enc) catch return;
                try self.cmd.appendSlice(self.gpa, enc[0..len]);
            },
            else => {},
        }
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
        return @max(digits, 3) + 1;
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
        self.frame.clearRetainingCapacity();
        try self.emit(ansi.hide_cursor);
        try self.emit(ansi.cursor_home);

        const rows = self.textRows();
        const gutter = self.gutterWidth();
        const cols = self.textCols();

        var r: usize = 0;
        while (r < rows) : (r += 1) {
            const file_row = self.top + r;
            if (file_row < self.buf.lineCount()) {
                try self.emitGutter(file_row + 1, gutter);
                try self.emitLine(file_row, self.buf.line(file_row), cols);
            } else {
                try self.emit(ansi.dim);
                try self.emit("~");
                try self.emit(ansi.reset_attrs);
            }
            try self.emit(ansi.clear_line_right);
            try self.emit("\r\n");
        }

        try self.renderStatus();
        try self.placeCursor(gutter);
        try self.emit(ansi.show_cursor);
        try self.term.write(self.frame.items);
        sp.lap("render");
    }

    fn emitGutter(self: *Editor, num: usize, gutter: usize) !void {
        var nb: [20]u8 = undefined;
        const ns = std.fmt.bufPrint(&nb, "{d}", .{num}) catch unreachable;
        try self.emit(ansi.dim);
        try self.emitSpaces(gutter - 1 - ns.len);
        try self.emit(ns);
        try self.emit(ansi.reset_attrs);
        try self.emit(" ");
    }

    fn emitLine(self: *Editor, row: usize, line: []const u8, cols: usize) !void {
        const sel = self.selectionRange(row);
        const left = self.left;
        const right = left + cols;
        var dc: usize = 0;
        var i: usize = 0;
        var in_sel = false;
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

            const want_sel = if (sel) |s| (byte >= s.lo and byte < s.hi) else false;
            if (want_sel and !in_sel) {
                try self.emit(ansi.reverse_video);
                in_sel = true;
            } else if (!want_sel and in_sel) {
                try self.emit(ansi.reset_attrs);
                in_sel = false;
            }

            if (d.cp == '\t' or start < left or start + w > right) {
                var c = if (start < left) left else start;
                while (c < start + w and c < right) : (c += 1) try self.emit(" ");
            } else {
                try self.emit(bytes);
            }
        }
        if (in_sel) try self.emit(ansi.reset_attrs);
    }

    const SelRange = struct { lo: usize, hi: usize };

    fn selectionRange(self: *Editor, row: usize) ?SelRange {
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
        const cols: usize = self.win.cols;
        try self.emit(ansi.reverse_video);

        if (self.mode == .command) {
            const prompt: []const u8 = switch (self.cmd_kind) {
                .ex => ":",
                .search_forward => "/",
                .search_backward => "?",
            };
            try self.emit(prompt);
            const shown = @min(self.cmd.items.len, if (cols > 0) cols - 1 else 0);
            try self.emit(self.cmd.items[0..shown]);
            try self.emitSpaces(cols - 1 - shown);
            try self.emit(ansi.reset_attrs);
            return;
        }

        var lb: [320]u8 = undefined;
        const fname = self.buf.path orelse "[No Name]";
        const dirty = if (self.buf.dirty) " [+]" else "";
        const msg = self.status.items;
        const sep = if (msg.len > 0) "  —  " else "";
        const rec = if (self.recording != null) " REC" else "";
        const left = std.fmt.bufPrint(&lb, " {s}{s}  {s}{s}{s}{s}", .{
            self.mode.label(), rec, fname, dirty, sep, msg,
        }) catch " ";

        var rb: [80]u8 = undefined;
        const col_disp = displayCol(self.curLine(), self.cx) + 1;
        const right = std.fmt.bufPrint(&rb, "Ln {d}, Col {d} ", .{ self.cy + 1, col_disp }) catch "";

        var used: usize = 0;
        const lshow = @min(left.len, cols);
        try self.emit(left[0..lshow]);
        used += lshow;
        if (used + right.len <= cols) {
            try self.emitSpaces(cols - used - right.len);
            try self.emit(right);
        } else {
            try self.emitSpaces(cols - used);
        }
        try self.emit(ansi.reset_attrs);
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

fn toggleAscii(cp: u21) u21 {
    if (cp >= 'a' and cp <= 'z') return cp - 'a' + 'A';
    if (cp >= 'A' and cp <= 'Z') return cp - 'A' + 'a';
    return cp;
}

fn lastColumn(line: []const u8) usize {
    if (line.len == 0) return 0;
    return unicode.prevBoundary(line, line.len);
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

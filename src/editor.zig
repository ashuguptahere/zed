//! The editor: state, the input→action dispatch, and screen rendering.
//!
//! The loop is event-driven. It renders only when something changed and then
//! blocks in the terminal layer waiting for input, so an idle editor uses no
//! CPU. Each frame is built into a reused buffer and pushed to the terminal in
//! a single write to avoid flicker and minimise syscalls.

const std = @import("std");
const term = @import("term.zig");
const buffer = @import("buffer.zig");
const key = @import("key.zig");
const unicode = @import("unicode.zig");
const log = @import("log.zig");
const ansi = term.ansi;
const Allocator = std.mem.Allocator;

/// Spaces a tab advances to. Tabs are stored verbatim and expanded on render,
/// so the on-disk file is preserved.
const tab_width = 4;

pub const Mode = enum {
    normal,
    insert,
    command,

    fn label(self: Mode) []const u8 {
        return switch (self) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .command => "COMMAND",
        };
    }
};

pub const Editor = struct {
    gpa: Allocator,
    io: std.Io,
    term: *term.Terminal,
    buf: buffer.Buffer,

    mode: Mode,
    cy: usize, // cursor row (line index)
    cx: usize, // cursor column (byte offset within the line)
    goal_col: usize, // sticky display column for vertical movement

    top: usize, // first visible row
    left: usize, // first visible display column
    win: term.Size,

    frame: std.ArrayList(u8), // reused render scratch
    status: std.ArrayList(u8), // transient message for the status bar
    cmd: std.ArrayList(u8), // command-line text (without the leading ':')
    pending_g: bool, // saw the first 'g' of a 'gg' motion
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
            .frame = .empty,
            .status = .empty,
            .cmd = .empty,
            .pending_g = false,
            .quit = false,
            .inbuf = undefined,
        };
    }

    pub fn deinit(self: *Editor) void {
        self.frame.deinit(self.gpa);
        self.status.deinit(self.gpa);
        self.cmd.deinit(self.gpa);
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

    /// Read one burst of input, extending a lone Escape into a full sequence if
    /// the terminal split it across reads (only ever waits right after an ESC).
    fn readInput(self: *Editor) ![]u8 {
        var n = (try self.term.read(self.inbuf[0..])).len;
        if (n == 1 and self.inbuf[0] == 0x1b and self.term.waitMore(25)) {
            n += (try self.term.read(self.inbuf[n..])).len;
        }
        return self.inbuf[0..n];
    }

    fn processInput(self: *Editor, chunk: []const u8) !void {
        var sp = log.Span.start();
        var i: usize = 0;
        while (i < chunk.len) {
            const d = key.decode(chunk[i..]);
            i += d.consumed;
            try self.handleKey(d.key);
            if (self.quit) break;
        }
        sp.lap("input");
    }

    fn handleKey(self: *Editor, k: key.Key) !void {
        self.status.clearRetainingCapacity();
        switch (self.mode) {
            .normal => try self.normalKey(k),
            .insert => try self.insertKey(k),
            .command => try self.commandKey(k),
        }
        self.clampCursor();
    }

    // --- mode handlers -----------------------------------------------------

    fn normalKey(self: *Editor, k: key.Key) !void {
        if (self.pending_g) {
            self.pending_g = false;
            if (k == .char and k.char == 'g') return self.gotoLine(0);
        }
        if (self.moveKey(k)) return;
        switch (k) {
            .char => |c| switch (c) {
                'h' => self.moveLeft(),
                'l' => self.moveRight(),
                'j' => self.moveDown(),
                'k' => self.moveUp(),
                '0' => self.moveLineStart(),
                '$' => self.moveLineEnd(),
                'g' => self.pending_g = true,
                'G' => self.gotoLine(std.math.maxInt(usize)),
                'i' => self.mode = .insert,
                'a' => {
                    self.moveRight();
                    self.mode = .insert;
                },
                'o' => try self.openBelow(),
                'O' => try self.openAbove(),
                'x' => try self.buf.deleteForward(self.cy, self.cx),
                ':' => {
                    self.mode = .command;
                    self.cmd.clearRetainingCapacity();
                },
                else => {},
            },
            .ctrl => |c| if (c == 'c') self.setStatus("Type :q then Enter to quit", .{}),
            else => {},
        }
    }

    fn insertKey(self: *Editor, k: key.Key) !void {
        if (self.moveKey(k)) return;
        switch (k) {
            .escape => self.mode = .normal,
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

    fn commandKey(self: *Editor, k: key.Key) !void {
        switch (k) {
            .escape => self.mode = .normal,
            .enter => {
                try self.execCommand();
                if (!self.quit) self.mode = .normal;
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

    fn execCommand(self: *Editor) !void {
        const raw = std.mem.trim(u8, self.cmd.items, " ");
        if (raw.len == 0) return;
        var it = std.mem.tokenizeScalar(u8, raw, ' ');
        const cmd = it.next() orelse return;
        const arg = std.mem.trim(u8, raw[cmd.len..], " ");

        if (eql(cmd, "w")) {
            _ = try self.doWrite(arg);
        } else if (eql(cmd, "q")) {
            self.doQuit();
        } else if (eql(cmd, "q!")) {
            self.quit = true;
        } else if (eql(cmd, "wq") or eql(cmd, "x")) {
            if (try self.doWrite(arg)) self.quit = true;
        } else {
            self.setStatus("unknown command: {s}", .{cmd});
        }
    }

    fn doWrite(self: *Editor, arg: []const u8) !bool {
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

    // --- cursor movement ---------------------------------------------------

    fn moveKey(self: *Editor, k: key.Key) bool {
        switch (k) {
            .left => self.moveLeft(),
            .right => self.moveRight(),
            .up => self.moveUp(),
            .down => self.moveDown(),
            .home => self.moveLineStart(),
            .end => self.moveLineEnd(),
            .page_up => self.movePage(true),
            .page_down => self.movePage(false),
            else => return false,
        }
        return true;
    }

    fn curLine(self: *Editor) []const u8 {
        return self.buf.line(self.cy);
    }

    fn moveLeft(self: *Editor) void {
        self.cx = unicode.prevBoundary(self.curLine(), self.cx);
        self.updateGoal();
    }

    fn moveRight(self: *Editor) void {
        const line = self.curLine();
        if (self.cx < line.len) self.cx = unicode.nextBoundary(line, self.cx);
        self.updateGoal();
    }

    fn moveUp(self: *Editor) void {
        if (self.cy == 0) return;
        self.cy -= 1;
        self.cx = byteAtDisplayCol(self.curLine(), self.goal_col);
    }

    fn moveDown(self: *Editor) void {
        if (self.cy + 1 >= self.buf.lineCount()) return;
        self.cy += 1;
        self.cx = byteAtDisplayCol(self.curLine(), self.goal_col);
    }

    fn moveLineStart(self: *Editor) void {
        self.cx = 0;
        self.goal_col = 0;
    }

    fn moveLineEnd(self: *Editor) void {
        self.cx = self.curLine().len;
        self.updateGoal();
    }

    fn movePage(self: *Editor, up: bool) void {
        const delta = self.textRows();
        if (up) {
            self.cy = if (self.cy > delta) self.cy - delta else 0;
        } else {
            self.cy = @min(self.cy + delta, self.buf.lineCount() - 1);
        }
        self.cx = byteAtDisplayCol(self.curLine(), self.goal_col);
    }

    fn gotoLine(self: *Editor, row: usize) void {
        self.cy = @min(row, self.buf.lineCount() - 1);
        self.cx = 0;
        self.goal_col = 0;
    }

    fn openBelow(self: *Editor) !void {
        try self.buf.splitLine(self.cy, self.curLine().len);
        self.cy += 1;
        self.cx = 0;
        self.goal_col = 0;
        self.mode = .insert;
    }

    fn openAbove(self: *Editor) !void {
        try self.buf.splitLine(self.cy, 0);
        self.cx = 0;
        self.goal_col = 0;
        self.mode = .insert;
    }

    fn updateGoal(self: *Editor) void {
        self.goal_col = displayCol(self.curLine(), self.cx);
    }

    fn clampCursor(self: *Editor) void {
        if (self.cy >= self.buf.lineCount()) self.cy = self.buf.lineCount() - 1;
        const line = self.curLine();
        if (self.cx > line.len) self.cx = line.len;
    }

    // --- viewport ----------------------------------------------------------

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
        return @max(digits, 3) + 1; // trailing space after the number
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

    // --- rendering ---------------------------------------------------------

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
                try self.emitLine(self.buf.line(file_row), cols);
            } else {
                try self.emit(ansi.dim);
                try self.emit("~");
                try self.emit(ansi.reset_attrs);
            }
            try self.emit(ansi.clear_line_right);
            try self.emit("\r\n");
        }

        try self.renderStatus(gutter);
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

    /// Emit one line's content, applying horizontal scroll and expanding tabs.
    /// Wide characters or tabs straddling a scroll edge render as spaces so
    /// columns stay aligned with the cursor.
    fn emitLine(self: *Editor, line: []const u8, cols: usize) !void {
        const left = self.left;
        const right = left + cols;
        var dc: usize = 0;
        var i: usize = 0;
        while (i < line.len) {
            const d = unicode.decode(line[i..]);
            const w = cellWidth(d.cp, dc);
            const start = dc;
            const end = dc + w;
            dc = end;
            const bytes = line[i .. i + d.len];
            i += d.len;

            if (end <= left) continue;
            if (start >= right) break;
            if (d.cp == '\t' or start < left or end > right) {
                var c = if (start < left) left else start;
                while (c < end and c < right) : (c += 1) try self.emit(" ");
            } else {
                try self.emit(bytes);
            }
        }
    }

    fn renderStatus(self: *Editor, gutter: usize) !void {
        _ = gutter;
        const cols: usize = self.win.cols;
        try self.emit(ansi.reverse_video);

        if (self.mode == .command) {
            try self.emit(":");
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
        const left = std.fmt.bufPrint(&lb, " {s}  {s}{s}{s}{s}", .{
            self.mode.label(), fname, dirty, sep, msg,
        }) catch " ";

        var rb: [80]u8 = undefined;
        const col_disp = displayCol(self.curLine(), self.cx) + 1;
        const right_full = std.fmt.bufPrint(&rb, "Ln {d}, Col {d} ", .{
            self.cy + 1,
            col_disp,
        }) catch "";

        var used: usize = 0;
        const lshow = @min(left.len, cols);
        try self.emit(left[0..lshow]);
        used += lshow;
        if (used + right_full.len <= cols) {
            try self.emitSpaces(cols - used - right_full.len);
            try self.emit(right_full);
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

    // --- small helpers -----------------------------------------------------

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

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Display width of a single codepoint at display column `col`, expanding tabs
/// to the next tab stop. Shared by the renderer and cursor math so they agree.
fn cellWidth(cp: u21, col: usize) usize {
    if (cp == '\t') return tab_width - (col % tab_width);
    return unicode.width(cp);
}

/// Display column of byte offset `upto` within `line`.
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

/// Byte offset of the codepoint boundary at or before display column `target`.
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
    try std.testing.expectEqual(@as(usize, 2), displayCol("世", 3)); // wide
}

test "byteAtDisplayCol round-trips with displayCol" {
    const line = "a\tbc";
    // 'a' occupies col 0; the tab fills cols 1..3; 'b' starts at display col tab_width.
    const off = byteAtDisplayCol(line, tab_width);
    try std.testing.expectEqual(@as(usize, 2), off); // byte offset of 'b'
    try std.testing.expectEqual(@as(usize, tab_width), displayCol(line, off));
}

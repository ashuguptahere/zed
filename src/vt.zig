//! A terminal emulator's screen: bytes from a child process in, a grid of
//! styled cells out. Pure — no pty, no rendering, no allocation past the one
//! grid — so the parser can be unit-tested without a terminal, which is the
//! only way a state machine this fiddly stays correct.
//!
//! The subset is what a shell and the ordinary command-line tools emit: the
//! C0 controls, cursor movement, erase, insert/delete of lines and
//! characters, scrolling regions, and SGR colour (the 16 ANSI colours, the
//! 256-colour cube and 24-bit truecolour). Escapes it does not know are
//! consumed and dropped rather than printed, which is the difference between
//! an unsupported feature and a screen full of garbage.
//!
//! Deliberately absent (see TODO.md): the alternate screen — so a
//! full-screen program run inside draws over the shell's output rather than
//! restoring it on exit — and any mouse or bracketed-paste mode of its own.
//! Mode sets (`CSI ? … h/l`, including DECTCEM's cursor hiding) are parsed and
//! dropped: nothing here draws a cursor, so tracking its visibility was state
//! no one read.

const std = @import("std");
const theme = @import("theme.zig");
const unicode = @import("unicode.zig");

pub const Color = theme.Color;

pub const Attr = struct {
    fg: ?Color = null, // null = the theme's default foreground
    bg: ?Color = null,
    bold: bool = false,
    dim: bool = false,
    reverse: bool = false,

    pub fn eql(a: Attr, b: Attr) bool {
        return std.meta.eql(a, b);
    }
};

pub const Cell = struct {
    cp: u21 = ' ',
    attr: Attr = .{},
    /// The trailing half of a double-width character: drawn as nothing, so
    /// the wide glyph before it keeps both its columns.
    wide_tail: bool = false,
};

/// The 16 ANSI colours. A terminal's own palette is a user preference we do
/// not have, so these are the widely-used xterm values.
const ansi16 = [16]Color{
    .{ .r = 0x00, .g = 0x00, .b = 0x00 }, .{ .r = 0xcd, .g = 0x00, .b = 0x00 },
    .{ .r = 0x00, .g = 0xcd, .b = 0x00 }, .{ .r = 0xcd, .g = 0xcd, .b = 0x00 },
    .{ .r = 0x00, .g = 0x00, .b = 0xee }, .{ .r = 0xcd, .g = 0x00, .b = 0xcd },
    .{ .r = 0x00, .g = 0xcd, .b = 0xcd }, .{ .r = 0xe5, .g = 0xe5, .b = 0xe5 },
    .{ .r = 0x7f, .g = 0x7f, .b = 0x7f }, .{ .r = 0xff, .g = 0x00, .b = 0x00 },
    .{ .r = 0x00, .g = 0xff, .b = 0x00 }, .{ .r = 0xff, .g = 0xff, .b = 0x00 },
    .{ .r = 0x5c, .g = 0x5c, .b = 0xff }, .{ .r = 0xff, .g = 0x00, .b = 0xff },
    .{ .r = 0x00, .g = 0xff, .b = 0xff }, .{ .r = 0xff, .g = 0xff, .b = 0xff },
};

/// xterm's 256-colour palette: 0-15 the ANSI colours, 16-231 a 6×6×6 cube,
/// 232-255 a 24-step greyscale ramp. Computed, not tabulated.
fn xterm256(n: u8) Color {
    if (n < 16) return ansi16[n];
    if (n < 232) {
        const i = n - 16;
        const steps = [6]u8{ 0, 95, 135, 175, 215, 255 };
        return .{ .r = steps[i / 36], .g = steps[(i / 6) % 6], .b = steps[i % 6] };
    }
    const v: u8 = @intCast(8 + (@as(u16, n - 232) * 10));
    return .{ .r = v, .g = v, .b = v };
}

const max_params = 16;

const State = enum { ground, esc, csi, osc, osc_esc, charset };

/// Rows kept after they scroll off the top. A terminal is for reading recent
/// output, not archiving it, so the history is capped and the oldest rows are
/// dropped — bounded memory whatever a runaway command does.
pub const max_scrollback = 5000;

pub const Screen = struct {
    gpa: std.mem.Allocator,
    cells: []Cell,
    /// Scrolled-off rows, oldest first, `cols` cells each.
    history: std.ArrayList(Cell) = .empty,
    hist_rows: usize = 0,
    /// How many rows back the *view* is. 0 is live, and any new output snaps
    /// back to live — which is what every terminal does, and what stops a
    /// scrolled-back view silently missing a command's output.
    back: usize = 0,
    rows: usize,
    cols: usize,
    cx: usize = 0,
    cy: usize = 0,
    attr: Attr = .{},
    /// The scrolling region (DECSTBM), inclusive, 0-based.
    top: usize = 0,
    bot: usize,
    /// xterm's deferred wrap: writing the last column leaves the cursor there
    /// with this set, so a following character wraps but a following `\r`
    /// does not. Without it, a line exactly as wide as the screen scrolls one
    /// row too early.
    wrap_next: bool = false,
    saved: struct { cx: usize = 0, cy: usize = 0, attr: Attr = .{} } = .{},
    state: State = .ground,
    params: [max_params]u32 = [_]u32{0} ** max_params,
    nparams: usize = 0,
    param_digits: bool = false, // a digit seen since the last ';'
    priv: u8 = 0, // the '?' / '>' of a private CSI
    utf8: [4]u8 = undefined,
    utf8_len: usize = 0,
    need: usize = 0, // bytes the pending UTF-8 sequence still wants

    pub fn init(gpa: std.mem.Allocator, rows: usize, cols: usize) !Screen {
        const r = @max(1, rows);
        const c = @max(1, cols);
        const cells = try gpa.alloc(Cell, r * c);
        @memset(cells, .{});
        return .{ .gpa = gpa, .cells = cells, .rows = r, .cols = c, .bot = r - 1 };
    }

    pub fn deinit(self: *Screen) void {
        self.gpa.free(self.cells);
        self.history.deinit(self.gpa);
    }

    /// A cell as the *viewer* sees it, which is the grid when live and the
    /// history when scrolled back.
    pub fn viewAt(self: *const Screen, row: usize, col: usize) Cell {
        if (row >= self.rows or col >= self.cols) return .{};
        if (self.back == 0) return self.at(row, col);
        const abs = self.hist_rows + row - self.back; // may land in either
        if (abs < self.hist_rows) return self.history.items[abs * self.cols + col];
        return self.at(abs - self.hist_rows, col);
    }

    /// Scroll the view `n` rows back through the history (or forward toward
    /// live with `back = false`). Returns true when it actually moved.
    pub fn scrollView(self: *Screen, n: usize, back: bool) bool {
        const was = self.back;
        if (back) {
            self.back = @min(self.back + n, self.hist_rows);
        } else self.back -|= n;
        return self.back != was;
    }

    /// Push the row about to be lost into the history.
    fn remember(self: *Screen, row: usize) void {
        if (max_scrollback == 0) return;
        const start = row * self.cols;
        self.history.appendSlice(self.gpa, self.cells[start .. start + self.cols]) catch return;
        self.hist_rows += 1;
        if (self.hist_rows > max_scrollback) {
            const drop = self.hist_rows - max_scrollback;
            self.history.replaceRange(self.gpa, 0, drop * self.cols, &.{}) catch return;
            self.hist_rows -= drop;
            self.back -|= drop; // the view keeps pointing at the same text
        }
    }

    pub fn at(self: *const Screen, row: usize, col: usize) Cell {
        if (row >= self.rows or col >= self.cols) return .{};
        return self.cells[row * self.cols + col];
    }

    fn cell(self: *Screen, row: usize, col: usize) *Cell {
        return &self.cells[row * self.cols + col];
    }

    /// Resize the grid, keeping the top-left of the old contents. Reflowing
    /// wrapped lines needs per-line "this continued" state the grid does not
    /// keep; a shell redraws its prompt on SIGWINCH anyway.
    pub fn resize(self: *Screen, rows: usize, cols: usize) !void {
        const r = @max(1, rows);
        const c = @max(1, cols);
        if (r == self.rows and c == self.cols) return;
        const fresh = try self.gpa.alloc(Cell, r * c);
        @memset(fresh, .{});
        const keep_r = @min(r, self.rows);
        const keep_c = @min(c, self.cols);
        for (0..keep_r) |y| {
            for (0..keep_c) |x| fresh[y * c + x] = self.cells[y * self.cols + x];
        }
        self.gpa.free(self.cells);
        self.cells = fresh;
        // The history's rows are `cols` cells wide, so a width change would
        // reinterpret them as garbage. Reflowing needs per-row "this
        // continued" state the grid does not keep, so it is dropped instead.
        if (c != self.cols) {
            self.history.clearRetainingCapacity();
            self.hist_rows = 0;
            self.back = 0;
        }
        self.rows = r;
        self.cols = c;
        self.top = 0;
        self.bot = r - 1;
        self.cx = @min(self.cx, c - 1);
        self.cy = @min(self.cy, r - 1);
        self.wrap_next = false;
    }

    // === feeding ===========================================================

    pub fn feed(self: *Screen, bytes: []const u8) void {
        if (bytes.len > 0) self.back = 0; // new output snaps the view to live
        for (bytes) |b| self.feedByte(b);
    }

    fn feedByte(self: *Screen, b: u8) void {
        switch (self.state) {
            .ground => self.ground(b),
            .esc => self.escape(b),
            .csi => self.csiByte(b),
            .osc => {
                // OSC runs to BEL or ST (ESC \). The payload is a window
                // title or a clipboard write — nothing this grid shows.
                if (b == 0x07) self.state = .ground;
                if (b == 0x1b) self.state = .osc_esc;
            },
            .osc_esc => self.state = if (b == '\\') .ground else .osc,
            .charset => self.state = .ground, // ESC ( B and friends: one byte, dropped
        }
    }

    fn ground(self: *Screen, b: u8) void {
        if (self.utf8_len > 0) return self.continuation(b);
        switch (b) {
            0x1b => {
                self.state = .esc;
                self.nparams = 0;
                self.params = [_]u32{0} ** max_params;
                self.param_digits = false;
                self.priv = 0;
            },
            '\r' => {
                self.cx = 0;
                self.wrap_next = false;
            },
            '\n', 0x0b, 0x0c => self.lineFeed(),
            0x08 => {
                if (self.wrap_next) {
                    self.wrap_next = false;
                } else if (self.cx > 0) self.cx -= 1;
            },
            '\t' => {
                self.wrap_next = false;
                self.cx = @min(self.cols - 1, (self.cx / 8 + 1) * 8);
            },
            0x07 => {}, // the bell is not ours to ring
            0x00...0x06, 0x0e...0x1a, 0x1c...0x1f, 0x7f => {}, // other C0: dropped
            else => {
                if (b < 0x80) return self.put(b);
                // A UTF-8 lead byte: gather its continuations before drawing.
                const need: usize = if (b & 0xe0 == 0xc0) 2 else if (b & 0xf0 == 0xe0) 3 else if (b & 0xf8 == 0xf0) 4 else 0;
                if (need == 0) return self.put(0xfffd); // a stray continuation
                self.utf8[0] = b;
                self.utf8_len = 1;
                self.need = need;
            },
        }
    }

    fn continuation(self: *Screen, b: u8) void {
        if (b & 0xc0 != 0x80) { // truncated sequence: draw a replacement, retry this byte
            self.utf8_len = 0;
            self.put(0xfffd);
            return self.ground(b);
        }
        self.utf8[self.utf8_len] = b;
        self.utf8_len += 1;
        if (self.utf8_len < self.need) return;
        const d = unicode.decode(self.utf8[0..self.utf8_len]);
        self.utf8_len = 0;
        self.put(if (d.len == 0) 0xfffd else d.cp);
    }

    /// Draw one codepoint at the cursor, honouring the deferred wrap and
    /// double-width cells.
    fn put(self: *Screen, cp: u21) void {
        const w = unicode.width(cp);
        if (w == 0) return; // a combining mark: no cell of its own here
        if (self.wrap_next) {
            self.cx = 0;
            self.lineFeed();
            self.wrap_next = false;
        }
        if (self.cx + w > self.cols) { // a wide char that will not fit
            self.cx = 0;
            self.lineFeed();
        }
        self.cell(self.cy, self.cx).* = .{ .cp = cp, .attr = self.attr };
        if (w == 2 and self.cx + 1 < self.cols)
            self.cell(self.cy, self.cx + 1).* = .{ .cp = ' ', .attr = self.attr, .wide_tail = true };
        self.cx += w;
        if (self.cx >= self.cols) {
            self.cx = self.cols - 1;
            self.wrap_next = true;
        }
    }

    fn lineFeed(self: *Screen) void {
        self.wrap_next = false;
        if (self.cy == self.bot) return self.scrollUp(1);
        if (self.cy + 1 < self.rows) self.cy += 1;
    }

    fn scrollUp(self: *Screen, n: usize) void {
        const count = @min(n, self.bot - self.top + 1);
        // Only rows leaving the top of the *screen* are history. A scrolling
        // region's rows are being rewritten in place by a full-screen program,
        // not scrolled away, so keeping them would fill the history with
        // redraw noise.
        if (self.top == 0) {
            var k: usize = 0;
            while (k < count) : (k += 1) self.remember(k);
        }
        var y = self.top;
        while (y + count <= self.bot) : (y += 1) {
            const dst = y * self.cols;
            const src = (y + count) * self.cols;
            @memcpy(self.cells[dst .. dst + self.cols], self.cells[src .. src + self.cols]);
        }
        while (y <= self.bot) : (y += 1) self.blankRow(y);
    }

    fn scrollDown(self: *Screen, n: usize) void {
        const count = @min(n, self.bot - self.top + 1);
        var y = self.bot + 1;
        while (y > self.top + count) {
            y -= 1;
            const dst = y * self.cols;
            const src = (y - count) * self.cols;
            @memcpy(self.cells[dst .. dst + self.cols], self.cells[src .. src + self.cols]);
        }
        while (y > self.top) {
            y -= 1;
            self.blankRow(y);
        }
    }

    /// A blanked cell keeps the *current* background, which is how a coloured
    /// erase (a shell painting its prompt line) comes out right.
    fn blankRow(self: *Screen, y: usize) void {
        const start = y * self.cols;
        @memset(self.cells[start .. start + self.cols], .{ .attr = .{ .bg = self.attr.bg } });
    }

    fn escape(self: *Screen, b: u8) void {
        switch (b) {
            '[' => self.state = .csi,
            ']' => self.state = .osc,
            '(', ')', '*', '+' => self.state = .charset,
            '7' => {
                self.saved = .{ .cx = self.cx, .cy = self.cy, .attr = self.attr };
                self.state = .ground;
            },
            '8' => {
                self.cx = @min(self.saved.cx, self.cols - 1);
                self.cy = @min(self.saved.cy, self.rows - 1);
                self.attr = self.saved.attr;
                self.state = .ground;
            },
            'M' => { // reverse index
                if (self.cy == self.top) self.scrollDown(1) else if (self.cy > 0) self.cy -= 1;
                self.state = .ground;
            },
            'c' => { // RIS: full reset
                self.attr = .{};
                self.top = 0;
                self.bot = self.rows - 1;
                self.cx = 0;
                self.cy = 0;
                @memset(self.cells, .{});
                self.state = .ground;
            },
            'D' => {
                self.lineFeed();
                self.state = .ground;
            },
            'E' => {
                self.cx = 0;
                self.lineFeed();
                self.state = .ground;
            },
            else => self.state = .ground, // unknown: dropped, never printed
        }
    }

    fn csiByte(self: *Screen, b: u8) void {
        switch (b) {
            '0'...'9' => {
                if (self.nparams == 0) self.nparams = 1;
                const p = &self.params[self.nparams - 1];
                p.* = @min(p.* * 10 + (b - '0'), 65535); // clamped: no overflow from a hostile stream
                self.param_digits = true;
                return;
            },
            ';' => {
                if (self.nparams < max_params) self.nparams += 1;
                if (self.nparams == 0) self.nparams = 1;
                self.params[self.nparams - 1] = 0;
                self.param_digits = false;
                return;
            },
            '?', '>', '<', '=' => {
                self.priv = b;
                return;
            },
            ' ', '!'...'/' => return, // intermediates, e.g. the ' ' of "CSI 1 SP q"
            else => {},
        }
        self.dispatch(b);
        self.state = .ground;
    }

    /// A CSI parameter, where absent *or zero* means the default — the rule
    /// for the cursor-motion and scroll finals. `param0` is for the ones
    /// where zero is a value of its own (SGR, ED, EL).
    fn param(self: *const Screen, i: usize, default: u32) u32 {
        if (i >= self.nparams) return default;
        const v = self.params[i];
        return if (v == 0) default else v;
    }

    /// A parameter that means "0 is a real value" (SGR, ED, EL).
    fn param0(self: *const Screen, i: usize) u32 {
        if (i >= self.nparams) return 0;
        return self.params[i];
    }

    fn dispatch(self: *Screen, final: u8) void {
        const n: usize = @max(1, self.param(0, 1));
        switch (final) {
            'A' => self.cy -|= n,
            'B' => self.cy = @min(self.rows - 1, self.cy + n),
            'C' => {
                self.cx = @min(self.cols - 1, self.cx + n);
                self.wrap_next = false;
            },
            'D' => {
                self.cx -|= n;
                self.wrap_next = false;
            },
            'E' => {
                self.cy = @min(self.rows - 1, self.cy + n);
                self.cx = 0;
            },
            'F' => {
                self.cy -|= n;
                self.cx = 0;
            },
            'G', '`' => {
                self.cx = @min(self.cols - 1, n - 1);
                self.wrap_next = false;
            },
            'd' => self.cy = @min(self.rows - 1, n - 1),
            'H', 'f' => {
                self.cy = @min(self.rows - 1, n - 1);
                self.cx = @min(self.cols - 1, @max(1, self.param(1, 1)) - 1);
                self.wrap_next = false;
            },
            'J' => self.eraseDisplay(self.param0(0)),
            'K' => self.eraseLine(self.param0(0)),
            'L' => self.insertLines(n),
            'M' => self.deleteLines(n),
            'P' => self.deleteChars(n),
            '@' => self.insertChars(n),
            'X' => { // ECH: overwrite n cells with blanks, cursor unmoved
                var x = self.cx;
                while (x < @min(self.cols, self.cx + n)) : (x += 1)
                    self.cell(self.cy, x).* = .{ .attr = .{ .bg = self.attr.bg } };
            },
            'S' => self.scrollUp(n),
            'T' => self.scrollDown(n),
            'm' => self.sgr(),
            'r' => { // DECSTBM
                const t = @max(1, self.param(0, 1)) - 1;
                const b = @max(1, self.param(1, @intCast(self.rows))) - 1;
                if (t < b and b < self.rows) {
                    self.top = t;
                    self.bot = b;
                } else {
                    self.top = 0;
                    self.bot = self.rows - 1;
                }
                self.cx = 0;
                self.cy = self.top;
            },
            's' => self.saved = .{ .cx = self.cx, .cy = self.cy, .attr = self.attr },
            'u' => {
                self.cx = @min(self.saved.cx, self.cols - 1);
                self.cy = @min(self.saved.cy, self.rows - 1);
                self.attr = self.saved.attr;
            },
            else => {}, // unknown final byte: the whole sequence is dropped
        }
    }

    fn eraseDisplay(self: *Screen, mode: u32) void {
        const blank = Cell{ .attr = .{ .bg = self.attr.bg } };
        switch (mode) {
            0 => { // cursor to end
                self.eraseLine(0);
                var y = self.cy + 1;
                while (y < self.rows) : (y += 1) self.blankRow(y);
            },
            1 => { // start to cursor
                var y: usize = 0;
                while (y < self.cy) : (y += 1) self.blankRow(y);
                var x: usize = 0;
                while (x <= @min(self.cx, self.cols - 1)) : (x += 1) self.cell(self.cy, x).* = blank;
            },
            else => {
                var y: usize = 0;
                while (y < self.rows) : (y += 1) self.blankRow(y);
            },
        }
    }

    fn eraseLine(self: *Screen, mode: u32) void {
        const blank = Cell{ .attr = .{ .bg = self.attr.bg } };
        const from: usize = switch (mode) {
            1 => 0,
            2 => 0,
            else => self.cx,
        };
        const to: usize = switch (mode) {
            1 => @min(self.cx + 1, self.cols),
            2 => self.cols,
            else => self.cols,
        };
        var x = from;
        while (x < to) : (x += 1) self.cell(self.cy, x).* = blank;
    }

    fn insertLines(self: *Screen, n: usize) void {
        if (self.cy < self.top or self.cy > self.bot) return;
        const saved_top = self.top;
        self.top = self.cy; // the region scrolls from the cursor down
        self.scrollDown(n);
        self.top = saved_top;
    }

    fn deleteLines(self: *Screen, n: usize) void {
        if (self.cy < self.top or self.cy > self.bot) return;
        const saved_top = self.top;
        self.top = self.cy;
        self.scrollUp(n);
        self.top = saved_top;
    }

    fn deleteChars(self: *Screen, n: usize) void {
        const count = @min(n, self.cols - self.cx);
        var x = self.cx;
        while (x + count < self.cols) : (x += 1) self.cell(self.cy, x).* = self.at(self.cy, x + count);
        while (x < self.cols) : (x += 1) self.cell(self.cy, x).* = .{ .attr = .{ .bg = self.attr.bg } };
    }

    fn insertChars(self: *Screen, n: usize) void {
        const count = @min(n, self.cols - self.cx);
        var x = self.cols;
        while (x > self.cx + count) {
            x -= 1;
            self.cell(self.cy, x).* = self.at(self.cy, x - count);
        }
        while (x > self.cx) {
            x -= 1;
            self.cell(self.cy, x).* = .{ .attr = .{ .bg = self.attr.bg } };
        }
    }

    fn sgr(self: *Screen) void {
        if (self.nparams == 0) {
            self.attr = .{};
            return;
        }
        var i: usize = 0;
        while (i < self.nparams) : (i += 1) {
            const p = self.params[i];
            switch (p) {
                0 => self.attr = .{},
                1 => self.attr.bold = true,
                2 => self.attr.dim = true,
                7 => self.attr.reverse = true,
                22 => {
                    self.attr.bold = false;
                    self.attr.dim = false;
                },
                27 => self.attr.reverse = false,
                30...37 => self.attr.fg = ansi16[p - 30],
                39 => self.attr.fg = null,
                40...47 => self.attr.bg = ansi16[p - 40],
                49 => self.attr.bg = null,
                90...97 => self.attr.fg = ansi16[p - 90 + 8],
                100...107 => self.attr.bg = ansi16[p - 100 + 8],
                38, 48 => {
                    const c = self.extendedColor(&i) orelse continue;
                    if (p == 38) self.attr.fg = c else self.attr.bg = c;
                },
                else => {}, // italics, underline, strike: no cell bit for them here
            }
        }
    }

    /// `38;5;n` or `38;2;r;g;b`, advancing `i` past what it consumed. Null
    /// when the parameters run out mid-colour (a truncated sequence).
    fn extendedColor(self: *const Screen, i: *usize) ?Color {
        if (i.* + 1 >= self.nparams) return null;
        const kind = self.params[i.* + 1];
        if (kind == 5) {
            if (i.* + 2 >= self.nparams) return null;
            i.* += 2;
            return xterm256(@truncate(self.params[i.*]));
        }
        if (kind == 2) {
            if (i.* + 4 >= self.nparams) return null;
            i.* += 4;
            return .{
                .r = @truncate(self.params[i.* - 2]),
                .g = @truncate(self.params[i.* - 1]),
                .b = @truncate(self.params[i.*]),
            };
        }
        return null;
    }
};

// === tests =================================================================

const testing = std.testing;

/// The text of one row, trailing blanks trimmed — what a human would call
/// "what is on that line".
fn rowText(s: *const Screen, gpa: std.mem.Allocator, row: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..s.cols) |x| {
        const c = s.at(row, x);
        if (c.wide_tail) continue;
        var b: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c.cp, &b) catch 1;
        try out.appendSlice(gpa, b[0..n]);
    }
    const t = std.mem.trimEnd(u8, out.items, " ");
    const owned = try gpa.dupe(u8, t);
    out.deinit(gpa);
    return owned;
}

fn expectRow(s: *const Screen, row: usize, want: []const u8) !void {
    const got = try rowText(s, testing.allocator, row);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "plain text lands on the grid and the cursor follows" {
    var s = try Screen.init(testing.allocator, 4, 10);
    defer s.deinit();
    s.feed("hello");
    try expectRow(&s, 0, "hello");
    try testing.expectEqual(@as(usize, 5), s.cx);
    try testing.expectEqual(@as(usize, 0), s.cy);
}

test "CR and LF move the cursor as a terminal does" {
    var s = try Screen.init(testing.allocator, 4, 10);
    defer s.deinit();
    s.feed("ab\r\ncd");
    try expectRow(&s, 0, "ab");
    try expectRow(&s, 1, "cd");
}

test "a line exactly as wide as the screen does not scroll early" {
    // The deferred wrap: writing column 10 of 10 leaves the cursor there, and
    // the following \r\n is one line feed, not two.
    var s = try Screen.init(testing.allocator, 3, 10);
    defer s.deinit();
    s.feed("0123456789\r\nnext");
    try expectRow(&s, 0, "0123456789");
    try expectRow(&s, 1, "next");
}

test "text past the last column wraps to the next row" {
    var s = try Screen.init(testing.allocator, 3, 4);
    defer s.deinit();
    s.feed("abcdef");
    try expectRow(&s, 0, "abcd");
    try expectRow(&s, 1, "ef");
}

test "output past the last row scrolls the screen" {
    var s = try Screen.init(testing.allocator, 3, 8);
    defer s.deinit();
    s.feed("one\r\ntwo\r\nthree\r\nfour");
    try expectRow(&s, 0, "two");
    try expectRow(&s, 1, "three");
    try expectRow(&s, 2, "four");
}

test "backspace, tab and carriage return" {
    var s = try Screen.init(testing.allocator, 2, 20);
    defer s.deinit();
    s.feed("abc\x08X");
    try expectRow(&s, 0, "abX");
    s.feed("\r\tZ");
    try expectRow(&s, 0, "abX     Z");
}

test "cursor positioning and erase" {
    var s = try Screen.init(testing.allocator, 3, 10);
    defer s.deinit();
    s.feed("aaaa\r\nbbbb\r\ncccc");
    s.feed("\x1b[2;2H"); // row 2, col 2 (1-based)
    try testing.expectEqual(@as(usize, 1), s.cy);
    try testing.expectEqual(@as(usize, 1), s.cx);
    s.feed("\x1b[K"); // erase to end of line
    try expectRow(&s, 1, "b");
    s.feed("\x1b[2J"); // erase all
    try expectRow(&s, 0, "");
    try expectRow(&s, 2, "");
}

test "erase from the start of the line keeps the tail" {
    var s = try Screen.init(testing.allocator, 2, 10);
    defer s.deinit();
    s.feed("abcdef\x1b[4G\x1b[1K"); // cursor to col 4, erase start..cursor
    try expectRow(&s, 0, "    ef");
}

test "SGR sets and resets colour" {
    var s = try Screen.init(testing.allocator, 2, 10);
    defer s.deinit();
    s.feed("\x1b[31mR\x1b[0mP");
    try testing.expectEqual(ansi16[1], s.at(0, 0).attr.fg.?);
    try testing.expect(s.at(0, 1).attr.fg == null);
}

test "SGR truecolour and the 256-colour cube" {
    var s = try Screen.init(testing.allocator, 2, 10);
    defer s.deinit();
    s.feed("\x1b[38;2;10;20;30mT");
    try testing.expectEqual(Color{ .r = 10, .g = 20, .b = 30 }, s.at(0, 0).attr.fg.?);
    s.feed("\x1b[48;5;196mB");
    try testing.expectEqual(xterm256(196), s.at(0, 1).attr.bg.?);
    // A bright colour and a background in one sequence.
    s.feed("\x1b[0;92;44mX");
    try testing.expectEqual(ansi16[10], s.at(0, 2).attr.fg.?);
    try testing.expectEqual(ansi16[4], s.at(0, 2).attr.bg.?);
}

test "a truncated colour sequence does not eat the rest of the line" {
    var s = try Screen.init(testing.allocator, 2, 10);
    defer s.deinit();
    s.feed("\x1b[38;2;10mok"); // r given, g and b missing
    try expectRow(&s, 0, "ok");
}

test "an unknown escape is dropped, not printed" {
    var s = try Screen.init(testing.allocator, 2, 20);
    defer s.deinit();
    s.feed("a\x1b[?1049hb\x1b]0;a title\x07c\x1b(Bd");
    try expectRow(&s, 0, "abcd");
}

test "OSC terminated by ST rather than BEL" {
    var s = try Screen.init(testing.allocator, 2, 20);
    defer s.deinit();
    s.feed("x\x1b]2;window\x1b\\y");
    try expectRow(&s, 0, "xy");
}

test "insert and delete characters" {
    var s = try Screen.init(testing.allocator, 2, 10);
    defer s.deinit();
    s.feed("abcdef\x1b[1G\x1b[2P"); // delete 2 at column 1
    try expectRow(&s, 0, "cdef");
    s.feed("\x1b[1G\x1b[2@XY"); // insert room for 2, then write
    try expectRow(&s, 0, "XYcdef");
}

test "insert and delete lines inside a scrolling region" {
    var s = try Screen.init(testing.allocator, 4, 6);
    defer s.deinit();
    s.feed("1\r\n2\r\n3\r\n4");
    s.feed("\x1b[2;4r"); // region = rows 2..4
    s.feed("\x1b[2;1H\x1b[M"); // delete row 2
    try expectRow(&s, 0, "1");
    try expectRow(&s, 1, "3");
    try expectRow(&s, 2, "4");
    try expectRow(&s, 3, "");
}

test "a scrolling region scrolls only itself" {
    var s = try Screen.init(testing.allocator, 4, 6);
    defer s.deinit();
    s.feed("top\r\na\r\nb\r\nc");
    s.feed("\x1b[2;4r\x1b[4;1H"); // region rows 2..4, cursor on the last
    s.feed("\nd");
    try expectRow(&s, 0, "top"); // untouched: outside the region
    try expectRow(&s, 1, "b");
    try expectRow(&s, 2, "c");
    try expectRow(&s, 3, "d");
}

test "reverse index scrolls down at the top of the region" {
    var s = try Screen.init(testing.allocator, 3, 6);
    defer s.deinit();
    s.feed("a\r\nb\r\nc\x1b[1;1H\x1bM");
    try expectRow(&s, 0, "");
    try expectRow(&s, 1, "a");
    try expectRow(&s, 2, "b");
}

test "save and restore the cursor" {
    var s = try Screen.init(testing.allocator, 3, 10);
    defer s.deinit();
    s.feed("ab\x1b7\r\ncd\x1b8X");
    try expectRow(&s, 0, "abX");
    try expectRow(&s, 1, "cd");
}

test "UTF-8 arrives split across feeds and still draws one glyph" {
    var s = try Screen.init(testing.allocator, 2, 10);
    defer s.deinit();
    s.feed("\xe2\x82"); // the first two bytes of €
    s.feed("\xacX");
    try expectRow(&s, 0, "\u{20ac}X");
}

test "a wide character takes two columns" {
    var s = try Screen.init(testing.allocator, 2, 6);
    defer s.deinit();
    s.feed("\u{4e16}\u{754c}!"); // 世界!
    try testing.expectEqual(@as(usize, 5), s.cx);
    try testing.expect(s.at(0, 1).wide_tail);
    try expectRow(&s, 0, "\u{4e16}\u{754c}!");
}

test "invalid UTF-8 becomes a replacement char, never a control byte" {
    var s = try Screen.init(testing.allocator, 2, 10);
    defer s.deinit();
    s.feed("a\xffb");
    const row = try rowText(&s, testing.allocator, 0);
    defer testing.allocator.free(row);
    try testing.expect(std.mem.indexOfScalar(u8, row, 0xff) == null);
    try testing.expect(std.unicode.utf8ValidateSlice(row));
}

/// Whether `want` appears on any row of the grid.
fn gridHas(s: *const Screen, want: []const u8) !bool {
    for (0..s.rows) |y| {
        const row = try rowText(s, testing.allocator, y);
        defer testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, want) != null) return true;
    }
    return false;
}

test "a hostile parameter run cannot overflow or escape the grid" {
    var s = try Screen.init(testing.allocator, 3, 10);
    defer s.deinit();
    var giant: std.ArrayList(u8) = .empty;
    defer giant.deinit(testing.allocator);
    try giant.appendSlice(testing.allocator, "\x1b[");
    for (0..500) |_| try giant.appendSlice(testing.allocator, "99999999;");
    try giant.appendSlice(testing.allocator, "1H" ++ "ok");
    s.feed(giant.items);
    // Every parameter is clamped, the cursor stays inside the grid, and the
    // text after the sequence is still drawn rather than swallowed.
    try testing.expect(s.cx < s.cols and s.cy < s.rows);
    try testing.expect(try gridHas(&s, "o"));
}

test "a parameter longer than the parameter array is bounded" {
    var s = try Screen.init(testing.allocator, 3, 10);
    defer s.deinit();
    s.feed("\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20Hx");
    try testing.expect(s.cx < s.cols and s.cy < s.rows);
    try testing.expect(try gridHas(&s, "x"));
}

test "resize keeps the top-left contents and clamps the cursor" {
    var s = try Screen.init(testing.allocator, 4, 10);
    defer s.deinit();
    s.feed("hello\r\nworld");
    try s.resize(2, 4);
    try expectRow(&s, 0, "hell");
    try expectRow(&s, 1, "worl");
    try testing.expect(s.cy < 2 and s.cx < 4);
}

test "rows that scroll off the top go into the history" {
    var s = try Screen.init(testing.allocator, 3, 8);
    defer s.deinit();
    s.feed("one\r\ntwo\r\nthree\r\nfour\r\nfive");
    // The screen shows the last three; the first two are history.
    try expectRow(&s, 0, "three");
    try testing.expectEqual(@as(usize, 2), s.hist_rows);
    // Scrolled back one row, the view starts a line earlier.
    try testing.expect(s.scrollView(1, true));
    try testing.expectEqual(@as(u21, 't'), s.viewAt(0, 0).cp); // "two"
    try testing.expectEqual(@as(u21, 'w'), s.viewAt(0, 1).cp);
    try testing.expect(s.scrollView(1, true));
    try testing.expectEqual(@as(u21, 'o'), s.viewAt(0, 0).cp); // "one"
}

test "the view cannot scroll past the oldest row or past live" {
    var s = try Screen.init(testing.allocator, 2, 6);
    defer s.deinit();
    s.feed("a\r\nb\r\nc");
    try testing.expectEqual(@as(usize, 1), s.hist_rows);
    try testing.expect(s.scrollView(99, true));
    try testing.expectEqual(@as(usize, 1), s.back); // clamped to what exists
    try testing.expect(!s.scrollView(1, true)); // already as far back as it goes
    try testing.expect(s.scrollView(99, false));
    try testing.expectEqual(@as(usize, 0), s.back);
    try testing.expect(!s.scrollView(1, false));
}

test "new output snaps the view back to live" {
    var s = try Screen.init(testing.allocator, 2, 6);
    defer s.deinit();
    s.feed("a\r\nb\r\nc");
    _ = s.scrollView(1, true);
    try testing.expect(s.back > 0);
    s.feed("d");
    try testing.expectEqual(@as(usize, 0), s.back);
}

test "a scrolling region's rows are not history" {
    var s = try Screen.init(testing.allocator, 4, 6);
    defer s.deinit();
    s.feed("1\r\n2\r\n3\r\n4");
    const before = s.hist_rows;
    s.feed("\x1b[2;4r\x1b[4;1H\nx"); // scroll inside rows 2..4
    try testing.expectEqual(before, s.hist_rows); // redraw noise, not history
}

test "the history is capped" {
    var s = try Screen.init(testing.allocator, 2, 4);
    defer s.deinit();
    var i: usize = 0;
    while (i < max_scrollback + 50) : (i += 1) s.feed("x\r\n");
    try testing.expectEqual(max_scrollback, s.hist_rows);
    try testing.expectEqual(max_scrollback * s.cols, s.history.items.len);
}

test "a width change drops the history rather than misreading it" {
    var s = try Screen.init(testing.allocator, 2, 8);
    defer s.deinit();
    s.feed("a\r\nb\r\nc");
    try testing.expect(s.hist_rows > 0);
    try s.resize(2, 12);
    try testing.expectEqual(@as(usize, 0), s.hist_rows);
}

test "viewAt is the grid when live" {
    var s = try Screen.init(testing.allocator, 2, 6);
    defer s.deinit();
    s.feed("hi");
    try testing.expectEqual(s.at(0, 0).cp, s.viewAt(0, 0).cp);
    try testing.expectEqual(s.at(0, 1).cp, s.viewAt(0, 1).cp);
}

test "an erase after setting a background paints that background" {
    var s = try Screen.init(testing.allocator, 2, 6);
    defer s.deinit();
    s.feed("\x1b[41m\x1b[2J");
    try testing.expectEqual(ansi16[1], s.at(1, 3).attr.bg.?);
}

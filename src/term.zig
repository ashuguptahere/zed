//! Terminal control: raw mode, the alternate screen, window size and input.
//!
//! Everything OS-specific about driving a terminal lives here so the rest of
//! the editor stays portable. The implementation targets POSIX terminals
//! (Linux, macOS, the BSDs). Windows console support is a known gap, isolated
//! to this module behind a clear compile-time error.
//!
//! Input is event-driven, not polled: the editor blocks in `poll(2)` until a
//! key is pressed or the window is resized, so an idle editor burns zero CPU.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

comptime {
    if (builtin.os.tag == .windows) {
        @compileError("zed's terminal layer is POSIX-only for now; Windows console support is not yet implemented");
    }
}

/// Set by the SIGWINCH handler, drained by the editor loop. Atomic because a
/// signal can fire between any two instructions of the main thread.
var resize_pending = std.atomic.Value(bool).init(false);

fn handleWinch(_: posix.SIG) callconv(.c) void {
    resize_pending.store(true, .release);
}

/// ANSI escape sequences. Grouped here so call sites read declaratively.
pub const ansi = struct {
    pub const enter_alt_screen = "\x1b[?1049h";
    pub const leave_alt_screen = "\x1b[?1049l";
    pub const clear_screen = "\x1b[2J";
    pub const clear_line_right = "\x1b[K";
    pub const cursor_home = "\x1b[H";
    pub const hide_cursor = "\x1b[?25l";
    pub const show_cursor = "\x1b[?25h";
    pub const reset_attrs = "\x1b[m";
    pub const reverse_video = "\x1b[7m";
    pub const dim = "\x1b[2m";
};

/// Window dimensions in character cells.
pub const Size = struct {
    rows: u16,
    cols: u16,
};

pub const Error = error{NotATerminal} || posix.UnexpectedError;

pub const Terminal = struct {
    in: posix.fd_t,
    out: posix.fd_t,
    original: posix.termios,
    raw_enabled: bool,
    alt_active: bool,

    /// Capture the current terminal settings. Fails cleanly when stdin is not
    /// a terminal (e.g. piped input), letting `main` print a friendly message.
    pub fn init() Error!Terminal {
        const in = posix.STDIN_FILENO;
        const original = posix.tcgetattr(in) catch return error.NotATerminal;
        return .{
            .in = in,
            .out = posix.STDOUT_FILENO,
            .original = original,
            .raw_enabled = false,
            .alt_active = false,
        };
    }

    /// Switch the terminal into raw mode: no echo, no line buffering, no signal
    /// or flow-control processing. Reads then block until a key arrives.
    pub fn enableRaw(self: *Terminal) Error!void {
        var raw = self.original;
        // Input: no break-to-signal, no CR->NL, no parity/strip, no flow control.
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        // Output: no post-processing (we emit \r\n ourselves).
        raw.oflag.OPOST = false;
        // Local: no echo, no canonical mode, no extended input, no signals.
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        // 8-bit characters.
        raw.cflag.CSIZE = .CS8;
        // Block until at least one byte is available; the editor sleeps in
        // poll(2) the rest of the time, so this costs no CPU while idle.
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        posix.tcsetattr(self.in, .FLUSH, raw) catch return error.NotATerminal;
        self.raw_enabled = true;
    }

    /// Restore the captured terminal settings. Idempotent.
    pub fn disableRaw(self: *Terminal) void {
        if (!self.raw_enabled) return;
        posix.tcsetattr(self.in, .FLUSH, self.original) catch {};
        self.raw_enabled = false;
    }

    /// Install the SIGWINCH handler so window resizes wake the input loop
    /// instead of being discovered by periodic polling.
    pub fn installResizeHandler(_: *Terminal) void {
        var act: posix.Sigaction = .{
            .handler = .{ .handler = handleWinch },
            .mask = posix.sigemptyset(),
            .flags = 0, // no SA_RESTART: let SIGWINCH interrupt poll() with EINTR
        };
        posix.sigaction(posix.SIG.WINCH, &act, null);
    }

    pub fn enterAltScreen(self: *Terminal) Error!void {
        try self.write(ansi.enter_alt_screen);
        self.alt_active = true;
    }

    pub fn leaveAltScreen(self: *Terminal) void {
        if (!self.alt_active) return;
        self.write(ansi.show_cursor) catch {};
        self.write(ansi.leave_alt_screen) catch {};
        self.alt_active = false;
    }

    /// Best-effort full restore for shutdown and panic paths. Idempotent.
    pub fn restore(self: *Terminal) void {
        self.leaveAltScreen();
        self.disableRaw();
    }

    /// True (and cleared) if a resize happened since the last check.
    pub fn takeResize(_: *Terminal) bool {
        return resize_pending.swap(false, .acquire);
    }

    /// Query the window size, falling back to a sane default if the ioctl is
    /// unavailable (some pipes and CI environments).
    pub fn size(self: *Terminal) Size {
        var ws: posix.winsize = undefined;
        const rc = posix.system.ioctl(self.out, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (posix.system.errno(rc) == .SUCCESS and ws.row > 0 and ws.col > 0) {
            return .{ .rows = ws.row, .cols = ws.col };
        }
        return .{ .rows = 24, .cols = 80 };
    }

    /// Write every byte, retrying short writes and EINTR. POSIX `write` was
    /// removed from the high-level std API in 0.16, so we loop the raw syscall.
    pub fn write(self: *Terminal, bytes: []const u8) Error!void {
        var i: usize = 0;
        while (i < bytes.len) {
            const rc = posix.system.write(self.out, bytes.ptr + i, bytes.len - i);
            switch (posix.system.errno(rc)) {
                .SUCCESS => i += @intCast(rc),
                .INTR, .AGAIN => continue,
                else => |e| return posix.unexpectedErrno(e),
            }
        }
    }

    /// Block (consuming no CPU) until input is ready or a signal fires.
    /// Returns `false` when interrupted before input arrived — typically
    /// SIGWINCH — which the caller treats as "check for a resize and redraw".
    ///
    /// We call the raw poll syscall rather than `std.posix.poll`, because the
    /// latter silently retries on EINTR and so would never surface a resize
    /// that arrives while we are blocked. (A resize landing in the brief window
    /// between the resize check and entering poll is missed until the next key;
    /// closing that race needs a self-pipe and is left as future work.)
    pub fn waitForInput(self: *Terminal) Error!bool {
        var fds = [_]posix.pollfd{.{ .fd = self.in, .events = posix.POLL.IN, .revents = 0 }};
        const rc = posix.system.poll(&fds, 1, -1);
        return switch (posix.system.errno(rc)) {
            .SUCCESS => (fds[0].revents & posix.POLL.IN) != 0,
            .INTR => false,
            else => |e| posix.unexpectedErrno(e),
        };
    }

    /// Read currently-available input into `buf`, returning the bytes read.
    /// Assumes data is ready (call after `waitForInput`).
    pub fn read(self: *Terminal, buf: []u8) Error![]u8 {
        const n = posix.read(self.in, buf) catch |err| switch (err) {
            error.WouldBlock => return buf[0..0],
            else => return error.Unexpected,
        };
        return buf[0..n];
    }

    /// True if more input arrives within `timeout_ms`. Used only to disambiguate
    /// a lone Escape from the start of an escape sequence, so it never runs
    /// while the editor is idle.
    pub fn waitMore(self: *Terminal, timeout_ms: i32) bool {
        var fds = [_]posix.pollfd{.{ .fd = self.in, .events = posix.POLL.IN, .revents = 0 }};
        const n = posix.poll(&fds, timeout_ms) catch return false;
        return n > 0 and (fds[0].revents & posix.POLL.IN) != 0;
    }
};

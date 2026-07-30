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
        @compileError("zedit's terminal layer is POSIX-only for now; Windows console support is not yet implemented");
    }
}

/// Set by the SIGWINCH handler, drained by the editor loop. Atomic because a
/// signal can fire between any two instructions of the main thread.
var resize_pending = std.atomic.Value(bool).init(false);

fn handleWinch(_: posix.SIG) callconv(.c) void {
    resize_pending.store(true, .release);
}

/// How many child descriptors the editor may wait on beside the keyboard:
/// a language server, an embedded terminal and a debug adapter.
pub const max_extra_fds = 3;

/// ANSI escape sequences. Grouped here so call sites read declaratively.
pub const ansi = struct {
    pub const enter_alt_screen = "\x1b[?1049h";
    pub const leave_alt_screen = "\x1b[?1049l";
    pub const enable_bracketed_paste = "\x1b[?2004h";
    pub const disable_bracketed_paste = "\x1b[?2004l";
    // Button events *plus* motion while a button is held (drag), SGR encoding.
    // 1002 is a strict superset of 1000 — press and release both still arrive —
    // so the two are never set together. 1003 (motion with no button down) is
    // deliberately not set: it would wake the editor on every pointer move,
    // where 1002 reports nothing at all while the mouse is idle.
    pub const enable_mouse = "\x1b[?1002h\x1b[?1006h";
    pub const disable_mouse = "\x1b[?1006l\x1b[?1002l";
    pub const clear_line_right = "\x1b[K";
    pub const cursor_home = "\x1b[H";
    pub const hide_cursor = "\x1b[?25l";
    pub const show_cursor = "\x1b[?25h";
    pub const reset_attrs = "\x1b[m";
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
    fn disableRaw(self: *Terminal) void {
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

    /// `mouse` is the config setting: false never asks the terminal to report,
    /// so the mouse stays entirely the terminal's (its own click-drag selection
    /// included) and no gesture reaches the editor.
    pub fn enterAltScreen(self: *Terminal, mouse: bool) Error!void {
        try self.write(ansi.enter_alt_screen);
        // Bracketed paste: terminal-pastes arrive fenced in \x1b[200~ ...
        // \x1b[201~ so they insert literally (crucial over SSH, where the
        // terminal's paste is the only clipboard route into the editor).
        try self.write(ansi.enable_bracketed_paste);
        // The wheel, clicks and drags. Any tracking mode makes the terminal
        // claim the button, so its own plain-drag selection is gone either
        // way; Shift+drag stays a total bypass and is how text is selected
        // for the terminal's clipboard.
        if (mouse) try self.write(ansi.enable_mouse);
        self.alt_active = true;
    }

    fn leaveAltScreen(self: *Terminal) void {
        if (!self.alt_active) return;
        self.write(ansi.disable_mouse) catch {};
        self.write(ansi.disable_bracketed_paste) catch {};
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

    /// Which descriptors became readable while blocked in `waitReady`.
    /// `input` is the keyboard; `others[i]` mirrors the i-th entry of the
    /// slice passed to `waitReady` (a null entry is always false).
    pub const Ready = struct { input: bool, others: [max_extra_fds]bool = .{false} ** max_extra_fds };

    /// Block (consuming no CPU) until stdin or `other` (e.g. a language server)
    /// is readable, or a signal fires. Both fields are false when interrupted —
    /// typically SIGWINCH — which the caller treats as "check for a resize".
    ///
    /// We call the raw poll syscall rather than `std.posix.poll`, because the
    /// latter silently retries on EINTR and so would never surface a resize
    /// that arrives while we are blocked. (A resize landing in the brief window
    /// between the resize check and entering poll is missed until the next key;
    /// closing that race needs a self-pipe and is left as future work.)
    /// Block until input (or `other`) is readable. `timeout_ms` of -1 blocks
    /// forever — the idle case, costing zero CPU; a non-negative value is used
    /// only while something is actually scheduled (the completion debounce).
    /// Block until the keyboard or one of `others` has something. The extras
    /// are the language server's stdout, an embedded terminal's pty and a
    /// debug adapter's stdout; a null entry costs nothing, so an editor with
    /// none of them running still blocks on just stdin at zero CPU.
    ///
    /// POLLHUP counts as ready: a child that exits leaves its pipe hung up
    /// rather than readable, and the loop must wake to notice rather than
    /// blocking for ever on something already dead.
    pub fn waitReady(self: *Terminal, others: []const ?posix.fd_t, timeout_ms: i32) Error!Ready {
        std.debug.assert(others.len <= max_extra_fds);
        var fds: [1 + max_extra_fds]posix.pollfd = undefined;
        var slot: [max_extra_fds]?usize = .{null} ** max_extra_fds;
        fds[0] = .{ .fd = self.in, .events = posix.POLL.IN, .revents = 0 };
        var n: posix.nfds_t = 1;
        for (others, 0..) |maybe, i| {
            const fd = maybe orelse continue;
            fds[n] = .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };
            slot[i] = n;
            n += 1;
        }
        const rc = posix.system.poll(&fds, n, timeout_ms);
        return switch (posix.system.errno(rc)) {
            .SUCCESS => blk: {
                var r = Ready{ .input = (fds[0].revents & posix.POLL.IN) != 0 };
                for (slot, 0..) |maybe, i| {
                    const at = maybe orelse continue;
                    r.others[i] = (fds[at].revents & (posix.POLL.IN | posix.POLL.HUP)) != 0;
                }
                break :blk r;
            },
            .INTR => .{ .input = false },
            else => |e| posix.unexpectedErrno(e),
        };
    }

    /// Read currently-available input into `buf`, returning the bytes read.
    /// Assumes data is ready (call after `waitReady`).
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

// === child pseudo-terminals =================================================
//
// The embedded terminal (`Space t`) runs a shell on its own pty: zedit is the
// terminal emulator for it, exactly as the outer terminal is for zedit. All
// of that is OS-specific, so it lives here rather than in `vt.zig`, which
// stays a pure state machine.

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1"); // posix_openpt / grantpt / ptsname
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/ioctl.h");
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
});

/// A child process on a pty: read its output from `fd`, write keys to it,
/// and reap it when it exits.
pub const Child = struct {
    fd: posix.fd_t,
    pid: posix.pid_t,
    /// Set once `reap` has seen it exit; the fd is closed at that point.
    exited: bool = false,
    /// The pty reported end-of-file (EIO on Linux): the child's side is gone
    /// even if it has not been reaped yet.
    hung_up: bool = false,

    /// Whatever the child has written, or an empty slice when nothing is
    /// ready. A closed pty (the shell exited) reads as empty and is noticed
    /// by `reap`.
    pub fn read(self: *Child, buf: []u8) []u8 {
        if (self.exited) return buf[0..0];
        const n = c.read(self.fd, buf.ptr, buf.len);
        // A pty master whose slave is gone reports EIO on Linux and a plain
        // end-of-file on macOS/the BSDs. Either way the fd would stay
        // permanently ready, so poll would return at once on every pass and
        // the editor would spin until the child became reapable — which is
        // the zero-idle-CPU promise broken. On Linux `waitpid` wins that race
        // in practice (the pty scenario cannot force the other order), so
        // this guard earns its place on the other platforms.
        if (n < 0) {
            if (posix.errno(n) == .IO) self.hung_up = true;
            return buf[0..0];
        }
        if (n == 0) self.hung_up = true;
        return buf[0..@intCast(n)];
    }

    pub fn write(self: *Child, bytes: []const u8) void {
        if (self.exited) return;
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(self.fd, bytes.ptr + off, bytes.len - off);
            if (n > 0) {
                off += @intCast(n);
                continue;
            }
            const err = posix.errno(n);
            if (err != .INTR) return; // EAGAIN on a full pty: drop, do not block the editor
        }
    }

    /// Tell the child its window changed, which is what makes a shell redraw
    /// its prompt at the new width (SIGWINCH is delivered by the kernel).
    pub fn resize(self: *Child, rows: u16, cols: u16) void {
        if (self.exited) return;
        var ws = c.winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
        _ = c.ioctl(self.fd, c.TIOCSWINSZ, &ws);
    }

    /// True the first time the child is found to have exited (non-blocking).
    /// The fd is closed here, so the poll loop stops waking on it.
    pub fn reap(self: *Child) bool {
        if (self.exited) return false;
        var status: c_int = 0;
        const done = c.waitpid(self.pid, &status, c.WNOHANG) == self.pid;
        // A hung-up pty counts as finished even before the child is reapable:
        // there is nothing more to read and nowhere to write, and leaving the
        // fd in the poll set would busy-loop.
        if (!done and !self.hung_up) return false;
        self.exited = true;
        _ = c.close(self.fd);
        return true;
    }

    /// Ask the child to go away, then reap it. SIGHUP is what a terminal
    /// sends when its window closes, so a shell exits cleanly.
    pub fn close(self: *Child) void {
        if (self.exited) return;
        _ = c.kill(self.pid, c.SIGHUP);
        var status: c_int = 0;
        _ = c.waitpid(self.pid, &status, c.WNOHANG);
        self.exited = true;
        _ = c.close(self.fd);
    }
};

pub const SpawnError = error{ OpenPt, GrantPt, Fork };

/// Run `argv` on a fresh pty of the given size. `argv` must be
/// null-terminated pointers; `cwd` is where the child starts.
pub fn spawnChild(argv: [*:null]const ?[*:0]const u8, cwd: ?[*:0]const u8, rows: u16, cols: u16) SpawnError!Child {
    const master = c.posix_openpt(c.O_RDWR | c.O_NOCTTY);
    if (master < 0) return error.OpenPt;
    if (c.grantpt(master) != 0 or c.unlockpt(master) != 0) {
        _ = c.close(master);
        return error.GrantPt;
    }
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(master);
        return error.Fork;
    }
    if (pid == 0) {
        // The child: give it the slave as its controlling terminal, then exec.
        _ = c.setsid();
        const slave = c.open(c.ptsname(master), c.O_RDWR);
        _ = c.ioctl(slave, c.TIOCSCTTY, @as(c_int, 0));
        _ = c.dup2(slave, 0);
        _ = c.dup2(slave, 1);
        _ = c.dup2(slave, 2);
        if (slave > 2) _ = c.close(slave);
        _ = c.close(master);
        // A terminal zedit can actually emulate. Claiming xterm-256color
        // would invite the alternate screen and mouse reporting, which
        // `vt.zig` does not implement.
        _ = c.setenv("TERM", "xterm", 1);
        if (cwd) |d| _ = c.chdir(d);
        _ = c.execvp(argv[0].?, @ptrCast(argv));
        c._exit(127);
    }
    var ws = c.winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
    _ = c.ioctl(master, c.TIOCSWINSZ, &ws);
    // Non-blocking, so a read with nothing ready returns instead of stalling
    // the editor's single-threaded loop.
    _ = c.fcntl(master, c.F_SETFL, c.O_NONBLOCK);
    return .{ .fd = master, .pid = pid };
}

/// The user's login shell, or `/bin/sh` when `$SHELL` says nothing.
pub fn userShell() [*:0]const u8 {
    if (std.c.getenv("SHELL")) |sh| {
        if (std.mem.sliceTo(sh, 0).len > 0) return sh;
    }
    return "/bin/sh";
}

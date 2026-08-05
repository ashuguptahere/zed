//! A pseudo-terminal test harness for driving `zedit` end-to-end.
//!
//! `Session.spawn` forks a child attached to a pty (so the editor sees a real
//! terminal), and exposes `send`/`drain` to push keystrokes and accumulate the
//! rendered output. Scenarios assert against the saved file or the captured
//! screen bytes. This is the Zig replacement for the old Python `tools/*.py`.

const std = @import("std");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1"); // expose posix_openpt/grantpt/ptsname/mkdtemp
    @cInclude("stdlib.h"); // posix_openpt, grantpt, unlockpt, ptsname, mkdtemp, setenv
    @cInclude("unistd.h"); // fork, setsid, dup2, execvp, chdir, read, write, close, sysconf
    @cInclude("fcntl.h"); // open, O_RDWR, O_NOCTTY
    @cInclude("sys/ioctl.h"); // ioctl, TIOCSCTTY, TIOCSWINSZ, struct winsize
    @cInclude("poll.h"); // poll, struct pollfd, POLLIN
    @cInclude("signal.h"); // kill
    @cInclude("sys/wait.h"); // waitpid
});

/// Shared run context: tool paths, the allocator/io, and the pass/fail tally.
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    zedit: []const u8, // path to the built zedit binary
    mock: []const u8, // path to the built mock_lsp binary
    mock_dap: []const u8 = "", // path to the built mock_dap binary
    passed: usize = 0,
    failed: usize = 0,
    /// Names of the checks that failed, reprinted at the end of the run. A CI
    /// log is usually read (and pasted) from its tail, where the per-check
    /// [FAIL] line has long scrolled away — so the summary has to carry it.
    failures: std.ArrayList([]const u8) = .empty,
    /// The suite currently running, so a failure names where to look.
    suite: []const u8 = "",
    /// Temp directories handed out by `tempDir`, removed when the suite ends.
    /// Every scenario used to carry three lines for this — make it, free the
    /// path, remove the tree — which was 200 lines of the test tree and one
    /// more thing to forget on an early return.
    temp_dirs: std.ArrayList([]const u8) = .empty,

    /// Like `check`, but a failure records `fmt` too — the got/want of an
    /// editing case, say. The detail rides along into the tail summary *and*
    /// the CI annotation, which is the only channel out of a runner whose log
    /// needs a token to read.
    fn checkFmt(self: *Ctx, name: []const u8, cond: bool, comptime fmt: []const u8, args: anytype) void {
        if (cond) return self.check(name, true);
        const detail = std.fmt.allocPrint(self.gpa, fmt, args) catch return self.check(name, false);
        defer self.gpa.free(detail);
        const full = std.fmt.allocPrint(self.gpa, "{s} [{s}]", .{ name, detail }) catch return self.check(name, false);
        defer self.gpa.free(full);
        self.check(full, false);
    }

    pub fn check(self: *Ctx, name: []const u8, cond: bool) void {
        if (cond) {
            self.passed += 1;
        } else {
            self.failed += 1;
            const label = std.fmt.allocPrint(self.gpa, "{s}: {s}", .{ self.suite, name }) catch name;
            self.failures.append(self.gpa, label) catch {};
        }
        std.debug.print("  [{s}] {s}\n", .{ if (cond) "PASS" else "FAIL", name });
    }

    pub fn deinit(self: *Ctx) void {
        for (self.failures.items) |f| self.gpa.free(f);
        self.dropTempDirs();
        self.temp_dirs.deinit(self.gpa);
        self.failures.deinit(self.gpa);
    }

    /// A temp directory that lives until the suite ends. The caller neither
    /// frees the path nor removes the tree.
    pub fn tempDir(self: *Ctx) ![]const u8 {
        const d = try makeTempDir(self.gpa);
        self.temp_dirs.append(self.gpa, d) catch {};
        return d;
    }

    /// Remove everything `tempDir` handed out. Called by the runner between
    /// suites, so one suite's directories cannot outlive it.
    pub fn dropTempDirs(self: *Ctx) void {
        for (self.temp_dirs.items) |d| {
            removeTree(self.gpa, self.io, d);
            self.gpa.free(d);
        }
        self.temp_dirs.clearRetainingCapacity();
    }
};

/// The screen as it stands after everything the session has emitted.
pub fn screenOf(ctx: *Ctx, s: *Session, rows: usize, cols: usize) !Screen {
    var scr = try Screen.init(ctx.gpa, rows, cols);
    scr.apply(s.out.items);
    return scr;
}

/// A screen rectangle, 1-based, for tests that locate chrome rather than
/// hardcoding where it was drawn.
pub const Rect = struct { x: usize, y: usize, w: usize, h: usize };

pub const SpawnOpts = struct {
    argv: []const []const u8, // full argv, including the program path
    cwd: ?[]const u8 = null,
    term: []const u8 = "xterm",
    cols: u16 = 80,
    /// Which keymap the session runs under, passed as `--keymap`. The
    /// shipped default is `vscode`, but almost every suite here is testing
    /// *vim* behaviour and says so by leaving this alone.
    ///
    /// `null` passes no flag at all, which is how a test checks what a user
    /// actually gets out of the box.
    keymap: ?[]const u8 = "vim",
    /// Spawn the way a job-control shell does: an intermediate process takes
    /// the session and the controlling terminal, then forks the editor into
    /// a process group of its own.
    ///
    /// Without that middle process the editor's group is *orphaned* — its
    /// only parent lives in another session — and POSIX requires a stop
    /// signal sent to an orphaned group to be discarded. `Ctrl-Z` then does
    /// nothing at all, and a test for it would pass with the `raise` deleted.
    job_control: bool = false,
};

pub const Session = struct {
    master: c_int,
    pid: c.pid_t,
    /// The session stub under job control, which owns `pid`; -1 otherwise.
    stub: c.pid_t = -1,
    out: std.ArrayList(u8),
    gpa: std.mem.Allocator,

    pub fn spawn(gpa: std.mem.Allocator, opts: SpawnOpts) !Session {
        // Almost every suite here is testing *vim* behaviour, and the shipped
        // default is `vscode`, so the harness says which keymap it means. A
        // flag rather than a config file: several suites bring a `--config`
        // of their own, and those must keep meaning vim too.
        //
        // It goes on the *end*: a third of the spawns here run the editor
        // under `env VAR=… zedit …`, so argv[0] is not always the program,
        // and zedit accepts its options in any position.
        var argv_buf: [64][]const u8 = undefined;
        var eff_argv = opts.argv;
        if (opts.keymap) |km| {
            if (opts.argv.len + 2 <= argv_buf.len) {
                for (opts.argv, 0..) |a, i| argv_buf[i] = a;
                argv_buf[opts.argv.len] = "--keymap";
                argv_buf[opts.argv.len + 1] = km;
                eff_argv = argv_buf[0 .. opts.argv.len + 2];
            }
        }

        // Build a null-terminated argv (+ duped TERM/cwd) in a scratch arena that
        // the parent frees right after fork; the child keeps its own copy.
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        const a = arena_state.allocator();
        const argv = try a.alloc(?[*:0]const u8, eff_argv.len + 1);
        for (eff_argv, 0..) |arg, i| argv[i] = (try a.dupeZ(u8, arg)).ptr;
        argv[eff_argv.len] = null;
        const term_z = try a.dupeZ(u8, opts.term);
        const cwd_z: ?[*:0]const u8 = if (opts.cwd) |cw| (try a.dupeZ(u8, cw)).ptr else null;

        const master = c.posix_openpt(c.O_RDWR | c.O_NOCTTY);
        if (master < 0) return error.OpenPt;
        if (c.grantpt(master) != 0 or c.unlockpt(master) != 0) return error.GrantPt;

        // Under job control the middle process reports the editor's real pid
        // back through a pipe, since the caller needs *that* one to watch and
        // signal — the process it forked is only the session stub.
        var pfd: [2]c_int = .{ -1, -1 };
        if (opts.job_control and c.pipe(&pfd) != 0) return error.Fork;

        const pid = c.fork();
        if (pid < 0) return error.Fork;
        if (pid == 0) {
            _ = c.setsid();
            const sname = c.ptsname(master);
            const slave = c.open(sname, c.O_RDWR);
            _ = c.ioctl(slave, c.TIOCSCTTY, @as(c_int, 0));
            if (opts.job_control) {
                _ = c.close(pfd[0]);
                // Fork again: the stub keeps the session, the grandchild gets
                // a process group of its own with the terminal handed to it,
                // which is exactly a shell starting a foreground job.
                const inner = c.fork();
                if (inner != 0) {
                    // The stub is the shell here: it puts the job in its own
                    // process group and hands it the terminal. `tcsetpgrp`
                    // from a process that is not the foreground group raises
                    // SIGTTOU at the caller, which is why every shell ignores
                    // it across this call — doing it in the child instead
                    // stopped the editor before it ever drew a frame.
                    _ = c.signal(c.SIGTTOU, c.SIG_IGN);
                    _ = c.setpgid(inner, inner);
                    _ = c.tcsetpgrp(slave, inner);
                    var w: c_int = @intCast(inner);
                    _ = c.write(pfd[1], &w, @sizeOf(c_int));
                    _ = c.close(pfd[1]);
                    var st: c_int = undefined;
                    while (c.waitpid(inner, &st, 0) < 0) {}
                    c._exit(0);
                }
                _ = c.close(pfd[1]);
                // Both sides set it, so neither races the other.
                _ = c.setpgid(0, 0);
            }
            _ = c.dup2(slave, 0);
            _ = c.dup2(slave, 1);
            _ = c.dup2(slave, 2);
            if (slave > 2) _ = c.close(slave);
            _ = c.close(master);
            _ = c.setenv("TERM", term_z, 1);
            if (cwd_z) |cw| _ = c.chdir(cw);
            _ = c.execvp(argv[0].?, @ptrCast(argv.ptr));
            c._exit(127);
        }

        var watch = pid;
        if (opts.job_control) {
            _ = c.close(pfd[1]);
            var got: c_int = 0;
            _ = c.read(pfd[0], &got, @sizeOf(c_int));
            _ = c.close(pfd[0]);
            if (got > 0) watch = got;
        }

        var ws = c.winsize{ .ws_row = 24, .ws_col = opts.cols, .ws_xpixel = 0, .ws_ypixel = 0 };
        _ = c.ioctl(master, c.TIOCSWINSZ, &ws);
        arena_state.deinit(); // child has its own copy of argv
        return .{ .master = master, .pid = watch, .stub = if (opts.job_control) pid else -1, .out = .empty, .gpa = gpa };
    }

    /// Write every byte, looping over short writes. A pty master can accept
    /// less than it was given when the slave has not drained yet, and the
    /// bursts here run to a couple of kilobytes — ignoring the return value
    /// silently dropped the tail of one, which is a dropped keystroke that
    /// looks like an editor bug on whichever machine happens to schedule it
    /// that way.
    pub fn send(self: *Session, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(self.master, bytes.ptr + off, bytes.len - off);
            if (n > 0) {
                off += @intCast(n);
                continue;
            }
            // EINTR/EAGAIN: give the reader a moment and try again. Anything
            // else (the child is gone) ends the write rather than spinning.
            const err = std.posix.errno(n);
            if (err != .INTR and err != .AGAIN) return;
            // Wait for the slave to make room, the same way `drain` waits for
            // output: poll rather than spin.
            var pfd = [_]c.pollfd{.{ .fd = self.master, .events = c.POLLOUT, .revents = 0 }};
            _ = c.poll(&pfd, 1, 50);
        }
    }

    /// Resize the pty, which sends the child a real SIGWINCH — the only way to
    /// exercise the resize path (re-tiling, a stale frame diff) end to end.
    pub fn resize(self: *Session, rows: u16, cols: u16) void {
        var ws = c.winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
        _ = c.ioctl(self.master, c.TIOCSWINSZ, &ws);
    }

    /// Read whatever the editor emits over `ms` milliseconds, appending it to
    /// `out`. Returns early if the child closes the pty.
    pub fn drain(self: *Session, ms: i64) void {
        var left = ms;
        while (left > 0) : (left -= 50) {
            var pfd = [_]c.pollfd{.{ .fd = self.master, .events = c.POLLIN, .revents = 0 }};
            if (c.poll(&pfd, 1, 50) > 0 and (pfd[0].revents & c.POLLIN) != 0) {
                var buf: [8192]u8 = undefined;
                const n = c.read(self.master, &buf, buf.len);
                if (n <= 0) return;
                self.out.appendSlice(self.gpa, buf[0..@intCast(n)]) catch {};
            }
        }
    }

    /// Send each chunk with a small gap, the way a person would type.
    pub fn sendKeys(self: *Session, chunks: []const []const u8) void {
        for (chunks) |ch| {
            self.send(ch);
            self.drain(90);
        }
    }

    /// Whether the editor is still running, and if not how it ended. A case
    /// that leaves its file untouched looks the same whether the editor
    /// crashed, hung, or was simply too slow to reach the keys before the
    /// harness killed it — this is what tells them apart, and it is the only
    /// way to ask the question from outside a CI runner.
    fn childState(self: *Session, buf: []u8) []const u8 {
        var st: c_int = 0;
        const r = c.waitpid(self.pid, &st, c.WNOHANG);
        if (r == 0) return "still running";
        if (r != self.pid) return "unknown";
        // WIFEXITED / WIFSIGNALED, spelled out: the macros are not exported
        // by translate-c.
        const low = st & 0x7f;
        if (low == 0) return std.fmt.bufPrint(buf, "exited {d}", .{(st >> 8) & 0xff}) catch "exited";
        return std.fmt.bufPrint(buf, "killed by signal {d}", .{low}) catch "signalled";
    }

    pub fn finish(self: *Session) void {
        _ = c.kill(self.pid, 9);
        var st: c_int = 0;
        _ = c.waitpid(self.pid, &st, 0);
        _ = c.close(self.master);
        self.out.deinit(self.gpa);
    }

    pub fn contains(self: *Session, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.out.items, needle) != null;
    }

    /// The output produced since `from` with escape sequences stripped (CSI
    /// skipped to its final letter, any other ESC plus its follow-up byte
    /// dropped) — for matching text that the renderer interleaves with colour.
    pub fn plainSince(self: *Session, gpa: std.mem.Allocator, from: usize) ![]u8 {
        var o: std.ArrayList(u8) = .empty;
        errdefer o.deinit(gpa);
        const s = self.out.items;
        var i: usize = @min(from, s.len);
        while (i < s.len) {
            if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
                i += 2;
                while (i < s.len and !std.ascii.isAlphabetic(s[i])) i += 1;
                if (i < s.len) i += 1; // the final letter
                continue;
            }
            if (s[i] == 0x1b) {
                i += 2;
                continue;
            }
            try o.append(gpa, s[i]);
            i += 1;
        }
        return o.toOwnedSlice(gpa);
    }

    /// The whole captured output, ANSI stripped.
    pub fn plain(self: *Session, gpa: std.mem.Allocator) ![]u8 {
        return self.plainSince(gpa, 0);
    }

    /// A mark into the output stream, for asserting on only what arrives next.
    pub fn mark(self: *Session) usize {
        return self.out.items.len;
    }

    /// Whether `needle` appears in the output produced since `from` (ANSI
    /// stripped) — lets a test assert on one frame instead of the whole
    /// session, e.g. that an indicator appears and then disappears.
    /// Raw bytes since `from` — for matching escape sequences themselves
    /// (a colour a theme emits), which the plain-text helpers strip out.
    pub fn containsSince(self: *Session, from: usize, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.out.items[@min(from, self.out.items.len)..], needle) != null;
    }

    pub fn containsPlainSince(self: *Session, gpa: std.mem.Allocator, from: usize, needle: []const u8) bool {
        const p = self.plainSince(gpa, from) catch return false;
        defer gpa.free(p);
        return std.mem.indexOf(u8, p, needle) != null;
    }

    pub fn containsPlain(self: *Session, gpa: std.mem.Allocator, needle: []const u8) bool {
        return self.containsPlainSince(gpa, 0, needle);
    }

    /// utime+stime in clock ticks, from /proc/<pid>/stat (Linux).
    /// The process state letter from `/proc/<pid>/stat` — `T` while stopped,
    /// which is how a suspend is checked for what it actually did rather
    /// than for what it printed on the way.
    pub fn procState(self: *Session) u8 {
        // Read it with open/read rather than `readFileAlloc`: a /proc file
        // reports a size of zero, and a reader that trusts that hands back
        // an empty buffer — which is what made the first version of this
        // report "no state" for a process that was stopped perfectly well.
        var pbuf: [64]u8 = undefined;
        const path = std.fmt.bufPrintZ(&pbuf, "/proc/{d}/stat", .{self.pid}) catch return 0;
        const fd = c.open(path.ptr, c.O_RDONLY);
        if (fd < 0) return 0;
        defer _ = c.close(fd);
        var buf: [512]u8 = undefined;
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) return 0;
        const data = buf[0..@intCast(n)];
        // The comm field is parenthesised and may hold spaces; the state is
        // the first token after its closing paren.
        const close_at = std.mem.lastIndexOfScalar(u8, data, ')') orelse return 0;
        var it = std.mem.tokenizeScalar(u8, data[close_at + 1 ..], ' ');
        const st = it.next() orelse return 0;
        return st[0];
    }

    /// Send a signal to the session's process (SIGCONT, to resume it).
    pub fn signal(self: *Session, sig: c_int) void {
        _ = c.kill(self.pid, sig);
    }

    pub fn cpuTicks(self: *Session, gpa: std.mem.Allocator, io: std.Io) !u64 {
        var pbuf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "/proc/{d}/stat", .{self.pid});
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 10));
        defer gpa.free(data);
        var it = std.mem.tokenizeScalar(u8, data, ' ');
        var idx: usize = 0;
        var total: u64 = 0;
        while (it.next()) |tok| : (idx += 1) {
            if (idx == 13 or idx == 14) total += std.fmt.parseInt(u64, tok, 10) catch 0;
        }
        return total;
    }
};

pub fn clockTicksPerSec() i64 {
    return c.sysconf(c._SC_CLK_TCK);
}

/// A tiny terminal model: applies captured output (cursor moves, SGR colours,
/// text) to a rows×cols grid, so scenarios can assert what ended up *where* —
/// e.g. that row 1 really shows the tabs beside the EXPLORER segment rather
/// than merely that both strings occurred somewhere in the byte stream.
/// Every codepoint is treated as one cell (fine for the ASCII + powerline
/// glyphs these tests look at); colours are the last-set 24-bit SGR values.
pub const Screen = struct {
    pub const default_color: u32 = 0xff000000; // sentinel: no explicit SGR
    pub const Cell = struct { cp: u21 = ' ', fg: u32 = default_color, bg: u32 = default_color };

    gpa: std.mem.Allocator,
    rows: usize,
    cols: usize,
    cells: []Cell,
    // Where the hardware cursor ended up after `apply` (1-based) — the last
    // position the editor's end-of-frame placement left it at.
    cur_row: usize = 1,
    cur_col: usize = 1,

    pub fn init(gpa: std.mem.Allocator, rows: usize, cols: usize) !Screen {
        const cells = try gpa.alloc(Cell, rows * cols);
        @memset(cells, .{});
        return .{ .gpa = gpa, .rows = rows, .cols = cols, .cells = cells };
    }

    pub fn deinit(self: *Screen) void {
        self.gpa.free(self.cells);
    }

    /// The cell at 1-based (row, col).
    pub fn at(self: *Screen, row: usize, col: usize) Cell {
        return self.cells[(row - 1) * self.cols + (col - 1)];
    }

    /// Row `row` decoded to UTF-8, trailing blanks trimmed (caller frees).
    /// Whether any row contains `needle`. The question every scenario asks of
    /// a screen, and four of them had written their own loop for it.
    pub fn has(self: *Screen, gpa: std.mem.Allocator, needle: []const u8) bool {
        var r: usize = 1;
        while (r <= self.rows) : (r += 1) {
            const t = self.rowText(gpa, r) catch return false;
            defer gpa.free(t);
            if (std.mem.indexOf(u8, t, needle) != null) return true;
        }
        return false;
    }

    pub fn rowText(self: *Screen, gpa: std.mem.Allocator, row: usize) ![]u8 {
        var o: std.ArrayList(u8) = .empty;
        errdefer o.deinit(gpa);
        var col: usize = 1;
        while (col <= self.cols) : (col += 1) {
            var b: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(self.at(row, col).cp, &b) catch continue;
            try o.appendSlice(gpa, b[0..n]);
        }
        while (o.items.len > 0 and o.items[o.items.len - 1] == ' ') o.items.len -= 1;
        return o.toOwnedSlice(gpa);
    }

    /// 1-based column where `needle` starts in `row`, or null.
    pub fn colOf(self: *Screen, gpa: std.mem.Allocator, row: usize, needle: []const u8) ?usize {
        const text = self.rowText(gpa, row) catch return null;
        defer gpa.free(text);
        const byte = std.mem.indexOf(u8, text, needle) orelse return null;
        // Bytes → cells: count the codepoints before the hit (1-based).
        return (std.unicode.utf8CountCodepoints(text[0..byte]) catch return null) + 1;
    }

    /// Feed captured pty output through the model.
    pub fn apply(self: *Screen, bytes: []const u8) void {
        var row: usize = 1;
        var col: usize = 1;
        defer {
            self.cur_row = row;
            self.cur_col = col;
        }
        var fg: u32 = default_color;
        var bg: u32 = default_color;
        var i: usize = 0;
        while (i < bytes.len) {
            const ch = bytes[i];
            if (ch == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '[') {
                const start = i + 2;
                var end = start;
                while (end < bytes.len and !std.ascii.isAlphabetic(bytes[end])) end += 1;
                if (end >= bytes.len) break;
                const params = bytes[start..end];
                switch (bytes[end]) {
                    'H', 'f' => {
                        var it = std.mem.splitScalar(u8, params, ';');
                        row = std.fmt.parseInt(usize, it.next() orelse "1", 10) catch 1;
                        col = std.fmt.parseInt(usize, it.next() orelse "1", 10) catch 1;
                        if (row < 1) row = 1;
                        if (col < 1) col = 1;
                    },
                    'm' => self.applySgr(params, &fg, &bg),
                    'J' => @memset(self.cells, .{}), // zedit only clears whole-screen
                    'K' => { // clear to end of line, in the current bg
                        var cc = col;
                        while (cc <= self.cols and row <= self.rows) : (cc += 1)
                            self.cells[(row - 1) * self.cols + (cc - 1)] = .{ .bg = bg };
                    },
                    else => {},
                }
                i = end + 1;
                continue;
            }
            if (ch == 0x1b) { // non-CSI escape: skip introducer + one byte
                i += 2;
                continue;
            }
            switch (ch) {
                '\r' => col = 1,
                '\n' => row += 1,
                8 => col -|= 1, // backspace
                else => {
                    if (ch < 0x20) {
                        i += 1;
                        continue;
                    }
                    const len = std.unicode.utf8ByteSequenceLength(ch) catch 1;
                    const end = @min(i + len, bytes.len);
                    const cp = std.unicode.utf8Decode(bytes[i..end]) catch '?';
                    if (row <= self.rows and col <= self.cols)
                        self.cells[(row - 1) * self.cols + (col - 1)] = .{ .cp = cp, .fg = fg, .bg = bg };
                    col += 1;
                    i = end;
                    continue;
                },
            }
            i += 1;
        }
    }

    fn applySgr(self: *Screen, params: []const u8, fg: *u32, bg: *u32) void {
        _ = self;
        var it = std.mem.splitScalar(u8, params, ';');
        while (it.next()) |tok| {
            // An empty parameter (e.g. the bare reset "\x1b[m") means 0.
            const n = if (tok.len == 0) 0 else std.fmt.parseInt(u32, tok, 10) catch continue;
            switch (n) {
                0 => {
                    fg.* = default_color;
                    bg.* = default_color;
                },
                38, 48 => {
                    // 38;2;r;g;b / 48;2;r;g;b
                    const two = it.next() orelse return;
                    if (!std.mem.eql(u8, two, "2")) return;
                    const r = std.fmt.parseInt(u32, it.next() orelse return, 10) catch return;
                    const g = std.fmt.parseInt(u32, it.next() orelse return, 10) catch return;
                    const b = std.fmt.parseInt(u32, it.next() orelse return, 10) catch return;
                    const packed_rgb = (r << 16) | (g << 8) | b;
                    if (n == 38) fg.* = packed_rgb else bg.* = packed_rgb;
                },
                39 => fg.* = default_color,
                49 => bg.* = default_color,
                else => {},
            }
        }
    }
};

/// 0xRRGGBB for Screen colour assertions.
pub fn rgb(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

// --- filesystem helpers (thin wrappers over std.Io) ------------------------

pub fn writeFile(io: std.Io, path: []const u8, data: []const u8) void {
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch {};
}

pub fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) []u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 << 20)) catch
        (gpa.dupe(u8, "") catch unreachable);
}

pub fn removeFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// A monotonic millisecond clock, for reporting how long each suite took.
pub fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.system.errno(std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// `dir/name` as one allocation (caller frees with `ctx.gpa`).
pub fn join(ctx: *Ctx, dir: []const u8, name: []const u8) []u8 {
    return std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ dir, name }) catch unreachable;
}

/// Run `argv` to completion, ignoring (but freeing) its output.
pub fn runQuiet(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) void {
    const res = std.process.run(gpa, io, .{ .argv = argv }) catch return;
    gpa.free(res.stdout);
    gpa.free(res.stderr);
}

/// Create a fresh temp directory and return its path (caller frees with `gpa`).
pub fn makeTempDir(gpa: std.mem.Allocator) ![]u8 {
    var tmpl = [_]u8{0} ** 32;
    const base = "/tmp/zedittestXXXXXX";
    @memcpy(tmpl[0..base.len], base);
    if (c.mkdtemp(&tmpl) == null) return error.Mkdtemp;
    return gpa.dupe(u8, std.mem.sliceTo(&tmpl, 0));
}

pub fn removeTree(gpa: std.mem.Allocator, io: std.Io, path: []const u8) void {
    runQuiet(gpa, io, &.{ "rm", "-rf", path });
}

/// Write `initial` to `target`, run `zedit target`, send `chunks`, then return the
/// saved file contents (caller frees). The workhorse for editing scenarios.
pub const EditRun = struct {
    /// The file as the editor left it.
    text: []u8,
    /// The tail of what the editor printed, ANSI stripped. Only looked at
    /// when a case fails — a panic message or an error statusline there is
    /// the difference between "indented wrongly" and "never ran", which is
    /// unknowable from the file alone.
    tail: []u8,

    pub fn deinit(self: *EditRun, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        gpa.free(self.tail);
    }
};

fn runEdit(ctx: *Ctx, target: []const u8, initial: []const u8, chunks: []const []const u8) EditRun {
    writeFile(ctx.io, target, initial);
    // `--lsp ""` starts no language server. Editing cases test motions,
    // operators and indent queries — not LSP — but opening a file otherwise
    // launches whatever server happens to be installed for its filetype, so
    // the result depended on the machine. That is precisely how the Rust
    // indent case passed on a workstation with no servers and hung on CI,
    // whose image ships rust-analyzer. Hermetic now: same answer everywhere.
    var s = Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--lsp", "", target } }) catch
        return .{
            .text = ctx.gpa.dupe(u8, "") catch unreachable,
            .tail = ctx.gpa.dupe(u8, "spawn failed") catch unreachable,
        };
    defer s.finish();
    s.drain(400); // first frame
    s.sendKeys(chunks);
    s.drain(600); // let :wq save and quit
    const plain = s.plain(ctx.gpa) catch (ctx.gpa.dupe(u8, "") catch unreachable);
    defer ctx.gpa.free(plain);
    const from = plain.len -| 200;
    var sb: [64]u8 = undefined;
    const state = s.childState(&sb);
    const tail = std.fmt.allocPrint(ctx.gpa, "[{s}] {s}", .{ state, plain[from..] }) catch
        (ctx.gpa.dupe(u8, state) catch unreachable);
    return .{
        .text = readFile(ctx.gpa, ctx.io, target),
        .tail = tail,
    };
}

/// One editing case: `runEdit` on `target`, then check the saved file equals
/// `want`, printing got/want on a failure.
pub fn case(ctx: *Ctx, target: []const u8, name: []const u8, chunks: []const []const u8, initial: []const u8, want: []const u8) void {
    var run = runEdit(ctx, target, initial, chunks);
    defer run.deinit(ctx.gpa);
    const got = run.text;
    const ok = std.mem.eql(u8, got, want);
    if (!ok) std.debug.print("       got  \"{f}\"\n       want \"{f}\"\n       screen …{s}\n", .{
        std.zig.fmtString(got), std.zig.fmtString(want), run.tail,
    });
    ctx.checkFmt(name, ok, "got \"{f}\" want \"{f}\" screen …{f}", .{
        std.zig.fmtString(got), std.zig.fmtString(want), std.zig.fmtString(run.tail),
    });
}

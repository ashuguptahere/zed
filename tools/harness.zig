//! A pseudo-terminal test harness for driving `zed` end-to-end.
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
    zed: []const u8, // path to the built zed binary
    mock: []const u8, // path to the built mock_lsp binary
    passed: usize = 0,
    failed: usize = 0,

    pub fn check(self: *Ctx, name: []const u8, cond: bool) void {
        if (cond) self.passed += 1 else self.failed += 1;
        std.debug.print("  [{s}] {s}\n", .{ if (cond) "PASS" else "FAIL", name });
    }
};

pub const SpawnOpts = struct {
    argv: []const []const u8, // full argv, including the program path
    cwd: ?[]const u8 = null,
    term: []const u8 = "xterm",
    rows: u16 = 24,
    cols: u16 = 80,
};

pub const Session = struct {
    master: c_int,
    pid: c.pid_t,
    out: std.ArrayList(u8),
    gpa: std.mem.Allocator,

    pub fn spawn(gpa: std.mem.Allocator, opts: SpawnOpts) !Session {
        // Build a null-terminated argv (+ duped TERM/cwd) in a scratch arena that
        // the parent frees right after fork; the child keeps its own copy.
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        const a = arena_state.allocator();
        const argv = try a.alloc(?[*:0]const u8, opts.argv.len + 1);
        for (opts.argv, 0..) |arg, i| argv[i] = (try a.dupeZ(u8, arg)).ptr;
        argv[opts.argv.len] = null;
        const term_z = try a.dupeZ(u8, opts.term);
        const cwd_z: ?[*:0]const u8 = if (opts.cwd) |cw| (try a.dupeZ(u8, cw)).ptr else null;

        const master = c.posix_openpt(c.O_RDWR | c.O_NOCTTY);
        if (master < 0) return error.OpenPt;
        if (c.grantpt(master) != 0 or c.unlockpt(master) != 0) return error.GrantPt;

        const pid = c.fork();
        if (pid < 0) return error.Fork;
        if (pid == 0) {
            _ = c.setsid();
            const sname = c.ptsname(master);
            const slave = c.open(sname, c.O_RDWR);
            _ = c.ioctl(slave, c.TIOCSCTTY, @as(c_int, 0));
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

        var ws = c.winsize{ .ws_row = opts.rows, .ws_col = opts.cols, .ws_xpixel = 0, .ws_ypixel = 0 };
        _ = c.ioctl(master, c.TIOCSWINSZ, &ws);
        arena_state.deinit(); // child has its own copy of argv/env
        return .{ .master = master, .pid = pid, .out = .empty, .gpa = gpa };
    }

    pub fn send(self: *Session, bytes: []const u8) void {
        _ = c.write(self.master, bytes.ptr, bytes.len);
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

    /// The captured output with CSI escape sequences (colour, cursor moves)
    /// stripped — for matching text that the renderer interleaves with colour.
    pub fn plain(self: *Session, gpa: std.mem.Allocator) ![]u8 {
        var o: std.ArrayList(u8) = .empty;
        errdefer o.deinit(gpa);
        const s = self.out.items;
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
                i += 2;
                while (i < s.len and !std.ascii.isAlphabetic(s[i])) i += 1;
                if (i < s.len) i += 1; // the final letter
                continue;
            }
            try o.append(gpa, s[i]);
            i += 1;
        }
        return o.toOwnedSlice(gpa);
    }

    pub fn containsPlain(self: *Session, gpa: std.mem.Allocator, needle: []const u8) bool {
        const p = self.plain(gpa) catch return false;
        defer gpa.free(p);
        return std.mem.indexOf(u8, p, needle) != null;
    }

    /// utime+stime in clock ticks, from /proc/<pid>/stat (Linux).
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

/// Create a fresh temp directory and return its path (caller frees with `gpa`).
pub fn tempDir(gpa: std.mem.Allocator) ![]u8 {
    var tmpl = [_]u8{0} ** 32;
    const base = "/tmp/zedtestXXXXXX";
    @memcpy(tmpl[0..base.len], base);
    if (c.mkdtemp(&tmpl) == null) return error.Mkdtemp;
    return gpa.dupe(u8, std.mem.sliceTo(&tmpl, 0));
}

pub fn removeTree(gpa: std.mem.Allocator, io: std.Io, path: []const u8) void {
    const res = std.process.run(gpa, io, .{ .argv = &.{ "rm", "-rf", path } }) catch return;
    gpa.free(res.stdout);
    gpa.free(res.stderr);
}

/// Write `initial` to `target`, run `zed target`, send `chunks`, then return the
/// saved file contents (caller frees). The workhorse for editing scenarios.
pub fn runEdit(ctx: *Ctx, target: []const u8, initial: []const u8, chunks: []const []const u8) []u8 {
    writeFile(ctx.io, target, initial);
    var s = Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zed, target } }) catch
        return ctx.gpa.dupe(u8, "") catch unreachable;
    defer s.finish();
    s.drain(400); // first frame
    s.sendKeys(chunks);
    s.drain(600); // let :wq save and quit
    return readFile(ctx.gpa, ctx.io, target);
}

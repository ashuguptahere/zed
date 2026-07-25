//! Editor benchmarks: zedit vs helix (hx) and neovim (nvim), driven through
//! real pseudo-terminals. Run with `zig build bench -Doptimize=ReleaseFast`
//! so zedit is measured as a release build like the others.
//!
//! Metrics (median over several runs):
//!   startup   spawn on a small file until output goes quiet (interactive)
//!   bigfile   the same, opening a ~10 MB / 200k-line file
//!   keypress  steady state, `j` sent, time until the first response byte
//!   picker    fuzzy-file-picker key until the redraw settles (zedit cold
//!             = includes the project walk; warm = the Zed-style cached open;
//!             helix re-walks each open; nvim has no built-in fuzzy picker)
//!   search    `/needle<CR>` for a unique needle near the end of the 10 MB
//!             file, keypress to settled redraw
//!
//! Fairness: nvim runs with `-u NONE -i NONE` and helix with an empty
//! XDG_CONFIG_HOME so nobody pays for user plugins/config; zedit runs its
//! defaults (it has no plugins by design). All editors see the same pty size.

const std = @import("std");
const h = @import("harness.zig");

const c = @cImport({
    @cInclude("poll.h");
    @cInclude("unistd.h");
});

const runs = 5;
const small_file = "/tmp/zedit_bench_small.txt";
const big_file = "/tmp/zedit_bench_big.txt";

const Editor = struct {
    name: []const u8,
    bin: []const u8, // the binary to existence-check
    argv_prefix: []const []const u8, // file path appended
    picker_key: ?[]const u8, // key(s) opening the fuzzy file picker
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len < 2) {
        std.debug.print("usage: bench <zedit-binary>\n", .{});
        std.process.exit(2);
    }
    const zedit = argv[1];

    // Fixture files.
    h.writeFile(io, small_file, "const a = 1;\nconst b = 2;\nconst c = 3;\n");
    {
        var big: std.ArrayList(u8) = .empty;
        defer big.deinit(gpa);
        var i: usize = 0;
        while (i < 200_000) : (i += 1) {
            var lb: [64]u8 = undefined;
            const line = std.fmt.bufPrint(&lb, "const value_{d} = {d}; // filler line\n", .{ i, i }) catch break;
            big.appendSlice(gpa, line) catch break;
        }
        h.writeFile(io, big_file, big.items);
    }

    // A private (mkdtemp) config home for helix, so the benchmark sees a
    // clean config and no other local user can pre-plant one.
    const xdg_dir = try h.tempDir(gpa);
    defer gpa.free(xdg_dir);
    defer h.removeTree(gpa, io, xdg_dir);
    const xdg_env = try std.fmt.allocPrint(gpa, "XDG_CONFIG_HOME={s}", .{xdg_dir});
    defer gpa.free(xdg_env);
    const helix_prefix = [_][]const u8{ "env", xdg_env, "hx" };

    const editors = [_]Editor{
        .{ .name = "zedit", .bin = zedit, .argv_prefix = &.{zedit}, .picker_key = " ff" },
        .{ .name = "helix", .bin = "hx", .argv_prefix = &helix_prefix, .picker_key = " f" },
        .{ .name = "nvim", .bin = "nvim", .argv_prefix = &.{ "nvim", "-u", "NONE", "-i", "NONE" }, .picker_key = null },
    };

    std.debug.print("\n{s:<8} {s:>12} {s:>12} {s:>12} {s:>12} {s:>12} {s:>14}\n", .{ "editor", "startup", "bigfile", "big-1stpaint", "keypress", "big-search", "picker-open" });
    std.debug.print("{s:-<8} {s:->12} {s:->12} {s:->12} {s:->12} {s:->12} {s:->14}\n", .{ "", "", "", "", "", "", "" });

    for (editors) |ed| {
        if (!binaryWorks(gpa, io, ed.bin)) {
            std.debug.print("{s:<8} {s:>12}\n", .{ ed.name, "(not found)" });
            continue;
        }
        const startup = median(measureStartup(gpa, ed, small_file, runs));
        const bigload = median(measureStartup(gpa, ed, big_file, 3));
        const bigpaint = median(measureFirstPaint(gpa, ed, big_file, 3));
        const keypress = median(measureKeypress(gpa, ed, runs));
        const bigsearch = median(measureSearch(gpa, ed, 3));
        std.debug.print("{s:<8} {d:>10.1}ms {d:>10.1}ms {d:>10.1}ms {d:>10.2}ms {d:>10.1}ms", .{ ed.name, startup, bigload, bigpaint, keypress, bigsearch });
        if (ed.picker_key) |pk| {
            const cold = measurePicker(gpa, ed, pk, false);
            std.debug.print(" {d:>8.1}ms cold", .{cold});
            if (std.mem.eql(u8, ed.name, "zedit")) {
                const warm = measurePicker(gpa, ed, pk, true);
                std.debug.print(" / {d:.1}ms warm", .{warm});
            }
        } else {
            std.debug.print(" {s:>13}", .{"(no builtin)"});
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("\n(median of {d} runs; pty 24x80; helix/nvim with clean configs)\n", .{runs});
}

fn binaryWorks(gpa: std.mem.Allocator, io: std.Io, bin: []const u8) bool {
    // Spawn directly (argv array, no shell): resolves via PATH exactly like
    // the benchmark runs themselves, and shell metacharacters stay inert.
    const res = std.process.run(gpa, io, .{ .argv = &.{ bin, "--version" } }) catch return false;
    gpa.free(res.stdout);
    gpa.free(res.stderr);
    return switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Spawn on `file`, measure until the output goes quiet (interactive).
fn measureStartup(gpa: std.mem.Allocator, ed: Editor, file: []const u8, n: usize) []f64 {
    var out: std.ArrayList(f64) = .empty;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var s = spawnOn(gpa, ed, file) orelse break;
        defer quitAndFinish(&s, ed);
        const t0 = nowNs();
        _ = waitQuiet(&s, 80, 8000);
        out.append(gpa, msBetween(t0, nowNs()) - 80.0) catch break;
    }
    return out.toOwnedSlice(gpa) catch &.{};
}

/// Time until the editor puts *something* on screen — what a user actually
/// waits for. Reported next to the settled time because an editor that paints
/// the text immediately and decorates it a frame later (zedit does: syntax,
/// git signs and diagnostics arrive after the first frame) is quick to appear
/// even when it settles no sooner.
fn measureFirstPaint(gpa: std.mem.Allocator, ed: Editor, file: []const u8, n: usize) []f64 {
    var out: std.ArrayList(f64) = .empty;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var s = spawnOn(gpa, ed, file) orelse break;
        defer quitAndFinish(&s, ed);
        if (firstByteMs(&s, 8000)) |ms| out.append(gpa, ms) catch break;
        _ = waitQuiet(&s, 50, 4000);
    }
    return out.toOwnedSlice(gpa) catch &.{};
}

/// Steady state, then time `j` to the first response byte, several times.
fn measureKeypress(gpa: std.mem.Allocator, ed: Editor, n: usize) []f64 {
    var out: std.ArrayList(f64) = .empty;
    var s = spawnOn(gpa, ed, small_file) orelse return out.toOwnedSlice(gpa) catch &.{};
    defer quitAndFinish(&s, ed);
    _ = waitQuiet(&s, 80, 8000);
    var i: usize = 0;
    while (i < n * 4) : (i += 1) {
        const key: []const u8 = if (i % 2 == 0) "j" else "k";
        s.send(key);
        if (firstByteMs(&s, 1000)) |ms| out.append(gpa, ms) catch break;
        _ = waitQuiet(&s, 30, 500);
    }
    return out.toOwnedSlice(gpa) catch &.{};
}

/// Search for a unique needle near the end of the big file: `/needle<CR>`,
/// keypress until the redraw settles.
fn measureSearch(gpa: std.mem.Allocator, ed: Editor, n: usize) []f64 {
    var out: std.ArrayList(f64) = .empty;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var s = spawnOn(gpa, ed, big_file) orelse break;
        defer quitAndFinish(&s, ed);
        _ = waitQuiet(&s, 80, 8000);
        const t0 = nowNs();
        s.send("/value_199999\r");
        _ = waitQuiet(&s, 80, 8000);
        out.append(gpa, msBetween(t0, nowNs()) - 80.0) catch break;
    }
    return out.toOwnedSlice(gpa) catch &.{};
}

/// Time from the picker key until the redraw settles. `warm` opens the picker
/// once first (so zedit's cached walk is measured on the second open).
fn measurePicker(gpa: std.mem.Allocator, ed: Editor, picker_key: []const u8, warm: bool) f64 {
    var s = spawnOn(gpa, ed, "build.zig") orelse return -1;
    defer quitAndFinish(&s, ed);
    _ = waitQuiet(&s, 80, 8000);
    if (warm) {
        s.send(picker_key);
        _ = waitQuiet(&s, 80, 8000);
        s.send("\x1b"); // close it again
        _ = waitQuiet(&s, 80, 2000);
    }
    const t0 = nowNs();
    s.send(picker_key);
    _ = waitQuiet(&s, 80, 8000);
    const ms = msBetween(t0, nowNs()) - 80.0;
    s.send("\x1b");
    _ = waitQuiet(&s, 50, 1000);
    return ms;
}

fn spawnOn(gpa: std.mem.Allocator, ed: Editor, file: []const u8) ?h.Session {
    var argv_buf: [8][]const u8 = undefined;
    for (ed.argv_prefix, 0..) |a, i| argv_buf[i] = a;
    argv_buf[ed.argv_prefix.len] = file;
    return h.Session.spawn(gpa, .{
        .argv = argv_buf[0 .. ed.argv_prefix.len + 1],
        .term = "xterm-256color",
    }) catch null;
}

fn quitAndFinish(s: *h.Session, ed: Editor) void {
    // Best-effort clean quit so no editor lingers holding the pty.
    s.send("\x1b\x1b");
    if (std.mem.eql(u8, ed.name, "helix")) s.send(":q!\r") else s.send(":q!\r");
    s.drain(150);
    s.finish();
}

/// Wait until no bytes arrive for `quiet_ms` (or `cap_ms` total), 1ms polls.
fn waitQuiet(s: *h.Session, quiet_ms: i64, cap_ms: i64) bool {
    var since_data: i64 = 0;
    var total: i64 = 0;
    while (total < cap_ms) {
        if (readAvailable(s, 1)) since_data = 0 else since_data += 1;
        total += 1;
        if (since_data >= quiet_ms) return true;
    }
    return false;
}

/// Time in ms until the first byte arrives (1ms polls), or null on timeout.
fn firstByteMs(s: *h.Session, cap_ms: i64) ?f64 {
    const t0 = nowNs();
    var total: i64 = 0;
    while (total < cap_ms) : (total += 1) {
        if (readAvailable(s, 1)) return msBetween(t0, nowNs());
    }
    return null;
}

fn readAvailable(s: *h.Session, timeout_ms: i32) bool {
    var pfd = [_]c.pollfd{.{ .fd = s.master, .events = c.POLLIN, .revents = 0 }};
    if (c.poll(&pfd, 1, timeout_ms) > 0 and (pfd[0].revents & c.POLLIN) != 0) {
        var buf: [16384]u8 = undefined;
        const n = c.read(s.master, &buf, buf.len);
        return n > 0;
    }
    return false;
}

fn nowNs() u64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.system.errno(std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn msBetween(t0: u64, t1: u64) f64 {
    return @as(f64, @floatFromInt(t1 -| t0)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}

fn median(vals: []f64) f64 {
    if (vals.len == 0) return -1;
    std.mem.sort(f64, vals, {}, std.sort.asc(f64));
    return vals[vals.len / 2];
}

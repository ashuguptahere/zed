//! Integration-test runner: drives the built `zedit` through a pty (and a mock
//! language server) to verify the interactive behaviour that unit tests can't.
//! Run with `zig build itest`, which passes the zedit and mock_lsp binary paths.

const std = @import("std");
const h = @import("harness.zig");

const scenarios = .{
    .{ "vim", @import("scenarios/vim.zig") },
    .{ "vim_compat", @import("scenarios/vim_compat.zig") },
    .{ "feature", @import("scenarios/feature.zig") },
    .{ "multicursor", @import("scenarios/multicursor.zig") },
    .{ "extra", @import("scenarios/extra.zig") },
    .{ "search", @import("scenarios/search.zig") },
    .{ "treesitter", @import("scenarios/treesitter.zig") },
    .{ "indent", @import("scenarios/indent.zig") },
    .{ "picker", @import("scenarios/picker.zig") },
    .{ "git", @import("scenarios/git.zig") },
    .{ "windows", @import("scenarios/windows.zig") },
    .{ "sidebar", @import("scenarios/sidebar.zig") },
    .{ "mouse", @import("scenarios/mouse.zig") },
    .{ "titlebar", @import("scenarios/titlebar.zig") },
    .{ "config", @import("scenarios/configtheme.zig") },
    .{ "cmdline", @import("scenarios/cmdline.zig") },
    .{ "robust", @import("scenarios/robust.zig") },
    .{ "remote", @import("scenarios/remote.zig") },
    .{ "ssh", @import("scenarios/ssh.zig") },
    .{ "lsp", @import("scenarios/lsp.zig") },
    .{ "bufcomplete", @import("scenarios/bufcomplete.zig") },
    .{ "cpu", @import("scenarios/cpu.zig") },
    .{ "wrap", @import("scenarios/wrap.zig") },
    .{ "undotree", @import("scenarios/undotree.zig") },
    .{ "session", @import("scenarios/session.zig") },
    .{ "terminal", @import("scenarios/terminal.zig") },
    .{ "debug", @import("scenarios/debug.zig") },
    .{ "quickfix", @import("scenarios/quickfix.zig") },
    .{ "fold", @import("scenarios/fold.zig") },
    .{ "view", @import("scenarios/view.zig") },
    .{ "ex", @import("scenarios/ex.zig") },
    .{ "keymap", @import("scenarios/keymap.zig") },
    .{ "palette", @import("scenarios/palette.zig") },
};

/// Whether suite `name` was asked for: everything when no filter was given.
fn wanted(only: []const []const u8, name: []const u8) bool {
    if (only.len == 0) return true;
    for (only) |o| {
        if (std.mem.eql(u8, o, name)) return true;
    }
    return false;
}

/// Every suite name, for the parallel driver.
const suite_names = blk: {
    var names: [scenarios.len][]const u8 = undefined;
    for (scenarios, 0..) |s, i| names[i] = s[0];
    break :blk names;
};

/// One suite farmed out to a child process.
const Job = struct {
    name: []const u8,
    child: ?std.process.Child = null,
    out: std.ArrayList(u8) = .empty,
    done: bool = false,
    passed: usize = 0,
    failed: usize = 0,
};

/// Run every suite as its own process, several at a time.
///
/// The suites are independent — each owns its own `/tmp/zedit_it_*` files, so
/// no two touch the same path — and the run was strictly serial: 27 suites,
/// 1216 checks, twelve minutes, on a machine with cores to spare. The cost is
/// not sleeping (a `drain` gives its budget back as soon as output flows) but
/// process startup: `vim_compat` alone spawns 283 editors.
///
/// A child is just this binary with a suite name, so the serial path below is
/// still what actually runs a suite — this only decides how many at once.
fn runParallel(gpa: std.mem.Allocator, io: std.Io, self_exe: []const u8, zedit: []const u8, mock: []const u8, mock_dap: []const u8) !u8 {
    const cap = @min(@as(usize, 12), suite_names.len);
    var jobs: [suite_names.len]Job = undefined;
    for (&jobs, suite_names) |*j, name| j.* = .{ .name = name };

    var next: usize = 0;
    var live: usize = 0;
    var finished: usize = 0;
    const began = h.nowMs();

    while (finished < jobs.len) {
        // Top up to the cap.
        while (live < cap and next < jobs.len) : (next += 1) {
            const j = &jobs[next];
            j.child = std.process.spawn(io, .{
                .argv = &.{ self_exe, zedit, mock, mock_dap, j.name },
                .stdout = .pipe,
                .stderr = .pipe,
            }) catch {
                j.done = true;
                finished += 1;
                std.debug.print("!!! {s}: could not spawn a runner\n", .{j.name});
                continue;
            };
            live += 1;
        }
        // Wait for output from any of them.
        var fds: [suite_names.len]std.posix.pollfd = undefined;
        var idx: [suite_names.len]usize = undefined;
        var n: usize = 0;
        for (&jobs, 0..) |*j, i| {
            const ch = j.child orelse continue;
            if (j.done) continue;
            // Everything the runner prints goes through `std.debug.print`,
            // which writes to *stderr* — that is the pipe to watch.
            fds[n] = .{ .fd = ch.stderr.?.handle, .events = std.posix.POLL.IN, .revents = 0 };
            idx[n] = i;
            n += 1;
        }
        if (n == 0) break;
        _ = std.posix.poll(fds[0..n], 200) catch 0;
        for (fds[0..n], idx[0..n]) |pfd, i| {
            if ((pfd.revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) == 0) continue;
            const j = &jobs[i];
            var buf: [16384]u8 = undefined;
            const got = std.posix.read(pfd.fd, &buf) catch 0;
            if (got > 0) {
                j.out.appendSlice(gpa, buf[0..got]) catch {};
                continue;
            }
            // End of output: the suite is over. Report it as it lands, so a
            // long run shows progress rather than twelve silent minutes.
            j.done = true;
            live -= 1;
            finished += 1;
            var ch = j.child.?;
            _ = ch.wait(io) catch {};
            tally(j);
            std.debug.print("{s}", .{j.out.items});
        }
    }

    var passed: usize = 0;
    var failed: usize = 0;
    for (&jobs) |*j| {
        passed += j.passed;
        failed += j.failed;
    }
    const took = h.nowMs() - began;
    std.debug.print("\n{d} passed, {d} failed in {d}.{d:0>3} s ({d} suites, {d} at a time)\n", .{
        passed, failed, @divTrunc(took, 1000), @mod(took, 1000), jobs.len, cap,
    });
    if (failed == 0) return 0;
    // Re-print every failure at the very tail: with suites interleaved, a
    // child's own summary is buried far above.
    std.debug.print("failed checks:\n", .{});
    for (&jobs) |*j| emitFailures(j.out.items);
    return 1;
}

/// Read a child's `N passed, M failed` line into the job.
fn tally(j: *Job) void {
    var it = std.mem.splitScalar(u8, j.out.items, '\n');
    while (it.next()) |line| {
        const at = std.mem.indexOf(u8, line, " passed, ") orelse continue;
        j.passed = std.fmt.parseInt(usize, std.mem.trim(u8, line[0..at], " "), 10) catch continue;
        const rest = line[at + " passed, ".len ..];
        const end = std.mem.indexOf(u8, rest, " failed") orelse continue;
        j.failed = std.fmt.parseInt(usize, rest[0..end], 10) catch 0;
    }
}

/// Forward a child's `  - suite: check` lines, and their CI annotations.
fn emitFailures(out: []const u8) void {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "  - ")) continue;
        // Only the name: the child already emitted its own `::error::` when
        // running under Actions, and its output was printed verbatim above —
        // emitting again put every failure in the annotations twice.
        std.debug.print("{s}\n", .{line});
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 4) {
        std.debug.print("usage: itest <zedit> <mock_lsp> <mock_dap> [suite...]\n", .{});
        std.process.exit(2);
    }
    // `zig build itest -- sidebar git` runs just those suites: the full run is
    // over ten minutes, which is too slow a loop for one scenario under repair.
    const only = argv[4..];
    // The build passes relative artifact paths; make them absolute so scenarios
    // that chdir into a temp dir can still exec the binaries.
    const cwd = try std.process.currentPathAlloc(init.io, arena);
    var ctx = h.Ctx{
        .gpa = init.gpa,
        .io = init.io,
        .zedit = try std.fs.path.resolve(arena, &.{ cwd, argv[1] }),
        .mock = try std.fs.path.resolve(arena, &.{ cwd, argv[2] }),
        .mock_dap = try std.fs.path.resolve(arena, &.{ cwd, argv[3] }),
    };

    // No filter: farm the suites out to child processes, several at a time.
    // A child always has a filter, so it takes the serial path below.
    if (only.len == 0) {
        const self_exe = try std.fs.path.resolve(arena, &.{ cwd, argv[0] });
        std.process.exit(try runParallel(init.gpa, init.io, self_exe, ctx.zedit, ctx.mock, ctx.mock_dap));
    }

    var before: usize = 0;
    var total_ms: i64 = 0;
    inline for (scenarios) |s| {
        if (wanted(only, s[0])) {
            std.debug.print("=== {s} ===\n", .{s[0]});
            ctx.suite = s[0];
            const began = h.nowMs();
            try s[1].run(&ctx);
            ctx.dropTempDirs();
            const took = h.nowMs() - began;
            std.debug.print("--- {s}: {d} checks in {d} ms\n", .{ s[0], ctx.passed + ctx.failed - before, took });
            before = ctx.passed + ctx.failed;
            total_ms += took;
        }
    }

    std.debug.print("\n{d} passed, {d} failed in {d}.{d:0>3} s\n", .{
        ctx.passed, ctx.failed, @divTrunc(total_ms, 1000), @mod(total_ms, 1000),
    });
    if (ctx.failed > 0) {
        // Name them again at the tail: a CI log is read from the bottom, and
        // "1 failed" without a name is a bug report nobody can act on.
        std.debug.print("failed checks:\n", .{});
        for (ctx.failures.items) |f| std.debug.print("  - {s}\n", .{f});
        // On GitHub Actions, also emit them as workflow errors. Those become
        // check annotations, which the API serves for a public repository
        // *without* a token — where the log body needs one. So a failure can
        // be diagnosed from outside the runner, which is exactly the problem
        // that made the first CI-only failure take days to name.
        if (std.c.getenv("GITHUB_ACTIONS") != null) {
            for (ctx.failures.items) |f| std.debug.print("::error title=itest::{s}\n", .{f});
        }
        std.process.exit(1);
    }
    ctx.deinit();
}

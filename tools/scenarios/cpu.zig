//! Idle-CPU and profiling-log end-to-end: confirm zed burns no CPU while idle
//! and writes profiling lines to its log. Port of tools/cpu_test.py.

const std = @import("std");
const h = @import("../harness.zig");

const target = "/tmp/zed_it_cpu.txt";
const logpath = "/tmp/zed_it_cpu.log";

pub fn run(ctx: *h.Ctx) !void {
    h.writeFile(ctx.io, target, "line\n" ** 50);
    h.removeFile(ctx.io, logpath);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zed, "--log", logpath, target } });
    defer s.finish();

    s.drain(500); // let it draw the first frame

    // A few keystrokes so there is something to profile.
    for ([_][]const u8{ "j", "j", "l", "k" }) |k| {
        s.send(k);
        s.drain(100);
    }

    const t0 = try s.cpuTicks(ctx.gpa, ctx.io);
    s.drain(3000); // sit idle for 3s
    const t1 = try s.cpuTicks(ctx.gpa, ctx.io);

    const idle_ms = @as(f64, @floatFromInt(t1 - t0)) /
        @as(f64, @floatFromInt(h.clockTicksPerSec())) * 1000.0;

    s.send(":q!\r");
    s.drain(500);

    std.debug.print("  CPU time over 3s idle: {d:.1} ms\n", .{idle_ms});
    ctx.check("idle CPU is negligible (<50ms over 3s)", idle_ms < 50.0);

    const log = h.readFile(ctx.gpa, ctx.io, logpath);
    defer ctx.gpa.free(log);
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "profile") != null) count += 1;
    }
    ctx.check("profiling lines written to log", count > 0);
}

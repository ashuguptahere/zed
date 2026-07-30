//! A stub debug adapter for the `debug` scenario, so the suite needs no
//! lldb-dap/debugpy installed anywhere.
//!
//! It speaks just enough DAP to drive the editor's side: it answers
//! `initialize` and sends `initialized`, accepts `setBreakpoints` and
//! `launch`, and on `configurationDone` reports a `stopped` event at the
//! first breakpoint it was given. Each `next`/`stepIn`/`stepOut` stops one
//! line further on; `continue` runs to the end and `terminated`s. The source
//! path it reports is the one the breakpoints came in on, so the editor's
//! "jump to where it stopped" really has a file to open.

const std = @import("std");

var out_buf: [4096]u8 = undefined;

fn send(io: std.Io, body: []const u8) void {
    const stdout = std.Io.File.stdout();
    var hdr: [64]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return;
    stdout.writeStreamingAll(io, h) catch {};
    stdout.writeStreamingAll(io, body) catch {};
}

fn sendFmt(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    send(io, std.fmt.bufPrint(&out_buf, fmt, args) catch return);
}

fn stopped(io: std.Io, reason: []const u8) void {
    sendFmt(io,
        \\{{"type":"event","event":"stopped","body":{{"reason":"{s}","threadId":1,"allThreadsStopped":true}}}}
    , .{reason});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const stdin = std.Io.File.stdin();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var path: std.ArrayList(u8) = .empty; // the source the breakpoints named
    defer path.deinit(gpa);
    var line: usize = 0;
    var consumed: usize = 0;

    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(stdin.handle, &chunk) catch break;
        if (n == 0) break;
        try buf.appendSlice(gpa, chunk[0..n]);

        while (true) {
            const b = buf.items[consumed..];
            const sep = std.mem.indexOf(u8, b, "\r\n\r\n") orelse break;
            const tag = "Content-Length:";
            const at = std.mem.indexOf(u8, b[0..sep], tag) orelse {
                consumed += sep + 4;
                continue;
            };
            const rest = b[at + tag.len .. sep];
            const end = std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
            const len = std.fmt.parseInt(usize, std.mem.trim(u8, rest[0..end], " \t"), 10) catch {
                consumed += sep + 4;
                continue;
            };
            if (b.len < sep + 4 + len) break; // the body is still arriving
            const body = b[sep + 4 .. sep + 4 + len];
            consumed += sep + 4 + len;

            const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const cmd = blk: {
                const v = parsed.value.object.get("command") orelse break :blk "";
                break :blk if (v == .string) v.string else "";
            };

            if (std.mem.eql(u8, cmd, "initialize")) {
                send(io,
                    \\{"type":"response","request_seq":1,"success":true,"command":"initialize","body":{"supportsConfigurationDoneRequest":true}}
                );
                send(io, "{\"type\":\"event\",\"event\":\"initialized\"}");
            } else if (std.mem.eql(u8, cmd, "setBreakpoints")) {
                // Remember where, so `stackTrace` can report a real file.
                const args = parsed.value.object.get("arguments") orelse continue;
                if (args != .object) continue;
                if (args.object.get("source")) |src| {
                    if (src == .object) {
                        if (src.object.get("path")) |p| {
                            if (p == .string) {
                                path.clearRetainingCapacity();
                                path.appendSlice(gpa, p.string) catch {};
                            }
                        }
                    }
                }
                if (args.object.get("breakpoints")) |bps| {
                    if (bps == .array and bps.array.items.len > 0) {
                        const first = bps.array.items[0];
                        if (first == .object) {
                            if (first.object.get("line")) |l| {
                                if (l == .integer) line = @intCast(l.integer);
                            }
                        }
                    }
                }
                send(io, "{\"type\":\"response\",\"success\":true,\"command\":\"setBreakpoints\",\"body\":{\"breakpoints\":[]}}");
            } else if (std.mem.eql(u8, cmd, "launch")) {
                send(io, "{\"type\":\"response\",\"success\":true,\"command\":\"launch\"}");
            } else if (std.mem.eql(u8, cmd, "configurationDone")) {
                send(io, "{\"type\":\"response\",\"success\":true,\"command\":\"configurationDone\"}");
                if (line == 0) line = 1;
                stopped(io, "breakpoint");
            } else if (std.mem.eql(u8, cmd, "stackTrace")) {
                sendFmt(io,
                    \\{{"type":"response","success":true,"command":"stackTrace","body":{{"stackFrames":[{{"id":1,"name":"main","line":{d},"column":1,"source":{{"path":"{s}"}}}}],"totalFrames":1}}}}
                , .{ line, path.items });
            } else if (std.mem.eql(u8, cmd, "next") or std.mem.eql(u8, cmd, "stepIn") or
                std.mem.eql(u8, cmd, "stepOut"))
            {
                sendFmt(io, "{{\"type\":\"response\",\"success\":true,\"command\":\"{s}\"}}", .{cmd});
                line += 1; // one line further on each step
                stopped(io, "step");
            } else if (std.mem.eql(u8, cmd, "continue")) {
                send(io, "{\"type\":\"response\",\"success\":true,\"command\":\"continue\"}");
                send(io, "{\"type\":\"event\",\"event\":\"output\",\"body\":{\"category\":\"stdout\",\"output\":\"program finished\\n\"}}");
                send(io, "{\"type\":\"event\",\"event\":\"terminated\"}");
            } else if (std.mem.eql(u8, cmd, "disconnect")) {
                send(io, "{\"type\":\"response\",\"success\":true,\"command\":\"disconnect\"}");
                return;
            }
        }
        if (consumed > 0) {
            buf.replaceRange(gpa, 0, consumed, &.{}) catch {};
            consumed = 0;
        }
    }
}

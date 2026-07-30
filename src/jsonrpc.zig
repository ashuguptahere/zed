//! The `Content-Length`-framed JSON transport that both the Language Server
//! Protocol and the Debug Adapter Protocol speak over a child's stdio.
//!
//! Only the framing lives here — headers in, message bodies out — because
//! that is the whole of what the two protocols share; what a message *means*
//! belongs to `lsp.zig` and `dap.zig`. Control is inverted (`nextFrame`
//! rather than a callback) so a caller stays an ordinary loop.

const std = @import("std");
const posix = std.posix;

pub const Transport = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    out_fd: posix.fd_t,
    stdin: std.Io.File,
    /// False once the child's pipe has failed or closed: every later write is
    /// dropped rather than posting into a dead process.
    alive: bool = true,
    buf: std.ArrayList(u8) = .empty,
    /// Bytes of the frame handed out by the last `nextFrame`, dropped at the
    /// start of the next call — so the body stays valid while the caller uses
    /// it, with no allocation per message.
    consumed: usize = 0,

    pub fn deinit(self: *Transport) void {
        self.buf.deinit(self.gpa);
    }

    pub fn write(self: *Transport, body: []const u8) void {
        if (!self.alive) return;
        var hdr: [64]u8 = undefined;
        const h = std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return;
        self.stdin.writeStreamingAll(self.io, h) catch {
            self.alive = false;
            return;
        };
        self.stdin.writeStreamingAll(self.io, body) catch {
            self.alive = false;
        };
    }

    /// Read whatever the child has written. Call when its stdout is readable.
    pub fn readAvailable(self: *Transport) void {
        var tmp: [4096]u8 = undefined;
        const n = posix.read(self.out_fd, &tmp) catch {
            self.alive = false;
            return;
        };
        if (n == 0) {
            self.alive = false; // the child closed its stdout
            return;
        }
        self.buf.appendSlice(self.gpa, tmp[0..n]) catch return;
    }

    /// The next complete message body, or null when one has not fully
    /// arrived. The returned slice is valid until the following call.
    pub fn nextFrame(self: *Transport) ?[]const u8 {
        if (self.consumed > 0) {
            self.buf.replaceRange(self.gpa, 0, self.consumed, &.{}) catch return null;
            self.consumed = 0;
        }
        while (true) {
            const b = self.buf.items;
            const sep = std.mem.indexOf(u8, b, "\r\n\r\n") orelse return null;
            const len = contentLength(b[0..sep]) orelse {
                // An unparseable header: drop it and look for the next one
                // rather than stalling on bytes that will never frame.
                self.buf.replaceRange(self.gpa, 0, sep + 4, &.{}) catch return null;
                continue;
            };
            const total = sep + 4 + len;
            if (b.len < total) return null; // the body is still arriving
            self.consumed = total;
            return self.buf.items[sep + 4 .. total];
        }
    }

    /// Block up to `timeout_ms` for the child to say something.
    pub fn pump(self: *Transport, timeout_ms: i32) void {
        if (!self.alive) return;
        var fds = [_]posix.pollfd{.{ .fd = self.out_fd, .events = posix.POLL.IN, .revents = 0 }};
        const n = posix.poll(&fds, timeout_ms) catch return;
        if (n > 0 and (fds[0].revents & posix.POLL.IN) != 0) self.readAvailable();
    }
};

/// The `Content-Length` value from a header block, in whatever order the
/// headers came.
pub fn contentLength(header: []const u8) ?usize {
    const tag = "Content-Length:";
    const at = std.mem.indexOf(u8, header, tag) orelse return null;
    const rest = header[at + tag.len ..];
    const line_end = std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
    return std.fmt.parseInt(usize, std.mem.trim(u8, rest[0..line_end], " \t"), 10) catch null;
}

/// Append `s` as the inside of a JSON string (no surrounding quotes).
pub fn appendEscaped(list: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, list);
    defer list.* = aw.toArrayList();
    try std.json.Stringify.encodeJsonStringChars(s, .{}, &aw.writer);
}

const testing = std.testing;

test "content length in either header order" {
    try testing.expectEqual(@as(?usize, 42), contentLength("Content-Length: 42"));
    try testing.expectEqual(@as(?usize, 7), contentLength("Content-Type: x\r\nContent-Length: 7"));
    try testing.expectEqual(@as(?usize, null), contentLength("Content-Type: x"));
    try testing.expectEqual(@as(?usize, null), contentLength("Content-Length: not-a-number"));
}

/// A transport wired to no process, for testing the framing alone.
fn testTransport(gpa: std.mem.Allocator, bytes: []const u8) !Transport {
    var t = Transport{ .gpa = gpa, .io = undefined, .out_fd = -1, .stdin = undefined };
    try t.buf.appendSlice(gpa, bytes);
    return t;
}

test "frames are handed out one at a time" {
    var t = try testTransport(testing.allocator,
        "Content-Length: 2\r\n\r\n{}" ++
            "Content-Length: 4\r\n\r\n[1,2]"[0 .. "Content-Length: 4\r\n\r\n".len + 4]);
    defer t.deinit();
    try testing.expectEqualStrings("{}", t.nextFrame().?);
    try testing.expectEqualStrings("[1,2", t.nextFrame().?);
    try testing.expect(t.nextFrame() == null);
}

test "a partial body waits for the rest" {
    var t = try testTransport(testing.allocator, "Content-Length: 10\r\n\r\n{\"a\":");
    defer t.deinit();
    try testing.expect(t.nextFrame() == null);
    try t.buf.appendSlice(testing.allocator, "12345");
    try testing.expectEqualStrings("{\"a\":12345", t.nextFrame().?);
}

test "an unparseable header is skipped rather than stalling the stream" {
    var t = try testTransport(testing.allocator, "Garbage: yes\r\n\r\nContent-Length: 2\r\n\r\nok");
    defer t.deinit();
    try testing.expectEqualStrings("ok", t.nextFrame().?);
}

test "a frame split across reads is assembled" {
    var t = try testTransport(testing.allocator, "Content-Len");
    defer t.deinit();
    try testing.expect(t.nextFrame() == null);
    try t.buf.appendSlice(testing.allocator, "gth: 3\r\n\r\nabc");
    try testing.expectEqualStrings("abc", t.nextFrame().?);
}

//! A Debug Adapter Protocol client: spawns a debug adapter, speaks DAP over
//! its stdio, and exposes just enough state for the editor to show where the
//! program stopped and to step from there.
//!
//! DAP frames messages exactly as LSP does, so the transport is shared
//! (`jsonrpc.zig`); what differs is the vocabulary. Three message kinds:
//! `request` (ours, answered by a `response` carrying the same seq), and
//! `event` (the adapter's, unsolicited — `stopped`, `terminated`, `output`).
//!
//! Best-effort, like the LSP client: no adapter installed simply means no
//! debugging, an adapter that dies is marked dead rather than hung on, and
//! everything it sends is untrusted text that reaches the screen through the
//! editor's sanitizer.
//!
//! What is here is the core loop — launch, breakpoints, stop, step, stack —
//! not the whole protocol: no variables/scopes, watches, REPL evaluation,
//! conditional or function breakpoints, or attach (see TODO.md).

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");

const Allocator = std.mem.Allocator;

pub const State = enum {
    /// Spawned; the handshake is in flight.
    starting,
    /// The program is running: no line to show, stepping is meaningless.
    running,
    /// Stopped at `where`, which is where the cursor goes.
    stopped,
    /// The program (or the adapter) finished.
    exited,
};

/// Where the program is stopped: a source path and a 1-based line.
pub const Stop = struct {
    path: []u8,
    line: usize,
    reason: []u8, // "breakpoint", "step", "exception", …
};

pub const Client = struct {
    gpa: Allocator,
    io: std.Io,
    child: std.process.Child,
    t: jsonrpc.Transport,
    state: State = .starting,
    seq: i64 = 1,
    /// The adapter said `initialized`, so breakpoints may be sent.
    configured: bool = false,
    /// The thread the last `stopped` event named; steps go to it.
    thread: i64 = 1,
    where: ?Stop = null,
    /// Lines the adapter printed (its own diagnostics and the program's
    /// stdout when it forwards it), newest last, capped.
    output: std.ArrayList([]u8) = .empty,
    /// Set when a `stopped`/`terminated` event has changed things, so the
    /// editor knows to move the cursor and redraw. Cleared by `takeChanged`.
    changed: bool = false,

    pub const max_output = 200;

    pub fn deinit(self: *Client) void {
        self.stop();
        self.clearWhere();
        for (self.output.items) |o| self.gpa.free(o);
        self.output.deinit(self.gpa);
        self.t.deinit();
    }

    fn clearWhere(self: *Client) void {
        if (self.where) |w| {
            self.gpa.free(w.path);
            self.gpa.free(w.reason);
        }
        self.where = null;
    }

    pub fn alive(self: *const Client) bool {
        return self.t.alive and self.state != .exited;
    }

    pub fn takeChanged(self: *Client) bool {
        defer self.changed = false;
        return self.changed;
    }

    /// Spawn `argv` as a debug adapter and start the handshake.
    pub fn spawn(gpa: Allocator, io: std.Io, argv: []const []const u8) !Client {
        const child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore, // an adapter's stderr is its own business
        });
        var self = Client{
            .gpa = gpa,
            .io = io,
            .child = child,
            .t = .{
                .gpa = gpa,
                .io = io,
                .out_fd = child.stdout.?.handle,
                .stdin = child.stdin.?,
            },
        };
        self.request("initialize",
            \\{"clientID":"zedit","adapterID":"zedit","linesStartAt1":true,"columnsStartAt1":true,"pathFormat":"path","supportsRunInTerminalRequest":false}
        );
        return self;
    }

    pub fn outFd(self: *const Client) std.posix.fd_t {
        return self.t.out_fd;
    }

    // --- outgoing -----------------------------------------------------------

    fn request(self: *Client, command: []const u8, arguments: []const u8) void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        body.print(self.gpa, "{{\"seq\":{d},\"type\":\"request\",\"command\":\"{s}\",\"arguments\":{s}}}", .{
            self.seq, command, arguments,
        }) catch return;
        self.seq += 1;
        self.t.write(body.items);
    }

    /// `launch` with the program to debug. Extra adapter-specific keys are
    /// not exposed: a launch.json equivalent is a configuration format of its
    /// own, and nothing here needs one yet.
    pub fn launch(self: *Client, program: []const u8, args: []const []const u8) void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        body.appendSlice(self.gpa, "{\"noDebug\":false,\"program\":\"") catch return;
        jsonrpc.appendEscaped(&body, self.gpa, program) catch return;
        body.appendSlice(self.gpa, "\",\"args\":[") catch return;
        for (args, 0..) |a, i| {
            if (i > 0) body.append(self.gpa, ',') catch return;
            body.append(self.gpa, '"') catch return;
            jsonrpc.appendEscaped(&body, self.gpa, a) catch return;
            body.append(self.gpa, '"') catch return;
        }
        body.appendSlice(self.gpa, "]}") catch return;
        self.request("launch", body.items);
    }

    /// Replace the breakpoints for one source file (DAP has no "add one":
    /// every change re-sends that file's whole set).
    pub fn setBreakpoints(self: *Client, path: []const u8, lines: []const usize) void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        body.appendSlice(self.gpa, "{\"source\":{\"path\":\"") catch return;
        jsonrpc.appendEscaped(&body, self.gpa, path) catch return;
        body.appendSlice(self.gpa, "\"},\"breakpoints\":[") catch return;
        for (lines, 0..) |l, i| {
            body.print(self.gpa, "{s}{{\"line\":{d}}}", .{ if (i > 0) "," else "", l }) catch return;
        }
        body.appendSlice(self.gpa, "]}") catch return;
        self.request("setBreakpoints", body.items);
    }

    pub fn configurationDone(self: *Client) void {
        self.request("configurationDone", "{}");
    }

    pub fn cont(self: *Client) void {
        self.threadRequest("continue");
        self.state = .running;
        self.clearWhere();
        self.changed = true;
    }

    pub fn next(self: *Client) void {
        self.threadRequest("next");
    }

    pub fn stepIn(self: *Client) void {
        self.threadRequest("stepIn");
    }

    pub fn stepOut(self: *Client) void {
        self.threadRequest("stepOut");
    }

    pub fn pause(self: *Client) void {
        self.threadRequest("pause");
    }

    fn threadRequest(self: *Client, command: []const u8) void {
        var buf: [64]u8 = undefined;
        const args = std.fmt.bufPrint(&buf, "{{\"threadId\":{d}}}", .{self.thread}) catch return;
        self.request(command, args);
    }

    /// End the session: ask politely, then make sure.
    pub fn stop(self: *Client) void {
        if (self.t.alive) {
            self.request("disconnect", "{\"terminateDebuggee\":true}");
            self.t.alive = false;
        }
        if (self.state != .exited) {
            self.child.kill(self.io);
            self.state = .exited;
        }
    }

    // --- incoming -----------------------------------------------------------

    pub fn readAvailable(self: *Client) void {
        self.t.readAvailable();
        while (self.t.nextFrame()) |body| self.handle(body);
        if (!self.t.alive and self.state != .exited) {
            self.state = .exited;
            self.changed = true;
        }
    }

    /// Block up to `timeout_ms` for the adapter, then process what came.
    pub fn pump(self: *Client, timeout_ms: i32) void {
        if (!self.t.alive) return;
        self.t.pump(timeout_ms);
        while (self.t.nextFrame()) |body| self.handle(body);
        if (!self.t.alive and self.state != .exited) {
            self.state = .exited;
            self.changed = true;
        }
    }

    fn handle(self: *Client, body: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, body, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const obj = parsed.value.object;
        const kind = strOf(obj.get("type")) orelse return;
        if (std.mem.eql(u8, kind, "event")) return self.event(obj);
        if (std.mem.eql(u8, kind, "response")) return self.response(obj);
    }

    fn event(self: *Client, obj: std.json.ObjectMap) void {
        const name = strOf(obj.get("event")) orelse return;
        const b = obj.get("body");
        if (std.mem.eql(u8, name, "initialized")) {
            self.configured = true;
            self.changed = true;
        } else if (std.mem.eql(u8, name, "stopped")) {
            self.state = .stopped;
            if (b) |v| {
                if (intOf(field(v, "threadId"))) |t| self.thread = t;
                self.clearWhere();
                const reason = strOf(field(v, "reason")) orelse "stopped";
                self.where = .{
                    .path = &.{}, // filled by the stackTrace response
                    .line = 0,
                    .reason = self.gpa.dupe(u8, reason) catch return,
                };
            }
            // Where exactly? Only the stack knows; ask, and the response
            // fills `where`.
            self.threadRequest("stackTrace");
            self.changed = true;
        } else if (std.mem.eql(u8, name, "terminated") or std.mem.eql(u8, name, "exited")) {
            self.state = .exited;
            self.clearWhere();
            self.changed = true;
        } else if (std.mem.eql(u8, name, "output")) {
            if (b) |v| {
                if (strOf(field(v, "output"))) |line| self.addOutput(line);
            }
        }
    }

    fn response(self: *Client, obj: std.json.ObjectMap) void {
        const command = strOf(obj.get("command")) orelse return;
        if (std.mem.eql(u8, command, "initialize")) {
            // The adapter is ready for `launch`; the editor drives that, since
            // only it knows what program the user asked for.
            self.changed = true;
            return;
        }
        if (!std.mem.eql(u8, command, "stackTrace")) return;
        const b = obj.get("body") orelse return;
        const frames = field(b, "stackFrames") orelse return;
        if (frames != .array or frames.array.items.len == 0) return;
        const top = frames.array.items[0];
        const line: usize = @intCast(@max(1, intOf(field(top, "line")) orelse 1));
        const src = field(top, "source") orelse return;
        const path = strOf(field(src, "path")) orelse return;
        if (self.where) |*w| {
            if (w.path.len > 0) self.gpa.free(w.path);
            w.path = self.gpa.dupe(u8, path) catch return;
            w.line = line;
        }
        self.changed = true;
    }

    /// Keep the adapter's output, split into lines and capped. It is remote
    /// text: stored verbatim here, sanitized where it is drawn.
    fn addOutput(self: *Client, text: []const u8) void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;
            const owned = self.gpa.dupe(u8, line) catch return;
            self.output.append(self.gpa, owned) catch {
                self.gpa.free(owned);
                return;
            };
            if (self.output.items.len > max_output) {
                const dropped = self.output.orderedRemove(0);
                self.gpa.free(dropped);
            }
        }
    }
};

fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn strOf(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn intOf(v: ?std.json.Value) ?i64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

// === breakpoints ============================================================
//
// A breakpoint set is editor state, not adapter state: the user places them
// before anything is running, and they must survive a session ending. Kept
// here so the rule (sorted, no duplicates, moved by edits) is unit-testable
// away from the editor.

pub const Breakpoints = struct {
    gpa: Allocator,
    /// Per file, sorted 1-based lines. Paths are owned.
    files: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty,

    pub fn deinit(self: *Breakpoints) void {
        var it = self.files.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(self.gpa);
        }
        self.files.deinit(self.gpa);
    }

    pub fn linesFor(self: *const Breakpoints, path: []const u8) []const usize {
        const e = self.files.get(path) orelse return &.{};
        return e.items;
    }

    pub fn has(self: *const Breakpoints, path: []const u8, line: usize) bool {
        for (self.linesFor(path)) |l| {
            if (l == line) return true;
        }
        return false;
    }

    /// Add the line if absent, remove it if present. Returns the new state,
    /// so the caller can say which it did.
    pub fn toggle(self: *Breakpoints, path: []const u8, line: usize) bool {
        const gop = self.files.getOrPut(self.gpa, path) catch return false;
        if (!gop.found_existing) {
            const owned = self.gpa.dupe(u8, path) catch {
                _ = self.files.remove(path);
                return false;
            };
            gop.key_ptr.* = owned;
            gop.value_ptr.* = .empty;
        }
        const list = gop.value_ptr;
        for (list.items, 0..) |l, i| {
            if (l != line) continue;
            _ = list.orderedRemove(i);
            return false;
        }
        // Kept sorted so the gutter and the adapter both see them in order.
        var at: usize = 0;
        while (at < list.items.len and list.items[at] < line) at += 1;
        list.insert(self.gpa, at, line) catch return false;
        return true;
    }

    pub fn total(self: *const Breakpoints) usize {
        var n: usize = 0;
        var it = self.files.valueIterator();
        while (it.next()) |v| n += v.items.len;
        return n;
    }
};

const testing = std.testing;

test "toggling a breakpoint adds then removes it" {
    var bp = Breakpoints{ .gpa = testing.allocator };
    defer bp.deinit();
    try testing.expect(bp.toggle("/a.zig", 10));
    try testing.expect(bp.has("/a.zig", 10));
    try testing.expect(!bp.toggle("/a.zig", 10));
    try testing.expect(!bp.has("/a.zig", 10));
    try testing.expectEqual(@as(usize, 0), bp.total());
}

test "breakpoints stay sorted whatever order they are set in" {
    var bp = Breakpoints{ .gpa = testing.allocator };
    defer bp.deinit();
    for ([_]usize{ 30, 10, 20, 5 }) |l| _ = bp.toggle("/a.zig", l);
    try testing.expectEqualSlices(usize, &.{ 5, 10, 20, 30 }, bp.linesFor("/a.zig"));
}

test "each file keeps its own set" {
    var bp = Breakpoints{ .gpa = testing.allocator };
    defer bp.deinit();
    _ = bp.toggle("/a.zig", 1);
    _ = bp.toggle("/b.zig", 2);
    try testing.expect(bp.has("/a.zig", 1) and !bp.has("/a.zig", 2));
    try testing.expect(bp.has("/b.zig", 2) and !bp.has("/b.zig", 1));
    try testing.expectEqual(@as(usize, 2), bp.total());
}

test "a file with no breakpoints reads as empty, not as an error" {
    var bp = Breakpoints{ .gpa = testing.allocator };
    defer bp.deinit();
    try testing.expectEqual(@as(usize, 0), bp.linesFor("/never.zig").len);
    try testing.expect(!bp.has("/never.zig", 1));
}

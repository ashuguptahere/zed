//! A minimal Language Server Protocol client (pure Zig, std only).
//!
//! Spawns a language server, speaks JSON-RPC over its stdio with Content-Length
//! framing, and surfaces what the editor needs: diagnostics (pushed by the
//! server), plus hover and goto-definition on request. It is best-effort — if
//! the server binary is missing or the handshake times out, the client simply
//! reports itself as not started and the editor carries on.
//!
//! The server's stdout fd is exposed so the editor can poll it alongside the
//! terminal; incoming messages are processed without blocking the UI.

const std = @import("std");
const posix = std.posix;
const unicode = @import("unicode.zig");
const Allocator = std.mem.Allocator;

pub const Diagnostic = struct {
    line: usize, // 0-based
    severity: u8, // 1=error 2=warning 3=info 4=hint
    message: []u8,
};

pub const Location = struct { uri: []u8, line: usize, col: usize };

pub const Completion = struct { label: []u8, insert: []u8 };

pub const Client = struct {
    gpa: Allocator,
    io: std.Io,
    child: std.process.Child,
    in_fd: posix.fd_t,
    out_fd: posix.fd_t,
    alive: bool,
    next_id: i64,
    version: i64,

    uri: []u8, // file:// URI of the open document
    read_buf: std.ArrayList(u8),
    diags: std.ArrayList(Diagnostic),

    init_done: bool,
    incremental: bool, // server supports incremental textDocument/didChange
    doc: std.ArrayList(u8), // mirror of the open document, for diffing changes
    hover_id: i64,
    def_id: i64,
    comp_id: i64,
    hover_text: ?[]u8, // pending hover result for the editor to show
    def_target: ?Location, // pending goto-definition result
    completions: std.ArrayList(Completion), // last completion result
    comp_ready: bool, // a completion response just arrived (editor should consume)

    pub fn start(
        gpa: Allocator,
        io: std.Io,
        argv: []const []const u8,
        root: []const u8,
        uri: []const u8,
        language_id: []const u8,
        content: []const u8,
    ) ?Client {
        const child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return null;

        var self: Client = .{
            .gpa = gpa,
            .io = io,
            .child = child,
            .in_fd = child.stdin.?.handle,
            .out_fd = child.stdout.?.handle,
            .alive = true,
            .next_id = 2,
            .version = 1,
            .uri = gpa.dupe(u8, uri) catch return null,
            .read_buf = .empty,
            .diags = .empty,
            .init_done = false,
            .incremental = false,
            .doc = .empty,
            .hover_id = -1,
            .def_id = -1,
            .comp_id = -1,
            .hover_text = null,
            .def_target = null,
            .completions = .empty,
            .comp_ready = false,
        };

        self.sendInitialize(root);
        // Pump until the server answers `initialize`, or give up.
        const deadline = nowMs() + 4000;
        while (!self.init_done and self.alive and nowMs() < deadline) {
            if (pollReadable(self.out_fd, 200)) self.readAvailable();
        }
        if (!self.init_done) {
            self.deinit();
            return null;
        }
        self.sendNotification("initialized", "{}");
        self.sendDidOpen(language_id, content);
        return self;
    }

    pub fn deinit(self: *Client) void {
        self.child.kill(self.io);
        self.gpa.free(self.uri);
        self.read_buf.deinit(self.gpa);
        self.doc.deinit(self.gpa);
        self.clearDiags();
        self.diags.deinit(self.gpa);
        self.clearCompletions();
        self.completions.deinit(self.gpa);
        if (self.hover_text) |t| self.gpa.free(t);
        if (self.def_target) |d| self.gpa.free(d.uri);
    }

    fn clearDiags(self: *Client) void {
        for (self.diags.items) |d| self.gpa.free(d.message);
        self.diags.clearRetainingCapacity();
    }

    fn clearCompletions(self: *Client) void {
        for (self.completions.items) |it| {
            self.gpa.free(it.label);
            self.gpa.free(it.insert);
        }
        self.completions.clearRetainingCapacity();
    }

    // --- outgoing ----------------------------------------------------------

    fn sendInitialize(self: *Client, root: []const u8) void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        body.appendSlice(self.gpa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"processId\":null,\"rootUri\":\"file://") catch return;
        appendEscaped(&body, self.gpa, root) catch return;
        body.appendSlice(self.gpa, "\",\"capabilities\":{\"textDocument\":{\"publishDiagnostics\":{},\"hover\":{},\"definition\":{},\"completion\":{}}}}}") catch return;
        self.writeMessage(body.items);
    }

    fn sendDidOpen(self: *Client, language_id: []const u8, content: []const u8) void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        const a = self.gpa;
        body.appendSlice(a, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"") catch return;
        appendEscaped(&body, a, self.uri) catch return;
        body.appendSlice(a, "\",\"languageId\":\"") catch return;
        appendEscaped(&body, a, language_id) catch return;
        body.appendSlice(a, "\",\"version\":1,\"text\":\"") catch return;
        appendEscaped(&body, a, content) catch return;
        body.appendSlice(a, "\"}}}") catch return;
        self.writeMessage(body.items);
        self.rememberDoc(content);
    }

    /// Notify the server of an edit. Sends an incremental change (just the
    /// edited range) when the server supports it, else the full document.
    pub fn didChange(self: *Client, content: []const u8) void {
        if (!self.alive) return;
        self.version += 1;
        if (self.incremental) self.sendDidChangeIncremental(content) else self.sendDidChangeFull(content);
        self.rememberDoc(content);
    }

    fn sendDidChangeFull(self: *Client, content: []const u8) void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        const a = self.gpa;
        self.changeHeader(&body) catch return;
        body.appendSlice(a, "\"text\":\"") catch return;
        appendEscaped(&body, a, content) catch return;
        body.appendSlice(a, "\"}]}}") catch return;
        self.writeMessage(body.items);
    }

    fn sendDidChangeIncremental(self: *Client, content: []const u8) void {
        const old = self.doc.items;
        // Common prefix/suffix -> a single changed range [start, old_end).
        const min = @min(old.len, content.len);
        var p: usize = 0;
        while (p < min and old[p] == content[p]) p += 1;
        var s: usize = 0;
        while (s < min - p and old[old.len - 1 - s] == content[content.len - 1 - s]) s += 1;
        const old_end = old.len - s;
        const new_text = content[p .. content.len - s];

        const start_pos = utf16Pos(old, p);
        const end_pos = utf16Pos(old, old_end);

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        const a = self.gpa;
        self.changeHeader(&body) catch return;
        var nb: [128]u8 = undefined;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"text\":\"", .{ start_pos.line, start_pos.character, end_pos.line, end_pos.character }) catch return) catch return;
        appendEscaped(&body, a, new_text) catch return;
        body.appendSlice(a, "\"}]}}") catch return;
        self.writeMessage(body.items);
    }

    /// Writes the didChange envelope up to (but not including) the first
    /// contentChange's fields: `...{"uri":...,"version":N},"contentChanges":[{`
    fn changeHeader(self: *Client, body: *std.ArrayList(u8)) !void {
        const a = self.gpa;
        try body.appendSlice(a, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"");
        try appendEscaped(body, a, self.uri);
        var nb: [32]u8 = undefined;
        try body.appendSlice(a, std.fmt.bufPrint(&nb, "\",\"version\":{d}", .{self.version}) catch return);
        try body.appendSlice(a, "},\"contentChanges\":[{");
    }

    fn rememberDoc(self: *Client, content: []const u8) void {
        self.doc.clearRetainingCapacity();
        self.doc.appendSlice(self.gpa, content) catch self.doc.clearRetainingCapacity();
    }

    pub fn requestCompletion(self: *Client, line: usize, col: usize) void {
        self.comp_id = self.nextId();
        self.sendPositionRequest(self.comp_id, "textDocument/completion", line, col);
    }

    pub fn requestHover(self: *Client, line: usize, col: usize) void {
        self.hover_id = self.nextId();
        self.sendPositionRequest(self.hover_id, "textDocument/hover", line, col);
    }

    pub fn requestDefinition(self: *Client, line: usize, col: usize) void {
        self.def_id = self.nextId();
        self.sendPositionRequest(self.def_id, "textDocument/definition", line, col);
    }

    fn sendPositionRequest(self: *Client, id: i64, method: []const u8, line: usize, col: usize) void {
        if (!self.alive) return;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        const a = self.gpa;
        var nb: [200]u8 = undefined;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{{\"textDocument\":{{\"uri\":\"", .{ id, method }) catch return) catch return;
        appendEscaped(&body, a, self.uri) catch return;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ line, col }) catch return) catch return;
        self.writeMessage(body.items);
    }

    fn sendNotification(self: *Client, method: []const u8, params: []const u8) void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var nb: [128]u8 = undefined;
        body.appendSlice(self.gpa, std.fmt.bufPrint(&nb, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":", .{method}) catch return) catch return;
        body.appendSlice(self.gpa, params) catch return;
        body.appendSlice(self.gpa, "}") catch return;
        self.writeMessage(body.items);
    }

    fn nextId(self: *Client) i64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn writeMessage(self: *Client, body: []const u8) void {
        if (!self.alive) return;
        var hdr: [64]u8 = undefined;
        const h = std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return;
        if (!writeAllFd(self.in_fd, h) or !writeAllFd(self.in_fd, body)) self.alive = false;
    }

    // --- incoming ----------------------------------------------------------

    /// Called by the editor when the server's stdout is readable.
    pub fn processReadable(self: *Client) void {
        self.readAvailable();
    }

    fn readAvailable(self: *Client) void {
        var tmp: [4096]u8 = undefined;
        const n = posix.read(self.out_fd, &tmp) catch {
            self.alive = false;
            return;
        };
        if (n == 0) {
            self.alive = false;
            return;
        }
        self.read_buf.appendSlice(self.gpa, tmp[0..n]) catch return;
        self.drainFrames();
    }

    fn drainFrames(self: *Client) void {
        while (true) {
            const buf = self.read_buf.items;
            const sep = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return;
            const len = contentLength(buf[0..sep]) orelse {
                // Unparseable header; drop it and continue.
                self.read_buf.replaceRange(self.gpa, 0, sep + 4, &.{}) catch return;
                continue;
            };
            const total = sep + 4 + len;
            if (self.read_buf.items.len < total) return; // wait for the rest
            self.handleMessage(self.read_buf.items[sep + 4 .. total]);
            self.read_buf.replaceRange(self.gpa, 0, total, &.{}) catch return;
        }
    }

    fn handleMessage(self: *Client, body: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, body, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const obj = parsed.value.object;

        if (obj.get("method")) |m| {
            if (m == .string and std.mem.eql(u8, m.string, "textDocument/publishDiagnostics")) {
                if (obj.get("params")) |p| self.updateDiagnostics(p);
            }
            return;
        }
        const id = if (obj.get("id")) |v| (if (v == .integer) v.integer else return) else return;
        const result_opt = obj.get("result");
        if (id == 1) { // response to our `initialize`
            self.init_done = true;
            if (result_opt) |r| self.parseServerCaps(r);
            return;
        }
        const result = result_opt orelse return;
        if (id == self.hover_id) self.handleHover(result);
        if (id == self.def_id) self.handleDefinition(result);
        if (id == self.comp_id) self.handleCompletion(result);
    }

    /// Read the server's `textDocumentSync` to decide full vs. incremental
    /// change notifications (it may be an integer or `{change: int}`).
    fn parseServerCaps(self: *Client, result: std.json.Value) void {
        const caps = getField(result, "capabilities") orelse return;
        const sync = getField(caps, "textDocumentSync") orelse return;
        const change: i64 = switch (sync) {
            .integer => |i| i,
            .object => asInt(getField(sync, "change")) orelse 0,
            else => 0,
        };
        self.incremental = (change == 2);
    }

    fn handleCompletion(self: *Client, result: std.json.Value) void {
        self.clearCompletions();
        // result is a CompletionList {items: [...]}, a bare array, or null.
        const items = switch (result) {
            .array => result,
            .object => getField(result, "items") orelse return,
            else => return,
        };
        if (items != .array) return;
        for (items.array.items) |it| {
            if (self.completions.items.len >= 400) break;
            const label = asStr(getField(it, "label")) orelse continue;
            const insert = asStr(getField(it, "insertText")) orelse label;
            const l = self.gpa.dupe(u8, label) catch continue;
            const ins = self.gpa.dupe(u8, insert) catch {
                self.gpa.free(l);
                continue;
            };
            self.completions.append(self.gpa, .{ .label = l, .insert = ins }) catch {
                self.gpa.free(l);
                self.gpa.free(ins);
            };
        }
        self.comp_ready = true;
    }

    fn updateDiagnostics(self: *Client, params: std.json.Value) void {
        self.clearDiags();
        const arr = getField(params, "diagnostics") orelse return;
        if (arr != .array) return;
        for (arr.array.items) |d| {
            const range = getField(d, "range") orelse continue;
            const start_pos = getField(range, "start") orelse continue;
            const line = asInt(getField(start_pos, "line")) orelse continue;
            const sev: u8 = @intCast(asInt(getField(d, "severity")) orelse 1);
            const msg = asStr(getField(d, "message")) orelse "";
            const owned = self.gpa.dupe(u8, msg) catch continue;
            self.diags.append(self.gpa, .{ .line = @intCast(line), .severity = sev, .message = owned }) catch {
                self.gpa.free(owned);
            };
        }
    }

    fn handleHover(self: *Client, result: std.json.Value) void {
        if (self.hover_text) |t| self.gpa.free(t);
        self.hover_text = null;
        // result.contents may be a string, {value}, or {kind,value}.
        const contents = getField(result, "contents") orelse return;
        const text = switch (contents) {
            .string => |s| s,
            .object => asStr(getField(contents, "value")) orelse return,
            else => return,
        };
        self.hover_text = self.gpa.dupe(u8, text) catch null;
    }

    fn handleDefinition(self: *Client, result: std.json.Value) void {
        // result may be a Location or an array of Locations.
        const loc = switch (result) {
            .object => result,
            .array => |a| if (a.items.len > 0) a.items[0] else return,
            else => return,
        };
        const uri = asStr(getField(loc, "uri")) orelse return;
        const range = getField(loc, "range") orelse return;
        const start_pos = getField(range, "start") orelse return;
        const line = asInt(getField(start_pos, "line")) orelse return;
        const col = asInt(getField(start_pos, "character")) orelse 0;
        if (self.def_target) |d| self.gpa.free(d.uri);
        self.def_target = .{ .uri = self.gpa.dupe(u8, uri) catch return, .line = @intCast(line), .col = @intCast(col) };
    }

    // --- queries for the editor -------------------------------------------

    pub fn severityAt(self: *const Client, line: usize) ?u8 {
        var best: ?u8 = null;
        for (self.diags.items) |d| {
            if (d.line == line and (best == null or d.severity < best.?)) best = d.severity;
        }
        return best;
    }

    pub fn messageAt(self: *const Client, line: usize) ?[]const u8 {
        for (self.diags.items) |d| if (d.line == line) return d.message;
        return null;
    }

    pub fn counts(self: *const Client) struct { errors: usize, warnings: usize } {
        var e: usize = 0;
        var w: usize = 0;
        for (self.diags.items) |d| {
            if (d.severity == 1) e += 1 else if (d.severity == 2) w += 1;
        }
        return .{ .errors = e, .warnings = w };
    }

    /// Take the pending hover text (caller owns it and must free with gpa).
    pub fn takeHover(self: *Client) ?[]u8 {
        const t = self.hover_text;
        self.hover_text = null;
        return t;
    }

    /// Take the pending goto-definition target (caller owns `.uri`).
    pub fn takeDefinition(self: *Client) ?Location {
        const d = self.def_target;
        self.def_target = null;
        return d;
    }
};

// --- helpers ---------------------------------------------------------------

/// Byte offset -> LSP position (0-based line; character in UTF-16 code units,
/// which is what LSP uses — exact for BMP text, correct surrogate width above).
fn utf16Pos(content: []const u8, byte: usize) struct { line: u32, character: u32 } {
    var line: u32 = 0;
    var col: u32 = 0;
    var i: usize = 0;
    while (i < byte and i < content.len) {
        if (content[i] == '\n') {
            line += 1;
            col = 0;
            i += 1;
            continue;
        }
        const d = unicode.decode(content[i..]);
        col += if (d.cp > 0xFFFF) 2 else 1;
        i += d.len;
    }
    return .{ .line = line, .character = col };
}

fn getField(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn asInt(v: ?std.json.Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

fn asStr(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn contentLength(header: []const u8) ?usize {
    const tag = "Content-Length:";
    const idx = std.mem.indexOf(u8, header, tag) orelse return null;
    var rest = header[idx + tag.len ..];
    rest = std.mem.trim(u8, rest, " \r\n\t");
    const end = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
    return std.fmt.parseInt(usize, rest[0..end], 10) catch null;
}

fn appendEscaped(list: *std.ArrayList(u8), gpa: Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try list.appendSlice(gpa, "\\\""),
        '\\' => try list.appendSlice(gpa, "\\\\"),
        '\n' => try list.appendSlice(gpa, "\\n"),
        '\r' => try list.appendSlice(gpa, "\\r"),
        '\t' => try list.appendSlice(gpa, "\\t"),
        else => if (c < 0x20) {
            var b: [8]u8 = undefined;
            try list.appendSlice(gpa, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch return);
        } else try list.append(gpa, c),
    };
}

fn writeAllFd(fd: posix.fd_t, bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        const rc = posix.system.write(fd, bytes.ptr + i, bytes.len - i);
        switch (posix.system.errno(rc)) {
            .SUCCESS => i += @intCast(rc),
            .INTR, .AGAIN => continue,
            else => return false,
        }
    }
    return true;
}

fn pollReadable(fd: posix.fd_t, timeout_ms: i32) bool {
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const rc = posix.system.poll(&fds, 1, timeout_ms);
    return posix.system.errno(rc) == .SUCCESS and (fds[0].revents & posix.POLL.IN) != 0;
}

fn nowMs() i64 {
    var ts: posix.timespec = undefined;
    if (posix.system.errno(posix.system.clock_gettime(posix.CLOCK.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @as(i64, @intCast(@divTrunc(ts.nsec, std.time.ns_per_ms)));
}

test "contentLength parsing" {
    try std.testing.expectEqual(@as(?usize, 42), contentLength("Content-Length: 42"));
    try std.testing.expectEqual(@as(?usize, 7), contentLength("Content-Type: x\r\nContent-Length: 7"));
    try std.testing.expectEqual(@as(?usize, null), contentLength("Nope: 1"));
}

test "json escaping" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try appendEscaped(&list, gpa, "a\"b\\c\nd");
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\nd", list.items);
}

//! A tiny mock language server for the integration tests (Zig port of the old
//! mock_lsp.py). Speaks JSON-RPC over stdio with Content-Length framing and
//! answers just enough for tools/scenarios/lsp.zig to exercise the client:
//! diagnostics, hover, definition, completion, signature help, rename, code
//! actions, and an executeCommand that drives a server-initiated applyEdit.

const std = @import("std");
const posix = std.posix;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var doc_uri: []u8 = &.{};
    defer if (doc_uri.len > 0) gpa.free(doc_uri);

    while (true) {
        const body = (readMessage(gpa, &buf) catch break) orelse break;
        defer gpa.free(body);
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        const method = strField(parsed.value, "method") orelse continue;
        const id = intField(parsed.value, "id");

        if (eql(method, "initialize")) {
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"capabilities\":{{" ++
                "\"textDocumentSync\":2,\"completionProvider\":{{}}," ++
                "\"signatureHelpProvider\":{{\"triggerCharacters\":[\"(\",\",\"]}}}}}}}}", .{id orelse 0});
        } else if (eql(method, "textDocument/didOpen")) {
            if (uriOf(parsed.value)) |u| {
                if (doc_uri.len > 0) gpa.free(doc_uri);
                doc_uri = gpa.dupe(u8, u) catch &.{};
            }
            diag(gpa, "mock error", 1, 1);
        } else if (eql(method, "textDocument/didChange")) {
            const kind = if (changeHasRange(obj)) "INCREMENTAL" else "FULL";
            diag(gpa, kind, 0, 2);
        } else if (eql(method, "textDocument/completion")) {
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"items\":[" ++
                "{{\"label\":\"mockComplete\",\"insertText\":\"mockComplete\"}}," ++
                "{{\"label\":\"mockOther\",\"insertText\":\"mockOther\"}}]}}}}", .{id orelse 0});
        } else if (eql(method, "textDocument/signatureHelp")) {
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"signatures\":[" ++
                "{{\"label\":\"mockFn(a: int, b: int)\",\"parameters\":[{{\"label\":[7,13]}},{{\"label\":[15,21]}}]}}," ++
                "{{\"label\":\"mockFn(a: str)\",\"parameters\":[{{\"label\":[7,13]}}]}}]," ++
                "\"activeSignature\":0,\"activeParameter\":0}}}}", .{id orelse 0});
        } else if (eql(method, "textDocument/hover")) {
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"contents\":\"mock hover\"}}}}", .{id orelse 0});
        } else if (eql(method, "textDocument/definition")) {
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"uri\":\"file:///x\"," ++
                "\"range\":{{\"start\":{{\"line\":2,\"character\":0}},\"end\":{{\"line\":2,\"character\":0}}}}}}}}", .{id orelse 0});
        } else if (eql(method, "textDocument/rename")) {
            const new_name = strField(getField(parsed.value, "params") orelse parsed.value, "newName") orelse "x";
            sendRaw(gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
            sendInt(gpa, id orelse 0);
            sendRaw(gpa, ",\"result\":{\"changes\":{\"");
            sendRaw(gpa, doc_uri);
            sendRaw(gpa, "\":[{\"range\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":7}},\"newText\":\"");
            sendRaw(gpa, new_name);
            sendRaw(gpa, "\"}]}}}");
            flush(gpa);
        } else if (eql(method, "textDocument/codeAction")) {
            sendRaw(gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
            sendInt(gpa, id orelse 0);
            sendRaw(gpa, ",\"result\":[{\"title\":\"Rename a to A\",\"kind\":\"quickfix\",\"edit\":{\"changes\":{\"");
            sendRaw(gpa, doc_uri);
            sendRaw(gpa, "\":[{\"range\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":7}},\"newText\":\"A\"}]}}}," ++
                "{\"title\":\"Run mock command\",\"command\":\"mock.run\"}]}");
            flush(gpa);
        } else if (eql(method, "workspace/executeCommand")) {
            const cmd = strField(getField(parsed.value, "params") orelse parsed.value, "command") orelse "";
            if (eql(cmd, "mock.run") and doc_uri.len > 0) {
                sendRaw(gpa, "{\"jsonrpc\":\"2.0\",\"id\":999,\"method\":\"workspace/applyEdit\",\"params\":{\"edit\":{\"changes\":{\"");
                sendRaw(gpa, doc_uri);
                sendRaw(gpa, "\":[{\"range\":{\"start\":{\"line\":1,\"character\":6},\"end\":{\"line\":1,\"character\":7}},\"newText\":\"B\"}]}}}}");
                flush(gpa);
            }
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id orelse 0});
        } else if (eql(method, "shutdown")) {
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id orelse 0});
        }
        // Everything else (initialized, the applyEdit response, etc.) is ignored.
    }
}

// --- diagnostics / message sending -----------------------------------------

fn diag(gpa: std.mem.Allocator, message: []const u8, line: u32, severity: u32) void {
    send(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":\"x\"," ++
        "\"diagnostics\":[{{\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":1}}}}," ++
        "\"severity\":{d},\"message\":\"{s}\"}}]}}}}", .{ line, line, severity, message });
}

/// A formatted JSON-RPC message (the format string uses `{{`/`}}` for literal
/// braces), framed with Content-Length and written to stdout.
fn send(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const body = std.fmt.allocPrint(gpa, fmt, args) catch return;
    defer gpa.free(body);
    var hdr: [64]u8 = undefined;
    writeAll(std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return);
    writeAll(body);
}

// For messages that embed an arbitrary URI/name we stream pieces directly.
var frame: std.ArrayList(u8) = .empty;
fn sendRaw(gpa: std.mem.Allocator, s: []const u8) void {
    frame.appendSlice(gpa, s) catch {};
}
fn sendInt(gpa: std.mem.Allocator, n: i64) void {
    var b: [32]u8 = undefined;
    frame.appendSlice(gpa, std.fmt.bufPrint(&b, "{d}", .{n}) catch return) catch {};
}
fn flush(gpa: std.mem.Allocator) void {
    defer frame.clearRetainingCapacity();
    var hdr: [64]u8 = undefined;
    writeAll(std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{frame.items.len}) catch return);
    writeAll(frame.items);
    _ = gpa;
}

fn writeAll(bytes: []const u8) void {
    var i: usize = 0;
    while (i < bytes.len) {
        const rc = posix.system.write(1, bytes.ptr + i, bytes.len - i);
        switch (posix.errno(rc)) {
            .SUCCESS => i += @intCast(rc),
            .INTR, .AGAIN => continue,
            else => return,
        }
    }
}

// --- incoming framing -------------------------------------------------------

fn readMessage(gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) !?[]u8 {
    while (true) {
        if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |sep| {
            if (contentLength(buf.items[0..sep])) |len| {
                const total = sep + 4 + len;
                if (buf.items.len >= total) {
                    const body = try gpa.dupe(u8, buf.items[sep + 4 .. total]);
                    buf.replaceRange(gpa, 0, total, &.{}) catch {};
                    return body;
                }
            } else {
                buf.replaceRange(gpa, 0, sep + 4, &.{}) catch {};
                continue;
            }
        }
        var tmp: [4096]u8 = undefined;
        const n = posix.read(0, &tmp) catch return null;
        if (n == 0) return null;
        try buf.appendSlice(gpa, tmp[0..n]);
    }
}

fn contentLength(header: []const u8) ?usize {
    const tag = "Content-Length:";
    const idx = std.mem.indexOf(u8, header, tag) orelse return null;
    const rest = std.mem.trim(u8, header[idx + tag.len ..], " \r\n\t");
    const end = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
    return std.fmt.parseInt(usize, rest[0..end], 10) catch null;
}

// --- json helpers -----------------------------------------------------------

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn getField(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn strField(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = getField(v, key) orelse return null;
    return if (f == .string) f.string else null;
}

fn intField(v: std.json.Value, key: []const u8) ?i64 {
    const f = getField(v, key) orelse return null;
    return if (f == .integer) f.integer else null;
}

fn uriOf(v: std.json.Value) ?[]const u8 {
    const params = getField(v, "params") orelse return null;
    const td = getField(params, "textDocument") orelse return null;
    return strField(td, "uri");
}

fn changeHasRange(obj: std.json.ObjectMap) bool {
    const params = obj.get("params") orelse return false;
    const changes = getField(params, "contentChanges") orelse return false;
    if (changes != .array or changes.array.items.len == 0) return false;
    return getField(changes.array.items[0], "range") != null;
}

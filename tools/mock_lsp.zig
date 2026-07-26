//! A tiny mock language server for the integration tests (Zig port of the old
//! mock_lsp.py). Speaks JSON-RPC over stdio with Content-Length framing and
//! answers just enough for tools/scenarios/lsp.zig to exercise the client:
//! diagnostics, hover, definition, completion, signature help, rename, code
//! actions, an executeCommand that drives a server-initiated applyEdit,
//! references, and formatting. Flags: `--fmt` advertises formatting in the
//! initialize response (turning on the editor's format-on-save); `--xfile`
//! makes rename return a second file's edits (sibling `zedit_it_other.zig`)
//! to exercise cross-file WorkspaceEdits.

const std = @import("std");
const posix = std.posix;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var fmt_mode = false;
    var xfile = false;
    for (argv[1..]) |a| {
        if (eql(a, "--fmt")) fmt_mode = true;
        if (eql(a, "--xfile")) xfile = true;
    }
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
            const caps_head = "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"capabilities\":{{" ++
                "\"textDocumentSync\":2,\"completionProvider\":{{}},\"referencesProvider\":true," ++
                "\"signatureHelpProvider\":{{\"triggerCharacters\":[\"(\",\",\"]}}";
            if (fmt_mode) {
                send(gpa, caps_head ++ ",\"documentFormattingProvider\":true}}}}}}", .{id orelse 0});
            } else {
                send(gpa, caps_head ++ "}}}}}}", .{id orelse 0});
            }
        } else if (eql(method, "textDocument/didOpen")) {
            if (uriOf(parsed.value)) |u| {
                if (doc_uri.len > 0) gpa.free(doc_uri);
                doc_uri = gpa.dupe(u8, u) catch &.{};
            }
            // Two diagnostics (line 1 error, line 2 warning) so ]d / [d have
            // somewhere to jump between.
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":\"x\",\"diagnostics\":[" ++
                "{{\"range\":{{\"start\":{{\"line\":1,\"character\":0}},\"end\":{{\"line\":1,\"character\":1}}}},\"severity\":1,\"message\":\"mock error\"}}," ++
                "{{\"range\":{{\"start\":{{\"line\":2,\"character\":0}},\"end\":{{\"line\":2,\"character\":1}}}},\"severity\":2,\"message\":\"mock warn\"}}" ++
                "]}}}}", .{});
        } else if (eql(method, "textDocument/didChange")) {
            const kind = if (changeHasRange(obj)) "INCREMENTAL" else "FULL";
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":\"x\"," ++
                "\"diagnostics\":[{{\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":1}}}}," ++
                "\"severity\":2,\"message\":\"{s}\"}}]}}}}", .{kind});
        } else if (eql(method, "textDocument/completion")) {
            // Two plain items, a snippet item (insertTextFormat 2, two
            // placeholders and a final stop), and a textEdit item whose range
            // replaces the four characters before the cursor — the client must
            // honour that range instead of guessing the identifier prefix —
            // carrying an additionalTextEdits import line as well.
            const pos = getField(getField(parsed.value, "params") orelse parsed.value, "position");
            const pline: i64 = if (pos) |p| (intField(p, "line") orelse 0) else 0;
            const pchar: i64 = if (pos) |p| (intField(p, "character") orelse 0) else 0;
            const from = if (pchar >= 4) pchar - 4 else 0;
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"items\":[" ++
                "{{\"label\":\"mockComplete\",\"insertText\":\"mockComplete\"}}," ++
                "{{\"label\":\"mockOther\",\"insertText\":\"mockOther\"}}," ++
                "{{\"label\":\"snipItem\",\"insertTextFormat\":2," ++
                "\"insertText\":\"call(${{1:first}}, ${{2:second}})$0\"}}," ++
                "{{\"label\":\"multiItem\",\"insertTextFormat\":2," ++
                "\"insertText\":\"if ${{1:cond}} {{\\n    $0\\n}}\"}}," ++
                "{{\"label\":\"choiceItem\",\"insertTextFormat\":2," ++
                "\"insertText\":\"${{1|const,var,let|}} name = $0;\"}}," ++
                "{{\"label\":\"editItem\",\"textEdit\":{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}}," ++
                "\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":\"EDITED\"}}," ++
                "\"additionalTextEdits\":[{{\"range\":{{\"start\":{{\"line\":0,\"character\":0}}," ++
                "\"end\":{{\"line\":0,\"character\":0}}}},\"newText\":\"IMPORT\\n\"}}]}}]}}}}", .{ id orelse 0, pline, from, pline, pchar });
        } else if (eql(method, "textDocument/signatureHelp")) {
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"signatures\":[" ++
                "{{\"label\":\"mockFn(a: int, b: int)\",\"parameters\":[{{\"label\":[7,13]}},{{\"label\":[15,21]}}]}}," ++
                "{{\"label\":\"mockFn(a: str)\",\"parameters\":[{{\"label\":[7,13]}}]}}]," ++
                "\"activeSignature\":0,\"activeParameter\":0}}}}", .{id orelse 0});
        } else if (eql(method, "textDocument/inlayHint")) {
            // A type hint after "a" on line 0 (char 7), label as parts to
            // exercise the client's label flattening: ": " + "i32" -> ": i32".
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"position\":{{\"line\":0,\"character\":7}}," ++
                "\"label\":[{{\"value\":\": \"}},{{\"value\":\"i32\"}}],\"kind\":1}}]}}", .{id orelse 0});
        } else if (eql(method, "workspace/symbol")) {
            // Two project-wide symbols, in different files, so the picker has
            // something cross-file to jump to. The query is echoed into the
            // first name to prove it reached the server.
            const q = strField(getField(parsed.value, "params") orelse parsed.value, "query") orelse "";
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"name\":\"wsymFor_{s}\",\"kind\":12,\"location\":{{\"uri\":\"{s}\"," ++
                "\"range\":{{\"start\":{{\"line\":2,\"character\":6}},\"end\":{{\"line\":2,\"character\":6}}}}}}}}," ++
                "{{\"name\":\"otherSymbol\",\"kind\":23,\"location\":{{\"uri\":\"file:///tmp/zedit_it_other.zig\"," ++
                "\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}}}}}}]}}", .{ id orelse 0, q, doc_uri });
        } else if (eql(method, "textDocument/documentSymbol")) {
            // A nested DocumentSymbol[] (struct Foo with a child field, plus a
            // top-level fn main) to exercise the client's flattening.
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[" ++
                "{{\"name\":\"Foo\",\"kind\":23,\"selectionRange\":{{\"start\":{{\"line\":0,\"character\":6}},\"end\":{{\"line\":0,\"character\":7}}}},\"children\":[" ++
                "{{\"name\":\"field_a\",\"kind\":8,\"selectionRange\":{{\"start\":{{\"line\":0,\"character\":6}},\"end\":{{\"line\":0,\"character\":7}}}}}}]}}," ++
                "{{\"name\":\"main\",\"kind\":12,\"selectionRange\":{{\"start\":{{\"line\":2,\"character\":6}},\"end\":{{\"line\":2,\"character\":7}}}}}}]}}", .{id orelse 0});
        } else if (eql(method, "textDocument/hover")) {
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"contents\":\"mock hover\"}}}}", .{id orelse 0});
        } else if (eql(method, "textDocument/definition")) {
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"uri\":\"file:///x\"," ++
                "\"range\":{{\"start\":{{\"line\":2,\"character\":0}},\"end\":{{\"line\":2,\"character\":0}}}}}}}}", .{id orelse 0});
        } else if (eql(method, "textDocument/implementation")) {
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"uri\":\"file:///x\"," ++
                "\"range\":{{\"start\":{{\"line\":1,\"character\":0}},\"end\":{{\"line\":1,\"character\":0}}}}}}}}", .{id orelse 0});
        } else if (eql(method, "textDocument/typeDefinition")) {
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"uri\":\"file:///x\"," ++
                "\"range\":{{\"start\":{{\"line\":2,\"character\":6}},\"end\":{{\"line\":2,\"character\":6}}}}}}]}}", .{id orelse 0});
        } else if (eql(method, "textDocument/rename")) {
            const new_name = strField(getField(parsed.value, "params") orelse parsed.value, "newName") orelse "x";
            var extra: []const u8 = "";
            defer if (extra.len > 0) gpa.free(extra);
            if (xfile) {
                if (std.mem.lastIndexOfScalar(u8, doc_uri, '/')) |slash| {
                    extra = std.fmt.allocPrint(gpa, ",\"{s}zedit_it_other.zig\":[{{\"range\":{{\"start\":{{\"line\":0,\"character\":6}}," ++
                        "\"end\":{{\"line\":0,\"character\":7}}}},\"newText\":\"{s}\"}}]", .{ doc_uri[0 .. slash + 1], new_name }) catch "";
                }
            }
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"changes\":{{\"{s}\":[{{\"range\":{{\"start\":{{\"line\":0,\"character\":6}}," ++
                "\"end\":{{\"line\":0,\"character\":7}}}},\"newText\":\"{s}\"}}]{s}}}}}}}", .{ id orelse 0, doc_uri, new_name, extra });
        } else if (eql(method, "textDocument/codeAction")) {
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"title\":\"Rename a to A\",\"kind\":\"quickfix\",\"edit\":{{\"changes\":{{\"{s}\":" ++
                "[{{\"range\":{{\"start\":{{\"line\":0,\"character\":6}},\"end\":{{\"line\":0,\"character\":7}}}},\"newText\":\"A\"}}]}}}}}}," ++
                "{{\"title\":\"Run mock command\",\"command\":\"mock.run\"}}]}}", .{ id orelse 0, doc_uri });
        } else if (eql(method, "workspace/executeCommand")) {
            const cmd = strField(getField(parsed.value, "params") orelse parsed.value, "command") orelse "";
            if (eql(cmd, "mock.run") and doc_uri.len > 0) {
                send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":999,\"method\":\"workspace/applyEdit\",\"params\":{{\"edit\":{{\"changes\":{{\"{s}\":" ++
                    "[{{\"range\":{{\"start\":{{\"line\":1,\"character\":6}},\"end\":{{\"line\":1,\"character\":7}}}},\"newText\":\"B\"}}]}}}}}}}}", .{doc_uri});
            }
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id orelse 0});
        } else if (eql(method, "textDocument/references")) {
            // Two in-document references ("a" on line 0 and "c" on line 2).
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":0,\"character\":6}},\"end\":{{\"line\":0,\"character\":7}}}}}}," ++
                "{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":2,\"character\":6}},\"end\":{{\"line\":2,\"character\":7}}}}}}]}}", .{ id orelse 0, doc_uri, doc_uri });
        } else if (eql(method, "textDocument/formatting")) {
            // One idempotent whole-document edit that appends a "// fmt"
            // comment to line 0 (multi-line range AND multi-line newText).
            send(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":2,\"character\":12}}}}," ++
                "\"newText\":\"const a = 1; // fmt\\nconst b = 2;\\nconst c = 3;\"}}]}}", .{id orelse 0});
        }
        // Everything else (initialized, the applyEdit response, etc.) is ignored.
    }
}

// --- message sending --------------------------------------------------------

/// A formatted JSON-RPC message (the format string uses `{{`/`}}` for literal
/// braces), framed with Content-Length and written to stdout.
fn send(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const body = std.fmt.allocPrint(gpa, fmt, args) catch return;
    defer gpa.free(body);
    var hdr: [64]u8 = undefined;
    writeAll(std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return);
    writeAll(body);
}

var io: std.Io = undefined; // set once in main, for writeAll

fn writeAll(bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch return;
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

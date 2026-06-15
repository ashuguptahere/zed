//! Tree-sitter syntax highlighting (vendored runtime + grammar, via the C API).
//!
//! Parses the document and runs the grammar's own `highlights.scm` query to
//! produce a per-byte `Style` array. This is the "real" highlighting that
//! understands structure, replacing the per-line lexer for languages we have a
//! grammar for. Reparsing is incremental: the previous tree is kept and a
//! single edit (derived from the prefix/suffix diff of old vs new text) is
//! applied so tree-sitter only re-parses the changed span. Best-effort: if the
//! parser or query fails to build, the editor falls back to `syntax.zig`.
//!
//! The runtime and the tree-sitter-zig grammar are vendored under `vendor/` and
//! compiled by `build.zig`; see CLAUDE.md for how to add more grammars.

const std = @import("std");
const syntax = @import("syntax.zig");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_zig() *const c.TSLanguage;

const highlights_zig = @embedFile("ts_highlights_zig");

pub const Highlighter = struct {
    gpa: Allocator,
    parser: *c.TSParser,
    query: *c.TSQuery,
    capture_styles: []syntax.Style, // capture id -> style
    tree: ?*c.TSTree, // last parse, kept for incremental reparsing
    content: std.ArrayList(u8), // copy of the last-parsed text, to diff against

    /// Create a highlighter for `lang`, or null if unsupported / setup failed.
    pub fn init(gpa: Allocator, lang: syntax.Language) ?Highlighter {
        const ts_lang: *const c.TSLanguage, const query_src: []const u8 = switch (lang) {
            .zig => .{ tree_sitter_zig(), highlights_zig },
            else => return null,
        };

        const parser = c.ts_parser_new() orelse return null;
        errdefer c.ts_parser_delete(parser);
        if (!c.ts_parser_set_language(parser, ts_lang)) return null;

        var err_off: u32 = 0;
        var err_type: c.TSQueryError = 0;
        const query = c.ts_query_new(ts_lang, query_src.ptr, @intCast(query_src.len), &err_off, &err_type) orelse return null;
        errdefer c.ts_query_delete(query);

        const n = c.ts_query_capture_count(query);
        const styles = gpa.alloc(syntax.Style, n) catch return null;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var len: u32 = 0;
            const name = c.ts_query_capture_name_for_id(query, i, &len);
            styles[i] = mapCapture(name[0..len]);
        }

        return .{ .gpa = gpa, .parser = parser, .query = query, .capture_styles = styles, .tree = null, .content = .empty };
    }

    pub fn deinit(self: *Highlighter) void {
        if (self.tree) |t| c.ts_tree_delete(t);
        self.content.deinit(self.gpa);
        self.gpa.free(self.capture_styles);
        c.ts_query_delete(self.query);
        c.ts_parser_delete(self.parser);
    }

    /// (Re)parse `content`, reusing the previous tree incrementally: a single
    /// edit derived from the common prefix/suffix of the old and new text means
    /// tree-sitter only re-parses the region that changed. Does not run the
    /// highlight query — call `queryRange` for that.
    pub fn reparse(self: *Highlighter, content: []const u8) void {
        if (content.len == 0) {
            self.replaceTree(null);
            self.rememberContent(content);
            return;
        }
        const old_tree: ?*c.TSTree = if (self.tree) |t| blk: {
            const edit = computeEdit(self.content.items, content);
            c.ts_tree_edit(t, &edit);
            break :blk t;
        } else null;
        const tree = c.ts_parser_parse_string(self.parser, old_tree, content.ptr, @intCast(content.len)) orelse {
            self.replaceTree(null);
            return;
        };
        self.replaceTree(tree);
        self.rememberContent(content);
    }

    /// Run the highlight query over document bytes [start, end) and fill `out`
    /// (one `Style` per byte, `out[i]` is the style of byte `start + i`). Only
    /// nodes intersecting the range are visited, so this is O(visible), not
    /// O(document). Later captures win on overlap (nvim convention).
    pub fn queryRange(self: *Highlighter, start: usize, end: usize, out: []syntax.Style) void {
        @memset(out, .normal);
        const tree = self.tree orelse return;
        if (end <= start) return;
        const root = c.ts_tree_root_node(tree);

        const cursor = c.ts_query_cursor_new() orelse return;
        defer c.ts_query_cursor_delete(cursor);
        _ = c.ts_query_cursor_set_byte_range(cursor, @intCast(start), @intCast(end));
        c.ts_query_cursor_exec(cursor, self.query, root);

        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            const caps = match.captures[0..match.capture_count];
            for (caps) |cap| {
                const style = self.capture_styles[cap.index];
                if (style == .normal) continue;
                const ns = c.ts_node_start_byte(cap.node);
                const ne = c.ts_node_end_byte(cap.node);
                // Clamp the node's absolute byte span to the queried window.
                const lo = if (ns > start) ns - start else 0;
                if (ne <= start) continue;
                var k: usize = lo;
                const hi = @min(ne - start, out.len);
                while (k < hi) : (k += 1) out[k] = style;
            }
        }
    }

    fn replaceTree(self: *Highlighter, tree: ?*c.TSTree) void {
        if (self.tree) |t| c.ts_tree_delete(t);
        self.tree = tree;
    }

    fn rememberContent(self: *Highlighter, content: []const u8) void {
        self.content.clearRetainingCapacity();
        self.content.appendSlice(self.gpa, content) catch self.content.clearRetainingCapacity();
    }
};

/// Derive a single `TSInputEdit` from the common prefix and suffix of the old
/// and new text. The changed span [start, *_end) covers every actual change
/// (even several at once), so tree-sitter reparses conservatively but correctly.
fn computeEdit(old: []const u8, new: []const u8) c.TSInputEdit {
    const min = @min(old.len, new.len);
    var p: usize = 0;
    while (p < min and old[p] == new[p]) p += 1;
    var s: usize = 0;
    while (s < min - p and old[old.len - 1 - s] == new[new.len - 1 - s]) s += 1;

    const old_end = old.len - s;
    const new_end = new.len - s;
    return .{
        .start_byte = @intCast(p),
        .old_end_byte = @intCast(old_end),
        .new_end_byte = @intCast(new_end),
        .start_point = pointAt(new, p),
        .old_end_point = pointAt(old, old_end),
        .new_end_point = pointAt(new, new_end),
    };
}

/// Byte offset -> (row, byte-column) point.
fn pointAt(content: []const u8, byte: usize) c.TSPoint {
    var row: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < byte and i < content.len) : (i += 1) {
        if (content[i] == '\n') {
            row += 1;
            line_start = i + 1;
        }
    }
    return .{ .row = row, .column = @intCast(byte - line_start) };
}

test "computeEdit prefix/suffix diff" {
    // "abXcd" -> "abYYcd": prefix "ab" (2), suffix "cd" (2).
    const e = computeEdit("abXcd", "abYYcd");
    try std.testing.expectEqual(@as(u32, 2), e.start_byte);
    try std.testing.expectEqual(@as(u32, 3), e.old_end_byte);
    try std.testing.expectEqual(@as(u32, 4), e.new_end_byte);
}

test "pointAt rows and columns" {
    const text = "ab\ncde\nf";
    try std.testing.expectEqual(@as(u32, 0), pointAt(text, 1).row);
    const p = pointAt(text, 5); // 'd' on line 1 (0-based), col 2
    try std.testing.expectEqual(@as(u32, 1), p.row);
    try std.testing.expectEqual(@as(u32, 2), p.column);
}

/// Map an nvim/helix highlight capture name to our `Style`. Prefix-based so
/// e.g. `@keyword.return` and `@function.call` are handled without an exact
/// list. Predicates in the query are not evaluated (a minor over-highlight at
/// worst).
fn mapCapture(name: []const u8) syntax.Style {
    const p = struct {
        fn has(n: []const u8, prefix: []const u8) bool {
            return std.mem.startsWith(u8, n, prefix);
        }
    };
    if (p.has(name, "keyword")) return .keyword;
    if (p.has(name, "comment")) return .comment;
    if (p.has(name, "string")) return .string_;
    if (p.has(name, "character")) return .char_;
    if (p.has(name, "number") or p.has(name, "float") or p.has(name, "boolean")) return .number;
    if (p.has(name, "function") or p.has(name, "method")) return .function;
    if (p.has(name, "constructor")) return .function;
    if (p.has(name, "type")) return .type_;
    if (p.has(name, "constant") or p.has(name, "variable.builtin") or p.has(name, "module")) return .builtin;
    if (p.has(name, "operator")) return .operator;
    if (p.has(name, "attribute") or p.has(name, "annotation")) return .preproc;
    return .normal;
}

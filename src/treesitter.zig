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
extern fn tree_sitter_c() *const c.TSLanguage;
extern fn tree_sitter_python() *const c.TSLanguage;
extern fn tree_sitter_json() *const c.TSLanguage;
extern fn tree_sitter_javascript() *const c.TSLanguage;
extern fn tree_sitter_typescript() *const c.TSLanguage;
extern fn tree_sitter_rust() *const c.TSLanguage;
extern fn tree_sitter_go() *const c.TSLanguage;
extern fn tree_sitter_html() *const c.TSLanguage;
extern fn tree_sitter_markdown() *const c.TSLanguage;
extern fn tree_sitter_markdown_inline() *const c.TSLanguage;

const highlights_zig = @embedFile("ts_highlights_zig");
const highlights_c = @embedFile("ts_highlights_c");
const highlights_python = @embedFile("ts_highlights_python");
const highlights_json = @embedFile("ts_highlights_json");
const highlights_javascript = @embedFile("ts_highlights_javascript");
// TypeScript's query only adds type/keyword patterns; it layers on JavaScript's.
const highlights_typescript = highlights_javascript ++ "\n" ++ @embedFile("ts_highlights_typescript");
const highlights_rust = @embedFile("ts_highlights_rust");
const highlights_go = @embedFile("ts_highlights_go");
const highlights_html = @embedFile("ts_highlights_html");
const highlights_markdown = @embedFile("ts_highlights_markdown");
const highlights_markdown_inline = @embedFile("ts_highlights_markdown_inline");

/// One parse+query layer: a parser, its tree, the highlight query and the
/// capture-id -> style table. Markdown uses two (block + inline).
const Layer = struct {
    parser: *c.TSParser,
    query: *c.TSQuery,
    styles: []syntax.Style,
    tree: ?*c.TSTree = null,

    fn init(gpa: Allocator, language: *const c.TSLanguage, query_src: []const u8) ?Layer {
        const parser = c.ts_parser_new() orelse return null;
        errdefer c.ts_parser_delete(parser);
        if (!c.ts_parser_set_language(parser, language)) return null;
        var err_off: u32 = 0;
        var err_type: c.TSQueryError = 0;
        const query = c.ts_query_new(language, query_src.ptr, @intCast(query_src.len), &err_off, &err_type) orelse return null;
        errdefer c.ts_query_delete(query);
        const n = c.ts_query_capture_count(query);
        const styles = gpa.alloc(syntax.Style, n) catch return null;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var len: u32 = 0;
            styles[i] = mapCapture(c.ts_query_capture_name_for_id(query, i, &len)[0..len]);
        }
        return .{ .parser = parser, .query = query, .styles = styles };
    }

    fn deinit(self: *Layer, gpa: Allocator) void {
        if (self.tree) |t| c.ts_tree_delete(t);
        c.ts_query_delete(self.query);
        c.ts_parser_delete(self.parser);
        gpa.free(self.styles);
    }

    /// Incrementally reparse `content`, applying `edit` to the old tree when one
    /// exists (caller passes the same edit to every layer over the same text).
    fn reparse(self: *Layer, content: []const u8, edit: ?c.TSInputEdit) void {
        const old: ?*c.TSTree = if (self.tree) |t| blk: {
            if (edit) |e| c.ts_tree_edit(t, &e);
            break :blk t;
        } else null;
        const new = c.ts_parser_parse_string(self.parser, old, content.ptr, @intCast(content.len));
        if (self.tree) |t| c.ts_tree_delete(t);
        self.tree = new;
    }

    /// Fill `out[0..]` (representing document bytes [start, end)) from this
    /// layer's captures. With `overwrite` false, only `.normal` bytes are set,
    /// so a secondary layer can fill gaps the primary left.
    fn fill(self: *const Layer, start: usize, end: usize, out: []syntax.Style, overwrite: bool) void {
        const tree = self.tree orelse return;
        const cursor = c.ts_query_cursor_new() orelse return;
        defer c.ts_query_cursor_delete(cursor);
        _ = c.ts_query_cursor_set_byte_range(cursor, @intCast(start), @intCast(end));
        c.ts_query_cursor_exec(cursor, self.query, c.ts_tree_root_node(tree));
        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            for (match.captures[0..match.capture_count]) |cap| {
                const style = self.styles[cap.index];
                if (style == .normal) continue;
                const ne = c.ts_node_end_byte(cap.node);
                if (ne <= start) continue;
                const ns = c.ts_node_start_byte(cap.node);
                var k: usize = if (ns > start) ns - start else 0;
                const hi = @min(ne - start, out.len);
                while (k < hi) : (k += 1) {
                    if (overwrite or out[k] == .normal) out[k] = style;
                }
            }
        }
    }
};

pub const Highlighter = struct {
    gpa: Allocator,
    primary: Layer,
    secondary: ?Layer, // markdown's inline layer; null otherwise
    content: std.ArrayList(u8), // copy of the last-parsed text, to diff against

    /// Create a highlighter for `lang`, or null if unsupported / setup failed.
    pub fn init(gpa: Allocator, lang: syntax.Language) ?Highlighter {
        const ts_lang: *const c.TSLanguage, const query_src: []const u8 = switch (lang) {
            .zig => .{ tree_sitter_zig(), highlights_zig },
            .c => .{ tree_sitter_c(), highlights_c },
            .python => .{ tree_sitter_python(), highlights_python },
            .json => .{ tree_sitter_json(), highlights_json },
            .javascript => .{ tree_sitter_javascript(), highlights_javascript },
            .typescript => .{ tree_sitter_typescript(), highlights_typescript },
            .rust => .{ tree_sitter_rust(), highlights_rust },
            .go => .{ tree_sitter_go(), highlights_go },
            .html => .{ tree_sitter_html(), highlights_html },
            .markdown => .{ tree_sitter_markdown(), highlights_markdown },
            .none => return null, // falls back to the lexer
        };

        var primary = Layer.init(gpa, ts_lang, query_src) orelse return null;
        // Markdown block structure (primary) + inline structure (secondary).
        const secondary: ?Layer = if (lang == .markdown)
            Layer.init(gpa, tree_sitter_markdown_inline(), highlights_markdown_inline)
        else
            null;
        if (lang == .markdown and secondary == null) {
            primary.deinit(gpa);
            return null;
        }
        return .{ .gpa = gpa, .primary = primary, .secondary = secondary, .content = .empty };
    }

    pub fn deinit(self: *Highlighter) void {
        self.primary.deinit(self.gpa);
        if (self.secondary) |*s| s.deinit(self.gpa);
        self.content.deinit(self.gpa);
    }

    /// (Re)parse `content`, reusing the previous tree(s) incrementally: a single
    /// edit derived from the common prefix/suffix of the old and new text means
    /// tree-sitter only re-parses the region that changed. Run `queryRange` for
    /// the styles.
    pub fn reparse(self: *Highlighter, content: []const u8) void {
        const edit: ?c.TSInputEdit = if (self.primary.tree != null and content.len > 0 and self.content.items.len > 0)
            computeEdit(self.content.items, content)
        else
            null;
        if (content.len == 0) {
            self.primary.reparse(content, null);
            if (self.secondary) |*s| s.reparse(content, null);
            self.rememberContent(content);
            return;
        }
        self.primary.reparse(content, edit);
        if (self.secondary) |*s| s.reparse(content, edit);
        self.rememberContent(content);
    }

    /// Fill `out` (one `Style` per byte of [start, end)) from the primary layer,
    /// then let the secondary layer fill any bytes still left `.normal`. Only
    /// nodes intersecting the range are visited, so this is O(visible).
    pub fn queryRange(self: *Highlighter, start: usize, end: usize, out: []syntax.Style) void {
        @memset(out, .normal);
        if (end <= start) return;
        self.primary.fill(start, end, out, true);
        if (self.secondary) |*s| s.fill(start, end, out, false);
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

test "every vendored grammar and its highlight query load" {
    inline for (.{ syntax.Language.zig, .c, .python, .json, .javascript, .typescript, .rust, .go, .html, .markdown }) |lang| {
        var h = Highlighter.init(std.testing.allocator, lang) orelse return error.GrammarFailedToLoad;
        h.deinit();
    }
}

test "grammars produce highlights" {
    const cases = .{
        .{ syntax.Language.c, "int main(void) { return 0; }" },
        .{ syntax.Language.python, "def f():\n    return 1\n" },
        .{ syntax.Language.json, "{\"a\": 1, \"b\": true}" },
        .{ syntax.Language.javascript, "const x = (a) => a + 1;" },
        .{ syntax.Language.typescript, "function f(a: number): number { return a; }" },
        .{ syntax.Language.rust, "fn main() { let x = 1; }" },
        .{ syntax.Language.go, "func main() { x := 1 }" },
        .{ syntax.Language.html, "<div class=\"x\">hi</div>" },
        .{ syntax.Language.markdown, "# Title\n\nsome **bold** text\n" },
    };
    inline for (cases) |case| {
        var h = Highlighter.init(std.testing.allocator, case[0]).?;
        defer h.deinit();
        const src = case[1];
        var styles: [src.len]syntax.Style = undefined;
        h.reparse(src);
        h.queryRange(0, src.len, &styles);
        var any = false;
        for (styles) |s| {
            if (s != .normal) {
                any = true;
                break;
            }
        }
        try std.testing.expect(any);
    }
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
    if (p.has(name, "tag")) return .keyword; // HTML/JSX tags
    // Markdown / prose (`@text.*`) and meaningful punctuation.
    if (p.has(name, "text.title") or p.has(name, "markup.heading")) return .keyword;
    if (p.has(name, "text.literal") or p.has(name, "markup.raw")) return .string_;
    if (p.has(name, "text.uri") or p.has(name, "text.reference") or p.has(name, "text.link")) return .function;
    if (p.has(name, "text.emphasis") or p.has(name, "text.strong")) return .builtin;
    if (p.has(name, "punctuation.special")) return .operator;
    return .normal;
}

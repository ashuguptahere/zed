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

/// Compiled highlight queries, one per grammar, kept for the life of the
/// process. Compiling one costs ~14 ms for a large grammar, and a query is
/// immutable once built — so every buffer and the picker's preview share it
/// instead of each paying that price. (C-allocated, freed by process exit.)
var query_cache: [16]?struct { src: []const u8, query: *c.TSQuery } = @splat(null);

fn cachedQuery(language: *const c.TSLanguage, query_src: []const u8) ?*c.TSQuery {
    for (query_cache) |slot| {
        if (slot) |s| {
            // Each grammar has exactly one query source, embedded at build
            // time, so identity of the slice is identity of the grammar.
            if (s.src.ptr == query_src.ptr and s.src.len == query_src.len) return s.query;
        }
    }
    var err_off: u32 = 0;
    var err_type: c.TSQueryError = 0;
    const query = c.ts_query_new(language, query_src.ptr, @intCast(query_src.len), &err_off, &err_type) orelse {
        std.log.scoped(.treesitter).err("highlights query failed to compile: error {d} at byte {d}", .{ err_type, err_off });
        return null;
    };
    for (&query_cache) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .src = query_src, .query = query };
            break;
        }
    }
    return query;
}

/// One parse+query layer: a parser, its tree, the shared highlight query and
/// the capture-id -> style table. Markdown uses two (block + inline).
const Layer = struct {
    parser: *c.TSParser,
    query: *c.TSQuery,
    styles: []syntax.Style,
    tree: ?*c.TSTree = null,

    fn init(gpa: Allocator, language: *const c.TSLanguage, query_src: []const u8) ?Layer {
        const parser = c.ts_parser_new() orelse return null;
        errdefer c.ts_parser_delete(parser);
        if (!c.ts_parser_set_language(parser, language)) return null;
        const query = cachedQuery(language, query_src) orelse return null;
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
        // `query` is shared via `query_cache` — never deleted here.
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
            .none, .diff => return null, // fall back to the lexer
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

    /// A byte range in the parsed document.
    pub const Span = struct { start: usize, end: usize };

    /// The innermost node containing `byte` whose type is one of `kinds`
    /// (grammar node names — see the tables in editor.zig). `inner` returns the
    /// node's `body` instead, minus its braces, which is what `if`/`ic` select.
    pub fn enclosing(self: *Highlighter, byte: usize, kinds: []const []const u8, inner: bool) ?Span {
        const tree = self.primary.tree orelse return null;
        const root = c.ts_tree_root_node(tree);
        const syms = resolveKinds(c.ts_tree_language(tree), kinds);
        var node = c.ts_node_descendant_for_byte_range(root, @intCast(byte), @intCast(byte));
        while (!c.ts_node_is_null(node)) : (node = c.ts_node_parent(node)) {
            if (syms.has(c.ts_node_symbol(node))) {
                if (!inner) return .{ .start = c.ts_node_start_byte(node), .end = c.ts_node_end_byte(node) };
                const body = c.ts_node_child_by_field_name(node, "body", 4);
                const target = if (c.ts_node_is_null(body)) node else body;
                var s = c.ts_node_start_byte(target);
                var e = c.ts_node_end_byte(target);
                // A braced body selects what is between the braces.
                if (!c.ts_node_is_null(body) and e > s + 1) {
                    const first = c.ts_node_child(target, 0);
                    if (!c.ts_node_is_null(first)) {
                        const ftype = std.mem.sliceTo(c.ts_node_type(first), 0);
                        if (ftype.len == 1 and (ftype[0] == '{' or ftype[0] == '(')) {
                            s = c.ts_node_end_byte(first);
                            e -= 1;
                        }
                    }
                }
                if (e < s) return null;
                return .{ .start = s, .end = e };
            }
        }
        return null;
    }

    /// The argument or parameter under `byte` — the `ia`/`aa` objects.
    /// `kinds` names the *list* nodes (`argument_list`, `formal_parameters`,
    /// …); the item is whichever of the list's named children holds the
    /// cursor, so the grammar decides where one argument ends and the next
    /// begins rather than a comma count that a nested call or a string would
    /// fool.
    ///
    /// `around` swallows the separator joining the item to its neighbour: the
    /// text up to the next item when there is one, else the text back from the
    /// previous item. Deleting it therefore leaves a well-formed list, which
    /// is the whole point of the object (and matches targets.vim).
    pub fn listItem(self: *Highlighter, byte: usize, kinds: []const []const u8, around: bool) ?Span {
        const tree = self.primary.tree orelse return null;
        const root = c.ts_tree_root_node(tree);
        const syms = resolveKinds(c.ts_tree_language(tree), kinds);
        if (syms.len == 0) return null;
        var node = c.ts_node_descendant_for_byte_range(root, @intCast(byte), @intCast(byte));
        while (!c.ts_node_is_null(node)) : (node = c.ts_node_parent(node)) {
            if (!syms.has(c.ts_node_symbol(node))) continue;
            const n = c.ts_node_named_child_count(node);
            if (n == 0) return null;
            // The first item ending after the cursor: the one it is inside, or
            // the next one when it sits on a comma or the whitespace after it.
            var k: u32 = n - 1;
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                if (byte < c.ts_node_end_byte(c.ts_node_named_child(node, i))) {
                    k = i;
                    break;
                }
            }
            const item = c.ts_node_named_child(node, k);
            const start = c.ts_node_start_byte(item);
            const end = c.ts_node_end_byte(item);
            if (!around) return .{ .start = start, .end = end };
            if (k + 1 < n) return .{ .start = start, .end = c.ts_node_start_byte(c.ts_node_named_child(node, k + 1)) };
            if (k > 0) return .{ .start = c.ts_node_end_byte(c.ts_node_named_child(node, k - 1)), .end = end };
            return .{ .start = start, .end = end }; // the only item: nothing to join
        }
        return null;
    }

    /// The comment under `byte` — the `iC`/`aC` objects. `around` extends over
    /// a run of comment nodes on consecutive lines at the same column, which
    /// is how a block of `//` lines is written and how one wants to delete it;
    /// a trailing comment beside code keeps its own column and so stays alone.
    pub fn commentSpan(self: *Highlighter, byte: usize, kinds: []const []const u8, around: bool) ?Span {
        const tree = self.primary.tree orelse return null;
        const root = c.ts_tree_root_node(tree);
        const syms = resolveKinds(c.ts_tree_language(tree), kinds);
        if (syms.len == 0) return null;
        var node = c.ts_node_descendant_for_byte_range(root, @intCast(byte), @intCast(byte));
        while (!c.ts_node_is_null(node)) : (node = c.ts_node_parent(node)) {
            if (!syms.has(c.ts_node_symbol(node))) continue;
            if (!around) return .{ .start = c.ts_node_start_byte(node), .end = c.ts_node_end_byte(node) };
            var first = node;
            var last = node;
            const col = c.ts_node_start_point(node).column;
            while (true) {
                const prev = c.ts_node_prev_named_sibling(first);
                if (c.ts_node_is_null(prev) or !syms.has(c.ts_node_symbol(prev))) break;
                if (c.ts_node_start_point(prev).column != col) break;
                if (c.ts_node_end_point(prev).row + 1 != c.ts_node_start_point(first).row) break;
                first = prev;
            }
            while (true) {
                const next = c.ts_node_next_named_sibling(last);
                if (c.ts_node_is_null(next) or !syms.has(c.ts_node_symbol(next))) break;
                if (c.ts_node_start_point(next).column != col) break;
                if (c.ts_node_end_point(last).row + 1 != c.ts_node_start_point(next).row) break;
                last = next;
            }
            return .{ .start = c.ts_node_start_byte(first), .end = c.ts_node_end_byte(last) };
        }
        return null;
    }

    /// The start byte of the next (or previous) node of one of `kinds`,
    /// relative to `byte` — the `]f` / `[f` motions.
    ///
    /// The search is pruned and stops at the first hit rather than walking the
    /// whole tree: forwards it skips any subtree ending at or before the
    /// cursor, backwards any subtree starting at or after it. Because a
    /// depth-first walk visits nodes in document order (and its mirror visits
    /// them in reverse), the first match found *is* the nearest one. On a
    /// 320 KB file this took `]f` from 12 ms to microseconds.
    pub fn seekNode(self: *Highlighter, byte: usize, kinds: []const []const u8, forward: bool) ?usize {
        const tree = self.primary.tree orelse return null;
        const root = c.ts_tree_root_node(tree);
        const syms = resolveKinds(c.ts_tree_language(tree), kinds);
        if (syms.len == 0) return null;
        return if (forward) firstAfter(root, byte, syms) else lastBefore(root, byte, syms);
    }

    /// The grammar's numeric ids for `kinds`. Resolving once per search lets
    /// the walk compare a u16 per node instead of running strcmp against every
    /// name — the node type string never has to be touched.
    const Symbols = struct {
        ids: [8]c.TSSymbol = @splat(0),
        len: usize = 0,

        fn has(self: Symbols, sym: c.TSSymbol) bool {
            for (self.ids[0..self.len]) |id| {
                if (id == sym) return true;
            }
            return false;
        }
    };

    fn resolveKinds(language: ?*const c.TSLanguage, kinds: []const []const u8) Symbols {
        var out: Symbols = .{};
        const lang = language orelse return out;
        for (kinds) |k| {
            if (out.len == out.ids.len) break;
            const sym = c.ts_language_symbol_for_name(lang, k.ptr, @intCast(k.len), true);
            if (sym != 0) {
                out.ids[out.len] = sym;
                out.len += 1;
            }
        }
        return out;
    }

    /// Nearest matching node starting after `byte`, in document order.
    fn firstAfter(node: c.TSNode, byte: usize, syms: Symbols) ?usize {
        if (c.ts_node_end_byte(node) <= byte) return null; // wholly before the cursor
        const start = c.ts_node_start_byte(node);
        if (start > byte and syms.has(c.ts_node_symbol(node))) return start;
        var i: u32 = 0;
        const n = c.ts_node_child_count(node);
        while (i < n) : (i += 1) {
            if (firstAfter(c.ts_node_child(node, i), byte, syms)) |hit| return hit;
        }
        return null;
    }

    /// Nearest matching node starting before `byte`, walking in reverse.
    fn lastBefore(node: c.TSNode, byte: usize, syms: Symbols) ?usize {
        const start = c.ts_node_start_byte(node);
        if (start >= byte) return null; // wholly at or after the cursor
        var i = c.ts_node_child_count(node);
        while (i > 0) {
            i -= 1;
            if (lastBefore(c.ts_node_child(node, i), byte, syms)) |hit| return hit;
        }
        return if (syms.has(c.ts_node_symbol(node))) start else null;
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

test "listItem: the argument under the cursor, with and without its comma" {
    const code = "void f(int a, char b) { g(alpha, beta); }\n";
    var h = Highlighter.init(std.testing.allocator, .c).?;
    defer h.deinit();
    h.reparse(code);
    const kinds = &[_][]const u8{ "parameter_list", "argument_list" };
    const at = struct {
        fn f(hay: []const u8, needle: []const u8) usize {
            return std.mem.indexOf(u8, hay, needle).?;
        }
    }.f;

    const cases = .{
        // cursor on          inner          around
        .{ at(code, "int a"), "int a", "int a, " }, // first: takes the comma after
        .{ at(code, "char b"), "char b", ", char b" }, // last: takes the comma before
        .{ at(code, "alpha"), "alpha", "alpha, " },
        .{ at(code, "beta"), "beta", ", beta" },
    };
    inline for (cases) |case| {
        const inner = h.listItem(case[0], kinds, false).?;
        try std.testing.expectEqualStrings(case[1], code[inner.start..inner.end]);
        const outer = h.listItem(case[0], kinds, true).?;
        try std.testing.expectEqualStrings(case[2], code[outer.start..outer.end]);
    }

    // The cursor on the comma itself belongs to the argument after it, and a
    // sole argument has no separator to take.
    const on_comma = h.listItem(at(code, ", char"), kinds, false).?;
    try std.testing.expectEqualStrings("char b", code[on_comma.start..on_comma.end]);
    const lone = "void g(void) { h(only); }\n";
    h.reparse(lone);
    const solo = h.listItem(std.mem.indexOf(u8, lone, "only").?, kinds, true).?;
    try std.testing.expectEqualStrings("only", lone[solo.start..solo.end]);
    // Outside any list there is no object.
    try std.testing.expect(h.listItem(0, kinds, false) == null);
}

test "commentSpan: one comment, or a run of them at the same column" {
    const code = "// one\n// two\nint x = 1; // trailing\n/* block */\n";
    var h = Highlighter.init(std.testing.allocator, .c).?;
    defer h.deinit();
    h.reparse(code);
    const kinds = &[_][]const u8{"comment"};

    const one = std.mem.indexOf(u8, code, "// one").?;
    const inner = h.commentSpan(one + 2, kinds, false).?;
    try std.testing.expectEqualStrings("// one", code[inner.start..inner.end]);
    const run = h.commentSpan(one + 2, kinds, true).?;
    try std.testing.expectEqualStrings("// one\n// two", code[run.start..run.end]);

    // A trailing comment sits at its own column, so the run above stops before
    // it and it stays alone.
    const trailing = std.mem.indexOf(u8, code, "// trailing").?;
    const alone = h.commentSpan(trailing + 2, kinds, true).?;
    try std.testing.expectEqualStrings("// trailing", code[alone.start..alone.end]);

    const block = std.mem.indexOf(u8, code, "/* block */").?;
    const b = h.commentSpan(block + 3, kinds, true).?;
    try std.testing.expectEqualStrings("/* block */", code[b.start..b.end]);
    try std.testing.expect(h.commentSpan(std.mem.indexOf(u8, code, "int x").?, kinds, false) == null);
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




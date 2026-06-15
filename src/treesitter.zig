//! Tree-sitter syntax highlighting (vendored runtime + grammar, via the C API).
//!
//! Parses the whole document and runs the grammar's own `highlights.scm` query
//! to produce a per-byte `Style` array. This is the "real" highlighting that
//! understands structure, replacing the per-line lexer for languages we have a
//! grammar for. It is best-effort: if the parser or query fails to build, the
//! editor falls back to `syntax.zig`.
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

        return .{ .gpa = gpa, .parser = parser, .query = query, .capture_styles = styles };
    }

    pub fn deinit(self: *Highlighter) void {
        self.gpa.free(self.capture_styles);
        c.ts_query_delete(self.query);
        c.ts_parser_delete(self.parser);
    }

    /// Parse `content` and fill `out` (one `Style` per byte; `out.len ==
    /// content.len`). Later captures win on overlap, matching the nvim-style
    /// convention that more specific patterns come later.
    pub fn highlight(self: *Highlighter, content: []const u8, out: []syntax.Style) void {
        @memset(out, .normal);
        if (content.len == 0) return;
        const tree = c.ts_parser_parse_string(self.parser, null, content.ptr, @intCast(content.len)) orelse return;
        defer c.ts_tree_delete(tree);
        const root = c.ts_tree_root_node(tree);

        const cursor = c.ts_query_cursor_new() orelse return;
        defer c.ts_query_cursor_delete(cursor);
        c.ts_query_cursor_exec(cursor, self.query, root);

        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            const caps = match.captures[0..match.capture_count];
            for (caps) |cap| {
                const style = self.capture_styles[cap.index];
                if (style == .normal) continue;
                const start = c.ts_node_start_byte(cap.node);
                const end = c.ts_node_end_byte(cap.node);
                var k: usize = start;
                while (k < end and k < out.len) : (k += 1) out[k] = style;
            }
        }
    }
};

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

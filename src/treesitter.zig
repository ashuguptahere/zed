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
//! Three query files per grammar, all optional beyond the first:
//!
//! - `highlights.scm` — the captures that become styles.
//! - `injections.scm` — regions of the document written in *another* language
//!   (a fenced code block's body, a `<script>` element's text). Each such
//!   region is parsed by that language's grammar into a child layer whose
//!   captures fill those bytes; the layers are kept and reparsed incrementally
//!   rather than rebuilt.
//! - `indents.scm` — which nodes open an indented block, for autoindent.
//!
//! Query predicates (`#eq?`, `#match?`, `#any-of?`, their negations and
//! `#lua-match?` where it means the same as a regex) are evaluated against the
//! captured node's text, so a pattern only fires where the grammar's query says
//! it should. Each predicate's regex is compiled once, beside the compiled
//! query in the process-wide cache — never per node.
//!
//! The runtime and the grammars are vendored under `vendor/` and compiled by
//! `build.zig`; see CLAUDE.md for how to add more.

const std = @import("std");
const syntax = @import("syntax.zig");
const regex = @import("regex.zig");
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

const indents_zig = @embedFile("ts_indents_zig");
const indents_c = @embedFile("ts_indents_c");
const indents_python = @embedFile("ts_indents_python");
const indents_javascript = @embedFile("ts_indents_javascript");
// As with highlights, TypeScript's indent query layers on JavaScript's.
const indents_typescript = indents_javascript ++ "\n" ++ @embedFile("ts_indents_typescript");
const indents_rust = @embedFile("ts_indents_rust");
const indents_go = @embedFile("ts_indents_go");

const injections_html = @embedFile("ts_injections_html");
const injections_markdown = @embedFile("ts_injections_markdown");

/// Everything zedit knows about one grammar. `highlights` doubles as the
/// grammar's identity: it is a distinct comptime slice per grammar, so
/// comparing its pointer identifies a layer's language without a second enum
/// (markdown-inline, reachable only as an injection, has no `syntax.Language`).
const Spec = struct {
    language: *const c.TSLanguage,
    highlights: []const u8,
    injections: ?[]const u8 = null,
    indents: ?[]const u8 = null,
};

fn specFor(lang: syntax.Language) ?Spec {
    return switch (lang) {
        .zig => .{ .language = tree_sitter_zig(), .highlights = highlights_zig, .indents = indents_zig },
        .c => .{ .language = tree_sitter_c(), .highlights = highlights_c, .indents = indents_c },
        .python => .{ .language = tree_sitter_python(), .highlights = highlights_python, .indents = indents_python },
        .json => .{ .language = tree_sitter_json(), .highlights = highlights_json },
        .javascript => .{ .language = tree_sitter_javascript(), .highlights = highlights_javascript, .indents = indents_javascript },
        .typescript => .{ .language = tree_sitter_typescript(), .highlights = highlights_typescript, .indents = indents_typescript },
        .rust => .{ .language = tree_sitter_rust(), .highlights = highlights_rust, .indents = indents_rust },
        .go => .{ .language = tree_sitter_go(), .highlights = highlights_go, .indents = indents_go },
        .html => .{ .language = tree_sitter_html(), .highlights = highlights_html, .injections = injections_html },
        .markdown => .{ .language = tree_sitter_markdown(), .highlights = highlights_markdown, .injections = injections_markdown },
        .none, .diff => null, // fall back to the lexer
    };
}

/// The grammar an injection names — a markdown fence's info string
/// ("```python") or a `#set! injection.language` value. Unknown names simply
/// have no grammar vendored, and the region keeps its parent layer's styling.
fn specByName(name: []const u8) ?Spec {
    if (std.mem.eql(u8, name, "markdown_inline"))
        return .{ .language = tree_sitter_markdown_inline(), .highlights = highlights_markdown_inline };
    // A fence tag is one of the names `syntax` already knows a language by —
    // the same list the file-extension lookup uses, since "py" and "rs" are
    // both. Keeping a second copy here is how `cpp` ended up highlighted as C
    // in one table and unknown in the other.
    const lang = syntax.byName(name);
    return if (lang == .none) null else specFor(lang);
}

/// Backing store for the process-wide query cache's predicate tables (and the
/// regexes they compile). Like the compiled queries themselves these live for
/// the life of the process; keeping them out of the editor's allocator is what
/// makes the cache safe to share between buffers.
var cache_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

/// A compiled query plus everything derived from it that is also immutable:
/// the predicates that gate each pattern and the `#set!` directives attached
/// to them. Compiling a large grammar's query costs ~14 ms, so every buffer
/// and the picker's preview share one. (Never freed — process lifetime.)
const Compiled = struct {
    src: []const u8,
    query: *c.TSQuery,
    preds: []const Pred,
    dirs: []const Dir,

    /// Does `match` survive its pattern's predicates? Patterns without any
    /// (the overwhelming majority) cost one length check.
    fn holds(self: Compiled, match: c.TSQueryMatch, content: []const u8) bool {
        for (self.preds) |p| {
            if (p.pattern != match.pattern_index) continue;
            if (!p.eval(match, content)) return false;
        }
        return true;
    }

    /// Whether pattern `pattern` carries the `#set! key ...` directive.
    fn hasDirective(self: Compiled, pattern: u16, key: []const u8) bool {
        for (self.dirs) |d| {
            if (d.pattern == pattern and std.mem.eql(u8, d.key, key)) return true;
        }
        return false;
    }

    /// The value of pattern `pattern`'s `#set! key value` directive.
    fn directive(self: Compiled, pattern: u16, key: []const u8) ?[]const u8 {
        for (self.dirs) |d| {
            if (d.pattern == pattern and std.mem.eql(u8, d.key, key)) return d.value;
        }
        return null;
    }
};

/// One `#…?` predicate: a filter on the pattern it belongs to.
const Pred = struct {
    const Kind = enum { match, not_match, eq_str, not_eq_str, eq_cap, not_eq_cap, any_of, not_any_of };

    pattern: u16,
    capture: u32,
    kind: Kind,
    re: ?regex.Regex = null,
    strs: []const []const u8 = &.{},
    other: u32 = 0, // the second capture, for `#eq? @a @b`

    fn eval(self: Pred, match: c.TSQueryMatch, content: []const u8) bool {
        // A capture the pattern didn't take part in cannot be judged; let the
        // match through rather than silently dropping it.
        const text = captureText(match, self.capture, content) orelse return true;
        return switch (self.kind) {
            .match => self.re.?.find(text, 0) != null,
            .not_match => self.re.?.find(text, 0) == null,
            .eq_str => std.mem.eql(u8, text, self.strs[0]),
            .not_eq_str => !std.mem.eql(u8, text, self.strs[0]),
            .any_of => anyEql(self.strs, text),
            .not_any_of => !anyEql(self.strs, text),
            .eq_cap, .not_eq_cap => blk: {
                const b = captureText(match, self.other, content) orelse break :blk true;
                break :blk std.mem.eql(u8, text, b) == (self.kind == .eq_cap);
            },
        };
    }
};

/// One `#set! key value` directive (`injection.language`, `indent.immediate`).
const Dir = struct { pattern: u16, key: []const u8, value: []const u8 };

fn anyEql(list: []const []const u8, text: []const u8) bool {
    for (list) |s| {
        if (std.mem.eql(u8, s, text)) return true;
    }
    return false;
}

/// The document text of the (first) node captured as `id` in `match`.
fn captureText(match: c.TSQueryMatch, id: u32, content: []const u8) ?[]const u8 {
    for (match.captures[0..match.capture_count]) |cap| {
        if (cap.index != id) continue;
        const s = c.ts_node_start_byte(cap.node);
        const e = c.ts_node_end_byte(cap.node);
        if (s > e or e > content.len) return null;
        return content[s..e];
    }
    return null;
}

/// Compiled queries, shared process-wide. 32 slots covers three query kinds
/// across the eleven vendored grammars.
var query_cache: [32]?Compiled = @splat(null);

fn cachedQuery(language: *const c.TSLanguage, query_src: []const u8) ?Compiled {
    for (query_cache) |slot| {
        if (slot) |s| {
            // Each grammar has exactly one source per query kind, embedded at
            // build time, so identity of the slice is identity of the query.
            if (s.src.ptr == query_src.ptr and s.src.len == query_src.len) return s;
        }
    }
    var err_off: u32 = 0;
    var err_type: c.TSQueryError = 0;
    const query = c.ts_query_new(language, query_src.ptr, @intCast(query_src.len), &err_off, &err_type) orelse {
        std.log.scoped(.treesitter).err("query failed to compile: error {d} at byte {d}", .{ err_type, err_off });
        return null;
    };
    const parsed = parsePredicates(query);
    const out: Compiled = .{ .src = query_src, .query = query, .preds = parsed.preds, .dirs = parsed.dirs };
    for (&query_cache) |*slot| {
        if (slot.* == null) {
            slot.* = out;
            break;
        }
    }
    return out;
}

/// Read every pattern's predicate steps once, at compile time of the query:
/// each `#match?` regex is compiled here and reused for every node the pattern
/// ever tests. Predicates we cannot evaluate (`#is-not? local`, which needs a
/// locals query, or a `#lua-match?` using Lua-only syntax) are dropped, which
/// leaves their pattern firing unconditionally — the behaviour before any
/// predicate was evaluated at all.
fn parsePredicates(query: *c.TSQuery) struct { preds: []const Pred, dirs: []const Dir } {
    const store = cache_arena.allocator();
    var preds: std.ArrayList(Pred) = .empty;
    var dirs: std.ArrayList(Dir) = .empty;

    const patterns = c.ts_query_pattern_count(query);
    var pi: u32 = 0;
    while (pi < patterns) : (pi += 1) {
        var count: u32 = 0;
        const steps = c.ts_query_predicates_for_pattern(query, pi, &count);
        var i: u32 = 0;
        while (i < count) {
            var j = i;
            while (j < count and steps[j].type != c.TSQueryPredicateStepTypeDone) j += 1;
            parseOne(query, store, @intCast(pi), steps[i..j], &preds, &dirs);
            i = j + 1;
        }
    }
    return .{
        .preds = preds.toOwnedSlice(store) catch &.{},
        .dirs = dirs.toOwnedSlice(store) catch &.{},
    };
}

fn parseOne(
    query: *c.TSQuery,
    store: Allocator,
    pattern: u16,
    steps: []const c.TSQueryPredicateStep,
    preds: *std.ArrayList(Pred),
    dirs: *std.ArrayList(Dir),
) void {
    if (steps.len == 0 or steps[0].type != c.TSQueryPredicateStepTypeString) return;
    const name = stringValue(query, steps[0].value_id);
    const args = steps[1..];

    // `#set! key [value]` — a directive, not a filter.
    if (std.mem.eql(u8, name, "set!")) {
        if (args.len == 0 or args[0].type != c.TSQueryPredicateStepTypeString) return;
        const key = stringValue(query, args[0].value_id);
        const value = if (args.len > 1 and args[1].type == c.TSQueryPredicateStepTypeString)
            stringValue(query, args[1].value_id)
        else
            "";
        dirs.append(store, .{ .pattern = pattern, .key = key, .value = value }) catch {};
        return;
    }

    // Every filter we evaluate takes a capture first.
    if (args.len < 2 or args[0].type != c.TSQueryPredicateStepTypeCapture) return;
    const capture = args[0].value_id;
    const negated = std.mem.startsWith(u8, name, "not-");
    const bare = if (negated) name["not-".len..] else name;

    if (std.mem.eql(u8, bare, "eq?")) {
        if (args[1].type == c.TSQueryPredicateStepTypeCapture) {
            preds.append(store, .{
                .pattern = pattern,
                .capture = capture,
                .kind = if (negated) .not_eq_cap else .eq_cap,
                .other = args[1].value_id,
            }) catch {};
            return;
        }
        const one = store.dupe([]const u8, &.{stringValue(query, args[1].value_id)}) catch return;
        preds.append(store, .{
            .pattern = pattern,
            .capture = capture,
            .kind = if (negated) .not_eq_str else .eq_str,
            .strs = one,
        }) catch {};
        return;
    }

    if (std.mem.eql(u8, bare, "any-of?")) {
        var list: std.ArrayList([]const u8) = .empty;
        for (args[1..]) |a| {
            if (a.type != c.TSQueryPredicateStepTypeString) continue;
            list.append(store, stringValue(query, a.value_id)) catch {};
        }
        preds.append(store, .{
            .pattern = pattern,
            .capture = capture,
            .kind = if (negated) .not_any_of else .any_of,
            .strs = list.toOwnedSlice(store) catch return,
        }) catch {};
        return;
    }

    const is_lua = std.mem.eql(u8, bare, "lua-match?");
    if (std.mem.eql(u8, bare, "match?") or is_lua) {
        if (args[1].type != c.TSQueryPredicateStepTypeString) return;
        const pat = stringValue(query, args[1].value_id);
        // A Lua pattern is only a regex when it uses no Lua-only syntax.
        if (is_lua and !luaIsRegex(pat)) return;
        const re = regex.Regex.compile(store, pat, false) catch {
            std.log.scoped(.treesitter).warn("query predicate regex rejected: {s}", .{pat});
            return;
        };
        preds.append(store, .{
            .pattern = pattern,
            .capture = capture,
            .kind = if (negated) .not_match else .match,
            .re = re,
        }) catch {};
        return;
    }
    // Anything else (`#is-not? local`, `#offset!`, `#gsub!`) is left alone.
}

fn stringValue(query: *c.TSQuery, id: u32) []const u8 {
    var len: u32 = 0;
    return c.ts_query_string_value_for_id(query, id, &len)[0..len];
}

/// The id of a capture by name, resolved once per query rather than compared
/// as a string per capture.
fn captureId(query: *c.TSQuery, name: []const u8) ?u32 {
    const n = c.ts_query_capture_count(query);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var len: u32 = 0;
        if (std.mem.eql(u8, c.ts_query_capture_name_for_id(query, i, &len)[0..len], name)) return i;
    }
    return null;
}

/// The (first) node captured as `id` in `match`.
fn captureNode(match: c.TSQueryMatch, id: u32) ?c.TSNode {
    for (match.captures[0..match.capture_count]) |cap| {
        if (cap.index == id) return cap.node;
    }
    return null;
}

/// Whether a Lua pattern means exactly the same thing as the identical regex.
/// `%` is Lua's escape, `()` its position captures and `-` its lazy repeat —
/// any of those and we decline rather than guess. Character classes, `^ $ . *
/// + ?` and literals mean the same in both dialects, which covers every
/// `#lua-match?` the vendored queries use.
fn luaIsRegex(pattern: []const u8) bool {
    var in_class = false;
    for (pattern) |ch| switch (ch) {
        '%', '(', ')' => return false,
        '-' => if (!in_class) return false,
        '[' => in_class = true,
        ']' => in_class = false,
        else => {},
    };
    return true;
}

/// The most byte ranges one injected layer tracks. Regions come from the
/// *visible* part of the document, so this is bounded by what fits on screen:
/// 64 covers a tall terminal showing nothing but one-line markdown paragraphs
/// (each of which is its own `(inline)` region). Regions past the cap are
/// dropped rather than mis-assigned.
const max_ranges = 64;
/// The most injected languages alive at once (markdown fences of several
/// languages plus its inline layer, all on one screen).
const max_injected = 6;
/// A region bigger than this is clipped to the visible range before it reaches
/// its parser. Collecting regions from the visible range bounds *which* nodes
/// are injected, not how far one reaches: a node that merely starts on screen
/// hands its whole length to the parser on **every** keystroke — a 3.3 MB
/// `<script>` measured at 80 ms a key, against 22 ms for the HTML layer over
/// the same file. Under the cap — 64 KB is ~1600 lines, so every fence and
/// script anyone writes, and the same limit zedit already puts on tree-sitter
/// in the picker preview — the region is parsed whole as before, which is what
/// keeps a code block that runs off the screen highlighted from its real
/// start. Only the first and last region of a frame can straddle the viewport,
/// so the work per layer is the screen plus at most two of these.
const max_region = 64 * 1024;

/// One parse+query layer: a parser, its tree, the shared compiled query and
/// the capture-id -> style table. The root layer covers the whole document;
/// an injected layer covers only `ranges`.
const Layer = struct {
    /// Grammar identity: the pointer of its highlights source (see `Spec`).
    id: [*]const u8,
    parser: *c.TSParser,
    q: Compiled,
    caps: []Cap,
    tree: ?*c.TSTree = null,
    /// The ranges this layer's tree was last parsed with (empty = whole
    /// document). Heap-allocated on first use, so a root layer — and every
    /// buffer of a language with no injections at all — carries a slice
    /// header rather than `max_ranges` inline.
    ranges: []c.TSRange = &.{},
    range_count: usize = 0,
    /// Set when the document changed under the layer: it must reparse even if
    /// its ranges are unchanged.
    dirty: bool = true,
    /// Whether the layer has visible regions this frame.
    active: bool = false,

    /// What one capture id does to the bytes it covers. `@none` (markdown's
    /// `code_fence_content`) explicitly *clears* what an outer pattern painted,
    /// which is how a fence stops being one long string literal.
    const Cap = struct { style: syntax.Style, clear: bool };

    /// Layers built since the process started. Reusing a layer rather than
    /// rebuilding it per frame is a performance claim, and comparing parser
    /// pointers cannot check it — the C allocator hands a just-freed parser
    /// straight back, so a layer rebuilt every frame looks identical. Counted
    /// here so a test can pin it.
    var built: usize = 0;

    fn init(gpa: Allocator, sp: Spec) ?Layer {
        const parser = c.ts_parser_new() orelse return null;
        // Not `errdefer`: these are `null` returns, not errors, and an
        // injected layer's setup can fail at any time (a grammar named by a
        // fence), not just once at startup.
        var ok = false;
        defer if (!ok) c.ts_parser_delete(parser);
        if (!c.ts_parser_set_language(parser, sp.language)) return null;
        const q = cachedQuery(sp.language, sp.highlights) orelse return null;
        const n = c.ts_query_capture_count(q.query);
        const caps = gpa.alloc(Cap, n) catch return null;
        ok = true;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var len: u32 = 0;
            const name = c.ts_query_capture_name_for_id(q.query, i, &len)[0..len];
            caps[i] = .{ .style = mapCapture(name), .clear = std.mem.eql(u8, name, "none") };
        }
        built += 1;
        return .{ .id = sp.highlights.ptr, .parser = parser, .q = q, .caps = caps };
    }

    fn deinit(self: *Layer, gpa: Allocator) void {
        if (self.tree) |t| c.ts_tree_delete(t);
        // `q.query` is shared via `query_cache` — never deleted here.
        c.ts_parser_delete(self.parser);
        gpa.free(self.caps);
        gpa.free(self.ranges);
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
        self.dirty = false;
    }

    /// Point this layer at `ranges` and reparse. The runtime diffs them against
    /// the ranges the old tree was built with and only re-lexes where they
    /// differ, so scrolling a new fenced block into view costs that block, not
    /// the document.
    fn reparseRanges(self: *Layer, gpa: Allocator, content: []const u8, ranges: []const c.TSRange) void {
        if (self.ranges.len == 0) self.ranges = gpa.alloc(c.TSRange, max_ranges) catch return;
        if (!c.ts_parser_set_included_ranges(self.parser, ranges.ptr, @intCast(ranges.len))) return;
        @memcpy(self.ranges[0..ranges.len], ranges);
        self.range_count = ranges.len;
        self.reparse(content, null);
    }

    /// Fill `out[0..]` (representing document bytes [start, end)) from this
    /// layer's captures, clipped to the layer's own regions.
    fn fill(self: *const Layer, content: []const u8, start: usize, end: usize, out: []syntax.Style) void {
        const tree = self.tree orelse return;
        const cursor = c.ts_query_cursor_new() orelse return;
        defer c.ts_query_cursor_delete(cursor);
        _ = c.ts_query_cursor_set_byte_range(cursor, @intCast(start), @intCast(end));
        c.ts_query_cursor_exec(cursor, self.q.query, c.ts_tree_root_node(tree));
        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            if (!self.q.holds(match, content)) continue;
            for (match.captures[0..match.capture_count]) |cap| {
                const info = self.caps[cap.index];
                if (info.style == .normal and !info.clear) continue;
                const ne = c.ts_node_end_byte(cap.node);
                if (ne <= start) continue;
                const ns = c.ts_node_start_byte(cap.node);
                self.paint(out, start, ns, ne, info.style);
            }
        }
    }

    fn paint(self: *const Layer, out: []syntax.Style, base: usize, ns: usize, ne: usize, style: syntax.Style) void {
        if (self.range_count == 0) return paintSpan(out, base, ns, ne, style);
        for (self.ranges[0..self.range_count]) |r| {
            const s = @max(ns, r.start_byte);
            const e = @min(ne, r.end_byte);
            if (s < e) paintSpan(out, base, s, e, style);
        }
    }

    fn paintSpan(out: []syntax.Style, base: usize, ns: usize, ne: usize, style: syntax.Style) void {
        var k: usize = if (ns > base) ns - base else 0;
        const hi = @min(ne -| base, out.len);
        while (k < hi) : (k += 1) out[k] = style;
    }
};

pub const Highlighter = struct {
    gpa: Allocator,
    root: Layer,
    /// Child layers, one per injected language, kept across reparses.
    injected: [max_injected]?Layer = @splat(null),
    /// The root grammar's `injections.scm` and the capture ids it uses.
    /// `inj_language` is null when no pattern captures one, i.e. every region's
    /// language comes from a `#set!` directive (HTML).
    inj: ?Compiled = null,
    inj_content: u32 = 0,
    inj_language: ?u32 = null,
    /// The root grammar's `indents.scm`, and its `@indent.begin` capture id.
    indent: ?Compiled = null,
    indent_begin: u32 = 0,
    content: std.ArrayList(u8), // copy of the last-parsed text, to diff against

    /// Create a highlighter for `lang`, or null if unsupported / setup failed.
    pub fn init(gpa: Allocator, lang: syntax.Language) ?Highlighter {
        const sp = specFor(lang) orelse return null;
        var self: Highlighter = .{
            .gpa = gpa,
            .root = Layer.init(gpa, sp) orelse return null,
            .content = .empty,
        };
        if (sp.injections) |src| {
            if (cachedQuery(sp.language, src)) |q| {
                // Without an `@injection.content` capture the query marks no
                // regions at all, so it is left switched off rather than run.
                if (captureId(q.query, "injection.content")) |id| {
                    self.inj = q;
                    self.inj_content = id;
                    self.inj_language = captureId(q.query, "injection.language");
                }
            }
        }
        if (sp.indents) |src| {
            if (cachedQuery(sp.language, src)) |q| {
                if (captureId(q.query, "indent.begin")) |id| {
                    self.indent = q;
                    self.indent_begin = id;
                }
            }
        }
        return self;
    }

    pub fn deinit(self: *Highlighter) void {
        self.root.deinit(self.gpa);
        for (&self.injected) |*slot| {
            if (slot.*) |*l| l.deinit(self.gpa);
        }
        self.content.deinit(self.gpa);
    }

    /// (Re)parse `content`, reusing the previous tree(s) incrementally: a single
    /// edit derived from the common prefix/suffix of the old and new text means
    /// tree-sitter only re-parses the region that changed. Run `queryRange` for
    /// the styles.
    ///
    /// The edit is computed whenever a previous tree exists — including when
    /// either side is empty (a buffer born empty, or delete-all). Passing the
    /// old tree to ts_parser_parse_string *without* ts_tree_edit violates its
    /// contract (vendor api.h) and freezes the stale tree: a `zedit new.py`
    /// buffer used to stay unhighlighted forever.
    ///
    /// Injected layers get the same edit applied to their trees and are marked
    /// for reparse; their new regions are only worked out in `queryRange`,
    /// where the visible range is known.
    pub fn reparse(self: *Highlighter, content: []const u8) void {
        const edit: ?c.TSInputEdit = if (self.root.tree != null)
            computeEdit(self.content.items, content)
        else
            null;
        self.root.reparse(content, edit);
        for (&self.injected) |*slot| {
            if (slot.*) |*l| {
                if (l.tree) |t| {
                    if (edit) |e| c.ts_tree_edit(t, &e);
                }
                l.dirty = true;
            }
        }
        self.rememberContent(content);
    }

    /// Fill `out` (one `Style` per byte of [start, end)) from the root layer,
    /// then from each injected layer over the regions it owns. Only nodes
    /// intersecting the range are visited, so this is O(visible).
    pub fn queryRange(self: *Highlighter, start: usize, end: usize, out: []syntax.Style) void {
        @memset(out, .normal);
        if (end <= start) return;
        self.updateInjections(start, end);
        self.root.fill(self.content.items, start, end, out);
        for (&self.injected) |*slot| {
            if (slot.*) |*l| {
                if (l.active) l.fill(self.content.items, start, end, out);
            }
        }
    }

    /// Find the injected regions intersecting [start, end), hand each language
    /// its own layer and reparse the ones whose regions moved. Only nodes that
    /// reach the visible range are considered, so the work per keystroke stays
    /// proportional to the screen — a fenced block below the fold costs
    /// nothing until it is scrolled to.
    fn updateInjections(self: *Highlighter, start: usize, end: usize) void {
        const q = self.inj orelse return;
        const tree = self.root.tree orelse return;
        for (&self.injected) |*slot| {
            if (slot.*) |*l| l.active = false;
        }

        const Want = struct { sp: Spec, ranges: [max_ranges]c.TSRange = undefined, n: usize = 0 };
        var wants: [max_injected]Want = undefined;
        var nwants: usize = 0;
        // The clip boundaries (see `max_region`), worked out only if a region
        // actually reaches past the screen: `pointAt` walks the text, and a
        // document whose regions are all of ordinary size must not pay for it.
        var start_point: ?c.TSPoint = null;
        var end_point: ?c.TSPoint = null;

        const cursor = c.ts_query_cursor_new() orelse return;
        defer c.ts_query_cursor_delete(cursor);
        _ = c.ts_query_cursor_set_byte_range(cursor, @intCast(start), @intCast(end));
        c.ts_query_cursor_exec(cursor, q.query, c.ts_tree_root_node(tree));
        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            if (!q.holds(match, self.content.items)) continue;
            const node = captureNode(match, self.inj_content) orelse continue;
            // The language is either captured (a fence's info string) or fixed
            // by the pattern's `#set! injection.language`.
            const captured = if (self.inj_language) |id| captureText(match, id, self.content.items) else null;
            const name = captured orelse
                q.directive(@intCast(match.pattern_index), "injection.language") orelse continue;
            const sp = specByName(name) orelse continue;
            var range: c.TSRange = .{
                .start_byte = c.ts_node_start_byte(node),
                .end_byte = c.ts_node_end_byte(node),
                .start_point = c.ts_node_start_point(node),
                .end_point = c.ts_node_end_point(node),
            };
            if (range.end_byte <= range.start_byte) continue;
            if (range.end_byte - range.start_byte > max_region) {
                if (range.start_byte < start) {
                    range.start_byte = @intCast(start);
                    range.start_point = start_point orelse blk: {
                        start_point = pointAt(self.content.items, start);
                        break :blk start_point.?;
                    };
                }
                if (range.end_byte > end) {
                    range.end_byte = @intCast(end);
                    range.end_point = end_point orelse blk: {
                        end_point = pointAt(self.content.items, end);
                        break :blk end_point.?;
                    };
                }
                if (range.end_byte <= range.start_byte) continue;
            }

            var w: ?*Want = null;
            for (wants[0..nwants]) |*have| {
                if (have.sp.highlights.ptr == sp.highlights.ptr) w = have;
            }
            if (w == null) {
                if (nwants == wants.len) continue;
                wants[nwants] = .{ .sp = sp };
                w = &wants[nwants];
                nwants += 1;
            }
            // Ranges must reach the parser sorted and disjoint; matches arrive
            // in document order, so a range that does not extend the last one
            // is a duplicate or an overlap and is dropped.
            const want = w.?;
            if (want.n == max_ranges) continue;
            if (want.n > 0 and range.start_byte < want.ranges[want.n - 1].end_byte) continue;
            want.ranges[want.n] = range;
            want.n += 1;
        }

        for (wants[0..nwants]) |*want| {
            const layer = self.layerFor(want.sp) orelse continue;
            layer.active = true;
            if (!layer.dirty and std.mem.eql(
                u8,
                std.mem.sliceAsBytes(layer.ranges[0..layer.range_count]),
                std.mem.sliceAsBytes(want.ranges[0..want.n]),
            )) continue;
            layer.reparseRanges(self.gpa, self.content.items, want.ranges[0..want.n]);
        }
    }

    /// The layer for `sp`: the one already parsing that grammar, else a free
    /// slot, else one whose language is off-screen this frame. Layers survive
    /// scrolling and editing — only a language leaving the screen entirely can
    /// cost another one its parser.
    fn layerFor(self: *Highlighter, sp: Spec) ?*Layer {
        for (&self.injected) |*slot| {
            if (slot.*) |*l| {
                if (l.id == sp.highlights.ptr) return l;
            }
        }
        for (&self.injected) |*slot| {
            if (slot.* == null) {
                slot.* = Layer.init(self.gpa, sp) orelse return null;
                return &slot.*.?;
            }
        }
        for (&self.injected) |*slot| {
            if (slot.*) |*l| {
                if (l.active) continue;
                l.deinit(self.gpa);
                slot.* = Layer.init(self.gpa, sp) orelse {
                    slot.* = null;
                    return null;
                };
                return &slot.*.?;
            }
        }
        return null;
    }

    /// How many indent levels the line at `row` *opens*, counting only the
    /// `@indent.begin` nodes that start on it and lie inside the document bytes
    /// [start_byte, end_byte) — which Enter narrows to the text before the
    /// cursor. A node that runs past the line counts outright; one that begins
    /// and ends on the line counts only when it is marked
    /// `#set! indent.immediate` (a `def f():` style opener, which still ends on
    /// its own row while its body is being typed) *and* ends within the range.
    /// **Null** when this grammar ships no indent query at all, which is how
    /// autoindent knows to fall back to vim's copy rule rather than to treat
    /// the line as opening nothing.
    pub fn openIndents(self: *Highlighter, row: usize, start_byte: usize, end_byte: usize) ?usize {
        const q = self.indent orelse return null;
        const tree = self.root.tree orelse return null;
        const cursor = c.ts_query_cursor_new() orelse return null;
        defer c.ts_query_cursor_delete(cursor);
        _ = c.ts_query_cursor_set_byte_range(cursor, @intCast(start_byte), @intCast(end_byte));
        c.ts_query_cursor_exec(cursor, q.query, c.ts_tree_root_node(tree));
        var match: c.TSQueryMatch = undefined;
        var levels: usize = 0;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            if (!q.holds(match, self.content.items)) continue;
            const immediate = q.hasDirective(@intCast(match.pattern_index), "indent.immediate");
            for (match.captures[0..match.capture_count]) |cap| {
                if (cap.index != self.indent_begin) continue;
                if (c.ts_node_start_point(cap.node).row != row) continue;
                if (c.ts_node_end_point(cap.node).row > row) {
                    levels += 1; // runs past the line: an opener whatever follows
                } else if (immediate and c.ts_node_end_byte(cap.node) <= end_byte) {
                    // An opener that begins *and* ends on the line only counts
                    // when all of it is inside [start_byte, end_byte) — which is
                    // what makes Enter honour the cursor: `def f(|):` splits into
                    // a `def f(` that opens nothing yet (nvim-verified).
                    levels += 1;
                }
            }
        }
        // A line of nothing but openers is still just a line; cap the jump so a
        // hostile file cannot indent a new line off the screen.
        return @min(levels, 4);
    }

    /// A byte range in the parsed document.
    pub const Span = struct { start: usize, end: usize };

    /// The innermost node containing `byte` whose type is one of `kinds`
    /// (grammar node names — see the tables in editor.zig). `inner` returns the
    /// node's `body` instead, minus its braces, which is what `if`/`ic` select.
    pub fn enclosing(self: *Highlighter, byte: usize, kinds: []const []const u8, inner: bool) ?Span {
        const tree = self.root.tree orelse return null;
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
        const tree = self.root.tree orelse return null;
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
        const tree = self.root.tree orelse return null;
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
        const tree = self.root.tree orelse return null;
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

/// Every language's styles for `src`, for the assertions below.
fn styleOf(lang: syntax.Language, src: []const u8, needle: []const u8) !syntax.Style {
    var h = Highlighter.init(std.testing.allocator, lang).?;
    defer h.deinit();
    const styles = try std.testing.allocator.alloc(syntax.Style, src.len);
    defer std.testing.allocator.free(styles);
    h.reparse(src);
    h.queryRange(0, src.len, styles);
    return styles[std.mem.indexOf(u8, src, needle) orelse return error.NeedleNotFound];
}

test "every vendored grammar and its highlight query load" {
    inline for (.{ syntax.Language.zig, .c, .python, .json, .javascript, .typescript, .rust, .go, .html, .markdown }) |lang| {
        var h = Highlighter.init(std.testing.allocator, lang) orelse return error.GrammarFailedToLoad;
        defer h.deinit();
        // A query that fails to compile is silently dropped at runtime (the
        // feature just stops working), so assert the ones we ship are there.
        const sp = specFor(lang).?;
        if (sp.injections != null) try std.testing.expect(h.inj != null);
        if (sp.indents != null) try std.testing.expect(h.indent != null);
    }
    // markdown-inline is reachable only as an injection, so it has no
    // `syntax.Language` — check its grammar and query separately.
    try std.testing.expect(specByName("markdown_inline") != null);
}

test "predicates gate the captures their query guards" {
    // `((identifier) @constant (#match? @constant "^[A-Z][A-Z_]*$"))` — the
    // pattern matches *every* identifier, and only the predicate keeps it off
    // the lowercase ones. Without predicate evaluation both came back
    // `.builtin`, which is what made every Python/Zig/Rust identifier light up.
    try std.testing.expectEqual(syntax.Style.builtin, try styleOf(.python, "FOO = 1\n", "FOO"));
    try std.testing.expectEqual(syntax.Style.normal, try styleOf(.python, "foo = 1\n", "foo"));

    // `#lua-match?` means the same thing as the regex here, so it is honoured:
    // Zig capitalised identifiers are types, all-caps ones constants.
    try std.testing.expectEqual(syntax.Style.type_, try styleOf(.zig, "const a = Foo;\n", "Foo"));
    try std.testing.expectEqual(syntax.Style.normal, try styleOf(.zig, "const a = bar;\n", "bar"));

    // `#eq? @variable.builtin "_"` — only the discard identifier.
    try std.testing.expectEqual(syntax.Style.builtin, try styleOf(.zig, "test {\n    _ = q;\n}\n", "_"));

    // Rust gates its `@constructor`/`@type` guesses on `#match? "^[A-Z]"`:
    // a capitalised path segment is styled, a lowercase one is left alone.
    try std.testing.expectEqual(syntax.Style.function, try styleOf(.rust, "fn f() { let a = Foo::BAR; }\n", "Foo"));
    try std.testing.expectEqual(syntax.Style.normal, try styleOf(.rust, "fn f() { let a = zed::BAR; }\n", "zed"));
}

/// The capture texts a synthetic query yields once its predicates have had
/// their say — `Layer.fill`'s filter, isolated. `parsePredicates` stores into
/// the same process-lifetime `cache_arena` the real path uses (a few dozen
/// bytes per query here), which is why this can call it directly.
fn survivors(gpa: Allocator, out: *std.ArrayList(u8), query_src: []const u8, src: []const u8) !void {
    const lang = tree_sitter_c();
    var err_off: u32 = 0;
    var err_type: c.TSQueryError = 0;
    const query = c.ts_query_new(lang, query_src.ptr, @intCast(query_src.len), &err_off, &err_type) orelse
        return error.QueryFailedToCompile;
    defer c.ts_query_delete(query);
    const parsed = parsePredicates(query);
    const comp: Compiled = .{ .src = query_src, .query = query, .preds = parsed.preds, .dirs = parsed.dirs };
    const parser = c.ts_parser_new().?;
    defer c.ts_parser_delete(parser);
    _ = c.ts_parser_set_language(parser, lang);
    const tree = c.ts_parser_parse_string(parser, null, src.ptr, @intCast(src.len)).?;
    defer c.ts_tree_delete(tree);
    const cursor = c.ts_query_cursor_new().?;
    defer c.ts_query_cursor_delete(cursor);
    c.ts_query_cursor_exec(cursor, query, c.ts_tree_root_node(tree));
    var match: c.TSQueryMatch = undefined;
    while (c.ts_query_cursor_next_match(cursor, &match)) {
        if (!comp.holds(match, src)) continue;
        for (match.captures[0..match.capture_count]) |cap| {
            try out.appendSlice(gpa, src[c.ts_node_start_byte(cap.node)..c.ts_node_end_byte(cap.node)]);
            try out.append(gpa, ' ');
        }
    }
}

test "predicate forms, and what an unevaluable predicate degrades to" {
    // The vendored queries only reach `#match?`, `#eq?` and `#lua-match?` (the
    // test above pins those in their real grammars). The rest of the evaluator
    // — the `#not-` forms, `#any-of?`, capture-to-capture `#eq?` — has no
    // vendored caller, so it is pinned here against a synthetic query instead
    // of taken on trust.
    //
    // The last three cases are the *degradation* rule: a predicate we cannot
    // evaluate is dropped, which leaves its pattern firing for every node —
    // over-highlighting, never a silently missing capture. `#is-not? local`
    // needs a locals query zedit has none of; `%a` is Lua-only syntax that
    // does not mean the same thing as a regex; `#vim-match?` we simply do not
    // know.
    const src = "int main(void) { int FOO = 1; int bar = 2; int FOO2 = FOO; return bar; }\n";
    const all = "main FOO bar FOO2 FOO bar ";
    const cases = [_]struct { q: []const u8, want: []const u8 }{
        .{ .q = "((identifier) @x)", .want = all },
        .{ .q = "((identifier) @x (#any-of? @x \"FOO\" \"bar\"))", .want = "FOO bar FOO bar " },
        .{ .q = "((identifier) @x (#not-any-of? @x \"FOO\" \"bar\"))", .want = "main FOO2 " },
        .{ .q = "((identifier) @x (#not-eq? @x \"FOO\"))", .want = "main bar FOO2 bar " },
        .{ .q = "((identifier) @x (#not-match? @x \"^[A-Z]\"))", .want = "main bar bar " },
        // `#eq? @a @b` compares two captures' texts: `FOO2 = FOO` differs.
        .{ .q = "((init_declarator declarator: (identifier) @a value: (identifier) @b) (#eq? @a @b))", .want = "" },
        .{ .q = "((init_declarator declarator: (identifier) @a value: (identifier) @b) (#not-eq? @a @b))", .want = "FOO2 FOO " },
        .{ .q = "((identifier) @x (#is-not? local))", .want = all },
        .{ .q = "((identifier) @x (#lua-match? @x \"^%a+$\"))", .want = all },
        .{ .q = "((identifier) @x (#vim-match? @x \"^[A-Z]\"))", .want = all },
    };
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(std.testing.allocator);
    for (cases) |case| {
        got.clearRetainingCapacity();
        try survivors(std.testing.allocator, &got, case.q, src);
        std.testing.expectEqualStrings(case.want, got.items) catch |e| {
            std.debug.print("  query: {s}\n", .{case.q});
            return e;
        };
    }
}

test "injections: a fenced block is parsed by the language its info string names" {
    const md = "```python\ndef f():\n    pass\n```\n";
    // `def` is a Python keyword; without the injection nothing in the fence is
    // a keyword — the markdown layer has no such capture.
    try std.testing.expectEqual(syntax.Style.keyword, try styleOf(.markdown, md, "def"));
    // A fence naming no language, or one with no vendored grammar, has no
    // injected layer and so no keywords.
    const plain = "```\ndef f():\n```\n";
    try std.testing.expectEqual(syntax.Style.normal, try styleOf(.markdown, plain, "def"));
    const unknown = "```haskell\ndef f():\n```\n";
    try std.testing.expectEqual(syntax.Style.normal, try styleOf(.markdown, unknown, "def"));
    // The fence's delimiters stay markdown's own `@text.literal`.
    try std.testing.expectEqual(syntax.Style.string_, try styleOf(.markdown, md, "```"));
    // The inline layer — once a hardcoded second parse of the whole document,
    // now an injection like any other — still styles emphasis, and reaches a
    // table cell, which the block grammar keeps out of `(inline)`.
    try std.testing.expectEqual(syntax.Style.builtin, try styleOf(.markdown, "a **b** c\n", "b"));
    try std.testing.expectEqual(
        syntax.Style.builtin,
        try styleOf(.markdown, "| h |\n|---|\n| **b** |\n", "b*"),
    );
}

test "injections: a <script> element is parsed as javascript" {
    const html = "<p>hi</p>\n<script>\nlet x = 1;\n</script>\n";
    try std.testing.expectEqual(syntax.Style.keyword, try styleOf(.html, html, "let"));
    try std.testing.expectEqual(syntax.Style.number, try styleOf(.html, html, "1"));
    // No <script>, no injected layer at all.
    var h = Highlighter.init(std.testing.allocator, .html).?;
    defer h.deinit();
    var styles: [10]syntax.Style = undefined;
    h.reparse("<p>hi</p>\n");
    h.queryRange(0, 10, &styles);
    try std.testing.expect(h.injected[0] == null);
}

test "injected layers are reused across reparses, not rebuilt" {
    const a = "```python\ndef f():\n    pass\n```\n";
    const b = "```python\ndef g():\n    pass\n```\n";
    var h = Highlighter.init(std.testing.allocator, .markdown).?;
    defer h.deinit();
    var styles: [64]syntax.Style = undefined;
    h.reparse(a);
    h.queryRange(0, a.len, styles[0..a.len]);
    const parser = h.injected[0].?.parser;
    const tree = h.injected[0].?.tree;
    const built = Layer.built;
    h.reparse(b);
    h.queryRange(0, b.len, styles[0..b.len]);
    // Same layer, same parser: an edit reparses the region, it does not build
    // a new parser (or recompile the query) per keystroke. The pointer alone
    // proves nothing (a freed parser comes straight back from the C
    // allocator), so the build count carries the claim.
    try std.testing.expectEqual(built, Layer.built);
    try std.testing.expectEqual(parser, h.injected[0].?.parser);
    try std.testing.expect(h.injected[0].?.tree != tree); // but the tree is fresh
    try std.testing.expectEqual(syntax.Style.keyword, styles[std.mem.indexOf(u8, b, "def").?]);
}

/// The document ranges the layer parsing `highlights` is currently pointed at,
/// or null when no such layer is live. Its `active` flag is the frame's own
/// answer to "does this language appear on screen", so this doubles as the
/// check that a layer left off-screen is not consulted.
fn injectedRanges(h: *Highlighter, highlights: []const u8) ?[]const c.TSRange {
    for (&h.injected) |*slot| {
        if (slot.*) |*l| {
            if (l.id == highlights.ptr and l.active) return l.ranges[0..l.range_count];
        }
    }
    return null;
}

test "an injected layer parses its own regions, not the document" {
    // The point of doing this through `ts_parser_set_included_ranges` rather
    // than as a second whole-document parse: markdown-inline sees the two
    // `(inline)` nodes and python sees the fence body — nothing else. The
    // hardcoded second layer this replaced re-parsed the *entire file* on
    // every keystroke, which is where the markdown editing cost came from, and
    // nothing about the visible colours would notice if it came back.
    const md = "# Title\n\n```python\ndef f():\n    pass\n```\n\n*em* text\n";
    var h = Highlighter.init(std.testing.allocator, .markdown).?;
    defer h.deinit();
    const styles = try std.testing.allocator.alloc(syntax.Style, md.len);
    defer std.testing.allocator.free(styles);
    h.reparse(md);
    h.queryRange(0, md.len, styles);

    const inl = injectedRanges(&h, highlights_markdown_inline) orelse return error.NoInlineLayer;
    try std.testing.expectEqual(@as(usize, 2), inl.len);
    try std.testing.expectEqualStrings("Title", md[inl[0].start_byte..inl[0].end_byte]);
    try std.testing.expectEqualStrings("*em* text", md[inl[1].start_byte..inl[1].end_byte]);

    const py = injectedRanges(&h, highlights_python) orelse return error.NoPythonLayer;
    try std.testing.expectEqual(@as(usize, 1), py.len);
    try std.testing.expectEqualStrings("def f():\n    pass\n", md[py[0].start_byte..py[0].end_byte]);
}

test "injected regions come from the visible range only" {
    // Per-keystroke work stays O(screen): a fenced block below the fold is not
    // parsed at all until it is scrolled to, and one scrolled past is dropped
    // again.
    const md = "```python\ndef aaa():\n    pass\n```\n\nmiddle\n\n```python\ndef bbb():\n    pass\n```\n";
    const split = std.mem.indexOf(u8, md, "middle").?;
    var h = Highlighter.init(std.testing.allocator, .markdown).?;
    defer h.deinit();
    const styles = try std.testing.allocator.alloc(syntax.Style, md.len);
    defer std.testing.allocator.free(styles);
    h.reparse(md);

    h.queryRange(0, split, styles[0..split]);
    const top = injectedRanges(&h, highlights_python) orelse return error.NoPythonLayer;
    try std.testing.expectEqual(@as(usize, 1), top.len);
    try std.testing.expectEqualStrings("def aaa():\n    pass\n", md[top[0].start_byte..top[0].end_byte]);

    h.queryRange(split, md.len, styles[split..]);
    const bot = injectedRanges(&h, highlights_python) orelse return error.NoPythonLayer;
    try std.testing.expectEqual(@as(usize, 1), bot.len);
    try std.testing.expectEqualStrings("def bbb():\n    pass\n", md[bot[0].start_byte..bot[0].end_byte]);
}

test "a region far bigger than the screen is clipped to it" {
    // Collecting regions from the visible range bounds which nodes are
    // injected, not how far one reaches. A single `<script>` covering the
    // whole file starts on screen, so without the clip its whole length went
    // to the javascript parser on every keystroke.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "<script>\nlet x = 1;\n");
    while (src.items.len < max_region + 4096)
        try src.appendSlice(std.testing.allocator, "let y = 2;\n");
    try src.appendSlice(std.testing.allocator, "</script>\n");

    var h = Highlighter.init(std.testing.allocator, .html).?;
    defer h.deinit();
    const vis = 200; // one screen's worth
    const styles = try std.testing.allocator.alloc(syntax.Style, vis);
    defer std.testing.allocator.free(styles);
    h.reparse(src.items);
    h.queryRange(0, vis, styles);

    const js = injectedRanges(&h, highlights_javascript) orelse return error.NoJsLayer;
    try std.testing.expectEqual(@as(usize, 1), js.len);
    try std.testing.expectEqual(@as(u32, vis), js[0].end_byte);
    // Clipped, not dropped: what is on screen is still javascript.
    try std.testing.expectEqual(syntax.Style.keyword, styles[std.mem.indexOf(u8, src.items, "let").?]);

    // A region that fits the cap is still taken whole, so a block running off
    // the bottom of the screen keeps being parsed from its real start.
    const small = "<script>\nlet x = 1;\nlet y = 2;\n</script>\n";
    var g = Highlighter.init(std.testing.allocator, .html).?;
    defer g.deinit();
    var small_styles: [12]syntax.Style = undefined;
    g.reparse(small);
    g.queryRange(0, small_styles.len, &small_styles);
    const whole = injectedRanges(&g, highlights_javascript) orelse return error.NoJsLayer;
    try std.testing.expectEqualStrings("\nlet x = 1;\nlet y = 2;\n", small[whole[0].start_byte..whole[0].end_byte]);
}

test "openIndents: which lines open an indented block" {
    // `upto`, when set, cuts the line short at that column — which is what
    // Enter does with the text after the cursor.
    const Case = struct { lang: syntax.Language, src: []const u8, row: usize, want: ?usize, upto: ?usize = null };
    const cases = [_]Case{
        // Brace languages: the block node opens on the line and runs past it.
        .{ .lang = .c, .src = "void f(void) {\n    int a;\n}\n", .row = 0, .want = 1 },
        .{ .lang = .c, .src = "void f(void) {\n    int a;\n}\n", .row = 1, .want = 0 },
        .{ .lang = .c, .src = "void f(void) {\n    int a;\n}\n", .row = 2, .want = 0 },
        // A block opened and closed on one line opens nothing.
        .{ .lang = .c, .src = "void f(void) { int a; }\n", .row = 0, .want = 0 },
        .{ .lang = .c, .src = "struct S {\n    int a;\n};\n", .row = 0, .want = 1 },
        .{ .lang = .zig, .src = "pub fn f() void {\n    var a = 1;\n}\n", .row = 0, .want = 1 },
        .{ .lang = .zig, .src = "const S = struct {\n    a: u8,\n};\n", .row = 0, .want = 1 },
        .{ .lang = .zig, .src = "pub fn f() void {\n    var a = 1;\n}\n", .row = 1, .want = 0 },
        .{ .lang = .rust, .src = "fn f() {\n    let a = 1;\n}\n", .row = 0, .want = 1 },
        .{ .lang = .rust, .src = "impl S {\n    fn f() {}\n}\n", .row = 0, .want = 1 },
        .{ .lang = .go, .src = "func f() {\n    a := 1\n}\n", .row = 0, .want = 1 },
        .{ .lang = .javascript, .src = "function f() {\n    let a = 1;\n}\n", .row = 0, .want = 1 },
        .{ .lang = .typescript, .src = "interface X {\n    a: number;\n}\n", .row = 0, .want = 1 },
        // Python has no closing token: the opener still ends on its own row
        // while the body is being typed, so it is marked `indent.immediate`.
        .{ .lang = .python, .src = "def f():\n", .row = 0, .want = 1 },
        .{ .lang = .python, .src = "def f():\n    if x:\n        pass\n", .row = 1, .want = 1 },
        .{ .lang = .python, .src = "def f():\n    return 1\n", .row = 1, .want = 0 },
        .{ .lang = .python, .src = "x = 1\n", .row = 0, .want = 0 },
        // Enter's `upto`: only the text before the cursor counts. The brace of
        // `void f(void) {` is the opener's first byte, so cutting the line
        // before it drops the opener; python's opener *starts* at the line
        // start, so it is its end that has to be inside the range. Both answers
        // are real nvim's (nvim-treesitter's indent module, pty-probed).
        .{ .lang = .c, .src = "void f(void) {\n}\n", .row = 0, .want = 1, .upto = 14 },
        .{ .lang = .c, .src = "void f(void) {\n}\n", .row = 0, .want = 0, .upto = 13 },
        .{ .lang = .python, .src = "def f():\n", .row = 0, .want = 1, .upto = 8 },
        .{ .lang = .python, .src = "def f():\n", .row = 0, .want = 0, .upto = 7 },
        // JSON ships no indent query at all, so the answer is "cannot say"
        // (null), which is what tells autoindent to use vim's copy rule.
        .{ .lang = .json, .src = "{\n  \"a\": 1\n}\n", .row = 0, .want = null },
    };
    for (cases) |case| {
        var h = Highlighter.init(std.testing.allocator, case.lang).?;
        defer h.deinit();
        h.reparse(case.src);
        var start: usize = 0;
        var row: usize = 0;
        while (row < case.row) : (row += 1) start = std.mem.indexOfScalarPos(u8, case.src, start, '\n').? + 1;
        const eol = std.mem.indexOfScalarPos(u8, case.src, start, '\n') orelse case.src.len;
        const end = if (case.upto) |n| @min(start + n, eol) else eol;
        try std.testing.expectEqual(case.want, h.openIndents(case.row, start, end));
    }
}

test "luaIsRegex accepts only patterns that mean the same thing" {
    // The three `#lua-match?` patterns the vendored Zig query uses.
    try std.testing.expect(luaIsRegex("^[A-Z_][a-zA-Z0-9_]*"));
    try std.testing.expect(luaIsRegex("^[A-Z][A-Z_0-9]+$"));
    try std.testing.expect(luaIsRegex("^//!"));
    // Lua-only syntax: `%` escapes, `()` position captures, `-` lazy repeat.
    try std.testing.expect(!luaIsRegex("%slang%s*="));
    try std.testing.expect(!luaIsRegex("(.+)/(.+)"));
    try std.testing.expect(!luaIsRegex("^a-b"));
    try std.testing.expect(luaIsRegex("[a-z]+")); // a '-' inside a class is a range in both
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
    // Empty sides: a born-empty buffer's first keystroke (insert-all) and a
    // delete-all must both come out as exact edits, not underflow.
    const ins = computeEdit("", "abc");
    try std.testing.expectEqual(@as(u32, 0), ins.start_byte);
    try std.testing.expectEqual(@as(u32, 0), ins.old_end_byte);
    try std.testing.expectEqual(@as(u32, 3), ins.new_end_byte);
    const del = computeEdit("abc", "");
    try std.testing.expectEqual(@as(u32, 0), del.start_byte);
    try std.testing.expectEqual(@as(u32, 3), del.old_end_byte);
    try std.testing.expectEqual(@as(u32, 0), del.new_end_byte);
}

test "highlighting survives an initially-empty parse" {
    // A buffer born empty (`zedit brandnew.py`) parses "" first. The next
    // reparse must describe the empty→text change as a real edit: passing the
    // old tree to ts_parser_parse_string without ts_tree_edit violates the
    // documented contract (vendor api.h) and freezes the stale zero-length
    // root — zero captures, forever.
    const src = "def f():\n    return 1\n";
    var styles: [src.len]syntax.Style = undefined;
    const any = struct {
        fn styled(s: []const syntax.Style) bool {
            for (s) |x| if (x != .normal) return true;
            return false;
        }
    };
    var h = Highlighter.init(std.testing.allocator, .python).?;
    defer h.deinit();
    h.reparse("");
    h.reparse(src);
    h.queryRange(0, src.len, &styles);
    try std.testing.expect(any.styled(&styles));
    // And the inverse transition: delete-all, then retype.
    h.reparse("");
    h.reparse(src);
    h.queryRange(0, src.len, &styles);
    try std.testing.expect(any.styled(&styles));
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

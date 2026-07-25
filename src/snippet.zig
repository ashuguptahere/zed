//! LSP snippet parsing.
//!
//! A completion item with `insertTextFormat: 2` carries snippet syntax rather
//! than literal text:
//!
//!     println!("$1")$0          fn ${1:name}(${2:args}) {\n\t$0\n}
//!
//! `parse` turns that into the plain text to insert plus the tabstops the
//! editor jumps between. Everything here is pure — no allocator state beyond
//! the returned buffers, no I/O — so the fiddly escaping rules are unit-tested
//! directly.
//!
//! Supported (the grammar servers actually emit): `$N` and `${N}` tabstops,
//! `${N:placeholder}` with default text, `${N|a,b,c|}` choices (the first is
//! used as the placeholder), `$0` as the final cursor position, and `\$`,
//! `\}`, `\\` escapes. Variables (`$TM_FILENAME`, `${VAR:default}`) are not
//! resolved: a variable with a default expands to that default, otherwise to
//! nothing — never to a stray `$NAME` in the buffer.

const std = @import("std");

/// One tabstop: where it sits in the produced text, how long its placeholder
/// is, and its snippet index (`$0` is stored as `final = true`, since it is
/// visited last however high the other indices go).
pub const Stop = struct {
    index: u32,
    final: bool,
    offset: usize, // byte offset into `text`
    len: usize, // placeholder length in bytes (0 for a bare $N)
    /// For `${N|a,b,c|}`: the alternatives, comma-separated as written. The
    /// first is used as the placeholder text; the editor cycles the rest.
    choices: ?[]u8 = null,
};

pub const Parsed = struct {
    text: []u8,
    stops: []Stop,

    pub fn deinit(self: *Parsed, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        for (self.stops) |s| {
            if (s.choices) |c| gpa.free(c);
        }
        gpa.free(self.stops);
    }
};

/// Whether `s` contains anything the snippet grammar would act on. Used to
/// skip the whole machinery for the common plain-text case.
pub fn hasTabstops(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == '$') return true;
    }
    return false;
}

/// Parse snippet syntax into literal text plus its tabstops, ordered the way
/// Tab visits them: ascending index, with `$0` last.
pub const Error = error{OutOfMemory};

/// Nesting depth cap. Placeholders nest a level or two in real snippets;
/// the limit exists because the text comes from a language server, and
/// unbounded `${1:${2:${3:…}}}` recursion would otherwise be a stack overflow
/// triggered by remote input. Beyond it, the inner text is taken literally.
const max_depth = 8;

pub fn parse(gpa: std.mem.Allocator, src: []const u8) Error!Parsed {
    return parseDepth(gpa, src, 0);
}

fn parseDepth(gpa: std.mem.Allocator, src: []const u8, depth: u8) Error!Parsed {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var stops: std.ArrayList(Stop) = .empty;
    errdefer stops.deinit(gpa);

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '\\' and i + 1 < src.len) {
            // Only the snippet metacharacters are escapable; anything else
            // keeps its backslash (a Windows path in a snippet stays intact).
            const n = src[i + 1];
            if (n == '$' or n == '}' or n == '\\') {
                try text.append(gpa, n);
                i += 2;
                continue;
            }
            try text.append(gpa, c);
            i += 1;
            continue;
        }
        if (c != '$') {
            try text.append(gpa, c);
            i += 1;
            continue;
        }
        // $ ...
        if (i + 1 < src.len and std.ascii.isDigit(src[i + 1])) {
            var j = i + 1;
            var idx: u32 = 0;
            while (j < src.len and std.ascii.isDigit(src[j])) : (j += 1) idx = idx * 10 + (src[j] - '0');
            try stops.append(gpa, .{ .index = idx, .final = idx == 0, .offset = text.items.len, .len = 0 });
            i = j;
            continue;
        }
        if (i + 1 < src.len and src[i + 1] == '{') {
            if (try parseBraced(gpa, src, i, &text, &stops, depth)) |next| {
                i = next;
                continue;
            }
        }
        if (i + 1 < src.len and isVarStart(src[i + 1])) {
            // A bare variable we cannot resolve contributes nothing.
            var j = i + 1;
            while (j < src.len and isVarChar(src[j])) : (j += 1) {}
            i = j;
            continue;
        }
        try text.append(gpa, c); // a lone '$'
        i += 1;
    }

    const slice = try stops.toOwnedSlice(gpa);
    std.mem.sort(Stop, slice, {}, lessStop);
    return .{ .text = try text.toOwnedSlice(gpa), .stops = slice };
}

/// `${...}`: a numbered tabstop (optionally with a placeholder or choices) or
/// a variable. Returns the index just past the closing brace, or null when the
/// construct is malformed (the caller then treats the `$` literally).
fn parseBraced(
    gpa: std.mem.Allocator,
    src: []const u8,
    start: usize,
    text: *std.ArrayList(u8),
    stops: *std.ArrayList(Stop),
    depth: u8,
) Error!?usize {
    if (depth >= max_depth) return null; // too deep: treat the `$` literally
    const close = matchBrace(src, start + 1) orelse return null;
    const body = src[start + 2 .. close];
    if (body.len == 0) return null;

    if (std.ascii.isDigit(body[0])) {
        var k: usize = 0;
        var idx: u32 = 0;
        while (k < body.len and std.ascii.isDigit(body[k])) : (k += 1) idx = idx * 10 + (body[k] - '0');
        const offset = text.items.len;
        var len: usize = 0;
        var choices: ?[]u8 = null;
        if (k < body.len and body[k] == ':') {
            // Placeholder text may itself contain nested tabstops; those are
            // flattened to their own placeholder text (we keep one level of
            // stops, which is what editors' Tab cycles actually need).
            var inner = try parseDepth(gpa, body[k + 1 ..], depth + 1);
            defer inner.deinit(gpa);
            try text.appendSlice(gpa, inner.text);
            len = inner.text.len;
        } else if (k < body.len and body[k] == '|') {
            // ${N|a,b,c|} — keep every alternative; show the first.
            const end_bar = std.mem.lastIndexOfScalar(u8, body, '|') orelse body.len;
            const list = body[k + 1 .. @max(end_bar, k + 1)];
            const first_end = std.mem.indexOfScalar(u8, list, ',') orelse list.len;
            const first = list[0..first_end];
            try text.appendSlice(gpa, first);
            len = first.len;
            choices = gpa.dupe(u8, list) catch null;
        }
        try stops.append(gpa, .{ .index = idx, .final = idx == 0, .offset = offset, .len = len, .choices = choices });
        return close + 1;
    }

    // ${VAR} / ${VAR:default} — unresolved, so only a default contributes.
    if (std.mem.indexOfScalar(u8, body, ':')) |colon| {
        var inner = try parseDepth(gpa, body[colon + 1 ..], depth + 1);
        defer inner.deinit(gpa);
        try text.appendSlice(gpa, inner.text);
    }
    return close + 1;
}

/// The `}` matching the `{` at `open`, honouring nesting and escapes.
fn matchBrace(src: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '\\' => i += 1,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn isVarStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isVarChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Tab order: ascending index, `$0` last, ties by position.
fn lessStop(_: void, a: Stop, b: Stop) bool {
    if (a.final != b.final) return b.final;
    if (a.index != b.index) return a.index < b.index;
    return a.offset < b.offset;
}

test "plain text has no tabstops" {
    try std.testing.expect(!hasTabstops("just text"));
    try std.testing.expect(!hasTabstops("cost \\$5"));
    try std.testing.expect(hasTabstops("foo($1)"));
}

test "bare tabstops are removed and recorded" {
    const gpa = std.testing.allocator;
    var p = try parse(gpa, "foo($1, $2)$0");
    defer p.deinit(gpa);
    try std.testing.expectEqualStrings("foo(, )", p.text);
    try std.testing.expectEqual(@as(usize, 3), p.stops.len);
    try std.testing.expectEqual(@as(usize, 4), p.stops[0].offset); // $1
    try std.testing.expectEqual(@as(usize, 6), p.stops[1].offset); // $2
    try std.testing.expect(p.stops[2].final); // $0 sorted last
    try std.testing.expectEqual(@as(usize, 7), p.stops[2].offset);
}

test "placeholders keep their text and length" {
    const gpa = std.testing.allocator;
    var p = try parse(gpa, "fn ${1:name}(${2:args}) {}");
    defer p.deinit(gpa);
    try std.testing.expectEqualStrings("fn name(args) {}", p.text);
    try std.testing.expectEqual(@as(usize, 2), p.stops.len);
    try std.testing.expectEqual(@as(usize, 3), p.stops[0].offset);
    try std.testing.expectEqual(@as(usize, 4), p.stops[0].len); // "name"
    try std.testing.expectEqual(@as(usize, 8), p.stops[1].offset);
    try std.testing.expectEqual(@as(usize, 4), p.stops[1].len); // "args"
}

test "final stop sorts after higher indices" {
    const gpa = std.testing.allocator;
    var p = try parse(gpa, "$0 then $1 then $2");
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), p.stops[0].index);
    try std.testing.expectEqual(@as(u32, 2), p.stops[1].index);
    try std.testing.expect(p.stops[2].final);
}

test "choices use the first option and keep the rest" {
    const gpa = std.testing.allocator;
    var p = try parse(gpa, "${1|const,var,let|} x");
    defer p.deinit(gpa);
    try std.testing.expectEqualStrings("const x", p.text);
    try std.testing.expectEqual(@as(usize, 5), p.stops[0].len);
    try std.testing.expectEqualStrings("const,var,let", p.stops[0].choices.?);
}

test "choice list with one entry" {
    const gpa = std.testing.allocator;
    var p = try parse(gpa, "${1|only|}");
    defer p.deinit(gpa);
    try std.testing.expectEqualStrings("only", p.text);
    try std.testing.expectEqualStrings("only", p.stops[0].choices.?);
}

test "escapes stay literal" {
    const gpa = std.testing.allocator;
    var p = try parse(gpa, "price \\$1 and \\} and \\\\ end");
    defer p.deinit(gpa);
    try std.testing.expectEqualStrings("price $1 and } and \\ end", p.text);
    try std.testing.expectEqual(@as(usize, 0), p.stops.len);
}

test "unresolved variables vanish, defaults survive" {
    const gpa = std.testing.allocator;
    var p = try parse(gpa, "$TM_FILENAME/${UNKNOWN:fallback}/end");
    defer p.deinit(gpa);
    try std.testing.expectEqualStrings("/fallback/end", p.text);
}

test "multi-line snippet keeps newlines and tabs" {
    const gpa = std.testing.allocator;
    var p = try parse(gpa, "if ${1:cond} {\n\t$0\n}");
    defer p.deinit(gpa);
    try std.testing.expectEqualStrings("if cond {\n\t\n}", p.text);
    try std.testing.expectEqual(@as(usize, 2), p.stops.len);
    try std.testing.expect(p.stops[1].final);
    try std.testing.expectEqual(@as(usize, 11), p.stops[1].offset); // after "\n\t"
}

test "nested placeholder flattens to its text" {
    const gpa = std.testing.allocator;
    var p = try parse(gpa, "${1:outer ${2:inner}}");
    defer p.deinit(gpa);
    try std.testing.expectEqualStrings("outer inner", p.text);
    try std.testing.expectEqual(@as(usize, 11), p.stops[0].len);
}

test "pathological nesting is bounded, not a stack overflow" {
    const gpa = std.testing.allocator;
    // A hostile language server could send arbitrarily nested placeholders.
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(gpa);
    var i: usize = 0;
    while (i < 5000) : (i += 1) try deep.appendSlice(gpa, "${1:");
    try deep.appendSlice(gpa, "x");
    i = 0;
    while (i < 5000) : (i += 1) try deep.append(gpa, '}');
    var p = try parse(gpa, deep.items);
    defer p.deinit(gpa);
    try std.testing.expect(p.text.len > 0); // parsed to *something*, no crash
}

test "malformed input never panics" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "${", "${1", "$", "${}", "${1:", "\\", "${|}" }) |bad| {
        var p = try parse(gpa, bad);
        p.deinit(gpa);
    }
}

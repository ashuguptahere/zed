//! Lightweight, dependency-free syntax highlighting.
//!
//! A per-line lexer classifies each byte into a `Style`; the editor maps styles
//! to theme colours. This is intentionally simple (no parser, no cross-line
//! state) which is plenty for line-comment languages like Zig and is fast
//! enough to run on every visible line each frame. Tree-sitter is the natural
//! upgrade path now that dependencies are permitted.

const std = @import("std");

pub const Style = enum {
    normal,
    comment,
    keyword,
    type_,
    builtin,
    function,
    string_,
    char_,
    number,
    operator,
    preproc,
};

pub const Language = enum { none, zig, c, python, javascript, typescript, json };

/// Pick a language from a file path's extension.
pub fn detect(path: ?[]const u8) Language {
    const p = path orelse return .none;
    const dot = std.mem.lastIndexOfScalar(u8, p, '.') orelse return .none;
    const ext = p[dot + 1 ..];
    const map = .{
        .{ "zig", Language.zig },
        .{ "c", Language.c },     .{ "h", Language.c },
        .{ "cpp", Language.c },   .{ "cc", Language.c }, .{ "hpp", Language.c },
        .{ "py", Language.python },
        .{ "js", Language.javascript },   .{ "jsx", Language.javascript },   .{ "mjs", Language.javascript },
        .{ "ts", Language.typescript },   .{ "tsx", Language.typescript },
        .{ "json", Language.json },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, ext, entry[0])) return entry[1];
    }
    return .none;
}

const Spec = struct {
    keywords: []const []const u8 = &.{},
    types: []const []const u8 = &.{},
    constants: []const []const u8 = &.{},
    line_comment: []const u8 = "",
    hash_preproc: bool = false, // '#' at line start is a preprocessor line (C)
    at_builtin: bool = false, // '@name' is a builtin (Zig)
    single_quote_string: bool = false, // '...' is a string, not a char (Python/JS)
};

/// Classify every byte of `line` into `out` (which must be `line.len` long).
pub fn highlight(lang: Language, line: []const u8, out: []Style) void {
    std.debug.assert(out.len == line.len);
    @memset(out, .normal);
    const spec = specFor(lang);

    var i: usize = 0;
    var seen_nonws = false;
    while (i < line.len) {
        const c = line[i];
        if (c == ' ' or c == '\t') {
            i += 1;
            continue;
        }

        // Preprocessor line (C): '#' as the first non-blank char.
        if (spec.hash_preproc and !seen_nonws and c == '#') {
            fill(out, i, line.len, .preproc);
            return;
        }
        seen_nonws = true;

        // Line comment to end of line.
        if (spec.line_comment.len > 0 and startsWith(line, i, spec.line_comment)) {
            fill(out, i, line.len, .comment);
            return;
        }
        // Zig builtins: @name
        if (spec.at_builtin and c == '@' and i + 1 < line.len and isIdentStart(line[i + 1])) {
            const e = identEnd(line, i + 1);
            fill(out, i, e, .builtin);
            i = e;
            continue;
        }
        if (c == '"') {
            i = lexString(line, i, '"', out, .string_);
            continue;
        }
        if (c == '\'') {
            const style: Style = if (spec.single_quote_string) .string_ else .char_;
            i = lexString(line, i, '\'', out, style);
            continue;
        }
        if (isDigit(c)) {
            const e = numberEnd(line, i);
            fill(out, i, e, .number);
            i = e;
            continue;
        }
        if (isIdentStart(c)) {
            const e = identEnd(line, i);
            const word = line[i..e];
            const style = classifyWord(spec, word, line, e);
            fill(out, i, e, style);
            i = e;
            continue;
        }
        // Punctuation / operators.
        if (isOperator(c)) out[i] = .operator;
        i += 1;
    }
}

fn classifyWord(spec: Spec, word: []const u8, line: []const u8, after: usize) Style {
    if (inList(spec.keywords, word)) return .keyword;
    if (inList(spec.types, word)) return .type_;
    if (inList(spec.constants, word)) return .builtin;
    if (looksLikeType(word)) return .type_;
    // A call: identifier immediately followed by '('.
    if (after < line.len and line[after] == '(') return .function;
    return .normal;
}

/// Heuristic: CamelCase / leading-capital words read as types (e.g. `Editor`).
fn looksLikeType(word: []const u8) bool {
    return word.len > 1 and word[0] >= 'A' and word[0] <= 'Z';
}

fn lexString(line: []const u8, start: usize, quote: u8, out: []Style, style: Style) usize {
    var j = start + 1;
    while (j < line.len) {
        if (line[j] == '\\' and j + 1 < line.len) {
            j += 2;
            continue;
        }
        if (line[j] == quote) {
            j += 1;
            break;
        }
        j += 1;
    }
    fill(out, start, j, style);
    return j;
}

fn numberEnd(line: []const u8, start: usize) usize {
    var j = start;
    while (j < line.len) {
        const c = line[j];
        if (isDigit(c) or c == '.' or c == '_' or c == 'x' or c == 'b' or c == 'o' or
            (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))
        {
            j += 1;
        } else break;
    }
    return j;
}

fn identEnd(line: []const u8, start: usize) usize {
    var j = start;
    while (j < line.len and isIdentChar(line[j])) j += 1;
    return j;
}

fn fill(out: []Style, start: usize, end: usize, style: Style) void {
    var k = start;
    while (k < end) : (k += 1) out[k] = style;
}

fn startsWith(line: []const u8, at: usize, needle: []const u8) bool {
    return at + needle.len <= line.len and std.mem.eql(u8, line[at .. at + needle.len], needle);
}

fn inList(list: []const []const u8, word: []const u8) bool {
    for (list) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isIdentStart(c: u8) bool {
    return c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c >= 0x80;
}
fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}
fn isOperator(c: u8) bool {
    return std.mem.indexOfScalar(u8, "+-*/%=<>!&|^~?:.,;(){}[]", c) != null;
}

fn specFor(lang: Language) Spec {
    return switch (lang) {
        .zig => .{
            .keywords = &.{ "const", "var", "fn", "pub", "return", "if", "else", "while", "for", "switch", "struct", "enum", "union", "error", "try", "catch", "defer", "errdefer", "comptime", "inline", "test", "and", "or", "orelse", "unreachable", "break", "continue", "export", "extern", "packed", "opaque", "anytype", "volatile", "threadlocal", "callconv", "align", "noalias", "asm", "usingnamespace" },
            .types = &.{ "bool", "void", "type", "anyerror", "noreturn", "usize", "isize", "u8", "u16", "u32", "u64", "u128", "i8", "i16", "i32", "i64", "i128", "f16", "f32", "f64", "f128", "c_int", "c_uint", "comptime_int", "comptime_float", "anyopaque" },
            .constants = &.{ "true", "false", "null", "undefined" },
            .line_comment = "//",
            .at_builtin = true,
        },
        .c => .{
            .keywords = &.{ "auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern", "for", "goto", "if", "inline", "register", "return", "sizeof", "static", "struct", "switch", "typedef", "union", "volatile", "while", "class", "public", "private", "protected", "namespace", "template", "new", "delete", "using" },
            .types = &.{ "void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "bool", "size_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t" },
            .constants = &.{ "true", "false", "NULL", "nullptr" },
            .line_comment = "//",
            .hash_preproc = true,
        },
        .python => .{
            .keywords = &.{ "def", "class", "import", "from", "as", "return", "if", "elif", "else", "for", "while", "with", "try", "except", "finally", "raise", "lambda", "yield", "global", "nonlocal", "pass", "break", "continue", "in", "is", "not", "and", "or", "async", "await", "del", "assert" },
            .types = &.{ "int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes", "object" },
            .constants = &.{ "True", "False", "None", "self", "cls" },
            .line_comment = "#",
            .single_quote_string = true,
        },
        .javascript, .typescript => .{
            .keywords = &.{ "var", "let", "const", "function", "return", "if", "else", "for", "while", "switch", "case", "break", "continue", "new", "class", "extends", "import", "export", "from", "default", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "async", "await", "yield", "this", "interface", "type", "enum", "namespace", "implements", "readonly", "public", "private", "protected", "abstract", "as", "declare" },
            .types = &.{ "Number", "String", "Boolean", "Object", "Array", "Promise", "number", "string", "boolean", "any", "void", "unknown", "never" },
            .constants = &.{ "true", "false", "null", "undefined", "NaN" },
            .line_comment = "//",
            .single_quote_string = true,
        },
        .json => .{
            .constants = &.{ "true", "false", "null" },
        },
        .none => .{ .line_comment = "" },
    };
}

const testing = std.testing;

test "detect language" {
    try testing.expectEqual(Language.zig, detect("src/main.zig"));
    try testing.expectEqual(Language.python, detect("a/b.py"));
    try testing.expectEqual(Language.javascript, detect("app.js"));
    try testing.expectEqual(Language.typescript, detect("app.ts"));
    try testing.expectEqual(Language.typescript, detect("ui.tsx"));
    try testing.expectEqual(Language.none, detect("README"));
}

test "highlight zig line" {
    const line = "const x = foo(42); // hi";
    var styles: [line.len]Style = undefined;
    highlight(.zig, line, &styles);
    try testing.expectEqual(Style.keyword, styles[0]); // 'const'
    try testing.expectEqual(Style.function, styles[10]); // 'foo' before '('
    try testing.expectEqual(Style.number, styles[14]); // '42'
    try testing.expectEqual(Style.comment, styles[20]); // '//'
}

test "highlight string and builtin" {
    const line = "@import(\"std\")";
    var styles: [line.len]Style = undefined;
    highlight(.zig, line, &styles);
    try testing.expectEqual(Style.builtin, styles[0]); // '@import'
    try testing.expectEqual(Style.string_, styles[8]); // inside the string
}

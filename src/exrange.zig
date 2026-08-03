//! Ex addresses and ranges, as pure functions over the command text.
//!
//! `:[range]cmd` is the half of vim's command line zedit never had: `:%d`,
//! `:1,5>`, `:.,+3y`, `:'a,'bd`, `:/foo/,/bar/d`, and the `:g`/`:v`/`:normal`
//! that hang off the same machinery. Parsing is separated from resolution on
//! purpose — an address like `/pat/` or `'a` needs the buffer to mean
//! anything, but deciding *what was written* needs nothing but the bytes, and
//! that is the error-prone half.
//!
//! The grammar, following vim's `:help :range`:
//!
//!     range  := '%' | addr (sep addr)?
//!     sep    := ',' | ';'
//!     addr   := base? offset*
//!     base   := '.' | '$' | digits | "'" mark | '/' pat '/'? | '?' pat '?'?
//!     offset := ('+' | '-') digits?

const std = @import("std");

/// Where an address starts from, before its offsets are applied.
pub const Base = union(enum) {
    current, // `.`, and the default when only an offset is written
    last, // `$`
    line: usize, // an absolute 1-based line number
    mark: u8, // `'a`; `'<` and `'>` are the visual selection's ends
    fwd: []const u8, // `/pat/` — the next line matching, from the cursor
    bwd: []const u8, // `?pat?` — the previous line matching
};

pub const Addr = struct {
    base: Base = .current,
    /// Sum of the `+n`/`-n` suffixes. A bare `+` is +1 and `--` is -2, as in
    /// vim.
    offset: i64 = 0,
};

pub const Range = struct {
    lo: Addr = .{},
    hi: Addr = .{},
    /// How many addresses were actually written: 0 leaves the command to pick
    /// its own default, 1 means `lo == hi`, 2 is a real range. Commands need
    /// this — `:d` with no range takes one line, with `%` takes the file.
    count: u8 = 0,
    /// `;` rather than `,`: the cursor moves to `lo` before `hi` is resolved,
    /// so `:.;+2` counts its offset from the *first* address.
    semicolon: bool = false,
};

pub const Parsed = struct {
    range: Range,
    /// What follows the range — the command itself, untouched.
    rest: []const u8,
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Parse one address. Returns null when nothing address-like is at `i`,
/// leaving `i` untouched so the caller can treat it as the command.
fn parseAddr(s: []const u8, i: *usize) ?Addr {
    var p = i.*;
    var a: Addr = .{};
    var have = false;

    if (p < s.len) switch (s[p]) {
        '.' => {
            a.base = .current;
            have = true;
            p += 1;
        },
        '$' => {
            a.base = .last;
            have = true;
            p += 1;
        },
        '\'' => {
            if (p + 1 >= s.len) return null;
            a.base = .{ .mark = s[p + 1] };
            have = true;
            p += 2;
        },
        '/', '?' => {
            const term = s[p];
            p += 1;
            const start = p;
            while (p < s.len and s[p] != term) : (p += 1) {
                if (s[p] == '\\' and p + 1 < s.len) p += 1; // an escaped delimiter
            }
            const pat = s[start..p];
            if (p < s.len) p += 1; // the closing delimiter is optional at the end
            a.base = if (term == '/') .{ .fwd = pat } else .{ .bwd = pat };
            have = true;
        },
        '0'...'9' => {
            const start = p;
            while (p < s.len and isDigit(s[p])) p += 1;
            a.base = .{ .line = std.fmt.parseInt(usize, s[start..p], 10) catch return null };
            have = true;
        },
        else => {},
    };

    // Offsets, which may appear with no base at all (`:+3d`) and may repeat.
    while (p < s.len and (s[p] == '+' or s[p] == '-')) {
        const sign: i64 = if (s[p] == '+') 1 else -1;
        p += 1;
        const start = p;
        while (p < s.len and isDigit(s[p])) p += 1;
        const n: i64 = if (p == start) 1 else @intCast(std.fmt.parseInt(u32, s[start..p], 10) catch 1);
        a.offset += sign * n;
        have = true;
    }

    if (!have) return null;
    i.* = p;
    return a;
}

/// Split a command line into its leading range and the rest. Never fails: a
/// line with no range comes back with `count == 0` and `rest` as written.
pub fn parse(s: []const u8) Parsed {
    var i: usize = 0;
    while (i < s.len and s[i] == ' ') i += 1;

    if (i < s.len and s[i] == '%') {
        // `%` is exactly `1,$` — vim says so, and treating it that way keeps
        // one resolution path instead of a special case downstream.
        return .{
            .range = .{
                .lo = .{ .base = .{ .line = 1 } },
                .hi = .{ .base = .last },
                .count = 2,
            },
            .rest = std.mem.trimStart(u8, s[i + 1 ..], " "),
        };
    }

    const first = parseAddr(s, &i) orelse return .{ .range = .{}, .rest = s };
    var r: Range = .{ .lo = first, .hi = first, .count = 1 };

    if (i < s.len and (s[i] == ',' or s[i] == ';')) {
        r.semicolon = s[i] == ';';
        i += 1;
        // `:5,` with nothing after it means `5,.` — vim defaults the missing
        // half to the current line rather than refusing the command.
        r.hi = parseAddr(s, &i) orelse Addr{};
        r.count = 2;
    }
    return .{ .range = r, .rest = std.mem.trimStart(u8, s[i..], " ") };
}

// ---------------------------------------------------------------------------

test "no range at all" {
    const p = parse("wq");
    try std.testing.expectEqual(@as(u8, 0), p.range.count);
    try std.testing.expectEqualStrings("wq", p.rest);
}

test "% is 1,$" {
    const p = parse("%d");
    try std.testing.expectEqual(@as(u8, 2), p.range.count);
    try std.testing.expectEqual(@as(usize, 1), p.range.lo.base.line);
    try std.testing.expect(p.range.hi.base == .last);
    try std.testing.expectEqualStrings("d", p.rest);
}

test "a single line number" {
    const p = parse("5d");
    try std.testing.expectEqual(@as(u8, 1), p.range.count);
    try std.testing.expectEqual(@as(usize, 5), p.range.lo.base.line);
    try std.testing.expectEqual(@as(usize, 5), p.range.hi.base.line);
    try std.testing.expectEqualStrings("d", p.rest);
}

test "two line numbers" {
    const p = parse("2,7y");
    try std.testing.expectEqual(@as(u8, 2), p.range.count);
    try std.testing.expectEqual(@as(usize, 2), p.range.lo.base.line);
    try std.testing.expectEqual(@as(usize, 7), p.range.hi.base.line);
    try std.testing.expectEqualStrings("y", p.rest);
}

test "dot and dollar" {
    const p = parse(".,$d");
    try std.testing.expect(p.range.lo.base == .current);
    try std.testing.expect(p.range.hi.base == .last);
}

test "offsets, bare and counted, with and without a base" {
    {
        const p = parse(".,+3y");
        try std.testing.expect(p.range.lo.base == .current);
        try std.testing.expectEqual(@as(i64, 3), p.range.hi.offset);
        try std.testing.expect(p.range.hi.base == .current);
    }
    {
        const p = parse("-2,+2d"); // no base written on either side
        try std.testing.expectEqual(@as(i64, -2), p.range.lo.offset);
        try std.testing.expectEqual(@as(i64, 2), p.range.hi.offset);
    }
    {
        const p = parse("$-1d");
        try std.testing.expect(p.range.lo.base == .last);
        try std.testing.expectEqual(@as(i64, -1), p.range.lo.offset);
    }
    {
        const p = parse("+++d"); // a bare + is +1, and they add up
        try std.testing.expectEqual(@as(i64, 3), p.range.lo.offset);
        try std.testing.expectEqualStrings("d", p.rest);
    }
}

test "marks, including the visual pair" {
    {
        const p = parse("'a,'bd");
        try std.testing.expectEqual(@as(u8, 'a'), p.range.lo.base.mark);
        try std.testing.expectEqual(@as(u8, 'b'), p.range.hi.base.mark);
    }
    {
        const p = parse("'<,'>normal A;");
        try std.testing.expectEqual(@as(u8, '<'), p.range.lo.base.mark);
        try std.testing.expectEqual(@as(u8, '>'), p.range.hi.base.mark);
        try std.testing.expectEqualStrings("normal A;", p.rest);
    }
}

test "pattern addresses" {
    {
        const p = parse("/foo/d");
        try std.testing.expectEqualStrings("foo", p.range.lo.base.fwd);
        try std.testing.expectEqualStrings("d", p.rest);
    }
    {
        const p = parse("?bar?,/baz/d");
        try std.testing.expectEqualStrings("bar", p.range.lo.base.bwd);
        try std.testing.expectEqualStrings("baz", p.range.hi.base.fwd);
    }
    {
        // An escaped delimiter stays inside the pattern.
        const p = parse("/a\\/b/d");
        try std.testing.expectEqualStrings("a\\/b", p.range.lo.base.fwd);
    }
    {
        // The closing delimiter may be left off at the end of the line.
        const p = parse("/foo");
        try std.testing.expectEqualStrings("foo", p.range.lo.base.fwd);
        try std.testing.expectEqualStrings("", p.rest);
    }
}

test "semicolon is remembered, comma is not" {
    try std.testing.expect(parse(".;+2d").range.semicolon);
    try std.testing.expect(!parse(".,+2d").range.semicolon);
}

test "a trailing separator defaults the missing half to the current line" {
    const p = parse("5,d");
    try std.testing.expectEqual(@as(u8, 2), p.range.count);
    try std.testing.expectEqual(@as(usize, 5), p.range.lo.base.line);
    try std.testing.expect(p.range.hi.base == .current);
    try std.testing.expectEqualStrings("d", p.rest);
}

test "a bare range leaves no command behind" {
    const p = parse("$");
    try std.testing.expectEqual(@as(u8, 1), p.range.count);
    try std.testing.expectEqualStrings("", p.rest);
}

test "a command starting with a letter is not an address" {
    for ([_][]const u8{ "wq", "normal x", "g/foo/d", "theme nord" }) |s| {
        const p = parse(s);
        try std.testing.expectEqual(@as(u8, 0), p.range.count);
        try std.testing.expectEqualStrings(s, p.rest);
    }
}

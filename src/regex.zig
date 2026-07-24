//! A small regular-expression engine: a Pike VM (Thompson NFA simulation
//! with capture slots).
//!
//! Matching is linear in the haystack and never backtracks, so a pathological
//! pattern cannot hang the editor. The syntax is the modern ("very magic")
//! dialect of Helix/ripgrep, not vim's magic mode:
//!
//! - literals; `.` matches any byte except '\n'
//! - classes `[abc]`, ranges `[a-z]`, negation `[^…]`, `\w \d \s` inside
//! - escapes `\w \W \d \D \s \S`, `\t \n \r`, and `\.` etc. for literal metas
//! - anchors `^` `$` (haystack start/end), `\b`, `\<` `\>` (word start/end)
//! - greedy quantifiers `*` `+` `?`, capturing groups `(…)` 1-9, `|`
//!
//! Counted repeats `{m,n}`, backreferences, lookaround and non-greedy
//! quantifiers are rejected with `error.InvalidPattern`.

const std = @import("std");

pub const Span = struct { start: usize, end: usize };

pub const Match = struct {
    /// The whole match (group 0).
    span: Span,
    /// `groups[i]` is capture group i+1; null when the group didn't take part.
    groups: [9]?Span,
};

/// Capture slots: start/end for group 0 (the whole match) and groups 1-9.
const slot_count = 20;
const no_pos = std.math.maxInt(usize);
const Slots = [slot_count]usize;

/// A 256-bit byte-membership set for character classes.
const ClassSet = [32]u8;

const Assert = enum { begin, end, word_boundary, word_start, word_end };

/// One VM instruction. `jmp`/`split`/`save`/`assert` are zero-width and get
/// resolved when a thread is added; the rest consume exactly one byte.
const Inst = union(enum) {
    /// One exact byte (already lowercased when case-insensitive).
    char: u8,
    /// Any byte except '\n'.
    any,
    /// Any byte in the set.
    class: ClassSet,
    /// Zero-width position test.
    assert: Assert,
    /// Store the current position in capture slot `n`.
    save: u8,
    /// Fork: try `a` first — priority order is what makes `*` greedy.
    split: [2]u32,
    jmp: u32,
    /// The whole pattern matched.
    match,
};

const Thread = struct { pc: u32, slots: Slots };

/// A fixed-capacity thread list backed by the compile-time scratch buffer;
/// each pc appears at most once per list, so `prog.len` slots always suffice.
const List = struct { items: []Thread, len: usize = 0 };

/// Bytes that make a pattern more than a plain string (for `literal`).
const meta_bytes = "\\.*+?()[]|^${";

pub const Regex = struct {
    prog: []Inst,
    fold: bool,
    lit: ?[]u8,
    /// Scratch for `find` (two thread lists and a per-pc visited stamp),
    /// allocated once here so matching never allocates or fails. `find` is
    /// therefore not reentrant — fine for the single-threaded editor.
    threads: []Thread,
    seen: []usize,

    pub fn compile(gpa: std.mem.Allocator, pattern: []const u8, case_insensitive: bool) error{ InvalidPattern, OutOfMemory }!Regex {
        // Parse to a small AST (arena-backed, freed wholesale), then emit
        // the NFA program.
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        var parser: Parser = .{ .pat = pattern, .arena = arena_state.allocator(), .fold = case_insensitive };
        const ast = try parser.parseAlt(0);
        if (parser.i != pattern.len) return error.InvalidPattern; // unbalanced ')'

        var prog: std.ArrayList(Inst) = .empty;
        errdefer prog.deinit(gpa);
        try prog.append(gpa, .{ .save = 0 });
        try emit(&prog, gpa, ast);
        try prog.append(gpa, .{ .save = 1 });
        try prog.append(gpa, .match);

        const threads = try gpa.alloc(Thread, 2 * prog.items.len);
        errdefer gpa.free(threads);
        const seen = try gpa.alloc(usize, prog.items.len);
        errdefer gpa.free(seen);

        // A pattern with no metacharacter at all is a plain string; keep a
        // copy so callers can use substring search as a fast path.
        var lit: ?[]u8 = null;
        if (!case_insensitive and std.mem.indexOfAny(u8, pattern, meta_bytes) == null)
            lit = try gpa.dupe(u8, pattern);
        errdefer if (lit) |l| gpa.free(l);

        return .{
            .prog = try prog.toOwnedSlice(gpa),
            .fold = case_insensitive,
            .lit = lit,
            .threads = threads,
            .seen = seen,
        };
    }

    pub fn deinit(self: *Regex, gpa: std.mem.Allocator) void {
        gpa.free(self.prog);
        gpa.free(self.threads);
        gpa.free(self.seen);
        if (self.lit) |l| gpa.free(l);
        self.* = undefined;
    }

    /// Leftmost match at or after `from` (then longest, via greedy thread
    /// priority). May return an empty match (span.start == span.end), e.g.
    /// for `a*` on "b"; callers iterating over matches must advance one byte
    /// past an empty match to make progress.
    pub fn find(self: *const Regex, haystack: []const u8, from: usize) ?Match {
        if (from > haystack.len) return null;

        const n = self.prog.len;
        var clist: List = .{ .items = self.threads[0..n] };
        var nlist: List = .{ .items = self.threads[n..] };
        @memset(self.seen, 0);
        var gen: usize = 1;
        var matched: ?Slots = null;

        const fresh: Slots = @splat(no_pos);
        var pos = from;
        self.addThread(&clist, gen, 0, pos, &fresh, haystack);

        while (true) {
            gen += 1;
            var i: usize = 0;
            while (i < clist.len) : (i += 1) {
                const t = clist.items[i];
                const consume = switch (self.prog[t.pc]) {
                    .char => |c| pos < haystack.len and (if (self.fold) lower(haystack[pos]) else haystack[pos]) == c,
                    .any => pos < haystack.len and haystack[pos] != '\n',
                    .class => |set| pos < haystack.len and hasBit(&set, haystack[pos]),
                    .match => {
                        // Threads after this one have lower priority: drop
                        // them. Surviving higher-priority threads may still
                        // overwrite this with a better (greedier) match.
                        matched = t.slots;
                        break;
                    },
                    else => unreachable, // zero-width ops are resolved in addThread
                };
                if (consume) self.addThread(&nlist, gen, t.pc + 1, pos + 1, &t.slots, haystack);
            }
            if (pos >= haystack.len) break;
            pos += 1;
            const tmp = clist;
            clist = nlist;
            nlist = tmp;
            nlist.len = 0;
            // Seed a lowest-priority thread at this start position — unless
            // a match is already in hand, which only earlier (higher
            // priority) threads may improve. This keeps the search leftmost.
            if (matched == null) self.addThread(&clist, gen, 0, pos, &fresh, haystack);
            if (matched != null and clist.len == 0) break;
        }

        const slots = matched orelse return null;
        var m: Match = .{ .span = .{ .start = slots[0], .end = slots[1] }, .groups = @splat(null) };
        for (&m.groups, 1..) |*g, grp| {
            if (slots[2 * grp] != no_pos and slots[2 * grp + 1] != no_pos)
                g.* = .{ .start = slots[2 * grp], .end = slots[2 * grp + 1] };
        }
        return m;
    }

    /// If the whole pattern is one literal string (no metacharacters,
    /// case-sensitive), return it — callers use SIMD substring search as a
    /// fast path. Null otherwise.
    pub fn literal(self: *const Regex) ?[]const u8 {
        return self.lit;
    }

    /// Add thread `pc` to `list`, resolving zero-width instructions (jumps,
    /// forks, saves, asserts) on the spot. The `seen` stamp keeps every pc
    /// unique per list, which both bounds the list and cuts empty-width
    /// loops like `()*`. Recursion depth is bounded by the program length.
    fn addThread(self: *const Regex, list: *List, gen: usize, pc: u32, pos: usize, slots: *const Slots, haystack: []const u8) void {
        if (self.seen[pc] == gen) return;
        self.seen[pc] = gen;
        switch (self.prog[pc]) {
            .jmp => |t| self.addThread(list, gen, t, pos, slots, haystack),
            .split => |ab| {
                self.addThread(list, gen, ab[0], pos, slots, haystack);
                self.addThread(list, gen, ab[1], pos, slots, haystack);
            },
            .save => |slot| {
                var s = slots.*;
                s[slot] = pos;
                self.addThread(list, gen, pc + 1, pos, &s, haystack);
            },
            .assert => |a| if (holds(a, haystack, pos)) self.addThread(list, gen, pc + 1, pos, slots, haystack),
            else => {
                list.items[list.len] = .{ .pc = pc, .slots = slots.* };
                list.len += 1;
            },
        }
    }
};

// ---------------------------------------------------------------- parsing

/// Nesting cap so a hostile pattern can't overflow the parse/emit stack.
const max_group_depth = 64;

const Node = union(enum) {
    /// Matches the empty string (empty pattern or alternation branch).
    empty,
    char: u8,
    any,
    class: ClassSet,
    assert: Assert,
    group: struct { idx: u8, body: *Node },
    star: *Node,
    plus: *Node,
    quest: *Node,
    concat: [2]*Node,
    alt: [2]*Node,
};

const Parser = struct {
    pat: []const u8,
    i: usize = 0,
    arena: std.mem.Allocator,
    fold: bool,
    ngroups: u8 = 0,

    const Error = error{ InvalidPattern, OutOfMemory };

    fn mk(p: *Parser, node: Node) Error!*Node {
        const n = try p.arena.create(Node);
        n.* = node;
        return n;
    }

    fn peekIs(p: *const Parser, c: u8) bool {
        return p.i < p.pat.len and p.pat[p.i] == c;
    }

    /// alternation := concat ('|' concat)* — lowest precedence.
    fn parseAlt(p: *Parser, depth: u32) Error!*Node {
        var node = try p.parseConcat(depth);
        while (p.peekIs('|')) {
            p.i += 1;
            node = try p.mk(.{ .alt = .{ node, try p.parseConcat(depth) } });
        }
        return node;
    }

    fn parseConcat(p: *Parser, depth: u32) Error!*Node {
        var node: ?*Node = null;
        while (p.i < p.pat.len and p.pat[p.i] != '|' and p.pat[p.i] != ')') {
            const atom = try p.parseRepeat(depth);
            node = if (node) |l| try p.mk(.{ .concat = .{ l, atom } }) else atom;
        }
        return node orelse p.mk(.empty);
    }

    /// One atom with an optional greedy quantifier. A quantifier with
    /// nothing before it — including the second one in `a*?`, so non-greedy
    /// syntax is rejected rather than misread — lands in parseAtom's error.
    fn parseRepeat(p: *Parser, depth: u32) Error!*Node {
        const atom = try p.parseAtom(depth);
        if (p.i < p.pat.len) switch (p.pat[p.i]) {
            '*' => {
                p.i += 1;
                return p.mk(.{ .star = atom });
            },
            '+' => {
                p.i += 1;
                return p.mk(.{ .plus = atom });
            },
            '?' => {
                p.i += 1;
                return p.mk(.{ .quest = atom });
            },
            else => {},
        };
        return atom;
    }

    fn parseAtom(p: *Parser, depth: u32) Error!*Node {
        const c = p.pat[p.i];
        p.i += 1;
        switch (c) {
            '(' => {
                if (depth >= max_group_depth) return error.InvalidPattern;
                p.ngroups += 1;
                if (p.ngroups > 9) return error.InvalidPattern; // only groups 1-9
                const idx = p.ngroups;
                const body = try p.parseAlt(depth + 1);
                if (!p.peekIs(')')) return error.InvalidPattern; // unclosed group
                p.i += 1;
                return p.mk(.{ .group = .{ .idx = idx, .body = body } });
            },
            '[' => return p.parseClass(),
            '\\' => return p.parseEscape(),
            '.' => return p.mk(.any),
            '^' => return p.mk(.{ .assert = .begin }),
            '$' => return p.mk(.{ .assert = .end }),
            '*', '+', '?' => return error.InvalidPattern, // nothing to repeat
            '{' => return error.InvalidPattern, // counted repeats unsupported
            else => return p.mk(.{ .char = if (p.fold) lower(c) else c }),
        }
    }

    /// An escape outside a class: `\w`-family sets, anchors, control
    /// characters, or an escaped metacharacter. Anything else (e.g. a
    /// backreference `\1`) is rejected.
    fn parseEscape(p: *Parser) Error!*Node {
        if (p.i >= p.pat.len) return error.InvalidPattern; // trailing '\'
        const c = p.pat[p.i];
        p.i += 1;
        return switch (c) {
            'w', 'W', 'd', 'D', 's', 'S' => blk: {
                var set: ClassSet = @splat(0);
                addPerl(&set, c);
                break :blk p.mk(.{ .class = set });
            },
            'b' => p.mk(.{ .assert = .word_boundary }),
            '<' => p.mk(.{ .assert = .word_start }),
            '>' => p.mk(.{ .assert = .word_end }),
            't' => p.mk(.{ .char = '\t' }),
            'n' => p.mk(.{ .char = '\n' }),
            'r' => p.mk(.{ .char = '\r' }),
            '.', '\\', '*', '+', '?', '(', ')', '[', ']', '|', '^', '$', '/', '{', '}' => p.mk(.{ .char = c }),
            else => error.InvalidPattern,
        };
    }

    /// `[...]` — ranges, negation, `]` as a first member, literal `-` when
    /// first or last, and the `\w \d \s` family inside.
    fn parseClass(p: *Parser) Error!*Node {
        var set: ClassSet = @splat(0);
        const neg = p.peekIs('^');
        if (neg) p.i += 1;
        var first = true;
        while (true) {
            if (p.i >= p.pat.len) return error.InvalidPattern; // unclosed '['
            var c = p.pat[p.i];
            if (c == ']' and !first) {
                p.i += 1;
                break;
            }
            first = false;
            p.i += 1;
            if (c == '\\') {
                if (p.i >= p.pat.len) return error.InvalidPattern;
                const e = p.pat[p.i];
                p.i += 1;
                switch (e) {
                    'w', 'W', 'd', 'D', 's', 'S' => {
                        addPerl(&set, e);
                        continue;
                    },
                    't' => c = '\t',
                    'n' => c = '\n',
                    'r' => c = '\r',
                    else => c = e, // \] \- \\ … taken literally
                }
            }
            // A '-' right before ']' is a literal member, not a range.
            if (p.peekIs('-') and p.i + 1 < p.pat.len and p.pat[p.i + 1] != ']') {
                p.i += 1; // the '-'
                var hi = p.pat[p.i];
                p.i += 1;
                if (hi == '\\') {
                    if (p.i >= p.pat.len) return error.InvalidPattern;
                    hi = switch (p.pat[p.i]) {
                        't' => '\t',
                        'n' => '\n',
                        'r' => '\r',
                        'w', 'W', 'd', 'D', 's', 'S' => return error.InvalidPattern, // a set can't end a range
                        else => |e| e,
                    };
                    p.i += 1;
                }
                if (c > hi) return error.InvalidPattern; // backwards range
                setRange(&set, c, hi);
            } else {
                setBit(&set, c);
            }
        }
        if (p.fold) foldClass(&set);
        if (neg) for (&set) |*b| {
            b.* = ~b.*;
        };
        return p.mk(.{ .class = set });
    }
};

// ------------------------------------------------------------- compiling

/// Emit `node` as NFA instructions (Thompson's construction):
///
///   e1|e2  →  split L1, L2; L1: e1; jmp L3; L2: e2; L3:
///   e*     →  L1: split L2, L3; L2: e; jmp L1; L3:
///   e+     →  L1: e; split L1, L2; L2:
///   e?     →  split L1, L2; L1: e; L2:
fn emit(prog: *std.ArrayList(Inst), gpa: std.mem.Allocator, node: *const Node) error{OutOfMemory}!void {
    switch (node.*) {
        .empty => {},
        .char => |c| try prog.append(gpa, .{ .char = c }),
        .any => try prog.append(gpa, .any),
        .class => |set| try prog.append(gpa, .{ .class = set }),
        .assert => |a| try prog.append(gpa, .{ .assert = a }),
        .group => |g| {
            try prog.append(gpa, .{ .save = 2 * g.idx });
            try emit(prog, gpa, g.body);
            try prog.append(gpa, .{ .save = 2 * g.idx + 1 });
        },
        .concat => |pair| {
            try emit(prog, gpa, pair[0]);
            try emit(prog, gpa, pair[1]);
        },
        .alt => |pair| {
            const fork = prog.items.len;
            try prog.append(gpa, .{ .split = .{ @intCast(fork + 1), 0 } });
            try emit(prog, gpa, pair[0]);
            const hop = prog.items.len;
            try prog.append(gpa, .{ .jmp = 0 });
            prog.items[fork].split[1] = @intCast(prog.items.len);
            try emit(prog, gpa, pair[1]);
            prog.items[hop].jmp = @intCast(prog.items.len);
        },
        .star => |body| {
            const fork = prog.items.len;
            try prog.append(gpa, .{ .split = .{ @intCast(fork + 1), 0 } });
            try emit(prog, gpa, body);
            try prog.append(gpa, .{ .jmp = @intCast(fork) });
            prog.items[fork].split[1] = @intCast(prog.items.len);
        },
        .plus => |body| {
            const start = prog.items.len;
            try emit(prog, gpa, body);
            const fork = prog.items.len;
            try prog.append(gpa, .{ .split = .{ @intCast(start), @intCast(fork + 1) } });
        },
        .quest => |body| {
            const fork = prog.items.len;
            try prog.append(gpa, .{ .split = .{ @intCast(fork + 1), 0 } });
            try emit(prog, gpa, body);
            prog.items[fork].split[1] = @intCast(prog.items.len);
        },
    }
}

// ------------------------------------------------------------ characters

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

fn isWord(c: u8) bool {
    return c == '_' or (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn holds(a: Assert, haystack: []const u8, pos: usize) bool {
    const before = pos > 0 and isWord(haystack[pos - 1]);
    const after = pos < haystack.len and isWord(haystack[pos]);
    return switch (a) {
        .begin => pos == 0,
        .end => pos == haystack.len,
        .word_boundary => before != after,
        .word_start => !before and after,
        .word_end => before and !after,
    };
}

fn setBit(set: *ClassSet, c: u8) void {
    set[c >> 3] |= @as(u8, 1) << @intCast(c & 7);
}

fn hasBit(set: *const ClassSet, c: u8) bool {
    return set[c >> 3] & (@as(u8, 1) << @intCast(c & 7)) != 0;
}

fn setRange(set: *ClassSet, lo: u8, hi: u8) void {
    var c = lo;
    while (true) {
        setBit(set, c);
        if (c == hi) break; // loop shape avoids overflow when hi == 255
        c += 1;
    }
}

/// Merge a `\w`-family escape into `set` (uppercase = complemented).
fn addPerl(set: *ClassSet, esc: u8) void {
    var s: ClassSet = @splat(0);
    switch (lower(esc)) {
        'w' => {
            setRange(&s, 'a', 'z');
            setRange(&s, 'A', 'Z');
            setRange(&s, '0', '9');
            setBit(&s, '_');
        },
        'd' => setRange(&s, '0', '9'),
        's' => for ([_]u8{ ' ', '\t', '\n', '\r', 0x0b, 0x0c }) |c| setBit(&s, c),
        else => unreachable,
    }
    const negate = esc < 'a'; // uppercase escape
    for (set, &s) |*dst, src| dst.* |= if (negate) ~src else src;
}

/// Make every letter match both cases (applied before class negation).
fn foldClass(set: *ClassSet) void {
    var c: u8 = 'a';
    while (c <= 'z') : (c += 1) {
        const u = c - ('a' - 'A');
        if (hasBit(set, c) or hasBit(set, u)) {
            setBit(set, c);
            setBit(set, u);
        }
    }
}

// ----------------------------------------------------------------- tests

const testing = std.testing;

fn expectFindWith(pattern: []const u8, case_insensitive: bool, haystack: []const u8, from: usize, want: ?Span) !void {
    var re = try Regex.compile(testing.allocator, pattern, case_insensitive);
    defer re.deinit(testing.allocator);
    const got: ?Span = if (re.find(haystack, from)) |m| m.span else null;
    try testing.expectEqual(want, got);
}

fn expectFind(pattern: []const u8, haystack: []const u8, from: usize, want: ?Span) !void {
    return expectFindWith(pattern, false, haystack, from, want);
}

fn expectInvalid(pattern: []const u8) !void {
    try testing.expectError(error.InvalidPattern, Regex.compile(testing.allocator, pattern, false));
}

test "literal at an offset" {
    try expectFind("bar", "foo bar baz", 0, .{ .start = 4, .end = 7 });
}

test "no match" {
    try expectFind("zap", "foo bar baz", 0, null);
    try expectFind("bar", "bar", 4, null); // from beyond the haystack
}

test "find starts at from" {
    try expectFind("bar", "bar bar", 0, .{ .start = 0, .end = 3 });
    try expectFind("bar", "bar bar", 1, .{ .start = 4, .end = 7 });
    try expectFind("bar", "bar", 3, null);
}

test "dot matches anything but newline" {
    try expectFind("a.c", "abc", 0, .{ .start = 0, .end = 3 });
    try expectFind("a.c", "a\nc", 0, null);
}

test "class members and ranges" {
    try expectFind("[abc]+", "zzcab!", 0, .{ .start = 2, .end = 5 });
    try expectFind("[a-z0-9]+", "A!x9y_", 0, .{ .start = 2, .end = 5 });
}

test "negated class" {
    try expectFind("[^0-9]+", "12ab34", 0, .{ .start = 2, .end = 4 });
}

test "class quirks: ] first, - literal" {
    try expectFind("[]a]+", "x]a]", 0, .{ .start = 1, .end = 4 });
    try expectFind("[a-]+", "b-a", 0, .{ .start = 1, .end = 3 });
    try expectFind("[-a]", "-", 0, .{ .start = 0, .end = 1 });
}

test "escapes inside a class" {
    try expectFind("[\\d_]+", "x_12y", 0, .{ .start = 1, .end = 4 });
    try expectFind("[^\\s]+", "  ab ", 0, .{ .start = 2, .end = 4 });
}

test "word, digit and space escapes" {
    try expectFind("\\w+", "foo bar", 0, .{ .start = 0, .end = 3 });
    try expectFind("\\w+", "foo bar", 3, .{ .start = 4, .end = 7 });
    try expectFind("\\d+", "abc123x", 0, .{ .start = 3, .end = 6 });
    try expectFind("\\s", "ab c", 0, .{ .start = 2, .end = 3 });
    try expectFind("\\S+", " ab ", 0, .{ .start = 1, .end = 3 });
    try expectFind("\\W", "ab-c", 0, .{ .start = 2, .end = 3 });
    try expectFind("\\D", "12x", 0, .{ .start = 2, .end = 3 });
}

test "escaped metacharacters are literal" {
    try expectFind("\\.", "ab.c", 0, .{ .start = 2, .end = 3 });
    try expectFind("\\.", "abc", 0, null);
    try expectFind("a\\+b", "a+b", 0, .{ .start = 0, .end = 3 });
    try expectFind("\\\\", "a\\b", 0, .{ .start = 1, .end = 2 });
    try expectFind("\\t", "a\tb", 0, .{ .start = 1, .end = 2 });
}

test "start and end anchors" {
    try expectFind("^foo", "foobar", 0, .{ .start = 0, .end = 3 });
    try expectFind("^foo", "xfoo", 0, null);
    try expectFind("foo$", "xfoo", 0, .{ .start = 1, .end = 4 });
    try expectFind("foo$", "foox", 0, null);
    try expectFind("$", "ab", 0, .{ .start = 2, .end = 2 });
}

test "^$ matches only an empty haystack" {
    try expectFind("^$", "", 0, .{ .start = 0, .end = 0 });
    try expectFind("^$", "x", 0, null);
}

test "word start/end anchors" {
    try expectFind("\\<foo\\>", "a foo b", 0, .{ .start = 2, .end = 5 });
    try expectFind("\\<foo\\>", "food", 0, null);
    try expectFind("\\<foo\\>", "afoo", 0, null);
    try expectFind("\\<foo", "food", 0, .{ .start = 0, .end = 3 });
}

test "word boundary" {
    try expectFind("\\bfoo\\b", "foo", 0, .{ .start = 0, .end = 3 });
    try expectFind("\\bfoo\\b", ".foo,", 0, .{ .start = 1, .end = 4 });
    try expectFind("\\bfoo\\b", "foods", 0, null);
}

test "star is greedy" {
    try expectFind("a*", "aaab", 0, .{ .start = 0, .end = 3 });
}

test "star allows an empty match (callers must step past it)" {
    try expectFind("a*", "bbb", 0, .{ .start = 0, .end = 0 });
    try expectFind("a*", "bba", 1, .{ .start = 1, .end = 1 });
}

test "plus needs at least one" {
    try expectFind("a+", "bbb", 0, null);
    try expectFind("a+", "baa", 0, .{ .start = 1, .end = 3 });
}

test "optional atom" {
    try expectFind("ab?c", "abc", 0, .{ .start = 0, .end = 3 });
    try expectFind("ab?c", "ac", 0, .{ .start = 0, .end = 2 });
    try expectFind("ab?c", "abbc", 0, null);
}

test "quantified groups" {
    try expectFind("(ab)+", "xababy", 0, .{ .start = 1, .end = 5 });
    try expectFind("(ab)*", "ababx", 0, .{ .start = 0, .end = 4 });
}

test "alternation" {
    try expectFind("cat|dog", "hotdog", 0, .{ .start = 3, .end = 6 });
    try expectFind("cat|dog", "catalog", 0, .{ .start = 0, .end = 3 });
    try expectFind("cat|dog", "bird", 0, null);
}

test "alternation binds weaker than concatenation" {
    try expectFind("ab|cd", "acd", 0, .{ .start = 1, .end = 3 });
    try expectFind("(a|b)c", "xbc", 0, .{ .start = 1, .end = 3 });
}

test "capture groups" {
    var re = try Regex.compile(testing.allocator, "(\\w+)-(\\w+)", false);
    defer re.deinit(testing.allocator);
    const m = re.find("one-two", 0).?;
    try testing.expectEqual(Span{ .start = 0, .end = 7 }, m.span);
    try testing.expectEqual(@as(?Span, .{ .start = 0, .end = 3 }), m.groups[0]);
    try testing.expectEqual(@as(?Span, .{ .start = 4, .end = 7 }), m.groups[1]);
    try testing.expectEqual(@as(?Span, null), m.groups[2]);
}

test "nested groups are numbered by open paren" {
    var re = try Regex.compile(testing.allocator, "((a)b)", false);
    defer re.deinit(testing.allocator);
    const m = re.find("ab", 0).?;
    try testing.expectEqual(@as(?Span, .{ .start = 0, .end = 2 }), m.groups[0]);
    try testing.expectEqual(@as(?Span, .{ .start = 0, .end = 1 }), m.groups[1]);
}

test "groups on the untaken branch stay null" {
    var re = try Regex.compile(testing.allocator, "(a)|(b)", false);
    defer re.deinit(testing.allocator);
    const m = re.find("b", 0).?;
    try testing.expectEqual(@as(?Span, null), m.groups[0]);
    try testing.expectEqual(@as(?Span, .{ .start = 0, .end = 1 }), m.groups[1]);
}

test "repeated group keeps its last iteration" {
    var re = try Regex.compile(testing.allocator, "(ab)+", false);
    defer re.deinit(testing.allocator);
    const m = re.find("abab", 0).?;
    try testing.expectEqual(@as(?Span, .{ .start = 2, .end = 4 }), m.groups[0]);
}

test "greedy dot-star runs to the last b" {
    try expectFind("a.*b", "aXbYb", 0, .{ .start = 0, .end = 5 });
}

test "pathological pattern finishes (no backtracking)" {
    const pattern = "a?" ** 20 ++ "a" ** 20;
    try expectFind(pattern, "a" ** 20, 0, .{ .start = 0, .end = 20 });
}

test "invalid patterns" {
    try expectInvalid("(");
    try expectInvalid("(ab");
    try expectInvalid("ab)");
    try expectInvalid("[abc");
    try expectInvalid("[");
    try expectInvalid("*a");
    try expectInvalid("a**"); // second quantifier has nothing to repeat
    try expectInvalid("a*?"); // non-greedy is unsupported
    try expectInvalid("a\\"); // trailing backslash
    try expectInvalid("\\q"); // unknown escape
    try expectInvalid("\\1"); // backreference
    try expectInvalid("a{2,3}"); // counted repeats are unsupported
    try expectInvalid("(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)"); // more than 9 groups
}

test "case-insensitive matching folds ASCII" {
    try expectFindWith("FOO", true, "xyfoo", 0, .{ .start = 2, .end = 5 });
    try expectFindWith("[a-z]+", true, "ABC", 0, .{ .start = 0, .end = 3 });
    // Folding happens before negation: [^a-z] must reject 'A' too.
    try expectFindWith("[^a-z]", true, "aA!", 0, .{ .start = 2, .end = 3 });
}

test "literal fast path" {
    var a = try Regex.compile(testing.allocator, "hello", false);
    defer a.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", a.literal().?);

    var b = try Regex.compile(testing.allocator, "hel.o", false);
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), b.literal());

    var c = try Regex.compile(testing.allocator, "a\\.b", false);
    defer c.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), c.literal());

    var d = try Regex.compile(testing.allocator, "hello", true);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), d.literal());
}

test "empty pattern matches the empty string at from" {
    try expectFind("", "abc", 1, .{ .start = 1, .end = 1 });
}

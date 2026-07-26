//! Git change signs for the gutter.
//!
//! We shell out to `git diff` (the only practical way to read repository state
//! without reimplementing packfile/zlib parsing) and turn its `-U0` hunk
//! headers into a per-line map of add/change/delete signs. It is best-effort:
//! outside a repo, or without `git`, there are simply no signs. Diffs are
//! recomputed on load and on save, never in the render or input path.

const std = @import("std");

pub const Sign = enum { added, changed, deleted };

/// Map from 0-based buffer row to its change sign.
pub const Signs = std.AutoHashMap(usize, Sign);

/// Recompute `signs` for `path` (working tree vs. index). Clears on any error.
/// Whether `path` sits inside a git work tree, decided with a few `stat`s
/// rather than by asking git. Spawning `git` costs ~1.2 ms, which is a lot to
/// pay on every open of a file that is not in a repository at all.
fn inWorkTree(io: std.Io, path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var dir: []const u8 = std.fs.path.dirname(path) orelse ".";
    var hops: usize = 0;
    while (hops < 64) : (hops += 1) {
        const probe = std.fmt.bufPrint(&buf, "{s}/.git", .{dir}) catch return true;
        // A .git *directory*, or a .git *file* (worktree or submodule).
        if (std.Io.Dir.cwd().access(io, probe, .{})) |_| return true else |_| {}
        dir = std.fs.path.dirname(dir) orelse break;
        if (dir.len == 0) break;
    }
    return false;
}

/// Run `git diff --no-color -U0 -- path` and return its stdout (caller frees).
/// Null on failure to run or a non-zero exit (not a repo / git error — normal).
fn runDiff(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "git", "diff", "--no-color", "-U0", "--", path },
        .stdout_limit = .limited(8 << 20),
        .stderr_limit = .limited(64 << 10),
    }) catch |err| {
        std.log.scoped(.git).debug("git diff failed to run: {s}", .{@errorName(err)});
        return null;
    };
    gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code == 0) return res.stdout,
        else => {},
    }
    gpa.free(res.stdout);
    return null;
}

pub fn compute(gpa: std.mem.Allocator, io: std.Io, path: []const u8, signs: *Signs) void {
    signs.clearRetainingCapacity();
    if (!inWorkTree(io, path)) return;
    const out = runDiff(gpa, io, path) orelse return;
    defer gpa.free(out);
    parse(out, signs);
}

/// Parse `git diff -U0` output, recording a sign for each affected new-file line.
fn parse(text: []const u8, signs: *Signs) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (parseHunkHeader(line)) |h| hunkSigns(h, true, signs);
    }
}

/// One side's line range from a `-U0` hunk header. `start` is 1-based; a
/// `count` of 0 marks a pure insertion/deletion point *after* line `start`
/// (0 = before the first line).
pub const Pair = struct { start: usize, count: usize };

/// One hunk: the old-side (index) and new-side (worktree) ranges it pairs.
pub const Hunk = struct { old: Pair, new: Pair };

/// `@@ -a,b +c,d @@` → the two ranges; null for any non-header line.
fn parseHunkHeader(line: []const u8) ?Hunk {
    if (!std.mem.startsWith(u8, line, "@@")) return null;
    const minus = std.mem.indexOfScalar(u8, line, '-') orelse return null;
    const plus = std.mem.indexOfScalarPos(u8, line, minus, '+') orelse return null;
    return .{ .old = parsePair(line[minus + 1 ..]), .new = parsePair(line[plus + 1 ..]) };
}

/// The diff's full hunk list (worktree vs. index), for the side-by-side
/// view's row alignment. One `git diff` feeds this and, via `signsFromHunks`,
/// the tint rows of both panes. Empty on any error (no repo, no git, no
/// changes); caller frees.
pub fn computeHunks(gpa: std.mem.Allocator, io: std.Io, path: []const u8) []Hunk {
    if (!inWorkTree(io, path)) return &.{};
    const out = runDiff(gpa, io, path) orelse return &.{};
    defer gpa.free(out);
    return parseHunks(gpa, out);
}

fn parseHunks(gpa: std.mem.Allocator, text: []const u8) []Hunk {
    var hunks: std.ArrayList(Hunk) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (parseHunkHeader(line)) |h| hunks.append(gpa, h) catch break;
    }
    return hunks.toOwnedSlice(gpa) catch {
        hunks.deinit(gpa);
        return &.{};
    };
}

/// Derive one side's sign map from a hunk list: the same rows `parse` marks
/// (`new_side`), or the index-version rows the hunks change/remove.
pub fn signsFromHunks(hunks: []const Hunk, new_side: bool, signs: *Signs) void {
    signs.clearRetainingCapacity();
    for (hunks) |h| hunkSigns(h, new_side, signs);
}

/// Record hunk `h`'s rows in `signs` for one side of the diff.
fn hunkSigns(h: Hunk, new_side: bool, signs: *Signs) void {
    if (new_side) {
        if (h.new.count == 0) {
            // Pure deletion: mark the surviving line it sits after.
            const row = if (h.new.start == 0) 0 else h.new.start - 1;
            signs.put(row, .deleted) catch {};
            return;
        }
        const sign: Sign = if (h.old.count == 0) .added else .changed;
        const base = if (h.new.start == 0) 0 else h.new.start - 1;
        var i: usize = 0;
        while (i < h.new.count) : (i += 1) signs.put(base + i, sign) catch {};
    } else {
        if (h.old.count == 0) return; // pure addition: no old-side rows
        const sign: Sign = if (h.new.count == 0) .deleted else .changed;
        const base = if (h.old.start == 0) 0 else h.old.start - 1;
        var i: usize = 0;
        while (i < h.old.count) : (i += 1) signs.put(base + i, sign) catch {};
    }
}

// === the line-diff view's data ==============================================

/// The in-buffer line-diff view's data: the hunk list plus the old
/// (deleted / changed-from) line text, both from one `git diff -U0` run —
/// the same subprocess the signs and the side-by-side alignment use.
/// `lines` holds every hunk's `-` lines in hunk order, slicing into `text`
/// (the retained diff output). The parser pads a body that runs short of
/// its header's promise with empty lines, so `lines.len == Σ old.count`
/// always holds and `above` can index without bounds checks.
pub const LineDiff = struct {
    hunks: []Hunk,
    lines: [][]const u8,
    text: []u8,

    pub fn deinit(self: *LineDiff, gpa: std.mem.Allocator) void {
        gpa.free(self.hunks);
        gpa.free(self.lines);
        gpa.free(self.text);
    }

    /// The old lines woven above buffer row `row` — anchored like the
    /// alignment: a change's old text sits above the first line that
    /// replaced it, a pure deletion's above the line the gap precedes
    /// (`row == lineCount` for a deletion at EOF). Empty when no hunk
    /// anchors there.
    pub fn above(self: *const LineDiff, row: usize) []const []const u8 {
        var off: usize = 0;
        for (self.hunks) |h| {
            const n = h.old.count;
            if (n > 0 and sideStart(h, true) == row) return self.lines[off .. off + n];
            off += n;
        }
        return &.{};
    }
};

/// The line-diff view's data for `path`, or null when there is nothing to
/// weave (no repo, no git, no changes).
pub fn computeLineDiff(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?LineDiff {
    if (!inWorkTree(io, path)) return null;
    const out = runDiff(gpa, io, path) orelse return null;
    if (parseLineDiff(gpa, out)) |ld| return ld;
    gpa.free(out);
    return null;
}

/// Parse hunk headers *and* their `-` bodies: with `-U0` each header is
/// followed by exactly `old.count` deleted lines (then the `+` lines, which
/// the buffer itself shows). On success the returned LineDiff owns `text`;
/// on null (no hunks, or OOM) it stays with the caller.
fn parseLineDiff(gpa: std.mem.Allocator, text: []u8) ?LineDiff {
    var hunks: std.ArrayList(Hunk) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    ok: {
        fillLineDiff(gpa, text, &hunks, &lines) catch break :ok;
        if (hunks.items.len == 0) break :ok;
        const hs = hunks.toOwnedSlice(gpa) catch break :ok;
        const ls = lines.toOwnedSlice(gpa) catch {
            gpa.free(hs);
            break :ok;
        };
        return .{ .hunks = hs, .lines = ls, .text = text };
    }
    hunks.deinit(gpa);
    lines.deinit(gpa);
    return null;
}

fn fillLineDiff(gpa: std.mem.Allocator, text: []const u8, hunks: *std.ArrayList(Hunk), lines: *std.ArrayList([]const u8)) !void {
    var expect: usize = 0; // `-` lines the last header still owes
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (parseHunkHeader(line)) |h| {
            try lines.appendNTimes(gpa, "", expect); // short body: keep offsets honest
            try hunks.append(gpa, h);
            expect = h.old.count;
        } else if (expect > 0) {
            if (line.len > 0 and line[0] == '-') {
                try lines.append(gpa, line[1..]);
                expect -= 1;
            } else {
                // A `+` line or `\ No newline` marker ends the `-` run.
                try lines.appendNTimes(gpa, "", expect);
                expect = 0;
            }
        }
    }
    try lines.appendNTimes(gpa, "", expect);
}

// === side-by-side row alignment =============================================
//
// The aligned display space: each hunk occupies max(old.count, new.count)
// display rows, top-aligned, so the side with fewer lines shows filler rows
// for the difference; between hunks both sides advance together. Each
// function uses only its own side's numbers, so an inconsistent header can
// never cross the sides up.

/// What one display row shows on one side of the pair.
pub const Slot = union(enum) { row: usize, filler };

// Internal: like `Slot`, but a filler also carries the first real row after it.
const Place = union(enum) { row: usize, filler: usize };

fn sideOf(h: Hunk, new_side: bool) Pair {
    return if (new_side) h.new else h.old;
}

/// The 0-based buffer row of one side's first hunk line (for a count of
/// zero: the row the insertion/deletion gap sits before). A malformed
/// "start 0 with lines" header saturates to row 0 instead of underflowing.
fn sideStart(h: Hunk, new_side: bool) usize {
    const p = sideOf(h, new_side);
    return if (p.count > 0) p.start -| 1 else p.start;
}

fn spanOf(h: Hunk) usize {
    return @max(h.old.count, h.new.count);
}

fn placeAt(hunks: []const Hunk, new_side: bool, d: usize) Place {
    var b: usize = 0; // buffer-row walker
    var dd: usize = 0; // display-row walker
    for (hunks) |h| {
        const s = sideStart(h, new_side);
        if (s < b) continue; // malformed/overlapping header: ignore it
        const count = sideOf(h, new_side).count;
        if (d < dd + (s - b)) return .{ .row = b + (d - dd) }; // before the hunk
        dd += s - b;
        b = s;
        if (d < dd + spanOf(h)) { // inside the hunk's display span
            const off = d - dd;
            return if (off < count) .{ .row = b + off } else .{ .filler = b + count };
        }
        dd += spanOf(h);
        b += count;
    }
    return .{ .row = b + (d - dd) }; // past the last hunk
}

/// The display row of buffer row `row` on one side.
pub fn displayRow(hunks: []const Hunk, new_side: bool, row: usize) usize {
    var b: usize = 0;
    var d: usize = 0;
    for (hunks) |h| {
        const s = sideStart(h, new_side);
        if (s < b) continue;
        const count = sideOf(h, new_side).count;
        if (row < s) break;
        d += s - b;
        if (row < s + count) return d + (row - s);
        d += spanOf(h);
        b = s + count;
    }
    return d + (row - b);
}

/// What display row `d` shows on one side: a buffer row, or a filler standing
/// in for lines only the other side has.
pub fn slotAt(hunks: []const Hunk, new_side: bool, d: usize) Slot {
    return switch (placeAt(hunks, new_side, d)) {
        .row => |r| .{ .row = r },
        .filler => .filler,
    };
}

/// The first buffer row at or after display row `d` — a pane top landing
/// mid-filler snaps to the next real line.
pub fn rowAtOrAfter(hunks: []const Hunk, new_side: bool, d: usize) usize {
    return switch (placeAt(hunks, new_side, d)) {
        .row => |r| r,
        .filler => |next| next,
    };
}

/// Parse a "N" or "N,M" count from the start of `s` (count defaults to 1).
fn parsePair(s: []const u8) Pair {
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    const start = std.fmt.parseInt(usize, s[0..i], 10) catch 0;
    var count: usize = 1;
    if (i < s.len and s[i] == ',') {
        var j = i + 1;
        while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
        count = std.fmt.parseInt(usize, s[i + 1 .. j], 10) catch 1;
    }
    return .{ .start = start, .count = count };
}

test "parseHunks keeps every hunk pair, including pure additions" {
    const diff =
        \\diff --git a/f b/f
        \\@@ -1,0 +2,2 @@
        \\@@ -5,2 +7,1 @@
        \\@@ -10,1 +11,0 @@
        \\
    ;
    const hunks = parseHunks(std.testing.allocator, diff);
    defer std.testing.allocator.free(hunks);
    try std.testing.expectEqual(@as(usize, 3), hunks.len);
    // The pure-addition hunk (no old-side rows) must survive the parse: it is
    // exactly where the side-by-side view needs index-pane filler rows.
    try std.testing.expectEqual(Hunk{ .old = .{ .start = 1, .count = 0 }, .new = .{ .start = 2, .count = 2 } }, hunks[0]);
    try std.testing.expectEqual(Hunk{ .old = .{ .start = 5, .count = 2 }, .new = .{ .start = 7, .count = 1 } }, hunks[1]);
    try std.testing.expectEqual(Hunk{ .old = .{ .start = 10, .count = 1 }, .new = .{ .start = 11, .count = 0 } }, hunks[2]);
}

test "signsFromHunks marks changed and removed index rows (old side)" {
    var signs = Signs.init(std.testing.allocator);
    defer signs.deinit();
    const hunks = [_]Hunk{
        .{ .old = .{ .start = 1, .count = 0 }, .new = .{ .start = 2, .count = 2 } },
        .{ .old = .{ .start = 5, .count = 2 }, .new = .{ .start = 7, .count = 1 } },
        .{ .old = .{ .start = 10, .count = 1 }, .new = .{ .start = 11, .count = 0 } },
    };
    signsFromHunks(&hunks, false, &signs);
    try std.testing.expect(signs.get(0) == null); // pure addition: nothing
    try std.testing.expectEqual(Sign.changed, signs.get(4).?); // old line 5
    try std.testing.expectEqual(Sign.changed, signs.get(5).?); // old line 6
    try std.testing.expectEqual(Sign.deleted, signs.get(9).?); // old line 10
}

test "signsFromHunks matches parse on the new side" {
    const diff =
        \\@@ -1,0 +2,2 @@
        \\@@ -5,2 +7,1 @@
        \\@@ -10,1 +11,0 @@
        \\
    ;
    var parsed = Signs.init(std.testing.allocator);
    defer parsed.deinit();
    parse(diff, &parsed);
    const hunks = parseHunks(std.testing.allocator, diff);
    defer std.testing.allocator.free(hunks);
    var derived = Signs.init(std.testing.allocator);
    defer derived.deinit();
    signsFromHunks(hunks, true, &derived);
    try std.testing.expectEqual(parsed.count(), derived.count());
    var it = parsed.iterator();
    while (it.next()) |e| try std.testing.expectEqual(e.value_ptr.*, derived.get(e.key_ptr.*).?);
}

// old:  one two   three           four five six
// new:  one TWO-C three add1 add2 four      six
// Aligned display rows (· = filler):
//   d0 one|one  d1 TWO-C|two  d2 three|three  d3 add1|·  d4 add2|·
//   d5 four|four  d6 ·|five  d7 six|six
const align_hunks = [_]Hunk{
    .{ .old = .{ .start = 2, .count = 1 }, .new = .{ .start = 2, .count = 1 } }, // change
    .{ .old = .{ .start = 3, .count = 0 }, .new = .{ .start = 4, .count = 2 } }, // pure addition
    .{ .old = .{ .start = 5, .count = 1 }, .new = .{ .start = 6, .count = 0 } }, // pure deletion
};

test "displayRow aligns matching lines across the panes" {
    const h = &align_hunks;
    // Both sides agree on the display row of every common line.
    try std.testing.expectEqual(@as(usize, 0), displayRow(h, true, 0)); // one
    try std.testing.expectEqual(@as(usize, 0), displayRow(h, false, 0));
    try std.testing.expectEqual(@as(usize, 2), displayRow(h, true, 2)); // three
    try std.testing.expectEqual(@as(usize, 2), displayRow(h, false, 2));
    try std.testing.expectEqual(@as(usize, 5), displayRow(h, true, 5)); // four
    try std.testing.expectEqual(@as(usize, 5), displayRow(h, false, 3));
    try std.testing.expectEqual(@as(usize, 7), displayRow(h, true, 6)); // six
    try std.testing.expectEqual(@as(usize, 7), displayRow(h, false, 5));
    // Lines only one side has.
    try std.testing.expectEqual(@as(usize, 3), displayRow(h, true, 3)); // add1
    try std.testing.expectEqual(@as(usize, 6), displayRow(h, false, 4)); // five
}

test "slotAt places fillers where the other side has extra lines" {
    const h = &align_hunks;
    // Index pane: fillers under the added lines.
    try std.testing.expectEqual(Slot.filler, slotAt(h, false, 3));
    try std.testing.expectEqual(Slot.filler, slotAt(h, false, 4));
    try std.testing.expectEqual(Slot{ .row = 3 }, slotAt(h, false, 5)); // four
    // Worktree pane: a filler where the deleted line was.
    try std.testing.expectEqual(Slot.filler, slotAt(h, true, 6));
    try std.testing.expectEqual(Slot{ .row = 6 }, slotAt(h, true, 7)); // six
    try std.testing.expectEqual(Slot{ .row = 4 }, slotAt(h, true, 4)); // add2
    // Past the last hunk both sides advance together.
    try std.testing.expectEqual(Slot{ .row = 7 }, slotAt(h, true, 8));
    try std.testing.expectEqual(Slot{ .row = 6 }, slotAt(h, false, 8));
}

test "malformed hunk headers stay inert" {
    // start 0 with a nonzero count never comes from real git; it must neither
    // underflow nor misalign the rows that follow.
    const bad = [_]Hunk{
        .{ .old = .{ .start = 0, .count = 3 }, .new = .{ .start = 0, .count = 3 } },
        .{ .old = .{ .start = 2, .count = 1 }, .new = .{ .start = 2, .count = 1 } }, // overlaps: skipped
        .{ .old = .{ .start = 9, .count = 1 }, .new = .{ .start = 9, .count = 2 } },
    };
    try std.testing.expectEqual(Slot{ .row = 0 }, slotAt(&bad, true, 0));
    try std.testing.expectEqual(@as(usize, 4), displayRow(&bad, false, 4));
    try std.testing.expectEqual(Slot.filler, slotAt(&bad, false, 9)); // real hunk still aligns
    try std.testing.expectEqual(@as(usize, 9), rowAtOrAfter(&bad, false, 9));
}

test "a deletion before line 1 puts its old rows above buffer row 0" {
    // `: > f` on a committed 5-line file: `@@ -1,5 +0,0 @@` — new-side start 0,
    // count 0. The whole hunk sits *above* the new side's buffer row 0 in
    // display space. This geometry is the contract editor.zig's paneDisplayTop
    // anchors on (a buffer-row viewport top of 0 alone can never reach it).
    const h = [_]Hunk{.{ .old = .{ .start = 1, .count = 5 }, .new = .{ .start = 0, .count = 0 } }};
    try std.testing.expectEqual(@as(usize, 5), displayRow(&h, true, 0)); // row 0 sits below the gap
    try std.testing.expectEqual(@as(usize, 0), displayRow(&h, false, 0));
    var d: usize = 0;
    while (d < 5) : (d += 1) {
        try std.testing.expectEqual(Slot.filler, slotAt(&h, true, d));
        try std.testing.expectEqual(Slot{ .row = d }, slotAt(&h, false, d));
    }
    try std.testing.expectEqual(Slot{ .row = 0 }, slotAt(&h, true, 5));
}

test "rowAtOrAfter snaps a mid-filler top to the next real line" {
    const h = &align_hunks;
    try std.testing.expectEqual(@as(usize, 3), rowAtOrAfter(h, false, 3)); // filler → four
    try std.testing.expectEqual(@as(usize, 6), rowAtOrAfter(h, true, 6)); // filler → six
    try std.testing.expectEqual(@as(usize, 2), rowAtOrAfter(h, true, 2)); // a real row is itself
    try std.testing.expectEqual(@as(usize, 0), rowAtOrAfter(h, false, 0));
}

test "parseLineDiff keeps each hunk's old-line text at its anchor" {
    const diff =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -2,1 +2,1 @@
        \\-two
        \\+TWO
        \\@@ -4,2 +3,0 @@
        \\-four
        \\-five
        \\@@ -7,0 +5,1 @@
        \\+added
        \\
    ;
    const text = try std.testing.allocator.dupe(u8, diff);
    var ld = parseLineDiff(std.testing.allocator, text) orelse {
        std.testing.allocator.free(text);
        return error.TestUnexpectedResult;
    };
    defer ld.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), ld.hunks.len);
    // Change: the old text weaves above the line that replaced it (row 1).
    const chg = ld.above(1);
    try std.testing.expectEqual(@as(usize, 1), chg.len);
    try std.testing.expectEqualStrings("two", chg[0]);
    // Pure deletion `@@ -4,2 +3,0 @@`: the gap sits after new line 3, so the
    // old lines weave above 0-based row 3.
    const del = ld.above(3);
    try std.testing.expectEqual(@as(usize, 2), del.len);
    try std.testing.expectEqualStrings("four", del[0]);
    try std.testing.expectEqualStrings("five", del[1]);
    // A pure addition has no old lines; unrelated rows weave nothing.
    try std.testing.expectEqual(@as(usize, 0), ld.above(4).len);
    try std.testing.expectEqual(@as(usize, 0), ld.above(0).len);
}

test "parseLineDiff: a total deletion anchors every old line above row 0" {
    const text = try std.testing.allocator.dupe(u8, "@@ -1,3 +0,0 @@\n-a\n-b\n-c\n");
    var ld = parseLineDiff(std.testing.allocator, text) orelse {
        std.testing.allocator.free(text);
        return error.TestUnexpectedResult;
    };
    defer ld.deinit(std.testing.allocator);
    const block = ld.above(0);
    try std.testing.expectEqual(@as(usize, 3), block.len);
    try std.testing.expectEqualStrings("a", block[0]);
    try std.testing.expectEqualStrings("c", block[2]);
}

test "parseLineDiff pads a short body instead of slipping later hunks" {
    // The first header promises two `-` lines but delivers one (truncated or
    // hostile output): the missing line pads empty so the second hunk's text
    // still lands at its own anchor.
    const text = try std.testing.allocator.dupe(u8, "@@ -1,2 +1,1 @@\n-only\n@@ -5,1 +4,1 @@\n-real\n+REAL\n");
    var ld = parseLineDiff(std.testing.allocator, text) orelse {
        std.testing.allocator.free(text);
        return error.TestUnexpectedResult;
    };
    defer ld.deinit(std.testing.allocator);
    const first = ld.above(0);
    try std.testing.expectEqual(@as(usize, 2), first.len);
    try std.testing.expectEqualStrings("only", first[0]);
    try std.testing.expectEqualStrings("", first[1]);
    const second = ld.above(3);
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqualStrings("real", second[0]);
}

test "parseLineDiff returns null when there are no hunks" {
    const text = try std.testing.allocator.dupe(u8, "diff --git a/f b/f\n");
    defer std.testing.allocator.free(text);
    try std.testing.expect(parseLineDiff(std.testing.allocator, text) == null);
}

test "parse hunk headers into signs" {
    var signs = Signs.init(std.testing.allocator);
    defer signs.deinit();
    const diff =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,0 +2,2 @@
        \\+added one
        \\+added two
        \\@@ -5,2 +7,1 @@
        \\-old
        \\-old two
        \\+changed
        \\@@ -10,1 +11,0 @@
        \\-deleted
        \\
    ;
    parse(diff, &signs);
    try std.testing.expectEqual(Sign.added, signs.get(1).?); // line 2
    try std.testing.expectEqual(Sign.added, signs.get(2).?); // line 3
    try std.testing.expectEqual(Sign.changed, signs.get(6).?); // line 7
    try std.testing.expectEqual(Sign.deleted, signs.get(10).?); // after line 11
    try std.testing.expect(signs.get(0) == null);
}

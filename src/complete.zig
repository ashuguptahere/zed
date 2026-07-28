//! Buffer-word completion candidates — vim's keyword completion.
//!
//! When no language server answers (none installed for the filetype, or it
//! returned an empty list), the completion popup is filled from the identifiers
//! already present in the open buffers. This module holds the harvesting: pure
//! text in, a deduplicated candidate list out, so it can be unit-tested without
//! a buffer, a terminal or a server.
//!
//! Storage follows the picker's house style: one byte arena addressed by
//! `u32` offsets, cleared and reused between requests rather than freed. The
//! words are *copied* into it — a candidate must outlive the buffer edits that
//! happen while the popup is open (inserting a character re-materialises the
//! line, invalidating any slice into it), and re-harvesting per keystroke
//! would put the scan back on the typing path it was kept off.

const std = @import("std");

/// Shortest word worth offering: two characters are rarely worth a popup and
/// float noise to the top of the list.
pub const min_len: usize = 3;

/// A candidate list. `reset` keeps the capacity for the next request.
pub const Words = struct {
    const Span = struct { off: u32, len: u32 };

    text: std.ArrayList(u8) = .empty, // the words' bytes, back to back
    spans: std.ArrayList(Span) = .empty,

    pub fn deinit(self: *Words, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        self.spans.deinit(gpa);
    }

    pub fn reset(self: *Words) void {
        self.text.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
    }

    pub fn count(self: *const Words) usize {
        return self.spans.items.len;
    }

    pub fn get(self: *const Words, i: usize) []const u8 {
        const s = self.spans.items[i];
        return self.text.items[s.off..][0..s.len];
    }

    fn has(self: *const Words, w: []const u8) bool {
        for (self.spans.items) |s| {
            if (s.len != w.len) continue;
            if (std.mem.eql(u8, self.text.items[s.off..][0..s.len], w)) return true;
        }
        return false;
    }

    /// Harvest the identifiers in `line`: a word starts with a letter or `_`,
    /// continues with letters, digits, `_` (and non-ASCII bytes, so a UTF-8
    /// identifier stays whole), and must be at least `min_len` long. `skip` —
    /// the word being typed at the cursor — is never a candidate for itself,
    /// and duplicates keep their first occurrence: the caller feeds lines
    /// outward from the cursor, so that is the closest one.
    ///
    /// Only the first `budget` bytes of `line` start a word (one already under
    /// way is finished, so candidates are never truncated) — the caller counts
    /// the budget down across lines. That bound is the load-bearing one: `cap`
    /// limits how many candidates are *kept*, but dedup costs a scan of them
    /// per word *examined*, so a file whose vocabulary never reaches the cap
    /// would otherwise scan every line at O(cap) each — measured at 82 ms a
    /// harvest, a visible stall on the very typing pause this runs in.
    ///
    /// Returns true once `cap` candidates are held: the caller's signal that
    /// there is nothing left to look for.
    pub fn addLine(self: *Words, gpa: std.mem.Allocator, line: []const u8, skip: []const u8, cap: usize, budget: usize) bool {
        if (self.spans.items.len >= cap) return true;
        var i: usize = 0;
        while (i < line.len and i < budget) {
            if (!isCont(line[i])) {
                i += 1;
                continue;
            }
            const start = i;
            while (i < line.len and isCont(line[i])) i += 1;
            const w = line[start..i];
            // A run that does not begin an identifier (`3abc`, `über`) is
            // skipped whole rather than restarted inside.
            if (!isStart(w[0]) or w.len < min_len) continue;
            if (std.mem.eql(u8, w, skip) or self.has(w)) continue;
            const off = self.text.items.len;
            self.text.appendSlice(gpa, w) catch return true;
            self.spans.append(gpa, .{ .off = @intCast(off), .len = @intCast(w.len) }) catch return true;
            if (self.spans.items.len >= cap) return true;
        }
        return false;
    }
};

fn isStart(c: u8) bool {
    return c == '_' or std.ascii.isAlphabetic(c);
}

fn isCont(c: u8) bool {
    return isStart(c) or std.ascii.isDigit(c) or c >= 0x80;
}

// --- tests -----------------------------------------------------------------

const t = std.testing;

/// Harvest every line of `text` (the editor feeds one buffer line at a time,
/// counting one byte budget down across them — see `harvestBuf`).
fn harvestBudget(w: *Words, text: []const u8, skip: []const u8, cap: usize, budget: usize) void {
    var left = budget;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (w.addLine(t.allocator, line, skip, cap, left)) return;
        if (line.len >= left) return;
        left -= line.len;
    }
}

fn harvest(w: *Words, text: []const u8, skip: []const u8, cap: usize) void {
    harvestBudget(w, text, skip, cap, std.math.maxInt(usize));
}

test "harvests identifiers, skipping punctuation and numbers" {
    var w: Words = .{};
    defer w.deinit(t.allocator);
    harvest(&w, "const value = other_thing(42);\n_priv = idx9;\n", "", 100);
    try t.expectEqual(@as(usize, 5), w.count());
    try t.expectEqualStrings("const", w.get(0));
    try t.expectEqualStrings("value", w.get(1));
    try t.expectEqualStrings("other_thing", w.get(2));
    try t.expectEqualStrings("_priv", w.get(3));
    try t.expectEqualStrings("idx9", w.get(4));
}

test "min length filters short words" {
    var w: Words = .{};
    defer w.deinit(t.allocator);
    harvest(&w, "a bc def ghij\n", "", 100);
    try t.expectEqual(@as(usize, 2), w.count());
    try t.expectEqualStrings("def", w.get(0));
    try t.expectEqualStrings("ghij", w.get(1));
}

test "a run that does not start an identifier is skipped whole" {
    var w: Words = .{};
    defer w.deinit(t.allocator);
    harvest(&w, "3abcd 0x7fff value\n", "", 100);
    try t.expectEqual(@as(usize, 1), w.count());
    try t.expectEqualStrings("value", w.get(0));
}

test "duplicates keep the first occurrence" {
    var w: Words = .{};
    defer w.deinit(t.allocator);
    harvest(&w, "alpha beta\nbeta alpha gamma\n", "", 100);
    try t.expectEqual(@as(usize, 3), w.count());
    try t.expectEqualStrings("alpha", w.get(0));
    try t.expectEqualStrings("beta", w.get(1));
    try t.expectEqualStrings("gamma", w.get(2));
}

test "the word being typed is not offered as its own completion" {
    var w: Words = .{};
    defer w.deinit(t.allocator);
    harvest(&w, "ret\nreturn_value ret\n", "ret", 100);
    try t.expectEqual(@as(usize, 1), w.count());
    try t.expectEqualStrings("return_value", w.get(0));
}

test "the cap stops the scan, mid-line included" {
    var w: Words = .{};
    defer w.deinit(t.allocator);
    const no_budget = std.math.maxInt(usize);
    // One line with more words than the cap: the scan must stop inside it.
    try t.expect(w.addLine(t.allocator, "aaa bbb ccc ddd eee fff", "", 4, no_budget));
    try t.expectEqual(@as(usize, 4), w.count());
    // And a full list refuses further lines without scanning them.
    try t.expect(w.addLine(t.allocator, "ggg hhh", "", 4, no_budget));
    try t.expectEqual(@as(usize, 4), w.count());
}

test "the byte budget stops a scan the cap never would" {
    var w: Words = .{};
    defer w.deinit(t.allocator);
    // Four bytes of budget: only the first word starts inside it. Without the
    // budget the cap (100) never bites and every line is scanned — the shape
    // that measured 82 ms a harvest on a low-vocabulary file.
    harvestBudget(&w, "alpha beta\ngamma delta\n", "", 100, 4);
    try t.expectEqual(@as(usize, 1), w.count());
    try t.expectEqualStrings("alpha", w.get(0)); // finished, not truncated at 4
}

test "the budget is spent across lines, not renewed per line" {
    var w: Words = .{};
    defer w.deinit(t.allocator);
    // "alpha" leaves 4 of the 9 bytes, so the next line yields its first word
    // and stops — a per-line budget would have taken "delta" too.
    harvestBudget(&w, "alpha\ngamma delta\n", "", 100, 9);
    try t.expectEqual(@as(usize, 2), w.count());
    try t.expectEqualStrings("alpha", w.get(0));
    try t.expectEqualStrings("gamma", w.get(1));
}

test "reset keeps capacity and empties the list" {
    var w: Words = .{};
    defer w.deinit(t.allocator);
    harvest(&w, "alpha beta gamma\n", "", 100);
    const cap = w.text.capacity;
    w.reset();
    try t.expectEqual(@as(usize, 0), w.count());
    try t.expectEqual(cap, w.text.capacity);
}

test "non-ASCII identifiers stay whole" {
    var w: Words = .{};
    defer w.deinit(t.allocator);
    harvest(&w, "caf\u{00e9}_count = 1\n", "", 100);
    try t.expectEqual(@as(usize, 1), w.count());
    try t.expectEqualStrings("caf\u{00e9}_count", w.get(0));
}

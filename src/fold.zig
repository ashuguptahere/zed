//! Folds: ranges of lines collapsed to a single row.
//!
//! The set lives per document and the rules are pure, so which rows are hidden
//! — and where the cursor may land — is unit-testable without a screen. The
//! renderer asks `closedAt`, motions ask `nextVisible`/`prevVisible`, and edits
//! call `shift` so a fold keeps covering the same text when lines move.
//!
//! Nesting is allowed: `closedAt` returns the *outermost* closed fold covering
//! a row, because that is the one whose header is on screen. Folds are kept
//! sorted by start (then by widest first), which makes that lookup a scan in
//! document order rather than a search.
//!
//! Deliberately absent: `foldlevel`/`foldmethod` as settings, fold columns,
//! and persistence — a fold is a thing you make while reading, and vim loses
//! them on close too unless `:mkview` is used.

const std = @import("std");

pub const Fold = struct {
    start: usize, // 0-based first row — the header, always visible
    end: usize, // 0-based last row, inclusive
    closed: bool = true, // `zf` makes a closed fold, as vim does

    fn covers(self: Fold, row: usize) bool {
        return row >= self.start and row <= self.end;
    }
};

pub const Set = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Fold) = .empty,

    pub fn deinit(self: *Set) void {
        self.items.deinit(self.gpa);
    }

    pub fn clear(self: *Set) void {
        self.items.clearRetainingCapacity();
    }

    pub fn len(self: *const Set) usize {
        return self.items.items.len;
    }

    /// Create a closed fold over `start..end`. A single line cannot be folded
    /// (there would be nothing to hide), and an existing fold over exactly the
    /// same range is reused rather than duplicated.
    pub fn add(self: *Set, start: usize, end: usize) void {
        const a = @min(start, end);
        const b = @max(start, end);
        if (b <= a) return;
        for (self.items.items) |*f| {
            if (f.start == a and f.end == b) {
                f.closed = true;
                return;
            }
        }
        var at: usize = 0;
        while (at < self.items.items.len) : (at += 1) {
            const f = self.items.items[at];
            if (f.start > a or (f.start == a and f.end < b)) break; // widest first
        }
        self.items.insert(self.gpa, at, .{ .start = a, .end = b }) catch {};
    }

    /// The outermost closed fold covering `row` — the one whose header is what
    /// the screen actually shows.
    pub fn closedAt(self: *const Set, row: usize) ?Fold {
        for (self.items.items) |f| {
            if (f.closed and f.covers(row)) return f;
        }
        return null;
    }

    /// The first visible row at or after `row` (`last` is the final row of the
    /// buffer, so a fold running to the end cannot walk past it).
    pub fn nextVisible(self: *const Set, row: usize, last: usize) usize {
        var r = row;
        while (r < last) {
            const f = self.closedAt(r) orelse break;
            if (r == f.start) break;
            r = f.end + 1;
        }
        return @min(r, last);
    }

    /// The last visible row at or before `row`: a closed fold resolves to its
    /// header, which is where the cursor belongs.
    pub fn prevVisible(self: *const Set, row: usize) usize {
        var r = row;
        while (true) {
            const f = self.closedAt(r) orelse return r;
            if (r == f.start) return r;
            r = f.start;
        }
    }

    /// Open or close the outermost fold covering `row`. True when one was
    /// there to act on.
    pub fn setClosed(self: *Set, row: usize, closed: bool) bool {
        // Closing looks at every fold; opening only at closed ones, so `zo`
        // inside a nested pair opens the outer first — vim's behaviour.
        if (closed) {
            var best: ?*Fold = null;
            for (self.items.items) |*f| {
                if (!f.covers(row)) continue;
                if (best == null or f.end - f.start < best.?.end - best.?.start) best = f;
            }
            const f = best orelse return false;
            f.closed = true;
            return true;
        }
        for (self.items.items) |*f| {
            if (f.closed and f.covers(row)) {
                f.closed = false;
                return true;
            }
        }
        return false;
    }

    pub fn toggle(self: *Set, row: usize) bool {
        const open_it = self.closedAt(row) != null;
        return self.setClosed(row, !open_it);
    }

    pub fn setAll(self: *Set, closed: bool) void {
        for (self.items.items) |*f| f.closed = closed;
    }

    /// Delete the innermost fold covering `row`. True when one went.
    pub fn removeAt(self: *Set, row: usize) bool {
        var best: ?usize = null;
        for (self.items.items, 0..) |f, i| {
            if (!f.covers(row)) continue;
            if (best == null or f.end - f.start < self.items.items[best.?].end - self.items.items[best.?].start)
                best = i;
        }
        const i = best orelse return false;
        _ = self.items.orderedRemove(i);
        return true;
    }

    /// Lines were inserted (`delta > 0`) or removed (`delta < 0`) at row `at`.
    /// Folds after the edit move with the text; one the edit landed inside
    /// grows or shrinks; one the edit swallowed entirely is dropped, since the
    /// text it covered is gone.
    pub fn shift(self: *Set, at: usize, delta: i64) void {
        if (delta == 0) return;
        var i: usize = 0;
        while (i < self.items.items.len) {
            const f = &self.items.items[i];
            if (f.start >= at) {
                const ns = @as(i64, @intCast(f.start)) + delta;
                const ne = @as(i64, @intCast(f.end)) + delta;
                if (ne <= @as(i64, @intCast(at))) { // swallowed by a deletion
                    _ = self.items.orderedRemove(i);
                    continue;
                }
                f.start = @intCast(@max(@as(i64, @intCast(at)), ns));
                f.end = @intCast(@max(@as(i64, @intCast(at)), ne));
            } else if (f.end >= at) {
                const ne = @as(i64, @intCast(f.end)) + delta;
                if (ne <= @as(i64, @intCast(f.start))) { // nothing left to hide
                    _ = self.items.orderedRemove(i);
                    continue;
                }
                f.end = @intCast(ne);
            }
            i += 1;
        }
    }
};

const testing = std.testing;

fn oneFold(gpa: std.mem.Allocator) Set {
    var s = Set{ .gpa = gpa };
    s.add(2, 5);
    return s;
}

test "a closed fold hides everything but its header" {
    var s = oneFold(testing.allocator);
    defer s.deinit();
    try testing.expect(s.closedAt(1) == null);
    try testing.expectEqual(@as(usize, 2), s.closedAt(2).?.start); // its own header
    try testing.expectEqual(@as(usize, 2), s.closedAt(3).?.start); // swallowed
    try testing.expectEqual(@as(usize, 2), s.closedAt(5).?.start);
    try testing.expect(s.closedAt(6) == null);
}

test "a single line cannot be folded" {
    var s = Set{ .gpa = testing.allocator };
    defer s.deinit();
    s.add(3, 3);
    try testing.expectEqual(@as(usize, 0), s.len());
}

test "an open fold hides nothing" {
    var s = oneFold(testing.allocator);
    defer s.deinit();
    try testing.expect(s.setClosed(3, false));
    try testing.expect(s.closedAt(3) == null);
    try testing.expect(s.closedAt(3) == null);
}

test "toggling flips it both ways" {
    var s = oneFold(testing.allocator);
    defer s.deinit();
    try testing.expect(s.toggle(4)); // closed -> open
    try testing.expect(s.closedAt(4) == null);
    try testing.expect(s.toggle(4)); // open -> closed
    try testing.expect(s.closedAt(4) != null);
}

test "nextVisible skips a closed fold's body" {
    var s = oneFold(testing.allocator);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 2), s.nextVisible(2, 20));
    try testing.expectEqual(@as(usize, 6), s.nextVisible(3, 20));
    try testing.expectEqual(@as(usize, 6), s.nextVisible(5, 20));
}

test "prevVisible resolves to the header" {
    var s = oneFold(testing.allocator);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 2), s.prevVisible(4));
    try testing.expectEqual(@as(usize, 1), s.prevVisible(1));
}

test "a fold running to the end never walks past the last row" {
    var s = Set{ .gpa = testing.allocator };
    defer s.deinit();
    s.add(4, 9);
    try testing.expectEqual(@as(usize, 9), s.nextVisible(5, 9));
}

test "nested folds resolve to the outermost closed one" {
    var s = Set{ .gpa = testing.allocator };
    defer s.deinit();
    s.add(1, 10); // outer
    s.add(3, 5); // inner
    // Both closed: the outer is what the screen shows.
    try testing.expectEqual(@as(usize, 1), s.closedAt(4).?.start);
    // Open the outer and the inner still hides its own body.
    try testing.expect(s.setClosed(4, false));
    try testing.expectEqual(@as(usize, 3), s.closedAt(4).?.start);
    try testing.expectEqual(@as(usize, 3), s.closedAt(4).?.start); // swallowed by the inner
    try testing.expect(s.closedAt(2) == null); // outside it
}

test "zR and zM act on every fold" {
    var s = Set{ .gpa = testing.allocator };
    defer s.deinit();
    s.add(1, 3);
    s.add(6, 9);
    s.setAll(false);
    try testing.expect(s.closedAt(2) == null and s.closedAt(7) == null);
    s.setAll(true);
    try testing.expect(s.closedAt(2) != null and s.closedAt(7) != null);
}

test "deleting a fold removes the innermost one" {
    var s = Set{ .gpa = testing.allocator };
    defer s.deinit();
    s.add(1, 10);
    s.add(3, 5);
    try testing.expect(s.removeAt(4));
    try testing.expectEqual(@as(usize, 1), s.len());
    try testing.expectEqual(@as(usize, 1), s.items.items[0].start); // the outer survived
    try testing.expect(!s.removeAt(20)); // nothing there
}

test "inserting lines above a fold moves it down" {
    var s = oneFold(testing.allocator); // 2..5
    defer s.deinit();
    s.shift(0, 3);
    try testing.expectEqual(@as(usize, 5), s.items.items[0].start);
    try testing.expectEqual(@as(usize, 8), s.items.items[0].end);
}

test "inserting inside a fold grows it" {
    var s = oneFold(testing.allocator); // 2..5
    defer s.deinit();
    s.shift(4, 2);
    try testing.expectEqual(@as(usize, 2), s.items.items[0].start);
    try testing.expectEqual(@as(usize, 7), s.items.items[0].end);
}

test "deleting the lines a fold covered drops it" {
    var s = oneFold(testing.allocator); // 2..5
    defer s.deinit();
    s.shift(2, -4);
    try testing.expectEqual(@as(usize, 0), s.len());
}

test "an edit below a fold leaves it alone" {
    var s = oneFold(testing.allocator); // 2..5
    defer s.deinit();
    s.shift(9, 5);
    try testing.expectEqual(@as(usize, 2), s.items.items[0].start);
    try testing.expectEqual(@as(usize, 5), s.items.items[0].end);
}

test "adding the same range twice does not duplicate it" {
    var s = oneFold(testing.allocator);
    defer s.deinit();
    _ = s.setClosed(3, false);
    s.add(2, 5); // re-folding the same range closes the one already there
    try testing.expectEqual(@as(usize, 1), s.len());
    try testing.expect(s.closedAt(3) != null);
}

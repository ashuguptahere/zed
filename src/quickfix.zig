//! The quickfix list: a set of file positions you work through one at a time.
//!
//! zedit already *finds* things — the grep picker, LSP references, the
//! diagnostics list — but a picker is transient: choose one result and the
//! rest are gone. The quickfix list is the other half, the one vim has and
//! this did not: the results stay, and `]q`/`[q` walk them without going back
//! to the picker each time.
//!
//! Pure and allocation-owning, so the stepping rules (wrapping, counts, an
//! empty list) are unit-testable away from the editor. Entries are owned
//! copies: they outlive the picker that produced them, and the buffers they
//! point at may not even be open.

const std = @import("std");

pub const Entry = struct {
    path: []u8, // owned
    line: usize, // 1-based, as every user-facing line number here is
    col: usize, // 0-based byte column
    text: []u8, // owned; the matched line, for the list view
};

pub const List = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Which entry `]q` steps from. Kept in range by every mutator.
    idx: usize = 0,
    /// What filled the list, for the window's title ("grep: foo", "references").
    title: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *List) void {
        self.clear();
        self.entries.deinit(self.gpa);
        self.title.deinit(self.gpa);
    }

    pub fn clear(self: *List) void {
        for (self.entries.items) |e| {
            self.gpa.free(e.path);
            self.gpa.free(e.text);
        }
        self.entries.clearRetainingCapacity();
        self.idx = 0;
    }

    pub fn setTitle(self: *List, what: []const u8) void {
        self.title.clearRetainingCapacity();
        self.title.appendSlice(self.gpa, what) catch {};
    }

    pub fn len(self: *const List) usize {
        return self.entries.items.len;
    }

    pub fn add(self: *List, path: []const u8, line: usize, col: usize, text: []const u8) void {
        const p = self.gpa.dupe(u8, path) catch return;
        const t = self.gpa.dupe(u8, text) catch {
            self.gpa.free(p);
            return;
        };
        self.entries.append(self.gpa, .{ .path = p, .line = @max(1, line), .col = col, .text = t }) catch {
            self.gpa.free(p);
            self.gpa.free(t);
        };
    }

    pub fn at(self: *const List, i: usize) ?Entry {
        if (i >= self.entries.items.len) return null;
        return self.entries.items[i];
    }

    pub fn current(self: *const List) ?Entry {
        return self.at(self.idx);
    }

    /// Move `count` entries and return where that lands. Wraps in both
    /// directions, as vim's `:cnext` does not — vim errors at the end — but
    /// `]q` in every modern config does, and wrapping is what makes walking a
    /// list of two feel right.
    pub fn step(self: *List, forward: bool, count: usize) ?Entry {
        const n = self.entries.items.len;
        if (n == 0) return null;
        const c = @mod(@max(1, count), n);
        self.idx = if (forward) @mod(self.idx + c, n) else @mod(self.idx + n - c, n);
        return self.current();
    }

    /// Jump straight to an entry (`:cc 3`, or a click in the list window).
    pub fn goTo(self: *List, i: usize) ?Entry {
        if (i >= self.entries.items.len) return null;
        self.idx = i;
        return self.current();
    }
};

const testing = std.testing;

fn threeEntries(gpa: std.mem.Allocator) List {
    var l = List{ .gpa = gpa };
    l.add("/a.zig", 10, 0, "first");
    l.add("/b.zig", 20, 4, "second");
    l.add("/c.zig", 30, 2, "third");
    return l;
}

test "entries keep their own copies of the path and text" {
    var l = List{ .gpa = testing.allocator };
    defer l.deinit();
    var path = [_]u8{ '/', 'x' };
    l.add(&path, 5, 1, "hit");
    path[1] = 'y'; // the caller's buffer changes under us
    try testing.expectEqualStrings("/x", l.current().?.path);
    try testing.expectEqual(@as(usize, 5), l.current().?.line);
}

test "stepping forward and back walks the list" {
    var l = threeEntries(testing.allocator);
    defer l.deinit();
    try testing.expectEqualStrings("second", l.step(true, 1).?.text);
    try testing.expectEqualStrings("third", l.step(true, 1).?.text);
    try testing.expectEqualStrings("second", l.step(false, 1).?.text);
}

test "stepping wraps at both ends" {
    var l = threeEntries(testing.allocator);
    defer l.deinit();
    // Back from the first entry lands on the last, and forward from there
    // comes round to the first again.
    try testing.expectEqualStrings("third", l.step(false, 1).?.text);
    try testing.expectEqualStrings("third", l.current().?.text);
    try testing.expectEqualStrings("first", l.step(true, 1).?.text);
}

test "a count larger than the list still lands somewhere sensible" {
    var l = threeEntries(testing.allocator);
    defer l.deinit();
    try testing.expectEqualStrings("first", l.step(true, 3).?.text); // a full lap
    try testing.expectEqualStrings("second", l.step(true, 7).?.text); // 7 mod 3 = 1
}

test "an empty list steps nowhere rather than trapping" {
    var l = List{ .gpa = testing.allocator };
    defer l.deinit();
    try testing.expect(l.step(true, 1) == null);
    try testing.expect(l.step(false, 4) == null);
    try testing.expect(l.current() == null);
    try testing.expectEqual(@as(usize, 0), l.len());
}

test "a line number of zero is clamped to one" {
    var l = List{ .gpa = testing.allocator };
    defer l.deinit();
    l.add("/a", 0, 0, "x"); // a 0-based caller slipping through
    try testing.expectEqual(@as(usize, 1), l.current().?.line);
}

test "goTo picks an entry and refuses one past the end" {
    var l = threeEntries(testing.allocator);
    defer l.deinit();
    try testing.expectEqualStrings("third", l.goTo(2).?.text);
    try testing.expect(l.goTo(3) == null);
    try testing.expectEqualStrings("third", l.current().?.text); // unchanged by the refusal
}

test "clearing frees the entries and resets the cursor" {
    var l = threeEntries(testing.allocator);
    defer l.deinit();
    _ = l.step(true, 2);
    l.clear();
    try testing.expectEqual(@as(usize, 0), l.len());
    try testing.expectEqual(@as(usize, 0), l.idx);
    l.add("/new", 1, 0, "again"); // reusable after a clear
    try testing.expectEqualStrings("again", l.current().?.text);
}

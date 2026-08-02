//! Toast notifications: the short-lived messages that belong in the corner of
//! the screen rather than on the statusline.
//!
//! The statusline holds *one* message and holds it until something replaces
//! it, which is right for "Ln 5, Col 3" and wrong for "copied to clipboard" —
//! a thing that happened, is worth seeing, and should then get out of the way.
//! AstroNvim has exactly this (nvim-notify, stacked in the top right); this is
//! the same idea sized for a terminal editor with no plugin manager.
//!
//! Pure and allocation-free: a fixed ring of fixed-width slots, so a queue
//! costs nothing at rest and the expiry rules are unit-testable away from a
//! screen. The editor owns the drawing and the clock.
//!
//! Expiry is the interesting constraint. zedit blocks in `poll(2)` when idle
//! and arms a timer only while typing, so a toast must not turn the editor
//! into something that wakes up several times a second. `nextDeadline` gives
//! the main loop a single point in time to wake for — one wakeup per toast,
//! not one per frame — and when nothing is showing there is no deadline and
//! the loop goes back to blocking for ever.

const std = @import("std");

/// The four levels `std.log` already has, in the same order and with the same
/// names — a notification and a log line describe the same event, and having
/// two different vocabularies for it would mean translating between them at
/// every call site. `err` is the "critical" end.
pub const Level = enum {
    debug,
    info,
    warn,
    err,

    /// The glyph that leads the line. Plain Unicode symbols rather than
    /// nerd-font icons: a toast has to read on a terminal without one, like
    /// the rest of zedit's fallbacks. Each is distinct at a glance, and the
    /// renderer measures the width rather than assuming one cell, so a
    /// terminal that draws any of them wide still lines the box up.
    pub fn mark(self: Level) []const u8 {
        return switch (self) {
            .debug => "\u{2699}", // ⚙ gear — machinery, not a user-facing event
            .info => "\u{2713}", // ✓ something finished
            .warn => "\u{26a0}", // ⚠ went on, but look at it
            .err => "\u{2717}", // ✗ did not happen
        };
    }
};

/// How long a toast stays up. Long enough to read a short line, short enough
/// that it is gone before it becomes furniture.
pub const default_ttl_ms: i64 = 3000;

/// Longest message kept. A toast is a glance; anything longer belongs in the
/// statusline or the log, and truncating here is what keeps the queue
/// allocation-free.
pub const max_text = 96;

pub const Toast = struct {
    buf: [max_text]u8 = undefined,
    len: usize = 0,
    level: Level = .info,
    until_ms: i64 = 0,

    pub fn text(self: *const Toast) []const u8 {
        return self.buf[0..self.len];
    }
};

/// At most this many on screen at once. Older ones are dropped rather than
/// queued behind: a stack of stale toasts is worse than missing one.
pub const capacity = 3;

pub const Queue = struct {
    items: [capacity]Toast = @splat(.{}),
    n: usize = 0,

    /// Add a toast, newest last. Text longer than `max_text` is truncated on a
    /// UTF-8 boundary, so a multibyte message can never be cut mid-codepoint
    /// and render as a replacement character.
    pub fn push(self: *Queue, level: Level, text: []const u8, now_ms: i64, ttl_ms: i64) void {
        if (self.n == capacity) {
            // Drop the oldest to make room.
            std.mem.copyForwards(Toast, self.items[0 .. capacity - 1], self.items[1..capacity]);
            self.n -= 1;
        }
        var t = Toast{ .level = level, .until_ms = now_ms + ttl_ms };
        const take = truncLen(text, max_text);
        @memcpy(t.buf[0..take], text[0..take]);
        t.len = take;
        self.items[self.n] = t;
        self.n += 1;
    }

    /// Drop everything whose time is up. True when the queue changed, which is
    /// the editor's signal that a frame is needed to erase them.
    pub fn expire(self: *Queue, now_ms: i64) bool {
        var out: usize = 0;
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (self.items[i].until_ms > now_ms) {
                if (out != i) self.items[out] = self.items[i];
                out += 1;
            }
        }
        const changed = out != self.n;
        self.n = out;
        return changed;
    }

    /// When the next toast expires, for the main loop's poll timeout. Null
    /// when nothing is showing — which is what lets an idle editor block for
    /// ever instead of waking to check.
    pub fn nextDeadline(self: *const Queue) ?i64 {
        var best: ?i64 = null;
        for (self.items[0..self.n]) |t| {
            if (best == null or t.until_ms < best.?) best = t.until_ms;
        }
        return best;
    }

    pub fn visible(self: *const Queue) []const Toast {
        return self.items[0..self.n];
    }
};

/// The longest prefix of `text` that is at most `limit` bytes and does not cut
/// a UTF-8 sequence in half.
fn truncLen(text: []const u8, limit: usize) usize {
    if (text.len <= limit) return text.len;
    var i = limit;
    while (i > 0 and (text[i] & 0xc0) == 0x80) i -= 1; // step off continuation bytes
    return i;
}

const testing = std.testing;

test "a toast is shown until its time is up" {
    var q = Queue{};
    q.push(.info, "copied to clipboard", 1000, 3000);
    try testing.expectEqual(@as(usize, 1), q.visible().len);
    try testing.expect(!q.expire(3999));
    try testing.expectEqual(@as(usize, 1), q.visible().len);
    try testing.expect(q.expire(4000)); // 1000 + 3000
    try testing.expectEqual(@as(usize, 0), q.visible().len);
}

test "expire reports whether anything actually went" {
    // The return value is the editor's redraw signal, so a call that drops
    // nothing must not claim a change — that would repaint on every poll.
    var q = Queue{};
    try testing.expect(!q.expire(5000)); // empty
    q.push(.info, "a", 0, 100);
    try testing.expect(!q.expire(50));
    try testing.expect(q.expire(200));
    try testing.expect(!q.expire(300)); // and not again
}

test "only the expired ones go" {
    var q = Queue{};
    q.push(.info, "first", 0, 100);
    q.push(.err, "second", 0, 5000);
    try testing.expect(q.expire(200));
    try testing.expectEqual(@as(usize, 1), q.visible().len);
    try testing.expectEqualStrings("second", q.visible()[0].text());
}

test "a full queue drops the oldest, not the newest" {
    var q = Queue{};
    for ([_][]const u8{ "one", "two", "three", "four" }, 0..) |t, i| q.push(.info, t, @intCast(i), 9999);
    try testing.expectEqual(@as(usize, capacity), q.visible().len);
    try testing.expectEqualStrings("two", q.visible()[0].text());
    try testing.expectEqualStrings("four", q.visible()[capacity - 1].text());
}

test "no deadline when nothing is showing" {
    var q = Queue{};
    try testing.expect(q.nextDeadline() == null); // the idle editor blocks for ever
    q.push(.info, "x", 100, 500);
    q.push(.info, "y", 100, 200);
    try testing.expectEqual(@as(i64, 300), q.nextDeadline().?); // the soonest
    _ = q.expire(400);
    try testing.expectEqual(@as(i64, 600), q.nextDeadline().?);
    _ = q.expire(700);
    try testing.expect(q.nextDeadline() == null);
}

test "a long message is cut on a codepoint boundary" {
    var q = Queue{};
    var long: [max_text + 10]u8 = undefined;
    // Fill with a 3-byte codepoint so a naive cut would land mid-sequence.
    var i: usize = 0;
    while (i + 3 <= long.len) : (i += 3) @memcpy(long[i..][0..3], "\u{4e2d}");
    q.push(.info, long[0..i], 0, 100);
    const got = q.visible()[0].text();
    try testing.expect(got.len <= max_text);
    try testing.expect(std.unicode.utf8ValidateSlice(got));
}

test "an exactly-fitting message is not truncated" {
    var q = Queue{};
    const exact = "x" ** max_text;
    q.push(.warn, exact, 0, 100);
    try testing.expectEqual(@as(usize, max_text), q.visible()[0].text().len);
    try testing.expectEqual(Level.warn, q.visible()[0].level);
}

test "the levels line up with std.log's, name for name" {
    // Not decoration: a call site that logs and notifies the same event must
    // not have to translate between two vocabularies.
    const log_names = comptime blk: {
        var out: [4][]const u8 = undefined;
        for (@typeInfo(std.log.Level).@"enum".fields, 0..) |f, i| out[i] = f.name;
        break :blk out;
    };
    const our_names = comptime blk: {
        var out: [4][]const u8 = undefined;
        for (@typeInfo(Level).@"enum".fields, 0..) |f, i| out[i] = f.name;
        break :blk out;
    };
    // std.log orders them err..debug and we order them debug..err, so compare
    // as sets: every std.log level has a notification level of the same name.
    for (log_names) |want| {
        var found = false;
        for (our_names) |got| found = found or std.mem.eql(u8, want, got);
        try testing.expect(found);
    }
    try testing.expectEqual(@as(usize, 4), our_names.len);
}

test "every level has its own mark" {
    var seen: [4][]const u8 = undefined;
    for ([_]Level{ .debug, .info, .warn, .err }, 0..) |l, i| {
        seen[i] = l.mark();
        try testing.expect(l.mark().len > 0);
        var j: usize = 0;
        while (j < i) : (j += 1) try testing.expect(!std.mem.eql(u8, seen[j], seen[i]));
    }
}

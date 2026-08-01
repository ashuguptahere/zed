//! Chrome geometry: where the editor's furniture goes, and what a box looks
//! like.
//!
//! The renderer had this arithmetic spread across every popup — the which-key
//! menu computed its own corner, the notification stack computed another, the
//! picker a third — which is how two of them ended up with different ideas of
//! what "the bottom right" means. The rules are the same everywhere, so they
//! live here: a rectangle, the ways of placing one against the screen, and the
//! inset a border costs.
//!
//! Pure. No emitting, no editor state, no theme — the caller draws, this only
//! says where. That is what makes it unit-testable, and it is also the line
//! that keeps `editor.zig` owning the frame buffer.
//!
//! Everything is **1-based**, like the terminal's own coordinates, so a `Rect`
//! can be handed straight to a cursor-position escape without adjustment.

const std = @import("std");

pub const Rect = struct {
    x: usize, // leftmost column, 1-based
    y: usize, // topmost row, 1-based
    w: usize,
    h: usize,

    pub fn right(self: Rect) usize {
        return self.x + self.w - 1;
    }

    pub fn bottom(self: Rect) usize {
        return self.y + self.h - 1;
    }

    pub fn contains(self: Rect, row: usize, col: usize) bool {
        return row >= self.y and row <= self.bottom() and col >= self.x and col <= self.right();
    }

    /// The area inside a single-cell border. A rectangle too small to have an
    /// inside comes back empty rather than underflowing.
    pub fn inner(self: Rect) Rect {
        if (self.w < 3 or self.h < 3) return .{ .x = self.x, .y = self.y, .w = 0, .h = 0 };
        return .{ .x = self.x + 1, .y = self.y + 1, .w = self.w - 2, .h = self.h - 2 };
    }
};

/// The screen a rectangle is placed against: the whole terminal, minus the
/// rows that already belong to something else.
pub const Screen = struct {
    rows: usize,
    cols: usize,
    /// Rows reserved at the top (the title bar) and bottom (the statusline or
    /// command line). A popup never covers those.
    top_reserved: usize = 0,
    bottom_reserved: usize = 0,
    /// Columns reserved at the left/right — the file tree, on whichever side
    /// it is docked. A floating picker centres over the *text*, not over the
    /// tree: covering the tree hides the thing a `zedit <dir>` session is
    /// there to browse.
    left_reserved: usize = 0,
    right_reserved: usize = 0,

    pub fn usableTop(self: Screen) usize {
        return 1 + self.top_reserved;
    }

    pub fn usableRows(self: Screen) usize {
        return self.rows -| (self.top_reserved + self.bottom_reserved);
    }

    pub fn usableLeft(self: Screen) usize {
        return 1 + self.left_reserved;
    }

    pub fn usableCols(self: Screen) usize {
        return self.cols -| (self.left_reserved + self.right_reserved);
    }
};

/// Centre a box of at most `want_w` x `want_h`, shrinking it to fit and
/// leaving at least `margin` columns either side so it reads as floating over
/// the text rather than replacing it. Null when the screen cannot hold a
/// usable box at all — the caller then falls back to drawing full-width,
/// which is what a 40-column terminal wants anyway.
pub fn centered(s: Screen, want_w: usize, want_h: usize, margin: usize) ?Rect {
    const avail_w = s.usableCols() -| (margin * 2);
    const avail_h = s.usableRows();
    if (avail_w < 20 or avail_h < 5) return null;
    const w = @min(want_w, avail_w);
    const h = @min(want_h, avail_h);
    return .{
        .x = s.usableLeft() + (s.usableCols() - w) / 2,
        .y = s.usableTop() + (avail_h - h) / 2,
        .w = w,
        .h = h,
    };
}

/// A box against the right edge, `h` rows tall, starting at the first usable
/// row (`from_top`) or ending at the last (`!from_top`). This is the shape the
/// notification stack and the which-key menu share; they differ only in which
/// end of the screen they hang from.
pub fn rightEdge(s: Screen, w: usize, h: usize, from_top: bool) ?Rect {
    if (w == 0 or h == 0 or s.cols < w or s.usableRows() < h) return null;
    return .{
        .x = s.cols - w + 1,
        .y = if (from_top) s.usableTop() else s.usableTop() + s.usableRows() - h,
        .w = w,
        .h = h,
    };
}

/// Box-drawing glyphs. One set: rounded corners, which read as a floating
/// window rather than a table, and are plain Unicode so no nerd font is
/// needed (the same bar the notification marks clear).
pub const border = struct {
    pub const top_left = "\u{256d}"; // ╭
    pub const top_right = "\u{256e}"; // ╮
    pub const bottom_left = "\u{2570}"; // ╰
    pub const bottom_right = "\u{256f}"; // ╯
    pub const horizontal = "\u{2500}"; // ─
    pub const vertical = "\u{2502}"; // │
};

const testing = std.testing;

test "a centred box is centred, and leaves the reserved rows alone" {
    const s = Screen{ .rows = 24, .cols = 80, .top_reserved = 1, .bottom_reserved = 1 };
    const r = centered(s, 60, 16, 4).?;
    try testing.expectEqual(@as(usize, 60), r.w);
    try testing.expectEqual(@as(usize, 16), r.h);
    try testing.expectEqual(@as(usize, 11), r.x); // (80-60)/2 + 1
    try testing.expect(r.y >= 2); // never over the title bar
    try testing.expect(r.bottom() <= 23); // never over the statusline
}

test "a box too big for the screen shrinks instead of overflowing" {
    const s = Screen{ .rows = 24, .cols = 80, .top_reserved = 1, .bottom_reserved = 1 };
    const r = centered(s, 200, 200, 4).?;
    try testing.expectEqual(@as(usize, 72), r.w); // 80 - 2*4
    try testing.expectEqual(@as(usize, 22), r.h); // 24 - 1 - 1
    try testing.expectEqual(@as(usize, 2), r.y);
    try testing.expect(r.right() <= 80);
}

test "a screen too small for a floating box says so" {
    // The caller then draws full-width; a 3-row popup with a border has no
    // inside at all.
    const tiny = Screen{ .rows = 4, .cols = 80, .top_reserved = 1, .bottom_reserved = 1 };
    try testing.expect(centered(tiny, 40, 10, 4) == null);
    const narrow = Screen{ .rows = 24, .cols = 24, .top_reserved = 1, .bottom_reserved = 1 };
    try testing.expect(centered(narrow, 40, 10, 4) == null);
}

test "the inside of a box is the border inset" {
    const r = Rect{ .x = 10, .y = 3, .w = 20, .h = 8 };
    const in = r.inner();
    try testing.expectEqual(@as(usize, 11), in.x);
    try testing.expectEqual(@as(usize, 4), in.y);
    try testing.expectEqual(@as(usize, 18), in.w);
    try testing.expectEqual(@as(usize, 6), in.h);
}

test "a box with no room inside comes back empty rather than underflowing" {
    for ([_]Rect{
        .{ .x = 1, .y = 1, .w = 2, .h = 9 },
        .{ .x = 1, .y = 1, .w = 9, .h = 2 },
        .{ .x = 1, .y = 1, .w = 0, .h = 0 },
    }) |r| {
        try testing.expectEqual(@as(usize, 0), r.inner().w);
        try testing.expectEqual(@as(usize, 0), r.inner().h);
    }
}

test "contains is inclusive of the border cells" {
    const r = Rect{ .x = 5, .y = 5, .w = 3, .h = 3 };
    try testing.expect(r.contains(5, 5)); // top-left corner
    try testing.expect(r.contains(7, 7)); // bottom-right corner
    try testing.expect(!r.contains(4, 5));
    try testing.expect(!r.contains(5, 8));
    try testing.expect(!r.contains(8, 5));
}

test "the right edge hangs from either end" {
    const s = Screen{ .rows = 24, .cols = 80, .top_reserved = 1, .bottom_reserved = 1 };
    const top = rightEdge(s, 30, 3, true).?;
    try testing.expectEqual(@as(usize, 51), top.x); // 80 - 30 + 1
    try testing.expectEqual(@as(usize, 2), top.y); // under the title bar
    const bot = rightEdge(s, 30, 3, false).?;
    try testing.expectEqual(@as(usize, 51), bot.x);
    try testing.expectEqual(@as(usize, 21), bot.y); // 2 + 22 - 3
    try testing.expectEqual(@as(usize, 23), bot.bottom()); // above the statusline
}

test "an edge box that cannot fit is refused, not clipped" {
    const s = Screen{ .rows = 24, .cols = 80, .top_reserved = 1, .bottom_reserved = 1 };
    try testing.expect(rightEdge(s, 100, 3, true) == null);
    try testing.expect(rightEdge(s, 30, 40, true) == null);
    try testing.expect(rightEdge(s, 0, 3, true) == null);
}

test "a centred box never covers the file tree" {
    // A `zedit <dir>` session is a tree beside a picker; a box centred over
    // the whole terminal would sit on top of the tree it is meant to sit next
    // to.
    const s = Screen{ .rows = 24, .cols = 110, .top_reserved = 1, .bottom_reserved = 1, .left_reserved = 30 };
    const r = centered(s, 200, 200, 4).?;
    try testing.expect(r.x > 30);
    try testing.expectEqual(@as(usize, 72), r.w); // 110 - 30 - 2*4
    try testing.expect(r.right() <= 110);
}

test "a right-docked tree is kept clear too" {
    const s = Screen{ .rows = 24, .cols = 110, .top_reserved = 1, .bottom_reserved = 1, .right_reserved = 30 };
    const r = centered(s, 200, 200, 4).?;
    try testing.expect(r.right() <= 80);
}

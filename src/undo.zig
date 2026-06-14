//! Undo/redo as buffer snapshots.
//!
//! A snapshot is the serialised buffer (via `toBytes`) plus the cursor. This is
//! simpler and obviously-correct compared to a change-journal, and the cost is
//! paid only when editing (never in the render path). Depth is capped so a long
//! session can't grow without bound. Restoring re-parses the bytes, which also
//! recovers the trailing-newline state.

const std = @import("std");
const buffer = @import("buffer.zig");
const Allocator = std.mem.Allocator;

const Snapshot = struct {
    data: []u8,
    cy: usize,
    cx: usize,
};

pub const History = struct {
    gpa: Allocator,
    undos: std.ArrayList(Snapshot),
    redos: std.ArrayList(Snapshot),
    max_depth: usize,

    pub fn init(gpa: Allocator) History {
        return .{ .gpa = gpa, .undos = .empty, .redos = .empty, .max_depth = 256 };
    }

    pub fn deinit(self: *History) void {
        self.freeAll(&self.undos);
        self.freeAll(&self.redos);
    }

    fn freeAll(self: *History, list: *std.ArrayList(Snapshot)) void {
        for (list.items) |snap| self.gpa.free(snap.data);
        list.deinit(self.gpa);
    }

    fn capture(self: *History, buf: *const buffer.Buffer, cy: usize, cx: usize) !Snapshot {
        return .{ .data = try buf.toBytes(self.gpa), .cy = cy, .cx = cx };
    }

    /// Record the state *before* a change, discarding any redo history.
    /// Best-effort: a failed snapshot simply isn't recorded.
    pub fn record(self: *History, buf: *const buffer.Buffer, cy: usize, cx: usize) void {
        const snap = self.capture(buf, cy, cx) catch return;
        self.undos.append(self.gpa, snap) catch {
            self.gpa.free(snap.data);
            return;
        };
        if (self.undos.items.len > self.max_depth) {
            const removed = self.undos.orderedRemove(0);
            self.gpa.free(removed.data);
        }
        self.freeAll(&self.redos);
        self.redos = .empty;
    }

    /// Step back one change. Returns false if there is nothing to undo.
    pub fn undo(self: *History, buf: *buffer.Buffer, cy: *usize, cx: *usize) bool {
        return self.step(&self.undos, &self.redos, buf, cy, cx);
    }

    /// Re-apply one undone change. Returns false if there is nothing to redo.
    pub fn redo(self: *History, buf: *buffer.Buffer, cy: *usize, cx: *usize) bool {
        return self.step(&self.redos, &self.undos, buf, cy, cx);
    }

    fn step(
        self: *History,
        from: *std.ArrayList(Snapshot),
        to: *std.ArrayList(Snapshot),
        buf: *buffer.Buffer,
        cy: *usize,
        cx: *usize,
    ) bool {
        if (from.items.len == 0) return false;
        const current = self.capture(buf, cy.*, cx.*) catch return false;
        to.append(self.gpa, current) catch {
            self.gpa.free(current.data);
            return false;
        };
        const snap = from.pop().?;
        buf.replaceContents(snap.data) catch {
            self.gpa.free(snap.data);
            return false;
        };
        cy.* = snap.cy;
        cx.* = snap.cx;
        buf.dirty = true;
        self.gpa.free(snap.data);
        return true;
    }
};

test "undo and redo round trip" {
    const gpa = std.testing.allocator;
    var buf = try buffer.Buffer.fromBytes(gpa, "one\n");
    defer buf.deinit();
    var h = History.init(gpa);
    defer h.deinit();

    var cy: usize = 0;
    var cx: usize = 0;

    h.record(&buf, 0, 0); // before change
    _ = try buf.insertCodepoint(0, 0, 'X'); // "Xone"
    try std.testing.expectEqualStrings("Xone", buf.line(0));

    try std.testing.expect(h.undo(&buf, &cy, &cx));
    try std.testing.expectEqualStrings("one", buf.line(0));

    try std.testing.expect(h.redo(&buf, &cy, &cx));
    try std.testing.expectEqualStrings("Xone", buf.line(0));

    try std.testing.expect(!h.redo(&buf, &cy, &cx)); // nothing more
}

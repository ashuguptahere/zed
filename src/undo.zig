//! Undo history as a *tree* of buffer snapshots.
//!
//! A node is the serialised buffer (via `toBytes`) plus the cursor and the
//! moment it was made. Undo walks to a node's parent, redo back down the branch
//! it came from — and, unlike a linear history, editing after an undo starts a
//! new branch instead of throwing the old one away. `g-`/`g+` and
//! `:earlier`/`:later` walk every state in the order it was created, which is
//! how work stranded on an abandoned branch is reached again.
//!
//! Snapshots rather than a change-journal: obviously correct, costs nothing in
//! the render path, and makes jumping to an arbitrary node in the tree a
//! `replaceContents` instead of a replay. Restoring re-parses the bytes, which
//! also recovers the trailing-newline state.
//!
//! Nodes live in one array and refer to each other by index, so nothing
//! dangles when it grows; freed slots are reused.

const std = @import("std");
const buffer = @import("buffer.zig");
const log = @import("log.zig");
const Allocator = std.mem.Allocator;

const Node = struct {
    data: []u8, // the whole buffer at this state
    cy: usize,
    cx: usize,
    parent: ?u32,
    /// The child undo came from, so redo returns the way it went.
    last_child: ?u32,
    children: u32, // how many children point here (pruning needs it)
    seq: u32, // creation order: what `g-`/`g+` and `:earlier` count in
    time_ms: i64,
    alive: bool,
};

/// One row of `:undolist`.
pub const Entry = struct {
    seq: u32,
    time_ms: i64,
    current: bool,
    branch: bool, // its parent has more than one child: an alternative history
};

/// Monotonic milliseconds — the same clock the profiler uses, so history
/// timestamps cannot jump when the wall clock is adjusted.
fn nowMs() i64 {
    return @intCast(@divTrunc(log.nowNanos(), std.time.ns_per_ms));
}

pub const History = struct {
    gpa: Allocator,
    nodes: std.ArrayList(Node),
    cur: ?u32,
    /// The buffer has been edited since we arrived at `cur`, so the state it
    /// now holds still needs a node of its own. Sealing is deferred to the next
    /// transition because that is the first moment the new state is complete.
    dirty: bool,
    next_seq: u32,
    max_nodes: usize,

    pub fn init(gpa: Allocator) History {
        return .{ .gpa = gpa, .nodes = .empty, .cur = null, .dirty = false, .next_seq = 0, .max_nodes = 256 };
    }

    pub fn deinit(self: *History) void {
        for (self.nodes.items) |n| if (n.alive) self.gpa.free(n.data);
        self.nodes.deinit(self.gpa);
    }

    /// A change is about to happen: give the state it replaces a node of its
    /// own (if it has not got one yet) and note that the buffer is moving on.
    pub fn record(self: *History, buf: *const buffer.Buffer, cy: usize, cx: usize) void {
        self.seal(buf, cy, cx);
        self.dirty = true;
    }

    /// Add the live buffer to the tree as a child of `cur`. A no-op when
    /// nothing has changed since we got here — including when a "change" left
    /// the text exactly as it was, which should not cost an undo step.
    fn seal(self: *History, buf: *const buffer.Buffer, cy: usize, cx: usize) void {
        if (self.cur != null and !self.dirty) return;
        const data = buf.toBytes(self.gpa) catch return;
        if (self.cur) |c| {
            if (std.mem.eql(u8, self.nodes.items[c].data, data)) {
                self.gpa.free(data);
                self.dirty = false;
                return;
            }
        }
        const idx = self.alloc(.{
            .data = data,
            .cy = cy,
            .cx = cx,
            .parent = self.cur,
            .last_child = null,
            .children = 0,
            .seq = self.next_seq,
            .time_ms = nowMs(),
            .alive = true,
        }) catch {
            self.gpa.free(data);
            return;
        };
        self.next_seq += 1;
        if (self.cur) |c| {
            self.nodes.items[c].last_child = idx;
            self.nodes.items[c].children += 1;
        }
        self.cur = idx;
        self.dirty = false;
        self.prune();
    }

    fn alloc(self: *History, n: Node) !u32 {
        for (self.nodes.items, 0..) |slot, i| {
            if (!slot.alive) {
                self.nodes.items[i] = n;
                return @intCast(i);
            }
        }
        try self.nodes.append(self.gpa, n);
        return @intCast(self.nodes.items.len - 1);
    }

    fn liveCount(self: *const History) usize {
        var n: usize = 0;
        for (self.nodes.items) |s| {
            if (s.alive) n += 1;
        }
        return n;
    }

    /// Keep the tree bounded. A linear history loses its oldest state, the
    /// child taking its place as root; where the root has branched, the oldest
    /// dead-end goes instead, so the trunk outlives the side branches.
    fn prune(self: *History) void {
        while (self.liveCount() > self.max_nodes) {
            if (self.dropRoot()) continue;
            if (self.dropOldestLeaf()) continue;
            return; // nothing may go: everything left is on the current path
        }
    }

    fn dropRoot(self: *History) bool {
        const root = self.rootIndex() orelse return false;
        if (self.cur == root or self.nodes.items[root].children != 1) return false;
        for (self.nodes.items) |*n| {
            if (n.alive and n.parent == root) {
                n.parent = null;
                break;
            }
        }
        self.free(root);
        return true;
    }

    fn dropOldestLeaf(self: *History) bool {
        var best: ?u32 = null;
        for (self.nodes.items, 0..) |n, i| {
            if (!n.alive or n.children != 0 or self.cur == @as(u32, @intCast(i))) continue;
            if (best == null or n.seq < self.nodes.items[best.?].seq) best = @intCast(i);
        }
        const leaf = best orelse return false;
        if (self.nodes.items[leaf].parent) |p| {
            self.nodes.items[p].children -= 1;
            if (self.nodes.items[p].last_child == leaf) self.nodes.items[p].last_child = null;
        }
        self.free(leaf);
        return true;
    }

    fn rootIndex(self: *const History) ?u32 {
        for (self.nodes.items, 0..) |n, i| if (n.alive and n.parent == null) return @intCast(i);
        return null;
    }

    fn free(self: *History, idx: u32) void {
        self.gpa.free(self.nodes.items[idx].data);
        self.nodes.items[idx].alive = false;
    }

    fn goTo(self: *History, target: u32, buf: *buffer.Buffer, cy: *usize, cx: *usize) bool {
        const n = self.nodes.items[target];
        buf.replaceContents(n.data) catch return false;
        cy.* = n.cy;
        cx.* = n.cx;
        buf.dirty = true;
        self.cur = target;
        self.dirty = false;
        return true;
    }

    /// Step back one change. False when there is nothing older.
    pub fn undo(self: *History, buf: *buffer.Buffer, cy: *usize, cx: *usize) bool {
        if (self.cur == null and !self.dirty) return false;
        self.seal(buf, cy.*, cx.*);
        const c = self.cur orelse return false;
        const parent = self.nodes.items[c].parent orelse return false;
        self.nodes.items[parent].last_child = c; // redo comes back this way
        return self.goTo(parent, buf, cy, cx);
    }

    /// Re-apply one undone change, down the branch undo came from.
    pub fn redo(self: *History, buf: *buffer.Buffer, cy: *usize, cx: *usize) bool {
        const c = self.cur orelse return false;
        if (self.dirty) return false; // a new change replaced what redo would do
        const child = self.nodes.items[c].last_child orelse return false;
        if (!self.nodes.items[child].alive) return false;
        return self.goTo(child, buf, cy, cx);
    }

    /// `g-` / `g+`, `:earlier N` / `:later N`: walk states in the order they
    /// were made, whatever branch they are on. Returns how many steps it
    /// managed — 0 means there was nowhere to go.
    pub fn travel(self: *History, buf: *buffer.Buffer, cy: *usize, cx: *usize, count: usize, back: bool) usize {
        if (self.cur == null and !self.dirty) return 0;
        self.seal(buf, cy.*, cx.*);
        var moved: usize = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const from = self.nodes.items[self.cur.?].seq;
            const target = (if (back) self.prevSeq(from) else self.nextSeq(from)) orelse break;
            if (!self.goTo(target, buf, cy, cx)) break;
            moved += 1;
        }
        return moved;
    }

    /// `:earlier 10s` / `:later 2m`: the nearest state at least `ms`
    /// milliseconds older (or newer) than the current one — and, when nothing
    /// reaches that far, the oldest (or newest) state there is. vim clamps
    /// rather than refusing, so `:earlier 1h` means "back to the beginning"
    /// (nvim-verified through a pty).
    pub fn travelTime(self: *History, buf: *buffer.Buffer, cy: *usize, cx: *usize, ms: i64, back: bool) bool {
        if (self.cur == null and !self.dirty) return false;
        self.seal(buf, cy.*, cx.*);
        const from = self.nodes.items[self.cur.?].time_ms;
        const limit = if (back) from - ms else from + ms;
        var best: ?u32 = null;
        for (self.nodes.items, 0..) |n, i| {
            if (!n.alive) continue;
            const reachable = if (back) n.time_ms <= limit else n.time_ms >= limit;
            if (!reachable) continue;
            // The closest such state: the newest going back, the oldest forward.
            if (best) |b| {
                const better = if (back) n.time_ms > self.nodes.items[b].time_ms else n.time_ms < self.nodes.items[b].time_ms;
                if (!better) continue;
            }
            best = @intCast(i);
        }
        const target = best orelse self.endMost(back) orelse return false;
        if (target == self.cur.?) return false;
        return self.goTo(target, buf, cy, cx);
    }

    /// The oldest (or newest) state in the tree.
    fn endMost(self: *const History, oldest: bool) ?u32 {
        var best: ?u32 = null;
        for (self.nodes.items, 0..) |n, i| {
            if (!n.alive) continue;
            if (best) |b| {
                const better = if (oldest) n.seq < self.nodes.items[b].seq else n.seq > self.nodes.items[b].seq;
                if (!better) continue;
            }
            best = @intCast(i);
        }
        return best;
    }

    fn prevSeq(self: *const History, from: u32) ?u32 {
        var best: ?u32 = null;
        for (self.nodes.items, 0..) |n, i| {
            if (!n.alive or n.seq >= from) continue;
            if (best == null or n.seq > self.nodes.items[best.?].seq) best = @intCast(i);
        }
        return best;
    }

    fn nextSeq(self: *const History, from: u32) ?u32 {
        var best: ?u32 = null;
        for (self.nodes.items, 0..) |n, i| {
            if (!n.alive or n.seq <= from) continue;
            if (best == null or n.seq < self.nodes.items[best.?].seq) best = @intCast(i);
        }
        return best;
    }

    /// Every state, oldest first — `:undolist`. Seals first, so the listing
    /// includes the state the buffer is in right now: without that, the change
    /// you have just made is missing from the list, and the branch it created
    /// does not look like one yet.
    pub fn list(self: *History, buf: *const buffer.Buffer, cy: usize, cx: usize, out: *std.ArrayList(Entry)) !void {
        self.seal(buf, cy, cx);
        out.clearRetainingCapacity();
        for (self.nodes.items, 0..) |n, i| {
            if (!n.alive) continue;
            const siblings = if (n.parent) |p| self.nodes.items[p].children else 1;
            try out.append(self.gpa, .{
                .seq = n.seq,
                .time_ms = n.time_ms,
                .current = self.cur == @as(u32, @intCast(i)),
                .branch = siblings > 1,
            });
        }
        std.mem.sort(Entry, out.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return a.seq < b.seq;
            }
        }.less);
    }

    /// Jump straight to a state by its sequence number (the `:undolist` picker).
    pub fn goToSeq(self: *History, buf: *buffer.Buffer, cy: *usize, cx: *usize, seq: u32) bool {
        self.seal(buf, cy.*, cx.*);
        for (self.nodes.items, 0..) |n, i| {
            if (n.alive and n.seq == seq) return self.goTo(@intCast(i), buf, cy, cx);
        }
        return false;
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

test "a change after an undo branches instead of discarding" {
    const gpa = std.testing.allocator;
    var buf = try buffer.Buffer.fromBytes(gpa, "one\n");
    defer buf.deinit();
    var h = History.init(gpa);
    defer h.deinit();
    var cy: usize = 0;
    var cx: usize = 0;

    h.record(&buf, 0, 0);
    _ = try buf.insertCodepoint(0, 0, 'A'); // "Aone" (seq 1)
    try std.testing.expect(h.undo(&buf, &cy, &cx));
    try std.testing.expectEqualStrings("one", buf.line(0));

    h.record(&buf, 0, 0);
    _ = try buf.insertCodepoint(0, 0, 'B'); // "Bone" (seq 2, a second branch)
    try std.testing.expect(h.undo(&buf, &cy, &cx));
    try std.testing.expectEqualStrings("one", buf.line(0));

    // Redo follows the branch just taken...
    try std.testing.expect(h.redo(&buf, &cy, &cx));
    try std.testing.expectEqualStrings("Bone", buf.line(0));

    // ...and the abandoned one is still reachable, because `g-` walks states
    // in the order they were made rather than along the branch: Bone(2) ->
    // Aone(1) -> one(0). Verified against headless nvim with the same keys
    // (IA<Esc> u IB<Esc> g- g- g+).
    try std.testing.expectEqual(@as(usize, 1), h.travel(&buf, &cy, &cx, 1, true));
    try std.testing.expectEqualStrings("Aone", buf.line(0));
    try std.testing.expectEqual(@as(usize, 1), h.travel(&buf, &cy, &cx, 1, true));
    try std.testing.expectEqualStrings("one", buf.line(0));
    try std.testing.expectEqual(@as(usize, 1), h.travel(&buf, &cy, &cx, 1, false));
    try std.testing.expectEqualStrings("Aone", buf.line(0));
}

test "travel reports how far it got and stops at the ends" {
    const gpa = std.testing.allocator;
    var buf = try buffer.Buffer.fromBytes(gpa, "\n");
    defer buf.deinit();
    var h = History.init(gpa);
    defer h.deinit();
    var cy: usize = 0;
    var cx: usize = 0;

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        h.record(&buf, 0, 0);
        _ = try buf.insertCodepoint(0, 0, 'x');
    }
    try std.testing.expectEqual(@as(usize, 3), h.travel(&buf, &cy, &cx, 9, true));
    try std.testing.expectEqualStrings("", buf.line(0));
    try std.testing.expectEqual(@as(usize, 0), h.travel(&buf, &cy, &cx, 1, true));
    try std.testing.expectEqual(@as(usize, 3), h.travel(&buf, &cy, &cx, 9, false));
    try std.testing.expectEqualStrings("xxx", buf.line(0));
}

test "a change that alters nothing costs no undo step" {
    const gpa = std.testing.allocator;
    var buf = try buffer.Buffer.fromBytes(gpa, "one\n");
    defer buf.deinit();
    var h = History.init(gpa);
    defer h.deinit();
    var cy: usize = 0;
    var cx: usize = 0;

    h.record(&buf, 0, 0); // operators that turn out to change nothing
    h.record(&buf, 0, 0);
    h.record(&buf, 0, 0);
    _ = try buf.insertCodepoint(0, 0, 'X');
    try std.testing.expect(h.undo(&buf, &cy, &cx));
    try std.testing.expectEqualStrings("one", buf.line(0));
    try std.testing.expect(!h.undo(&buf, &cy, &cx)); // one state, not four
}

test "the tree stays bounded" {
    const gpa = std.testing.allocator;
    var buf = try buffer.Buffer.fromBytes(gpa, "\n");
    defer buf.deinit();
    var h = History.init(gpa);
    defer h.deinit();
    h.max_nodes = 8;

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        h.record(&buf, 0, 0);
        _ = try buf.insertCodepoint(0, 0, 'x');
    }
    h.record(&buf, 0, 0);
    try std.testing.expect(h.liveCount() <= 8);

    // What is left is still a usable chain back through the newest states.
    var cy: usize = 0;
    var cx: usize = 0;
    try std.testing.expectEqual(@as(usize, 3), h.travel(&buf, &cy, &cx, 3, true));
}

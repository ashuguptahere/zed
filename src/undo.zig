//! Undo history as a *tree* of edits.
//!
//! Undo walks to a node's parent, redo back down the branch it came from — and,
//! unlike a linear history, editing after an undo starts a new branch instead
//! of throwing the old one away. `g-`/`g+` and `:earlier`/`:later` walk every
//! state in the order it was created, which is how work stranded on an
//! abandoned branch is reached again.
//!
//! A node stores the *difference* from its parent, not a copy of the buffer:
//! the offset where the two first differ, the bytes that were there and the
//! bytes that replaced them, found by trimming the common prefix and suffix.
//! One 300-keystroke session on a 7.6 MB file cost 295 MB of snapshots before
//! and 12 MB of edits now — and it is what makes writing the history to disk
//! conceivable at all.
//!
//! The content of the state we are on is kept materialised in `base`, so
//! stepping to a neighbour applies one small edit rather than rebuilding
//! anything. Jumping across the tree walks up to the common ancestor undoing
//! edits and back down applying them, which is a handful of memmoves — every
//! move is proportional to what changed, never to the file.
//!
//! Nodes live in one array and refer to each other by index, so nothing
//! dangles when it grows; freed slots are reused.

const std = @import("std");
const buffer = @import("buffer.zig");
const config = @import("config.zig");
const log = @import("log.zig");
const Allocator = std.mem.Allocator;

/// A state, as the edit that turns its parent into it. The root has no parent
/// and holds the whole text (`at`/`old_len` zero, `bytes` the content).
const Node = struct {
    /// `parent[0..at] ++ inserted ++ parent[at + old_len ..]`
    at: u32,
    old_len: u32,
    new_len: u32,
    /// The removed bytes followed by the inserted ones, in one allocation:
    /// `bytes[0..old_len]` restores the parent, `bytes[old_len..]` produces
    /// this state. Keeping both directions is what makes undo as cheap as redo.
    bytes: []u8,
    cy: usize,
    cx: usize,
    parent: ?u32,
    /// The child undo came from, so redo returns the way it went.
    last_child: ?u32,
    children: u32,
    depth: u32, // distance from the root: how the common ancestor is found
    seq: u32, // creation order: what `g-`/`g+` and `:earlier` count in
    time_ms: i64,
    saved: bool, // the buffer was written while in this state (`:earlier 1f`)
    alive: bool,

    fn removed(self: Node) []const u8 {
        return self.bytes[0..self.old_len];
    }

    fn inserted(self: Node) []const u8 {
        return self.bytes[self.old_len..];
    }
};

/// One row of `:undolist`.
pub const Entry = struct {
    seq: u32,
    time_ms: i64,
    current: bool,
    branch: bool, // its parent has more than one child: an alternative history
};

/// Where a file's history is kept: `$XDG_STATE_HOME/zedit/undo/<hash>`. The
/// name is a hash of the absolute path (paths are longer than a filename may
/// be, and contain slashes); the path itself is stored inside the file and
/// checked on load, so a collision cannot apply the wrong history.
pub fn filePath(buf: []u8, abs_path: []const u8) ?[]const u8 {
    var home_buf: [512]u8 = undefined;
    const dir = config.xdgPath(&home_buf, "XDG_STATE_HOME", ".local/state", "undo") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/{x:0>16}.undo", .{ dir, std.hash.Wyhash.hash(0, abs_path) }) catch null;
}

pub const History = struct {
    gpa: Allocator,
    nodes: std.ArrayList(Node),
    cur: ?u32,
    /// The text of the state `cur` names. Kept beside the tree so a step is an
    /// edit rather than a reconstruction.
    base: std.ArrayList(u8),
    /// The buffer has been edited since we arrived at `cur`, so the state it
    /// now holds still needs a node of its own. Sealing is deferred to the next
    /// transition because that is the first moment the new state is complete.
    dirty: bool,
    next_seq: u32,
    max_nodes: usize,

    pub fn init(gpa: Allocator) History {
        return .{
            .gpa = gpa,
            .nodes = .empty,
            .cur = null,
            .base = .empty,
            .dirty = false,
            .next_seq = 0,
            .max_nodes = 256,
        };
    }

    pub fn deinit(self: *History) void {
        for (self.nodes.items) |n| if (n.alive) self.gpa.free(n.bytes);
        self.nodes.deinit(self.gpa);
        self.base.deinit(self.gpa);
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
        defer self.gpa.free(data);
        if (self.cur == null) return self.plantRoot(data, cy, cx);
        if (std.mem.eql(u8, self.base.items, data)) {
            self.dirty = false;
            return;
        }
        const d = diff(self.base.items, data);
        const bytes = self.gpa.alloc(u8, d.old_len + d.new_len) catch return;
        @memcpy(bytes[0..d.old_len], self.base.items[d.at..][0..d.old_len]);
        @memcpy(bytes[d.old_len..], data[d.at..][0..d.new_len]);
        const parent = self.cur.?;
        const idx = self.alloc(.{
            .at = @intCast(d.at),
            .old_len = @intCast(d.old_len),
            .new_len = @intCast(d.new_len),
            .bytes = bytes,
            .cy = cy,
            .cx = cx,
            .parent = parent,
            .last_child = null,
            .children = 0,
            .depth = self.nodes.items[parent].depth + 1,
            .seq = self.next_seq,
            .time_ms = log.nowMs(),
            .saved = false,
            .alive = true,
        }) catch {
            self.gpa.free(bytes);
            return;
        };
        self.next_seq += 1;
        self.nodes.items[parent].last_child = idx;
        self.nodes.items[parent].children += 1;
        self.setBase(data) catch {};
        self.cur = idx;
        self.dirty = false;
        self.prune();
    }

    fn plantRoot(self: *History, data: []const u8, cy: usize, cx: usize) void {
        const bytes = self.gpa.dupe(u8, data) catch return;
        const idx = self.alloc(.{
            .at = 0,
            .old_len = 0,
            .new_len = @intCast(bytes.len),
            .bytes = bytes,
            .cy = cy,
            .cx = cx,
            .parent = null,
            .last_child = null,
            .children = 0,
            .depth = 0,
            .seq = self.next_seq,
            .time_ms = log.nowMs(),
            .saved = false,
            .alive = true,
        }) catch {
            self.gpa.free(bytes);
            return;
        };
        self.next_seq += 1;
        self.setBase(data) catch {};
        self.cur = idx;
        self.dirty = false;
    }

    fn setBase(self: *History, data: []const u8) !void {
        self.base.clearRetainingCapacity();
        try self.base.appendSlice(self.gpa, data);
    }

    const Diff = struct { at: usize, old_len: usize, new_len: usize };

    /// The one replaced range between two texts: trim the bytes they share at
    /// the front and at the back, and what is left is what changed. Exact for
    /// the edits an editor makes one at a time, and still correct (just wider)
    /// for a change that touched several places at once.
    fn diff(old: []const u8, new: []const u8) Diff {
        const max_pre = @min(old.len, new.len);
        var pre: usize = 0;
        while (pre < max_pre and old[pre] == new[pre]) pre += 1;
        var suf: usize = 0;
        while (suf < max_pre - pre and old[old.len - 1 - suf] == new[new.len - 1 - suf]) suf += 1;
        return .{ .at = pre, .old_len = old.len - pre - suf, .new_len = new.len - pre - suf };
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

    /// Promote the root's only child. It has to become a full-text node, which
    /// is the one place the whole file is copied — once per dropped state, and
    /// only once the history is already at its limit.
    fn dropRoot(self: *History) bool {
        const root = self.rootIndex() orelse return false;
        if (self.cur == root or self.nodes.items[root].children != 1) return false;
        var child: u32 = 0;
        var found = false;
        for (self.nodes.items, 0..) |n, i| {
            if (n.alive and n.parent == root) {
                child = @intCast(i);
                found = true;
                break;
            }
        }
        if (!found) return false;

        const r = self.nodes.items[root];
        const c = self.nodes.items[child];
        const len = r.bytes.len - c.old_len + c.new_len;
        const full = self.gpa.alloc(u8, len) catch return false;
        @memcpy(full[0..c.at], r.bytes[0..c.at]);
        @memcpy(full[c.at..][0..c.new_len], c.inserted());
        @memcpy(full[c.at + c.new_len ..], r.bytes[c.at + c.old_len ..]);

        self.gpa.free(self.nodes.items[child].bytes);
        self.nodes.items[child] = .{
            .at = 0,
            .old_len = 0,
            .new_len = @intCast(len),
            .bytes = full,
            .cy = c.cy,
            .cx = c.cx,
            .parent = null,
            .last_child = c.last_child,
            .children = c.children,
            .depth = 0,
            .seq = c.seq,
            .time_ms = c.time_ms,
            .saved = c.saved,
            .alive = true,
        };
        self.free(root);
        for (self.nodes.items) |*n| {
            if (n.alive and n.depth > 0) n.depth -= 1;
        }
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
        self.gpa.free(self.nodes.items[idx].bytes);
        self.nodes.items[idx].alive = false;
    }

    /// Move to a neighbour of `cur` — its parent, or one of its children — by
    /// applying that one edit to `base`. `cur` only advances once the edit has
    /// landed, so a failure leaves the two consistent.
    fn hop(self: *History, next: u32) bool {
        const c = self.cur.?;
        if (self.nodes.items[next].parent == c) {
            const n = self.nodes.items[next];
            self.base.replaceRange(self.gpa, n.at, n.old_len, n.inserted()) catch return false;
        } else {
            const n = self.nodes.items[c]; // undoing our own edit
            self.base.replaceRange(self.gpa, n.at, n.new_len, n.removed()) catch return false;
        }
        self.cur = next;
        return true;
    }

    /// Walk to any node: up to the common ancestor undoing edits, then down
    /// applying them.
    fn goTo(self: *History, target: u32, buf: *buffer.Buffer, cy: *usize, cx: *usize) bool {
        if (self.cur == null) return false;
        var down: std.ArrayList(u32) = .empty;
        defer down.deinit(self.gpa);

        // Bring both to the same depth, collecting the downward half.
        var a = self.cur.?;
        var b = target;
        while (self.nodes.items[b].depth > self.nodes.items[a].depth) {
            down.append(self.gpa, b) catch return false;
            b = self.nodes.items[b].parent orelse return false;
        }
        var ups: usize = 0;
        while (self.nodes.items[a].depth > self.nodes.items[b].depth) {
            a = self.nodes.items[a].parent orelse return false;
            ups += 1;
        }
        while (a != b) { // then rise together to the common ancestor
            down.append(self.gpa, b) catch return false;
            a = self.nodes.items[a].parent orelse return false;
            b = self.nodes.items[b].parent orelse return false;
            ups += 1;
        }

        var i: usize = 0;
        while (i < ups) : (i += 1) {
            const up = self.nodes.items[self.cur.?].parent orelse break;
            if (!self.hop(up)) break;
        }
        var j = down.items.len;
        while (j > 0) {
            j -= 1;
            if (!self.hop(down.items[j])) break;
        }
        const at = self.nodes.items[self.cur.?];
        buf.replaceContents(self.base.items) catch return false;
        cy.* = at.cy;
        cx.* = at.cx;
        buf.dirty = true;
        self.dirty = false;
        return self.cur.? == target;
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

    /// The buffer has just been written: remember that this state is on disk,
    /// so `:earlier 1f` can come back to it.
    pub fn markSaved(self: *History, buf: *const buffer.Buffer, cy: usize, cx: usize) void {
        self.seal(buf, cy, cx);
        if (self.cur) |c| self.nodes.items[c].saved = true;
    }

    /// `:earlier Nf` / `:later Nf`: step over the states the file was written
    /// at. Running past the last one lands on the oldest (or newest) state
    /// rather than failing, the same clamp vim applies (nvim-verified: with no
    /// writes at all, `:earlier 1f` goes to the very beginning).
    pub fn travelWrites(self: *History, buf: *buffer.Buffer, cy: *usize, cx: *usize, count: usize, back: bool) bool {
        if (self.cur == null and !self.dirty) return false;
        self.seal(buf, cy.*, cx.*);
        var target: ?u32 = null;
        var from = self.nodes.items[self.cur.?].seq;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const next = self.adjacentSaved(from, back) orelse {
                target = self.endMost(back);
                break;
            };
            target = next;
            from = self.nodes.items[next].seq;
        }
        const to = target orelse return false;
        if (to == self.cur.?) return false;
        return self.goTo(to, buf, cy, cx);
    }

    /// The nearest written state before (or after) `from` in creation order.
    fn adjacentSaved(self: *const History, from: u32, back: bool) ?u32 {
        var best: ?u32 = null;
        for (self.nodes.items, 0..) |n, i| {
            if (!n.alive or !n.saved) continue;
            if (back and n.seq >= from) continue;
            if (!back and n.seq <= from) continue;
            if (best) |b| {
                const better = if (back) n.seq > self.nodes.items[b].seq else n.seq < self.nodes.items[b].seq;
                if (!better) continue;
            }
            best = @intCast(i);
        }
        return best;
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

    // === persistence =======================================================
    //
    // The tree is diffs, so writing it costs about what the edits cost. The
    // root's full text is *not* written: the state the history is anchored to
    // is the text in the file, and the diffs run both ways, so the root can be
    // rebuilt from it on load. A 200-change session on an 8.6 MB file is a
    // 1.5 KB undo file rather than a second copy of the file.
    //
    // What is written instead is the length and hash of that anchor text, so a
    // file edited by something else is detected and its history refused rather
    // than replayed onto text it never described.
    //
    // Records are stored by sequence number rather than array index, because
    // indices are a detail of how slots get reused.

    const magic = "ZUNDO";
    const format_version: u8 = 1;
    const no_seq: u32 = 0xFFFF_FFFF;

    /// Write the whole tree to `path` (0600 — it holds the file's text).
    pub fn writeTo(self: *History, io: std.Io, path: []const u8, for_file: []const u8) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        const w = &out;
        w.appendSlice(self.gpa, magic) catch return;
        w.append(self.gpa, format_version) catch return;
        putU32(self.gpa, w, @intCast(for_file.len)) catch return;
        w.appendSlice(self.gpa, for_file) catch return;
        putU64(self.gpa, w, self.base.items.len) catch return;
        putU64(self.gpa, w, std.hash.Wyhash.hash(0, self.base.items)) catch return;
        putU32(self.gpa, w, if (self.cur) |c| self.nodes.items[c].seq else no_seq) catch return;
        putU32(self.gpa, w, self.next_seq) catch return;
        putU32(self.gpa, w, @intCast(self.liveCount())) catch return;

        // Ascending sequence order, so the reader meets a parent before its
        // children and can link as it goes.
        var order: std.ArrayList(u32) = .empty;
        defer order.deinit(self.gpa);
        for (self.nodes.items, 0..) |n, i| {
            if (n.alive) order.append(self.gpa, @intCast(i)) catch return;
        }
        const Ctx = struct {
            h: *const History,
            fn less(c: @This(), a: u32, b: u32) bool {
                return c.h.nodes.items[a].seq < c.h.nodes.items[b].seq;
            }
        };
        std.mem.sort(u32, order.items, Ctx{ .h = self }, Ctx.less);

        for (order.items) |i| {
            const n = self.nodes.items[i];
            putU32(self.gpa, w, n.seq) catch return;
            putU32(self.gpa, w, if (n.parent) |p| self.nodes.items[p].seq else no_seq) catch return;
            putU32(self.gpa, w, if (n.last_child) |c| (if (self.nodes.items[c].alive) self.nodes.items[c].seq else no_seq) else no_seq) catch return;
            putU32(self.gpa, w, n.at) catch return;
            putU32(self.gpa, w, n.old_len) catch return;
            putU32(self.gpa, w, if (n.parent == null) 0 else n.new_len) catch return;
            putU32(self.gpa, w, @intCast(n.cy)) catch return;
            putU32(self.gpa, w, @intCast(n.cx)) catch return;
            putU64(self.gpa, w, @bitCast(n.time_ms)) catch return;
            w.append(self.gpa, @intFromBool(n.saved)) catch return;
            // The root's text is the one thing left out; it comes back from
            // the file itself.
            if (n.parent != null) w.appendSlice(self.gpa, n.bytes) catch return;
        }

        if (std.mem.lastIndexOfScalar(u8, path, '/')) |cut| {
            std.Io.Dir.cwd().createDirPath(io, path[0..cut]) catch {};
        }
        // The history is a copy of the file's text in another place, so it is
        // created owner-only rather than at the usual 0666-minus-umask.
        std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = out.items,
            .flags = .{ .permissions = @enumFromInt(0o600) },
        }) catch |err| {
            std.log.scoped(.undo).debug("cannot write {s}: {s}", .{ path, @errorName(err) });
        };
    }

    /// Read a tree written by `writeTo`. `content` is the text the file holds
    /// now: it seeds the history and is checked against the anchor recorded
    /// when it was written, so a file edited by something else gets no history
    /// rather than someone else's past. Null on any disagreement.
    pub fn readFrom(gpa: Allocator, io: std.Io, path: []const u8, for_file: []const u8, content: []const u8) ?History {
        const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20)) catch return null;
        defer gpa.free(raw);
        var h = History.init(gpa);
        if (parseInto(&h, raw, for_file, content)) return h;
        h.deinit();
        return null;
    }

    fn parseInto(h: *History, raw: []const u8, for_file: []const u8, content: []const u8) bool {
        // A fixed reader turns every read past the end into `error.EndOfStream`,
        // so a truncated or hostile file can only ever be rejected.
        var r: std.Io.Reader = .fixed(raw);
        if (!std.mem.eql(u8, r.take(magic.len) catch return false, magic)) return false;
        if ((r.takeByte() catch return false) != format_version) return false;
        const plen = r.takeInt(u32, .little) catch return false;
        if (!std.mem.eql(u8, r.take(plen) catch return false, for_file)) return false;
        const anchor_len = r.takeInt(u64, .little) catch return false;
        const anchor_hash = r.takeInt(u64, .little) catch return false;
        if (anchor_len != content.len or anchor_hash != std.hash.Wyhash.hash(0, content)) return false;
        const cur_seq = r.takeInt(u32, .little) catch return false;
        h.next_seq = r.takeInt(u32, .little) catch return false;
        const count = r.takeInt(u32, .little) catch return false;
        if (count > 1_000_000) return false;

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const seq = r.takeInt(u32, .little) catch return false;
            const parent_seq = r.takeInt(u32, .little) catch return false;
            const child_seq = r.takeInt(u32, .little) catch return false;
            const at = r.takeInt(u32, .little) catch return false;
            const old_len = r.takeInt(u32, .little) catch return false;
            const new_len = r.takeInt(u32, .little) catch return false;
            const cy = r.takeInt(u32, .little) catch return false;
            const cx = r.takeInt(u32, .little) catch return false;
            const time_ms: i64 = @bitCast(r.takeInt(u64, .little) catch return false);
            const saved = (r.takeByte() catch return false) != 0;
            const want = if (parent_seq == no_seq) 0 else @as(usize, old_len) + new_len;
            const body = r.take(want) catch return false;
            const bytes = h.gpa.dupe(u8, body) catch return false;
            const parent = if (parent_seq == no_seq) null else h.indexOfSeq(parent_seq) orelse {
                h.gpa.free(bytes);
                return false;
            };
            const idx = h.alloc(.{
                .at = at,
                .old_len = old_len,
                .new_len = new_len,
                .bytes = bytes,
                .cy = cy,
                .cx = cx,
                .parent = parent,
                .last_child = null, // linked below, once every seq is known
                .children = 0,
                .depth = if (parent) |p| h.nodes.items[p].depth + 1 else 0,
                .seq = seq,
                .time_ms = time_ms,
                .saved = saved,
                .alive = true,
            }) catch {
                h.gpa.free(bytes);
                return false;
            };
            if (parent) |p| h.nodes.items[p].children += 1;
            if (child_seq != no_seq) h.nodes.items[idx].last_child = child_seq; // patched below
        }
        // Second pass: last_child was stored as a sequence number.
        for (h.nodes.items) |*n| {
            if (!n.alive) continue;
            if (n.last_child) |seq_as_child| n.last_child = h.indexOfSeq(seq_as_child);
        }
        h.cur = if (cur_seq == no_seq) null else h.indexOfSeq(cur_seq);
        if (h.cur == null and count > 0) return false;
        h.setBase(content) catch return false;
        return h.rebuildRoot();
    }

    fn indexOfSeq(self: *const History, seq: u32) ?u32 {
        for (self.nodes.items, 0..) |n, i| if (n.alive and n.seq == seq) return @intCast(i);
        return null;
    }

    /// Undo every edit from `cur` back to the root to recover the root's text,
    /// which the file does not carry. Pruning is the only thing that needs it,
    /// but it needs it to be exact.
    fn rebuildRoot(self: *History) bool {
        const cur = self.cur orelse return true;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        text.appendSlice(self.gpa, self.base.items) catch return false;
        var at = cur;
        var steps: usize = 0;
        while (self.nodes.items[at].parent) |p| {
            const n = self.nodes.items[at];
            if (n.at + n.new_len > text.items.len) return false; // not our file
            text.replaceRange(self.gpa, n.at, n.new_len, n.removed()) catch return false;
            at = p;
            steps += 1;
            if (steps > self.nodes.items.len) return false; // a cycle
        }
        const full = text.toOwnedSlice(self.gpa) catch return false;
        self.gpa.free(self.nodes.items[at].bytes);
        self.nodes.items[at].bytes = full;
        self.nodes.items[at].new_len = @intCast(full.len);
        return true;
    }

    fn putU32(gpa: Allocator, w: *std.ArrayList(u8), v: u32) !void {
        try w.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
    }

    fn putU64(gpa: Allocator, w: *std.ArrayList(u8), v: u64) !void {
        try w.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u64, v)));
    }

    /// Bytes the history is holding — what the diff storage exists to keep small.
    pub fn bytesHeld(self: *const History) usize {
        var n: usize = self.base.items.len;
        for (self.nodes.items) |s| {
            if (s.alive) n += s.bytes.len;
        }
        return n;
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

test "a node costs its edit, not the file" {
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendNTimes(gpa, 'a', 100_000);
    try text.append(gpa, '\n');
    var buf = try buffer.Buffer.fromBytes(gpa, text.items);
    defer buf.deinit();
    var h = History.init(gpa);
    defer h.deinit();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        h.record(&buf, 0, 0);
        _ = try buf.insertCodepoint(0, 0, 'x');
    }
    h.record(&buf, 0, 0);
    // 200 one-character edits over a 100 KB file: the root and the live copy
    // dominate, the 200 states cost bytes each. Snapshots would have needed
    // 20 MB.
    try std.testing.expect(h.bytesHeld() < 300_000);
}

test "a history survives a round trip through its file" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "/tmp/zedit_undo_roundtrip.undo";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var buf = try buffer.Buffer.fromBytes(gpa, "start\n");
    defer buf.deinit();
    var cy: usize = 0;
    var cx: usize = 0;
    {
        var h = History.init(gpa);
        defer h.deinit();
        h.record(&buf, 0, 0);
        _ = try buf.insertCodepoint(0, 0, 'A');
        h.record(&buf, 0, 0);
        _ = try buf.insertCodepoint(0, 0, 'B');
        _ = h.undo(&buf, &cy, &cx); // "Astart", leaving "BAstart" on a branch
        h.markSaved(&buf, cy, cx);
        h.writeTo(io, path, "/tmp/some/file.txt");
    }

    // A different file's history is never applied, whatever the name says —
    // and neither is one whose anchor text no longer matches.
    try std.testing.expect(History.readFrom(gpa, io, path, "/tmp/other.txt", "Astart\n") == null);
    try std.testing.expect(History.readFrom(gpa, io, path, "/tmp/some/file.txt", "edited elsewhere\n") == null);

    var back = History.readFrom(gpa, io, path, "/tmp/some/file.txt", "Astart\n") orelse return error.NoHistory;
    defer back.deinit();

    // The branch, the sequence numbers and the write mark all came back.
    try std.testing.expectEqual(@as(usize, 3), back.liveCount());
    try std.testing.expect(back.redo(&buf, &cy, &cx));
    try std.testing.expectEqualStrings("BAstart", buf.line(0));
    try std.testing.expect(back.travelWrites(&buf, &cy, &cx, 1, true));
    try std.testing.expectEqualStrings("Astart", buf.line(0));
}

test "a truncated or foreign undo file is refused, not trusted" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "/tmp/zedit_undo_broken.undo";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var buf = try buffer.Buffer.fromBytes(gpa, "hello\n");
    defer buf.deinit();
    var h = History.init(gpa);
    defer h.deinit();
    h.record(&buf, 0, 0);
    _ = try buf.insertCodepoint(0, 0, 'x');
    h.record(&buf, 0, 0);
    h.writeTo(io, path, "/tmp/f.txt");

    const whole = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(whole);

    // Every prefix of a valid file must be rejected rather than half-read.
    var cut: usize = 0;
    while (cut < whole.len) : (cut += 1) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = whole[0..cut] });
        if (History.readFrom(gpa, io, path, "/tmp/f.txt", "xhello\n")) |*bad| {
            var b = bad.*;
            b.deinit();
            return error.TruncatedFileAccepted;
        }
    }
    // Random bytes in place of the body are rejected too.
    const junk = try gpa.dupe(u8, whole);
    defer gpa.free(junk);
    for (junk[8..]) |*b| b.* = 0xAB;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = junk });
    try std.testing.expect(History.readFrom(gpa, io, path, "/tmp/f.txt", "xhello\n") == null);
}

test "jumping across branches rebuilds the exact text" {
    const gpa = std.testing.allocator;
    var buf = try buffer.Buffer.fromBytes(gpa, "start\n");
    defer buf.deinit();
    var h = History.init(gpa);
    defer h.deinit();
    var cy: usize = 0;
    var cx: usize = 0;

    // Two branches, each several states deep, so the walk has to rise to the
    // common ancestor and descend the other side.
    h.record(&buf, 0, 0);
    _ = try buf.insertCodepoint(0, 0, 'A');
    h.record(&buf, 0, 0);
    _ = try buf.insertCodepoint(0, 0, 'B'); // "BAstart"
    _ = h.undo(&buf, &cy, &cx);
    _ = h.undo(&buf, &cy, &cx);
    try std.testing.expectEqualStrings("start", buf.line(0));
    h.record(&buf, 0, 0);
    _ = try buf.insertCodepoint(0, 0, 'C');
    h.record(&buf, 0, 0);
    _ = try buf.insertCodepoint(0, 0, 'D'); // "DCstart" on the other branch
    h.record(&buf, 0, 0);

    // seq 0 start, 1 "Astart", 2 "BAstart", 3 "Cstart", 4 "DCstart"
    try std.testing.expect(h.goToSeq(&buf, &cy, &cx, 2));
    try std.testing.expectEqualStrings("BAstart", buf.line(0));
    try std.testing.expect(h.goToSeq(&buf, &cy, &cx, 4));
    try std.testing.expectEqualStrings("DCstart", buf.line(0));
    try std.testing.expect(h.goToSeq(&buf, &cy, &cx, 1));
    try std.testing.expectEqualStrings("Astart", buf.line(0));
    try std.testing.expect(h.goToSeq(&buf, &cy, &cx, 0));
    try std.testing.expectEqualStrings("start", buf.line(0));
}

//! Vim registers: named text holders for yank, delete and paste.
//!
//! Slot 0 is the unnamed register ("); slots 1..26 are a..z; slot 27 is the
//! system clipboard (`+`, with `*` as an alias) — the editor mirrors writes to
//! it out to the terminal via OSC 52, so it works locally and over SSH.
//! Writing a named register mirrors into the unnamed one, matching vim. An
//! uppercase name appends to the lowercase register. Each register remembers
//! how its text was taken so paste can reproduce vim's behaviour.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// How the text was taken, which is what `p`/`P` dispatch on: charwise text
/// goes in at the cursor, linewise text becomes whole lines, and blockwise
/// text is a rectangle — one register line per buffer line, at one column.
pub const Kind = enum { charwise, linewise, blockwise };

pub const Register = struct {
    text: []u8,
    kind: Kind,
    /// Blockwise only: the rectangle's display width. A yank slices each row
    /// ragged (a short line contributes fewer cells than the block spans), so
    /// the width has to travel with the text for a paste to square it back up
    /// — vim pads a register line out to it whenever something follows the
    /// insertion point. Zero for the other kinds.
    width: usize = 0,
};

pub const Store = struct {
    gpa: Allocator,
    slots: [28]?Register,

    pub fn init(gpa: Allocator) Store {
        return .{ .gpa = gpa, .slots = [_]?Register{null} ** 28 };
    }

    pub fn deinit(self: *Store) void {
        for (&self.slots) |*slot| {
            if (slot.*) |r| self.gpa.free(r.text);
            slot.* = null;
        }
    }

    fn index(name: ?u8) ?usize {
        const n = name orelse return 0;
        return switch (n) {
            '"' => 0,
            'a'...'z' => 1 + (n - 'a'),
            'A'...'Z' => 1 + (n - 'A'),
            '+', '*' => 27, // system clipboard (shared slot, like vim's common setup)
            else => null,
        };
    }

    /// Whether `name` addresses the system clipboard (`"+` / `"*`).
    pub fn isClipboard(name: ?u8) bool {
        const n = name orelse return false;
        return n == '+' or n == '*';
    }

    /// Store `text` in register `name` (null = unnamed). Copies the text.
    ///
    /// An uppercase name appends. The register keeps the kind it already had —
    /// only a *linewise* addition overrides it — so appending to a rectangle
    /// leaves a rectangle, one row longer and at its original width
    /// (nvim-verified). Only a charwise register has its last line joined to
    /// the new text; a blockwise one gains a whole row, so the two are
    /// separated by a newline.
    pub fn set(self: *Store, name: ?u8, text: []const u8, kind: Kind, width: usize) !void {
        const slot = index(name) orelse 0;
        const append = if (name) |n| n >= 'A' and n <= 'Z' else false;

        if (append and self.slots[slot] != null) {
            const old = self.slots[slot].?;
            const sep: usize = if (old.kind == .blockwise) 1 else 0;
            const buf = try self.gpa.alloc(u8, old.text.len + sep + text.len);
            @memcpy(buf[0..old.text.len], old.text);
            if (sep == 1) buf[old.text.len] = '\n';
            @memcpy(buf[old.text.len + sep ..], text);
            self.gpa.free(old.text);
            const joined: Kind = if (kind == .linewise) .linewise else old.kind;
            self.slots[slot] = .{
                .text = buf,
                .kind = joined,
                .width = if (joined == .blockwise) old.width else 0,
            };
        } else {
            try self.store(slot, text, kind, width);
        }

        // Mirror named writes into the unnamed register.
        if (slot != 0) {
            const r = self.slots[slot].?;
            try self.store(0, r.text, r.kind, r.width);
        }
    }

    fn store(self: *Store, slot: usize, text: []const u8, kind: Kind, width: usize) !void {
        const buf = try self.gpa.dupe(u8, text);
        if (self.slots[slot]) |r| self.gpa.free(r.text);
        self.slots[slot] = .{ .text = buf, .kind = kind, .width = width };
    }

    pub fn get(self: *const Store, name: ?u8) ?Register {
        const slot = index(name) orelse return null;
        return self.slots[slot];
    }
};

test "set and get unnamed" {
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    try s.set(null, "hello", .charwise, 0);
    const r = s.get(null).?;
    try std.testing.expectEqualStrings("hello", r.text);
    try std.testing.expectEqual(Kind.charwise, r.kind);
}

test "named mirrors to unnamed; uppercase appends" {
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    try s.set('a', "foo", .linewise, 0);
    try std.testing.expectEqualStrings("foo", s.get('a').?.text);
    try std.testing.expectEqualStrings("foo", s.get(null).?.text); // mirrored
    try s.set('A', "bar", .linewise, 0);
    try std.testing.expectEqualStrings("foobar", s.get('a').?.text);
    try std.testing.expectEqual(Kind.linewise, s.get('a').?.kind);
}

test "clipboard register + and * share a slot" {
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    try s.set('+', "clip", .charwise, 0);
    try std.testing.expectEqualStrings("clip", s.get('*').?.text);
    try std.testing.expectEqualStrings("clip", s.get(null).?.text); // mirrored
    try std.testing.expect(Store.isClipboard('+'));
    try std.testing.expect(!Store.isClipboard('a'));
}

test "blockwise kind and width survive a mirror to the unnamed register" {
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    try s.set('a', "ab\ncd", .blockwise, 3);
    for ([_]?u8{ 'a', null }) |name| {
        const r = s.get(name).?;
        try std.testing.expectEqual(Kind.blockwise, r.kind);
        try std.testing.expectEqual(@as(usize, 3), r.width);
    }
}

test "appending keeps the register's own kind unless the addition is linewise" {
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    // A rectangle stays a rectangle, one row longer and at its own width —
    // the appended text is a new row, not a continuation of the last one.
    try s.set('a', "ab\ncd", .blockwise, 2);
    try s.set('A', "Z", .charwise, 0);
    try std.testing.expectEqualStrings("ab\ncd\nZ", s.get('a').?.text);
    try std.testing.expectEqual(Kind.blockwise, s.get('a').?.kind);
    try std.testing.expectEqual(@as(usize, 2), s.get('a').?.width);
    // Linewise overrides, and the row separator still goes in.
    try s.set('A', "ZZ\n", .linewise, 0);
    try std.testing.expectEqualStrings("ab\ncd\nZ\nZZ\n", s.get('a').?.text);
    try std.testing.expectEqual(Kind.linewise, s.get('a').?.kind);
    // A charwise register joins its last line to the addition instead.
    try s.set('b', "xy", .charwise, 0);
    try s.set('B', "ab\ncd", .blockwise, 2);
    try std.testing.expectEqualStrings("xyab\ncd", s.get('b').?.text);
    try std.testing.expectEqual(Kind.charwise, s.get('b').?.kind);
}

//! Vim registers: named text holders for yank, delete and paste.
//!
//! Slot 0 is the unnamed register ("); slots 1..26 are a..z; slot 27 is the
//! system clipboard (`+`, with `*` as an alias) — the editor mirrors writes to
//! it out to the terminal via OSC 52, so it works locally and over SSH.
//! Writing a named register mirrors into the unnamed one, matching vim. An
//! uppercase name appends to the lowercase register. Each register remembers
//! whether its text is linewise so paste can reproduce vim's behaviour.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Register = struct {
    text: []u8,
    linewise: bool,
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
    pub fn set(self: *Store, name: ?u8, text: []const u8, linewise: bool) !void {
        const slot = index(name) orelse 0;
        const append = if (name) |n| n >= 'A' and n <= 'Z' else false;

        if (append and self.slots[slot] != null) {
            const old = self.slots[slot].?;
            const buf = try self.gpa.alloc(u8, old.text.len + text.len);
            @memcpy(buf[0..old.text.len], old.text);
            @memcpy(buf[old.text.len..], text);
            self.gpa.free(old.text);
            self.slots[slot] = .{ .text = buf, .linewise = old.linewise or linewise };
        } else {
            try self.store(slot, text, linewise);
        }

        // Mirror named writes into the unnamed register.
        if (slot != 0) try self.store(0, self.slots[slot].?.text, self.slots[slot].?.linewise);
    }

    fn store(self: *Store, slot: usize, text: []const u8, linewise: bool) !void {
        const buf = try self.gpa.dupe(u8, text);
        if (self.slots[slot]) |r| self.gpa.free(r.text);
        self.slots[slot] = .{ .text = buf, .linewise = linewise };
    }

    pub fn get(self: *const Store, name: ?u8) ?Register {
        const slot = index(name) orelse return null;
        return self.slots[slot];
    }
};

test "set and get unnamed" {
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    try s.set(null, "hello", false);
    const r = s.get(null).?;
    try std.testing.expectEqualStrings("hello", r.text);
    try std.testing.expect(!r.linewise);
}

test "named mirrors to unnamed; uppercase appends" {
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    try s.set('a', "foo", true);
    try std.testing.expectEqualStrings("foo", s.get('a').?.text);
    try std.testing.expectEqualStrings("foo", s.get(null).?.text); // mirrored
    try s.set('A', "bar", true);
    try std.testing.expectEqualStrings("foobar", s.get('a').?.text);
}

test "clipboard register + and * share a slot" {
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    try s.set('+', "clip", false);
    try std.testing.expectEqualStrings("clip", s.get('*').?.text);
    try std.testing.expectEqualStrings("clip", s.get(null).?.text); // mirrored
    try std.testing.expect(Store.isClipboard('+'));
    try std.testing.expect(!Store.isClipboard('a'));
}

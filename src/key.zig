//! Decoding raw terminal bytes into key events.
//!
//! `decode` turns the front of a byte buffer into one `Key` plus the number of
//! bytes it consumed, so the editor can drain a whole read in a loop. UTF-8
//! text is decoded to a single codepoint; escape sequences for arrows, Home,
//! End, Delete and paging are recognised; everything else is `unknown` but
//! still consumes bytes so the loop never stalls.

const std = @import("std");
const unicode = @import("unicode.zig");

pub const Key = union(enum) {
    char: u21,
    ctrl: u8, // the associated lowercase letter, e.g. 0x03 -> 'c'
    enter,
    tab,
    backspace,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    delete,
    unknown,
};

pub const Decoded = struct {
    key: Key,
    consumed: usize,
};

/// Decode the first key in `bytes`, which must be non-empty.
pub fn decode(bytes: []const u8) Decoded {
    std.debug.assert(bytes.len > 0);
    const b = bytes[0];
    return switch (b) {
        0x1b => decodeEscape(bytes),
        '\r', '\n' => .{ .key = .enter, .consumed = 1 },
        '\t' => .{ .key = .tab, .consumed = 1 },
        0x7f, 0x08 => .{ .key = .backspace, .consumed = 1 },
        0x01...0x07, 0x0b, 0x0c, 0x0e...0x1a => .{ .key = .{ .ctrl = b - 1 + 'a' }, .consumed = 1 },
        else => decodeChar(bytes),
    };
}

fn decodeChar(bytes: []const u8) Decoded {
    const d = unicode.decode(bytes);
    return .{ .key = .{ .char = d.cp }, .consumed = d.len };
}

fn decodeEscape(bytes: []const u8) Decoded {
    // Lone ESC, or ESC not followed by a recognised introducer.
    if (bytes.len < 2 or (bytes[1] != '[' and bytes[1] != 'O')) {
        return .{ .key = .escape, .consumed = 1 };
    }
    if (bytes.len < 3) return .{ .key = .escape, .consumed = 1 };

    // SS3 sequences: ESC O <final>  (e.g. some terminals' Home/End/arrows).
    if (bytes[1] == 'O') {
        return .{ .key = ss3(bytes[2]), .consumed = 3 };
    }

    // CSI sequences: ESC [ ...
    const c = bytes[2];
    switch (c) {
        'A' => return .{ .key = .up, .consumed = 3 },
        'B' => return .{ .key = .down, .consumed = 3 },
        'C' => return .{ .key = .right, .consumed = 3 },
        'D' => return .{ .key = .left, .consumed = 3 },
        'H' => return .{ .key = .home, .consumed = 3 },
        'F' => return .{ .key = .end, .consumed = 3 },
        '0'...'9' => return decodeCsiNumeric(bytes),
        else => return .{ .key = .unknown, .consumed = 3 },
    }
}

fn ss3(final: u8) Key {
    return switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        else => .unknown,
    };
}

/// Parse ESC [ <number> ~  style sequences (Home/End/Delete/PageUp/PageDown).
fn decodeCsiNumeric(bytes: []const u8) Decoded {
    var i: usize = 2;
    var num: usize = 0;
    while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) {
        num = num * 10 + (bytes[i] - '0');
    }
    // Need the terminating '~'; if the sequence is truncated, drop what we have.
    if (i >= bytes.len) return .{ .key = .unknown, .consumed = bytes.len };
    const consumed = i + 1; // include the final byte
    if (bytes[i] != '~') return .{ .key = .unknown, .consumed = consumed };
    const key: Key = switch (num) {
        1, 7 => .home,
        4, 8 => .end,
        3 => .delete,
        5 => .page_up,
        6 => .page_down,
        else => .unknown,
    };
    return .{ .key = key, .consumed = consumed };
}

test "decode ascii char" {
    const d = decode("a");
    try std.testing.expectEqual(Key{ .char = 'a' }, d.key);
    try std.testing.expectEqual(@as(usize, 1), d.consumed);
}

test "decode control keys" {
    try std.testing.expectEqual(Key{ .ctrl = 'c' }, decode(&[_]u8{0x03}).key);
    try std.testing.expectEqual(Key.enter, decode("\r").key);
    try std.testing.expectEqual(Key.backspace, decode(&[_]u8{0x7f}).key);
    try std.testing.expectEqual(Key.escape, decode(&[_]u8{0x1b}).key);
}

test "decode arrows and navigation" {
    try std.testing.expectEqual(Key.up, decode("\x1b[A").key);
    try std.testing.expectEqual(Key.left, decode("\x1b[D").key);
    try std.testing.expectEqual(Key.home, decode("\x1b[H").key);
    const del = decode("\x1b[3~");
    try std.testing.expectEqual(Key.delete, del.key);
    try std.testing.expectEqual(@as(usize, 4), del.consumed);
    try std.testing.expectEqual(Key.page_down, decode("\x1b[6~").key);
}

test "decode utf8 char" {
    const d = decode("世");
    try std.testing.expectEqual(@as(u21, 0x4E16), d.key.char);
    try std.testing.expectEqual(@as(usize, 3), d.consumed);
}

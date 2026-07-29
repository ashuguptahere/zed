//! Decoding raw terminal bytes into key events.
//!
//! `decode` turns the front of a byte buffer into one `Key` plus the number of
//! bytes it consumed, so the editor can drain a whole read in a loop. UTF-8
//! text is decoded to a single codepoint; escape sequences for arrows, Home,
//! End, Delete and paging are recognised; everything else is `unknown` but
//! still consumes bytes so the loop never stalls.

const std = @import("std");
const unicode = @import("unicode.zig");

/// A mouse event, at 1-based screen coordinates.
pub const Mouse = struct { row: u16, col: u16 };

pub const Key = union(enum) {
    char: u21,
    mouse_press: Mouse, // left button down
    mouse_drag: Mouse, // motion while the left button is held
    mouse_release: Mouse, // left button up
    mouse_other, // a mouse report that never acts: other buttons, modifiers, tilt
    ctrl: u8, // the associated lowercase letter, e.g. 0x03 -> 'c'
    enter,
    tab,
    shift_tab,
    backspace,
    escape,
    up,
    down,
    scroll_up,
    scroll_down,
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
        'Z' => return .{ .key = .shift_tab, .consumed = 3 },
        '<' => return decodeSgrMouse(bytes),
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

/// Parse an SGR mouse report: ESC [ < button ; x ; y (M|m). The wheel
/// (buttons 64/65) and the three left-button events — press, motion while
/// held, release — become keys; every other report decodes to `mouse_other`,
/// a distinct key the editor swallows whole, so it can never reset pending
/// state or smear its raw bytes into the showcmd indicator the way an
/// `unknown` key would.
///
/// The button field packs flags, so each is tested by mask and in order:
/// bit 7 = extra buttons 8-11, bits 2-4 = shift/alt/ctrl, bit 6 = the wheel
/// (its low bits distinguish vertical 64/65 from the horizontal tilt axis
/// 66/67, which unlike the wheel *does* send a release), bit 5 = motion,
/// bits 0-1 = the button. Modified reports stay inert: nvim gives Alt+drag
/// and Ctrl+click meanings of their own (blockwise select, tag jump) that
/// zedit does not implement, so binding them to the plain gesture would be
/// silently wrong rather than merely missing.
fn decodeSgrMouse(bytes: []const u8) Decoded {
    var i: usize = 3; // past "\x1b[<"
    while (i < bytes.len and (bytes[i] == ';' or (bytes[i] >= '0' and bytes[i] <= '9'))) i += 1;
    if (i >= bytes.len) return .{ .key = .unknown, .consumed = bytes.len }; // truncated
    const consumed = i + 1; // include the final M/m
    const final = bytes[i];
    if (final != 'M' and final != 'm') return .{ .key = .mouse_other, .consumed = consumed };

    // button ; x ; y — the "<" marker makes even a malformed report
    // unambiguously mouse noise, so every parse failure is inert too.
    var it = std.mem.splitScalar(u8, bytes[3..i], ';');
    const b = std.fmt.parseInt(u16, it.next() orelse "", 10) catch return .{ .key = .mouse_other, .consumed = consumed };
    if (b & 128 != 0 or b & 28 != 0) return .{ .key = .mouse_other, .consumed = consumed }; // extra buttons, modifiers
    if (b & 64 != 0) {
        if (final != 'M') return .{ .key = .mouse_other, .consumed = consumed }; // a tilt release
        return switch (b & 3) {
            0 => .{ .key = .scroll_up, .consumed = consumed },
            1 => .{ .key = .scroll_down, .consumed = consumed },
            else => .{ .key = .mouse_other, .consumed = consumed }, // horizontal tilt
        };
    }
    if (b & 3 != 0) return .{ .key = .mouse_other, .consumed = consumed }; // middle/right/"no button"
    const col = std.fmt.parseInt(u16, it.next() orelse "", 10) catch return .{ .key = .mouse_other, .consumed = consumed };
    const row = std.fmt.parseInt(u16, it.next() orelse "", 10) catch return .{ .key = .mouse_other, .consumed = consumed };
    const m: Mouse = .{ .row = row, .col = col };
    if (final == 'm') return .{ .key = .{ .mouse_release = m }, .consumed = consumed };
    return .{ .key = if (b & 32 != 0) .{ .mouse_drag = m } else .{ .mouse_press = m }, .consumed = consumed };
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

test "decode shift-tab" {
    try std.testing.expectEqual(Key.shift_tab, decode("\x1b[Z").key);
    try std.testing.expectEqual(@as(usize, 3), decode("\x1b[Z").consumed);
}

test "decode SGR mouse wheel" {
    const up = decode("\x1b[<64;10;5M");
    try std.testing.expectEqual(Key.scroll_up, up.key);
    try std.testing.expectEqual(@as(usize, 11), up.consumed);
    try std.testing.expectEqual(Key.scroll_down, decode("\x1b[<65;1;1M").key);
    // The wheel sends no release, but the horizontal tilt axis does — a
    // wheel branch keyed on bit 6 alone would scroll vertically, twice.
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<64;5;5m").key);
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<66;5;5M").key); // tilt left
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<67;5;5m").key); // tilt right release
}

test "decode SGR mouse press, drag and release" {
    // The three left-button events act; everything else is `mouse_other` —
    // consumed whole and swallowed by the editor, never `unknown` (which
    // would reset pending state and show in showcmd).
    const click = decode("\x1b[<0;12;3M");
    try std.testing.expectEqual(@as(u16, 12), click.key.mouse_press.col);
    try std.testing.expectEqual(@as(u16, 3), click.key.mouse_press.row);
    try std.testing.expectEqual(@as(usize, 10), click.consumed);

    const drag = decode("\x1b[<32;120;45M");
    try std.testing.expectEqual(@as(u16, 120), drag.key.mouse_drag.col);
    try std.testing.expectEqual(@as(u16, 45), drag.key.mouse_drag.row);
    try std.testing.expectEqual(@as(usize, 13), drag.consumed);

    const rel = decode("\x1b[<0;12;3m");
    try std.testing.expectEqual(@as(u16, 12), rel.key.mouse_release.col);
    try std.testing.expectEqual(@as(u16, 3), rel.key.mouse_release.row);
    try std.testing.expectEqual(@as(usize, 10), rel.consumed);

    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<2;5;5M").key); // right button
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<1;5;5M").key); // middle button
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<33;5;5M").key); // middle drag
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<35;5;5M").key); // bare motion
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<3;5;5m").key); // "no button" release
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<128;5;5M").key); // extra button 8
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<129;5;5m").key); // extra button 9 release
    // Modifiers are unbound, so a modified report never acts as a plain one.
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<4;5;5M").key); // shift-click
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<8;5;5M").key); // alt-click
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<16;5;5M").key); // ctrl-click
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<40;5;5M").key); // alt-drag
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<48;5;5M").key); // ctrl-drag
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<72;5;5M").key); // alt-wheel
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<;5;5M").key); // malformed: still mouse noise
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<0;12;3X").key); // unknown final byte
    // A truncated report consumes what it has, so the decode loop never stalls.
    try std.testing.expectEqual(Key.unknown, decode("\x1b[<32;15").key);
    try std.testing.expectEqual(@as(usize, 8), decode("\x1b[<32;15").consumed);
}

test "decode utf8 char" {
    const d = decode("世");
    try std.testing.expectEqual(@as(u21, 0x4E16), d.key.char);
    try std.testing.expectEqual(@as(usize, 3), d.consumed);
}

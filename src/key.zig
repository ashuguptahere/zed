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

/// An 8-bit-per-channel colour, as an OSC colour report carries it.
pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const Key = union(enum) {
    char: u21,
    /// The terminal's answer to `OSC 11 ; ? ST` — the background colour it is
    /// painting the window with, ours to restore on the way out.
    background: Rgb,
    /// Any other OSC reply. Inert like `mouse_other`, and for the same reason:
    /// it must be swallowed whole rather than decoded as `Esc` and then the
    /// payload as text, which is what typed `]11;rgb:1a1b/...` into the buffer.
    osc_reply,
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
    scroll_up: Mouse, // wheel up, at the cell the pointer was over
    scroll_down: Mouse,
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
        '\r' => .{ .key = .enter, .consumed = 1 },
        '\t' => .{ .key = .tab, .consumed = 1 },
        0x7f => .{ .key = .backspace, .consumed = 1 },
        // 0x08 and 0x0a are Ctrl-h and Ctrl-j on the wire, and a terminal
        // sends 0x7f for Backspace and 0x0d for Enter — so the pairs *are*
        // distinguishable, which is how nvim binds <C-h>/<C-j> at all. The
        // editor turns them back into Backspace/Enter everywhere except
        // normal mode, so only the new window bindings see the difference.
        0x08 => .{ .key = .{ .ctrl = 'h' }, .consumed = 1 },
        '\n' => .{ .key = .{ .ctrl = 'j' }, .consumed = 1 },
        // NUL is what a terminal sends for Ctrl-Space, Ctrl-@ and — on most
        // of them — Ctrl-` too, since backtick masks to zero. They are
        // indistinguishable on the wire, so they are one key here, spelled
        // with a space because that is the one a user is most likely to name.
        0x00 => .{ .key = .{ .ctrl = ' ' }, .consumed = 1 },
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
    if (bytes.len < 2 or (bytes[1] != '[' and bytes[1] != 'O' and bytes[1] != ']')) {
        return .{ .key = .escape, .consumed = 1 };
    }
    if (bytes[1] == ']') return decodeOsc(bytes);
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

/// An OSC reply: `ESC ] <body> BEL` or `ESC ] <body> ESC \`. Only the editor's
/// own background query (`OSC 11`) means anything; every other reply is
/// consumed and dropped. An unterminated one consumes the whole buffer rather
/// than leaking its bytes as text — `incompleteEscapeTail` normally holds a
/// split reply back until its terminator arrives, so this is the last resort
/// for a reply longer than one read of the input buffer.
fn decodeOsc(bytes: []const u8) Decoded {
    var i: usize = 2;
    while (i < bytes.len) : (i += 1) {
        const end = if (bytes[i] == 0x07) i else if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') i else continue;
        const consumed = if (bytes[end] == 0x07) end + 1 else end + 2;
        const body = bytes[2..end];
        if (parseBackgroundReply(body)) |rgb| return .{ .key = .{ .background = rgb }, .consumed = consumed };
        return .{ .key = .osc_reply, .consumed = consumed };
    }
    return .{ .key = .osc_reply, .consumed = bytes.len };
}

/// `11;rgb:RRRR/GGGG/BBBB` (xterm's format — 1 to 4 hex digits a channel,
/// scaled to 8 bits) or `11;#RRGGBB`. Null when it is not a colour report.
fn parseBackgroundReply(body: []const u8) ?Rgb {
    if (!std.mem.startsWith(u8, body, "11;")) return null;
    const spec = body[3..];
    if (std.mem.startsWith(u8, spec, "rgb:")) {
        var it = std.mem.splitScalar(u8, spec[4..], '/');
        var out: [3]u8 = undefined;
        for (&out) |*ch| ch.* = scaleHexChannel(it.next() orelse return null) orelse return null;
        if (it.next() != null) return null; // more than three channels: not this
        return .{ .r = out[0], .g = out[1], .b = out[2] };
    }
    if (spec.len == 7 and spec[0] == '#') {
        var out: [3]u8 = undefined;
        for (&out, 0..) |*ch, i| ch.* = std.fmt.parseInt(u8, spec[1 + i * 2 ..][0..2], 16) catch return null;
        return .{ .r = out[0], .g = out[1], .b = out[2] };
    }
    return null;
}

/// One `rgb:` channel to 8 bits. The width carries the scale: `f` is full
/// intensity just as `ffff` is, so a 1-digit channel is not simply truncated.
fn scaleHexChannel(text: []const u8) ?u8 {
    if (text.len == 0 or text.len > 4) return null;
    const v = std.fmt.parseInt(u16, text, 16) catch return null;
    const max: u32 = (@as(u32, 1) << @intCast(4 * text.len)) - 1;
    return @intCast((@as(u32, v) * 255 + max / 2) / max);
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
    const wheel = b & 64 != 0;
    if (wheel) {
        if (final != 'M') return .{ .key = .mouse_other, .consumed = consumed }; // a tilt release
        if (b & 2 != 0) return .{ .key = .mouse_other, .consumed = consumed }; // horizontal tilt
    } else if (b & 3 != 0) return .{ .key = .mouse_other, .consumed = consumed }; // middle/right/"no button"
    // The wheel carries coordinates too: the notch scrolls the window under
    // the pointer, so they have to survive the decode.
    const col = std.fmt.parseInt(u16, it.next() orelse "", 10) catch return .{ .key = .mouse_other, .consumed = consumed };
    const row = std.fmt.parseInt(u16, it.next() orelse "", 10) catch return .{ .key = .mouse_other, .consumed = consumed };
    const m: Mouse = .{ .row = row, .col = col };
    if (wheel) return .{ .key = if (b & 1 != 0) .{ .scroll_down = m } else .{ .scroll_up = m }, .consumed = consumed };
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
    // Ctrl-` / Ctrl-Space / Ctrl-@ all arrive as NUL.
    try std.testing.expectEqual(Key{ .ctrl = ' ' }, decode(&[_]u8{0x00}).key);
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
    // The notch's cell decides which window scrolls, so the coordinates must
    // survive the wheel branch — they used to be parsed below it.
    const up = decode("\x1b[<64;10;5M");
    try std.testing.expectEqual(@as(u16, 10), up.key.scroll_up.col);
    try std.testing.expectEqual(@as(u16, 5), up.key.scroll_up.row);
    try std.testing.expectEqual(@as(usize, 11), up.consumed);
    const down = decode("\x1b[<65;1;1M");
    try std.testing.expectEqual(@as(u16, 1), down.key.scroll_down.col);
    try std.testing.expectEqual(@as(u16, 1), down.key.scroll_down.row);
    // The wheel sends no release, but the horizontal tilt axis does — a
    // wheel branch keyed on bit 6 alone would scroll vertically, twice.
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<64;5;5m").key);
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<66;5;5M").key); // tilt left
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<67;5;5m").key); // tilt right release
    // A wheel report with no coordinates cannot say which window to scroll.
    try std.testing.expectEqual(Key.mouse_other, decode("\x1b[<64;5M").key);
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

test "an OSC background reply decodes to the colour, not to Esc and text" {
    // The bug this exists to stop: `ESC ]` used to decode as the Escape key,
    // leaving `11;rgb:...` to be typed into the buffer as ordinary characters.
    const d = decode("\x1b]11;rgb:1a1a/1b1b/2626\x1b\\");
    try std.testing.expectEqual(Key{ .background = .{ .r = 0x1a, .g = 0x1b, .b = 0x26 } }, d.key);
    try std.testing.expectEqual(@as(usize, 25), d.consumed);
}

test "a BEL-terminated reply works the same as an ST-terminated one" {
    const d = decode("\x1b]11;rgb:1a1a/1b1b/2626\x07");
    try std.testing.expectEqual(Key{ .background = .{ .r = 0x1a, .g = 0x1b, .b = 0x26 } }, d.key);
    try std.testing.expectEqual(@as(usize, 24), d.consumed);
}

test "short channels scale rather than truncate" {
    // `f` is full intensity, as `ffff` is — truncating would read it as 15.
    try std.testing.expectEqual(Key{ .background = .{ .r = 255, .g = 0, .b = 136 } }, decode("\x1b]11;rgb:f/0/8\x07").key);
    try std.testing.expectEqual(Key{ .background = .{ .r = 0x12, .g = 0x34, .b = 0x56 } }, decode("\x1b]11;#123456\x07").key);
}

test "another OSC reply is swallowed whole" {
    const d = decode("\x1b]10;rgb:c0c0/c0c0/c0c0\x1b\\rest");
    try std.testing.expectEqual(Key.osc_reply, d.key);
    try std.testing.expectEqual(@as(usize, 25), d.consumed); // `rest` is left for the next decode
}

test "a malformed colour reply is inert rather than a wrong colour" {
    try std.testing.expectEqual(Key.osc_reply, decode("\x1b]11;rgb:zz/00/00\x07").key);
    try std.testing.expectEqual(Key.osc_reply, decode("\x1b]11;rgb:11/22\x07").key);
    try std.testing.expectEqual(Key.osc_reply, decode("\x1b]11;rgb:1/2/3/4\x07").key);
    try std.testing.expectEqual(Key.osc_reply, decode("\x1b]11;plum\x07").key);
}

test "an unterminated reply consumes the buffer instead of leaking text" {
    const d = decode("\x1b]11;rgb:1a1a/1b1b");
    try std.testing.expectEqual(Key.osc_reply, d.key);
    try std.testing.expectEqual(@as(usize, 18), d.consumed);
}

test "Ctrl-h and Ctrl-j are distinct from Backspace and Enter" {
    // A terminal sends 0x7f for Backspace and 0x0d for Enter, so binding
    // <C-h>/<C-j> costs neither of them.
    try std.testing.expectEqual(Key{ .ctrl = 'h' }, decode(&[_]u8{0x08}).key);
    try std.testing.expectEqual(Key{ .ctrl = 'j' }, decode(&[_]u8{0x0a}).key);
    try std.testing.expectEqual(Key.backspace, decode(&[_]u8{0x7f}).key);
    try std.testing.expectEqual(Key.enter, decode(&[_]u8{0x0d}).key);
    try std.testing.expectEqual(Key{ .ctrl = 'k' }, decode(&[_]u8{0x0b}).key);
    try std.testing.expectEqual(Key{ .ctrl = 'l' }, decode(&[_]u8{0x0c}).key);
}

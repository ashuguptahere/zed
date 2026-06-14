//! UTF-8 decoding and terminal display-width helpers.
//!
//! The editor stores text as raw UTF-8 bytes. Cursor movement and rendering,
//! however, operate on *codepoints* and their on-screen *width*. These helpers
//! bridge the two without ever crashing on malformed input: an invalid byte is
//! treated as a single-width replacement so a broken file is still editable.

const std = @import("std");

/// A decoded codepoint together with how many bytes it consumed.
pub const Decoded = struct {
    cp: u21,
    len: u3,
};

/// Number of bytes in the UTF-8 sequence that starts with `first`.
/// Returns 1 for an invalid lead byte so callers can always make progress.
pub fn sequenceLen(first: u8) u3 {
    return std.unicode.utf8ByteSequenceLength(first) catch 1;
}

/// Decode the codepoint at the start of `bytes`.
///
/// `bytes` must be non-empty. Malformed sequences decode to the replacement
/// character U+FFFD with a length of 1, guaranteeing forward progress.
pub fn decode(bytes: []const u8) Decoded {
    std.debug.assert(bytes.len > 0);
    const len = sequenceLen(bytes[0]);
    if (len == 1 or len > bytes.len) {
        if (bytes[0] < 0x80) return .{ .cp = bytes[0], .len = 1 };
        return .{ .cp = 0xFFFD, .len = 1 };
    }
    const cp = std.unicode.utf8Decode(bytes[0..len]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = len };
}

/// Byte offset of the codepoint boundary `n` codepoints to the right of `off`.
/// Stops at the end of the slice.
pub fn nextBoundary(bytes: []const u8, off: usize) usize {
    if (off >= bytes.len) return bytes.len;
    return off + decode(bytes[off..]).len;
}

/// Byte offset of the codepoint boundary one codepoint to the left of `off`.
/// Walks back over UTF-8 continuation bytes (0b10xx_xxxx).
pub fn prevBoundary(bytes: []const u8, off: usize) usize {
    if (off == 0) return 0;
    var i = off - 1;
    while (i > 0 and isContinuation(bytes[i])) : (i -= 1) {}
    return i;
}

fn isContinuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

/// Terminal display width of a codepoint in cells: 0, 1, or 2.
///
/// This is a compact approximation of POSIX `wcwidth`: combining and
/// zero-width marks render in 0 cells, East-Asian wide and most emoji in 2,
/// everything else in 1. Control characters are the caller's concern.
pub fn width(cp: u21) u8 {
    if (cp == 0) return 0;
    if (isZeroWidth(cp)) return 0;
    if (isWide(cp)) return 2;
    return 1;
}

/// Total display width of a UTF-8 slice (sum of per-codepoint widths).
pub fn displayWidth(bytes: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const d = decode(bytes[i..]);
        total += width(d.cp);
        i += d.len;
    }
    return total;
}

fn isZeroWidth(cp: u21) bool {
    return switch (cp) {
        0x0300...0x036F, // combining diacritical marks
        0x0483...0x0489,
        0x0591...0x05BD,
        0x0610...0x061A,
        0x064B...0x065F,
        0x0670,
        0x06D6...0x06DC,
        0x0E31,
        0x0E34...0x0E3A,
        0x1AB0...0x1AFF, // combining diacritical marks extended
        0x1DC0...0x1DFF, // combining diacritical marks supplement
        0x200B...0x200F, // zero-width space / joiners / marks
        0x202A...0x202E, // bidi controls
        0x20D0...0x20FF, // combining marks for symbols
        0xFE00...0xFE0F, // variation selectors
        0xFE20...0xFE2F, // combining half marks
        0xFEFF, // zero-width no-break space (BOM)
        => true,
        else => false,
    };
}

fn isWide(cp: u21) bool {
    return switch (cp) {
        0x1100...0x115F, // Hangul Jamo
        0x2329...0x232A, // angle brackets
        0x2E80...0x303E, // CJK radicals, Kangxi, punctuation
        0x3041...0x33FF, // Hiragana .. CJK compatibility
        0x3400...0x4DBF, // CJK extension A
        0x4E00...0x9FFF, // CJK unified ideographs
        0xA000...0xA4CF, // Yi
        0xAC00...0xD7A3, // Hangul syllables
        0xF900...0xFAFF, // CJK compatibility ideographs
        0xFE30...0xFE4F, // CJK compatibility forms
        0xFF00...0xFF60, // fullwidth forms
        0xFFE0...0xFFE6, // fullwidth signs
        0x1F300...0x1FAFF, // symbols & pictographs, emoji
        0x20000...0x3FFFD, // CJK extension B and beyond
        => true,
        else => false,
    };
}

test "decode ascii" {
    const d = decode("A");
    try std.testing.expectEqual(@as(u21, 'A'), d.cp);
    try std.testing.expectEqual(@as(u3, 1), d.len);
}

test "decode multibyte" {
    const d = decode("é"); // U+00E9, two bytes
    try std.testing.expectEqual(@as(u21, 0x00E9), d.cp);
    try std.testing.expectEqual(@as(u3, 2), d.len);
}

test "decode invalid byte makes progress" {
    const bad = [_]u8{0xFF};
    const d = decode(&bad);
    try std.testing.expectEqual(@as(u21, 0xFFFD), d.cp);
    try std.testing.expectEqual(@as(u3, 1), d.len);
}

test "boundaries round-trip" {
    const s = "aé世"; // 1 + 2 + 3 bytes
    try std.testing.expectEqual(@as(usize, 1), nextBoundary(s, 0));
    try std.testing.expectEqual(@as(usize, 3), nextBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 6), nextBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 3), prevBoundary(s, 6));
    try std.testing.expectEqual(@as(usize, 1), prevBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 0), prevBoundary(s, 1));
}

test "display width" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth("a"));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("世")); // wide CJK
    try std.testing.expectEqual(@as(usize, 1), displayWidth("é"));
    try std.testing.expectEqual(@as(usize, 0), width(0x0301)); // combining acute
}

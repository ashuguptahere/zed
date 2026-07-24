//! The text buffer: an editable document held as a list of lines.
//!
//! Loading is zero-copy: the file's bytes are kept in one shared `source`
//! buffer and every line starts as a *borrowed* slice into it — so opening a
//! 200k-line file is a single allocation plus a newline scan, not 200k line
//! copies. A line converts to *owned* heap storage on its first mutation
//! (copy-on-write); splitting a borrowed line just splits the slice. This is
//! the pragmatic answer to large-file open times (see `zig build bench`); a
//! full rope stays on the table if per-edit costs ever show up in profiles.
//!
//! All offsets into a line are byte offsets that the editor keeps on UTF-8
//! codepoint boundaries; edits insert and remove whole codepoints.

const std = @import("std");
const unicode = @import("unicode.zig");
const Allocator = std.mem.Allocator;

/// Hard cap on the size of a file we will load, to fail loudly rather than
/// exhaust memory on a pathological input.
pub const max_file_bytes = 2 * 1024 * 1024 * 1024;

/// One line: a zero-copy slice of the buffer's `source`, or (after its first
/// mutation) heap bytes of its own.
pub const Line = union(enum) {
    borrowed: []const u8,
    owned: std.ArrayList(u8),

    pub fn bytes(l: *const Line) []const u8 {
        return switch (l.*) {
            .borrowed => |s| s,
            .owned => |a| a.items,
        };
    }

    fn free(l: *Line, gpa: Allocator) void {
        switch (l.*) {
            .owned => |*a| a.deinit(gpa),
            .borrowed => {},
        }
    }
};

/// Where a backspace/join left the cursor.
pub const Pos = struct { row: usize, col: usize };

pub const Buffer = struct {
    gpa: Allocator,
    lines: std.ArrayList(Line),
    /// The loaded file bytes that borrowed lines slice into (null for buffers
    /// that never loaded anything). Freed only in deinit/replaceContents, so
    /// borrowed slices stay valid for the buffer's whole life.
    source: ?[]u8,
    path: ?[]u8,
    dirty: bool,
    /// Bumped on every content mutation; lets observers (LSP, tree-sitter)
    /// cheaply detect when a resync is needed.
    revision: u64,
    /// Whether the on-disk file ends with a trailing newline; preserved on save.
    final_newline: bool,
    /// True when the document is genuinely empty (new/0-byte buffer, or every
    /// line was deleted) as opposed to one line whose text was emptied. Matches
    /// vim: `ggVGd` then `:w` writes 0 bytes, but `d$` on a one-line file
    /// writes "\n". Cleared by any text insertion.
    emptied: bool,
    /// True while every line is still a borrowed slice of `source` in file
    /// order — the state right after a load. Search uses this to scan the
    /// whole source in one pass instead of line by line (see search.zig).
    pure_borrowed: bool,
    /// Whether the loaded file had CRLF line endings (the fast search path
    /// bows out then, since line slices exclude the stripped '\r').
    has_cr: bool,

    pub fn initEmpty(gpa: Allocator) !Buffer {
        var lines: std.ArrayList(Line) = .empty;
        try lines.append(gpa, .{ .borrowed = &.{} });
        // New buffers follow the POSIX convention: once they hold content they
        // are saved with a trailing newline. A still-empty buffer writes 0 bytes.
        return .{ .gpa = gpa, .lines = lines, .source = null, .path = null, .dirty = false, .revision = 0, .final_newline = true, .emptied = true, .pure_borrowed = false, .has_cr = false };
    }

    pub fn deinit(self: *Buffer) void {
        for (self.lines.items) |*l| l.free(self.gpa);
        self.lines.deinit(self.gpa);
        if (self.source) |s| self.gpa.free(s);
        if (self.path) |p| self.gpa.free(p);
        self.* = undefined;
    }

    /// Build a buffer from in-memory bytes (copied once into `source`; lines
    /// borrow from it). Splits on '\n' and tolerates CRLF by shrinking a
    /// trailing '\r' out of each line's slice.
    pub fn fromBytes(gpa: Allocator, data: []const u8) !Buffer {
        const source: ?[]u8 = if (data.len > 0) try gpa.dupe(u8, data) else null;
        errdefer if (source) |s| gpa.free(s);
        return fromSource(gpa, source);
    }

    /// Like `fromBytes` but takes ownership of `data` (no copy) — the fast
    /// path `load` uses so a big file is read exactly once.
    pub fn fromOwnedBytes(gpa: Allocator, data: []u8) !Buffer {
        const source: ?[]u8 = if (data.len > 0) data else null;
        if (data.len == 0) gpa.free(data);
        errdefer if (source) |s| gpa.free(s);
        return fromSource(gpa, source);
    }

    fn fromSource(gpa: Allocator, source: ?[]u8) !Buffer {
        var lines: std.ArrayList(Line) = .empty;
        errdefer lines.deinit(gpa);

        const src: []const u8 = source orelse &.{};
        // Estimate the line count (~40 bytes/line) to make growth rare, but
        // keep a single pass — a separate exact count pass costs ~25% of the
        // whole parse on huge files.
        try lines.ensureTotalCapacity(gpa, src.len / 40 + 1);
        // One vectorized pass over the bytes: per-line `indexOf` calls cost
        // more in call overhead than the search itself on short lines
        // (measured ~3x slower on a 200k-line file).
        const vlen = 32;
        const nl_splat: @Vector(vlen, u8) = @splat('\n');
        var start: usize = 0;
        var i: usize = 0;
        var has_cr = false;
        while (i + vlen <= src.len) : (i += vlen) {
            const chunk: @Vector(vlen, u8) = src[i..][0..vlen].*;
            var mask: u32 = @bitCast(chunk == nl_splat);
            while (mask != 0) {
                const nl = i + @ctz(mask);
                const stripped = stripCr(src[start..nl]);
                has_cr = has_cr or stripped.len != nl - start;
                try lines.append(gpa, .{ .borrowed = stripped });
                start = nl + 1;
                mask &= mask - 1; // clear the lowest set bit
            }
        }
        while (i < src.len) : (i += 1) {
            if (src[i] == '\n') {
                const stripped = stripCr(src[start..i]);
                has_cr = has_cr or stripped.len != i - start;
                try lines.append(gpa, .{ .borrowed = stripped });
                start = i + 1;
            }
        }
        var final_newline = true;
        if (start < src.len) {
            // Trailing text after the last newline: no final newline on disk.
            try lines.append(gpa, .{ .borrowed = stripCr(src[start..]) });
            final_newline = false;
        }
        const was_empty = lines.items.len == 0;
        if (was_empty) try lines.append(gpa, .{ .borrowed = &.{} });

        return .{ .gpa = gpa, .lines = lines, .source = source, .path = null, .dirty = false, .revision = 0, .final_newline = final_newline, .emptied = was_empty, .pure_borrowed = source != null, .has_cr = has_cr };
    }

    /// Load `path` into a new buffer. A missing file yields an empty buffer
    /// already named `path`, matching the familiar "open to create" behaviour.
    pub fn load(gpa: Allocator, io: std.Io, path: []const u8) !Buffer {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => {
                var b = try initEmpty(gpa);
                b.path = try gpa.dupe(u8, path);
                return b;
            },
            else => return err,
        };
        var b = try fromOwnedBytes(gpa, data);
        b.path = try gpa.dupe(u8, path);
        return b;
    }

    /// Serialise the buffer back to bytes, restoring line endings and the
    /// original trailing-newline convention. Caller owns the result.
    pub fn toBytes(self: *const Buffer, gpa: Allocator) ![]u8 {
        // A genuinely empty document writes 0 bytes; a single line whose text
        // was merely emptied still writes its "\n" (vim semantics).
        if (self.emptied and self.lines.items.len == 1 and self.lines.items[0].bytes().len == 0) {
            return gpa.alloc(u8, 0);
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (self.lines.items, 0..) |*ln, idx| {
            try out.appendSlice(gpa, ln.bytes());
            const last = idx + 1 == self.lines.items.len;
            if (!last or self.final_newline) try out.append(gpa, '\n');
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn save(self: *Buffer, io: std.Io) !void {
        const path = self.path orelse return error.NoFileName;
        const data = try self.toBytes(self.gpa);
        defer self.gpa.free(data);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
        self.dirty = false;
    }

    pub fn setPath(self: *Buffer, path: []const u8) !void {
        const dup = try self.gpa.dupe(u8, path);
        if (self.path) |p| self.gpa.free(p);
        self.path = dup;
    }

    pub fn lineCount(self: *const Buffer) usize {
        return self.lines.items.len;
    }

    pub fn line(self: *const Buffer, row: usize) []const u8 {
        return self.lines.items[row].bytes();
    }

    /// The row's bytes as mutable storage (converting a borrowed line to owned
    /// first) — for same-length in-place edits like case toggling.
    pub fn lineMut(self: *Buffer, row: usize) ![]u8 {
        const l = try self.toOwned(row);
        return l.items;
    }

    /// Ensure the line owns its bytes (copy-on-write conversion).
    fn toOwned(self: *Buffer, row: usize) !*std.ArrayList(u8) {
        const l = &self.lines.items[row];
        switch (l.*) {
            .owned => |*a| return a,
            .borrowed => |s| {
                var a: std.ArrayList(u8) = .empty;
                errdefer a.deinit(self.gpa);
                try a.appendSlice(self.gpa, s);
                l.* = .{ .owned = a };
                self.pure_borrowed = false;
                return &l.owned;
            },
        }
    }

    // --- editing -----------------------------------------------------------

    /// Insert one codepoint at (row, col). Returns the new column (col + bytes).
    pub fn insertCodepoint(self: *Buffer, row: usize, col: usize, cp: u21) !usize {
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc) catch return col;
        const l = try self.toOwned(row);
        try l.insertSlice(self.gpa, col, enc[0..n]);
        self.emptied = false;
        self.dirty = true;
        self.revision +%= 1;
        return col + n;
    }

    /// Split the line at (row, col) into two, as the Enter key does. A
    /// borrowed line splits into two borrowed slices — no copies.
    pub fn splitLine(self: *Buffer, row: usize, col: usize) !void {
        switch (self.lines.items[row]) {
            .borrowed => |s| {
                try self.lines.insert(self.gpa, row + 1, .{ .borrowed = s[col..] });
                self.lines.items[row] = .{ .borrowed = s[0..col] };
            },
            .owned => |*a| {
                var new_line: std.ArrayList(u8) = .empty;
                errdefer new_line.deinit(self.gpa);
                try new_line.appendSlice(self.gpa, a.items[col..]);
                try self.lines.insert(self.gpa, row + 1, .{ .owned = new_line });
                // The insert may have moved the array; re-fetch before truncating.
                self.lines.items[row].owned.items.len = col;
                self.pure_borrowed = false;
            },
        }
        self.emptied = false;
        self.dirty = true;
        self.revision +%= 1;
    }

    /// Delete the codepoint at (row, col). At end-of-line, join the next line.
    pub fn deleteForward(self: *Buffer, row: usize, col: usize) !void {
        if (col < self.lines.items[row].bytes().len) {
            const cur = try self.toOwned(row);
            const len = unicode.decode(cur.items[col..]).len;
            try cur.replaceRange(self.gpa, col, len, &[_]u8{});
            self.dirty = true;
            self.revision +%= 1;
        } else if (row + 1 < self.lines.items.len) {
            var next = self.lines.orderedRemove(row + 1);
            defer next.free(self.gpa);
            const cur = try self.toOwned(row);
            try cur.appendSlice(self.gpa, next.bytes());
            self.dirty = true;
            self.revision +%= 1;
        }
    }

    /// Delete the codepoint before (row, col). At column 0, join onto the
    /// previous line. Returns the resulting cursor position.
    pub fn deleteBackward(self: *Buffer, row: usize, col: usize) !Pos {
        if (col > 0) {
            const cur = try self.toOwned(row);
            const prev = unicode.prevBoundary(cur.items, col);
            try cur.replaceRange(self.gpa, prev, col - prev, &[_]u8{});
            self.dirty = true;
            self.revision +%= 1;
            return .{ .row = row, .col = prev };
        }
        if (row == 0) return .{ .row = 0, .col = 0 };
        var cur = self.lines.orderedRemove(row);
        defer cur.free(self.gpa);
        const prev = try self.toOwned(row - 1);
        const new_col = prev.items.len;
        try prev.appendSlice(self.gpa, cur.bytes());
        self.dirty = true;
        self.revision +%= 1;
        return .{ .row = row - 1, .col = new_col };
    }

    /// Replace the whole document with freshly-parsed `data`, keeping the path.
    /// Used by undo/redo to restore a snapshot.
    pub fn replaceContents(self: *Buffer, data: []const u8) !void {
        const tmp = try fromBytes(self.gpa, data);
        for (self.lines.items) |*l| l.free(self.gpa);
        self.lines.deinit(self.gpa);
        if (self.source) |s| self.gpa.free(s);
        self.lines = tmp.lines; // take ownership; tmp.path is null
        self.source = tmp.source;
        self.final_newline = tmp.final_newline;
        self.emptied = tmp.emptied;
        self.pure_borrowed = tmp.pure_borrowed;
        self.has_cr = tmp.has_cr;
        self.revision +%= 1;
    }

    /// Insert raw bytes into a line at a byte offset.
    pub fn insertBytes(self: *Buffer, row: usize, col: usize, bytes: []const u8) !void {
        const l = try self.toOwned(row);
        try l.insertSlice(self.gpa, col, bytes);
        self.emptied = false;
        self.dirty = true;
        self.revision +%= 1;
    }

    /// Remove bytes [start, end) from a line.
    pub fn deleteInLine(self: *Buffer, row: usize, start: usize, end: usize) !void {
        if (end <= start) return;
        const l = try self.toOwned(row);
        try l.replaceRange(self.gpa, start, end - start, &[_]u8{});
        self.dirty = true;
        self.revision +%= 1;
    }

    /// Replace a line's entire content.
    pub fn setLine(self: *Buffer, row: usize, bytes: []const u8) !void {
        const l = try self.toOwned(row);
        l.clearRetainingCapacity();
        try l.appendSlice(self.gpa, bytes);
        self.emptied = false;
        self.dirty = true;
        self.revision +%= 1;
    }

    /// Insert a new line (copying `bytes`) at index `at`.
    pub fn insertLineAt(self: *Buffer, at: usize, bytes: []const u8) !void {
        var new_line: std.ArrayList(u8) = .empty;
        errdefer new_line.deinit(self.gpa);
        try new_line.appendSlice(self.gpa, bytes);
        try self.lines.insert(self.gpa, at, .{ .owned = new_line });
        self.pure_borrowed = false;
        self.emptied = false;
        self.dirty = true;
        self.revision +%= 1;
    }

    /// Remove line `at`, always leaving at least one (empty) line.
    pub fn removeLineAt(self: *Buffer, at: usize) void {
        var removed = self.lines.orderedRemove(at);
        removed.free(self.gpa);
        if (self.lines.items.len == 0) {
            self.lines.append(self.gpa, .{ .borrowed = &.{} }) catch {};
            self.emptied = true; // every line deleted -> truly empty document
        }
        self.dirty = true;
        self.revision +%= 1;
    }

    fn stripCr(s: []const u8) []const u8 {
        if (s.len > 0 and s[s.len - 1] == '\r') return s[0 .. s.len - 1];
        return s;
    }
};

test "fromBytes splits lines and tracks final newline" {
    const gpa = std.testing.allocator;
    var b = try Buffer.fromBytes(gpa, "alpha\nbeta\n");
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 2), b.lineCount());
    try std.testing.expectEqualStrings("alpha", b.line(0));
    try std.testing.expectEqualStrings("beta", b.line(1));
    try std.testing.expect(b.final_newline);
}

test "fromBytes handles CRLF and no trailing newline" {
    const gpa = std.testing.allocator;
    var b = try Buffer.fromBytes(gpa, "a\r\nb");
    defer b.deinit();
    try std.testing.expectEqualStrings("a", b.line(0));
    try std.testing.expectEqualStrings("b", b.line(1));
    try std.testing.expect(!b.final_newline);
}

test "empty input yields one empty line" {
    const gpa = std.testing.allocator;
    var b = try Buffer.fromBytes(gpa, "");
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 1), b.lineCount());
    try std.testing.expectEqualStrings("", b.line(0));
}

test "round trips through toBytes" {
    const gpa = std.testing.allocator;
    const inputs = [_][]const u8{ "alpha\nbeta\n", "a\nb", "", "one\n\ntwo\n" };
    for (inputs) |input| {
        var b = try Buffer.fromBytes(gpa, input);
        defer b.deinit();
        const out = try b.toBytes(gpa);
        defer gpa.free(out);
        // CRLF normalises to LF, so compare against an LF-only expectation.
        try std.testing.expectEqualStrings(input, out);
    }
}

test "insert and delete codepoints" {
    const gpa = std.testing.allocator;
    var b = try Buffer.fromBytes(gpa, "ac");
    defer b.deinit();
    const col = try b.insertCodepoint(0, 1, 'b');
    try std.testing.expectEqual(@as(usize, 2), col);
    try std.testing.expectEqualStrings("abc", b.line(0));

    const pos = try b.deleteBackward(0, 2);
    try std.testing.expectEqual(@as(usize, 1), pos.col);
    try std.testing.expectEqualStrings("ac", b.line(0));

    try b.deleteForward(0, 0);
    try std.testing.expectEqualStrings("c", b.line(0));
}

test "split and join lines" {
    const gpa = std.testing.allocator;
    var b = try Buffer.fromBytes(gpa, "hello world");
    defer b.deinit();
    try b.splitLine(0, 5);
    try std.testing.expectEqual(@as(usize, 2), b.lineCount());
    try std.testing.expectEqualStrings("hello", b.line(0));
    try std.testing.expectEqualStrings(" world", b.line(1));

    // Backspace at column 0 of line 1 joins it back.
    const pos = try b.deleteBackward(1, 0);
    try std.testing.expectEqual(Pos{ .row = 0, .col = 5 }, pos);
    try std.testing.expectEqualStrings("hello world", b.line(0));
}

test "copy-on-write: editing one borrowed line leaves the rest borrowed" {
    const gpa = std.testing.allocator;
    var b = try Buffer.fromBytes(gpa, "one\ntwo\nthree\n");
    defer b.deinit();
    try std.testing.expect(b.lines.items[1] == .borrowed);
    _ = try b.insertCodepoint(1, 0, 'X');
    try std.testing.expectEqualStrings("Xtwo", b.line(1));
    try std.testing.expect(b.lines.items[1] == .owned);
    // Neighbours stayed zero-copy and unchanged.
    try std.testing.expect(b.lines.items[0] == .borrowed);
    try std.testing.expect(b.lines.items[2] == .borrowed);
    try std.testing.expectEqualStrings("one", b.line(0));
    try std.testing.expectEqualStrings("three", b.line(2));
}

test "splitting a borrowed line stays zero-copy and round-trips" {
    const gpa = std.testing.allocator;
    var b = try Buffer.fromBytes(gpa, "hello world\n");
    defer b.deinit();
    try b.splitLine(0, 5);
    try std.testing.expect(b.lines.items[0] == .borrowed);
    try std.testing.expect(b.lines.items[1] == .borrowed);
    const out = try b.toBytes(gpa);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("hello\n world\n", out);
}

test "join across borrowed and owned lines" {
    const gpa = std.testing.allocator;
    var b = try Buffer.fromBytes(gpa, "aaa\nbbb\n");
    defer b.deinit();
    _ = try b.insertCodepoint(0, 3, '!'); // line 0 becomes owned
    try b.deleteForward(0, 4); // join borrowed line 1 onto it
    try std.testing.expectEqualStrings("aaa!bbb", b.line(0));
    try std.testing.expectEqual(@as(usize, 1), b.lineCount());
}

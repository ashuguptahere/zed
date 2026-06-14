//! The text buffer: an editable document held as a list of lines.
//!
//! A line-array is the simplest representation that supports everything v0
//! needs (insertion, deletion, line splits/joins) with clear code. A rope or
//! gap buffer would scale to very large files better and is the natural next
//! step, but would be premature now.
//!
//! All offsets into a line are byte offsets that the editor keeps on UTF-8
//! codepoint boundaries; edits insert and remove whole codepoints.

const std = @import("std");
const unicode = @import("unicode.zig");
const Allocator = std.mem.Allocator;

/// Hard cap on the size of a file we will load, to fail loudly rather than
/// exhaust memory on a pathological input.
pub const max_file_bytes = 256 * 1024 * 1024;

pub const Line = std.ArrayList(u8);

/// Where a backspace/join left the cursor.
pub const Pos = struct { row: usize, col: usize };

pub const Buffer = struct {
    gpa: Allocator,
    lines: std.ArrayList(Line),
    path: ?[]u8,
    dirty: bool,
    /// Whether the on-disk file ends with a trailing newline; preserved on save.
    final_newline: bool,

    pub fn initEmpty(gpa: Allocator) !Buffer {
        var lines: std.ArrayList(Line) = .empty;
        try lines.append(gpa, .empty);
        // New buffers follow the POSIX convention: once they hold content they
        // are saved with a trailing newline. A still-empty buffer writes 0 bytes.
        return .{ .gpa = gpa, .lines = lines, .path = null, .dirty = false, .final_newline = true };
    }

    pub fn deinit(self: *Buffer) void {
        for (self.lines.items) |*l| l.deinit(self.gpa);
        self.lines.deinit(self.gpa);
        if (self.path) |p| self.gpa.free(p);
        self.* = undefined;
    }

    /// Build a buffer from in-memory bytes. Splits on '\n' and tolerates CRLF
    /// by stripping a trailing '\r' from each line.
    pub fn fromBytes(gpa: Allocator, data: []const u8) !Buffer {
        var lines: std.ArrayList(Line) = .empty;
        errdefer {
            for (lines.items) |*l| l.deinit(gpa);
            lines.deinit(gpa);
        }

        var start: usize = 0;
        var i: usize = 0;
        while (i < data.len) : (i += 1) {
            if (data[i] == '\n') {
                try appendCopy(gpa, &lines, stripCr(data[start..i]));
                start = i + 1;
            }
        }
        var final_newline = false;
        if (start < data.len) {
            // Trailing text after the last newline: no final newline on disk.
            try appendCopy(gpa, &lines, stripCr(data[start..]));
        } else {
            // Data ended on a newline, or is empty; either way new content
            // should keep ending with a newline.
            final_newline = true;
        }
        if (lines.items.len == 0) try lines.append(gpa, .empty);

        return .{ .gpa = gpa, .lines = lines, .path = null, .dirty = false, .final_newline = final_newline };
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
        defer gpa.free(data);
        var b = try fromBytes(gpa, data);
        b.path = try gpa.dupe(u8, path);
        return b;
    }

    /// Serialise the buffer back to bytes, restoring line endings and the
    /// original trailing-newline convention. Caller owns the result.
    pub fn toBytes(self: *const Buffer, gpa: Allocator) ![]u8 {
        // A lone empty line is an empty document: write 0 bytes, not "\n".
        if (self.lines.items.len == 1 and self.lines.items[0].items.len == 0) {
            return gpa.alloc(u8, 0);
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (self.lines.items, 0..) |ln, idx| {
            try out.appendSlice(gpa, ln.items);
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
        return self.lines.items[row].items;
    }

    // --- editing -----------------------------------------------------------

    /// Insert one codepoint at (row, col). Returns the new column (col + bytes).
    pub fn insertCodepoint(self: *Buffer, row: usize, col: usize, cp: u21) !usize {
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc) catch return col;
        try self.lines.items[row].insertSlice(self.gpa, col, enc[0..n]);
        self.dirty = true;
        return col + n;
    }

    /// Split the line at (row, col) into two, as the Enter key does.
    pub fn splitLine(self: *Buffer, row: usize, col: usize) !void {
        const tail = self.lines.items[row].items[col..];
        var new_line: Line = .empty;
        errdefer new_line.deinit(self.gpa);
        try new_line.appendSlice(self.gpa, tail);
        try self.lines.insert(self.gpa, row + 1, new_line);
        self.lines.items[row].items.len = col; // truncate, keep capacity
        self.dirty = true;
    }

    /// Delete the codepoint at (row, col). At end-of-line, join the next line.
    pub fn deleteForward(self: *Buffer, row: usize, col: usize) !void {
        const cur = &self.lines.items[row];
        if (col < cur.items.len) {
            const len = unicode.decode(cur.items[col..]).len;
            try cur.replaceRange(self.gpa, col, len, &[_]u8{});
            self.dirty = true;
        } else if (row + 1 < self.lines.items.len) {
            var next = self.lines.orderedRemove(row + 1);
            defer next.deinit(self.gpa);
            try self.lines.items[row].appendSlice(self.gpa, next.items);
            self.dirty = true;
        }
    }

    /// Delete the codepoint before (row, col). At column 0, join onto the
    /// previous line. Returns the resulting cursor position.
    pub fn deleteBackward(self: *Buffer, row: usize, col: usize) !Pos {
        if (col > 0) {
            const cur = &self.lines.items[row];
            const prev = unicode.prevBoundary(cur.items, col);
            try cur.replaceRange(self.gpa, prev, col - prev, &[_]u8{});
            self.dirty = true;
            return .{ .row = row, .col = prev };
        }
        if (row == 0) return .{ .row = 0, .col = 0 };
        var cur = self.lines.orderedRemove(row);
        defer cur.deinit(self.gpa);
        const prev = &self.lines.items[row - 1];
        const new_col = prev.items.len;
        try prev.appendSlice(self.gpa, cur.items);
        self.dirty = true;
        return .{ .row = row - 1, .col = new_col };
    }

    fn appendCopy(gpa: Allocator, lines: *std.ArrayList(Line), bytes: []const u8) !void {
        var l: Line = .empty;
        errdefer l.deinit(gpa);
        try l.appendSlice(gpa, bytes);
        try lines.append(gpa, l);
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

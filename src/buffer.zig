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
const remote = @import("remote.zig");
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

/// A load that has only read its first chunk.
pub const Pending = struct {
    file: std.Io.File,
    filled: usize, // bytes of `source` that hold real data
    scan_from: usize, // byte the newline scan stopped at
};

/// Where a backspace/join left the cursor.
pub const Pos = struct { row: usize, col: usize };

pub const Buffer = struct {
    gpa: Allocator,
    /// Per-line storage. Empty while the buffer is still "lazy": until the
    /// first edit, lines are described purely by `offsets` into `source`.
    lines: std.ArrayList(Line),
    /// Set while only the head of the file has been read (see `loadPartial`).
    /// The whole file is allocated up front, so borrowed line slices stay
    /// valid as the tail lands; `loadRest` fills and indexes the remainder.
    pending: ?Pending = null,
    /// Lazy line index: byte offset of each line start in `source`, plus a
    /// trailing sentinel (so line i spans [offsets[i], offsets[i+1]-1)).
    /// Non-empty exactly while `lines` is unused — see `materialize`.
    offsets: std.ArrayList(u32) = .empty,
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

    /// Build the `lines` array from the lazy offset index. Called by the first
    /// operation that needs per-line storage — i.e. the first edit. Reading,
    /// searching, rendering and saving all work straight off the offsets, so a
    /// file opened to look at never pays for this.
    fn materialize(self: *Buffer) !void {
        if (self.offsets.items.len == 0) return; // already materialized
        const src = self.source orelse "";
        try self.lines.ensureTotalCapacity(self.gpa, self.offsets.items.len - 1);
        var i: usize = 0;
        while (i + 1 < self.offsets.items.len) : (i += 1) {
            const s = self.offsets.items[i];
            const e = self.offsets.items[i + 1];
            self.lines.appendAssumeCapacity(.{ .borrowed = stripCr(src[s .. e - 1]) });
        }
        self.offsets.clearRetainingCapacity();
    }

    /// True while the buffer is still described by the offset index alone.
    fn isLazy(self: *const Buffer) bool {
        return self.offsets.items.len != 0;
    }

    pub fn initEmpty(gpa: Allocator) !Buffer {
        var lines: std.ArrayList(Line) = .empty;
        try lines.append(gpa, .{ .borrowed = &.{} });
        // New buffers follow the POSIX convention: once they hold content they
        // are saved with a trailing newline. A still-empty buffer writes 0 bytes.
        return .{ .gpa = gpa, .lines = lines, .offsets = .empty, .source = null, .path = null, .dirty = false, .revision = 0, .final_newline = true, .emptied = true, .pure_borrowed = false, .has_cr = false };
    }

    pub fn deinit(self: *Buffer) void {
        self.offsets.deinit(self.gpa);
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
        // Lazy index: one u32 offset per line (plus an end sentinel) instead of
        // a 32-byte tagged union each — 8x less memory written at open, which
        // is most of what opening a large file costs. `materialize` turns this
        // into real `Line`s the first time something edits.
        var offsets: std.ArrayList(u32) = .empty;
        errdefer offsets.deinit(gpa);
        // Estimate the line count (~40 bytes/line) to make growth rare, but
        // keep a single pass — a separate exact count pass costs ~25% of the
        // whole parse on huge files.
        try offsets.ensureTotalCapacity(gpa, src.len / 40 + 2);
        try offsets.append(gpa, 0);
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
                has_cr = has_cr or (nl > start and src[nl - 1] == '\r');
                try offsets.append(gpa, @intCast(nl + 1));
                start = nl + 1;
                mask &= mask - 1; // clear the lowest set bit
            }
        }
        while (i < src.len) : (i += 1) {
            if (src[i] == '\n') {
                has_cr = has_cr or (i > start and src[i - 1] == '\r');
                try offsets.append(gpa, @intCast(i + 1));
                start = i + 1;
            }
        }
        var final_newline = true;
        if (start < src.len) {
            // Trailing text after the last newline: no final newline on disk.
            try offsets.append(gpa, @intCast(src.len + 1)); // sentinel past the (absent) \n
            final_newline = false;
        }
        // `offsets` holds one entry per line start plus a trailing sentinel, so
        // a file with N lines has N+1 entries. Fewer than 2 means no lines.
        const was_empty = offsets.items.len < 2;
        if (was_empty) {
            offsets.clearRetainingCapacity();
            try lines.append(gpa, .{ .borrowed = &.{} });
        }

        return .{ .gpa = gpa, .lines = lines, .offsets = offsets, .source = source, .path = null, .dirty = false, .revision = 0, .final_newline = final_newline, .emptied = was_empty, .pure_borrowed = source != null, .has_cr = has_cr };
    }

    /// Read only the head of `path` and index the complete lines in it, so the
    /// first screen can be painted before the rest of the file has arrived —
    /// the one thing nvim still did sooner than us. The full file is allocated
    /// up front, so the borrowed line slices survive `loadRest` filling in the
    /// tail. Falls back to a plain load for remote paths and small files,
    /// where two-phase reading would only add syscalls.
    pub fn loadPartial(gpa: Allocator, io: std.Io, path: []const u8, head: usize) !Buffer {
        if (remote.parse(path) != null) return load(gpa, io, path);
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return load(gpa, io, path);
        var close_file = true;
        defer if (close_file) file.close(io);

        const st = file.stat(io) catch return load(gpa, io, path);
        const size = std.math.cast(usize, st.size) orelse return error.StreamTooLong;
        if (size > max_file_bytes) return error.StreamTooLong;
        if (size <= head) return load(gpa, io, path); // one read is enough

        const source = try gpa.alloc(u8, size);
        errdefer gpa.free(source);
        const got = file.readPositionalAll(io, source[0..head], 0) catch return load(gpa, io, path);
        // Index whole lines only; a trailing partial line waits for the tail.
        const cut = std.mem.lastIndexOfScalar(u8, source[0..got], '\n') orelse 0;

        // Index only the bytes that actually arrived. (Going through
        // `fromSource` here would scan the whole allocation — including the
        // uninitialised tail — and throw the result away.)
        var offsets: std.ArrayList(u32) = .empty;
        errdefer offsets.deinit(gpa);
        try indexRange(&offsets, gpa, source[0 .. cut + 1], 0);

        const b: Buffer = .{
            .gpa = gpa,
            .lines = .empty,
            .offsets = offsets,
            .pending = .{ .file = file, .filled = got, .scan_from = cut + 1 },
            .source = source,
            .path = try gpa.dupe(u8, path),
            .dirty = false,
            .revision = 0,
            .final_newline = true,
            .emptied = false,
            .pure_borrowed = true,
            .has_cr = std.mem.indexOfScalar(u8, source[0..got], '\r') != null,
        };
        close_file = false; // the buffer owns it until loadRest
        return b;
    }

    /// Finish a `loadPartial`: read the remainder and extend the line index.
    /// Safe to call when nothing is pending.
    pub fn loadRest(self: *Buffer, io: std.Io) !void {
        const p = self.pending orelse return;
        self.pending = null;
        defer p.file.close(io);
        const source = self.source orelse return;
        if (p.filled < source.len) {
            _ = p.file.readPositionalAll(io, source[p.filled..], p.filled) catch {};
        }
        try indexRange(&self.offsets, self.gpa, source, p.scan_from);
        // Re-derive the tail properties now that the whole file is present.
        self.final_newline = source.len == 0 or source[source.len - 1] == '\n';
        if (!self.final_newline) try self.offsets.append(self.gpa, @intCast(source.len + 1));
        self.has_cr = self.has_cr or std.mem.indexOfScalar(u8, source, '\r') != null;
    }

    /// Append line starts for the newlines in `src[from..]`. The array already
    /// holds a leading 0 (and any earlier lines) when called incrementally.
    fn indexRange(offsets: *std.ArrayList(u32), gpa: Allocator, src: []const u8, from: usize) !void {
        if (offsets.items.len == 0) try offsets.append(gpa, 0);
        try offsets.ensureUnusedCapacity(gpa, (src.len - from) / 40 + 2);
        const vlen = 32;
        const nl_splat: @Vector(vlen, u8) = @splat('\n');
        var i = from;
        while (i + vlen <= src.len) : (i += vlen) {
            const chunk: @Vector(vlen, u8) = src[i..][0..vlen].*;
            var mask: u32 = @bitCast(chunk == nl_splat);
            while (mask != 0) {
                try offsets.append(gpa, @intCast(i + @ctz(mask) + 1));
                mask &= mask - 1;
            }
        }
        while (i < src.len) : (i += 1) {
            if (src[i] == '\n') try offsets.append(gpa, @intCast(i + 1));
        }
    }

    /// Load `path` into a new buffer. A missing file yields an empty buffer
    /// already named `path`, matching the familiar "open to create" behaviour.
    /// An `ssh://user@host/path` URL is fetched over ssh (see remote.zig) and
    /// keeps the URL as its path, so `:w` writes back to the same place.
    pub fn load(gpa: Allocator, io: std.Io, path: []const u8) !Buffer {
        if (remote.parse(path)) |target| {
            const data = try remote.read(gpa, io, target, max_file_bytes);
            var b = try fromOwnedBytes(gpa, data);
            b.path = try gpa.dupe(u8, path);
            return b;
        }
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
        const count = self.lineCount();
        if (self.emptied and count == 1 and self.line(0).len == 0) {
            return gpa.alloc(u8, 0);
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        // Reads through `line`, so an unedited buffer serialises straight out
        // of the lazy index without materialising it.
        try out.ensureTotalCapacity(gpa, if (self.source) |s| s.len else 0);
        var idx: usize = 0;
        while (idx < count) : (idx += 1) {
            try out.appendSlice(gpa, self.line(idx));
            const last = idx + 1 == count;
            if (!last or self.final_newline) try out.append(gpa, '\n');
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn save(self: *Buffer, io: std.Io) !void {
        const path = self.path orelse return error.NoFileName;
        const data = try self.toBytes(self.gpa);
        defer self.gpa.free(data);
        if (remote.parse(path)) |target| {
            try remote.write(self.gpa, io, target, data);
        } else {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
        }
        self.dirty = false;
    }

    pub fn setPath(self: *Buffer, path: []const u8) !void {
        const dup = try self.gpa.dupe(u8, path);
        if (self.path) |p| self.gpa.free(p);
        self.path = dup;
    }

    pub fn lineCount(self: *const Buffer) usize {
        if (self.isLazy()) return self.offsets.items.len - 1;
        return self.lines.items.len;
    }

    pub fn line(self: *const Buffer, row: usize) []const u8 {
        if (self.isLazy()) {
            const src = self.source orelse "";
            const s = self.offsets.items[row];
            const e = self.offsets.items[row + 1];
            const text = src[s .. e - 1];
            return if (self.has_cr) stripCr(text) else text;
        }
        return self.lines.items[row].bytes();
    }

    /// The row's bytes as mutable storage (converting a borrowed line to owned
    /// first) — for same-length in-place edits like case toggling.
    pub fn lineMut(self: *Buffer, row: usize) ![]u8 {
        try self.materialize();
        const l = try self.toOwned(row);
        return l.items;
    }

    /// Ensure the line owns its bytes (copy-on-write conversion).
    fn toOwned(self: *Buffer, row: usize) !*std.ArrayList(u8) {
        try self.materialize();
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
        try self.materialize();
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
        try self.materialize();
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
        try self.materialize();
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
        try self.materialize();
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
        self.offsets.deinit(self.gpa);
        if (self.source) |s| self.gpa.free(s);
        self.lines = tmp.lines; // take ownership; tmp.path is null
        self.offsets = tmp.offsets;
        self.source = tmp.source;
        self.final_newline = tmp.final_newline;
        self.emptied = tmp.emptied;
        self.pure_borrowed = tmp.pure_borrowed;
        self.has_cr = tmp.has_cr;
        self.revision +%= 1;
    }

    /// Insert raw bytes into a line at a byte offset.
    pub fn insertBytes(self: *Buffer, row: usize, col: usize, bytes: []const u8) !void {
        try self.materialize();
        const l = try self.toOwned(row);
        try l.insertSlice(self.gpa, col, bytes);
        self.emptied = false;
        self.dirty = true;
        self.revision +%= 1;
    }

    /// Remove bytes [start, end) from a line.
    pub fn deleteInLine(self: *Buffer, row: usize, start: usize, end: usize) !void {
        try self.materialize();
        if (end <= start) return;
        const l = try self.toOwned(row);
        try l.replaceRange(self.gpa, start, end - start, &[_]u8{});
        self.dirty = true;
        self.revision +%= 1;
    }

    /// Replace a line's entire content.
    pub fn setLine(self: *Buffer, row: usize, bytes: []const u8) !void {
        try self.materialize();
        const l = try self.toOwned(row);
        l.clearRetainingCapacity();
        try l.appendSlice(self.gpa, bytes);
        self.emptied = false;
        self.dirty = true;
        self.revision +%= 1;
    }

    /// Insert a new line (copying `bytes`) at index `at`.
    pub fn insertLineAt(self: *Buffer, at: usize, bytes: []const u8) !void {
        try self.materialize();
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
        self.materialize() catch return;
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
    // Freshly loaded: no per-line storage at all, just the offset index.
    try std.testing.expect(b.isLazy());
    try std.testing.expectEqual(@as(usize, 0), b.lines.items.len);
    try std.testing.expectEqualStrings("two", b.line(1));

    _ = try b.insertCodepoint(1, 0, 'X'); // the first edit materialises
    try std.testing.expectEqualStrings("Xtwo", b.line(1));
    try std.testing.expect(b.lines.items[1] == .owned);
    // Neighbours stayed zero-copy and unchanged.
    try std.testing.expect(b.lines.items[0] == .borrowed);
    try std.testing.expect(b.lines.items[2] == .borrowed);
    try std.testing.expectEqualStrings("one", b.line(0));
    try std.testing.expectEqualStrings("three", b.line(2));
}

test "the lazy index reads, counts and serialises without materialising" {
    const gpa = std.testing.allocator;
    var b = try Buffer.fromBytes(gpa, "alpha\nbeta\ngamma\n");
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 3), b.lineCount());
    try std.testing.expectEqualStrings("alpha", b.line(0));
    try std.testing.expectEqualStrings("gamma", b.line(2));
    const out = try b.toBytes(gpa);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("alpha\nbeta\ngamma\n", out);
    try std.testing.expect(b.isLazy()); // reading never materialises
}

test "lazy index handles CRLF and a missing final newline" {
    const gpa = std.testing.allocator;
    var crlf = try Buffer.fromBytes(gpa, "one\r\ntwo\r\n");
    defer crlf.deinit();
    try std.testing.expectEqual(@as(usize, 2), crlf.lineCount());
    try std.testing.expectEqualStrings("one", crlf.line(0));
    try std.testing.expectEqualStrings("two", crlf.line(1));

    var tail = try Buffer.fromBytes(gpa, "a\nb");
    defer tail.deinit();
    try std.testing.expectEqual(@as(usize, 2), tail.lineCount());
    try std.testing.expectEqualStrings("b", tail.line(1));
    const out = try tail.toBytes(gpa);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("a\nb", out); // no newline invented
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

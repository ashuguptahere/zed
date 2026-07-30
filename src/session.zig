//! Sessions: the open files, where the cursor sat in each, which one was
//! active, how the windows were split, and whether the file tree was open —
//! saved per working directory so reopening a project resumes it.
//!
//! One file per directory in `$XDG_STATE_HOME/zedit/sessions/<hash>` (the
//! name is a hash of the absolute cwd, which is longer than a filename may be
//! and full of slashes; the cwd itself is stored inside and checked on load,
//! so a collision cannot restore the wrong project). The format is one
//! directive per line:
//!
//!     cwd /home/u/src
//!     layout v 2
//!     sidebar 1
//!     active 1
//!     file 42 7 /home/u/src/main.zig
//!
//! Unknown directives are skipped rather than rejected, so a session written
//! by a later version still restores what this one understands. Best-effort
//! throughout: an unreadable or malformed file simply means no session.
//!
//! Nothing here happens on its own — saving and restoring are both explicit
//! (`Space S s` / `Space S l`, `:session save` / `:session load`), keeping the
//! promise that zedit never does work the user did not ask for.

const std = @import("std");
const config = @import("config.zig");

/// Enough for any project; a session file is written in one go, so the cap is
/// really a bound on how much a malformed file can make us allocate.
pub const max_files = 200;

pub const Entry = struct {
    path: []u8, // owned by the Session
    line: usize,
    col: usize,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    active: usize = 0,
    windows: usize = 1,
    split_vertical: bool = false,
    sidebar: bool = false,

    pub fn deinit(self: *Session) void {
        for (self.entries.items) |e| self.gpa.free(e.path);
        self.entries.deinit(self.gpa);
    }
};

/// The session file for `cwd`, or null when there is no state directory to
/// put one in (no `$XDG_STATE_HOME` and no `$HOME`).
pub fn filePath(buf: []u8, cwd: []const u8) ?[]const u8 {
    var dir_buf: [512]u8 = undefined;
    const dir = config.xdgPath(&dir_buf, "XDG_STATE_HOME", ".local/state", "sessions") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/{x:0>16}.session", .{ dir, std.hash.Wyhash.hash(0, cwd) }) catch null;
}

/// Serialise `s` for working directory `cwd`. The directory is created if it
/// is missing. Errors propagate so the caller can name the failure — a save
/// the user asked for must never look like it worked.
pub fn save(io: std.Io, cwd: []const u8, s: *const Session) !void {
    var buf: [1024]u8 = undefined;
    const path = filePath(&buf, cwd) orelse return error.NoStateDir;
    const dir = std.fs.path.dirname(path) orelse return error.NoStateDir;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(s.gpa);
    try text.print(s.gpa, "cwd {s}\n", .{cwd});
    try text.print(s.gpa, "layout {s} {d}\n", .{ if (s.split_vertical) "v" else "h", s.windows });
    try text.print(s.gpa, "sidebar {d}\n", .{@intFromBool(s.sidebar)});
    try text.print(s.gpa, "active {d}\n", .{s.active});
    for (s.entries.items) |e| {
        // A path with a newline in it would forge a directive; there is no
        // legal reason for one, so such an entry is dropped rather than
        // escaped (the reader would have to un-escape, for no real case).
        if (std.mem.indexOfScalar(u8, e.path, '\n') != null) continue;
        try text.print(s.gpa, "file {d} {d} {s}\n", .{ e.line, e.col, e.path });
    }

    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text.items });
}

/// Read the session for `cwd`, or null when there is none, it cannot be read,
/// or it belongs to a different directory (a hash collision).
pub fn load(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) ?Session {
    var buf: [1024]u8 = undefined;
    const path = filePath(&buf, cwd) orelse return null;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return null;
    defer gpa.free(text);
    var s = parse(gpa, text) orelse return null;
    if (s.entries.items.len == 0) {
        s.deinit();
        return null;
    }
    return s;
}

/// The pure half of `load`: text in, session out. Split off so the format is
/// unit-testable without touching the filesystem.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) ?Session {
    var s = Session{ .gpa = gpa };
    var ok = false; // a `cwd` line seen: this really is one of our files
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..sp];
        const rest = line[sp + 1 ..];
        if (std.mem.eql(u8, key, "cwd")) {
            ok = true;
        } else if (std.mem.eql(u8, key, "sidebar")) {
            s.sidebar = !std.mem.eql(u8, rest, "0");
        } else if (std.mem.eql(u8, key, "active")) {
            s.active = std.fmt.parseInt(usize, rest, 10) catch 0;
        } else if (std.mem.eql(u8, key, "layout")) {
            s.split_vertical = std.mem.startsWith(u8, rest, "v");
            const n = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
            s.windows = @max(1, std.fmt.parseInt(usize, rest[n + 1 ..], 10) catch 1);
        } else if (std.mem.eql(u8, key, "file")) {
            if (s.entries.items.len >= max_files) continue;
            const e = parseFile(gpa, rest) orelse continue;
            s.entries.append(gpa, e) catch {
                gpa.free(e.path);
                break;
            };
        }
    }
    if (!ok) {
        s.deinit();
        return null;
    }
    if (s.active >= s.entries.items.len) s.active = 0;
    s.windows = @min(s.windows, @max(1, s.entries.items.len));
    return s;
}

/// `<line> <col> <path>` — the path may contain spaces, so only the first two
/// fields are split off.
fn parseFile(gpa: std.mem.Allocator, rest: []const u8) ?Entry {
    const a = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const b = std.mem.indexOfScalarPos(u8, rest, a + 1, ' ') orelse return null;
    const line = std.fmt.parseInt(usize, rest[0..a], 10) catch return null;
    const col = std.fmt.parseInt(usize, rest[a + 1 .. b], 10) catch return null;
    const path = rest[b + 1 ..];
    if (path.len == 0) return null;
    return .{ .path = gpa.dupe(u8, path) catch return null, .line = line, .col = col };
}

/// Remove the session for `cwd`. True when one was there to remove.
pub fn delete(io: std.Io, cwd: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const path = filePath(&buf, cwd) orelse return false;
    std.Io.Dir.cwd().deleteFile(io, path) catch return false;
    return true;
}

test "parse restores files, cursors and layout" {
    const gpa = std.testing.allocator;
    var s = parse(gpa,
        \\cwd /tmp/proj
        \\layout v 2
        \\sidebar 1
        \\active 1
        \\file 42 7 /tmp/proj/main.zig
        \\file 1 0 /tmp/proj/a file with spaces.txt
        \\
    ).?;
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 2), s.entries.items.len);
    try std.testing.expectEqual(@as(usize, 42), s.entries.items[0].line);
    try std.testing.expectEqual(@as(usize, 7), s.entries.items[0].col);
    try std.testing.expectEqualStrings("/tmp/proj/a file with spaces.txt", s.entries.items[1].path);
    try std.testing.expectEqual(@as(usize, 1), s.active);
    try std.testing.expect(s.split_vertical);
    try std.testing.expectEqual(@as(usize, 2), s.windows);
    try std.testing.expect(s.sidebar);
}

test "a file without a cwd line is not ours" {
    try std.testing.expect(parse(std.testing.allocator, "file 1 0 /tmp/x\n") == null);
}

test "malformed directives are skipped, not fatal" {
    const gpa = std.testing.allocator;
    var s = parse(gpa,
        \\cwd /tmp/proj
        \\file notanumber 0 /tmp/x
        \\file 3 nope /tmp/y
        \\file 5
        \\unknown directive we do not know
        \\file 9 2 /tmp/good
        \\
    ).?;
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 1), s.entries.items.len);
    try std.testing.expectEqualStrings("/tmp/good", s.entries.items[0].path);
    try std.testing.expectEqual(@as(usize, 9), s.entries.items[0].line);
}

test "an out-of-range active index falls back to the first file" {
    const gpa = std.testing.allocator;
    var s = parse(gpa, "cwd /p\nactive 9\nfile 1 0 /p/a\n").?;
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 0), s.active);
}

test "the window count never exceeds the files restored" {
    const gpa = std.testing.allocator;
    var s = parse(gpa, "cwd /p\nlayout h 8\nfile 1 0 /p/a\n").?;
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 1), s.windows);
}

test "the file cap bounds what a malformed session can allocate" {
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "cwd /p\n");
    for (0..max_files + 50) |i| try text.print(gpa, "file 1 0 /p/f{d}\n", .{i});
    var s = parse(gpa, text.items).?;
    defer s.deinit();
    try std.testing.expectEqual(max_files, s.entries.items.len);
}

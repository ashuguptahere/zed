//! The recently-opened list behind the startup screen.
//!
//! One line per entry, newest first, in `$XDG_STATE_HOME/zedit/recent`
//! (falling back to `~/.local/state/zedit/recent` — the XDG spec's home for
//! state that should persist but is not config or a cache). Entries are
//! absolute paths, prefixed by kind so directories and remote targets survive
//! a round trip:
//!
//!     f /home/u/src/main.zig
//!     d /home/u/src
//!     f ssh://host/etc/hosts
//!
//! Best-effort throughout: an unreadable or malformed file simply means no
//! history, and writing failures are logged, never fatal. The list is capped
//! and de-duplicated (a re-opened path moves to the front), and entries whose
//! local path has since disappeared are dropped when the list is read.

const std = @import("std");
const config = @import("config.zig");
const remote = @import("remote.zig");

pub const max_entries = 30;

pub const Kind = enum { file, dir };

pub const Entry = struct {
    kind: Kind,
    path: []u8, // owned by the List
};

pub const List = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *List) void {
        for (self.entries.items) |e| self.gpa.free(e.path);
        self.entries.deinit(self.gpa);
    }

    fn indexOf(self: *const List, path: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.path, path)) return i;
        }
        return null;
    }

    /// Insert (or move) `path` at the front, capping the list.
    pub fn touch(self: *List, kind: Kind, path: []const u8) void {
        if (self.indexOf(path)) |i| {
            const e = self.entries.orderedRemove(i);
            self.entries.insert(self.gpa, 0, e) catch self.gpa.free(e.path);
            return;
        }
        const owned = self.gpa.dupe(u8, path) catch return;
        self.entries.insert(self.gpa, 0, .{ .kind = kind, .path = owned }) catch {
            self.gpa.free(owned);
            return;
        };
        while (self.entries.items.len > max_entries) {
            const dropped = self.entries.pop() orelse break;
            self.gpa.free(dropped.path);
        }
    }
};

/// The state-file path, built into `buf`. Null when neither env var exists.
pub fn statePath(buf: []u8) ?[]const u8 {
    return config.xdgPath(buf, "XDG_STATE_HOME", ".local/state", "recent");
}

/// Read the list, dropping entries whose local path no longer exists (remote
/// `ssh://` entries are kept as-is — checking them would mean a network call).
pub fn load(gpa: std.mem.Allocator, io: std.Io) List {
    var list: List = .{ .gpa = gpa };
    var pbuf: [512]u8 = undefined;
    const path = statePath(&pbuf) orelse return list;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 10)) catch return list;
    defer gpa.free(text);
    parse(&list, text);
    prune(&list, io);
    return list;
}

/// Parse the state file (pure — no I/O, so it is unit-tested directly).
fn parse(list: *List, text: []const u8) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len < 3 or line[1] != ' ') continue;
        const kind: Kind = switch (line[0]) {
            'f' => .file,
            'd' => .dir,
            else => continue,
        };
        const p = std.mem.trim(u8, line[2..], " \t\r");
        if (p.len == 0) continue;
        if (list.entries.items.len >= max_entries) break;
        const owned = list.gpa.dupe(u8, p) catch continue;
        list.entries.append(list.gpa, .{ .kind = kind, .path = owned }) catch list.gpa.free(owned);
    }
}

/// Drop entries whose local path has disappeared. Remote (`ssh://`) entries
/// are kept — checking them would mean a network round trip per entry.
fn prune(list: *List, io: std.Io) void {
    var i: usize = 0;
    while (i < list.entries.items.len) {
        const e = list.entries.items[i];
        if (remote.isRemote(e.path) or exists(io, e.path, e.kind)) {
            i += 1;
            continue;
        }
        list.gpa.free(e.path);
        _ = list.entries.orderedRemove(i);
    }
}

fn exists(io: std.Io, path: []const u8, kind: Kind) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return (kind == .dir) == (st.kind == .directory);
}

/// Write the list back (creating the directory). Best-effort: failures are
/// logged, never surfaced — losing the recent list must not break a session.
pub fn save(list: *const List, io: std.Io) void {
    var pbuf: [512]u8 = undefined;
    const path = statePath(&pbuf) orelse return;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(list.gpa);
    for (list.entries.items) |e| {
        text.print(list.gpa, "{c} {s}\n", .{ @as(u8, if (e.kind == .dir) 'd' else 'f'), e.path }) catch return;
    }
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |cut| {
        std.Io.Dir.cwd().createDirPath(io, path[0..cut]) catch {};
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text.items }) catch |err| {
        std.log.scoped(.recent).debug("cannot write {s}: {s}", .{ path, @errorName(err) });
    };
}

test "touch inserts, moves to front, and caps" {
    const gpa = std.testing.allocator;
    var list: List = .{ .gpa = gpa };
    defer list.deinit();

    list.touch(.file, "/a");
    list.touch(.dir, "/b");
    try std.testing.expectEqualStrings("/b", list.entries.items[0].path);
    try std.testing.expectEqual(Kind.dir, list.entries.items[0].kind);

    list.touch(.file, "/a"); // re-open moves it to the front, no duplicate
    try std.testing.expectEqual(@as(usize, 2), list.entries.items.len);
    try std.testing.expectEqualStrings("/a", list.entries.items[0].path);

    var i: usize = 0;
    while (i < max_entries + 5) : (i += 1) {
        var b: [16]u8 = undefined;
        list.touch(.file, std.fmt.bufPrint(&b, "/f{d}", .{i}) catch unreachable);
    }
    try std.testing.expectEqual(max_entries, list.entries.items.len);
}

test "parse reads entries in order and skips junk" {
    const gpa = std.testing.allocator;
    var list: List = .{ .gpa = gpa };
    defer list.deinit();
    parse(&list, "f ssh://host/etc/hosts\nx bad kind\n\nf\nd /tmp\nf /a b/c.txt\n");
    try std.testing.expectEqual(@as(usize, 3), list.entries.items.len);
    try std.testing.expectEqualStrings("ssh://host/etc/hosts", list.entries.items[0].path);
    try std.testing.expectEqual(Kind.dir, list.entries.items[1].kind);
    try std.testing.expectEqualStrings("/a b/c.txt", list.entries.items[2].path); // spaces survive
}

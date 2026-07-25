//! Git change signs for the gutter.
//!
//! We shell out to `git diff` (the only practical way to read repository state
//! without reimplementing packfile/zlib parsing) and turn its `-U0` hunk
//! headers into a per-line map of add/change/delete signs. It is best-effort:
//! outside a repo, or without `git`, there are simply no signs. Diffs are
//! recomputed on load and on save, never in the render or input path.

const std = @import("std");

pub const Sign = enum { added, changed, deleted };

/// Map from 0-based buffer row to its change sign.
pub const Signs = std.AutoHashMap(usize, Sign);

/// Recompute `signs` for `path` (working tree vs. index). Clears on any error.
/// Whether `path` sits inside a git work tree, decided with a few `stat`s
/// rather than by asking git. Spawning `git` costs ~1.2 ms, which is a lot to
/// pay on every open of a file that is not in a repository at all.
fn inWorkTree(io: std.Io, path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var dir: []const u8 = std.fs.path.dirname(path) orelse ".";
    var hops: usize = 0;
    while (hops < 64) : (hops += 1) {
        const probe = std.fmt.bufPrint(&buf, "{s}/.git", .{dir}) catch return true;
        if (std.Io.Dir.cwd().openDir(io, probe, .{})) |*d| {
            var dd = d.*;
            dd.close(io);
            return true;
        } else |_| {}
        // A .git *file* means a worktree or submodule; openFile catches that.
        if (std.Io.Dir.cwd().openFile(io, probe, .{})) |f| {
            var ff = f;
            ff.close(io);
            return true;
        } else |_| {}
        dir = std.fs.path.dirname(dir) orelse break;
        if (dir.len == 0) break;
    }
    return false;
}

pub fn compute(gpa: std.mem.Allocator, io: std.Io, path: []const u8, signs: *Signs) void {
    signs.clearRetainingCapacity();
    if (!inWorkTree(io, path)) return;
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "git", "diff", "--no-color", "-U0", "--", path },
        .stdout_limit = .limited(8 << 20),
        .stderr_limit = .limited(64 << 10),
    }) catch |err| {
        std.log.scoped(.git).debug("git diff failed to run: {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) return, // not a repo / git error (normal; not logged)
        else => return,
    }
    parse(res.stdout, signs);
}

/// Recompute `signs` for the OLD side of `path`'s diff (index vs. worktree):
/// each index-version line that was changed or removed gets a sign, so the
/// side-by-side view can tint the index pane. Clears on any error.
pub fn computeOldSide(gpa: std.mem.Allocator, io: std.Io, path: []const u8, signs: *Signs) void {
    signs.clearRetainingCapacity();
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "git", "diff", "--no-color", "-U0", "--", path },
        .stdout_limit = .limited(8 << 20),
        .stderr_limit = .limited(64 << 10),
    }) catch return;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) return,
        else => return,
    }
    parseOldSide(res.stdout, signs);
}

/// Old-side counterpart of `parse`: marks index-version rows that a hunk
/// changes (`changed`) or removes entirely (`deleted`).
fn parseOldSide(text: []const u8, signs: *Signs) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "@@")) continue;
        const minus = std.mem.indexOfScalar(u8, line, '-') orelse continue;
        const plus = std.mem.indexOfScalarPos(u8, line, minus, '+') orelse continue;
        const old = parsePair(line[minus + 1 ..]);
        const new = parsePair(line[plus + 1 ..]);
        if (old.count == 0) continue; // pure addition: no old-side rows
        const sign: Sign = if (new.count == 0) .deleted else .changed;
        const base = if (old.start == 0) 0 else old.start - 1;
        var i: usize = 0;
        while (i < old.count) : (i += 1) signs.put(base + i, sign) catch {};
    }
}

/// Parse `git diff -U0` output, recording a sign for each affected new-file line.
fn parse(text: []const u8, signs: *Signs) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "@@")) continue;
        const minus = std.mem.indexOfScalar(u8, line, '-') orelse continue;
        const plus = std.mem.indexOfScalarPos(u8, line, minus, '+') orelse continue;
        const old = parsePair(line[minus + 1 ..]);
        const new = parsePair(line[plus + 1 ..]);

        if (new.count == 0) {
            // Pure deletion: mark the surviving line it sits after.
            const row = if (new.start == 0) 0 else new.start - 1;
            signs.put(row, .deleted) catch {};
        } else {
            const sign: Sign = if (old.count == 0) .added else .changed;
            const base = if (new.start == 0) 0 else new.start - 1;
            var i: usize = 0;
            while (i < new.count) : (i += 1) signs.put(base + i, sign) catch {};
        }
    }
}

const Pair = struct { start: usize, count: usize };

/// Parse a "N" or "N,M" count from the start of `s` (count defaults to 1).
fn parsePair(s: []const u8) Pair {
    var i: usize = 0;
    while (i < s.len and isDigit(s[i])) i += 1;
    const start = std.fmt.parseInt(usize, s[0..i], 10) catch 0;
    var count: usize = 1;
    if (i < s.len and s[i] == ',') {
        var j = i + 1;
        while (j < s.len and isDigit(s[j])) j += 1;
        count = std.fmt.parseInt(usize, s[i + 1 .. j], 10) catch 1;
    }
    return .{ .start = start, .count = count };
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

test "parseOldSide marks changed and removed index rows" {
    var signs = Signs.init(std.testing.allocator);
    defer signs.deinit();
    const diff =
        \\@@ -1,0 +2,2 @@
        \\@@ -5,2 +7,1 @@
        \\@@ -10,1 +11,0 @@
        \\
    ;
    parseOldSide(diff, &signs);
    try std.testing.expect(signs.get(0) == null); // pure addition: nothing
    try std.testing.expectEqual(Sign.changed, signs.get(4).?); // old line 5
    try std.testing.expectEqual(Sign.changed, signs.get(5).?); // old line 6
    try std.testing.expectEqual(Sign.deleted, signs.get(9).?); // old line 10
}

test "parse hunk headers into signs" {
    var signs = Signs.init(std.testing.allocator);
    defer signs.deinit();
    const diff =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,0 +2,2 @@
        \\+added one
        \\+added two
        \\@@ -5,2 +7,1 @@
        \\-old
        \\-old two
        \\+changed
        \\@@ -10,1 +11,0 @@
        \\-deleted
        \\
    ;
    parse(diff, &signs);
    try std.testing.expectEqual(Sign.added, signs.get(1).?); // line 2
    try std.testing.expectEqual(Sign.added, signs.get(2).?); // line 3
    try std.testing.expectEqual(Sign.changed, signs.get(6).?); // line 7
    try std.testing.expectEqual(Sign.deleted, signs.get(10).?); // after line 11
    try std.testing.expect(signs.get(0) == null);
}

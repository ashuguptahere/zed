//! Git change gutter end-to-end: add/change/delete signs render in their
//! colours. Port of tools/git_test.py. Sets up a real git repo in a temp dir,
//! commits a file, makes a working-tree change, opens zed, and checks the
//! rendered output for the sign colours. Uses .txt files so the only colours
//! present come from the git gutter (no syntax highlighting).

const std = @import("std");
const h = @import("../harness.zig");

const ESC = "\x1b";

// theme.zig gutter colours (24-bit SGR foreground).
const ADD = "\x1b[38;2;158;206;106m"; // theme.git_add
const CHANGE = "\x1b[38;2;224;175;104m"; // theme.git_change
const DELETE = "\x1b[38;2;247;118;142m"; // theme.git_delete
const BAR = "\xe2\x94\x82"; // U+2502
const LOWBLOCK = "\xe2\x96\x81"; // U+2581

/// Run a git subcommand in `dir`, ignoring (but freeing) its output. Uses `-C`
/// and `-c` flags so it works regardless of the global/system git config.
fn git(ctx: *h.Ctx, argv: []const []const u8) void {
    const res = std.process.run(ctx.gpa, ctx.io, .{ .argv = argv }) catch return;
    ctx.gpa.free(res.stdout);
    ctx.gpa.free(res.stderr);
}

/// Build a fresh repo with `committed` committed and `modified` in the working
/// tree, open zed on the file, drain the first frames, run the checks against
/// the live session, then quit and clean up.
fn capture(
    ctx: *h.Ctx,
    committed: []const u8,
    modified: []const u8,
    name: []const u8,
    checks: []const struct { name: []const u8, present: []const []const u8, absent: []const []const u8 },
) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    const file = try std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ dir, name });
    defer ctx.gpa.free(file);

    git(ctx, &.{ "git", "-C", dir, "init", "-q" });
    h.writeFile(ctx.io, file, committed);
    git(ctx, &.{ "git", "-C", dir, "add", name });
    git(ctx, &.{ "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t.t", "commit", "-q", "-m", "init" });
    h.writeFile(ctx.io, file, modified); // working-tree change

    var s = try h.Session.spawn(ctx.gpa, .{
        .argv = &.{ ctx.zed, name },
        .cwd = dir,
        .term = "xterm-256color",
    });
    defer s.finish();
    s.drain(1500); // no keys: just let it render

    // Run the assertions while the session is alive (it frees its bytes on finish).
    for (checks) |chk| {
        var ok = true;
        for (chk.present) |needle| ok = ok and s.contains(needle);
        for (chk.absent) |needle| ok = ok and !s.contains(needle);
        ctx.check(chk.name, ok);
    }

    s.send(ESC ++ ":q!\r");
    s.drain(300);
}

pub fn run(ctx: *h.Ctx) !void {
    // changed + added line
    try capture(ctx, "alpha\nbeta\ngamma\n", "alpha\nBETA\ngamma\nadded\n", "f.txt", &.{
        .{ .name = "changed line shows change sign", .present = &.{ CHANGE, BAR }, .absent = &.{} },
        .{ .name = "added line shows add sign", .present = &.{ADD}, .absent = &.{} },
    });

    // deleted line
    try capture(ctx, "one\ntwo\nthree\n", "one\nthree\n", "f.txt", &.{
        .{ .name = "deleted line shows delete sign", .present = &.{ DELETE, LOWBLOCK }, .absent = &.{} },
    });

    // unchanged file
    try capture(ctx, "same\nlines\n", "same\nlines\n", "f.txt", &.{
        .{ .name = "unchanged file shows no sign colours", .present = &.{}, .absent = &.{ CHANGE, ADD, DELETE } },
    });
}

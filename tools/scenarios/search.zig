//! In-buffer search: incremental jump, cancel, n, and match highlight.
//! Port of tools/search_test.py.

const std = @import("std");
const h = @import("../harness.zig");

const ESC = "\x1b";
const CR = "\r";
const target = "/tmp/zed_it_search.txt";

fn case(ctx: *h.Ctx, name: []const u8, chunks: []const []const u8, initial: []const u8, want: []const u8) void {
    const got = h.runEdit(ctx, target, initial, chunks);
    defer ctx.gpa.free(got);
    ctx.check(name, std.mem.eql(u8, got, want));
}

pub fn run(ctx: *h.Ctx) !void {
    // / finds and edits (cursor lands on the match).
    case(ctx, "/ jumps to match and edits", &.{ "/gamma", CR, "x", ":wq", CR }, "alpha\nbeta\ngamma\n", "alpha\nbeta\namma\n");

    // Esc cancels the search and restores the original cursor (still on line 1).
    case(ctx, "Esc cancels, cursor restored", &.{ "/gamma", ESC, "x", ":wq", CR }, "alpha\nbeta\ngamma\n", "lpha\nbeta\ngamma\n");

    // n repeats to the next match.
    case(ctx, "n repeats to next match", &.{ "/foo", CR, "n", "x", ":wq", CR }, "foo\nfoo\nfoo\n", "foo\nfoo\noo\n");

    // Live highlight uses the match colour while typing (theme.match = 61;89;161).
    {
        h.writeFile(ctx.io, target, "alpha\nbeta\ngamma\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zed, target }, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400); // first frame
        s.send("/beta");
        s.drain(800); // let the live highlight render
        ctx.check("matches are highlighted", s.contains("\x1b[48;2;61;89;161m"));
    }
}

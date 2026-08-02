//! In-buffer search: incremental jump, cancel, n, and match highlight.
//! Port of tools/search_test.py.

const h = @import("../harness.zig");

const ESC = "\x1b";
const CR = "\r";
const target = "/tmp/zedit_it_search.txt";

pub fn run(ctx: *h.Ctx) !void {
    // / finds and edits (cursor lands on the match).
    h.case(ctx, target, "/ jumps to match and edits", &.{ "/gamma", CR, "x", ":wq", CR }, "alpha\nbeta\ngamma\n", "alpha\nbeta\namma\n");

    // Esc cancels the search and restores the original cursor (still on line 1).
    h.case(ctx, target, "Esc cancels, cursor restored", &.{ "/gamma", ESC, "x", ":wq", CR }, "alpha\nbeta\ngamma\n", "lpha\nbeta\ngamma\n");

    // n repeats to the next match.
    h.case(ctx, target, "n repeats to next match", &.{ "/foo", CR, "n", "x", ":wq", CR }, "foo\nfoo\nfoo\n", "foo\nfoo\noo\n");

    // Mid-line editing in the search prompt: "/ab" then Left and "X" edits
    // the pattern to "aXb" — the live preview must re-run on the full line,
    // so Enter lands on line 3's "aXb", not line 2's "ab".
    h.case(ctx, target, "mid-line insert re-previews the whole pattern", &.{ "/ab", "\x1b[D", "X", CR, "rZ", ":wq", CR }, "qq\nab\naXb\n", "qq\nab\nZXb\n");

    // Esc after a mid-line edit still cancels and restores the origin.
    h.case(ctx, target, "Esc after a mid-line edit restores the cursor", &.{ "/ab", "\x1b[D", "X", ESC, "x", ":wq", CR }, "qq\nab\naXb\n", "q\nab\naXb\n");

    // Live highlight uses the match colour while typing (theme.match = 61;89;161).
    {
        h.writeFile(ctx.io, target, "alpha\nbeta\ngamma\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, target }, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400); // first frame
        s.send("/beta");
        s.drain(800); // let the live highlight render
        ctx.check("matches are highlighted", s.contains("\x1b[48;2;61;89;161m"));
    }
}

//! Buffer-word completion: the fallback that makes completion work with no
//! language server installed (the owner's report: a new .py file on a machine
//! without pylsp had neither highlighting nor completion, and nothing said
//! why). Covers the popup filling from the current buffer, from another open
//! buffer, the word being typed never completing itself, `buffer_completion =
//! false`, the missing-server hint (and its silence for a filetype with no
//! known server), and the mock-server cases: items win, an empty result falls
//! back, a *replaced* result leaves no popup indexing the old one, and a
//! server that died is treated like one that was never installed. Plus the
//! rule that decides which words the caps keep: the ones nearest the cursor.
//!
//! Assertions use the harness Screen model — the popup is the row *under the
//! cursor*, which is what distinguishes it from the same word sitting in the
//! buffer text.

const std = @import("std");
const h = @import("../harness.zig");

const Step = struct { keys: []const u8, ms: i64 };

/// Run a session and return its final screen (caller deinits).
fn drive(ctx: *h.Ctx, argv: []const []const u8, cwd: []const u8, cols: u16, steps: []const Step) !h.Screen {
    var s = try h.Session.spawn(ctx.gpa, .{ .argv = argv, .cwd = cwd, .cols = cols });
    defer s.finish();
    s.drain(600); // first frame + the decorate pass (highlighting, LSP)
    for (steps) |st| {
        s.send(st.keys);
        s.drain(st.ms);
    }
    var scr = try h.Screen.init(ctx.gpa, 24, cols);
    scr.apply(s.out.items);
    return scr;
}

/// Is `needle` on one of the popup's rows? The popup is drawn under the cursor
/// (at most 8 rows of it), which is what distinguishes a candidate from the
/// same word sitting in the buffer text. Every case below types on the last
/// line, so these rows hold the popup or nothing.
fn popupHas(ctx: *h.Ctx, scr: *h.Screen, needle: []const u8) bool {
    var row = scr.cur_row + 1;
    const last = @min(scr.rows - 1, scr.cur_row + 8); // -1: never the statusline
    while (row <= last) : (row += 1) {
        const text = scr.rowText(ctx.gpa, row) catch continue;
        defer ctx.gpa.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

/// Is `name` an executable on PATH? The scenarios below assume no pylsp — that
/// is the whole point of the fallback — so the run says so rather than passing
/// for the wrong reason on a machine that has one.
fn onPath(ctx: *h.Ctx, name: []const u8) bool {
    const cmd = std.fmt.allocPrint(ctx.gpa, "command -v {s}", .{name}) catch return false;
    defer ctx.gpa.free(cmd);
    const res = std.process.run(ctx.gpa, ctx.io, .{ .argv = &.{ "sh", "-c", cmd } }) catch return false;
    defer ctx.gpa.free(res.stdout);
    defer ctx.gpa.free(res.stderr);
    return res.stdout.len > 0;
}

pub fn run(ctx: *h.Ctx) !void {
    // --- a request made while the server is still starting is not lost -------
    // The handshake stopped blocking in 0.33.0, which opened a window where a
    // completion fired before `initialize` came back was dropped with nothing
    // to ask again. With the buffer-word fallback off, that is silence: type
    // fast after opening a file and the popup never comes. The request must
    // wait for the handshake instead.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const cfg = h.join(ctx, dir, "cfg");
        defer ctx.gpa.free(cfg);
        h.writeFile(ctx.io, cfg, "buffer_completion = false\n");
        const src = h.join(ctx, dir, "m.zig");
        defer ctx.gpa.free(src);
        h.writeFile(ctx.io, src, "const x = 1;\n");
        const cmd = try std.fmt.allocPrint(ctx.gpa, "{s} --slow-init=900", .{ctx.mock});
        defer ctx.gpa.free(cmd);
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--config", "cfg", "--lsp", cmd, "m.zig" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(300); // deliberately less than the server needs to answer
        s.send("Gomock"); // the debounce fires while it is still handshaking
        // Wait for the *outcome*, not for a fixed number of milliseconds: how
        // long the handshake plus a round trip takes depends on the machine,
        // and a budget tuned here is a test that goes red on a slower one for
        // no reason. Give up after six seconds, which is a failure either way.
        var found = false;
        var waited: usize = 0;
        while (waited < 6000 and !found) : (waited += 250) {
            s.drain(250);
            var scr = try h.Screen.init(ctx.gpa, 24, 80);
            defer scr.deinit();
            scr.apply(s.out.items);
            found = popupHas(ctx, &scr, "mockComplete");
        }
        ctx.check("a completion asked for during the handshake still arrives", found);
        s.send("\x1b:q!\r");
        s.drain(300);
    }


    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    const first = h.join(ctx, dir, "first.py");
    defer ctx.gpa.free(first);
    const self_only = h.join(ctx, dir, "self.py");
    defer ctx.gpa.free(self_only);
    const other = h.join(ctx, dir, "other.py");
    defer ctx.gpa.free(other);
    const plain = h.join(ctx, dir, "plain.py");
    defer ctx.gpa.free(plain);
    const note = h.join(ctx, dir, "note.txt");
    defer ctx.gpa.free(note);
    const cfg = h.join(ctx, dir, "cfg");
    defer ctx.gpa.free(cfg);
    const zsrc = h.join(ctx, dir, "m.zig");
    defer ctx.gpa.free(zsrc);

    h.writeFile(ctx.io, first, "def f():\n    return_value = 1\n");
    h.writeFile(ctx.io, self_only, "ret = 1\n");
    h.writeFile(ctx.io, other, "widget_count = 3\n");
    h.writeFile(ctx.io, plain, "x = 0\n");
    h.writeFile(ctx.io, note, "some words here\n");
    h.writeFile(ctx.io, cfg, "buffer_completion = false\n");
    h.writeFile(ctx.io, zsrc, "const mockFromBuffer = 1;\n");

    ctx.check("no pylsp on PATH (the fallback's premise)", !onPath(ctx, "pylsp"));

    // A word from the current buffer, offered with no server anywhere: type
    // "ret" under a line holding `return_value`, pause past the debounce.
    {
        var scr = try drive(ctx, &.{ ctx.zedit, "first.py" }, dir, 80, &.{.{ .keys = "Goret", .ms = 900 }});
        defer scr.deinit();
        ctx.check("buffer word completes with no language server", popupHas(ctx, &scr, "return_value"));
    }

    // Tab accepts it exactly as an LSP item would: the typed prefix is
    // replaced, and the file reads back with the whole word. (Sent by hand
    // rather than through `runEdit`: the popup needs the debounce to elapse,
    // which is longer than that helper's inter-chunk pause.)
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "first.py" }, .cwd = dir });
        defer s.finish();
        s.drain(600);
        s.send("Goret");
        s.drain(900); // the popup opens
        s.send("\t"); // accept
        s.drain(300);
        s.send("\x1b:wq\r");
        s.drain(600);
        const saved = h.readFile(ctx.gpa, ctx.io, first);
        defer ctx.gpa.free(saved);
        const want = "def f():\n    return_value = 1\n    return_value\n";
        if (!std.mem.eql(u8, saved, want)) std.debug.print("       got \"{f}\"\n", .{std.zig.fmtString(saved)});
        ctx.check("Tab accepts a buffer word into the buffer", std.mem.eql(u8, saved, want));
    }

    // The word being typed is not a candidate for itself: `ret` is the only
    // word in this file, so there is nothing to offer and no popup.
    {
        var scr = try drive(ctx, &.{ ctx.zedit, "self.py" }, dir, 80, &.{.{ .keys = "Goret", .ms = 900 }});
        defer scr.deinit();
        ctx.check("the typed word never completes itself", !popupHas(ctx, &scr, "ret"));
    }

    // The same rule with the cursor *inside* a word: typing `r` in front of
    // `ret` makes the line read `rret`, which must not be offered back as a
    // completion of `r` (excluding only the typed prefix used to do exactly
    // that — and the swallowed Esc that followed hid it).
    {
        var scr = try drive(ctx, &.{ ctx.zedit, "self.py" }, dir, 80, &.{.{ .keys = "ggir", .ms = 900 }});
        defer scr.deinit();
        ctx.check("typing inside a word does not offer that word", !popupHas(ctx, &scr, "rret"));
    }

    // Another open buffer is harvested too (vim's keyword completion scans
    // every buffer): `widget_count` lives only in other.py.
    {
        var scr = try drive(ctx, &.{ ctx.zedit, "plain.py" }, dir, 80, &.{
            .{ .keys = ":e other.py\r", .ms = 500 },
            .{ .keys = ":e plain.py\r", .ms = 500 },
            .{ .keys = "Gowid", .ms = 900 },
        });
        defer scr.deinit();
        ctx.check("a word from another open buffer completes", popupHas(ctx, &scr, "widget_count"));
    }

    // ...and the whole thing is switchable off — including the on-demand
    // Ctrl-n, which does not go through the typing debounce.
    {
        var scr = try drive(ctx, &.{ ctx.zedit, "--config", "cfg", "first.py" }, dir, 80, &.{
            .{ .keys = "Goret", .ms = 500 },
            .{ .keys = "\x0e", .ms = 600 }, // Ctrl-n
        });
        defer scr.deinit();
        ctx.check("buffer_completion = false gives no popup", !popupHas(ctx, &scr, "return_value"));
    }

    // The missing-server hint: python has a known server (pylsp) that is not
    // installed, so the statusline says so — at 120 columns, where the whole
    // message fits. A .txt file has no known server and stays silent.
    {
        var scr = try drive(ctx, &.{ ctx.zedit, "first.py" }, dir, 120, &.{});
        defer scr.deinit();
        const status = try scr.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(status);
        ctx.check(
            "missing server named in the statusline",
            std.mem.indexOf(u8, status, "no language server for python (install pylsp); completing from open buffers") != null,
        );
    }
    {
        var scr = try drive(ctx, &.{ ctx.zedit, "note.txt" }, dir, 120, &.{});
        defer scr.deinit();
        const status = try scr.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(status);
        ctx.check("no hint for a filetype with no known server", std.mem.indexOf(u8, status, "no language server") == null);
    }

    // The hint is a per-document event, not a per-keystroke one: typing (each
    // pause a completion request) must never bring it back.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "first.py" }, .cwd = dir, .cols = 120 });
        defer s.finish();
        s.drain(600);
        s.send(":w\r"); // a different status takes the row
        s.drain(400);
        const m = s.mark();
        s.sendKeys(&.{ "Gore", "t", "u", "r" });
        s.drain(600);
        ctx.check("hint not repeated while typing", !s.containsPlainSince(ctx.gpa, m, "no language server"));
    }

    // With a server attached, its items win and the fallback stays out of the
    // way — `mockFromBuffer` is in the buffer and matches "mock", but the
    // popup shows only what the server sent.
    {
        var scr = try drive(ctx, &.{ ctx.zedit, "--lsp", ctx.mock, "m.zig" }, dir, 80, &.{.{ .keys = "Gomock", .ms = 1200 }});
        defer scr.deinit();
        ctx.check("server items win over buffer words", popupHas(ctx, &scr, "mockComplete"));
        ctx.check("buffer fallback does not fire beside them", !popupHas(ctx, &scr, "mockFromBuffer"));
    }

    // A server that answers with an empty list falls back to the buffer, so a
    // filetype whose server simply has nothing here still completes.
    {
        const cmd = try std.fmt.allocPrint(ctx.gpa, "{s} --nocomp", .{ctx.mock});
        defer ctx.gpa.free(cmd);
        var scr = try drive(ctx, &.{ ctx.zedit, "--lsp", cmd, "m.zig" }, dir, 80, &.{.{ .keys = "Gomock", .ms = 1200 }});
        defer scr.deinit();
        ctx.check("empty server result falls back to buffer words", popupHas(ctx, &scr, "mockFromBuffer"));
    }

    // Every response *replaces* the server's list, so a popup opened from the
    // previous one is left holding indices into items that no longer exist.
    // With the fallback switched off nothing refills it, and the next frame
    // used to read off the end of an empty list and kill the editor.
    {
        const cmd = try std.fmt.allocPrint(ctx.gpa, "{s} --thenempty", .{ctx.mock});
        defer ctx.gpa.free(cmd);
        const out = h.join(ctx, dir, "out.zig");
        defer ctx.gpa.free(out);
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--config", "cfg", "--lsp", cmd, "m.zig" },
            .cwd = dir,
        });
        defer s.finish();
        s.drain(600);
        s.send("Gomock");
        s.drain(900); // response 1: items -> the popup opens on them
        s.send("C");
        s.drain(900); // response 2: empty -> that list is gone
        s.send("\x1b:w out.zig\r");
        s.drain(600);
        const saved = h.readFile(ctx.gpa, ctx.io, out);
        defer ctx.gpa.free(saved);
        ctx.check(
            "the editor survives a server emptying its list under the popup",
            std.mem.eql(u8, saved, "const mockFromBuffer = 1;\nmockC\n"),
        );
    }

    // A server that died after the handshake answers nothing at all, so it
    // has to be treated like one that was never installed — otherwise the
    // request goes into a dead pipe and no popup ever comes.
    {
        const cmd = try std.fmt.allocPrint(ctx.gpa, "{s} --die", .{ctx.mock});
        defer ctx.gpa.free(cmd);
        var scr = try drive(ctx, &.{ ctx.zedit, "--lsp", cmd, "m.zig" }, dir, 80, &.{.{ .keys = "Gomock", .ms = 1200 }});
        defer scr.deinit();
        ctx.check("a dead server falls back to buffer words", popupHas(ctx, &scr, "mockFromBuffer"));
    }

    // Which words the caps keep: the nearest ones. The harvest walks outward
    // from the cursor, so the identifier on the line just above is offered
    // even when two thousand distinct words sit above it — scanning the
    // window top-down filled all 200 slots long before reaching the cursor.
    {
        const big = h.join(ctx, dir, "big.txt");
        defer ctx.gpa.free(big);
        var txt: std.ArrayList(u8) = .empty;
        defer txt.deinit(ctx.gpa);
        var i: usize = 0;
        while (i < 2000) : (i += 1) {
            const ln = try std.fmt.allocPrint(ctx.gpa, "filler_word_{d:0>6} more_{d:0>6}\n", .{ i, i });
            defer ctx.gpa.free(ln);
            try txt.appendSlice(ctx.gpa, ln);
        }
        try txt.appendSlice(ctx.gpa, "zzz_nearby = 1\n"); // the line above the cursor
        h.writeFile(ctx.io, big, txt.items);
        var scr = try drive(ctx, &.{ ctx.zedit, "big.txt" }, dir, 80, &.{.{ .keys = "Gozzz_", .ms = 900 }});
        defer scr.deinit();
        ctx.check("the nearest word wins the candidate cap", popupHas(ctx, &scr, "zzz_nearby"));
    }
}

//! Robustness: hostile bytes stay inert (control characters in file content
//! are rendered as placeholders, never emitted as terminal escapes), failed
//! saves are reported in plain English (`:w` and `:wa`), and `:qa` refuses to
//! discard unsaved buffers (nvim-verified; see vim_compat nvim#h5).

const std = @import("std");
const h = @import("../harness.zig");

/// A binary file (the user's example: .DS_Store) must render inert and inside
/// its rows: NUL and malformed bytes each as one '?' cell, no raw byte >= 0x80
/// reaching the terminal, and no row emitting more cells than the window has —
/// the pre-fix build wrote 2000-cell rows that the terminal wrapped backwards.
fn binaryInert(ctx: *h.Ctx) !void {
    const dir = try ctx.tempDir();
    const path = h.join(ctx, dir, "blob.bin");
    defer ctx.gpa.free(path);

    // 'A', 300 NULs, a lone continuation byte, a truncated 3-byte sequence,
    // then a scatter of high bytes — one newline-free "line", like .DS_Store.
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(ctx.gpa);
    try data.append(ctx.gpa, 'A');
    try data.appendNTimes(ctx.gpa, 0, 300);
    try data.appendSlice(ctx.gpa, &[_]u8{ 0x92, 0xE5, 0x92 });
    var b: u8 = 0x80;
    while (b < 0xC0) : (b += 1) try data.append(ctx.gpa, b);
    h.writeFile(ctx.io, path, data.items);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "blob.bin" }, .cwd = dir });
    defer s.finish();
    s.drain(600);

    // Walk the raw stream: rows are delimited by cursor-position escapes; count
    // visible cells per row and watch for raw high bytes outside escapes.
    const out = s.out.items;
    var col: usize = 0;
    var max_col: usize = 0;
    var raw_high: usize = 0;
    var i: usize = 0;
    while (i < out.len) {
        if (out[i] == 0x1b) { // skip the escape; \x1b[row;colH resets the count
            var j = i + 1;
            if (j < out.len and out[j] == '[') {
                j += 1;
                while (j < out.len and !std.ascii.isAlphabetic(out[j])) j += 1;
                if (j < out.len and out[j] == 'H') col = 0;
                i = @min(j + 1, out.len);
            } else i = j;
            continue;
        }
        // A valid UTF-8 sequence is one glyph cell (the fixture makes zedit
        // emit no wide characters); a byte that does not begin a valid
        // sequence is a raw leak — exactly what the sanitizer must prevent.
        const len = std.unicode.utf8ByteSequenceLength(out[i]) catch {
            raw_high += 1;
            i += 1;
            continue;
        };
        if (i + len > out.len or !std.unicode.utf8ValidateSlice(out[i .. i + len])) {
            raw_high += 1;
            i += 1;
            continue;
        }
        col += 1;
        max_col = @max(max_col, col);
        i += len;
    }
    ctx.check("binary bytes never reach the terminal raw", raw_high == 0);
    if (max_col > 80) std.debug.print("       widest row: {d} cells\n", .{max_col});
    ctx.check("no row emits more cells than the window has", max_col <= 80);
    s.send(":q!\r");
    s.drain(200);
}

pub fn run(ctx: *h.Ctx) !void {
    try binaryInert(ctx);

    const dir = try ctx.tempDir();

    // A file smuggling an OSC title-set and a clear-screen CSI must render as
    // plain '?' text — the raw escape bytes must never reach the terminal.
    {
        const evil = h.join(ctx, dir, "evil.txt");
        defer ctx.gpa.free(evil);
        h.writeFile(ctx.io, evil, "before \x1b]0;pwned\x07 middle \x1b[2J after\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "evil.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(500);
        ctx.check("escape bytes are neutralised", !s.contains("\x1b]0;pwned") and !s.contains("\x1b[2J"));
        ctx.check("neutralised bytes still visible as text", s.containsPlain(ctx.gpa, "]0;pwned"));
        s.send(":q!\r");
        s.drain(200);
    }

    // :w on a read-only file reports "permission denied", not a raw enum.
    {
        const ro = h.join(ctx, dir, "ro.txt");
        defer ctx.gpa.free(ro);
        h.writeFile(ctx.io, ro, "locked\n");
        h.runQuiet(ctx.gpa, ctx.io, &.{ "chmod", "444", ro });
        defer h.runQuiet(ctx.gpa, ctx.io, &.{ "chmod", "644", ro });
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "ro.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send("x:w\r");
        s.drain(400);
        ctx.check(":w failure is plain English", s.containsPlain(ctx.gpa, "permission denied") and
            !s.containsPlain(ctx.gpa, "AccessDenied"));

        // :wa on the same dirty read-only buffer names the failure too.
        s.send(":wa\r");
        s.drain(400);
        ctx.check(":wa reports the failed save", s.containsPlain(ctx.gpa, "1 failed") and
            s.containsPlain(ctx.gpa, "ro.txt"));
        s.send(":q!\r");
        s.drain(200);
    }

    // :qa with unsaved changes refuses with a hint; :qa! then discards.
    {
        const f = h.join(ctx, dir, "f.txt");
        defer ctx.gpa.free(f);
        h.writeFile(ctx.io, f, "aa\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send("x:qa\r");
        s.drain(400);
        ctx.check(":qa refuses with unsaved changes", s.containsPlain(ctx.gpa, ":wa or :qa!"));
        s.send(":qa!\r");
        s.drain(300);
        const t = h.readFile(ctx.gpa, ctx.io, f);
        defer ctx.gpa.free(t);
        ctx.check(":qa! discards the edit", std.mem.eql(u8, t, "aa\n"));
    }

    // --- Ctrl-Z suspends, and picks everything back up on resume ---------
    // The point is not that zedit prints the right escapes but that it
    // really stops: the check reads the process state out of /proc, which is
    // `T` only when the kernel has actually stopped it.
    {
        const sdir = try ctx.tempDir();
        const f = h.join(ctx, sdir, "s.txt");
        defer ctx.gpa.free(f);
        h.writeFile(ctx.io, f, "suspendable\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--lsp", "", "s.txt" }, .cwd = sdir, .job_control = true });
        defer s.finish();
        s.drain(700);
        ctx.check("the file is showing before suspending", s.containsPlain(ctx.gpa, "suspendable"));

        const m = s.mark();
        s.send("\x1a"); // Ctrl-Z
        s.drain(500);
        // Everything the editor took has to go back before it stops.
        ctx.check("suspend leaves the alternate screen", s.containsSince(m, "\x1b[?1049l"));
        ctx.check("...and shows the cursor again", s.containsSince(m, "\x1b[?25h"));
        ctx.check("...and turns mouse reporting off", s.containsSince(m, "\x1b[?1006l"));

        // Poll for the stop rather than assuming a fixed delay: CI is slower
        // than a workstation, and waiting longer can only help.
        var stopped = false;
        var waited: usize = 0;
        while (waited < 2000) : (waited += 50) {
            const st = s.procState();
            if (st == 'T') {
                stopped = true;
                break;
            }
            s.drain(50);
        }
        ctx.check("Ctrl-Z actually stops the process", stopped);

        // Resume it the way a shell's `fg` would.
        const m2 = s.mark();
        s.signal(18); // SIGCONT
        s.drain(800);
        ctx.check("resuming re-enters the alternate screen", s.containsSince(m2, "\x1b[?1049h"));
        ctx.check("...and repaints the file", s.containsPlainSince(ctx.gpa, m2, "suspendable"));

        // And the editor still works afterwards.
        s.send("x:wq\r");
        s.drain(700);
        const got = h.readFile(ctx.gpa, ctx.io, f);
        defer ctx.gpa.free(got);
        ctx.check("editing works again after a resume", std.mem.eql(u8, got, "uspendable\n"));
    }
}

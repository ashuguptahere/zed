//! Sessions (`Space S s/l/d`, `:session save|load|delete`): the open files,
//! their cursors, the split layout and the tree's state, saved per working
//! directory and restored on demand — never on its own.
//!
//! Every session here lives under a temp `XDG_STATE_HOME`, so the run never
//! reads or writes the developer's real state directory.

const std = @import("std");
const h = @import("../harness.zig");

const ESC = "\x1b";
const CR = "\r";

pub fn run(ctx: *h.Ctx) !void {
    const dir = try ctx.tempDir();
    const state = h.join(ctx, dir, "state");
    defer ctx.gpa.free(state);
    const state_env = try std.fmt.allocPrint(ctx.gpa, "XDG_STATE_HOME={s}", .{state});
    defer ctx.gpa.free(state_env);

    const one = h.join(ctx, dir, "one.txt");
    defer ctx.gpa.free(one);
    const two = h.join(ctx, dir, "two.txt");
    defer ctx.gpa.free(two);
    const three = h.join(ctx, dir, "three.txt");
    defer ctx.gpa.free(three);
    h.writeFile(ctx.io, one, "a1\na2\na3\na4\na5\n");
    h.writeFile(ctx.io, two, "b1\nb2\nb3\n");
    h.writeFile(ctx.io, three, "c1\n");

    // --- save: two files, a split, the tree open, the cursor on line 4 ------
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", state_env, ctx.zedit, "one.txt" },
            .cwd = dir,
            .cols = 100,
        });
        defer s.finish();
        s.drain(600);
        s.send(":e two.txt" ++ CR);
        s.drain(400);
        s.send(":e three.txt" ++ CR);
        s.drain(400);
        s.send(":bp" ++ CR); // two.txt
        s.drain(400);
        s.send(":bp" ++ CR); // back to one.txt
        s.drain(400);
        s.send("3j"); // line 4
        s.drain(200);
        s.send(":vsplit" ++ CR); // three panes, one per file
        s.drain(400);
        s.send(":vsplit" ++ CR);
        s.drain(400);
        s.send(" e"); // open the tree
        s.drain(400);
        s.send(ESC); // unfocus it, keep it open
        s.drain(200);
        var m = s.mark();
        s.send(" ");
        s.drain(300);
        ctx.check("Space lists the session group", s.containsPlainSince(ctx.gpa, m, "Session"));
        s.send("S");
        s.drain(300);
        ctx.check("Space S lists save/load/delete", s.containsPlain(ctx.gpa, "save session") and
            s.containsPlain(ctx.gpa, "delete session"));
        m = s.mark();
        s.send("s");
        s.drain(500);
        ctx.check("Space S s saves the session", s.containsPlainSince(ctx.gpa, m, "session saved (3 files)"));
        s.send(":qa!" ++ CR);
        s.drain(400);
    }

    // --- load: a fresh editor in the same directory restores it -------------
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", state_env, ctx.zedit, "three.txt" },
            .cwd = dir,
            .cols = 100,
        });
        defer s.finish();
        s.drain(600);
        var m = s.mark();
        s.send(" Sl");
        s.drain(900);
        ctx.check("Space S l restores the session", s.containsPlainSince(ctx.gpa, m, "session restored (3 files)"));
        m = s.mark();
        s.send(":ls" ++ CR);
        s.drain(400);
        ctx.check("both saved files are open", s.containsPlainSince(ctx.gpa, m, "one.txt") and
            s.containsPlainSince(ctx.gpa, m, "two.txt"));
        // The cursor came back with the file: `x` on the restored line 4.
        s.send(ESC);
        s.drain(200);
        s.send("x:w" ++ CR);
        s.drain(500);
        const got = h.readFile(ctx.gpa, ctx.io, one);
        defer ctx.gpa.free(got);
        ctx.check("the cursor is restored to its saved line", std.mem.eql(u8, got, "a1\na2\na3\n4\na5\n"));
        // Two windows came back, each showing its own file — the text of both
        // is on screen at once, which one window could never manage.
        var scr = try h.Screen.init(ctx.gpa, 24, 100);
        defer scr.deinit();
        scr.apply(s.out.items);
        var a5 = false; // one.txt's last line
        var b3 = false; // two.txt's last line
        var c1 = false; // three.txt's only line
        var row: usize = 1;
        while (row <= scr.rows) : (row += 1) {
            const t = try scr.rowText(ctx.gpa, row);
            defer ctx.gpa.free(t);
            if (std.mem.indexOf(u8, t, "a5") != null) a5 = true;
            if (std.mem.indexOf(u8, t, "b3") != null) b3 = true;
            if (std.mem.indexOf(u8, t, "c1") != null) c1 = true;
        }
        ctx.check("the split layout is restored, a file per pane", a5 and b3 and c1);
        ctx.check("the tree came back open", s.containsPlain(ctx.gpa, "EXPLORER"));
        s.send(":qa!" ++ CR);
        s.drain(400);
    }

    // --- an unsaved buffer blocks the restore, rather than discarding it ----
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", state_env, ctx.zedit, "three.txt" },
            .cwd = dir,
            .cols = 100,
        });
        defer s.finish();
        s.drain(600);
        s.send("ixx" ++ ESC); // dirty it
        s.drain(300);
        const m = s.mark();
        s.send(" Sl");
        s.drain(600);
        ctx.check("a dirty buffer blocks the restore", s.containsPlainSince(ctx.gpa, m, "no write since last change"));
        ctx.check("the unsaved text survives the refusal", s.containsPlain(ctx.gpa, "xxc1"));
        s.send(":qa!" ++ CR);
        s.drain(400);
    }

    // --- a vanished file is skipped, and delete forgets the session ---------
    {
        h.runQuiet(ctx.gpa, ctx.io, &.{ "rm", "-f", two });
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", state_env, ctx.zedit, "three.txt" },
            .cwd = dir,
            .cols = 100,
        });
        defer s.finish();
        s.drain(600);
        var m = s.mark();
        s.send(":session load" ++ CR);
        s.drain(900);
        ctx.check("a deleted file is reported, not fatal", s.containsPlainSince(ctx.gpa, m, "2 files, 1 gone"));
        m = s.mark();
        s.send(":session delete" ++ CR);
        s.drain(400);
        ctx.check(":session delete removes it", s.containsPlainSince(ctx.gpa, m, "session deleted"));
        m = s.mark();
        s.send(":session load" ++ CR);
        s.drain(400);
        ctx.check("a deleted session is gone", s.containsPlainSince(ctx.gpa, m, "no session saved"));
        m = s.mark();
        s.send(":session wat" ++ CR);
        s.drain(300);
        ctx.check("an unknown subcommand shows the usage", s.containsPlainSince(ctx.gpa, m, "usage: :session"));
        s.send(":qa!" ++ CR);
        s.drain(400);
    }
}

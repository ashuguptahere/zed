//! The undo tree's own UI: `:undolist` lists every state and jumps to the one
//! picked, and the branch a redo cannot reach is still there to be chosen.
//!
//! The `g-`/`g+`/`:earlier`/`:later` semantics live in `vim_compat`, where they
//! are pinned byte-for-byte against real nvim.

const std = @import("std");
const h = @import("../harness.zig");

const ESC = "\x1b";
const CR = "\r";

pub fn run(ctx: *h.Ctx) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
    const path = try std.fmt.allocPrint(ctx.gpa, "{s}/u.txt", .{dir});
    defer ctx.gpa.free(path);

    // The list names every state, marks the current one, and flags the point
    // where history branched.
    {
        h.writeFile(ctx.io, path, "one\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "u.txt" }, .cwd = dir, .cols = 100 });
        defer s.finish();
        s.drain(400);
        s.sendKeys(&.{ "IA", ESC, "u", "IB", ESC }); // two branches from "one"
        s.drain(300);
        s.send(":undolist\r");
        s.drain(400);
        ctx.check("undolist is labelled", s.containsPlain(ctx.gpa, "UNDO TREE"));
        ctx.check("undolist shows each state", s.containsPlain(ctx.gpa, "0") and s.containsPlain(ctx.gpa, "2"));
        ctx.check("undolist marks the branch point", s.containsPlain(ctx.gpa, "(branch)"));
        s.send("\x1b:q!\r");
        s.drain(200);
    }

    // Picking a state restores it — including one no amount of redo reaches,
    // because it is on the branch that undo-then-edit left behind.
    {
        h.writeFile(ctx.io, path, "one\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "u.txt" }, .cwd = dir, .cols = 100 });
        defer s.finish();
        s.drain(400);
        s.sendKeys(&.{ "IA", ESC, "u", "IB", ESC }); // "Aone" is now stranded
        s.drain(300);
        s.send(":undolist\r");
        s.drain(400);
        // The list opens on the state the buffer is in (the last row, "Bone");
        // one step up is state 1, the abandoned "Aone".
        s.send("\x1b[A");
        s.drain(200);
        s.send("\r");
        s.drain(300);
        s.send(":wq\r");
        s.drain(400);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        const ok = std.mem.eql(u8, got, "Aone\n");
        if (!ok) std.debug.print("       got  \"{f}\"\n", .{std.zig.fmtString(got)});
        ctx.check("picking a state restores the abandoned branch", ok);
    }

    // A count on g- travels several states at once, and running out says so
    // rather than failing silently.
    {
        h.writeFile(ctx.io, path, "one\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "u.txt" }, .cwd = dir, .cols = 100 });
        defer s.finish();
        s.drain(400);
        s.sendKeys(&.{ "IA", ESC, "IB", ESC, "IC", ESC });
        s.drain(300);
        s.send("3g-");
        s.drain(300);
        ctx.check("a counted g- reports how far it went", s.containsPlain(ctx.gpa, "3 changes back"));
        s.send("g-");
        s.drain(300);
        ctx.check("and stops at the oldest state", s.containsPlain(ctx.gpa, "already at oldest change"));
        s.send(":wq\r");
        s.drain(400);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        ctx.check("3g- reaches the original text", std.mem.eql(u8, got, "one\n"));
    }

    // persistent_undo: the tree is written on save and picked up by the next
    // session, so `u` still reaches changes made before the editor was closed.
    {
        const state = try std.fmt.allocPrint(ctx.gpa, "{s}/state", .{dir});
        defer ctx.gpa.free(state);
        const cfg = try std.fmt.allocPrint(ctx.gpa, "{s}/cfg", .{dir});
        defer ctx.gpa.free(cfg);
        const xdg = try std.fmt.allocPrint(ctx.gpa, "XDG_STATE_HOME={s}", .{state});
        defer ctx.gpa.free(xdg);
        h.writeFile(ctx.io, cfg, "persistent_undo = true\n");
        h.writeFile(ctx.io, path, "one\n");

        // Plant siblings in the state dir before the first write: an undo
        // file long abandoned (90+ days by mtime), a fresh one, an old file
        // that is not an undo file, and an undo-file-named symlink whose
        // target is that old. Writing u.txt's history must prune exactly the
        // first — the symlink is not a regular file (and must never be
        // followed to its target's mtime).
        const undo_dir = try std.fmt.allocPrint(ctx.gpa, "{s}/zedit/undo", .{state});
        defer ctx.gpa.free(undo_dir);
        std.Io.Dir.cwd().createDirPath(ctx.io, undo_dir) catch {};
        const old_undo = try std.fmt.allocPrint(ctx.gpa, "{s}/00000000deadbeef.undo", .{undo_dir});
        defer ctx.gpa.free(old_undo);
        const fresh_undo = try std.fmt.allocPrint(ctx.gpa, "{s}/00000000cafebabe.undo", .{undo_dir});
        defer ctx.gpa.free(fresh_undo);
        const old_other = try std.fmt.allocPrint(ctx.gpa, "{s}/not-ours.txt", .{undo_dir});
        defer ctx.gpa.free(old_other);
        const link_undo = try std.fmt.allocPrint(ctx.gpa, "{s}/00000000feedface.undo", .{undo_dir});
        defer ctx.gpa.free(link_undo);
        h.writeFile(ctx.io, old_undo, "stale");
        h.writeFile(ctx.io, fresh_undo, "fresh");
        h.writeFile(ctx.io, old_other, "keep");
        h.runQuiet(ctx.gpa, ctx.io, &.{ "touch", "-d", "2020-01-01", old_undo });
        h.runQuiet(ctx.gpa, ctx.io, &.{ "touch", "-d", "2020-01-01", old_other });
        h.runQuiet(ctx.gpa, ctx.io, &.{ "ln", "-s", old_other, link_undo });

        {
            var s = try h.Session.spawn(ctx.gpa, .{
                .argv = &.{ "env", xdg, ctx.zedit, "--config", cfg, "u.txt" },
                .cwd = dir,
            });
            defer s.finish();
            s.drain(400);
            s.sendKeys(&.{ "IA", ESC, "IB", ESC, ":wq", CR }); // saved as "BAone"
            s.drain(500);
        }
        const saved = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(saved);
        ctx.check("the file was written", std.mem.eql(u8, saved, "BAone\n"));

        // The save wrote an undo file, which is the moment stale siblings go.
        const stale_after = h.readFile(ctx.gpa, ctx.io, old_undo);
        defer ctx.gpa.free(stale_after);
        ctx.check("a 90-day-old undo file is pruned on write", stale_after.len == 0);
        const fresh_after = h.readFile(ctx.gpa, ctx.io, fresh_undo);
        defer ctx.gpa.free(fresh_after);
        ctx.check("a recent sibling undo file survives", std.mem.eql(u8, fresh_after, "fresh"));
        const other_after = h.readFile(ctx.gpa, ctx.io, old_other);
        defer ctx.gpa.free(other_after);
        ctx.check("an old non-undo file is not ours to delete", std.mem.eql(u8, other_after, "keep"));
        var link_stat: bool = true;
        _ = std.Io.Dir.cwd().statFile(ctx.io, link_undo, .{ .follow_symlinks = false }) catch {
            link_stat = false;
        };
        ctx.check("an undo-named symlink is neither followed nor deleted", link_stat);

        {
            var s = try h.Session.spawn(ctx.gpa, .{
                .argv = &.{ "env", xdg, ctx.zedit, "--config", cfg, "u.txt" },
                .cwd = dir,
            });
            defer s.finish();
            s.drain(600);
            s.sendKeys(&.{ "u", "u", ":wq", CR }); // undo past the start of this session
            s.drain(500);
        }
        const undone = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(undone);
        const ok = std.mem.eql(u8, undone, "one\n");
        if (!ok) std.debug.print("       got  \"{f}\"\n", .{std.zig.fmtString(undone)});
        ctx.check("undo history survives closing the editor", ok);

        // A file changed behind zedit's back must not have the old history
        // applied to it: the past it describes is not this file's.
        h.writeFile(ctx.io, path, "something else entirely\n");
        {
            var s = try h.Session.spawn(ctx.gpa, .{
                .argv = &.{ "env", xdg, ctx.zedit, "--config", cfg, "u.txt" },
                .cwd = dir,
            });
            defer s.finish();
            s.drain(600);
            s.sendKeys(&.{ "u", ":wq", CR });
            s.drain(500);
        }
        const untouched = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(untouched);
        ctx.check("a stale undo file is ignored", std.mem.eql(u8, untouched, "something else entirely\n"));
    }

    // Without the setting, nothing is written and nothing is restored.
    {
        const state = try std.fmt.allocPrint(ctx.gpa, "{s}/state2", .{dir});
        defer ctx.gpa.free(state);
        const xdg = try std.fmt.allocPrint(ctx.gpa, "XDG_STATE_HOME={s}", .{state});
        defer ctx.gpa.free(xdg);
        h.writeFile(ctx.io, path, "one\n");
        {
            var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ "env", xdg, ctx.zedit, "u.txt" }, .cwd = dir });
            defer s.finish();
            s.drain(400);
            s.sendKeys(&.{ "IA", ESC, ":wq", CR });
            s.drain(500);
        }
        {
            var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ "env", xdg, ctx.zedit, "u.txt" }, .cwd = dir });
            defer s.finish();
            s.drain(500);
            s.sendKeys(&.{ "u", ":wq", CR });
            s.drain(500);
        }
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        ctx.check("persistent_undo off keeps history per session", std.mem.eql(u8, got, "Aone\n"));
    }

    // A bad argument explains itself instead of doing something surprising.
    {
        h.writeFile(ctx.io, path, "one\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "u.txt" }, .cwd = dir, .cols = 100 });
        defer s.finish();
        s.drain(400);
        s.send(":earlier soon\r");
        s.drain(300);
        ctx.check("a bad :earlier argument shows the usage", s.containsPlain(ctx.gpa, "usage: :earlier"));
        s.send(":q!\r");
        s.drain(200);
    }
}

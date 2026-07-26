//! Remote editing over SSH and the startup screen.
//!
//! The SSH cases run against a mock `ssh` shell script placed first on `PATH`,
//! which maps remote commands onto a local directory — so they exercise the
//! real argv construction, quoting and stream handling in `remote.zig` without
//! needing a reachable host or credentials. The startup-screen cases point
//! `XDG_STATE_HOME` at a temp dir so the recent list is per-test.

const std = @import("std");
const h = @import("../harness.zig");

/// A stand-in for `ssh`: skips ssh options and the destination, rewrites the
/// sentinel remote root into `$MOCK_REMOTE_ROOT`, and runs the rest locally.
/// With `$MOCK_SSH_LOG` set, every remote command is appended there — one
/// line per ssh invocation, so a scenario can count spawns.
const mock_ssh =
    \\#!/bin/bash
    \\while [[ $# -gt 0 ]]; do
    \\  case "$1" in
    \\    -o|-p) shift 2 ;;
    \\    -*) shift ;;
    \\    *) shift; break ;;
    \\  esac
    \\done
    \\cmd="$*"
    \\if [[ -n $MOCK_SSH_LOG ]]; then printf '%s\n' "$cmd" >> "$MOCK_SSH_LOG"; fi
    \\bash -c "${cmd//\/remotefs/$MOCK_REMOTE_ROOT}"
    \\
;

/// Lines in the mock-ssh invocation log that contain `needle` — e.g. the
/// number of ssh spawns that carried a write command.
fn sshLogCount(ctx: *h.Ctx, log_path: []const u8, needle: []const u8) usize {
    const text = h.readFile(ctx.gpa, ctx.io, log_path);
    defer ctx.gpa.free(text);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) n += 1;
    }
    return n;
}

/// Whether any `.zedit.tmp.*` write-temp file is left under `dir_path`: a
/// completed write must rename its temp away, success or failure.
fn tmpLeftover(ctx: *h.Ctx, dir_path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(ctx.io);
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (std.mem.indexOf(u8, entry.name, ".zedit.tmp.") != null) return true;
    }
    return false;
}

pub fn run(ctx: *h.Ctx) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    // Fake remote filesystem + the mock ssh on PATH.
    const bin = h.join(ctx, dir, "bin");
    defer ctx.gpa.free(bin);
    const rroot = h.join(ctx, dir, "remote");
    defer ctx.gpa.free(rroot);
    const rsub = h.join(ctx, dir, "remote/sub");
    defer ctx.gpa.free(rsub);
    std.Io.Dir.cwd().createDirPath(ctx.io, bin) catch {};
    std.Io.Dir.cwd().createDirPath(ctx.io, rsub) catch {};
    const ssh_path = h.join(ctx, dir, "bin/ssh");
    defer ctx.gpa.free(ssh_path);
    h.writeFile(ctx.io, ssh_path, mock_ssh);
    h.runQuiet(ctx.gpa, ctx.io, &.{ "chmod", "+x", ssh_path });

    const rfile = h.join(ctx, dir, "remote/hello.txt");
    defer ctx.gpa.free(rfile);
    h.writeFile(ctx.io, rfile, "remote alpha\nremote beta\n");
    const rdeep = h.join(ctx, dir, "remote/sub/deep.txt");
    defer ctx.gpa.free(rdeep);
    h.writeFile(ctx.io, rdeep, "nested\n");
    // A path with a space and a quote: the shell-quoting must keep it inert.
    const rodd = h.join(ctx, dir, "remote/od'd name.txt");
    defer ctx.gpa.free(rodd);
    h.writeFile(ctx.io, rodd, "odd\n");

    const path_env = try std.fmt.allocPrint(ctx.gpa, "PATH={s}:/usr/bin:/bin", .{bin});
    defer ctx.gpa.free(path_env);
    const root_env = try std.fmt.allocPrint(ctx.gpa, "MOCK_REMOTE_ROOT={s}", .{rroot});
    defer ctx.gpa.free(root_env);

    // Open a remote file, edit it, write it back over ssh.
    {
        const ssh_log = h.join(ctx, dir, "ssh.log");
        defer ctx.gpa.free(ssh_log);
        const log_env = try std.fmt.allocPrint(ctx.gpa, "MOCK_SSH_LOG={s}", .{ssh_log});
        defer ctx.gpa.free(log_env);
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", path_env, root_env, log_env, ctx.zedit, "ssh://testhost/remotefs/hello.txt" },
            .cwd = dir,
        });
        defer s.finish();
        s.drain(900);
        ctx.check("remote file content is shown", s.containsPlain(ctx.gpa, "remote alpha"));
        // The filename moved from the statusline into the title bar's tab,
        // which shows the basename (as it does for local files).
        ctx.check("title bar names the remote file", s.containsPlain(ctx.gpa, "hello.txt"));
        s.send("x:w\r"); // delete a char, write back through ssh
        s.drain(800);
        const after = h.readFile(ctx.gpa, ctx.io, rfile);
        defer ctx.gpa.free(after);
        ctx.check("write goes back over ssh", std.mem.eql(u8, after, "emote alpha\nremote beta\n"));
        // The write went through a temp file renamed into place; a clean
        // write must not leave the temp behind.
        ctx.check("write leaves no temp file behind", !tmpLeftover(ctx, rroot));
        // The temp+rename pipeline is one composed command: exactly one ssh
        // spawn carried the whole write.
        ctx.check("a write is exactly one ssh spawn", sshLogCount(ctx, ssh_log, ".zedit.tmp.") == 1);
        s.send(":q!\r");
        s.drain(200);
    }

    // A remote path containing a space and a single quote round-trips: proof
    // the remote command is quoted, not interpolated.
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", path_env, root_env, ctx.zedit, "ssh://testhost/remotefs/od'd name.txt" },
            .cwd = dir,
        });
        defer s.finish();
        s.drain(900);
        ctx.check("odd remote path opens", s.containsPlain(ctx.gpa, "odd"));
        s.send("ix\x1b:w\r");
        s.drain(800);
        const after = h.readFile(ctx.gpa, ctx.io, rodd);
        defer ctx.gpa.free(after);
        ctx.check("odd remote path writes back", std.mem.eql(u8, after, "xodd\n"));
        ctx.check("odd path leaves no temp file behind", !tmpLeftover(ctx, rroot));
        s.send(":q!\r");
        s.drain(200);
    }

    // Atomicity: a write whose transfer fails must leave the target exactly
    // as it was — the temp file takes the failure, the rename never runs and
    // a non-zero exit reports the write as failed. A directory the temp
    // cannot be created in stands in for the failed transfer (the target
    // itself stays writable, so the old `cat > target` would have clobbered
    // it here).
    {
        h.writeFile(ctx.io, rfile, "keep me\n");
        h.runQuiet(ctx.gpa, ctx.io, &.{ "chmod", "555", rroot });
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", path_env, root_env, ctx.zedit, "ssh://testhost/remotefs/hello.txt" },
            .cwd = dir,
        });
        defer s.finish();
        s.drain(900);
        ctx.check("read-only remote dir still opens", s.containsPlain(ctx.gpa, "keep me"));
        s.send("x:w\r");
        s.drain(800);
        h.runQuiet(ctx.gpa, ctx.io, &.{ "chmod", "755", rroot });
        ctx.check("failed remote write is reported", s.containsPlain(ctx.gpa, "write failed"));
        const after = h.readFile(ctx.gpa, ctx.io, rfile);
        defer ctx.gpa.free(after);
        ctx.check("failed remote write never touches the target", std.mem.eql(u8, after, "keep me\n"));
        s.send(":q!\r");
        s.drain(200);
    }

    // A target that is an existing directory is refused up front: without
    // the guard, `mv` would move the temp *into* the directory and exit 0 —
    // a "successful" write that created nothing at the asked-for path.
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", path_env, root_env, ctx.zedit, "ssh://testhost/remotefs/hello.txt" },
            .cwd = dir,
        });
        defer s.finish();
        s.drain(900);
        s.send(":w ssh://testhost/remotefs/sub\r"); // sub/ is a directory
        s.drain(800);
        ctx.check("writing onto a remote directory is refused", s.containsPlain(ctx.gpa, "write failed"));
        ctx.check("no temp file dropped into the directory", !tmpLeftover(ctx, rsub) and !tmpLeftover(ctx, rroot));
        s.send(":q!\r");
        s.drain(200);
    }

    // A remote directory starts in the picker, listing the remote tree; the
    // filtered pick opens over ssh.
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", path_env, root_env, ctx.zedit, "ssh://testhost/remotefs" },
            .cwd = dir,
        });
        defer s.finish();
        s.drain(1200);
        ctx.check("remote directory lists files in the picker", s.containsPlain(ctx.gpa, "hello.txt") and
            s.containsPlain(ctx.gpa, "deep.txt"));
        s.send("deep\r"); // filter to the nested file and open it
        s.drain(900);
        ctx.check("picking a remote file opens it", s.containsPlain(ctx.gpa, "nested"));
        s.send(":qa!\r");
        s.drain(200);
    }

    // `:ssh host` browses the login directory (the mock maps it to the root).
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", path_env, root_env, ctx.zedit, "ssh://testhost/remotefs/hello.txt" },
            .cwd = dir,
        });
        defer s.finish();
        s.drain(800);
        s.send(":ssh testhost/remotefs\r");
        s.drain(1200);
        ctx.check(":ssh opens the remote picker", s.containsPlain(ctx.gpa, "FILES") and
            s.containsPlain(ctx.gpa, "hello.txt"));
        s.send("\x1b:qa!\r");
        s.drain(200);
    }

    // An unreachable host fails with a readable message, never a hang.
    {
        const failing_ssh =
            \\#!/bin/bash
            \\echo "ssh: connect to host nope port 22: No route to host" >&2
            \\exit 255
            \\
        ;
        h.writeFile(ctx.io, ssh_path, failing_ssh);
        h.runQuiet(ctx.gpa, ctx.io, &.{ "chmod", "+x", ssh_path });
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", path_env, root_env, ctx.zedit, "ssh://nope/remotefs/x.txt" },
            .cwd = dir,
        });
        defer s.finish();
        s.drain(1000);
        ctx.check("unreachable host is reported, not hung", s.containsPlain(ctx.gpa, "cannot open") or
            s.containsPlain(ctx.gpa, "ssh"));
        s.send(":q!\r");
        s.drain(200);
    }

    // --- startup screen -------------------------------------------------
    {
        const state = h.join(ctx, dir, "state");
        defer ctx.gpa.free(state);
        const state_dir = h.join(ctx, dir, "state/zedit");
        defer ctx.gpa.free(state_dir);
        std.Io.Dir.cwd().createDirPath(ctx.io, state_dir) catch {};
        const a_txt = h.join(ctx, dir, "alpha.txt");
        defer ctx.gpa.free(a_txt);
        const b_txt = h.join(ctx, dir, "beta.txt");
        defer ctx.gpa.free(b_txt);
        h.writeFile(ctx.io, a_txt, "aaa\n");
        h.writeFile(ctx.io, b_txt, "bbb\n");
        const recent_file = h.join(ctx, dir, "state/zedit/recent");
        defer ctx.gpa.free(recent_file);
        const listing = try std.fmt.allocPrint(ctx.gpa, "f {s}\nf {s}\nf {s}/gone.txt\n", .{ a_txt, b_txt, dir });
        defer ctx.gpa.free(listing);
        h.writeFile(ctx.io, recent_file, listing);

        const state_env = try std.fmt.allocPrint(ctx.gpa, "XDG_STATE_HOME={s}", .{state});
        defer ctx.gpa.free(state_env);

        // No file argument: the startup screen lists the recent entries.
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ "env", state_env, ctx.zedit }, .cwd = dir });
        defer s.finish();
        s.drain(700);
        ctx.check("startup screen lists recent files", s.containsPlain(ctx.gpa, "alpha.txt") and
            s.containsPlain(ctx.gpa, "beta.txt"));
        ctx.check("startup screen shows the version", s.containsPlain(ctx.gpa, "zedit") and
            s.containsPlain(ctx.gpa, "Recent"));
        ctx.check("vanished entries are pruned", !s.containsPlain(ctx.gpa, "gone.txt"));

        // j then Enter opens the second entry.
        s.send("j\r");
        s.drain(700);
        s.send("x:w\r"); // bbb -> bb proves beta.txt was opened
        s.drain(500);
        const bb = h.readFile(ctx.gpa, ctx.io, b_txt);
        defer ctx.gpa.free(bb);
        ctx.check("startup screen opens the selected entry", std.mem.eql(u8, bb, "bb\n"));
        s.send(":q!\r");
        s.drain(300);

        // The opened file is remembered, newest first, for the next session.
        const saved = h.readFile(ctx.gpa, ctx.io, recent_file);
        defer ctx.gpa.free(saved);
        const first_line_end = std.mem.indexOfScalar(u8, saved, '\n') orelse saved.len;
        ctx.check("recent list records the newest first", std.mem.indexOf(u8, saved[0..first_line_end], "beta.txt") != null);

        // A file argument skips the screen entirely.
        var s2 = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ "env", state_env, ctx.zedit, "alpha.txt" }, .cwd = dir });
        defer s2.finish();
        s2.drain(700);
        ctx.check("a file argument skips the startup screen", !s2.containsPlain(ctx.gpa, "Recent") and
            s2.containsPlain(ctx.gpa, "aaa"));
        s2.send(":q!\r");
        s2.drain(200);
    }

    // --check-update runs headless and prints a verdict (no network needed for
    // the failure path; with network it reports up-to-date or an update).
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--check-update" }, .cwd = dir });
        defer s.finish();
        s.drain(2500);
        ctx.check("--check-update reports a verdict", s.containsPlain(ctx.gpa, "up to date") or
            s.containsPlain(ctx.gpa, "update available") or
            s.containsPlain(ctx.gpa, "no releases") or
            s.containsPlain(ctx.gpa, "cannot"));
    }
}

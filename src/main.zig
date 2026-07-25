//! zedit — a terminal code editor in Zig.
//!
//! `main` is the composition root: it parses the command line, optionally turns
//! on logging, loads the buffer, puts the terminal into editing mode and runs
//! the editor loop. Its other job is failure handling — every exit path leaves
//! the terminal restored and prints a human-readable message.

const std = @import("std");
const cli = @import("cli.zig");
const log = @import("log.zig");
const term = @import("term.zig");
const buffer = @import("buffer.zig");
const editor = @import("editor.zig");
const config = @import("config.zig");

const search = @import("search.zig");
const remote = @import("remote.zig");
const regex = @import("regex.zig");

const tutor_text = @embedFile("tutor_text");

/// Route std.log through our file logger.
pub const std_options = log.options;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var cfg = switch (cli.parse(argv)) {
        .help => return cli.printHelp(),
        .version => return cli.printVersion(),
        .init_config => {
            var pbuf: [512]u8 = undefined;
            const path = config.writeDefault(io, &pbuf) catch |err| {
                switch (err) {
                    error.PathAlreadyExists => cli.printError("config file already exists — edit it instead"),
                    error.NoHome => cli.printError("cannot locate a config directory (no $HOME)"),
                    else => cli.printError("cannot write the config file"),
                }
                std.process.exit(1);
            };
            cli.printNote(path);
            return;
        },
        .err => |message| {
            cli.printError(message);
            std.process.exit(2);
        },
        .run => |c| c,
    };

    if (cfg.log_path) |path| {
        if (!log.enable(path)) cli.printError("cannot open the log file — logging disabled");
    }
    defer log.disable();
    std.log.scoped(.main).info("starting zedit, file={s}", .{cfg.file orelse "<none>"});

    if (cfg.benchmark) return runBenchmark(gpa, io, cfg.file);
    if (cfg.check_update) return checkUpdate(gpa, io);

    if (!config.load(gpa, io, cfg.config_path) and cfg.config_path != null) {
        // An explicit --config that cannot be read is a mistake the user
        // asked to be told about; the implicit path stays best-effort.
        cli.printError("cannot read that config file — using defaults");
    }

    // A directory argument (e.g. `zedit .`) becomes the working directory and
    // the session starts in the file picker — the nvim/helix habit. An
    // `ssh://host/dir` URL does the same over ssh (see remote.zig).
    var open_picker = false;
    var remote_dir: ?[]const u8 = null;
    if (cfg.file) |p| {
        if (remote.parse(p)) |target| {
            if (remote.isDir(gpa, io, target)) {
                remote_dir = p;
                cfg.file = null;
                open_picker = true;
            }
        } else if (isDirectory(io, p)) {
            std.process.setCurrentPath(io, p) catch {
                cli.printError("cannot enter that directory (permission denied?)");
                std.process.exit(1);
            };
            cfg.file = null;
            open_picker = true;
        }
    }

    var buf = if (cfg.tutor)
        buffer.Buffer.fromBytes(gpa, tutor_text) catch {
            cli.printError("out of memory loading the tutorial");
            std.process.exit(1);
        }
    else
        openBuffer(gpa, io, cfg.file) catch std.process.exit(1);

    var terminal = term.Terminal.init() catch |err| {
        buf.deinit();
        switch (err) {
            error.NotATerminal => cli.printError("not a terminal — run zedit in an interactive terminal"),
            else => {
                var eb: [128]u8 = undefined;
                cli.printError(std.fmt.bufPrint(&eb, "cannot set up the terminal ({s})", .{@errorName(err)}) catch "cannot set up the terminal");
            },
        }
        std.log.scoped(.main).err("terminal init failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    // From here the editor owns `buf`; only `ed.deinit` frees it.
    var ed = editor.Editor.init(gpa, io, &terminal, buf, cfg.lsp_cmd) catch |err| {
        buf.deinit();
        terminal.restore();
        var eb: [128]u8 = undefined;
        cli.printError(std.fmt.bufPrint(&eb, "cannot start the editor ({s})", .{@errorName(err)}) catch "cannot start the editor");
        std.log.scoped(.main).err("editor init failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer ed.deinit();
    defer terminal.restore();

    // Recently-opened list: drives the startup screen when no file was given.
    ed.startSession(null, cfg.file == null and !cfg.tutor and !open_picker);
    if (cfg.file) |p| ed.noteRecent(p, .file);
    if (remote_dir) |d| {
        ed.openRemoteDir(d);
    } else if (open_picker) {
        ed.noteRecentCwd();
        ed.openFilePicker();
    }

    ed.run() catch |err| {
        terminal.restore();
        std.log.scoped(.main).err("fatal: {s}", .{@errorName(err)});
        cli.printError(@errorName(err));
        std.process.exit(1);
    };
}

/// `--check-update`: compare this build's version with the newest published
/// release tag. Runs without a terminal, so scripts and CI can use it.
fn checkUpdate(gpa: std.mem.Allocator, io: std.Io) void {
    const url = "https://github.com/ashuguptahere/zed.git";
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "git", "ls-remote", "--tags", "--refs", url },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(8 << 10),
    }) catch {
        cli.printError("cannot check for updates (is git installed?)");
        std.process.exit(1);
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) {
            std.log.scoped(.main).warn("ls-remote failed: {s}", .{std.mem.trim(u8, res.stderr, " \n")});
            cli.printError("cannot reach the release server (no network?)");
            std.process.exit(1);
        },
        else => {
            cli.printError("cannot check for updates");
            std.process.exit(1);
        },
    }
    var b: [256]u8 = undefined;
    const newest = editor.newestReleaseTag(res.stdout) orelse {
        cli.printOut("zedit: no releases published yet\n");
        return;
    };
    if (editor.versionIsNewer(newest, cli.version)) {
        cli.printOut(std.fmt.bufPrint(&b, "zedit: update available — {s} (you have {s})\n" ++
            "  https://github.com/ashuguptahere/zed/releases/latest\n", .{ newest, cli.version }) catch return);
    } else {
        cli.printOut(std.fmt.bufPrint(&b, "zedit: up to date ({s})\n", .{cli.version}) catch return);
    }
}

fn isDirectory(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// `--benchmark`: time the hot paths on a real file (or synthetic data) and
/// print a small human-readable report. Needs no terminal, so it works in
/// scripts and CI.
fn runBenchmark(gpa: std.mem.Allocator, io: std.Io, path: ?[]const u8) void {
    var out: [1024]u8 = undefined;
    var n: usize = 0;

    // Load (or synthesise ~10 MB of plausible source text).
    const t_load = log.nowNanos();
    var buf: buffer.Buffer = undefined;
    if (path) |p| {
        buf = buffer.Buffer.load(gpa, io, p) catch {
            cli.printError("cannot open that file to benchmark it");
            std.process.exit(1);
        };
    } else {
        const line = "const value = compute(alpha, beta) + gamma[index];\n";
        const reps = (10 << 20) / line.len;
        const data = gpa.alloc(u8, reps * line.len) catch std.process.exit(1);
        var i: usize = 0;
        while (i < reps) : (i += 1) @memcpy(data[i * line.len ..][0..line.len], line);
        buf = buffer.Buffer.fromOwnedBytes(gpa, data) catch std.process.exit(1);
    }
    defer buf.deinit();
    const load_ms = msSince(t_load);

    const bytes = if (buf.source) |s| s.len else 0;
    n += (std.fmt.bufPrint(out[n..], "target      {s} ({d} lines, {Bi:.1})\n", .{
        path orelse "synthetic", buf.lineCount(), bytes,
    }) catch return).len;
    n += (std.fmt.bufPrint(out[n..], "open        {d:.2} ms\n", .{load_ms}) catch return).len;

    // Literal search across the whole buffer (the SIMD fast path).
    const t_lit = log.nowNanos();
    var matches: usize = 0;
    var pos: search.Pos = .{ .row = 0, .col = 0 };
    while (search.nextLiteral(&buf, pos, "gamma")) |m| {
        if (m.row < pos.row or (m.row == pos.row and m.col <= pos.col and matches > 0)) break; // wrapped
        matches += 1;
        pos = m;
        if (matches > 1_000_000) break;
    }
    n += (std.fmt.bufPrint(out[n..], "search      {d:.2} ms ({d} literal matches)\n", .{ msSince(t_lit), matches }) catch return).len;

    // Regex search (Pike VM) over the same content.
    var re = regex.Regex.compile(gpa, "ga\\w+a", false) catch std.process.exit(1);
    defer re.deinit(gpa);
    const t_re = log.nowNanos();
    var re_matches: usize = 0;
    var rpos: search.Pos = .{ .row = 0, .col = 0 };
    while (search.next(&buf, rpos, &re)) |m| {
        if (m.row < rpos.row or (m.row == rpos.row and m.col <= rpos.col and re_matches > 0)) break;
        re_matches += 1;
        rpos = m;
        if (re_matches > 1_000_000) break;
    }
    n += (std.fmt.bufPrint(out[n..], "regex       {d:.2} ms ({d} matches)\n", .{ msSince(t_re), re_matches }) catch return).len;

    // Serialise (what :w does before writing).
    const t_ser = log.nowNanos();
    const serialized = buf.toBytes(gpa) catch std.process.exit(1);
    gpa.free(serialized);
    n += (std.fmt.bufPrint(out[n..], "serialize   {d:.2} ms\n", .{msSince(t_ser)}) catch return).len;

    cli.printOut(out[0..n]);
}

fn msSince(start: i128) f64 {
    return @as(f64, @floatFromInt(log.nowNanos() - start)) / 1_000_000.0;
}

/// Load `path`, or start with an empty buffer when no file was given. On
/// failure, print a friendly message and signal the caller to exit.
fn openBuffer(gpa: std.mem.Allocator, io: std.Io, path: ?[]const u8) !buffer.Buffer {
    const p = path orelse return buffer.Buffer.initEmpty(gpa);
    return buffer.Buffer.load(gpa, io, p) catch |err| {
        var b: [512]u8 = undefined;
        const reason: []const u8 = switch (err) {
            error.StreamTooLong => "file is too large (2 GB cap)",
            error.AccessDenied, error.PermissionDenied => "permission denied",
            error.IsDir, error.NotDir => "that is a directory",
            error.OutOfMemory => "out of memory",
            else => @errorName(err),
        };
        const msg = std.fmt.bufPrint(&b, "cannot open {s}: {s}", .{ p, reason }) catch "cannot open file";
        cli.printError(msg);
        std.log.scoped(.main).err("open failed: {s}", .{@errorName(err)});
        return err;
    };
}

test {
    // Pull every module's test blocks into `zig build test`.
    _ = @import("unicode.zig");
    _ = @import("key.zig");
    _ = @import("buffer.zig");
    _ = @import("cli.zig");
    _ = @import("term.zig");
    _ = @import("log.zig");
    _ = @import("motion.zig");
    _ = @import("register.zig");
    _ = @import("undo.zig");
    _ = @import("search.zig");
    _ = @import("regex.zig");
    _ = @import("theme.zig");
    _ = @import("syntax.zig");
    _ = @import("fuzzy.zig");
    _ = @import("config.zig");
    _ = @import("git.zig");
    _ = @import("recent.zig");
    _ = @import("remote.zig");
    _ = @import("lsp.zig");
    _ = @import("treesitter.zig");
    _ = @import("editor.zig");
}

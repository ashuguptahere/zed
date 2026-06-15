//! zed — a terminal code editor in Zig.
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

/// Route std.log through our file logger.
pub const std_options = log.options;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    const cfg = switch (cli.parse(argv)) {
        .help => return cli.printHelp(),
        .version => return cli.printVersion(),
        .err => |message| {
            cli.printError(message);
            std.process.exit(2);
        },
        .run => |c| c,
    };

    if (cfg.log_path) |path| log.enable(path);
    defer log.disable();
    std.log.scoped(.main).info("starting zed, file={s}", .{cfg.file orelse "<none>"});

    var buf = openBuffer(gpa, io, cfg.file) catch std.process.exit(1);

    var terminal = term.Terminal.init() catch |err| {
        buf.deinit();
        switch (err) {
            error.NotATerminal => cli.printError("not a terminal — run zed in an interactive terminal"),
            else => cli.printError(@errorName(err)),
        }
        std.process.exit(1);
    };

    // From here the editor owns `buf`; only `ed.deinit` frees it.
    var ed = editor.Editor.init(gpa, io, &terminal, buf);
    defer ed.deinit();
    defer terminal.restore();

    ed.run() catch |err| {
        terminal.restore();
        std.log.scoped(.main).err("fatal: {s}", .{@errorName(err)});
        cli.printError(@errorName(err));
        std.process.exit(1);
    };
}

/// Load `path`, or start with an empty buffer when no file was given. On
/// failure, print a friendly message and signal the caller to exit.
fn openBuffer(gpa: std.mem.Allocator, io: std.Io, path: ?[]const u8) !buffer.Buffer {
    const p = path orelse return buffer.Buffer.initEmpty(gpa);
    return buffer.Buffer.load(gpa, io, p) catch |err| {
        var b: [512]u8 = undefined;
        const reason: []const u8 = switch (err) {
            error.StreamTooLong => "file is too large",
            error.AccessDenied, error.PermissionDenied => "permission denied",
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
    _ = @import("theme.zig");
    _ = @import("syntax.zig");
    _ = @import("editor.zig");
}

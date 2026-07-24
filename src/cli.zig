//! Command-line parsing and the user-facing help/version text.
//!
//! Parsing is deliberately small and explicit. The result is a tagged union so
//! `main` decides what to print and which exit code to use, keeping I/O policy
//! in one place.

const std = @import("std");
const posix = std.posix;

pub const version = "0.1.0";

pub const Config = struct {
    file: ?[]const u8 = null,
    log_path: ?[]const u8 = null,
    lsp_cmd: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    tutor: bool = false,
};

pub const Parsed = union(enum) {
    run: Config,
    help,
    version,
    init_config,
    err: []const u8,
};

/// Parse `argv` (including argv[0]). Never allocates; returned slices borrow
/// from `argv`, which lives for the whole process.
pub fn parse(argv: []const [:0]const u8) Parsed {
    var cfg: Config = .{};
    var i: usize = 1;
    var positional_only = false;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (!positional_only and arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            if (eql(arg, "--")) {
                positional_only = true;
            } else if (eql(arg, "-h") or eql(arg, "--help")) {
                return .help;
            } else if (eql(arg, "-V") or eql(arg, "--version")) {
                return .version;
            } else if (eql(arg, "--log")) {
                i += 1;
                if (i >= argv.len) return .{ .err = "--log requires a file path" };
                cfg.log_path = argv[i];
            } else if (prefix(arg, "--log=")) {
                cfg.log_path = arg["--log=".len..];
            } else if (eql(arg, "--lsp")) {
                i += 1;
                if (i >= argv.len) return .{ .err = "--lsp requires a server command" };
                cfg.lsp_cmd = argv[i];
            } else if (prefix(arg, "--lsp=")) {
                cfg.lsp_cmd = arg["--lsp=".len..];
            } else if (eql(arg, "--config")) {
                i += 1;
                if (i >= argv.len) return .{ .err = "--config requires a file path" };
                cfg.config_path = argv[i];
            } else if (prefix(arg, "--config=")) {
                cfg.config_path = arg["--config=".len..];
            } else if (eql(arg, "--tutor")) {
                cfg.tutor = true;
            } else if (eql(arg, "--init-config")) {
                return .init_config;
            } else {
                return .{ .err = "unknown option (try --help)" };
            }
        } else {
            if (cfg.file != null) return .{ .err = "only one file may be opened at a time" };
            cfg.file = arg;
        }
    }
    return .{ .run = cfg };
}

const help_text =
    \\zedit — a terminal code editor in Zig
    \\
    \\Usage:
    \\  zedit [options] [file]
    \\
    \\Options:
    \\  -h, --help           Show this help and exit
    \\  -V, --version        Show version and exit
    \\      --log <path>     Write diagnostic logs to <path>
    \\      --lsp <cmd>      Language server command (e.g. "zls"); defaults per filetype
    \\      --config <path>  Use <path> instead of ~/.config/zedit/config
    \\      --init-config    Write the documented default config file and exit
    \\      --tutor          Open the interactive tutorial (like vimtutor)
    \\
    \\Keys (normal mode):
    \\  h j k l           Move left/down/up/right
    \\  0 $               Start / end of line
    \\  g G               First / last line
    \\  i a o             Insert before / after cursor / on a new line
    \\  x                 Delete character
    \\  :                 Command line  (:w write, :q quit, :wq, :q!)
    \\
    \\Insert mode: type to edit, Esc returns to normal mode.
    \\
    \\Examples:
    \\  zedit                 Start with an empty buffer
    \\  zedit src/main.zig    Open a file
    \\  zedit --log zedit.log notes.txt
    \\
;

pub fn printHelp() void {
    writeFd(posix.STDOUT_FILENO, help_text);
}

pub fn printVersion() void {
    writeFd(posix.STDOUT_FILENO, "zedit " ++ version ++ "\n");
}

pub fn printError(message: []const u8) void {
    writeFd(posix.STDERR_FILENO, "zedit: ");
    writeFd(posix.STDERR_FILENO, message);
    writeFd(posix.STDERR_FILENO, "\n");
}

/// Print a normal (non-error) one-liner, e.g. where --init-config wrote to.
pub fn printNote(message: []const u8) void {
    writeFd(posix.STDOUT_FILENO, "zedit: wrote ");
    writeFd(posix.STDOUT_FILENO, message);
    writeFd(posix.STDOUT_FILENO, "\n");
}

fn writeFd(fd: posix.fd_t, bytes: []const u8) void {
    var i: usize = 0;
    while (i < bytes.len) {
        const rc = posix.system.write(fd, bytes.ptr + i, bytes.len - i);
        switch (posix.system.errno(rc)) {
            .SUCCESS => i += @intCast(rc),
            .INTR, .AGAIN => continue,
            else => return,
        }
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn prefix(a: []const u8, p: []const u8) bool {
    return std.mem.startsWith(u8, a, p);
}

test "parse file and flags" {
    const argv = [_][:0]const u8{ "zedit", "--log", "x.log", "file.txt" };
    const r = parse(&argv);
    try std.testing.expect(r == .run);
    try std.testing.expectEqualStrings("file.txt", r.run.file.?);
    try std.testing.expectEqualStrings("x.log", r.run.log_path.?);
}

test "parse help and version" {
    try std.testing.expect(parse(&[_][:0]const u8{ "zedit", "--help" }) == .help);
    try std.testing.expect(parse(&[_][:0]const u8{ "zedit", "-V" }) == .version);
}

test "parse errors" {
    try std.testing.expect(parse(&[_][:0]const u8{ "zedit", "--nope" }) == .err);
    try std.testing.expect(parse(&[_][:0]const u8{ "zedit", "--log" }) == .err);
    try std.testing.expect(parse(&[_][:0]const u8{ "zedit", "a", "b" }) == .err);
}

test "double dash forces positional" {
    const r = parse(&[_][:0]const u8{ "zedit", "--", "-weird-name" });
    try std.testing.expect(r == .run);
    try std.testing.expectEqualStrings("-weird-name", r.run.file.?);
}

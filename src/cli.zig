//! Command-line parsing and the user-facing help/version text.
//!
//! Parsing is deliberately small and explicit. The result is a tagged union so
//! `main` decides what to print and which exit code to use, keeping I/O policy
//! in one place.

const std = @import("std");
const posix = std.posix;
const log = @import("log.zig");

/// The release version, read from the VERSION file at the repo root (the
/// single source of truth; CHANGELOG.md documents each release).
pub const version = std.mem.trim(u8, @embedFile("version_text"), " \n\r");

pub const Config = struct {
    file: ?[]const u8 = null,
    log_path: ?[]const u8 = null,
    lsp_cmd: ?[]const u8 = null,
    dap_cmd: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    tutor: bool = false,
    benchmark: bool = false,
    check_update: bool = false,
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
            } else if (eql(arg, "-v") or eql(arg, "-V") or eql(arg, "--version")) {
                return .version;
            } else if (eql(arg, "-l") or eql(arg, "--log")) {
                i += 1;
                if (i >= argv.len) return .{ .err = "--log requires a file path" };
                cfg.log_path = argv[i];
            } else if (prefix(arg, "--log=")) {
                cfg.log_path = arg["--log=".len..];
            } else if (eql(arg, "-s") or eql(arg, "--lsp")) {
                i += 1;
                if (i >= argv.len) return .{ .err = "--lsp requires a server command" };
                cfg.lsp_cmd = argv[i];
            } else if (prefix(arg, "--lsp=")) {
                cfg.lsp_cmd = arg["--lsp=".len..];
            } else if (eql(arg, "-D") or eql(arg, "--dap")) {
                i += 1;
                if (i >= argv.len) return .{ .err = "--dap requires an adapter command" };
                cfg.dap_cmd = argv[i];
            } else if (prefix(arg, "--dap=")) {
                cfg.dap_cmd = arg["--dap=".len..];
            } else if (eql(arg, "-c") or eql(arg, "--config")) {
                i += 1;
                if (i >= argv.len) return .{ .err = "--config requires a file path" };
                cfg.config_path = argv[i];
            } else if (prefix(arg, "--config=")) {
                cfg.config_path = arg["--config=".len..];
            } else if (eql(arg, "-t") or eql(arg, "--tutor")) {
                cfg.tutor = true;
            } else if (eql(arg, "-b") or eql(arg, "--benchmark")) {
                cfg.benchmark = true;
            } else if (eql(arg, "-u") or eql(arg, "--check-update")) {
                cfg.check_update = true;
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
    \\  -v, --version        Show version and exit
    \\  -l, --log <path>     Write diagnostic logs to <path>
    \\  -s, --lsp <cmd>      Language server command (e.g. "zls"); defaults per filetype
    \\  -D, --dap <cmd>      Debug adapter command (e.g. "lldb-dap"); defaults per filetype
    \\  -c, --config <path>  Use <path> instead of ~/.config/zedit/config
    \\  -t, --tutor          Open the interactive tutorial (like vimtutor)
    \\  -b, --benchmark      Time open/search/save on [file] (or synthetic data) and exit
    \\  -u, --check-update   Compare this build with the newest release and exit
    \\      --init-config    Write the documented default config file and exit
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
    \\  zedit .               Open a directory (file picker)
    \\  zedit ssh://host/etc/hosts   Edit a file on another machine over SSH
    \\  zedit --log zedit.log notes.txt
    \\
;

pub fn printHelp() void {
    log.writeAll(posix.STDOUT_FILENO, help_text);
}

pub fn printVersion() void {
    log.writeAll(posix.STDOUT_FILENO, "zedit " ++ version ++ "\n");
}

pub fn printError(message: []const u8) void {
    log.writeAll(posix.STDERR_FILENO, "zedit: ");
    log.writeAll(posix.STDERR_FILENO, message);
    log.writeAll(posix.STDERR_FILENO, "\n");
}

/// Print a block of normal output (the --benchmark report).
pub fn printOut(text: []const u8) void {
    log.writeAll(posix.STDOUT_FILENO, text);
}

/// Print a normal (non-error) one-liner, e.g. where --init-config wrote to.
pub fn printNote(message: []const u8) void {
    log.writeAll(posix.STDOUT_FILENO, "zedit: wrote ");
    log.writeAll(posix.STDOUT_FILENO, message);
    log.writeAll(posix.STDOUT_FILENO, "\n");
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
    try std.testing.expect(parse(&[_][:0]const u8{ "zedit", "-v" }) == .version);
}

test "short and long forms agree" {
    const long = parse(&[_][:0]const u8{ "zedit", "--log", "x", "--config", "y", "--lsp", "z", "--tutor", "--benchmark" });
    const short = parse(&[_][:0]const u8{ "zedit", "-l", "x", "-c", "y", "-s", "z", "-t", "-b" });
    try std.testing.expect(long == .run and short == .run);
    try std.testing.expectEqualStrings(long.run.log_path.?, short.run.log_path.?);
    try std.testing.expectEqualStrings(long.run.config_path.?, short.run.config_path.?);
    try std.testing.expectEqualStrings(long.run.lsp_cmd.?, short.run.lsp_cmd.?);
    try std.testing.expectEqual(long.run.tutor, short.run.tutor);
    try std.testing.expectEqual(long.run.benchmark, short.run.benchmark);
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

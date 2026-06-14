//! Diagnostic logging and lightweight profiling.
//!
//! Logging is opt-in: with no `--log` flag nothing is written and the cost is a
//! single null check per call. When enabled, every message is timestamped with
//! milliseconds since startup and appended to a file, keeping the terminal UI
//! clean while making a session fully traceable for development.
//!
//! `Span` is the profiling primitive: it samples a monotonic clock at `start`
//! and logs the elapsed microseconds at `lap`. Both are no-ops when logging is
//! disabled, so instrumentation can stay in hot paths without burning cycles.

const std = @import("std");
const posix = std.posix;

/// Destination file descriptor, or null when logging is disabled.
var sink: ?posix.fd_t = null;
/// Monotonic timestamp (ns) captured when logging was enabled.
var start_ns: i128 = 0;

/// Wire this into `std.Options` so `std.log` routes through here.
pub const options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

/// Open `path` for logging (truncating any previous contents). Quietly does
/// nothing useful if the file cannot be opened — diagnostics must never take
/// the editor down.
pub fn enable(path: []const u8) void {
    const fd = posix.openat(posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    }, 0o644) catch return;
    sink = fd;
    start_ns = nowNanos();
    std.log.info("zed log started", .{});
}

pub fn disable() void {
    if (sink) |fd| {
        _ = posix.system.close(fd);
        sink = null;
    }
}

pub fn enabled() bool {
    return sink != null;
}

fn nowNanos() i128 {
    var ts: posix.timespec = undefined;
    if (posix.system.errno(posix.system.clock_gettime(posix.CLOCK.MONOTONIC, &ts)) != .SUCCESS) {
        return 0;
    }
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const fd = sink orelse return;
    const elapsed_ms = @divTrunc(nowNanos() - start_ns, std.time.ns_per_ms);

    var buf: [2048]u8 = undefined;
    const prefix = "[+{d}ms] " ++ @tagName(level) ++ " (" ++ @tagName(scope) ++ "): ";
    const line = std.fmt.bufPrint(&buf, prefix ++ format ++ "\n", .{elapsed_ms} ++ args) catch {
        writeAll(fd, "[log] message dropped (too long)\n");
        return;
    };
    writeAll(fd, line);
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) void {
    var i: usize = 0;
    while (i < bytes.len) {
        const rc = posix.system.write(fd, bytes.ptr + i, bytes.len - i);
        switch (posix.system.errno(rc)) {
            .SUCCESS => i += @intCast(rc),
            .INTR, .AGAIN => continue,
            else => return, // give up silently; logging is best-effort
        }
    }
}

/// A profiling span. Construct with `start`, then call `lap` to record how long
/// a region took. Zero cost when logging is disabled.
pub const Span = struct {
    begin: i128,

    pub fn start() Span {
        return .{ .begin = if (sink != null) nowNanos() else 0 };
    }

    pub fn lap(self: Span, comptime label: []const u8) void {
        if (sink == null) return;
        const us = @divTrunc(nowNanos() - self.begin, std.time.ns_per_us);
        std.log.scoped(.profile).debug(label ++ " {d}us", .{us});
    }
};

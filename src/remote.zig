//! Editing files on another machine over SSH.
//!
//! `zedit ssh://[user@]host[:port]/path` (also `:e ssh://…`) opens a remote
//! file; `:w` writes it back. A remote directory opens the file picker over
//! that directory's contents. This is the terminal-editor answer to VS Code's
//! Remote-SSH: no agent is installed on the remote — every operation is one
//! `ssh` invocation reading or writing a stream, so anything you can already
//! ssh into works, including hosts configured in `~/.ssh/config`.
//!
//! Reads run `ssh host cat -- <path>`; writes pipe the buffer into
//! `ssh host cat > <path>`. Both go through the *remote* shell, so paths are
//! wrapped in single quotes with embedded quotes escaped (`shellQuote`) — the
//! only injection-safe way to pass an arbitrary path through a shell.
//! `BatchMode=yes` keeps a missing key or unknown host from hanging the editor
//! on a password/confirmation prompt, and a multiplexed connection
//! (`ControlMaster`) makes the repeated calls of a picker session cheap.

const std = @import("std");
const log = @import("log.zig");

/// A parsed `ssh://[user@]host[:port]/path` target. Slices borrow from the URL.
pub const Target = struct {
    /// What ssh is given as its destination: `host` or `user@host`.
    dest: []const u8,
    port: ?[]const u8,
    /// The remote path, always absolute (the URL's leading `/` is kept).
    path: []const u8,
};

pub const scheme = "ssh://";

pub fn isRemote(path: []const u8) bool {
    return std.mem.startsWith(u8, path, scheme);
}

/// Split a remote URL. Null when it is not `ssh://user@host/path` shaped.
pub fn parse(url: []const u8) ?Target {
    if (!isRemote(url)) return null;
    const rest = url[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    var authority = rest[0..slash];
    const path = rest[slash..];
    if (authority.len == 0 or path.len < 2) return null; // need a host and a path

    // An optional :port sits after the host (not inside the user part).
    var port: ?[]const u8 = null;
    const host_start = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| at + 1 else 0;
    if (std.mem.lastIndexOfScalar(u8, authority[host_start..], ':')) |rel| {
        const colon = host_start + rel;
        const p = authority[colon + 1 ..];
        if (p.len > 0 and std.mem.findNone(u8, p, "0123456789") == null) {
            port = p;
            authority = authority[0..colon];
        }
    }
    if (authority.len == 0) return null;
    return .{ .dest = authority, .port = port, .path = path };
}

/// Wrap `s` for the remote shell: `'` + s (with `'` → `'\''`) + `'`.
/// The result is a single shell word whatever `s` contains.
pub fn shellQuote(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    const esc = try std.mem.replaceOwned(u8, gpa, s, "'", "'\\''");
    defer gpa.free(esc);
    return std.fmt.allocPrint(gpa, "'{s}'", .{esc});
}

/// The common ssh options: never prompt (so the editor cannot hang), and reuse
/// one connection for the whole session so repeated calls stay fast.
const ssh_opts = [_][]const u8{
    "-o", "BatchMode=yes",
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=~/.ssh/zedit-%r@%h:%p",
    "-o", "ControlPersist=60",
};

/// Build the argv for `ssh [opts] [-p port] dest <remote_command>`.
/// Caller owns the returned slice (the strings borrow from its inputs).
fn buildArgv(gpa: std.mem.Allocator, t: Target, remote_cmd: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(gpa);
    try argv.append(gpa, "ssh");
    try argv.appendSlice(gpa, &ssh_opts);
    if (t.port) |p| {
        try argv.append(gpa, "-p");
        try argv.append(gpa, p);
    }
    try argv.append(gpa, t.dest);
    try argv.append(gpa, remote_cmd);
    return argv.toOwnedSlice(gpa);
}

pub const Error = error{ SshFailed, OutOfMemory };

/// Read a remote file. Caller owns the bytes. A missing remote file yields an
/// empty buffer (like the local "open to create" behaviour) — distinguished
/// from a connection failure by ssh's exit code (127/255 vs cat's 1).
pub fn read(gpa: std.mem.Allocator, io: std.Io, t: Target, limit: usize) Error![]u8 {
    const quoted = shellQuote(gpa, t.path) catch return error.OutOfMemory;
    defer gpa.free(quoted);
    const cmd = std.fmt.allocPrint(gpa, "cat -- {s}", .{quoted}) catch return error.OutOfMemory;
    defer gpa.free(cmd);
    const argv = buildArgv(gpa, t, cmd) catch return error.OutOfMemory;
    defer gpa.free(argv);

    const res = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(limit),
        .stderr_limit = .limited(8 << 10),
    }) catch |err| {
        std.log.scoped(.remote).warn("ssh failed to run: {s}", .{@errorName(err)});
        return error.SshFailed;
    };
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| {
            if (code == 0) return res.stdout;
            gpa.free(res.stdout);
            // 255 is ssh's own failure (unreachable host, auth); anything else
            // came from the remote command, i.e. we connected fine.
            if (code == 255) {
                std.log.scoped(.remote).warn("ssh {s}: {s}", .{ t.dest, std.mem.trim(u8, res.stderr, " \n\r") });
                return error.SshFailed;
            }
            return gpa.alloc(u8, 0) catch error.OutOfMemory; // no such remote file
        },
        else => {
            gpa.free(res.stdout);
            return error.SshFailed;
        },
    }
}

/// Write `data` to the remote path, creating it if needed.
pub fn write(gpa: std.mem.Allocator, io: std.Io, t: Target, data: []const u8) Error!void {
    const quoted = shellQuote(gpa, t.path) catch return error.OutOfMemory;
    defer gpa.free(quoted);
    const cmd = std.fmt.allocPrint(gpa, "cat > {s}", .{quoted}) catch return error.OutOfMemory;
    defer gpa.free(cmd);
    const argv = buildArgv(gpa, t, cmd) catch return error.OutOfMemory;
    defer gpa.free(argv);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .pipe,
    }) catch |err| {
        std.log.scoped(.remote).warn("ssh failed to run: {s}", .{@errorName(err)});
        return error.SshFailed;
    };
    log.writeAll(child.stdin.?.handle, data);
    child.stdin.?.close(io);
    child.stdin = null;
    const term = child.wait(io) catch return error.SshFailed;
    switch (term) {
        .exited => |code| if (code != 0) {
            std.log.scoped(.remote).warn("remote write failed with code {d}", .{code});
            return error.SshFailed;
        },
        else => return error.SshFailed,
    }
}

/// List files under a remote directory, newline-separated, relative paths —
/// the picker's candidate list. Bounded so a huge remote tree cannot flood us.
pub fn listFiles(gpa: std.mem.Allocator, io: std.Io, t: Target) Error![]u8 {
    const quoted = shellQuote(gpa, t.path) catch return error.OutOfMemory;
    defer gpa.free(quoted);
    // -L follows symlinks the user asked for; prune the usual noise, cap the
    // count so an enormous tree cannot stall the picker.
    const cmd = std.fmt.allocPrint(
        gpa,
        "cd {s} && find . \\( -name .git -o -name node_modules -o -name zig-out -o -name .zig-cache \\) -prune -o -type f -print 2>/dev/null | head -20000",
        .{quoted},
    ) catch return error.OutOfMemory;
    defer gpa.free(cmd);
    const argv = buildArgv(gpa, t, cmd) catch return error.OutOfMemory;
    defer gpa.free(argv);

    const res = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(8 << 20),
        .stderr_limit = .limited(8 << 10),
    }) catch return error.SshFailed;
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| {
            if (code == 0) return res.stdout;
            gpa.free(res.stdout);
            return error.SshFailed;
        },
        else => {
            gpa.free(res.stdout);
            return error.SshFailed;
        },
    }
}

/// Whether the remote path is a directory (one round trip).
pub fn isDir(gpa: std.mem.Allocator, io: std.Io, t: Target) bool {
    const quoted = shellQuote(gpa, t.path) catch return false;
    defer gpa.free(quoted);
    const cmd = std.fmt.allocPrint(gpa, "test -d {s}", .{quoted}) catch return false;
    defer gpa.free(cmd);
    const argv = buildArgv(gpa, t, cmd) catch return false;
    defer gpa.free(argv);
    const res = std.process.run(gpa, io, .{ .argv = argv, .stderr_limit = .limited(4 << 10) }) catch return false;
    gpa.free(res.stdout);
    gpa.free(res.stderr);
    return switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "parse plain host and path" {
    const t = parse("ssh://web/etc/hosts").?;
    try std.testing.expectEqualStrings("web", t.dest);
    try std.testing.expectEqualStrings("/etc/hosts", t.path);
    try std.testing.expectEqual(@as(?[]const u8, null), t.port);
}

test "parse user, port, nested path" {
    const t = parse("ssh://deploy@10.0.0.5:2222/srv/app/main.zig").?;
    try std.testing.expectEqualStrings("deploy@10.0.0.5", t.dest);
    try std.testing.expectEqualStrings("2222", t.port.?);
    try std.testing.expectEqualStrings("/srv/app/main.zig", t.path);
}

test "parse rejects malformed urls" {
    try std.testing.expect(parse("ssh://") == null);
    try std.testing.expect(parse("ssh://host") == null); // no path
    try std.testing.expect(parse("ssh:///path") == null); // no host
    try std.testing.expect(parse("ssh://host/") == null); // empty path
    try std.testing.expect(parse("/local/file") == null);
}

test "parse keeps a non-numeric colon in the host" {
    // An IPv6-ish or otherwise odd authority must not lose text to a bad
    // port split; only all-digit suffixes count as a port.
    const t = parse("ssh://host:notaport/x/y").?;
    try std.testing.expectEqualStrings("host:notaport", t.dest);
    try std.testing.expectEqualStrings("/x/y", t.path);
}

test "shellQuote neutralises quotes and metacharacters" {
    const gpa = std.testing.allocator;
    const plain = try shellQuote(gpa, "/tmp/a b.txt");
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("'/tmp/a b.txt'", plain);

    // The classic injection attempt: a path that tries to end the quote and
    // append a command. It must come back as one inert word.
    const evil = try shellQuote(gpa, "/tmp/x'; rm -rf /; echo '");
    defer gpa.free(evil);
    try std.testing.expectEqualStrings("'/tmp/x'\\''; rm -rf /; echo '\\'''", evil);
}

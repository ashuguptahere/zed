//! Integration-test runner: drives the built `zedit` through a pty (and a mock
//! language server) to verify the interactive behaviour that unit tests can't.
//! Run with `zig build itest`, which passes the zedit and mock_lsp binary paths.

const std = @import("std");
const h = @import("harness.zig");

const scenarios = .{
    .{ "vim", @import("scenarios/vim.zig") },
    .{ "vim_compat", @import("scenarios/vim_compat.zig") },
    .{ "feature", @import("scenarios/feature.zig") },
    .{ "multicursor", @import("scenarios/multicursor.zig") },
    .{ "extra", @import("scenarios/extra.zig") },
    .{ "search", @import("scenarios/search.zig") },
    .{ "treesitter", @import("scenarios/treesitter.zig") },
    .{ "indent", @import("scenarios/indent.zig") },
    .{ "picker", @import("scenarios/picker.zig") },
    .{ "git", @import("scenarios/git.zig") },
    .{ "windows", @import("scenarios/windows.zig") },
    .{ "sidebar", @import("scenarios/sidebar.zig") },
    .{ "mouse", @import("scenarios/mouse.zig") },
    .{ "titlebar", @import("scenarios/titlebar.zig") },
    .{ "config", @import("scenarios/configtheme.zig") },
    .{ "cmdline", @import("scenarios/cmdline.zig") },
    .{ "robust", @import("scenarios/robust.zig") },
    .{ "remote", @import("scenarios/remote.zig") },
    .{ "ssh", @import("scenarios/ssh.zig") },
    .{ "lsp", @import("scenarios/lsp.zig") },
    .{ "bufcomplete", @import("scenarios/bufcomplete.zig") },
    .{ "cpu", @import("scenarios/cpu.zig") },
    .{ "wrap", @import("scenarios/wrap.zig") },
    .{ "undotree", @import("scenarios/undotree.zig") },
    .{ "session", @import("scenarios/session.zig") },
    .{ "terminal", @import("scenarios/terminal.zig") },
    .{ "debug", @import("scenarios/debug.zig") },
};

/// Whether suite `name` was asked for: everything when no filter was given.
fn wanted(only: []const []const u8, name: []const u8) bool {
    if (only.len == 0) return true;
    for (only) |o| {
        if (std.mem.eql(u8, o, name)) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 4) {
        std.debug.print("usage: itest <zedit> <mock_lsp> <mock_dap> [suite...]\n", .{});
        std.process.exit(2);
    }
    // `zig build itest -- sidebar git` runs just those suites: the full run is
    // over ten minutes, which is too slow a loop for one scenario under repair.
    const only = argv[4..];
    // The build passes relative artifact paths; make them absolute so scenarios
    // that chdir into a temp dir can still exec the binaries.
    const cwd = try std.process.currentPathAlloc(init.io, arena);
    var ctx = h.Ctx{
        .gpa = init.gpa,
        .io = init.io,
        .zedit = try std.fs.path.resolve(arena, &.{ cwd, argv[1] }),
        .mock = try std.fs.path.resolve(arena, &.{ cwd, argv[2] }),
        .mock_dap = try std.fs.path.resolve(arena, &.{ cwd, argv[3] }),
    };

    inline for (scenarios) |s| {
        if (wanted(only, s[0])) {
            std.debug.print("=== {s} ===\n", .{s[0]});
            ctx.suite = s[0];
            try s[1].run(&ctx);
        }
    }

    std.debug.print("\n{d} passed, {d} failed\n", .{ ctx.passed, ctx.failed });
    if (ctx.failed > 0) {
        // Name them again at the tail: a CI log is read from the bottom, and
        // "1 failed" without a name is a bug report nobody can act on.
        std.debug.print("failed checks:\n", .{});
        for (ctx.failures.items) |f| std.debug.print("  - {s}\n", .{f});
        // On GitHub Actions, also emit them as workflow errors. Those become
        // check annotations, which the API serves for a public repository
        // *without* a token — where the log body needs one. So a failure can
        // be diagnosed from outside the runner, which is exactly the problem
        // that made the first CI-only failure take days to name.
        if (std.c.getenv("GITHUB_ACTIONS") != null) {
            for (ctx.failures.items) |f| std.debug.print("::error title=itest::{s}\n", .{f});
        }
        std.process.exit(1);
    }
    ctx.deinit();
}

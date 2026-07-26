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
    .{ "picker", @import("scenarios/picker.zig") },
    .{ "git", @import("scenarios/git.zig") },
    .{ "windows", @import("scenarios/windows.zig") },
    .{ "sidebar", @import("scenarios/sidebar.zig") },
    .{ "titlebar", @import("scenarios/titlebar.zig") },
    .{ "config", @import("scenarios/configtheme.zig") },
    .{ "cmdline", @import("scenarios/cmdline.zig") },
    .{ "robust", @import("scenarios/robust.zig") },
    .{ "remote", @import("scenarios/remote.zig") },
    .{ "ssh", @import("scenarios/ssh.zig") },
    .{ "lsp", @import("scenarios/lsp.zig") },
    .{ "cpu", @import("scenarios/cpu.zig") },
    .{ "wrap", @import("scenarios/wrap.zig") },
    .{ "undotree", @import("scenarios/undotree.zig") },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 3) {
        std.debug.print("usage: itest <zedit-binary> <mock_lsp-binary>\n", .{});
        std.process.exit(2);
    }
    // The build passes relative artifact paths; make them absolute so scenarios
    // that chdir into a temp dir can still exec the binaries.
    const cwd = try std.process.currentPathAlloc(init.io, arena);
    var ctx = h.Ctx{
        .gpa = init.gpa,
        .io = init.io,
        .zedit = try std.fs.path.resolve(arena, &.{ cwd, argv[1] }),
        .mock = try std.fs.path.resolve(arena, &.{ cwd, argv[2] }),
    };

    inline for (scenarios) |s| {
        std.debug.print("=== {s} ===\n", .{s[0]});
        try s[1].run(&ctx);
    }

    std.debug.print("\n{d} passed, {d} failed\n", .{ ctx.passed, ctx.failed });
    if (ctx.failed > 0) std.process.exit(1);
}

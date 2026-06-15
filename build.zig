const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Vendored tree-sitter runtime + grammar (see vendor/ and CLAUDE.md).
    // The runtime needs libc; _GNU_SOURCE exposes endian/stdio helpers it uses,
    // and it builds without wasm (the wasm symbols have non-wasm stubs).
    exe_mod.link_libc = true;
    exe_mod.addIncludePath(b.path("vendor/tree-sitter/include"));
    exe_mod.addIncludePath(b.path("vendor/tree-sitter/src"));
    exe_mod.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter/src/lib.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
    });
    exe_mod.addIncludePath(b.path("vendor/tree-sitter-zig/src"));
    exe_mod.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter-zig/src/parser.c"),
        .flags = &.{"-D_GNU_SOURCE"},
    });
    // The grammar's highlight query, embedded via @embedFile.
    exe_mod.addAnonymousImport("ts_highlights_zig", .{
        .root_source_file = b.path("vendor/tree-sitter-zig/highlights.scm"),
    });

    const exe = b.addExecutable(.{ .name = "zed", .root_module = exe_mod });
    b.installArtifact(exe);

    // Install the man page so `man zed` works after `zig build --prefix ...`.
    b.installFile("doc/zed.1", "share/man/man1/zed.1");

    // `zig build run [-- args]` builds and runs the editor.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run zed");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` runs every test block reachable from src/main.zig.
    const unit_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

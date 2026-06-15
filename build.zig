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
    // Each grammar: the dir holding its generated parser.c (+ optional C
    // scanner and tree_sitter/ headers), and its highlights query embedded via
    // @embedFile. `src` is explicit because tree-sitter-typescript keeps its
    // grammar under typescript/ with a sibling common/scanner.h.
    const Grammar = struct { name: []const u8, src: []const u8, scanner: bool, highlights: []const u8 };
    const grammars = [_]Grammar{
        .{ .name = "zig", .src = "vendor/tree-sitter-zig/src", .scanner = false, .highlights = "vendor/tree-sitter-zig/highlights.scm" },
        .{ .name = "c", .src = "vendor/tree-sitter-c/src", .scanner = false, .highlights = "vendor/tree-sitter-c/highlights.scm" },
        .{ .name = "python", .src = "vendor/tree-sitter-python/src", .scanner = true, .highlights = "vendor/tree-sitter-python/highlights.scm" },
        .{ .name = "json", .src = "vendor/tree-sitter-json/src", .scanner = false, .highlights = "vendor/tree-sitter-json/highlights.scm" },
        .{ .name = "javascript", .src = "vendor/tree-sitter-javascript/src", .scanner = true, .highlights = "vendor/tree-sitter-javascript/highlights.scm" },
        .{ .name = "typescript", .src = "vendor/tree-sitter-typescript/typescript/src", .scanner = true, .highlights = "vendor/tree-sitter-typescript/highlights.scm" },
        .{ .name = "rust", .src = "vendor/tree-sitter-rust/src", .scanner = true, .highlights = "vendor/tree-sitter-rust/highlights.scm" },
        .{ .name = "go", .src = "vendor/tree-sitter-go/src", .scanner = false, .highlights = "vendor/tree-sitter-go/highlights.scm" },
    };
    inline for (grammars) |g| {
        exe_mod.addIncludePath(b.path(g.src));
        exe_mod.addCSourceFile(.{ .file = b.path(g.src ++ "/parser.c"), .flags = &.{"-D_GNU_SOURCE"} });
        if (g.scanner) exe_mod.addCSourceFile(.{ .file = b.path(g.src ++ "/scanner.c"), .flags = &.{"-D_GNU_SOURCE"} });
        exe_mod.addAnonymousImport("ts_highlights_" ++ g.name, .{ .root_source_file = b.path(g.highlights) });
    }

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

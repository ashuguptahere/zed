const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Release artifacts are built with -Dstrip (see .github/workflows/release.yml).
    const strip = b.option(bool, "strip", "Strip debug info from the binary") orelse false;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (strip) true else null,
    });

    // Vendored tree-sitter runtime + grammars (see vendor/ and CLAUDE.md), all
    // compiled into ONE static library that every artifact links. Attaching the
    // C sources to each module instead would recompile all 19 translation units
    // per artifact — `zig build test` alone used to re-pay the entire C build,
    // which dominates a cold build on a laptop-class CPU.
    // The runtime needs libc; _GNU_SOURCE exposes endian/stdio helpers it uses,
    // and it builds without wasm (the wasm symbols have non-wasm stubs).
    const ts_mod = b.createModule(.{ .target = target, .optimize = optimize });
    ts_mod.link_libc = true;
    ts_mod.addIncludePath(b.path("vendor/tree-sitter/include"));
    ts_mod.addIncludePath(b.path("vendor/tree-sitter/src"));
    ts_mod.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter/src/lib.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
    });

    // The Zig side only needs the public header to @cImport; the grammar
    // entry points are `extern fn`s resolved from the library at link time.
    exe_mod.link_libc = true;
    exe_mod.addIncludePath(b.path("vendor/tree-sitter/include"));
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
        .{ .name = "html", .src = "vendor/tree-sitter-html/src", .scanner = true, .highlights = "vendor/tree-sitter-html/highlights.scm" },
        .{ .name = "markdown", .src = "vendor/tree-sitter-markdown/src", .scanner = true, .highlights = "vendor/tree-sitter-markdown/highlights.scm" },
        .{ .name = "markdown_inline", .src = "vendor/tree-sitter-markdown-inline/src", .scanner = true, .highlights = "vendor/tree-sitter-markdown-inline/highlights.scm" },
    };
    inline for (grammars) |g| {
        ts_mod.addIncludePath(b.path(g.src));
        ts_mod.addCSourceFile(.{ .file = b.path(g.src ++ "/parser.c"), .flags = &.{"-D_GNU_SOURCE"} });
        if (g.scanner) ts_mod.addCSourceFile(.{ .file = b.path(g.src ++ "/scanner.c"), .flags = &.{"-D_GNU_SOURCE"} });
        exe_mod.addAnonymousImport("ts_highlights_" ++ g.name, .{ .root_source_file = b.path(g.highlights) });
    }

    const ts_lib = b.addLibrary(.{ .name = "tree-sitter", .root_module = ts_mod, .linkage = .static });
    exe_mod.linkLibrary(ts_lib);

    // The interactive tutorial, embedded so `zedit --tutor` works anywhere.
    exe_mod.addAnonymousImport("tutor_text", .{ .root_source_file = b.path("doc/tutor.txt") });
    exe_mod.addAnonymousImport("version_text", .{ .root_source_file = b.path("VERSION") });

    const exe = b.addExecutable(.{ .name = "zedit", .root_module = exe_mod });
    b.installArtifact(exe);

    // Install the man page so `man zedit` works after `zig build --prefix ...`.
    b.installFile("doc/zedit.1", "share/man/man1/zedit.1");

    // `zig build run [-- args]` builds and runs the editor.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run zedit");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` runs every test block reachable from src/main.zig.
    const unit_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // `zig build itest` drives the built editor through a pseudo-terminal (and a
    // mock language server) to cover the interactive paths unit tests can't.
    const mock_mod = b.createModule(.{
        .root_source_file = b.path("tools/mock_lsp.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mock_exe = b.addExecutable(.{ .name = "mock_lsp", .root_module = mock_mod });

    const itest_mod = b.createModule(.{
        .root_source_file = b.path("tools/itest.zig"),
        .target = target,
        .optimize = optimize,
    });
    itest_mod.link_libc = true; // the pty harness uses posix_openpt/forkpty-style libc calls
    const itest_exe = b.addExecutable(.{ .name = "itest", .root_module = itest_mod });

    const run_itest = b.addRunArtifact(itest_exe);
    run_itest.addArtifactArg(exe); // argv[1] = zedit
    run_itest.addArtifactArg(mock_exe); // argv[2] = mock_lsp
    if (b.args) |args| run_itest.addArgs(args);
    const itest_step = b.step("itest", "Run pty integration tests");
    itest_step.dependOn(&run_itest.step);

    // `zig build bench -Doptimize=ReleaseFast` compares zedit against helix and
    // neovim (if installed) through real ptys: startup, big-file open,
    // keypress latency, picker-open.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.link_libc = true;
    const bench_exe = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.addArtifactArg(exe);
    const bench_step = b.step("bench", "Benchmark zedit against helix/nvim");
    bench_step.dependOn(&run_bench.step);
}

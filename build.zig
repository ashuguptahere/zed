const std = @import("std");

// The VERSION file is the single source of truth (embedded into `--version`
// below); build.zig.zon must carry the same value for package metadata. A
// mismatch fails every build right here instead of shipping two versions.
comptime {
    const v = std.mem.trim(u8, @embedFile("VERSION"), " \t\r\n");
    const z = zonVersion(@embedFile("build.zig.zon"));
    if (!std.mem.eql(u8, v, z))
        @compileError("version mismatch: VERSION says \"" ++ v ++
            "\" but build.zig.zon's .version says \"" ++ z ++
            "\" — update build.zig.zon to match the VERSION file");
}

/// The first quoted string after `.version` in build.zig.zon — a plain scan;
/// the file is ours and its shape is fixed.
fn zonVersion(comptime zon: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, zon, ".version") orelse return "";
    const q1 = std.mem.indexOfScalarPos(u8, zon, at + ".version".len, '"') orelse return "";
    const q2 = std.mem.indexOfScalarPos(u8, zon, q1 + 1, '"') orelse return "";
    return zon[q1 + 1 .. q2];
}

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
    // scanner and tree_sitter/ headers), and its query files embedded via
    // @embedFile. `src` is explicit because tree-sitter-typescript keeps its
    // grammar under typescript/ with a sibling common/scanner.h. `dir` is where
    // the .scm files live (the grammar's own directory); an empty `injections`
    // or `indents` means that grammar ships none and the feature is simply off
    // for it.
    const Grammar = struct {
        name: []const u8,
        dir: []const u8,
        src: []const u8,
        scanner: bool,
        injections: bool = false,
        indents: bool = false,
    };
    const grammars = [_]Grammar{
        .{ .name = "zig", .dir = "vendor/tree-sitter-zig", .src = "vendor/tree-sitter-zig/src", .scanner = false, .indents = true },
        .{ .name = "c", .dir = "vendor/tree-sitter-c", .src = "vendor/tree-sitter-c/src", .scanner = false, .indents = true },
        .{ .name = "python", .dir = "vendor/tree-sitter-python", .src = "vendor/tree-sitter-python/src", .scanner = true, .indents = true },
        .{ .name = "json", .dir = "vendor/tree-sitter-json", .src = "vendor/tree-sitter-json/src", .scanner = false },
        .{ .name = "javascript", .dir = "vendor/tree-sitter-javascript", .src = "vendor/tree-sitter-javascript/src", .scanner = true, .indents = true },
        .{ .name = "typescript", .dir = "vendor/tree-sitter-typescript", .src = "vendor/tree-sitter-typescript/typescript/src", .scanner = true, .indents = true },
        .{ .name = "rust", .dir = "vendor/tree-sitter-rust", .src = "vendor/tree-sitter-rust/src", .scanner = true, .indents = true },
        .{ .name = "go", .dir = "vendor/tree-sitter-go", .src = "vendor/tree-sitter-go/src", .scanner = false, .indents = true },
        .{ .name = "html", .dir = "vendor/tree-sitter-html", .src = "vendor/tree-sitter-html/src", .scanner = true, .injections = true },
        .{ .name = "markdown", .dir = "vendor/tree-sitter-markdown", .src = "vendor/tree-sitter-markdown/src", .scanner = true, .injections = true },
        .{ .name = "markdown_inline", .dir = "vendor/tree-sitter-markdown-inline", .src = "vendor/tree-sitter-markdown-inline/src", .scanner = true },
    };
    inline for (grammars) |g| {
        ts_mod.addIncludePath(b.path(g.src));
        ts_mod.addCSourceFile(.{ .file = b.path(g.src ++ "/parser.c"), .flags = &.{"-D_GNU_SOURCE"} });
        if (g.scanner) ts_mod.addCSourceFile(.{ .file = b.path(g.src ++ "/scanner.c"), .flags = &.{"-D_GNU_SOURCE"} });
        exe_mod.addAnonymousImport("ts_highlights_" ++ g.name, .{ .root_source_file = b.path(g.dir ++ "/highlights.scm") });
        if (g.injections) exe_mod.addAnonymousImport("ts_injections_" ++ g.name, .{ .root_source_file = b.path(g.dir ++ "/injections.scm") });
        if (g.indents) exe_mod.addAnonymousImport("ts_indents_" ++ g.name, .{ .root_source_file = b.path(g.dir ++ "/indents.scm") });
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

    const mock_dap_mod = b.createModule(.{
        .root_source_file = b.path("tools/mock_dap.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mock_dap_exe = b.addExecutable(.{ .name = "mock_dap", .root_module = mock_dap_mod });

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
    run_itest.addArtifactArg(mock_dap_exe); // argv[3] = mock_dap
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

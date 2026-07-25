//! LSP client against the mock server: diagnostics (+ ]d/[d navigation), hover
//! (normal + insert), inlay hints, document symbols (picker + jump), incremental
//! didChange, completion, signature help (+ overload cycling), rename (single-
//! and cross-file + :wa), code actions (inline edit + executeCommand/applyEdit),
//! references (picker + jump), and formatting (on demand + format-on-save).
//! Drives the built mock_lsp.

const std = @import("std");
const h = @import("../harness.zig");

const target = "/tmp/zedit_it_lsp.zig";
const initial = "const a = 1;\nconst b = 2;\nconst c = 3;\n";
const quit = "\x1b:q!\r";

const RED = "\x1b[38;2;247;118;142m"; // error sign colour (theme.git_delete)
const DOT = "\xe2\x97\x8f"; // U+25CF ●
const BUILTIN = "\x1b[38;2;224;175;104m"; // theme.builtin (active parameter)

const Step = struct { keys: []const u8, ms: i64 };

const Result = struct {
    out: []u8,
    plain: []u8,
    text: []u8,
    fn deinit(self: Result, gpa: std.mem.Allocator) void {
        gpa.free(self.out);
        gpa.free(self.plain);
        gpa.free(self.text);
    }
    fn outHas(self: Result, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.out, needle) != null;
    }
    fn plainHas(self: Result, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.plain, needle) != null;
    }
    fn textHas(self: Result, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.text, needle) != null;
    }
};

/// Drive a fresh session against the mock and capture the screen + saved file.
fn drive(ctx: *h.Ctx, steps: []const Step, final: []const u8) Result {
    return driveOpt(ctx, null, steps, final);
}

/// Like `drive`, with an extra mock flag (`--fmt` / `--xfile`) appended to the
/// `--lsp` command line.
fn driveOpt(ctx: *h.Ctx, flag: ?[]const u8, steps: []const Step, final: []const u8) Result {
    const lsp_cmd = if (flag) |f|
        std.fmt.allocPrint(ctx.gpa, "{s} {s}", .{ ctx.mock, f }) catch unreachable
    else
        ctx.gpa.dupe(u8, ctx.mock) catch unreachable;
    defer ctx.gpa.free(lsp_cmd);
    h.writeFile(ctx.io, target, initial);
    var s = h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--lsp", lsp_cmd, target } }) catch return .{
        .out = ctx.gpa.dupe(u8, "") catch unreachable,
        .plain = ctx.gpa.dupe(u8, "") catch unreachable,
        .text = ctx.gpa.dupe(u8, "") catch unreachable,
    };
    defer s.finish();
    s.drain(1500); // startup handshake + didOpen + diagnostics
    for (steps) |st| {
        s.send(st.keys);
        s.drain(st.ms);
    }
    s.send(final);
    s.drain(400);
    return .{
        .out = ctx.gpa.dupe(u8, s.out.items) catch unreachable,
        .plain = s.plain(ctx.gpa) catch (ctx.gpa.dupe(u8, "") catch unreachable),
        .text = h.readFile(ctx.gpa, ctx.io, target),
    };
}

pub fn run(ctx: *h.Ctx) !void {
    // Diagnostics + hover. "0" clears the startup status (cursor stays off the
    // diagnostic line so the count shows); "j" moves onto it; "K" hovers.
    {
        const r = drive(ctx, &.{
            .{ .keys = "0", .ms = 500 },
            .{ .keys = "j", .ms = 600 },
            .{ .keys = "K", .ms = 800 },
        }, quit);
        defer r.deinit(ctx.gpa);
        ctx.check("diagnostic count in statusline", r.outHas("E:1 W:1"));
        ctx.check("error sign rendered (red dot)", r.outHas(RED) and r.outHas(DOT));
        ctx.check("diagnostic message shown on its line", r.outHas("mock error"));
        ctx.check("hover result shown", r.outHas("mock hover"));
    }

    // Inline diagnostics: each diagnostic's message renders as dim virtual
    // text after the code on its own line (config inline_diagnostics, on by
    // default). Line 1 is an error, line 2 a warning — both show at once,
    // unlike the statusline which only shows the cursor's line.
    {
        const r = drive(ctx, &.{.{ .keys = "0", .ms = 600 }}, quit);
        defer r.deinit(ctx.gpa);
        ctx.check("inline error text shown after the code", r.plainHas("mock error"));
        ctx.check("inline warning shown on its own line", r.plainHas("mock warn"));
        ctx.check("inline diagnostics use a separator glyph", r.plainHas("\u{25B8}"));
        // The virtual text is not part of the buffer: writing must not save it.
        ctx.check("inline text never enters the buffer", !r.textHas("mock error"));
    }

    // Diagnostic navigation: ]d jumps to the next diagnostic line, [d to the
    // previous (wrapping). The landed line's message shows in the statusline.
    {
        const r = drive(ctx, &.{ .{ .keys = "]d", .ms = 400 }, .{ .keys = "]d", .ms = 400 } }, quit);
        defer r.deinit(ctx.gpa);
        // From line 0: first ]d -> line 1 (mock error), second -> line 2 (mock warn).
        ctx.check("]d jumps to next diagnostic", r.outHas("mock warn"));
    }
    {
        const r = drive(ctx, &.{ .{ .keys = "G", .ms = 400 }, .{ .keys = "[d", .ms = 400 } }, quit);
        defer r.deinit(ctx.gpa);
        // G -> last line (mock warn); [d -> previous diagnostic (line 1, mock error).
        ctx.check("[d jumps to previous diagnostic", r.outHas("mock error"));
    }

    // Hover in insert mode (Ctrl-k).
    {
        const r = drive(ctx, &.{ .{ .keys = "i", .ms = 300 }, .{ .keys = "\x0b", .ms = 800 } }, quit);
        defer r.deinit(ctx.gpa);
        ctx.check("insert-mode hover shown", r.outHas("mock hover"));
    }

    // Inlay hints: the mock returns a ": i32" type hint after "a" on line 0,
    // rendered inline as dim virtual text (not part of the buffer).
    {
        const r = drive(ctx, &.{}, quit);
        defer r.deinit(ctx.gpa);
        ctx.check("inlay hint rendered inline", r.plainHas(": i32"));
    }


    // Incremental sync: an edit on line 0 makes the mock echo "INCREMENTAL".
    {
        const r = drive(ctx, &.{ .{ .keys = "ix", .ms = 800 }, .{ .keys = "\x1b", .ms = 800 } }, quit);
        defer r.deinit(ctx.gpa);
        ctx.check("incremental didChange sent", r.outHas("INCREMENTAL"));
        ctx.check("full didChange not sent", !r.outHas("FULL"));
    }

    // Completion: type a prefix, Ctrl-n to request, Tab to accept.
    {
        const r = drive(ctx, &.{
            .{ .keys = "omock", .ms = 400 },
            .{ .keys = "\x0e", .ms = 900 },
            .{ .keys = "\t", .ms = 400 },
            .{ .keys = "\x1b", .ms = 300 },
        }, "\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("completion popup shows candidate", r.outHas("mockComplete"));
        ctx.check("accepted completion written to file", r.textHas("mockComplete\n"));
    }

    // Signature help + overload cycling: type "(", then Ctrl-p to cycle.
    {
        const r = drive(ctx, &.{ .{ .keys = "omockFn(", .ms = 900 }, .{ .keys = "\x10", .ms = 600 } }, quit);
        defer r.deinit(ctx.gpa);
        ctx.check("signature popup shows label", r.plainHas("mockFn(a: int, b: int)"));
        ctx.check("active parameter highlighted", r.outHas(BUILTIN ++ "a: int"));
        ctx.check("overload counter shown", r.plainHas("(1/2)"));
        ctx.check("Ctrl-p cycles to other overload", r.plainHas("mockFn(a: str)") and r.plainHas("(2/2)"));
    }

    // Rename: move onto "a", gr (prompt pre-filled), clear, type new name.
    {
        const r = drive(ctx, &.{
            .{ .keys = "0w", .ms = 300 },
            .{ .keys = "gr", .ms = 400 },
            .{ .keys = "\x7fxyz", .ms = 400 },
            .{ .keys = "\r", .ms = 900 },
        }, "\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("rename prompt pre-filled with identifier", r.plainHas("rename: a"));
        ctx.check("rename status shown", r.outHas("renamed 1"));
        ctx.check("rename applied to buffer", r.textHas("const xyz = 1;"));
    }

    // Code action: ga opens a picker; Enter on the first applies its inline edit.
    {
        const r = drive(ctx, &.{ .{ .keys = "ga", .ms = 800 }, .{ .keys = "\r", .ms = 800 } }, "\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("code action picker labelled", r.plainHas("ACTIONS"));
        ctx.check("code action titles listed", r.plainHas("Rename a to A") and r.plainHas("Run mock command"));
        ctx.check("code action edit applied to buffer", r.textHas("const A = 1;"));
    }

    // Command-based action: select the second action; executeCommand triggers a
    // server applyEdit that the editor applies (line 1: "b" -> "B").
    {
        const r = drive(ctx, &.{
            .{ .keys = "ga", .ms = 800 },
            .{ .keys = "\x0e", .ms = 300 },
            .{ .keys = "\r", .ms = 1000 },
        }, "\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("executeCommand applyEdit applied to buffer", r.textHas("const B = 2;"));
    }

    // References: Space l R opens a picker of "path:line: text" items; Ctrl-n
    // to the second reference (line 3), Enter jumps there, x edits at it.
    {
        const r = drive(ctx, &.{
            .{ .keys = " lR", .ms = 900 },
            .{ .keys = "\x0e", .ms = 300 },
            .{ .keys = "\r", .ms = 400 },
            .{ .keys = "x", .ms = 300 },
        }, "\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("references picker labelled", r.plainHas("REFERENCES"));
        ctx.check("references show path:line: text", r.plainHas(":3: const c = 3;"));
        ctx.check("Enter jumps to the reference", r.textHas("onst c = 3;"));
    }

    // Formatting on demand (Space l f): the mock's whole-document edit (a
    // multi-line range replaced by multi-line text) is applied as one change.
    {
        const r = drive(ctx, &.{ .{ .keys = " lf", .ms = 900 } }, "\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("format status shown", r.plainHas("formatted (1 edit(s))"));
        ctx.check("formatting edit applied", r.textHas("const a = 1; // fmt\nconst b = 2;\nconst c = 3;\n"));
    }

    // Format-on-save: with --fmt the mock advertises formatting, so a plain
    // :wq formats first (config format_on_save defaults to true).
    {
        const r = driveOpt(ctx, "--fmt", &.{}, "\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("format-on-save formats before :w", r.textHas("const a = 1; // fmt"));
    }

    // Cross-file rename: with --xfile the rename's WorkspaceEdit touches a
    // second file, which is edited in a background buffer and saved by :wa.
    {
        const other = "/tmp/zedit_it_other.zig";
        h.writeFile(ctx.io, other, "const a = 9;\n");
        const r = driveOpt(ctx, "--xfile", &.{
            .{ .keys = "0w", .ms = 300 },
            .{ .keys = "gr", .ms = 400 },
            .{ .keys = "\x7fxyz", .ms = 400 },
            .{ .keys = "\r", .ms = 900 },
            .{ .keys = ":wa\r", .ms = 600 },
        }, ":qa\r");
        defer r.deinit(ctx.gpa);
        ctx.check("cross-file rename status", r.plainHas("renamed 2 in 2 files"));
        ctx.check(":wa reports both buffers", r.plainHas("2 buffer(s) written"));
        ctx.check("rename applied to the current file", r.textHas("const xyz = 1;"));
        const other_text = h.readFile(ctx.gpa, ctx.io, other);
        defer ctx.gpa.free(other_text);
        ctx.check("rename applied to the other file", std.mem.eql(u8, other_text, "const xyz = 9;\n"));
    }

    // Document symbols: Space-o opens a picker (kind tag + indented names);
    // filtering to "main" and Enter jumps to line 2 col 6, where x deletes.
    {
        const r = drive(ctx, &.{
            .{ .keys = " ls", .ms = 800 },
            .{ .keys = "main", .ms = 300 },
            .{ .keys = "\r", .ms = 300 },
            .{ .keys = "x", .ms = 300 },
        }, "\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("symbol picker labelled", r.plainHas("SYMBOLS"));
        ctx.check("symbol picker lists symbols", r.plainHas("struct Foo") and r.plainHas("fn main"));
        ctx.check("jump to symbol lands at its position", r.textHas("const  = 3;"));
    }
}

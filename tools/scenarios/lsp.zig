//! LSP client against the mock server: diagnostics (+ ]d/[d navigation), hover
//! (normal + insert), incremental didChange, completion, signature help (+
//! overload cycling), rename, and code actions (inline edit +
//! executeCommand/applyEdit). Drives the built mock_lsp binary.

const std = @import("std");
const h = @import("../harness.zig");

const target = "/tmp/zed_it_lsp.zig";
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
    h.writeFile(ctx.io, target, initial);
    var s = h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zed, "--lsp", ctx.mock, target } }) catch return .{
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
}

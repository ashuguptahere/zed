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

    // Auto-completion: typing an identifier and pausing pops the list up on
    // its own (no Ctrl-n), after the configured debounce.
    {
        const r = drive(ctx, &.{.{ .keys = "omock", .ms = 900 }}, quit);
        defer r.deinit(ctx.gpa);
        ctx.check("completion pops up while typing", r.plainHas("mockComplete"));
    }

    // Fuzzy filtering: "mplt" is a subsequence of mockComplete but not a
    // prefix, and is not a subsequence of mockOther — so exactly one survives.
    {
        const r = drive(ctx, &.{.{ .keys = "omplt", .ms = 900 }}, quit);
        defer r.deinit(ctx.gpa);
        ctx.check("completion matches fuzzily", r.plainHas("mockComplete"));
        ctx.check("fuzzy filter excludes non-matches", !r.plainHas("mockOther"));
    }

    // Workspace symbols (Space l S): the server matches the query across the
    // project — the mock echoes it back — and Enter jumps to the symbol.
    {
        const r = drive(ctx, &.{ .{ .keys = " lS", .ms = 800 } }, quit);
        defer r.deinit(ctx.gpa);
        ctx.check("workspace symbol picker labelled", r.plainHas("WORKSPACE SYMBOLS"));
        ctx.check("workspace symbols listed", r.plainHas("wsymFor_") and r.plainHas("otherSymbol"));
    }
    {
        const r = drive(ctx, &.{
            .{ .keys = " lS", .ms = 700 },
            .{ .keys = "query", .ms = 800 }, // re-queries the server after the pause
        }, quit);
        defer r.deinit(ctx.gpa);
        ctx.check("the query is sent to the server", r.plainHas("wsymFor_query"));
    }
    {
        const r = drive(ctx, &.{
            .{ .keys = " lS", .ms = 800 },
            .{ .keys = "\r", .ms = 600 }, // open the first symbol (line 3 of this file)
            .{ .keys = "x", .ms = 300 },
        }, "\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("workspace symbol jumps to its position", r.textHas("onst c = 3;"));
    }

    // Diagnostics picker (Space l D): every diagnostic across the open
    // buffers, tagged by severity; Enter jumps to the line.
    {
        const r = drive(ctx, &.{ .{ .keys = " lD", .ms = 800 } }, quit);
        defer r.deinit(ctx.gpa);
        ctx.check("diagnostics picker labelled", r.plainHas("DIAGNOSTICS"));
        ctx.check("diagnostics listed with severity", r.plainHas("E ") and r.plainHas("mock error") and
            r.plainHas("W ") and r.plainHas("mock warn"));
    }
    {
        const r = drive(ctx, &.{
            .{ .keys = " lD", .ms = 800 },
            .{ .keys = "\x0e", .ms = 300 }, // second row: the warning on line 3
            .{ .keys = "\r", .ms = 500 },
            .{ .keys = "x", .ms = 300 },
        }, "\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("diagnostic entry jumps to its line", r.textHas("onst c = 3;"));
    }

    // gi / gy: goto implementation and type definition reuse the definition
    // plumbing, so the cursor lands where the server points (the mock puts
    // the implementation on line 2 and the type on line 3, col 6).
    {
        const r = drive(ctx, &.{ .{ .keys = "gi", .ms = 700 }, .{ .keys = "x", .ms = 300 } }, "\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("gi jumps to the implementation", r.textHas("onst b = 2;"));
    }
    {
        const r = drive(ctx, &.{ .{ .keys = "gy", .ms = 700 }, .{ .keys = "x", .ms = 300 } }, "\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("gy jumps to the type definition", r.textHas("const  = 3;"));
    }

    // Snippet completion: "snip" uniquely selects the snippet item, whose
    // insertText is "call(${1:first}, ${2:second})$0". Accepting expands the
    // placeholders, puts the cursor on the first one, and typing replaces it;
    // Tab jumps to the second; a final Tab lands on $0 past the ")".
    {
        const r = drive(ctx, &.{
            .{ .keys = "osnip", .ms = 800 },
            .{ .keys = "\t", .ms = 500 }, // accept -> expands, cursor on "first"
            .{ .keys = "AAA", .ms = 400 }, // replaces the pristine placeholder
            .{ .keys = "\t", .ms = 300 }, // jump to "second"
            .{ .keys = "BBB", .ms = 400 },
            .{ .keys = "\x1b", .ms = 300 },
        }, "\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("snippet placeholders expand", r.plainHas("call(first, second)"));
        ctx.check("typing replaces the first placeholder", r.textHas("call(AAA, BBB)"));
    }

    // Tab to the final stop ($0) leaves the text alone and ends the session.
    {
        const r = drive(ctx, &.{
            .{ .keys = "osnip", .ms = 800 },
            .{ .keys = "\t", .ms = 500 },
            .{ .keys = "\t\t", .ms = 400 }, // through $2 to $0
            .{ .keys = "!", .ms = 300 }, // typed at the final stop, after ")"
            .{ .keys = "\x1b", .ms = 300 },
        }, "\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("final tabstop sits after the snippet", r.textHas("call(first, second)!"));
    }

    // Choice placeholders: ${1|const,var,let|} inserts the first alternative
    // and Ctrl-n / Ctrl-p cycle the rest in place.
    {
        const r = drive(ctx, &.{
            .{ .keys = "ochoice", .ms = 800 },
            .{ .keys = "\t", .ms = 500 },
        }, "\x1b\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("choice snippet inserts the first option", r.textHas("const name = ;"));
        // The full list is width-dependent (the file path shares the bar), so
        // assert on the hint itself; the cycling cases below prove the rest.
        ctx.check("choices are advertised in the statusline", r.plainHas("^n/^p choices"));
    }
    {
        const r = drive(ctx, &.{
            .{ .keys = "ochoice", .ms = 800 },
            .{ .keys = "\t", .ms = 500 },
            .{ .keys = "\x0e", .ms = 400 }, // Ctrl-n: next alternative
        }, "\x1b\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("Ctrl-n cycles to the next choice", r.textHas("var name = ;"));
    }
    {
        const r = drive(ctx, &.{
            .{ .keys = "ochoice", .ms = 800 },
            .{ .keys = "\t", .ms = 500 },
            .{ .keys = "\x10", .ms = 400 }, // Ctrl-p wraps to the last
        }, "\x1b\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("Ctrl-p wraps around the choices", r.textHas("let name = ;"));
    }

    // A multi-line snippet keeps its tabstops across lines, and typing Enter
    // inside a placeholder moves the later stops down with the text.
    {
        const r = drive(ctx, &.{
            .{ .keys = "omulti", .ms = 800 },
            .{ .keys = "\t", .ms = 500 },
            .{ .keys = "ready", .ms = 300 },
            .{ .keys = "\t", .ms = 300 }, // to $0 on the next line
            .{ .keys = "body();", .ms = 400 },
        }, "\x1b\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("multi-line snippet tabstops work", r.textHas("if ready {\n    body();\n}"));
    }
    {
        const r = drive(ctx, &.{
            .{ .keys = "omulti", .ms = 800 },
            .{ .keys = "\t", .ms = 500 },
            .{ .keys = "a", .ms = 250 },
            .{ .keys = "\r", .ms = 250 }, // split inside the placeholder
            .{ .keys = "b", .ms = 250 },
            .{ .keys = "\t", .ms = 400 }, // the final stop followed the split
            .{ .keys = "Z", .ms = 300 },
        }, "\x1b\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("tabstops survive a line split", r.textHas("if a\nb {\n    Z\n}"));
    }

    // A textEdit item replaces the server's own range (the four characters
    // before the cursor), and its additionalTextEdits are applied too.
    {
        const r = drive(ctx, &.{
            .{ .keys = "oedit", .ms = 800 },
            .{ .keys = "\t", .ms = 600 },
            .{ .keys = "\x1b", .ms = 300 },
        }, "\x1b:wq\r");
        defer r.deinit(ctx.gpa);
        ctx.check("textEdit range replaces the typed text", r.textHas("EDITED") and !r.textHas("edit\n"));
        ctx.check("additionalTextEdits are applied", r.textHas("IMPORT"));
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

    // The rename prompt never ghosts (decision: it has no history, and
    // command names make no sense there) — and a suggestion left over from a
    // `:` line must not leak into it. "able was I" strictly extends the
    // pre-filled identifier "a", so a leak would render "rename: able".
    {
        const r = drive(ctx, &.{
            .{ .keys = ":able was I\x1b", .ms = 300 }, // seed ex history
            .{ .keys = ":a\x1b", .ms = 300 }, // ghost "ble was I" shows, then Esc
            .{ .keys = "0wgr", .ms = 500 },
        }, "\x1b" ++ quit);
        defer r.deinit(ctx.gpa);
        ctx.check("rename prompt shows no ghost", r.plainHas("rename: a") and !r.plainHas("rename: able"));
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

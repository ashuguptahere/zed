//! A minimal Language Server Protocol client (pure Zig, std only).
//!
//! Spawns a language server, speaks JSON-RPC over its stdio with Content-Length
//! framing, and surfaces what the editor needs: diagnostics (pushed by the
//! server), plus hover, goto-definition, completion and signature help on
//! request. It is best-effort — if the server binary is missing or the
//! handshake times out, the client simply reports itself as not started and the
//! editor carries on.
//!
//! The server's stdout fd is exposed so the editor can poll it alongside the
//! terminal; incoming messages are processed without blocking the UI.

const std = @import("std");
const posix = std.posix;
const unicode = @import("unicode.zig");
const log = @import("log.zig");
const Allocator = std.mem.Allocator;

pub const Diagnostic = struct {
    line: usize, // 0-based
    severity: u8, // 1=error 2=warning 3=info 4=hint
    message: []u8,
};

pub const Location = struct { uri: []u8, line: usize, col: usize };

/// A completion candidate. `insert` is the text (or snippet source) to put in
/// the buffer; `edit` is the server's own replacement range when it sent a
/// `textEdit`, which beats our identifier-prefix guess. `extra` holds
/// `additionalTextEdits` (auto-imports and the like), applied alongside.
pub const Completion = struct {
    label: []u8,
    insert: []u8,
    is_snippet: bool = false, // insertTextFormat == 2
    edit: ?TextEdit = null,
    extra: []TextEdit = &.{},
};

pub const Signature = struct {
    label: []u8,
    active_start: usize, // byte range of the active parameter within `label`
    active_end: usize, // == active_start when there is no active parameter
};

/// One edit from a WorkspaceEdit: replace [start, end) (LSP positions, UTF-16
/// columns) with `text`.
pub const TextEdit = struct {
    start_line: u32,
    start_char: u32,
    end_line: u32,
    end_char: u32,
    text: []u8,
};

/// All the edits a WorkspaceEdit carries for one file.
pub const FileEdits = struct {
    uri: []u8,
    edits: std.ArrayList(TextEdit),
};

fn clearFileEdits(gpa: std.mem.Allocator, files: *std.ArrayList(FileEdits)) void {
    for (files.items) |*f| {
        gpa.free(f.uri);
        for (f.edits.items) |e| gpa.free(e.text);
        f.edits.deinit(gpa);
    }
    files.clearRetainingCapacity();
}

/// A code action offered by the server. `files` are the WorkspaceEdit entries
/// (grouped per file — cross-file actions apply everywhere); `command` /
/// `arguments` (when present) are run via `workspace/executeCommand`.
pub const CodeAction = struct {
    title: []u8,
    files: std.ArrayList(FileEdits),
    command: ?[]u8 = null, // command id for executeCommand
    arguments: ?[]u8 = null, // serialized JSON arguments array
};

/// Virtual text the server wants shown inline at (line, col). `col` is a UTF-16
/// character offset; `text` is the (flattened) label.
pub const InlayHint = struct {
    line: u32,
    col: u32,
    text: []u8,
};

/// A document symbol, flattened from the (possibly nested) response. `kind` is
/// the LSP SymbolKind; `depth` is the nesting level (0 = top); (line, col) is
/// the symbol's selection position.
/// A `workspace/symbol` result: a symbol anywhere in the project, with the
/// file it lives in. Bounded per response and cleared before each new one, so
/// this list never grows unbounded.
pub const WorkspaceSymbol = struct {
    name: []u8,
    uri: []u8,
    kind: u8,
    line: u32,
    col: u32,
};

pub const Symbol = struct {
    name: []u8,
    kind: u8,
    line: u32,
    col: u32,
    depth: u8,
};

pub const Client = struct {
    gpa: Allocator,
    io: std.Io,
    child: std.process.Child,
    out_fd: posix.fd_t,
    alive: bool,
    next_id: i64,
    version: i64,

    uri: []u8, // file:// URI of the open document
    read_buf: std.ArrayList(u8),
    diags: std.ArrayList(Diagnostic),

    init_done: bool,
    incremental: bool, // server supports incremental textDocument/didChange
    can_format: bool, // server advertises documentFormattingProvider
    doc: std.ArrayList(u8), // mirror of the open document, for diffing changes
    hover_id: i64,
    def_id: i64,
    comp_id: i64,
    sig_id: i64,
    hover_text: ?[]u8, // pending hover result for the editor to show
    def_target: ?Location, // pending goto-definition result
    completions: std.ArrayList(Completion), // last completion result
    comp_ready: bool, // a completion response just arrived (editor should consume)
    signatures: std.ArrayList(Signature), // all overloads from the last response
    sig_active: usize, // index of the displayed overload (server-suggested, then cycled)
    sig_ready: bool, // a signatureHelp response just arrived (editor should consume)
    rename_id: i64,
    rename_files: std.ArrayList(FileEdits), // pending rename edits, per file
    rename_ready: bool, // a rename response just arrived (editor should apply)
    ca_id: i64,
    code_actions: std.ArrayList(CodeAction), // last code-action result
    ca_ready: bool, // a codeAction response just arrived (editor should consume)
    server_files: std.ArrayList(FileEdits), // edits from a workspace/applyEdit request
    apply_ready: bool, // a workspace/applyEdit just arrived (editor should apply)
    ref_id: i64,
    references: std.ArrayList(Location), // last references result
    refs_ready: bool,
    fmt_id: i64,
    fmt_edits: std.ArrayList(TextEdit), // formatting edits for the open document
    fmt_ready: bool,
    hint_id: i64,
    inlay_hints: std.ArrayList(InlayHint), // virtual text for the open document
    sym_id: i64,
    symbols: std.ArrayList(Symbol), // last documentSymbol result (flattened)
    sym_ready: bool, // a documentSymbol response just arrived (editor should consume)
    wsym_id: i64,
    wsymbols: std.ArrayList(WorkspaceSymbol), // last workspace/symbol result
    wsym_ready: bool,

    pub fn start(
        gpa: Allocator,
        io: std.Io,
        argv: []const []const u8,
        root: []const u8,
        uri: []const u8,
        language_id: []const u8,
        content: []const u8,
    ) ?Client {
        const child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch |err| {
            std.log.scoped(.lsp).warn("cannot spawn {s}: {s}", .{ argv[0], @errorName(err) });
            return null;
        };

        var self: Client = .{
            .gpa = gpa,
            .io = io,
            .child = child,
            .out_fd = child.stdout.?.handle,
            .alive = true,
            .next_id = 2,
            .version = 1,
            .uri = gpa.dupe(u8, uri) catch return null,
            .read_buf = .empty,
            .diags = .empty,
            .init_done = false,
            .incremental = false,
            .can_format = false,
            .doc = .empty,
            .hover_id = -1,
            .def_id = -1,
            .comp_id = -1,
            .sig_id = -1,
            .hover_text = null,
            .def_target = null,
            .completions = .empty,
            .comp_ready = false,
            .signatures = .empty,
            .sig_active = 0,
            .sig_ready = false,
            .rename_id = -1,
            .rename_files = .empty,
            .rename_ready = false,
            .ca_id = -1,
            .code_actions = .empty,
            .ca_ready = false,
            .server_files = .empty,
            .apply_ready = false,
            .ref_id = -1,
            .references = .empty,
            .refs_ready = false,
            .fmt_id = -1,
            .fmt_edits = .empty,
            .fmt_ready = false,
            .hint_id = -1,
            .inlay_hints = .empty,
            .sym_id = -1,
            .symbols = .empty,
            .sym_ready = false,
            .wsym_id = -1,
            .wsymbols = .empty,
            .wsym_ready = false,
        };

        self.sendInitialize(root);
        // Pump until the server answers `initialize`, or give up.
        const started = log.nowMs();
        const deadline = started + 4000;
        while (!self.init_done and self.alive and log.nowMs() < deadline) {
            if (pollReadable(self.out_fd, 200)) self.readAvailable();
        }
        if (!self.init_done) {
            std.log.scoped(.lsp).warn("{s}: no initialize response within 4s — giving up", .{argv[0]});
            self.deinit();
            return null;
        }
        std.log.scoped(.lsp).info("{s}: handshake done in {d} ms", .{ argv[0], log.nowMs() - started });
        self.sendNotification("initialized", "{}");
        self.sendDidOpen(language_id, content);
        return self;
    }

    pub fn deinit(self: *Client) void {
        self.child.kill(self.io);
        self.gpa.free(self.uri);
        self.read_buf.deinit(self.gpa);
        self.doc.deinit(self.gpa);
        self.clearDiags();
        self.diags.deinit(self.gpa);
        self.clearCompletions();
        self.completions.deinit(self.gpa);
        self.clearSignatures();
        self.signatures.deinit(self.gpa);
        clearFileEdits(self.gpa, &self.rename_files);
        self.rename_files.deinit(self.gpa);
        self.clearCodeActions();
        self.code_actions.deinit(self.gpa);
        clearFileEdits(self.gpa, &self.server_files);
        self.server_files.deinit(self.gpa);
        for (self.references.items) |r| self.gpa.free(r.uri);
        self.references.deinit(self.gpa);
        for (self.fmt_edits.items) |e| self.gpa.free(e.text);
        self.fmt_edits.deinit(self.gpa);
        self.clearInlayHints();
        self.inlay_hints.deinit(self.gpa);
        self.clearSymbols();
        self.symbols.deinit(self.gpa);
        self.clearWorkspaceSymbols();
        self.wsymbols.deinit(self.gpa);
        if (self.hover_text) |t| self.gpa.free(t);
        if (self.def_target) |d| self.gpa.free(d.uri);
    }

    fn clearDiags(self: *Client) void {
        for (self.diags.items) |d| self.gpa.free(d.message);
        self.diags.clearRetainingCapacity();
    }

    fn clearCompletions(self: *Client) void {
        for (self.completions.items) |it| {
            self.gpa.free(it.label);
            self.gpa.free(it.insert);
            if (it.edit) |e| self.gpa.free(e.text);
            for (it.extra) |e| self.gpa.free(e.text);
            if (it.extra.len > 0) self.gpa.free(it.extra);
        }
        self.completions.clearRetainingCapacity();
    }

    fn clearSignatures(self: *Client) void {
        for (self.signatures.items) |s| self.gpa.free(s.label);
        self.signatures.clearRetainingCapacity();
        self.sig_active = 0;
    }

    fn clearCodeActions(self: *Client) void {
        for (self.code_actions.items) |*a| {
            self.gpa.free(a.title);
            clearFileEdits(self.gpa, &a.files);
            a.files.deinit(self.gpa);
            if (a.command) |c| self.gpa.free(c);
            if (a.arguments) |args| self.gpa.free(args);
        }
        self.code_actions.clearRetainingCapacity();
    }

    pub fn clearServerFiles(self: *Client) void {
        clearFileEdits(self.gpa, &self.server_files);
    }

    fn clearInlayHints(self: *Client) void {
        for (self.inlay_hints.items) |hint| self.gpa.free(hint.text);
        self.inlay_hints.clearRetainingCapacity();
    }

    fn clearWorkspaceSymbols(self: *Client) void {
        for (self.wsymbols.items) |s| {
            self.gpa.free(s.name);
            self.gpa.free(s.uri);
        }
        self.wsymbols.clearRetainingCapacity();
    }

    fn clearSymbols(self: *Client) void {
        for (self.symbols.items) |s| self.gpa.free(s.name);
        self.symbols.clearRetainingCapacity();
    }

    // --- outgoing ----------------------------------------------------------

    fn sendInitialize(self: *Client, root: []const u8) void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        body.appendSlice(self.gpa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"processId\":null,\"rootUri\":\"file://") catch return;
        appendEscaped(&body, self.gpa, root) catch return;
        body.appendSlice(self.gpa, "\",\"capabilities\":{\"textDocument\":{\"publishDiagnostics\":{},\"hover\":{},\"definition\":{},\"implementation\":{},\"typeDefinition\":{},\"completion\":{\"completionItem\":{\"snippetSupport\":true}},\"signatureHelp\":{},\"rename\":{},\"codeAction\":{},\"inlayHint\":{},\"documentSymbol\":{},\"workspaceSymbol\":{},\"references\":{},\"formatting\":{}}}}}") catch return;
        self.writeMessage(body.items);
    }

    fn sendDidOpen(self: *Client, language_id: []const u8, content: []const u8) void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        const a = self.gpa;
        body.appendSlice(a, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"") catch return;
        appendEscaped(&body, a, self.uri) catch return;
        body.appendSlice(a, "\",\"languageId\":\"") catch return;
        appendEscaped(&body, a, language_id) catch return;
        body.appendSlice(a, "\",\"version\":1,\"text\":\"") catch return;
        appendEscaped(&body, a, content) catch return;
        body.appendSlice(a, "\"}}}") catch return;
        self.writeMessage(body.items);
        self.rememberDoc(content);
    }

    /// Notify the server of an edit. Sends an incremental change (just the
    /// edited range) when the server supports it, else the full document.
    pub fn didChange(self: *Client, content: []const u8) void {
        if (!self.alive) return;
        self.version += 1;
        if (self.incremental) self.sendDidChangeIncremental(content) else self.sendDidChangeFull(content);
        self.rememberDoc(content);
    }

    fn sendDidChangeFull(self: *Client, content: []const u8) void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        const a = self.gpa;
        self.changeHeader(&body) catch return;
        body.appendSlice(a, "\"text\":\"") catch return;
        appendEscaped(&body, a, content) catch return;
        body.appendSlice(a, "\"}]}}") catch return;
        self.writeMessage(body.items);
    }

    fn sendDidChangeIncremental(self: *Client, content: []const u8) void {
        const old = self.doc.items;
        // Common prefix/suffix -> a single changed range [start, old_end).
        const min = @min(old.len, content.len);
        var p: usize = 0;
        while (p < min and old[p] == content[p]) p += 1;
        var s: usize = 0;
        while (s < min - p and old[old.len - 1 - s] == content[content.len - 1 - s]) s += 1;
        const old_end = old.len - s;
        const new_text = content[p .. content.len - s];

        const start_pos = utf16Pos(old, p);
        const end_pos = utf16Pos(old, old_end);

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        const a = self.gpa;
        self.changeHeader(&body) catch return;
        var nb: [128]u8 = undefined;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"text\":\"", .{ start_pos.line, start_pos.character, end_pos.line, end_pos.character }) catch return) catch return;
        appendEscaped(&body, a, new_text) catch return;
        body.appendSlice(a, "\"}]}}") catch return;
        self.writeMessage(body.items);
    }

    /// Writes the didChange envelope up to (but not including) the first
    /// contentChange's fields: `...{"uri":...,"version":N},"contentChanges":[{`
    fn changeHeader(self: *Client, body: *std.ArrayList(u8)) !void {
        const a = self.gpa;
        try body.appendSlice(a, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"");
        try appendEscaped(body, a, self.uri);
        var nb: [32]u8 = undefined;
        try body.appendSlice(a, std.fmt.bufPrint(&nb, "\",\"version\":{d}", .{self.version}) catch return);
        try body.appendSlice(a, "},\"contentChanges\":[{");
    }

    fn rememberDoc(self: *Client, content: []const u8) void {
        self.doc.clearRetainingCapacity();
        self.doc.appendSlice(self.gpa, content) catch self.doc.clearRetainingCapacity();
    }

    pub fn requestCompletion(self: *Client, line: usize, col: usize) void {
        self.comp_id = self.nextId();
        self.sendPositionRequest(self.comp_id, "textDocument/completion", line, col);
    }

    pub fn requestSignatureHelp(self: *Client, line: usize, col: usize) void {
        self.sig_id = self.nextId();
        self.sendPositionRequest(self.sig_id, "textDocument/signatureHelp", line, col);
    }

    pub fn requestHover(self: *Client, line: usize, col: usize) void {
        self.hover_id = self.nextId();
        self.sendPositionRequest(self.hover_id, "textDocument/hover", line, col);
    }

    pub fn requestDefinition(self: *Client, line: usize, col: usize) void {
        self.def_id = self.nextId();
        self.sendPositionRequest(self.def_id, "textDocument/definition", line, col);
    }

    /// `gi` / `gy`: the same Location(s) plumbing as goto-definition, so the
    /// reply lands in `def_target` and the editor jumps the same way.
    pub fn requestImplementation(self: *Client, line: usize, col: usize) void {
        self.def_id = self.nextId();
        self.sendPositionRequest(self.def_id, "textDocument/implementation", line, col);
    }

    pub fn requestTypeDefinition(self: *Client, line: usize, col: usize) void {
        self.def_id = self.nextId();
        self.sendPositionRequest(self.def_id, "textDocument/typeDefinition", line, col);
    }

    /// Request code actions for the range [sl,sc)-(el,ec]. We pass an empty
    /// diagnostics context (the editor doesn't keep diagnostic ranges), so this
    /// surfaces range/refactor actions plus any the server offers unprompted.
    pub fn requestCodeAction(self: *Client, sl: usize, sc: usize, el: usize, ec: usize) void {
        if (!self.alive) return;
        self.ca_id = self.nextId();
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        const a = self.gpa;
        var nb: [256]u8 = undefined;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"textDocument/codeAction\",\"params\":{{\"textDocument\":{{\"uri\":\"", .{self.ca_id}) catch return) catch return;
        appendEscaped(&body, a, self.uri) catch return;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "\"}},\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"context\":{{\"diagnostics\":[]}}}}}}", .{ sl, sc, el, ec }) catch return) catch return;
        self.writeMessage(body.items);
    }

    /// Run a code action's command. The server typically responds by sending a
    /// `workspace/applyEdit` request (handled in `handleMessage`); the command
    /// response itself is usually null and we don't track it.
    pub fn executeCommand(self: *Client, command: []const u8, arguments_json: ?[]const u8) void {
        if (!self.alive) return;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        const a = self.gpa;
        var nb: [160]u8 = undefined;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"workspace/executeCommand\",\"params\":{{\"command\":\"", .{self.nextId()}) catch return) catch return;
        appendEscaped(&body, a, command) catch return;
        body.appendSlice(a, "\"") catch return;
        if (arguments_json) |args| {
            body.appendSlice(a, ",\"arguments\":") catch return;
            body.appendSlice(a, args) catch return;
        }
        body.appendSlice(a, "}}") catch return;
        self.writeMessage(body.items);
    }

    /// `workspace/symbol`: symbols across the project, filtered by `query`
    /// server-side (an empty query asks for everything the server will give).
    pub fn requestWorkspaceSymbol(self: *Client, query: []const u8) void {
        if (!self.alive) return;
        self.wsym_id = self.nextId();
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        const a = self.gpa;
        var nb: [128]u8 = undefined;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"workspace/symbol\",\"params\":{{\"query\":\"", .{self.wsym_id}) catch return) catch return;
        appendEscaped(&body, a, query) catch return;
        body.appendSlice(a, "\"}}") catch return;
        self.writeMessage(body.items);
    }

    pub fn requestDocumentSymbol(self: *Client) void {
        if (!self.alive) return;
        self.sym_id = self.nextId();
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        const a = self.gpa;
        var nb: [128]u8 = undefined;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"textDocument/documentSymbol\",\"params\":{{\"textDocument\":{{\"uri\":\"", .{self.sym_id}) catch return) catch return;
        appendEscaped(&body, a, self.uri) catch return;
        body.appendSlice(a, "\"}}}") catch return; // close uri", textDocument, params, root
        self.writeMessage(body.items);
    }

    /// Request inlay hints for the whole document [0,0]-[end_line,0].
    pub fn requestInlayHints(self: *Client, end_line: usize) void {
        if (!self.alive) return;
        self.hint_id = self.nextId();
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        const a = self.gpa;
        var nb: [160]u8 = undefined;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"textDocument/inlayHint\",\"params\":{{\"textDocument\":{{\"uri\":\"", .{self.hint_id}) catch return) catch return;
        appendEscaped(&body, a, self.uri) catch return;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "\"}},\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}}}}}}", .{end_line}) catch return) catch return;
        self.writeMessage(body.items);
    }

    pub fn requestRename(self: *Client, line: usize, col: usize, new_name: []const u8) void {
        if (!self.alive) return;
        self.rename_id = self.nextId();
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        const a = self.gpa;
        var nb: [200]u8 = undefined;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"textDocument/rename\",\"params\":{{\"textDocument\":{{\"uri\":\"", .{self.rename_id}) catch return) catch return;
        appendEscaped(&body, a, self.uri) catch return;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "\"}},\"position\":{{\"line\":{d},\"character\":{d}}},\"newName\":\"", .{ line, col }) catch return) catch return;
        appendEscaped(&body, a, new_name) catch return;
        body.appendSlice(a, "\"}}") catch return;
        self.writeMessage(body.items);
    }

    pub fn requestReferences(self: *Client, line: usize, col: usize) void {
        if (!self.alive) return;
        self.ref_id = self.nextId();
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        const a = self.gpa;
        var nb: [200]u8 = undefined;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"textDocument/references\",\"params\":{{\"textDocument\":{{\"uri\":\"", .{self.ref_id}) catch return) catch return;
        appendEscaped(&body, a, self.uri) catch return;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "\"}},\"position\":{{\"line\":{d},\"character\":{d}}},\"context\":{{\"includeDeclaration\":true}}}}}}", .{ line, col }) catch return) catch return;
        self.writeMessage(body.items);
    }

    /// Request whole-document formatting with the editor's indent settings.
    pub fn requestFormatting(self: *Client, tab_size: usize) void {
        if (!self.alive) return;
        self.fmt_id = self.nextId();
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        const a = self.gpa;
        var nb: [160]u8 = undefined;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"textDocument/formatting\",\"params\":{{\"textDocument\":{{\"uri\":\"", .{self.fmt_id}) catch return) catch return;
        appendEscaped(&body, a, self.uri) catch return;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "\"}},\"options\":{{\"tabSize\":{d},\"insertSpaces\":true}}}}}}", .{tab_size}) catch return) catch return;
        self.writeMessage(body.items);
    }

    fn sendPositionRequest(self: *Client, id: i64, method: []const u8, line: usize, col: usize) void {
        if (!self.alive) return;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        const a = self.gpa;
        var nb: [200]u8 = undefined;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{{\"textDocument\":{{\"uri\":\"", .{ id, method }) catch return) catch return;
        appendEscaped(&body, a, self.uri) catch return;
        body.appendSlice(a, std.fmt.bufPrint(&nb, "\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ line, col }) catch return) catch return;
        self.writeMessage(body.items);
    }

    fn sendNotification(self: *Client, method: []const u8, params: []const u8) void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var nb: [128]u8 = undefined;
        body.appendSlice(self.gpa, std.fmt.bufPrint(&nb, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":", .{method}) catch return) catch return;
        body.appendSlice(self.gpa, params) catch return;
        body.appendSlice(self.gpa, "}") catch return;
        self.writeMessage(body.items);
    }

    fn nextId(self: *Client) i64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn writeMessage(self: *Client, body: []const u8) void {
        if (!self.alive) return;
        var hdr: [64]u8 = undefined;
        const h = std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return;
        const stdin = self.child.stdin.?;
        stdin.writeStreamingAll(self.io, h) catch {
            self.alive = false;
            return;
        };
        stdin.writeStreamingAll(self.io, body) catch {
            self.alive = false;
        };
    }

    // --- incoming ----------------------------------------------------------

    /// Called by the editor when the server's stdout is readable.
    pub fn readAvailable(self: *Client) void {
        var tmp: [4096]u8 = undefined;
        const n = posix.read(self.out_fd, &tmp) catch {
            if (self.alive) std.log.scoped(.lsp).warn("server read failed — marking it dead", .{});
            self.alive = false;
            return;
        };
        if (n == 0) {
            if (self.alive) std.log.scoped(.lsp).warn("server closed its stdout (exited?)", .{});
            self.alive = false;
            return;
        }
        self.read_buf.appendSlice(self.gpa, tmp[0..n]) catch return;
        self.drainFrames();
    }

    fn drainFrames(self: *Client) void {
        while (true) {
            const buf = self.read_buf.items;
            const sep = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return;
            const len = contentLength(buf[0..sep]) orelse {
                // Unparseable header; drop it and continue.
                self.read_buf.replaceRange(self.gpa, 0, sep + 4, &.{}) catch return;
                continue;
            };
            const total = sep + 4 + len;
            if (self.read_buf.items.len < total) return; // wait for the rest
            self.handleMessage(self.read_buf.items[sep + 4 .. total]);
            self.read_buf.replaceRange(self.gpa, 0, total, &.{}) catch return;
        }
    }

    /// Block up to `timeout_ms` for server output and process it (used by the
    /// bounded synchronous wait in format-on-save). One poll + read per call.
    pub fn pump(self: *Client, timeout_ms: i32) void {
        if (!self.alive) return;
        if (pollReadable(self.out_fd, timeout_ms)) self.readAvailable();
    }

    fn handleMessage(self: *Client, body: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, body, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const obj = parsed.value.object;

        if (obj.get("method")) |m| {
            if (m != .string) return;
            if (std.mem.eql(u8, m.string, "textDocument/publishDiagnostics")) {
                if (obj.get("params")) |p| self.updateDiagnostics(p);
            } else if (std.mem.eql(u8, m.string, "workspace/applyEdit")) {
                self.handleApplyEdit(obj);
            }
            return;
        }
        const id = if (obj.get("id")) |v| (if (v == .integer) v.integer else return) else return;
        const result_opt = obj.get("result");
        if (id == 1) { // response to our `initialize`
            self.init_done = true;
            if (result_opt) |r| self.parseServerCaps(r);
            return;
        }
        const result = result_opt orelse return;
        if (id == self.hover_id) self.handleHover(result);
        if (id == self.def_id) self.handleDefinition(result);
        if (id == self.comp_id) self.handleCompletion(result);
        if (id == self.sig_id) self.handleSignature(result);
        if (id == self.rename_id) self.handleRename(result);
        if (id == self.ca_id) self.handleCodeAction(result);
        if (id == self.hint_id) self.handleInlayHints(result);
        if (id == self.sym_id) self.handleDocumentSymbol(result);
        if (id == self.wsym_id) self.handleWorkspaceSymbol(result);
        if (id == self.ref_id) self.handleReferences(result);
        if (id == self.fmt_id) self.handleFormatting(result);
    }

    /// Read the server's `textDocumentSync` to decide full vs. incremental
    /// change notifications (it may be an integer or `{change: int}`), and
    /// whether it can format (so format-on-save skips servers that can't).
    fn parseServerCaps(self: *Client, result: std.json.Value) void {
        const caps = getField(result, "capabilities") orelse return;
        if (getField(caps, "documentFormattingProvider")) |f| {
            self.can_format = switch (f) {
                .bool => |b| b,
                .object => true,
                else => false,
            };
        }
        const sync = getField(caps, "textDocumentSync") orelse return;
        const change: i64 = switch (sync) {
            .integer => |i| i,
            .object => asInt(getField(sync, "change")) orelse 0,
            else => 0,
        };
        self.incremental = (change == 2);
    }

    fn handleCompletion(self: *Client, result: std.json.Value) void {
        self.clearCompletions();
        // result is a CompletionList {items: [...]}, a bare array, or null.
        const items = switch (result) {
            .array => result,
            .object => getField(result, "items") orelse return,
            else => return,
        };
        if (items != .array) return;
        for (items.array.items) |it| {
            if (self.completions.items.len >= 400) break;
            const label = asStr(getField(it, "label")) orelse continue;

            // A textEdit (or the insert side of an InsertReplaceEdit) carries
            // both the text and the exact range it replaces.
            var edit: ?TextEdit = null;
            if (getField(it, "textEdit")) |te| {
                const range = getField(te, "range") orelse getField(te, "insert") orelse getField(te, "replace");
                if (range) |r| edit = parseRangeEdit(self, r, asStr(getField(te, "newText")) orelse "");
            }
            const insert = if (edit) |e| e.text else (asStr(getField(it, "insertText")) orelse label);

            const l = self.gpa.dupe(u8, label) catch {
                if (edit) |e| self.gpa.free(e.text);
                continue;
            };
            const ins = self.gpa.dupe(u8, insert) catch {
                self.gpa.free(l);
                if (edit) |e| self.gpa.free(e.text);
                continue;
            };
            var extra: std.ArrayList(TextEdit) = .empty;
            if (getField(it, "additionalTextEdits")) |arr| self.collectEdits(arr, &extra);
            const fmt = asInt(getField(it, "insertTextFormat")) orelse 1;

            self.completions.append(self.gpa, .{
                .label = l,
                .insert = ins,
                .is_snippet = fmt == 2,
                .edit = edit,
                .extra = extra.toOwnedSlice(self.gpa) catch &.{},
            }) catch {
                self.gpa.free(l);
                self.gpa.free(ins);
                if (edit) |e| self.gpa.free(e.text);
            };
        }
        self.comp_ready = true;
    }

    /// Parse a `SignatureHelp`: keep every overload (with each one's active
    /// parameter located within its own label) plus the server-suggested active
    /// index. `sig_ready` is set regardless so the editor (re)opens or closes
    /// the popup.
    fn handleSignature(self: *Client, result: std.json.Value) void {
        self.clearSignatures();
        self.sig_ready = true;
        const sigs = getField(result, "signatures") orelse return;
        if (sigs != .array or sigs.array.items.len == 0) return;
        const top_active_param = asInt(getField(result, "activeParameter"));

        for (sigs.array.items) |sig| {
            const label = asStr(getField(sig, "label")) orelse continue;
            const owned = self.gpa.dupe(u8, label) catch continue;
            const r = paramRange(sig, owned, top_active_param);
            self.signatures.append(self.gpa, .{ .label = owned, .active_start = r.start, .active_end = r.end }) catch {
                self.gpa.free(owned);
            };
        }
        const n = self.signatures.items.len;
        if (n == 0) return;
        const idx = asInt(getField(result, "activeSignature")) orelse 0;
        self.sig_active = if (idx >= 0 and @as(usize, @intCast(idx)) < n) @intCast(idx) else 0;
    }

    /// A rename's result is a `WorkspaceEdit`; keep every file's edits (the
    /// editor applies them across buffers). `rename_ready` is set regardless so
    /// the editor consumes the result (an empty list means "no changes").
    fn handleRename(self: *Client, result: std.json.Value) void {
        clearFileEdits(self.gpa, &self.rename_files);
        self.rename_ready = true;
        if (result == .object) self.parseWorkspaceEdit(result, &self.rename_files);
    }

    /// A code-action result is an array of `CodeAction | Command`; keep each
    /// one's title, its inline `edit` (all files), and its `command` (executed
    /// via executeCommand). A bare `Command` has `command` as a string; a
    /// `CodeAction.command` is a nested object.
    fn handleCodeAction(self: *Client, result: std.json.Value) void {
        self.clearCodeActions();
        self.ca_ready = true;
        if (result != .array) return;
        for (result.array.items) |a| {
            const title = asStr(getField(a, "title")) orelse continue;
            const owned_title = self.gpa.dupe(u8, title) catch continue;

            var files: std.ArrayList(FileEdits) = .empty;
            if (getField(a, "edit")) |edit| self.parseWorkspaceEdit(edit, &files);

            // Locate the command id and arguments (bare Command vs CodeAction.command).
            var cmd_str: ?[]const u8 = null;
            var args_val: ?std.json.Value = null;
            if (getField(a, "command")) |c| switch (c) {
                .string => |s| {
                    cmd_str = s;
                    args_val = getField(a, "arguments");
                },
                .object => {
                    cmd_str = asStr(getField(c, "command"));
                    args_val = getField(c, "arguments");
                },
                else => {},
            };
            const command = if (cmd_str) |s| (self.gpa.dupe(u8, s) catch null) else null;
            const arguments = if (args_val) |v| (std.json.Stringify.valueAlloc(self.gpa, v, .{}) catch null) else null;

            self.code_actions.append(self.gpa, .{
                .title = owned_title,
                .files = files,
                .command = command,
                .arguments = arguments,
            }) catch {
                clearFileEdits(self.gpa, &files);
                files.deinit(self.gpa);
                self.gpa.free(owned_title);
                if (command) |c| self.gpa.free(c);
                if (arguments) |args| self.gpa.free(args);
            };
        }
    }

    /// Parse an `InlayHint[]` result: each hint's position and (flattened)
    /// label. Replaces the stored hints; the editor reads them while rendering.
    fn handleInlayHints(self: *Client, result: std.json.Value) void {
        self.clearInlayHints();
        if (result != .array) return;
        for (result.array.items) |hint| {
            const pos = getField(hint, "position") orelse continue;
            const text = inlayLabel(self.gpa, getField(hint, "label")) orelse continue;
            self.inlay_hints.append(self.gpa, .{
                .line = u32From(getField(pos, "line")),
                .col = u32From(getField(pos, "character")),
                .text = text,
            }) catch self.gpa.free(text);
        }
    }

    /// Parse a documentSymbol result — either a nested `DocumentSymbol[]` or a
    /// flat `SymbolInformation[]` — into a flat list (children depth-tagged).
    fn handleDocumentSymbol(self: *Client, result: std.json.Value) void {
        self.clearSymbols();
        self.sym_ready = true;
        if (result != .array) return;
        for (result.array.items) |s| self.addSymbol(s, 0);
    }

    /// Parse a `WorkspaceSymbol[]` / `SymbolInformation[]`: each entry has a
    /// name and a location (uri + range).
    fn handleWorkspaceSymbol(self: *Client, result: std.json.Value) void {
        self.clearWorkspaceSymbols();
        self.wsym_ready = true;
        if (result != .array) return;
        for (result.array.items) |s| {
            if (self.wsymbols.items.len >= 1000) break; // bound a huge project
            const name = asStr(getField(s, "name")) orelse continue;
            const loc = getField(s, "location") orelse continue;
            const uri = asStr(getField(loc, "uri")) orelse continue;
            const pos = if (getField(loc, "range")) |r| getField(r, "start") else null;
            const owned_name = self.gpa.dupe(u8, name) catch continue;
            const owned_uri = self.gpa.dupe(u8, uri) catch {
                self.gpa.free(owned_name);
                continue;
            };
            self.wsymbols.append(self.gpa, .{
                .name = owned_name,
                .uri = owned_uri,
                .kind = @intCast(u32From(getField(s, "kind"))),
                .line = if (pos) |p| u32From(getField(p, "line")) else 0,
                .col = if (pos) |p| u32From(getField(p, "character")) else 0,
            }) catch {
                self.gpa.free(owned_name);
                self.gpa.free(owned_uri);
            };
        }
    }

    fn addSymbol(self: *Client, s: std.json.Value, depth: u8) void {
        if (self.symbols.items.len >= 1000) return; // bound pathological files
        const name = asStr(getField(s, "name")) orelse return;
        // Position: DocumentSymbol.selectionRange/range.start, else
        // SymbolInformation.location.range.start.
        const pos = blk: {
            if (getField(s, "selectionRange")) |r| break :blk getField(r, "start");
            if (getField(s, "range")) |r| break :blk getField(r, "start");
            if (getField(s, "location")) |loc| {
                if (getField(loc, "range")) |r| break :blk getField(r, "start");
            }
            break :blk null;
        } orelse return;

        const owned = self.gpa.dupe(u8, name) catch return;
        self.symbols.append(self.gpa, .{
            .name = owned,
            .kind = @intCast(u32From(getField(s, "kind"))),
            .line = u32From(getField(pos, "line")),
            .col = u32From(getField(pos, "character")),
            .depth = depth,
        }) catch {
            self.gpa.free(owned);
            return;
        };
        if (getField(s, "children")) |ch| {
            if (ch == .array) for (ch.array.items) |c| self.addSymbol(c, depth +| 1);
        }
    }

    /// Apply a server-initiated `workspace/applyEdit` request: stash the edits
    /// for the editor to apply and answer `{applied: true}` (every file the
    /// edit touches). The request id is echoed in the response.
    fn handleApplyEdit(self: *Client, obj: std.json.ObjectMap) void {
        if (obj.get("params")) |p| {
            if (getField(p, "edit")) |edit| self.parseWorkspaceEdit(edit, &self.server_files);
        }
        self.apply_ready = true;
        if (obj.get("id")) |id_val| {
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(self.gpa);
            const a = self.gpa;
            body.appendSlice(a, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
            const id_json = std.json.Stringify.valueAlloc(a, id_val, .{}) catch return;
            defer a.free(id_json);
            body.appendSlice(a, id_json) catch return;
            body.appendSlice(a, ",\"result\":{\"applied\":true}}") catch return;
            self.writeMessage(body.items);
        }
    }

    /// Parse a `WorkspaceEdit` (the `changes` map or the `documentChanges`
    /// array) into per-file edit groups — every file, not just the open one.
    fn parseWorkspaceEdit(self: *Client, edit: std.json.Value, into: *std.ArrayList(FileEdits)) void {
        if (getField(edit, "changes")) |changes| {
            if (changes == .object) {
                var it = changes.object.iterator();
                while (it.next()) |entry| {
                    const file = self.fileEntry(into, entry.key_ptr.*) orelse continue;
                    self.collectEdits(entry.value_ptr.*, &file.edits);
                }
            }
            return;
        }
        if (getField(edit, "documentChanges")) |dc| {
            if (dc != .array) return;
            for (dc.array.items) |tde| {
                // Only TextDocumentEdit entries; create/rename/delete file
                // operations have no `textDocument` and are skipped.
                const td = getField(tde, "textDocument") orelse continue;
                const uri = asStr(getField(td, "uri")) orelse continue;
                const arr = getField(tde, "edits") orelse continue;
                const file = self.fileEntry(into, uri) orelse continue;
                self.collectEdits(arr, &file.edits);
            }
        }
    }

    /// Find (or append) the `FileEdits` group for `uri`.
    fn fileEntry(self: *Client, into: *std.ArrayList(FileEdits), uri: []const u8) ?*FileEdits {
        for (into.items) |*f| {
            if (std.mem.eql(u8, f.uri, uri)) return f;
        }
        const owned = self.gpa.dupe(u8, uri) catch return null;
        into.append(self.gpa, .{ .uri = owned, .edits = .empty }) catch {
            self.gpa.free(owned);
            return null;
        };
        return &into.items[into.items.len - 1];
    }

    /// One LSP range + text as a TextEdit (the text is owned by the caller).
    fn parseRangeEdit(self: *Client, range: std.json.Value, new_text: []const u8) ?TextEdit {
        const s = getField(range, "start") orelse return null;
        const e = getField(range, "end") orelse return null;
        return .{
            .start_line = u32From(getField(s, "line")),
            .start_char = u32From(getField(s, "character")),
            .end_line = u32From(getField(e, "line")),
            .end_char = u32From(getField(e, "character")),
            .text = self.gpa.dupe(u8, new_text) catch return null,
        };
    }

    fn collectEdits(self: *Client, arr: std.json.Value, into: *std.ArrayList(TextEdit)) void {
        if (arr != .array) return;
        for (arr.array.items) |e| {
            const range = getField(e, "range") orelse continue;
            const s = getField(range, "start") orelse continue;
            const en = getField(range, "end") orelse continue;
            const new_text = asStr(getField(e, "newText")) orelse continue;
            const owned = self.gpa.dupe(u8, new_text) catch continue;
            into.append(self.gpa, .{
                .start_line = u32From(getField(s, "line")),
                .start_char = u32From(getField(s, "character")),
                .end_line = u32From(getField(en, "line")),
                .end_char = u32From(getField(en, "character")),
                .text = owned,
            }) catch self.gpa.free(owned);
        }
    }

    fn updateDiagnostics(self: *Client, params: std.json.Value) void {
        self.clearDiags();
        const arr = getField(params, "diagnostics") orelse return;
        if (arr != .array) return;
        for (arr.array.items) |d| {
            const range = getField(d, "range") orelse continue;
            const start_pos = getField(range, "start") orelse continue;
            const line = asInt(getField(start_pos, "line")) orelse continue;
            const sev: u8 = @intCast(asInt(getField(d, "severity")) orelse 1);
            const msg = asStr(getField(d, "message")) orelse "";
            const owned = self.gpa.dupe(u8, msg) catch continue;
            self.diags.append(self.gpa, .{ .line = @intCast(line), .severity = sev, .message = owned }) catch {
                self.gpa.free(owned);
            };
        }
    }

    fn handleHover(self: *Client, result: std.json.Value) void {
        if (self.hover_text) |t| self.gpa.free(t);
        self.hover_text = null;
        // result.contents may be a string, {value}, or {kind,value}.
        const contents = getField(result, "contents") orelse return;
        const text = switch (contents) {
            .string => |s| s,
            .object => asStr(getField(contents, "value")) orelse return,
            else => return,
        };
        self.hover_text = self.gpa.dupe(u8, text) catch null;
    }

    /// A references result is a `Location[]`. `refs_ready` is set regardless
    /// (an empty list means "no references found").
    fn handleReferences(self: *Client, result: std.json.Value) void {
        for (self.references.items) |r| self.gpa.free(r.uri);
        self.references.clearRetainingCapacity();
        self.refs_ready = true;
        if (result != .array) return;
        for (result.array.items) |loc| {
            if (self.references.items.len >= 1000) break; // bound huge symbols
            const uri = asStr(getField(loc, "uri")) orelse continue;
            const range = getField(loc, "range") orelse continue;
            const start_pos = getField(range, "start") orelse continue;
            const owned = self.gpa.dupe(u8, uri) catch continue;
            self.references.append(self.gpa, .{
                .uri = owned,
                .line = u32From(getField(start_pos, "line")),
                .col = u32From(getField(start_pos, "character")),
            }) catch self.gpa.free(owned);
        }
    }

    /// A formatting result is a `TextEdit[]` for the open document.
    fn handleFormatting(self: *Client, result: std.json.Value) void {
        for (self.fmt_edits.items) |e| self.gpa.free(e.text);
        self.fmt_edits.clearRetainingCapacity();
        self.fmt_ready = true;
        if (result == .array) self.collectEdits(result, &self.fmt_edits);
    }

    fn handleDefinition(self: *Client, result: std.json.Value) void {
        // result may be a Location or an array of Locations.
        const loc = switch (result) {
            .object => result,
            .array => |a| if (a.items.len > 0) a.items[0] else return,
            else => return,
        };
        const uri = asStr(getField(loc, "uri")) orelse return;
        const range = getField(loc, "range") orelse return;
        const start_pos = getField(range, "start") orelse return;
        const line = asInt(getField(start_pos, "line")) orelse return;
        const col = asInt(getField(start_pos, "character")) orelse 0;
        if (self.def_target) |d| self.gpa.free(d.uri);
        self.def_target = .{ .uri = self.gpa.dupe(u8, uri) catch return, .line = @intCast(line), .col = @intCast(col) };
    }

    // --- queries for the editor -------------------------------------------

    pub fn severityAt(self: *const Client, line: usize) ?u8 {
        var best: ?u8 = null;
        for (self.diags.items) |d| {
            if (d.line == line and (best == null or d.severity < best.?)) best = d.severity;
        }
        return best;
    }

    pub fn messageAt(self: *const Client, line: usize) ?[]const u8 {
        for (self.diags.items) |d| if (d.line == line) return d.message;
        return null;
    }

    pub fn counts(self: *const Client) struct { errors: usize, warnings: usize } {
        var e: usize = 0;
        var w: usize = 0;
        for (self.diags.items) |d| {
            if (d.severity == 1) e += 1 else if (d.severity == 2) w += 1;
        }
        return .{ .errors = e, .warnings = w };
    }

    /// The nearest diagnostic line strictly after (forward) or before `from`,
    /// wrapping around the document. Null when there are no diagnostics.
    pub fn nextDiagLine(self: *const Client, from: usize, forward: bool) ?usize {
        var near: ?usize = null; // closest in the requested direction
        var wrap: ?usize = null; // extreme line, used when nothing is past `from`
        for (self.diags.items) |d| {
            if (forward) {
                if (d.line > from and (near == null or d.line < near.?)) near = d.line;
                if (wrap == null or d.line < wrap.?) wrap = d.line;
            } else {
                if (d.line < from and (near == null or d.line > near.?)) near = d.line;
                if (wrap == null or d.line > wrap.?) wrap = d.line;
            }
        }
        return near orelse wrap;
    }

    /// Take the pending hover text (caller owns it and must free with gpa).
    pub fn takeHover(self: *Client) ?[]u8 {
        const t = self.hover_text;
        self.hover_text = null;
        return t;
    }

    /// Take the pending goto-definition target (caller owns `.uri`).
    pub fn takeDefinition(self: *Client) ?Location {
        const d = self.def_target;
        self.def_target = null;
        return d;
    }
};

// --- helpers ---------------------------------------------------------------

/// Byte offset -> LSP position (0-based line; character in UTF-16 code units,
/// which is what LSP uses — exact for BMP text, correct surrogate width above).
fn utf16Pos(content: []const u8, byte: usize) struct { line: u32, character: u32 } {
    var line: u32 = 0;
    var col: u32 = 0;
    var i: usize = 0;
    while (i < byte and i < content.len) {
        if (content[i] == '\n') {
            line += 1;
            col = 0;
            i += 1;
            continue;
        }
        const d = unicode.decode(content[i..]);
        col += if (d.cp > 0xFFFF) 2 else 1;
        i += d.len;
    }
    return .{ .line = line, .character = col };
}

/// UTF-16 code-unit offset within a string -> byte offset (the inverse of the
/// column part of `utf16Pos`, for the single-line label offsets LSP uses in
/// signature-help parameter ranges).
fn utf16ToByte(s: []const u8, units: usize) usize {
    var u: usize = 0;
    var i: usize = 0;
    while (i < s.len and u < units) {
        const d = unicode.decode(s[i..]);
        u += if (d.cp > 0xFFFF) 2 else 1;
        i += d.len;
    }
    return i;
}

const ParamRange = struct { start: usize, end: usize };

/// Byte range of the active parameter within a signature's label, or {0,0} if
/// there is none. Handles both label forms LSP allows: a literal substring of
/// the label, and a [startUtf16, endUtf16) pair of offsets into it.
fn paramRange(sig: std.json.Value, label: []const u8, top_active_param: ?i64) ParamRange {
    const none: ParamRange = .{ .start = 0, .end = 0 };
    const params = getField(sig, "parameters") orelse return none;
    if (params != .array or params.array.items.len == 0) return none;
    // A signature-level activeParameter (3.16+) overrides the top-level one.
    const ap_val = asInt(getField(sig, "activeParameter")) orelse top_active_param orelse 0;
    const ap: usize = if (ap_val >= 0) @intCast(ap_val) else 0;
    if (ap >= params.array.items.len) return none;
    const plabel = getField(params.array.items[ap], "label") orelse return none;
    switch (plabel) {
        .string => |s| if (std.mem.indexOf(u8, label, s)) |off| return .{ .start = off, .end = off + s.len },
        .array => |a| if (a.items.len >= 2 and a.items[0] == .integer and a.items[1] == .integer) {
            return .{
                .start = utf16ToByte(label, @intCast(@max(a.items[0].integer, 0))),
                .end = utf16ToByte(label, @intCast(@max(a.items[1].integer, 0))),
            };
        },
        else => {},
    }
    return none;
}

fn getField(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn asInt(v: ?std.json.Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

/// A non-negative line/character field as a u32 (0 when absent or negative).
fn u32From(v: ?std.json.Value) u32 {
    const i = asInt(v) orelse 0;
    return if (i > 0) @intCast(i) else 0;
}

/// Flatten an inlay-hint label (a string, or an array of `{value}` parts) into
/// an owned string (caller frees), or null when there is nothing to show.
fn inlayLabel(gpa: Allocator, label: ?std.json.Value) ?[]u8 {
    const l = label orelse return null;
    switch (l) {
        .string => |s| return gpa.dupe(u8, s) catch null,
        .array => |arr| {
            var buf: std.ArrayList(u8) = .empty;
            for (arr.items) |part| {
                const v = asStr(getField(part, "value")) orelse continue;
                buf.appendSlice(gpa, v) catch {
                    buf.deinit(gpa);
                    return null;
                };
            }
            return buf.toOwnedSlice(gpa) catch null;
        },
        else => return null,
    }
}

fn asStr(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn contentLength(header: []const u8) ?usize {
    const tag = "Content-Length:";
    const idx = std.mem.indexOf(u8, header, tag) orelse return null;
    var rest = header[idx + tag.len ..];
    rest = std.mem.trim(u8, rest, " \r\n\t");
    const end = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
    return std.fmt.parseInt(usize, rest[0..end], 10) catch null;
}

fn appendEscaped(list: *std.ArrayList(u8), gpa: Allocator, s: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, list);
    defer list.* = aw.toArrayList();
    try std.json.Stringify.encodeJsonStringChars(s, .{}, &aw.writer);
}

fn pollReadable(fd: posix.fd_t, timeout_ms: i32) bool {
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const n = posix.poll(&fds, timeout_ms) catch return false;
    return n > 0 and (fds[0].revents & posix.POLL.IN) != 0;
}

test "contentLength parsing" {
    try std.testing.expectEqual(@as(?usize, 42), contentLength("Content-Length: 42"));
    try std.testing.expectEqual(@as(?usize, 7), contentLength("Content-Type: x\r\nContent-Length: 7"));
    try std.testing.expectEqual(@as(?usize, null), contentLength("Nope: 1"));
}

test "json escaping" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try appendEscaped(&list, gpa, "a\"b\\c\nd");
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\nd", list.items);
}

test "utf16ToByte" {
    // ASCII: code units == bytes.
    try std.testing.expectEqual(@as(usize, 0), utf16ToByte("foo(a, b)", 0));
    try std.testing.expectEqual(@as(usize, 4), utf16ToByte("foo(a, b)", 4));
    // A 4-byte codepoint (😀) is 2 UTF-16 units but 4 bytes; "x" before it is 1/1.
    try std.testing.expectEqual(@as(usize, 1), utf16ToByte("x\u{1F600}y", 1));
    try std.testing.expectEqual(@as(usize, 5), utf16ToByte("x\u{1F600}y", 3));
    // Past the end clamps to len.
    try std.testing.expectEqual(@as(usize, 3), utf16ToByte("abc", 99));
}

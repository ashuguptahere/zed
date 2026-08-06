//! Runtime configuration from a single documented file.
//!
//! The file lives at `$XDG_CONFIG_HOME/zedit/config` (falling back to
//! `~/.config/zedit/config`) and can be overridden with `--config <path>`.
//! Format: one `key = value` per line, `#` starts a comment, blank lines and
//! unknown keys are ignored (so configs stay forward/backward compatible).
//! `zedit --init-config` writes `default_text` — the fully documented default —
//! to the standard path. Parsed once at startup; no file watching.

const std = @import("std");
const theme = @import("theme.zig");

pub const Side = enum { left, right };

/// Which set of keys the editor answers to. `vim` is modal, as zedit has
/// always been; the other two are **non-modal** — typing inserts, and the
/// commands live on Ctrl/Alt chords. `zed` is the same table as `vscode`
/// (Zed ships VS Code's bindings on Linux by design) with its own name, so a
/// user who reaches for one is not told the other.
pub const Keymap = enum { vim, vscode, zed };

pub const Settings = struct {
    /// Cells a tab character occupies (rendering only; tabs are stored verbatim).
    tab_width: usize = 4,
    /// Use Nerd Font glyphs (powerline statusline separators). Set false if
    /// your terminal font shows boxes/question marks in the statusline.
    nerd_font: bool = true,
    /// Which side the file-tree sidebar (`Space e`) opens on.
    sidebar: Side = .left,
    /// Which keys the editor answers to: the non-modal `vscode`/`zed`
    /// chords, or modal `vim`.
    keymap: Keymap = .vscode,
    /// Relative line numbers in the gutter (the cursor line stays absolute,
    /// AstroNvim's hybrid style). False shows absolute numbers everywhere.
    relative_numbers: bool = true,
    /// Files larger than this many megabytes open in large-file mode: syntax
    /// highlighting, LSP and git signs are skipped so the file opens instantly
    /// and nothing chokes on it. 0 treats every file as large.
    large_file_mb: usize = 64,
    /// Inherit the current line's indentation on `o`, `O`, Enter and `cc`
    /// (vim 'autoindent'; an auto-indent left blank is stripped on leaving).
    autoindent: bool = true,
    /// Show the title bar: open buffers as powerline tabs across the top,
    /// plus the explorer's header when the sidebar is open. Always on screen
    /// while enabled (VS Code-style, even for a single file); false removes
    /// the row and puts the filename back in the statusline.
    buffer_tabs: bool = true,
    /// Pop up completions on their own while typing, after a short pause,
    /// instead of only on `Ctrl-n` (Helix and recent Neovim both do this).
    auto_completion: bool = true,
    /// How long typing must pause before an automatic completion request, in
    /// milliseconds. Only armed while typing an identifier, so an idle editor
    /// still blocks in poll() and burns no CPU.
    completion_delay_ms: usize = 150,
    /// Complete from the words already in the open buffers when no language
    /// server answers (none installed for the filetype, or an empty result) —
    /// vim's keyword completion. False leaves completion to the server alone.
    buffer_completion: bool = true,
    /// Show each diagnostic's message inline at the end of its line (dim,
    /// severity-coloured virtual text — helix/nvim call this virtual_text).
    /// The gutter sign and the statusline message appear either way.
    inline_diagnostics: bool = true,
    /// Wrap a line too long for the window onto the next screen row instead
    /// of scrolling sideways (vim's `wrap`, on by default there too). `j`/`k`
    /// still move by buffer line, as in vim; `gj`/`gk` move by screen row.
    /// Paint the terminal's window background in the theme's colour, so the
    /// few pixels of padding outside the character grid — the strip along the
    /// bottom and right edge of most terminal windows — match the editor
    /// instead of showing through in the terminal's own colour. The original
    /// is restored on exit. Only ever applied to a terminal that answers the
    /// colour query, so one that ignores OSC 11 is never left recoloured.
    sync_background: bool = true,
    /// Relative window sizes, applied when a split has exactly this many
    /// windows — `1,2` makes the second twice the first, and being relative
    /// it holds at any terminal size. Zero-length (the default) tiles evenly.
    /// `Ctrl-w +`/`-`/`<`/`>` resize live; `:winsave` writes the result here.
    split_sizes: [8]f64 = @splat(0),
    soft_wrap: bool = true,
    /// Pin the lines that open the enclosing scopes to the top of the window
    /// while scrolling — VS Code's sticky scroll. They yield to the cursor
    /// rather than covering it, so the viewport itself never changes.
    sticky_scroll: bool = true,
    /// Repeat a wrapped line's indent in front of every continuation row, so
    /// it stays under its own first character (vim's `breakindent`). Capped at
    /// half the window so there is always room for text.
    wrap_indent: bool = true,
    /// Wrap at this column rather than at the window edge. 0 = the window
    /// edge; a value wider than the window is clamped to it.
    wrap_column: usize = 0,
    /// Keep the undo history on disk (vim's `undofile`), under
    /// `$XDG_STATE_HOME/zedit/undo`, so undo still works after reopening a
    /// file. Off by default, as in vim: the files hold your text and nothing
    /// prunes them.
    persistent_undo: bool = false,
    /// Ask the language server to format the document before every `:w`
    /// (skipped when no server is running or it cannot format). AstroNvim and
    /// Helix both format on save by default; `:format` formats on demand.
    format_on_save: bool = true,
    /// Fish-style inline suggestion on the command line: the rest of the
    /// newest matching history entry (or a command name) shown as dim ghost
    /// text after the cursor; Right/End accepts it. False turns it off.
    cmdline_suggestions: bool = true,
    /// Ask the terminal to report mouse events: the wheel, clicks that move
    /// the cursor, and drags that select. False never enables reporting, so
    /// the mouse stays entirely the terminal's — including its own click-drag
    /// selection, which any tracking mode takes over.
    mouse: bool = true,
    /// How long two clicks at the same cell may be apart and still count as a
    /// double (then triple, then quadruple) click, in milliseconds — vim's
    /// `mousetime`. The count is derived from the previous click's timestamp
    /// when the next one arrives, so no timer is ever armed.
    mousetime: usize = 500,
};

/// The live settings, read by the editor/renderer. Defaults apply when there
/// is no config file.
pub var settings: Settings = .{};

/// The documented default configuration, written by `zedit --init-config`.
pub const default_text =
    \\# zedit configuration
    \\# Location: ~/.config/zedit/config  (or $XDG_CONFIG_HOME/zedit/config)
    \\# One `key = value` per line; `#` starts a comment. Unknown keys are
    \\# ignored, so it is safe to keep settings for newer/older versions here.
    \\
    \\# Colour theme. Built-in themes:
    \\#   tokyonight   (default)
    \\#   gruvbox
    \\#   catppuccin
    \\#   nord
    \\#   onedark
    \\# Switch at runtime with `:theme <name>` or the `Space f t` picker.
    \\theme = tokyonight
    \\
    \\# How many cells a tab character occupies (1-16). Tabs are stored
    \\# verbatim in the file; this affects rendering only.
    \\tab_width = 4
    \\
    \\# Nerd Font glyphs. zedit's powerline statusline separators are private-use
    \\# glyphs that only patched "Nerd Fonts" contain. If your terminal font is
    \\# not a Nerd Font they render as boxes — set this to false for a flat
    \\# statusline that works with any font.
    \\nerd_font = true
    \\
    \\# Which side the file-tree sidebar (Space e) opens on: left or right.
    \\sidebar = left
    \\
    \\# Which keys the editor answers to.
    \\#   vscode - non-modal (the default): typing always inserts, commands
    \\#            on Ctrl chords
    \\#            (Ctrl-s save, Ctrl-p files, Ctrl-f find, Ctrl-/ comment,
    \\#            Shift+arrows select, Alt+Up/Down move a line...)
    \\#   zed    - the same table under Zed's name
    \\#   vim    - modal editing: normal / insert / visual, the full vim
    \\#            keymap this editor also implements
    \\# Non-modal means the vim commands are not reachable, and vice versa:
    \\# these are emulations, not a hybrid.
    \\keymap = vscode
    \\
    \\# Relative line numbers in the gutter (the cursor line stays absolute).
    \\# Set to false for absolute numbers everywhere.
    \\relative_numbers = true
    \\
    \\# Files larger than this many megabytes open in large-file mode:
    \\# highlighting, LSP and git signs are skipped so huge files open
    \\# instantly and nothing chokes on them.
    \\large_file_mb = 64
    \\
    \\# Inherit the current line's indentation on o / O / Enter / cc
    \\# (vim's 'autoindent'). An auto-indent left blank is stripped.
    \\autoindent = true
    \\
    \\# Show the title bar along the top: open buffers as tabs (the active one
    \\# highlighted) beside the explorer's header, VS Code-style. Set false to
    \\# remove the row; the filename then returns to the statusline.
    \\buffer_tabs = true
    \\
    \\# Pop up completions while typing (after completion_delay_ms of pause),
    \\# not just on Ctrl-n. The popup is fuzzy-matched: "mc" finds mockComplete.
    \\auto_completion = true
    \\
    \\# Pause before an automatic completion request, in milliseconds. Raise it
    \\# on a slow language server; the timer is only armed while you are typing
    \\# an identifier, so an idle editor still uses no CPU.
    \\completion_delay_ms = 150
    \\
    \\# Complete from words already in the open buffers when no language server
    \\# answers (none is installed for the filetype, or it returned nothing) —
    \\# vim's keyword completion. Set false to complete only from a server.
    \\buffer_completion = true
    \\
    \\# Show each diagnostic's message inline at the end of its line, as dim
    \\# severity-coloured text (the gutter sign and statusline message show
    \\# regardless). Set false for a quieter buffer.
    \\inline_diagnostics = true
    \\
    \\# Wrap long lines onto the next screen row instead of scrolling the view
    \\# sideways (vim's 'wrap'). j/k still step whole buffer lines; gj/gk step
    \\# screen rows. Set false to scroll horizontally instead.
    \\# Relative window sizes for a split with this many windows, e.g. "1,2"
    \\# for a third and two thirds. Empty tiles evenly. `Ctrl-w +`/`-`/`<`/`>`
    \\# resize live and `:winsave` writes the current proportions here.
    \\split_sizes =
    \\
    \\# Paint the terminal's window padding (the strip outside the character
    \\# grid, along the bottom and right edges) in the theme's background
    \\# colour. Restored on exit.
    \\sync_background = true
    \\
    \\soft_wrap = true
    \\
    \\# Pin the lines that open the enclosing scopes (the struct, the function)
    \\# to the top rows while you scroll inside them, so you can always see
    \\# what you are in the middle of. Needs a tree-sitter grammar for the
    \\# language; the pinned rows step aside when the cursor would be under
    \\# them, so nothing is ever hidden by them.
    \\sticky_scroll = true
    \\
    \\# Repeat a wrapped line's indent on its continuation rows, so a wrapped
    \\# line stays under its own first character.
    \\wrap_indent = true
    \\
    \\# Wrap at this column instead of at the window edge (0 = window edge).
    \\wrap_column = 0
    \\
    \\# Keep undo history on disk (vim's 'undofile'), under
    \\# $XDG_STATE_HOME/zedit/undo, so u still works after reopening a file.
    \\# Off by default: those files hold copies of your text, and nothing
    \\# removes them again.
    \\persistent_undo = false
    \\
    \\# Ask the language server to format the document on :w (format-on-save,
    \\# as AstroNvim and Helix do). Only applies when a server is running and
    \\# advertises formatting; :format always formats on demand.
    \\format_on_save = true
    \\
    \\# Inline suggestions on the command line (fish-style): the rest of the
    \\# newest matching history entry, or a command name, appears as dim ghost
    \\# text after the cursor; Right or End accepts it. Enter always runs only
    \\# what you typed. Set false to turn the ghost text off.
    \\cmdline_suggestions = true
    \\
    \\# Report mouse events to zedit: the wheel scrolls, a click moves the
    \\# cursor (and focuses the split it landed in), and a drag selects.
    \\# Set false to leave the mouse entirely to your terminal — including
    \\# its own click-drag selection, which any reporting mode takes over.
    \\# Shift+drag is the terminal's own selection either way.
    \\mouse = true
    \\
    \\# How long (milliseconds) two clicks at the same cell may be apart and
    \\# still count as a double click — then triple (the line), then quadruple
    \\# (one blockwise cell), as in vim's 'mousetime'. 0 turns multi-clicks off.
    \\mousetime = 500
    \\
;

/// "true"/"false" → the bool; anything else is null (setting left untouched).
fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

/// Apply `key = value` lines to the live settings. Forgiving by design:
/// malformed lines and unknown keys/values are skipped, never fatal.
pub fn apply(text: []const u8) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var line = raw;
        if (std.mem.indexOfScalar(u8, line, '#')) |c| line = line[0..c];
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t\r");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (key.len == 0 or value.len == 0) continue;

        if (std.mem.eql(u8, key, "theme")) {
            _ = theme.set(value); // unknown theme names keep the current one
        } else if (std.mem.eql(u8, key, "tab_width")) {
            const n = std.fmt.parseInt(usize, value, 10) catch continue;
            if (n >= 1 and n <= 16) settings.tab_width = n;
        } else if (std.mem.eql(u8, key, "nerd_font")) {
            if (parseBool(value)) |b| settings.nerd_font = b;
        } else if (std.mem.eql(u8, key, "keymap")) {
            if (std.meta.stringToEnum(Keymap, value)) |k| settings.keymap = k;
        } else if (std.mem.eql(u8, key, "sidebar")) {
            if (std.meta.stringToEnum(Side, value)) |s| settings.sidebar = s;
        } else if (std.mem.eql(u8, key, "relative_numbers")) {
            if (parseBool(value)) |b| settings.relative_numbers = b;
        } else if (std.mem.eql(u8, key, "large_file_mb")) {
            const n = std.fmt.parseInt(usize, value, 10) catch continue;
            settings.large_file_mb = n;
        } else if (std.mem.eql(u8, key, "autoindent")) {
            if (parseBool(value)) |b| settings.autoindent = b;
        } else if (std.mem.eql(u8, key, "buffer_tabs")) {
            if (parseBool(value)) |b| settings.buffer_tabs = b;
        } else if (std.mem.eql(u8, key, "auto_completion")) {
            if (parseBool(value)) |b| settings.auto_completion = b;
        } else if (std.mem.eql(u8, key, "completion_delay_ms")) {
            const n = std.fmt.parseInt(usize, value, 10) catch continue;
            if (n <= 10_000) settings.completion_delay_ms = n;
        } else if (std.mem.eql(u8, key, "wrap_indent")) {
            if (parseBool(value)) |b| settings.wrap_indent = b;
        } else if (std.mem.eql(u8, key, "wrap_column")) {
            if (std.fmt.parseInt(usize, value, 10)) |n| {
                if (n <= 4096) settings.wrap_column = n;
            } else |_| {}
        } else if (std.mem.eql(u8, key, "persistent_undo")) {
            if (parseBool(value)) |b| settings.persistent_undo = b;
        } else if (std.mem.eql(u8, key, "split_sizes")) {
            settings.split_sizes = parseSizes(value);
        } else if (std.mem.eql(u8, key, "sync_background")) {
            if (parseBool(value)) |b| settings.sync_background = b;
        } else if (std.mem.eql(u8, key, "sticky_scroll")) {
            if (parseBool(value)) |b| settings.sticky_scroll = b;
        } else if (std.mem.eql(u8, key, "soft_wrap")) {
            if (parseBool(value)) |b| settings.soft_wrap = b;
        } else if (std.mem.eql(u8, key, "buffer_completion")) {
            if (parseBool(value)) |b| settings.buffer_completion = b;
        } else if (std.mem.eql(u8, key, "inline_diagnostics")) {
            if (parseBool(value)) |b| settings.inline_diagnostics = b;
        } else if (std.mem.eql(u8, key, "format_on_save")) {
            if (parseBool(value)) |b| settings.format_on_save = b;
        } else if (std.mem.eql(u8, key, "cmdline_suggestions")) {
            if (parseBool(value)) |b| settings.cmdline_suggestions = b;
        } else if (std.mem.eql(u8, key, "mouse")) {
            if (parseBool(value)) |b| settings.mouse = b;
        } else if (std.mem.eql(u8, key, "mousetime")) {
            const n = std.fmt.parseInt(usize, value, 10) catch continue;
            if (n <= 10_000) settings.mousetime = n;
        }
    }
}

/// Rewrite `key`'s value in `text`, keeping every other line — comments and
/// settings alike. The config file is the user's, not ours to regenerate, so
/// a setting the editor changes is edited in place; one that is not there yet
/// is appended with a note saying who wrote it.
///
/// A commented-out line for the key (`# theme = nord`) is left alone and the
/// real setting added: uncommenting someone's line would change more than the
/// one thing they asked for.
pub fn setKeyIn(gpa: std.mem.Allocator, text: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var replaced = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const trimmed = std.mem.trimStart(u8, line, " \t");
        const is_key = !std.mem.startsWith(u8, trimmed, "#") and
            std.mem.startsWith(u8, trimmed, key) and
            std.mem.indexOfScalar(u8, trimmed, '=') != null and
            std.mem.eql(u8, std.mem.trimEnd(u8, trimmed[0..std.mem.indexOfScalar(u8, trimmed, '=').?], " \t"), key);
        if (is_key and !replaced) {
            try out.print(gpa, "{s} = {s}", .{ key, value });
            replaced = true;
        } else try out.appendSlice(gpa, line);
    }
    if (!replaced) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
        try out.print(gpa, "{s} = {s}\n", .{ key, value });
    }
    return out.toOwnedSlice(gpa);
}

/// A comma-separated list of relative window sizes. A non-positive or
/// unparseable entry voids the whole list rather than silently tiling on a
/// half-read one — a layout is all of its parts.
pub fn parseSizes(value: []const u8) [8]f64 {
    var out: [8]f64 = @splat(0);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (t.len == 0) {
            if (n == 0 and it.peek() == null) return out; // an empty setting
            return @splat(0);
        }
        if (n == out.len) return @splat(0); // more windows than we persist
        const v = std.fmt.parseFloat(f64, t) catch return @splat(0);
        if (!(v > 0) or !std.math.isFinite(v)) return @splat(0);
        out[n] = v;
        n += 1;
    }
    return out;
}

/// Persist one setting to the config file `load` used, creating it (and its
/// directory) from the annotated default text when there is none yet.
pub fn saveKey(gpa: std.mem.Allocator, io: std.Io, key: []const u8, value: []const u8) !void {
    var pbuf: [512]u8 = undefined;
    const path = loaded_from orelse (standardPath(&pbuf) orelse return error.NoConfigPath);
    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch
        try gpa.dupe(u8, default_text);
    defer gpa.free(existing);
    const updated = try setKeyIn(gpa, existing, key, value);
    defer gpa.free(updated);
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = updated });
}

/// An XDG base-directory path, built into `buf`: `$env_var/zedit/leaf`, or
/// `$HOME/home_fallback/zedit/leaf` when the variable is unset or empty. Null
/// when neither env var exists. (libc getenv — the editor links libc for
/// tree-sitter anyway.) Shared by the config, recent-list and undo paths.
pub fn xdgPath(buf: []u8, env_var: [:0]const u8, home_fallback: []const u8, leaf: []const u8) ?[]const u8 {
    if (std.c.getenv(env_var)) |xdg_z| {
        const xdg = std.mem.sliceTo(xdg_z, 0);
        if (xdg.len > 0) return std.fmt.bufPrint(buf, "{s}/zedit/{s}", .{ xdg, leaf }) catch null;
    }
    const home_z = std.c.getenv("HOME") orelse return null;
    const home = std.mem.sliceTo(home_z, 0);
    return std.fmt.bufPrint(buf, "{s}/{s}/zedit/{s}", .{ home, home_fallback, leaf }) catch null;
}

/// The standard config path: $XDG_CONFIG_HOME/zedit/config or
/// ~/.config/zedit/config.
fn standardPath(buf: []u8) ?[]const u8 {
    return xdgPath(buf, "XDG_CONFIG_HOME", ".config", "config");
}

/// Load the config file (from `override` if given, else the standard path) and
/// apply it. Best-effort: a missing or unreadable file just means defaults —
/// but the caller learns whether it loaded, so an explicit `--config` that
/// cannot be read can be reported instead of silently ignored.
/// Where `load` read from, so `saveKey` writes back to the same file — a
/// `--config` session must not silently edit the standard one instead.
var loaded_from: ?[]const u8 = null;
var loaded_buf: [512]u8 = undefined;

pub fn load(gpa: std.mem.Allocator, io: std.Io, override: ?[]const u8) bool {
    var pbuf: [512]u8 = undefined;
    const path = override orelse (standardPath(&pbuf) orelse return false);
    loaded_from = std.fmt.bufPrint(&loaded_buf, "{s}", .{path}) catch null;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        std.log.scoped(.config).info("config not loaded: {s}: {s}", .{ path, @errorName(err) });
        return false;
    };
    defer gpa.free(text);
    apply(text);
    std.log.scoped(.config).info("config loaded: {s}", .{path});
    return true;
}

/// The per-project config: a `.zedit` file at or above the working
/// directory, applied *over* whatever the user's own config said. nvim's
/// `'exrc'` and Focus's project config, which is two independent votes for
/// the idea.
///
/// **It is safe to apply without asking, and that is the whole difference
/// from `'exrc'`.** nvim's is Lua — a file from a cloned repository running as
/// you — which is why it ships off and grew a trust prompt. zedit's config is
/// inert data: `key = value`, no setting names a program to run, unknown keys
/// are ignored and every value is range-checked by `apply`. The worst a
/// hostile `.zedit` can do is make the editor look wrong. **Anything added to
/// `Settings` that names a command must not be readable from here** — that is
/// the line this rests on.
///
/// The search stops at the first `.zedit`, at a `.git` directory (the edge of
/// the project — so a stray `.zedit` in a home directory never leaks into an
/// unrelated repository), or at the filesystem root. `loaded_from` is left
/// alone: `:theme` writes the choice to the *user's* config, never into a
/// file that belongs to the project.
pub fn loadProject(gpa: std.mem.Allocator, io: std.Io, buf: []u8) ?[]const u8 {
    const cwd = std.process.currentPathAlloc(io, gpa) catch return null;
    defer gpa.free(cwd);
    var dir: []const u8 = cwd;
    while (true) {
        const path = std.fmt.bufPrint(buf, "{s}/.zedit", .{dir}) catch return null;
        if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20))) |text| {
            defer gpa.free(text);
            apply(text);
            std.log.scoped(.config).info("project config loaded: {s}", .{path});
            return path;
        } else |_| {}
        // A repository root is where a project ends.
        var gbuf: [512]u8 = undefined;
        const git = std.fmt.bufPrint(&gbuf, "{s}/.git", .{dir}) catch return null;
        if (std.Io.Dir.cwd().access(io, git, .{})) |_| return null else |_| {}
        const slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse return null;
        if (slash == 0) return null; // reached "/"
        dir = dir[0..slash];
    }
}

/// Write the documented default config to the standard path (creating the
/// directory), refusing to overwrite an existing file. Returns the path.
pub fn writeDefault(io: std.Io, buf: []u8) ![]const u8 {
    const path = standardPath(buf) orelse return error.NoHome;
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| return error.PathAlreadyExists else |_| {}
    const dir_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.NoHome;
    std.Io.Dir.cwd().createDirPath(io, path[0..dir_end]) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = default_text });
    return path;
}

/// Overwrite the config with the documented default, keeping whatever was
/// there as `config.bak` — a reset the user asked for should still not be the
/// moment their settings vanish. Returns the path written.
pub fn resetDefault(io: std.Io, buf: []u8) ![]const u8 {
    const path = standardPath(buf) orelse return error.NoHome;
    const dir_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.NoHome;
    std.Io.Dir.cwd().createDirPath(io, path[0..dir_end]) catch {};
    // Only back up a file that is actually there, and only over the one
    // backup — a second reset must not lose the *original* settings.
    var bak_buf: [576]u8 = undefined;
    if (std.fmt.bufPrint(&bak_buf, "{s}.bak", .{path})) |bak| {
        if (std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), bak, io)) |_| {} else |_| {}
    } else |_| {}
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = default_text });
    return path;
}

test "apply parses keys, comments, junk" {
    settings = .{};
    apply(
        \\# comment
        \\tab_width = 8
        \\nerd_font = false   # trailing comment
        \\not_a_setting = 42
        \\garbage line without equals
        \\tab_width = 99
    );
    try std.testing.expectEqual(@as(usize, 8), settings.tab_width); // 99 out of range, kept 8
    try std.testing.expectEqual(false, settings.nerd_font);
    settings = .{};
}

test "every setting is documented and parsed" {
    // A setting that reaches `Settings` but not the parser silently ignores
    // what the user wrote; one that is in neither the parser nor the annotated
    // default is undiscoverable. Walking the struct at comptime makes both
    // impossible to forget when the next setting is added, which a written rule
    // cannot.
    inline for (@typeInfo(Settings).@"struct".fields) |f| {
        settings = .{};
        var found = false;
        var lines = std.mem.splitScalar(u8, default_text, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t");
            if (std.mem.startsWith(u8, t, f.name) and std.mem.indexOfScalar(u8, t, '=') != null) found = true;
        }
        if (!found) {
            std.debug.print("setting '{s}' is missing from the default config text\n", .{f.name});
            return error.SettingNotDocumented;
        }
        // And read back: feed a value that differs from the default and check
        // it lands.
        const dflt = @as(*const f.type, @ptrCast(@alignCast(f.default_value_ptr.?))).*;
        const want: []const u8 = switch (@typeInfo(f.type)) {
            .bool => if (dflt) "false" else "true",
            .int => "7",
            // Any value that is not the default, whatever the enum is —
            // this used to assume `Side` was the only one, and said so by
            // failing to compile the moment a second appeared.
            .@"enum" => |e| lbl: {
                inline for (e.fields) |ef| {
                    if (@as(f.type, @enumFromInt(ef.value)) != dflt) break :lbl @as([]const u8, ef.name);
                }
                continue;
            },
            else => continue,
        };
        var buf: [128]u8 = undefined;
        apply(std.fmt.bufPrint(&buf, "{s} = {s}", .{ f.name, want }) catch unreachable);
        if (@field(settings, f.name) == dflt) {
            std.debug.print("setting '{s}' is not read by the config parser\n", .{f.name});
            return error.SettingNotParsed;
        }
    }
    settings = .{};
}

test "default config text applies cleanly to defaults" {
    settings = .{};
    apply(default_text);
    try std.testing.expectEqual(@as(usize, 4), settings.tab_width);
    try std.testing.expectEqual(true, settings.nerd_font);
}

const testing = std.testing;

fn expectSet(text: []const u8, key: []const u8, value: []const u8, want: []const u8) !void {
    const got = try setKeyIn(testing.allocator, text, key, value);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "setting an existing key rewrites just that line" {
    try expectSet("theme = nord\ntab_width = 4\n", "theme", "gruvbox", "theme = gruvbox\ntab_width = 4\n");
}

test "comments and other settings survive untouched" {
    try expectSet(
        "# my config\n\ntheme = nord   # the old one\n# trailing note\nmouse = false\n",
        "theme",
        "onedark",
        "# my config\n\ntheme = onedark\n# trailing note\nmouse = false\n",
    );
}

test "a missing key is appended" {
    try expectSet("tab_width = 2\n", "theme", "nord", "tab_width = 2\ntheme = nord\n");
}

test "appending to a file with no trailing newline still starts a line" {
    try expectSet("tab_width = 2", "theme", "nord", "tab_width = 2\ntheme = nord\n");
}

test "an empty file just gets the setting" {
    try expectSet("", "theme", "nord", "theme = nord\n");
}

test "a commented-out key is left alone and the setting added" {
    // Uncommenting someone's line would change more than the one thing asked.
    try expectSet("# theme = nord\n", "theme", "gruvbox", "# theme = nord\ntheme = gruvbox\n");
}

test "a key that is a prefix of another is not mistaken for it" {
    try expectSet("wrap_column = 80\nwrap = true\n", "wrap", "false", "wrap_column = 80\nwrap = false\n");
}

test "indented settings are recognised and normalised" {
    try expectSet("   theme = nord\n", "theme", "nord2", "theme = nord2\n");
}

test "only the first occurrence is rewritten" {
    try expectSet("theme = a\ntheme = b\n", "theme", "c", "theme = c\ntheme = b\n");
}

test "split sizes parse into relative weights" {
    settings = .{};
    apply("split_sizes = 1,2");
    try testing.expectEqual(@as(f64, 1), settings.split_sizes[0]);
    try testing.expectEqual(@as(f64, 2), settings.split_sizes[1]);
    try testing.expectEqual(@as(f64, 0), settings.split_sizes[2]); // the list ends
    settings = .{};
    apply("split_sizes = 0.25 , 0.75");
    try testing.expectEqual(@as(f64, 0.25), settings.split_sizes[0]);
    try testing.expectEqual(@as(f64, 0.75), settings.split_sizes[1]);
    settings = .{};
}

test "a broken size list is dropped whole rather than half-applied" {
    // Tiling on the readable prefix would put the windows somewhere the user
    // never asked for; even tiling is the honest answer.
    for ([_][]const u8{
        "split_sizes = 1,x",   // not a number
        "split_sizes = 1,0",   // a window with no width
        "split_sizes = 1,-2",  // negative
        "split_sizes = 1,,2",  // a hole in the middle
        "split_sizes = 1,2,3,4,5,6,7,8,9", // more than we keep
    }) |text| {
        settings = .{};
        apply(text);
        try testing.expectEqual(@as(f64, 0), settings.split_sizes[0]);
    }
    settings = .{};
}

test "an empty split_sizes is simply no layout" {
    settings = .{};
    apply("split_sizes =");
    try testing.expectEqual(@as(f64, 0), settings.split_sizes[0]);
    settings = .{};
}

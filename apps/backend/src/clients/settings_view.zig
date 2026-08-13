/// In-TUI settings overlay — reveals ALL config sections with sub-menus,
/// current values, help text, and inline editing. Writes via config/set RPC.
///
/// Opened by the registry-backed `settings` command (slash syntax remains a
/// compatibility alias). Renders as a full-screen overlay replacing the
/// normal transcript+footer when active. Navigation:
///   Left/Right or Tab — switch section
///   Up/Down           — navigate entries within section
///   Enter             — edit entry (or toggle for bools)
///   Enter in edit     — save via config/set
///   Esc               — cancel edit, or close panel
///
/// Config sections (10): runtime, provider, agent_routes, agents, context,
/// prompts, draft, buffer, memory, environment.
const std = @import("std");
const VAR1 = @import("VAR1");
const config_file = VAR1.core.config_file;
const protocol = VAR1.core.protocol_types;

pub const section_names = [_][]const u8{
    "runtime",
    "provider",
    "agent_routes",
    "agents",
    "context",
    "prompts",
    "draft",
    "buffer",
    "memory",
    "environment",
};

pub const SettingsState = struct {
    allocator: std.mem.Allocator,
    open: bool = false,
    section_cursor: usize = 0,
    entry_cursor: usize = 0,
    editing: bool = false,
    edit_buffer: std.ArrayList(u8) = .{},
    workspace_root: []const u8,
    /// Loaded config entries for the current section: [key, value_string, help_text]
    entries: std.ArrayList(ConfigEntry) = .{},
    status_message: ?[]u8 = null,

    pub const ConfigEntry = struct {
        key: []u8,
        value_text: []u8,
        help_text: []u8,
        is_bool: bool = false,
        is_string: bool = false,
        is_log_level: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, workspace_root: []const u8) SettingsState {
        return .{
            .allocator = allocator,
            .workspace_root = workspace_root,
        };
    }

    pub fn deinit(self: *SettingsState) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value_text);
            self.allocator.free(entry.help_text);
        }
        self.entries.deinit(self.allocator);
        self.edit_buffer.deinit(self.allocator);
        if (self.status_message) |msg| self.allocator.free(msg);
    }

    /// Replace the operator-facing status line without leaking the previous
    /// message. The settings surface stays usable when the persisted config
    /// is missing or invalid; callers can report that state here instead of
    /// failing back into the chat composer.
    pub fn setStatusMessage(self: *SettingsState, message: []const u8) !void {
        if (self.status_message) |old| self.allocator.free(old);
        self.status_message = try self.allocator.dupe(u8, message);
    }

    /// Load the config entries for the current section from disk.
    pub fn loadSection(self: *SettingsState) !void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value_text);
            self.allocator.free(entry.help_text);
        }
        self.entries.clearRetainingCapacity();

        const section_name = section_names[self.section_cursor];
        // A damaged or not-yet-created workspace config must not make the
        // settings command disappear. Use the compiled defaults as the
        // visible projection and leave a short recovery hint in the footer.
        var parsed = config_file.readValidatedDocument(self.allocator, self.workspace_root) catch null;
        defer if (parsed) |*document| document.deinit();

        var defaults = std.json.parseFromSlice(std.json.Value, self.allocator, config_file.default_document, .{}) catch return;
        defer defaults.deinit();

        const default_root = defaults.value.object;
        const active_section = blk: {
            if (parsed) |document| {
                const root = document.value.object;
                if (root.get(section_name)) |section| {
                    if (section == .object) break :blk section.object;
                }
            }
            break :blk null;
        };
        const default_section = blk: {
            if (default_root.get(section_name)) |section| {
                if (section == .object) break :blk section.object;
            }
            break :blk null;
        } orelse return;

        // Get the _help objects for this section if present. Older config
        // files can contain a newer value without its newer help metadata;
        // use the canonical template as the visible fallback.
        const help_obj = if (active_section) |section| section.get("_help") else null;
        const default_help_obj = default_section.get("_help");

        // Iterate the section's keys (excluding _help).
        if (active_section) |section| {
            var iter = section.iterator();
            while (iter.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "_help")) continue;
                try self.appendConfigEntry(entry.key_ptr.*, entry.value_ptr.*, helpForKey(help_obj, default_help_obj, entry.key_ptr.*));
            }
        }

        // Keep older valid config files backward-compatible without silently
        // rewriting them. Missing keys remain typed defaults until the
        // operator saves them through config/set.
        var default_iter = default_section.iterator();
        while (default_iter.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "_help")) continue;
            if (active_section) |section| {
                if (section.get(entry.key_ptr.*) != null) continue;
            }
            try self.appendConfigEntry(entry.key_ptr.*, entry.value_ptr.*, default_help_obj);
        }
        self.entry_cursor = 0;
        if (parsed == null) try self.setStatusMessage("Using defaults: workspace config is unavailable");
    }

    fn helpForKey(primary: ?std.json.Value, fallback: ?std.json.Value, key: []const u8) ?std.json.Value {
        if (primary) |help| {
            if (help == .object and help.object.get(key) != null) return help;
        }
        return fallback;
    }

    fn appendConfigEntry(
        self: *SettingsState,
        key_text: []const u8,
        value: std.json.Value,
        help_obj: ?std.json.Value,
    ) !void {
        const key = try self.allocator.dupe(u8, key_text);
        errdefer self.allocator.free(key);
        const value_text = try valueToString(self.allocator, value);
        errdefer self.allocator.free(value_text);
        const help_text = blk: {
            if (help_obj) |help| {
                if (help == .object) {
                    if (help.object.get(key_text)) |help_value| {
                        if (help_value == .string) break :blk try self.allocator.dupe(u8, help_value.string);
                    }
                }
            }
            break :blk try self.allocator.dupe(u8, "");
        };
        try self.entries.append(self.allocator, .{
            .key = key,
            .value_text = value_text,
            .help_text = help_text,
            .is_bool = value == .bool,
            .is_string = value == .string,
            .is_log_level = std.mem.eql(u8, key_text, "log_level"),
        });
    }

    /// Save the currently-edited entry via config/set RPC.
    pub fn saveCurrentEntry(self: *SettingsState, rpc_client: anytype) !void {
        if (self.entry_cursor >= self.entries.items.len) return;
        const entry = self.entries.items[self.entry_cursor];
        const section_name = section_names[self.section_cursor];

        const encoded_value = if (entry.is_string)
            try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(self.edit_buffer.items, .{})})
        else
            try self.allocator.dupe(u8, self.edit_buffer.items);
        defer self.allocator.free(encoded_value);

        // Build config/set params. String values must remain JSON strings;
        // older settings editing passed bare text and could reject the write.
        const params = try std.fmt.allocPrint(self.allocator, "{{\"section\":\"{s}\",\"key\":\"{s}\",\"value\":{s}}}", .{
            section_name,
            entry.key,
            encoded_value,
        });
        defer self.allocator.free(params);

        const result = rpc_client.call(protocol.methods.config_set, params) catch |err| {
            if (self.status_message) |msg| self.allocator.free(msg);
            self.status_message = try self.allocator.dupe(u8, switch (err) {
                error.RpcTimeout => "Error: config/set timed out",
                else => "Error: config/set RPC failed",
            });
            return;
        };
        defer result.deinit(self.allocator);

        if (self.status_message) |msg| self.allocator.free(msg);
        if (result.error_json != null) {
            self.status_message = try self.allocator.dupe(u8, "Error: config/set rejected");
            return;
        }
        self.status_message = try std.fmt.allocPrint(self.allocator, "Saved {s}.{s} = {s} (applies on next turn)", .{
            section_name,
            entry.key,
            self.edit_buffer.items,
        });
    }

    /// Handle a key press. Returns true if the key was consumed.
    pub fn handleKey(self: *SettingsState, key_event: anytype, rpc_client: anytype) !bool {
        const key = key_event;
        // Esc — cancel edit or close panel.
        if (key.matches(tui.Key.escape, .{})) {
            if (self.editing) {
                self.editing = false;
                self.edit_buffer.clearRetainingCapacity();
            } else {
                self.open = false;
            }
            return true;
        }
        // If editing, route text input to the edit buffer.
        if (self.editing) {
            if (key.matches(tui.Key.enter, .{})) {
                try self.saveCurrentEntry(rpc_client);
                self.editing = false;
                self.edit_buffer.clearRetainingCapacity();
                try self.loadSection();
                return true;
            }
            // Accept printable characters into the edit buffer.
            return false; // Let the TUI's text input handler handle char input.
        }
        // Section navigation.
        if (key.matches(tui.Key.left, .{}) or key.matches(tui.Key.tab, .{ .shift = true })) {
            if (self.section_cursor > 0) {
                self.section_cursor -= 1;
                try self.loadSection();
            }
            return true;
        }
        if (key.matches(tui.Key.right, .{}) or key.matches(tui.Key.tab, .{})) {
            if (self.section_cursor < section_names.len - 1) {
                self.section_cursor += 1;
                try self.loadSection();
            }
            return true;
        }
        // Entry navigation.
        if (key.matches(tui.Key.up, .{})) {
            if (self.entry_cursor > 0) self.entry_cursor -= 1;
            return true;
        }
        if (key.matches(tui.Key.down, .{})) {
            if (self.entry_cursor < self.entries.items.len -| 1) self.entry_cursor += 1;
            return true;
        }
        // Enter — start editing or toggle bool.
        if (key.matches(tui.Key.enter, .{})) {
            if (self.entry_cursor < self.entries.items.len) {
                const entry = self.entries.items[self.entry_cursor];
                if (entry.is_bool) {
                    // Toggle immediately.
                    const new_val = !std.mem.eql(u8, entry.value_text, "true");
                    self.edit_buffer.clearRetainingCapacity();
                    try self.edit_buffer.appendSlice(self.allocator, if (new_val) "true" else "false");
                    try self.saveCurrentEntry(rpc_client);
                    self.edit_buffer.clearRetainingCapacity();
                    try self.loadSection();
                } else if (entry.is_log_level) {
                    self.edit_buffer.clearRetainingCapacity();
                    try self.edit_buffer.appendSlice(self.allocator, nextLogLevel(entry.value_text));
                    try self.saveCurrentEntry(rpc_client);
                    self.edit_buffer.clearRetainingCapacity();
                    try self.loadSection();
                } else {
                    self.editing = true;
                    self.edit_buffer.clearRetainingCapacity();
                    try self.edit_buffer.appendSlice(self.allocator, entry.value_text);
                }
            }
            return true;
        }
        return false;
    }
};

const tui = @import("tui");

/// Render the settings overlay to the root window.
pub fn drawSettings(win: tui.Window, state: *SettingsState) void {
    win.fill(.{ .style = .{ .bg = Color.bg } });

    // Header.
    _ = win.print(
        &.{
            .{ .text = " Settings — ", .style = .{ .bold = true, .bg = Color.bg, .fg = Color.accent } },
            .{ .text = section_names[state.section_cursor], .style = .{ .bold = true, .bg = Color.bg, .fg = Color.fg } },
            .{ .text = "  (Esc to close)", .style = .{ .bg = Color.bg, .fg = Color.dim } },
        },
        .{ .row_offset = 0 },
    );

    // Section tabs.
    var col: usize = 2;
    for (section_names, 0..) |name, i| {
        const is_active = i == state.section_cursor;
        const style: tui.Cell.Style = if (is_active)
            .{ .bold = true, .bg = Color.bg, .fg = Color.accent }
        else
            .{ .bg = Color.bg, .fg = Color.dim };

        _ = win.print(
            &.{.{ .text = name, .style = style }},
            .{ .col_offset = @intCast(col), .row_offset = 1 },
        );
        col += name.len + 2;
    }

    // Separator line.
    _ = win.print(
        &.{.{ .text = "─" ** 80, .style = .{ .bg = Color.bg, .fg = Color.dim } }},
        .{ .row_offset = 2 },
    );

    // Entries. Reserve the final two rows for status and navigation help,
    // and stop by row rather than by entry count because each help line also
    // consumes a terminal row.
    var row: usize = 3;
    const content_limit: usize = @as(usize, win.height -| 3);
    var entry_index: usize = 0;
    while (entry_index < state.entries.items.len and row < content_limit) : (entry_index += 1) {
        const entry = state.entries.items[entry_index];
        const i = entry_index;
        const is_selected = i == state.entry_cursor;
        const is_editing = is_selected and state.editing;
        const key_style: tui.Cell.Style = if (is_selected)
            .{ .bold = true, .bg = Color.bg, .fg = Color.accent }
        else
            .{ .bg = Color.bg, .fg = Color.fg };

        const value_display = if (is_editing) state.edit_buffer.items else entry.value_text;
        const value_style: tui.Cell.Style = if (is_editing)
            .{ .bg = Color.bg, .fg = Color.warning }
        else if (is_selected)
            .{ .bold = true, .bg = Color.bg, .fg = Color.accent }
        else
            .{ .bg = Color.bg, .fg = Color.dim };

        // Key column (left).
        _ = win.print(
            &.{.{ .text = entry.key, .style = key_style }},
            .{ .col_offset = 2, .row_offset = @intCast(row), .wrap = .none },
        );
        // Value column (right, padded).
        const value_col: usize = 28;
        _ = win.print(
            &.{.{ .text = value_display, .style = value_style }},
            .{ .col_offset = @intCast(value_col), .row_offset = @intCast(row), .wrap = .none },
        );
        row += 1;

        // Help text (one line below, indented and dimmed).
        if (entry.help_text.len > 0 and row < content_limit) {
            const help_width = @as(usize, win.width) -| 6;
            const help_truncated = if (entry.help_text.len > help_width) entry.help_text[0..help_width] else entry.help_text;
            _ = win.print(
                &.{.{ .text = help_truncated, .style = .{ .bg = Color.bg, .fg = Color.dim } }},
                .{ .col_offset = 4, .row_offset = @intCast(row), .wrap = .none },
            );
            row += 1;
        }
    }

    // Status message (if any).
    if (state.status_message) |msg| {
        const status_row = win.height -| 2;
        _ = win.print(
            &.{.{ .text = msg, .style = .{ .bg = Color.bg, .fg = Color.success } }},
            .{ .col_offset = 2, .row_offset = status_row },
        );
    }

    // Footer help.
    const footer_row = win.height -| 1;
    _ = win.print(
        &.{
            .{ .text = " ←/→ section  ↑/↓ entry  Enter edit/toggle  Esc close", .style = .{ .bg = Color.bg, .fg = Color.dim } },
        },
        .{ .col_offset = 2, .row_offset = footer_row },
    );
}

fn nextLogLevel(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "silent")) return "normal";
    if (std.mem.eql(u8, value, "normal")) return "full";
    return "silent";
}

const Color = struct {
    const bg = tui.Cell.Color.rgbFromUint(0x08110f);
    const fg = tui.Cell.Color.rgbFromUint(0x8ce6c8);
    const accent = tui.Cell.Color.rgbFromUint(0x5ad4b8);
    const dim = tui.Cell.Color.rgbFromUint(0x4a6a5c);
    const warning = tui.Cell.Color.rgbFromUint(0xffd700);
    const success = tui.Cell.Color.rgbFromUint(0x69f0ae);
};

/// Convert a JSON value to a display string.
fn valueToString(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return switch (value) {
        .string => |s| allocator.dupe(u8, s),
        .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}),
        .bool => |b| allocator.dupe(u8, if (b) "true" else "false"),
        .null => allocator.dupe(u8, "(disabled)"),
        .object => allocator.dupe(u8, "{...}"),
        .array => allocator.dupe(u8, "[...]"),
        .number_string => |s| allocator.dupe(u8, s),
    };
}

// Tests

test "SettingsState init and deinit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);

    var state = SettingsState.init(std.testing.allocator, workspace);
    defer state.deinit();
    try std.testing.expect(!state.open);
}

test "settings falls back to defaults when workspace config is unavailable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);
    const config_path = try config_file.ensure(std.testing.allocator, workspace);
    defer std.testing.allocator.free(config_path);
    try VAR1.shared.fsutil.writeText(config_path, "{broken\n");

    var state = SettingsState.init(std.testing.allocator, workspace);
    defer state.deinit();
    try state.loadSection();

    try std.testing.expect(state.entries.items.len > 0);
    try std.testing.expectEqualStrings("Using defaults: workspace config is unavailable", state.status_message.?);
}

test "section_names has 10 entries" {
    try std.testing.expectEqual(@as(usize, 10), section_names.len);
    try std.testing.expectEqualStrings("runtime", section_names[0]);
    try std.testing.expectEqualStrings("environment", section_names[9]);
}

test "valueToString converts types" {
    const allocator = std.testing.allocator;
    const s = try valueToString(allocator, .{ .string = "hello" });
    defer allocator.free(s);
    try std.testing.expectEqualStrings("hello", s);

    const b = try valueToString(allocator, .{ .bool = true });
    defer allocator.free(b);
    try std.testing.expectEqualStrings("true", b);

    const n = try valueToString(allocator, .{ .integer = 42 });
    defer allocator.free(n);
    try std.testing.expectEqualStrings("42", n);

    const null_val = try valueToString(allocator, .null);
    defer allocator.free(null_val);
    try std.testing.expectEqualStrings("(disabled)", null_val);
}

test "settings exposes default keys omitted by an older config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);

    const config_path = try config_file.ensure(std.testing.allocator, workspace);
    defer std.testing.allocator.free(config_path);
    try VAR1.shared.fsutil.writeText(config_path, "{\"version\":1,\"runtime\":{\"max_steps\":10}}\n");

    var state = SettingsState.init(std.testing.allocator, workspace);
    defer state.deinit();
    try state.loadSection();

    var found = false;
    for (state.entries.items) |entry| {
        if (std.mem.eql(u8, entry.key, "full_access_mode")) {
            found = true;
            try std.testing.expectEqualStrings("false", entry.value_text);
            try std.testing.expect(entry.is_bool);
        }
    }
    var log_level_found = false;
    for (state.entries.items) |entry| {
        if (std.mem.eql(u8, entry.key, "log_level")) {
            log_level_found = true;
            try std.testing.expectEqualStrings("silent", entry.value_text);
            try std.testing.expect(entry.is_string);
            try std.testing.expect(entry.is_log_level);
        }
    }
    try std.testing.expect(found);
    try std.testing.expect(log_level_found);
}

test "log level setting cycles in the compact order" {
    try std.testing.expectEqualStrings("normal", nextLogLevel("silent"));
    try std.testing.expectEqualStrings("full", nextLogLevel("normal"));
    try std.testing.expectEqualStrings("silent", nextLogLevel("full"));
    try std.testing.expectEqualStrings("silent", nextLogLevel("unknown"));
}

test "settings serializes log level as a JSON string" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    var state = SettingsState.init(allocator, workspace);
    defer state.deinit();
    state.open = true;
    try state.loadSection();
    try selectRuntimeEntry(&state, "log_level");

    var client = SettingsSuccessClient{};
    try std.testing.expect(try state.handleKey(tui.Key{ .codepoint = tui.Key.enter }, &client));
    try std.testing.expectEqual(@as(usize, 1), client.calls);
    try std.testing.expect(client.saw_json_string_value);
}

test "settings accepts newer values with older help metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);

    const config_path = try config_file.ensure(std.testing.allocator, workspace);
    defer std.testing.allocator.free(config_path);
    try VAR1.shared.fsutil.writeText(config_path,
        \\{"version":1,"runtime":{"_help":{"max_steps":"Maximum steps."},"max_steps":10,"full_access_mode":true}}
    );

    var state = SettingsState.init(std.testing.allocator, workspace);
    defer state.deinit();
    try state.loadSection();

    var found = false;
    for (state.entries.items) |entry| {
        if (std.mem.eql(u8, entry.key, "full_access_mode")) {
            found = true;
            try std.testing.expectEqualStrings("true", entry.value_text);
            try std.testing.expect(std.mem.indexOf(u8, entry.help_text, "other directories") != null);
        }
    }
    try std.testing.expect(found);
}

const SettingsTestResult = struct {
    error_json: ?[]const u8 = null,

    fn deinit(_: SettingsTestResult, _: std.mem.Allocator) void {}
};

const SettingsSuccessClient = struct {
    calls: usize = 0,
    saw_json_string_value: bool = false,

    fn call(self: *SettingsSuccessClient, method: []const u8, params: []const u8) anyerror!SettingsTestResult {
        try std.testing.expectEqualStrings(protocol.methods.config_set, method);
        try std.testing.expect(std.mem.indexOf(u8, params, "\"section\":\"runtime\"") != null);
        self.saw_json_string_value = std.mem.indexOf(u8, params, "\"value\":\"normal\"") != null;
        self.calls += 1;
        return .{};
    }
};

const SettingsTimeoutClient = struct {
    fn call(_: *SettingsTimeoutClient, _: []const u8, _: []const u8) anyerror!SettingsTestResult {
        return error.RpcTimeout;
    }
};

fn selectRuntimeBool(state: *SettingsState, key: []const u8) !void {
    for (state.entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.key, key)) {
            try std.testing.expect(entry.is_bool);
            state.entry_cursor = index;
            return;
        }
    }
    return error.TestExpectedEqual;
}

fn selectRuntimeEntry(state: *SettingsState, key: []const u8) !void {
    for (state.entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.key, key)) {
            state.entry_cursor = index;
            return;
        }
    }
    return error.TestExpectedEqual;
}

test "settings apply close and repeated reopen share one state owner" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    var state = SettingsState.init(allocator, workspace);
    defer state.deinit();
    state.open = true;
    try state.loadSection();
    try selectRuntimeBool(&state, "full_access_mode");

    var client = SettingsSuccessClient{};
    try std.testing.expect(try state.handleKey(tui.Key{ .codepoint = tui.Key.enter }, &client));
    try std.testing.expectEqual(@as(usize, 1), client.calls);
    try std.testing.expect(std.mem.startsWith(u8, state.status_message.?, "Saved runtime.full_access_mode"));

    try std.testing.expect(try state.handleKey(tui.Key{ .codepoint = tui.Key.escape }, &client));
    try std.testing.expect(!state.open);

    state.open = true;
    try state.loadSection();
    try std.testing.expect(state.entries.items.len > 0);
    try std.testing.expect(try state.handleKey(tui.Key{ .codepoint = tui.Key.escape }, &client));
    try std.testing.expect(!state.open);
}

test "settings shift tab navigates to the previous section" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    var state = SettingsState.init(allocator, workspace);
    defer state.deinit();
    state.open = true;
    state.section_cursor = 1;
    try state.loadSection();

    var client = SettingsSuccessClient{};
    const shift_tab = tui.Key{ .codepoint = tui.Key.tab, .mods = .{ .shift = true } };
    try std.testing.expect(try state.handleKey(shift_tab, &client));
    try std.testing.expectEqual(@as(usize, 0), state.section_cursor);
    try std.testing.expect(state.entries.items.len > 0);
}

test "settings tab navigates to the next section" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    var state = SettingsState.init(allocator, workspace);
    defer state.deinit();
    state.open = true;
    try state.loadSection();

    var client = SettingsSuccessClient{};
    const tab = tui.Key{ .codepoint = tui.Key.tab, .mods = .{} };
    try std.testing.expect(try state.handleKey(tab, &client));
    try std.testing.expectEqual(@as(usize, 1), state.section_cursor);
    try std.testing.expect(state.entries.items.len > 0);
}

test "settings timeout is visible and remains closable" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    var state = SettingsState.init(allocator, workspace);
    defer state.deinit();
    state.open = true;
    try state.loadSection();
    try selectRuntimeBool(&state, "full_access_mode");

    var client = SettingsTimeoutClient{};
    try std.testing.expect(try state.handleKey(tui.Key{ .codepoint = tui.Key.enter }, &client));
    try std.testing.expectEqualStrings("Error: config/set timed out", state.status_message.?);
    try std.testing.expect(try state.handleKey(tui.Key{ .codepoint = tui.Key.escape }, &client));
    try std.testing.expect(!state.open);
}

/// In-TUI settings overlay — reveals ALL config sections with sub-menus,
/// current values, help text, and inline editing. Writes via config/set RPC.
///
/// Opened by the /settings slash command. Renders as a full-screen overlay
/// replacing the normal transcript+footer when active. Navigation:
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

    /// Load the config entries for the current section from disk.
    pub fn loadSection(self: *SettingsState) !void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value_text);
            self.allocator.free(entry.help_text);
        }
        self.entries.clearRetainingCapacity();

        const section_name = section_names[self.section_cursor];
        var parsed = config_file.readValidatedDocument(self.allocator, self.workspace_root) catch return;
        defer parsed.deinit();

        const root = parsed.value.object;
        const section = root.get(section_name) orelse return;
        if (section != .object) return;

        // Get the _help object for this section if present.
        const help_obj = if (section.object.get("_help")) |h| h else null;

        // Iterate the section's keys (excluding _help).
        var iter = section.object.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "_help")) continue;

            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            const value_text = try valueToString(self.allocator, entry.value_ptr.*);
            const help_text = blk: {
                if (help_obj) |h| {
                    if (h == .object) {
                        if (h.object.get(entry.key_ptr.*)) |help_val| {
                            if (help_val == .string) break :blk try self.allocator.dupe(u8, help_val.string);
                        }
                    }
                }
                break :blk try self.allocator.dupe(u8, "");
            };
            const is_bool = entry.value_ptr.* == .bool;
            try self.entries.append(self.allocator, .{
                .key = key,
                .value_text = value_text,
                .help_text = help_text,
                .is_bool = is_bool,
            });
        }
        self.entry_cursor = 0;
    }

    /// Save the currently-edited entry via config/set RPC.
    pub fn saveCurrentEntry(self: *SettingsState, rpc_client: anytype) !void {
        if (self.entry_cursor >= self.entries.items.len) return;
        const entry = self.entries.items[self.entry_cursor];
        const section_name = section_names[self.section_cursor];

        // Build config/set params.
        const params = try std.fmt.allocPrint(self.allocator, "{{\"section\":\"{s}\",\"key\":\"{s}\",\"value\":{s}}}", .{
            section_name,
            entry.key,
            self.edit_buffer.items,
        });
        defer self.allocator.free(params);

        const result = rpc_client.call(protocol.methods.config_set, params) catch {
            if (self.status_message) |msg| self.allocator.free(msg);
            self.status_message = try self.allocator.dupe(u8, "Error: config/set RPC failed");
            return;
        };
        defer result.deinit(self.allocator);

        if (self.status_message) |msg| self.allocator.free(msg);
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
        if (key.matches(tui.Key.left, .{}) or key.matches(tui.Key.tab, .{})) {
            if (self.section_cursor > 0) {
                self.section_cursor -= 1;
                try self.loadSection();
            }
            return true;
        }
        if (key.matches(tui.Key.right, .{})) {
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

    // Entries.
    var row: usize = 3;
    const max_entries = @min(state.entries.items.len, @as(usize, win.height -| 6));
    for (state.entries.items[0..max_entries], 0..) |entry, i| {
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
            .{ .col_offset = 2, .row_offset = @intCast(row) },
        );
        // Value column (right, padded).
        const value_col: usize = 28;
        _ = win.print(
            &.{.{ .text = value_display, .style = value_style }},
            .{ .col_offset = @intCast(value_col), .row_offset = @intCast(row) },
        );
        row += 1;

        // Help text (one line below, indented and dimmed).
        if (entry.help_text.len > 0 and row < max_entries + 3 + 20) {
            const help_truncated = if (entry.help_text.len > 76) entry.help_text[0..76] else entry.help_text;
            _ = win.print(
                &.{.{ .text = help_truncated, .style = .{ .bg = Color.bg, .fg = Color.dim } }},
                .{ .col_offset = 4, .row_offset = @intCast(row) },
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

test "section_names has 10 entries" {
    try std.testing.expectEqual(@as(usize, 10), section_names.len);
    try std.testing.expectEqualStrings("runtime", section_names[0]);
    try std.testing.expectEqualStrings("memory", section_names[9]);
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

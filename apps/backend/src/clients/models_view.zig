/// Full-frame model picker overlay.
///
/// Catalogue from `models/list-all` — one flat list across all providers,
/// provider derived on commit so the operator picks a model, not a provider.
/// Follows the question_view controller discipline: Action enum, handleKey,
/// draw, frame-arena allocation.
const std = @import("std");
const VAR1 = @import("VAR1");
const tui = @import("tui");
const protocol = VAR1.core.protocol_types;

pub const Action = enum {
    consumed,
    commit,
    cancel,
};

pub const DrawStyles = struct {
    panel: tui.Cell.Style,
    title: tui.Cell.Style,
    provider_header: tui.Cell.Style,
    model_id: tui.Cell.Style,
    selected: tui.Cell.Style,
    selected_name: tui.Cell.Style,
    metadata: tui.Cell.Style,
    hint: tui.Cell.Style,
    active_marker: tui.Cell.Style,
    error_text: tui.Cell.Style,
};

/// One model row in the flat catalog. All string fields are owned by State.
const ModelEntry = struct {
    id: []u8,
    owned_by: ?[]u8,
    context_length: ?u64,
    provider_id: []u8,
    provider_base_url: []u8,
    is_active: bool,

    fn deinit(self: ModelEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.owned_by) |v| allocator.free(v);
        allocator.free(self.provider_id);
        allocator.free(self.provider_base_url);
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(ModelEntry) = .{},
    cursor: usize = 0,
    scroll: usize = 0,
    /// The active model id from the catalog (null if empty or unknown).
    active_model: []u8,
    active_provider: []u8,
    /// Error shown when discovery fails entirely (null when loaded).
    error_message: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, active_model: []u8, active_provider: []u8) State {
        return .{
            .allocator = allocator,
            .active_model = active_model,
            .active_provider = active_provider,
        };
    }

    pub fn deinit(self: *State) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.allocator.free(self.active_model);
        self.allocator.free(self.active_provider);
        if (self.error_message) |msg| self.allocator.free(msg);
    }

    /// Load the full model catalog from the RPC `models/list-all` call.
    /// Replaces any existing entries. On failure, sets error_message.
    pub fn loadFromRpc(self: *State, client: anytype) void {
        // Clear previous entries.
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.clearRetainingCapacity();
        if (self.error_message) |msg| {
            self.allocator.free(msg);
            self.error_message = null;
        }
        self.cursor = 0;
        self.scroll = 0;

        const call = client.call(protocol.methods.models_list_all, "{}") catch {
            self.error_message = std.fmt.allocPrint(self.allocator, "Failed to reach kernel for model list.", .{}) catch null;
            return;
        };
        defer call.deinit(self.allocator);

        if (call.error_json != null) {
            const err_text = call.error_json orelse "unknown error";
            self.error_message = std.fmt.allocPrint(self.allocator, "Model list error: {s}", .{err_text}) catch null;
            return;
        }

        const result_json = call.result_json orelse {
            self.error_message = std.fmt.allocPrint(self.allocator, "Model list returned empty result.", .{}) catch null;
            return;
        };

        // Parse the result.
        const parsed = std.json.parseFromSlice(
            protocol.ModelsAllListResult,
            self.allocator,
            result_json,
            .{},
        ) catch {
            self.error_message = std.fmt.allocPrint(self.allocator, "Failed to parse model list response.", .{}) catch null;
            return;
        };
        defer parsed.deinit();
        const result = parsed.value;

        // Update active model/provider from response.
        self.allocator.free(self.active_model);
        self.active_model = self.allocator.dupe(u8, result.active_model) catch "";
        self.allocator.free(self.active_provider);
        self.active_provider = self.allocator.dupe(u8, result.active_provider) catch "";

        // Flatten into entries — active provider group first (server already sorts).
        for (result.providers) |group| {
            for (group.models) |model| {
                const id = self.allocator.dupe(u8, model.id) catch continue;
                const owned_by = if (model.owned_by) |v| self.allocator.dupe(u8, v) catch null else null;
                const pid = self.allocator.dupe(u8, group.provider_id) catch {
                    self.allocator.free(id);
                    if (owned_by) |v| self.allocator.free(v);
                    continue;
                };
                const base = self.allocator.dupe(u8, group.base_url) catch {
                    self.allocator.free(id);
                    if (owned_by) |v| self.allocator.free(v);
                    self.allocator.free(pid);
                    continue;
                };
                const is_active = std.mem.eql(u8, model.id, result.active_model) and
                    std.mem.eql(u8, group.provider_id, result.active_provider);
                self.entries.append(self.allocator, .{
                    .id = id,
                    .owned_by = owned_by,
                    .context_length = model.context_length,
                    .provider_id = pid,
                    .provider_base_url = base,
                    .is_active = is_active,
                }) catch {
                    // Allocation failure mid-load: free partial state and bail.
                    // The last entry was appended successfully, but its strings
                    // are owned and will be freed on next deinit.
                    return;
                };
            }
        }
    }

    /// Returns the currently selected entry, or null if the list is empty.
    pub fn selectedEntry(self: *const State) ?ModelEntry {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[@min(self.cursor, self.entries.items.len - 1)];
    }

    /// Commit the selected model via `providers/set-model`. Returns the
    /// provider_id and model id of the committed selection (owned by caller).
    pub fn commitSelected(self: *State, client: anytype) !?struct { provider_id: []u8, model: []u8 } {
        const entry = self.selectedEntry() orelse return null;
        const allocator = self.allocator;
        const params = try std.fmt.allocPrint(allocator, "{{\"provider_id\":{f},\"model\":{f}}}", .{
            std.json.fmt(entry.provider_id, .{}),
            std.json.fmt(entry.id, .{}),
        });
        defer allocator.free(params);

        const call = client.call(protocol.methods.provider_model_set, params) catch {
            return error.RpcFailed;
        };
        defer call.deinit(allocator);

        if (call.error_json != null) return error.RpcRejected;
        const result_json = call.result_json orelse return error.RpcFailed;

        // Parse to extract active_provider from the response.
        const parsed = std.json.parseFromSlice(
            protocol.ProviderModelSetResult,
            allocator,
            result_json,
            .{},
        ) catch return error.RpcFailed;
        defer parsed.deinit();
        const result = parsed.value;

        // Update local active state from the confirmed response.
        allocator.free(self.active_model);
        self.active_model = allocator.dupe(u8, result.model) catch "";
        allocator.free(self.active_provider);
        self.active_provider = allocator.dupe(u8, result.active_provider) catch "";

        // Re-mark active flags.
        for (self.entries.items) |*e| {
            e.is_active = std.mem.eql(u8, e.id, result.model) and
                std.mem.eql(u8, e.provider_id, result.active_provider);
        }

        return .{
            .provider_id = try allocator.dupe(u8, result.active_provider),
            .model = try allocator.dupe(u8, result.model),
        };
    }

    fn clampCursor(self: *State) void {
        if (self.entries.items.len == 0) {
            self.cursor = 0;
            return;
        }
        if (self.cursor >= self.entries.items.len) {
            self.cursor = self.entries.items.len - 1;
        }
    }

    fn visibleHeight(win_height: u16) usize {
        // Reserve 3 rows for header + hint + provider header estimate.
        return if (win_height > 3) @as(usize, win_height) - 3 else 0;
    }

    pub fn handleKey(self: *State, key: tui.Key, win_height: u16) Action {
        self.clampCursor();
        const vheight = visibleHeight(win_height);

        if (key.matches(tui.Key.escape, .{})) return .cancel;
        if (key.matches('c', .{ .ctrl = true })) return .cancel;

        if (key.matches(tui.Key.up, .{})) {
            if (self.cursor > 0) {
                self.cursor -= 1;
                if (self.cursor < self.scroll) self.scroll = self.cursor;
            }
            return .consumed;
        }
        if (key.matches(tui.Key.down, .{})) {
            if (self.cursor + 1 < self.entries.items.len) {
                self.cursor += 1;
                if (vheight > 0 and self.cursor >= self.scroll + vheight) {
                    self.scroll = self.cursor - vheight + 1;
                }
            }
            return .consumed;
        }
        if (key.matches(tui.Key.page_up, .{})) {
            const jump = if (vheight > 0) vheight else 1;
            if (self.cursor > jump) {
                self.cursor -= jump;
            } else {
                self.cursor = 0;
            }
            if (self.cursor < self.scroll) self.scroll = self.cursor;
            return .consumed;
        }
        if (key.matches(tui.Key.page_down, .{})) {
            const jump = if (vheight > 0) vheight else 1;
            if (self.cursor + jump < self.entries.items.len) {
                self.cursor += jump;
            } else {
                self.cursor = self.entries.items.len -| 1;
            }
            if (vheight > 0 and self.cursor >= self.scroll + vheight) {
                self.scroll = self.cursor - vheight + 1;
            }
            return .consumed;
        }
        if (key.matches(tui.Key.home, .{})) {
            self.cursor = 0;
            self.scroll = 0;
            return .consumed;
        }
        if (key.matches(tui.Key.end, .{})) {
            if (self.entries.items.len > 0) {
                self.cursor = self.entries.items.len - 1;
                if (vheight > 0) {
                    if (self.entries.items.len > vheight) {
                        self.scroll = self.entries.items.len - vheight;
                    } else {
                        self.scroll = 0;
                    }
                }
            }
            return .consumed;
        }
        if (key.matches(tui.Key.enter, .{})) {
            if (self.entries.items.len > 0) return .commit;
            return .consumed;
        }
        return .consumed;
    }

    pub fn draw(
        self: *const State,
        win: tui.Window,
        styles: DrawStyles,
        frame_allocator: std.mem.Allocator,
    ) void {
        win.fill(.{ .style = styles.panel });
        if (win.width == 0 or win.height == 0) return;

        // Header row.
        const header = std.fmt.allocPrint(
            frame_allocator,
            " Models ({d}) · ↑↓ select · Enter switch · Esc cancel",
            .{self.entries.items.len},
        ) catch " Models";
        _ = win.print(&.{.{ .text = header, .style = styles.title }}, .{ .row_offset = 0, .wrap = .none });

        if (self.entries.items.len == 0) {
            if (self.error_message) |err| {
                _ = win.print(&.{.{ .text = err, .style = styles.error_text }}, .{
                    .row_offset = 2,
                    .col_offset = 1,
                    .wrap = .none,
                });
            } else {
                _ = win.print(&.{.{ .text = "No models discovered.", .style = styles.metadata }}, .{
                    .row_offset = 2,
                    .col_offset = 1,
                    .wrap = .none,
                });
            }
            return;
        }

        // Model list — grouped by provider. Track which provider header we
        // last rendered so we can insert a divider when the provider changes.
        var row: usize = 2;
        const clamped_cursor = @min(self.cursor, self.entries.items.len - 1);
        const vheight = visibleHeight(win.height);
        const end = @min(self.scroll + vheight, self.entries.items.len);
        var last_provider_id: []const u8 = "";
        var cursor_rendered = false;

        for (self.entries.items[self.scroll..end], 0..) |*entry, i| {
            const actual_index = self.scroll + i;
            const is_selected = actual_index == clamped_cursor;

            // Provider header when group changes.
            if (!std.mem.eql(u8, entry.provider_id, last_provider_id)) {
                if (row < win.height) {
                    const provider_label = std.fmt.allocPrint(
                        frame_allocator,
                        " {s} ({s})",
                        .{ entry.provider_id, entry.provider_base_url },
                    ) catch entry.provider_id;
                    _ = win.print(&.{.{ .text = provider_label, .style = styles.provider_header }}, .{
                        .row_offset = @intCast(row),
                        .wrap = .none,
                    });
                    row += 1;
                }
                last_provider_id = entry.provider_id;
            }

            if (row >= win.height) break;

            // Model row.
            const body_width = @max(@as(usize, 1), @as(usize, win.width) -| 4);
            const id_style = if (is_selected) styles.selected_name else styles.model_id;
            const meta_style = if (is_selected) styles.selected else styles.metadata;

            if (is_selected) cursor_rendered = true;

            // Prefix: active marker or space.
            const prefix = if (entry.is_active) "▸ " else "  ";
            // Truncate long model ids to body width.
            const display_id = if (entry.id.len > body_width) entry.id[0..body_width] else entry.id;

            // Build suffix: owned_by or context_length.
            var segments: [4]tui.Cell.Segment = undefined;
            var count: usize = 0;

            segments[count] = .{ .text = prefix, .style = if (entry.is_active) styles.active_marker else meta_style };
            count += 1;
            segments[count] = .{ .text = display_id, .style = id_style };
            count += 1;

            // Append context_length hint on the right if it fits.
            if (entry.context_length) |ctx| {
                const ctx_k = ctx / 1024;
                const ctx_label = std.fmt.allocPrint(
                    frame_allocator,
                    " {d}k",
                    .{ctx_k},
                ) catch "";
                if (ctx_label.len > 0 and display_id.len + ctx_label.len + 2 < body_width) {
                    segments[count] = .{ .text = ctx_label, .style = meta_style };
                    count += 1;
                }
            }

            _ = win.print(segments[0..count], .{
                .row_offset = @intCast(row),
                .col_offset = 0,
                .wrap = .none,
            });
            row += 1;
        }

        // Footer hint at bottom.
        if (win.height > 0) {
            const hint_text = if (cursor_rendered) blk: {
                if (self.selectedEntry()) |entry| {
                    break :blk std.fmt.allocPrint(
                        frame_allocator,
                        " {s} via {s}",
                        .{ entry.id, entry.provider_id },
                    ) catch entry.id;
                }
                break :blk "";
            } else "";
            _ = win.print(&.{.{ .text = hint_text, .style = styles.hint }}, .{
                .row_offset = @intCast(@max(@as(usize, 1), @as(usize, win.height) -| 1)),
                .col_offset = 0,
                .wrap = .none,
            });
        }
    }
};

/// In-TUI settings overlay — reveals ALL config sections with sub-menus,
/// current values, help text, and inline editing. Writes via config/set RPC.
///
/// Opened by the registry-backed `settings` command (slash syntax remains a
/// compatibility alias). Renders as a full-screen overlay replacing the
/// normal transcript+footer when active. Navigation:
///   Tab / Shift-Tab / Ctrl-Q / Ctrl-E — switch section (wraps at the ends)
///   Left/Right — switch section, or cycle the value of a constrained entry
///   Up/Down           — navigate entries within section
///   Enter             — edit entry (or toggle for bools)
///   Enter in edit     — save via config/set
///   Esc               — cancel edit, or close panel
///
/// Config sections (11): runtime, tui, provider, agent_routes, agents, context,
/// prompts, draft, buffer, memory, environment.
const std = @import("std");
const VAR1 = @import("VAR1");
const config_file = VAR1.core.config_file;
const protocol = VAR1.core.protocol_types;

pub const section_names = [_][]const u8{
    "runtime",
    "tui",
    "provider",
    "models",
    "agent_routes",
    "agents",
    "context",
    "prompts",
    "draft",
    "buffer",
    "memory",
    "environment",
};

/// A reusable "cycle instead of type" selection engine. Any constrained
/// setting (model, provider, agent, theme, log_level, status_bar_position)
/// renders its options here; Left/Right cycle, Enter locks the highlighted
/// option. This is the single mechanic replacing free-text input across
/// settings — one engine, no per-field typing.
pub const Picker = struct {
    /// Display label for each option (owned).
    labels: std.ArrayList([]u8) = .{},
    /// Optional stable value for each option, distinct from the label when
    /// the label is a human description (e.g. provider "OpenCode" → "opencode").
    values: std.ArrayList([]u8) = .{},
    cursor: usize = 0,
    active: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Picker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Picker) void {
        for (self.labels.items) |item| self.allocator.free(item);
        self.labels.deinit(self.allocator);
        for (self.values.items) |item| self.allocator.free(item);
        self.values.deinit(self.allocator);
    }

    pub fn clear(self: *Picker) void {
        for (self.labels.items) |item| self.allocator.free(item);
        self.labels.clearRetainingCapacity();
        for (self.values.items) |item| self.allocator.free(item);
        self.values.clearRetainingCapacity();
        self.cursor = 0;
        self.active = false;
    }

    pub fn add(self: *Picker, label_text: []const u8, value_text: []const u8) !void {
        try self.labels.append(self.allocator, try self.allocator.dupe(u8, label_text));
        try self.values.append(self.allocator, try self.allocator.dupe(u8, value_text));
    }

    pub fn itemCount(self: *const Picker) usize {
        return self.labels.items.len;
    }

    pub fn label(self: *const Picker) []const u8 {
        if (self.cursor >= self.labels.items.len) return "";
        return self.labels.items[self.cursor];
    }

    pub fn value(self: *const Picker) []const u8 {
        if (self.cursor >= self.values.items.len) return "";
        return self.values.items[self.cursor];
    }

    pub fn move(self: *Picker, direction: i8) void {
        const count = self.labels.items.len;
        if (count == 0) return;
        if (direction < 0) {
            self.cursor = if (self.cursor == 0) count - 1 else self.cursor - 1;
        } else {
            self.cursor = (self.cursor + 1) % count;
        }
    }

    /// Find the index of the option whose value matches `value`, or null.
    pub fn indexOfValue(self: *const Picker, needle: []const u8) ?usize {
        for (self.values.items, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, needle)) return index;
        }
        return null;
    }
};

/// Mode state for the Models tab. A layered selection: provider → model →
/// (assign to active provider or an agent). Each layer reuses the Picker
/// engine so the whole flow is cycle-to-lock, never typing.
pub const ModelsState = struct {
    mode: enum { providers, models, assign } = .providers,
    providers: Picker,
    models: Picker,
    /// Assign-target picker. Index 0 is always the active provider; indices
    /// 1..N are the agents (from `agent_ids`). Rebuilt on each assign entry.
    agents: Picker,
    /// The real agent ids from agents/list, kept separately so the assign
    /// picker can be rebuilt (active provider + agents) without losing them.
    agent_ids: std.ArrayList([]u8) = .{},
    /// Provider id the current model list was pulled from (for assignment).
    active_provider_id: []u8 = "",
    loaded_provider_id: []u8 = "",
    status_message: ?[]u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ModelsState {
        return .{
            .providers = Picker.init(allocator),
            .models = Picker.init(allocator),
            .agents = Picker.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ModelsState) void {
        self.providers.deinit();
        self.models.deinit();
        self.agents.deinit();
        for (self.agent_ids.items) |id| self.allocator.free(id);
        self.agent_ids.deinit(self.allocator);
        if (self.active_provider_id.len > 0) self.allocator.free(self.active_provider_id);
        if (self.loaded_provider_id.len > 0) self.allocator.free(self.loaded_provider_id);
        if (self.status_message) |msg| self.allocator.free(msg);
    }

    pub fn setStatus(self: *ModelsState, message: []const u8) !void {
        if (self.status_message) |msg| self.allocator.free(msg);
        self.status_message = try self.allocator.dupe(u8, message);
    }

    /// Free and clear the status line. Direct `status_message = null` would
    /// leak the previous heap message; every transition goes through here.
    pub fn clearStatus(self: *ModelsState) void {
        if (self.status_message) |msg| self.allocator.free(msg);
        self.status_message = null;
    }
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
    config_changed: bool = false,
    /// Models-tab state (providers → models → assign). Populated lazily when
    /// the models section is opened; uses the shared Picker engine.
    models_state: ?ModelsState = null,

    pub const ConfigEntry = struct {
        key: []u8,
        value_text: []u8,
        help_text: []u8,
        is_bool: bool = false,
        is_string: bool = false,
        is_log_level: bool = false,
        is_theme: bool = false,
        is_status_bar_position: bool = false,
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
        if (self.models_state) |*ms| ms.deinit();
    }

    /// Replace the operator-facing status line without leaking the previous
    /// message. The settings surface stays usable when the persisted config
    /// is missing or invalid; callers can report that state here instead of
    /// failing back into the chat composer.
    pub fn setStatusMessage(self: *SettingsState, message: []const u8) !void {
        if (self.status_message) |old| self.allocator.free(old);
        self.status_message = try self.allocator.dupe(u8, message);
    }

    pub fn takeConfigChanged(self: *SettingsState) bool {
        const changed = self.config_changed;
        self.config_changed = false;
        return changed;
    }


    /// Move to an adjacent section and load its surface through one owner.
    /// The models section is RPC-backed (`loadModels`); every other section
    /// loads its config entries. Movement wraps at both ends — an operator on
    /// "runtime" pressing previous lands on "environment" and vice versa — so
    /// horizontal navigation always produces visible movement. Consolidating
    /// this keeps keyboard paths — the generic handler and the models overlay
    /// — from diverging on what entering the models section loads.
    fn changeSection(self: *SettingsState, direction: i8, rpc_client: anytype) !bool {
        // Wrap at both boundaries: the section ring is a cycle, so the
        // operator can always move without hitting an edge.
        if (direction < 0) {
            self.section_cursor = if (self.section_cursor > 0)
                self.section_cursor - 1
            else
                section_names.len - 1;
        } else {
            self.section_cursor = (self.section_cursor + 1) % section_names.len;
        }
        // Clear the status message from the previous section so a "Saved
        // tui.theme = midnight" hint doesn't persist into the next section
        // and confuse the operator into thinking the last action there was
        // also saved.
        if (self.status_message) |msg| {
            self.allocator.free(msg);
            self.status_message = null;
        }
        if (std.mem.eql(u8, section_names[self.section_cursor], "models")) {
            try self.loadModels(rpc_client);
        } else {
            try self.loadSection();
        }
        return true;
    }

    /// Load the config entries for the current section from disk.
    pub fn loadSection(self: *SettingsState) !void {
        // Preserve the operator's position and edit state across a reload.
        // Without this, a save-triggered loadSection resets entry_cursor to
        // 0 (the operator must re-navigate after every enum cycle) and the
        // editing flag survives into a different section where Enter would
        // write the stale edit_buffer under the wrong key (data corruption).
        const saved_cursor = self.entry_cursor;
        var saved_key_buf: [128]u8 = undefined;
        const saved_key: ?[]const u8 = if (saved_cursor < self.entries.items.len)
            blk: {
                const key = self.entries.items[saved_cursor].key;
                const copy_len = @min(key.len, saved_key_buf.len);
                @memcpy(saved_key_buf[0..copy_len], key[0..copy_len]);
                break :blk saved_key_buf[0..copy_len];
            }
        else
            null;
        self.editing = false;
        self.edit_buffer.clearRetainingCapacity();


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

        // Restore cursor position: match the saved key against the new
        // entries list so the operator stays where they were after a save.
        if (saved_key) |key| {
            for (self.entries.items, 0..) |entry, index| {
                if (std.mem.eql(u8, entry.key, key)) {
                    self.entry_cursor = index;
                    break;
                }
            }
        } else {
            self.entry_cursor = @min(saved_cursor, self.entries.items.len -| 1);
        }
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
            .is_theme = std.mem.eql(u8, key_text, "theme"),
            .is_status_bar_position = std.mem.eql(u8, key_text, "status_bar_position"),
        });
    }

    /// Populate the models tab from kernel RPC surfaces: connected providers
    /// (providers/list), detected-but-unconnected natives (auth/detect), and
    /// the agent registry (agents/list) for assignment. All read-only; the
    /// operator triggers the single mutating actions (import, set-model,
    /// assign) explicitly.
    pub fn loadModels(self: *SettingsState, rpc_client: anytype) !void {
        if (self.models_state == null) self.models_state = ModelsState.init(self.allocator);
        const models = &self.models_state.?;
        models.providers.clear();
        models.models.clear();
        models.agents.clear();

        // Agents for the assignment cycler.
        {
            for (models.agent_ids.items) |id| self.allocator.free(id);
            models.agent_ids.clearRetainingCapacity();
            const call = rpc_client.call(protocol.methods.agents_list, "{}") catch null;
            if (call) |*c| {
                defer c.deinit(self.allocator);
                if (c.error_json == null) {
                    if (c.result_json) |result_json| {
                        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, result_json, .{ .ignore_unknown_fields = true }) catch null;
                        if (parsed) |*p| {
                            defer p.deinit();
                            if (p.value == .object) {
                                if (p.value.object.get("agents")) |agents_value| {
                                    if (agents_value == .array) {
                                        for (agents_value.array.items) |agent_item| {
                                            if (agent_item != .object) continue;
                                            const id = agent_item.object.get("id") orelse continue;
                                            if (id != .string) continue;
                                            try models.agent_ids.append(self.allocator, try self.allocator.dupe(u8, id.string));
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Connected providers + their current model.
        {
            const call = rpc_client.call(protocol.methods.providers_list, "{}") catch null;
            if (call) |*c| {
                defer c.deinit(self.allocator);
                if (c.error_json == null) {
                    if (c.result_json) |result_json| {
                        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, result_json, .{ .ignore_unknown_fields = true }) catch null;
                        if (parsed) |*p| {
                            defer p.deinit();
                            if (p.value == .object) {
                                if (p.value.object.get("active_provider")) |active| {
                                    if (active == .string) {
                                        if (models.active_provider_id.len > 0) self.allocator.free(models.active_provider_id);
                                        models.active_provider_id = try self.allocator.dupe(u8, active.string);
                                    }
                                }
                                if (p.value.object.get("providers")) |providers_value| {
                                    if (providers_value == .array) {
                                        for (providers_value.array.items) |provider_item| {
                                            if (provider_item != .object) continue;
                                            const provider_id = provider_item.object.get("provider_id") orelse continue;
                                            if (provider_id != .string) continue;
                                            if (provider_item.object.get("model")) |model_value| {
                                                if (model_value == .string and model_value.string.len > 0) {
                                                    const label = try std.fmt.allocPrint(self.allocator, "{s} ({s})", .{ provider_id.string, model_value.string });
                                                    defer self.allocator.free(label);
                                                    try models.providers.add(label, provider_id.string);
                                                    continue;
                                                }
                                            }
                                            try models.providers.add(provider_id.string, provider_id.string);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Detected-but-unconnected native credentials (secret-free).
        {
            const call = rpc_client.call(protocol.methods.auth_detect, "{}") catch null;
            if (call) |*c| {
                defer c.deinit(self.allocator);
                if (c.error_json == null) {
                    if (c.result_json) |result_json| {
                        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, result_json, .{ .ignore_unknown_fields = true }) catch null;
                        if (parsed) |*p| {
                            defer p.deinit();
                            if (p.value == .object) {
                                if (p.value.object.get("detected")) |detected_value| {
                                    if (detected_value == .array) {
                                        for (detected_value.array.items) |entry| {
                                            if (entry != .object) continue;
                                            const provider_id = entry.object.get("provider_id") orelse continue;
                                            const live = entry.object.get("live") orelse continue;
                                            if (provider_id != .string or live != .bool) continue;
                                            // Already connected (in providers) is
                                            // shown by the providers row above.
                                            if (models.providers.indexOfValue(provider_id.string) != null) continue;
                                            if (!live.bool) continue;
                                            const source = entry.object.get("source") orelse continue;
                                            if (source != .string) continue;
                                            const label = try std.fmt.allocPrint(self.allocator, "{s} (detected: {s}, press Enter to connect)", .{ provider_id.string, source.string });
                                            defer self.allocator.free(label);
                                            // auth/import matches PROVENANCE source names
                                            // (claude/codex/opencode), not provider ids, so
                                            // the picker value is the source name while the
                                            // label keeps the human provider id.
                                            try models.providers.add(label, source.string);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Handle a key while the models tab is active. Routes provider/model/assign
    /// picker navigation and the explicit mutations.
    pub fn handleModelsKey(self: *SettingsState, key_event: anytype, rpc_client: anytype) !bool {
        const models = &self.models_state.?;
        const key = key_event;

        // Esc walks back up the layered picker, then out of models entirely.
        if (key.matches(tui.Key.escape, .{})) {
            if (models.mode != .providers) {
                models.mode = .providers;
                models.models.clear();
                models.clearStatus();
            } else {
                self.open = false;
            }
            return true;
        }
        // Tab / Shift-Tab keep section navigation even while the models overlay
        // owns keys, so the operator can leave the tab without Esc. The same
        // section-change owner the generic handler uses loads the destination
        // surface — including models when the cursor wraps onto it.
        if (key.matches(tui.Key.tab, .{ .shift = true })) {
            _ = try self.changeSection(-1, rpc_client);
            return true;
        }
        if (key.matches(tui.Key.tab, .{})) {
            _ = try self.changeSection(1, rpc_client);
            return true;
        }

        // Dedicated section keys mirror the generic handler: Ctrl-Q previous,
        // Ctrl-E next. They always move sections so an operator on the models
        // tab is never trapped by the picker's own Left/Right value cycling.
        if (key.matches('q', .{ .ctrl = true })) {
            _ = try self.changeSection(-1, rpc_client);
            return true;
        }
        if (key.matches('e', .{ .ctrl = true })) {
            _ = try self.changeSection(1, rpc_client);
            return true;
        }

        switch (models.mode) {
            .providers => {
                if (key.matches(tui.Key.up, .{})) {
                    models.providers.move(-1);
                    return true;
                }
                if (key.matches(tui.Key.down, .{})) {
                    models.providers.move(1);
                    return true;
                }
                if (key.matches(tui.Key.left, .{})) {
                    models.providers.move(-1);
                    return true;
                }
                if (key.matches(tui.Key.right, .{})) {
                    models.providers.move(1);
                    return true;
                }
                if (key.matches(tui.Key.enter, .{})) {
                    const provider_id = models.providers.value();
                    if (provider_id.len == 0) return true;
                    // Connected providers are in providers/list; detected-only
                    // rows are marked "(detected: ...)" and import on Enter.
                    if (std.mem.indexOf(u8, models.providers.label(), "detected:") != null) {
                        try self.importDetectedSource(rpc_client, provider_id);
                        return true;
                    }
                    try self.pullModelsForProvider(rpc_client, provider_id);
                    return true;
                }
                return false;
            },
            .models => {
                if (key.matches(tui.Key.up, .{})) {
                    models.models.move(-1);
                    return true;
                }
                if (key.matches(tui.Key.down, .{})) {
                    models.models.move(1);
                    return true;
                }
                if (key.matches(tui.Key.left, .{})) {
                    models.models.move(-1);
                    return true;
                }
                if (key.matches(tui.Key.right, .{})) {
                    models.models.move(1);
                    return true;
                }
                if (key.matches(tui.Key.enter, .{})) {
                    const model = models.models.value();
                    if (model.len == 0) return true;
                    // Rebuild the assign picker: index 0 = the provider the
                    // model list was pulled from (set-model writes THAT
                    // provider's ledger record), then every agent. The label
                    // must name the provider the commit will actually write —
                    // "(active provider)" only when it really is the ledger's
                    // active provider, never as a blanket caption.
                    models.agents.clear();
                    const target_provider = models.loaded_provider_id;
                    const is_active_target = models.active_provider_id.len > 0 and
                        std.mem.eql(u8, target_provider, models.active_provider_id);
                    const provider_label = if (is_active_target)
                        try std.fmt.allocPrint(self.allocator, "{s} (active provider)", .{target_provider})
                    else
                        try std.fmt.allocPrint(self.allocator, "{s} (provider)", .{target_provider});
                    defer self.allocator.free(provider_label);
                    try models.agents.add(provider_label, target_provider);
                    for (models.agent_ids.items) |agent_id| {
                        try models.agents.add(agent_id, agent_id);
                    }
                    models.mode = .assign;
                    models.clearStatus();
                    return true;
                }
                return false;
            },
            .assign => {
                // Left/Right cycle between "active provider" and each agent.
                // The first picker entry is the active provider; the rest are
                // agents from the loaded registry.
                if (key.matches(tui.Key.left, .{})) {
                    models.agents.move(-1);
                    return true;
                }
                if (key.matches(tui.Key.right, .{})) {
                    models.agents.move(1);
                    return true;
                }
                if (key.matches(tui.Key.up, .{})) {
                    models.agents.move(-1);
                    return true;
                }
                if (key.matches(tui.Key.down, .{})) {
                    models.agents.move(1);
                    return true;
                }
                if (key.matches(tui.Key.enter, .{})) {
                    try self.commitModelAssignment(rpc_client);
                    return true;
                }
                return false;
            },
        }
    }

    fn pullModelsForProvider(self: *SettingsState, rpc_client: anytype, provider_id: []const u8) !void {
        const models = &self.models_state.?;
        models.models.clear();
        models.clearStatus();
        if (models.loaded_provider_id.len > 0) self.allocator.free(models.loaded_provider_id);
        models.loaded_provider_id = try self.allocator.dupe(u8, provider_id);

        const params = try std.fmt.allocPrint(self.allocator, "{{\"provider_id\":{f}}}", .{std.json.fmt(provider_id, .{})});
        defer self.allocator.free(params);
        const call = rpc_client.call(protocol.methods.models_list, params) catch {
            try models.setStatus("Error: models/list RPC failed");
            return;
        };
        defer call.deinit(self.allocator);
        if (call.error_json != null) {
            try models.setStatus("Error: models/list rejected");
            return;
        }
        const result_json = call.result_json orelse {
            try models.setStatus("Error: malformed models/list response");
            return;
        };
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, result_json, .{ .ignore_unknown_fields = true }) catch {
            try models.setStatus("Error: malformed models/list response");
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return;
        if (parsed.value.object.get("status")) |status| {
            if (status == .string and !std.mem.eql(u8, status.string, "ok")) {
                const message = parsed.value.object.get("error_message") orelse return;
                if (message == .string) try models.setStatus(message.string);
                return;
            }
        }
        if (parsed.value.object.get("models")) |models_value| {
            if (models_value == .array) {
                for (models_value.array.items) |model_item| {
                    if (model_item != .object) continue;
                    const id = model_item.object.get("id") orelse continue;
                    if (id != .string) continue;
                    if (model_item.object.get("context_length")) |ctx| {
                        if (ctx == .integer) {
                            const label = try std.fmt.allocPrint(self.allocator, "{s} (ctx {d})", .{ id.string, ctx.integer });
                            defer self.allocator.free(label);
                            try models.models.add(label, id.string);
                            continue;
                        }
                    }
                    try models.models.add(id.string, id.string);
                }
            }
        }
        if (models.models.itemCount() == 0) {
            try models.setStatus("No models reported by this provider");
            return;
        }
        models.mode = .models;
    }

    /// Return whether a mutation RPC's result envelope reports `status:"ok"`.
    /// Handlers return owner rejections as `{status:"rejected"/"failed",
    /// error_message}` envelopes (not transport errors), so callers must read
    /// the status. Parses the body and compares inside the tree lifetime.
    fn mutationSucceeded(self: *SettingsState, call: anytype) bool {
        if (call.error_json != null) return false;
        const result_json = call.result_json orelse return false;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, result_json, .{ .ignore_unknown_fields = true }) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const status = parsed.value.object.get("status") orelse return false;
        if (status != .string) return false;
        return std.mem.eql(u8, status.string, "ok");
    }

    fn importDetectedSource(self: *SettingsState, rpc_client: anytype, provider_id: []const u8) !void {
        const models = &self.models_state.?;
        const params = try std.fmt.allocPrint(self.allocator, "{{\"sources\":[{f}]}}", .{std.json.fmt(provider_id, .{})});
        defer self.allocator.free(params);
        const call = rpc_client.call(protocol.methods.auth_import, params) catch {
            try models.setStatus("Error: auth/import RPC failed");
            return;
        };
        defer call.deinit(self.allocator);
        if (!self.mutationSucceeded(call)) {
            try models.setStatus("Error: import rejected");
            return;
        }
        // The import envelope reports ok even when the source-collision guard
        // skipped everything; report the actual per-provider outcome instead
        // of claiming success. imported/skipped are provider ids, never
        // tokens.
        var imported_count: usize = 0;
        var skipped_count: usize = 0;
        if (call.result_json) |result_json| {
            if (std.json.parseFromSlice(std.json.Value, self.allocator, result_json, .{ .ignore_unknown_fields = true })) |parsed| {
                defer parsed.deinit();
                if (parsed.value == .object) {
                    if (parsed.value.object.get("imported")) |value| {
                        if (value == .array) imported_count = value.array.items.len;
                    }
                    if (parsed.value.object.get("skipped")) |value| {
                        if (value == .array) skipped_count = value.array.items.len;
                    }
                }
            } else |_| {}
        }
        if (imported_count == 0 and skipped_count > 0) {
            try models.setStatus("Skipped: provider already owned by another credential source. Force with `vantari auth import --force`.");
            return;
        }
        if (imported_count == 0) {
            try models.setStatus("Nothing imported: no live credential matched this source.");
            return;
        }
        try models.setStatus("Imported. Applies on the next turn.");
        try self.loadModels(rpc_client);
    }

    fn commitModelAssignment(self: *SettingsState, rpc_client: anytype) !void {
        const models = &self.models_state.?;
        const model = models.models.value();
        if (model.len == 0) return;

        // The assign picker has index 0 = active provider, 1..N = agents.
        // Derive the target from the cursor so Left/Right reaches agents.
        if (models.agents.cursor == 0) {
            const provider_id = models.loaded_provider_id;
            if (provider_id.len == 0) return;
            const params = try std.fmt.allocPrint(self.allocator, "{{\"provider_id\":{f},\"model\":{f}}}", .{
                std.json.fmt(provider_id, .{}),
                std.json.fmt(model, .{}),
            });
            defer self.allocator.free(params);
            const call = rpc_client.call(protocol.methods.provider_model_set, params) catch {
                try models.setStatus("Error: set-model RPC failed");
                return;
            };
            defer call.deinit(self.allocator);
            if (!self.mutationSucceeded(call)) {
                try models.setStatus("Error: set-model rejected");
                return;
            }
            const message = try std.fmt.allocPrint(self.allocator, "Model set for {s}: {s}. Applies on the next turn.", .{ provider_id, model });
            defer self.allocator.free(message);
            try models.setStatus(message);
        } else {
            const agent_id = models.agents.value();
            if (agent_id.len == 0) return;
            // Include the provider the model was pulled from so a model
            // discovered on a non-active provider configures a usable
            // provider/model pair on the agent.
            const params = try std.fmt.allocPrint(self.allocator, "{{\"agent_id\":{f},\"provider_id\":{f},\"model\":{f}}}", .{
                std.json.fmt(agent_id, .{}),
                std.json.fmt(models.loaded_provider_id, .{}),
                std.json.fmt(model, .{}),
            });
            defer self.allocator.free(params);
            const call = rpc_client.call(protocol.methods.agents_configure, params) catch {
                try models.setStatus("Error: agent configure RPC failed");
                return;
            };
            defer call.deinit(self.allocator);
            if (!self.mutationSucceeded(call)) {
                try models.setStatus("Error: agent assignment rejected");
                return;
            }
            try models.setStatus("Assigned to agent. Hot-loads on the next agents snapshot.");
        }
        self.config_changed = true;
        models.mode = .providers;
        // Reload the provider list so the updated model label is visible
        // immediately — without this the operator sees stale "(old-model)"
        // labels until they leave and re-enter the tab.
        self.loadModels(rpc_client) catch {};
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
        self.config_changed = true;
    }

    /// Handle a key press. Returns true if the key was consumed.
    pub fn handleKey(self: *SettingsState, key_event: anytype, rpc_client: anytype) !bool {
        const key = key_event;
        // The models section is RPC-backed; route all keys to its picker.
        if (std.mem.eql(u8, section_names[self.section_cursor], "models")) {
            return self.handleModelsKey(key, rpc_client);
        }
        // Dedicated section keys — Ctrl-Q previous, Ctrl-E next — always move
        // sections regardless of the selected entry. Left/Right are overloaded
        // (value cycling on constrained entries), so operators need one key
        // pair whose meaning never changes while the overlay is open.
        if (key.matches('q', .{ .ctrl = true })) {
            _ = try self.changeSection(-1, rpc_client);
            return true;
        }
        if (key.matches('e', .{ .ctrl = true })) {
            _ = try self.changeSection(1, rpc_client);
            return true;
        }
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
        // Left/Right cycle a constrained (enum) entry immediately — the same
        // no-typing mechanic the models tab uses. When the selected entry is
        // unconstrained, Left/Right falls through to section navigation.
        if (key.matches(tui.Key.left, .{}) or key.matches(tui.Key.right, .{})) {
            if (self.entry_cursor < self.entries.items.len) {
                const entry = self.entries.items[self.entry_cursor];
                if (entry.is_log_level or entry.is_theme or entry.is_status_bar_position) {
                    const direction: i8 = if (key.matches(tui.Key.left, .{})) -1 else 1;
                    const next = nextEnumValue(entry, direction);
                    self.edit_buffer.clearRetainingCapacity();
                    try self.edit_buffer.appendSlice(self.allocator, next);
                    try self.saveCurrentEntry(rpc_client);
                    self.edit_buffer.clearRetainingCapacity();
                    try self.loadSection();
                    return true;
                }
            }
        }
        // Section navigation. Tab / Shift-Tab always move sections; Left/Right
        // also move sections when the selected entry is not a constrained enum.
        // `changeSection` owns the destination load, including the RPC-backed
        // models surface, so every keyboard path loads the same thing.
        if (key.matches(tui.Key.left, .{}) or key.matches(tui.Key.tab, .{ .shift = true })) {
            _ = try self.changeSection(-1, rpc_client);
            return true;
        }
        if (key.matches(tui.Key.right, .{}) or key.matches(tui.Key.tab, .{})) {
            _ = try self.changeSection(1, rpc_client);
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
                } else if (entry.is_theme) {
                    self.edit_buffer.clearRetainingCapacity();
                    try self.edit_buffer.appendSlice(self.allocator, nextTheme(entry.value_text));
                    try self.saveCurrentEntry(rpc_client);
                    self.edit_buffer.clearRetainingCapacity();
                    try self.loadSection();
                } else if (entry.is_status_bar_position) {
                    self.edit_buffer.clearRetainingCapacity();
                    try self.edit_buffer.appendSlice(self.allocator, nextStatusBarPosition(entry.value_text));
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
/// Render the settings overlay to the root window. `frame_allocator` owns
/// every string Vaxis borrows from this frame until `vx.render` completes.
pub fn drawSettings(win: tui.Window, state: *SettingsState, frame_allocator: std.mem.Allocator) void {
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

    if (std.mem.eql(u8, section_names[state.section_cursor], "models")) {
        drawModels(win, state, frame_allocator);
        return;
    }

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
            .{ .text = " Tab/Ctrl-Q ← section →  Ctrl-E/Tab  ↑/↓ entry  ←/→ value  Enter edit/toggle  Esc close", .style = .{ .bg = Color.bg, .fg = Color.dim } },
        },
        .{ .col_offset = 2, .row_offset = footer_row },
    );
}

/// Render the Models tab: a layered picker over providers → models → assign
/// target. Each layer reuses the Picker engine; Left/Right (and Up/Down) cycle,
/// Enter locks, Esc walks back up. Every formatted row string comes from the
/// frame allocator: Vaxis cells BORROW printed text until `vx.render`, so a
/// per-row alloc/free here segfaults the render after the models list grows.
fn drawModels(win: tui.Window, state: *SettingsState, frame_allocator: std.mem.Allocator) void {
    // Every print is single-line (`.wrap = .none`): the default `.grapheme`
    // wrap would push long provider/model labels onto the next picker row and
    // corrupt the layered list layout on narrow terminals.
    const models = state.models_state orelse {
        _ = win.print(
            &.{.{ .text = "Loading providers…", .style = .{ .bg = Color.bg, .fg = Color.dim } }},
            .{ .col_offset = 2, .row_offset = 3, .wrap = .none },
        );
        return;
    };

    var row: usize = 3;
    const picker: *const Picker = switch (models.mode) {
        .providers => &models.providers,
        .models => &models.models,
        .assign => &models.agents,
    };
    const mode_title = switch (models.mode) {
        .providers => "Providers (connected + detected):",
        .models => "Models:",
        .assign => "Assign to (provider default or an agent):",
    };

    _ = win.print(
        &.{.{ .text = mode_title, .style = .{ .bg = Color.bg, .fg = Color.fg } }},
        .{ .col_offset = 2, .row_offset = @intCast(row), .wrap = .none },
    );
    row += 1;

    if (picker.itemCount() == 0) {
        _ = win.print(
            &.{.{ .text = "  (none)", .style = .{ .bg = Color.bg, .fg = Color.dim } }},
            .{ .col_offset = 4, .row_offset = @intCast(row), .wrap = .none },
        );
        row += 1;
    } else {
        const start = if (picker.cursor >= 8) picker.cursor - 7 else 0;
        const visible = @min(@as(usize, 8), picker.itemCount() - start);
        for (0..visible) |offset| {
            const index = start + offset;
            const is_selected = index == picker.cursor;
            const label = picker.labels.items[index];
            const row_text = std.fmt.allocPrint(frame_allocator, "{s}{s}", .{ if (is_selected) "→ " else "  ", label }) catch {
                row += 1;
                continue;
            };
            _ = win.print(
                &.{.{ .text = row_text, .style = if (is_selected)
                    .{ .bold = true, .bg = Color.bg, .fg = Color.accent }
                else
                    .{ .bg = Color.bg, .fg = Color.fg } }},
                .{ .col_offset = 2, .row_offset = @intCast(row), .wrap = .none },
            );
            row += 1;
        }
    }

    if (models.mode == .models and models.loaded_provider_id.len > 0) {
        _ = win.print(
            &.{.{ .text = models.loaded_provider_id, .style = .{ .bg = Color.bg, .fg = Color.dim } }},
            .{ .col_offset = 30, .row_offset = 4, .wrap = .none },
        );
    }

    if (models.status_message) |msg| {
        _ = win.print(
            &.{.{ .text = msg, .style = .{ .bg = Color.bg, .fg = Color.success } }},
            .{ .col_offset = 2, .row_offset = @intCast(win.height -| 2), .wrap = .none },
        );
    }

    const hint = switch (models.mode) {
        .providers => "↑/↓/←/→ cycle  Enter: connect/import or show models  Esc back",
        .models => "↑/↓/←/→ cycle model  Enter: assign  Esc back",
        .assign => "←/→ cycle target  Enter: lock in  Esc back",
    };
    _ = win.print(
        &.{.{ .text = hint, .style = .{ .bg = Color.bg, .fg = Color.dim } }},
        .{ .col_offset = 2, .row_offset = @intCast(win.height -| 1), .wrap = .none },
    );
}

fn nextLogLevel(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "silent")) return "normal";
    if (std.mem.eql(u8, value, "normal")) return "full";
    return "silent";
}

fn nextTheme(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "vantari")) return "midnight";
    if (std.mem.eql(u8, value, "midnight")) return "high_contrast";
    if (std.mem.eql(u8, value, "high_contrast")) return "amber";
    return "vantari";
}

fn nextStatusBarPosition(value: []const u8) []const u8 {
    return if (std.mem.eql(u8, value, "bottom")) "top" else "bottom";
}

/// Cycle a constrained setting's value one step in `direction` (-1 prev,
/// +1 next). Each family keeps a stable ring so Left/Right wraps deterministically.
fn nextEnumValue(entry: SettingsState.ConfigEntry, direction: i8) []const u8 {
    if (entry.is_log_level) {
        if (direction < 0) {
            if (std.mem.eql(u8, entry.value_text, "silent")) return "full";
            if (std.mem.eql(u8, entry.value_text, "normal")) return "silent";
            return "normal";
        }
        return nextLogLevel(entry.value_text);
    }
    if (entry.is_status_bar_position) {
        return nextStatusBarPosition(entry.value_text);
    }
    if (entry.is_theme) {
        if (direction < 0) {
            if (std.mem.eql(u8, entry.value_text, "vantari")) return "amber";
            if (std.mem.eql(u8, entry.value_text, "midnight")) return "vantari";
            if (std.mem.eql(u8, entry.value_text, "high_contrast")) return "midnight";
            return "high_contrast";
        }
        return nextTheme(entry.value_text);
    }
    return entry.value_text;
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

test "section_names has 12 entries with models tab" {
    try std.testing.expectEqual(@as(usize, 12), section_names.len);
    try std.testing.expectEqualStrings("runtime", section_names[0]);
    try std.testing.expectEqualStrings("tui", section_names[1]);
    try std.testing.expectEqualStrings("models", section_names[3]);
    try std.testing.expectEqualStrings("environment", section_names[11]);
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

test "settings cycles persisted TUI controls through the config owner" {
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
    try selectRuntimeEntry(&state, "theme");

    var client = SettingsSuccessClient{};
    try std.testing.expect(try state.handleKey(tui.Key{ .codepoint = tui.Key.enter }, &client));
    try std.testing.expect(client.saw_tui_theme);
    try std.testing.expect(state.takeConfigChanged());
    try std.testing.expect(!state.takeConfigChanged());
    try std.testing.expectEqualStrings("midnight", nextTheme("vantari"));
    try std.testing.expectEqualStrings("top", nextStatusBarPosition("bottom"));
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
    result_json: ?[]u8 = null,

    fn deinit(self: SettingsTestResult, allocator: std.mem.Allocator) void {
        if (self.result_json) |value| allocator.free(value);
    }
};

const SettingsSuccessClient = struct {
    calls: usize = 0,
    saw_json_string_value: bool = false,
    saw_tui_theme: bool = false,

    fn call(self: *SettingsSuccessClient, method: []const u8, params: []const u8) anyerror!SettingsTestResult {
        try std.testing.expectEqualStrings(protocol.methods.config_set, method);
        const is_runtime = std.mem.indexOf(u8, params, "\"section\":\"runtime\"") != null;
        const is_tui = std.mem.indexOf(u8, params, "\"section\":\"tui\"") != null;
        try std.testing.expect(is_runtime or is_tui);
        self.saw_json_string_value = std.mem.indexOf(u8, params, "\"value\":\"normal\"") != null;
        self.saw_tui_theme = std.mem.indexOf(u8, params, "\"key\":\"theme\"") != null and
            std.mem.indexOf(u8, params, "\"value\":\"midnight\"") != null;
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

test "settings section navigation wraps at both boundaries" {
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
    // Shift-Tab from the first section wraps to the last (environment).
    const shift_tab = tui.Key{ .codepoint = tui.Key.tab, .mods = .{ .shift = true } };
    try std.testing.expect(try state.handleKey(shift_tab, &client));
    try std.testing.expectEqual(@as(usize, section_names.len - 1), state.section_cursor);
    try std.testing.expect(state.entries.items.len > 0);
    // Tab from the last section wraps back to the first (runtime).
    const tab = tui.Key{ .codepoint = tui.Key.tab, .mods = .{} };
    try std.testing.expect(try state.handleKey(tab, &client));
    try std.testing.expectEqual(@as(usize, 0), state.section_cursor);
    try std.testing.expect(state.entries.items.len > 0);
}

test "settings dedicated section keys ctrl-q and ctrl-e always move sections" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    var state = SettingsState.init(allocator, workspace);
    defer state.deinit();
    state.open = true;
    try state.loadSection();

    var client = ModelsTestClient{};
    defer client.deinit();
    // Move onto the tui section and select `theme` — a constrained enum where
    // Left/Right cycle the VALUE. Ctrl-E must still switch the section.
    const tab = tui.Key{ .codepoint = tui.Key.tab, .mods = .{} };
    try std.testing.expect(try state.handleKey(tab, &client));
    for (state.entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.key, "theme")) {
            state.entry_cursor = i;
            break;
        }
    }
    try std.testing.expect(try state.handleKey(tui.Key{ .codepoint = 'e', .mods = .{ .ctrl = true } }, &client));
    try std.testing.expectEqualStrings("provider", section_names[state.section_cursor]);
    try std.testing.expect(state.entries.items.len > 0);
    // A second Ctrl-E crosses onto the RPC-backed models surface.
    try std.testing.expect(try state.handleKey(tui.Key{ .codepoint = 'e', .mods = .{ .ctrl = true } }, &client));
    try std.testing.expectEqualStrings("models", section_names[state.section_cursor]);
    try std.testing.expect(state.models_state != null);
    // Ctrl-Q walks back off the models tab to the previous section.
    try std.testing.expect(try state.handleKey(tui.Key{ .codepoint = 'q', .mods = .{ .ctrl = true } }, &client));
    try std.testing.expectEqualStrings("provider", section_names[state.section_cursor]);
    try std.testing.expect(state.entries.items.len > 0);
    // Wrap check: Ctrl-Q from the first section lands on environment.
    var state2 = SettingsState.init(allocator, workspace);
    defer state2.deinit();
    state2.open = true;
    try state2.loadSection();
    try std.testing.expect(try state2.handleKey(tui.Key{ .codepoint = 'q', .mods = .{ .ctrl = true } }, &client));
    try std.testing.expectEqual(@as(usize, section_names.len - 1), state2.section_cursor);
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

/// Fake RPC client for the Models tab. Returns canned providers, models, and
/// agents; records the last mutation it observed.
const ModelsTestClient = struct {
    mutation: ?[]u8 = null,
    import_params: ?[]u8 = null,
    /// When set, providers/list also reports this connected NON-active
    /// provider so tests can pull models from a provider other than the
    /// active one.
    second_provider: ?[]const u8 = null,
    /// When true, auth/import reports the collision-guard outcome: nothing
    /// imported, one provider skipped.
    import_skipped: bool = false,

    fn deinit(self: *ModelsTestClient) void {
        if (self.mutation) |value| std.testing.allocator.free(value);
        if (self.import_params) |value| std.testing.allocator.free(value);
    }

    fn call(self: *ModelsTestClient, method: []const u8, params: []const u8) anyerror!SettingsTestResult {
        if (std.mem.eql(u8, method, protocol.methods.auth_import)) {
            self.import_params = try std.testing.allocator.dupe(u8, params);
            if (self.import_skipped) {
                return .{ .result_json = try std.testing.allocator.dupe(u8,
                    \\{"status":"ok","imported":[],"skipped":["anthropic"]}
                ) };
            }
            return .{ .result_json = try std.testing.allocator.dupe(u8,
                \\{"status":"ok","imported":["anthropic"],"skipped":[]}
            ) };
        }
        if (std.mem.eql(u8, method, protocol.methods.providers_list)) {
            if (self.second_provider) |provider_id| {
                const rendered = try std.fmt.allocPrint(std.testing.allocator,
                    \\{{"active_provider":"zai","providers":[{{"provider_id":"zai","model":"glm-5.2","base_url":"https://api.z.ai/api/coding/paas/v4"}},{{"provider_id":"{s}","model":"m-1","base_url":"https://example.invalid/v1"}}]}}
                , .{provider_id});
                return .{ .result_json = rendered };
            }
            return .{ .result_json = try std.testing.allocator.dupe(u8,
                \\{"active_provider":"zai","providers":[{"provider_id":"zai","model":"glm-5.2","base_url":"https://api.z.ai/api/coding/paas/v4"}]}
            ) };
        }
        if (std.mem.eql(u8, method, protocol.methods.agents_list)) {
            return .{ .result_json = try std.testing.allocator.dupe(u8,
                \\{"agents":[{"id":"recon","description":"Recon"}]}
            ) };
        }
        if (std.mem.eql(u8, method, protocol.methods.auth_detect)) {
            return .{ .result_json = try std.testing.allocator.dupe(u8,
                \\{"detected":[{"provider_id":"anthropic","source":"claude","live":true}]}
            ) };
        }
        if (std.mem.eql(u8, method, protocol.methods.models_list)) {
            return .{ .result_json = try std.testing.allocator.dupe(u8,
                \\{"status":"ok","models":[{"id":"glm-5.5","context_length":128000}]}
            ) };
        }
        if (std.mem.eql(u8, method, protocol.methods.provider_model_set) or
            std.mem.eql(u8, method, protocol.methods.agents_configure))
        {
            self.mutation = try std.testing.allocator.dupe(u8, params);
            return .{ .result_json = try std.testing.allocator.dupe(u8, "{\"status\":\"ok\"}") };
        }
        return .{ .result_json = try std.testing.allocator.dupe(u8, "{}") };
    }
};

test "settings cycles constrained entries with left/right arrows" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    var state = SettingsState.init(allocator, workspace);
    defer state.deinit();
    state.open = true;
    state.section_cursor = 1; // tui section (theme, status_bar_position)
    try state.loadSection();
    try selectRuntimeEntry(&state, "theme");

    var client = SettingsSuccessClient{};
    // Right arrow cycles theme vantari → midnight.
    try std.testing.expect(try state.handleKey(tui.Key{ .codepoint = tui.Key.right }, &client));
    try std.testing.expect(client.saw_tui_theme);
    try std.testing.expect(state.takeConfigChanged());
}

test "models tab cycles models with left/right arrows and preserves tab nav" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);

    var state = SettingsState.init(std.testing.allocator, workspace);
    defer state.deinit();
    state.open = true;
    for (section_names, 0..) |name, index| {
        if (std.mem.eql(u8, name, "models")) {
            state.section_cursor = index;
            break;
        }
    }
    var client = ModelsTestClient{};
    defer client.deinit();
    try state.loadModels(&client);
    const models = &state.models_state.?;
    const Mode = @TypeOf(models.mode);

    // Enter provider → models mode.
    _ = try state.handleModelsKey(tui.Key{ .codepoint = tui.Key.enter }, &client);
    try std.testing.expectEqual(Mode.models, models.mode);

    // Right arrow cycles within models (single model: wraps to itself).
    try std.testing.expect(try state.handleModelsKey(tui.Key{ .codepoint = tui.Key.right }, &client));
    try std.testing.expectEqualStrings("glm-5.5", models.models.value());

    // Shift-Tab leaves the models overlay to the previous section.
    const shift_tab = tui.Key{ .codepoint = tui.Key.tab, .mods = .{ .shift = true } };
    try std.testing.expect(try state.handleModelsKey(shift_tab, &client));
    try std.testing.expectEqualStrings("provider", section_names[state.section_cursor]);
}

test "models tab passes the provenance source name to auth import for detected rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);

    var state = SettingsState.init(std.testing.allocator, workspace);
    defer state.deinit();
    state.open = true;
    for (section_names, 0..) |name, index| {
        if (std.mem.eql(u8, name, "models")) {
            state.section_cursor = index;
            break;
        }
    }
    var client = ModelsTestClient{};
    defer client.deinit();
    try state.loadModels(&client);
    const models = &state.models_state.?;
    const Mode = @TypeOf(models.mode);

    // Providers: zai (index 0) + anthropic detected (index 1). The detected
    // row's picker value is the PROVENANCE source ("claude"), not the
    // provider id ("anthropic") — auth/import matches source names.
    try std.testing.expectEqual(@as(usize, 2), models.providers.itemCount());
    models.providers.cursor = 1;
    try std.testing.expectEqualStrings("claude", models.providers.value());

    // Enter on the detected row imports the source, then reloads.
    _ = try state.handleModelsKey(tui.Key{ .codepoint = tui.Key.enter }, &client);
    try std.testing.expect(client.import_params != null);
    try std.testing.expect(std.mem.indexOf(u8, client.import_params.?, "\"claude\"") != null);
    try std.testing.expectEqual(Mode.providers, models.mode);
}

test "picker cycles and locks without typing" {
    var picker = Picker.init(std.testing.allocator);
    defer picker.deinit();
    try picker.add("OpenCode", "opencode");
    try picker.add("Codex", "openai-codex");
    try picker.add("Anthropic", "anthropic");
    try std.testing.expectEqual(@as(usize, 3), picker.itemCount());
    try std.testing.expectEqualStrings("opencode", picker.value());
    picker.move(1);
    try std.testing.expectEqualStrings("openai-codex", picker.value());
    picker.move(1);
    try std.testing.expectEqualStrings("anthropic", picker.value());
    picker.move(1);
    try std.testing.expectEqualStrings("opencode", picker.value()); // wraps
    picker.move(-1);
    try std.testing.expectEqualStrings("anthropic", picker.value());
    try std.testing.expectEqual(@as(?usize, 1), picker.indexOfValue("openai-codex"));
}

test "models tab loads providers detected and agents and assigns to an agent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);

    var state = SettingsState.init(std.testing.allocator, workspace);
    defer state.deinit();
    state.open = true;
    // Pin to the models section and load via the seam.
    for (section_names, 0..) |name, index| {
        if (std.mem.eql(u8, name, "models")) {
            state.section_cursor = index;
            break;
        }
    }
    var client = ModelsTestClient{};
    defer client.deinit();
    try state.loadModels(&client);
    try std.testing.expect(state.models_state != null);
    const models = &state.models_state.?;
    const Mode = @TypeOf(models.mode);

    // Providers: zai (connected) + anthropic (detected).
    try std.testing.expectEqual(@as(usize, 2), models.providers.itemCount());
    try std.testing.expectEqualStrings("zai", models.providers.value());

    // Enter on connected provider pulls models.
    try std.testing.expect(try state.handleModelsKey(tui.Key{ .codepoint = tui.Key.enter }, &client));
    try std.testing.expectEqual(Mode.models, models.mode);
    try std.testing.expectEqual(@as(usize, 1), models.models.itemCount());
    try std.testing.expectEqualStrings("glm-5.5", models.models.value());

    // Enter on model → assign mode, index 0 = active provider, index 1 = agent.
    try std.testing.expect(try state.handleModelsKey(tui.Key{ .codepoint = tui.Key.enter }, &client));
    try std.testing.expectEqual(Mode.assign, models.mode);
    try std.testing.expectEqual(@as(usize, 2), models.agents.itemCount());

    // Cycle right to the agent and lock in.
    try std.testing.expect(try state.handleModelsKey(tui.Key{ .codepoint = tui.Key.right }, &client));
    try std.testing.expectEqualStrings("recon", models.agents.value());
    try std.testing.expect(try state.handleModelsKey(tui.Key{ .codepoint = tui.Key.enter }, &client));
    try std.testing.expect(client.mutation != null);
    try std.testing.expect(std.mem.indexOf(u8, client.mutation.?, "\"agent_id\":\"recon\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.mutation.?, "\"provider_id\":\"zai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.mutation.?, "\"model\":\"glm-5.5\"") != null);
    // Returns to providers mode after committing.
    try std.testing.expectEqual(Mode.providers, models.mode);
}

test "models tab assigns to the active provider at cursor 0" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);

    var state = SettingsState.init(std.testing.allocator, workspace);
    defer state.deinit();
    state.open = true;
    for (section_names, 0..) |name, index| {
        if (std.mem.eql(u8, name, "models")) {
            state.section_cursor = index;
            break;
        }
    }
    var client = ModelsTestClient{};
    defer client.deinit();
    try state.loadModels(&client);
    const models = &state.models_state.?;

    // providers → models → assign (cursor stays 0 = active provider).
    _ = try state.handleModelsKey(tui.Key{ .codepoint = tui.Key.enter }, &client);
    _ = try state.handleModelsKey(tui.Key{ .codepoint = tui.Key.enter }, &client);
    try std.testing.expectEqual(@as(usize, 0), models.agents.cursor);
    _ = try state.handleModelsKey(tui.Key{ .codepoint = tui.Key.enter }, &client);
    try std.testing.expect(client.mutation != null);
    try std.testing.expect(std.mem.indexOf(u8, client.mutation.?, "\"provider_id\":\"zai\"") != null);
}

test "tab into the models section loads its picker surface" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);

    var state = SettingsState.init(std.testing.allocator, workspace);
    defer state.deinit();
    state.open = true;
    // Start on the section before models.
    for (section_names, 0..) |name, index| {
        if (std.mem.eql(u8, name, "models")) {
            state.section_cursor = index - 1;
            break;
        }
    }
    try state.loadSection();

    var client = ModelsTestClient{};
    defer client.deinit();
    // One Tab crossing into models must load the RPC-backed surface, not the
    // generic config entries.
    try std.testing.expect(try state.handleKey(tui.Key{ .codepoint = tui.Key.tab }, &client));
    try std.testing.expectEqualStrings("models", section_names[state.section_cursor]);
    try std.testing.expect(state.models_state != null);
    try std.testing.expect(state.models_state.?.providers.itemCount() > 0);
}

test "models status transitions free the previous message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);

    var state = SettingsState.init(std.testing.allocator, workspace);
    defer state.deinit();
    state.open = true;
    for (section_names, 0..) |name, index| {
        if (std.mem.eql(u8, name, "models")) {
            state.section_cursor = index;
            break;
        }
    }
    var client = ModelsTestClient{};
    defer client.deinit();
    try state.loadModels(&client);
    const models = &state.models_state.?;
    const Mode = @TypeOf(models.mode);

    // A status line exists, then every clearing transition (Esc back from
    // models mode, a fresh pull) must free it — leaks fail the test
    // allocator at deinit.
    try models.setStatus("previous message that must be freed");
    _ = try state.handleModelsKey(tui.Key{ .codepoint = tui.Key.enter }, &client);
    try std.testing.expectEqual(Mode.models, models.mode);
    _ = try state.handleModelsKey(tui.Key{ .codepoint = tui.Key.escape }, &client);
    try std.testing.expectEqual(Mode.providers, models.mode);
    try std.testing.expect(models.status_message == null);
}

test "assign row names the provider the commit writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);

    var state = SettingsState.init(std.testing.allocator, workspace);
    defer state.deinit();
    state.open = true;
    for (section_names, 0..) |name, index| {
        if (std.mem.eql(u8, name, "models")) {
            state.section_cursor = index;
            break;
        }
    }
    var client = ModelsTestClient{ .second_provider = "openrouter" };
    defer client.deinit();
    try state.loadModels(&client);
    const models = &state.models_state.?;
    const Mode = @TypeOf(models.mode);

    // zai (active) + openrouter (connected, non-active). Pull models from
    // openrouter: the assign row 0 must name openrouter — never the active
    // provider zai — and the commit must write openrouter.
    models.providers.cursor = 1;
    try std.testing.expectEqualStrings("openrouter", models.providers.value());
    _ = try state.handleModelsKey(tui.Key{ .codepoint = tui.Key.enter }, &client);
    try std.testing.expectEqual(Mode.models, models.mode);
    _ = try state.handleModelsKey(tui.Key{ .codepoint = tui.Key.enter }, &client);
    try std.testing.expectEqual(Mode.assign, models.mode);
    try std.testing.expect(std.mem.indexOf(u8, models.agents.label(), "openrouter") != null);
    try std.testing.expect(std.mem.indexOf(u8, models.agents.label(), "zai") == null);
    _ = try state.handleModelsKey(tui.Key{ .codepoint = tui.Key.enter }, &client);
    try std.testing.expect(client.mutation != null);
    try std.testing.expect(std.mem.indexOf(u8, client.mutation.?, "\"provider_id\":\"openrouter\"") != null);
}

test "import reports skipped sources instead of claiming success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);

    var state = SettingsState.init(std.testing.allocator, workspace);
    defer state.deinit();
    state.open = true;
    for (section_names, 0..) |name, index| {
        if (std.mem.eql(u8, name, "models")) {
            state.section_cursor = index;
            break;
        }
    }
    var client = ModelsTestClient{ .import_skipped = true };
    defer client.deinit();
    try state.loadModels(&client);
    const models = &state.models_state.?;

    // The detected row (index 1) triggers import; the collision guard
    // skipped everything and the status must say so.
    models.providers.cursor = 1;
    _ = try state.handleModelsKey(tui.Key{ .codepoint = tui.Key.enter }, &client);
    try std.testing.expect(models.status_message != null);
    try std.testing.expect(std.mem.indexOf(u8, models.status_message.?, "Skipped") != null);
    try std.testing.expect(std.mem.indexOf(u8, models.status_message.?, "Imported") == null);
}

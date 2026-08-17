const std = @import("std");

/// Vendored model-capability snapshot, generated from the models.dev
/// registry (MIT, `.refs/models-dev/api.json`) for the providers VANTARI
/// ships profiles for. This is the "what exists" floor under live
/// discovery: when a gateway has no models endpoint (Codex API-key path,
/// OpenCode gateway base) or is unreachable, the snapshot still answers
/// model-catalog queries with real context windows instead of a fabricated
/// single-model list.
///
/// Precedence (one family, three sources):
///   1. live discovery per transport (models.zig)
///   2. this snapshot (what exists, with limits)
///   3. the credential's configured model (last resort)
///
/// Regenerate with scripts/gen-models-snapshot.py.

pub const SnapshotModel = struct {
    id: []const u8,
    context: ?u64,
    output: ?u64,
    tool_call: bool,
    reasoning: bool,
};

pub const SnapshotProvider = struct {
    id: []const u8,
    name: []const u8,
    models: []SnapshotModel,
};

const snapshot_json = @embedFile("models_snapshot.json");

pub const Error = error{MalformedSnapshot, OutOfMemory};

const ParsedEntry = struct {
    id: []const u8,
    context: ?u64 = null,
    output: ?u64 = null,
    tool_call: bool = false,
    reasoning: bool = false,
};

const ParsedProvider = struct {
    id: []const u8,
    name: []const u8,
    models: []ParsedEntry,
};

/// Look up one model's capabilities. Caller owns nothing — slices point
/// into the parsed arena. Returns null when the provider or model is not
/// in the vendored subset.
pub fn lookup(allocator: std.mem.Allocator, provider_id: []const u8, model_id: []const u8) Error!?SnapshotModel {
    var parsed = try parseSnapshot(allocator);
    defer parsed.deinit(allocator);
    for (parsed.providers) |provider| {
        if (!std.mem.eql(u8, provider.id, provider_id)) continue;
        for (provider.models) |model| {
            if (std.mem.eql(u8, model.id, model_id)) {
                return SnapshotModel{
                    .id = model.id,
                    .context = model.context,
                    .output = model.output,
                    .tool_call = model.tool_call,
                    .reasoning = model.reasoning,
                };
            }
        }
        return null;
    }
    return null;
}

/// List every vendored model for one provider. Model ids are OWNED dupes;
/// free the whole list with `freeModelList`.
pub fn listProviderModels(allocator: std.mem.Allocator, provider_id: []const u8) Error!?[]SnapshotModel {
    var parsed = try parseSnapshot(allocator);
    defer parsed.deinit(allocator);
    for (parsed.providers) |provider| {
        if (!std.mem.eql(u8, provider.id, provider_id)) continue;
        const out = try allocator.alloc(SnapshotModel, provider.models.len);
        errdefer allocator.free(out);
        for (provider.models, 0..) |model, i| {
            out[i] = .{
                .id = try allocator.dupe(u8, model.id),
                .context = model.context,
                .output = model.output,
                .tool_call = model.tool_call,
                .reasoning = model.reasoning,
            };
        }
        return out;
    }
    return null;
}

pub fn freeModelList(allocator: std.mem.Allocator, models: []SnapshotModel) void {
    for (models) |model| allocator.free(model.id);
    allocator.free(models);
}

const ParsedSnapshot = struct {
    providers: []ParsedProvider,
    arena: *std.heap.ArenaAllocator,

    fn deinit(self: ParsedSnapshot, allocator: std.mem.Allocator) void {
        const parent = self.arena.child_allocator;
        self.arena.deinit();
        parent.destroy(self.arena);
        _ = allocator;
    }
};

fn parseSnapshot(allocator: std.mem.Allocator) Error!ParsedSnapshot {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena_allocator, snapshot_json, .{
        .ignore_unknown_fields = true,
    }) catch return Error.MalformedSnapshot;

    const root = switch (parsed) {
        .object => |obj| obj,
        else => return Error.MalformedSnapshot,
    };

    var providers = std.array_list.Managed(ParsedProvider).init(arena_allocator);
    var it = root.iterator();
    while (it.next()) |entry| {
        const provider_obj = switch (entry.value_ptr.*) {
            .object => |obj| obj,
            else => continue,
        };
        const name_value = provider_obj.get("n") orelse continue;
        const name = switch (name_value) {
            .string => |s| s,
            else => continue,
        };
        const models_value = provider_obj.get("m") orelse continue;
        const models_obj = switch (models_value) {
            .object => |obj| obj,
            else => continue,
        };

        var models = std.array_list.Managed(ParsedEntry).init(arena_allocator);
        var model_it = models_obj.iterator();
        while (model_it.next()) |model_entry| {
            const model_obj = switch (model_entry.value_ptr.*) {
                .object => |obj| obj,
                else => continue,
            };
            const context: ?u64 = intField(model_obj, "c");
            const output: ?u64 = intField(model_obj, "o");
            const tool_call = boolField(model_obj, "t");
            const reasoning = boolField(model_obj, "r");
            try models.append(.{
                .id = model_entry.key_ptr.*,
                .context = context,
                .output = output,
                .tool_call = tool_call,
                .reasoning = reasoning,
            });
        }
        try providers.append(.{
            .id = entry.key_ptr.*,
            .name = name,
            .models = try models.toOwnedSlice(),
        });
    }

    return .{ .providers = try providers.toOwnedSlice(), .arena = arena };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| if (n > 0) @as(?u64, @intCast(n)) else null,
        .float => |n| if (n > 0) @as(?u64, @intFromFloat(n)) else null,
        else => null,
    };
}

fn boolField(obj: std.json.ObjectMap, key: []const u8) bool {
    const value = obj.get(key) orelse return false;
    return switch (value) {
        .bool => |b| b,
        else => false,
    };
}

test "snapshot resolves known model capabilities across providers" {
    const allocator = std.testing.allocator;

    const glm = (try lookup(allocator, "opencode", "glm-4.6")).?;
    try std.testing.expect(glm.context != null and glm.context.? > 100_000);
    try std.testing.expect(glm.tool_call);
    try std.testing.expect(glm.reasoning);

    const gpt = try lookup(allocator, "openai", "gpt-4o");
    try std.testing.expect(gpt != null);
    try std.testing.expect(gpt.?.tool_call);

    const missing_provider = try lookup(allocator, "not-a-provider", "any");
    try std.testing.expect(missing_provider == null);
}

test "snapshot lists models for a vendored provider only" {
    const allocator = std.testing.allocator;

    const models = (try listProviderModels(allocator, "anthropic")).?;
    defer freeModelList(allocator, models);
    try std.testing.expect(models.len > 5);
    var found_sonnet = false;
    for (models) |model| {
        if (std.mem.indexOf(u8, model.id, "sonnet") != null) found_sonnet = true;
    }
    try std.testing.expect(found_sonnet);

    const absent = try listProviderModels(allocator, "private-gateway");
    try std.testing.expect(absent == null);
}

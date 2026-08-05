const std = @import("std");
const provider = @import("openai_compatible.zig");

/// Model discovery for OpenAI-compatible providers (LM Studio, llama.cpp,
/// vLLM, Ollama, OpenRouter, z.ai, ...). One GET to {base_url}/v1/models
/// returns the live model list. For LM Studio, the OpenAI-compat surface
/// omits context_length — the native /api/v1/models/loaded endpoint is
/// probed as a fallback to recover runtime context-window info.
///
/// Harvested from pi-mono's web-ui model-discovery and adapted to the typed
/// Zig transport. The OpenAI-compat /v1/models response is
/// `{ object, data: [{id, object, owned_by}] }`; `created` is optional (LM
/// Studio omits it) and `context_length` is optional (vLLM/llama.cpp include
/// it; LM Studio does not on this surface).

pub const Error = error{
    Unreachable,
    BadStatus,
    MalformedResponse,
    OutOfMemory,
};

pub const ModelDescriptor = struct {
    id: []const u8,
    owned_by: ?[]const u8 = null,
    context_length: ?u64 = null,
    raw_json: []const u8,

    pub fn deinit(self: ModelDescriptor, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.owned_by) |value| allocator.free(value);
        allocator.free(self.raw_json);
    }
};

pub const ModelsList = struct {
    provider_id: []const u8,
    base_url: []const u8,
    models: []ModelDescriptor,
    context_from_native_surface: bool = false,

    pub fn deinit(self: ModelsList, allocator: std.mem.Allocator) void {
        for (self.models) |model| model.deinit(allocator);
        allocator.free(self.models);
        allocator.free(self.provider_id);
        allocator.free(self.base_url);
    }
};

pub fn listModels(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_key: []const u8,
    account_id: ?[]const u8,
    provider_id: []const u8,
) Error!ModelsList {
    const url = try provider.modelsUrl(allocator, base_url);
    defer allocator.free(url);

    const body = provider.httpGet(allocator, url, api_key, account_id) catch |err| switch (err) {
        error.ConnectionRefused, error.NetworkUnreachable, error.ConnectionTimedOut => return Error.Unreachable,
        provider.Error.BadStatus => return Error.BadStatus,
        else => return Error.Unreachable,
    };
    defer allocator.free(body);

    var models = try parseModelsData(allocator, body);
    errdefer {
        for (models) |model| model.deinit(allocator);
        allocator.free(models);
    }

    var context_from_native = false;
    if (provider.isLocalHostUrl(base_url)) {
        if (try enrichFromLmStudioNative(allocator, base_url, api_key, &models)) {
            context_from_native = true;
        }
    }

    return .{
        .provider_id = try allocator.dupe(u8, provider_id),
        .base_url = try allocator.dupe(u8, base_url),
        .models = models,
        .context_from_native_surface = context_from_native,
    };
}

pub fn detectContextWindowForModel(list: ModelsList, model_id: []const u8) ?u64 {
    for (list.models) |model| {
        if (model.context_length) |length| {
            if (std.mem.eql(u8, model.id, model_id)) return length;
        }
    }
    return null;
}

fn parseModelsData(allocator: std.mem.Allocator, body: []const u8) Error![]ModelDescriptor {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return Error.MalformedResponse;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return Error.MalformedResponse,
    };

    if (root.get("error")) |_| return Error.BadStatus;

    const data_value = root.get("data") orelse return Error.MalformedResponse;
    const data_array = switch (data_value) {
        .array => |arr| arr,
        else => return Error.MalformedResponse,
    };

    var models = std.array_list.Managed(ModelDescriptor).init(allocator);
    errdefer {
        for (models.items) |model| model.deinit(allocator);
        models.deinit();
    }

    for (data_array.items) |entry| {
        const entry_obj = switch (entry) {
            .object => |obj| obj,
            else => continue,
        };
        const parsed_entry = parseModelEntry(entry_obj) orelse continue;

        const id = try allocator.dupe(u8, parsed_entry.id.?);
        errdefer allocator.free(id);
        const owned_by = if (parsed_entry.owned_by) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_by) |value| allocator.free(value);
        const raw_json = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(entry, .{})});
        errdefer allocator.free(raw_json);

        try models.append(.{
            .id = id,
            .owned_by = owned_by,
            .context_length = parsed_entry.context_length,
            .raw_json = raw_json,
        });
    }

    return models.toOwnedSlice();
}

fn parseModelEntry(obj: std.json.ObjectMap) ?ParsedModelEntry {
    const id_value = obj.get("id") orelse return null;
    const id = switch (id_value) {
        .string => |s| s,
        else => return null,
    };
    if (id.len == 0) return null;

    var entry = ParsedModelEntry{ .id = id };
    if (obj.get("owned_by")) |value| {
        if (value == .string) entry.owned_by = value.string;
    }
    if (obj.get("context_length")) |value| {
        switch (value) {
            .integer => |n| if (n > 0) {
                entry.context_length = @intCast(n);
            },
            .float => |n| if (n > 0) {
                entry.context_length = @intFromFloat(n);
            },
            else => {},
        }
    }
    if (obj.get("max_model_len")) |value| {
        switch (value) {
            .integer => |n| if (n > 0 and entry.context_length == null) {
                entry.context_length = @intCast(n);
            },
            .float => |n| if (n > 0 and entry.context_length == null) {
                entry.context_length = @intFromFloat(n);
            },
            else => {},
        }
    }
    return entry;
}

fn enrichFromLmStudioNative(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_key: []const u8,
    models: *[]ModelDescriptor,
) Error!bool {
    const url = (provider.lmStudioLoadedModelsUrl(allocator, base_url) catch return false) orelse return false;
    defer allocator.free(url);

    const body = provider.httpGet(allocator, url, api_key, null) catch return false;
    defer allocator.free(body);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return false,
    };

    const instances_value = root.get("modelInstances") orelse {
        switch (parsed.value) {
            .array => |arr| return mergeNativeInstances(arr.items, models),
            else => return false,
        }
    };
    const instances = switch (instances_value) {
        .array => |arr| arr.items,
        else => return false,
    };
    return mergeNativeInstances(instances, models);
}

fn mergeNativeInstances(
    instances: []std.json.Value,
    models: *[]ModelDescriptor,
) Error!bool {
    var merged_any = false;
    for (instances) |instance| {
        const obj = switch (instance) {
            .object => |o| o,
            else => continue,
        };
        const identifier = blk: {
            const id_value = obj.get("identifier") orelse obj.get("model") orelse continue;
            if (id_value != .string) continue;
            break :blk id_value.string;
        };

        const context_length: ?u64 = blk: {
            const ctx_value = obj.get("contextLength") orelse break :blk null;
            switch (ctx_value) {
                .integer => |n| break :blk if (n > 0) @as(?u64, @intCast(n)) else null,
                .float => |n| break :blk if (n > 0) @as(?u64, @intFromFloat(n)) else null,
                else => break :blk null,
            }
        };
        if (context_length == null) continue;

        for (models.*) |*model| {
            if (std.mem.eql(u8, model.id, identifier)) {
                if (model.context_length == null) {
                    model.context_length = context_length;
                    merged_any = true;
                }
                break;
            }
        }
    }
    return merged_any;
}

const ParsedModelEntry = struct {
    id: ?[]const u8 = null,
    owned_by: ?[]const u8 = null,
    context_length: ?u64 = null,
};

test "models parser handles LM Studio shape with missing created and no context_length" {
    const body =
        \\{"object":"list","data":[
        \\  {"id":"ibm/granite-4-micro","object":"model","owned_by":"lmstudio"},
        \\  {"id":"qwen2.5-7b-instruct","object":"model","owned_by":"lmstudio"}
        \\]}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const models = try parseModelsData(allocator, body);
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("ibm/granite-4-micro", models[0].id);
    try std.testing.expectEqualStrings("lmstudio", models[0].owned_by.?);
    try std.testing.expect(models[0].context_length == null);
    try std.testing.expectEqualStrings("qwen2.5-7b-instruct", models[1].id);
}

test "models parser handles vLLM context_length field" {
    const body =
        \\{"object":"list","data":[
        \\  {"id":"meta-llama/Llama-3.1-8B-Instruct","object":"model","created":1700000000,"owned_by":"vllm","context_length":32768}
        \\]}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const models = try parseModelsData(allocator, body);
    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqualStrings("meta-llama/Llama-3.1-8B-Instruct", models[0].id);
    try std.testing.expectEqual(@as(u64, 32768), models[0].context_length.?);
}

test "models parser handles llama.cpp max_model_len field" {
    const body =
        \\{"data":[{"id":"llama-3-8b","max_model_len":8192}]}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const models = try parseModelsData(allocator, body);
    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqual(@as(u64, 8192), models[0].context_length.?);
}

test "models parser treats error envelope as BadStatus" {
    const body = "{\"error\":\"model not loaded\"}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(Error.BadStatus, parseModelsData(arena.allocator(), body));
}

test "models parser rejects malformed json" {
    const body = "{not json";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(Error.MalformedResponse, parseModelsData(arena.allocator(), body));
}

test "models parser skips entries with missing or non-string id" {
    const body =
        \\{"data":[
        \\  {"id":"valid-model","object":"model"},
        \\  {"object":"model"},
        \\  {"id":42,"object":"model"},
        \\  {"id":"","object":"model"}
        \\]}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const models = try parseModelsData(allocator, body);
    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqualStrings("valid-model", models[0].id);
}

test "detectContextWindowForModel returns matching window and null otherwise" {
    const models = [_]ModelDescriptor{
        .{ .id = "alpha", .owned_by = null, .context_length = 4096, .raw_json = "{}" },
        .{ .id = "beta", .owned_by = null, .context_length = null, .raw_json = "{}" },
    };
    const list = ModelsList{
        .provider_id = "test",
        .base_url = "http://localhost:1234",
        .models = @constCast(&models),
    };

    try std.testing.expectEqual(@as(?u64, 4096), detectContextWindowForModel(list, "alpha"));
    try std.testing.expectEqual(@as(?u64, null), detectContextWindowForModel(list, "beta"));
    try std.testing.expectEqual(@as(?u64, null), detectContextWindowForModel(list, "missing"));
}

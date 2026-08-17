const std = @import("std");
const provider = @import("openai_compatible.zig");
const models_snapshot = @import("models_snapshot.zig");
const provider_profile = @import("profile.zig");
const types = @import("../../shared/types.zig");
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
    return listModelsWithAuth(allocator, base_url, api_key, account_id, provider_id, null);
}

/// Discover models with the provider's explicit header scheme. The legacy
/// entry point above remains compatible for local OpenAI-compatible callers;
/// canonical RPC callers pass the auth-ledger scheme here.
pub fn listModelsWithAuth(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_key: []const u8,
    account_id: ?[]const u8,
    provider_id: []const u8,
    configured_auth_scheme: ?types.AuthScheme,
) Error!ModelsList {
    const url = try provider.modelsUrl(allocator, base_url);
    defer allocator.free(url);

    const profile_defaults = provider_profile.defaults(provider_id, base_url);
    const headers = provider.RequestHeaders{
        .auth_scheme = configured_auth_scheme orelse profile_defaults.auth_scheme,
        .account_id = account_id,
        .anthropic_version = profile_defaults.anthropic_version,
    };
    const body = provider.httpGetWithHeaders(allocator, url, api_key, headers) catch |err| switch (err) {
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

/// One family, three catalog sources with one precedence. Provider
/// identity is an attribute of a model (ACP lesson), never a separate
/// surface per provider:
///
///   1. LIVE — the family's real discovery endpoint:
///        OpenAI-compatible gateways  {base}/v1/models   (listModelsWithAuth)
///        Codex (ChatGPT OAuth)       {base}/codex/models  listCodexModels
///        OpenCode Zen gateway        https://opencode.ai/zen[/go]/v1/models
///        Anthropic                   {base}/v1/models with x-api-key headers
///   2. SNAPSHOT — the vendored models.dev subset (models_snapshot.zig):
///      answers "what exists" with real context limits when the gateway
///      has no models endpoint (Codex API-key path, opencode base URL)
///      or is unreachable.
///   3. CONFIGURED — the credential's model as a single-entry catalog
///      (nativeModels). Last resort only.
const DiscoveryFamily = enum {
    openai_compatible,
    codex_backend,
    anthropic,
};

fn discoveryFamilyFor(provider_id: []const u8, base_url: []const u8) DiscoveryFamily {
    if (std.mem.eql(u8, provider_id, "openai-codex")) return .codex_backend;
    if (provider_profile.isAnthropic(provider_id, base_url)) return .anthropic;
    return .openai_compatible;
}

/// Reverse-engineered Codex model discovery. The ChatGPT backend serves
/// `GET {base}/codex/models` (Bearer + ChatGPT-Account-ID headers) with
/// `{models: [{slug, display_name, context_window, visibility, …}]}`.
/// Only visibility=="list" entries are operator-selectable; codex-rs
/// applies the same filter. The API-key path has NO codex models surface
/// (openai/codex#3716) — callers fall back to the snapshot.
pub fn listCodexModels(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    access_token: []const u8,
    account_id: ?[]const u8,
    provider_id: []const u8,
) Error!ModelsList {
    const trimmed = std.mem.trimRight(u8, base_url, "/");
    const codex_base = if (std.mem.endsWith(u8, trimmed, "/codex"))
        trimmed
    else
        std.fmt.allocPrint(allocator, "{s}/codex", .{trimmed}) catch return Error.OutOfMemory;
    defer if (!std.mem.eql(u8, codex_base, trimmed)) allocator.free(codex_base);

    const url = std.fmt.allocPrint(allocator, "{s}/models?client_version=var1", .{codex_base}) catch return Error.OutOfMemory;
    defer allocator.free(url);

    const headers = provider.RequestHeaders{
        .auth_scheme = .bearer,
        .account_id = account_id,
    };
    const body = provider.httpGetWithHeaders(allocator, url, access_token, headers) catch |err| switch (err) {
        provider.Error.BadStatus => return Error.BadStatus,
        else => return Error.Unreachable,
    };
    defer allocator.free(body);

    return parseCodexModelsData(allocator, body, provider_id, base_url);
}

const CodexModelEntry = struct {
    slug: []const u8,
    display_name: ?[]const u8 = null,
    context_window: ?u64 = null,
};

fn parseCodexModelsData(
    allocator: std.mem.Allocator,
    body: []const u8,
    provider_id: []const u8,
    base_url: []const u8,
) Error!ModelsList {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return Error.MalformedResponse;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return Error.MalformedResponse,
    };
    if (root.get("error") != null) return Error.BadStatus;
    const models_value = root.get("models") orelse return Error.MalformedResponse;
    const models_array = switch (models_value) {
        .array => |arr| arr,
        else => return Error.MalformedResponse,
    };

    var models = std.array_list.Managed(ModelDescriptor).init(allocator);
    errdefer {
        for (models.items) |model| model.deinit(allocator);
        models.deinit();
    }

    for (models_array.items) |entry| {
        const obj = switch (entry) {
            .object => |o| o,
            else => continue,
        };
        const slug_value = obj.get("slug") orelse continue;
        const slug = switch (slug_value) {
            .string => |s| s,
            else => continue,
        };
        if (slug.len == 0) continue;
        // codex-rs filters to visibility=="list": hidden or none entries
        // are not operator-selectable.
        if (obj.get("visibility")) |visibility| {
            if (visibility == .string and !std.mem.eql(u8, visibility.string, "list")) continue;
        }

        var context_window: ?u64 = null;
        if (obj.get("context_window")) |value| {
            switch (value) {
                .integer => |n| {
                    if (n > 0) context_window = @intCast(n);
                },
                .float => |n| {
                    if (n > 0) context_window = @intFromFloat(n);
                },
                else => {},
            }
        }

        const id = allocator.dupe(u8, slug) catch return Error.OutOfMemory;
        errdefer allocator.free(id);
        const owned_by = allocator.dupe(u8, provider_id) catch return Error.OutOfMemory;
        errdefer allocator.free(owned_by);
        const raw_json = std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"native_surface\":\"codex_backend\"}}", .{slug}) catch return Error.OutOfMemory;
        errdefer allocator.free(raw_json);
        models.append(.{
            .id = id,
            .owned_by = owned_by,
            .context_length = context_window,
            .raw_json = raw_json,
        }) catch return Error.OutOfMemory;
    }

    if (models.items.len == 0) return Error.MalformedResponse;

    return .{
        .provider_id = allocator.dupe(u8, provider_id) catch return Error.OutOfMemory,
        .base_url = allocator.dupe(u8, base_url) catch return Error.OutOfMemory,
        .models = models.toOwnedSlice() catch return Error.OutOfMemory,
        .context_from_native_surface = true,
    };
}

/// Map a VANTARI provider id onto its models.dev registry id. Family
/// aliases keep the snapshot tier answering for gateway credentials whose
/// registry entry is named differently.
fn snapshotRegistryId(provider_id: []const u8) []const u8 {
    if (std.mem.eql(u8, provider_id, "openai-codex")) return "openai";
    if (std.mem.eql(u8, provider_id, "opencode-go") or
        std.mem.eql(u8, provider_id, "opencode-zen") or
        std.mem.eql(u8, provider_id, "zai-coding-plan")) return "opencode";
    if (std.mem.eql(u8, provider_id, "lm-studio")) return "lmstudio";
    if (std.mem.eql(u8, provider_id, "google") or std.mem.eql(u8, provider_id, "gemini")) return "google";
    return provider_id;
}

/// Snapshot catalog for one provider: the vendored models.dev subset with
/// real context/output limits. Answers "what exists" when the gateway has
/// no live models endpoint or is unreachable.
pub fn snapshotModels(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    base_url: []const u8,
) Error!?ModelsList {
    const registry_id = snapshotRegistryId(provider_id);
    const snapshot_models = models_snapshot.listProviderModels(allocator, registry_id) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.MalformedResponse,
    };
    const listed = snapshot_models orelse return null;
    errdefer models_snapshot.freeModelList(allocator, listed);

    var descriptors = std.array_list.Managed(ModelDescriptor).init(allocator);
    errdefer {
        for (descriptors.items) |model| model.deinit(allocator);
        descriptors.deinit();
    }
    for (listed) |model| {
        const id = allocator.dupe(u8, model.id) catch return Error.OutOfMemory;
        errdefer allocator.free(id);
        const raw_json = std.fmt.allocPrint(
            allocator,
            "{{\"id\":\"{s}\",\"native_surface\":\"models_dev_snapshot\"}}",
            .{model.id},
        ) catch return Error.OutOfMemory;
        errdefer allocator.free(raw_json);
        const owned_by = allocator.dupe(u8, provider_id) catch return Error.OutOfMemory;
        errdefer allocator.free(owned_by);
        descriptors.append(.{
            .id = id,
            .owned_by = owned_by,
            .context_length = model.context,
            .raw_json = raw_json,
        }) catch return Error.OutOfMemory;
    }
    models_snapshot.freeModelList(allocator, listed);

    return .{
        .provider_id = allocator.dupe(u8, provider_id) catch return Error.OutOfMemory,
        .base_url = allocator.dupe(u8, base_url) catch return Error.OutOfMemory,
        .models = descriptors.toOwnedSlice() catch return Error.OutOfMemory,
        .context_from_native_surface = true,
    };
}

/// Enrich a live-discovered descriptor with snapshot context limits when
/// the gateway omitted them (LM Studio's OpenAI-compat surface has no
/// context_length; the snapshot supplies real values).
pub fn enrichFromSnapshot(allocator: std.mem.Allocator, provider_id: []const u8, models: []ModelDescriptor) void {
    const registry_id = snapshotRegistryId(provider_id);
    for (models) |*model| {
        if (model.context_length != null) continue;
        const snapshot_model = models_snapshot.lookup(allocator, registry_id, model.id) catch continue orelse continue;
        model.context_length = snapshot_model.context;
    }
}

/// ONE discovery entry point for the whole family. Precedence: live
/// endpoint per transport → vendored snapshot → configured-model catalog.
/// Every provider is the same shape here; callers never branch on provider
/// id to pick a discovery surface.
pub fn discoverModels(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    account_id: ?[]const u8,
    configured_auth_scheme: ?types.AuthScheme,
    configured_model: ?[]const u8,
) Error!ModelsList {
    const family = discoveryFamilyFor(provider_id, base_url);

    var live: ?ModelsList = switch (family) {
        .codex_backend => listCodexModels(allocator, base_url, api_key, account_id, provider_id) catch |err| blk: {
            if (err == Error.OutOfMemory) return err;
            break :blk null;
        },
        .anthropic, .openai_compatible => listModelsWithAuth(allocator, base_url, api_key, account_id, provider_id, configured_auth_scheme) catch |err| blk: {
            if (err == Error.OutOfMemory) return err;
            break :blk null;
        },
    };

    if (live) |*listed| {
        enrichFromSnapshot(allocator, provider_id, listed.models);
        return listed.*;
    }

    if (try snapshotModels(allocator, provider_id, base_url)) |snapshot_list| {
        return snapshot_list;
    }

    return nativeModels(allocator, provider_id, base_url, configured_model);
}

/// Last-resort catalog: the credential's configured model as one entry.
/// Reached only when both live discovery and the snapshot have nothing
/// for the provider (custom gateways, brand-new families).
pub fn nativeModels(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    base_url: []const u8,
    configured_model: ?[]const u8,
) Error!ModelsList {
    const model = if (configured_model) |value|
        (if (value.len > 0) value else provider_id)
    else
        provider_id;

    const id = allocator.dupe(u8, model) catch return Error.OutOfMemory;
    errdefer allocator.free(id);
    const owned_by = allocator.dupe(u8, provider_id) catch return Error.OutOfMemory;
    errdefer allocator.free(owned_by);
    const raw_json = std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"native_surface\":\"configured\"}}", .{model}) catch return Error.OutOfMemory;
    errdefer allocator.free(raw_json);
    const descriptors = allocator.alloc(ModelDescriptor, 1) catch return Error.OutOfMemory;
    errdefer allocator.free(descriptors);
    descriptors[0] = .{
        .id = id,
        .owned_by = owned_by,
        .context_length = null,
        .raw_json = raw_json,
    };

    return .{
        .provider_id = allocator.dupe(u8, provider_id) catch return Error.OutOfMemory,
        .base_url = allocator.dupe(u8, base_url) catch return Error.OutOfMemory,
        .models = descriptors,
        .context_from_native_surface = true,
    };
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

test "discovery family resolves codex backend and anthropic without provider lists" {
    try std.testing.expectEqual(DiscoveryFamily.codex_backend, discoveryFamilyFor("openai-codex", "https://chatgpt.com/backend-api"));
    try std.testing.expectEqual(DiscoveryFamily.anthropic, discoveryFamilyFor("anthropic", "https://api.anthropic.com"));
    try std.testing.expectEqual(DiscoveryFamily.openai_compatible, discoveryFamilyFor("zai", "https://api.z.ai/api/coding/paas/v4"));
    try std.testing.expectEqual(DiscoveryFamily.openai_compatible, discoveryFamilyFor("custom-gateway", "http://127.0.0.1:9000/v1"));
}

test "codex models parser filters visibility and maps slug to context window" {
    const body =
        \\{"models":[
        \\  {"slug":"gpt-5.4-mini","display_name":"GPT-5.4 Mini","context_window":400000,"visibility":"list"},
        \\  {"slug":"gpt-hidden","context_window":100000,"visibility":"hidden"},
        \\  {"slug":"gpt-5.3-codex","context_window":400000}
        \\]}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var listed = try parseCodexModelsData(allocator, body, "openai-codex", "https://chatgpt.com/backend-api");
    defer listed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), listed.models.len);
    try std.testing.expectEqualStrings("gpt-5.4-mini", listed.models[0].id);
    try std.testing.expectEqual(@as(u64, 400000), listed.models[0].context_length.?);
    // Missing visibility defaults to listable (codex-rs treats absent as list).
    try std.testing.expectEqualStrings("gpt-5.3-codex", listed.models[1].id);
}

test "discovery falls back to snapshot when live endpoint is unreachable" {
    // Unroutable base URL proves the live tier failed; the snapshot still
    // answers with real models and context windows for a vendored provider.
    var listed = try discoverModels(
        std.testing.allocator,
        "opencode",
        "http://127.0.0.1:1/v1",
        "unused-key",
        null,
        null,
        "opencode-go",
    );
    defer listed.deinit(std.testing.allocator);
    try std.testing.expect(listed.models.len > 1);
    try std.testing.expect(listed.context_from_native_surface);
    var found_configured = false;
    for (listed.models) |model| {
        if (model.context_length != null and model.context_length.? > 50_000) found_configured = true;
    }
    try std.testing.expect(found_configured);
}

test "discovery last resort returns configured model for unknown providers" {
    var listed = try discoverModels(
        std.testing.allocator,
        "private-gateway",
        "http://127.0.0.1:1/v1",
        "unused-key",
        null,
        null,
        "tenant/custom-model",
    );
    defer listed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), listed.models.len);
    try std.testing.expectEqualStrings("tenant/custom-model", listed.models[0].id);
}

const ParsedModelEntry = struct {
    id: ?[]const u8 = null,
    owned_by: ?[]const u8 = null,
    context_length: ?u64 = null,
};


test "last-resort catalog carries the configured model without network" {
    // Custom gateway: no live endpoint reachable, no snapshot entry — the
    // configured model becomes the single-entry catalog.
    var configured = try nativeModels(std.testing.allocator, "private-gateway", "http://127.0.0.1:1/v1", "tenant/custom-model");
    defer configured.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), configured.models.len);
    try std.testing.expectEqualStrings("tenant/custom-model", configured.models[0].id);
    try std.testing.expect(configured.context_from_native_surface);

    // Null configured model degrades to the provider id, never a fabricated id.
    var fallback = try nativeModels(std.testing.allocator, "brand-new-family", "https://gw.example/v1", null);
    defer fallback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("brand-new-family", fallback.models[0].id);
}

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

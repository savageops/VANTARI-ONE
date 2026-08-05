const std = @import("std");
const provider = @import("../providers/openai_compatible.zig");
const types = @import("../../shared/types.zig");
const auth = @import("../auth/store.zig");
const fsutil = @import("../../shared/fsutil.zig");

/// Embedding client for OpenAI-compatible /v1/embeddings endpoints. Reuses
/// the existing HTTP transport. When no embedding provider is configured,
/// the caller should use the TF-IDF fallback in `semantic.zig`.
pub const EmbeddingClient = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    transport: provider.Transport,

    /// Resolve an embedding client from the auth ledger. Looks for a provider
    /// with id `embeddings` first, then falls back to the active provider.
    /// Returns null if no provider is found or the endpoint is not configured.
    pub fn fromAuth(
        allocator: std.mem.Allocator,
        workspace_root: []const u8,
        embedding_provider_id: ?[]const u8,
        transport: provider.Transport,
    ) !?EmbeddingClient {
        const resolved = blk: {
            if (embedding_provider_id) |id| {
                if (try auth.readProviderById(allocator, workspace_root, id)) |p| break :blk p;
            }
            break :blk try auth.readActiveProvider(allocator, workspace_root);
        } orelse return null;
        defer allocator.free(resolved.base_url);
        defer allocator.free(resolved.api_key);
        defer allocator.free(resolved.model);

        return .{
            .base_url = try allocator.dupe(u8, resolved.base_url),
            .api_key = try allocator.dupe(u8, resolved.api_key),
            .model = try allocator.dupe(u8, resolved.model),
            .transport = transport,
        };
    }

    pub fn deinit(self: *EmbeddingClient, allocator: std.mem.Allocator) void {
        allocator.free(self.base_url);
        allocator.free(self.api_key);
        allocator.free(self.model);
    }

    /// Embed a batch of texts. Returns a slice of f32 slices (one per input).
    /// Each embedding vector has `dimensions` elements (provider-dependent,
    /// typically 768-1536). Caller owns all memory.
    pub fn embed(
        self: EmbeddingClient,
        allocator: std.mem.Allocator,
        texts: []const []const u8,
    ) ![][]f32 {
        if (texts.len == 0) return &.{};

        const url = try embeddingsUrl(allocator, self.base_url);
        defer allocator.free(url);

        // Build the request JSON: {"model":"...", "input":["text1","text2",...]}
        var payload = std.array_list.Managed(u8).init(allocator);
        defer payload.deinit();
        const writer = payload.writer();
        try writer.print("{{\"model\":\"{s}\",\"input\":[", .{self.model});
        for (texts, 0..) |text, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("\"");
            // Escape the text for JSON.
            for (text) |c| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    else => if (c < 0x20) {
                        try writer.print("\\u{x:0>4}", .{c});
                    } else {
                        try writer.writeByte(c);
                    },
                }
            }
            try writer.writeAll("\"");
        }
        try writer.writeAll("]}");

        const response_body = try self.transport.send(allocator, url, self.api_key, payload.items, .{});
        defer allocator.free(response_body);

        return try parseEmbeddingsResponse(allocator, response_body);
    }

    /// Embed a single text. Convenience wrapper.
    pub fn embedOne(
        self: EmbeddingClient,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) ![]f32 {
        const inputs = [_][]const u8{text};
        const results = try self.embed(allocator, &inputs);
        defer {
            // Free all but the first (there's only one).
            allocator.free(results);
        }
        return results[0];
    }
};

/// Parse the OpenAI-compatible embeddings response:
/// {"data":[{"embedding":[0.1,0.2,...],"index":0},...]}
fn parseEmbeddingsResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
) ![][]f32 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return Error.MalformedEmbeddingResponse;
    const data = root.object.get("data") orelse return Error.MalformedEmbeddingResponse;
    if (data != .array) return Error.MalformedEmbeddingResponse;

    var results = try allocator.alloc([]f32, data.array.items.len);
    errdefer {
        for (results) |r| if (r.len > 0) allocator.free(r);
        allocator.free(results);
    }

    for (data.array.items, 0..) |item, i| {
        if (item != .object) return Error.MalformedEmbeddingResponse;
        const embedding = item.object.get("embedding") orelse return Error.MalformedEmbeddingResponse;
        if (embedding != .array) return Error.MalformedEmbeddingResponse;

        const vec = try allocator.alloc(f32, embedding.array.items.len);
        results[i] = vec;

        for (embedding.array.items, 0..) |val, j| {
            vec[j] = switch (val) {
                .float => |f| @as(f32, @floatCast(f)),
                .integer => |n| @as(f32, @floatFromInt(n)),
                else => 0.0,
            };
        }
    }

    return results;
}

/// Build the embeddings URL from a base URL.
fn embeddingsUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    // The base_url may or may not have a trailing version segment.
    // OpenAI-compatible: base_url + "/embeddings"
    // If base_url ends with /v1, /v4, etc., append /embeddings.
    // If not, assume the base_url IS the versioned root and append /embeddings.
    if (std.mem.endsWith(u8, base_url, "/")) {
        return std.fmt.allocPrint(allocator, "{s}embeddings", .{base_url});
    }
    return std.fmt.allocPrint(allocator, "{s}/embeddings", .{base_url});
}

/// Compute cosine similarity between two equal-length vectors.
/// Returns 1.0 for identical vectors, 0.0 for orthogonal, -1.0 for opposite.
pub fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    if (a.len == 0 or a.len != b.len) return 0.0;

    var dot: f64 = 0.0;
    var norm_a: f64 = 0.0;
    var norm_b: f64 = 0.0;

    for (a, b) |va, vb| {
        const va_f: f64 = va;
        const vb_f: f64 = vb;
        dot += va_f * vb_f;
        norm_a += va_f * va_f;
        norm_b += vb_f * vb_f;
    }

    if (norm_a == 0.0 or norm_b == 0.0) return 0.0;
    const denom = @sqrt(norm_a) * @sqrt(norm_b);
    if (denom == 0.0) return 0.0;

    return @as(f32, @floatCast(dot / denom));
}

pub const Error = error{
    MalformedEmbeddingResponse,
};

// ============================================================================
// Tests
// ============================================================================

test "cosineSimilarity returns 1.0 for identical vectors" {
    const a = [_]f32{ 1.0, 0.5, 0.3, 0.8 };
    const sim = cosineSimilarity(&a, &a);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sim, 0.001);
}

test "cosineSimilarity returns 0.0 for orthogonal vectors" {
    const a = [_]f32{ 1.0, 0.0 };
    const b = [_]f32{ 0.0, 1.0 };
    const sim = cosineSimilarity(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sim, 0.001);
}

test "cosineSimilarity handles empty and mismatched vectors" {
    const empty = [_]f32{};
    const a = [_]f32{ 1.0, 2.0 };
    try std.testing.expectEqual(@as(f32, 0.0), cosineSimilarity(&empty, &empty));
    try std.testing.expectEqual(@as(f32, 0.0), cosineSimilarity(&a, &empty));
}

test "parseEmbeddingsResponse extracts float vectors" {
    const body =
        \\{"data":[{"embedding":[0.1,0.2,0.3],"index":0},{"embedding":[0.4,0.5,0.6],"index":1}]}
    ;
    const result = try parseEmbeddingsResponse(std.testing.allocator, body);
    defer {
        for (result) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(usize, 3), result[0].len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), result[0][0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), result[1][2], 0.001);
}

test "embeddingsUrl appends /embeddings correctly" {
    const url1 = try embeddingsUrl(std.testing.allocator, "https://api.example.com/v1");
    defer std.testing.allocator.free(url1);
    try std.testing.expectEqualStrings("https://api.example.com/v1/embeddings", url1);

    const url2 = try embeddingsUrl(std.testing.allocator, "http://127.0.0.1:1234/");
    defer std.testing.allocator.free(url2);
    try std.testing.expectEqualStrings("http://127.0.0.1:1234/embeddings", url2);
}

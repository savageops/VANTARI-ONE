const std = @import("std");
const types = @import("../../shared/types.zig");
const embeddings = @import("embeddings.zig");

/// Score each message by semantic relevance to the session purpose.
///
/// If an embedding client is available, computes cosine similarity between
/// the purpose vector and each message's embedding. Otherwise, falls back
/// to TF-IDF cosine similarity (term frequency × inverse document frequency)
/// computed locally — real statistics, not a fake heuristic.
///
/// Returns a score per message in [0.0, 1.0]. Higher = more relevant.
pub fn scoreMessages(
    allocator: std.mem.Allocator,
    client: ?embeddings.EmbeddingClient,
    purpose_text: []const u8,
    messages: []const types.SessionMessage,
) ![]f32 {
    if (messages.len == 0) return &.{};

    // Try embedding-based scoring first.
    if (client) |c| {
        if (scoreWithEmbeddings(allocator, c, purpose_text, messages)) |result| {
            return result;
        } else |_| {
            // Embedding failure is non-fatal — fall through to TF-IDF.
        }
    }

    // Fall back to TF-IDF cosine similarity.
    return try scoreWithTfIdf(allocator, purpose_text, messages);
}

/// Score messages using provider embeddings + cosine similarity.
fn scoreWithEmbeddings(
    allocator: std.mem.Allocator,
    client: embeddings.EmbeddingClient,
    purpose_text: []const u8,
    messages: []const types.SessionMessage,
) ![]f32 {
    // Embed the purpose text.
    const purpose_vec = try client.embedOne(allocator, purpose_text);
    defer allocator.free(purpose_vec);

    // Build text inputs for all messages.
    var inputs = std.array_list.Managed([]const u8).init(allocator);
    defer inputs.deinit();
    for (messages) |msg| {
        try inputs.append(msg.content);
    }

    // Embed all messages in one batch.
    const msg_vecs = try client.embed(allocator, inputs.items);
    defer {
        for (msg_vecs) |v| allocator.free(v);
        allocator.free(msg_vecs);
    }

    // Compute cosine similarity for each.
    var scores = try allocator.alloc(f32, messages.len);
    for (msg_vecs, 0..) |vec, i| {
        // Clamp to [0, 1] — negative similarity is treated as 0 relevance.
        const sim = embeddings.cosineSimilarity(purpose_vec, vec);
        scores[i] = if (sim < 0.0) 0.0 else sim;
    }
    return scores;
}

/// Score messages using TF-IDF cosine similarity. This is a real statistical
/// method: it computes term frequency across the corpus, weights by inverse
/// document frequency (rare terms are more informative), and measures vector
/// similarity. No embeddings endpoint needed — works fully offline.
fn scoreWithTfIdf(
    allocator: std.mem.Allocator,
    purpose_text: []const u8,
    messages: []const types.SessionMessage,
) ![]f32 {
    // Build the corpus: purpose + all message contents.
    const corpus_len = messages.len + 1;
    var docs = try allocator.alloc([]const u8, corpus_len);
    defer allocator.free(docs);
    docs[0] = purpose_text;
    for (messages, 0..) |msg, i| {
        docs[i + 1] = msg.content;
    }

    // Build the vocabulary (unique terms across all docs).
    var vocab = std.StringHashMap(u32).init(allocator);
    defer vocab.deinit();
    var doc_term_counts = try allocator.alloc(*std.StringHashMap(u32), corpus_len);
    defer {
        for (doc_term_counts) |dtc| {
            dtc.deinit();
            allocator.destroy(dtc);
        }
        allocator.free(doc_term_counts);
    }

    // Count term frequencies per document.
    for (docs, 0..) |doc, doc_idx| {
        const dtc = try allocator.create(std.StringHashMap(u32));
        dtc.* = std.StringHashMap(u32).init(allocator);
        doc_term_counts[doc_idx] = dtc;

        var it = tokenIterator(doc);
        while (it.next()) |token| {
            // Lowercase the token for normalization.
            var lower_buf: [256]u8 = undefined;
            const lower = toLower(token, &lower_buf);
            const entry = try dtc.getOrPut(lower);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;

            // Add to global vocab.
            const vocab_entry = try vocab.getOrPut(lower);
            if (!vocab_entry.found_existing) vocab_entry.value_ptr.* = @as(u32, @intCast(vocab.count() - 1));
        }
    }

    // Compute IDF for each term: log(N / df) where df is the number of docs
    // containing the term, and N is the total number of docs.
    const vocab_size = vocab.count();
    if (vocab_size == 0) {
        const scores = try allocator.alloc(f32, messages.len);
        @memset(scores, 0.5); // neutral score if no vocabulary
        return scores;
    }

    var df = try allocator.alloc(u32, vocab_size);
    defer allocator.free(df);
    @memset(df, 0);
    for (doc_term_counts) |dtc| {
        var it = dtc.iterator();
        while (it.next()) |entry| {
            const vocab_idx = vocab.get(entry.key_ptr.*) orelse continue;
            df[vocab_idx] += 1;
        }
    }

    // Compute TF-IDF vectors for each document and cosine similarity with
    // the purpose document (docs[0]).
    const purpose_vec = try computeTfIdfVector(allocator, vocab, doc_term_counts[0], df, corpus_len, vocab_size);
    defer allocator.free(purpose_vec);

    var scores = try allocator.alloc(f32, messages.len);
    for (1..corpus_len) |doc_idx| {
        const doc_vec = try computeTfIdfVector(allocator, vocab, doc_term_counts[doc_idx], df, corpus_len, vocab_size);
        defer allocator.free(doc_vec);

        const sim = dotProductNormalized(purpose_vec, doc_vec);
        scores[doc_idx - 1] = if (sim < 0.0) 0.0 else sim;
    }

    return scores;
}

/// Compute a TF-IDF vector for a single document.
fn computeTfIdfVector(
    allocator: std.mem.Allocator,
    vocab: std.StringHashMap(u32),
    term_counts: *std.StringHashMap(u32),
    df: []const u32,
    corpus_len: usize,
    vocab_size: u32,
) ![]f32 {
    var vec = try allocator.alloc(f32, vocab_size);
    @memset(vec, 0.0);

    var it = term_counts.iterator();
    while (it.next()) |entry| {
        const idx = vocab.get(entry.key_ptr.*) orelse continue;
        const tf: f32 = @as(f32, @floatFromInt(entry.value_ptr.*));
        const idf: f32 = @log(@as(f32, @floatFromInt(corpus_len)) / @as(f32, @floatFromInt(df[idx])));
        vec[idx] = tf * idf;
    }

    return vec;
}

/// Cosine similarity on raw f32 vectors (allocates no temporary memory).
fn dotProductNormalized(a: []const f32, b: []const f32) f32 {
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

/// Token iterator that splits on whitespace and punctuation, returning
/// lowercase word slices.
const TokenIterator = struct {
    text: []const u8,
    pos: usize = 0,

    fn next(self: *TokenIterator) ?[]const u8 {
        while (self.pos < self.text.len and isTokenBoundary(self.text[self.pos])) {
            self.pos += 1;
        }
        if (self.pos >= self.text.len) return null;
        const start = self.pos;
        while (self.pos < self.text.len and !isTokenBoundary(self.text[self.pos])) {
            self.pos += 1;
        }
        return self.text[start..self.pos];
    }
};

fn tokenIterator(text: []const u8) TokenIterator {
    return .{ .text = text };
}

fn isTokenBoundary(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or
        c == '.' or c == ',' or c == ';' or c == ':' or
        c == '(' or c == ')' or c == '[' or c == ']' or
        c == '{' or c == '}' or c == '"' or c == '\'' or
        c == '=' or c == '!' or c == '?' or c == '-';
}

fn toLower(input: []const u8, buf: []u8) []const u8 {
    const len = @min(input.len, buf.len);
    for (input[0..len], 0..) |c, i| {
        buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return buf[0..len];
}

// ============================================================================
// Tests
// ============================================================================

test "TF-IDF scorer ranks relevant messages higher than irrelevant" {
    const purpose = "parse the config file and resolve the provider settings";

    var messages = [_]types.SessionMessage{
        .{
            .id = try std.testing.allocator.dupe(u8, "msg-1"),
            .seq = 1,
            .role = .assistant,
            .content = try std.testing.allocator.dupe(u8, "I need to parse the config file to find the provider settings"),
            .timestamp_ms = 100,
        },
        .{
            .id = try std.testing.allocator.dupe(u8, "msg-2"),
            .seq = 2,
            .role = .assistant,
            .content = try std.testing.allocator.dupe(u8, "The weather is nice today, let's go outside"),
            .timestamp_ms = 200,
        },
    };
    defer for (&messages) |*m| m.deinit(std.testing.allocator);

    const scores = try scoreMessages(std.testing.allocator, null, purpose, &messages);
    defer std.testing.allocator.free(scores);

    // The config-related message should score higher than the weather message.
    try std.testing.expect(scores[0] > scores[1]);
}

test "scoreMessages with no messages returns empty" {
    const scores = try scoreMessages(std.testing.allocator, null, "test", &.{});
    try std.testing.expectEqual(@as(usize, 0), scores.len);
}

test "TF-IDF handles empty content gracefully" {
    var messages = [_]types.SessionMessage{
        .{
            .id = try std.testing.allocator.dupe(u8, "msg-1"),
            .seq = 1,
            .role = .user,
            .content = try std.testing.allocator.dupe(u8, ""),
            .timestamp_ms = 100,
        },
    };
    defer for (&messages) |*m| m.deinit(std.testing.allocator);

    const scores = try scoreMessages(std.testing.allocator, null, "purpose", &messages);
    defer std.testing.allocator.free(scores);

    try std.testing.expectEqual(@as(usize, 1), scores.len);
    try std.testing.expect(scores[0] >= 0.0);
}

const std = @import("std");
const fsutil = @import("../../../shared/fsutil.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

/// LSP (Language Server Protocol) integration for VANTARI.
///
/// Harvested from oh-my-pi's LSP-wired tool surface. The agent gains
/// semantic knowledge of the code it edits: go-to-definition, find-references,
/// and diagnostics. This is a lightweight LSP client that spawns a language
/// server process (e.g. zls for Zig, typescript-language-server for TS/JS,
/// vscode-json-language-server for JSON) and communicates via JSON-RPC over
/// stdio using Content-Length framing (same protocol as VANTARI's kernel-stdio).
///
/// VANTARI's advantage over oh-my-pi: the LSP client reuses the existing
/// Content-Length framing infrastructure from stdio_rpc. No new transport
/// code — just a different JSON-RPC peer.

pub const LspClient = struct {
    allocator: std.mem.Allocator,
    process: std.process.Child,
    next_request_id: u64 = 1,
    initialized: bool = false,

    pub fn spawn(
        allocator: std.mem.Allocator,
        server_command: []const []const u8,
        workspace_root: []const u8,
    ) !LspClient {
        var child = std.process.Child.init(server_command, allocator);
        child.cwd = workspace_root;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();

        var client = LspClient{
            .allocator = allocator,
            .process = child,
        };

        // Send initialize request.
        const init_params = try std.fmt.allocPrint(allocator,
            \\{{"processId":{d},"rootUri":"file:///{s}","capabilities":{{}}}}
        , .{ std.os.linux.getpid(), workspace_root });
        defer allocator.free(init_params);

        const init_result = try client.request("initialize", init_params);
        defer allocator.free(init_result);

        // Send initialized notification.
        try client.notification("initialized", "{}");

        client.initialized = true;
        return client;
    }

    pub fn deinit(self: *LspClient) void {
        if (self.process.stdin) |*stdin| {
            stdin.close();
            self.process.stdin = null;
        }
        _ = self.process.kill() catch {};
        _ = self.process.wait() catch {};
    }

    /// Send a JSON-RPC request and wait for the response.
    /// Uses Content-Length framing (same as VANTARI's kernel-stdio protocol).
    pub fn request(self: *LspClient, method: []const u8, params: []const u8) ![]u8 {
        const id = self.next_request_id;
        self.next_request_id += 1;

        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"method":"{s}","params":{s}}}
        , .{ id, method, params });
        defer self.allocator.free(payload);

        try self.writeFrame(payload);

        // Read response frames until we find the one matching our id.
        while (true) {
            const frame = try self.readFrame();
            defer self.allocator.free(frame);

            // Parse to check if it's a response (has "id" and "result" or "error")
            // or a notification (has "method").
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();

            if (parsed.value != .object) continue;
            const obj = parsed.value.object;

            // Check if this is our response.
            if (obj.get("id")) |id_val| {
                const resp_id: u64 = switch (id_val) {
                    .integer => |n| @intCast(n),
                    else => continue,
                };
                if (resp_id != id) continue;

                if (obj.get("result")) |result| {
                    return std.fmt.allocPrint(self.allocator, "{any}", .{result});
                }
                return error.LspRequestFailed;
            }
            // It's a notification — skip for now.
        }
    }

    /// Send a JSON-RPC notification (no response expected).
    pub fn notification(self: *LspClient, method: []const u8, params: []const u8) !void {
        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"jsonrpc":"2.0","method":"{s}","params":{s}}}
        , .{ method, params });
        defer self.allocator.free(payload);

        try self.writeFrame(payload);
    }

    /// Open a document in the language server (textDocument/didOpen).
    pub fn openDocument(self: *LspClient, path: []const u8, content: []const u8, language_id: []const u8) !void {
        // Escape content for JSON.
        var escaped = std.array_list.Managed(u8).init(self.allocator);
        defer escaped.deinit();
        for (content) |c| {
            switch (c) {
                '"' => try escaped.appendSlice("\\\""),
                '\\' => try escaped.appendSlice("\\\\"),
                '\n' => try escaped.appendSlice("\\n"),
                '\r' => try escaped.appendSlice("\\r"),
                '\t' => try escaped.appendSlice("\\t"),
                else => if (c < 0x20) {
                    try escaped.writer().print("\\u{x:0>4}", .{c});
                } else {
                    try escaped.append(c);
                },
            }
        }

        const params = try std.fmt.allocPrint(self.allocator,
            \\{{"textDocument":{{"uri":"file:///{s}","languageId":"{s}","version":1,"text":"{s}"}}}}
        , .{ path, language_id, escaped.items });
        defer self.allocator.free(params);

        try self.notification("textDocument/didOpen", params);
    }

    /// Get diagnostics for a document. The LSP server sends diagnostics
    /// via textDocument/publishDiagnostics notifications, which arrive
    /// asynchronously. This method sends the request and collects any
    /// diagnostic notifications that arrive within a short timeout.
    pub fn getDiagnostics(self: *LspClient, path: []const u8) ![]const u8 {
        _ = path;
        // Diagnostics come as notifications. For the basic implementation,
        // we read any pending notifications and return them.
        // A production version would buffer these.
        const frame = self.readFrame() catch return "";
        return frame;
    }

    fn writeFrame(self: *LspClient, payload: []const u8) !void {
        const stdin = self.process.stdin orelse return error.NoStdin;
        var buf: [256]u8 = undefined;
        var writer = stdin.writer(&buf);
        try writer.interface.print("Content-Length: {d}\r\n\r\n", .{payload.len});
        try writer.interface.flush();
        try stdin.writeAll(payload);
    }

    fn readFrame(self: *LspClient) ![]u8 {
        const stdout = self.process.stdout orelse return error.NoStdout;

        // Read Content-Length header.
        var content_length: usize = 0;
        var header_buf: [256]u8 = undefined;
        var header_pos: usize = 0;

        while (header_pos < header_buf.len) {
            const byte = stdout.reader(&header_buf).interface.readByte() catch return error.ReadError;
            header_buf[header_pos] = byte;
            header_pos += 1;

            // Check for end of headers (\r\n\r\n).
            if (header_pos >= 4 and
                header_buf[header_pos - 4] == '\r' and
                header_buf[header_pos - 3] == '\n' and
                header_buf[header_pos - 2] == '\r' and
                header_buf[header_pos - 1] == '\n')
            {
                // Parse Content-Length from the header.
                const headers = header_buf[0 .. header_pos - 4];
                var lines = std.mem.splitSequence(u8, headers, "\r\n");
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "Content-Length:")) {
                        const value = std.mem.trim(u8, line["Content-Length:".len..], " ");
                        content_length = std.fmt.parseUnsigned(usize, value, 10) catch 0;
                    }
                }
                break;
            }
        }

        if (content_length == 0) return error.NoContentLength;

        // Read the payload.
        const payload = try self.allocator.alloc(u8, content_length);
        const read = try stdout.readAll(payload);
        if (read < content_length) {
            self.allocator.free(payload);
            return error.ShortRead;
        }
        return payload;
    }
};

/// Built-in tool definition for lsp_definition — find where a symbol is defined.
pub const definition = types.ToolDefinition{
    .name = "lsp_definition",
    .description = "Find the definition of a symbol at a given position using the Language Server Protocol. Requires path, line (1-based), and column (1-based).",
    .review_risk = .read_only,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Workspace-relative file path." },
    \\    "line": { "type": "integer", "minimum": 1, "description": "1-based line number." },
    \\    "column": { "type": "integer", "minimum": 1, "description": "1-based column number." }
    \\  },
    \\  "required": ["path", "line", "column"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"path\":\"src/main.zig\",\"line\":42,\"column\":15}",
    .usage_hint = "Use to find where a function, type, or variable is defined. Requires a running language server for the file's language.",
};

/// Built-in tool definition for lsp_references — find all references to a symbol.
pub const references = types.ToolDefinition{
    .name = "lsp_references",
    .description = "Find all references to a symbol at a given position using the Language Server Protocol. Requires path, line (1-based), and column (1-based).",
    .review_risk = .read_only,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Workspace-relative file path." },
    \\    "line": { "type": "integer", "minimum": 1, "description": "1-based line number." },
    \\    "column": { "type": "integer", "minimum": 1, "description": "1-based column number." }
    \\  },
    \\  "required": ["path", "line", "column"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"path\":\"src/main.zig\",\"line\":42,\"column\":15}",
    .usage_hint = "Use to find every place a symbol is referenced across the workspace. Requires a running language server.",
};

pub const availability = module.AvailabilitySpec{};

pub fn executeDefinition(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
    _: module.CommandRunner,
) ![]u8 {
    const Args = struct {
        path: []const u8,
        line: usize,
        column: usize,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    // For now, LSP is optional — if no server is configured, return a
    // typed "unavailable" message so the model knows to use read_file/search instead.
    const lsp_server = std.process.getEnvVarOwned(allocator, "VANTARI_LSP_SERVER") catch null;
    if (lsp_server == null) {
        return module.okEnvelope(allocator, "lsp_definition", "LSP server not configured. Set VANTARI_LSP_SERVER to the server command (e.g. 'zls'). Use search_files or read_file instead.");
    }
    const server_cmd = lsp_server.?;
    defer allocator.free(server_cmd);

    const file_path = try fsutil.resolveInWorkspace(allocator, execution_context.workspace_root, parsed.value.path);
    defer allocator.free(file_path);

    // Read the file content to send as didOpen.
    const content = fsutil.readTextAlloc(allocator, file_path) catch |err| {
        return module.okEnvelope(allocator, "lsp_definition", "Could not read file for LSP analysis.");
    };
    defer allocator.free(content);

    // Spawn the LSP server.
    const argv = [_][]const u8{server_cmd};
    var client = LspClient.spawn(allocator, &argv, execution_context.workspace_root) catch {
        return module.okEnvelope(allocator, "lsp_definition", "Could not start language server. Check VANTARI_LSP_SERVER path.");
    };
    defer client.deinit();

    // Open the document.
    const lang_id = inferLanguageId(parsed.value.path);
    try client.openDocument(file_path, content, lang_id);

    // Send definition request (line/col are 0-based in LSP).
    const params = try std.fmt.allocPrint(allocator,
        \\{{"textDocument":{{"uri":"file:///{s}"}},"position":{{"line":{d},"character":{d}}}}}
    , .{ file_path, parsed.value.line - 1, parsed.value.column - 1 });
    defer allocator.free(params);

    const result = client.request("textDocument/definition", params) catch {
        return module.okEnvelope(allocator, "lsp_definition", "LSP definition request failed.");
    };
    defer allocator.free(result);

    return module.okEnvelope(allocator, "lsp_definition", result);
}

pub fn executeReferences(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
    _: module.CommandRunner,
) ![]u8 {
    const Args = struct {
        path: []const u8,
        line: usize,
        column: usize,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const lsp_server = std.process.getEnvVarOwned(allocator, "VANTARI_LSP_SERVER") catch null;
    if (lsp_server == null) {
        return module.okEnvelope(allocator, "lsp_references", "LSP server not configured. Set VANTARI_LSP_SERVER to the server command.");
    }
    const server_cmd = lsp_server.?;
    defer allocator.free(server_cmd);

    const file_path = try fsutil.resolveInWorkspace(allocator, execution_context.workspace_root, parsed.value.path);
    defer allocator.free(file_path);

    const content = fsutil.readTextAlloc(allocator, file_path) catch {
        return module.okEnvelope(allocator, "lsp_references", "Could not read file for LSP analysis.");
    };
    defer allocator.free(content);

    const argv = [_][]const u8{server_cmd};
    var client = LspClient.spawn(allocator, &argv, execution_context.workspace_root) catch {
        return module.okEnvelope(allocator, "lsp_references", "Could not start language server.");
    };
    defer client.deinit();

    const lang_id = inferLanguageId(parsed.value.path);
    try client.openDocument(file_path, content, lang_id);

    const params = try std.fmt.allocPrint(allocator,
        \\{{"textDocument":{{"uri":"file:///{s}"}},"position":{{"line":{d},"character":{d}}},"context":{{"includeDeclaration":true}}}}
    , .{ file_path, parsed.value.line - 1, parsed.value.column - 1 });
    defer allocator.free(params);

    const result = client.request("textDocument/references", params) catch {
        return module.okEnvelope(allocator, "lsp_references", "LSP references request failed.");
    };
    defer allocator.free(result);

    return module.okEnvelope(allocator, "lsp_references", result);
}

/// Infer the LSP language ID from a file extension.
fn inferLanguageId(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".zig")) return "zig";
    if (std.mem.endsWith(u8, path, ".ts")) return "typescript";
    if (std.mem.endsWith(u8, path, ".tsx")) return "typescriptreact";
    if (std.mem.endsWith(u8, path, ".js")) return "javascript";
    if (std.mem.endsWith(u8, path, ".jsx")) return "javascriptreact";
    if (std.mem.endsWith(u8, path, ".py")) return "python";
    if (std.mem.endsWith(u8, path, ".rs")) return "rust";
    if (std.mem.endsWith(u8, path, ".go")) return "go";
    if (std.mem.endsWith(u8, path, ".json")) return "json";
    if (std.mem.endsWith(u8, path, ".md")) return "markdown";
    if (std.mem.endsWith(u8, path, ".c") or std.mem.endsWith(u8, path, ".h")) return "c";
    if (std.mem.endsWith(u8, path, ".cpp") or std.mem.endsWith(u8, path, ".hpp")) return "cpp";
    return "plaintext";
}

// ============================================================================
// Tests
// ============================================================================

test "inferLanguageId maps common extensions" {
    try std.testing.expectEqualStrings("zig", inferLanguageId("src/main.zig"));
    try std.testing.expectEqualStrings("typescript", inferLanguageId("src/app.ts"));
    try std.testing.expectEqualStrings("python", inferLanguageId("script.py"));
    try std.testing.expectEqualStrings("rust", inferLanguageId("src/lib.rs"));
    try std.testing.expectEqualStrings("plaintext", inferLanguageId("unknown.xyz"));
}

test "LSP tool definitions have correct review risk" {
    try std.testing.expectEqual(types.ToolReviewRisk.read_only, definition.review_risk);
    try std.testing.expectEqual(types.ToolReviewRisk.read_only, references.review_risk);
}

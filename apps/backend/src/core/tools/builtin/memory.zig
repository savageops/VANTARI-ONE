const std = @import("std");
const memory = @import("../../memory/store.zig");
const module = @import("../module.zig");
const types = @import("../../../shared/types.zig");

pub const definitions = [_]types.ToolDefinition{
    .{
        .name = "memory_read",
        .description = "Recall active session-only and/or global VANTARI memories with bounded relevance filtering and source evidence.",
        .review_risk = .read_only,
        .parameters_json =
        \\{"type":"object","properties":{"scope":{"type":"string","enum":["session","global","all"]},"query":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":100}},"additionalProperties":false}
        ,
        .example_json = "{\"scope\":\"all\",\"query\":\"memory architecture\",\"limit\":20}",
        .usage_hint = "Session memory is visible only to the current session. Global memory follows across workspaces. Read before relying on remembered facts that may have changed.",
    },
    .{
        .name = "memory_write",
        .description = "Remember, update, or forget one compact topic in session-only or global VANTARI memory. Reusing a topic supersedes its previous value without rewriting history.",
        .review_risk = .write_capable,
        .parameters_json =
        \\{"type":"object","properties":{"operation":{"type":"string","enum":["remember","forget"]},"scope":{"type":"string","enum":["session","global"]},"kind":{"type":"string","enum":["fact","decision","preference","invariant","lesson"]},"topic":{"type":"string"},"content":{"type":"string"},"trigger":{"type":"string","enum":["user_requested","agent_decided"]},"activation":{"type":"string","enum":["always","relevant"]}},"required":["operation","scope","topic","trigger"],"additionalProperties":false}
        ,
        .example_json = "{\"operation\":\"remember\",\"scope\":\"session\",\"kind\":\"decision\",\"topic\":\"memory-owner\",\"content\":\"The memory store is owned by core/memory.\",\"trigger\":\"agent_decided\",\"activation\":\"relevant\"}",
        .usage_hint = "Default uncertain or task-local knowledge to session. Use global only for genuinely cross-workspace preferences or lessons. Never store secrets, raw transcripts, guesses, or facts that should be read from live code.",
    },
};

const Args = struct {
    operation: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    topic: ?[]const u8 = null,
    content: ?[]const u8 = null,
    trigger: ?[]const u8 = null,
    activation: ?[]const u8 = null,
    query: ?[]const u8 = null,
    limit: ?usize = null,
};

pub fn handles(name: []const u8) bool { for (definitions) |definition| if (std.mem.eql(u8, name, definition.name)) return true; return false; }

pub fn execute(allocator: std.mem.Allocator, execution_context: module.ExecutionContext, name: []const u8, arguments_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    const args = parsed.value;
    if (std.mem.eql(u8, name, "memory_read")) {
        const scope = args.scope orelse "all";
        const include_session = std.mem.eql(u8, scope, "session") or std.mem.eql(u8, scope, "all");
        const include_global = std.mem.eql(u8, scope, "global") or std.mem.eql(u8, scope, "all");
        if (!include_session and !include_global) return module.Error.InvalidArguments;
        return memory.renderContext(
            allocator,
            execution_context.workspace_root,
            if (include_session) execution_context.parent_session_id else null,
            args.query orelse "",
            if (include_session) 16 * 1024 else 0,
            if (include_global) 16 * 1024 else 0,
            args.limit orelse 20,
        );
    }
    if (std.mem.eql(u8, name, "memory_write")) {
        if (!execution_context.memory_policy.agent_writes_enabled) return module.Error.MemoryWritesDisabled;
        const operation = try memory.parseOperation(args.operation orelse return module.Error.InvalidArguments);
        const scope = try memory.parseScope(args.scope orelse return module.Error.InvalidArguments);
        return memory.append(allocator, execution_context.workspace_root, .{
            .scope = scope,
            .operation = operation,
            .kind = try memory.parseKind(args.kind orelse "fact"),
            .topic = args.topic orelse return module.Error.InvalidArguments,
            .content = args.content orelse "",
            .trigger = try memory.parseTrigger(args.trigger orelse return module.Error.InvalidArguments),
            .activation = try memory.parseActivation(args.activation orelse "relevant"),
            .session_id = execution_context.parent_session_id,
            .max_entry_bytes = execution_context.memory_policy.max_entry_bytes,
        });
    }
    return module.Error.UnknownTool;
}

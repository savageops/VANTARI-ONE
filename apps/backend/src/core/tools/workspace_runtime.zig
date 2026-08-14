const builtin = @import("builtin");
const std = @import("std");
const fsutil = @import("../../shared/fsutil.zig");
const types = @import("../../shared/types.zig");

pub const definitions = [_]types.ToolDefinition{
    .{
        .name = "init_workspace",
        .description = "Scaffold the canonical .var structure for the current workspace without overwriting existing populated files unless explicitly forced.",
        .review_risk = .write_capable,
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "force_overwrite": { "type": "boolean", "description": "When true, overwrite the scaffold files owned by init_workspace." }
        \\  },
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{\"force_overwrite\":false}",
        .usage_hint = "Call only when canonical .var scaffolding is missing or explicitly requested. Omit force_overwrite unless replacement is intentional.",
    },
    .{
        .name = "changelog_ledger",
        .description = "Read or append the canonical .var changelog log for ticket-linked completion evidence.",
        .review_risk = .write_capable,
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "action": { "type": "string", "enum": ["read", "append"] },
        \\    "content": { "type": "string", "description": "Markdown to append when action is append." },
        \\  },
        \\  "required": ["action"],
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{\"action\":\"append\",\"content\":\"- Completed prompt-layer validation.\\n\"}",
    },
    .{
        .name = "docs_artifact",
        .description = "Read or write canonical runtime contract docs under .var/docs/.",
        .review_risk = .write_capable,
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "action": { "type": "string", "enum": ["read", "write"] },
        \\    "path": { "type": "string", "description": "Path relative to .var/docs/." },
        \\    "content": { "type": "string", "description": "Markdown body to write when action is write." }
        \\  },
        \\  "required": ["action", "path"],
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{\"action\":\"write\",\"path\":\"runtime/prompt-contract.md\",\"content\":\"# Prompt Contract\\n\"}",
        .usage_hint = "Path is relative to .var/docs. Use for current runtime contract docs only, not aspirational future claims.",
    },
    .{
        .name = "knowledge_artifact",
        .description = "Read, write, or list durable knowledge artifacts across the canonical .var surfaces: research, plans, advice, roadmap. Subagents persist findings here so the orchestrator holds only the artifact index, not full payloads.",
        .review_risk = .write_capable,
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "action": { "type": "string", "enum": ["read", "write", "list"] },
        \\    "surface": { "type": "string", "enum": ["research", "plans", "advice", "roadmap"], "description": "Knowledge surface under .var/." },
        \\    "path": { "type": "string", "description": "Path relative to .var/<surface>/. Required for read and write; ignored for list." },
        \\    "title": { "type": "string", "description": "Optional markdown heading prepended when action is write and content has no heading." },
        \\    "content": { "type": "string", "description": "Markdown body to write when action is write." }
        \\  },
        \\  "required": ["action", "surface"],
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{\"action\":\"write\",\"surface\":\"research\",\"path\":\"oh-my-pi-never-wait.md\",\"title\":\"oh-my-pi Never-Wait Mechanics\",\"content\":\"The yield-queue injects results as a new turn...\"}",
        .usage_hint = "Every subagent that discovers findings MUST persist them to the matching surface before returning its SITREP. Research/DOM/scrape → research. Implementation plans → plans. Advisor SITREPs → advice. Roadmap decisions → roadmap. Use list to inventory artifacts without reading full payloads.",
    },
    .{
        .name = "git_worktree",
        .description = "Inspect or manage Git worktrees rooted under .var/worktrees/ when the workspace is a real Git checkout.",
        .review_risk = .write_capable,
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "action": { "type": "string", "enum": ["status", "list", "add", "remove", "lock", "prune"] },
        \\    "name": { "type": "string", "description": "Worktree directory name under .var/worktrees/ for add, remove, or lock." },
        \\    "ref": { "type": "string", "description": "Optional Git ref for add." },
        \\    "force": { "type": "boolean", "description": "Force remove when action is remove." },
        \\    "reason": { "type": "string", "description": "Optional lock reason when action is lock." }
        \\  },
        \\  "required": ["action"],
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{\"action\":\"status\"}",
        .usage_hint = "Use status/list before add/remove. Worktree names are directory names under .var/worktrees and must stay project-local.",
    },
    .{
        .name = "workspace_backup",
        .description = "Create a timestamped workspace backup archive under .var/backup/.",
        .review_risk = .write_capable,
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "label": { "type": "string", "description": "Optional suffix to include in the backup filename." }
        \\  },
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{\"label\":\"before-prompt-edit\"}",
        .usage_hint = "Use before broad or risky workspace edits. The label is optional and becomes part of the backup filename.",
    },
    .{
        .name = "instruction_ingestion",
        .description = "Discover applicable AGENTS.md instructions within the workspace according to the canonical ingestion modes.",
        .review_risk = .read_only,
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "mode": { "type": "string", "enum": ["session-start", "on-demand-subtree", "always", "never"] },
        \\    "target_path": { "type": "string", "description": "Optional path inside the workspace whose instruction context should be resolved." }
        \\  },
        \\  "required": ["mode"],
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{\"mode\":\"session-start\"}",
        .usage_hint = "Use session-start for baseline instruction discovery or on-demand-subtree with target_path for a specific workspace subtree.",
    },
};

pub fn handles(tool_name: []const u8) bool {
    for (definitions) |definition| {
        if (std.mem.eql(u8, definition.name, tool_name)) return true;
    }
    return false;
}

pub fn execute(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
    runner: anytype,
) ![]u8 {
    if (std.mem.eql(u8, tool_name, "init_workspace")) {
        return executeInitWorkspace(allocator, workspace_root, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "changelog_ledger")) {
        return executeChangelogLedger(allocator, workspace_root, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "docs_artifact")) {
        return executeDocsArtifact(allocator, workspace_root, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "knowledge_artifact")) {
        return executeKnowledgeArtifact(allocator, workspace_root, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "git_worktree")) {
        return executeGitWorktree(allocator, workspace_root, arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_name, "workspace_backup")) {
        return executeWorkspaceBackup(allocator, workspace_root, arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_name, "instruction_ingestion")) {
        return executeInstructionIngestion(allocator, workspace_root, arguments_json);
    }

    return error.UnknownTool;
}

fn workspaceStateRootPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var" });
}

fn changelogLogPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "changelog", "_log.md" });
}

fn docsIndexPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "docs", "_index.md" });
}

fn docsArchitecturePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "docs", "architecture.md" });
}

fn docsToolContractsPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "docs", "tool-contracts.md" });
}

fn readmePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "README.md" });
}

fn docsPath(allocator: std.mem.Allocator, workspace_root: []const u8, relative_path: []const u8) ![]u8 {
    const relative = try fsutil.join(allocator, &.{ ".var", "docs", relative_path });
    defer allocator.free(relative);
    return fsutil.resolveInWorkspace(allocator, workspace_root, relative);
}

fn knowledgeSurfaceDir(surface: []const u8) ![]const u8 {
    if (std.mem.eql(u8, surface, "research")) return "research";
    if (std.mem.eql(u8, surface, "plans")) return "plans";
    if (std.mem.eql(u8, surface, "advice")) return "advice";
    if (std.mem.eql(u8, surface, "roadmap")) return "roadmap";
    return error.InvalidArguments;
}

fn knowledgeSurfaceRoot(allocator: std.mem.Allocator, workspace_root: []const u8, surface: []const u8) ![]u8 {
    const dir = try knowledgeSurfaceDir(surface);
    return fsutil.join(allocator, &.{ workspace_root, ".var", dir });
}

fn knowledgeSurfacePath(allocator: std.mem.Allocator, workspace_root: []const u8, surface: []const u8, relative_path: []const u8) ![]u8 {
    const dir = try knowledgeSurfaceDir(surface);
    const relative = try fsutil.join(allocator, &.{ ".var", dir, relative_path });
    defer allocator.free(relative);
    return fsutil.resolveInWorkspace(allocator, workspace_root, relative);
}

fn worktreesRootPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "worktrees" });
}

fn backupRootPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "backup" });
}

fn okEnvelope(allocator: std.mem.Allocator, tool_name: []const u8, content: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"tool\":{f},\"content\":{f}}}",
        .{
            std.json.fmt(tool_name, .{}),
            std.json.fmt(content, .{}),
        },
    );
}

fn appendMarkdownBlock(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    var line = std.array_list.Managed(u8).init(allocator);
    defer line.deinit();
    try line.writer().writeAll(content);
    if (content.len == 0 or content[content.len - 1] != '\n') try line.writer().writeByte('\n');
    try line.writer().writeByte('\n');
    try fsutil.appendText(path, line.items);
}

fn isSafeSegment(segment: []const u8) bool {
    if (segment.len == 0) return false;
    if (std.mem.indexOf(u8, segment, "..") != null) return false;
    for (segment) |byte| {
        if (byte == '/' or byte == '\\') return false;
    }
    return true;
}

const ScaffoldStats = struct {
    directories_created: usize = 0,
    files_written: usize = 0,
    files_skipped: usize = 0,
};

fn ensureDir(path: []const u8, stats: *ScaffoldStats) !void {
    if (fsutil.fileExists(path)) return;
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    stats.directories_created += 1;
}

fn writeTemplateFile(path: []const u8, content: []const u8, force_overwrite: bool, stats: *ScaffoldStats) !void {
    if (fsutil.fileExists(path) and !force_overwrite) {
        stats.files_skipped += 1;
        return;
    }
    try fsutil.writeText(path, content);
    stats.files_written += 1;
}

fn defaultWorkspaceReadme() []const u8 {
    const content =
        \\# .var
        \\
        \\`.var/` is the canonical runtime-owned and process-owned root for this workspace.
        \\
        \\## Ownership
        \\
        \\- `.var/` owns the ticket ledger, session ledgers, summaries, changelog, research, plans, advice, roadmap, docs, backup, and worktree state for VAR1. Agent memory is owned by the runtime memory store, not this scaffold.
        \\- Tickets are the only work lifecycle. Summaries are handoff projections; research, plans, advice, roadmap, changelog, and docs are ticket-linked artifacts.
        \\- Legacy `.var/todos/` slices and per-session `session.md` records are not created or read by the runtime.
        \\- `.docs/` remains readable repo documentation or preserved historical material when present.
        \\- `init_workspace` owns the default scaffold. Other workspace-state tools operate inside that canonical tree and do not create a parallel system.
    ;
    return content;
}

fn defaultChangelogFile() []const u8 {
    const content =
        \\# VAR1 Changelog Log
        \\
    ;
    return content;
}

fn defaultDocsIndex() []const u8 {
    const content =
        \\# .var Docs Index
        \\
        \\- [architecture.md](./architecture.md)
        \\  Canonical directory hierarchy, process flow, and runtime ownership boundary.
        \\- [tool-contracts.md](./tool-contracts.md)
        \\  Canonical tool contracts for the workspace runtime.
        \\
        \\## Current Rule
        \\
        \\Use `.var/` for live runtime/process state. Use `.docs/` for readable repo documentation.
    ;
    return content;
}

fn defaultDocsArchitecture() []const u8 {
    const content =
        \\# .var Architecture
        \\
        \\## Runtime Boundary
        \\
        \\The active workspace root is the default mutation boundary. VAR1 must not create a second live runtime or a second state ledger outside `.var/`.
        \\
        \\## Canonical Tree
        \\
        \\```text
        \\<project-root>/
        \\  .var/
        \\    tickets/
        \\      tickets.jsonl
        \\    changelog/
        \\      _log.md
        \\    sessions/
        \\      <session-id>/
        \\        session.json
        \\        messages.jsonl
        \\        context.jsonl
        \\        events.jsonl
        \\        output.txt
        \\    research/
        \\    plans/
        \\    advice/
        \\    roadmap/
        \\    docs/
        \\      _index.md
        \\      architecture.md
        \\      tool-contracts.md
        \\    worktrees/
        \\    backup/
        \\```
        \\
        \\## Tool Runtime
        \\
        \\- `init_workspace` scaffolds the canonical structure.
        \\- Workspace-state tools operate inside `.var/` only.
        \\- Consumer runtimes such as `VAR1` must project through the root contract instead of inventing a parallel system.
    ;
    return content;
}

fn defaultToolContracts() []const u8 {
    const content =
        \\# Tool Contracts
        \\
        \\## Init Tool
        \\
        \\Purpose:
        \\- scaffold the canonical `.var/` tree
        \\- create missing default docs and ledgers without inventing a second system
        \\
        \\## Required Domain Tools
        \\
        \\- `log_ticket` owns work lifecycle and terminal state
        \\- `update_session_summary` owns bounded handoff state
        \\- `changelog_ledger` appends ticket-linked completion evidence
        \\- `docs_artifact`
        \\- `knowledge_artifact`
        \\- `git_worktree`
        \\- `workspace_backup`
        \\- `instruction_ingestion`
        \\
        \\Rule:
        \\- every workspace-state tool operates inside `.var/`
        \\- tools may be used only when relevant to the request
        \\- no tool may create a parallel work lifecycle
    ;
    return content;
}

fn defaultWorktreesReadme() []const u8 {
    const content =
        \\# .var Worktrees
        \\
        \\Use `git_worktree` to manage Git worktrees under this directory when the workspace is a real Git checkout.
    ;
    return content;
}

fn defaultBackupReadme() []const u8 {
    const content =
        \\# .var Backup
        \\
        \\Use `workspace_backup` to create timestamped workspace archives before destructive operations or large migrations.
    ;
    return content;
}

fn defaultResearchReadme() []const u8 {
    const content =
        \\# .var Research
        \\
        \\Store decision rationale, source summaries, and implementation snapshots here.
    ;
    return content;
}

fn defaultPlansReadme() []const u8 {
    const content =
        \\# .var Plans
        \\
        \\Store durable implementation plans, execution chains, step sequences, and proof-gate definitions here. Each plan carries its owner path, invariants, and stop conditions.
    ;
    return content;
}

fn defaultAdviceReadme() []const u8 {
    const content =
        \\# .var Advice
        \\
        \\Store advisor SITREPs, coaching records, verification findings, and critique summaries here. Advisors are coaches, not authorities: they sharpen strategy and flag drift.
    ;
    return content;
}

fn defaultRoadmapReadme() []const u8 {
    const content =
        \\# .var Roadmap
        \\
        \\Store roadmap artifacts here. Each roadmap entry must carry an owner path and exit criteria; an entry without both is an aspiration, not a roadmap item.
    ;
    return content;
}

fn scaffoldWorkspace(allocator: std.mem.Allocator, workspace_root: []const u8, force_overwrite: bool) !ScaffoldStats {
    var stats = ScaffoldStats{};

    const directories = [_][]const u8{
        try workspaceStateRootPath(allocator, workspace_root),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "memories" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "changelog" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "docs" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "sessions" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "research" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "plans" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "advice" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "roadmap" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "worktrees" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "backup" }),
    };
    defer for (directories) |path| allocator.free(path);

    for (directories) |path| try ensureDir(path, &stats);

    const worktrees_readme = try fsutil.join(allocator, &.{ workspace_root, ".var", "worktrees", "README.md" });
    defer allocator.free(worktrees_readme);
    const backup_readme = try fsutil.join(allocator, &.{ workspace_root, ".var", "backup", "README.md" });
    defer allocator.free(backup_readme);
    const research_readme = try fsutil.join(allocator, &.{ workspace_root, ".var", "research", "README.md" });
    defer allocator.free(research_readme);
    const plans_readme = try fsutil.join(allocator, &.{ workspace_root, ".var", "plans", "README.md" });
    defer allocator.free(plans_readme);
    const advice_readme = try fsutil.join(allocator, &.{ workspace_root, ".var", "advice", "README.md" });
    defer allocator.free(advice_readme);
    const roadmap_readme = try fsutil.join(allocator, &.{ workspace_root, ".var", "roadmap", "README.md" });
    defer allocator.free(roadmap_readme);

    const readme = try readmePath(allocator, workspace_root);
    defer allocator.free(readme);
    const changelog = try changelogLogPath(allocator, workspace_root);
    defer allocator.free(changelog);
    const docs_index = try docsIndexPath(allocator, workspace_root);
    defer allocator.free(docs_index);
    const docs_architecture = try docsArchitecturePath(allocator, workspace_root);
    defer allocator.free(docs_architecture);
    const docs_contracts = try docsToolContractsPath(allocator, workspace_root);
    defer allocator.free(docs_contracts);

    try writeTemplateFile(readme, defaultWorkspaceReadme(), force_overwrite, &stats);
    try writeTemplateFile(changelog, defaultChangelogFile(), force_overwrite, &stats);
    try writeTemplateFile(docs_index, defaultDocsIndex(), force_overwrite, &stats);
    try writeTemplateFile(docs_architecture, defaultDocsArchitecture(), force_overwrite, &stats);
    try writeTemplateFile(docs_contracts, defaultToolContracts(), force_overwrite, &stats);
    try writeTemplateFile(worktrees_readme, defaultWorktreesReadme(), force_overwrite, &stats);
    try writeTemplateFile(backup_readme, defaultBackupReadme(), force_overwrite, &stats);
    try writeTemplateFile(research_readme, defaultResearchReadme(), force_overwrite, &stats);
    try writeTemplateFile(plans_readme, defaultPlansReadme(), force_overwrite, &stats);
    try writeTemplateFile(advice_readme, defaultAdviceReadme(), force_overwrite, &stats);
    try writeTemplateFile(roadmap_readme, defaultRoadmapReadme(), force_overwrite, &stats);

    return stats;
}

fn executeInitWorkspace(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct {
        force_overwrite: bool = false,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const stats = try scaffoldWorkspace(allocator, workspace_root, parsed.value.force_overwrite);
    const content = try std.fmt.allocPrint(
        allocator,
        "ROOT {s}\nDIRECTORIES_ENSURED {d}\nFILES_WRITTEN {d}\nFILES_SKIPPED {d}",
        .{ ".var", stats.directories_created, stats.files_written, stats.files_skipped },
    );
    defer allocator.free(content);

    return okEnvelope(allocator, "init_workspace", content);
}

fn executeChangelogLedger(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct {
        action: []const u8,
        content: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const file_path = try changelogLogPath(allocator, workspace_root);
    defer allocator.free(file_path);
    try fsutil.ensureParent(file_path);
    if (!fsutil.fileExists(file_path)) try fsutil.writeText(file_path, defaultChangelogFile());

    if (std.mem.eql(u8, parsed.value.action, "read")) {
        const content = try fsutil.readTextAlloc(allocator, file_path);
        defer allocator.free(content);
        const payload = try std.fmt.allocPrint(allocator, "PATH {s}\n{s}", .{ file_path, content });
        defer allocator.free(payload);
        return okEnvelope(allocator, "changelog_ledger", payload);
    }

    if (std.mem.eql(u8, parsed.value.action, "append")) {
        const content = parsed.value.content orelse return error.InvalidArguments;
        try appendMarkdownBlock(allocator, file_path, content);
        const payload = try std.fmt.allocPrint(allocator, "PATH {s}\nAPPENDED_BYTES {d}", .{ file_path, content.len });
        defer allocator.free(payload);
        return okEnvelope(allocator, "changelog_ledger", payload);
    }

    return error.InvalidArguments;
}

fn executeDocsArtifact(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    return executeBodyFileTool(allocator, workspace_root, arguments_json, "docs_artifact", docsPath);
}

fn executeKnowledgeArtifact(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct {
        action: []const u8,
        surface: []const u8,
        path: ?[]const u8 = null,
        title: ?[]const u8 = null,
        content: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();
    const args = parsed.value;

    // Validate surface early so list works without a path.
    _ = try knowledgeSurfaceDir(args.surface);

    if (std.mem.eql(u8, args.action, "list")) {
        const surface_root = try knowledgeSurfaceRoot(allocator, workspace_root, args.surface);
        defer allocator.free(surface_root);

        var dir = std.fs.cwd().openDir(surface_root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return okEnvelope(allocator, "knowledge_artifact", "SURFACE empty\nREASON surface directory does not exist yet"),
            else => return err,
        };
        defer dir.close();

        var entries = std.array_list.Managed(u8).init(allocator);
        defer entries.deinit();
        const writer = entries.writer();
        try writer.print("SURFACE {s}\n", .{args.surface});

        var count: usize = 0;
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            try writer.print("- {s}\n", .{entry.path});
            count += 1;
        }
        if (count == 0) try writer.writeAll("(none)\n");
        return okEnvelope(allocator, "knowledge_artifact", entries.items);
    }

    const relative_path = args.path orelse return error.InvalidArguments;
    const file_path = try knowledgeSurfacePath(allocator, workspace_root, args.surface, relative_path);
    defer allocator.free(file_path);

    if (std.mem.eql(u8, args.action, "read")) {
        const content = try fsutil.readTextAlloc(allocator, file_path);
        defer allocator.free(content);
        const payload = try std.fmt.allocPrint(allocator, "PATH {s}\n{s}", .{ file_path, content });
        defer allocator.free(payload);
        return okEnvelope(allocator, "knowledge_artifact", payload);
    }

    if (std.mem.eql(u8, args.action, "write")) {
        const content_body = args.content orelse return error.InvalidArguments;
        const rendered = try if (args.title) |title|
            if (std.mem.startsWith(u8, content_body, "# ")) allocator.dupe(u8, content_body) else std.fmt.allocPrint(allocator, "# {s}\n\n{s}", .{ title, content_body })
        else
            allocator.dupe(u8, content_body);
        defer allocator.free(rendered);

        try fsutil.writeText(file_path, rendered);
        const payload = try std.fmt.allocPrint(allocator, "SURFACE {s}\nPATH {s}\nBYTES {d}", .{ args.surface, file_path, rendered.len });
        defer allocator.free(payload);
        return okEnvelope(allocator, "knowledge_artifact", payload);
    }

    return error.InvalidArguments;
}

fn executeBodyFileTool(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
    tool_name: []const u8,
    path_resolver: *const fn (std.mem.Allocator, []const u8, []const u8) anyerror![]u8,
) ![]u8 {
    const Args = struct {
        action: []const u8,
        path: []const u8,
        title: ?[]const u8 = null,
        content: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const file_path = try path_resolver(allocator, workspace_root, parsed.value.path);
    defer allocator.free(file_path);

    if (std.mem.eql(u8, parsed.value.action, "read")) {
        const content = try fsutil.readTextAlloc(allocator, file_path);
        defer allocator.free(content);
        const payload = try std.fmt.allocPrint(allocator, "PATH {s}\n{s}", .{ file_path, content });
        defer allocator.free(payload);
        return okEnvelope(allocator, tool_name, payload);
    }

    if (std.mem.eql(u8, parsed.value.action, "write")) {
        const content_body = parsed.value.content orelse return error.InvalidArguments;
        const rendered = try if (parsed.value.title) |title|
            if (std.mem.startsWith(u8, content_body, "# ")) allocator.dupe(u8, content_body) else std.fmt.allocPrint(allocator, "# {s}\n\n{s}", .{ title, content_body })
        else
            allocator.dupe(u8, content_body);
        defer allocator.free(rendered);

        try fsutil.writeText(file_path, rendered);
        const payload = try std.fmt.allocPrint(allocator, "PATH {s}\nBYTES {d}", .{ file_path, rendered.len });
        defer allocator.free(payload);
        return okEnvelope(allocator, tool_name, payload);
    }

    return error.InvalidArguments;
}

fn executeGitWorktree(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
    runner: anytype,
) ![]u8 {
    const Args = struct {
        action: []const u8,
        name: ?[]const u8 = null,
        ref: ?[]const u8 = null,
        force: bool = false,
        reason: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    if (!try workspaceIsGitCheckout(allocator, workspace_root, runner)) {
        const payload = try allocator.dupe(u8, "WORKTREE_STATUS disabled\nREASON workspace is not a Git checkout");
        defer allocator.free(payload);
        return okEnvelope(allocator, "git_worktree", payload);
    }

    if (std.mem.eql(u8, parsed.value.action, "status")) {
        const list_output = try runner.run(allocator, workspace_root, &.{ "git", "worktree", "list", "--porcelain" });
        defer list_output.deinit(allocator);
        if (list_output.exit_code != 0) return error.CommandFailed;
        const payload = try std.fmt.allocPrint(allocator, "WORKTREE_STATUS ready\n{s}", .{list_output.stdout});
        defer allocator.free(payload);
        return okEnvelope(allocator, "git_worktree", payload);
    }

    if (std.mem.eql(u8, parsed.value.action, "list")) {
        const list_output = try runner.run(allocator, workspace_root, &.{ "git", "worktree", "list", "--porcelain" });
        defer list_output.deinit(allocator);
        if (list_output.exit_code != 0) return error.CommandFailed;
        return okEnvelope(allocator, "git_worktree", list_output.stdout);
    }

    if (std.mem.eql(u8, parsed.value.action, "prune")) {
        const prune_output = try runner.run(allocator, workspace_root, &.{ "git", "worktree", "prune", "-v" });
        defer prune_output.deinit(allocator);
        if (prune_output.exit_code != 0) return error.CommandFailed;
        return okEnvelope(allocator, "git_worktree", prune_output.stdout);
    }

    const name = parsed.value.name orelse return error.InvalidArguments;
    if (!isSafeSegment(name)) return error.InvalidArguments;

    const worktrees_root = try worktreesRootPath(allocator, workspace_root);
    defer allocator.free(worktrees_root);
    var worktree_stats = ScaffoldStats{};
    try ensureDir(worktrees_root, &worktree_stats);

    const worktree_path = try fsutil.join(allocator, &.{ worktrees_root, name });
    defer allocator.free(worktree_path);

    if (std.mem.eql(u8, parsed.value.action, "add")) {
        var argv = std.array_list.Managed([]const u8).init(allocator);
        defer argv.deinit();
        try argv.append("git");
        try argv.append("worktree");
        try argv.append("add");
        try argv.append(worktree_path);
        if (parsed.value.ref) |ref_value| try argv.append(ref_value);

        const add_output = try runner.run(allocator, workspace_root, argv.items);
        defer add_output.deinit(allocator);
        if (add_output.exit_code != 0) return error.CommandFailed;
        const payload = try std.fmt.allocPrint(allocator, "PATH {s}\n{s}", .{ worktree_path, add_output.stdout });
        defer allocator.free(payload);
        return okEnvelope(allocator, "git_worktree", payload);
    }

    if (std.mem.eql(u8, parsed.value.action, "remove")) {
        var argv = std.array_list.Managed([]const u8).init(allocator);
        defer argv.deinit();
        try argv.append("git");
        try argv.append("worktree");
        try argv.append("remove");
        if (parsed.value.force) try argv.append("-f");
        try argv.append(worktree_path);

        const remove_output = try runner.run(allocator, workspace_root, argv.items);
        defer remove_output.deinit(allocator);
        if (remove_output.exit_code != 0) return error.CommandFailed;
        return okEnvelope(allocator, "git_worktree", remove_output.stdout);
    }

    if (std.mem.eql(u8, parsed.value.action, "lock")) {
        var argv = std.array_list.Managed([]const u8).init(allocator);
        defer argv.deinit();
        try argv.append("git");
        try argv.append("worktree");
        try argv.append("lock");
        if (parsed.value.reason) |reason| {
            try argv.append("--reason");
            try argv.append(reason);
        }
        try argv.append(worktree_path);

        const lock_output = try runner.run(allocator, workspace_root, argv.items);
        defer lock_output.deinit(allocator);
        if (lock_output.exit_code != 0) return error.CommandFailed;
        return okEnvelope(allocator, "git_worktree", lock_output.stdout);
    }

    return error.InvalidArguments;
}

fn executeWorkspaceBackup(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
    runner: anytype,
) ![]u8 {
    const Args = struct {
        label: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    if (parsed.value.label) |label| {
        if (!isSafeSegment(label)) return error.InvalidArguments;
    }

    const backup_root = try backupRootPath(allocator, workspace_root);
    defer allocator.free(backup_root);
    var backup_stats = ScaffoldStats{};
    try ensureDir(backup_root, &backup_stats);

    const timestamp_ms = std.time.milliTimestamp();
    const filename = if (parsed.value.label) |label|
        try std.fmt.allocPrint(allocator, "backup-{d}-{s}.zip", .{ timestamp_ms, label })
    else
        try std.fmt.allocPrint(allocator, "backup-{d}.zip", .{timestamp_ms});
    defer allocator.free(filename);

    const destination = try fsutil.join(allocator, &.{ backup_root, filename });
    defer allocator.free(destination);

    const result = if (builtin.os.tag == .windows) blk: {
        const script = try std.fmt.allocPrint(
            allocator,
            "Compress-Archive -Path * -DestinationPath '{s}' -Force -CompressionLevel Optimal -Exclude '.var/backup/*','.zig-cache/*','zig-out/*'",
            .{destination},
        );
        defer allocator.free(script);
        break :blk try runner.run(allocator, workspace_root, &.{ "powershell", "-NoProfile", "-Command", script });
    } else blk: {
        break :blk try runner.run(allocator, workspace_root, &.{ "zip", "-r", destination, ".", "-x", ".var/backup/*", ".zig-cache/*", "zig-out/*" });
    };
    defer result.deinit(allocator);

    if (result.exit_code != 0) return error.CommandFailed;

    const payload = try std.fmt.allocPrint(allocator, "PATH {s}\n{s}", .{ destination, result.stdout });
    defer allocator.free(payload);
    return okEnvelope(allocator, "workspace_backup", payload);
}

fn executeInstructionIngestion(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct {
        mode: []const u8,
        target_path: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    if (std.mem.eql(u8, parsed.value.mode, "never")) {
        return okEnvelope(allocator, "instruction_ingestion", "MODE never\nFILES 0");
    }

    const target_root = try fsutil.resolveInWorkspace(allocator, workspace_root, parsed.value.target_path orelse ".");
    defer allocator.free(target_root);

    var paths = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (paths.items) |item| allocator.free(item);
        paths.deinit();
    }

    if (std.mem.eql(u8, parsed.value.mode, "always")) {
        try collectAgentsFilesRecursive(allocator, workspace_root, workspace_root, &paths);
    } else {
        try collectAgentsFilesUpward(allocator, workspace_root, target_root, &paths);
    }

    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    try output.writer().print("MODE {s}\nFILES {d}\n", .{ parsed.value.mode, paths.items.len });

    for (paths.items) |path| {
        const content = try fsutil.readTextAlloc(allocator, path);
        defer allocator.free(content);
        const relative = try std.fs.path.relative(allocator, workspace_root, path);
        defer allocator.free(relative);
        try output.writer().print("PATH {s}\n{s}\n", .{ relative, content });
    }

    const rendered = try output.toOwnedSlice();
    defer allocator.free(rendered);
    return okEnvelope(allocator, "instruction_ingestion", rendered);
}

fn workspaceIsGitCheckout(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    runner: anytype,
) !bool {
    const result = try runner.run(allocator, workspace_root, &.{ "git", "rev-parse", "--is-inside-work-tree" });
    defer result.deinit(allocator);
    if (result.exit_code != 0) return false;
    return std.mem.indexOf(u8, result.stdout, "true") != null;
}

fn collectAgentsFilesUpward(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    target_root: []const u8,
    output: *std.array_list.Managed([]u8),
) !void {
    const workspace_abs = try fsutil.resolveAbsolute(allocator, workspace_root);
    defer allocator.free(workspace_abs);

    var current = try allocator.dupe(u8, target_root);
    defer allocator.free(current);

    while (true) {
        const agents_path = try std.fs.path.join(allocator, &.{ current, "AGENTS.md" });
        defer allocator.free(agents_path);
        if (fsutil.fileExists(agents_path) and !containsOwnedPath(output.items, agents_path)) {
            try output.append(try allocator.dupe(u8, agents_path));
        }
        if (std.ascii.eqlIgnoreCase(current, workspace_abs)) break;
        const parent = std.fs.path.dirname(current) orelse break;
        if (parent.len == 0 or std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

fn collectAgentsFilesRecursive(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    search_root: []const u8,
    output: *std.array_list.Managed([]u8),
) !void {
    var dir = try std.fs.openDirAbsolute(search_root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "AGENTS.md")) continue;

        const absolute = try std.fs.path.join(allocator, &.{ search_root, entry.path });
        defer allocator.free(absolute);
        const resolved = try fsutil.resolveInWorkspace(allocator, workspace_root, absolute);
        defer allocator.free(resolved);
        if (!containsOwnedPath(output.items, resolved)) {
            try output.append(try allocator.dupe(u8, resolved));
        }
    }
}

fn containsOwnedPath(items: []const []u8, candidate: []const u8) bool {
    for (items) |item| {
        if (pathEqual(item, candidate)) return true;
    }
    return false;
}

fn pathEqual(left: []const u8, right: []const u8) bool {
    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(left, right);
    return std.mem.eql(u8, left, right);
}

const std = @import("std");

const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definition = types.ToolDefinition{
    .name = "skill_info",
    .description = "Inspect Ventari skill capsules. Use this before invoking a named skill when the operator asks for skills or when task routing depends on skill-specific protocol.",
    .review_risk = .read_only,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "name": { "type": "string", "description": "Optional exact skill name, for example planning-spec, insect, dupe-audit, ux-playbook, or t3-tape." },
    \\    "query": { "type": "string", "description": "Optional lowercase routing query used to filter skill capsules." },
    \\    "include_addons": { "type": "boolean", "description": "Include add-on/non-native skills in index results. Defaults to true." }
    \\  },
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"name\":\"planning-spec\"}",
    .usage_hint = "Native skills are already summarized in the prompt. Call skill_info for exact routing capsules; do not load every skill body unless the task explicitly needs it.",
};

pub const availability = module.AvailabilitySpec{};

const SkillEntry = struct {
    name: []const u8,
    tier: []const u8,
    root: []const u8,
    summary: []const u8,
    triggers: []const u8,
    protocol: []const u8 = "",
};

const native_skills = [_]SkillEntry{
    .{
        .name = "planning-spec",
        .tier = "native",
        .root = "%USERPROFILE%\\.codex\\skills\\planning-spec",
        .summary = "Deterministic parent-plus-lettered execution chains, invariant tracking, crash recovery, and cold-start handoff for substantial implementation work.",
        .triggers = "planning, specs, todo chains, execution units, cold-start handoff, state-machine work",
        .protocol = "Read SKILL.md and todo_chain_templates.md before writing planning-spec artifacts. Persist parent-plus-lettered todo chains with source-message proof and next_todo handoff.",
    },
    .{
        .name = "insect",
        .tier = "native",
        .root = "%USERPROFILE%\\.codex\\skills\\insect-rs-runtime",
        .summary = "Compiled Rust web/search/scrape runtime for external research, crawling, page extraction, SERP retrieval, and YouTube transcript work.",
        .triggers = "web search, scrape, crawl, harvest, external research, YouTube transcript",
        .protocol = "Canonical runtime path is %USERPROFILE%\\.codex\\skills\\insect-rs-runtime. Use scripts\\run-insect-rs.ps1 with engine --query <query>, engine --url <url>, transcribe-youtube --url/--video-id, or serve. Do not search for the Insect runtime location after this capsule is available.",
    },
    .{
        .name = "dupe-audit",
        .tier = "native",
        .root = "%USERPROFILE%\\.codex\\skills\\dupe-audit",
        .summary = "Similarity and duplication audit using the packaged model/runtime for regression gates, parity checks, related-code discovery, and refactor evidence.",
        .triggers = "duplicate logic, parity audit, similar code, regression gate, refactor evidence",
    },
    .{
        .name = "recon-intel",
        .tier = "native",
        .root = "%USERPROFILE%\\.codex\\skills\\recon-intel",
        .summary = "Structured repository reconnaissance before changing orchestration, persistence, auth, runtime flows, or unfamiliar architecture.",
        .triggers = "recon, architecture map, source-of-truth, pipeline flow, ownership boundaries",
    },
    .{
        .name = "ux-playbook",
        .tier = "native",
        .root = "%USERPROFILE%\\.codex\\skills\\ux-playbook",
        .summary = "Enterprise UI/UX structure, hierarchy, disclosure, authenticated product surfaces, dashboards, settings, and workflow review.",
        .triggers = "UI, UX, layout, dashboard, settings, forms, visual hierarchy, frontend work",
    },
    .{
        .name = "t3-tape",
        .tier = "native",
        .root = "%USERPROFILE%\\.codex\\skills\\t3-tape",
        .summary = "PatchMD workflow for recording, validating, importing, approving, and governing repository patch streams.",
        .triggers = "patch workflow, t3, patch.md, migration, recorded patch, hook validation",
    },
    .{
        .name = "repo-harvester",
        .tier = "native",
        .root = "%USERPROFILE%\\.codex\\skills\\repo-harvester",
        .summary = "Harvest, qualify, archive, extract, de-duplicate, and index elite language/source repositories into the global collection.",
        .triggers = "repo collection, harvest repositories, Zig/Rust/JS corpus, archive and index",
    },
    .{
        .name = "playwright",
        .tier = "native",
        .root = "%USERPROFILE%\\.codex\\skills\\playwright",
        .summary = "Real browser automation for local UI flows, screenshots, form interaction, and visual/runtime verification.",
        .triggers = "browser test, screenshot, UI smoke, click/type, local web app verification",
    },
    .{
        .name = "task-audit",
        .tier = "native",
        .root = "%USERPROFILE%\\.codex\\skills\\task-audit",
        .summary = "Implementation correctness review for architecture drift, stale routes, prompt/schema mismatch, and source-of-truth violations.",
        .triggers = "review, audit implementation, drift, stale wires, correctness check",
    },
};

const addon_skills = [_]SkillEntry{
    .{
        .name = "docx",
        .tier = "addon",
        .root = "%USERPROFILE%\\.claude\\skills\\docx",
        .summary = "Create, read, edit, and manipulate Word documents with professional structure and formatting.",
        .triggers = "docx, Word document, report, memo, template",
    },
    .{
        .name = "react-doctor",
        .tier = "addon",
        .root = "%USERPROFILE%\\.claude\\skills\\react-doctor",
        .summary = "Diagnose and repair React health, performance, security, and maintainability issues.",
        .triggers = "React review, component health, frontend performance",
    },
    .{
        .name = "find-skills",
        .tier = "addon",
        .root = "%USERPROFILE%\\.claude\\skills\\find-skills",
        .summary = "Discover potentially installable skills for a requested capability.",
        .triggers = "find a skill, installable capability, skill discovery",
    },
    .{
        .name = "remotion-best-practices",
        .tier = "addon",
        .root = "%USERPROFILE%\\.claude\\skills\\remotion-best-practices",
        .summary = "Remotion video creation guidance and best practices.",
        .triggers = "Remotion, video composition, React video",
    },
};

pub fn renderPromptCapsules(writer: anytype) !void {
    try writer.writeAll(
        \\# Skill Routing Contract
        \\Skills are reusable operating protocols, distinct from tools. Tools execute actions; skills select method, evidence shape, and validation discipline.
        \\Default native skills are available conceptually without preloading full bodies:
        \\
    );
    for (native_skills) |skill| {
        try writer.print("- {s}: {s}\n", .{ skill.name, skill.summary });
    }
    try writer.writeAll(
        \\Known native roots live under `%USERPROFILE%\.codex\skills`; Insect's canonical runtime is `%USERPROFILE%\.codex\skills\insect-rs-runtime` via `scripts\run-insect-rs.ps1`.
        \\Use skill_info for an exact capsule when the operator says "use <skill>" or when task routing depends on a skill. Treat add-on skills as discoverable, not always loaded.
        \\
    );
}

pub fn execute(
    allocator: std.mem.Allocator,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct {
        name: ?[]const u8 = null,
        query: ?[]const u8 = null,
        include_addons: bool = true,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    if (parsed.value.name) |name| {
        const skill = findByName(name) orelse return module.Error.InvalidArguments;
        return renderExact(allocator, skill);
    }

    return renderIndex(allocator, parsed.value.query, parsed.value.include_addons);
}

fn findByName(name: []const u8) ?SkillEntry {
    for (native_skills) |skill| {
        if (std.ascii.eqlIgnoreCase(name, skill.name)) return skill;
    }
    for (addon_skills) |skill| {
        if (std.ascii.eqlIgnoreCase(name, skill.name)) return skill;
    }
    if (std.ascii.eqlIgnoreCase(name, "insect-rs-runtime")) return native_skills[1];
    return null;
}

fn renderExact(allocator: std.mem.Allocator, skill: SkillEntry) ![]u8 {
    const content = try std.fmt.allocPrint(
        allocator,
        "SKILL {s}\nTIER {s}\nROOT {s}\nSUMMARY {s}\nTRIGGERS {s}\nPROTOCOL {s}\n",
        .{ skill.name, skill.tier, skill.root, skill.summary, skill.triggers, skill.protocol },
    );
    defer allocator.free(content);
    return module.okEnvelope(allocator, definition.name, content);
}

fn renderIndex(
    allocator: std.mem.Allocator,
    query: ?[]const u8,
    include_addons: bool,
) ![]u8 {
    var content = std.array_list.Managed(u8).init(allocator);
    errdefer content.deinit();
    try content.writer().writeAll("NATIVE SKILLS\n");
    try renderEntries(content.writer(), native_skills[0..], query);
    if (include_addons) {
        try content.writer().writeAll("ADDON SKILLS\n");
        try renderEntries(content.writer(), addon_skills[0..], query);
    }
    const owned = try content.toOwnedSlice();
    defer allocator.free(owned);
    return module.okEnvelope(allocator, definition.name, owned);
}

fn renderEntries(writer: anytype, entries: []const SkillEntry, query: ?[]const u8) !void {
    for (entries) |skill| {
        if (query) |needle| {
            if (!matchesQuery(skill, needle)) continue;
        }
        try writer.print("- {s} [{s}]: {s}\n  triggers: {s}\n", .{ skill.name, skill.tier, skill.summary, skill.triggers });
    }
}

fn matchesQuery(skill: SkillEntry, query: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(skill.name, query) != null or
        std.ascii.indexOfIgnoreCase(skill.summary, query) != null or
        std.ascii.indexOfIgnoreCase(skill.triggers, query) != null;
}

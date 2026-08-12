const std = @import("std");
const config_file = @import("../config/file.zig");
const fsutil = @import("../../shared/fsutil.zig");
const profile_contract = @import("profile.zig");
const routes = @import("../providers/routes.zig");

pub const Error = error{
    EmptyAgentRegistry,
    InvalidAgentDefinition,
    InstructionTooLarge,
    UnknownAgentSpec,
    UnknownAgentBase,
};

pub const AgentSpec = struct {
    id: []const u8,
    description: []const u8,
    when_to_use: []const u8,
    instruction_capsule: []const u8,
    route_role: routes.RouteRole,
    execution_kind: routes.ExecutionKind,
    capability_profile_id: []const u8,
    max_steps: usize,
    max_tool_calls: usize,
    max_children: usize,
    output_contract: []const u8,
    /// Distilled doctrine tags (kebab-case, space separated) baked into the
    /// model-visible catalog so every specialist carries the doctrine without
    /// re-reading AGENTS.md: evidence-first capability-truth ticket-discipline
    /// harvest-before-originate proof-gated append-only no-parallel-systems
    /// stale-owner-reconciliation cold-start-replayable.
    doctrine_tags: []const u8,
    /// Agent may transition states of tickets it owns (assigned→in_progress→
    /// complete). Agents NEVER close tickets — close authority is kernel-only
    /// (tickets.close_authority). No config knob exists to widen this.
    ticket_ownership: bool,
    /// Live checkpoint contract the agent must keep current while working
    /// (>=3-sentence summary row) so the parent, siblings, and cold-start
    /// recovery can see progress and state. Rendered into the catalog.
    checkpoint_contract: []const u8,
    /// Direction mode: "directed" (execute only the assigned ticket),
    /// "bounded" (assigned ticket plus explicitly bounded adjacent evidence),
    /// "self_directed" (may decompose its ticket into child work within budget).
    autonomy: []const u8,
    /// Optional per-agent effort override; "" means VANTARI (the kernel) or
    /// the route decides — the model is the plane, VANTARI is the pilot.
    effort: []const u8 = "",
    /// Optional per-agent temperature override; -1 means VANTARI/route decides.
    temperature: f64 = -1,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    specs: []AgentSpec,

    pub fn deinit(self: Registry) void {
        for (self.specs) |spec| deinitOwnedSpec(self.allocator, spec);
        self.allocator.free(self.specs);
    }

    pub fn all(self: Registry) []const AgentSpec {
        return self.specs;
    }

    pub fn resolve(self: Registry, spec_id: []const u8) Error!AgentSpec {
        for (self.specs) |spec| {
            if (std.mem.eql(u8, spec.id, spec_id)) return spec;
        }
        return Error.UnknownAgentSpec;
    }
};

pub const DefinitionPatch = struct {
    id: []const u8,
    extends: ?[]const u8 = null,
    enabled: ?bool = null,
    description: ?[]const u8 = null,
    when_to_use: ?[]const u8 = null,
    instruction: ?[]const u8 = null,
    route_role: ?[]const u8 = null,
    max_steps: ?usize = null,
    max_tool_calls: ?usize = null,
    max_children: ?usize = null,
    output_contract: ?[]const u8 = null,
    doctrine_tags: ?[]const u8 = null,
    ticket_ownership: ?bool = null,
    checkpoint_contract: ?[]const u8 = null,
    autonomy: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    temperature: ?f64 = null,
};

pub const MutationEvidence = struct {
    config_path: []u8,
    action: []const u8,
    agent_id: []u8,
    before_bytes: usize,
    after_bytes: usize,
    before_sha256: [64]u8,
    after_sha256: [64]u8,

    pub fn deinit(self: MutationEvidence, allocator: std.mem.Allocator) void {
        allocator.free(self.config_path);
        allocator.free(self.agent_id);
    }
};

var config_mutation_mutex: std.Thread.Mutex = .{};

const built_in_specs = [_]AgentSpec{
    .{
        .id = "general",
        .description = "Bounded general-purpose VAR1 child session with ticket discipline.",
        .when_to_use = "Use when no narrower specialist owns the task, or when the ticket needs a flexible executor with delegation latitude.",
        .instruction_capsule = "TICKET DISCIPLINE: own your assigned ticket — drive state to complete, mark complete when done, NEVER close (kernel-only). KEEP the checkpoint summary current (>=3 sentences: status, evidence, next action) so the parent and siblings can read your state live. Return a concise SITREP: findings, evidence paths, uncertainty, blockers, residual risk. Evidence-first: every claim carries file:line or command receipt.",
        .route_role = .general,
        .execution_kind = .agent_session,
        .capability_profile_id = "subagent",
        .max_steps = 96,
        .max_tool_calls = 64,
        .max_children = 2,
        .output_contract = "var1.sitrep.v1",
        .doctrine_tags = "ticket-discipline evidence-first checkpoint-live no-parallel-systems capability-truth",
        .ticket_ownership = true,
        .checkpoint_contract = "var1.summary.v1",
        .autonomy = "bounded",
    },
    .{
        .id = "recon",
        .description = "Read-only repository or evidence reconnaissance. IX/IEX search, exact provenance.",
        .when_to_use = "Use when ownership, architecture, dependencies, or exact source evidence must be mapped before any decision or mutation.",
        .instruction_capsule = "INSPECT ONLY. Evidence-first: cite exact paths, file:line, and commands; record uncertainty and residual risk; never guess — source or retract. Use ix/IEX search contracts; never substitute ad hoc readers. Findings-ledger shape: defect/owner/evidence/acceptance. Keep the checkpoint summary current.",
        .route_role = .recon,
        .execution_kind = .agent_session,
        .capability_profile_id = "recon",
        .max_steps = 64,
        .max_tool_calls = 48,
        .max_children = 0,
        .output_contract = "var1.recon_sitrep.v1",
        .doctrine_tags = "evidence-first harvest-before-originate findings-ledger source-or-retract no-parallel-systems",
        .ticket_ownership = true,
        .checkpoint_contract = "var1.summary.v1",
        .autonomy = "directed",
    },
    .{
        .id = "planner",
        .description = "One-turn plan synthesis from supplied evidence. Planning-spec protocol distillation.",
        .when_to_use = "Use after reconnaissance when supplied evidence must become an ordered, gated implementation contract.",
        .instruction_capsule = "USE ONLY SUPPLIED CONTEXT. Return an ordered plan: decomposed phases, dependency edges, invariants preserved, proof gates per phase, blocker protocol, stop conditions. Every phase maps to source evidence; no invented owners. State the falsification hook that catches a shallow execution.",
        .route_role = .planning,
        .execution_kind = .model_task,
        .capability_profile_id = "model_task",
        .max_steps = 1,
        .max_tool_calls = 0,
        .max_children = 0,
        .output_contract = "var1.plan.v1",
        .doctrine_tags = "proof-gated evidence-anchored invariant-preserving no-pretend-completion",
        .ticket_ownership = false,
        .checkpoint_contract = "var1.summary.v1",
        .autonomy = "directed",
    },
    .{
        .id = "spec",
        .description = "One-turn spec/contract author. System boundary, owners, dependency order, ratchet targets.",
        .when_to_use = "Use when a feature or chain needs an authoritative parent spec: boundary, canonical owners, sequencing, improvement ratchet, research agenda.",
        .instruction_capsule = "AUTHOR THE CONTRACT, not prose. Name the system boundary, canonical owners, dependency and risk ordering, chain-level improvement ratchet (better-than-before deltas), and bounded research agenda with evidence surfaces. Source-message anchors verbatim; every slice carries a proof obligation. Reject skeletal specs.",
        .route_role = .planning,
        .execution_kind = .model_task,
        .capability_profile_id = "model_task",
        .max_steps = 1,
        .max_tool_calls = 0,
        .max_children = 0,
        .output_contract = "var1.spec.v1",
        .doctrine_tags = "capability-truth evidence-anchored ratchet-monotonic source-message-provenance",
        .ticket_ownership = false,
        .checkpoint_contract = "var1.summary.v1",
        .autonomy = "directed",
    },
    .{
        .id = "compactor",
        .description = "One-turn dense summary wording over supplied artifacts. Entry-aware compression.",
        .when_to_use = "Use when supplied evidence must be compressed without losing decisions, owners, or unresolved state.",
        .instruction_capsule = "PRESERVE decisions, evidence, active state, unresolved risks, and exact owner paths; compacted ranges stay source-truth under the full transcript. Do not invent facts. Bounded aggressiveness: higher compaction may re-summarize; never drop a decision or owner.",
        .route_role = .compaction,
        .execution_kind = .model_task,
        .capability_profile_id = "model_task",
        .max_steps = 1,
        .max_tool_calls = 0,
        .max_children = 0,
        .output_contract = "var1.compaction_summary.v1",
        .doctrine_tags = "entry-aware append-only no-fact-invention source-truth-preserved",
        .ticket_ownership = false,
        .checkpoint_contract = "var1.summary.v1",
        .autonomy = "directed",
    },
    .{
        .id = "implementer",
        .description = "Bounded implementation branch with read, write, and command capability. Ticket owner.",
        .when_to_use = "Use when one isolated file or module slice can be implemented and validated independently as its own ticket.",
        .instruction_capsule = "TICKET OWNER: own the assigned ticket, drive it to complete, mark complete ONLY when proven (tests + evidence), NEVER close (kernel-only). Own only the assigned files; preserve concurrent work. Write-capable tools emit effect evidence: resolved path, byte counts, hashes. Keep the checkpoint summary current; return a diff-grounded SITREP with validation receipts.",
        .route_role = .implementation,
        .execution_kind = .agent_session,
        .capability_profile_id = "write",
        .max_steps = 128,
        .max_tool_calls = 96,
        .max_children = 0,
        .output_contract = "var1.implementation_sitrep.v1",
        .doctrine_tags = "ticket-discipline capability-truth effect-evidence diff-grounded no-pretend-completion",
        .ticket_ownership = true,
        .checkpoint_contract = "var1.summary.v1",
        .autonomy = "bounded",
    },
    .{
        .id = "doc_writer",
        .description = "High-step document writer for large file persistence with verification.",
        .when_to_use = "Use when a large file (docs, ledgers, generated artifacts) must be written and verified in bounded slices.",
        .instruction_capsule = "PERSIST IN SLICES: write, verify byte counts and structure, then continue; never leave a torn tail. Docs describe shipped runtime truth, not intended future state. Keep the checkpoint summary current; return a SITREP with written paths, byte counts, and verification receipts.",
        .route_role = .implementation,
        .execution_kind = .agent_session,
        .capability_profile_id = "write",
        .max_steps = 120,
        .max_tool_calls = 60,
        .max_children = 0,
        .output_contract = "var1.implementation_sitrep.v1",
        .doctrine_tags = "capability-truth effect-evidence docs-ship-runtime-truth torn-write-safe",
        .ticket_ownership = true,
        .checkpoint_contract = "var1.summary.v1",
        .autonomy = "directed",
    },
    .{
        .id = "scaffold",
        .description = "Chain scaffold: decomposes work into planning-spec chains / findings-ledgers with proof gates.",
        .when_to_use = "Use when work requires decomposed execution chains, state-machine handoff, invariant preservation, or crash recovery.",
        .instruction_capsule = "SCAFFOLD THE CHAIN: source-message anchors verbatim -> category purity -> repository ownership recon -> parent + lettered units -> dependency edges -> quality gates (test floor, idempotency contract, blast radius, rollback) -> evidence-gated single-move archival -> terminal QC review. Every unit carries entry state, exit state, handoff contract. Skeletal slices are failures.",
        .route_role = .implementation,
        .execution_kind = .agent_session,
        .capability_profile_id = "subagent",
        .max_steps = 128,
        .max_tool_calls = 96,
        .max_children = 2,
        .output_contract = "var1.scaffold.v1",
        .doctrine_tags = "proof-gated evidence-anchored handoff-complete crash-recovery single-move-archival",
        .ticket_ownership = true,
        .checkpoint_contract = "var1.summary.v1",
        .autonomy = "self_directed",
    },
    .{
        .id = "orchestrator_parent",
        .description = "Parent orchestrator: aggressive fan-out delegation, live monitoring, ticket assignment and closure review.",
        .when_to_use = "Use when orchestrating multi-agent work with constant parallel delegation, ticket assignment, and completion review.",
        .instruction_capsule = "DELEGATION DISCIPLINE — AGGRESSIVE: fan out ALL branchable work immediately; never one agent when two can run parallel; background:true always; poll agent_status non-blocking; never sit idle — launch the next independent stream while agents fly. TICKET AUTHORITY: assign tickets to specialists; each agent owns its ticket state; agents mark complete but ONLY YOU close or reopen/reassign, ALWAYS with written reasoning; a reopened ticket is re-assigned immediately to a fresh specialist. Read child checkpoint summaries to synthesize; reconcile contradictions; publish ONE parent-owned conclusion. Live status table after every action.",
        .route_role = .general,
        .execution_kind = .agent_session,
        .capability_profile_id = "subagent",
        .max_steps = 256,
        .max_tool_calls = 128,
        .max_children = 12,
        .output_contract = "var1.orchestration_sitrep.v1",
        .doctrine_tags = "ticket-discipline parallel-fanout live-monitor reconcile-contradictions parent-owned-conclusion close-with-reasoning",
        .ticket_ownership = true,
        .checkpoint_contract = "var1.summary.v1",
        .autonomy = "self_directed",
    },
    .{
        .id = "harvester",
        .description = "Competitive intelligence harvester: nsect/insect research, source-proof benchmarks.",
        .when_to_use = "Use when competitor research, market analysis, feature benchmarking, or evidence harvesting must precede a decision.",
        .instruction_capsule = "RESEARCH HARVEST DOCTRINE — THREE LAWS: (1) NEVER GUESS: source every claim to URL or file:line; (2) HARVEST WIDE: 3-5+ queries per competitor, then benchmark deep against our source; (3) PROVE OR RETRACT. Competitor mistakes are free education, successes are stolen blueprints. Six-competitor floor for decisions; twelve for deep mechanisms. Write findings to the evidence ledger with provenance.",
        .route_role = .recon,
        .execution_kind = .agent_session,
        .capability_profile_id = "recon",
        .max_steps = 80,
        .max_tool_calls = 64,
        .max_children = 0,
        .output_contract = "var1.harvest_report.v1",
        .doctrine_tags = "harvest-before-originate six-competitor-floor source-or-retract evidence-ledger benchmark-deep",
        .ticket_ownership = true,
        .checkpoint_contract = "var1.summary.v1",
        .autonomy = "bounded",
    },
    .{
        .id = "reviewer",
        .description = "One-turn supplied-artifact review. QC 4/4 maintainer judgment.",
        .when_to_use = "Use when a bounded artifact set needs an independent findings-first review without tool access.",
        .instruction_capsule = "QC 4/4 JUDGMENT: structure (maintainer-grade ownership, no parallel systems), contract truth (capability proven through the real consumer path), test pressure (falsification, not ceremony), code quality (anti-pattern sweep: hidden fallbacks, drift, fake simplicity). Severity-ordered findings with exact referents and falsification notes. No professional does this — why would he do it like that? flags amateur tells.",
        .route_role = .review,
        .execution_kind = .model_task,
        .capability_profile_id = "model_task",
        .max_steps = 1,
        .max_tool_calls = 0,
        .max_children = 0,
        .output_contract = "var1.review.v1",
        .doctrine_tags = "findings-first capability-truth no-parallel-systems falsification-pressure maintainer-craft",
        .ticket_ownership = false,
        .checkpoint_contract = "var1.summary.v1",
        .autonomy = "directed",
    },
    .{
        .id = "validator",
        .description = "Read-only validation branch for independent falsification proof.",
        .when_to_use = "Use when commands or source checks can independently falsify an implementation claim without mutation.",
        .instruction_capsule = "FALSIFY, DO NOT CONFIRM: run bounded validation probes without mutation; treat a passing test as valuable only when it proves an invariant a shallow implementation would violate. Return commands, observed outputs, failures, and residual risk. Adversarial pipeline probes: poisoned suffixes, stale owners, torn writes, same-millisecond bursts.",
        .route_role = .validation,
        .execution_kind = .agent_session,
        .capability_profile_id = "recon",
        .max_steps = 64,
        .max_tool_calls = 48,
        .max_children = 0,
        .output_contract = "var1.validation_sitrep.v1",
        .doctrine_tags = "falsification-pressure adversarial-probes capability-truth no-green-tests",
        .ticket_ownership = true,
        .checkpoint_contract = "var1.summary.v1",
        .autonomy = "directed",
    },
};

/// Compiled floors remain available for receipt compatibility and legacy
/// callers. Live discovery and launch must use loadRegistry instead.
pub fn all() []const AgentSpec {
    return built_in_specs[0..];
}

pub fn resolve(spec_id: []const u8) Error!AgentSpec {
    return findBuiltIn(spec_id) orelse Error.UnknownAgentSpec;
}

/// Parse the canonical config on every call. No process-local cache exists:
/// external edits and configure_agent mutations become visible on the next
/// catalog read or launch admission.
pub fn loadRegistry(allocator: std.mem.Allocator, workspace_root: []const u8) !Registry {
    var parsed = try config_file.readValidatedDocument(allocator, workspace_root);
    defer parsed.deinit();
    return loadRegistryFromValue(allocator, parsed.value);
}

pub fn loadRegistryFromValue(allocator: std.mem.Allocator, document: std.json.Value) !Registry {
    try config_file.validateDocumentValue(document);
    const root = document.object;
    const definitions = if (root.get("agents")) |agents_value|
        if (agents_value.object.get("definitions")) |definitions_value| definitions_value.object else null
    else
        null;

    var effective = std.array_list.Managed(AgentSpec).init(allocator);
    errdefer {
        for (effective.items) |spec| deinitOwnedSpec(allocator, spec);
        effective.deinit();
    }

    for (built_in_specs) |base| {
        const override = if (definitions) |items|
            if (items.get(base.id)) |value| value.object else null
        else
            null;
        if (override) |object| {
            if (object.get("extends")) |extends_value| {
                if (extends_value != .null) return Error.InvalidAgentDefinition;
            }
            if (!optionalBool(object, "enabled", true)) continue;
        }
        try appendEffective(&effective, base.id, base, override);
    }

    if (definitions) |items| {
        var iterator = items.iterator();
        while (iterator.next()) |entry| {
            if (findBuiltIn(entry.key_ptr.*) != null) continue;
            const definition = entry.value_ptr.object;
            const extends_value = definition.get("extends") orelse return Error.UnknownAgentBase;
            if (extends_value != .string) return Error.UnknownAgentBase;
            const base = findBuiltIn(extends_value.string) orelse return Error.UnknownAgentBase;
            if (!optionalBool(definition, "enabled", true)) continue;
            try appendEffective(&effective, entry.key_ptr.*, base, definition);
        }
    }

    if (effective.items.len == 0) return Error.EmptyAgentRegistry;
    return .{
        .allocator = allocator,
        .specs = try effective.toOwnedSlice(),
    };
}

/// Compact model-facing selection data. Private instruction capsules stay out
/// of the parent context and are injected only into the selected child prompt.
pub fn renderCatalog(allocator: std.mem.Allocator, registry: Registry) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    const writer = output.writer();
    try writer.writeAll("{\"schema\":\"var1.agent_catalog.v1\",\"hotloaded\":true,\"agents\":[");
    for (registry.specs, 0..) |spec, index| {
        if (index > 0) try writer.writeByte(',');
        // Doctrine tags, ticket ownership, checkpoint contract, autonomy, and
        // effort are model-visible: the catalog IS the doctrine surface the
        // operator prompt steers with — no second prompt layer.
        try writer.print("{{\"id\":{f},\"description\":{f},\"when_to_use\":{f},\"kind\":{f},\"route_role\":{f},\"capability_profile\":{f},\"output_contract\":{f},\"doctrine\":{f},\"ticket_ownership\":{s},\"checkpoint\":{f},\"autonomy\":{f},\"effort\":{f}}}", .{
            std.json.fmt(spec.id, .{}),
            std.json.fmt(spec.description, .{}),
            std.json.fmt(spec.when_to_use, .{}),
            std.json.fmt(spec.execution_kind.label(), .{}),
            std.json.fmt(spec.route_role.label(), .{}),
            std.json.fmt(spec.capability_profile_id, .{}),
            std.json.fmt(spec.output_contract, .{}),
            std.json.fmt(spec.doctrine_tags, .{}),
            if (spec.ticket_ownership) "true" else "false",
            std.json.fmt(spec.checkpoint_contract, .{}),
            std.json.fmt(spec.autonomy, .{}),
            std.json.fmt(spec.effort, .{}),
        });
    }
    try writer.writeAll("]}");
    return output.toOwnedSlice();
}

/// Atomically upsert one editable definition, then validate the complete
/// effective registry before the config file becomes visible to readers.
pub fn upsertConfiguredAgent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    patch: DefinitionPatch,
) !MutationEvidence {
    config_mutation_mutex.lock();
    defer config_mutation_mutex.unlock();
    return mutateConfiguredAgent(allocator, workspace_root, .upsert, patch);
}

/// Reset removes the configured row. Built-in ids fall back to their compiled
/// floor; custom ids disappear from the next hot-loaded catalog.
pub fn resetConfiguredAgent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    agent_id: []const u8,
) !MutationEvidence {
    config_mutation_mutex.lock();
    defer config_mutation_mutex.unlock();
    return mutateConfiguredAgent(allocator, workspace_root, .reset, .{ .id = agent_id });
}

/// Hash the effective capability surface and execution ceilings for receipts.
pub fn capabilityHash(spec: AgentSpec, capability_profile_id: []const u8) ![64]u8 {
    const profile = try profile_contract.resolveProfile(capability_profile_id);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(spec.id);
    hasher.update("\x00");
    hasher.update(spec.execution_kind.label());
    hasher.update("\x00");
    hasher.update(spec.route_role.label());
    hasher.update("\x00");
    hasher.update(capability_profile_id);
    for (profile.allowed_tool_classes) |tool_class| {
        hasher.update("\x00");
        hasher.update(profile_contract.toolClassLabel(tool_class));
    }
    var budget_buffer: [96]u8 = undefined;
    const budget = try std.fmt.bufPrint(&budget_buffer, "{d}:{d}:{d}", .{ spec.max_steps, spec.max_tool_calls, spec.max_children });
    hasher.update(budget);
    // Behavioral surface: ticket ownership and autonomy change what a child
    // may do; receipts must reflect it.
    hasher.update("\x00");
    hasher.update(if (spec.ticket_ownership) "ticket_owner" else "no_ticket");
    hasher.update("\x00");
    hasher.update(spec.autonomy);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return hexDigest(digest);
}

pub fn contentHash(content: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    return hexDigest(digest);
}

fn appendEffective(
    list: *std.array_list.Managed(AgentSpec),
    id: []const u8,
    base: AgentSpec,
    override: ?std.json.ObjectMap,
) !void {
    const spec = try cloneEffective(list.allocator, id, base, override);
    errdefer deinitOwnedSpec(list.allocator, spec);
    try list.append(spec);
}

const MutationAction = enum { upsert, reset };

fn mutateConfiguredAgent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    action: MutationAction,
    patch: DefinitionPatch,
) !MutationEvidence {
    if (!isValidAgentId(patch.id)) return Error.InvalidAgentDefinition;
    const config_path = try config_file.ensure(allocator, workspace_root);
    errdefer allocator.free(config_path);
    const before = try fsutil.readTextAlloc(allocator, config_path);
    defer allocator.free(before);
    var parsed = try config_file.readValidatedDocument(allocator, workspace_root);
    defer parsed.deinit();
    const arena = parsed.arena.allocator();
    const root = &parsed.value.object;
    const agents = try ensureObjectField(arena, root, "agents");
    const definitions = try ensureObjectField(arena, agents, "definitions");

    // Instruction size cap: 8192 bytes
    if (patch.instruction) |instruction| {
        if (instruction.len > 8192) {
            return Error.InstructionTooLarge;
        }
    }

    // max_children > 0 requires max_tool_calls >= 1 (need launch_agent)
    if (patch.max_children) |mc| {
        if (mc > 0) {
            if (patch.max_tool_calls) |mtc| {
                if (mtc == 0) return Error.InvalidAgentDefinition;
            }
        }
    }

    switch (action) {
        .reset => _ = definitions.orderedRemove(patch.id),
        .upsert => {
            const definition = try ensureObjectField(arena, definitions, patch.id);
            if (patch.extends) |value| try putString(arena, definition, "extends", value);
            if (patch.enabled) |value| try putValue(arena, definition, "enabled", .{ .bool = value });
            if (patch.description) |value| try putString(arena, definition, "description", value);
            if (patch.when_to_use) |value| try putString(arena, definition, "when_to_use", value);
            if (patch.instruction) |value| try putString(arena, definition, "instruction", value);
            if (patch.route_role) |value| try putString(arena, definition, "route_role", value);
            if (patch.max_steps) |value| try putInteger(arena, definition, "max_steps", value);
            if (patch.max_tool_calls) |value| try putInteger(arena, definition, "max_tool_calls", value);
            if (patch.max_children) |value| try putInteger(arena, definition, "max_children", value);
            if (patch.output_contract) |value| try putString(arena, definition, "output_contract", value);
            if (patch.doctrine_tags) |value| try putString(arena, definition, "doctrine_tags", value);
            if (patch.ticket_ownership) |value| try putValue(arena, definition, "ticket_ownership", .{ .bool = value });
            if (patch.checkpoint_contract) |value| try putString(arena, definition, "checkpoint_contract", value);
            if (patch.autonomy) |value| try putString(arena, definition, "autonomy", value);
            if (patch.effort) |value| try putString(arena, definition, "effort", value);
            if (patch.temperature) |value| try putValue(arena, definition, "temperature", .{ .float = value });
        },
    }

    var effective = try loadRegistryFromValue(allocator, parsed.value);
    effective.deinit();
    const after = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(parsed.value, .{ .whitespace = .indent_2 })});
    defer allocator.free(after);
    try fsutil.writeText(config_path, after);

    return .{
        .config_path = config_path,
        .action = @tagName(action),
        .agent_id = try allocator.dupe(u8, patch.id),
        .before_bytes = before.len,
        .after_bytes = after.len,
        .before_sha256 = contentHash(before),
        .after_sha256 = contentHash(after),
    };
}

fn ensureObjectField(
    allocator: std.mem.Allocator,
    owner: *std.json.ObjectMap,
    key: []const u8,
) !*std.json.ObjectMap {
    if (owner.getPtr(key)) |value| {
        if (value.* != .object) return Error.InvalidAgentDefinition;
        return &value.object;
    }
    const object = std.json.ObjectMap.init(allocator);
    try owner.put(try allocator.dupe(u8, key), .{ .object = object });
    return &owner.getPtr(key).?.object;
}

fn putString(allocator: std.mem.Allocator, owner: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try putValue(allocator, owner, key, .{ .string = try allocator.dupe(u8, value) });
}

fn putInteger(allocator: std.mem.Allocator, owner: *std.json.ObjectMap, key: []const u8, value: usize) !void {
    const integer = std.math.cast(i64, value) orelse return Error.InvalidAgentDefinition;
    try putValue(allocator, owner, key, .{ .integer = integer });
}

fn putValue(allocator: std.mem.Allocator, owner: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    try owner.put(try allocator.dupe(u8, key), value);
}

fn cloneEffective(
    allocator: std.mem.Allocator,
    id: []const u8,
    base: AgentSpec,
    override: ?std.json.ObjectMap,
) !AgentSpec {
    const object = override;
    const description = if (object) |value| optionalString(value, "description", base.description) else base.description;
    const when_to_use = if (object) |value| optionalString(value, "when_to_use", base.when_to_use) else base.when_to_use;
    const instruction = if (object) |value| optionalString(value, "instruction", base.instruction_capsule) else base.instruction_capsule;
    const role_text = if (object) |value| optionalString(value, "route_role", base.route_role.label()) else base.route_role.label();
    const route_role = routes.RouteRole.parse(role_text) catch return Error.InvalidAgentDefinition;
    const max_steps = if (object) |value| optionalUsize(value, "max_steps", base.max_steps) else base.max_steps;
    const max_tool_calls = if (object) |value| optionalUsize(value, "max_tool_calls", base.max_tool_calls) else base.max_tool_calls;
    const max_children = if (object) |value| optionalUsize(value, "max_children", base.max_children) else base.max_children;
    const output_contract = if (object) |value| optionalString(value, "output_contract", base.output_contract) else base.output_contract;
    const doctrine_tags = if (object) |value| optionalString(value, "doctrine_tags", base.doctrine_tags) else base.doctrine_tags;
    const ticket_ownership = if (object) |value| optionalBool(value, "ticket_ownership", base.ticket_ownership) else base.ticket_ownership;
    const checkpoint_contract = if (object) |value| optionalString(value, "checkpoint_contract", base.checkpoint_contract) else base.checkpoint_contract;
    const autonomy = if (object) |value| optionalString(value, "autonomy", base.autonomy) else base.autonomy;
    if (!isValidAutonomy(autonomy)) return Error.InvalidAgentDefinition;
    const effort = if (object) |value| optionalString(value, "effort", base.effort) else base.effort;
    const temperature = if (object) |value| optionalFloat(value, "temperature", base.temperature) else base.temperature;
    if (temperature != -1 and (temperature < 0 or temperature > 2)) return Error.InvalidAgentDefinition;

    try validateEffective(base, max_steps, max_tool_calls, max_children);
    _ = try profile_contract.resolveProfile(base.capability_profile_id);

    const id_owned = try allocator.dupe(u8, id);
    errdefer allocator.free(id_owned);
    const description_owned = try allocator.dupe(u8, description);
    errdefer allocator.free(description_owned);
    const when_owned = try allocator.dupe(u8, when_to_use);
    errdefer allocator.free(when_owned);
    const instruction_owned = try allocator.dupe(u8, instruction);
    errdefer allocator.free(instruction_owned);
    const profile_owned = try allocator.dupe(u8, base.capability_profile_id);
    errdefer allocator.free(profile_owned);
    const contract_owned = try allocator.dupe(u8, output_contract);
    errdefer allocator.free(contract_owned);
    const doctrine_owned = try allocator.dupe(u8, doctrine_tags);
    errdefer allocator.free(doctrine_owned);
    const checkpoint_owned = try allocator.dupe(u8, checkpoint_contract);
    errdefer allocator.free(checkpoint_owned);
    const autonomy_owned = try allocator.dupe(u8, autonomy);
    errdefer allocator.free(autonomy_owned);
    const effort_owned: []u8 = if (effort.len > 0) try allocator.dupe(u8, effort) else @constCast("");

    return .{
        .id = id_owned,
        .description = description_owned,
        .when_to_use = when_owned,
        .instruction_capsule = instruction_owned,
        .route_role = route_role,
        .execution_kind = base.execution_kind,
        .capability_profile_id = profile_owned,
        .max_steps = max_steps,
        .max_tool_calls = max_tool_calls,
        .max_children = max_children,
        .output_contract = contract_owned,
        .doctrine_tags = doctrine_owned,
        .ticket_ownership = ticket_ownership,
        .checkpoint_contract = checkpoint_owned,
        .autonomy = autonomy_owned,
        .effort = effort_owned,
        .temperature = temperature,
    };
}

/// Autonomy vocabulary is closed: directed / bounded / self_directed.
/// Anything else is a schema violation, not a runtime fallback.
fn isValidAutonomy(value: []const u8) bool {
    return std.mem.eql(u8, value, "directed") or
        std.mem.eql(u8, value, "bounded") or
        std.mem.eql(u8, value, "self_directed");
}

fn validateEffective(base: AgentSpec, max_steps: usize, max_tool_calls: usize, max_children: usize) !void {
    if (max_steps == 0 or max_steps > 4096 or max_tool_calls > 4096 or max_children > 64) return Error.InvalidAgentDefinition;
    if (base.execution_kind == .model_task) {
        if (max_steps != 1 or max_tool_calls != 0 or max_children != 0) return Error.InvalidAgentDefinition;
        return;
    }
    if (max_tool_calls == 0) return Error.InvalidAgentDefinition;
    const profile = try profile_contract.resolveProfile(base.capability_profile_id);
    if (!profile.delegation_policy.allow_child_launch and max_children != 0) return Error.InvalidAgentDefinition;
}

fn findBuiltIn(spec_id: []const u8) ?AgentSpec {
    for (built_in_specs) |spec| {
        if (std.mem.eql(u8, spec.id, spec_id)) return spec;
    }
    return null;
}

fn isValidAgentId(value: []const u8) bool {
    if (value.len == 0 or value.len > 64 or value[0] < 'a' or value[0] > 'z') return false;
    for (value[1..]) |character| {
        if ((character >= 'a' and character <= 'z') or
            (character >= '0' and character <= '9') or
            character == '_') continue;
        return false;
    }
    return true;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8, default: []const u8) []const u8 {
    const value = object.get(key) orelse return default;
    if (value == .null) return default;
    return value.string;
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const value = object.get(key) orelse return default;
    if (value == .null) return default;
    return value.bool;
}

fn optionalUsize(object: std.json.ObjectMap, key: []const u8, default: usize) usize {
    const value = object.get(key) orelse return default;
    if (value == .null) return default;
    return std.math.cast(usize, value.integer) orelse default;
}

fn optionalFloat(object: std.json.ObjectMap, key: []const u8, default: f64) f64 {
    const value = object.get(key) orelse return default;
    if (value == .null) return default;
    return value.float;
}

fn deinitOwnedSpec(allocator: std.mem.Allocator, spec: AgentSpec) void {
    allocator.free(spec.id);
    allocator.free(spec.description);
    allocator.free(spec.when_to_use);
    allocator.free(spec.instruction_capsule);
    allocator.free(spec.capability_profile_id);
    allocator.free(spec.output_contract);
    allocator.free(spec.doctrine_tags);
    allocator.free(spec.checkpoint_contract);
    allocator.free(spec.autonomy);
    if (spec.effort.len > 0) allocator.free(spec.effort);
}

fn hexDigest(digest: [32]u8) [64]u8 {
    const chars = "0123456789abcdef";
    var result: [64]u8 = undefined;
    for (digest, 0..) |byte, index| {
        result[index * 2] = chars[byte >> 4];
        result[index * 2 + 1] = chars[byte & 0x0f];
    }
    return result;
}

test "agent specs map specialist identity to route and bounded execution" {
    const recon = try resolve("recon");
    try std.testing.expectEqual(routes.RouteRole.recon, recon.route_role);
    try std.testing.expectEqual(@as(usize, 0), recon.max_children);
    const planner = try resolve("planner");
    try std.testing.expectEqual(routes.RouteRole.planning, planner.route_role);
    try std.testing.expectEqual(routes.ExecutionKind.model_task, planner.execution_kind);
    try std.testing.expectEqualStrings("model_task", planner.capability_profile_id);
    try std.testing.expectEqual(@as(usize, 1), planner.max_steps);
    try std.testing.expectEqual(@as(usize, 0), planner.max_tool_calls);
    try std.testing.expectError(Error.UnknownAgentSpec, resolve("agent_for_everything"));
}

test "capability and content hashes are deterministic and domain separated" {
    const recon = try resolve("recon");
    const first = try capabilityHash(recon, "recon");
    const second = try capabilityHash(recon, "recon");
    try std.testing.expectEqualStrings(first[0..], second[0..]);
    try std.testing.expect(!std.mem.eql(u8, first[0..], contentHash("recon")[0..]));
}

test "custom personas inherit fixed capability floors" {
    const document =
        \\{"version":1,"agents":{"orchestrator_only":true,"definitions":{"frontend_recon":{"extends":"recon","description":"Frontend ownership recon.","when_to_use":"Use for frontend ownership.","instruction":"Inspect frontend only.","route_role":"validation","max_steps":20,"max_tool_calls":10,"max_children":0,"output_contract":"var1.frontend_recon.v1"}}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    var registry = try loadRegistryFromValue(std.testing.allocator, parsed.value);
    defer registry.deinit();
    const custom = try registry.resolve("frontend_recon");
    try std.testing.expectEqual(routes.ExecutionKind.agent_session, custom.execution_kind);
    try std.testing.expectEqualStrings("recon", custom.capability_profile_id);
    try std.testing.expectEqual(routes.RouteRole.validation, custom.route_role);
    try std.testing.expectEqual(@as(usize, 10), custom.max_tool_calls);
}

test "custom personas cannot escalate inherited model task capability" {
    const document =
        \\{"version":1,"agents":{"definitions":{"unsafe_planner":{"extends":"planner","max_steps":2,"max_tool_calls":1}}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    try std.testing.expectError(Error.InvalidAgentDefinition, loadRegistryFromValue(std.testing.allocator, parsed.value));
}

test "compact catalog omits private instruction capsules" {
    const document = "{\"version\":1}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    var registry = try loadRegistryFromValue(std.testing.allocator, parsed.value);
    defer registry.deinit();
    const catalog = try renderCatalog(std.testing.allocator, registry);
    defer std.testing.allocator.free(catalog);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "when_to_use") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "instruction_capsule") == null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "Inspect only. Return findings") == null);
}

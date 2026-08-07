const std = @import("std");

pub const Error = error{
    UnsupportedCapabilityProfile,
    UnsupportedCapability,
};

pub const ToolClass = enum {
    file_read,
    file_write,
    command,
    scheduling,
    delegation,
    workspace_state,
};

pub const ProviderPolicy = enum {
    inherit_parent,
};

pub const BudgetPolicy = struct {
    max_scope_depth_without_reason: usize = 1,
    max_contact_budget_without_reason: usize = 1,
};

pub const DelegationPolicy = struct {
    allow_child_launch: bool = true,
};

pub const CapabilityProfile = struct {
    id: []const u8,
    allowed_tool_classes: []const ToolClass,
    provider_policy: ProviderPolicy,
    budget_policy: BudgetPolicy,
    delegation_policy: DelegationPolicy,
};

const subagent_tool_classes = [_]ToolClass{
    .file_read,
    .file_write,
    .command,
    .delegation,
};

const root_tool_classes = [_]ToolClass{
    .file_read,
    .file_write,
    .command,
    .scheduling,
    .delegation,
    .workspace_state,
};

// Branch-scoped profiles (roadmap P0-5c). Each restricts the tool set to
// the minimum the branch type needs — least-privilege per branch.
const recon_tool_classes = [_]ToolClass{
    .file_read,
};

const write_branch_tool_classes = [_]ToolClass{
    .file_read,
    .file_write,
    .command,
};

const model_task_tool_classes = [_]ToolClass{};

pub fn defaultSubagentProfile() CapabilityProfile {
    return .{
        .id = "subagent",
        .allowed_tool_classes = subagent_tool_classes[0..],
        .provider_policy = .inherit_parent,
        .budget_policy = .{},
        .delegation_policy = .{},
    };
}

pub fn rootProfile() CapabilityProfile {
    return .{
        .id = "root",
        .allowed_tool_classes = root_tool_classes[0..],
        .provider_policy = .inherit_parent,
        .budget_policy = .{
            .max_scope_depth_without_reason = 1,
            .max_contact_budget_without_reason = 1,
        },
        .delegation_policy = .{},
    };
}

/// Recon branch profile: read-only, no delegation, tight budget.
/// For research, codebase reconnaissance, and audit branches that
/// should never mutate files or launch sub-branches.
pub fn reconBranchProfile() CapabilityProfile {
    return .{
        .id = "recon",
        .allowed_tool_classes = recon_tool_classes[0..],
        .provider_policy = .inherit_parent,
        .budget_policy = .{
            .max_scope_depth_without_reason = 0,
            .max_contact_budget_without_reason = 0,
        },
        .delegation_policy = .{ .allow_child_launch = false },
    };
}

/// Write branch profile: read + write, no delegation.
/// For branches that mutate files but should not fan out further.
pub fn writeBranchProfile() CapabilityProfile {
    return .{
        .id = "write",
        .allowed_tool_classes = write_branch_tool_classes[0..],
        .provider_policy = .inherit_parent,
        .budget_policy = .{
            .max_scope_depth_without_reason = 0,
            .max_contact_budget_without_reason = 0,
        },
        .delegation_policy = .{ .allow_child_launch = false },
    };
}

/// Model tasks receive supplied context only and cannot dispatch tools.
pub fn modelTaskProfile() CapabilityProfile {
    return .{
        .id = "model_task",
        .allowed_tool_classes = model_task_tool_classes[0..],
        .provider_policy = .inherit_parent,
        .budget_policy = .{
            .max_scope_depth_without_reason = 0,
            .max_contact_budget_without_reason = 0,
        },
        .delegation_policy = .{ .allow_child_launch = false },
    };
}

pub fn resolveProfile(profile_id: []const u8) Error!CapabilityProfile {
    if (std.mem.eql(u8, profile_id, "subagent")) return defaultSubagentProfile();
    if (std.mem.eql(u8, profile_id, "root")) return rootProfile();
    if (std.mem.eql(u8, profile_id, "recon")) return reconBranchProfile();
    if (std.mem.eql(u8, profile_id, "write")) return writeBranchProfile();
    if (std.mem.eql(u8, profile_id, "model_task")) return modelTaskProfile();
    return Error.UnsupportedCapabilityProfile;
}

pub fn allowsToolClass(capability_profile: CapabilityProfile, tool_class: ToolClass) bool {
    for (capability_profile.allowed_tool_classes) |allowed| {
        if (allowed == tool_class) return true;
    }
    return false;
}

pub fn ensureToolClass(capability_profile: CapabilityProfile, tool_class: ToolClass) Error!void {
    if (!allowsToolClass(capability_profile, tool_class)) return Error.UnsupportedCapability;
}

pub fn toolClassLabel(tool_class: ToolClass) []const u8 {
    return switch (tool_class) {
        .file_read => "file_read",
        .file_write => "file_write",
        .command => "command",
        .scheduling => "scheduling",
        .delegation => "delegation",
        .workspace_state => "workspace_state",
    };
}

test "capability profiles resolve canonical ids and reject unknown ids" {
    const subagent = try resolveProfile("subagent");
    try std.testing.expect(std.mem.eql(u8, subagent.id, "subagent"));
    try std.testing.expect(allowsToolClass(subagent, .delegation));
    try std.testing.expect(!allowsToolClass(subagent, .workspace_state));

    const root = try resolveProfile("root");
    try std.testing.expect(allowsToolClass(root, .workspace_state));

    try std.testing.expectError(Error.UnsupportedCapabilityProfile, resolveProfile("org_agent"));
}

test "recon branch profile is read-only with no delegation" {
    const recon = try resolveProfile("recon");
    try std.testing.expect(std.mem.eql(u8, recon.id, "recon"));
    try std.testing.expect(allowsToolClass(recon, .file_read));
    try std.testing.expect(!allowsToolClass(recon, .file_write));
    try std.testing.expect(!allowsToolClass(recon, .delegation));
    try std.testing.expect(!allowsToolClass(recon, .workspace_state));
    try std.testing.expect(!recon.delegation_policy.allow_child_launch);
}

test "write branch profile allows read+write but not delegation" {
    const write_branch = try resolveProfile("write");
    try std.testing.expect(std.mem.eql(u8, write_branch.id, "write"));
    try std.testing.expect(allowsToolClass(write_branch, .file_read));
    try std.testing.expect(allowsToolClass(write_branch, .file_write));
    try std.testing.expect(!allowsToolClass(write_branch, .delegation));
    try std.testing.expect(!write_branch.delegation_policy.allow_child_launch);
}

test "branch profiles enforce least privilege via ensureToolClass" {
    const recon = try resolveProfile("recon");
    try ensureToolClass(recon, .file_read);
    try std.testing.expectError(Error.UnsupportedCapability, ensureToolClass(recon, .file_write));

    const write_branch = try resolveProfile("write");
    try ensureToolClass(write_branch, .file_write);
    try std.testing.expectError(Error.UnsupportedCapability, ensureToolClass(write_branch, .delegation));
}

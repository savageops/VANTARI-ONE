const std = @import("std");

pub const Error = error{
    UnsupportedCapabilityProfile,
    UnsupportedCapability,
};

pub const ToolClass = enum {
    file_read,
    file_write,
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
    .delegation,
};

const root_tool_classes = [_]ToolClass{
    .file_read,
    .file_write,
    .delegation,
    .workspace_state,
};

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

pub fn resolveProfile(profile_id: []const u8) Error!CapabilityProfile {
    if (std.mem.eql(u8, profile_id, "subagent")) return defaultSubagentProfile();
    if (std.mem.eql(u8, profile_id, "root")) return rootProfile();
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

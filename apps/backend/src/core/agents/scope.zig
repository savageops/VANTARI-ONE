const std = @import("std");
const profile_contract = @import("profile.zig");

pub const Error = error{
    UnsupportedDelegationScope,
    UnsupportedCapabilityProfile,
    UnsupportedCapability,
};

pub const DelegationValidationStatus = enum {
    unverified,
    self_checked,
    validated,
};

pub const DelegationScope = struct {
    scope_depth: usize = 1,
    contact_budget: usize = 1,
    validation_status: DelegationValidationStatus = .unverified,
    escalation_reason: ?[]const u8 = null,
    parent_capability_profile: ?[]const u8 = null,
};

pub fn parseValidationStatus(value: []const u8) Error!DelegationValidationStatus {
    if (std.mem.eql(u8, value, "unverified")) return .unverified;
    if (std.mem.eql(u8, value, "self_checked")) return .self_checked;
    if (std.mem.eql(u8, value, "validated")) return .validated;
    return Error.UnsupportedDelegationScope;
}

pub fn validationStatusLabel(status: DelegationValidationStatus) []const u8 {
    return switch (status) {
        .unverified => "unverified",
        .self_checked => "self_checked",
        .validated => "validated",
    };
}

pub fn escalationReasonLabel(scope: DelegationScope) []const u8 {
    return scope.escalation_reason orelse "none";
}

pub fn parentCapabilityProfileLabel(scope: DelegationScope) []const u8 {
    return scope.parent_capability_profile orelse "none";
}

pub fn validateDelegationScope(
    scope: DelegationScope,
    capability_profile: profile_contract.CapabilityProfile,
) Error!void {
    profile_contract.ensureToolClass(capability_profile, .delegation) catch |err| switch (err) {
        profile_contract.Error.UnsupportedCapability => return Error.UnsupportedCapability,
        profile_contract.Error.UnsupportedCapabilityProfile => return Error.UnsupportedCapabilityProfile,
    };

    if (!capability_profile.delegation_policy.allow_child_launch) return Error.UnsupportedDelegationScope;
    if (scope.scope_depth == 0 or scope.contact_budget == 0) return Error.UnsupportedDelegationScope;

    const expands_scope = scope.scope_depth > capability_profile.budget_policy.max_scope_depth_without_reason or
        scope.contact_budget > capability_profile.budget_policy.max_contact_budget_without_reason;
    if (expands_scope and !hasText(scope.escalation_reason)) return Error.UnsupportedDelegationScope;

    if (scope.parent_capability_profile) |profile_id| {
        _ = profile_contract.resolveProfile(profile_id) catch |err| switch (err) {
            profile_contract.Error.UnsupportedCapabilityProfile => return Error.UnsupportedCapabilityProfile,
            profile_contract.Error.UnsupportedCapability => return Error.UnsupportedCapability,
        };
    }
}

pub fn renderDelegationEvent(
    allocator: std.mem.Allocator,
    scope: DelegationScope,
    capability_profile: profile_contract.CapabilityProfile,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.delegation_scope.v1\",\"capability_profile\":\"{s}\",\"scope_depth\":{},\"contact_budget\":{},\"validation_status\":\"{s}\",\"escalation_reason\":{f},\"parent_capability_profile\":{f}}}",
        .{
            capability_profile.id,
            scope.scope_depth,
            scope.contact_budget,
            validationStatusLabel(scope.validation_status),
            std.json.fmt(scope.escalation_reason, .{}),
            std.json.fmt(scope.parent_capability_profile, .{}),
        },
    );
}

fn hasText(value: ?[]const u8) bool {
    const text = value orelse return false;
    return std.mem.trim(u8, text, " \t\r\n").len > 0;
}

test "delegation scope rejects unreasoned expansion" {
    const subagent = profile_contract.defaultSubagentProfile();

    try validateDelegationScope(.{}, subagent);
    try validateDelegationScope(.{
        .scope_depth = 2,
        .contact_budget = 3,
        .validation_status = .self_checked,
        .escalation_reason = "parallel bounded audit",
        .parent_capability_profile = "root",
    }, subagent);

    try std.testing.expectError(Error.UnsupportedDelegationScope, validateDelegationScope(.{
        .scope_depth = 2,
    }, subagent));
}

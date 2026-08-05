const std = @import("std");
const memory = @import("core/memory/store.zig");
const memory_tool = @import("core/tools/builtin/memory.zig");

test "memory owner compiles" {
    std.testing.refAllDecls(memory);
    std.testing.refAllDecls(memory_tool);
}

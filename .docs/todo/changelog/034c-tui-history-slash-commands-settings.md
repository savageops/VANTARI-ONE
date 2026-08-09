---
id: 034c
title: "Config write primitive + config/set RPC method"
parent: 034
status: pending
priority: high
blast_radius: high
category: feature
dependencies: []
next_todo: /todo/pending/034d-tui-history-slash-commands-settings.md
source_message_anchor: settings-config
source_message_excerpt: "we also need a flag for settings, so we can configure the config json without leaving the TUI, and the TUI reveals ALL configs"
source_message_proof_obligation: Implements the atomic config.json write primitive and the config/set RPC method that the settings panel will call.
idempotency_contract: conditionally-idempotent — safe if the key path is valid; a write that fails validation does not modify the file.
---

## Execute Now

Add an atomic, validated config.json write function to `config/file.zig` and a `config/set` RPC method in `stdio_rpc.zig` that the TUI settings panel will call to mutate configuration without leaving the TUI.

## Better-than-before

`config/file.zig` is currently read-only at runtime — no write function exists. This slice adds the missing primitive. Every config change today requires manually editing the JSON file. After this slice, the kernel can mutate config programmatically with validation, enabling self-tuning (already prompted) and the settings panel.

## Entry State

- `config/file.zig:243-245` `readValidatedDocument` reads + validates but never writes
- `config/file.zig:265-389` `validateDocumentShape` is the validation gate (rejects unknown keys, enforces `_help` pattern, bounds checks)
- `fsutil.zig:29-40` `writeText` provides atomic writes (atomicFile + rename)
- `shared/protocol/types.zig:8-23` has no `config/set` method
- `stdio_rpc.zig:429-478` dispatch table has no config handler

## Patch Surface

**Modifies:**
- `src/core/config/file.zig` — add `writeConfigKey(allocator, workspace_root, section, key, json_value_string)` and `setConfigValue` helper
- `src/shared/protocol/types.zig` — add `config_set = "config/set"` to methods, `config_set: bool = true` to Capabilities
- `src/host/stdio_rpc.zig` — add `handleConfigSet` dispatch branch

**Must not touch:**
- `config/default.json` — no new keys needed (the function works on arbitrary existing keys)
- The TUI — this is a kernel-side primitive only

## Detailed Requirements

1. **`writeConfigKey`** (`config/file.zig`):
   ```zig
   /// Atomically set one config key under a section. Reads the current document,
   /// mutates the key, re-validates the entire document, and writes atomically.
   /// Returns Error.InvalidConfig if validation fails (the file is not modified).
   pub fn writeConfigKey(
       allocator: std.mem.Allocator,
       workspace_root: []const u8,
       section: []const u8,      // "runtime", "prompts", "agents", etc.
       key: []const u8,          // "effort", "persona", "orchestrator_only", etc.
       value: std.json.Value,    // the new value (string, int, bool, object)
   ) !void
   ```
   Flow: `readValidatedDocument` → parse to `std.json.Value` → navigate to `section` → set `key` → re-serialize → `validateDocumentValue` on the result → if valid, `fsutil.writeText`; if invalid, return error WITHOUT writing.

2. **`config/set` RPC method** (`stdio_rpc.zig`):
   - Add to dispatch table: `if (std.mem.eql(u8, method, protocol_types.methods.config_set)) try handleConfigSet(...)`
   - `handleConfigSet` parses `{section, key, value}` from params, calls `config_file.writeConfigKey`, returns success/failure envelope
   - On success, the next provider turn will hot-load the new config (existing behavior — config is re-read per turn)

3. **`addConfigSectionKey`** (for the settings panel's "add new guardrail/persona" feature):
   ```zig
   /// Add a new key to a section that supports arbitrary entries (prompts.guardrails,
   /// agents.definitions). Validates the section supports additions.
   pub fn addConfigSectionKey(
       allocator, workspace_root, section, parent_key, new_key, value
   ) !void
   ```
   This is needed for "new ones can be added/created" per the user's request.

4. **Validation-before-write invariant**: the write function MUST validate the entire document after mutation and before the atomic write. A write that produces an invalid config MUST fail without modifying the file. This is non-negotiable — a corrupt config.json breaks the kernel.

## Rollback Procedure

Remove `writeConfigKey`/`addConfigSectionKey` from `file.zig`, remove the `config_set` method constant and dispatch branch. Config.json reverts to read-only. No data loss (config.json is unchanged).

## Exit State / Handoff Contract

- `writeConfigKey` and `addConfigSectionKey` exist in `config/file.zig`
- `config/set` RPC method is dispatchable
- `config/default.json` is untouched
- Next unit (034d) can call `config/set` from the TUI settings panel

## Validation

```bash
zig build test
```

**New tests:**
- `test "writeConfigKey sets a string value under runtime section"`
- `test "writeConfigKey sets a bool value under agents section"`
- `test "writeConfigKey rejects invalid key with validation error"`
- `test "writeConfigKey is atomic — invalid write does not modify file"`
- `test "writeConfigKey re-validates entire document after mutation"`
- `test "addConfigSectionKey adds new agent definition"`
- `test "config/set RPC round-trips through stdio"`
- `test "config/set rejects unknown section"`

**Manual proof:** `vantari config` shows current config → call config/set to change `runtime.effort` → verify config.json is updated → next session uses new effort.

# packages/tui

Vantari terminal user interface package. Pure Zig TUI primitives for future CLI and terminal harness surfaces.

This package is based on the Zig 0.15-compatible `libvaxis` branch by Tim Culverhouse, licensed under MIT.

## Contract

- Package identity: `vantari_tui`
- Public module: `tui`
- Toolchain: Zig `0.15.1`, matching `apps/backend/scripts/zigw.ps1`
- Upstream base: `rockorager/libvaxis` branch `zig-0.15`

## API Layers

- Low-level cell rendering, keyboard, mouse, terminal protocol, image, and parser primitives.
- Higher-level widgets such as text input, text view, table, scroll view, line numbers, and code view.
- `vxfw` widget framework primitives for reactive terminal layout where the runtime surface needs them.

## Consumer Build Wiring

```zig
const tui_mod = b.createModule(.{
    .root_source_file = b.path("../../packages/tui/src/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{
        .{ .name = "code_point", .module = zg_dep.module("code_point") },
        .{ .name = "Graphemes", .module = zg_dep.module("Graphemes") },
        .{ .name = "DisplayWidth", .module = zg_dep.module("DisplayWidth") },
        .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
    },
});

exe_mod.addImport("tui", tui_mod);
```

```zig
const tui = @import("tui");
```

## Validation

```powershell
..\..\apps\backend\scripts\zigw.ps1 build test --summary all
```

The package is intentionally local and source-owned. Do not reintroduce upstream `.git`, CI, flake, media, or detached package-manager state inside this directory.

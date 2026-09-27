# Active Plans

## Currently Active

- **[000-webgpu-port.md](000-webgpu-port.md)** - Port redfish_gl_zig to WebGPU (zgpu)
  - Next: **Step 1 - Skeleton: Window, Device, Clear, zgui**

## Port Progress

| Step | Description | Status |
|---|---|---|
| 0 | Project setup | ✅ 2026-09-27 |
| 1 | Skeleton: window, device, clear, zgui | |
| 2 | Math: zero-to-one depth | |
| 3a | One colored cube: shaders, bindings, pipelines, per-draw data | |
| 3b | Textures and all shapes, scene_tree | |
| 4 | glTF static meshes with PBR | |
| 5 | Skinning and animation | |
| 6 | bullets | |
| 7 | level_01 | |
| 8 | demo_app complete | |
| 9 | angrybot and remaining examples | |

## After the Port

Continue redfish_gl_zig's roadmap here: 016 motion patterns, 004 animation state machine,
005 scene management.

Consider moving from zgpu/Dawn to **wgpu-native** (the Rust `wgpu` crate behind the standard
`webgpu.h`, prebuilt releases, used by Bevy) via bronter/wgpu_native_zig. It gives an sRGB
surface and a maintained backend; the cost is replacing zgpu's `GraphicsContext` helpers
(pools, uniforms ring) and pointing zgui's backend at wgpu-native. Raw `wgpu.*` calls live
only in `src/core`, so the change stays mostly in `gpu_context.zig`.

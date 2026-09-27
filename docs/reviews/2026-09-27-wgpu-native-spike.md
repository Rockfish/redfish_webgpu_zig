# Decision: wgpu-native instead of zgpu/Dawn (2026-09-27)

## Decision

Build on **wgpu-native** (gfx-rs, the Rust `wgpu` crate behind `webgpu.h`), called through
`webgpu.h` translated by the build into `src/core/wgpu/`. No zgpu, no Zig binding package.

## Why not zgpu/Dawn

- Upstream zgpu HEAD (`e6d8103`) is what gui_test_webgpu pins; since late 2024 it has only
  had build-script updates.
- It links michal-z's prebuilt `libdawn.a` (~2023). That Dawn predates `wgpuSurfaceConfigure`,
  and its swapchain validation accepts only `BGRA8Unorm`: no sRGB surface.
- zgpu's `generateMipmaps` asserts square, power-of-two, ≤ 2048 textures and writes storage
  textures, which sRGB formats can't be.
- Fixing it means building Dawn ourselves and rewriting zgpu's ~3000-line `wgpu.zig`,
  `zgpu.zig`, and zgui's backend include path.

## Why not bronter/wgpu_native_zig

Last commit 2025-07-17, Zig 0.14, wgpu-native v25. Unmerged Zig 0.15/0.16 PRs, an open
"still maintained?" issue. The prebuilt wgpu-native releases are current (v29.0.1.1,
2026-06-23); only this Zig layer was stale, and translate-c removes the need for it.

## Spike results (branch `spike/wgpu-native`, merged into Step 1)

- `b.addTranslateC` on `webgpu.h` + `wgpu.h` works on Zig 0.16. Every struct field gets a
  zero default, so descriptors are `.{ ... }` with only the fields that matter. `*_INIT`
  macros don't translate; set non-zero defaults by hand (`depthSlice`).
- Surface: CAMetalLayer via `objc_msgSend`, `WGPUSurfaceSourceMetalLayer`. The surface offers
  `BGRA8UnormSrgb`; linear 0.5 clear shows as encoded gray (180 in a macOS screenshot,
  which converts to the display profile; exact 188 check waits for Step 8's readback).
- Async adapter/device requests: `CallbackMode_AllowProcessEvents` + `wgpuInstanceProcessEvents`.
- zgui unmodified with `.backend = .glfw`; imgui's `imgui_impl_wgpu.cpp` compiled against
  wgpu-native's headers. imgui 1.92.1's `BACKEND_WGPU` path predates wgpu-native 29;
  its `BACKEND_DAWN` path matches (`WGPUComputeState`, `WGPUVertexAttribute.nextInChain`).
  imgui 1.93 (2026-08-31) supports wgpu-native 29 under `BACKEND_WGPU`.
- Apple M1 Pro adapter limits: 8 bind groups, 16 vertex buffers, 65535 bindings per group,
  4 KB immediates. Devices get WebGPU defaults unless `requiredLimits` asks for more.
- Tested on an external monitor and the MacBook Retina screen: resize, dragging between
  screens, and Esc quit all clean, no validation errors.

## Costs accepted

- We own the thin layer zgpu provided: uniform ring buffer, mipmap generator (needed
  either way), error callbacks.
- wgpu-native upgrades mean fixing our calls against the new `webgpu.h` ourselves.

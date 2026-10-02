# redfish_webgpu_zig

A port of redfish_gl_zig (`/Users/john/Dev/Dev_Zig/redfish_gl_zig`) from OpenGL 4.1 to WebGPU,
using **wgpu-native** through a build-translated `webgpu.h`. A 3D engine for animated glTF models with PBR rendering.
Hobby project; readability for a returning reader matters more than cleverness.

## Read First

- **`docs/STYLE.md`**: the style guide. All code follows it; where existing code disagrees,
  the guide wins.
- **`docs/plans/active-plans.md`**: start here. The active plan, parked plans (each with
  its next step), and completed ones. Plans 001-016 came from redfish_gl_zig;
  `docs/plans/README.md` explains the workflow, including parking a plan with a
  "where it stands / next step" note. Record design discussions and decisions in the plan.
- **`docs/plans/000-webgpu-port.md`**: the completed port (steps, decisions, known issues).

## The Port in One Paragraph

Keep redfish_gl_zig's shape: same directories, files, type names, and call shapes. Only the
graphics API changes, plus the fixes needed to do it correctly. Correctness beats fidelity to
the GL code: establish the right WebGPU pattern even if it looks different from GL. When
porting a file, open the redfish_gl_zig version side by side and keep it recognizable.

## Status

The port is complete (plan 000, 2026-09-27): all apps run on wgpu-native, and `angrybot` is
the regression check. Since then:
- PBR edge-highlight fixes, orthographic picking, softer demo_app lights, the brace style pass
- Plan 016 motion patterns: `src/core/motion.zig` (`SmoothFollow`, `dampLookAt`,
  `moveToward`, `PathFollow`, `Shake`); `CameraGimbal` revived in `examples/camera_rig`
- Plan 017 shadows: `examples/shadows`, `DepthBias`, `ShadowMap` filter, `ShadowMapArray`
- Plan 018 anti-aliasing: 4x MSAA (`-Dmsaa`, default on), alpha-to-coverage for glTF MASK
- Plan 008 turrets: `core.motion` (`YawPitchAim`, `Sweep`), `core.FireControl`,
  `core.ballistics`; `examples/turrets` (track, sweep, mortar, programs, turret types)
- Plan 009 gravity bullets: `examples/bullets` steps with `core.ballistics` (G gravity, P paths)

Active plan: 010 input (phase 1: `Input.isDown` / `pressedOnce`, bullets mode and
global keys; next: `core.Input` alongside ImGui). See `docs/plans/active-plans.md`.

## Layout (target, mirrors redfish_gl_zig)

```
src/
├── core/         # Engine: gpu_context, shader, mesh, model, texture, animation, shapes, ...
│   └── wgpu/     # webgpu.h translated by the build, string-view helpers, Metal layer
├── math/         # Vec/Mat/Quat, column-major
└── containers/
examples/         # gpu_caps, draw_test, scene_tree, demo_app, animation_example, bullets, skybox, shadows, camera_rig, turrets
games/            # level_01, angrybot (regression reference)
assets/           # symlink to ../redfish_gl_zig/assets
assets_nas/       # symlink to /Volumes/Dev/Assets (glTF sample models), as in redfish
docs/
├── STYLE.md
├── plans/        # Numbered plans + active-plans.md
├── designs/      # Design notes
└── reviews/      # Reviews and decision records
```

## Reference Projects

- **redfish_gl_zig**: structure, names, behavior. Zig 0.16 idioms (`pub fn main(init: std.process.Init)`, `init.io`, `init.gpa`).
- **wgpu-native** (`gfx-rs/wgpu-native`): API reference is its `webgpu.h` / `wgpu.h`
  (fetched into `zig-pkg/`, and the translated Zig in `.zig-cache`).
- **gui_test_webgpu** (`/Users/john/Dev/Dev_Zig/gui_test_webgpu`): source of the zglfw and zgui
  pins. Its zgpu/Dawn setup is not used (see `docs/reviews/2026-09-27-wgpu-native-spike.md`).
- **small_wgpu_core**, **angry_wgpu_rust** (`/Users/john/Dev/Dev_Rust/`): earlier work on the same
  wgpu. Reuse lessons, not the bind group layout (it needs 7 groups; WebGPU defaults allow 4).

## Key WebGPU Rules (details in STYLE.md section 9)

- Raw WebGPU calls only in `src/core`; C API used as translated (`const c = wgpu.c;`)
- Bind groups: 0 frame, 1 material, 2 object/draw, 3 pass-specific
- Never rewrite a buffer between draws expecting per-draw values; use `uniform_ring.zig`
  with dynamic offsets
- Pipelines created at init; render state is pipeline state (`RenderState` → `PipelineVariants`)
- Per-draw values: `DrawUniforms` through `gpu.uniform_ring`; frame values: `gpu.writeFrameUniforms`
- `examples/draw_test` is the per-draw regression check; run it after touching the draw path
- Depth 0..1, sRGB surface and color textures, texture origin top-left
- MSAA (`-Dmsaa`, default on): window passes are 4x and resolve into the frame's view. A
  window pass that doesn't use `beginSurfacePass` gets its target from `frame.surfaceTarget`;
  `.surface` pipelines have `gpu_context.window_sample_count` samples, render-target
  pipelines too with `ShaderConfig.multisampled` (their pass has a `resolve`), else 1
- Translated descriptors default every field to zero; set the ones where zero is wrong
  (`depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED`)
- Mipmaps from our render-pass generator in `mipmaps.zig` (WebGPU has none)
- Group 1 materials: `Shader` declares a `MaterialKind`; `texture.bind(frame)` sets the texture
  `.texture` shape draws use (re-set per draw, safe across PBR draws)
- Group 2 binding 1 = joint matrices (storage); skinned draws set `joint_offset` and
  `DrawFlags.skinned`. Draw each posed `ModelInstance` once per frame
- Per-frame vertex data (lines, instance attributes) goes through `gpu.vertex_ring`
- Lights: `SceneLights.uniforms()` into `FrameUniforms.lights`, once per frame
- Multi-pass frames: `gpu.acquireFrame()`, then `frame.beginPass(PassTarget)` / `endPass`
  per pass; group 3 (e.g. `ShadowMap.bind`, or `ShadowMapArray.bindCaster` per shadow pass
  and `.bind` for receivers) is set after each `beginPass`. Shaders for render
  targets or depth-only passes set `ShaderConfig.color_target` / `depth` / `pass`; variants
  of one WGSL file differ by `constants` (WGSL `override`). See docs/designs/009-angrybot.md
- GL-era color constants (clear colors, part colors, palette) go through `srgbToLinear`
- Shared shaders live in `src/core/shaders/` (`common.wgsl` embedded, `pbr.wgsl` loaded by path)
- GL-era color constants go through `colors.srgbToLinear` to look the same
- Request needed limits in `requiredLimits`; otherwise the device gets WebGPU defaults
- GPU cleanup: `releaseGpuObjects()` on leaves, `cleanUp()` on aggregates, before arena reset

## Build

Zig 0.16.0 (`~/zig/zig-aarch64-macos-0.16.0`). `zig build <app>` and `zig build <app>-run`,
as in redfish_gl_zig (e.g. `zig build gpu_caps-run`). wgpu-native is listed for macOS arm64
only; add a lazy package per platform in `build.zig.zon` and `wgpuNativeDependency`.

- `-Dmsaa=false` turns off 4x MSAA for every app (default on; plan 018)
- `zig build test` always prints a `failed command: ...test` line: one test writes to
  stderr. It isn't a failure; check the exit code, or `zig build test --summary all`
  ("N/N tests passed")

### macOS Toolchain Note (Xcode 27 / Zig 0.16)
- The macOS 27 SDK `math.h` defers `INFINITY` to `<float.h>` via `__need_infinity_nan`
  (LLVM 22 behavior); Zig 0.16's LLVM 21 `float.h` ignores it, so libc++ sub-compilation
  fails with `use of undeclared identifier 'INFINITY'` (real error is at the top of the log)
- **Fix**: `~/zig/<version>/lib/include/float.h` is patched to handle `__need_infinity_nan`
  (original kept as `float.h.orig`). Re-apply after any Zig upgrade until Zig ships LLVM 22 headers
- Zig ignores `SDKROOT`; it always uses `xcrun --sdk macosx --show-sdk-path`
- After an Xcode update, run `sudo xcodebuild -license accept` and open a fresh terminal

## Working Rules

- **Never add signatures or attribution lines to commit messages**
- Run `zig fmt` on every edited `.zig` file, and only on `.zig` files; never on dependency code
- Every print/log call takes an args tuple, even `.{}`
- Delete dead code; don't comment it out
- Time-based easing goes through `core.motion` (`dampAlpha`, `dampVec3`, `dampAngle`,
  `moveToward`, ...), never `lerp(k * dt)` or `@min(1, rate * dt)`, which converge at
  different speeds at different frame rates
- Zig lazy analysis skips unreferenced functions: "it builds" proves nothing about uncalled code.
  `zig build test` runs `tests/analyze_all.zig`, which forces analysis of all public decls in
  math, containers, and core; run it after every change. A module root (or namespace root like
  `utils/root.zig`) needs `test { std.testing.refAllDecls(@This()); }` for its files' tests to run
- Each plan step ends with a `CHANGELOG.md` entry and a commit

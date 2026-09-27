# Changelog

## Recent Changes

### 2026-09-27 - Zero-to-One Depth (Port Step 2)
- **Math**: `Mat4.perspectiveRhZo` / `orthographicRhZo` replace the GL (-1..1) projections; `Camera` and `CameraGimbal` use them
- **Mouse rays**: `getWorldRayFromMouse` NDC z set to the 0..1 near plane (results unchanged; x/y are depth-independent), documented as perspective-only
- **Screen-Y audit**: mouse → NDC unchanged (NDC is y-up in both APIs); texture `flip_v`, screenshot readback, and shadow UV flips recorded in Steps 3b/4, 8, and 9
- **ray.zig**: restored (by-value `Vec3`, sphere range params named `t_min` / `t_max`) with tests, for later picking
- **Tests**: known matrices, depth mapping, mouse-ray directions; 52 pass

### 2026-09-27 - Carry-over Modules (Port Step 1 complete)
- **Copied from redfish_gl_zig**: `src/math/`, `src/containers/`, and core `context`, `arenas`, `movement`, `transform`, `aabb`, `camera`, `camera_gimbal`, `render_context`, `frame_counter`, `random`, `colors`, `string`, `gltf/gltf.zig` + `parser.zig`, `utils/`; zstbi dependency
- **Deferred**: `animator`, `animation_fsm` (Step 5), `gltf/report` (Step 4), `constants` (replaced by `bindings.zig`); `math/cglm.zig` dropped (dead)
- **Tests**: `zig build test` runs each module's tests (47 pass) plus `tests/analyze_all.zig`, which forces analysis of every public declaration
- **Latent errors fixed** (code redfish never compiled): `camera_gimbal` (by-value Vec3 calls, `std.meta.eql`, `turn_left/right` routed to the base), `Quat.lookAtOrientation` (`Quat.Identity`), vec tests; `remove` / `retain` tests rewritten with assertions and leak checks
- **Dead code deleted**: `math/ray.zig`, `truncate`, `wrapAround`, `screenToModelGlam`, `calculateNormal`, `Quat.toEulerAngles`, `randIntInRange`, `fileExists`, `getExistsFilename`, `hasDeinit`, two `std.rand` experiment tests
- **Limits**: WebGPU defaults cover the design; no `requiredLimits` yet

### 2026-09-27 - Switch to wgpu-native (Port Step 1, in progress)
- **Decision**: wgpu-native v29 replaces zgpu/Dawn; zgpu's prebuilt Dawn is frozen (~2023, `bgra8_unorm`-only swapchain). Record: `docs/reviews/2026-09-27-wgpu-native-spike.md`
- **Bindings**: `webgpu.h` + `wgpu.h` translated by `b.addTranslateC` into the `wgpu` module (`src/core/wgpu/`); no Zig binding package
- **Build**: `build.zig`, `build.zig.zon` with zglfw, zgui (`.backend = .glfw`), wgpu-native (lazy, macOS arm64); imgui's WebGPU backend compiled against wgpu-native's headers with `BACKEND_DAWN` (matches wgpu-native 29 in imgui 1.92.1)
- **Core**: `gpu_context.zig` (instance, Metal surface, adapter/device, sRGB surface config, depth texture, begin/endFrame, reconfigure on resize), `gpu_debug.zig` (error/lost callbacks, adapter info and limits), `gui.zig`
- **Example**: `gpu_caps` logs adapter and limits, clears to linear 0.5 gray on an sRGB surface, shows a zgui panel; resize, Retina, and Esc quit verified
- **Plan**: sRGB surface replaces the scene-target/present-pass workaround; `uniform_ring.zig` replaces `uniformsAllocate`; own mipmap generator stays; `requiredLimits` noted

### 2026-09-27 - Port Plan Review
- **Scene target**: zgpu's swapchain is fixed at `bgra8_unorm`, so scenes render linear into a `GpuContext`-owned `rgba16float` + `Depth32Float` target; a present pass encodes sRGB and draws zgui
- **Mipmaps**: own render-pass generator in `texture.zig`; zgpu's `generateMipmaps` is square/power-of-two/≤ 2048 and can't write sRGB
- **zgpu pool sizes** set in `build.zig` from Step 1
- **Other**: group 0 is a persistent per-frame buffer; zaudio moves to Step 6; Step 2 audits screen-Y assumptions; `zopengl` left out
- **Risk noted**: zgpu's prebuilt Dawn is frozen (~2023); wgpu-native listed as a post-port option

### 2026-09-27 - Project Setup (Port Step 0)
- **Purpose**: Port redfish_gl_zig from OpenGL 4.1 to WebGPU via zig-gamedev `zgpu` (Dawn), keeping its structure and changing only the graphics API
- **Docs**: `docs/STYLE.md` style guide, `docs/plans/000-webgpu-port.md` port plan, `docs/plans/active-plans.md`, `CLAUDE.md`
- **Decisions**: zgpu `GraphicsContext`; bind groups 0 frame / 1 material / 2 object / 3 pass; per-draw data via `uniformsAllocate`; storage buffers for joints; runtime-loaded WGSL with generated shared constants; 0..1 depth; sRGB; `zaudio` for audio; URL packages instead of vendored libs
- **Assets**: `assets/` symlinks to redfish_gl_zig's `assets/`
- **License**: MIT

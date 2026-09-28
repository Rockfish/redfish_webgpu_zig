# Changelog

## Recent Changes

### 2026-09-27 - demo_app Complete (Port Step 8)
- **Screenshots**: `core.ScreenCapture` renders an extra offscreen frame (surface format) and reads it back; demo_app's F12 writes `temp/<timestamp>_screenshot.png` without the UI
- **Uniform dump**: `core.UniformDebug` on `GpuContext` captures frame, draw, and material uniform structs by field path; G toggles, U prints, F12 writes the JSON
- **GpuContext**: `beginOffscreenFrame` / `submitFrame`; `PbrMaterial` keeps a CPU copy of its uniforms
- **Fixes**: `temp/` created without execute permission (GL too); timestamps used the boot clock, now local time via libc `localtime_r` (core links libc)
- **Tests**: 61 pass

### 2026-09-27 - level_01 (Port Step 7)
- **level_01**: ported from `games/level_01` (main, run_app, state, nodes); `basic_model.wgsl` unlit with hit color and vertex-color barrel; Spacesuit on core `pbr.wgsl`
- **Not ported**: `run_animation.zig` and `player_shader` (never called), main's unused print tests
- **Fixes**: Spacesuit had no working light in GL (now scene_tree's light); scroll zoom used pixel dimensions

### 2026-09-27 - bullets (Port Step 6)
- **Design**: `docs/designs/006-bullets.md`
- **Lights**: `SceneLights` in group 0 for every shader; PBR reads direction and point lights; existing apps keep their look
- **Core**: per-frame vertex ring (`FrameRing`), `Shape.drawInstanced`, `Lines`, `Skybox` (own LessEqual pipeline, cube texture), `ShaderConfig`, bound materials for shapes, `ResourceManager`, `animation_fsm`
- **bullets**: all three scenes, cannon, turret, instanced bullets, skybox, floor, spacesuit and toon soldier; `--scene` option; dead files not ported
- **Fixes**: bullet buffers, skybox cleanup and shader binding, floor texture release, PBR lights, washed-out cannon, frame-rate-dependent walking, ruins OBJs now show MTL colors
- **zaudio** moves to Step 9
- **Tests**: 60 pass

### 2026-09-27 - Skinning and Animation (Port Step 5)
- **Design**: `docs/designs/005-skinning.md`
- **Skinning**: joint matrices in a group 2 storage buffer; `DrawUniforms.joint_offset` and `DrawFlags.skinned`; one `pbr.wgsl` for live and baked (moved to `src/core/shaders/`); `skinMatrix` in `common.wgsl`
- **Core**: `storage_buffer.zig` (replaces texture buffers), `skinning.zig` (`JointBuffer`), `baked_animator.zig` (storage buffer rows, CPU node matrices); `Model` / `ModelInstance` skin through `Mesh.drawAt`; baked variant of `AnimatorImpl`
- **Custom textures**: `GltfAsset.addCustomTexture` maps GL uniform names to material slots
- **Examples**: `animation_example` ported (`player.wgsl`, 4×4 baked grid); demo_app `BAKE_ANIMATION` on; scene_tree's CesiumMan node back and animating
- **Fixes**: bound texture lost across PBR draws (3b design fix); animation_example's normal-map name mismatch; demo_app's converted CesiumMan path
- **Known issue**: `CesiumMan_converted.gltf` root rotations have flipped signs (upside down)

### 2026-09-27 - glTF Static Meshes with PBR (Port Step 4)
- **Design**: `docs/designs/004-gltf-pbr.md`
- **Core**: `gltf_asset.zig`, `mesh.zig` (canonical vertex format, strided accessor reader, u8→u16 indices), `material.zig` (`PbrMaterial` group 1 bind group, 1×1 default textures), `model.zig` and `model_instance.zig` sharing `Mesh.drawAt`, `animator.zig` (CPU side), `gltf/report.zig`
- **Textures**: `initFromGltf` with per-asset dedupe, sRGB by usage, glTF samplers; `initFromPixels`
- **Shaders**: `pbr.wgsl` (no manual gamma, glTF emissive, alpha MASK, one frame light until Step 6); `MaterialKind.pbr`; material flags in the generated WGSL header
- **demo_app**: ported for static models (model cycling, UI panels)
- **Fixes**: node `matrix` ignored in bounds (Duck), world transforms missing before the first animation update, report writers writing empty files, texture double upload / leak, alpha mode and double-sided ignored
- **GpuContext**: handles wgpu-native's `Occluded` surface status without spinning
- **Assets**: `assets_nas` symlink to `/Volumes/Dev/Assets`
- **Tests**: 58 pass

### 2026-09-27 - Textures and All Shapes (Port Step 3b)
- **Textures**: `texture.zig` (`initFromFile`, RGBA upload, `is_srgb`, `SamplerCache`, per-texture group 1 bind group, `bind(frame)`); `mipmaps.zig` render-pass mip generator for any size, sRGB and linear
- **Materials**: `MaterialKind` on `Shader` selects the group 1 layout
- **Shapes**: square, cylinder, sphere, obj_loader, plane ported; winding fixed for culling (square, cylinder caps and tube), cylinder bottom normal, plane normals, sphere index/count/type bugs, `ShapeBuilder.resize` colors, plane texture/cleanup bugs
- **Input**: `input.zig` ported (no `gl.viewport`)
- **Colors**: `colors.srgbToLinear` for GL-era color constants
- **Examples**: `scene_tree` ported (textures, cylinder, picking with hit highlight; model node waits for Step 4); `draw_test` shape selector
- **Correction**: loaded textures need no V-flip change; `flip_v` keeps its redfish meaning
- **Tests**: 56 pass

### 2026-09-27 - Rendering Foundation (Port Step 3a)
- **Design**: `docs/designs/003a-rendering-foundation.md`
- **bindings.zig**: group numbers, vertex locations, `MAX_JOINTS`, `FrameUniforms` / `DrawUniforms` (size-checked), generated WGSL header, shared layouts and bind groups (frame, empty material, object with dynamic offset)
- **uniform_ring.zig**: 4 MiB per-draw uniform buffer, 256-byte slices staged on the CPU, one upload per frame before submit
- **shader.zig**: WGSL loaded from file with header + embedded `common.wgsl`; compile errors caught in a validation error scope and returned as `error.ShaderCompile`
- **pipeline.zig**: `RenderState` flags → 16 precreated pipeline variants; blend, cull, depth are pipeline state
- **shapes**: `ShapeBuilder` / `Shape` with per-attribute vertex buffers, defaults for missing attributes, `draw(frame, shader, draw_uniforms)`; culling on (fixes redfish always disabling it); `cubeboid` ported
- **GpuContext**: owns the ring and bindings; binds group 0 per frame; `writeFrameUniforms`; `init` takes an allocator
- **Example**: `draw_test`, the per-draw regression check (grid of cubes, gradient colors, render-state toggles)
- **Tests**: ring allocation/alignment, `RenderState` indexing; 54 pass

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

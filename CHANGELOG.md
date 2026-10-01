# Changelog

## Recent Changes

### 2026-10-01 - Mortar, plan 008 phase 4
- **core.ballistics**: `launchVelocity` (fixed flight time, one line), `positionAt`, and `step` (exact under constant gravity, so shells land where predicted at any frame rate); tests
- **examples/turrets**: the `mortar` pattern and a fourth turret; finned rockets drawn instanced from parts, nose following the arc, optional spin; shells burst at the target on a fuse, on the floor, or on a direct hit; fireballs, fading burn marks, blast radius; predicted-arc lines; the lob's lead follows the target's curve (`p + v·T + ½·a·T²`); Space (or the panel) pauses everything but the camera and panel

### 2026-10-01 - Sweep pattern, plan 008 phase 3
- **core.motion.Sweep**: an angle swinging back and forth across an arc at a steady speed; tests. `yawPitchOf` and `yawPitchDirection` made public
- **examples/turrets**: the `sweep` pattern (center on the target's bearing or a fixed heading, the target's pitch or a fixed one); a third turret, "sweeper"; pattern choice per turret in the panel; arc lines

### 2026-10-01 - Turret test bed and fire control, plan 008 phase 2
- **core.FireControl**: when shots go out: `while_turning` or `when_aligned`, a steady rate or bursts; a shot timer that carries over its remainder (the same shots per second at any frame rate) and gives each shot its age, so streams stay evenly spaced; tests
- **core.fire_control.ShotJitter**: per-shot aim cone and speed spread; **core.ballistics.leadPoint**: aim where a moving target will be; **YawPitchAim.aimError**
- **examples/turrets**: two turrets (rate-limited and damped slew) track a target on a loop and fire tracers, with or without lead; panel for slew, policy, cadence, jitter, and lead; aim lines, hit counts

### 2026-10-01 - Two-axis aim, plan 008 phase 1
- **core.motion**: `wrapAngle`, `moveTowardAngle`, `dampAngle` (the short way around, frame-rate independent), and `YawPitchAim` (yaw and pitch with their own speeds, rate-limited or damped, pitch limits, optional yaw sector, `aimAt`, `isAligned`); tests
- **bullets**: `Cannon` eases its aim and recoil frame-rate independently (`dampAngle`, `dampAlpha`)

### 2026-09-30 - Camera shake and gimbal rig, plan 016 phase 4 (plan finished)
- **core.motion.Shake**: trauma-model camera shake (strength trauma², smooth noise, frame-rate independent), applied to the frame's `RenderContext` after the camera controller
- **CameraGimbal**: two mount modes, `.gimbal` (the base's pitch and tilt, as a satellite) and `.gimbal_level` (the base's heading, level with the horizontal plane); `getCameraTransform()` makes the view, `getCameraPosition`, and `getCameraForward` agree in every mode (also fixes `.base` mode's position)
- **examples/camera_rig**: a gimbal rig following a focus on a Catmull-Rom loop; circle, radius, base tilt, gimbal aim, the three view modes, and shake
- **Plans**: 016 motion patterns completed; movement review item 4 (CameraGimbal) resolved

### 2026-09-29 - Motion paths, plan 016 phase 3
- **core.motion.PathFollow**: moves along waypoints at a steady speed; straight segments or a Catmull-Rom curve through the points; once, loop, or ping-pong; `tangent()` for facing. Invariant tests (frame-rate independence, loop and ping-pong ends, no corner on the curve)
- **examples/shadows**: camera flythrough around the scene (linear or Catmull-Rom, look at the center or ahead), with the path drawn as lines

### 2026-09-29 - demo_app: Sponza and Stained Glass Lamp
- **demo_app**: Sponza (alpha MASK plants and chains) and Stained Glass Lamp (its no-extension `glTF-JPG-PNG` version) added to the model list

### 2026-09-29 - Alpha-to-coverage for MASK materials, plan 018 phase 3 (plan finished)
- **pbr.wgsl**: with MSAA, glTF alpha MASK edges are smoothed through alpha-to-coverage (alpha sharpened around the cutoff, so the cut stays where glTF puts it); without MSAA it still discards
- **core**: `ShaderConfig.alpha_to_coverage` / `PipelineConfig.alpha_to_coverage`, on in multisampled, non-blended variants; the pipeline sets the shader's `ALPHA_TO_COVERAGE` override
- **demo_app**: AlphaBlendModeTest added to the model list (index 22)
- **Plans**: 018 anti-aliasing completed

### 2026-09-29 - Anti-aliasing in angrybot, plan 018 phase 2
- **angrybot**: the emission and scene passes are 4x multisampled and resolve into their render targets; blur and composite unchanged
- **core**: `gpu_context.Attachment` (render-only textures; `GpuContext`'s depth and MSAA textures use it), `ShaderConfig.multisampled` for render-target pipelines in multisampled passes

### 2026-09-29 - Anti-aliasing: 4x MSAA in the window pass, plan 018 phase 1
- **MSAA**: everything drawn in the window pass is 4x multisampled and resolved into the surface; on by default, `zig build -Dmsaa=false` turns it off
- **core**: `gpu_context.window_sample_count`, `Frame.surfaceTarget`, `PassTarget.resolve`, `PipelineConfig.sample_count`; ImGui uses the window's sample count
- **angrybot**: the composite pass uses `frame.surfaceTarget` (its scene is still single-sample: phase 2)
- **gpu_caps**: shows the sample count

### 2026-09-29 - Plan 017 finished
- **Plans**: 017 shadows completed after phase 3; unclipped depth (phase 4) left until a scene needs it

### 2026-09-29 - Shadows from several lights, plan 017 phase 3
- **core.ShadowMapArray**: one depth texture with a layer per light; each layer's shadow pass binds its own light matrix at group 3 (`PassKind.shadow_caster`), receivers sample all layers (`PassKind.shadow_layers`). Each light's matrix has its own 256-byte slot, written once per frame, so nothing is rewritten between passes
- **examples/shadows**: a spotlight with its own shadow layer next to the directional light; the spotlight's cone is its shadow projection; debug views pick a layer

### 2026-09-29 - angrybot: emission pass occluders
- **Fix**: the player's glow showed through enemies in front of it and through the floor when the dying player sinks into it; the emission pass now draws the floor and enemies depth-only before the player's emissive parts (a depth write only hides later draws). redfish drew only the player and bullets there

### 2026-09-29 - angrybot: caster slope bias and linear shadow filtering (plan 017)
- **angrybot**: player and enemy shadow casters use a slope-scaled depth bias and the shadow map filters linearly; removes the acne outline along the eels' backs
- **Backlog**: anti-aliasing (MSAA) added to the Advanced Rendering cluster

### 2026-09-29 - Shadow bias and filtering, plan 017 phase 2
- **core.pipeline.DepthBias**: slope-scaled depth bias for shadow casters (`ShaderConfig.depth_bias`)
- **ShadowMap**: `init(gpu, .{ .size, .filter })`; `.linear` is the hardware 2x2 comparison filter (default `.nearest`, angrybot unchanged)
- **examples/shadows**: panel controls for shader bias, pipeline bias, filter, and PCF radius; defaults are the tested combination (caster slope bias plus a small receiver bias, linear, 3x3 PCF)
- **Fix**: examples/shadows gave ImGui an arena allocator (ImGui's frees were no-ops); it now uses the general-purpose allocator like the other apps

### 2026-09-29 - Shadows example, plan 017 phase 1
- **examples/shadows**: shadow map test bed: flat and sloped receivers, one directional light with panel controls (direction, orthographic box, bias), `zig build shadows-run`
- **Debug views**: the shadow map as an overlay (`textureLoad`, adjustable depth range) and the scene drawn from the light
- **Plans**: plan 017 (shadows) drafted and active, 016 parked; review of the Rust wgpu projects in `docs/reviews/`

### 2026-09-28 - Motion patterns, phases 1-2 (plan 016)
- **core.motion**: `SmoothFollow`, `dampLookAt`, `moveToward`, `dampVec3`, `dampQuat`, `dampAlpha` (frame-rate independent damping), with invariant tests
- **angrybot**: the game camera eases after the player (`SmoothFollow`) instead of snapping
- **level_01**: click-to-move uses `moveToward`
- **Fix**: `Quat.lookAtOrientation` built a mirrored basis; now matches `Transform.lookAt`, with a test
- **Plans**: redfish_gl_zig plans 001-016, backlog, and notes imported; `docs/plans/README.md` describes parking and resuming plans
- **Tests**: 69 pass

### 2026-09-28 - Orthographic mouse picking
- **math.getWorldRayFromMouse**: returns `MouseRay { origin, direction }` unprojected at the near and far planes; works for orthographic projections (redfish's version was perspective-only, so clicking in ortho mode hit the wrong place)
- **Callers**: scene_tree, level_01, angrybot use the ray's origin; new unit test for orthographic rays

### 2026-09-28 - Softer demo_app light, optional grazing specular fade
- **demo_app**: key light 100 → 50 plus a dim fill from the opposite side; backlit bevel edges no longer blow out to white
- **SceneLights.fade_grazing_specular**: optional, stylistic fade of PBR specular at grazing views (off by default); demo_app toggles it with E
- **pbr.wgsl**: back faces of double-sided materials use the flipped normal (glTF); shading normals are kept facing the viewer

### 2026-09-28 - PBR edge highlights
- **pbr.wgsl**: Fresnel on VdotH instead of NdotV, Schlick-GGX `k = (roughness + 1)² / 8` for direct light; the white rims on shadow-side edges (redfish too) are gone, backlit specular remains

### 2026-09-28 - angrybot: restore original AngryGL features
- **Emission pass**: floor drawn depth-only (`ShaderConfig.color_writes = false`), so bullets below the floor don't bloom through it
- **Muzzle flash**: follows the animated gun node (`Model.findNode` / `nodeTransform`) with the original's billboard tilt and 0.05 s frames; its light sits at the muzzle
- **Floor**: lit by the muzzle flash light again, with the original attenuation
- **Bullets**: spawn from the animated gun muzzle, as the Rust port did (redfish used a fixed offset since the glTF migration)

### 2026-09-27 - angrybot and skybox (Port Step 9)
- **Design**: `docs/designs/009-angrybot.md`
- **Core**: multi-pass frames (`acquireFrame`, `beginPass` / `endPass`), shaders for render targets / depth-only / group 3 / override constants, `ShadowMap`, `FrameUniforms.light_space`, `DrawUniforms.params`, render-target textures (`rgba16float`), zaudio `SoundEngine`, `GltfAsset.useGammaSpaceTextures`, `SkyboxFaces.mirrored`
- **angrybot**: shadow, emission, scene, blur, composite passes; one shader file for player / enemy / shadow / emission pipelines; correct shadow UVs; gamma-space shading to match GL; sound
- **skybox**: ported on core `Skybox` (the GL version showed no sky)
- **Fixes**: enemy node transforms and normals, floor spec map binding, fullscreen quad depth outside WebGPU's 0..1
- **Tests**: 62 pass

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

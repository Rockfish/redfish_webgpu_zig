# Plan 000 - Port redfish_gl_zig to WebGPU

## Status: DRAFT

## Context

redfish_gl_zig (`/Users/john/Dev/Dev_Zig/redfish_gl_zig`) is a working OpenGL 4.1 engine:
glTF PBR, skeletal and baked animation, shapes, scenes, zgui. macOS OpenGL stops at 4.1
and GL's quirks keep costing time. This project is the same engine on WebGPU through
**wgpu-native** (the Rust `wgpu` crate, as used by Bevy, behind the standard `webgpu.h`),
so it has a cross-platform, modern, maintained API underneath.

Sources:
- **redfish_gl_zig**: the structure, names, and behavior to match.
- **wgpu-native** (`gfx-rs/wgpu-native`): prebuilt release zips (headers + static lib).
  `webgpu.h` is the API reference; `wgpu.h` adds native extensions.
- **gui_test_webgpu** (`/Users/john/Dev/Dev_Zig/gui_test_webgpu`): source of the zglfw and
  zgui pins that work on Zig 0.16. Its zgpu/Dawn setup is not used.
- **small_wgpu_core / angry_wgpu_rust** (`/Users/john/Dev/Dev_Rust/`): earlier wgpu work on
  the same wgpu implementation. Reuse the lessons, not the bind group layout (see Design
  Decisions).

Why not zgpu/Dawn: zgpu links a frozen ~2023 prebuilt Dawn (SwapChain API, `bgra8_unorm`
swapchain only, square power-of-two mipmaps). Updating it means building Dawn and rewriting
zgpu's bindings. A spike (`docs/reviews/2026-09-27-wgpu-native-spike.md`) confirmed
wgpu-native v29 on Zig 0.16 with a translated `webgpu.h`, an sRGB surface, and zgui.

Code follows `docs/STYLE.md`.

## Goals

- Same directories, files, type names, and call shapes as redfish_gl_zig. Only the graphics
  API changes, plus the fixes needed to do it correctly.
- Correctness over fidelity: establish the right WebGPU patterns up front, even where the
  result looks a little different from the GL version (e.g. proper sRGB).
- Every step ends with something that builds, runs, and can be checked on screen.

## Non-Goals

- New engine features during the port. Plans 004/005/016 from redfish continue after.
- Porting `examples/picker` and `examples/shader_generator` (stale, not in the build).
- New gameplay in angrybot. It is ported as a regression reference.

---

## What Carries Over Unchanged

Copied as-is (then conformed to STYLE.md when touched):

Status after Step 1: copied except `math/cglm.zig` (dead `@cImport`), `constants.zig`
(GL uniform names; `MAX_JOINTS` moves to `bindings.zig`), `gltf/report.zig` (needs
`gltf_asset`, Step 4), and `animator.zig` / `animation_fsm.zig` (need `model_instance`,
Step 5). `render_context.zig` came over early because the cameras use it.

- `src/math/` (plus zero-to-one depth projections, Step 2)
- `src/containers/`
- `src/core/`: `context.zig`, `arenas.zig`, `gltf/` (parser, report), `animator.zig` (CPU side),
  `animation_fsm.zig`, `movement.zig`, `transform.zig`, `aabb.zig`, `camera.zig` (logic),
  `frame_counter.zig`, `random.zig`, `colors.zig`, `string.zig`, `utils/`
- `sound_engine.zig` keeps its API but moves onto `zaudio` (Step 6, first app with sound)

## What Gets Rewritten

GL-specific files. Same file name unless the name itself says GL:

| redfish_gl_zig | redfish_webgpu_zig | Notes |
|---|---|---|
| (none) | `wgpu/` | `webgpu.h` translated by the build, string-view helpers, macOS Metal layer |
| `gl_debug.zig` | `gpu_debug.zig` | Device error/lost callbacks, adapter info and limits |
| (none) | `gpu_context.zig` | Instance, surface, device, sRGB surface config, depth texture, per-frame begin/end |
| (none) | `uniform_ring.zig` | Per-frame uniform ring buffer for per-draw data (dynamic offsets) |
| (none) | `gui.zig` | zgui init/newFrame/draw on imgui's WebGPU renderer backend |
| (none) | `bindings.zig` | Bind group slot numbers, shared layouts, shared WGSL constants |
| `shader.zig` | `shader.zig` | WGSL loader, prepends generated constants + `common.wgsl` |
| (none) | `pipeline.zig` | Pipeline config (blend, depth, cull, topology) → cached pipeline |
| `texture.zig` | `texture.zig` | RGBA upload, sRGB vs linear, sampler cache, material bind group |
| (none) | `mipmaps.zig` | Render-pass mipmap generator |
| `texture_buffer.zig` | `storage_buffer.zig` | Storage buffers replace TBOs |
| `mesh.zig` | `mesh.zig` | Per-attribute vertex buffers, format conversion, placeholder buffers |
| `model.zig`, `model_instance.zig` | same | Draw path through bind groups and per-draw uniforms |
| `baked_animator.zig` | same | Storage buffer instead of TBO |
| `render_context.zig` | same | Also produces the frame uniforms for group 0 |
| `lights.zig` | same | Uniform struct in group 0 instead of named uniforms |
| `input.zig` | same | Resize reconfigures the surface and depth texture instead of `gl.viewport` |
| `shapes/*` | same | Vertex buffers + pipeline variants instead of GL state toggles |
| all `.vert`/`.frag` | `.wgsl` | One WGSL file per shader pair |

---

## Design Decisions

### Settled

- **wgpu-native**, called through `webgpu.h` translated by the build (`b.addTranslateC`)
  into the `wgpu` module in `src/core/wgpu/`. No Zig binding package. Translated structs
  have zero defaults, so descriptors name only the fields that matter; where zero is wrong
  (e.g. `depthSlice = WGPU_DEPTH_SLICE_UNDEFINED`), set it explicitly. Raw `c.wgpu*` calls
  stay inside `src/core`.
- **`GpuContext`** (`gpu_context.zig`) owns instance, surface, adapter, device, queue, and
  the depth texture; it reconfigures on resize or an `Outdated` / `Lost` surface.
- **Bind groups** (defined in `bindings.zig`, same numbers in WGSL):
  - group 0: frame — camera matrices, view position, time, lights. One persistent uniform
    buffer written once per frame with `wgpuQueueWriteBuffer`; no dynamic offset
  - group 1: material — textures, samplers, material factors
  - group 2: object / draw — model transform, node transform, flags, joint matrices
  - group 3: pass-specific — shadow map, etc.
- **Per-draw data** goes through `uniform_ring.zig`: one uniform buffer, per-draw slices
  allocated at 256-byte alignment into CPU memory during the frame, one `wgpuQueueWriteBuffer`
  before submit, bound with a dynamic offset on group 2. Queue ordering makes reusing the
  buffer next frame safe. Never rewrite a buffer between draws.
- **One `DrawUniforms` for every draw path** (`bindings.zig`, mirrored in `common.wgsl`):
  `model`, `normal_matrix` (CPU inverse-transpose; WGSL has no `inverse()`), `color`,
  `flags`. glTF node transforms fold into `model`; material factors go in group 1.
- **Pipeline variants**: `RenderState` (transparent, double-sided, depth write, depth test)
  indexes 16 pipelines a `Shader` creates at init. No hashed cache, no first-use hitch.
  No wireframe: WebGPU has no polygon mode.
- **Joint matrices and baked animation** use read-only storage buffers.
- **Shaders**: hand-written WGSL, loaded from files at runtime. A generated header of shared
  constants (`MAX_JOINTS`, ...) and `common.wgsl` are prepended.
- **Depth**: 0..1 clip space, `Depth32Float`, `*Zo` projections.
- **Color**: sRGB surface (`BGRA8UnormSrgb`, chosen from the surface capabilities); base
  color and emissive textures `rgba8unorm-srgb`; normal, metallic-roughness, occlusion
  `rgba8unorm`. Shaders output linear color and do no manual gamma.
- **Mipmaps**: our own generator in `mipmaps.zig` (WebGPU has none). It renders each mip level
  from the one above with a full-screen triangle and a linear sampler, one pipeline per
  format, so any size and sRGB formats work.
- **Device limits**: a device gets WebGPU's defaults (4 bind groups, 8 vertex buffers, ...)
  unless `requiredLimits` asks for more, not the adapter's (the M1 offers 8 and 16). The
  defaults cover the design (groups 0-3, 7 PBR vertex buffers), so none are requested yet;
  a step that needs more adds it to `requiredLimits` in `GpuContext.init`.
- **Texture origin top-left**; no default V-flip. For images loaded from files this
  changes nothing: both APIs sample v = 0 from the first uploaded row, so `flip_v` keeps
  its redfish meaning. It matters for textures something rendered into (Step 9).
- **Materials at group 1**: a `Shader` declares a `MaterialKind` (`none`, `texture`; PBR
  adds its own in Step 4). `texture.bind(frame)` sets group 1 for the draws that follow,
  as redfish's `bindTextureAuto` did; bind group changes are recorded in draw order, so
  this is correct WebGPU.
- **Cleanup**: `releaseGpuObjects()` on leaves, `cleanUp()` on aggregates, before arena reset.
- **Dependencies**: URL packages in `build.zig.zon`, not vendored: wgpu-native release zips
  (lazy, one per platform; macOS arm64 listed so far), zglfw, zgui with `.backend = .glfw`.
  imgui's `imgui_impl_wgpu.cpp` from zgui's tree is compiled in our `build.zig` against
  wgpu-native's headers. It uses `IMGUI_IMPL_WEBGPU_BACKEND_DAWN` because imgui 1.92.1's
  Dawn branches match wgpu-native 29's header; switch to `BACKEND_WGPU` when zgui moves to
  imgui 1.93.
- **Frame API**: `GpuContext.beginFrame(clear_color)` returns `?Frame` (null: skip the frame)
  with the surface view, encoder, and the open main render pass; `endFrame(frame)` ends the
  pass, submits, and presents. zgui draws last in the main pass. Parallel to redfish's
  clear / `swapBuffers`.
- **Audio**: zig-gamedev `zaudio` replaces the vendored miniaudio module; `sound_engine.zig`
  is adapted to it in Step 6. zaudio is unproven on Zig 0.16, so it stays out of the skeleton.
- **Assets**: `assets/` is a symlink to redfish_gl_zig's `assets/` for now.

### To Settle in the Step Where They First Matter

| Decision | Step | Starting proposal |
|---|---|---|
| Missing vertex attributes | 4 | One shared placeholder buffer per attribute type, bound with stride 0, so one pipeline serves skinned and unskinned meshes. PBR uses 7 vertex buffers of the default limit of 8 |
| Passes before the main pass | 9 | Shadow and bloom passes need the encoder before the main pass opens; split `beginFrame` into acquire + `beginMainPass` then |
| Wide lines | 6 | `lineWidth` doesn't exist; start with 1px lines, add quad-based lines only if needed |
| Clamp-to-border | 9 | Not in WebGPU; use clamp-to-edge plus an in-shader bounds check for shadows |

---

## Steps

Each step: a short design note at the top if needed, the code, a `CHANGELOG.md` entry, a commit.
Checking "done" means building, running, and comparing side by side with the GL version.

### Step 0 - Project Setup ✅ 2026-09-27

- `LICENSE` (MIT)
- `.gitignore` (`.idea/`, `zig-out/`, `.zig-cache/`, `zig-pkg/`)
- `assets` symlink to `../redfish_gl_zig/assets`
- `CLAUDE.md`: project facts, pointers to `docs/STYLE.md` and this plan, build commands,
  the Xcode/`float.h` toolchain notes carried over from redfish
- `docs/plans/active-plans.md`, `CHANGELOG.md`

**Done:** repo has docs only; first commit.

### Step 1 - Skeleton: Window, Device, Clear, zgui ✅ 2026-09-27

Mirrors redfish `build.zig` layout: `math`, `containers`, `core` modules and the
`inline for` app table with `<name>` / `<name>-run` steps.

Landed from the spike:
- `build.zig`, `build.zig.zon` (zglfw, zgui `.glfw`, wgpu-native v29.0.1.1), translate-c of
  `src/core/wgpu/webgpu.h`, imgui WebGPU backend library
- `src/core/wgpu/` (`wgpu.zig`, `metal_layer.zig`), `gpu_context.zig`, `gpu_debug.zig`, `gui.zig`
- `examples/gpu_caps/` replaces `gl_caps`: logs adapter info and limits, clears to linear
  0.5 gray, shows a zgui panel. Checked on an external monitor and the Retina screen:
  resize, drag between screens, Esc quit

Then:
- zstbi dependency; carry-over modules copied in, `math` / `containers` modules added
- `zig build test`: each module's tests, plus `tests/analyze_all.zig`, which forces
  analysis of every public declaration so uncalled code can't hide compile errors
- That check found carry-over code redfish never compiled. Fixed where it has callers
  (`camera_gimbal`, `Quat.lookAtOrientation`, vec tests, `remove` / `retain` tests
  rewritten with assertions); deleted where it has none (`math/ray.zig`, `truncate`,
  `wrapAround`, `screenToModelGlam`, `calculateNormal`, `Quat.toEulerAngles`,
  `randIntInRange`, `fileExists`, `getExistsFilename`, `hasDeinit`)

**Done:** window clears to a color (a known linear value shows its sRGB-encoded value on
screen), zgui panel draws with correct colors, resizing works without validation
errors, closing shuts down cleanly.

### Step 2 - Math: Zero-to-One Depth ✅ 2026-09-27

- `Mat4.perspectiveRhZo`, `Mat4.orthographicRhZo` (same matrices as glam's `perspective_rh` /
  `orthographic_rh`) replace the GL versions, which have no WebGPU use. `lookAtRhGl` /
  `lookToRhGl` keep their names: view matrices don't depend on the depth range
- `Camera` and `CameraGimbal` use the Zo versions
- `getWorldRayFromMouse`: unprojected x/y don't depend on NDC z, so results are unchanged;
  NDC z set to 0 (the near plane) and the function documented as perspective-only
- Screen-Y audit: WebGPU NDC is y-up like GL, so mouse → NDC is unchanged. The GL flips that
  matter are in files not yet ported; each is listed in its step (3b/4 texture `flip_v`,
  8 screenshot readback, 9 shadow UV). Correction in 3b: file textures need no change
- Tests: hand-computed known matrices, near → 0 / far → 1 depth, mouse rays at the center
  and corners; `ray.zig` restored with tests for later picking

**Done:** `zig build test` passes; no GL projections remain.

### Step 3 - Rendering Foundation: Shaders, Bindings, Pipelines, Shapes

The step that fixes the core patterns. Split in two.

**3a - one colored cube** ✅ 2026-09-27 (design: `docs/designs/003a-rendering-foundation.md`)
- `bindings.zig` (groups 0-3, generated WGSL constants), `shader.zig`, `pipeline.zig`
- `render_context.zig` writes `FrameUniforms` to group 0's persistent buffer once per frame
- `uniform_ring.zig`; per-draw uniforms from it on group 2 with dynamic offsets
- `shapes/shape.zig`: `ShapeBuilder` → per-attribute vertex buffers; `Shape.draw(pass, ...)`
- Shape flags (transparent, double-sided, depth write) select a pipeline variant instead
  of toggling state
- `shapes/cubeboid.zig` ported early (the cube); shapes are built with all four attributes,
  missing ones filled with defaults
- `examples/draw_test` (new, no redfish equivalent): a grid of up to 100×100 cubes, each with
  its own model matrix and gradient color through the ring; kept as the per-draw regression
  check. Checked at 400 draws: correct gradient, per-cube rotation, lighting, culling, depth
- Shader compile errors come back from `Shader.init` as `error.ShaderCompile` with naga's
  message and the prepended line count

**3b - textures and all shapes** ✅ 2026-09-27
- `texture.zig`: `initFromFile` (always 4 channels: WebGPU has no RGB8, and 1-/2-channel
  images read as color), `is_srgb` replaces redfish's unused `gamma_correction`,
  `SamplerCache` keyed by filter / wrap / mipmaps, a group 1 bind group per texture,
  `bind(frame)`. `flip_v` keeps its meaning (see Texture origin). `initFromGltf` /
  `loadImage` come with `gltf_asset.zig` in Step 4
- `mipmaps.zig`: each level rendered from the one above; any size, sRGB and linear
- Shapes: square, cylinder, sphere, obj_loader, plane; `input.zig` (no `gl.viewport`)
- `colors.srgbToLinear` for GL-era color constants (clear colors, uniform colors), which
  GL displayed as-is
- `examples/scene_tree` (the `run_interfaces` path; `run_union` / `nodes_union` were never
  called). The CesiumMan node returns in Step 4. Checked: textured cubes, cylinder with
  spinning cube, mipmapped floor, red hit highlight on the cube under the mouse
- `draw_test` gained a shape selector (`zig build draw_test-run -- sphere`); every
  generator checked with culling on

**Fixes:** `Shape.draw` always disabling culling; winding wrong for culling in `Square`
(clockwise) and `Cylinder` (top cap facing down, tube facing in, cap fans closing with a
reversed triangle); cylinder bottom cap normal; `Plane` having 2 normals for 4 vertices;
`Sphere` resizing its index list before appending (uninitialized indices), using the
unclamped poly count, typed `.cylinder`; `ShapeBuilder.resize` leaving colors
uninitialized; `Plane` textures `undefined` when not configured and its shape never
released; Plane's normal and specular maps loaded as color; scene_tree's `Node.draw`
setting a uniform named `model` the shader didn't have (all nodes drew with one matrix) and
its hit highlight being commented out. Dead code removed: `Plane.draw`, `shapes/cube.zig`,
`createSkybox`, `input.getProjectionView`.

**Done:** scene_tree renders with textures and depth; many shapes drawn with different
transforms in one frame show correct per-draw data.

### Step 4 - glTF Static Meshes with PBR ✅ 2026-09-27

Design: `docs/designs/004-gltf-pbr.md`. Split into 4a (core) and 4b (demo_app).

**4a - core**
- `animator.zig` (CPU side; its `draw` moved into `ModelInstance`), `gltf_asset.zig` (takes
  the `GpuContext`; `cleanUp` releases meshes and textures), `gltf/report.zig`
- `mesh.zig`: every attribute converted to one canonical format through a strided accessor
  reader (interleaved data needs no special case); defaults for missing attributes; u8
  indices → u16; index buffers padded to 4 bytes. This replaces the stride-0 placeholder
  proposal
- `material.zig`: `PbrMaterial` (group 1: uniforms, five textures, five samplers) per
  primitive; shared 1×1 `DefaultTextures`; render state from alpha mode and double-sided
- Textures deduped per asset, sRGB for base color / emissive, glTF samplers through the
  sampler cache (unset filters are trilinear)
- `Model` and `ModelInstance` (live animator and none) share `Mesh.drawAt`
- One point light in `FrameUniforms` until Step 6

**4b - demo_app**: model cycling, UI panels through `core.gui`, `BAKE_ANIMATION` off until
Step 5; screenshots and the uniform dump wait for Step 8. Checked: Textured Box, Cube,
Lantern, Damaged Helmet, Flight Helmet (15 textures, blend materials), Duck, Avocado,
Interleaved Box, Animated Box and Interpolation Test (node animation), all exit cleanly.
Skinned models (Player, Fox, CesiumMan, BrainStem) load and draw in bind pose.

**Fixes:** shared textures uploaded twice and leaked; 2-channel images mapped to RED; glTF
`alpha_mode` / `double_sided` ignored; emissive factor ignored without a texture; manual
gamma; `calculateBoundingBox` ignoring node `matrix` (Duck normalized 100× too small; in
redfish too); `Animator.init` leaving local transforms where world transforms were expected
(nested nodes of never-animated models misplaced); `GltfReport` file writers writing empty
files and `printReport` using the removed `GeneralPurposeAllocator`. Dead code removed:
`GltfAsset.hideAllNodes` / `showAllNodes` (referenced a field it doesn't have), `flipv` and
the unread flip / gamma fields.

**Deferred:** `GltfAsset.addCustomTexture` (binds by GL uniform name) returns with its first
user, animation_example or angrybot, designed for bind groups; until then the Player model
draws untextured.

**Done:** demo_app's static models render and look correct (color is expected to differ
from GL due to sRGB).

### Step 5 - Skinning and Animation ✅ 2026-09-27

Design: `docs/designs/005-skinning.md`.

- Group 2 binding 1 is a read-only storage buffer of joint matrices; `DrawUniforms` gains
  `joint_offset` and `DrawFlags.skinned`. One `pbr.wgsl` skins for live and baked animation
  (`skinMatrix` in `common.wgsl`), so `pbr_anim_baked.wgsl` isn't needed. `pbr.wgsl` moved
  to `src/core/shaders/` (shared by demo_app, scene_tree, and later apps)
- `storage_buffer.zig` replaces `texture_buffer.zig`; `skinning.zig` (`JointBuffer` per live
  skinned instance, written when it draws); `baked_animator.zig` (rows uploaded once, CPU
  copy for node matrices, joints by offset)
- `Model` and `ModelInstance` skin through the shared `Mesh.drawAt`; `ModelInstance` has its
  `baked_animator` variant back; demo_app `BAKE_ANIMATION` on
- `GltfAsset.addCustomTexture` (deferred from Step 4): GL uniform names map to material
  slots (`texture_diffuse` → base color, `texture_specular` → the metallic-roughness slot,
  `texture_normal(s)` → normal, `texture_emissive` → emissive) and override that slot for
  meshes with the name
- `examples/animation_example`: `player.wgsl` (redfish's player_shader without shadows,
  custom textures from the material slots) or the core `pbr.wgsl`; the 4×4 grid is drawn as
  16 draws instead of GL instancing (instancing is Step 6)
- scene_tree's CesiumMan node is back, drawing with PBR through `Model` and animating

Checked: Player, Fox, CesiumMan, BrainStem, Spacesuit animate baked and live in demo_app;
animation_example's Player grid animates with its custom textures; scene_tree's model walks.

**Fixes:** `MAX_JOINTS` hand-copied into shaders (now from `bindings.zig`); animation_example
registering `texture_normal` while its shader read `texture_normals` (both map to the
normal slot); demo_app's "CesiumMan (Converted)" entry pointing at a missing path. Design fix
from 3b: `texture.bind(frame)` now records the frame's bound texture and each `.texture`
shape draw sets group 1 from it, so a PBR draw in between no longer leaves an incompatible
group 1 bound (found when scene_tree's model came back).

**Done:** Fox, CesiumMan, and the other animated demo models play live and baked;
animation_example runs.

### Step 6 - bullets

Where new work happens, so it moves ahead of level_01.

- `build.zig.zon` adds zaudio; `sound_engine.zig` moves onto it
- `lines.zig` (1px), `skybox.zig` (cube texture, `LessEqual` depth pipeline, binds its own shader)
- Instanced bullets: per-instance vertex buffers with `stepMode = .instance`; the same for
  animation_example's grid if wanted
- `lights.zig`: `SceneLights` as a uniform struct in group 0, used by basic and PBR shaders
- Scene switching through `cleanUp()` then arena reset; `ResourceManager`
- Port all three scenes, cannon, turret, bullet systems

**Fixes:** bullet instance buffers never freed, skybox cleanup never called,
`lights.apply` being a no-op for PBR shaders, dead `ResourceManager.loadGltfAsset` / `buildModel`.

**Done:** all three scenes run, PageUp/PageDown switches cleanly, cannon fires.

### Step 7 - level_01

- Port app files; replace per-app `gl.*` setup with core calls

**Done:** level_01 plays as in GL.

### Step 8 - demo_app Complete

- Screenshots: render the scene (no zgui) into an offscreen `rgba8unorm-srgb` texture,
  `wgpuCommandEncoderCopyTextureToBuffer` (256-byte row alignment), map, write PNG with no
  vertical flip (redfish's `readPixels` + `setFlipVerticallyOnWrite(true)` goes away).
  Also the exact check of the Step 1 clear color
- Uniform dump for screenshots from the frame/draw uniform structs
- All zgui panels

**Done:** F12 writes a correct PNG and uniform dump; demo_app matches GL feature for feature.

### Step 9 - angrybot and Remaining Examples

- Offscreen targets: shadow depth texture (comparison sampler, PCF), emission, scene
  (`rgba16float` for bloom headroom), blur ping-pong, composite to the surface, all as
  render passes
- Correct shadow NDC → UV mapping: the five `player_shader` / `floor_shader` fragments use
  GL's `proj * 0.5 + 0.5` for x, y, and z. WebGPU needs `uv = (x * 0.5 + 0.5, 0.5 - y * 0.5)`
  and raw z (already 0..1); the light projection is `orthographicRhZo`
- Port `examples/skybox`

**Done:** angrybot plays as in GL, including shadows and bloom. It is then the regression
check for later changes.

---

## Known Issues (later)

- **Orthographic mouse picking.** `getWorldRayFromMouse` is perspective-only: with an
  orthographic projection every ray has the camera's forward direction and only the origin
  moves with the mouse. In scene_tree, clicking the floor in ortho mode (key 5) moves the
  cylinder group to the wrong place. Likely never worked in redfish either. Fix with an
  ortho path that unprojects the mouse to a near-plane origin.

- **CesiumMan_converted.gltf is upside down.** Its `Z_UP` and `Armature` rotations have the
  opposite sign of the original CesiumMan's matrices (+90° X instead of -90°), as if the
  converter wrote conjugated quaternions. demo_app entry 9 shows it on its head; scene_tree
  compensates with a 180° X rotation. Fix the converter or re-export the asset.

- **PBR highlights on edges at the shadow side** (redfish too; e.g. panel seams of the
  spacesuit models). Suspected, not verified: `pbr.wgsl`'s geometry term uses `k = alpha / 2`,
  so with roughness clamped to 0.1 (`k` = 0.005) `G / (4 NdotV NdotL)` reaches ~1/(4k²) where
  both dot products are small; and Fresnel uses `NdotV` instead of `VdotH`, which goes to 1 at
  grazing view. Try Schlick-GGX with `k = (roughness + 1)² / 8` for direct light and
  Fresnel on `VdotH`, and compare on the same model.

## Risks

- **Per-draw data design (Step 3a).** Everything later depends on it. Test it with many
  draws per frame before moving on.
- **wgpu-native API churn.** `webgpu.h` is still moving toward 1.0. Upgrading wgpu-native
  means fixing our calls in `src/core` against the new header; there is no binding layer
  to wait for. Pin a release and upgrade deliberately.
- **imgui backend coupling.** imgui's WebGPU backend must match the wgpu-native header.
  A wgpu-native upgrade may need a newer imgui than zgui ships (see Dependencies).
- **Naga vs. Tint.** WGSL is compiled by naga. Its errors and occasional gaps differ from
  Dawn's; the Rust projects are the reference for what works.
- **zgui on WebGPU** draws inside a render pass, not after swap, so apps' frame order changes.
- **Asset variety.** glTF files use many vertex formats; conversions in Step 4 need the full
  demo_app model list to validate.

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
| `texture.zig` | `texture.zig` | RGBA upload, sRGB vs linear, render-pass mipmap generator, sampler cache |
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
- **Joint matrices and baked animation** use read-only storage buffers.
- **Shaders**: hand-written WGSL, loaded from files at runtime. A generated header of shared
  constants (`MAX_JOINTS`, ...) and `common.wgsl` are prepended.
- **Depth**: 0..1 clip space, `Depth32Float`, `*Zo` projections.
- **Color**: sRGB surface (`BGRA8UnormSrgb`, chosen from the surface capabilities); base
  color and emissive textures `rgba8unorm-srgb`; normal, metallic-roughness, occlusion
  `rgba8unorm`. Shaders output linear color and do no manual gamma.
- **Mipmaps**: our own generator in `texture.zig` (WebGPU has none). It renders each mip level
  from the one above with a full-screen triangle and a linear sampler, one pipeline per
  format, so any size and sRGB formats work.
- **Device limits**: a device gets WebGPU's defaults (4 bind groups, 8 vertex buffers, ...)
  unless `requiredLimits` asks for more, not the adapter's (the M1 offers 8 and 16). The
  defaults cover the design (groups 0-3, 7 PBR vertex buffers), so none are requested yet;
  a step that needs more adds it to `requiredLimits` in `GpuContext.init`.
- **Texture origin top-left**; no default V-flip.
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
| Pipeline cache key | 3 | `PipelineConfig` struct (shader, blend, depth write/compare, cull, topology) hashed to a pipeline |
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
  8 screenshot readback, 9 shadow UV)
- Tests: hand-computed known matrices, near → 0 / far → 1 depth, mouse rays at the center
  and corners; `ray.zig` restored with tests for later picking

**Done:** `zig build test` passes; no GL projections remain.

### Step 3 - Rendering Foundation: Shaders, Bindings, Pipelines, Shapes

The step that fixes the core patterns. Split in two.

**3a - one colored cube**
- `bindings.zig` (groups 0-3, generated WGSL constants), `shader.zig`, `pipeline.zig`
- `render_context.zig` writes `FrameUniforms` to group 0's persistent buffer once per frame
- `uniform_ring.zig`; per-draw uniforms from it on group 2 with dynamic offsets
- `shapes/shape.zig`: `ShapeBuilder` → per-attribute vertex buffers; `Shape.draw(pass, ...)`
- Shape flags (transparent, double-sided, depth write) select a pipeline variant instead
  of toggling state

**3b - textures and all shapes**
- `texture.zig`: `flip_v` / `zstbi.setFlipVerticallyOnLoad` existed for GL's bottom-left
  texture origin; with WebGPU's top-left origin, glTF and image files load unflipped.
  Keep the option only if an asset proves it needs it
- `texture.zig`: `initFromFile`, RGB → RGBA expansion, sRGB/linear choice, render-pass
  mipmap generator (any size, non-square, sRGB and linear formats), sampler cache keyed by
  filter/wrap
- Remaining shape generators: cubeboid, square, cylinder, sphere, obj_loader, plane
- Port `examples/scene_tree`

**Fixes:** `Shape` leaking texcoord/normal buffers, `Shape.draw` always disabling culling,
`Plane` having 2 normals for 4 vertices, dead `Plane.draw` / `shapes/cube.zig` / `createSkybox`.

**Done:** scene_tree renders with textures and depth; many shapes drawn with different
transforms in one frame show correct per-draw data.

### Step 4 - glTF Static Meshes with PBR

- `gltf_asset.zig`: GPU objects created at load through the context (device must exist first)
- `mesh.zig`: per-attribute vertex buffers; u8 indices → u16; 3-component 8/16-bit formats
  → 4-component; placeholder buffers for missing attributes
- Texture dedupe per asset; material bind group with 1×1 default textures;
  glTF samplers through the sampler cache
- `model.zig`: per-node transform and material factors as per-draw data
- `pbr.wgsl` from `pbr.vert`/`pbr.frag`; alpha mode and double-sided become pipeline variants
- Port `examples/demo_app` model cycling, static models only

**Fixes:** shared textures uploaded twice and leaked, 2-channel images mapped to RED,
glTF `alpha_mode` / `double_sided` ignored.

**Done:** demo_app's static models render and look correct (color is expected to differ
from GL due to sRGB).

### Step 5 - Skinning and Animation

- Joint matrices in a storage buffer (group 2), written once per model instance per frame
- `model_instance.zig` draw path for live, baked, and no animator
- `baked_animator.zig` + `storage_buffer.zig` replace the TBO; instance matrices likewise
- `pbr.wgsl` skinning path; `pbr_anim_baked.wgsl`
- Port `examples/animation_example`

**Fixes:** `meshID` vs `meshId` naming split, `MAX_JOINTS` hand-copied into shaders.

**Done:** Fox, CesiumMan, and the other animated demo models play live and baked;
animation_example runs.

### Step 6 - bullets

Where new work happens, so it moves ahead of level_01.

- `build.zig.zon` adds zaudio; `sound_engine.zig` moves onto it
- `lines.zig` (1px), `skybox.zig` (cube texture, `LessEqual` depth pipeline, binds its own shader)
- Instanced bullets: per-instance vertex buffers with `stepMode = .instance`
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

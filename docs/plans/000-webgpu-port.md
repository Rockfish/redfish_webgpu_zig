# Plan 000 - Port redfish_gl_zig to WebGPU

## Status: DRAFT

## Context

redfish_gl_zig (`/Users/john/Dev/Dev_Zig/redfish_gl_zig`) is a working OpenGL 4.1 engine:
glTF PBR, skeletal and baked animation, shapes, scenes, zgui. macOS OpenGL stops at 4.1
and GL's quirks keep costing time. This project is the same engine on WebGPU through
zig-gamedev `zgpu` (Dawn), so it has a cross-platform, modern API underneath.

Sources:
- **redfish_gl_zig**: the structure, names, and behavior to match.
- **gui_test_webgpu** (`/Users/john/Dev/Dev_Zig/gui_test_webgpu`): working Zig 0.16 build of
  zgpu + Dawn + zgui `glfw_wgpu`. Copy its `build.zig.zon` dependencies and zgpu setup.
- **small_wgpu_core / angry_wgpu_rust** (`/Users/john/Dev/Dev_Rust/`): earlier wgpu work.
  Reuse the lessons, not the bind group layout (see Design Decisions).

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

- `src/math/` (plus zero-to-one depth projections, Step 2)
- `src/containers/`
- `src/core/`: `context.zig`, `arenas.zig`, `gltf/` (parser, report), `animator.zig` (CPU side),
  `animation_fsm.zig`, `movement.zig`, `transform.zig`, `aabb.zig`, `camera.zig` (logic),
  `frame_counter.zig`, `random.zig`, `colors.zig`, `string.zig`, `utils/`
- `sound_engine.zig` keeps its API but moves onto `zaudio`

## What Gets Rewritten

GL-specific files. Same file name unless the name itself says GL:

| redfish_gl_zig | redfish_webgpu_zig | Notes |
|---|---|---|
| `gl_debug.zig` | `gpu_debug.zig` | Dawn device error/lost callbacks, error scopes |
| (none) | `gpu_context.zig` | Creates the zgpu GraphicsContext, depth texture, per-frame begin/end |
| (none) | `bindings.zig` | Bind group slot numbers, shared layouts, shared WGSL constants |
| `shader.zig` | `shader.zig` | WGSL loader, prepends generated constants + `common.wgsl` |
| (none) | `pipeline.zig` | Pipeline config (blend, depth, cull, topology) → cached pipeline |
| `texture.zig` | `texture.zig` | RGBA upload, sRGB vs linear, mipmaps, sampler cache |
| `texture_buffer.zig` | `storage_buffer.zig` | Storage buffers replace TBOs |
| `mesh.zig` | `mesh.zig` | Per-attribute vertex buffers, format conversion, placeholder buffers |
| `model.zig`, `model_instance.zig` | same | Draw path through bind groups and per-draw uniforms |
| `baked_animator.zig` | same | Storage buffer instead of TBO |
| `render_context.zig` | same | Also produces the frame uniforms for group 0 |
| `lights.zig` | same | Uniform struct in group 0 instead of named uniforms |
| `input.zig` | same | Resize reconfigures surface/depth instead of `gl.viewport` |
| `shapes/*` | same | Vertex buffers + pipeline variants instead of GL state toggles |
| all `.vert`/`.frag` | `.wgsl` | One WGSL file per shader pair |

---

## Design Decisions

### Settled

- **zgpu `GraphicsContext`** owns device, queue, swapchain, resource pools. Raw `wgpu.*`
  calls stay inside `src/core`.
- **Bind groups** (defined in `bindings.zig`, same numbers in WGSL):
  - group 0: frame — camera matrices, view position, time, lights
  - group 1: material — textures, samplers, material factors
  - group 2: object / draw — model transform, node transform, flags, joint matrices
  - group 3: pass-specific — shadow map, etc.
- **Per-draw data** uses `gctx.uniformsAllocate` (per-frame ring buffer) with a dynamic
  offset on group 2. Never rewrite a buffer between draws.
- **Joint matrices and baked animation** use read-only storage buffers.
- **Shaders**: hand-written WGSL, loaded from files at runtime. A generated header of shared
  constants (`MAX_JOINTS`, ...) and `common.wgsl` are prepended.
- **Depth**: 0..1 clip space, `Depth32Float`, `*Zo` projections.
- **Color**: sRGB surface; base color and emissive textures `rgba8unorm-srgb`; normal,
  metallic-roughness, occlusion `rgba8unorm`. Shaders output linear color, no manual gamma.
- **Texture origin top-left**; no default V-flip.
- **Cleanup**: `releaseGpuObjects()` on leaves, `cleanUp()` on aggregates, before arena reset.
- **Dependencies**: URL packages in `build.zig.zon` (as in gui_test_webgpu), not vendored.
- **Frame API**: `gpu_context.beginFrame()` returns a `Frame { encoder, color_view, depth_view }`;
  `endFrame(frame)` submits and presents. Parallel to redfish's clear / `swapBuffers`.
- **Audio**: zig-gamedev `zaudio` replaces the vendored miniaudio module; `sound_engine.zig`
  is adapted to it.
- **Assets**: `assets/` is a symlink to redfish_gl_zig's `assets/` for now.

### To Settle in the Step Where They First Matter

| Decision | Step | Starting proposal |
|---|---|---|
| Where the depth texture lives | 1 | Owned by `GpuContext`, recreated on resize |
| Missing vertex attributes | 4 | One shared placeholder buffer per attribute type, bound with stride 0, so one pipeline serves skinned and unskinned meshes |
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

### Step 1 - Skeleton: Window, Device, Clear, zgui

Mirrors redfish `build.zig` layout: `math`, `containers`, `core` modules and the
`inline for` app table with `<name>` / `<name>-run` steps.

- `build.zig`, `build.zig.zon` (zglfw, zgpu + Dawn packages, zgui `glfw_wgpu`, zstbi, zaudio)
- `src/core/gpu_context.zig`, `src/core/gpu_debug.zig`
- Carry-over modules copied in so `core` builds
- `examples/gpu_caps/` replaces `gl_caps`: prints adapter info and limits, clears the
  screen, shows a zgui panel

**Done:** window clears to a color, zgui panel draws, resizing works without validation
errors, closing shuts down cleanly.

### Step 2 - Math: Zero-to-One Depth

- `Mat4.perspectiveRhZo`, `Mat4.orthographicRhZo` alongside the GL versions
- `Camera` uses the Zo versions; review `getWorldRayFromMouse` NDC z
- Tests comparing against known matrices

**Done:** `zig build test` passes; GL versions remain only where explicitly wanted.

### Step 3 - Rendering Foundation: Shaders, Bindings, Pipelines, Shapes

The step that fixes the core patterns. Split in two.

**3a - one colored cube**
- `bindings.zig` (groups 0-3, generated WGSL constants), `shader.zig`, `pipeline.zig`
- `render_context.zig` writes `FrameUniforms` to group 0
- Per-draw uniforms via `uniformsAllocate` on group 2
- `shapes/shape.zig`: `ShapeBuilder` → per-attribute vertex buffers; `Shape.draw(pass, ...)`
- Shape flags (transparent, double-sided, depth write) select a pipeline variant instead
  of toggling state

**3b - textures and all shapes**
- `texture.zig`: `initFromFile`, RGB → RGBA expansion, sRGB/linear choice, mipmaps via
  `gctx.generateMipmaps`, sampler cache keyed by filter/wrap
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

- Screenshots: render to offscreen texture, `copyTextureToBuffer` (256-byte row alignment),
  map, write PNG with no vertical flip
- Uniform dump for screenshots from the frame/draw uniform structs
- All zgui panels

**Done:** F12 writes a correct PNG and uniform dump; demo_app matches GL feature for feature.

### Step 9 - angrybot and Remaining Examples

- Offscreen targets: shadow depth texture (comparison sampler, PCF), emission, scene,
  blur ping-pong, composite, all as render passes
- Correct shadow NDC → UV mapping (Y flip, raw z)
- Port `examples/skybox`

**Done:** angrybot plays as in GL, including shadows and bloom. It is then the regression
check for later changes.

---

## Risks

- **Per-draw data design (Step 3a).** Everything later depends on it. Test it with many
  draws per frame before moving on.
- **zgpu limits.** `uniforms_buffer_size` (default 4 MiB) and `max_num_bindings_per_group`
  (default 10) are zgpu build options. Check them against the material group and busy scenes.
- **zgui on WebGPU** draws inside a render pass, not after swap, so apps' frame order changes.
- **Asset variety.** glTF files use many vertex formats; conversions in Step 4 need the full
  demo_app model list to validate.

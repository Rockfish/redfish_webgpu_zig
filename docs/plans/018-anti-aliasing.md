# Plan 018 - Anti-aliasing (MSAA)

## Status: Planned (drafted 2026-09-29, not started)

## Context

Nothing is anti-aliased. Every pass renders one sample per pixel, so polygon edges and
shadow silhouettes stair-step, most visibly on the shadows example's slab and pillar and on
thin geometry (the player's antenna and gun in angrybot). The backlog item from 2026-09-29
("Anti-aliasing (MSAA)") becomes this plan.

**MSAA in one paragraph.** With 4x multisampling each pixel of the render target stores
four color and depth samples. The rasterizer tests coverage and depth per sample, but runs
the fragment shader once per pixel and writes its result to the covered samples. Inside a
triangle all four samples get the same color; on an edge only some do. At the end of the
pass the samples are averaged into a normal single-sample texture (the *resolve*), so edge
pixels get a blend of the colors on both sides. The cost is memory (four samples per pixel
for the color and depth attachments) and bandwidth; the fragment shader cost stays about
the same. It smooths geometry edges only: texture detail, shader-computed edges (a shadow's
PCF edge, the spotlight's cone), and alpha-tested cutouts aren't touched.

**WebGPU specifics** (the reason this is a plan and not a flag):

- Sample counts are 1 or 4; 4 is guaranteed for the formats used here (the sRGB surface
  formats, `rgba16float`, `Depth32Float`).
- The surface texture itself is always single-sample. A multisampled pass draws into a
  separate 4x color texture and names the surface texture as its `resolveTarget`.
- Every attachment in a pass has the same sample count, including depth: a 4x pass needs a
  4x depth texture.
- A pipeline's `multisample.count` must match the pass it's used in. Pipelines are created
  at init, so the sample count is decided when the pipelines are.

## Current state (2026-09-29)

- `GpuContext` owns one depth texture, single-sample, sized to the window
  (`createDepthTexture`). `Frame.beginSurfacePass` pairs it with the surface's view.
- `createRenderPipeline` (`src/core/pipeline.zig`) sets `.multisample = .{ .count = 1 }`
  for every `Shader` pipeline. Other pipelines: `mipmaps.zig` (renders into textures; stays
  1x) and ImGui's WebGPU backend (`pipeline_multisample_state` in `gui.zig`, count 1).
- `ScreenCapture` draws an offscreen frame through `beginSurfacePass` into a texture of the
  surface's format.
- angrybot draws its scene and emission into `rgba16float` render targets with
  `gpu.depth_view` (`framebuffers.zig`, `passTarget`), blurs, then composites into the
  window with a full-screen quad. Window MSAA alone wouldn't smooth angrybot: its edges are
  drawn in the render targets.
- Nothing reads the window's depth texture after the pass.

## Design

### Where the sample count lives

`GpuContext.sample_count` (1 or 4), chosen at init from a `GpuContext.Config` field
(`msaa: bool`, default on). It is fixed for the context's lifetime: switching would mean
recreating every pipeline, which the apps don't have a way to do. An app that wants it off
passes the option; the gpu_caps example reports it.

Open question: default on for every app, or opt-in? Leaning on: the cost at these window
sizes is small, and the look improves everywhere. Decide after measuring frame time in
demo_app and angrybot (phase 1 and 2 notes).

### The window pass

`GpuContext` gets a multisampled color texture (surface format, `sampleCount = 4`) and a
multisampled depth texture, both recreated with the surface in `configure`.
`beginSurfacePass` attaches:

- color: the 4x texture, `resolveTarget` = the frame's color view (the surface, or the
  screenshot target), `storeOp = Discard` (only the resolved result is kept);
- depth: the 4x depth texture, `depthStoreOp = Discard`.

With `sample_count == 1` everything stays as now. The single-sample depth texture stays
for render-target passes that aren't multisampled (angrybot's blur and composite don't use
depth; its scene and emission passes change in phase 2).

`PassTarget` gets an optional `resolve` view, so render-target passes can multisample too
(phase 2). `beginPass` sets `resolveTarget` from it.

### Pipelines

`PipelineConfig.sample_count` (default 1) goes into `.multisample.count`. `Shader` derives
it from `ShaderConfig.color_target`:

- `.surface`: `gpu.sample_count` (it draws in the window pass);
- `.format` (render targets) and `.none` (depth-only shadow passes): 1, unless
  `ShaderConfig.multisampled = true` (phase 2, for angrybot's scene and emission).

Shadow passes stay single-sample: shadow maps are sampled as depth textures, and a 4x depth
texture can't be sampled by a comparison sampler.

ImGui draws in the window pass: `gui.init` passes `gpu.sample_count` in
`pipeline_multisample_state`.

### Screenshots

`ScreenCapture` needs no change: its offscreen frame goes through `beginSurfacePass`, so it
resolves into the capture texture as the window does. Its texture stays single-sample.

### Validation

A pipeline or attachment with the wrong sample count is a wgpu validation error the first
time it's used, so running every app once catches any path that was missed. The phase
checks are: every app starts and draws with no `error(gpu` lines, then screenshots of the
same view with and without MSAA, enlarged.

### Alternatives considered

- **FXAA / SMAA** (a post-process pass that detects and blurs edges in the final image):
  works on everything, including shader edges, but blurs texture detail, and needs a
  full-screen pass over the finished frame. MSAA is the standard answer for geometry edges
  and fits the existing pass structure. A post-process pass can come later if shader edges
  bother more than geometry edges.
- **Supersampling** (render at 2x size and downsample): simple, but four times the fragment
  work.
- **A runtime toggle**: would need every `Shader` to rebuild its pipelines on demand. Not
  worth it for comparing; screenshots with the option on and off do that.

## Phases

### Phase 1 - Window MSAA in core
- [ ] `GpuContext.Config.msaa` and `sample_count`; 4x color and depth textures, recreated
      in `configure`, released in `deinit`
- [ ] `beginSurfacePass` with the 4x attachments and the frame's view as resolve target
- [ ] `PipelineConfig.sample_count`; `Shader` sets it from `color_target`
- [ ] ImGui's `pipeline_multisample_state` from `gpu.sample_count`
- [ ] gpu_caps shows the sample count
- [ ] Every app runs without GPU errors; draw_test, shadows, demo_app screenshots on vs off;
      a demo_app screenshot (`ScreenCapture` path) is smooth too; frame time noted

### Phase 2 - angrybot's render targets
- [ ] `PassTarget.resolve`; `beginPass` sets `resolveTarget`
- [ ] `ShaderConfig.multisampled` for render-target pipelines
- [ ] angrybot: 4x textures for the scene and emission passes resolving into the existing
      targets, and a 4x depth texture for those passes; blur and composite unchanged
- [ ] Screenshots: edges smooth, bloom unchanged; frame time noted

### Phase 3 - Optional
- [ ] Alpha-to-coverage for glTF alpha MASK materials (`pbr.wgsl` discards below the
      cutoff, so cutout edges stay jagged under MSAA; with alpha-to-coverage the alpha
      decides how many samples are covered). Only if a model shows it
- [ ] Decide the default (on / off) from the frame times in phases 1-2

Each phase ends with a `CHANGELOG.md` entry and a commit, `zig build test` passing, and all
apps run once.

## Notes & Decisions

**2026-09-29**: Drafted from the backlog item. MSAA over a post-process filter because it
smooths geometry edges without blurring textures and fits the pass structure. Sample
count fixed at `GpuContext` init, because pipelines are. Shadow passes stay single-sample.
angrybot is its own phase: its geometry is drawn in render targets, so window MSAA doesn't
reach it.

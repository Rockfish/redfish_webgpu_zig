# Plan 018 - Anti-aliasing (MSAA)

## Status: Active (phases 1-2 done 2026-09-29; phase 3 optional)

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

**Decided (2026-09-29): a build option, on by default.** `zig build -Dmsaa=false` turns it
off for every app; core reads it as `gpu_context.window_sample_count` (4 or 1), a comptime
constant. A build option fits because the sample count has to be fixed before any pipeline
is created anyway, and it makes on/off comparisons one flag with no app code. (The first
draft had a `GpuContext.Config` field chosen per app at init.) gpu_caps shows it.

### The window pass

`GpuContext` gets a multisampled color texture (surface format, `sampleCount = 4`) and a
multisampled depth texture, both recreated with the surface in `configure`.
`beginSurfacePass` attaches:

- color: the 4x texture, `resolveTarget` = the frame's color view (the surface, or the
  screenshot target), `storeOp = Discard` (only the resolved result is kept);
- depth: the 4x depth texture, `depthStoreOp = Discard`.

With `window_sample_count == 1` everything stays as now. The single-sample depth texture stays
for render-target passes that aren't multisampled (angrybot's blur and composite don't use
depth; its scene and emission passes change in phase 2).

`PassTarget` gets an optional `resolve` view, so render-target passes can multisample too
(phase 2). `beginPass` sets `resolveTarget` from it.

### Pipelines

`PipelineConfig.sample_count` (default 1) goes into `.multisample.count`. `Shader` derives
it from `ShaderConfig.color_target`:

- `.surface`: `window_sample_count` (it draws in the window pass);
- `.format` (render targets) and `.none` (depth-only shadow passes): 1, unless
  `ShaderConfig.multisampled = true` (phase 2, for angrybot's scene and emission).

Shadow passes stay single-sample: shadow maps are sampled as depth textures, and a 4x depth
texture can't be sampled by a comparison sampler.

ImGui draws in the window pass: `gui.init` passes `window_sample_count` in
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
- [x] `-Dmsaa` build option (default on) and `gpu_context.window_sample_count`; 4x color
      and depth textures, recreated in `configure`, released in `deinit`
- [x] `beginSurfacePass` with the 4x attachments and the frame's view as resolve target
- [x] `PipelineConfig.sample_count`; `Shader` sets it from `color_target`
- [x] ImGui's `pipeline_multisample_state` from `window_sample_count`
- [x] gpu_caps shows the sample count
- [x] Every app runs without GPU errors; shadows screenshots on vs off; the
      `ScreenCapture` path is smooth too; cost noted

### Phase 2 - angrybot's render targets
- [x] `PassTarget.resolve`; `beginPass` sets `resolveTarget` (done in phase 1: the window
      pass uses it)
- [x] `ShaderConfig.multisampled` for render-target pipelines
- [x] angrybot: 4x textures for the scene and emission passes resolving into the existing
      targets, and a 4x depth texture for those passes; blur and composite unchanged
- [x] Screenshots: edges smooth, bloom unchanged; cost noted

### Phase 3 - Optional
- [ ] Alpha-to-coverage for glTF alpha MASK materials (`pbr.wgsl` discards below the
      cutoff, so cutout edges stay jagged under MSAA; with alpha-to-coverage the alpha
      decides how many samples are covered). Only if a model shows it
- [x] Decide the default (on / off): on, as a build option (phase 1)

Each phase ends with a `CHANGELOG.md` entry and a commit, `zig build test` passing, and all
apps run once.

## Notes & Decisions

**2026-09-29**: Drafted from the backlog item. MSAA over a post-process filter because it
smooths geometry edges without blurring textures and fits the pass structure. Sample
count fixed at `GpuContext` init, because pipelines are. Shadow passes stay single-sample.
angrybot is its own phase: its geometry is drawn in render targets, so window MSAA doesn't
reach it.

**2026-09-29**: Phase 1 done.
- `-Dmsaa` build option (default true), passed to core through `build_options`;
  `gpu_context.window_sample_count` is 4 or 1.
- `GpuContext` creates the 4x color (surface format) and 4x depth textures with the
  single-sample depth in `createAttachments`, all recreated on resize.
  `Frame.surfaceTarget(label, clear, with_depth)` builds the window pass's target: with
  MSAA, the 4x views plus the frame's color view as `resolve`. `beginSurfacePass` uses it,
  and so does angrybot's composite pass (a window pass without depth that used to name
  `frame.color_view` directly, and whose `.surface` pipeline now has 4 samples).
- `PassTarget.resolve` (from phase 2's list): a pass with a resolve target discards its
  samples and depth at the end (`storeOp = Discard`); only the resolved color is written.
- `PipelineConfig.sample_count`; `Shader` gives `.surface` pipelines the window's count and
  render targets and depth-only passes 1. ImGui gets the window's count. The mipmap
  generator is unchanged (renders into textures).
- Checked: all ten apps run with no GPU validation errors (animation_example's "Invalid
  animation id 4" is on the committed tree too, unrelated). Shadows example, 3x crops:
  the floor's far edge and the pillar are stair-stepped with `-Dmsaa=false` and smooth
  with MSAA. A `ScreenCapture` frame resolves the same way.
- Cost: footprint 101 MB off, 129 MB on, for a 1280 x 800 framebuffer (this display is 1x).
  A Retina framebuffer has four times the pixels, about 110 MB extra. Frame time is
  vsync-bound (the present mode is FIFO), so no difference shows.
- angrybot's scene still has jagged edges: it's drawn in render targets (phase 2).

**2026-09-29**: Phase 2 done.
- `gpu_context.Attachment`: a texture that passes draw into and shaders never sample (depth,
  multisampled color), with its view. `GpuContext` now holds `depth`, `msaa_color`,
  `msaa_depth` as attachments (they were texture / view field pairs).
- `ShaderConfig.multisampled`: a render-target pipeline that draws in a multisampled pass
  gets the window's sample count. angrybot sets it on the nine shaders of its emission and
  scene passes.
- angrybot `FrameBuffers`: one 4x `rgba16float` `msaa_color`, shared by the emission and
  scene passes (each clears it and resolves into its own target); both use the window's 4x
  depth, which is the same size. `passTarget(with_depth)` became `geometryPassTarget`
  (depth, MSAA when enabled) and `quadPassTarget` (the blurs: single-sample, no depth).
- Checked: all apps run with no GPU errors, with MSAA on and angrybot with it off too.
  angrybot on vs off (3x crops): the player's silhouette, antenna, and gun are smooth with
  MSAA; the emissive specks stay pixel-sized (texture detail, which MSAA doesn't touch);
  bloom unchanged.
- Cost: angrybot's footprint 663 MB off, 739 MB on at 1500 x 1000 (the window's 4x color
  and depth plus the 4x `rgba16float`).

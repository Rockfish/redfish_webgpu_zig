# Plan 017 - Shadows: example, debug view, bias and filtering, several lights

## Status: Active (phases 1-3 done 2026-09-29; phase 4 optional)

## Context

Shadows exist in one place: angrybot. `core.ShadowMap` (`src/core/shadow_map.zig`) is a
single `Depth32Float` texture, a `LessEqual` comparison sampler with nearest filtering, and
the group 3 bind group. angrybot creates one (`games/angrybot/run_app.zig:221`), draws
the casters in a depth-only pass, and its floor and player shaders sample it through
`shadowCoords` in `src/core/shaders/common.wgsl:85`. No example exercises shadows on their
own, so a change to `ShadowMap` can only be checked by running angrybot.

The earlier Rust projects went further (see
[the review](../reviews/2026-09-29-rust-wgpu-projects-review.md)):

- small_wgpu_core's `shadows` example (`/Users/john/Dev/Dev_Rust/small_wgpu_core/examples/shadows/`),
  derived from wgpu's own shadow sample: two lights with one layer each in a 2D-array depth
  texture, a comparison sampler with linear filtering, and a debug view that draws a layer
  of the shadow map on screen and can move the camera to a light's point of view.
- The Rust shadow pipelines set a pipeline depth bias, `constant: 2, slope_scale: 2.0`, and
  enable `unclipped_depth` when the device supports it
  (`angry_wgpu_rust/src/render/player_render.rs:31-60`).

This project has none of those. The shader subtracts a constant `SHADOW_BIAS`, and
`PipelineConfig` (`src/core/pipeline.zig`) has no depth bias fields.

Goal: an `examples/shadows` that tests `ShadowMap` without angrybot, and the features
above added to core one at a time, each checked in the example first.

**Out of scope:** cascaded shadow maps, point-light (cube) shadows, shadows in `pbr.wgsl`
(demo_app). These go to the backlog if they come up.

---

## Design

### The example

`examples/shadows`: a floor plane and a few cubes and spheres from `core.shapes`, at
different heights and angles, so both flat and sloped receivers are visible. One directional
light at first. An example-local WGSL shader lights and receives shadows (as angrybot's
floor shader does), with a depth-only caster variant from the same file (`color_target =
.none`, `pass = .shadow`, a `DEPTH_MODE` override constant, as angrybot does).

Controls, shown in a zgui panel:
- Orbit camera (as the other examples).
- Light direction (azimuth / elevation sliders) and the light's ortho extent and near/far.
- Toggles for the features this plan adds: slope bias on/off and its values, nearest /
  linear filtering, PCF kernel size.
- Debug view: off / shadow map overlay / view from the light.

### Debug view

The shadow map is a `texture_depth_2d`. A debug shader reads it with `textureLoad` (no
sampler needed, so it doesn't conflict with group 3's comparison sampler) and draws it as a
grayscale quad in a corner of the window, with a remap from the depth range to 0..1 because
raw depth is mostly near 1. "View from the light" sets the frame's projection and view to
the light's (`light_space`), so the scene draws from exactly where the shadow pass did.

Where the overlay code lives: example-local first. It moves to core (for instance
`ShadowMap.drawDebug`) only if angrybot needs it too.

### Depth bias in the pipeline

`WGPUDepthStencilState` has `depthBias` (i32), `depthBiasSlopeScale`, and `depthBiasClamp`.
Add an optional `depth_bias` to `PipelineConfig` and `ShaderConfig`, used by caster
pipelines only. A slope-scaled bias grows with how steeply the surface faces away from the
light, which a constant shader bias can't do: a constant large enough for sloped surfaces
detaches shadows from their casters on flat ones ("peter-panning").

Open question: keep `SHADOW_BIAS` in the receiving shaders alongside the pipeline bias, or
drop it. Decide in the example by looking at acne and peter-panning on both flat and sloped
receivers. **Decided (2026-09-29): keep both** (see the phase 2 note).

### Filtering

With `magFilter = minFilter = Linear` on a comparison sampler, the hardware compares four
texels and blends the results: 2×2 PCF from one sample. Add a filter option to
`ShadowMap.init` (default `nearest`, redfish's single-sample test, so angrybot looks the
same). angrybot's floor already does a 3×3 PCF by hand; with linear filtering each tap is
smoother, which is worth trying there after the example.

### Several lights

A directional light and a spotlight, each with its own layer in one depth texture: a
`D2Array` texture, one single-layer view per layer as each shadow pass's depth attachment,
and one `D2Array` view for sampling (`texture_depth_2d_array`). This is what small_wgpu_core
did (`angry_wgpu_rust/src/render/shadow_material.rs:60-78, 283-294`).

**The per-pass light matrix is the main design question.** Casters now read
`FrameUniforms.light_space`, one matrix, written once per frame by `gpu.writeFrameUniforms`.
With two shadow passes in one frame, rewriting it between the passes would be the
"rewrite a buffer between draws" bug from the review: both passes would see the last
value. Options:

1. Light matrices as an array in `FrameUniforms` (or `LightsUniforms`), with the pass's
   light index passed to casters as a per-draw value (`DrawUniforms.params` or a new field).
   Receivers loop over the same array.
2. A group 3 binding for casters too: a small uniform with the light index, one bind group
   per layer, set after each shadow `beginPass`. Matches "group 3 is pass-specific".
3. small_wgpu_core's trick: the light index as `instance_index` (`draw_indexed(..., i..i+1)`).
   Compact, but it takes over instancing, so no.

**Decided (2026-09-29): option 2.** Each shadow layer gets its own group 3 bind group over
its own small uniform buffer holding that light's index (or its matrix), written once when
the lights change, before any pass is recorded. Each shadow pass binds its own group after
`beginPass`. No buffer is rewritten between passes, so nothing depends on when queue
writes execute. The light index is a property of the pass, not of the frame or the draw,
and group 3 is the pass-specific group.

The code gets an explanatory comment at the point where the per-layer bind groups are
created: why one buffer rewritten between the two passes would give both passes the
last light's matrix (queue writes all run before the submitted commands), and why a bind
group per pass avoids it. It's the same lesson as `uniform_ring.zig`, applied at pass
granularity, and the review's section 1 shows the bug it prevents.

`ShadowMap` keeps its single-light form for angrybot. Either it gets a `layers` count (1 by
default), or a separate `ShadowMapArray` type is added; decide when writing it.

### Unclipped depth

`WGPUPrimitiveState.unclippedDepth` lets casters in front of the light's near plane still
write depth (clamped) instead of being clipped away, so a tight light volume doesn't lose
tall casters. It needs the `DepthClipControl` feature, requested at device creation, so
it's optional and only used when the adapter has it. Try it last; it may not be needed.

---

## Phases

### Phase 1 - Example and debug view
- [x] `examples/shadows`: floor, cubes and spheres, one directional light, a local
      lit/shadow-receiving shader and its depth-only caster variant; build steps
      `shadows` / `shadows-run`
- [x] zgui panel: light direction, light extent and near/far
- [x] Debug view: shadow map overlay (`textureLoad`, depth remapped) and view from the light
- [x] Screenshot check; angrybot unchanged

### Phase 2 - Bias and filtering
- [x] `depth_bias` in `PipelineConfig` / `ShaderConfig`, set on caster pipelines
- [x] Decide whether receivers keep `SHADOW_BIAS` (acne vs. peter-panning, flat and sloped):
      keep both
- [x] `ShadowMap` filter option (nearest default, linear); panel toggle; PCF kernel size in
      the example shader
- [x] Try slope bias and linear filtering in angrybot; keep them only if it looks as
      good or better than now (angrybot is the regression reference): kept

### Phase 3 - Several lights
- [x] Decide how casters get the pass's light matrix: a group 3 bind group per shadow
      pass (Design, option 2)
- [x] Per-layer group 3 bind groups for casters, with the explanatory comment on why
      they aren't one rewritten buffer
- [x] Layered shadow map (a `layers` count or `ShadowMapArray`): per-layer attachment views,
      array view for sampling, group 3 layout for `texture_depth_2d_array`
- [x] Example: directional light plus spotlight, one shadow pass each; receivers sample
      both layers; debug overlay picks the layer
- [x] `examples/draw_test` and angrybot still pass

### Phase 4 - Unclipped depth (optional)
- [ ] Request `DepthClipControl` when the adapter offers it; `unclipped_depth` on caster
      pipelines when enabled; compare with a tight light volume in the example

Each phase ends with a `CHANGELOG.md` entry and a commit, `zig build test` passing, and
a check of the example, angrybot, and draw_test.

---

## Notes & Decisions

**2026-09-29**: Drafted after the review of the Rust wgpu projects. Plan 016 parked to
make this the active plan. The shadows example is the part of those projects worth
carrying over; the rest either already exists here or isn't needed (see the review's
"Side by side"). Order chosen so the example and debug view come first: every later
change is checked there before it touches angrybot.

**2026-09-29**: Per-pass light matrix decided: a group 3 bind group per shadow pass
(option 2). Chosen because it shows the pattern that avoids the buffer-overwrite bug, at
pass level; the code will carry a comment explaining it.

**2026-09-29**: Phase 1 done.
- `examples/shadows` (`zig build shadows-run`): floor, cubes, spheres, a cylinder, a slab
  tilted 30° as a sloped receiver, and a small cube resting on a larger one. One directional
  light from azimuth / elevation sliders; its orthographic box (extent, distance, near, far)
  is in the panel. Arrows circle the camera (world axes, so the horizon stays level;
  orbit, around the camera's own axes, tilted it), W / S zoom.
- One WGSL file, `shadow_scene.wgsl`, gives both pipelines: lit and receiving (`pass =
  .shadow`), and the depth-only caster (`color_target = .none`, `DEPTH_MODE`), as angrybot
  does. No core changes were needed.
- The shadow bias is a per-draw value for now (`draw.params.x`, a panel slider), so phase 2
  can compare it against the pipeline bias without editing the shader.
- Debug overlay: `shadow_map_overlay.wgsl` reads the map with `textureLoad`, so group 3's
  comparison sampler doesn't matter. Correction to the design note above: the light is
  orthographic, so depth is linear from near to far and not bunched near 1. The overlay
  gets a depth min / max range instead of a fixed remap; the scene occupies roughly
  0.35-0.65 of it at the defaults.
- View from the light uses the light's position and direction with the horizontal extent
  widened to the window's aspect, so the picture isn't stretched; the shadow map covers
  the middle square. No shadows are visible in this view, as expected.
- Checked: screenshots of all three views; `zig build test` (69 pass); draw_test, angrybot,
  and shadows run with no GPU errors.

**2026-09-29**: Phase 2 done in core and the example; the angrybot trial is still open.
- `core.pipeline.DepthBias` (`constant`, `slope_scale`, `clamp`) on `PipelineConfig` and
  `ShaderConfig.depth_bias`; asserted zero for line topologies. With `Depth32Float` the
  constant term is tiny (about 2^-24 per step near depth 0.5); the slope term does the work.
- `ShadowMap.init(gpu, .{ .size, .filter })`: `Filter.nearest` (default, angrybot's look) or
  `.linear`, the hardware 2x2 comparison filter. angrybot's call updated, behavior unchanged.
- Example: panel "Shadows" section with shader bias, pipeline bias on/off with constant and
  slope scale, filter, and PCF radius 0-2 (`draw.params.y`). Pipeline and sampler state are
  fixed at creation, so edits rebuild the caster shader or the shadow map between frames;
  bias sliders rebuild when the drag ends (`zgui.isItemDeactivatedAfterEdit`), not on
  every step.
- **Bias findings** (light elevation 25°, offscreen captures):
  - No bias: acne everywhere (moiré rings on spheres, bands on the floor).
  - Shader bias 0.002 alone, or pipeline bias 2 / 2.0 alone, with a single sample: clean.
  - Pipeline bias 2 / 2.0 with 3x3 PCF: faceted acne returns on the spheres. PCF compares
    the fragment's depth with neighboring texels, which on a curved or sloped surface are
    deeper by about slope × offset; the caster-side slope term only covers one texel.
    Slope scale 4 nearly fixes it (a few faint lines).
  - Pipeline 2 / 2.0 plus shader bias 0.0005 with PCF: clean. So is shader 0.002 alone
    with PCF; no peter-panning was visible at this scene's scale (0.002 of a 49-unit depth
    range is about 0.1 units).
  - Decision: keep both. The slope-scaled caster bias handles steep surfaces, and a small
    receiver bias covers PCF's neighbor samples. Example defaults: pipeline 2 / 2.0, shader
    0.0005, linear, PCF radius 1.
- **angrybot trial not done.** `screencapture` stopped being able to read windows during
  this session, and angrybot has no offscreen capture path (its frame goes through several
  render targets before the composite), so there was no way to compare before and after.
  Its map is 6144 texels over 20 units (about 3 mm per texel), and the floor already does a
  3x3 PCF, so the expected difference is small. Next: try `.filter = .linear` and a caster
  `depth_bias` in angrybot and compare on screen.
- Tooling note: the example's check used a temporary edit that draws one offscreen frame
  with `core.ScreenCapture` at frame 30, writes a PNG, and exits. It works without
  screen-recording permission.

**2026-09-29**: Memory check after a system freeze (macOS reported the shadows app at 1.2 GB
just before it). Not reproduced: the physical footprint (`footprint -p`) held at 81-85 MB
idle, with the shadow map or caster shader rebuilt every frame, in both debug views, with
the light animated, with the window resized every frame, and with simulated panel input.
There was no JetsamEvent report to name the process. One real fix: the example gave ImGui
the arena allocator, and ImGui frees in any order, while an arena only reclaims its most
recent allocation. It now gets the general-purpose allocator, like the other apps. If it
happens again, watch the Memory column in Activity Monitor for `shadows`.

**2026-09-29**: angrybot trial done; both kept. Caster pipelines (player, enemies) get
`depth_bias = .{ .constant = 2, .slope_scale = 2.0 }` and the shadow map `.filter = .linear`;
the receivers keep `SHADOW_BIAS = 0.001`. Window captures of the same view before and after
(3x crops): the baseline shows a stippled dark outline of self-shadow acne along the eel's
back, which is nearly edge-on to the light; the trial doesn't. The floor shadows and the
player look the same at the game camera's distance.

**2026-09-29**: Phase 3 done.
- `core.ShadowMapArray` (`src/core/shadow_map_array.zig`), a separate type; `ShadowMap`
  stays the single-light form for angrybot, since the WGSL types differ
  (`texture_depth_2d` vs `texture_depth_2d_array`). One depth texture with a layer per
  light (up to `MAX_SHADOW_LAYERS` = 4), a single-layer 2D view per layer as each shadow
  pass's attachment, and a 2D-array view for sampling.
- Light matrices: one uniform buffer with a 256-byte slot per layer
  (`ShadowLayerUniforms`, WGSL `struct ShadowLayer { @size(256) light_space: mat4x4f }`).
  256 is WebGPU's minimum uniform offset alignment, so the same buffer serves both sides:
  - each layer's caster bind group (`PassKind.shadow_caster`) binds its own slot, 64
    bytes at `layer * 256`;
  - the receivers' bind group (`PassKind.shadow_layers`) binds all slots as
    `array<ShadowLayer, MAX_SHADOW_LAYERS>`, next to the texture array and sampler.
  `setLightSpace` writes each slot once per frame, before any pass is recorded. The comment
  on the caster bind groups in `ShadowMapArray.init` explains why a rewritten single buffer
  would give every layer the last light's shadows.
- The caster is its own WGSL file (examples/shadows/shaders/shadow_caster.wgsl) instead of
  a `DEPTH_MODE` override in the scene shader: an override-guarded branch still counts as
  using the caster's group 3 binding, which the receivers' layout doesn't have.
- Example: directional light (layer 0) plus spotlight (layer 1, point light 0 in
  `SceneLights`). The spotlight's cone is its shadow projection: a perspective frustum
  whose field of view is the cone, lit inside the circle inscribed in its map with a soft
  edge (`spotCone`). Panel: spotlight on/off, position, cone, range, intensity; the debug
  views pick a layer. With the spotlight off, its shadow pass is skipped.
- Checked with window captures: shadows from both lights (overlapping shadows on the slab
  are one light's shadow lit by the other); the spot layer's overlay (perspective depth,
  near 1: shown with depth range 0.9-1.0) and the view from the spotlight (a centered
  circle, none of its own shadows visible). `zig build test` passes; draw_test and angrybot
  run without errors.

# 009 - angrybot: Passes, Shadows, Bloom, Audio

Port Step 9. angrybot is the only app with more than one render pass per frame, a shadow
map, post-processing, and sound. It is ported last and then kept as the regression check.

Split: **9a** core (passes, render targets, shadows, audio), **9b** the angrybot app,
**9c** `examples/skybox`.

## Frame of angrybot in GL

1. Shadow pass: `depth_map_fbo` (6144², depth only). Player and enemies drawn with their
   usual shaders in `depth_mode` (vertex uses `lightSpaceMatrix`, fragment writes white).
2. Emission pass: `emissions_fbo`. Player with its emissive texture only, then the
   bullets (alpha blended).
3. Scene pass: `scene_fbo`. Floor (3×3 PCF shadow), player (shadow, spec, emission,
   muzzle point light), muzzle flash sprite, enemies (wiggle vertex shader), burn marks,
   bullet impact sprites.
4. Blur: emission → horizontal blur → vertical blur, half resolution, 28 taps.
5. Composite to the window: scene + blurred emission × 2.9 + a brightness boost from the
   unblurred emission.

## Multi-pass frames (core)

A `Frame` is one surface texture and one command encoder; passes are opened and closed on
it in order:

```zig
var frame = gpu.acquireFrame() orelse continue;   // no pass open yet
gpu.writeFrameUniforms(uniforms);

frame.beginPass(shadow_map.passTarget());
player.draw(&frame, player_shadow_shader);
frame.endPass();

frame.beginPass(emission.passTarget(gpu, .{ 0, 0, 0, 0 }));
...
frame.endPass();

frame.beginSurfacePass(CLEAR_COLOR);
composite...
gpu.endFrame(frame);                               // ends the open pass, submits, presents
```

- `PassTarget { color: ?view, depth: ?view, clear_color, label }`. Each pass binds group 0.
  Viewports default to the attachment size, so the half-size blur targets need nothing.
- `beginFrame(clear)` stays: `acquireFrame` plus `beginSurfacePass`. No other app changes.
- Bind groups are per pass in WebGPU, so group 3 (shadow map) is bound after `beginPass`.
- The uniform and vertex rings upload once, before the single submit, as before.

## Pipelines for other targets

`ShaderConfig` gains:

- `color_target: .surface | .{ .format = f } | .none`. `.none` is a depth-only pipeline
  (no fragment stage) for the shadow pass.
- `depth: bool = true`. False for the full-screen blur / composite passes.
- `pass: PassKind = .none | .shadow`, what the shader binds at group 3.
- `constants`: WGSL `override` values. The shadow pipeline of a shader is the same file
  with `DEPTH_MODE = true`, as GL's `depth_mode` uniform, so the shadow position always
  matches the lit position (skinning, wiggle).

## Shadows

- `core.ShadowMap`: `Depth32Float` texture, size from the app (angrybot: 6144 as GL), a
  comparison sampler (`LessEqual`, nearest, clamp-to-edge), and its group 3 bind group
  (`texture_depth_2d` + `sampler_comparison`).
- `FrameUniforms.light_space` (GL's `lightSpaceMatrix`): available in every pass, including
  the shadow pass, which binds no group 3 (a texture can't be sampled and be the depth
  attachment in one pass).
- `common.wgsl` `shadowCoords(light_clip)`: `uv = (x * 0.5 + 0.5, 0.5 - y * 0.5)`, raw z
  (already 0..1); the light projection is `orthographicRhZo`. GL mapped z with
  `* 0.5 + 0.5` too and didn't flip y.
- Samples use `textureSampleCompareLevel(map, sampler, uv, depth - bias)`, which returns 1
  when lit. Outside the map GL's border color (1) meant lit; WebGPU has no border color,
  so the shader treats coordinates outside 0..1 as lit.
- The floor keeps GL's 3×3 PCF and its `/ 7 * 0.7` weighting.

## Render targets and bloom

- `Texture.initRenderTarget(gpu, width, height, format, label)`: a `Texture` that is also a
  render attachment (linear clamp sampler, group 1 `.texture` bind group), so blur passes
  sample the previous target with `target.bind(frame)`.
- Emission, scene, and blur targets are `rgba16float` (GL used `RGB8`, clamping at 1). The
  scene and emission passes share `gpu.depth_view` (same size as the surface; each clears).
- The composite samples three targets through a `.pbr` material made from them (base
  color = scene, emissive = blurred emission, metallic-roughness = raw emission), the same
  slot reuse the bullets shaders use. Targets and that material are recreated on resize.
- Colors are linear throughout and the sRGB surface encodes, as every other port. GL did
  its math on sRGB-encoded values, so bloom and highlights differ slightly.

## Per-draw values

`DrawUniforms.params: vec4f` for shader-specific per-draw values (sprite columns, time per
frame, age). GL set these as uniforms between draws.

## Audio

zaudio (zig-gamedev, miniaudio 0.11.25, Zig 0.16, active in 2026) replaces redfish's
vendored miniaudio module. `core.SoundEngine(ClipName, ClipData)` keeps its API
(`init(allocator, clips)`, `playSound(clip)`, `deinit`).

## Fixes found porting

- Enemy: GL ignored the glTF node transforms and added its own +90° X rotation, which is
  what the node chain holds. The port uses the asset's node transform and drops the manual
  rotation (a 0.04 unit height offset remains from the node translation).
- Normals use `draw.normal_matrix` (with the skin). GL used `aimRot × last joint` for the
  player and a fixed +90° X rotation for enemies, so enemy lighting ignored their heading.
- Floor specular: GL bound the spec map as `texture_spec`, but the shader samples
  `texture_specular`, so it read whatever was in texture unit 0. The port binds the map.
- GL enabled face culling only after the first bullet draw; the port culls from the start
  (materials say double-sided where needed).
- The player model is drawn in three passes per frame; its joint buffer gets the same pose
  each time, which is safe (the once-per-frame rule is about different poses).

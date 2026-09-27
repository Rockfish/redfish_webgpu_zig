# Step 4 Design: glTF Static Meshes with PBR

Written before the code; updated if the code proves a decision wrong.

## Split

- **4a, core:** `animator.zig` (CPU side), `gltf_asset.zig`, glTF textures, `mesh.zig`,
  `material.zig`, `pbr.wgsl`, `model.zig`, `model_instance.zig` (live animator and none;
  baked in Step 5), `gltf/report.zig`.
- **4b, demo_app:** model cycling with `BAKE_ANIMATION = false` until Step 5. Screenshots
  and the uniform dump are Step 8.

## Vertex data: one canonical format

glTF allows float or normalized u8/u16 attributes, vec3 or vec4 colors, u8 or u16 joints,
and interleaved buffer views. WebGPU bakes vertex formats into the pipeline, so every
attribute is converted on load:

| Attribute | Location | Canonical format | Missing |
|---|---|---|---|
| position | 0 | `float32x3` | required |
| texcoord 0 | 1 | `float32x2` | (0, 0) |
| normal | 2 | `float32x3` | generated (`accurate` / `simple`) or (0, 1, 0) with `has_normals` off |
| tangent | 3 | `float32x4` | (1, 0, 0, 1) |
| color 0 | 4 | `float32x4` | (1, 1, 1, 1), `has_vertex_colors` off |
| joints 0 | 5 | `uint32x4` | (0, 0, 0, 0) |
| weights 0 | 6 | `float32x4` | (0, 0, 0, 0) |

One vertex layout for every primitive, so one `Shader` (16 render-state variants) draws
every glTF mesh. This replaces the plan's stride-0 placeholder proposal: conversion is
needed anyway, and per-vertex defaults are what shapes already do. The cost is memory
(about 108 bytes per vertex), irrelevant at these model sizes.

Accessors are read through a strided reader (`byte_stride` or tight packing), so
interleaved buffers need no special case. Sparse accessors are not supported (as in
redfish).

**Indices**: u8 widens to u16 (WebGPU has no u8 index format); u16 and u32 are kept. Index
buffers are padded to a 4-byte size (`wgpuQueueWriteBuffer` requires it). Non-indexed
primitives use `draw`.

Only `triangles` mode is drawn; other modes are logged and skipped (as in redfish, which
drew everything as triangles).

## Materials: group 1, one bind group per primitive

`MaterialKind.pbr` layout:

| Binding | Resource |
|---|---|
| 0 | `MaterialUniforms` (base color factor, emissive factor, metallic, roughness, alpha cutoff, flags) |
| 1-5 | base color, metallic-roughness, normal, occlusion, emissive textures |
| 6-10 | a sampler for each, from the glTF sampler through `GpuContext.samplers` |

Missing textures bind shared 1×1 defaults (white, and a flat normal), so the shader never
branches on a missing binding; flags say which textures are real where the result would
differ (normal map, occlusion, emissive per the rules below). Flags also carry the
primitive's `has_normals`, `has_vertex_colors`, `has_skin`, and alpha mode.

Color space per glTF: base color and emissive sRGB, the rest linear. Textures are deduped
by glTF texture index; one referenced as both color and data logs a warning and keeps the
first.

**Render state** from the material: `BLEND` → transparent, no depth write;
`double_sided` → no culling; `MASK` → discard below `alpha_cutoff` in the shader.

## Behavior changes from redfish (correctness)

- Manual gamma (`pow(color, 1/2.2)`) removed; the surface is sRGB.
- Emissive follows glTF: `emissive_factor * texture`, texture defaulting to white. redfish
  ignored the factor without a texture.
- Alpha mode and double-sided honored (were ignored).
- Textures uploaded once per asset and released (were uploaded per reference and leaked).
- 2-channel images read as color (were mapped to RED).

## Draw path shared by Model and ModelInstance

`MeshPrimitive.draw(frame, shader, draw_uniforms)` sets the pipeline from the material's
render state, binds the material group and the ring offset, and draws. `Mesh.draw` loops
primitives. `Model.draw` and `ModelInstance.draw` walk nodes, compute
`model_transform * node_transform`, and call `Mesh.draw`. Retiring `Model` later touches no
GPU code.

## Lighting until Step 6

One point light (position, color, intensity) is added to `FrameUniforms`. Step 6 replaces
it with `SceneLights`.

## Skinned meshes in Step 4

Drawn unskinned with their node transform. Joint matrices in a storage buffer and the
skinning path are Step 5.

## Deferred

- `GltfAsset.addCustomTexture` binds by GL uniform name. It returns with the first app that
  uses it, designed for bind groups then.

## Found while building

- `Animator.init` left each node's `calculated_transform` as its local transform; world
  transforms were only computed by `updateAnimation`. `init` now composes them once.
- `calculateBoundingBox` ignored node `matrix`, so the Duck normalized 100× too small.
- wgpu-native on Metal returns `Occluded` (not in `webgpu.h`) when the window is hidden or
  covered. `beginFrame` skips the frame and waits briefly for events instead of spinning.

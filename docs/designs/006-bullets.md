# Step 6 Design: Lights, Lines, Skybox, Instancing, bullets

Split: **6a** core (below), **6b** the bullets app (three scenes, cannon, turret, bullets).
zaudio moves to Step 9: only angrybot plays sound.

## SceneLights in group 0

`lights.zig` keeps redfish's `SceneLights` API (`init`, `towerDefenseDefaults`,
`setPointLight`) and drops `apply(shader)`. `SceneLights.uniforms()` fills a
`LightsUniforms` block inside `FrameUniforms`, so every shader sees the frame's lights.
This replaces Step 4's single temporary light and fixes `apply` being a no-op for PBR.

PBR reads the same lights: the direction light unattenuated, point lights with
`constant + linear·d + quadratic·d²`, and `ambient × base color` (was a constant 0.15).
demo_app's old light becomes `ambient 0.15` plus one point light at (50, 50, 50), color
×100, attenuation (1, 0.01, 0.001): the same look.

One light set per frame: where redfish lit the floor and the models of a scene with
different uniforms, the scene's `SceneLights` now carries both (toon gallery: the PBR light
becomes a point light).

## Per-frame vertex data: the vertex ring

Lines (redfish rewrote one VBO per `draw`) and bullet instance data change every frame.
Rewriting a buffer between draws would give every draw the last data, so both append into
a **vertex ring** next to the uniform ring: each draw writes its own region and binds that
offset; the ring resets each frame. `uniform_ring.zig` becomes a generic `FrameRing`
(`UniformRing` = uniform usage, 256-byte slices; `VertexRing` = vertex usage, 4-byte).
This also makes "bullet instance buffers never freed" moot: there are none.

## Instancing

`Shape.drawInstanced(frame, shader, draw_uniforms, instance_data, count)`: the shape's four
vertex buffers plus one ring slice per instance attribute (`stepMode = Instance`).
`shapes.instancedVertexLayouts(attrs)` builds the shader's vertex layout: the shape's
layouts followed by the instance ones at the given locations (bullets: rotation quat at
8, position at 9).

## Shader config

`Shader.init(io, allocator, gpu, path, config)` with `ShaderConfig { vertex_buffers,
material = .none, topology = .triangle_list }`. Lines use `.line_list`. Lines are 1 px
(`lineWidth` doesn't exist).

## Materials on shapes: the bound material

Step 5's `bound_texture` generalizes to a **bound material** (group 1 bind group plus its
`MaterialKind`). `texture.bind(frame)` binds a `.texture` material; `PbrMaterial.bind` binds
a `.pbr` one. `Shape.draw` sets group 1 from the bound material when its kind matches the
shader's, and logs otherwise. The floor's three maps (diffuse, normal, specular) become a
`PbrMaterial` built from textures (`initWithTextures`) in the base-color, normal, and
metallic-roughness slots.

## Skybox

Owns its shader (`src/core/shaders/skybox.wgsl`), a 6-layer cube texture, and a pipeline
with `LessEqual` depth, no depth write, no culling (`PipelineConfig.depth_compare`). The
shader drops the view's translation itself; `pos.xyww` puts it at depth 1. Face order and
the horizontal flip are redfish's: cube map sampling is the same in both APIs. Fixes
redfish's `SkyBoxDirections.draw` never binding its shader.

## Ported bugs, noted not fixed

- `basic_model.frag` point lights use `normalize(worldPos)` (direction from the origin).
- `basic_texture.frag` uses the floor's tangent-space normal map as a world normal.

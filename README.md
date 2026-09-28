# redfish_webgpu_zig

A small 3D engine in Zig for animated glTF models with PBR rendering, on WebGPU through
wgpu-native. The engine code is meant to be readable: most of it is plain Zig 
with few layers between the application and the GPU.

Zig 0.16. Tested on macOS arm64 (Metal); wgpu-native is only listed for that platform.

## Highlights

- **Own glTF loader** (`src/core/gltf/`, `src/core/gltf_asset.zig`). Parses `.gltf` and
  `.glb` directly: scenes, nodes, meshes, materials, textures, samplers, skins, and
  animations. Vertex attributes in any glTF format are converted to one canonical layout.
  A report tool prints what a file contains.
- **Own WebGPU binding** (`src/core/wgpu/`). The build translates wgpu-native's `webgpu.h`
  with Zig's translate-c; there is no binding package. Raw WebGPU calls stay in
  `src/core`.
- **Live and baked animation.** Live: keyframes sampled and blended per frame, including
  weighted blending between clips (`animator.zig`). Baked: poses precomputed into a
  storage buffer and indexed per instance (`baked_animator.zig`). One PBR shader skins
  both.
- **Own math library** (`src/math/`). Vectors, matrices, and quaternions, column-major,
  with WebGPU's 0..1 depth projections, ray tests (plane, triangle, sphere), mouse picking
  for perspective and orthographic cameras, and easing functions. Bounding boxes and their
  ray test are in `src/core/aabb.zig`.
- **Camera movement** (`src/core/movement.zig`). One place for the ways a camera or object
  can move: translate, turn, free-look rotate, roll, orbit around a target in local or
  world axes, and dolly, with pitch limits and handling near the poles.

## Rendering

- Metallic-roughness PBR (GGX, Schlick), normal, occlusion, and emissive maps, alpha mask
  and blend, double-sided materials.
- Scene lights: one directional light, point lights, ambient.
- Bind groups by update rate: frame, material, per-draw, per-pass. Per-draw values go
  through a uniform ring with dynamic offsets.
- Render state (blend, culling, depth) is pipeline state: each shader builds its pipeline
  variants at startup.
- The WGSL header (bind group numbers, attribute locations, flags) is generated from the
  Zig structs, so both sides stay in sync.
- Multi-pass frames: shadow maps (comparison sampling, PCF), render targets, bloom.
- Instancing, lines, skybox, basic shapes, OBJ loading with MTL colors.
- Mipmaps generated on the GPU (WebGPU has no built-in mipmap generation).
- Screenshots read back from the GPU to PNG, with a dump of the frame's uniforms.
- sRGB surface and textures; shaders work in linear color.
- zgui (Dear ImGui) panels, sound through zaudio.

## Apps

Build with `zig build <app>`, run with `zig build <app>-run`.

| App | What it shows |
|---|---|
| `gpu_caps` | Adapter info and limits, surface format, a zgui panel |
| `draw_test` | Many draws per frame: the per-draw data path |
| `scene_tree` | Node hierarchy, picking with the mouse, perspective and orthographic |
| `demo_app` | A list of glTF models (Khronos samples and others), animation, UI panels, F12 screenshots |
| `animation` | Live and baked animation, many instances |
| `bullets` | Instancing, lines, skybox, OBJ scenes |
| `skybox` | Cube-map sky and a textured cube |
| `level_01` | Small scene with picking and an animated character |
| `angrybot` | Top-down shooter: shadows, bloom, skinned and blended animation, sound |

Assets are expected in `assets/` (the demo models also in `assets_nas/`); both are symlinks
in the author's setup.

## Development

- `zig build test` runs the unit tests and `tests/analyze_all.zig`, which makes Zig
  type-check every public declaration in math, containers, and core. Zig only analyzes
  code that is called, so without it an unused function can hide compile errors.
- `docs/STYLE.md` is the style guide; `docs/plans/` and `docs/designs/` hold the port plan
  and design notes; `CHANGELOG.md` lists changes by step.

## Dependencies

- wgpu-native (prebuilt library, `webgpu.h`)
- zglfw (windows and input) 
- zgui (Dear ImGui)
- zstbi (image loading)
- zaudio (sound)

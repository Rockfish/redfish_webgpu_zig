# Step 3a Design: Shaders, Bindings, Pipelines, Per-Draw Data

The patterns every later draw path follows. Written before the code; updated if the code
proves a decision wrong.

## The GL pattern being replaced

redfish sets named uniforms on a program whenever it likes, then draws:

```zig
shader.setVec4("hit_color", &vec4(1, 0, 0, 0));
node.draw(shader);
shader.setVec4("hit_color", &vec4(0, 0, 0, 0));
```

In WebGPU, buffer writes land before the frame runs, so the last write wins and every draw
sees zero. Per-draw values must live in per-draw memory.

## Files

| File | Role |
|---|---|
| `bindings.zig` | Group numbers, vertex attribute locations, shared constants, the Zig mirrors of `FrameUniforms` / `DrawUniforms`, the WGSL header generated from them, and the shared bind group layouts |
| `uniform_ring.zig` | One uniform buffer for per-draw data; slices allocated per draw, uploaded once per frame |
| `shader.zig` | Loads a WGSL file, prepends the generated header and `common.wgsl`, creates the module |
| `pipeline.zig` | `PipelineConfig` → render pipeline; `RenderState` flags → one of the precreated variants |
| `shaders/common.wgsl` | `FrameUniforms`, `DrawUniforms`, and their bindings; embedded in the binary |
| `shapes/shape.zig` | `ShapeBuilder` → per-attribute vertex buffers; `Shape.draw(frame, shader, draw)` |

## Decisions

**One `DrawUniforms` for every draw path.** `model`, `normal_matrix`, `color`, `flags`.
glTF's node transform is folded into `model` on the CPU, so PBR, shapes, and lines share the
struct; material factors go in group 1. `normal_matrix` is computed on the CPU because WGSL
has no `inverse()`; it is a `mat4x4` because a WGSL `mat3x3` uniform pads each column to 16
bytes and Zig's `Mat3` doesn't.

**Uniform ring.** A 4 MiB uniform buffer owned by `GpuContext`. During the frame,
`allocate(DrawUniforms)` copies the struct into a CPU staging slice at 256-byte alignment
(`minUniformBufferOffsetAlignment`) and returns the offset. `endFrame` does one
`wgpuQueueWriteBuffer` before submit. Reusing the same buffer next frame is safe: queue
operations run in order, so frame N+1's write can't overtake frame N's draws. One bind group
(group 2) binds the buffer with `hasDynamicOffset`; each draw passes its offset. Overflow is
a panic naming the constant to raise; it is a sizing bug, not a runtime condition.

**Frame uniforms.** A persistent buffer written once per frame (`gpu.writeFrameUniforms`)
from `RenderContext`, bound at group 0 when the main pass opens.

**Empty material group.** A pipeline layout that uses group 2 must also have group 1.
Until materials exist (3b), shaders without textures get an empty layout and bind group.

**Pipeline variants precreated.** `Shape` flags (`is_transparent`, `is_double_sided`,
`is_depth_write`, `is_depth_test`) map to a 4-bit `RenderState`. A `Shader` creates all 16
variants at init and `draw` indexes them. That keeps "created at init, never per frame"
and replaces the plan's proposed hashed cache: no hashing, no first-use hitch. `is_wireframe`
is dropped; WebGPU has no polygon mode (wgpu-native's `PolygonModeLine` extension can bring
it back if needed).

**Fixed vertex layout for shapes.** Locations match redfish's `constants.VertexAttr`
(position 0, texcoord 1, normal 2, color 4). `ShapeBuilder` fills missing attributes
(white color, zero texcoords) so one pipeline layout serves every shape. The stride-0
placeholder buffer stays the proposal for glTF meshes (Step 4), where attribute sets vary.

**Culling on.** Counter-clockwise front faces, back faces culled unless `is_double_sided`.
Fixes redfish's `Shape.draw` always disabling culling.

**Shader errors.** `Shader.init` wraps module creation in a validation error scope and returns
`error.ShaderCompile` with naga's message logged, instead of an uncaptured error later.

**`common.wgsl` embedded.** Core owns it, so it's `@embedFile`d rather than found via the
working directory. App shaders still load from files at runtime, as in redfish.

## Checked on screen

`examples/draw_test`: a grid of cubes, each drawn with its own model matrix and color
through the ring, rotating. Every cube distinct means per-draw data works; all the same
color or position means a write-between-draws bug.

## Step 3b additions

**Materials.** A `Shader` declares a `MaterialKind` for group 1 (`none`, `texture`). Each
`Texture` owns a bind group for the `texture` layout, and `texture.bind(frame)` sets it for
the draws that follow. This keeps redfish's "bind texture, then draw" shape and is correct
WebGPU: `setBindGroup` is recorded in draw order, unlike buffer writes.

**Samplers** come from `GpuContext.samplers`, keyed by filter / wrap / mipmaps, so
textures with the same settings share one. `lodMaxClamp` and `maxAnisotropy` are set
explicitly; their zero defaults would disable mipmaps or be invalid.

**Mipmaps** (`mipmaps.zig`): one downsample pipeline per format, each level rendered from
the one above. Sampling an sRGB view decodes and the sRGB target encodes, so filtering
happens in linear space.

**Texture orientation.** Unchanged from GL for loaded images: both APIs sample v = 0 from
the first uploaded row, so `flip_v` keeps its meaning.

**Color constants.** GL displayed color values as-is, so GL-era constants are sRGB values.
`colors.srgbToLinear` converts them for the linear pipeline. Textures need nothing: GL
showed their bytes raw, and decode + encode here gives the same bytes.

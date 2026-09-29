# Review: the Rust wgpu projects compared with this port (2026-09-29)

A look back at two earlier projects, both on wgpu 0.19.1 (early 2024), and how their use of
wgpu compares with redfish_webgpu_zig's use of wgpu-native:

- **small_wgpu_core** (`/Users/john/Dev/Dev_Rust/small_wgpu_core`, last commit 2024-04-28):
  a small engine library (context, camera, assimp model loading, animator, materials) plus
  examples (`draw_triangle`, `draw_cube`, `animation`, `shadows`).
- **angry_wgpu_rust** (`/Users/john/Dev/Dev_Rust/angry_wgpu_rust`, last commit 2024-12-17):
  the angrybot game on top of small_wgpu_core, with a shadow pass and a forward pass.

Both are the same wgpu underneath: the Rust `wgpu` crate is the library that wgpu-native
exposes through `webgpu.h`. So the comparison is about how each project uses the API, not
about two different GPU libraries.

## Summary

The Rust projects were mostly on track. The frame structure, pipeline creation, depth-only
shadow pipeline, layered shadow texture, and instancing were all the right WebGPU patterns.
In the small_wgpu_core `shadows` example, dynamic uniform offsets were used correctly;
that is the pattern this project turned into `uniform_ring.zig`.

The problems were in five places:

1. **Writing a buffer between draws** and expecting each draw to see its own value
   (`update_mesh_buffers` inside the draw loop).
2. **Bind groups organized by resource instead of by update frequency**: seven groups, one
   per texture, so the device needed `max_bind_groups = 8` when WebGPU guarantees 4.
3. **GL conventions left in the shadow lookups**: three shaders, three different
   versions of the lookup, two of them using GL's `* 0.5 + 0.5` on depth and not flipping y.
4. **Color and format details**: pipeline targets taken from `formats[0]` instead of the
   configured surface format; every texture uploaded as sRGB; no mipmaps.
5. **Repetition**: every entity repeated about 100 lines of pipeline descriptor, and group
   numbers were hard-coded separately in Rust and in WGSL.

None of these is a misunderstanding of the whole model. Each one is a detail that WebGPU
handles differently from OpenGL and that neither the API nor the compiler flags.

## What was done right

**Pipelines at init, stored per entity.** `WorldRender::new`
(`angry_wgpu_rust/src/render/main_render.rs:39`) builds every pipeline once; `render` only
sets them. That is how WebGPU is meant to be used. Render state is baked into the pipeline, so
creating pipelines inside the frame loop is the main performance mistake people make coming
from GL, and it wasn't made here.

**Shared bind group layouts.** `bind_layout_cache` in `GpuContext`
(`small_wgpu_core/src/gpu_context.rs:16`) hands every pipeline the same layout object for
the camera, model, and material groups. Bind groups built for one pipeline then work with
another. This project gets the same result from `Bindings` in `src/core/bindings.zig`.

**A correct depth-only shadow pipeline.** `fragment: None`, `DepthBiasState { constant: 2,
slope_scale: 2.0 }`, and `unclipped_depth` enabled when the device supports
`DEPTH_CLIP_CONTROL` (`angry_wgpu_rust/src/render/player_render.rs:31-60`). This follows
wgpu's own shadow example and is right.

**Layered shadow texture with per-layer views.** One `Depth32Float` texture with two array
layers, one `D2` view per layer to render into, and a `D2Array` view for sampling
(`angry_wgpu_rust/src/render/shadow_material.rs:60-78, 283-294`). WebGPU requires a single-layer
view for a render attachment, which is easy to miss, and this got it right.

**One encoder, two passes, one submit.** Each pass lives in its own `{ }` block, so the pass
is dropped (ended) before `encoder.finish()` (`main_render.rs:74-129`). This project does the
same with `frame.beginPass` / `frame.endPass` and one submit in `endFrame`.

**Instancing.** There are three kinds, all correct:
- Enemies: a uniform array of per-enemy data indexed by `@builtin(instance_index)`, one
  `draw_indexed` per mesh for all enemies (`src/render/enemy_render.rs:137`,
  `shaders/wiggle_shader.wgsl:50`).
- Bullets: two instance-rate vertex buffers (`VertexStepMode::Instance`) for position and
  rotation (`src/render/bullet_render.rs:32-50`).
- Muzzle flash sprites: an instance-rate "age" buffer (`src/render/sprite_render.rs:86-97`).

**Dynamic offsets, in the shadows example.** `small_wgpu_core/examples/shadows/entities.rs:96-106`
aligns each entity's uniform slot to `min_uniform_buffer_offset_alignment`, writes all slots
into one buffer, and binds with `set_bind_group(1, &entity_bind_group, &[entity.uniform_offset])`
(`examples/shadows/world.rs:106, 192`). That is the right answer to "per-draw values", and it
is what this project's `UniformRing` generalizes. The lesson just didn't carry over into
angry_wgpu_rust's model code (next section).

**sRGB surface, with the reason written down.** `small_wgpu_core/src/gpu_context.rs:64-72`
picks an sRGB surface format and explains why.

**Uniform layout discipline.** `#[repr(C)]`, `bytemuck::Pod`, and explicit padding fields
(`CameraUniform::_padding`, `ShaderParametersUniform::_pad`) are what WGSL's alignment rules
need. This project does the same with `extern struct` in `bindings.zig`.

## What went wrong

### 1. Rewriting a buffer between draws

`Model::update_mesh_buffers` (`small_wgpu_core/src/model.rs:62-71`) writes the mesh's node
transform into the model's single `node_transform_buffer`. The player and enemy render functions
call it inside the draw loop, once per mesh, between draws
(`angry_wgpu_rust/src/render/player_render.rs:147-148`):

```rust
for mesh in player.model.meshes.iter() {
    player.model.update_mesh_buffers(context, &mesh);   // queue.write_buffer
    ...
    render_pass.draw_indexed(0..mesh.num_elements, 0, 0..1);
}
```

`queue.write_buffer` does not run at that point in the pass. It is queued, and **all** queued
writes execute before the command buffer that holds the draws. So every mesh draws with the
last mesh's node transform. In GL, `glBufferSubData` between draws does act per draw (the
driver versions the buffer behind your back), which is why the pattern looks natural.

It probably went unnoticed because `get_animated_position` in `shaders/common.wgsl:63-104`
only uses `node_transform` when no bone influences the vertex. Skinned meshes never read it;
only a rigid mesh inside a multi-mesh model would show the error.

A second, harmless instance of the same issue: `shadow_render_pass` calls
`set_use_light(false)` and `forward_render_pass` calls `set_use_light(true)`
(`main_render.rs:151, 174`), but the parameter buffer was already uploaded at the top of
`render` (`main_render.rs:66`, and also `game_loop.rs:364`). Neither change reaches the GPU
for that frame; `use_light` is effectively always 1. It didn't matter because the shadow
pipelines have no fragment stage. This is also the only reason `forward_render_pass` needs
`&mut World`.

**How this project handles it:** CLAUDE.md's rule "never rewrite a buffer between draws
expecting per-draw values". Every draw copies its `DrawUniforms` into the CPU staging
memory of `gpu.uniform_ring` and gets an offset (`src/core/uniform_ring.zig:46-61`,
`src/core/mesh.zig:339`). The ring is uploaded once before submit
(`src/core/gpu_context.zig`, `submitFrame`), and each draw binds group 2 with its own
dynamic offset. `examples/draw_test` exists as the regression check for exactly this bug.

### 2. Seven bind groups

The player's forward pipeline layout (`player_render.rs:62-74`):

```
0 camera   1 model   2 params   3 diffuse   4 specular   5 emissive   6 shadow
```

Each texture has its own group because `Material` in small_wgpu_core is one texture plus
one sampler plus one bind group (`small_wgpu_core/src/material.rs:14-23`). WebGPU guarantees
only 4 bind groups, so `GpuContext::new` raises the limit to 8
(`small_wgpu_core/src/gpu_context.rs:44-55`). That works on wgpu native with Metal, but
would fail in a browser or on a device that reports the minimum.

Group numbers also differ per entity: the shadow map is group 6 for the player and floor,
group 5 for enemies (`enemy_render.rs:156`). Each WGSL file and each render function has to
agree by hand.

**How this project handles it:** four groups by update frequency, fixed project-wide
(`src/core/bindings.zig`, `BindGroup`): 0 frame (camera, lights, time), 1 material (all of a
material's textures, samplers, and factors), 2 object/draw (ring offset, joints), 3 pass
(shadow map). Bind groups are set from least to most frequently changed, so a draw normally
rebinds only groups 1 and 2. The numbers and struct layouts are emitted into
`bindings.wgsl_header` (`bindings.zig:183`) and prepended to every shader, so WGSL never
hard-codes a group number.

### 3. GL conventions in the shadow lookups

The matrices were right: glam's `perspective_rh` and `orthographic_rh` produce WebGPU's 0..1
depth. But there are three shadow lookups, and they disagree:

- `shaders/player_shader.wgsl:124-137` and `shaders/wiggle_shader.wgsl:150-162` use the GL
  version: `projCoords = projCoords * 0.5 + 0.5` on **xyz**. That remaps a depth that is
  already 0..1, so the comparison value is too large, and it doesn't flip y. WebGPU textures
  have their origin at the top-left, so the lookup samples a vertically mirrored location.
- `shaders/floor_shader.wgsl:152-172` does flip y (`flip_correction = vec2(0.5, -0.5)`, copied
  from the shadows example) but compares against `homogeneous_coords.z` without dividing by
  `w`. With the perspective light projection in `game_loop.rs:354`, that isn't the stored
  depth.

All three sample a depth texture with a non-filtering sampler and compare by hand. The
small_wgpu_core `shadows` example already had the WebGPU version: a `Comparison` sampler and
`textureSampleCompareLevel` (`examples/shadows/forward_pass.rs:79, 104-112`,
`examples/shadows/shader.wgsl:53-72`).

This finding comes from reading the code; I didn't build and run angry_wgpu_rust to see how
the player's shadowing looks.

**How this project handles it:** one function, `shadowCoords` in
`src/core/shaders/common.wgsl:85`, used by every shadow-receiving shader. It flips y and
leaves depth alone. `ShadowMap` owns a `LessEqual` comparison sampler (`src/core/shadow_map.zig:51`),
and shaders call `textureSampleCompareLevel`. CLAUDE.md lists "depth 0..1, texture origin
top-left" as a key rule because this is where GL habits cause the most trouble.

### 4. Formats, color space, mipmaps

- Every pipeline takes its color target from `surface.get_capabilities(&adapter).formats[0]`
  (`player_render.rs:76-77` and each other `*_render.rs`), not from `context.config.format`,
  the format the surface was actually configured with. On Metal `formats[0]` happens to be
  `Bgra8UnormSrgb`, the same one small_wgpu_core picks, so it matched by luck. This project
  stores `surface_format` once in `GpuContext` and every pipeline uses it.
- Every texture is uploaded as `Rgba8UnormSrgb` (`small_wgpu_core/src/material.rs:62`),
  including specular and normal maps, which hold data, not color, and should be linear.
  This project decides per use: `is_srgb` comes from how the glTF material uses the texture
  (`src/core/texture.zig`).
- `mip_level_count: 1` everywhere. WebGPU has no `glGenerateMipmap`, so the floor texture is
  minified with no mip chain and shimmers at a distance. This project generates mips with
  a render-pass generator (`src/core/mipmaps.zig`).
- A small one: the final-bones layout sets `min_binding_size` to `MAX_BONES * 16`
  (`small_wgpu_core/src/model_builder.rs:372`); a `mat4x4<f32>` is 64 bytes. It's a minimum,
  so it didn't fail, but validation couldn't catch a buffer that was too small.

### 5. Repetition and hand-kept agreements

Each of `player_render.rs`, `floor_render.rs`, `enemy_render.rs`, `sprite_render.rs`,
`bullet_render.rs`, and `shadow_material.rs` spells out a full `RenderPipelineDescriptor`,
often two, differing in a handful of fields. Group numbers, vertex locations, and uniform
struct layouts are written once in Rust and again in WGSL.

The naga_oil composer setup (`src/render/shader_loader.rs:5-54`) resolves imports by
repeatedly trying to add every `.wgsl` file until all dependencies succeed, printing an
error for each failed attempt. It works, but it is brute force.

**How this project handles it:** `PipelineConfig` plus `RenderState` (a 4-bit packed struct:
blend, cull, depth write, and so on) produce up to 16 `PipelineVariants` per shader at init
(`src/core/pipeline.zig`). Variants of one WGSL file differ by WGSL `override` constants. The
shared header plus `common.wgsl` replace an import system.

### Smaller points

- `surface.get_current_texture().expect(...)` (`main_render.rs:70`) panics on `Outdated` or
  `Lost`, which a resize can cause. `GpuContext.acquireFrame` handles each status and skips
  the frame instead.
- `World` holds its systems in `RefCell` / `Rc<RefCell<..>>` (`src/world.rs:73-79`) so the render
  code can borrow parts of it while holding `&mut World`. That is another sign of the borrow
  checker fights described next, paid for with runtime borrow checks.

## `forward_render_pass` and the render_pass lifetime

The code in question (`angry_wgpu_rust/src/render/main_render.rs:182-202`):

```rust
let mut render_pass = encoder.begin_render_pass(pass_description);

render_pass.set_pipeline(&self.floor_shader_pipelines.forward_pipeline);
render_pass = forward_render_floor(world, render_pass, floor, &self.shadow_map_material);

render_pass.set_pipeline(&self.player_shader_pipelines.forward_pipeline);
render_pass = forward_render_player(context, world, render_pass, player, &self.shadow_map_material);
...
```

with each helper shaped like:

```rust
pub fn forward_render_floor<'a>(world: &'a World, mut render_pass: RenderPass<'a>,
                                floor: &'a Floor, shadow_map: &'a ShadowMaterial) -> RenderPass<'a>
```

### Where the lifetime comes from

In wgpu 0.19 (`wgpu-0.19.3/src/lib.rs:920, 3525, 3545`):

```rust
pub struct RenderPass<'a> {
    id: ObjectId,
    data: Box<Data>,
    parent: &'a mut CommandEncoder,
}

impl<'a> RenderPass<'a> {
    pub fn set_bind_group(&mut self, index: u32, bind_group: &'a BindGroup, offsets: &[DynamicOffset]);
    pub fn set_pipeline(&mut self, pipeline: &'a RenderPipeline);
    pub fn set_vertex_buffer(&mut self, slot: u32, buffer_slice: BufferSlice<'a>);
}
```

The single lifetime `'a` means two things at once: how long the pass borrows the encoder, and
how long every pipeline, bind group, and buffer given to the pass must stay alive. The
compiler is proving that nothing you bind can be dropped while the pass might still refer to
it. That guarantee is real, and it is the reason for the lifetime.

### Why passing `&mut RenderPass` failed

I don't have the original error message, but a mock with the same signatures (no wgpu, just
the types above) shows the two usual ways to get stuck. All four variants were compiled with
rustc 1.79.

**(b) No lifetime on the resource:**

```rust
fn draw_floor(rp: &mut RenderPass, floor: &Floor) {
    rp.set_bind_group(1, &floor.bind_group);
}
```
```
error: lifetime may not live long enough
  |               has type `&mut RenderPass<'2>`
  |  let's call the lifetime of this reference `'1`
  |  argument requires that `'1` must outlive `'2`
```

That's correct: nothing says `floor` lives as long as the pass. The natural next step is to
put `'a` on everything:

**(a) One lifetime on everything, including the `&mut`:**

```rust
fn draw_floor<'a>(rp: &'a mut RenderPass<'a>, floor: &'a Floor) { ... }
fn draw_player<'a>(rp: &'a mut RenderPass<'a>, p: &'a Player) { ... }

draw_floor(&mut rp, floor);
draw_player(&mut rp, player);
```
```
error[E0499]: cannot borrow `rp` as mutable more than once at a time
   |     draw_floor(&mut rp, floor);
   |                ------- first mutable borrow occurs here
   |     draw_player(&mut rp, player);
   |                 ^^^^^^^ second mutable borrow occurs here
```

`&'a mut RenderPass<'a>` says "borrow the pass mutably **for the pass's entire lifetime**".
Behind a `&mut`, the `'a` inside `RenderPass<'a>` can't be shortened (a `&mut T` is invariant
in `T`), so the outer borrow has to last all of `'a` too. After the first call the pass stays
mutably borrowed until it dies, and no second call can compile. This is a well-known Rust
trap, sometimes written as "never write `&'a mut Thing<'a>`".

**(c) The fix: give the `&mut` borrow its own lifetime (or let it be elided):**

```rust
fn draw_floor<'a>(rp: &mut RenderPass<'a>, floor: &'a Floor) { ... }
fn draw_player<'a>(rp: &mut RenderPass<'a>, p: &'a Player) { ... }

draw_floor(&mut rp, floor);
draw_player(&mut rp, player);   // compiles
```

The resources must outlive the pass (`'a`), while the `&mut` borrow lasts only for the call.
Written out in full: `fn draw_floor<'a, 'b>(rp: &'b mut RenderPass<'a>, floor: &'a Floor)`.

**(d) The workaround that was used: move in, move out:**

```rust
fn draw_floor<'a>(mut rp: RenderPass<'a>, floor: &'a Floor) -> RenderPass<'a> { ...; rp }

rp = draw_floor(rp, floor);
rp = draw_player(rp, player);   // compiles
```

### Why returning the pass satisfied the compiler

Passing `rp` by value creates no borrow at all. Ownership moves into the function, and the
function moves it back out. With no `&mut` there is no borrow lifetime that could get stuck
at `'a`. The only lifetime left is the one in the type, `RenderPass<'a>`, and it's the same
going in and coming out, so the resource requirements are still checked exactly as before.

So the workaround was **sound**. It didn't weaken any check, and moving a `RenderPass`
copies a few machine words (an id, a `Box` pointer, a reference), which is essentially free.
It was just unidiomatic: `&mut RenderPass<'a>` with the elided outer lifetime is what the
compiler wanted, and the error message in (a) doesn't point to it. That really was wrestling
with the compiler, and the compiler's guidance didn't help.

### Postscript: wgpu removed the constraint

wgpu v22.0.0 (2024-07-18) removed it: "recording methods (e.g.
`wgpu::RenderPass::set_render_pipeline`) no longer impose a lifetime constraint to objects
passed to a pass". It also added `RenderPass::forget_lifetime` to drop the pass's borrow of
its encoder. wgpu now keeps recorded objects alive with internal reference counts, the same
way `webgpu.h` specifies it. On a current wgpu, `fn draw_floor(rp: &mut RenderPass, floor: &Floor)`
compiles as written. angry_wgpu_rust was on 0.19, the last generation with the strict
lifetime.

### The same thing in this project

`Frame` (`src/core/gpu_context.zig`, `Frame`) holds the encoder and the open pass, and draws
take `frame: *const Frame`: `player.draw(&frame, player_shader, player_transform)`. That's the
Zig equivalent of passing `&mut RenderPass`, but nothing checks it:

- Lifetime of bound objects: handled at runtime by `webgpu.h` reference counting. A recorded
  bind group stays alive inside wgpu-native even if our handle is released. Our own rule
  is `releaseGpuObjects()` / `cleanUp()` before an arena reset, never mid-frame.
- "Draws only inside a pass": `beginPass` asserts no pass is open, and `endPass` nulls
  `frame.pass`. A draw with no open pass would hand wgpu-native a null encoder, and nothing
  catches that at compile time.

The trade-off: Rust 0.19 turned a real class of bug (freeing a buffer the GPU is about to
read) into a compile error, at the cost of lifetime puzzles like the one above. Zig relies on
the API's reference counting and on keeping the frame structure simple and consistent. For
a single-threaded renderer with one frame shape, that has been enough.

## Side by side

| Topic | small_wgpu_core / angry_wgpu_rust | redfish_webgpu_zig |
|---|---|---|
| API | wgpu 0.19 crate (Rust API) | wgpu-native via translated `webgpu.h` (C API) |
| Pipelines | Created at init, one hand-written descriptor per entity per pass | Created at init; `PipelineConfig` × `RenderState` → `PipelineVariants`; WGSL `override` for variants |
| Bind groups | 7, by resource (one per texture); `max_bind_groups = 8` | 4, by frequency: frame / material / object / pass; default limit |
| Group numbers | Hard-coded in Rust and WGSL, differ per entity | Generated `wgsl_header` from `bindings.zig` |
| Per-draw data | Per-model buffers; `write_buffer` between draws (bug); dynamic offsets only in the shadows example | `uniform_ring` + dynamic offsets for every draw; one upload before submit |
| Per-frame vertex data | Dedicated instance buffers per system | `vertex_ring`, instance data at an offset |
| Instancing | Enemies (uniform array + `instance_index`), bullets, sprites | Bullets instanced; enemies drawn one by one (as redfish did) |
| Shadows | Comparison sampler in the example; manual compare and GL mapping in the game | One `shadowCoords`, comparison sampler, group 3 |
| Surface | sRGB chosen; pipelines use `formats[0]`; `expect` on acquire | sRGB chosen and stored; all surface statuses handled |
| Textures | All sRGB, no mipmaps | sRGB per use, render-pass mipmap generator |
| Shader composition | naga_oil with retry-until-it-resolves | Header + `common.wgsl` prepended |
| Lifetime safety | Compile-time (0.19 lifetimes), plus `RefCell` | Runtime refcounting plus convention and asserts |

Where the Rust version was ahead: angry_wgpu_rust draws all enemies with one instanced call
per mesh; this port draws each enemy separately, following the GL original. At angrybot's
enemy counts it doesn't matter, but it would be a straightforward change using a storage
buffer at group 2 indexed by `instance_index`.

## How close was it?

Close. The structure of a WebGPU renderer (pipelines at init, shared layouts, passes inside one
encoder, depth-only shadow pass, instancing) was in place and correct. What was missing is a
set of rules this project had to write down explicitly in CLAUDE.md and STYLE §9, because
neither the API nor either compiler enforces them:

1. Queue writes happen before the whole submission; per-draw values need their own memory
   (ring plus dynamic offsets).
2. Group bind groups by how often they change, and stay within 4.
3. Depth is 0..1 and textures start at the top-left; do the NDC-to-texture mapping in one
   shared function.
4. Keep the configured surface format in one place; decide sRGB per texture; generate mips
   yourself.
5. Keep one source of truth for anything Zig/Rust and WGSL must agree on.

Most of these were already solved somewhere in the Rust code, especially in the
small_wgpu_core `shadows` example, which was derived from wgpu's own sample. The main gap was
carrying those solutions into the game code consistently.

# Step 5 Design: Skinning and Baked Animation

## One shader for live and baked skinning

redfish had `pbr.vert` (joint matrices as a uniform array) and `pbr_anim_baked.vert`
(frames in a buffer texture, indexed by `frameId`, `numMeshes`, `animationOffset`). Both
reduce to "read joint matrices from an array at some offset", so one `pbr.wgsl` does both:

- **Group 2, binding 1** is a read-only storage buffer `joints: array<mat4x4f>`.
- **`DrawUniforms.joint_offset`** is where this draw's joints start in it.
- **Node matrices** (non-skinned meshes) fold into `DrawUniforms.model` on the CPU, from
  the live animator or from a CPU copy of the baked rows. The shader never reads them.

| Animator | Group 2 bind group | `joint_offset` | Node matrix source |
|---|---|---|---|
| none / unskinned | shared (`Bindings.object_bind_group`, 1-matrix dummy) | 0 | identity / animator |
| live | per instance: ring + its `MAX_JOINTS` joint buffer | 0 | `Animator.nodes` |
| baked | per animator: ring + the whole baked buffer | `animation_offset + frame × (meshes + joints) + meshes` | baked row, CPU copy |

`pbr_anim_baked.wgsl` from the plan is therefore not needed.

## Skinned primitives

As redfish: a skinned primitive's position is `Σ weight × joint[j] × position`, then
`draw.model` (the model transform only; the node transform is not applied, per glTF).
Normals and tangents use `mat3(joint)`, then the normal matrix of `draw.model`.

## Write rules

- A live instance's joint buffer is written with `wgpuQueueWriteBuffer` when it draws,
  once per frame. Distinct instances have distinct buffers, so that's safe. Drawing the
  **same** `ModelInstance` twice in one frame with different poses would break the
  "no rewriting between draws" rule; give each posed copy its own instance.
- Baked data is uploaded once at bake time and never rewritten; frames are just offsets.

## Files

- `storage_buffer.zig` replaces `texture_buffer.zig`: create, write, release.
- `skinning.zig`: `JointBuffer` (live joints + its group 2 bind group).
- `baked_animator.zig`: bakes as redfish did, keeps a CPU copy of the rows for node
  matrices, uploads the rows to one storage buffer with its own group 2 bind group.

## Found while building

- **Bound texture across PBR draws.** Step 3b's `texture.bind(frame)` set group 1 once;
  scene_tree's model draw (PBR, its own group 1) sat between that and the shapes, which then
  drew with an incompatible group 1 (validation error at submit). `bind` now records the
  texture on `GpuContext`, and `Shape.draw` sets group 1 from it on every `.texture` draw.
- **Custom textures** map GL uniform names to material slots, so any shader on the PBR
  material layout can read them (animation_example's `player.wgsl` reads the base color and
  metallic-roughness slots as diffuse and specular).
- **Skinning helpers** (`skinMatrix`, `jointMatrix`) live in `common.wgsl`; joint reads are
  clamped to the array length.

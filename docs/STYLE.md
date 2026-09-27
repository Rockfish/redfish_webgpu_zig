# redfish_webgpu_zig Style Guide

Status: **DRAFT** — being tuned with John. Items marked **(open)** are proposals not yet settled.
Settled so far: cleanup method names, bind group slots, shared shader constants.

This guide is for anyone (human or agent) writing code in this project. When the
guide and existing code disagree, the guide wins; fix the code when you touch it.

## 1. Priorities

In order:

1. **Correct.** Establish the right pattern up front, even when it differs from redfish_gl_zig.
2. **Readable after months away.** A reader should see what a function does without
   holding the whole file in their head.
3. **Parallel to redfish_gl_zig.** Same directories, files, type names, and call shapes,
   so the two repos can be opened side by side. Only the graphics API changes.
4. **Short.** Least code that stays clear. Never at the cost of 1 or 2.

`src/` is where the bar is highest. Apps in `examples/` and `games/` follow the same rules
for new code; existing large `run()` functions are refactored when there's a reason to touch them.

## 2. File Layout

Top down, in this order:

1. `std` import, then dependency imports, then project module imports
2. Type and function aliases, grouped by source (`const Vec3 = math.Vec3;`)
3. `const log = std.log.scoped(.name);`
4. Module-level constants
5. Types (structs, enums, unions)
6. The main public function(s) of the file
7. Support functions, **callers before callees**, in the order they are first called

Types are imported at the top of the file, never inline in a parameter list.

```zig
const std = @import("std");
const zgpu = @import("zgpu");
const math = @import("math");

const wgpu = zgpu.wgpu;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.mesh);

const MAX_VERTEX_BUFFERS = 7;
```

### Inside a struct

1. Fields
2. Struct-level constants (`const Self = @This();` if used)
3. Lifecycle, in the order it happens: `init` / `create`, then the main operations
   (`update`, `draw`), then `releaseGpuObjects` / `cleanUp` / `deinit`
4. Private helpers, callers before callees

A reader scrolling down meets things in the order they execute.

## 3. Functions

- **One clear purpose.** If the name needs "and", it's probably two functions.
- **Short.** Aim for a screen (~40 lines). Longer is fine when it's a flat sequence
  of steps, e.g. filling out a pipeline descriptor.
- **Blank lines separate steps.** Each paragraph of code does one thing; a one-line
  comment above a paragraph is welcome when the step isn't obvious from the code.
- **Name temporaries for meaning.** A local that names an intermediate result is
  better than a nested expression.
- **Hoist repeated access.** If `self.context.alloc` or `gctx.device` appears several
  times, bind it to a local at the top.
- **Top function reads like an outline.** A high-level function should mostly be calls
  to well-named helpers.

```zig
pub fn draw(self: *Model, pass: wgpu.RenderPassEncoder, frame: *const FrameData) void {
    const gctx = frame.gctx;

    self.writeJointMatrices(gctx);
    pass.setBindGroup(BindGroup.object, self.object_bind_group, &.{});

    for (self.draw_items) |item| {
        const draw_uniforms = self.allocateDrawUniforms(gctx, item);
        drawPrimitive(pass, item, draw_uniforms.offset);
    }
}
```

## 4. Naming

- Zig conventions: `TitleCase` types, `camelCase` functions, `snake_case` variables and fields.
- Module-level constants in `SCREAMING_SNAKE_CASE` (`MAX_JOINTS`, `SCR_WIDTH`), as in redfish.
- Spell things out: `vertex_buffer`, `bind_group_layout`, `joint_matrices`. Short names
  only for tight scopes (`i`, loop captures) and established math (`x`, `v`, `m`).
- Booleans read as questions: `is_transparent`, `has_skin`, `use_light`.
- Name GPU objects for their role, not their type: `camera_buffer`, not `buffer1`.
- A name from redfish_gl_zig is kept unless it names GL (`gl_texture_id` → `texture_handle`,
  `deleteGlObjects` → `releaseGpuObjects`).

## 5. Control Flow

- `if` / `else` always use braces, even for one line.
- Prefer early return over deep nesting.
- Unwrap optionals with `if (x) |value|` or `orelse`; use `.?` only where null is a bug.
- `switch` over enums and tagged unions; no `else` branch unless it's truly a default,
  so the compiler flags new cases.

## 6. Comments and Documentation

- Explain **why**, and conventions the code can't show (matrix layout, binding slots,
  coordinate systems, units). Don't narrate what the code already says.
- Public types and non-obvious public functions get a `///` doc comment.
- Every uniform/storage struct names the WGSL file(s) it mirrors.
- **No commented-out code.** Delete it; git is the archive.
- `TODO:` comments are allowed but should say what and why.

## 7. Errors and Logging

- Propagate with `try`; return errors for anything a caller could react to
  (missing file, bad asset, shader compile failure).
- `@panic` / `unreachable` only for programmer errors (violated invariants).
- Use scoped logs (`log.debug`, `log.err`), not `std.debug.print`, in `src/`.
- Every print/log call passes an args tuple, even with no args: `log.info("ready", .{});`

## 8. Memory and Resource Ownership

Carried over unchanged from redfish_gl_zig (`docs/review/allocator_conventions_review.md` there):

- Owners (World, scenes, scopes) hold `Arenas` and are the only ones that reset them.
  They pass a `Context { alloc, temp_alloc, io }` down.
- Components take a `Context` or `Allocator`, never own arenas, never store an allocator
  for cleanup, and have no memory `deinit`.
- `temp_alloc` memory must not outlive the call that received it.
- **GPU resources** are the non-memory resources: leaves release them in
  `releaseGpuObjects()`, aggregates in `cleanUp()`, called once, **before** the owning
  arena resets.
- One arena per independently unloadable unit; ping-pong when generations overlap.

## 9. Graphics (WebGPU) Patterns

Correctness rules. They exist because WebGPU works differently from GL.

- **Raw `wgpu.*` / `zgpu.*` calls live in `src/core`.** Apps work through core types
  (`Shader`, `Mesh`, `Model`, `Shape`, `RenderContext`). An app needing something new
  from the GPU adds it to core.
- **Bind group slots are fixed project-wide** and defined once in Zig, with the same
  numbers in WGSL:
  - group 0: frame (camera, lights, time)
  - group 1: material (textures, sampler, material factors)
  - group 2: object / draw (model transform, joint matrices, per-draw data)
  - group 3: pass-specific (shadow map, etc.)
- **Uniform and storage structs are `extern struct`** with explicit padding fields
  and a `comptime` size check, so the Zig and WGSL layouts can't drift quietly.
  WGSL field names match the Zig field names exactly.

  ```zig
  /// Mirrors `FrameUniforms` in shaders/common.wgsl (group 0, binding 0).
  pub const FrameUniforms = extern struct {
      mat_projection: Mat4,
      mat_view: Mat4,
      view_position: Vec3,
      time: f32, // fills vec3's 16-byte slot
  };

  comptime {
      std.debug.assert(@sizeOf(FrameUniforms) == 144);
  }
  ```

- **Never write the same buffer between draws expecting different values per draw.**
  Queue writes all land before the frame runs; the last write wins. Per-draw data
  goes in its own slice (`gctx.uniformsAllocate` + dynamic offset) or in a storage
  array indexed per draw or instance.
- **Pipelines and bind group layouts are created at init, never per frame.** Render
  state (blend, depth write, cull) is part of the pipeline, so each combination is
  a named pipeline, not a runtime toggle.
- **Constants shared with shaders** (`MAX_JOINTS`, `MAX_POINT_LIGHTS`, ...) are defined
  once in Zig. The shader loader generates a small WGSL header from them
  (`const MAX_JOINTS: u32 = 100u;`) and prepends it, along with `common.wgsl`, to every
  shader. WGSL files never hard-code these values.
- **Depth is 0..1** (WebGPU clip space). Use the `*Zo` projection functions in `math`.
- **Texture origin is top-left.** No default V-flip for GL's sake.
- **Color space:** color textures (base color, emissive) are `*-srgb` formats; data
  textures (normal, metallic-roughness, occlusion) are linear. The surface is sRGB;
  shaders output linear color and do no manual gamma.

## 10. WGSL

- One file per shader module, in the app's `shaders/` directory or `src/core/shaders/`
  for shared ones. Loaded from file at runtime, as redfish does.
- Shared structs and bindings live in `common.wgsl`, prepended as text. No module system.
- Order within a file: structs, bindings (grouped by group number), vertex entry,
  fragment entry, helper functions.
- Entry points are named `vs_main` / `fs_main` (plus `vs_shadow` etc. when a module
  has several).
- Same readability rules as Zig: named temporaries, short helper functions, comments
  explaining the math.

## 11. Formatting and Tooling

- Run `zig fmt` on every Zig file you edit. Only on `.zig` files.
- Never `zig fmt` or edit vendored/fetched dependency code.
- For multi-line `{}` lists, put a comma after the last item so `zig fmt` folds it one per line.
- Zig lazy analysis compiles unreferenced functions without checking them. "It builds"
  proves nothing about uncalled code: call new public functions from somewhere, or
  cover them with a `test`.

## 12. Git

- Commit messages describe what changed and why. **No signatures or attribution lines.**
- One logical change per commit; a port step from the plan is a good unit.

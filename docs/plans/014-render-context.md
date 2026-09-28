# RenderContext and Draw Call Refactor — Plan 014

> Imported from redfish_gl_zig on 2026-09-28. **In this repo:** Implemented in redfish_gl_zig; ported as `RenderContext.frameUniforms` (Steps 3a, 6).
> File and API references in the body are to redfish_gl_zig (OpenGL) unless noted.

## Status: Implemented

## Motivation

Every drawable object in the bullets example takes `(projection: *const Mat4, view: *const Mat4)` and internally sets 2-3 matrix uniforms per draw call. This has several problems:

1. **Redundant GL calls** — projection rarely changes, yet every object sets it every frame
2. **No `viewPos`** — specular highlights need the camera world position, but there's no clean way to pass it without adding a third parameter to every `draw()` signature
3. **Signature fragility** — adding any new per-frame data (time, view position, render flags) means changing every object's `draw()` function
4. **Inconsistency** — angrybot uses `projectionView` (combined), bullets uses separate `projection` + `view`; `Camera` already supports both via `getProjectionView()`

## Design

### `RenderContext` struct

A per-frame value computed once from the camera, passed to all draw calls. Lives in `../../src/core/render_context.zig` alongside future `RenderPass`.

```zig
pub const RenderContext = struct {
    projection: Mat4,
    projection_view: Mat4,
    view: Mat4,
    view_pos: Vec3,
    time: f32 = 0.0,
};
```

**Fields:**
- `projection` — kept for core engine APIs (Lines, Plane, Skybox) that still use separate `matProjection`/`matView` uniforms
- `projection_view` — combined matrix, one uniform call instead of two; saves a per-vertex multiply on the GPU
- `view` — kept separate because some effects need it (skybox strips translation, fog uses view depth, billboard facing)
- `view_pos` — camera world position for specular highlights, fog distance, fresnel
- `time` — total elapsed time for animated shader effects (water, wind, pulsing); defaulted to 0 so callers that don't need it can ignore it

**Not included:**
- `model` matrix — per-object, stays on each object
- Lights — already handled by `SceneLights.apply()`, set at scene level
- Render pass info — separate concept (see RenderPass section below)

### Camera integration

Both `Camera` and `CameraGimbal` have `getRenderContext(time)`:

```zig
pub fn getRenderContext(self: *Self, time: f32) RenderContext {
    const projection = self.getProjection();
    const view = self.getView();
    return .{
        .projection = projection,
        .projection_view = projection.mulMat4(&view),
        .view = view,
        .view_pos = self.getPosition(), // getCameraPosition() for gimbal
        .time = time,
    };
}
```

One call per frame, all objects use the result.

### Shader migration

Shaders that used separate `matProjection` and `matView` now use a single `projectionView` uniform:

```glsl
// Before
uniform mat4 matProjection;
uniform mat4 matView;
gl_Position = matProjection * matView * matModel * vec4(inPosition, 1.0);

// After
uniform mat4 projectionView;
gl_Position = projectionView * matModel * vec4(inPosition, 1.0);
```

**Exception:** `lines.vert` and `skybox.vert` keep `matProjection`/`matView` because they are used by core engine APIs (`Lines.draw`, `Skybox.draw`) that still take separate matrices. The bullets scene objects pass `ctx.projection` and `ctx.view` to these core APIs.

### Draw call pattern

All objects changed from:
```zig
pub fn draw(self: *Self, projection: *const Mat4, view: *const Mat4) void
```
to:
```zig
pub fn draw(self: *Self, ctx: RenderContext) void
```

Inside each draw, objects using migrated shaders set:
```zig
self.shader.setMat4(uniforms.Projection_View, &ctx.projection_view);
```

Objects calling core APIs (Lines, Plane, Skybox) pass individual matrices:
```zig
self.lines.draw(&segments, &ctx.projection, &ctx.view);
```

### Scene dispatch

`Scene.draw()` now takes `time: f32` and threads it through the dispatch vtable to scene implementations. The scene implementation (e.g. `debug_scene`) computes `RenderContext` once from the camera and passes it to all objects:

```zig
pub fn draw(self: *Self, time: f32) void {
    var camera = self.getSceneCamera().getCamera();
    const ctx = camera.getRenderContext(time);
    self.cube.draw(ctx);
    self.skybox.draw(ctx);
    ...
}
```

## Changes Implemented

### Core engine
1. **`../../src/core/render_context.zig`** (NEW) — `RenderContext` struct definition
2. **`src/core/root.zig`** — export `render` module and `RenderContext`
3. **`src/core/camera.zig`** — add `getRenderContext(time)` method
4. **`src/core/camera_gimbal.zig`** — add `getRenderContext(time)` method

### Shaders migrated to `projectionView`
5. **`examples/bullets/shaders/basic_texture.vert`**
6. **`examples/bullets/shaders/basic_model.vert`**
7. **`examples/bullets/shaders/instanced_quats.vert`**
8. **`games/level_01/shaders/basic_model.vert`**
9. **`games/level_01/shaders/animated_pbr.vert`**
10. **`games/level_01/shaders/player_shader.vert`**
11. **`examples/demo_app/shaders/pbr.vert`**
12. **`examples/demo_app/shaders/basic_model.vert`**
13. **`examples/demo_app/shaders/player_shader.vert`**

### Shaders unchanged (used by core APIs)
- **`examples/bullets/shaders/lines.vert`** — core `Lines.draw` sets `matProjection`/`matView`
- **`examples/bullets/shaders/skybox.vert`** — core `Skybox.draw` + skybox strips view translation

### Bullets scene objects (draw takes `RenderContext`)
14. **`examples/bullets/scene/cube.zig`**
15. **`examples/bullets/scene/floor.zig`** — bypasses `Plane.draw`, sets uniforms directly
16. **`examples/bullets/scene/spacesuit.zig`**
17. **`examples/bullets/scene/toon_soldier.zig`**
18. **`examples/bullets/scene/skyboxes.zig`** — passes `ctx.projection` + `ctx.view.removeTranslation()`
19. **`examples/bullets/scene/axis_lines.zig`** — passes `ctx.projection`/`ctx.view` to `Lines.draw`
20. **`examples/bullets/scene/grid.zig`**
21. **`examples/bullets/projectiles/turret.zig`**
22. **`examples/bullets/projectiles/bullet_system.zig`**
23. **`examples/bullets/projectiles/bullet_simple.zig`**
24. **`examples/bullets/scene_object.zig`** — vtable dispatch updated

### Scene dispatch
25. **`examples/bullets/scene.zig`** — `draw(time: f32)` dispatch
26. **`examples/bullets/debug_scene.zig`** — computes `RenderContext` once per frame
27. **`examples/bullets/run_app.zig`** — passes `input.total_time` to `scene.draw()`

### level_01 and demo_app
28. **`games/level_01/run_app.zig`** — computes `RenderContext`, sets `projectionView` uniform
29. **`examples/demo_app/run_app.zig`** — computes `RenderContext`, sets `projectionView` uniform

### Not touched
- `games/angrybot/**` — uses its own rendering pattern, no changes
- Core `Lines.draw` / `Plane.draw` / `Skybox.draw` signatures — still take separate matrices

## Design Decision: `projection` field

The original plan excluded `projection` as a separate field. During implementation, it became clear that core engine APIs (`Lines.draw`, `Plane.draw`) and the skybox (which strips view translation before combining with projection) need projection separately. Rather than computing matrix inverse or changing core APIs, `projection` was added to `RenderContext`. The cost is one extra cached `Mat4` — negligible since `Camera.getProjection()` is already cached.

## Future: Core API Migration

When `Lines.draw` and `Plane.draw` are migrated to accept `RenderContext` (and their shaders switch to `projectionView`), the `projection` field can be removed from `RenderContext`. This is a separate change that requires updating all consumers of these core APIs across all examples and games.

## RenderPass Model (Future)

The `RenderContext` handles per-frame data that every object needs. But some rendering scenarios require **multi-pass rendering** where the same scene is drawn multiple times with different configurations. This is a separate concern from `RenderContext`.

### The Problem

Angrybot currently handles shadows and blur with large blocks of inline GL code in the main run loop:

1. Switch to shadow framebuffer, set depth-only mode, draw everything with a depth shader
2. Switch back to the main framebuffer, draw everything with the color shader, bind the shadow map
3. Draw the scene again into a blur framebuffer for glow effects
4. Composite the blur texture onto the final output

This works but scatters rendering logic across the game loop, making it hard to maintain or extend.

### The Concept

A `RenderPass` would encapsulate "how to draw" as a separate configuration from "what to draw":

- **ShadowPass** — binds shadow framebuffer, uses depth-only shader, sets `matLightSpace` uniform, disables color writes
- **ColorPass** — binds main framebuffer, uses each object's normal shader, binds shadow map as a texture input
- **BlurPass** — binds glow framebuffer, renders only emissive/bright fragments
- **PostProcessPass** — full-screen quad compositing blur, tone mapping, etc.

Each pass would:
1. Configure the GL state (framebuffer, viewport, clear, depth settings)
2. Optionally override or supplement shader uniforms (e.g. `matLightSpace` for shadow pass, `shadowMap` sampler for color pass)
3. Let the scene draw its objects normally — objects don't know which pass they're in

The scene draw loop becomes:
```
for each pass:
    pass.begin()           // bind FBO, set GL state
    pass.configure(shader) // set pass-specific uniforms
    scene.draw(ctx)        // same draw calls every time
    pass.end()             // unbind, restore state
```

### Relationship to RenderContext

`RenderContext` and `RenderPass` operate at different levels:

- **RenderContext** = "from whose perspective" — camera matrices, position, time. Changes per frame but is the same for all objects within a frame.
- **RenderPass** = "for what purpose" — shadow depth, color, post-process. Changes per pass but is the same for all objects within a pass.

Some passes modify the context (shadow pass uses a light-space camera instead of the player camera), but most passes share the same `RenderContext` and just change GL state and shader bindings around it.

### When to Build It

Not yet. The current priority is getting lighting working in bullets. `RenderPass` becomes relevant when shadows land in bullets, at which point the angrybot shadow code serves as the reference implementation to extract a clean pattern from. Both `RenderContext` and `RenderPass` will live in `../../src/core/render_context.zig`.

## Verification

1. `zig build check` — no compilation errors across all targets ✅
2. `zig build bullets` — compiles without errors ✅
3. `zig build level_01` — compiles without errors ✅

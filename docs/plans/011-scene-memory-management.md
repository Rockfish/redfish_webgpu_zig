# Plan 011: Scene Memory Management

> Imported from redfish_gl_zig on 2026-09-28. **In this repo:** Implemented: `src/core/arenas.zig` and `Context`; conventions in docs/STYLE.md section 8.
> File and API references in the body are to redfish_gl_zig (OpenGL) unless noted.

## Overview

Tiered arena allocation strategy for managing CPU memory and GPU resources across scene lifetimes. Enables clean scene switching without per-object deinit complexity.

## Tiered Arena Architecture

### App Arena
- Lives for the entire application lifetime
- Holds shared resources used across all scenes: common shaders, shared textures, fonts, audio assets
- Allocated once at startup, freed at application exit
- Objects here are never duplicated per-scene

### Scene Arena
- Allocated when a scene is created, freed entirely on scene transition
- Holds all scene-specific objects: geometry, scene-local shaders, scene-local textures, cameras, game objects
- Scene switching becomes: clean up GPU resources, free scene arena, create new scene arena, init new scene
- No per-object deinit needed for CPU memory -- one `arena.deinit()` handles everything

### Frame Arena (future)
- Reset every frame, never freed until shutdown
- Useful for per-frame scratch allocations: temporary strings, debug UI data, intermediate computation buffers
- Very fast allocation (bump pointer), zero deallocation cost (just reset the pointer)

## GPU Resource Management

Freeing a scene arena releases CPU memory but does not clean up OpenGL objects (VAOs, VBOs, textures, shader programs). These require explicit `glDelete*` calls.

### GpuResource Registry

Each scene maintains a list of GPU handles registered at creation time:

```zig
const GpuResource = union(enum) {
    vao: gl.Uint,
    vbo: gl.Uint,
    texture: gl.Uint,
    shader_program: gl.Uint,
};

/// Tracked per scene
gpu_resources: std.ArrayList(GpuResource),
```

When any scene object creates an OpenGL resource, it registers the handle with the scene's resource list. Objects do not need their own deinit methods for this -- they just register at creation time.

### Cleanup on Scene Transition

```
1. Iterate gpu_resources, call the appropriate glDelete* for each handle:
   - .vao        -> glDeleteVertexArrays(1, &handle)
   - .vbo        -> glDeleteBuffers(1, &handle)
   - .texture    -> glDeleteTextures(1, &handle)
   - .shader_program -> glDeleteProgram(handle)
2. Free the scene arena (all CPU memory released in one call)
3. Create new scene arena
4. Init new scene using the new arena
```

### Shared vs Scene-Local Resources

Some resources (e.g., a common PBR shader) may be used across multiple scenes. These should be allocated from the app arena and NOT registered in any scene's GPU resource list. The rule:

- **App arena resources**: allocated once, cleaned up at app exit only
- **Scene arena resources**: registered in the scene's GPU resource list, cleaned up on scene transition

Objects that reference app-level resources just hold pointers to them. The app-level resources outlive all scenes.

## Scene Switching Flow

```
switchScene(new_scene_id):
    // Tear down current scene
    for current_scene.gpu_resources |resource|:
        deleteGpuResource(resource)
    scene_arena.deinit()

    // Stand up new scene
    scene_arena = ArenaAllocator.init(backing_allocator)
    current_scene = new_scene_id.init(scene_arena.allocator(), app_resources)
```

## Implementation Order

1. Introduce scene arena -- pass a scene-specific arena allocator into scene init
2. Add GpuResource list to scene, register handles at creation time
3. Implement scene teardown (GPU cleanup + arena free)
4. Implement scene switching (teardown old, init new)
5. Add frame arena if per-frame scratch allocations become needed
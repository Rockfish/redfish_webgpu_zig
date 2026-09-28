# Plan 005: Basic Scene Management

> Imported from redfish_gl_zig on 2026-09-28. **In this repo:** Planned. See the 2026-09-28 notes at the end.
> File and API references in the body are to redfish_gl_zig (OpenGL) unless noted.

**Status**: 📋 Planned  
**Priority**: Low  
**Started**: TBD  
**Target**: 1-2 weeks  

## Overview

Implement essential scene management features to support multiple models, basic transform hierarchy, and simple scene composition. This focused plan enables loading and positioning multiple objects in 3D space with basic optimization.

## Prerequisites

- [x] Plan 001 (GLB Support) completed
- [ ] Plan 002 (Demo Application) completed
- [ ] Plan 003 (Basic PBR Shaders) completed
- [ ] Plan 004 (Basic Animation System) completed or in progress
- [ ] Multiple models loading reliably

## Phase 1: Multi-Model Support

### Basic Scene Structure
- [ ] Create simple scene container for multiple models
- [ ] Implement model positioning and transforms
- [ ] Add basic parent-child relationships
- [ ] Support loading multiple models simultaneously
- [ ] Create scene update and render loop

### Transform Management
- [ ] Implement local vs world transform calculations
- [ ] Add transform hierarchy support
- [ ] Create transform matrix management
- [ ] Support model positioning, rotation, and scaling
- [ ] Add transform animation support for scene objects

## Phase 2: Basic Optimization

### Simple Culling
- [ ] Implement basic frustum culling
- [ ] Add distance-based model culling
- [ ] Create simple bounding box calculations
- [ ] Support culling for off-screen objects
- [ ] Add basic performance monitoring

### Scene Composition
- [ ] Create simple scene building API
- [ ] Add support for environment models (like Sponza)
- [ ] Support multiple character models in scene
- [ ] Implement basic scene validation
- [ ] Add scene statistics and debugging info

## Success Criteria

- [ ] Multiple models can be loaded and positioned in 3D space
- [ ] Basic transform hierarchy works correctly
- [ ] Simple frustum culling improves performance
- [ ] Scene composition API is easy to use
- [ ] Demo app can show multiple models together
- [ ] System supports both static and animated models in same scene

## Testing Scenarios

### Multi-Model Scenes
- Load multiple models from assets_list.zig into single scene
- Test basic transform hierarchies
- Verify culling with models outside camera view

### Mixed Content Scenes
- Static environment model (like architectural scenes)
- Multiple character models with animations
- Combination of simple and complex models

### Performance Validation
- Tens of simple objects (Box.glb instances)
- Basic culling effectiveness
- Memory usage with multiple models

## Scope Limitations

**Not Included in This Plan** (moved to backlog):
- Advanced spatial optimization (octrees, etc.)
- Complex scene serialization formats
- Dynamic batching and instancing
- Scene streaming and memory management
- Advanced culling systems
- Scene editing tools
- Multi-scene support

## Notes & Decisions

**Focus**: This plan focuses on essential multi-model support that enables basic scene composition. Advanced optimization and tooling features are deferred to later iterations.

## Related Files

- `src/core/scene.zig` - Basic scene management (to be created)
- `src/core/transform.zig` - Enhanced transform system
- `examples/demo_app/scene_demo.zig` - Scene composition demo

---

## Notes (2026-09-28)

Discussion while importing the plans:

- **Union vs. dispatch.** redfish's `examples/scene_tree/nodes_union.zig` (not ported) is
  a closed set: node kinds are cases of a `union(enum)`, `switch` handles each, the
  compiler checks every case, and the set is visible in one place. The dispatch version
  (scene_tree, level_01, bullets' `Scene` and `SceneCamera`) is open: any type with
  `draw` / `update` becomes a node without touching core.
- **Dispatch weaknesses.** The same `Dispatch` struct is copied in four places (a small
  generic helper in core could replace them); `hasMethod` turns a missing or misspelled
  method into a silent no-op; the `state: *anyopaque` argument isn't checked against the
  type captured at init.
- **Why Godot has many node types.** They give the editor a schema: inspector properties,
  signals and virtual functions (`_ready`, `_process`) as hook points, and a structure to
  save and load. Without an editor, a game here needs a transform hierarchy, update /
  draw order, ownership that fits the arenas, and bounds for picking, not a node taxonomy.
- **Inspector without a class hierarchy.** Zig's `@typeInfo` can walk any struct's fields
  (as `src/core/uniform_debug.zig` does), so a zgui panel could show and edit any object.
- **Suggested direction** when this plan resumes: a core transform hierarchy plus a shared
  dispatch helper, and possibly the reflection-based inspector; hold a full scene system
  until a second game needs it.

# Plan 004: Basic Animation System

> Imported from redfish_gl_zig on 2026-09-28. **In this repo:** Open. Partly superseded by plan 006 (weighted blending) and plan 012 (animation FSM); review the remaining tasks before resuming.
> File and API references in the body are to redfish_gl_zig (OpenGL) unless noted.

**Status**: 🔄 Active - Phase 1 (Core Foundation Complete)  
**Priority**: Medium  
**Started**: 2025-07-09  
**Target**: 1-2 weeks  

## Overview

Implement essential animation features including clip playback, simple blending, and basic state management. This focused plan enables characters to animate and respond to input with smooth transitions, building on the PBR rendering foundation.

## Prerequisites

- [x] Plan 001 (GLB Support) completed
- [x] Plan 002 (Demo Application) completed
- [x] Plan 003 (Basic PBR Shaders) - Phase 2 completed with skeletal animation support
- [x] Character models loading and rendering correctly with animations

## Phase 1: Animation Clip System ✅ FOUNDATION COMPLETE

### Core Animation Playback ✅ IMPLEMENTED
- [x] **Complete glTF animation system** with keyframe interpolation (`animator.zig:97-135`)
- [x] **Time-based animation state management** (`animator.zig:48-89`)
- [x] **Multiple interpolation modes** (linear, step, cubic spline) (`animator.zig:354-384`)
- [x] **Animation clip playback** with `playClip()` and `playAnimationById()` (`animator.zig:234-282`)
- [x] **Loop modes support** (Once, Count, Forever) (`animator.zig:24-28`, `animator.zig:68-88`)
- [ ] Create animation speed control
- [ ] Add animation pause/resume functionality

### Animation Blending
- [ ] Implement linear interpolation between animation clips
- [ ] Add cross-fade transitions with configurable duration
- [ ] Create simple blend weight management
- [ ] Support simultaneous animation playback (upper/lower body)

## Phase 2: Basic State Management

### Simple State Machine
- [ ] Create basic animation state system (idle, walk, run)
- [ ] Implement state transition logic
- [ ] Add input-driven state changes
- [ ] Create smooth transitions between states
- [ ] Support state-specific animation settings

### Character Controller Integration
- [ ] Connect keyboard input to animation states
- [ ] Add movement speed affecting animation playback
- [ ] Implement directional movement awareness
- [ ] Create responsive state changes
- [ ] Add basic turn-in-place support

## Success Criteria

- [ ] Characters can play multiple animation clips smoothly
- [ ] Transitions between animations look natural and responsive
- [ ] Input controls feel immediate and intuitive
- [ ] Animation system works reliably with different character models
- [ ] Demo app showcases character movement and animation
- [ ] System is simple to use and extend for new animations

## Testing Models for Animation Features

### Character Animation
- `Fox/glTF-Binary/Fox.glb` - Complex character with multiple animations
- `CesiumMan/glTF-Binary/CesiumMan.glb` - Standard rigged character
- `BoxAnimated/glTF-Binary/BoxAnimated.glb` - Simple animated test case

### Animation Basics
- `AnimatedCube/glTF/AnimatedCube.gltf` - Simple animation testing
- `InterpolationTest/glTF-Binary/InterpolationTest.glb` - Interpolation validation
- `SimpleSkin/glTF/SimpleSkin.gltf` - Basic skinning test

### Skeletal Systems  
- `RiggedSimple/glTF-Binary/RiggedSimple.glb` - Simple rigging reference
- `RiggedFigure/glTF-Binary/RiggedFigure.glb` - Basic character rigging

## Scope Limitations

**Not Included in This Plan** (moved to backlog):
- Complex state machine hierarchies
- Animation events and gameplay integration
- 2D blend spaces and complex blending
- Animation LOD and performance optimization
- Root motion support
- Advanced character controller features

## Notes & Decisions

**Focus**: This plan focuses on essential animation functionality that enables basic character movement and state changes. Advanced features like complex blending and state hierarchies are deferred to later iterations.

## Related Files

- `src/core/animator.zig` - Enhanced animation system ✅ (foundation complete)
- `src/core/animation_state.zig` - Basic state management (to be created)
- `examples/demo_app/character_controller.zig` - Demo character controller (to be created)
# Plan 006: Multi-Animation Support

> Imported from redfish_gl_zig on 2026-09-28. **In this repo:** Phase 1 completed in redfish_gl_zig and carried over (`WeightedAnimation`, `Model.updateWeightedAnimations`).
> File and API references in the body are to redfish_gl_zig (OpenGL) unless noted.

**Status**: ✅ COMPLETED (Phase 1)  
**Priority**: High  
**Start Date**: 2025-07-19  
**Completed**: 2025-07-19  
**Target**: Fix InterpolationTest model animation and enable multi-animation scenarios

## Problem Statement

The current animation system only supports playing one animation at a time via `current_animation: ?GltfAnimationState`. This breaks models like InterpolationTest.gltf which has 9 separate animations that need to run simultaneously on different nodes to demonstrate different interpolation methods (STEP, LINEAR, CUBICSPLINE).

## Current Architecture Limitations

1. **Single Animation Only**: `Animator.current_animation` field limits to one animation
2. **No Conflict Detection**: No handling of multiple animations targeting same nodes
3. **Missing Multi-Animation API**: No way to play multiple animations simultaneously

## Solution Overview

### Phase 1: Basic Multi-Animation Support (Current Focus)

**Core Changes to `src/core/animator.zig`:**

1. **Data Structure**:
   ```zig
   // Replace single animation with list
   // OLD: current_animation: ?GltfAnimationState
   // NEW: active_animations: ArrayList(GltfAnimationState)
   ```

2. **Backward Compatibility**:
   - Keep all existing methods working unchanged
   - Treat them as "clear all, play one" operations
   - No breaking changes to existing API

3. **New Multi-Animation Methods**:
   ```zig
   pub fn playAllAnimations(self: *Self) !void
   pub fn playAnimations(self: *Self, animation_indices: []const u32) !void
   ```

4. **Conflict Resolution**:
   - **Strategy**: "Last animation wins" for conflicting nodes
   - **Detection**: Warning messages for conflicts
   - **Tracking**: `animated_nodes[]` boolean array

### Phase 2: Advanced Features (Future)

1. Animation blending for conflicting nodes
2. Animation layers/priorities  
3. Selective node targeting
4. Animation groups/sets

## Implementation Plan

### Step 1: Data Structure Changes

**File**: `src/core/animator.zig`

```zig
pub const Animator = struct {
    // ... existing fields ...
    
    // CHANGE: Replace single animation with list
    active_animations: ArrayList(GltfAnimationState),
    // Remove: current_animation: ?GltfAnimationState,
    
    // ... rest unchanged ...
};
```

### Step 2: Constructor Updates

**In `Animator.init()`:**
```zig
animator.* = Animator{
    // ... existing fields ...
    .active_animations = ArrayList(GltfAnimationState).init(allocator),
    // ... rest unchanged ...
};
```

### Step 3: Backward Compatibility

**Modify existing methods:**

```zig
pub fn playClip(self: *Self, clip: AnimationClip) !void {
    // Clear all animations, play just this one
    self.active_animations.clearRetainingCapacity();
    const anim_state = GltfAnimationState.init(/*...*/);
    try self.active_animations.append(anim_state);
}

pub fn playAnimationById(self: *Self, animation_index: u32) !void {
    // Same pattern - clear all, add one
    self.active_animations.clearRetainingCapacity();
    // ... calculate duration, create state, append
}

pub fn updateAnimation(self: *Self, delta_time: f32) !void {
    // Update ALL active animations
    for (self.active_animations.items) |*anim_state| {
        anim_state.update(delta_time);
    }
    try self.updateNodeTransformations();
    try self.updateShaderMatrices();
}

pub fn playTick(self: *Self, time: f32) !void {
    // Update time for ALL active animations
    for (self.active_animations.items) |*anim_state| {
        anim_state.current_time = time;
    }
    try self.updateNodeTransformations();
    try self.updateShaderMatrices();
}
```

### Step 4: New Multi-Animation API

```zig
/// Play all animations in the model simultaneously (for InterpolationTest)
pub fn playAllAnimations(self: *Self) !void {
    if (self.gltf_asset.gltf.animations == null) return;
    
    self.active_animations.clearRetainingCapacity();
    const animations = self.gltf_asset.gltf.animations.?;
    
    for (0..animations.len) |i| {
        const animation_index = @as(u32, @intCast(i));
        const duration = try self.calculateAnimationDuration(animation_index);
        const anim_state = GltfAnimationState.init(animation_index, 0.0, duration, .Forever);
        try self.active_animations.append(anim_state);
    }
    
    std.debug.print("Playing {d} animations simultaneously\n", .{animations.len});
}

/// Play specific animations by indices
pub fn playAnimations(self: *Self, animation_indices: []const u32) !void {
    self.active_animations.clearRetainingCapacity();
    
    for (animation_indices) |animation_index| {
        const duration = try self.calculateAnimationDuration(animation_index);
        const anim_state = GltfAnimationState.init(animation_index, 0.0, duration, .Forever);
        try self.active_animations.append(anim_state);
    }
}

/// Extract existing duration calculation logic into helper
fn calculateAnimationDuration(self: *Self, animation_index: u32) !f32 {
    // Move logic from playAnimationById() here
    // Return max_time from all samplers
}
```

### Step 5: Core Animation Processing

**Update `updateNodeTransformations()`:**

```zig
fn updateNodeTransformations(self: *Self) !void {
    if (self.active_animations.items.len == 0 or self.gltf_asset.gltf.animations == null) return;

    // Reset all node transforms to defaults
    if (self.gltf_asset.gltf.nodes) |nodes| {
        for (0..nodes.len) |i| {
            const node = nodes[i];
            self.node_transforms[i] = Transform{
                .translation = node.translation orelse vec3(0.0, 0.0, 0.0),
                .rotation = node.rotation orelse quat(0.0, 0.0, 0.0, 1.0),
                .scale = node.scale orelse vec3(1.0, 1.0, 1.0),
            };
        }
    }

    // Track animated nodes for conflict detection
    const allocator = self.arena.allocator();
    var animated_nodes = try allocator.alloc(bool, self.node_transforms.len);
    defer allocator.free(animated_nodes);
    @memset(animated_nodes, false);

    // Apply each active animation
    for (self.active_animations.items) |anim_state| {
        const animation = self.gltf_asset.gltf.animations.?[anim_state.animation_index];
        
        for (animation.channels) |channel| {
            if (channel.target.node) |node_index| {
                if (node_index < self.node_transforms.len) {
                    // Conflict detection (warning only for now)
                    if (animated_nodes[node_index]) {
                        std.debug.print("Warning: Multiple animations targeting node {d} - last animation wins\n", .{node_index});
                    }
                    animated_nodes[node_index] = true;
                    
                    try self.evaluateAnimationChannel(channel, animation.samplers[channel.sampler], anim_state.current_time, node_index);
                }
            }
        }
    }

    try self.calculateNodeMatrices();
}
```

### Step 6: Model API Updates

**File**: `src/core/model.zig`

Add convenience methods:
```zig
pub fn playAllAnimations(self: *Self) !void {
    try self.animator.playAllAnimations();
}
```

### Step 7: Demo App Integration

**Usage for InterpolationTest:**
```zig
// Instead of: try model.animator.playAnimationById(0);
try model.playAllAnimations();
```

## Testing Strategy

### Regression Testing
1. **Existing Models**: Fox, CesiumMan should work unchanged
2. **Single Animation**: `playAnimationById()` should work as before
3. **API Compatibility**: All existing methods preserved

### New Functionality Testing
1. **InterpolationTest**: All 9 cubes should animate with different interpolation
2. **Multiple Animations**: Verify multiple animations run simultaneously
3. **Conflict Detection**: Test warning messages for conflicting animations

## Success Criteria

### Phase 1 Complete When:
1. 🔄 InterpolationTest.gltf shows all 9 cubes animating correctly (ISSUE: cubes not moving yet)
2. ✅ All existing models (Fox, CesiumMan) work unchanged  
3. ✅ No breaking changes to public API
4. ✅ Conflict detection warns about overlapping animations
5. ✅ `playAllAnimations()` method available for demo app

### Future Phases:
- Animation blending for smooth conflicts
- Selective animation control per node
- Animation priority/layering system

## Files to Modify

1. **`src/core/animator.zig`** - Core changes (data structure, methods)
2. **`src/core/model.zig`** - Add convenience methods
3. **Test files** - Verify backward compatibility

## Risk Mitigation

1. **Backward Compatibility**: Keep all existing methods working
2. **Performance**: Use ArrayList for efficient multi-animation storage
3. **Memory**: Reuse allocations where possible
4. **Conflicts**: Start with simple "last wins" strategy

## Dependencies

- No external dependencies
- Uses existing ArrayList and Arena allocator patterns
- Compatible with current glTF animation infrastructure

---

## Implementation Status

### ✅ **Phase 1 Implementation Completed (2025-07-19)**

All core infrastructure has been successfully implemented:

1. **✅ Data Structure Changes**: `active_animations: ArrayList(GltfAnimationState)` replaces single animation
2. **✅ Backward Compatibility**: All existing methods (`playClip`, `playAnimationById`, `updateAnimation`, `playTick`) work unchanged
3. **✅ Multi-Animation API**: `playAllAnimations()` and `playAnimations()` methods implemented
4. **✅ Conflict Detection**: Warning system for overlapping animations with "last wins" strategy
5. **✅ Demo App Integration**: Flag-based configuration using `play_all_animations: bool` in `DemoModel` struct
6. **✅ Testing**: Build successful, multi-animation system activates correctly for InterpolationTest

### ✅ **CRITICAL ISSUE RESOLVED - Non-Skinned Animation Fix (2025-07-19)**

**Root Cause Identified**: The rendering system was ignoring animated transforms for non-skinned models.

**Problem**: `renderNodes()` in `src/core/model.zig` used static glTF node transforms instead of animated transforms calculated by the animator.

**The Issue**:
```zig
// BROKEN - Used static transforms from glTF data
const transform = Transform{
    .translation = node.translation orelse vec3(0.0, 0.0, 0.0),  // ❌ Static
    .rotation = node.rotation orelse quat(0.0, 0.0, 0.0, 1.0),   // ❌ Static  
    .scale = node.scale orelse vec3(1.0, 1.0, 1.0),             // ❌ Static
};
```

**The Fix**:
```zig
// WORKING - Uses animated transforms from animator
const transform = if (node_index < self.animator.node_transforms.len) 
    self.animator.node_transforms[node_index]  // ✅ Animated transforms
else Transform{
    .translation = node.translation orelse vec3(0.0, 0.0, 0.0),  // Fallback
    .rotation = node.rotation orelse quat(0.0, 0.0, 0.0, 1.0),
    .scale = node.scale orelse vec3(1.0, 1.0, 1.0),
};
```

**Impact**: 
- ✅ **BoxAnimated**: Simple rotation + translation animations now work
- ✅ **InterpolationTest**: All 9 cubes animate with different interpolation methods  
- ✅ **Player.gltf**: Hybrid skinned (body) + non-skinned (gun) animation works perfectly
- ✅ **All Models**: Complete animation system now functional

**Technical Details**:
1. **Animator was working correctly** - calculating animated transforms in `node_transforms[]`
2. **Rendering was broken** - ignored calculated animations for non-skinned geometry
3. **Fix maintains compatibility** - skinned meshes still use joint matrices, non-skinned use node transforms
4. **Hybrid models supported** - models with both animation types work seamlessly

### 🎯 **Phase 1 COMPLETED Successfully**

All success criteria have been met:
1. ✅ **InterpolationTest.gltf**: All 9 cubes animate correctly with different interpolation methods
2. ✅ **Existing Models**: Fox, CesiumMan, and all previous models work unchanged  
3. ✅ **API Compatibility**: No breaking changes to public API
4. ✅ **Conflict Detection**: Warning system implemented (silenced for expected multi-animation cases)
5. ✅ **Multi-Animation API**: `playAllAnimations()` method available and working
6. ✅ **Hybrid Animation**: Both skinned and non-skinned animation work simultaneously

## Command Line Interface Integration

### ✅ **Enhanced Testing Support (2025-07-19)**

Added comprehensive command line interface to both `animation_example` and `demo_app` for easy multi-animation testing:

#### **Animation Example Updates**
- **File**: `examples/animation_example/main.zig`
- **Multi-Animation Flag**: `animationPlayAll: bool` in `ModelConfig`
- **InterpolationTest Configuration**: Set `animationPlayAll = true` for automatic multi-animation activation
- **Usage**: Model automatically detected and plays all 9 animations simultaneously

#### **Demo App Command Line Interface**
- **File**: `examples/demo_app/main.zig` and `examples/demo_app/run_app.zig`
- **Complete CLI**: Added comprehensive argument parsing similar to animation_example

**Available Options:**
```bash
# Show all available options
zig build demo_app-run -- --help

# List all 17 available models with indices
zig build demo_app-run -- --list-models

# Start with specific model (e.g., InterpolationTest at index 0)
zig build demo_app-run -- --model-index 0

# Run for specific duration and auto-exit (perfect for testing)
zig build demo_app-run -- --model-index 0 --duration 5

# Test Fox model with 3-second runtime
zig build demo_app-run -- --model-index 5 --duration 3
```

**Key Benefits:**
1. **Automated Testing**: Duration parameter enables scripted testing scenarios
2. **Model Discovery**: List option shows all available models and their indices
3. **Targeted Testing**: Direct model selection without manual navigation
4. **Multi-Animation Testing**: InterpolationTest (index 0) automatically activates all 9 animations
5. **Consistent Interface**: Both demo_app and animation_example use similar CLI patterns

**Implementation Details:**
- Command line parsing with full validation and error handling
- Model index validation against available models (0-16 range)
- Duration-based auto-exit for automated testing scenarios
- Help system with usage examples and option descriptions
- Integration with existing `assets_list.zig` model configuration

**Testing Examples:**
```bash
# Quick InterpolationTest multi-animation test
zig build demo_app-run -- -m 0 -d 3

# Test all animated models sequentially
for i in 0 5 6 7; do zig build demo_app-run -- -m $i -d 2; done

# List models to find specific ones
zig build demo_app-run -- -l | grep "Helmet"
```

This CLI enhancement significantly improves the development and testing workflow for multi-animation scenarios.

---

## 🎉 **PLAN 006 COMPLETED SUCCESSFULLY (2025-07-19)**

**Final Status**: All objectives achieved. Multi-animation support is fully functional with comprehensive testing infrastructure. Both skinned and non-skinned animation work perfectly, including complex hybrid models.

**Next Steps**: Ready for Plan 007 or other engine enhancements. The animation system now supports the full glTF specification for animation scenarios.
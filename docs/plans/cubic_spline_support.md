# Cubic Spline Animation Support - IMPLEMENTED

## Overview

This document describes the implemented cubic spline interpolation support in the redfish_gl_zig animation system. 
Cubic splines provide smooth, curved interpolation between keyframes with continuous velocity and acceleration, 
eliminating the jerky transitions that can occur with linear interpolation.

## Background

**What Cubic Splines Do:**
- Create smooth curves between control points using cubic polynomials
- Ensure C² continuity (position, velocity, and acceleration are continuous)
- Each curve segment is defined by: start point, start tangent, end tangent, end point
- Produce natural, fluid motion without sharp changes in direction or speed

**Usage in Game Engines:**
- Very common - industry standard in Unity, Unreal, Godot, CryEngine
- Official interpolation mode in glTF 2.0 specification (CUBICSPLINE)
- Essential for high-quality character animation, camera movement, and UI transitions

## Implementation Design

The implementation follows these principles:

1. **Plain objects** without methods - data structures are simple containers
2. **Separate structs** for different interpolation types (linear vs cubic)
3. **Union-based dispatch** - type-safe switching between interpolation modes
4. **Clear separation** between data structures and algorithms
5. **Clarity over micro-optimization** - use arrays of structs for spline data

## Implementation Architecture

The cubic spline system uses a union-based architecture for type-safe interpolation dispatch:

### Core Data Structures

- **Keyframe Structs**: `Vec3CubicKeyframe`, `QuatCubicKeyframe`, `ScalarCubicKeyframe` contain `in_tangent`, `value`, `out_tangent` fields
- **Data Containers**: `Vec3CubicData`, `QuatCubicData`, `ScalarCubicData` hold keyframe arrays and timing data
- **Union Types**: `NodeTranslationData`, `NodeRotationData`, `NodeScaleData`, `NodeWeightData` enable compile-time dispatch between linear and cubic interpolation

### Interpolation Functions

- **Type-Safe Dispatch**: Union switching automatically selects linear vs cubic interpolation
- **Hermite Implementation**: Uses standard cubic Hermite basis functions matching Khronos glTF-Sample-Renderer
- **Quaternion Handling**: Component-wise Hermite interpolation followed by normalization
- **Tangent Scaling**: Pre-scales tangents by keyframe delta time for correct Khronos compliance

## Implementation Benefits

1. **Crystal Clear Intent**: `keyframe.value`, `keyframe.in_tangent`, `keyframe.out_tangent` is immediately understandable
2. **Type Safety**: Compile-time dispatch eliminates runtime interpolation type checking
3. **Khronos Compliance**: Exact match with glTF-Sample-Renderer cubic spline implementation
4. **Extensible**: Easy to add new interpolation types by extending the unions
5. **Memory Efficient**: Struct-based keyframes pack well and maintain good cache behavior

## Technical Notes

### Quaternion Cubic Splines
- Component-wise Hermite interpolation (treat quaternion as 4 scalars: x, y, z, w)
- Normalize final result to ensure unit quaternion
- Follows glTF specification exactly - no specialized quaternion spline algorithms needed

### glTF Data Parsing
- Converts flat glTF arrays `[in_tangent0, value0, out_tangent0, ...]` to keyframe structs
- Implemented in `parseCubicSplineVec3Data`, `parseCubicSplineQuatData`, `parseCubicSplineScalarData` helper functions
- Handles all four animation channels: translation, rotation, scale, weights

### Hermite Basis Functions
The implementation uses standard cubic Hermite basis functions matching Khronos reference:
- `h00 = 2t³ - 3t² + 1` (start value weight)
- `h10 = t³ - 2t² + t` (start tangent weight)  
- `h01 = -2t³ + 3t²` (end value weight)
- `h11 = t³ - t²` (end tangent weight)

### Tangent Pre-scaling
Tangents are pre-scaled by keyframe delta time before applying Hermite interpolation, ensuring exact compliance with Khronos glTF-Sample-Renderer implementation.

## Future Enhancements

- Add support for additional spline types (Catmull-Rom, B-splines)
- Optimize memory layout if performance profiling indicates bottlenecks
- Add spline editing/creation tools for development
# Development Backlog

> Imported from redfish_gl_zig on 2026-09-28. Items the WebGPU port has delivered since are
> ticked or annotated; new ideas go at the end of the relevant cluster.

This file tracks future features organized by development layers. Features are grouped into logical clusters that build upon the foundational layer (Plans 001-004).

## Next Iteration (Layer 2) - Advanced Features

### Advanced Rendering Cluster
- [x] **Shadow Mapping System** (port Step 9: `core.ShadowMap`, PCF; angrybot)
  - Directional light shadow maps
  - Basic shadow filtering
  - Shadow map optimization

- [ ] **Environment Mapping & IBL** (skybox done: `core.shapes.Skybox`; IBL open)
  - Skybox/environment cube support
  - Image-based lighting basics
  - Reflection probe system
  - Environment map filtering

- [ ] **Post-Processing Pipeline** (render targets and bloom in angrybot; Reinhard in `pbr.wgsl`; sRGB surface)
  - Tone mapping (ACES, Reinhard)
  - Basic bloom effect
  - Gamma correction pipeline
  - Exposure control system

- [ ] **Advanced Material Features** (blend and double-sided done; extensions open)
  - glTF material extensions (clearcoat, transmission)
  - Blend mode support
  - Double-sided rendering
  - Texture coordinate transformations

- [ ] **Anti-aliasing (MSAA)** (added 2026-09-29; shape edges and shadow silhouettes stair-step)
  - 4x MSAA: a multisampled color texture resolved into the surface texture, and a
    multisampled depth texture, in `GpuContext`
  - Sample count on every pipeline (`createRenderPipeline`) and in ImGui's backend
    (`pipeline_multisample_state` in `gui.zig`)
  - Render-target passes (angrybot's) either match the sample count or stay at one
  - Option to turn it off; `ScreenCapture` resolves the same way

### Advanced Animation Cluster
- [ ] **Complex State Machine**
  - Hierarchical state machines
  - Parallel state execution
  - State machine composition
  - Reusable state components

- [ ] **Animation Events & Integration**
  - Animation event markers
  - Frame-based event triggers
  - Sound effect integration points
  - Particle effect triggers
  - Gameplay event notifications

- [ ] **Advanced Blending Systems**
  - 2D blend spaces (directional movement)
  - Blend trees for locomotion
  - Additive animation support
  - Animation layering system
  - Root motion support

- [ ] **Animation Tools & Optimization**
  - Animation LOD system
  - Bone mask optimization
  - Animation compression
  - Debugging and visualization tools

### Advanced Scene Management Cluster
- [ ] **Spatial Optimization**
  - Occlusion culling system
  - Bounding volume hierarchies
  - Spatial partitioning (octree/quadtree)
  - Distance-based LOD

- [ ] **Batching & Performance** (instancing done: `Shape.drawInstanced`)
  - Static batch rendering
  - Dynamic batching
  - Instanced rendering support
  - Material sorting optimization
  - Draw call optimization

- [ ] **Scene Streaming & Memory**
  - Scene object pooling
  - Streaming for large scenes
  - Background scene loading
  - Memory usage monitoring
  - Texture atlasing

- [ ] **Scene Tools & Serialization**
  - Advanced scene file format
  - Scene validation system
  - Scene template system
  - Scene merging capabilities
  - Procedural scene generation

## Future Iterations (Layer 3+) - Engine Integration & Polish

### Engine Systems Integration
- [ ] **Audio System** (basic clips done: `core.SoundEngine` on zaudio)
  - Spatial audio support
  - Audio streaming
  - Music and sound effect management
  - Audio event integration with animations

- [ ] **Loading Progress System**
  - Progress indication for large models
  - Loading state management
  - User feedback during load operations

- [ ] **Physics Integration**
  - Physics engine integration (Bullet, etc.)
  - Collision detection
  - Rigid body dynamics
  - Character controller physics

- [ ] **Input & Platform Support**
  - Gamepad support
  - Mobile touch input
  - Platform-specific optimizations
  - Multi-platform deployment

### Performance & Optimization
- [ ] **Multi-threading Support**
  - Render thread separation
  - Asset loading threads
  - Animation update threading
  - Task-based parallelism

- [ ] **Mobile & Low-end Support**
  - Mobile GPU optimizations
  - Reduced precision rendering
  - Battery usage optimization
  - Performance profiling tools

- [ ] **Advanced Culling & LOD**
  - GPU-driven rendering
  - Compute shader culling
  - Automatic LOD generation
  - Temporal coherence optimization

### Development Tools & Pipeline
- [ ] **Asset Pipeline**
  - Asset import/export tools
  - Texture compression pipeline
  - Model optimization tools
  - Asset dependency management

- [ ] **Editor & Tooling**
  - Scene editor application
  - Material editor
  - Animation state machine editor
  - Performance profiling tools

- [ ] **Debugging & Profiling**
  - Frame debugger
  - GPU profiling integration
  - Memory leak detection
  - Performance bottleneck analysis

### Advanced Features
- [ ] **Networking Support**
  - Multi-player scene synchronization
  - Network-aware animation systems
  - Lag compensation
  - Server-client architecture

- [ ] **VR/AR Support**
  - VR headset integration
  - Stereo rendering
  - Hand tracking
  - AR camera integration

- [ ] **Advanced Lighting**
  - Global illumination
  - Light probes
  - Volumetric lighting
  - Real-time ray tracing (when available)

## Backlog Management

### Selection Criteria for Next Iteration
- Builds naturally on foundation layer
- Provides visible improvement to demo
- Doesn't require extensive infrastructure changes
- Can be completed in 1-2 weeks per cluster

### Priority Guidelines
1. **User-Visible Features First** - Things that improve the demo experience
2. **Performance When Needed** - Optimize when current approach becomes limiting
3. **Tools Last** - Build tools when manual processes become tedious

### Review Process
- After completing foundation layer (Plans 001-004), review this backlog
- Select 2-3 clusters for next iteration based on current needs
- Create new focused plan files for selected features
- Update this backlog with any new discoveries or requirements

## Notes
- Features in this backlog may be split, combined, or reprioritized based on actual development experience
- Some features may be moved back to foundation layer if they prove essential
- New features discovered during development should be added to appropriate clusters
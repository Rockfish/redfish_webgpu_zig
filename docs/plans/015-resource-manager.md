# Plan 015 - Resource Manager

> Imported from redfish_gl_zig on 2026-09-28. **In this repo:** Implemented in the factory form proposed here: `src/core/resource_manager.zig` creates and tracks shaders, textures, models, shapes, and materials (port Step 6).
> File and API references in the body are to redfish_gl_zig (OpenGL) unless noted.

## Status: Design Discussion

## Context

The current `ResourceManager` prototype in `examples/bullets/resource_manager.zig` uses a type-erased dispatch pattern to track GL resources for cleanup. While the dispatch implementation is solid, the design has a fundamental weakness identified in `plan/resource_manager_notes.md`:

> "it really doesn't provide anything more than scene calling deleteGlObject on each loaded object"

Every scene object must manually call `addResource` after creating its own resources. In practice, none of the scene objects in `debug_scene.zig` actually do this -- the ResourceManager is created but never populated. Resource creation and resource tracking are disconnected actions, and the tracking side gets skipped.

The proposed direction: make the ResourceManager a **factory that wraps creation calls and automatically tracks what it creates**. This eliminates the manual tracking step entirely and creates a single place for all resource creation.

---

## 1. Why the Factory Pattern Is Right

The core insight is that **tracking should be a side effect of creation, not a separate step**. When you call `rm.createShader(vert, frag)`, the manager both creates the shader and adds it to its internal list. There is no way to forget the tracking step because it does not exist as a separate action.

Looking at how scene objects currently create resources, the pattern is highly consistent:

```zig
// ToonSoldier.init()
const shader = try core.Shader.init(allocator, vert_path, frag_path);
var gltf_asset = try core.asset_loader.GltfAsset.init(allocator, "name", model_path);
const model = try gltf_asset.buildModel();

// Floor.init()
var floor = try core.shapes.Plane.init(allocator, config);
const shader = try Shader.init(allocator, vert_path, frag_path);
```

Every scene object follows the same sequence: create shader, create model or shape, sometimes create textures. The allocator is always passed in. Wrapping these calls in factory methods is natural because the signatures are already uniform.

The key principle: **the ResourceManager wraps existing init() calls -- it does not replace them**. `Shader.init()`, `Texture.initFromFile()`, `GltfAsset.init()`, and `Plane.init()` keep their current signatures. Scene code that does not want the ResourceManager can still create resources directly.

---

## 2. How Other Engines Handle This

### Raylib (Minimal)
Load functions return value types, programmer calls `UnloadTexture()`, `UnloadModel()` manually. No automatic tracking. Works for small projects where you can mentally track a dozen resources. Breaks down with multiple scenes and shared assets.

### Love2D (GC-Driven)
Lua's garbage collector handles resource lifetime. When a resource has no references, it gets collected and the GL object is freed. Automatic but imprecise -- you cannot control when cleanup happens, and it can cause frame hitches during collection.

### MonoGame/XNA ContentManager (Best Fit for This Engine)
Call `content.Load<Texture2D>("path")`, it loads and caches by path, `content.Unload()` frees everything. Multiple ContentManagers can exist for different scopes (global vs per-level). Simple, typed, no reference counting needed until you actually share resources. **This is the closest match to what redfish_gl_zig needs.**

### Godot ResourceLoader (Full Featured)
`load("res://texture.png")` returns a cached reference if already loaded. Full reference counting, path-based caching, resource database. Powerful but complex -- thousands of lines of code. More infrastructure than a small engine needs.

### Bevy AssetServer (ECS Approach)
Typed `Handle<T>` values, assets loaded asynchronously, stored in typed `Assets<T>` collections. Very general, very powerful, requires significant infrastructure. Designed for ECS architecture, not a good fit for the current scene-object architecture.

### The Pattern That Fits
For a small-to-mid-size engine, the **ContentManager/Registry pattern** is the sweet spot:
1. Typed factory methods -- the manager knows the type at creation time
2. Typed storage -- separate lists per resource type, no type erasure for common operations
3. Bulk cleanup -- single `deleteAll()` for scene teardown
4. Optional naming -- string keys for resources that need lookup (shaders, models)

---

## 3. Recommended Design

### Typed Storage Over Type Erasure

The existing `Resource` dispatch pattern stores everything in one generic list. The factory approach stores resources in **typed lists** -- one per resource type. This is simpler, more debuggable, and faster to iterate. The type-erased pattern can remain as a fallback for edge cases, but the typed lists are the primary storage.

```
ResourceManager
  ├── shaders: ManagedArrayList(*Shader)
  ├── textures: ManagedArrayList(*Texture)
  ├── models: ManagedArrayList(*Model)
  ├── planes: ManagedArrayList(Plane)
  ├── shapes: ManagedArrayList(*Shape)
  ├── shader_names: StringHashMap(*Shader)     // optional lookup
  ├── model_names: StringHashMap(*Model)       // optional lookup
  └── texture_names: StringHashMap(*Texture)   // optional lookup
```

### Factory Methods

Each wraps the existing init() call, stores the result, returns it:

```zig
pub fn createShader(self: *Self, vert_path: []const u8, frag_path: []const u8) !*Shader
pub fn createShaderNamed(self: *Self, name: []const u8, vert_path: []const u8, frag_path: []const u8) !*Shader
pub fn createTexture(self: *Self, path: [:0]const u8, config: TextureConfig) !*Texture
pub fn loadModel(self: *Self, name: []const u8, path: []const u8) !*Model
pub fn loadGltfAsset(self: *Self, name: []const u8, path: []const u8) !*GltfAsset  // for manual config
pub fn buildModel(self: *Self, gltf_asset: *GltfAsset) !*Model                     // tracks manual build
pub fn createPlane(self: *Self, config: PlaneConfig) !Plane
pub fn deleteAll(self: *Self) void
```

### The Two-Step Model Loading Pattern

Scene objects often need to configure a GltfAsset before building:

```zig
// Current pattern in scene objects:
var gltf_asset = try core.asset_loader.GltfAsset.init(allocator, "spacesuit", path);
gltf_asset.setNormalGenerationMode(.accurate);
gltf_asset.skipModelTextures();
const model = try gltf_asset.buildModel();
```

The ResourceManager supports this with two separate calls:

```zig
// With ResourceManager:
var gltf_asset = try rm.loadGltfAsset("spacesuit", path);
gltf_asset.setNormalGenerationMode(.accurate);
const model = try rm.buildModel(gltf_asset);
```

This avoids callback patterns or trying to encode every config option in the factory method signature.

### Cleanup Order

Order matters -- models reference shaders, so models must be torn down first:

1. Models (own arenas, textures via GltfAsset)
2. Planes (own shapes + textures)
3. Shapes (VAOs, VBOs, EBOs)
4. Standalone textures (not owned by models)
5. Shaders (GL program IDs)
6. Name map keys (allocated strings)

### How Scene Objects Change

```zig
// Before: scene object manages its own allocator
pub fn init(allocator: Allocator) !*ToonSoldier {
    const shader = try core.Shader.init(allocator, vert_path, frag_path);
    var gltf_asset = try core.asset_loader.GltfAsset.init(allocator, "soldier", model_path);
    const model = try gltf_asset.buildModel();
    ...
}

// After: scene object receives ResourceManager
pub fn init(rm: *core.ResourceManager) !*ToonSoldier {
    const shader = try rm.createShader(vert_path, frag_path);
    const model = try rm.loadModel("soldier", model_path);
    ...
}
```

The scene object no longer needs an allocator for resource creation. The dependency on resource management is explicit in the signature.

### Where It Lives

`src/core/resource_manager.zig` -- a core engine type, not example-specific. Exported from `src/core/root.zig` as `core.ResourceManager`. The current prototype in `examples/bullets/` gets removed.

---

## 4. Phased Implementation

### Phase 1 -- Immediate Value

**Goal**: Working factory with auto-tracking. Proves the pattern works.

**Scope**:
- Create `src/core/resource_manager.zig` with typed lists, factory methods, `deleteAll()`
- Export from `src/core/root.zig`
- Migrate `examples/bullets/` scene objects to use it
- Remove `examples/bullets/resource_manager.zig` prototype

**What NOT to do**: No lookup methods, no scene-scoping, no caching. Just create and track.

### Phase 2 -- Named Lookup and Scene Transitions

**Goal**: Enable resource sharing between scene objects and support scene swaps.

**Scope**:
- `getShader(name)`, `getModel(name)`, `getTexture(name)` lookup methods
- Path-based shader deduplication (linear scan is fine for 5-20 shaders)
- Two-tier ownership: global ResourceManager on World + per-scene ResourceManager
- Scene transition: create new scene RM → load → swap → deleteAll old RM

The global manager holds resources shared across scenes (common shaders). Each scene gets its own manager for scene-specific resources:

```zig
const shader = global_rm.getShader("animated_pbr") orelse
    try scene_rm.createShaderNamed("animated_pbr", vert_path, frag_path);
```

### Phase 3 -- Config Files and Advanced Features

**Goal**: Data-driven resource loading, development tools.

**Config file** -- a JSON manifest that maps names to types and paths:

```json
{
    "shaders": {
        "animated_pbr": {
            "vertex": "shaders/animated_pbr.vert",
            "fragment": "shaders/animated_pbr.frag"
        }
    },
    "models": {
        "soldier": {
            "path": "assets/models/Character_Soldier.gltf",
            "normal_mode": "skip"
        }
    },
    "textures": {
        "floor_diffuse": {
            "path": "assets/textures/floor_d.png",
            "wrap": "repeat"
        }
    }
}
```

The ResourceManager becomes the natural loader:

```zig
pub fn loadFromManifest(self: *Self, manifest_path: []const u8) !void
```

Config file names become the StringHashMap keys. Scene code becomes:

```zig
const shader = rm.getShader("animated_pbr").?;
const model = rm.getModel("soldier").?;
```

Changing which model file "soldier" uses becomes a config change, not a code change.

**Important boundary**: the config file defines **what resources to load**, not **how to arrange them in a scene**. Scene layout (positions, rotations, which objects appear) stays in code. Mixing resource loading with scene description creates a much larger problem.

**Other Phase 3 features** (only when needed):
- Reference counting for shared resources with independent lifetimes
- Shader hot-reloading for development (RM knows all shader paths)
- Async/background loading for large assets

---

## 5. What to Avoid

| Avoid | Why |
|-------|-----|
| Changing core type init() signatures | The RM wraps them; scene code that doesn't want the RM should still work |
| Making it a singleton/global | Pass explicitly, consistent with how allocator is passed. Globals hide dependencies |
| Reference counting in Phase 1 | No actual shared-lifetime resources exist yet. The fix is to create shared resources once and pass them, not to add ref-counting |
| Building an ECS | The scene-object architecture works well. The RM makes it easier, doesn't replace it |
| Scene description in config files | Config defines what to load, not where to place it. Scene layout is a separate, much larger problem |
| Over-abstracting types | Typed lists per resource type are simpler and more debuggable than one generic type-erased list |

---

## 6. Summary

| Phase | What | Value |
|-------|------|-------|
| 1 | Factory methods + auto-tracking + deleteAll | Eliminates manual tracking, single cleanup point |
| 2 | Named lookup + scene scoping | Resource sharing, scene transitions |
| 3 | Config files + hot reload | Data-driven loading, faster development iteration |

### Key Files
- `src/core/resource_manager.zig` -- new core type (Phase 1)
- `src/core/root.zig` -- export point
- `examples/bullets/debug_scene.zig` -- first migration target
- `examples/bullets/scene/*.zig` -- scene objects to migrate
- `src/core/shader.zig` -- most commonly wrapped factory call
- `../../src/core/gltf_asset.zig` -- GltfAsset/Model creation flow

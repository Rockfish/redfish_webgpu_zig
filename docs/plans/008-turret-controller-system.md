# Plan 008: Turret Controller System

> Imported from redfish_gl_zig on 2026-09-28. **In this repo:** Planning. No controller yet; `examples/bullets/objects/cannon.zig` is the nearest code.
> File and API references in the body are to redfish_gl_zig (OpenGL) unless noted.

**Status**: 📝 Planning
**Priority**: Medium
**Estimated Effort**: Medium (2-3 days)
**Created**: 2026-01-11

## Overview

Implement a modular turret controller system for tower defense games and similar use cases. Following the organizational pattern from `examples/bullets`, this system provides clean separation between scene objects, controllers, and rendering, enabling hierarchical control of multi-part objects (turrets, cranes, robotic arms) where different components rotate independently on specific axes.

## Design Philosophy

### Inspired by examples/bullets Organization

The `examples/bullets` demonstrates excellent separation of concerns:

```
examples/bullets/
├── scene/
│   ├── cube.zig           # Each object owns shader, texture, shape
│   ├── floor.zig          # Self-contained with draw() method
│   ├── axis_lines.zig     # No shader crosstalk
│   ├── scene.zig          # Composes all objects
│   └── input_handler.zig  # Input management
├── projectiles/
│   ├── bullet.zig         # Bullet system
│   └── simple_bullets.zig # Bullet variants
├── shaders/               # Shader files
├── run_app.zig           # Clean orchestration loop
└── state.zig             # Global state
```

**Key Principles:**
1. **Object Ownership**: Each scene object owns its shader, prevents crosstalk
2. **File Organization**: One file per object type, grouped in directories
3. **Scene Composition**: `scene.zig` composes objects, provides clean API
4. **Minimal run_app**: Just loop and scene method calls
5. **Easy Extension**: Add new objects by creating new files

### Applied to Turret System

```
games/level_01/
├── turrets/
│   ├── turret.zig              # Turret scene object (owns shader)
│   ├── turret_controller.zig  # Tracking/aiming logic
│   ├── turret_builder.zig     # Factory for creating turrets
│   └── turret_types.zig       # Different turret configurations
├── scene/
│   ├── scene.zig              # Scene composition
│   ├── ground.zig             # Ground object
│   ├── target.zig             # Moving target object
│   └── lights.zig             # Lighting configuration
├── shaders/
│   ├── turret.vert            # Turret vertex shader
│   ├── turret.frag            # Turret fragment shader
│   └── basic.vert/frag        # Basic shaders
├── run_app.zig               # Clean main loop
├── nodes.zig                 # Node system (already exists)
└── state.zig                 # Game state
```

## Architecture

### Component Responsibilities

**Turret (Scene Object)** - Self-contained rendering unit:
```zig
// turrets/turret.zig
pub const Turret = struct {
    // Ownership
    base_node: *Node,
    body_node: *Node,
    barrel_node: *Node,
    shader: *Shader,           // Owns its shader
    textures: TurretTextures,  // Owns textures

    // Configuration
    controller: TurretController,

    // Interface
    pub fn init(allocator, position, config) !Turret
    pub fn update(delta_time) void
    pub fn draw(projection, view) void
    pub fn setTarget(target: ?Vec3) void
};
```

**TurretController** - Pure logic component:
```zig
// turrets/turret_controller.zig
pub const TurretController = struct {
    body_node: *Node,
    barrel_node: *Node,

    target: ?Vec3,
    yaw_speed: f32,
    pitch_speed: f32,
    pitch_limits: [2]f32,

    current_yaw: f32,
    current_pitch: f32,

    pub fn update(delta_time) void
    pub fn setTarget(target: ?Vec3) void
    pub fn isOnTarget(tolerance: f32) bool
    pub fn getAimDirection() Vec3
};
```

**Scene** - Composition and orchestration:
```zig
// scene/scene.zig
pub const Scene = struct {
    camera: *Camera,
    ground: Ground,
    turrets: std.ArrayList(Turret),
    target: MovingTarget,
    lights: Lights,

    pub fn init(arena, scr_width, scr_height) !Scene
    pub fn update(delta_time) void
    pub fn drawTurrets(projection, view) void
    pub fn drawGround(projection, view) void
    pub fn drawTarget(projection, view) void
};
```

## Implementation Plan

### Phase 1: Directory Structure & Basic Files

**Task**: Create organized directory structure following bullets pattern

**Files to Create**:
```
games/level_01/
├── turrets/
│   └── .gitkeep
├── scene/
│   ├── lights.zig        # Lighting configuration
│   └── scene.zig         # Scene composition (basic version)
└── shaders/
    ├── turret.vert       # Turret-specific shaders
    └── turret.frag
```

**1. Create `turrets/` directory structure**:
```bash
mkdir -p games/level_01/turrets
mkdir -p games/level_01/scene
```

**2. Create `scene/lights.zig`** - Shared lighting configuration:
```zig
const math = @import("math");
const Vec3 = math.Vec3;
const vec3 = math.vec3;

pub const Lights = struct {
    ambient_color: Vec3,
    light_color: Vec3,
    light_direction: Vec3,
};

pub const basic_lights = Lights{
    .ambient_color = vec3(1.0, 0.6, 0.6),
    .light_color = vec3(0.35, 0.4, 0.5),
    .light_direction = vec3(3.0, 3.0, 3.0),
};
```

**3. Create basic shader files** in `shaders/turret.vert` and `turret.frag`

**Acceptance Criteria**:
- [ ] Directory structure matches bullets pattern
- [ ] `lights.zig` provides shared lighting config
- [ ] Basic shader files created
- [ ] Code formatted with `zig fmt`

---

### Phase 2: Node Helper Methods

**File**: `games/level_01/nodes.zig`

**Task**: Add helper methods to Node for turret control

**Methods to Add**:

1. **`setLocalRotation()`** - Set absolute rotation:
   ```zig
   pub fn setLocalRotation(self: *Node, rotation: Quat) void {
       self.transform.rotation = rotation;
       self.updateTransforms(if (self.parent) |p| &p.global_transform else null);
   }
   ```

2. **`getForward()`**, **`getRight()`**, **`getUp()`** - Direction helpers:
   ```zig
   pub fn getForward(self: *Node) Vec3 {
       return self.global_transform.forward();
   }

   pub fn getRight(self: *Node) Vec3 {
       return self.global_transform.right();
   }

   pub fn getUp(self: *Node) Vec3 {
       return self.global_transform.up();
   }
   ```

3. **`getWorldPosition()`** - Convenience method:
   ```zig
   pub fn getWorldPosition(self: *Node) Vec3 {
       return self.global_transform.translation;
   }
   ```

**Acceptance Criteria**:
- [ ] Node has `setLocalRotation()` method
- [ ] Node has direction helper methods
- [ ] Methods update transforms correctly
- [ ] Code formatted with `zig fmt`

---

### Phase 3: TurretController Component

**File**: `turrets/turret_controller.zig`

**Task**: Create pure logic controller for turret aiming

```zig
const std = @import("std");
const math = @import("math");
const nodes = @import("../nodes.zig");

const Vec3 = math.Vec3;
const vec3 = math.vec3;
const Quat = math.Quat;
const Node = nodes.Node;

pub const TurretController = struct {
    body_node: *Node,
    barrel_node: *Node,

    // Targeting
    target: ?Vec3 = null,

    // Movement parameters
    yaw_speed: f32 = 90.0,     // degrees per second
    pitch_speed: f32 = 60.0,   // degrees per second
    pitch_limits: [2]f32 = .{ -10.0, 80.0 },  // [min, max] degrees

    // State
    current_yaw: f32 = 0.0,
    current_pitch: f32 = 0.0,
    is_tracking: bool = false,

    const Self = @This();

    pub fn init(body: *Node, barrel: *Node) Self {
        return .{
            .body_node = body,
            .barrel_node = barrel,
        };
    }

    pub fn setTarget(self: *Self, target: ?Vec3) void {
        self.target = target;
        self.is_tracking = (target != null);
    }

    pub fn update(self: *Self, delta_time: f32) void {
        if (self.target) |tgt| {
            self.trackTarget(tgt, delta_time);
        }
    }

    fn trackTarget(self: *Self, target: Vec3, delta_time: f32) void {
        const body_pos = self.body_node.getWorldPosition();
        const to_target = target.sub(&body_pos);

        // Calculate desired yaw (horizontal rotation)
        const desired_yaw = std.math.atan2(f32, to_target.x, to_target.z);
        const yaw_delta = angleWrap(desired_yaw - self.current_yaw);
        const max_yaw_delta = math.degreesToRadians(self.yaw_speed * delta_time);
        const clamped_yaw = std.math.clamp(yaw_delta, -max_yaw_delta, max_yaw_delta);

        self.current_yaw += clamped_yaw;
        const yaw_quat = Quat.fromAxisAngle(&vec3(0.0, 1.0, 0.0), self.current_yaw);
        self.body_node.setLocalRotation(yaw_quat);

        // Calculate desired pitch (vertical rotation)
        const horizontal_dist = std.math.sqrt(to_target.x * to_target.x + to_target.z * to_target.z);
        const desired_pitch = std.math.atan2(f32, to_target.y, horizontal_dist);
        const pitch_delta = angleWrap(desired_pitch - self.current_pitch);
        const max_pitch_delta = math.degreesToRadians(self.pitch_speed * delta_time);
        const clamped_pitch_delta = std.math.clamp(pitch_delta, -max_pitch_delta, max_pitch_delta);

        const new_pitch = self.current_pitch + clamped_pitch_delta;
        const pitch_min = math.degreesToRadians(self.pitch_limits[0]);
        const pitch_max = math.degreesToRadians(self.pitch_limits[1]);
        self.current_pitch = std.math.clamp(new_pitch, pitch_min, pitch_max);

        const pitch_quat = Quat.fromAxisAngle(&vec3(1.0, 0.0, 0.0), self.current_pitch);
        self.barrel_node.setLocalRotation(pitch_quat);
    }

    pub fn isOnTarget(self: *Self, tolerance_degrees: f32) bool {
        if (self.target == null) return false;

        const aim_dir = self.getAimDirection();
        const body_pos = self.body_node.getWorldPosition();
        const to_target = self.target.?.sub(&body_pos).toNormalized();

        const angle_to_target = std.math.acos(aim_dir.dot(&to_target).clamp(-1.0, 1.0));
        return angle_to_target < math.degreesToRadians(tolerance_degrees);
    }

    pub fn getAimDirection(self: *Self) Vec3 {
        return self.barrel_node.getForward();
    }

    pub fn getBarrelTip(self: *Self, barrel_length: f32) Vec3 {
        const forward = self.barrel_node.getForward();
        const barrel_pos = self.barrel_node.getWorldPosition();
        return barrel_pos.add(&forward.mulScalar(barrel_length));
    }

    fn angleWrap(angle: f32) f32 {
        var result = angle;
        while (result > std.math.pi) result -= 2.0 * std.math.pi;
        while (result < -std.math.pi) result += 2.0 * std.math.pi;
        return result;
    }
};
```

**Acceptance Criteria**:
- [ ] TurretController with yaw/pitch tracking
- [ ] Smooth rotation with speed limits
- [ ] Pitch angle constraints working
- [ ] Helper methods: `isOnTarget()`, `getAimDirection()`, `getBarrelTip()`
- [ ] Code formatted with `zig fmt`

---

### Phase 4: Turret Scene Object

**File**: `turrets/turret.zig`

**Task**: Create self-contained turret object that owns shader and manages rendering

```zig
const std = @import("std");
const core = @import("core");
const math = @import("math");
const nodes = @import("../nodes.zig");
const turret_controller = @import("turret_controller.zig");
const Lights = @import("../scene/lights.zig").Lights;

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const Mat4 = math.Mat4;
const Shader = core.Shader;
const Texture = core.texture.Texture;
const Shape = core.shapes.Shape;
const Node = nodes.Node;
const TurretController = turret_controller.TurretController;

// Helper for shapes with textures (following bullets pattern)
const ShapeWithTexture = struct {
    shape: *Shape,
    texture: *Texture,

    pub fn draw(self: *ShapeWithTexture, shader: *Shader) void {
        shader.bindTextureAuto("texture_diffuse", self.texture.gl_texture_id);
        self.shape.draw(shader);
    }

    pub fn getBoundingBox(self: *ShapeWithTexture) core.AABB {
        return self.shape.aabb;
    }
};

pub const TurretConfig = struct {
    position: Vec3,
    yaw_speed: f32 = 90.0,
    pitch_speed: f32 = 60.0,
    pitch_limits: [2]f32 = .{ -10.0, 80.0 },
    barrel_length: f32 = 2.0,
};

pub const Turret = struct {
    // Node hierarchy
    base_node: *Node,
    body_node: *Node,
    barrel_node: *Node,

    // Rendering (OWNS shader - no crosstalk!)
    shader: *Shader,
    base_shape_obj: ShapeWithTexture,
    body_shape_obj: ShapeWithTexture,
    barrel_shape_obj: ShapeWithTexture,

    // Logic
    controller: TurretController,
    config: TurretConfig,

    const Self = @This();

    pub fn init(
        allocator: Allocator,
        node_manager: *nodes.NodeManager,
        config: TurretConfig,
        base_shape: *Shape,
        body_shape: *Shape,
        barrel_shape: *Shape,
        texture: *Texture,
    ) !Self {
        // Create shader for this turret (owns it!)
        const turret_shader = try Shader.init(
            allocator,
            "games/level_01/shaders/basic_model.vert",
            "games/level_01/shaders/basic_model.frag",
        );

        turret_shader.setBool("hasTexture", true);

        // Create node hierarchy
        var empty = EmptyObject{};
        const base_node = try node_manager.create("turret_base", &empty);
        base_node.setTranslation(config.position);

        var body_obj = ShapeWithTexture{ .shape = body_shape, .texture = texture };
        const body_node = try Node.init(allocator, "turret_body", &body_obj);
        try base_node.addChild(body_node);
        body_node.setTranslation(vec3(0.0, 0.5, 0.0));

        var barrel_obj = ShapeWithTexture{ .shape = barrel_shape, .texture = texture };
        const barrel_node = try Node.init(allocator, "gun_barrel", &barrel_obj);
        try body_node.addChild(barrel_node);
        barrel_node.setTranslation(vec3(0.0, 0.3, 0.0));

        // Create controller
        var controller = TurretController.init(body_node, barrel_node);
        controller.yaw_speed = config.yaw_speed;
        controller.pitch_speed = config.pitch_speed;
        controller.pitch_limits = config.pitch_limits;

        return .{
            .base_node = base_node,
            .body_node = body_node,
            .barrel_node = barrel_node,
            .shader = turret_shader,
            .base_shape_obj = .{ .shape = base_shape, .texture = texture },
            .body_shape_obj = body_obj,
            .barrel_shape_obj = barrel_obj,
            .controller = controller,
            .config = config,
        };
    }

    pub fn update(self: *Self, delta_time: f32) void {
        self.controller.update(delta_time);
    }

    pub fn updateLights(self: *Self, lights: Lights) void {
        self.shader.setVec3("ambientColor", &lights.ambient_color);
        self.shader.setVec3("lightColor", &lights.light_color);
        self.shader.setVec3("lightDirection", &lights.light_direction);
    }

    pub fn draw(self: *Self, projection: *const Mat4, view: *const Mat4) void {
        self.shader.setMat4("matProjection", projection);
        self.shader.setMat4("matView", view);

        // Draw base
        const base_mat = self.base_node.global_transform.toMatrix();
        self.shader.setMat4("matModel", &base_mat);
        self.base_shape_obj.draw(self.shader);

        // Draw body
        const body_mat = self.body_node.global_transform.toMatrix();
        self.shader.setMat4("matModel", &body_mat);
        self.body_shape_obj.draw(self.shader);

        // Draw barrel
        const barrel_mat = self.barrel_node.global_transform.toMatrix();
        self.shader.setMat4("matModel", &barrel_mat);
        self.barrel_shape_obj.draw(self.shader);
    }

    pub fn setTarget(self: *Self, target: ?Vec3) void {
        self.controller.setTarget(target);
    }

    pub fn isOnTarget(self: *Self, tolerance: f32) bool {
        return self.controller.isOnTarget(tolerance);
    }

    pub fn getAimDirection(self: *Self) Vec3 {
        return self.controller.getAimDirection();
    }

    pub fn getBarrelTip(self: *Self) Vec3 {
        return self.controller.getBarrelTip(self.config.barrel_length);
    }
};

const EmptyObject = struct {
    pub fn draw(self: *EmptyObject, shader: *Shader) void {
        _ = self;
        _ = shader;
    }
};
```

**Acceptance Criteria**:
- [ ] Turret object owns its shader
- [ ] Turret manages node hierarchy internally
- [ ] Clean `draw(projection, view)` interface
- [ ] Controller integrated
- [ ] Code formatted with `zig fmt`

---

### Phase 5: Scene Composition

**File**: `scene/scene.zig`

**Task**: Create scene that composes turrets and other objects

```zig
const std = @import("std");
const core = @import("core");
const math = @import("math");

const Turret = @import("../turrets/turret.zig").Turret;
const TurretConfig = @import("../turrets/turret.zig").TurretConfig;
const Lights = @import("lights.zig").Lights;
const basic_lights = @import("lights.zig").basic_lights;

const Vec3 = math.Vec3;
const vec3 = math.vec3;
const Mat4 = math.Mat4;
const Camera = core.Camera;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const Scene = struct {
    camera: *Camera,
    turrets: std.ArrayList(Turret),
    target_position: Vec3,

    const Self = @This();

    pub fn init(
        arena: *ArenaAllocator,
        node_manager: anytype,
        scr_width: f32,
        scr_height: f32,
    ) !Self {
        const allocator = arena.allocator();

        const camera = try Camera.init(allocator, .{
            .position = vec3(0.0, 10.0, 20.0),
            .target = vec3(0.0, 2.0, 0.0),
            .scr_width = scr_width,
            .scr_height = scr_height,
        });

        var turrets = std.ArrayList(Turret).init(allocator);

        // Create turrets will be added here

        return .{
            .camera = camera,
            .turrets = turrets,
            .target_position = vec3(5.0, 2.0, 5.0),
        };
    }

    pub fn addTurret(self: *Self, turret: Turret) !void {
        try self.turrets.append(turret);
    }

    pub fn update(self: *Self, delta_time: f32) void {
        for (self.turrets.items) |*turret| {
            turret.update(delta_time);
        }
    }

    pub fn drawTurrets(self: *Self, projection: *const Mat4, view: *const Mat4) void {
        for (self.turrets.items) |*turret| {
            turret.draw(projection, view);
        }
    }

    pub fn setTargetForAllTurrets(self: *Self, target: Vec3) void {
        self.target_position = target;
        for (self.turrets.items) |*turret| {
            turret.setTarget(target);
        }
    }
};
```

**Acceptance Criteria**:
- [ ] Scene composes turrets and camera
- [ ] Clean API following bullets pattern
- [ ] Easy to add/remove turrets
- [ ] Code formatted with `zig fmt`

---

### Phase 6: Clean run_app Integration

**File**: `games/level_01/run_app.zig`

**Task**: Update run_app to use scene composition (following bullets pattern)

**Key Changes**:
1. Create scene at startup
2. Update scene in game loop
3. Draw scene components
4. Minimal logic in run_app - delegate to scene

```zig
// In run() function, after creating node_manager:

const Scene = @import("scene/scene.zig").Scene;

var scene = try Scene.init(&arena, node_manager, scaled_width, scaled_height);

// Create shapes for turrets
var cylinder = try shapes.createCylinder(allocator, 1.0, 2.0, 20.0);
var cuboid = try shapes.createCube(.{ .width = 1.5, .height = 1.0, .depth = 1.0 });
var barrel = try shapes.createCylinder(allocator, 0.3, 2.0, 12.0);

// Create turrets
const turret1 = try Turret.init(
    allocator,
    node_manager,
    .{ .position = vec3(-5.0, 0.0, -5.0) },
    &cylinder,
    &cuboid,
    &barrel,
    cube_texture,
);
try scene.addTurret(turret1);

const turret2 = try Turret.init(
    allocator,
    node_manager,
    .{ .position = vec3(5.0, 0.0, -5.0) },
    &cylinder,
    &cuboid,
    &barrel,
    cube_texture,
);
try scene.addTurret(turret2);

// Set target for all turrets
scene.setTargetForAllTurrets(vec3(0.0, 2.0, 5.0));

// In game loop:
scene.update(state.delta_time);

const projection = camera.getProjection();
const view = camera.getView();

scene.drawTurrets(&projection, &view);
```

**Acceptance Criteria**:
- [ ] run_app.zig is clean and minimal
- [ ] Scene manages all complexity
- [ ] Easy to add more turrets
- [ ] Follows bullets pattern exactly
- [ ] Code formatted with `zig fmt`

---

### Phase 7: Advanced Features (Optional)

**File**: `turrets/turret_types.zig`

**Task**: Create different turret configurations

```zig
pub const TurretType = enum {
    basic,
    fast,
    heavy,
    sniper,
};

pub fn getConfig(turret_type: TurretType) TurretConfig {
    return switch (turret_type) {
        .basic => .{
            .position = vec3(0, 0, 0),
            .yaw_speed = 90.0,
            .pitch_speed = 60.0,
            .pitch_limits = .{ -10.0, 80.0 },
        },
        .fast => .{
            .position = vec3(0, 0, 0),
            .yaw_speed = 180.0,
            .pitch_speed = 120.0,
            .pitch_limits = .{ 0.0, 85.0 },
        },
        .heavy => .{
            .position = vec3(0, 0, 0),
            .yaw_speed = 45.0,
            .pitch_speed = 30.0,
            .pitch_limits = .{ -5.0, 60.0 },
        },
        .sniper => .{
            .position = vec3(0, 0, 0),
            .yaw_speed = 60.0,
            .pitch_speed = 45.0,
            .pitch_limits = .{ 10.0, 85.0 },
        },
    };
}
```

**Acceptance Criteria**:
- [ ] Multiple turret types defined
- [ ] Easy to add new types
- [ ] Configs clearly show differences
- [ ] Code formatted with `zig fmt`

---

## File Organization Summary

### Final Structure
```
games/level_01/
├── turrets/
│   ├── turret.zig              # Scene object (owns shader)
│   ├── turret_controller.zig  # Pure logic component
│   ├── turret_types.zig       # Configurations
│   └── README.md              # Documentation
├── scene/
│   ├── scene.zig              # Composition
│   ├── lights.zig             # Shared lighting
│   ├── ground.zig             # Ground object (future)
│   └── target.zig             # Target object (future)
├── shaders/
│   ├── turret.vert
│   ├── turret.frag
│   ├── basic_model.vert
│   └── basic_model.frag
├── run_app.zig               # Clean orchestration
├── nodes.zig                 # Node system
└── state.zig                 # Game state
```

### Key Patterns from bullets

1. **One File Per Object**: `cube.zig`, `floor.zig` → `turret.zig`, `ground.zig`
2. **Object Owns Shader**: Prevents crosstalk, self-contained rendering
3. **Scene Composition**: `scene.zig` composes all objects
4. **Clean draw() API**: `object.draw(projection, view)` handles everything
5. **Minimal run_app**: Just loop and scene method calls
6. **Directory Organization**: Related files grouped (`scene/`, `turrets/`, `shaders/`)

## Benefits of This Approach

### 1. No Shader Crosstalk
Each turret owns its shader instance, preventing state bleeding between objects.

### 2. Easy to Extend
Adding a new turret type:
1. Define config in `turret_types.zig`
2. Instantiate in scene
Done!

### 3. Clean Separation
- **turrets/**: All turret-related code
- **scene/**: Scene composition
- **run_app.zig**: Just orchestration

### 4. Testable
Each component can be tested independently:
- TurretController: Pure logic, easy to test
- Turret: Scene object with mocked nodes
- Scene: Composition testing

### 5. Reusable Pattern
Same pattern applies to:
- Enemies
- Projectiles
- Power-ups
- Environmental objects

## Testing Strategy

### Unit Tests
- TurretController tracking accuracy
- Angle wrapping and clamping
- Speed limit enforcement

### Integration Tests
- Turret with node hierarchy
- Multiple turrets tracking same target
- Scene composition and updates

### Visual Tests
- Turrets smoothly track target
- Pitch limits visually correct
- Multiple turrets independent
- No gimbal lock or jitter

## Success Criteria

1. **Organization**: Follows bullets pattern exactly
2. **No Crosstalk**: Each turret has independent shader state
3. **Clean API**: run_app is minimal and readable
4. **Extensible**: Easy to add new turret types
5. **Documented**: README explains pattern and usage

## Future Enhancements

1. **More Scene Objects**: Ground, targets, projectiles
2. **Turret States**: Idle, tracking, firing, reloading
3. **Visual Effects**: Muzzle flash, tracer rounds
4. **Audio**: Turret rotation sounds, firing sounds
5. **Turret Manager**: Centralized turret coordination

## References

- **Pattern Source**: `examples/bullets/` - excellent organization
- **Scene Object Example**: `examples/bullets/scene/cube.zig`
- **Scene Composition**: `examples/bullets/scene/scene.zig`
- **Clean run_app**: `examples/bullets/run_app.zig`
- **Current Node System**: `games/level_01/nodes.zig`

## Notes

- This plan prioritizes clean organization over quick implementation
- Following established patterns makes code easier to understand
- Each turret owning its shader eliminates entire class of bugs
- Directory structure mirrors bullets for consistency
- Pattern is proven and extensible

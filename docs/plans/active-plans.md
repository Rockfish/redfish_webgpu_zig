# Active Plans

How these files work, including parking and resuming plans: [README.md](README.md).

## 🔄 Active

- **[016-motion-patterns.md](016-motion-patterns.md)**: time-based, goal-seeking motion
  (`src/core/motion.zig`): `dampAlpha`, `moveToward`, `SmoothFollow`, damped look-at.
  - Scope now: phases 1-2. First users: level_01 click-to-move, angrybot's follow camera.

## ⏸️ Parked

- **[012-animation-fsm.md](012-animation-fsm.md)**: phases 1-2 implemented
  (`animation_fsm.zig`, bullets). Next: the crossfade-interrupt fix, then a blend-space
  state tried on angrybot's locomotion (review notes 2026-09-28).
- **[005-scene-management.md](005-scene-management.md)**: discussed 2026-09-28 (union vs.
  dispatch, why Godot has node types). Next: a core transform hierarchy and a shared
  dispatch helper; a full scene system waits for a second game.
- **[004-animation-state-machine.md](004-animation-state-machine.md)**: partly superseded by
  006 and 012; review the remaining tasks before resuming.
- **[009-gravity-bullet-system.md](009-gravity-bullet-system.md)**: phase 1 in bullets;
  phase 2 planned.
- **[008-turret-controller-system.md](008-turret-controller-system.md)**: planning; nearest
  code is bullets' `cannon.zig`.
- **[010-input-handling-architecture.md](010-input-handling-architecture.md)**: design
  discussion.

## ✅ Completed

- **[000-webgpu-port.md](000-webgpu-port.md)**: port of redfish_gl_zig to WebGPU
  (wgpu-native), 2026-09-27. Known issues resolved or out of scope 2026-09-28.

  | Step | Description | Status |
  |---|---|---|
  | 0 | Project setup | ✅ 2026-09-27 |
  | 1 | Skeleton: window, device, clear, zgui | ✅ 2026-09-27 |
  | 2 | Math: zero-to-one depth | ✅ 2026-09-27 |
  | 3a | One colored cube: shaders, bindings, pipelines, per-draw data | ✅ 2026-09-27 |
  | 3b | Textures and all shapes, scene_tree | ✅ 2026-09-27 |
  | 4 | glTF static meshes with PBR | ✅ 2026-09-27 |
  | 5 | Skinning and animation | ✅ 2026-09-27 |
  | 6 | bullets | ✅ 2026-09-27 |
  | 7 | level_01 | ✅ 2026-09-27 |
  | 8 | demo_app complete | ✅ 2026-09-27 |
  | 9 | angrybot and remaining examples | ✅ 2026-09-27 |

- Completed in redfish_gl_zig and carried over by the port:
  [001](001-glb-support.md) GLB support,
  [002](002-demo-application.md) demo application,
  [003](003-shader-improvements.md) PBR shaders,
  [006](006-multi-animation-support.md) multi-animation (phase 1),
  [007](007-movement-transform-refactor.md) movement / transform refactor,
  [011](011-scene-memory-management.md) scene memory (arenas),
  [013](013-lighting.md) lighting,
  [014](014-render-context.md) render context,
  [015](015-resource-manager.md) resource manager (factory form).

## Session Notes

**2026-09-28**: Imported plans 001-016, `backlog.md`, the notes files, and the movement
reviews from redfish_gl_zig; statuses reconciled with this repo (a note under each plan's
title). Plan 016 made active (phases 1-2). Review notes added to 012 and 005. Older
session notes stay in redfish_gl_zig's `active-plans.md`.

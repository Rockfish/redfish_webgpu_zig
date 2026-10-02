# Active Plans

How these files work, including parking and resuming plans: [README.md](README.md).

## 🔄 Active

- **[010-input-handling-architecture.md](010-input-handling-architecture.md)**: input
  modes and one-shot keys; reviewed against bullets 2026-10-01.
  - Phase 1 done 2026-10-01: `Input.isDown` / `pressedOnce`, mouse, scroll, and modifier
    fixes, Escape moved to the apps; bullets debug scene split into mode and global keys.
    Next: phase 2, `core.Input` alongside ImGui.

## ⏸️ Parked

- **[012-animation-fsm.md](012-animation-fsm.md)**: phases 1-2 implemented
  (`animation_fsm.zig`, bullets). Next: the crossfade-interrupt fix, then a blend-space
  state tried on angrybot's locomotion (review notes 2026-09-28).
- **[005-scene-management.md](005-scene-management.md)**: discussed 2026-09-28 (union vs.
  dispatch, why Godot has node types). Next: a core transform hierarchy and a shared
  dispatch helper; a full scene system waits for a second game.
- **[004-animation-state-machine.md](004-animation-state-machine.md)**: partly superseded by
  006 and 012; review the remaining tasks before resuming.

## ✅ Completed

- **[009-gravity-bullet-system.md](009-gravity-bullet-system.md)**: 2026-10-01. Phase 2
  through `core.ballistics` (`step`, `positionAt`); bullets example: G gravity, P
  predicted paths.
- **[008-turret-controller-system.md](008-turret-controller-system.md)**: 2026-10-01.
  `core.motion` (`YawPitchAim`, angle helpers, `Sweep`), `core.FireControl` and
  `ShotJitter`, `core.ballistics` (`leadPoint`, `launchVelocity`, `positionAt`, `step`);
  `examples/turrets`: track, sweep, mortar (finned rockets, explosions), programs, turret
  types, a ball turret. Open: game integration.
- **[016-motion-patterns.md](016-motion-patterns.md)**: 2026-09-30. `core.motion`
  (`dampAlpha`, `moveToward`, `SmoothFollow`, `dampLookAt`, `PathFollow`, `Shake`);
  `CameraGimbal` revived (tilted or level mount) with `examples/camera_rig`.
- **[018-anti-aliasing.md](018-anti-aliasing.md)**: 2026-09-29. 4x MSAA in every app
  (`-Dmsaa`, default on), angrybot's render targets included; alpha-to-coverage for glTF
  MASK materials in pbr.wgsl.
- **[017-shadows.md](017-shadows.md)**: 2026-09-29. `examples/shadows` (debug views,
  bias, filter, and PCF controls), `DepthBias`, the `ShadowMap` filter option (both in
  angrybot), and `ShadowMapArray` for several lights. Phase 4 (unclipped depth) left
  until a scene needs it.
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
session notes stay in redfish_gl_zig's `active-plans.md`. Plan 016 phases 1-2 done:
`core.motion`, used by level_01 and angrybot; `Quat.lookAtOrientation` fixed.

**2026-09-29**: Reviewed the Rust wgpu projects
(`docs/reviews/2026-09-29-rust-wgpu-projects-review.md`). Plan 017 (shadows) drafted and
made active; 016 parked after phases 1-2.
Plan 017 finished (phases 1-3); angrybot's emission pass fixed (occluders drawn first).
Plan 018 (anti-aliasing) drafted and finished: MSAA, angrybot's render targets, alpha-to-coverage.
Plan 016 resumed: phase 3 (`PathFollow`) done.

**2026-09-30**: Plan 016 finished: `Shake`, `CameraGimbal` revived, `examples/camera_rig`.

**2026-10-01**: Plan 008 active; phases 1 (two-axis aim), 2 (turret test bed, fire
control, `track`), 3 (`sweep`), 4 (mortar), and 5 (programs, types, ball turret) done;
plan finished. Plan 009 finished with `core.ballistics` in the bullets example.

**2026-10-01 (later)**: Plan 010 reviewed against bullets and made active; phase 1 done.

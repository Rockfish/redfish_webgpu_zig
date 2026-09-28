# Unified Lighting System — Plan 013

> Imported from redfish_gl_zig on 2026-09-28. **In this repo:** Implemented in redfish_gl_zig; ported as `SceneLights` in group 0 (Step 6).
> File and API references in the body are to redfish_gl_zig (OpenGL) unless noted.

## Status: Implemented

## Context

The bullets example had broken lighting — the Zig code set uniform names (`"ambientColor"`, `"lightColor"`, `"lightDirection"`) that didn't match the GLSL shader (`"directionLight.dir"`, `"directionLight.color"`, `"ambient"`). All uniform sets silently failed. Meanwhile, angrybot had working lighting using GLSL struct uniforms (`DirectionLight`, `PointLight`) with dot-notation names.

This plan standardized on the angrybot pattern, created a reusable `SceneLights` type in `src/core/`, and used the bullets example as testbed. The design supports future expansion to multiple point lights (gun flashes, explosions) for tower defense gameplay.

## What Was Done

### 1. `src/core/lights.zig` — Core lighting module (NEW)

Engine-canonical lighting types:

- `DirectionLight` — dir + color
- `PointLight` — worldPos, color, constant/linear/quadratic attenuation, enabled flag
- `SceneLights` — ambient, useLight, direction light, up to 4 point lights
  - `init()` — sensible defaults (white light, 0.2 ambient)
  - `towerDefenseDefaults()` — warm sun, cool blue-grey ambient preset
  - `setPointLight(index, light)` — set a point light slot, auto-tracks count
  - `apply(shader)` — pushes all uniforms to any shader; missing uniforms silently skipped

Uses a single reusable `bufPrintZ` buffer for point light array uniform names (safe because `Shader.getUniformLocation` dupes the key).

### 2. `src/core/root.zig` — Exports added

Exports `lights`, `SceneLights`, `PointLight`, `DirectionLight`.

### 3. `src/core/constants.zig` — Standardized uniform constants

Added alongside existing legacy names:
- `Ambient = "ambient"`
- `Use_Light = "useLight"`
- `Direction_Light_Dir = "directionLight.dir"`
- `Direction_Light_Color = "directionLight.color"`
- `Num_Point_Lights = "numPointLights"`

Legacy `Ambient_Color`, `Light_Color`, `Light_Direction` kept (used by `animated_pbr` shaders).

### 4. `examples/bullets/shaders/basic_texture.frag` — Point lights + specular map

- Added `PointLight` struct and accumulation loop with distance attenuation
- Enabled `textureSpec` sampler — specular map modulates highlight intensity (`lighting += lighting * spec * 0.3`)

### 5. `examples/bullets/shaders/basic_model.frag` — Rewritten lighting

- `DirectionLight` and `PointLight` structs with `useLight` toggle
- Direction light diffuse + ambient
- Point lights: normal-only contribution (no `fragWorldPos` from vertex shader)

### 6. `examples/bullets/scene/lights.zig` — Re-export shim

Replaced old `Lights` struct with re-export of `core.SceneLights`. `basic_lights` is now `towerDefenseDefaults()`.

### 7-10. Scene files — Simplified `updateLights`

`floor.zig`, `cube.zig`, `spacesuit.zig`, `toon_soldier.zig` all now call `lights.apply(self.shader)` instead of manually setting individual uniforms.

### 11. `examples/bullets/debug_scene.zig` — Uses shared lights

Removed local `basic_lights` definition; imports from `scene/lights.zig`.

### 12. `src/core/shapes/plane.zig` — Texture rename

Renamed `spectal_texture` to `specular_texture` in `PlaneConfig` (fixed legacy typo, consistent with Phong-style shader usage).

## Naming Convention: Specular vs Metallic

The floor textures are `Floor D.png` (diffuse), `Floor N.png` (normal), `Floor M.png` (metallic/roughness from PBR asset pack). In the current Phong-style shaders, this texture functions as a **specular intensity map**, so it's called `specular_texture` / `textureSpec` throughout. If the engine moves to PBR shaders, rename to `metallic_texture` / `textureMetallic` when it actually drives a metallic-roughness BRDF.

## Tower Defense Default Values

- **Ambient**: `vec3(0.12, 0.14, 0.18)` — cool blue-grey, suggests overcast/twilight
- **Direction light dir**: `vec3(-1.5, -2.0, -1.0)` — upper-left sun (normalized in shader)
- **Direction light color**: `vec3(0.95, 0.88, 0.72)` — warm sunlight
- **Point light defaults**: `constant=1.0, linear=0.5, quadratic=3.0` — tight falloff for explosions/flashes

## Future Considerations

### `viewPos` uniform for proper specular highlights
The `basic_texture.frag` shader currently approximates specular contribution by scaling lighting with the specular map. Adding a `viewPos` (camera world position) uniform would enable proper Blinn-Phong specular reflections with view-dependent highlights, matching angrybot's `floor_shader.frag` pattern. This requires:
- Adding `viewPos` to `SceneLights.apply()` or passing it separately
- Using `reflect()` / `pow()` for specular term in the shader

### Shadow mapping
Angrybot's floor shader has full shadow mapping (`shadow_map` sampler, `fragPosLightSpace`, PCF filtering). The bullets `basic_texture.vert` already outputs `fragLightSpacePosition` — plumbing in a shadow pass would complete the angrybot-parity lighting.

### Migrate angrybot to `SceneLights`
Angrybot currently manages its own light uniforms directly. Migrating it to use `SceneLights.apply()` would unify the lighting code across all projects. Its shaders use slightly different uniform names (`texture_diffuse` vs `textureDiffuse`) so this would need shader alignment or a naming adapter.

### `basic_model.frag` world position
The instanced bullet model shader lacks `fragWorldPos`, so point lights use normal-only contribution without distance attenuation. Adding a world position output from `basic_model.vert` would enable proper point light falloff on bullets (visible as muzzle flash illumination).

### PBR shader migration
When ready to move beyond Phong, the specular map and lighting pipeline would be replaced with a Cook-Torrance BRDF using metallic-roughness textures. The `SceneLights` type and `apply()` pattern would remain — only the shader-side calculations change.

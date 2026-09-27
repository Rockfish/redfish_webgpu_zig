# Changelog

## Recent Changes

### 2026-09-27 - Project Setup (Port Step 0)
- **Purpose**: Port redfish_gl_zig from OpenGL 4.1 to WebGPU via zig-gamedev `zgpu` (Dawn), keeping its structure and changing only the graphics API
- **Docs**: `docs/STYLE.md` style guide, `docs/plans/000-webgpu-port.md` port plan, `docs/plans/active-plans.md`, `CLAUDE.md`
- **Decisions**: zgpu `GraphicsContext`; bind groups 0 frame / 1 material / 2 object / 3 pass; per-draw data via `uniformsAllocate`; storage buffers for joints; runtime-loaded WGSL with generated shared constants; 0..1 depth; sRGB; `zaudio` for audio; URL packages instead of vendored libs
- **Assets**: `assets/` symlinks to redfish_gl_zig's `assets/`
- **License**: MIT

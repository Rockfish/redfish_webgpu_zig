# Changelog

## Recent Changes

### 2026-09-27 - Port Plan Review
- **Scene target**: zgpu's swapchain is fixed at `bgra8_unorm`, so scenes render linear into a `GpuContext`-owned `rgba16float` + `Depth32Float` target; a present pass encodes sRGB and draws zgui
- **Mipmaps**: own render-pass generator in `texture.zig`; zgpu's `generateMipmaps` is square/power-of-two/≤ 2048 and can't write sRGB
- **zgpu pool sizes** set in `build.zig` from Step 1
- **Other**: group 0 is a persistent per-frame buffer; zaudio moves to Step 6; Step 2 audits screen-Y assumptions; `zopengl` left out
- **Risk noted**: zgpu's prebuilt Dawn is frozen (~2023); wgpu-native listed as a post-port option

### 2026-09-27 - Project Setup (Port Step 0)
- **Purpose**: Port redfish_gl_zig from OpenGL 4.1 to WebGPU via zig-gamedev `zgpu` (Dawn), keeping its structure and changing only the graphics API
- **Docs**: `docs/STYLE.md` style guide, `docs/plans/000-webgpu-port.md` port plan, `docs/plans/active-plans.md`, `CLAUDE.md`
- **Decisions**: zgpu `GraphicsContext`; bind groups 0 frame / 1 material / 2 object / 3 pass; per-draw data via `uniformsAllocate`; storage buffers for joints; runtime-loaded WGSL with generated shared constants; 0..1 depth; sRGB; `zaudio` for audio; URL packages instead of vendored libs
- **Assets**: `assets/` symlinks to redfish_gl_zig's `assets/`
- **License**: MIT

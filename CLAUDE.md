# redfish_webgpu_zig

A port of redfish_gl_zig (`/Users/john/Dev/Dev_Zig/redfish_gl_zig`) from OpenGL 4.1 to WebGPU,
using **wgpu-native** through a build-translated `webgpu.h`. A 3D engine for animated glTF models with PBR rendering.
Hobby project; readability for a returning reader matters more than cleverness.

## Read First

- **`docs/STYLE.md`**: the style guide. All code follows it; where existing code disagrees,
  the guide wins.
- **`docs/plans/000-webgpu-port.md`**: the port plan. Work one step at a time, in order.
- **`docs/plans/active-plans.md`**: which step is current.

## The Port in One Paragraph

Keep redfish_gl_zig's shape: same directories, files, type names, and call shapes. Only the
graphics API changes, plus the fixes needed to do it correctly. Correctness beats fidelity to
the GL code: establish the right WebGPU pattern even if it looks different from GL. When
porting a file, open the redfish_gl_zig version side by side and keep it recognizable.

## Status

Step 1 done: window, device, sRGB clear, and zgui on wgpu-native (`gpu_caps`); carry-over
modules in. See `docs/plans/active-plans.md`.

## Layout (target, mirrors redfish_gl_zig)

```
src/
├── core/         # Engine: gpu_context, shader, mesh, model, texture, animation, shapes, ...
│   └── wgpu/     # webgpu.h translated by the build, string-view helpers, Metal layer
├── math/         # Vec/Mat/Quat, column-major
└── containers/
examples/         # gpu_caps, scene_tree, demo_app, animation_example, bullets, skybox
games/            # level_01, angrybot (regression reference)
assets/           # symlink to ../redfish_gl_zig/assets
docs/
├── STYLE.md
├── plans/        # Numbered plans + active-plans.md
├── designs/      # Design notes
└── reviews/      # Reviews and decision records
```

## Reference Projects

- **redfish_gl_zig**: structure, names, behavior. Zig 0.16 idioms (`pub fn main(init: std.process.Init)`, `init.io`, `init.gpa`).
- **wgpu-native** (`gfx-rs/wgpu-native`): API reference is its `webgpu.h` / `wgpu.h`
  (fetched into `zig-pkg/`, and the translated Zig in `.zig-cache`).
- **gui_test_webgpu** (`/Users/john/Dev/Dev_Zig/gui_test_webgpu`): source of the zglfw and zgui
  pins. Its zgpu/Dawn setup is not used (see `docs/reviews/2026-09-27-wgpu-native-spike.md`).
- **small_wgpu_core**, **angry_wgpu_rust** (`/Users/john/Dev/Dev_Rust/`): earlier work on the same
  wgpu. Reuse lessons, not the bind group layout (it needs 7 groups; WebGPU defaults allow 4).

## Key WebGPU Rules (details in STYLE.md section 9)

- Raw WebGPU calls only in `src/core`; C API used as translated (`const c = wgpu.c;`)
- Bind groups: 0 frame, 1 material, 2 object/draw, 3 pass-specific
- Never rewrite a buffer between draws expecting per-draw values; use `uniform_ring.zig`
  with dynamic offsets
- Pipelines created at init; render state is pipeline state
- Depth 0..1, sRGB surface and color textures, texture origin top-left
- Translated descriptors default every field to zero; set the ones where zero is wrong
  (`depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED`)
- Mipmaps from our render-pass generator in `texture.zig` (WebGPU has none)
- Request needed limits in `requiredLimits`; otherwise the device gets WebGPU defaults
- GPU cleanup: `releaseGpuObjects()` on leaves, `cleanUp()` on aggregates, before arena reset

## Build

Zig 0.16.0 (`~/zig/zig-aarch64-macos-0.16.0`). `zig build <app>` and `zig build <app>-run`,
as in redfish_gl_zig (e.g. `zig build gpu_caps-run`). wgpu-native is listed for macOS arm64
only; add a lazy package per platform in `build.zig.zon` and `wgpuNativeDependency`.

### macOS Toolchain Note (Xcode 27 / Zig 0.16)
- The macOS 27 SDK `math.h` defers `INFINITY` to `<float.h>` via `__need_infinity_nan`
  (LLVM 22 behavior); Zig 0.16's LLVM 21 `float.h` ignores it, so libc++ sub-compilation
  fails with `use of undeclared identifier 'INFINITY'` (real error is at the top of the log)
- **Fix**: `~/zig/<version>/lib/include/float.h` is patched to handle `__need_infinity_nan`
  (original kept as `float.h.orig`). Re-apply after any Zig upgrade until Zig ships LLVM 22 headers
- Zig ignores `SDKROOT`; it always uses `xcrun --sdk macosx --show-sdk-path`
- After an Xcode update, run `sudo xcodebuild -license accept` and open a fresh terminal

## Working Rules

- **Never add signatures or attribution lines to commit messages**
- Run `zig fmt` on every edited `.zig` file, and only on `.zig` files; never on dependency code
- Every print/log call takes an args tuple, even `.{}`
- Delete dead code; don't comment it out
- Zig lazy analysis skips unreferenced functions: "it builds" proves nothing about uncalled code.
  `zig build test` runs `tests/analyze_all.zig`, which forces analysis of all public decls in
  math, containers, and core; run it after every change. A module root (or namespace root like
  `utils/root.zig`) needs `test { std.testing.refAllDecls(@This()); }` for its files' tests to run
- Each plan step ends with a `CHANGELOG.md` entry and a commit

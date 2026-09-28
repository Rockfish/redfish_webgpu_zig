# glTF

The engine's own glTF 2.0 loader: parsing, the data types, and a report tool. Loading
into GPU resources (meshes, materials, textures) is in `../gltf_asset.zig`.

## Files

- `gltf.zig`: the glTF data types (scenes, nodes, meshes, accessors, materials, textures,
  samplers, skins, animations), close to the specification's JSON.
- `parser.zig`: `parseGltfJson` turns the JSON into those types.
- `report.zig`: `GltfReport` describes what a loaded file contains.

## Loading

`GltfAsset` reads `.gltf` (JSON with external or embedded `data:` buffers) and `.glb`
(binary with a JSON and a BIN chunk). `load` parses the file, reads the buffers, loads the
textures, and builds the meshes; `buildModel` adds an animator.

```zig
const core = @import("core");
const GltfAsset = core.gltf_asset.GltfAsset;

var gltf_asset = try GltfAsset.init(context, gpu, "Fox", "assets_nas/glTF-Sample-Models/2.0/Fox/glTF/Fox.gltf");
try gltf_asset.load();
const model = try gltf_asset.buildModel();
defer model.cleanUp();
```

Before `load`, an asset can be configured:

- `addCustomTexture(mesh_name, uniform_name, path, config)`: use a texture file for a
  material slot (e.g. `"texture_diffuse"` for base color), for models converted without
  their textures.
- `skipModelTextures()`: don't load the file's textures.
- `useGammaSpaceTextures()`: load color maps without sRGB decoding, for apps that light in
  gamma space (angrybot).
- `setNormalGenerationMode(mode)`: generate normals for primitives without them.

Not supported: sparse accessors and glTF extensions.

## Report

```zig
const GltfReport = core.gltf_report.GltfReport;

// Scenes and node hierarchy, meshes, accessors, animations, materials, textures
GltfReport.printReport(allocator, gltf_asset);
try GltfReport.writeReportToFile(io, allocator, gltf_asset, "model_report.md");

// Adds animation keyframes and skin joints, up to the given counts per channel / skin
try GltfReport.writeDetailedReportToFile(io, allocator, gltf_asset, "model_report.md", 5, 5);

// Or as a string (caller frees)
const report = try GltfReport.generateReport(allocator, gltf_asset);
defer allocator.free(report);
```

`examples/animation_example` writes a detailed report when its `DUMP_REPORT` constant is
set.

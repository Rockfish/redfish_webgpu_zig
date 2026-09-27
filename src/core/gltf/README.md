# glTF Report Tool

This module provides comprehensive glTF file inspection and reporting functionality.

## Features

- **Scene Analysis**: Node hierarchies, root nodes, children relationships
- **Mesh Details**: Primitives, attributes (position, normal, texcoord, etc.), materials
- **Accessor Information**: Data types, component types, counts, buffer views
- **Animation Data**: Channels, samplers, targets, paths
- **Material Properties**: PBR metallic roughness, textures, factors
- **Texture Information**: Image sources, samplers

## Usage

```zig
const core = @import("core");
const GltfAsset = core.asset_loader.GltfAsset;
const GltfReport = core.gltf_report.GltfReport;

// Load a glTF asset
var gltf_asset = try GltfAsset.init(allocator, "model_name", "path/to/model.gltf");
try gltf_asset.load();

// Print report to console
GltfReport.printReport(&gltf_asset);

// Generate report as string
const report = try GltfReport.generateReport(allocator, &gltf_asset);
defer allocator.free(report);

// Write report to file
try GltfReport.writeReportToFile(allocator, &gltf_asset, "report.txt");
```

## Test Program

See `examples/demo_app/test_report.zig` for a complete example of using the report functionality.

## Integration

The report module is integrated into the core module and can be imported as:
```zig
const gltf_report = @import("core").gltf_report;
```
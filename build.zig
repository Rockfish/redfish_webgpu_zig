const std = @import("std");

const content_dir = "assets/";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "content_dir", content_dir);

    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });

    // zgui provides imgui and its GLFW platform backend. The WebGPU renderer backend
    // is compiled below against wgpu-native's headers instead of zgui's Dawn ones.
    const zgui = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .backend = .glfw,
        .shared = false,
    });

    const zstbi = b.dependency("zstbi", .{
        .target = target,
        .optimize = optimize,
    });

    const wgpu_native = wgpuNativeDependency(b, target) orelse return;
    const wgpu = wgpuModule(b, target, optimize, wgpu_native);
    const imgui_wgpu = imguiWgpuLibrary(b, target, optimize, zgui, wgpu_native);

    const containers = b.createModule(.{
        .root_source_file = b.path("src/containers/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const math = b.createModule(.{
        .root_source_file = b.path("src/math/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    core.addImport("math", math);
    core.addImport("containers", containers);
    core.addImport("wgpu", wgpu);
    core.addImport("zglfw", zglfw.module("root"));
    core.addImport("zgui", zgui.module("root"));
    core.addImport("zstbi", zstbi.module("root"));

    core.linkLibrary(zgui.artifact("imgui"));
    core.linkLibrary(imgui_wgpu);
    core.linkLibrary(zglfw.artifact("glfw"));
    linkWgpuNative(core, target, wgpu_native);

    inline for ([_]struct {
        name: []const u8,
        exe_name: []const u8,
        source: []const u8,
    }{
        .{ .name = "gpu_caps", .exe_name = "gpu_caps", .source = "examples/gpu_caps/main.zig" },
        .{ .name = "draw_test", .exe_name = "draw_test", .source = "examples/draw_test/main.zig" },
        .{ .name = "scene_tree", .exe_name = "scene_tree", .source = "examples/scene_tree/main.zig" },
    }) |app| {
        const exe = b.addExecutable(.{
            .name = app.exe_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(app.source),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "core", .module = core },
                    .{ .name = "math", .module = math },
                    .{ .name = "containers", .module = containers },
                    .{ .name = "zglfw", .module = zglfw.module("root") },
                    .{ .name = "zgui", .module = zgui.module("root") },
                    .{ .name = "zstbi", .module = zstbi.module("root") },
                    .{ .name = "build_options", .module = build_options.createModule() },
                },
            }),
        });

        const install_exe = b.addInstallArtifact(exe, .{});

        b.getInstallStep().dependOn(&install_exe.step);
        b.step(app.name, "Build '" ++ app.name ++ "' app").dependOn(&install_exe.step);

        const run_exe = b.addRunArtifact(exe);
        run_exe.step.dependOn(&install_exe.step);

        if (b.args) |args| {
            run_exe.addArgs(args);
        }

        b.step(app.name ++ "-run", "Run '" ++ app.name ++ "' app").dependOn(&run_exe.step);
    }

    // Unit tests plus a full semantic check of math, containers, and core: lazy analysis
    // would otherwise skip every function no app calls yet.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/analyze_all.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "math", .module = math },
                .{ .name = "containers", .module = containers },
            },
        }),
    });
    const test_step = b.step("test", "Run unit tests and analyze all of math, containers, core");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Test blocks are only discovered in a test's root module, so each module gets its own.
    inline for (.{ math, containers, core }) |module| {
        const module_tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(module_tests).step);
    }
}

/// The prebuilt wgpu-native release for the target. Returns null while the lazy
/// package is still being fetched.
fn wgpuNativeDependency(b: *std.Build, target: std.Build.ResolvedTarget) ?*std.Build.Dependency {
    const os = target.result.os.tag;
    const arch = target.result.cpu.arch;

    if (os == .macos and arch == .aarch64) return b.lazyDependency("wgpu_native_aarch64_macos", .{});

    std.debug.panic("wgpu-native: no prebuilt package listed for {t}-{t}", .{ arch, os });
}

/// `wgpu` module: src/core/wgpu/wgpu.zig over the translated webgpu.h + wgpu.h.
fn wgpuModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    wgpu_native: *std.Build.Dependency,
) *std.Build.Module {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/core/wgpu/webgpu.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(wgpu_native.path("include"));

    const wgpu = b.createModule(.{ .root_source_file = b.path("src/core/wgpu/wgpu.zig") });
    wgpu.addImport("webgpu_c", translate.createModule());
    return wgpu;
}

/// imgui's WebGPU renderer backend, built for wgpu-native. The macros match zgui's
/// imgui build so struct layouts and symbol names agree.
///
/// BACKEND_DAWN is deliberate: in imgui 1.92.1 the Dawn-only branches are exactly the
/// standard webgpu.h changes (`WGPUComputeState`, `WGPUVertexAttribute.nextInChain`)
/// that wgpu-native 29 adopted. imgui 1.93 builds for wgpu-native 29 with BACKEND_WGPU;
/// switch when zgui moves to it.
fn imguiWgpuLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zgui: *std.Build.Dependency,
    wgpu_native: *std.Build.Dependency,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    module.addCMacro("IMGUI_IMPL_API", "extern \"C\"");
    module.addCMacro("IMGUI_DISABLE_OBSOLETE_FUNCTIONS", "");
    module.addCMacro("IMGUI_IMPL_WEBGPU_BACKEND_DAWN", "");
    module.addIncludePath(zgui.path("libs/imgui"));
    module.addIncludePath(wgpu_native.path("include"));
    module.addCSourceFile(.{
        .file = zgui.path("libs/imgui/backends/imgui_impl_wgpu.cpp"),
        .flags = &.{ "-fno-sanitize=undefined", "-Wno-elaborated-enum-base" },
    });

    return b.addLibrary(.{
        .name = "imgui_wgpu",
        .linkage = .static,
        .root_module = module,
    });
}

fn linkWgpuNative(
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    wgpu_native: *std.Build.Dependency,
) void {
    module.addObjectFile(wgpu_native.path("lib/libwgpu_native.a"));

    if (target.result.os.tag == .macos) {
        module.linkFramework("Metal", .{});
        module.linkFramework("QuartzCore", .{});
        module.linkFramework("Foundation", .{});
        module.linkFramework("CoreGraphics", .{});
        module.linkSystemLibrary("objc", .{});
    }
}

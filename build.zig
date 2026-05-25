const std = @import("std");
const zon = @import("build.zig.zon");

pub const version = std.SemanticVersion.parse(zon.version) catch @panic("Invalid version in build.zig.zon");

fn createModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const zon_mod = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
    });
    mod.addImport("zon", zon_mod);
    return mod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = createModule(b, target, optimize);

    addExe(b, mod);
    addTest(b, mod);
    addCoverage(b, mod, target, optimize);
    addDocs(b, mod);
    addDocsServe(b, target, optimize);
}

fn addExe(b: *std.Build, mod: *std.Build.Module) void {
    const exe = b.addExecutable(.{
        .name = "zix",
        .root_module = mod,
        .version = version,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    b.step("run", "Run the app").dependOn(&run_cmd.step);
}

fn addTest(b: *std.Build, mod: *std.Build.Module) void {
    const install_bin = b.option(bool, "test-bin", "Install test binary for coverage analysis") orelse false;

    const compile = b.addTest(.{
        .name = "zix-test",
        .root_module = mod,
        .use_llvm = true,
    });
    if (install_bin) b.installArtifact(compile);

    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(compile).step);
}

fn addCoverage(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    // Test binary
    const test_compile = b.addTest(.{
        .name = "zix-test",
        .root_module = mod,
        .use_llvm = true,
    });
    b.installArtifact(test_compile);

    // Coverage report tool
    const report_mod = b.createModule(.{
        .root_source_file = b.path("build/coverage.zig"),
        .target = target,
        .optimize = optimize,
    });
    const report_exe = b.addExecutable(.{
        .name = "coverage-report",
        .root_module = report_mod,
    });
    b.installArtifact(report_exe);

    // kcov step
    const kcov = b.addSystemCommand(&.{ "sh", "-c" });
    const test_bin = b.pathJoin(&.{ b.install_path, "bin", "zix-test" });
    const report_bin = b.pathJoin(&.{ b.install_path, "bin", "coverage-report" });
    const kcov_run = std.fmt.allocPrint(b.allocator, "rm -rf coverage && nix-shell -p kcov --run 'kcov --include-pattern=src ./coverage {s}' && {s} coverage", .{ test_bin, report_bin }) catch @panic("OOM");
    kcov.addArg(kcov_run);
    kcov.step.dependOn(b.getInstallStep());
    b.step("coverage", "Run tests under kcov and print line coverage").dependOn(&kcov.step);
}

fn addDocs(b: *std.Build, mod: *std.Build.Module) void {
    const compile = b.addTest(.{
        .name = "zix-docs",
        .root_module = mod,
    });
    const install = b.addInstallDirectory(.{
        .source_dir = compile.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Build documentation").dependOn(&install.step);
}

fn addDocsServe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const serve_mod = b.createModule(.{
        .root_source_file = b.path("build/serve.zig"),
        .target = target,
        .optimize = optimize,
    });
    const serve_exe = b.addExecutable(.{
        .name = "serve",
        .root_module = serve_mod,
    });

    const serve_cmd = b.addRunArtifact(serve_exe);
    serve_cmd.addArg(b.pathJoin(&.{ b.install_path, "docs" }));
    serve_cmd.step.dependOn(b.getInstallStep());

    b.step("docs:serve", "Build docs and serve at localhost:8000").dependOn(&serve_cmd.step);
}


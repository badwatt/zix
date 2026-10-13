//! Build configuration for zix.
//!
//! Defines targets: exe, test, coverage, docs, docs:serve.
//! Module creation is deduplicated via `createModule`.

const std = @import("std");
const zon = @import("build.zig.zon");

pub const version = std.SemanticVersion.parse(zon.version) catch @panic("Invalid version in build.zig.zon");

/// Creates the root module with shared imports (zon module).
/// Used by exe, test, and doc targets to avoid duplication.
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
    const docs_compile = addDocs(b, mod);
    addCoverage(b, mod, target, optimize);
    addDocsServe(b, target, optimize, docs_compile);
}

/// Builds and installs the zix executable. Adds `run` step.
fn addExe(b: *std.Build, mod: *std.Build.Module) void {
    const exe = b.addExecutable(.{
        .name = "zix",
        .root_module = mod,
        .version = version,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // Forward `zig build run -- <args>` to the executable.
    run_cmd.addPassthruArgs();
    b.step("run", "Run the app").dependOn(&run_cmd.step);
}

/// Adds `test` step. Optionally installs test binary with `-Dtest-bin=true`.
fn addTest(b: *std.Build, mod: *std.Build.Module) void {
    const install_bin = b.option(bool, "test-bin", "Install test binary for coverage analysis") orelse false;

    const compile = b.addTest(.{
        .name = "zix-test",
        .root_module = mod,
        .use_llvm = true,
    });
    if (install_bin) b.installArtifact(compile);

    const run_tests = b.addRunArtifact(compile);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}

/// Adds `coverage` step: runs kcov via nix-shell, then prints summary
/// using the Zig coverage-report tool.
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

    // kcov step. The install prefix is not known while configuring the build
    // graph, so the test and report binaries are passed as positional args
    // (`$1`, `$2`) resolved from the compile steps.
    const kcov = b.addSystemCommand(&.{ "sh", "-c" });
    kcov.addArg("rm -rf coverage && ZIX_TEST_BIN=\"$1\" nix-shell -p kcov --run 'kcov --include-pattern=src ./coverage \"$ZIX_TEST_BIN\"' && \"$2\" coverage");
    kcov.addArg("zix-coverage"); // $0
    kcov.addArtifactArg2(test_compile, .{}); // $1
    kcov.addArtifactArg2(report_exe, .{}); // $2
    b.step("coverage", "Run tests under kcov and print line coverage").dependOn(&kcov.step);
}

/// Adds `docs` step: builds autodoc and installs to zig-out/docs/.
/// Returns the docs compile step so `docs:serve` can consume its output.
fn addDocs(b: *std.Build, mod: *std.Build.Module) *std.Build.Step.Compile {
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
    return compile;
}

/// Adds `docs:serve` step: builds docs then starts a local HTTP server.
/// The server reads files from the emitted docs directory.
fn addDocsServe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, docs_compile: *std.Build.Step.Compile) void {
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
    serve_cmd.addDirectoryArg2(docs_compile.getEmittedDocs(), .{});

    b.step("docs:serve", "Build docs and serve at localhost:8000").dependOn(&serve_cmd.step);
}

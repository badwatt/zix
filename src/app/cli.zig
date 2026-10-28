//! CLI workflow: builds argv commands and runs the update pipeline.
//!
//! All side effects go through the injected `Runner` and `UserIo` ports. Every
//! step checks the exit status and aborts on failure (fail-fast), so cleanup
//! never runs after a failed rebuild and a failed step is never reported as a
//! success.

const std = @import("std");
const cmd = @import("../core/commands.zig");
const process = @import("../core/process.zig");
const ui_mod = @import("../core/ui.zig");
const Config = @import("config.zig").Config;
const Step = @import("config.zig").Step;

/// Errors the workflow surfaces so `main` can pick an exit code.
pub const Error = error{
    InvalidArgs,
    InvalidConfig,
    NotAGitRepo,
    GitPullFailed,
    FlakeUpdateFailed,
    GitStatusFailed,
    GitAddFailed,
    DiffFailed,
    RebuildFailed,
    HostnameUnknown,
    CleanupFailed,
};

/// Injected dependencies: a capture allocator, the command runner, the user
/// I/O port, and the process environment.
pub const Deps = struct {
    /// Allocator used for captured command output (temporary scratch).
    allocator: std.mem.Allocator,
    /// Command execution port.
    runner: process.Runner,
    /// User-facing output port.
    ui: ui_mod.UserIo,
    /// Diagnostics writer (stderr in production, a fixed buffer in tests).
    err_writer: *std.Io.Writer,
    /// Environment variables (HOME / HOSTNAME).
    environ: *std.process.Environ.Map,
};

/// Pre-built argv commands. Allocation happens in `buildCommands`; afterwards
/// the workflow needs no allocation of its own (capture uses scratch memory).
pub const Commands = struct {
    git_pull: [4][]const u8,
    git_status: [5][]const u8,
    git_rev_parse: [5][]const u8,
    git_add: [5][]const u8,
    nix_update: [5][]const u8,
    nix_rebuild: cmd.Rebuild,
    nix_keep: [6][]const u8,
    nix_gc: [2][]const u8,
    nix_diff: [5][]const u8,
};

/// Builds every argv the workflow needs from `config` and the detected flavor.
pub fn buildCommands(
    config: Config,
    flavor: cmd.RebuildFlavor,
    allocator: std.mem.Allocator,
) !Commands {
    std.debug.assert(config.repo.len > 0);
    std.debug.assert(config.hostname.len > 0);
    std.debug.assert(config.keep > 0);

    const flake = try cmd.formatFlake(allocator, config.repo, config.hostname);
    const max_jobs = if (config.jobs) |jobs| try cmd.formatCount(allocator, jobs) else null;
    const cores = if (config.cores) |value| try cmd.formatCount(allocator, value) else null;

    return .{
        .git_pull = cmd.gitPull(config.repo),
        .git_status = cmd.gitStatus(config.repo),
        .git_rev_parse = cmd.gitRevParse(config.repo),
        .git_add = cmd.gitAdd(config.repo),
        .nix_update = cmd.nixUpdate(config.repo),
        .nix_rebuild = cmd.nixRebuild(flake, flavor, max_jobs, cores),
        .nix_keep = cmd.nixKeep(try cmd.formatKeep(allocator, config.keep)),
        .nix_gc = cmd.nixCollectGarbage(),
        .nix_diff = cmd.nixDiffClosures(),
    };
}

/// Probes the installed `nixos-rebuild` to choose compatible flags. On any
/// error, conservatively assumes the classic implementation.
pub fn detectFlavor(io: std.Io, deps: Deps) cmd.RebuildFlavor {
    const code = deps.runner.probe(io, &cmd.rebuildProbe()) catch return .classic;
    return if (code == 0) .ng else .classic;
}

/// Runs the full workflow using the pre-built commands.
pub fn execute(
    io: std.Io,
    writer: *std.Io.Writer,
    config: Config,
    commands: *const Commands,
    deps: Deps,
) anyerror!void {
    std.debug.assert(config.repo.len > 0);
    std.debug.assert(config.hostname.len > 0);

    try deps.ui.title(writer, "ZIX Configuration");
    try deps.ui.config(writer, config);

    if (!config.yes and !(try deps.ui.confirm(writer, true, null))) {
        try deps.ui.output(writer, "Aborted.\n");
        return;
    }

    if (config.runs(.pull)) try pull(io, writer, commands, deps);

    if (config.runs(.flake)) try flakeUpdate(io, writer, commands, deps);

    if (config.runs(.stage) and !try stage(io, writer, config, commands, deps)) return;
    if (config.runs(.rebuild)) try rebuild(io, writer, commands, deps);
    if (config.runs(.cleanup)) try cleanup(io, commands, deps);

    if (config.runs(.diff)) try showDiff(io, writer, commands, deps);
}

/// Reports `msg` on stderr and returns `err`.
fn fail(deps: Deps, err: Error, msg: []const u8) anyerror {
    try deps.ui.err(deps.err_writer, msg);
    return err;
}

/// Verifies the repo is a git work tree, then pulls.
fn pull(io: std.Io, writer: *std.Io.Writer, commands: *const Commands, deps: Deps) anyerror!void {
    try deps.ui.title(writer, "Git Pull");
    if (try deps.runner.probe(io, &commands.git_rev_parse) != 0) {
        return fail(deps, Error.NotAGitRepo, "Repository is not a git working tree");
    }
    if (try deps.runner.run(io, &commands.git_pull) != 0) {
        return fail(deps, Error.GitPullFailed, "Failed to pull changes");
    }
}

/// Runs `nix flake update`.
fn flakeUpdate(io: std.Io, writer: *std.Io.Writer, commands: *const Commands, deps: Deps) anyerror!void {
    try deps.ui.title(writer, "Nix Update");
    if (try deps.runner.run(io, &commands.nix_update) != 0) {
        return fail(deps, Error.FlakeUpdateFailed, "Failed to update flake inputs");
    }
}

/// Detects changes (including untracked files) and, if confirmed, stages them.
/// Returns false when the user declines, so the caller aborts the pipeline.
fn stage(
    io: std.Io,
    writer: *std.Io.Writer,
    config: Config,
    commands: *const Commands,
    deps: Deps,
) anyerror!bool {
    const status = try deps.runner.capture(io, deps.allocator, &commands.git_status);
    defer status.deinit(deps.allocator);
    if (status.code != 0) {
        if (status.stderr.len > 0) try deps.ui.output(deps.err_writer, status.stderr);
        return fail(deps, Error.GitStatusFailed, "Failed to read repository status");
    }
    if (std.mem.trim(u8, status.stdout, " \t\r\n").len == 0) return true;

    try deps.ui.title(writer, "Git Changes");
    try deps.ui.output(writer, status.stdout);

    if (!config.yes and !(try deps.ui.confirm(
        writer,
        true,
        "Do you want to add these changes to the stage?",
    ))) {
        // Nothing was staged, so the rebuild would evaluate a stale flake.
        try deps.ui.output(writer, "Changes not added to stage; aborting.\n");
        return false;
    }

    if (try deps.runner.run(io, &commands.git_add) != 0) {
        return fail(deps, Error.GitAddFailed, "Failed to add changes to the stage");
    }
    try deps.ui.success(writer, "Changes added to git stage successfully");
    return true;
}

/// Rebuilds and switches the system.
fn rebuild(io: std.Io, writer: *std.Io.Writer, commands: *const Commands, deps: Deps) anyerror!void {
    try deps.ui.title(writer, "Nixos Rebuild");
    const code = try deps.runner.run(io, commands.nix_rebuild.slice());
    if (code == 0) return;
    // 128 + N is the shell convention for a signal-terminated child. An
    // out-of-memory kill can arrive this way, so point at --jobs.
    if (code >= 128) {
        return fail(
            deps,
            Error.RebuildFailed,
            "nixos-rebuild was terminated by a signal; if the build ran out of memory, lower --cores/--jobs",
        );
    }
    return fail(deps, Error.RebuildFailed, "Nixos rebuild failed");
}

/// Prunes old generations and frees unreferenced store paths.
fn cleanup(io: std.Io, commands: *const Commands, deps: Deps) anyerror!void {
    for ([_][]const []const u8{ &commands.nix_keep, &commands.nix_gc }) |argv| {
        if (try deps.runner.run(io, argv) != 0) {
            return fail(deps, Error.CleanupFailed, "Cleanup failed");
        }
    }
}

/// Shows the closure diff from the last `Version` line onward.
fn showDiff(io: std.Io, writer: *std.Io.Writer, commands: *const Commands, deps: Deps) anyerror!void {
    try deps.ui.title(writer, "Nix Diff");
    const output = try deps.runner.capture(io, deps.allocator, &commands.nix_diff);
    defer output.deinit(deps.allocator);
    if (output.code != 0) {
        if (output.stderr.len > 0) try deps.ui.output(deps.err_writer, output.stderr);
        return fail(deps, Error.DiffFailed, "Failed to compute closure diff");
    }
    const tail = cmd.tailFromLastVersion(output.stdout);
    try deps.ui.output(writer, tail);
    if (tail.len > 0 and tail[tail.len - 1] != '\n') {
        try writer.writeByte('\n');
        try writer.flush();
    }
}

/// Human-readable message for an error surfaced by the workflow.
pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidArgs => "Invalid arguments",
        error.InvalidConfig => "Invalid configuration",
        error.NotAGitRepo => "Repository is not a git working tree",
        error.GitPullFailed => "Failed to pull changes",
        error.FlakeUpdateFailed => "Failed to update flake inputs",
        error.GitStatusFailed => "Failed to read repository status",
        error.GitAddFailed => "Failed to add changes to the stage",
        error.DiffFailed => "Failed to compute closure diff",
        error.RebuildFailed => "Nixos rebuild failed",
        error.HostnameUnknown => "Could not determine hostname; pass --hostname",
        error.CleanupFailed => "Cleanup failed",
        else => "Unexpected error",
    };
}

/// Process exit code for an error: 2 for invalid usage, 1 otherwise.
pub fn exitCode(err: anyerror) u8 {
    return switch (err) {
        error.InvalidArgs, error.InvalidConfig => 2,
        else => 1,
    };
}

// --- Test mocks ---

var fail_needle: ?[]const u8 = null;
var fail_code: i32 = 1;
var capture_code: i32 = 0;
var capture_code_needle: ?[]const u8 = null;
var capture_output: []const u8 = "";
var capture_stderr: []const u8 = "";
var probe_result: i32 = 0;
var probe_error: bool = false;
var confirm_count: u32 = 0;
var confirm_false_at: u32 = 0;
var last_error: []const u8 = "";
var last_success: []const u8 = "";
var last_output: []const u8 = "";
var output_copy: [1024]u8 = undefined;
var output_len: usize = 0;

var test_err_buf: [4096]u8 = undefined;
var test_err_state: std.Io.Writer = undefined;

/// Returns a fresh fixed-buffer writer for diagnostics in tests.
fn testErrWriter() *std.Io.Writer {
    test_err_state = std.Io.Writer.fixed(&test_err_buf);
    return &test_err_state;
}

fn resetMocks() void {
    fail_needle = null;
    fail_code = 1;
    capture_code = 0;
    capture_code_needle = null;
    capture_output = "";
    capture_stderr = "";
    probe_result = 0;
    probe_error = false;
    confirm_count = 0;
    confirm_false_at = 0;
    last_error = "";
    last_success = "";
    output_len = 0;
    last_output = "";
}

/// True when any argv element equals `needle`.
fn hasArg(argv: process.Runner.Command, needle: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn mockRun(_: ?*anyopaque, _: std.Io, argv: process.Runner.Command) anyerror!i32 {
    if (fail_needle) |needle| {
        if (hasArg(argv, needle)) return fail_code;
    }
    return 0;
}

fn mockCapture(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    argv: process.Runner.Command,
) anyerror!process.Capture {
    const code = if (capture_code_needle) |needle|
        (if (hasArg(argv, needle)) capture_code else 0)
    else
        capture_code;
    const out = try allocator.dupe(u8, capture_output);
    const err = try allocator.dupe(u8, capture_stderr);
    return .{ .code = code, .stdout = out, .stderr = err };
}

fn mockProbe(_: ?*anyopaque, _: std.Io, _: process.Runner.Command) anyerror!i32 {
    if (probe_error) return error.MockError;
    return probe_result;
}

fn mockTitle(_: *std.Io.Writer, _: []const u8) anyerror!void {}
fn mockConfig(_: *std.Io.Writer, _: Config) anyerror!void {}
fn mockError(_: *std.Io.Writer, msg: []const u8) anyerror!void {
    last_error = msg;
}
fn mockSuccess(_: *std.Io.Writer, msg: []const u8) anyerror!void {
    last_success = msg;
}
fn mockOutput(_: *std.Io.Writer, out: []const u8) anyerror!void {
    const n = @min(out.len, output_copy.len);
    @memcpy(output_copy[0..n], out[0..n]);
    output_len = n;
    last_output = output_copy[0..output_len];
}
fn mockConfirm(_: *std.Io.Writer, _: bool, _: ?[]const u8) anyerror!bool {
    confirm_count += 1;
    if (confirm_false_at != 0 and confirm_count == confirm_false_at) return false;
    return true;
}

fn testDeps(allocator: std.mem.Allocator, environ: *std.process.Environ.Map) Deps {
    return .{
        .allocator = allocator,
        .runner = .{ .runFn = mockRun, .captureFn = mockCapture, .probeFn = mockProbe },
        .ui = .{
            .title = mockTitle,
            .confirm = mockConfirm,
            .err = mockError,
            .success = mockSuccess,
            .output = mockOutput,
            .config = mockConfig,
        },
        .environ = environ,
        .err_writer = testErrWriter(),
    };
}

fn testConfig(hostname: []const u8) Config {
    var config = Config.defaults(hostname);
    config.repo = "/repo";
    return config;
}

// --- Tests ---

test "buildCommands populates every field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const commands = try buildCommands(testConfig("host"), .ng, arena.allocator());
    const rebuild_argv = commands.nix_rebuild.slice();
    try std.testing.expectEqualStrings("git", commands.git_pull[0]);
    try std.testing.expectEqualStrings("--porcelain", commands.git_status[4]);
    try std.testing.expectEqualStrings("--is-inside-work-tree", commands.git_rev_parse[4]);
    try std.testing.expectEqualStrings(".", commands.git_add[4]);
    try std.testing.expectEqualStrings("/repo", commands.nix_update[4]);
    try std.testing.expectEqualStrings("/repo#host", rebuild_argv[5]);
    try std.testing.expectEqualStrings("--elevate=sudo", rebuild_argv[2]);
    try std.testing.expectEqualStrings("+10", commands.nix_keep[5]);
    try std.testing.expectEqualStrings("nix-collect-garbage", commands.nix_gc[1]);
    try std.testing.expectEqualStrings("diff-closures", commands.nix_diff[2]);
}

test "buildCommands passes --max-jobs and --cores when set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var config = testConfig("host");
    config.jobs = 4;
    config.cores = 6;
    const commands = try buildCommands(config, .ng, arena.allocator());
    const rebuild_argv = commands.nix_rebuild.slice();
    try std.testing.expectEqualStrings("--max-jobs", rebuild_argv[4]);
    try std.testing.expectEqualStrings("4", rebuild_argv[5]);
    try std.testing.expectEqualStrings("--cores", rebuild_argv[6]);
    try std.testing.expectEqualStrings("6", rebuild_argv[7]);
    try std.testing.expectEqualStrings("/repo#host", rebuild_argv[9]);
}

test "execute reports a signal-terminated rebuild" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();
    fail_needle = "switch";
    fail_code = 143;

    var config = testConfig("host");
    config.yes = true;
    const commands = try buildCommands(config, .ng, arena.allocator());
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(
        Error.RebuildFailed,
        execute(std.testing.io, &writer, config, &commands, testDeps(arena.allocator(), &environ)),
    );
    try std.testing.expect(std.mem.indexOf(u8, last_error, "signal") != null);
}

test "detectFlavor picks compatible flavor" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const deps = testDeps(std.testing.allocator, &environ);
    const io = std.testing.io;

    resetMocks();
    probe_result = 0;
    try std.testing.expectEqual(cmd.RebuildFlavor.ng, detectFlavor(io, deps));

    resetMocks();
    probe_result = 1;
    try std.testing.expectEqual(cmd.RebuildFlavor.classic, detectFlavor(io, deps));

    resetMocks();
    probe_error = true;
    try std.testing.expectEqual(cmd.RebuildFlavor.classic, detectFlavor(io, deps));
}

test "execute happy path needs no confirmations when yes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();

    var config = testConfig("host");
    config.yes = true;
    const commands = try buildCommands(config, .ng, arena.allocator());

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try execute(std.testing.io, &writer, config, &commands, testDeps(arena.allocator(), &environ));
    try std.testing.expectEqual(@as(u32, 0), confirm_count);
}

test "execute frees every captured buffer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();
    capture_output = "Version 2\nchanged\n";

    var config = testConfig("host");
    config.yes = true;
    config.diff = true;
    const commands = try buildCommands(config, .ng, arena.allocator());

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    // The capture allocator is the leak checker: an unfreed Capture fails here.
    try execute(std.testing.io, &writer, config, &commands, testDeps(std.testing.allocator, &environ));
    try std.testing.expectEqualStrings("Version 2\nchanged\n", last_output);
}

test "execute aborts when initial confirmation is declined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();
    confirm_false_at = 1;

    const config = testConfig("host");
    const commands = try buildCommands(config, .ng, arena.allocator());
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try execute(std.testing.io, &writer, config, &commands, testDeps(arena.allocator(), &environ));
    try std.testing.expectEqual(@as(u32, 1), confirm_count);
    try std.testing.expectEqualStrings("Aborted.\n", last_output);
}

test "execute fails when repo is not a git work tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();
    probe_result = 1;

    var config = testConfig("host");
    config.yes = true;
    const commands = try buildCommands(config, .ng, arena.allocator());
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(
        Error.NotAGitRepo,
        execute(std.testing.io, &writer, config, &commands, testDeps(arena.allocator(), &environ)),
    );
    try std.testing.expectEqualStrings("Repository is not a git working tree", last_error);
}

test "execute fails when git pull fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();
    fail_needle = "pull";

    var config = testConfig("host");
    config.yes = true;
    const commands = try buildCommands(config, .ng, arena.allocator());
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(
        Error.GitPullFailed,
        execute(std.testing.io, &writer, config, &commands, testDeps(arena.allocator(), &environ)),
    );
}

test "execute fails when flake update fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();
    fail_needle = "update";

    var config = testConfig("host");
    config.yes = true;
    config.update = true;
    const commands = try buildCommands(config, .ng, arena.allocator());
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(
        Error.FlakeUpdateFailed,
        execute(std.testing.io, &writer, config, &commands, testDeps(arena.allocator(), &environ)),
    );
}

test "execute fails when git status cannot be read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();
    capture_code = 2;
    capture_stderr = "fatal: not a git repository\n";

    var config = testConfig("host");
    config.yes = true;
    const commands = try buildCommands(config, .ng, arena.allocator());
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(
        Error.GitStatusFailed,
        execute(std.testing.io, &writer, config, &commands, testDeps(arena.allocator(), &environ)),
    );
    try std.testing.expect(std.mem.indexOf(u8, last_output, "fatal: not a git repository") != null);
}

test "execute stages changes when confirmed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();
    capture_output = " M src/main.zig\n";

    var config = testConfig("host");
    config.yes = true;
    const commands = try buildCommands(config, .ng, arena.allocator());
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try execute(std.testing.io, &writer, config, &commands, testDeps(arena.allocator(), &environ));
    try std.testing.expectEqualStrings(" M src/main.zig\n", last_output);
    try std.testing.expectEqualStrings("Changes added to git stage successfully", last_success);
}

test "execute aborts when staging changes is declined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();
    capture_output = " M file\n";
    confirm_false_at = 2; // initial prompt yes, staging prompt no.
    fail_needle = "switch"; // the rebuild must not run

    var config = testConfig("host");
    config.diff = true; // neither must the diff
    const commands = try buildCommands(config, .ng, arena.allocator());
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try execute(std.testing.io, &writer, config, &commands, testDeps(arena.allocator(), &environ));
    try std.testing.expectEqual(@as(u32, 2), confirm_count);
    try std.testing.expectEqualStrings("Changes not added to stage; aborting.\n", last_output);
}

test "execute fails when git add fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();
    capture_output = " M file\n";
    fail_needle = "add";

    var config = testConfig("host");
    config.yes = true;
    const commands = try buildCommands(config, .ng, arena.allocator());
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(
        Error.GitAddFailed,
        execute(std.testing.io, &writer, config, &commands, testDeps(arena.allocator(), &environ)),
    );
}

test "execute fails when rebuild fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();
    fail_needle = "switch";

    var config = testConfig("host");
    config.yes = true;
    const commands = try buildCommands(config, .ng, arena.allocator());
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(
        Error.RebuildFailed,
        execute(std.testing.io, &writer, config, &commands, testDeps(arena.allocator(), &environ)),
    );
}

test "execute fails when generation pruning fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();
    fail_needle = "nix-env";

    var config = testConfig("host");
    config.yes = true;
    const commands = try buildCommands(config, .ng, arena.allocator());
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(
        Error.CleanupFailed,
        execute(std.testing.io, &writer, config, &commands, testDeps(arena.allocator(), &environ)),
    );
}

test "execute fails when garbage collection fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();
    fail_needle = "nix-collect-garbage";

    var config = testConfig("host");
    config.yes = true;
    const commands = try buildCommands(config, .ng, arena.allocator());
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(
        Error.CleanupFailed,
        execute(std.testing.io, &writer, config, &commands, testDeps(arena.allocator(), &environ)),
    );
}

test "execute shows diff when requested" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();
    capture_output = "noise\nVersion 2\nchanged\n";

    var config = testConfig("host");
    config.yes = true;
    config.diff = true;
    const commands = try buildCommands(config, .ng, arena.allocator());
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try execute(std.testing.io, &writer, config, &commands, testDeps(arena.allocator(), &environ));
    try std.testing.expectEqualStrings("Version 2\nchanged\n", last_output);
}

test "execute appends newline when diff tail lacks one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();
    capture_output = "Version 2";

    var config = testConfig("host");
    config.yes = true;
    config.diff = true;
    const commands = try buildCommands(config, .ng, arena.allocator());
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try execute(std.testing.io, &writer, config, &commands, testDeps(arena.allocator(), &environ));
    try std.testing.expect(std.mem.endsWith(u8, buf[0..writer.end], "\n"));
}

test "execute fails when diff-closures fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();
    capture_code = 7;
    capture_code_needle = "diff-closures";

    var config = testConfig("host");
    config.yes = true;
    config.diff = true;
    const commands = try buildCommands(config, .ng, arena.allocator());
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(
        Error.DiffFailed,
        execute(std.testing.io, &writer, config, &commands, testDeps(arena.allocator(), &environ)),
    );
    try std.testing.expectEqualStrings("Failed to compute closure diff", last_error);
}

test "execute runs only the selected steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();
    // `pull` would fail if it ran, so success proves --only skipped it.
    fail_needle = "pull";
    capture_output = "Version 2\nchanged\n";

    var config = testConfig("host");
    config.yes = true;
    config.only = std.EnumSet(Step).initOne(.diff);
    const commands = try buildCommands(config, .ng, arena.allocator());
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try execute(std.testing.io, &writer, config, &commands, testDeps(arena.allocator(), &environ));
    try std.testing.expectEqualStrings("Version 2\nchanged\n", last_output);
}

test "execute skips the diff when it is not selected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    resetMocks();
    // A failing capture would abort the run if the diff step ran.
    capture_code = 7;

    var config = testConfig("host");
    config.yes = true;
    config.only = std.EnumSet(Step).initOne(.pull);
    const commands = try buildCommands(config, .ng, arena.allocator());
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try execute(std.testing.io, &writer, config, &commands, testDeps(arena.allocator(), &environ));
}

test "errorMessage and exitCode cover every variant" {
    try std.testing.expectEqualStrings("Invalid arguments", errorMessage(error.InvalidArgs));
    try std.testing.expectEqualStrings("Invalid configuration", errorMessage(error.InvalidConfig));
    try std.testing.expectEqualStrings("Repository is not a git working tree", errorMessage(error.NotAGitRepo));
    try std.testing.expectEqualStrings("Failed to pull changes", errorMessage(error.GitPullFailed));
    try std.testing.expectEqualStrings("Failed to update flake inputs", errorMessage(error.FlakeUpdateFailed));
    try std.testing.expectEqualStrings("Failed to read repository status", errorMessage(error.GitStatusFailed));
    try std.testing.expectEqualStrings("Failed to add changes to the stage", errorMessage(error.GitAddFailed));
    try std.testing.expectEqualStrings("Failed to compute closure diff", errorMessage(error.DiffFailed));
    try std.testing.expectEqualStrings("Nixos rebuild failed", errorMessage(error.RebuildFailed));
    try std.testing.expectEqualStrings("Could not determine hostname; pass --hostname", errorMessage(error.HostnameUnknown));
    try std.testing.expectEqualStrings("Cleanup failed", errorMessage(error.CleanupFailed));
    try std.testing.expectEqualStrings("Unexpected error", errorMessage(error.MockError));

    try std.testing.expectEqual(@as(u8, 2), exitCode(error.InvalidArgs));
    try std.testing.expectEqual(@as(u8, 2), exitCode(error.InvalidConfig));
    try std.testing.expectEqual(@as(u8, 1), exitCode(error.GitPullFailed));
    try std.testing.expectEqual(@as(u8, 1), exitCode(error.MockError));
}

test "hasArg matches and misses" {
    try std.testing.expect(hasArg(&.{ "git", "pull" }, "pull"));
    try std.testing.expect(!hasArg(&.{ "git", "pull" }, "add"));
}

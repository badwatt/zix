//! CLI orchestration: builds commands, executes update workflow, manages git staging.
//! Two-phase design: init (allocation allowed) → static (zero allocation).
//! All side effects injected via Deps for testability.

const std = @import("std");
const io = @import("../core/io.zig");
const cmd = @import("../core/commands.zig");
const process = @import("../core/process.zig");
const Config = @import("config.zig").Config;

/// Injected side effects: shell execution, user confirmation, UI output.
/// Each field is a function pointer enabling full mock substitution in tests.
pub const Deps = struct {
    /// Run a shell command. Returns exit code.
    run: *const fn (std.Io, []const u8, process.RunOpts) anyerror!i32,
    /// Prompt user for yes/no confirmation. `default_yes` sets default, `message` overrides prompt text.
    confirm: *const fn (*std.Io.Writer, bool, ?[]const u8) anyerror!bool,
    /// Print a styled section title to output.
    printTitle: *const fn (*std.Io.Writer, []const u8) anyerror!void,
    /// Print the full configuration summary to output.
    configPrint: *const fn (*std.Io.Writer, Config) anyerror!void,
};

/// Pre-built command strings. All allocation happens in buildCommands().
/// After buildCommands() returns, zero allocation is needed.
pub const Commands = struct {
    git_pull: []const u8,
    git_diff: []const u8,
    git_status: []const u8,
    git_add: []const u8,
    nix_update: []const u8,
    nix_rebuild: []const u8,
    nix_keep: []const u8,

    /// nixDiff is a compile-time constant. No allocation needed.
    pub const nix_diff = cmd.nixDiff;
};

/// Phase 1: Init. Build all command strings. Allocation allowed.
pub fn buildCommands(config: Config, allocator: std.mem.Allocator) !Commands {
    // Assert preconditions.
    std.debug.assert(config.repo.len > 0);
    std.debug.assert(config.hostname.len > 0);
    std.debug.assert(config.keep > 0);

    return Commands{
        .git_pull = try cmd.gitPull(allocator, config.repo),
        .git_diff = try cmd.gitDiff(allocator, config.repo),
        .git_status = try cmd.gitStatus(allocator, config.repo),
        .git_add = try cmd.gitAdd(allocator, config.repo),
        .nix_update = try cmd.nixUpdate(allocator, config.repo),
        .nix_rebuild = try cmd.nixRebuild(allocator, config.repo, config.hostname),
        .nix_keep = try cmd.nixKeep(allocator, config.keep),
    };
}

/// Phase 2: Static. Execute all operations using pre-built commands.
/// Zero allocation in this phase.
pub fn execute(
    cli_io: std.Io,
    writer: *std.Io.Writer,
    config: Config,
    commands: Commands,
    deps: Deps,
) !void {
    // Assert preconditions: config must be valid, commands must not be empty.
    std.debug.assert(config.repo.len > 0);
    std.debug.assert(config.hostname.len > 0);

    try deps.printTitle(writer, "ZIX Configuration");
    try deps.configPrint(writer, config);

    if (try deps.confirm(writer, true, null)) {
        // Git pull.
        try deps.printTitle(writer, "Git Pull");
        const pull_status = try deps.run(cli_io, commands.git_pull, .{});
        if (pull_status != 0) {
            try io.printTo(writer, "{s}Failed to pull changes{s}\n", .{ io.Red, io.Reset });
            return error.GitPullFailed;
        }

        // Nix update (optional).
        if (config.update) {
            try deps.printTitle(writer, "Nix Update");
            _ = try deps.run(cli_io, commands.nix_update, .{});
        }

        // Stage git changes.
        try stageGitChanges(cli_io, writer, commands, deps);

        // Nixos rebuild.
        try deps.printTitle(writer, "Nixos Rebuild");
        _ = try deps.run(cli_io, commands.nix_rebuild, .{});
        _ = try deps.run(cli_io, commands.nix_keep, .{});

        // Nix diff (optional).
        if (config.diff) {
            try deps.printTitle(writer, "Nix Diff");
            _ = try deps.run(cli_io, Commands.nix_diff, .{});
        }
    }
}

/// Check for unstaged changes via git-diff, prompt user, optionally git-add.
/// Returns silently if no changes detected.
fn stageGitChanges(
    cli_io: std.Io,
    writer: *std.Io.Writer,
    commands: Commands,
    deps: Deps,
) !void {
    // Assert preconditions: command strings must have been built.
    std.debug.assert(commands.git_diff.len > 0);

    // diff --exit-code returns 1 when there are unstaged changes.
    const has_changes = try deps.run(cli_io, commands.git_diff, .{ .output = false });
    if (has_changes != 1) return;

    try deps.printTitle(writer, "Git Changes");
    _ = try deps.run(cli_io, commands.git_status, .{});

    if (try deps.confirm(
        writer,
        true,
        "Do you want to add these changes to the stage?",
    )) {
        _ = deps.run(cli_io, commands.git_add, .{}) catch |err| {
            try io.printTo(
                writer,
                "{s}Failed to add changes to the stage: {}{s}\n",
                .{ io.Red, err, io.Reset },
            );
            return;
        };
        try io.printTo(
            writer,
            "{s}Changes added to git stage successfully{s}\n",
            .{ io.Green, io.Reset },
        );
    } else {
        try io.printTo(
            writer,
            "{s}Changes not added to stage{s}\n",
            .{ io.Red, io.Reset },
        );
    }
}

// --- Test Mocks ---

/// Returns 1 for git-diff commands (simulating unstaged changes), 0 otherwise.
fn mockRun(_: std.Io, command: []const u8, _: process.RunOpts) anyerror!i32 {
    if (std.mem.startsWith(u8, command, "git -C")) {
        if (std.mem.indexOf(u8, command, "diff --exit-code") != null) return 1;
    }
    return 0;
}

/// Tracks call count. Returns true for all calls except the second.
var confirm_call_count: u32 = 0;
fn mockConfirmCounting(
    _: *std.Io.Writer,
    _: bool,
    _: ?[]const u8,
) anyerror!bool {
    confirm_call_count += 1;
    return confirm_call_count != 2;
}

/// Always confirms yes.
fn mockConfirmTrue(
    _: *std.Io.Writer,
    _: bool,
    _: ?[]const u8,
) anyerror!bool {
    return true;
}

/// Always declines (returns false).
fn mockConfirmFalse(
    _: *std.Io.Writer,
    _: bool,
    _: ?[]const u8,
) anyerror!bool {
    return false;
}

/// No-op title printer for tests.
fn mockPrintTitle(_: *std.Io.Writer, _: []const u8) anyerror!void {}

/// No-op config printer for tests.
fn mockConfigPrint(_: *std.Io.Writer, _: Config) anyerror!void {}

// --- Tests ---

/// Helper: build a minimal Config with given flags.
fn testConfig(update: bool, diff: bool) Config {
    return Config{
        .repo = "r",
        .hostname = "h",
        .keep = 1,
        .update = update,
        .diff = diff,
    };
}

test "execute branches" {
    var memory: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    const allocator = fba.allocator();

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const cli_io = std.testing.io;

    const deps = Deps{
        .run = mockRun,
        .confirm = mockConfirmTrue,
        .printTitle = mockPrintTitle,
        .configPrint = mockConfigPrint,
    };

    // Phase 1: build commands.
    const commands = try buildCommands(testConfig(true, true), allocator);

    // Phase 2: execute (zero alloc from here).

    // confirm false => early return.
    const no_deps = Deps{
        .run = mockRun,
        .confirm = mockConfirmFalse,
        .printTitle = mockPrintTitle,
        .configPrint = mockConfigPrint,
    };
    try execute(cli_io, &writer, testConfig(false, false), commands, no_deps);

    // git pull fails.
    const fail_deps = Deps{
        .run = struct {
            fn f(_: std.Io, _: []const u8, _: process.RunOpts) anyerror!i32 {
                return 1;
            }
        }.f,
        .confirm = mockConfirmTrue,
        .printTitle = mockPrintTitle,
        .configPrint = mockConfigPrint,
    };
    try std.testing.expectError(
        error.GitPullFailed,
        execute(cli_io, &writer, testConfig(false, false), commands, fail_deps),
    );

    // update + diff + git changes + add.
    try execute(cli_io, &writer, testConfig(true, true), commands, deps);

    // no git changes (diff returns 0).
    const no_changes_deps = Deps{
        .run = struct {
            fn f(_: std.Io, _: []const u8, _: process.RunOpts) anyerror!i32 {
                return 0;
            }
        }.f,
        .confirm = mockConfirmTrue,
        .printTitle = mockPrintTitle,
        .configPrint = mockConfigPrint,
    };
    try execute(cli_io, &writer, testConfig(false, false), commands, no_changes_deps);
}

test "execute git add failure" {
    var memory: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    const allocator = fba.allocator();

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const cli_io = std.testing.io;

    const commands = try buildCommands(testConfig(false, true), allocator);

    const add_fail_deps = Deps{
        .run = struct {
            fn f(_: std.Io, c: []const u8, _: process.RunOpts) anyerror!i32 {
                if (std.mem.indexOf(u8, c, "add .") != null) return error.MockError;
                if (std.mem.indexOf(u8, c, "diff --exit-code") != null) return 1;
                return 0;
            }
        }.f,
        .confirm = mockConfirmTrue,
        .printTitle = mockPrintTitle,
        .configPrint = mockConfigPrint,
    };

    try execute(cli_io, &writer, testConfig(false, true), commands, add_fail_deps);
    const out = std.mem.sliceTo(&buf, 0);
    try std.testing.expect(std.mem.indexOf(u8, out, "Failed to add changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "successfully") == null);
}

test "execute decline add changes" {
    var memory: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    const allocator = fba.allocator();

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const cli_io = std.testing.io;

    const commands = try buildCommands(testConfig(false, true), allocator);

    confirm_call_count = 0;
    const decline_deps = Deps{
        .run = mockRun,
        .confirm = mockConfirmCounting,
        .printTitle = mockPrintTitle,
        .configPrint = mockConfigPrint,
    };
    try execute(cli_io, &writer, testConfig(false, true), commands, decline_deps);
    const out = std.mem.sliceTo(&buf, 0);
    try std.testing.expect(std.mem.indexOf(u8, out, "not added") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "successfully") == null);
}

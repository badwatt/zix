//! Application entry point and argument dispatch for zix.
//!
//! Parses CLI flags into a `Config`, validates it, resolves the rebuild flavor,
//! builds the argv commands, and delegates to `cli.execute`. Parse errors abort
//! with exit code 2 instead of falling through to the workflow.

const std = @import("std");
const ui = @import("../core/ui.zig");
const cli = @import("./cli.zig");
const completions = @import("./completions.zig");
const cmd = @import("../core/commands.zig");
const dry_run = @import("../core/dry_run.zig");
const hostname_mod = @import("./hostname.zig");
const Config = @import("config.zig").Config;
const PipelineStep = @import("config.zig").Step;
const pipelineStepFromName = @import("config.zig").stepFromName;
const step_names = @import("config.zig").step_names;
const StaticAllocator = @import("../core/static_allocator.zig");
const VERSION = @import("zon").version;

/// Result of interpreting command-line arguments.
pub const Intent = union(enum) {
    help,
    version,
    completions: completions.Shell,
    run,
    invalid,
};

/// Main orchestration function. Resolves the hostname, parses args, validates
/// config, builds commands, and runs the workflow. Returns errors that `main`
/// maps to exit codes.
pub fn run(
    cli_io: std.Io,
    writer: *std.Io.Writer,
    args: []const []const u8,
    deps: cli.Deps,
    static_allocator: *StaticAllocator,
) anyerror!void {
    std.debug.assert(args.len >= 1);

    const allocator = static_allocator.allocator();
    var deps_local = deps;

    var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const resolved = hostname_mod.resolve(cli_io, allocator, deps.environ, &hostname_buf);
    var config = Config.defaults(resolved);

    const intent = parse(args, &config, deps.err_writer);
    switch (intent) {
        .help => return ui.printHelp(writer),
        .version => return ui.printVersion(writer, VERSION),
        .completions => |shell| return completions.print(writer, shell),
        .invalid => return cli.Error.InvalidArgs,
        .run => {},
    }

    config.repo = try Config.expandTilde(allocator, deps.environ.get("HOME"), config.repo);

    if (config.validate()) |msg| {
        printValidationError(deps.err_writer, msg);
        return cli.Error.InvalidConfig;
    }

    // Abort before any side effect (pull, flake update, staging) when the
    // rebuild is selected and the hostname could not be resolved. A run that
    // skips the rebuild (e.g. `--only diff`) does not need it.
    if (config.runs(.rebuild) and std.mem.eql(u8, config.hostname, "unknown")) {
        return cli.Error.HostnameUnknown;
    }

    // `--dry-run` swaps the command runner for one that only prints.
    var dry = dry_run.DryRun{ .writer = writer };
    if (config.dry_run) deps_local.runner = dry.runner();

    // Probing the installed `nixos-rebuild` is only useful when the rebuild
    // step runs; `--only diff` must not invoke it at all.
    const flavor = if (config.runs(.rebuild))
        cli.detectFlavor(cli_io, deps_local)
    else
        cmd.RebuildFlavor.classic;
    const commands = try cli.buildCommands(config, flavor, allocator);

    static_allocator.transition_from_init_to_static();
    return cli.execute(cli_io, writer, config, commands, deps_local);
}

/// Prints a validation error prefixed with `Error:`.
fn printValidationError(writer: *std.Io.Writer, msg: []const u8) void {
    var buf: [256]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "Error: {s}", .{msg}) catch msg;
    ui.printError(writer, full) catch {};
}

/// Parser step: how many extra args were consumed, or a terminal intent.
const Step = union(enum) {
    consumed: usize,
    terminal: Intent,
};

/// Which `Config` field a value flag targets.
const ValueKey = enum { repo, hostname, keep, jobs, cores };

/// Parses arguments, folding flags into `config`. Non-run intents short-circuit.
fn parse(args: []const []const u8, config: *Config, writer: *std.Io.Writer) Intent {
    if (args.len <= 1) return .run;

    if (args.len == 2) {
        if (std.mem.eql(u8, args[1], "help")) return .help;
        if (std.mem.eql(u8, args[1], "version")) return .version;
    }

    const first = args[1];
    if (first.len == 0 or first[0] != '-') {
        printParseError(writer, "Unknown argument \"{s}\"", .{first});
        return .invalid;
    }
    return parseFlags(args, config, writer);
}

/// Walks the argument list, folding flags into `config`.
fn parseFlags(args: []const []const u8, config: *Config, writer: *std.Io.Writer) Intent {
    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];
        const step: Step = if (std.mem.startsWith(u8, arg, "--"))
            parseLong(arg, args, i, config, writer)
        else if (arg[0] == '-')
            parseShort(arg, args, i, config, writer)
        else blk: {
            printParseError(writer, "Unknown argument \"{s}\"", .{arg});
            break :blk .{ .terminal = .invalid };
        };
        switch (step) {
            .consumed => |n| i += 1 + n,
            .terminal => |intent| return intent,
        }
    }
    return .run;
}

/// Parses a `--long` flag (or `--long=value`) at `args[i]`.
fn parseLong(
    arg: []const u8,
    args: []const []const u8,
    i: usize,
    config: *Config,
    writer: *std.Io.Writer,
) Step {
    // GNU-style `--flag=value`: the value travels in the same argv entry.
    const eq = std.mem.indexOfScalar(u8, arg, '=');
    const name = if (eq) |index| arg[0..index] else arg;
    const inline_value: ?[]const u8 = if (eq) |index| arg[index + 1 ..] else null;

    if (std.mem.eql(u8, name, "--help")) {
        if (rejectInline(name, inline_value, writer)) return .{ .terminal = .invalid };
        return .{ .terminal = .help };
    }
    if (std.mem.eql(u8, name, "--version")) {
        if (rejectInline(name, inline_value, writer)) return .{ .terminal = .invalid };
        return .{ .terminal = .version };
    }
    if (std.mem.eql(u8, name, "--update")) {
        if (rejectInline(name, inline_value, writer)) return .{ .terminal = .invalid };
        config.update = true;
        return .{ .consumed = 0 };
    }
    if (std.mem.eql(u8, name, "--diff")) {
        if (rejectInline(name, inline_value, writer)) return .{ .terminal = .invalid };
        config.diff = true;
        return .{ .consumed = 0 };
    }
    if (std.mem.eql(u8, name, "--yes")) {
        if (rejectInline(name, inline_value, writer)) return .{ .terminal = .invalid };
        config.yes = true;
        return .{ .consumed = 0 };
    }
    if (std.mem.eql(u8, name, "--dry-run")) {
        if (rejectInline(name, inline_value, writer)) return .{ .terminal = .invalid };
        config.dry_run = true;
        return .{ .consumed = 0 };
    }
    if (std.mem.eql(u8, name, "--no-color")) {
        if (rejectInline(name, inline_value, writer)) return .{ .terminal = .invalid };
        return .{ .consumed = 0 };
    }
    if (std.mem.eql(u8, name, "--completions")) {
        const value = longValue(name, inline_value, args, i, writer) orelse
            return .{ .terminal = .invalid };
        const shell = completions.fromName(value.text) orelse {
            printParseError(writer, "Unknown shell \"{s}\" (valid: {s})", .{
                value.text,
                completions.names,
            });
            return .{ .terminal = .invalid };
        };
        return .{ .terminal = .{ .completions = shell } };
    }
    if (std.mem.eql(u8, name, "--only")) {
        const value = longValue(name, inline_value, args, i, writer) orelse
            return .{ .terminal = .invalid };
        config.only = parseSteps(value.text, writer) orelse
            return .{ .terminal = .invalid };
        return .{ .consumed = value.consumed };
    }
    if (std.mem.eql(u8, name, "--repo") or
        std.mem.eql(u8, name, "--hostname") or
        std.mem.eql(u8, name, "--keep") or
        std.mem.eql(u8, name, "--jobs") or
        std.mem.eql(u8, name, "--cores"))
    {
        const value = longValue(name, inline_value, args, i, writer) orelse
            return .{ .terminal = .invalid };
        if (!setValue(longKey(name), value.text, name, config, writer)) {
            return .{ .terminal = .invalid };
        }
        return .{ .consumed = value.consumed };
    }
    printParseError(writer, "Unknown flag \"{s}\"", .{name});
    return .{ .terminal = .invalid };
}

/// Reports `--flag=value` for a flag that takes no value.
fn rejectInline(name: []const u8, value: ?[]const u8, writer: *std.Io.Writer) bool {
    if (value == null) return false;
    printParseError(writer, "\"{s}\" flag does not take a value", .{name});
    return true;
}

/// A long flag's value and how many extra argv entries it consumed.
const FlagValue = struct {
    text: []const u8,
    consumed: usize,
};

/// Resolves a long flag's value. `--flag=value` carries it inline; plain
/// `--flag value` consumes the next argv entry.
fn longValue(
    name: []const u8,
    inline_value: ?[]const u8,
    args: []const []const u8,
    i: usize,
    writer: *std.Io.Writer,
) ?FlagValue {
    if (inline_value) |value| {
        if (value.len == 0) {
            printParseError(writer, "\"{s}\" flag requires an argument", .{name});
            return null;
        }
        return .{ .text = value, .consumed = 0 };
    }
    const value = takeValue(args, i, name, writer) orelse return null;
    return .{ .text = value, .consumed = 1 };
}

/// Parses a comma-separated `--only` list, or reports an unknown step.
fn parseSteps(value: []const u8, writer: *std.Io.Writer) ?std.EnumSet(PipelineStep) {
    var steps: std.EnumSet(PipelineStep) = .empty;
    var names = std.mem.splitScalar(u8, value, ',');
    while (names.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;
        const step = pipelineStepFromName(name) orelse {
            printParseError(writer, "Unknown step \"{s}\" (valid: {s})", .{ name, step_names });
            return null;
        };
        steps.insert(step);
    }
    if (steps.count() == 0) {
        printParseError(writer, "\"--only\" flag requires at least one step", .{});
        return null;
    }
    return steps;
}

/// Maps a long value-flag name to its `ValueKey`.
fn longKey(arg: []const u8) ValueKey {
    if (std.mem.eql(u8, arg, "--repo")) return .repo;
    if (std.mem.eql(u8, arg, "--hostname")) return .hostname;
    if (std.mem.eql(u8, arg, "--jobs")) return .jobs;
    if (std.mem.eql(u8, arg, "--cores")) return .cores;
    return .keep;
}

/// Parses a `-short` flag cluster at `args[i]`. A value flag must be last in
/// the cluster; it consumes the following argument.
fn parseShort(
    arg: []const u8,
    args: []const []const u8,
    i: usize,
    config: *Config,
    writer: *std.Io.Writer,
) Step {
    for (arg[1..], 0..) |flag, index| {
        switch (flag) {
            'h' => return .{ .terminal = .help },
            'v' => return .{ .terminal = .version },
            'd' => config.diff = true,
            'u' => config.update = true,
            'y' => config.yes = true,
            'r', 'n', 'k', 'j', 'c' => {
                var label_buf: [4]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buf, "-{c}", .{flag}) catch unreachable;
                // A value flag consumes the next argv, so anything after it in
                // the same cluster would be silently dropped. Reject instead.
                if (index + 1 != arg.len - 1) {
                    printParseError(writer, "\"{s}\" flag must be last in a cluster", .{label});
                    return .{ .terminal = .invalid };
                }
                const value = takeValue(args, i, label, writer) orelse return .{ .terminal = .invalid };
                if (!setValue(shortKey(flag), value, label, config, writer)) {
                    return .{ .terminal = .invalid };
                }
                return .{ .consumed = 1 };
            },
            else => {
                printParseError(writer, "Unknown flag \"-{c}\"", .{flag});
                return .{ .terminal = .invalid };
            },
        }
    }
    return .{ .consumed = 0 };
}

/// Maps a short value-flag character to its `ValueKey`.
fn shortKey(flag: u8) ValueKey {
    if (flag == 'r') return .repo;
    if (flag == 'n') return .hostname;
    if (flag == 'j') return .jobs;
    if (flag == 'c') return .cores;
    return .keep;
}

/// Reads the argument following a value flag, or reports a missing value.
/// Another flag is not accepted as a value.
fn takeValue(
    args: []const []const u8,
    i: usize,
    label: []const u8,
    writer: *std.Io.Writer,
) ?[]const u8 {
    if (i + 1 >= args.len) {
        printParseError(writer, "\"{s}\" flag requires an argument", .{label});
        return null;
    }
    const next = args[i + 1];
    if (next.len > 1 and next[0] == '-') {
        printParseError(writer, "\"{s}\" flag requires an argument", .{label});
        return null;
    }
    return next;
}

/// Assigns `value` to the field selected by `key`. Returns false when the
/// value was rejected (the error is already printed).
fn setValue(
    key: ValueKey,
    value: []const u8,
    label: []const u8,
    config: *Config,
    writer: *std.Io.Writer,
) bool {
    switch (key) {
        .repo => config.repo = value,
        .hostname => config.hostname = value,
        .keep => config.keep = parseNumber(u8, value, label, writer) orelse return false,
        .jobs => config.jobs = parseNumber(u16, value, label, writer) orelse return false,
        .cores => config.cores = parseNumber(u16, value, label, writer) orelse return false,
    }
    return true;
}

/// Parses a numeric flag value of at least 1, or reports why it was rejected.
/// The target type caps the value; an overflow names the accepted maximum so
/// `-k 256` is not misreported as "not numeric".
fn parseNumber(
    comptime T: type,
    value: []const u8,
    label: []const u8,
    writer: *std.Io.Writer,
) ?T {
    const num = std.fmt.parseInt(T, value, 10) catch |err| {
        switch (err) {
            error.Overflow => printParseError(
                writer,
                "Value of \"{s}\" flag must be at most {d}.",
                .{ label, std.math.maxInt(T) },
            ),
            error.InvalidCharacter => printParseError(
                writer,
                "Value of \"{s}\" flag is not numeric.",
                .{label},
            ),
        }
        return null;
    };
    if (num == 0) {
        printParseError(writer, "Value of \"{s}\" flag must be at least 1.", .{label});
        return null;
    }
    return num;
}

/// Formats and prints a parse error; overlong messages are dropped.
fn printParseError(writer: *std.Io.Writer, comptime fmt: []const u8, fmt_args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Error: " ++ fmt, fmt_args) catch return;
    ui.printError(writer, msg) catch {};
}

// --- Tests ---

/// Counts command-runner calls so tests can assert that nothing ran.
var commands_run: u32 = 0;

const test_runner = cli.Deps{
    .allocator = std.testing.allocator,
    .runner = .{ .runFn = noopRun, .captureFn = noopCapture, .probeFn = noopProbe },
    .ui = .{
        .title = echoTitle,
        .confirm = yesConfirm,
        .err = noopStatus,
        .success = noopStatus,
        .output = noopStatus,
        .config = noopConfig,
    },
    .environ = undefined,
    .err_writer = undefined,
};

fn noopRun(_: ?*anyopaque, _: std.Io, _: []const []const u8) anyerror!i32 {
    commands_run += 1;
    return 0;
}
fn noopCapture(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: []const []const u8,
) anyerror!@import("../core/process.zig").Capture {
    commands_run += 1;
    return .{ .code = 0, .stdout = try allocator.dupe(u8, " M file\n"), .stderr = &.{} };
}
fn noopProbe(_: ?*anyopaque, _: std.Io, _: []const []const u8) anyerror!i32 {
    commands_run += 1;
    return 0;
}
fn echoTitle(writer: *std.Io.Writer, text: []const u8) anyerror!void {
    try writer.writeAll(text);
    try writer.flush();
}
fn noopStatus(_: *std.Io.Writer, _: []const u8) anyerror!void {}
fn noopConfig(_: *std.Io.Writer, _: Config) anyerror!void {}
fn yesConfirm(_: *std.Io.Writer, _: bool, _: ?[]const u8) anyerror!bool {
    return true;
}

const intent_run: Intent = .run;
const intent_help: Intent = .help;
const intent_version: Intent = .version;
const intent_invalid: Intent = .invalid;

fn parseIntent(args: []const []const u8, config: *Config, writer: *std.Io.Writer) Intent {
    return parse(args, config, writer);
}

fn testConfig() Config {
    return Config.defaults("host");
}

test "parse returns run for bare invocation" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var config = testConfig();
    try std.testing.expectEqual(intent_run, parseIntent(&.{"zix"}, &config, &writer));
}

test "parse recognizes help and version words and flags" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var config = testConfig();
    try std.testing.expectEqual(intent_help, parseIntent(&.{ "zix", "-h" }, &config, &writer));
    try std.testing.expectEqual(intent_help, parseIntent(&.{ "zix", "--help" }, &config, &writer));
    try std.testing.expectEqual(intent_help, parseIntent(&.{ "zix", "help" }, &config, &writer));
    try std.testing.expectEqual(intent_version, parseIntent(&.{ "zix", "-v" }, &config, &writer));
    try std.testing.expectEqual(intent_version, parseIntent(&.{ "zix", "--version" }, &config, &writer));
    try std.testing.expectEqual(intent_version, parseIntent(&.{ "zix", "version" }, &config, &writer));
}

test "parse folds boolean flags" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var config = testConfig();
    try std.testing.expectEqual(
        intent_run,
        parseIntent(&.{ "zix", "-duy", "--update", "--dry-run", "--diff", "--yes", "--no-color" }, &config, &writer),
    );
    try std.testing.expect(config.update);
    try std.testing.expect(config.diff);
    try std.testing.expect(config.yes);
    try std.testing.expect(config.dry_run);
}

test "parse folds long value flags" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var config = testConfig();
    try std.testing.expectEqual(
        intent_run,
        parseIntent(&.{ "zix", "--repo", "/r", "--hostname", "h", "--keep", "5" }, &config, &writer),
    );
    try std.testing.expectEqualStrings("/r", config.repo);
    try std.testing.expectEqualStrings("h", config.hostname);
    try std.testing.expectEqual(@as(u8, 5), config.keep);
}

test "parse folds short value flags" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var config = testConfig();
    try std.testing.expectEqual(
        intent_run,
        parseIntent(&.{ "zix", "-r", "/r", "-n", "h", "-k", "3" }, &config, &writer),
    );
    try std.testing.expectEqualStrings("/r", config.repo);
    try std.testing.expectEqualStrings("h", config.hostname);
    try std.testing.expectEqual(@as(u8, 3), config.keep);
}

test "parse accepts a boolean flag before a value flag in a cluster" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var config = testConfig();
    try std.testing.expectEqual(
        intent_run,
        parseIntent(&.{ "zix", "-yr", "/r" }, &config, &writer),
    );
    try std.testing.expect(config.yes);
    try std.testing.expectEqualStrings("/r", config.repo);
}

test "parse accepts inline long values" {
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var config = testConfig();
    try std.testing.expectEqual(
        intent_run,
        parseIntent(&.{
            "zix", "--repo=/r", "--hostname=h", "--keep=5", "--jobs=4", "--cores=2",
        }, &config, &writer),
    );
    try std.testing.expectEqualStrings("/r", config.repo);
    try std.testing.expectEqualStrings("h", config.hostname);
    try std.testing.expectEqual(@as(u8, 5), config.keep);
    try std.testing.expectEqual(@as(?u16, 4), config.jobs);
    try std.testing.expectEqual(@as(?u16, 2), config.cores);
}

test "parse accepts an inline value that starts with a dash" {
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var config = testConfig();
    try std.testing.expectEqual(
        intent_run,
        parseIntent(&.{ "zix", "--repo=-weird" }, &config, &writer),
    );
    try std.testing.expectEqualStrings("-weird", config.repo);
}

test "parse folds the jobs flag" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    var short = testConfig();
    try std.testing.expectEqual(
        intent_run,
        parseIntent(&.{ "zix", "-j", "4" }, &short, &writer),
    );
    try std.testing.expectEqual(@as(?u16, 4), short.jobs);

    var long = testConfig();
    try std.testing.expectEqual(
        intent_run,
        parseIntent(&.{ "zix", "--jobs", "2" }, &long, &writer),
    );
    try std.testing.expectEqual(@as(?u16, 2), long.jobs);

    var cores = testConfig();
    try std.testing.expectEqual(
        intent_run,
        parseIntent(&.{ "zix", "-c", "6" }, &cores, &writer),
    );
    try std.testing.expectEqual(@as(?u16, 6), cores.cores);

    var cores_long = testConfig();
    try std.testing.expectEqual(
        intent_run,
        parseIntent(&.{ "zix", "--cores", "3" }, &cores_long, &writer),
    );
    try std.testing.expectEqual(@as(?u16, 3), cores_long.cores);
}

test "parse accepts the numeric maximums" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var config = testConfig();
    try std.testing.expectEqual(
        intent_run,
        parseIntent(&.{ "zix", "-k", "255", "-j", "65535", "-c", "65535" }, &config, &writer),
    );
    try std.testing.expectEqual(@as(u8, 255), config.keep);
    try std.testing.expectEqual(@as(?u16, 65535), config.jobs);
    try std.testing.expectEqual(@as(?u16, 65535), config.cores);
}

test "parse reports the accepted numeric range" {
    const Case = struct {
        args: []const []const u8,
        message: []const u8,
    };
    const cases = &[_]Case{
        .{ .args = &.{ "zix", "-k", "256" }, .message = "at most 255" },
        .{ .args = &.{ "zix", "-j", "65536" }, .message = "at most 65535" },
        .{ .args = &.{ "zix", "-c", "65536" }, .message = "at most 65535" },
        .{ .args = &.{ "zix", "-k", "0" }, .message = "at least 1" },
    };
    for (cases) |tc| {
        var buf: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        var config = testConfig();
        try std.testing.expectEqual(intent_invalid, parseIntent(tc.args, &config, &writer));
        try std.testing.expect(std.mem.indexOf(u8, &buf, tc.message) != null);
    }
}

test "parse recognizes --completions with every shell" {
    for (completions.all) |shell| {
        var buf: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        var config = testConfig();
        const intent = parseIntent(
            &.{ "zix", "--completions", completions.name(shell) },
            &config,
            &writer,
        );
        try std.testing.expectEqual(shell, intent.completions);
    }
}

test "parse accepts --completions=shell" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var config = testConfig();
    try std.testing.expectEqual(
        completions.Shell.fish,
        parseIntent(&.{ "zix", "--completions=fish" }, &config, &writer).completions,
    );
}

test "parse rejects an incomplete or unknown --completions" {
    const cases = [_][]const []const u8{
        &.{ "zix", "--completions" },
        &.{ "zix", "--completions=" },
        &.{ "zix", "--completions", "powershell" },
    };
    for (cases) |args| {
        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        var config = testConfig();
        try std.testing.expectEqual(intent_invalid, parseIntent(args, &config, &writer));
        try std.testing.expect(std.mem.indexOf(u8, &buf, "Error") != null);
    }
}

test "parse folds --only step lists" {
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var config = testConfig();
    try std.testing.expectEqual(
        intent_run,
        parseIntent(&.{ "zix", "--only", "pull, stage ,rebuild" }, &config, &writer),
    );
    const steps = config.only.?;
    try std.testing.expect(steps.contains(.pull));
    try std.testing.expect(steps.contains(.stage));
    try std.testing.expect(steps.contains(.rebuild));
    try std.testing.expect(!steps.contains(.diff));

    var alias = testConfig();
    try std.testing.expectEqual(
        intent_run,
        parseIntent(&.{ "zix", "--only=update" }, &alias, &writer),
    );
    try std.testing.expect(alias.only.?.contains(.flake));
}

test "parse rejects an invalid --only list" {
    const Case = struct {
        args: []const []const u8,
        message: []const u8,
    };
    const cases = &[_]Case{
        .{ .args = &.{ "zix", "--only" }, .message = "requires an argument" },
        .{ .args = &.{ "zix", "--only=" }, .message = "requires an argument" },
        .{ .args = &.{ "zix", "--only", "" }, .message = "requires at least one step" },
        .{ .args = &.{ "zix", "--only", "pull,nope" }, .message = "Unknown step \"nope\"" },
    };
    for (cases) |tc| {
        var buf: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        var config = testConfig();
        try std.testing.expectEqual(intent_invalid, parseIntent(tc.args, &config, &writer));
        try std.testing.expect(std.mem.indexOf(u8, &buf, tc.message) != null);
    }
}

test "parse rejects invalid input and reports it" {
    const cases = &[_][]const []const u8{
        &.{ "zix", "unknown" },
        &.{ "zix", "-x" },
        &.{ "zix", "--nope" },
        &.{ "zix", "-r" },
        &.{ "zix", "--hostname" },
        &.{ "zix", "-k", "abc" },
        &.{ "zix", "-k", "0" },
        &.{ "zix", "--keep", "x" },
        &.{ "zix", "-j", "0" },
        &.{ "zix", "-j", "abc" },
        &.{ "zix", "--jobs", "x" },
        &.{ "zix", "-c", "0" },
        &.{ "zix", "-c", "abc" },
        &.{ "zix", "--cores", "x" },
        &.{ "zix", "/repo", "extra" },
        &.{ "zix", "-r", "/repo", "trailing" },
        &.{ "zix", "-ry", "/repo" },
        &.{ "zix", "--repo", "--hostname", "h" },
        &.{ "zix", "-n", "-r" },
        &.{ "zix", "--repo=" },
        &.{ "zix", "--keep=0" },
        &.{ "zix", "--yes=1" },
        &.{ "zix", "--help=1" },
        &.{ "zix", "--nope=1" },
        &.{ "zix", "--no-color=1" },
    };
    for (cases) |args| {
        var buf: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        var config = testConfig();
        try std.testing.expectEqual(intent_invalid, parseIntent(args, &config, &writer));
        try std.testing.expect(std.mem.indexOf(u8, &buf, "Error") != null);
    }
}

test "parse drops overlong error messages" {
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var config = testConfig();
    var long_flag: [300]u8 = undefined;
    long_flag[0] = '-';
    @memset(long_flag[1..], 'x');
    const args = [_][]const u8{ "zix", &long_flag };
    try std.testing.expectEqual(intent_invalid, parseIntent(&args, &config, &writer));
}

test "run dispatches completions without running the workflow" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var ebuf: [1024]u8 = undefined;
    var ewriter = std.Io.Writer.fixed(&ebuf);
    var deps = test_runner;
    deps.environ = &environ;
    deps.err_writer = &ewriter;

    var memory: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    var static_allocator = StaticAllocator.init(fba.allocator());
    var buf: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try run(
        std.testing.io,
        &writer,
        &.{ "zix", "--completions", "bash" },
        deps,
        &static_allocator,
    );
    try std.testing.expect(std.mem.indexOf(u8, &buf, "complete -F _zix zix") != null);
}

test "run dispatches help and version without running the workflow" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var ebuf: [1024]u8 = undefined;
    var ewriter = std.Io.Writer.fixed(&ebuf);
    var deps = test_runner;
    deps.environ = &environ;
    deps.err_writer = &ewriter;

    for ([_][]const []const u8{
        &.{ "zix", "-h" },
        &.{ "zix", "--help" },
        &.{ "zix", "-v" },
        &.{ "zix", "--version" },
    }) |args| {
        var memory: [8192]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&memory);
        var static_allocator = StaticAllocator.init(fba.allocator());
        var buf: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try run(std.testing.io, &writer, args, deps, &static_allocator);
        try std.testing.expect(std.mem.indexOf(u8, &buf, "ZIX") != null);
    }
}

test "run rejects invalid arguments with InvalidArgs" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var ebuf: [1024]u8 = undefined;
    var ewriter = std.Io.Writer.fixed(&ebuf);
    var deps = test_runner;
    deps.environ = &environ;
    deps.err_writer = &ewriter;

    var memory: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    var static_allocator = StaticAllocator.init(fba.allocator());
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(
        cli.Error.InvalidArgs,
        run(std.testing.io, &writer, &.{ "zix", "-x" }, deps, &static_allocator),
    );
}

test "run rejects zero keep with InvalidArgs" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var ebuf: [1024]u8 = undefined;
    var ewriter = std.Io.Writer.fixed(&ebuf);
    var deps = test_runner;
    deps.environ = &environ;
    deps.err_writer = &ewriter;

    var memory: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    var static_allocator = StaticAllocator.init(fba.allocator());
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(
        cli.Error.InvalidArgs,
        run(std.testing.io, &writer, &.{ "zix", "-k", "0" }, deps, &static_allocator),
    );
}

test "run reaches the workflow with valid args" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var ebuf: [1024]u8 = undefined;
    var ewriter = std.Io.Writer.fixed(&ebuf);
    var deps = test_runner;
    deps.environ = &environ;
    deps.err_writer = &ewriter;

    var memory: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    var static_allocator = StaticAllocator.init(fba.allocator());
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try run(std.testing.io, &writer, &.{ "zix", "-n", "host" }, deps, &static_allocator);
    try std.testing.expect(std.mem.indexOf(u8, &buf, "ZIX Configuration") != null);
}

test "run rejects invalid config with InvalidConfig" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var ebuf: [1024]u8 = undefined;
    var ewriter = std.Io.Writer.fixed(&ebuf);
    var deps = test_runner;
    deps.environ = &environ;
    deps.err_writer = &ewriter;

    var memory: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    var static_allocator = StaticAllocator.init(fba.allocator());
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(
        cli.Error.InvalidConfig,
        run(std.testing.io, &writer, &.{ "zix", "-r", "" }, deps, &static_allocator),
    );
    try std.testing.expect(std.mem.indexOf(u8, &ebuf, "repo path cannot be empty") != null);
}

test "run with dry-run prints commands" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var ebuf: [1024]u8 = undefined;
    var ewriter = std.Io.Writer.fixed(&ebuf);
    var deps = test_runner;
    deps.environ = &environ;
    deps.err_writer = &ewriter;

    var memory: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    var static_allocator = StaticAllocator.init(fba.allocator());
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try run(std.testing.io, &writer, &.{ "zix", "--dry-run", "-y", "-n", "host" }, deps, &static_allocator);
    try std.testing.expect(std.mem.indexOf(u8, &buf, "$ ") != null);
}

test "run with --only diff does not require a hostname" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var ebuf: [1024]u8 = undefined;
    var ewriter = std.Io.Writer.fixed(&ebuf);
    var deps = test_runner;
    deps.environ = &environ;
    deps.err_writer = &ewriter;

    var memory: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    var static_allocator = StaticAllocator.init(fba.allocator());
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try run(
        std.testing.io,
        &writer,
        &.{ "zix", "--only", "diff", "--dry-run", "-y", "-n", "unknown" },
        deps,
        &static_allocator,
    );
    try std.testing.expect(std.mem.indexOf(u8, &buf, "diff-closures") != null);
    // The rebuild was not selected, so `nixos-rebuild` is never probed.
    try std.testing.expect(std.mem.indexOf(u8, &buf, "nixos-rebuild") == null);
}

test "run rejects unknown hostname before any command runs" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var ebuf: [1024]u8 = undefined;
    var ewriter = std.Io.Writer.fixed(&ebuf);
    var deps = test_runner;
    deps.environ = &environ;
    deps.err_writer = &ewriter;
    commands_run = 0;

    var memory: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    var static_allocator = StaticAllocator.init(fba.allocator());
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(
        cli.Error.HostnameUnknown,
        run(std.testing.io, &writer, &.{ "zix", "-n", "unknown" }, deps, &static_allocator),
    );
    try std.testing.expectEqual(@as(u32, 0), commands_run);
}

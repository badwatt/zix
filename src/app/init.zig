//! Application entry point and argument dispatch for zix.
//!
//! Parses CLI flags into a `Config`, validates it, resolves the rebuild flavor,
//! builds the argv commands, and delegates to `cli.execute`. Parse errors abort
//! with exit code 2 instead of falling through to the workflow.

const std = @import("std");
const ui = @import("../core/ui.zig");
const cli = @import("./cli.zig");
const cmd = @import("../core/commands.zig");
const dry_run = @import("../core/dry_run.zig");
const hostname_mod = @import("./hostname.zig");
const Config = @import("config.zig").Config;
const StaticAllocator = @import("../core/static_allocator.zig");
const VERSION = @import("zon").version;

/// Result of interpreting command-line arguments.
pub const Intent = enum { help, version, run, invalid };

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

    const intent = parse(args, &config, writer);
    switch (intent) {
        .help => return ui.printHelp(writer),
        .version => return ui.printVersion(writer, VERSION),
        .invalid => return cli.Error.InvalidArgs,
        .run => {},
    }

    config.repo = try Config.expandTilde(allocator, deps.environ.get("HOME"), config.repo);

    if (config.validate()) |msg| {
        printValidationError(writer, msg);
        return cli.Error.InvalidConfig;
    }

    // `--dry-run` swaps the command runner for one that only prints.
    var dry = dry_run.DryRun{ .writer = writer };
    if (config.dry_run) deps_local.runner = dry.runner();

    const flavor = cli.detectFlavor(cli_io, deps_local);
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
const ValueKey = enum { repo, hostname, keep };

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

/// Parses a `--long` flag at `args[i]`.
fn parseLong(
    arg: []const u8,
    args: []const []const u8,
    i: usize,
    config: *Config,
    writer: *std.Io.Writer,
) Step {
    if (std.mem.eql(u8, arg, "--help")) return .{ .terminal = .help };
    if (std.mem.eql(u8, arg, "--version")) return .{ .terminal = .version };
    if (std.mem.eql(u8, arg, "--update")) {
        config.update = true;
        return .{ .consumed = 0 };
    }
    if (std.mem.eql(u8, arg, "--diff")) {
        config.diff = true;
        return .{ .consumed = 0 };
    }
    if (std.mem.eql(u8, arg, "--yes")) {
        config.yes = true;
        return .{ .consumed = 0 };
    }
    if (std.mem.eql(u8, arg, "--dry-run")) {
        config.dry_run = true;
        return .{ .consumed = 0 };
    }
    if (std.mem.eql(u8, arg, "--repo") or
        std.mem.eql(u8, arg, "--hostname") or
        std.mem.eql(u8, arg, "--keep"))
    {
        const value = takeValue(args, i, arg, writer) orelse return .{ .terminal = .invalid };
        return setValue(longKey(arg), value, arg, config, writer);
    }
    printParseError(writer, "Unknown flag \"{s}\"", .{arg});
    return .{ .terminal = .invalid };
}

/// Maps a long value-flag name to its `ValueKey`.
fn longKey(arg: []const u8) ValueKey {
    if (std.mem.eql(u8, arg, "--repo")) return .repo;
    if (std.mem.eql(u8, arg, "--hostname")) return .hostname;
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
    for (arg[1..]) |flag| {
        switch (flag) {
            'h' => return .{ .terminal = .help },
            'v' => return .{ .terminal = .version },
            'd' => config.diff = true,
            'u' => config.update = true,
            'y' => config.yes = true,
            'r', 'n', 'k' => {
                var label_buf: [4]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buf, "-{c}", .{flag}) catch unreachable;
                const value = takeValue(args, i, label, writer) orelse return .{ .terminal = .invalid };
                return setValue(shortKey(flag), value, label, config, writer);
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
    return .keep;
}

/// Reads the argument following a value flag, or reports a missing value.
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
    return args[i + 1];
}

/// Assigns `value` to the field selected by `key`.
fn setValue(
    key: ValueKey,
    value: []const u8,
    label: []const u8,
    config: *Config,
    writer: *std.Io.Writer,
) Step {
    switch (key) {
        .repo => config.repo = value,
        .hostname => config.hostname = value,
        .keep => config.keep = parseKeep(value, label, writer) orelse
            return .{ .terminal = .invalid },
    }
    return .{ .consumed = 1 };
}

/// Parses a numeric `--keep` value (>= 1), or reports an error.
fn parseKeep(value: []const u8, label: []const u8, writer: *std.Io.Writer) ?u8 {
    const num = std.fmt.parseInt(u8, value, 10) catch {
        printParseError(writer, "Value of \"{s}\" flag is not numeric.", .{label});
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
};

fn noopRun(_: ?*anyopaque, _: std.Io, _: []const []const u8) anyerror!i32 {
    return 0;
}
fn noopCapture(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: []const []const u8,
) anyerror!@import("../core/process.zig").Capture {
    return .{ .code = 0, .stdout = try allocator.dupe(u8, " M file\n"), .stderr = &.{} };
}
fn noopProbe(_: ?*anyopaque, _: std.Io, _: []const []const u8) anyerror!i32 {
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
    try std.testing.expectEqual(Intent.run, parseIntent(&.{"zix"}, &config, &writer));
}

test "parse recognizes help and version words and flags" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var config = testConfig();
    try std.testing.expectEqual(Intent.help, parseIntent(&.{ "zix", "-h" }, &config, &writer));
    try std.testing.expectEqual(Intent.help, parseIntent(&.{ "zix", "--help" }, &config, &writer));
    try std.testing.expectEqual(Intent.help, parseIntent(&.{ "zix", "help" }, &config, &writer));
    try std.testing.expectEqual(Intent.version, parseIntent(&.{ "zix", "-v" }, &config, &writer));
    try std.testing.expectEqual(Intent.version, parseIntent(&.{ "zix", "--version" }, &config, &writer));
    try std.testing.expectEqual(Intent.version, parseIntent(&.{ "zix", "version" }, &config, &writer));
}

test "parse folds boolean flags" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var config = testConfig();
    try std.testing.expectEqual(
        Intent.run,
        parseIntent(&.{ "zix", "-duy", "--update", "--dry-run", "--diff", "--yes" }, &config, &writer),
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
        Intent.run,
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
        Intent.run,
        parseIntent(&.{ "zix", "-r", "/r", "-n", "h", "-k", "3" }, &config, &writer),
    );
    try std.testing.expectEqualStrings("/r", config.repo);
    try std.testing.expectEqualStrings("h", config.hostname);
    try std.testing.expectEqual(@as(u8, 3), config.keep);
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
        &.{ "zix", "/repo", "extra" },
        &.{ "zix", "-r", "/repo", "trailing" },
    };
    for (cases) |args| {
        var buf: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        var config = testConfig();
        try std.testing.expectEqual(Intent.invalid, parseIntent(args, &config, &writer));
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
    try std.testing.expectEqual(Intent.invalid, parseIntent(&args, &config, &writer));
}

test "run dispatches help and version without running the workflow" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var deps = test_runner;
    deps.environ = &environ;

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
    var deps = test_runner;
    deps.environ = &environ;

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
    var deps = test_runner;
    deps.environ = &environ;

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
    var deps = test_runner;
    deps.environ = &environ;

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
    var deps = test_runner;
    deps.environ = &environ;

    var memory: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    var static_allocator = StaticAllocator.init(fba.allocator());
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(
        cli.Error.InvalidConfig,
        run(std.testing.io, &writer, &.{ "zix", "-r", "" }, deps, &static_allocator),
    );
    try std.testing.expect(std.mem.indexOf(u8, &buf, "repo path cannot be empty") != null);
}

test "run with dry-run prints commands" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var deps = test_runner;
    deps.environ = &environ;

    var memory: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    var static_allocator = StaticAllocator.init(fba.allocator());
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try run(std.testing.io, &writer, &.{ "zix", "--dry-run", "-y", "-n", "host" }, deps, &static_allocator);
    try std.testing.expect(std.mem.indexOf(u8, &buf, "$ ") != null);
}

//! Application entry point and argument dispatch for zix.
//!
//! Parses CLI flags, validates config, transitions StaticAllocator
//! from .init to .static, and delegates to `cli.execute`.

const std = @import("std");
const io = @import("../core/io.zig");
const ui = @import("../core/ui.zig");
const cli_module = @import("./cli.zig");
const buildCommands = cli_module.buildCommands;
const execute = cli_module.execute;
const equal = std.mem.eql;
const process = @import("../core/process.zig");
const Config = @import("config.zig").Config;
const StaticAllocator = @import("../core/static_allocator.zig");
const VERSION = @import("zon").version;

/// Result of argument parsing: continue execution, show help, or show version.
const ParseResult = enum {
    success,
    help,
    version,
};

/// Main orchestration function. Parses args, validates config,
/// transitions allocator to .static, and runs CLI workflow.
/// Returns error on failure, exits gracefully for help/version.
pub fn run(
    cli_io: std.Io,
    writer: *std.Io.Writer,
    args: []const []const u8,
    deps: cli_module.Deps,
    static_allocator: *StaticAllocator,
) !void {
    std.debug.assert(args.len >= 1);

    const allocator = static_allocator.allocator();

    var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    var config = Config.defaults(&hostname_buf);

    // No args beyond program name — run with defaults.
    if (args.len <= 1) {
        std.debug.assert(config.keep > 0);
        const commands = try buildCommands(config, allocator);
        static_allocator.transition_from_init_to_static();
        return try execute(cli_io, writer, config, commands, deps);
    }

    const result = parseFlags(args, &config, writer);
    switch (result) {
        .help => return try ui.printHelp(writer),
        .version => return try ui.printVersion(writer, VERSION),
        .success => {},
    }

    if (config.validate()) |error_message| {
        return try io.printTo(writer, "{s}Error: {s}{s}\n", .{ io.Red, error_message, io.Reset });
    }

    const commands = try buildCommands(config, allocator);
    static_allocator.transition_from_init_to_static();
    return try execute(cli_io, writer, config, commands, deps);
}

/// Parses CLI flags and subcommands. Mutates config in place.
/// Returns `.help` or `.version` for early exit, `.success` to continue.
fn parseFlags(
    args: []const []const u8,
    config: *Config,
    writer: *std.Io.Writer,
) ParseResult {
    var arg_index: u32 = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        std.debug.assert(arg.len > 0);
        if (arg[0] == '-') {
            for (arg[1..]) |flag| {
                switch (flag) {
                    'h' => return .help,
                    'v' => return .version,
                    'd' => config.diff = true,
                    'u' => config.update = true,
                    'r', 'n', 'k' => {
                        arg_index += 1;
                        if (arg_index >= args.len) {
                            _ = io.printTo(
                                writer,
                                "{s}Error: \"-{c}\" flag requires an argument\n{s}",
                                .{ io.Red, flag, io.Reset },
                            ) catch {};
                            return .success;
                        }
                        if (flag == 'r') config.repo = args[arg_index];
                        if (flag == 'n') config.hostname = args[arg_index];
                        if (flag == 'k') {
                            const number = std.fmt.parseInt(u8, args[arg_index], 10) catch {
                                _ = io.printTo(
                                    writer,
                                    "{s}Error: Value of \"-k\" flag is not numeric.\n{s}",
                                    .{ io.Red, io.Reset },
                                ) catch {};
                                return .success;
                            };
                            config.keep = number;
                        }
                    },
                    else => {
                        _ = io.printTo(
                            writer,
                            "{s}Error: Unknown flag \"-{c}\"\n{s}",
                            .{ io.Red, flag, io.Reset },
                        ) catch {};
                        return .success;
                    },
                }
            }
        } else {
            if (equal(u8, arg, "help")) return .help;
            if (equal(u8, arg, "version")) return .version;
            _ = io.printTo(
                writer,
                "{s}Error: Unknown argument \"{s}\"\n{s}",
                .{ io.Red, arg, io.Reset },
            ) catch {};
            return .success;
        }
    }
    return .success;
}

/// No-op mock for process.run in tests.
fn mockRun(_: std.Io, _: []const u8, _: process.RunOpts) anyerror!i32 {
    return 0;
}
/// Always-yes mock for ui.confirm in tests.
noinline fn mockConfirm(
    _: *std.Io.Writer,
    _: bool,
    _: ?[]const u8,
) anyerror!bool {
    return true;
}
/// No-op mock for ui.printTitle in tests.
noinline fn mockPrintTitle(_: *std.Io.Writer, _: []const u8) anyerror!void {}
/// No-op mock for ui.configPrint in tests.
noinline fn mockConfigPrint(_: *std.Io.Writer, _: Config) anyerror!void {}

test "run flag branches" {
    const test_io = std.testing.io;

    var memory: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);

    const TestCase = struct {
        args: []const []const u8,
        expect_contains: ?[]const u8 = null,
    };
    const cases = &[_]TestCase{
        .{ .args = &.{ "zix", "-h" }, .expect_contains = "ZIX" },
        .{ .args = &.{ "zix", "-v" }, .expect_contains = VERSION },
        .{ .args = &.{ "zix", "help" }, .expect_contains = "ZIX" },
        .{ .args = &.{ "zix", "version" }, .expect_contains = VERSION },
        .{ .args = &.{ "zix", "unknown" }, .expect_contains = "Unknown argument" },
        .{ .args = &.{ "zix", "-r" }, .expect_contains = "requires an argument" },
        .{ .args = &.{ "zix", "-n" }, .expect_contains = "requires an argument" },
        .{ .args = &.{ "zix", "-k", "abc" }, .expect_contains = "not numeric" },
        .{ .args = &.{ "zix", "-k", "5", "-h" }, .expect_contains = "ZIX" },
        .{ .args = &.{ "zix", "-x" }, .expect_contains = "Unknown flag" },
        .{ .args = &.{ "zix", "-d" }, .expect_contains = null },
        .{ .args = &.{ "zix", "-u" }, .expect_contains = null },
        .{ .args = &.{ "zix", "-d", "help" }, .expect_contains = "ZIX" },
        .{ .args = &.{ "zix", "-d", "unknown" }, .expect_contains = "Unknown argument" },
    };

    const mock_deps = cli_module.Deps{
        .run = mockRun,
        .confirm = mockConfirm,
        .printTitle = mockPrintTitle,
        .configPrint = mockConfigPrint,
    };

    for (cases) |tc| {
        fba.reset();
        var static_alloc = StaticAllocator.init(fba.allocator());
        var buf = [_]u8{0} ** 2048;
        var writer = std.Io.Writer.fixed(&buf);
        run(test_io, &writer, tc.args, mock_deps, &static_alloc) catch continue;
        if (tc.expect_contains) |needle| {
            const out = std.mem.sliceTo(&buf, 0);
            try std.testing.expect(std.mem.indexOf(u8, out, needle) != null);
        }
    }
}

test "run reaches cli" {
    const test_io = std.testing.io;
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    var memory: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    var static_allocator = StaticAllocator.init(fba.allocator());

    const mock_deps = cli_module.Deps{
        .run = mockRun,
        .confirm = mockConfirm,
        .printTitle = mockPrintTitle,
        .configPrint = mockConfigPrint,
    };

    try run(test_io, &writer, &.{"zix"}, mock_deps, &static_allocator);
}

test "run rejects invalid config via flags" {
    const test_io = std.testing.io;
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    var memory: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    var static_allocator = StaticAllocator.init(fba.allocator());

    const mock_deps = cli_module.Deps{
        .run = mockRun,
        .confirm = mockConfirm,
        .printTitle = mockPrintTitle,
        .configPrint = mockConfigPrint,
    };

    try run(test_io, &writer, &.{ "zix", "-k", "0" }, mock_deps, &static_allocator);
    const out = std.mem.sliceTo(&buf, 0);
    try std.testing.expect(std.mem.indexOf(u8, out, "Error") != null);
}
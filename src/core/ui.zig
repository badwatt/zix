//! Terminal UI: titles, help, version, config display, prompts, and status
//! messages. Also defines the `UserIo` port used by the workflow.
//!
//! All output uses `io.printTo` for immediate flush. `confirm` reads
//! stdin byte-by-byte via posix.read to avoid buffering issues.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("io.zig");
const Config = @import("../app/config.zig").Config;
const equal = std.mem.eql;

/// Maximum border width for printed titles.
const MAX_TITLE_LEN: u32 = 128;

/// User-facing I/O port. `terminal` is the production implementation; tests
/// and `--dry-run` inject their own.
pub const UserIo = struct {
    title: *const fn (*std.Io.Writer, []const u8) anyerror!void,
    confirm: *const fn (*std.Io.Writer, bool, ?[]const u8) anyerror!bool,
    err: *const fn (*std.Io.Writer, []const u8) anyerror!void,
    success: *const fn (*std.Io.Writer, []const u8) anyerror!void,
    output: *const fn (*std.Io.Writer, []const u8) anyerror!void,
    config: *const fn (*std.Io.Writer, Config) anyerror!void,
};

/// Production `UserIo` writing to the caller-provided writer.
///
/// The stdin-reading `confirm` is replaced by a stub under `zig build test`:
/// exercising it would require taking over fd 0, which the test runner's
/// `--listen=-` protocol owns. `confirmAlloc` covers the parsing logic.
pub const terminal = UserIo{
    .title = printTitle,
    .confirm = if (builtin.is_test) testConfirm else confirm,
    .err = printError,
    .success = printSuccess,
    .output = printOutput,
    .config = configPrint,
};

fn testConfirm(_: *std.Io.Writer, _: bool, _: ?[]const u8) anyerror!bool {
    return true;
}

// --- Formatting ---

/// Prints a red error message.
pub fn printError(writer: *std.Io.Writer, msg: []const u8) !void {
    std.debug.assert(msg.len > 0);
    try io.printTo(writer, "{s}{s}{s}\n", .{ io.style(io.Red), msg, io.style(io.Reset) });
}

/// Prints a green success message.
pub fn printSuccess(writer: *std.Io.Writer, msg: []const u8) !void {
    std.debug.assert(msg.len > 0);
    try io.printTo(writer, "{s}{s}{s}\n", .{ io.style(io.Green), msg, io.style(io.Reset) });
}

/// Prints captured command output verbatim.
pub fn printOutput(writer: *std.Io.Writer, output: []const u8) !void {
    try writer.writeAll(output);
    try writer.flush();
}

/// Prints a bordered, colored title with asterisk borders.
/// Asserts text is non-empty and fits within MAX_TITLE_LEN.
pub fn printTitle(writer: *std.Io.Writer, text: []const u8) !void {
    std.debug.assert(text.len > 0);
    std.debug.assert(text.len + 4 <= MAX_TITLE_LEN);

    var border_buf: [MAX_TITLE_LEN]u8 = undefined;
    const border = border_buf[0 .. text.len + 4];
    for (border) |*c| {
        c.* = '*';
    }
    try io.printTo(
        writer,
        "{s}\n{s}\n* {s}{s}{s} *\n{s}\n{s}",
        .{
            io.style(io.Blue),
            border,
            io.style(io.Red),
            text,
            io.style(io.Blue),
            border,
            io.style(io.Reset),
        },
    );
}

/// Prints the CLI help text with flag descriptions.
pub fn printHelp(writer: *std.Io.Writer) !void {
    try io.printTo(writer,
        \\
        \\ *****************************************************
        \\  ZIX - A simple CLI tool to update your nixos system
        \\ *****************************************************
        \\ -r, --repo      : set repo path (default is $HOME/.dotfiles)
        \\ -n, --hostname  : set hostname (default is OS hostname)
        \\ -k, --keep      : set generations to keep (default is 10)
        \\ -u, --update    : set update to true (default is false)
        \\ -d, --diff      : set diff to true (default is false)
        \\ -y, --yes       : assume yes for all prompts (default is false)
        \\     --dry-run   : print commands without executing them
        \\ -h, --help      : Display this help message
        \\ -v, --version   : Display the current version
        \\
        \\
    , .{});
}

/// Prints the version number with colored formatting.
/// Asserts version string is non-empty.
pub fn printVersion(writer: *std.Io.Writer, version: []const u8) !void {
    std.debug.assert(version.len > 0);
    try io.printTo(
        writer,
        "{s}\nZIX version: {s}{s}\n{s}",
        .{ io.style(io.Yellow), io.style(io.Cyan), version, io.style(io.Reset) },
    );
}

/// Prints a single config line: `◉ label = value`. Uses comptime type
/// detection to format strings vs other types.
fn printConfigLine(
    writer: *std.Io.Writer,
    label: []const u8,
    value: anytype,
) !void {
    std.debug.assert(label.len > 0);
    const value_fmt = comptime if (@TypeOf(value) == []const u8) "{" ++ "s}" else "{" ++ "}";
    try io.printTo(writer, "{s}◉ {s}{s}{s} = {s}" ++ value_fmt ++ "{s}\n", .{
        io.style(io.Cyan),
        io.style(io.Red),
        label,
        io.style(io.Reset),
        io.style(io.Cyan),
        value,
        io.style(io.Reset),
    });
}

/// Prints the visible config fields with colored labels via `printConfigLine`.
/// `yes` is omitted (it only skips prompts); `dry-run` is shown when set so the
/// user never mistakes a dry run for a real one. Always ends with a newline
/// so a following `printTitle` renders its leading newline as a blank line.
pub fn configPrint(writer: *std.Io.Writer, config: Config) !void {
    std.debug.assert(config.repo.len > 0);
    try printConfigLine(writer, "repo", config.repo);
    try printConfigLine(writer, "hostname", config.hostname);
    try printConfigLine(writer, "keep", config.keep);
    try printConfigLine(writer, "update", config.update);
    try printConfigLine(writer, "diff", config.diff);
    if (config.dry_run) try printConfigLine(writer, "dry-run", config.dry_run);
}

/// Reads a yes/no answer from stdin using raw posix.read.
/// Shows a prompt with optional message and (Y/n) or (y/N) hint.
/// Returns true for yes, false for no. Falls back to `default_value`
/// for empty input.
pub fn confirm(
    writer: *std.Io.Writer,
    default_value: bool,
    msg: ?[]const u8,
) !bool {
    if (msg) |value| std.debug.assert(value.len > 0);

    try writeConfirmPrompt(writer, default_value, msg);

    var buf: [256]u8 = undefined;
    var byte_index: u32 = 0;
    while (byte_index < buf.len - 1) {
        const bytes_read = std.posix.read(0, buf[byte_index .. byte_index + 1]) catch |err| {
            if (err == error.WouldBlock) continue;
            return err;
        };
        if (bytes_read == 0) return false;
        if (buf[byte_index] == '\n') {
            return parseConfirmResponse(
                buf[0..byte_index],
                default_value,
            );
        }
        byte_index += 1;
    }
    return false;
}

/// Writes the confirm prompt with colored (Y/n) or (y/N) hint.
fn writeConfirmPrompt(
    writer: *std.Io.Writer,
    default_value: bool,
    msg: ?[]const u8,
) !void {
    const hint_color = if (default_value) io.Green else io.Red;
    const hint = if (default_value) "(Y/n)" else "(y/N)";
    if (msg) |value| {
        try io.printTo(writer, "\n{s}{s}{s} {s}{s}{s}: ", .{
            io.style(io.Yellow),
            value,
            io.style(io.Reset),
            io.style(hint_color),
            hint,
            io.style(io.Reset),
        });
    } else {
        try io.printTo(writer, "\n{s}Proceed?{s} {s}{s}{s}: ", .{
            io.style(io.Yellow),
            io.style(io.Reset),
            io.style(hint_color),
            hint,
            io.style(io.Reset),
        });
    }
    try writer.flush();
}

/// Parses a yes/no response string. "y"/"yes" → true, "n"/"no" → false.
/// Empty input falls back to `default_value`. Unknown input defaults to false.
fn parseConfirmResponse(line: []const u8, default_value: bool) bool {
    var lower_buf: [256]u8 = undefined;
    if (line.len > lower_buf.len) return false;
    const lower = std.ascii.lowerString(&lower_buf, line);

    if (equal(u8, lower, "y") or equal(u8, lower, "yes")) return true;
    if (equal(u8, lower, "n") or equal(u8, lower, "no")) return false;
    if (line.len == 0) return default_value;
    return false;
}

/// Allocating variant of confirm that reads from a `std.Io.Reader`.
/// Used in tests where stdin is replaced with a fixed buffer.
fn confirmAlloc(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    default_value: bool,
    msg: ?[]const u8,
) !bool {
    if (msg) |value| std.debug.assert(value.len > 0);

    try writeConfirmPrompt(writer, default_value, msg);

    const line = reader.takeDelimiterExclusive('\n') catch |err| {
        if (err == error.EndOfStream) return false;
        return err;
    };
    return parseConfirmResponse(line, default_value);
}

// --- Tests ---

test "printError and printSuccess wrap in color" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try printError(&writer, "bad");
    try std.testing.expect(std.mem.indexOf(u8, &buf, "bad") != null);
    try std.testing.expect(std.mem.indexOf(u8, &buf, io.Red) != null);

    var buf2: [128]u8 = undefined;
    var writer2 = std.Io.Writer.fixed(&buf2);
    try printSuccess(&writer2, "good");
    try std.testing.expect(std.mem.indexOf(u8, &buf2, "good") != null);
    try std.testing.expect(std.mem.indexOf(u8, &buf2, io.Green) != null);
}

test "styles are dropped when color is disabled" {
    io.color_enabled = false;
    defer io.color_enabled = true;

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try printError(&writer, "bad");
    try std.testing.expectEqualStrings("bad\n", buf[0..writer.end]);

    var buf2: [256]u8 = undefined;
    var writer2 = std.Io.Writer.fixed(&buf2);
    try printTitle(&writer2, "ZIX");
    try std.testing.expect(std.mem.indexOf(u8, buf2[0..writer2.end], "\x1b[") == null);
}

test "printOutput writes verbatim" {
    var buf: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try printOutput(&writer, "raw output\n");
    try std.testing.expectEqualStrings("raw output\n", buf[0..writer.end]);
}

test "printTitle border format" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try printTitle(&writer, "ZIX");
    const s = std.mem.sliceTo(&buf, '\n');
    try std.testing.expect(s.len > 0);
}

test "printHelp writes help text" {
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try printHelp(&writer);
    const out = std.mem.sliceTo(&buf, 0);
    try std.testing.expect(std.mem.indexOf(u8, out, "ZIX") != null);
}

test "printVersion writes version" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try printVersion(&writer, "1.0.0");
    const out = std.mem.sliceTo(&buf, 0);
    try std.testing.expect(std.mem.indexOf(u8, out, "1.0.0") != null);
}

test "configPrint renders visible fields only" {
    io.color_enabled = false;
    defer io.color_enabled = true;

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const config = Config{
        .repo = "~/.dotfiles",
        .hostname = "nixos",
        .keep = 10,
        .update = false,
        .diff = true,
        .yes = true,
        .dry_run = true,
    };
    try configPrint(&writer, config);
    const out = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, out, "repo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hostname") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "keep") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "update") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "diff") != null);
    // `yes` is hidden; `dry-run` is shown because it changes what happens.
    try std.testing.expect(std.mem.indexOf(u8, out, "yes") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "dry-run = true") != null);
    // Ends with a newline so the next title renders a separating blank line.
    try std.testing.expectEqual(@as(u8, '\n'), out[out.len - 1]);
}

test "configPrint omits dry-run when it is off" {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try configPrint(&writer, Config{
        .repo = "r",
        .hostname = "h",
        .keep = 1,
        .update = false,
        .diff = false,
        .yes = false,
        .dry_run = false,
    });
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "dry-run") == null);
}

test "config block is separated from the next title by a blank line" {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try configPrint(&writer, Config{
        .repo = "r",
        .hostname = "h",
        .keep = 1,
        .update = false,
        .diff = false,
        .yes = true,
        .dry_run = false,
    });
    try printTitle(&writer, "Git Pull");
    const out = buf[0..writer.end];

    // Last config line ends with `Reset\n`; the title then emits `Blue\n`,
    // which is what renders as the separating blank line.
    var needle_buf: [64]u8 = undefined;
    const needle = try std.fmt.bufPrint(&needle_buf, "false{s}\n{s}\n", .{ io.Reset, io.Blue });
    try std.testing.expect(std.mem.indexOf(u8, out, needle) != null);
}

test "terminal port exposes production functions" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try terminal.title(&writer, "T");
    _ = try terminal.confirm(&writer, true, null);
    try terminal.err(&writer, "e");
    try terminal.success(&writer, "s");
    try terminal.output(&writer, "o");
    try terminal.config(&writer, Config{
        .repo = "r",
        .hostname = "h",
        .keep = 1,
        .update = false,
        .diff = false,
        .yes = false,
        .dry_run = false,
    });
}

test "confirm responses" {
    const TestCase = struct {
        input: []const u8,
        default_value: bool,
        expected: bool,
        msg: ?[]const u8 = null,
    };
    const cases = &[_]TestCase{
        .{ .input = "y\n", .default_value = false, .expected = true },
        .{ .input = "yes\n", .default_value = false, .expected = true },
        .{ .input = "n\n", .default_value = true, .expected = false },
        .{ .input = "no\n", .default_value = true, .expected = false },
        .{ .input = "\n", .default_value = true, .expected = true },
        .{ .input = "\n", .default_value = false, .expected = false },
        .{ .input = "maybe\n", .default_value = true, .expected = false },
        .{ .input = "maybe\n", .default_value = false, .expected = false },
        .{ .input = "y\n", .default_value = false, .expected = true, .msg = "Sure" },
    };
    inline for (cases) |tc| {
        var wbuf: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&wbuf);
        var reader = std.Io.Reader.fixed(tc.input);
        const result = try confirmAlloc(
            &reader,
            &writer,
            tc.default_value,
            tc.msg,
        );
        try std.testing.expectEqual(tc.expected, result);
    }
}

test "confirm empty input hits EndOfStream" {
    var wbuf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&wbuf);
    var reader = std.Io.Reader.fixed("");
    const result = try confirmAlloc(&reader, &writer, true, null);
    try std.testing.expectEqual(false, result);
}

test "parseConfirmResponse rejects overlong line" {
    var line: [300]u8 = undefined;
    @memset(&line, 'x');
    try std.testing.expectEqual(false, parseConfirmResponse(&line, true));
}

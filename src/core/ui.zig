//! Terminal UI functions: titles, help, version, config display, and confirmation prompts.
//!
//! All output uses `io.printTo` for immediate flush. `confirm` reads
//! stdin byte-by-byte via posix.read to avoid buffering issues.

const std = @import("std");
const io = @import("io.zig");
const equal = std.mem.eql;

/// Maximum border width for printed titles.
const MAX_TITLE_LEN: u32 = 128;

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
        .{ io.Blue, border, io.Red, text, io.Blue, border, io.Reset },
    );
}

/// Prints the CLI help text with flag descriptions.
pub fn printHelp(writer: *std.Io.Writer) !void {
    try io.printTo(writer,
        \\
        \\ *****************************************************
        \\  ZIX - A simple CLI tool to update your nixos system
        \\ *****************************************************
        \\ -r : set repo path (default is $HOME/.dotfiles)
        \\ -n : set hostname (default is OS hostname)
        \\ -k : set generations to keep (default is 10)
        \\ -u : set update to true (default is false)
        \\ -d : set diff to true (default is false)
        \\ -h, help : Display this help message
        \\ -v, version : Display the current version
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
        .{ io.Yellow, io.Cyan, version, io.Reset },
    );
}

/// Prints a single config line: `◉ label = value`. Uses comptime type
/// detection to format strings vs other types. Suppresses trailing
/// newline for the last field when `options.new_line` is false.
fn printConfigLine(
    writer: *std.Io.Writer,
    label: []const u8,
    value: anytype,
    options: struct { new_line: bool = true },
) !void {
    std.debug.assert(label.len > 0);
    const value_fmt = comptime if (@TypeOf(value) == []const u8) "{" ++ "s}" else "{" ++ "}";
    try io.printTo(writer, "{s}◉ {s}{s}{s} = {s}" ++ value_fmt ++ "{s}{s}", .{
        io.Cyan,
        io.Red,
        label,
        io.Reset,
        io.Cyan,
        value,
        io.Reset,
        if (options.new_line) "\n" else "",
    });
}

/// Prints all config fields with colored labels via `printConfigLine`.
/// The last field omits the trailing newline.
pub fn configPrint(writer: *std.Io.Writer, config: @import("../app/config.zig").Config) !void {
    std.debug.assert(config.repo.len > 0);
    const fields = @typeInfo(@TypeOf(config)).@"struct".fields;
    inline for (fields, 0..) |field, i| {
        const is_last = i == fields.len - 1;
        const value = @field(config, field.name);
        try printConfigLine(writer, field.name, value, .{ .new_line = !is_last });
    }
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
    const hint = if (default_value)
        std.fmt.comptimePrint("{s}(Y/n){s}", .{ io.Green, io.Reset })
    else
        std.fmt.comptimePrint("{s}(y/N){s}", .{ io.Red, io.Reset });
    if (msg) |value| {
        try io.printTo(writer, "\n{s}{s}{s} {s}: ", .{ io.Yellow, value, io.Reset, hint });
    } else {
        try io.printTo(writer, "\n\n{s}Proceed?{s} {s}: ", .{ io.Yellow, io.Reset, hint });
    }
    try writer.flush();
}

/// Parses a yes/no response string. "y"/"yes" → true, "n"/"no" → false.
/// Empty input falls back to `default_value`. Unknown input defaults to false.
fn parseConfirmResponse(line: []const u8, default_value: bool) bool {
    std.debug.assert(line.len <= 256);

    var lower_buf: [256]u8 = undefined;
    if (line.len > lower_buf.len) return false;
    const lower = std.ascii.lowerString(&lower_buf, line);

    if (equal(u8, lower, "y") or equal(u8, lower, "yes")) return true;
    if (equal(u8, lower, "n") or equal(u8, lower, "no")) return false;
    if (equal(u8, lower, "") or line.len == 0) return default_value;
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

test "configPrint renders all fields" {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const config = @import("../app/config.zig").Config{
        .repo = "~/.dotfiles",
        .hostname = "nixos",
        .keep = 10,
        .update = false,
        .diff = true,
    };
    try configPrint(&writer, config);
    try std.testing.expect(std.mem.indexOf(u8, &buf, "repo") != null);
    try std.testing.expect(std.mem.indexOf(u8, &buf, "hostname") != null);
    try std.testing.expect(std.mem.indexOf(u8, &buf, "keep") != null);
    try std.testing.expect(std.mem.indexOf(u8, &buf, "update") != null);
    try std.testing.expect(std.mem.indexOf(u8, &buf, "diff") != null);
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
        .{ .input = "", .default_value = true, .expected = false },
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

test "confirm empty input" {
    var wbuf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&wbuf);
    var reader = std.Io.Reader.fixed("y\n");
    const result = try confirmAlloc(&reader, &writer, true, null);
    try std.testing.expectEqual(true, result);
}

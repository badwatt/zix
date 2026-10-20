//! I/O utilities: formatted output and ANSI style constants.
//!
//! `printTo` wraps `Writer.print` + `flush` for immediate output.
//! Style constants provide shorthand ANSI escape sequences.

const std = @import("std");

// --- Formatting ---

/// Writes formatted text to `writer` and flushes immediately.
/// Asserts format string is non-empty.
pub fn printTo(
    writer: *std.Io.Writer,
    comptime format: []const u8,
    args: anytype,
) !void {
    // Assert preconditions: format must not be empty.
    std.debug.assert(format.len > 0);

    try writer.print(format, args);
    try writer.flush();
}

// --- ANSI Styles ---

/// Whether ANSI style sequences are emitted. Set once at startup from
/// `colorSupported`; tests may toggle it.
pub var color_enabled: bool = true;

/// Returns `code` when color is enabled, otherwise an empty string.
pub fn style(code: []const u8) []const u8 {
    return if (color_enabled) code else "";
}

/// True when the environment and stdout allow colored output: `NO_COLOR` is
/// unset or empty, `TERM` is not `dumb`, and stdout is a terminal.
pub fn colorSupported(io: std.Io, environ: *std.process.Environ.Map) bool {
    if (!colorAllowedByEnv(environ)) return false;
    return std.Io.File.stdout().isTty(io) catch false;
}

/// Environment half of `colorSupported`: `NO_COLOR` and `TERM=dumb` opt out.
fn colorAllowedByEnv(environ: *std.process.Environ.Map) bool {
    if (environ.get("NO_COLOR")) |value| {
        if (value.len > 0) return false;
    }
    if (environ.get("TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb")) return false;
    }
    return true;
}

/// ANSI foreground color escape sequences and reset codes.
pub const Red = "\x1b[31m";
pub const Green = "\x1b[32m";
pub const Yellow = "\x1b[33m";
pub const Blue = "\x1b[34m";
pub const Cyan = "\x1b[36m";
pub const Reset = "\x1b[0m";

test "printTo writes exact bytes" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try printTo(&writer, "hello {d} {s}", .{ 42, "world" });
    try std.testing.expectEqualStrings("hello 42 world", buf[0..14]);
}

test "style honors color_enabled" {
    color_enabled = false;
    defer color_enabled = true;
    try std.testing.expectEqualStrings("", style(Red));
    try std.testing.expectEqualStrings("", style(Reset));
    color_enabled = true;
    try std.testing.expectEqualStrings(Red, style(Red));
}

test "colorSupported honors NO_COLOR and TERM" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    try std.testing.expect(colorAllowedByEnv(&environ));

    try environ.put("NO_COLOR", "1");
    try std.testing.expect(!colorAllowedByEnv(&environ));
    try environ.put("NO_COLOR", "");
    try std.testing.expect(colorAllowedByEnv(&environ));

    try environ.put("TERM", "dumb");
    try std.testing.expect(!colorAllowedByEnv(&environ));
    try environ.put("TERM", "xterm-256color");
    try std.testing.expect(colorAllowedByEnv(&environ));

    // The terminal probe depends on the real stdout; just exercise it.
    _ = colorSupported(std.testing.io, &environ);
}

test "style constants are non-empty" {
    for ([_][]const u8{ Red, Green, Yellow, Blue, Cyan, Reset }) |code| {
        try std.testing.expect(code.len > 0);
    }
}

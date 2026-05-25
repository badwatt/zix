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

/// ANSI foreground color escape sequences and reset codes.
pub const Red = "\x1b[31m";
pub const Green = "\x1b[32m";
pub const Yellow = "\x1b[33m";
pub const Blue = "\x1b[34m";
pub const Magenta = "\x1b[35m";
pub const Cyan = "\x1b[36m";
pub const Gray = "\x1b[37m";
pub const Black = "\x1b[30m";
pub const Reset = "\x1b[0m";
pub const Bold = "\x1b[1m";
pub const Underline = "\x1b[4m";

test "printTo writes exact bytes" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try printTo(&writer, "hello {d} {s}", .{ 42, "world" });
    try std.testing.expectEqualStrings("hello 42 world", buf[0..14]);
}

test "style constants are non-empty" {
    const fields = @typeInfo(@This()).@"struct".fields;
    inline for (fields) |field| {
        const val = @field(@This(), field.name);
        try std.testing.expect(val.len > 0);
    }
}
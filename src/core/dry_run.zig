//! `--dry-run` command runner: prints argv lists instead of executing them.

const std = @import("std");
const process = @import("process.zig");

/// State for the dry-run runner: where commands are printed.
pub const DryRun = struct {
    writer: *std.Io.Writer,

    /// Returns a `Runner` bound to this state.
    pub fn runner(self: *DryRun) process.Runner {
        return .{ .ctx = self, .runFn = run, .captureFn = capture, .probeFn = probe };
    }

    fn run(ctx: ?*anyopaque, _: std.Io, argv: process.Runner.Command) anyerror!i32 {
        try printCommand(state(ctx).writer, argv);
        return 0;
    }

    fn capture(
        ctx: ?*anyopaque,
        _: std.Io,
        _: std.mem.Allocator,
        _: std.Io.Timeout,
        argv: process.Runner.Command,
    ) anyerror!process.Capture {
        try printCommand(state(ctx).writer, argv);
        return .{ .code = 0, .stdout = &.{}, .stderr = &.{} };
    }

    fn probe(ctx: ?*anyopaque, _: std.Io, argv: process.Runner.Command) anyerror!i32 {
        try printCommand(state(ctx).writer, argv);
        return 0;
    }

    fn state(ctx: ?*anyopaque) *DryRun {
        return @ptrCast(@alignCast(ctx.?));
    }
};

/// Writes `$ prog arg1 arg2 …` and flushes. Arguments that are not simple
/// shell words are single-quoted so the preview is copy-pasteable.
pub fn printCommand(writer: *std.Io.Writer, argv: []const []const u8) !void {
    std.debug.assert(argv.len > 0);
    try writer.writeAll("$ ");
    for (argv, 0..) |arg, i| {
        if (i != 0) try writer.writeByte(' ');
        try writeArg(writer, arg);
    }
    try writer.writeByte('\n');
    try writer.flush();
}

fn writeArg(writer: *std.Io.Writer, arg: []const u8) !void {
    if (isSimpleWord(arg)) return writer.writeAll(arg);
    try writer.writeByte('\'');
    for (arg) |c| {
        if (c == '\'') {
            try writer.writeAll("'\\''");
        } else {
            try writer.writeByte(c);
        }
    }
    try writer.writeByte('\'');
}

fn isSimpleWord(arg: []const u8) bool {
    if (arg.len == 0) return false;
    for (arg) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/', ':', '@', '%', '+', '=', ',' => {},
        else => return false,
    };
    return true;
}

// --- Tests ---

test "printCommand joins argv" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try printCommand(&writer, &.{ "git", "-C", "/repo", "pull" });
    try std.testing.expectEqualStrings("$ git -C /repo pull\n", buf[0..writer.end]);
}

test "printCommand quotes non-simple arguments" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try printCommand(&writer, &.{ "echo", "hi there", "it's", "" });
    try std.testing.expectEqualStrings(
        "$ echo 'hi there' 'it'\\''s' ''\n",
        buf[0..writer.end],
    );
}

test "dry runner prints and returns success" {
    const io = std.testing.io;
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var dry = DryRun{ .writer = &writer };
    const runner = dry.runner();

    try std.testing.expectEqual(@as(i32, 0), try runner.run(io, &.{"true"}));
    const captured = try runner.capture(io, std.testing.allocator, &.{ "echo", "hi" });
    defer captured.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 0), captured.code);
    try std.testing.expectEqual(@as(usize, 0), captured.stdout.len);
    try std.testing.expectEqual(@as(i32, 0), try runner.probe(io, &.{"probe"}));

    const out = buf[0..writer.end];
    try std.testing.expectEqualStrings("$ true\n$ echo hi\n$ probe\n", out);
}

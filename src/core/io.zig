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

/// Whether ANSI style sequences are emitted on stdout. Set once at startup from
/// `colorSupported`; tests may toggle it.
pub var color_enabled: bool = true;

/// Whether ANSI style sequences are emitted on stderr. Kept separate so a
/// redirected stream never receives escapes because the other one is a TTY.
pub var err_color_enabled: bool = true;

/// Returns `code` when stdout color is enabled, otherwise an empty string.
pub fn style(code: []const u8) []const u8 {
    return if (color_enabled) code else "";
}

/// Returns `code` when stderr color is enabled, otherwise an empty string.
pub fn styleErr(code: []const u8) []const u8 {
    return if (err_color_enabled) code else "";
}

/// True when the environment and `file` allow colored output: `NO_COLOR` is
/// unset or empty, `TERM` is not `dumb`, and `file` is a terminal.
pub fn colorSupported(io: std.Io, environ: *std.process.Environ.Map, file: std.Io.File) bool {
    if (!colorAllowedByEnv(environ)) return false;
    return file.isTty(io) catch false;
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

/// True when `--no-color` appears anywhere in `args`. Scanned before parsing
/// so the flag also silences diagnostics from an argument error.
pub fn noColorRequested(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--no-color")) return true;
    }
    return false;
}

// --- Terminal control ---

/// Whether terminal control sequences (progress and notifications) are
/// emitted. Set once at startup from `controlSupported`; tests may toggle it.
pub var control_enabled: bool = false;

/// Progress lifecycle bookkeeping so pause/resume only act while a run is
/// actually in progress.
const ProgressState = enum { inactive, running, paused };
var progress_state: ProgressState = .inactive;

/// True when stdout can receive terminal control sequences: it is a TTY and
/// `TERM` is not `dumb`. `NO_COLOR` only affects colors, not progress.
pub fn controlSupported(io: std.Io, environ: *std.process.Environ.Map) bool {
    if (environ.get("TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb")) return false;
    }
    return std.Io.File.stdout().isTty(io) catch false;
}

/// Writes `seq` and flushes; control sequences are best-effort.
fn writeControl(writer: *std.Io.Writer, seq: []const u8) void {
    writer.writeAll(seq) catch return;
    writer.flush() catch {};
}

/// Shows an indeterminate progress bar (OSC 9;4;3).
pub fn progressStart(writer: *std.Io.Writer) void {
    if (!control_enabled) return;
    progress_state = .running;
    writeControl(writer, "\x1b]9;4;3;0\x1b\\");
}

/// Pauses the progress bar while waiting for the user (OSC 9;4;4).
pub fn progressPause(writer: *std.Io.Writer) void {
    if (!control_enabled or progress_state != .running) return;
    progress_state = .paused;
    writeControl(writer, "\x1b]9;4;4\x1b\\");
}

/// Resumes a paused progress bar (OSC 9;4;3).
pub fn progressResume(writer: *std.Io.Writer) void {
    if (!control_enabled or progress_state != .paused) return;
    progress_state = .running;
    writeControl(writer, "\x1b]9;4;3;0\x1b\\");
}

/// Clears the progress bar (OSC 9;4;0). Idempotent.
pub fn progressStop(writer: *std.Io.Writer) void {
    if (!control_enabled or progress_state == .inactive) return;
    progress_state = .inactive;
    writeControl(writer, "\x1b]9;4;0;0\x1b\\");
}

/// Emits a desktop notification (OSC 9) and rings the bell so the user looks
/// at the terminal when input is needed or the run ends.
pub fn notify(writer: *std.Io.Writer, msg: []const u8) void {
    if (!control_enabled) return;
    std.debug.assert(msg.len > 0);
    writer.writeAll("\x1b]9;") catch return;
    writer.writeAll(msg) catch return;
    writer.writeAll("\x1b\\\x07") catch return;
    writer.flush() catch {};
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

test "style honors the per-stream flags" {
    color_enabled = false;
    err_color_enabled = false;
    defer {
        color_enabled = true;
        err_color_enabled = true;
    }
    try std.testing.expectEqualStrings("", style(Red));
    try std.testing.expectEqualStrings("", style(Reset));
    try std.testing.expectEqualStrings("", styleErr(Red));
    try std.testing.expectEqualStrings("", styleErr(Reset));

    color_enabled = true;
    try std.testing.expectEqualStrings(Red, style(Red));
    try std.testing.expectEqualStrings("", styleErr(Red));

    err_color_enabled = true;
    try std.testing.expectEqualStrings(Red, styleErr(Red));
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

    // The terminal probe depends on the real streams; just exercise it.
    _ = colorSupported(std.testing.io, &environ, std.Io.File.stdout());
    _ = colorSupported(std.testing.io, &environ, std.Io.File.stderr());
}

test "noColorRequested scans every argument" {
    try std.testing.expect(!noColorRequested(&.{"zix"}));
    try std.testing.expect(noColorRequested(&.{ "zix", "-y", "--no-color" }));
    try std.testing.expect(!noColorRequested(&.{ "zix", "--no-color=1" }));
}

test "progress sequences follow the lifecycle" {
    control_enabled = true;
    progress_state = .inactive;
    defer {
        control_enabled = false;
        progress_state = .inactive;
    }

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    progressStart(&writer);
    progressPause(&writer);
    progressResume(&writer);
    progressStop(&writer);
    const out = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b]9;4;3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b]9;4;4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b]9;4;0") != null);
}

test "progress pause and resume are no-ops outside their state" {
    control_enabled = true;
    progress_state = .inactive;
    defer {
        control_enabled = false;
        progress_state = .inactive;
    }

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    progressPause(&writer);
    progressResume(&writer);
    try std.testing.expectEqual(@as(usize, 0), writer.end);

    progressStart(&writer);
    const after_start = writer.end;
    progressResume(&writer);
    try std.testing.expectEqual(after_start, writer.end);

    progressPause(&writer);
    const after_pause = writer.end;
    progressPause(&writer);
    try std.testing.expectEqual(after_pause, writer.end);

    progressStop(&writer);
    const after_stop = writer.end;
    progressStop(&writer);
    try std.testing.expectEqual(after_stop, writer.end);
}

test "terminal control is silent when disabled" {
    control_enabled = false;
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    progressStart(&writer);
    progressPause(&writer);
    progressResume(&writer);
    progressStop(&writer);
    notify(&writer, "zix: none");
    try std.testing.expectEqual(@as(usize, 0), writer.end);
}

test "notify writes an OSC 9 notification and a bell" {
    control_enabled = true;
    defer control_enabled = false;

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    notify(&writer, "zix: done");
    const out = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b]9;zix: done\x1b\\") != null);
    try std.testing.expectEqual(@as(u8, '\x07'), out[out.len - 1]);
}

test "controlSupported honors TERM=dumb" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("TERM", "dumb");
    try std.testing.expect(!controlSupported(std.testing.io, &environ));
    try environ.put("TERM", "xterm-256color");
    // The TTY half depends on the real stdout; just exercise it.
    _ = controlSupported(std.testing.io, &environ);
}

test "style constants are non-empty" {
    for ([_][]const u8{ Red, Green, Yellow, Blue, Cyan, Reset }) |code| {
        try std.testing.expect(code.len > 0);
    }
}

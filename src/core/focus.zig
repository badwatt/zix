//! Best-effort terminal focus detection via the compositor IPC.
//!
//! Notifications are only useful when the user is looking at another window.
//! zix queries niri or Hyprland and treats unknown environments or query
//! errors as "focused", so it stays quiet instead of notifying spuriously.

const std = @import("std");
const process = @import("process.zig");

/// Returns true when the terminal running zix appears to be the focused
/// window. Unknown compositors, unknown terminals and query failures are
/// treated as focused.
pub fn isTerminalFocused(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    runner: process.Runner,
) bool {
    const argv = queryArgv(environ) orelse return true;
    const result = runner.capture(io, allocator, argv) catch return true;
    defer result.deinit(allocator);
    if (result.code != 0) return true;
    return focusedApp(allocator, result.stdout, environ);
}

/// Compositor query for the current environment, or null when unsupported.
fn queryArgv(environ: *std.process.Environ.Map) ?[]const []const u8 {
    if (environ.get("NIRI_SOCKET") != null) {
        return &.{ "niri", "msg", "-j", "focused-window" };
    }
    if (environ.get("HYPRLAND_INSTANCE_SIGNATURE") != null) {
        return &.{ "hyprctl", "activewindow", "-j" };
    }
    return null;
}

/// Expected compositor app id for the running terminal, if known.
fn terminalAppId(environ: *std.process.Environ.Map) ?[]const u8 {
    if (environ.get("TERM_PROGRAM")) |program| {
        if (std.ascii.eqlIgnoreCase(program, "ghostty")) return "com.mitchellh.ghostty";
        if (std.ascii.eqlIgnoreCase(program, "iTerm.app")) return "iTerm2";
        if (std.ascii.eqlIgnoreCase(program, "WezTerm")) return "org.wezfurlong.wezterm";
        if (std.ascii.eqlIgnoreCase(program, "vscode")) return "code";
        if (std.ascii.eqlIgnoreCase(program, "Apple_Terminal")) return "com.apple.Terminal";
    }
    if (environ.get("KITTY_WINDOW_ID") != null) return "kitty";
    if (environ.get("WEZTERM_PANE") != null) return "org.wezfurlong.wezterm";
    if (environ.get("ALACRITTY_WINDOW_ID") != null) return "Alacritty";
    return null;
}

/// Whether `json` names the running terminal as the focused window.
fn focusedApp(
    allocator: std.mem.Allocator,
    json: []const u8,
    environ: *std.process.Environ.Map,
) bool {
    const expected = terminalAppId(environ) orelse return true;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return true;
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |value| value,
        else => return true,
    };
    const app = object.get("app_id") orelse object.get("class") orelse return true;
    const app_id = switch (app) {
        .string => |value| value,
        else => return true,
    };
    return std.ascii.eqlIgnoreCase(app_id, expected);
}

// --- Tests ---

var mock_output: []const u8 = "";
var mock_code: i32 = 0;
var mock_error: bool = false;

fn mockRun(_: ?*anyopaque, _: std.Io, _: process.Runner.Command) anyerror!i32 {
    return 0;
}

fn mockCapture(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: process.Runner.Command,
) anyerror!process.Capture {
    if (mock_error) return error.MockError;
    return .{
        .code = mock_code,
        .stdout = try allocator.dupe(u8, mock_output),
        .stderr = try allocator.dupe(u8, &.{}),
    };
}

fn mockProbe(_: ?*anyopaque, _: std.Io, _: process.Runner.Command) anyerror!i32 {
    return 0;
}

const mock_runner = process.Runner{ .runFn = mockRun, .captureFn = mockCapture, .probeFn = mockProbe };

fn testEnv(allocator: std.mem.Allocator) std.process.Environ.Map {
    return std.process.Environ.Map.init(allocator);
}

test "queryArgv picks the supported compositors" {
    var environ = testEnv(std.testing.allocator);
    defer environ.deinit();
    try std.testing.expect(queryArgv(&environ) == null);

    try environ.put("NIRI_SOCKET", "/run/user/1000/niri.sock");
    try std.testing.expectEqualStrings("niri", queryArgv(&environ).?[0]);

    var hypr = testEnv(std.testing.allocator);
    defer hypr.deinit();
    try hypr.put("HYPRLAND_INSTANCE_SIGNATURE", "sig");
    try std.testing.expectEqualStrings("hyprctl", queryArgv(&hypr).?[0]);
}

test "terminalAppId maps known terminals" {
    var environ = testEnv(std.testing.allocator);
    defer environ.deinit();
    try std.testing.expect(terminalAppId(&environ) == null);

    try environ.put("TERM_PROGRAM", "ghostty");
    try std.testing.expectEqualStrings("com.mitchellh.ghostty", terminalAppId(&environ).?);
    try environ.put("TERM_PROGRAM", "WezTerm");
    try std.testing.expectEqualStrings("org.wezfurlong.wezterm", terminalAppId(&environ).?);
    try environ.put("KITTY_WINDOW_ID", "1");
    try environ.put("TERM_PROGRAM", "");
    try std.testing.expectEqualStrings("kitty", terminalAppId(&environ).?);
}

test "focusedApp compares the compositor app id" {
    var environ = testEnv(std.testing.allocator);
    defer environ.deinit();
    try environ.put("TERM_PROGRAM", "ghostty");

    try std.testing.expect(focusedApp(
        std.testing.allocator,
        "{\"app_id\":\"com.mitchellh.ghostty\"}",
        &environ,
    ));
    try std.testing.expect(!focusedApp(
        std.testing.allocator,
        "{\"app_id\":\"firefox\"}",
        &environ,
    ));
    try std.testing.expect(focusedApp(
        std.testing.allocator,
        "{\"class\":\"com.mitchellh.ghostty\"}",
        &environ,
    ));
    try std.testing.expect(focusedApp(std.testing.allocator, "not json", &environ));
    try std.testing.expect(!focusedApp(
        std.testing.allocator,
        "{\"app_id\":\"firefox\"}",
        &environ,
    ));
}

test "isTerminalFocused uses the runner and stays quiet on errors" {
    var environ = testEnv(std.testing.allocator);
    defer environ.deinit();
    try environ.put("NIRI_SOCKET", "/run/user/1000/niri.sock");
    try environ.put("TERM_PROGRAM", "ghostty");

    _ = try mockRun(null, std.testing.io, &.{"x"});
    _ = try mockProbe(null, std.testing.io, &.{"x"});

    mock_output = "{\"app_id\":\"com.mitchellh.ghostty\"}";
    mock_code = 0;
    mock_error = false;
    try std.testing.expect(isTerminalFocused(std.testing.io, std.testing.allocator, &environ, mock_runner));

    mock_output = "{\"app_id\":\"firefox\"}";
    try std.testing.expect(!isTerminalFocused(std.testing.io, std.testing.allocator, &environ, mock_runner));

    mock_code = 1;
    try std.testing.expect(isTerminalFocused(std.testing.io, std.testing.allocator, &environ, mock_runner));

    mock_code = 0;
    mock_error = true;
    try std.testing.expect(isTerminalFocused(std.testing.io, std.testing.allocator, &environ, mock_runner));

    var plain = testEnv(std.testing.allocator);
    defer plain.deinit();
    try std.testing.expect(isTerminalFocused(std.testing.io, std.testing.allocator, &plain, mock_runner));
}

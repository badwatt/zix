//! Shell-free command builders for git and nix operations.
//!
//! Every builder returns an argv list (program name first), so values coming
//! from the CLI (`repo`, `hostname`) are passed as literal arguments and can
//! never be reinterpreted by a shell. No `sh -c`, no quoting, no injection.

const std = @import("std");

/// An argv list: program name first, then its arguments.
pub const Command = []const []const u8;

/// Returns the `git -C <repo> pull` argv.
pub fn gitPull(repo: []const u8) [4][]const u8 {
    std.debug.assert(repo.len > 0);
    return .{ "git", "-C", repo, "pull" };
}

/// Returns the `git -C <repo> status --porcelain` argv.
pub fn gitStatus(repo: []const u8) [5][]const u8 {
    std.debug.assert(repo.len > 0);
    return .{ "git", "-C", repo, "status", "--porcelain" };
}

/// Returns the `git -C <repo> rev-parse --is-inside-work-tree` argv.
pub fn gitRevParse(repo: []const u8) [5][]const u8 {
    std.debug.assert(repo.len > 0);
    return .{ "git", "-C", repo, "rev-parse", "--is-inside-work-tree" };
}

/// Returns the `git -C <repo> add .` argv.
pub fn gitAdd(repo: []const u8) [5][]const u8 {
    std.debug.assert(repo.len > 0);
    return .{ "git", "-C", repo, "add", "." };
}

/// Returns the `nix flake update --flake <repo>` argv.
pub fn nixUpdate(repo: []const u8) [5][]const u8 {
    std.debug.assert(repo.len > 0);
    return .{ "nix", "flake", "update", "--flake", repo };
}

/// Which `nixos-rebuild` implementation is installed. The newer `-ng`
/// rewrite supports `--elevate` (evaluate as the invoking user) and
/// `--no-reexec`; the classic shell script elevates the whole command and
/// spells the re-exec skip `--fast`.
pub const RebuildFlavor = enum { classic, ng };

/// Capability probe: `--elevate` exists only in the `-ng` rewrite, and
/// `list-generations` is read-only. Exit code 0 means `-ng`.
pub fn rebuildProbe() [3][]const u8 {
    return .{ "nixos-rebuild", "--elevate=none", "list-generations" };
}

/// Builds the `switch` argv for the detected flavor from the pre-formatted
/// `<repo>#<hostname>` flake reference. Always skips the self re-exec with the
/// flavor-appropriate flag, so the redundant pre-build evaluation is not paid.
pub fn nixRebuild(flake: []const u8, flavor: RebuildFlavor) [7][]const u8 {
    std.debug.assert(flake.len > 0);
    return switch (flavor) {
        .ng => .{
            "nixos-rebuild",
            "switch",
            "--elevate=sudo",
            "--no-reexec",
            "--flake",
            flake,
            "--show-trace",
        },
        .classic => .{
            "sudo",
            "nixos-rebuild",
            "switch",
            "--fast",
            "--flake",
            flake,
            "--show-trace",
        },
    };
}

/// Formats the `<repo>#<hostname>` flake reference for `--flake`.
pub fn formatFlake(allocator: std.mem.Allocator, repo: []const u8, hostname: []const u8) ![]const u8 {
    std.debug.assert(repo.len > 0);
    std.debug.assert(hostname.len > 0);
    return std.fmt.allocPrint(allocator, "{s}#{s}", .{ repo, hostname });
}

/// Returns the `sudo nix-env --profile <system> --delete-generations +<n>`
/// argv from the pre-formatted `+<n>` argument.
pub fn nixKeep(keep_arg: []const u8) [6][]const u8 {
    std.debug.assert(keep_arg.len > 0);
    return .{
        "sudo",
        "nix-env",
        "--profile",
        "/nix/var/nix/profiles/system",
        "--delete-generations",
        keep_arg,
    };
}

/// Formats the `+<n>` argument for `--delete-generations`.
pub fn formatKeep(allocator: std.mem.Allocator, generations_to_keep: u8) ![]const u8 {
    std.debug.assert(generations_to_keep > 0);
    return std.fmt.allocPrint(allocator, "+{d}", .{generations_to_keep});
}

/// Returns the `sudo nix-collect-garbage` argv.
pub fn nixCollectGarbage() [2][]const u8 {
    return .{ "sudo", "nix-collect-garbage" };
}

/// Returns the `nix profile diff-closures --profile <system>` argv.
pub fn nixDiffClosures() [5][]const u8 {
    return .{
        "nix",
        "profile",
        "diff-closures",
        "--profile",
        "/nix/var/nix/profiles/system",
    };
}

/// Returns the tail of `output` starting at the last line containing `Version`.
///
/// Mirrors the former `tac | awk '/Version/{print; exit} 1' | tac` pipeline:
/// when no such line exists, the whole output is returned unchanged.
pub fn tailFromLastVersion(output: []const u8) []const u8 {
    var start: ?usize = null;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        if (output[i] != '\n') continue;
        if (std.mem.indexOf(u8, output[line_start..i], "Version") != null) start = line_start;
        line_start = i + 1;
    }
    if (line_start < output.len and
        std.mem.indexOf(u8, output[line_start..], "Version") != null)
    {
        start = line_start;
    }
    return if (start) |s| output[s..] else output;
}

// --- Tests ---

fn expectArgv(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqualSlices([]const u8, expected, actual);
}

test "git commands use argv, not shell" {
    try expectArgv(&.{ "git", "-C", "/repo", "pull" }, &gitPull("/repo"));
    try expectArgv(&.{ "git", "-C", "/repo", "status", "--porcelain" }, &gitStatus("/repo"));
    try expectArgv(
        &.{ "git", "-C", "/repo", "rev-parse", "--is-inside-work-tree" },
        &gitRevParse("/repo"),
    );
    try expectArgv(&.{ "git", "-C", "/repo", "add", "." }, &gitAdd("/repo"));
}

test "repo with spaces stays a single argument" {
    const repo = "/tmp/my dotfiles";
    try expectArgv(&.{ "git", "-C", repo, "pull" }, &gitPull(repo));
}

test "nix commands use argv, not shell" {
    try expectArgv(&.{ "nix", "flake", "update", "--flake", "/repo" }, &nixUpdate("/repo"));
    try expectArgv(
        &.{ "nixos-rebuild", "--elevate=none", "list-generations" },
        &rebuildProbe(),
    );
    try expectArgv(
        &.{ "sudo", "nix-collect-garbage" },
        &nixCollectGarbage(),
    );
    try expectArgv(
        &.{
            "nix",
            "profile",
            "diff-closures",
            "--profile",
            "/nix/var/nix/profiles/system",
        },
        &nixDiffClosures(),
    );
}

test "nixRebuild reflects flavor" {
    try expectArgv(
        &.{
            "nixos-rebuild",
            "switch",
            "--elevate=sudo",
            "--no-reexec",
            "--flake",
            "/repo#host",
            "--show-trace",
        },
        &nixRebuild("/repo#host", .ng),
    );
    try expectArgv(
        &.{
            "sudo",
            "nixos-rebuild",
            "switch",
            "--fast",
            "--flake",
            "/repo#host",
            "--show-trace",
        },
        &nixRebuild("/repo#host", .classic),
    );
}

test "formatFlake and formatKeep allocate expected strings" {
    const alloc = std.testing.allocator;
    const flake = try formatFlake(alloc, "/repo", "host");
    defer alloc.free(flake);
    try std.testing.expectEqualStrings("/repo#host", flake);

    const keep = try formatKeep(alloc, 7);
    defer alloc.free(keep);
    try std.testing.expectEqualStrings("+7", keep);
}

test "nixKeep argv" {
    try expectArgv(
        &.{
            "sudo",
            "nix-env",
            "--profile",
            "/nix/var/nix/profiles/system",
            "--delete-generations",
            "+5",
        },
        &nixKeep("+5"),
    );
}

test "tailFromLastVersion keeps from last match" {
    const output = "old Version 1\nnoise\nVersion 2\nline a\nline b\n";
    try std.testing.expectEqualStrings(
        "Version 2\nline a\nline b\n",
        tailFromLastVersion(output),
    );
}

test "tailFromLastVersion without match returns all" {
    const output = "line a\nline b\n";
    try std.testing.expectEqualStrings(output, tailFromLastVersion(output));
}

test "tailFromLastVersion handles empty and last-line match" {
    try std.testing.expectEqualStrings("", tailFromLastVersion(""));
    try std.testing.expectEqualStrings("Version 3\n", tailFromLastVersion("a\nVersion 3\n"));
    // Last line has no trailing newline.
    try std.testing.expectEqualStrings("Version 4", tailFromLastVersion("a\nVersion 4"));
}

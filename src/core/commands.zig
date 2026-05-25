//! Shell command builders for git and nix operations.
//!
//! Each function allocates and returns a shell command string.
//! All assert preconditions (e.g., non-empty repo paths).

const std = @import("std");

/// Returns `git -C <repo> pull`.
pub fn gitPull(allocator: std.mem.Allocator, repo: []const u8) ![]const u8 {
    std.debug.assert(repo.len > 0);
    return std.fmt.allocPrint(allocator, "git -C {s} pull", .{repo});
}

/// Returns `git -C <repo> diff --exit-code`. Exit code 1 means changes exist.
pub fn gitDiff(allocator: std.mem.Allocator, repo: []const u8) ![]const u8 {
    std.debug.assert(repo.len > 0);
    return std.fmt.allocPrint(allocator, "git -C {s} diff --exit-code", .{repo});
}

/// Returns `git -C <repo> status --porcelain`.
pub fn gitStatus(allocator: std.mem.Allocator, repo: []const u8) ![]const u8 {
    std.debug.assert(repo.len > 0);
    return std.fmt.allocPrint(allocator, "git -C {s} status --porcelain", .{repo});
}

/// Returns `git -C <repo> add .`.
pub fn gitAdd(allocator: std.mem.Allocator, repo: []const u8) ![]const u8 {
    std.debug.assert(repo.len > 0);
    return std.fmt.allocPrint(allocator, "git -C {s} add .", .{repo});
}

/// Returns `nix flake update --flake <repo>`.
pub fn nixUpdate(allocator: std.mem.Allocator, repo: []const u8) ![]const u8 {
    std.debug.assert(repo.len > 0);
    return std.fmt.allocPrint(allocator, "nix flake update --flake {s}", .{repo});
}

/// Returns `sudo nixos-rebuild switch --flake <repo>#<hostname> --show-trace`.
pub fn nixRebuild(
    allocator: std.mem.Allocator,
    repo: []const u8,
    hostname: []const u8,
) ![]const u8 {
    std.debug.assert(repo.len > 0);
    std.debug.assert(hostname.len > 0);
    return std.fmt.allocPrint(
        allocator,
        "sudo nixos-rebuild switch --flake {s}#{s} --show-trace",
        .{ repo, hostname },
    );
}

/// Returns `sudo nix-env --profile /nix/var/nix/profiles/system --delete-generations +<n>`.
pub fn nixKeep(
    allocator: std.mem.Allocator,
    generations_to_keep: u8,
) ![]const u8 {
    std.debug.assert(generations_to_keep > 0);
    return std.fmt.allocPrint(
        allocator,
        "sudo nix-env --profile /nix/var/nix/profiles/system" ++ " --delete-generations +{d}",
        .{generations_to_keep},
    );
}

/// Static command string for nix profile diff-closures with awk filtering.
const nix_diff_profile = " --profile /nix/var/nix/profiles/system";
const nix_diff_awk = " | awk '/Version/{print; exit} 1'";

/// Pre-built nix diff command. No allocation needed — comptime concatenated.
pub const nixDiff =
    "nix profile diff-closures" ++ nix_diff_profile ++ " | tac" ++ nix_diff_awk ++ " | tac";

test "command strings" {
    const alloc = std.testing.allocator;
    const s0 = try gitPull(alloc, "/repo");
    defer alloc.free(s0);
    try std.testing.expectEqualStrings("git -C /repo pull", s0);
    const s1 = try gitDiff(alloc, "/repo");
    defer alloc.free(s1);
    try std.testing.expectEqualStrings("git -C /repo diff --exit-code", s1);
    const s2 = try gitStatus(alloc, "/repo");
    defer alloc.free(s2);
    try std.testing.expectEqualStrings("git -C /repo status --porcelain", s2);
    const s3 = try gitAdd(alloc, "/repo");
    defer alloc.free(s3);
    try std.testing.expectEqualStrings("git -C /repo add .", s3);
    const s4 = try nixUpdate(alloc, "/repo");
    defer alloc.free(s4);
    try std.testing.expectEqualStrings("nix flake update --flake /repo", s4);
    const s5 = try nixRebuild(alloc, "/repo", "host");
    defer alloc.free(s5);
    try std.testing.expectEqualStrings(
        "sudo nixos-rebuild switch --flake /repo#host --show-trace",
        s5,
    );
    const s6 = try nixKeep(alloc, 5);
    defer alloc.free(s6);
    try std.testing.expectEqualStrings(
        "sudo nix-env --profile /nix/var/nix/profiles/system" ++ " --delete-generations +5",
        s6,
    );
}

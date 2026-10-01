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

/// Returns `nix flake update --flake <repo>`. When `input` is non-null,
/// appends the input name to update only that flake input.
pub fn nixUpdate(
    allocator: std.mem.Allocator,
    repo: []const u8,
    input: ?[]const u8,
) ![]const u8 {
    std.debug.assert(repo.len > 0);
    if (input) |name| {
        std.debug.assert(name.len > 0);
        return std.fmt.allocPrint(
            allocator,
            "nix flake update --flake {s} {s}",
            .{ repo, name },
        );
    }
    return std.fmt.allocPrint(allocator, "nix flake update --flake {s}", .{repo});
}

/// Returns `nixos-rebuild switch --elevate=sudo --flake <repo>#<hostname> --show-trace`.
/// Evaluation runs as the invoking user; only activation is elevated. When
/// `fast` is true, `--no-reexec` skips the self re-exec evaluation.
pub fn nixRebuild(
    allocator: std.mem.Allocator,
    repo: []const u8,
    hostname: []const u8,
    fast: bool,
) ![]const u8 {
    std.debug.assert(repo.len > 0);
    std.debug.assert(hostname.len > 0);
    if (fast) {
        return std.fmt.allocPrint(
            allocator,
            "nixos-rebuild switch --elevate=sudo --no-reexec" ++
                " --flake {s}#{s} --show-trace",
            .{ repo, hostname },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "nixos-rebuild switch --elevate=sudo --flake {s}#{s} --show-trace",
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
    const s4 = try nixUpdate(alloc, "/repo", null);
    defer alloc.free(s4);
    try std.testing.expectEqualStrings("nix flake update --flake /repo", s4);
    const s4i = try nixUpdate(alloc, "/repo", "nixpkgs");
    defer alloc.free(s4i);
    try std.testing.expectEqualStrings("nix flake update --flake /repo nixpkgs", s4i);
    const s5 = try nixRebuild(alloc, "/repo", "host", false);
    defer alloc.free(s5);
    try std.testing.expectEqualStrings(
        "nixos-rebuild switch --elevate=sudo --flake /repo#host --show-trace",
        s5,
    );
    const s5f = try nixRebuild(alloc, "/repo", "host", true);
    defer alloc.free(s5f);
    try std.testing.expectEqualStrings(
        "nixos-rebuild switch --elevate=sudo --no-reexec --flake /repo#host --show-trace",
        s5f,
    );
    const s6 = try nixKeep(alloc, 5);
    defer alloc.free(s6);
    try std.testing.expectEqualStrings(
        "sudo nix-env --profile /nix/var/nix/profiles/system" ++ " --delete-generations +5",
        s6,
    );
}

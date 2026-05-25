//! Application configuration for zix.
//!
//! Defines `Config` with defaults, validation, and round-trip tests.
//! Hostname defaults to OS hostname; repo to `~/.dotfiles`; keep to 10.

const std = @import("std");

/// CLI configuration struct. All fields have sensible defaults.
pub const Config = struct {
    /// Path to the dotfiles git repository.
    repo: []const u8,
    /// NixOS hostname for flake rebuild target.
    hostname: []const u8,
    /// Number of generations to keep when pruning.
    keep: u8,
    /// Whether to run `nix flake update` before rebuild.
    update: bool,
    /// Whether to show nix profile diff-closures after rebuild.
    diff: bool,

    /// Returns a Config with OS hostname, default repo, and keep=10.
    /// Caller must provide a buffer of `HOST_NAME_MAX` bytes for hostname.
    pub fn defaults(hostname_buf: *[std.posix.HOST_NAME_MAX]u8) Config {
        return .{
            .repo = "~/.dotfiles",
            .hostname = std.posix.gethostname(hostname_buf) catch "unknown",
            .keep = 10,
            .update = false,
            .diff = false,
        };
    }

    /// Validates config invariants. Returns an error message or null if valid.
    pub fn validate(self: Config) ?[]const u8 {
        if (self.repo.len == 0) return "repo path cannot be empty";
        if (self.keep == 0) return "generations to keep must be > 0";
        return null;
    }
};

test "defaults produces valid config" {
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const config = Config.defaults(&buf);
    try std.testing.expect(config.repo.len > 0);
    try std.testing.expect(config.hostname.len > 0);
    try std.testing.expect(config.keep > 0);
}

test "validate accepts valid config" {
    const config = Config{
        .repo = "~/.dotfiles",
        .hostname = "nixos",
        .keep = 10,
        .update = false,
        .diff = false,
    };
    try std.testing.expectEqual(@as(?[]const u8, null), config.validate());
}

test "validate rejects empty repo" {
    const config = Config{
        .repo = "",
        .hostname = "nixos",
        .keep = 10,
        .update = false,
        .diff = false,
    };
    try std.testing.expect(config.validate() != null);
}

test "validate rejects zero keep" {
    const config = Config{
        .repo = "~/.dotfiles",
        .hostname = "nixos",
        .keep = 0,
        .update = false,
        .diff = false,
    };
    try std.testing.expect(config.validate() != null);
}

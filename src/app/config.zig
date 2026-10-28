//! Application configuration for zix.
//!
//! Defines `Config` with defaults, validation, and `~` expansion.
//! Hostname is resolved by the caller; repo defaults to `~/.dotfiles`; keep 10.

const std = @import("std");

/// Default dotfiles repository path (before `~` expansion).
pub const DEFAULT_REPO = "~/.dotfiles";
/// Default number of generations to keep when pruning.
pub const DEFAULT_KEEP = 10;

/// One step of the update pipeline, in execution order. `--only` selects an
/// explicit subset; `Config.runs` decides which steps run.
pub const Step = enum {
    pull,
    flake,
    stage,
    rebuild,
    cleanup,
    diff,

    /// Comma-separated step names, for error messages.
    pub const names = "pull,flake,stage,rebuild,cleanup,diff";

    /// CLI name of the step.
    pub fn name(self: Step) []const u8 {
        return @tagName(self);
    }

    /// Looks a step up by its CLI name. `update` aliases `flake`, matching the
    /// `--update` flag people already know.
    pub fn fromName(value: []const u8) ?Step {
        if (std.mem.eql(u8, value, "update")) return .flake;
        return std.meta.stringToEnum(Step, value);
    }
};

/// CLI configuration struct. All fields have sensible defaults.
pub const Config = struct {
    /// Path to the dotfiles git repository.
    repo: []const u8,
    /// NixOS hostname for flake rebuild target.
    hostname: []const u8,
    /// Number of generations to keep when pruning.
    keep: u8,
    /// Maximum parallel Nix builds, or null to use the Nix configuration.
    jobs: ?u16,
    /// Maximum parallel jobs for a single build, or null for the Nix config.
    cores: ?u16,
    /// Whether to run `nix flake update` before rebuild.
    update: bool,
    /// Whether to show nix profile diff-closures after rebuild.
    diff: bool,
    /// Assume "yes" for all confirmation prompts.
    yes: bool,
    /// Print commands instead of executing them.
    dry_run: bool,
    /// Explicit step selection (`--only`), or null for the default pipeline.
    only: ?std.EnumSet(Step) = null,

    /// Returns a Config with the given hostname and default repo/keep/flags.
    pub fn defaults(hostname: []const u8) Config {
        return .{
            .repo = DEFAULT_REPO,
            .hostname = hostname,
            .keep = DEFAULT_KEEP,
            .jobs = null,
            .cores = null,
            .update = false,
            .diff = false,
            .yes = false,
            .dry_run = false,
        };
    }

    /// Validates config invariants. Returns an error message or null if valid.
    pub fn validate(self: Config) ?[]const u8 {
        if (self.repo.len == 0) return "repo path cannot be empty";
        if (self.hostname.len == 0) return "hostname cannot be empty";
        if (self.keep == 0) return "generations to keep must be > 0";
        if (self.jobs) |jobs| {
            if (jobs == 0) return "jobs must be > 0";
        }
        if (self.cores) |cores| {
            if (cores == 0) return "cores must be > 0";
        }
        return null;
    }

    /// Whether `step` belongs to this run. `--only` wins when given; otherwise
    /// pull/stage/rebuild/cleanup always run and the flake update / closure
    /// diff follow their own flags.
    pub fn runs(self: Config, step: Step) bool {
        if (self.only) |steps| return steps.contains(step);
        return switch (step) {
            .flake => self.update,
            .diff => self.diff,
            .pull, .stage, .rebuild, .cleanup => true,
        };
    }

    /// Expands a leading `~` (alone or followed by `/`) to `home`. Returns
    /// `path` unchanged for `~user` forms, paths not starting with `~`, or
    /// when `home` is null.
    pub fn expandTilde(
        allocator: std.mem.Allocator,
        home: ?[]const u8,
        path: []const u8,
    ) ![]const u8 {
        if (path.len == 0 or path[0] != '~') return path;
        // Only `~` and `~/...` are home-relative; `~user` is not supported and
        // must not be spliced onto $HOME.
        if (path.len > 1 and path[1] != '/') return path;
        const h = home orelse return path;
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ h, path[1..] });
    }
};

test "defaults produces valid config" {
    const config = Config.defaults("nixos");
    try std.testing.expect(config.validate() == null);
    try std.testing.expectEqualStrings(DEFAULT_REPO, config.repo);
    try std.testing.expectEqual(@as(u8, DEFAULT_KEEP), config.keep);
    try std.testing.expect(!config.yes);
    try std.testing.expect(!config.dry_run);
}

test "validate accepts valid config" {
    var config = Config.defaults("nixos");
    config.repo = "~/.dotfiles";
    try std.testing.expectEqual(@as(?[]const u8, null), config.validate());
}

test "validate rejects empty repo" {
    var config = Config.defaults("nixos");
    config.repo = "";
    try std.testing.expect(config.validate() != null);
}

test "validate rejects empty hostname" {
    const config = Config.defaults("");
    try std.testing.expect(config.validate() != null);
}

test "validate rejects zero jobs" {
    var config = Config.defaults("nixos");
    config.jobs = 0;
    try std.testing.expect(config.validate() != null);
}

test "validate rejects zero cores" {
    var config = Config.defaults("nixos");
    config.cores = 0;
    try std.testing.expect(config.validate() != null);
}

test "validate rejects zero keep" {
    var config = Config.defaults("nixos");
    config.keep = 0;
    try std.testing.expect(config.validate() != null);
}

test "runs follows the default pipeline" {
    var config = Config.defaults("nixos");
    try std.testing.expect(config.runs(.pull));
    try std.testing.expect(config.runs(.stage));
    try std.testing.expect(config.runs(.rebuild));
    try std.testing.expect(config.runs(.cleanup));
    try std.testing.expect(!config.runs(.flake));
    try std.testing.expect(!config.runs(.diff));

    config.update = true;
    config.diff = true;
    try std.testing.expect(config.runs(.flake));
    try std.testing.expect(config.runs(.diff));
}

test "runs follows an explicit --only set" {
    var config = Config.defaults("nixos");
    config.update = true;
    config.diff = true;
    config.only = std.EnumSet(Step).initOne(.diff);
    try std.testing.expect(config.runs(.diff));
    // An explicit list wins over --update/--diff.
    try std.testing.expect(!config.runs(.flake));
    try std.testing.expect(!config.runs(.pull));
}

test "step names round-trip and update aliases flake" {
    for ([_]Step{ .pull, .flake, .stage, .rebuild, .cleanup, .diff }) |step| {
        try std.testing.expectEqual(step, Step.fromName(step.name()).?);
    }
    try std.testing.expectEqual(Step.flake, Step.fromName("update").?);
    try std.testing.expectEqual(@as(?Step, null), Step.fromName("bogus"));
    try std.testing.expectEqualStrings("pull,flake,stage,rebuild,cleanup,diff", Step.names);
}

test "expandTilde expands home" {
    const alloc = std.testing.allocator;
    const expanded = try Config.expandTilde(alloc, "/home/u", "~/.dotfiles");
    defer alloc.free(expanded);
    try std.testing.expectEqualStrings("/home/u/.dotfiles", expanded);

    const bare = try Config.expandTilde(alloc, "/home/u", "~");
    defer alloc.free(bare);
    try std.testing.expectEqualStrings("/home/u", bare);
}

test "expandTilde leaves ~user paths untouched" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqualStrings(
        "~bob/dots",
        try Config.expandTilde(alloc, "/home/u", "~bob/dots"),
    );
    try std.testing.expectEqualStrings(
        "~bob",
        try Config.expandTilde(alloc, "/home/u", "~bob"),
    );
}

test "expandTilde leaves paths untouched" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqualStrings(
        "/abs/path",
        try Config.expandTilde(alloc, "/home/u", "/abs/path"),
    );
    try std.testing.expectEqualStrings(
        "rel/path",
        try Config.expandTilde(alloc, "/home/u", "rel/path"),
    );
    try std.testing.expectEqualStrings(
        "",
        try Config.expandTilde(alloc, "/home/u", ""),
    );
}

test "expandTilde without home returns path" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqualStrings(
        "~/.dotfiles",
        try Config.expandTilde(alloc, null, "~/.dotfiles"),
    );
}

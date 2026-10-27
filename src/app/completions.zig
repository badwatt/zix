//! Shell completion scripts, printed by `zix --completions <shell>`.
//!
//! The scripts are static so the binary stays dependency free: no completion
//! generator, no build step, and no runtime parsing beyond the shell name.

const std = @import("std");

/// Shell flavours zix can emit completions for.
pub const Shell = enum { bash, zsh, fish };

/// Every supported shell, in help and error-message order.
pub const all = [_]Shell{ .bash, .zsh, .fish };

/// Comma-separated shell names, for error messages and help.
pub const names = "bash,zsh,fish";

/// Every long option the parser accepts. Tests use this list to keep the
/// scripts from drifting behind the CLI.
pub const long_options = [_][]const u8{
    "--repo",     "--hostname",    "--keep", "--jobs",    "--cores",
    "--update",   "--diff",        "--yes",  "--only",    "--dry-run",
    "--no-color", "--completions", "--help", "--version",
};

/// CLI name of the shell.
pub fn name(shell: Shell) []const u8 {
    return @tagName(shell);
}

/// Looks a shell up by its CLI name.
pub fn fromName(value: []const u8) ?Shell {
    return std.meta.stringToEnum(Shell, value);
}

/// The completion script for `shell`.
pub fn script(shell: Shell) []const u8 {
    return switch (shell) {
        .bash => bash,
        .zsh => zsh,
        .fish => fish,
    };
}

/// Writes the completion script for `shell` and flushes.
pub fn print(writer: *std.Io.Writer, shell: Shell) !void {
    try writer.writeAll(script(shell));
    try writer.flush();
}

const bash =
    \\# bash completion for zix
    \\# Install: zix --completions bash | sudo tee /etc/bash_completion.d/zix
    \\_zix() {
    \\    local cur words
    \\    cur="${COMP_WORDS[COMP_CWORD]}"
    \\    words="--repo --hostname --keep --jobs --cores --update --diff --yes \
    \\--only --dry-run --no-color --completions --help --version help version \
    \\-r -n -k -j -c -u -d -y -h -v"
    \\
    \\    case "${COMP_WORDS[COMP_CWORD-1]}" in
    \\        -r|--repo)
    \\            COMPREPLY=( $(compgen -f -- "$cur") )
    \\            return
    \\            ;;
    \\        --only)
    \\            COMPREPLY=( $(compgen -W "pull flake stage rebuild cleanup diff" -- "$cur") )
    \\            return
    \\            ;;
    \\        --completions)
    \\            COMPREPLY=( $(compgen -W "bash zsh fish" -- "$cur") )
    \\            return
    \\            ;;
    \\    esac
    \\
    \\    COMPREPLY=( $(compgen -W "$words" -- "$cur") )
    \\}
    \\
    \\complete -F _zix zix
    \\
;

const zsh =
    \\#compdef zix
    \\# zsh completion for zix
    \\# Install: zix --completions zsh > "${fpath[1]}/_zix"
    \\_zix() {
    \\    _arguments -s \
    \\        '(-r --repo)'{-r,--repo}'[path to the dotfiles repo]:repo:_files -/' \
    \\        '(-n --hostname)'{-n,--hostname}'[hostname for the flake attribute]:hostname:' \
    \\        '(-k --keep)'{-k,--keep}'[generations to keep]:count:' \
    \\        '(-j --jobs)'{-j,--jobs}'[cap nix max-jobs]:count:' \
    \\        '(-c --cores)'{-c,--cores}'[cap nix cores]:count:' \
    \\        '(-u --update)'{-u,--update}'[update flake inputs first]' \
    \\        '(-d --diff)'{-d,--diff}'[show the closure diff]' \
    \\        '(-y --yes)'{-y,--yes}'[assume yes for all prompts]' \
    \\        '--only[run only these steps]:steps:(pull flake stage rebuild cleanup diff)' \
    \\        '--dry-run[print commands without executing them]' \
    \\        '--no-color[disable colored output]' \
    \\        '--completions[print shell completions]:shell:(bash zsh fish)' \
    \\        '(-h --help)'{-h,--help}'[print help]' \
    \\        '(-v --version)'{-v,--version}'[print the version]' \
    \\        '1:command:(help version)'
    \\}
    \\
    \\_zix "$@"
    \\
;

const fish =
    \\# fish completion for zix
    \\# Install: zix --completions fish > ~/.config/fish/completions/zix.fish
    \\complete -c zix -s r -l repo -d 'path to the dotfiles repo' -r -F
    \\complete -c zix -s n -l hostname -d 'hostname for the flake attribute' -r
    \\complete -c zix -s k -l keep -d 'generations to keep' -r
    \\complete -c zix -s j -l jobs -d 'cap nix max-jobs' -r
    \\complete -c zix -s c -l cores -d 'cap nix cores' -r
    \\complete -c zix -s u -l update -d 'update flake inputs first'
    \\complete -c zix -s d -l diff -d 'show the closure diff'
    \\complete -c zix -s y -l yes -d 'assume yes for all prompts'
    \\complete -c zix -l only -d 'run only these steps' -r -f -a "pull flake stage rebuild cleanup diff"
    \\complete -c zix -l dry-run -d 'print commands without executing them'
    \\complete -c zix -l no-color -d 'disable colored output'
    \\complete -c zix -l completions -d 'print shell completions' -r -f -a "bash zsh fish"
    \\complete -c zix -s h -l help -d 'print help'
    \\complete -c zix -s v -l version -d 'print the version'
    \\
;

// --- Tests ---

test "shell names round-trip" {
    for (all) |shell| {
        try std.testing.expectEqual(shell, fromName(name(shell)).?);
    }
    try std.testing.expectEqual(@as(?Shell, null), fromName("powershell"));
    try std.testing.expectEqualStrings("bash,zsh,fish", names);
}

test "every long option appears in every script" {
    for (all) |shell| {
        const text = script(shell);
        for (long_options) |option| {
            var buf: [64]u8 = undefined;
            const needle = if (shell == .fish)
                try std.fmt.bufPrint(&buf, "-l {s}", .{option[2..]})
            else
                option;
            try std.testing.expect(std.mem.indexOf(u8, text, needle) != null);
        }
    }
}

test "scripts complete the binary and their own arguments" {
    try std.testing.expect(std.mem.indexOf(u8, script(.bash), "complete -F _zix zix") != null);
    try std.testing.expect(std.mem.indexOf(u8, script(.zsh), "#compdef zix") != null);
    try std.testing.expect(std.mem.indexOf(u8, script(.fish), "complete -c zix") != null);
}

test "print writes the exact script" {
    var buf: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try print(&writer, .zsh);
    try std.testing.expectEqualStrings(zsh, buf[0..writer.end]);
}

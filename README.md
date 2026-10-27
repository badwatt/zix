# ZIX

![](vhs/zix.gif)

CLI tool for managing NixOS configuration.

## Requirements

- **Zig 0.17.0** or later
- **Nix** (for nix-shell, kcov)

## Installation

```sh
git clone https://github.com/badwatt/zix.git
cd zix
zig build run
```

Install the binary somewhere on your `PATH`:

```sh
install -Dm755 zig-out/bin/zix ~/.local/bin/zix
```

### NixOS

```sh
nix run github:badwatt/zix
```

Or install it into your profile:

```sh
nix profile install github:badwatt/zix
```

Add to flake:

```nix
{
    inputs = {
        zix.url = "github:badwatt/zix";
    };
}
```

```nix
{ inputs, pkgs, ... }:
{
    home.packages = [
        inputs.zix.packages.${pkgs.system}.default
    ];
}
```

## Build Commands

All tasks via `zig build`:

| Command | Description |
|---|---|
| `zig build` | Compile project |
| `zig build run` | Build and run |
| `zig build test --summary all` | Run unit, integration and build-tool tests |
| `zig build coverage` | Run tests under kcov, print line coverage |
| `zig build docs` | Generate autodoc HTML |
| `zig build docs:serve` | Build docs + serve at `127.0.0.1:8000` |
| `zig build fmt` | Format `src/`, `build/`, `tests/` and `build.zig` |
| `zig build fmt:check` | Fail if any file needs formatting (used by CI) |

## Coverage

100% line coverage of `src/` via **kcov**:

```sh
zig build coverage
# 100.0% (<covered>/<total> lines)
```

Tests run with the LLVM backend (`.use_llvm = true`) for accurate DWARF
instrumentation. The build-time helpers in `build/` have their own unit tests
(part of `zig build test`) but are not instrumented by kcov.

CI runs `zig build fmt:check` and `zig build test` on every push and pull
request, and the release tag job depends on the same checks.

## Documentation

```sh
zig build docs          # generate to zig-out/docs/
zig build docs:serve    # build + serve at http://localhost:8000
```

Autodoc uses `///` (declarations) and `//!` (module-level) comments. No doc comments inside function bodies — use `//` there.

## Usage

```
 *****************************************************
  ZIX - A simple CLI tool to update your nixos system
 *****************************************************
 -r, --repo      : set repo path (default is $HOME/.dotfiles)
 -n, --hostname  : set hostname (default is OS hostname)
 -k, --keep      : set generations to keep (default is 10)
 -j, --jobs      : set max parallel builds (default is nix config)
 -c, --cores     : set max parallel jobs per build (default is nix config)
 -u, --update    : set update to true (default is false)
 -d, --diff      : set diff to true (default is false)
 -y, --yes       : assume yes for all prompts (default is false)
     --dry-run   : print commands without executing them
     --no-color  : disable colored output
     --only      : run only these steps (pull,flake,stage,rebuild,cleanup,diff)
     --completions : print shell completions (bash,zsh,fish)
 -h, --help      : Display this help message
 -v, --version   : Display the current version
```

Long options also accept `--flag=value` (`--repo=/path`, `--only=diff`).

### Step selection

`--only` takes a comma-separated list of `pull`, `flake`, `stage`, `rebuild`,
`cleanup`, `diff` (`update` is an alias for `flake`):

```sh
zix --only diff                 # only show the closure diff
zix -u --only flake             # just update flake inputs
zix --only stage,rebuild        # no pull, no cleanup
```

The list wins over `--update`/`--diff`, and a run that skips `rebuild` does not
need a detected hostname.

### Shell completions and man page

```sh
zix --completions bash | sudo tee /etc/bash_completion.d/zix
zix --completions zsh > "${fpath[1]}/_zix"
zix --completions fish > ~/.config/fish/completions/zix.fish
```

The scripts are static (no generator or build step) and cover every flag,
including the step names for `--only`. `zix.1` documents every option, the
step selection and the exit codes; the Nix package installs it under
`share/man/man1`, and from a source checkout `man ./zix.1` works too.

Exit codes: `0` success, `1` runtime failure, `2` invalid arguments or config,
`141` when stdout is closed early (SIGPIPE convention, e.g. `zix | head`).
Diagnostics go to stderr; stdout carries only the normal report. ANSI colors
are disabled when stdout is not a terminal, when `NO_COLOR` is set, or when
`TERM=dumb`.

Commands run as argv lists (never through a shell), so a `--repo` containing
spaces or shell metacharacters cannot be injected. Hostname resolves via
`/proc` → `$HOSTNAME` → `gethostname` → `unknown`; a rebuild with an unknown
hostname aborts instead of using `#unknown`.

zix auto-detects whether the installed `nixos-rebuild` is the classic
shell script or the newer `-ng` rewrite and uses the compatible flags:
`--elevate=sudo` and `--no-reexec` on `-ng`, `sudo` and `--fast` on
classic. The self re-exec is always skipped to avoid its extra
evaluation.

### Out-of-memory during rebuild

A rebuild compiles derivations inside the terminal's transient systemd scope.
If Nix runs too much in parallel, the kernel OOM killer can kill a process in
that scope; systemd then applies `OOMPolicy=stop` and terminates the whole
scope, so the shell reports `terminated` and zix disappears mid-rebuild.

Two independent knobs control parallelism, and the worst case is roughly
`max-jobs × cores` concurrent compiler processes:

- `--cores`: jobs inside **one** derivation (`nixos-rebuild --cores N`).
  This is the one that matters when a single heavy package (e.g. a large C++
  project) is compiling with all cores.
- `--jobs`: how many **derivations** build at once
  (`nixos-rebuild --max-jobs N`). This matters when many packages build in
  parallel.

Nix's defaults are `max-jobs = auto` (one per thread) and `cores = 0`
(all cores), so a 16-thread machine can start 16 compilers for a single
derivation. When a few GiB are already in use, 16 compilers at ~350 MiB each
plus linkers is enough to trigger the OOM killer.

Start with a per-build cap and lower `--jobs` if several derivations run:

```sh
zix -du -c 4          # single heavy derivation
zix -du -j 2 -c 4     # at most ~8 compilers across builds
```

or set it system-wide:

```nix
{
  nix.settings.max-jobs = 2;
  nix.settings.cores = 4;
}
```

Both flags are passed through as `nixos-rebuild --max-jobs <n> --cores <n>`;
when omitted, the Nix configuration is used unchanged. If the rebuild child
dies from a signal, zix reports it and points at `--cores`/`--jobs`.

## Project Structure

```
build.zig            Build configuration
build/coverage.zig   kcov JSON parser (Zig)
build/serve.zig      Static HTTP server for autodoc (Zig)
build/tests.zig      Test root for the build/ helpers
src/main.zig         Entry point, port wiring, exit codes
src/app/init.zig       Arg parsing (Intent), hostname, dispatch
src/app/cli.zig        Workflow pipeline, Deps, error/exit mapping
src/app/config.zig     Config struct: defaults, validation, ~ expansion
src/app/hostname.zig   Hostname resolution chain
src/app/completions.zig Static completion scripts (bash, zsh, fish)
src/core/commands.zig argv builders for git and nix
src/core/io.zig      Formatted output + ANSI style constants
src/core/process.zig CommandRunner port + std.process implementation
src/core/dry_run.zig --dry-run CommandRunner
src/core/ui.zig      UserIo port + terminal implementation
src/core/static_allocator.zig Two-phase allocator (init → static → deinit)
tests/integration.zig End-to-end tests for the compiled binary
zix.1                 Man page (installed by the Nix package)
```

## License

MIT. See LICENSE.

## Style Guide

This project follows [TigerBeetle's TIGER_STYLE](docs/TIGER_STYLE.md).

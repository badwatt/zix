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

Move binary to PATH:

```sh
sudo mv zig-out/bin/zix <PATH>
```

### NixOS

```sh
nix run github:badwatt/zix#target.x86_64-linux-musl
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
| `zig build test --summary all` | Run unit + integration test suite |
| `zig build coverage` | Run tests under kcov, print line coverage |
| `zig build docs` | Generate autodoc HTML |
| `zig build docs:serve` | Build docs + serve at `localhost:8000` |
| `zig build fmt` | Not available — use `zig fmt src/` directly |

## Coverage

100% line coverage via **kcov**:

```sh
zig build coverage
# 100.0% (1163/1163 lines)
```

Tests run with LLVM backend (`.use_llvm = true`) for accurate DWARF instrumentation.

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
 -u, --update    : set update to true (default is false)
 -d, --diff      : set diff to true (default is false)
 -y, --yes       : assume yes for all prompts (default is false)
     --dry-run   : print commands without executing them
 -h, --help      : Display this help message
 -v, --version   : Display the current version
```

Exit codes: `0` success, `1` runtime failure, `2` invalid arguments or config.

Commands run as argv lists (never through a shell), so a `--repo` containing
spaces or shell metacharacters cannot be injected. Hostname resolves via
`/proc` → `$HOSTNAME` → `gethostname` → `unknown`; a rebuild with an unknown
hostname aborts instead of using `#unknown`.

zix auto-detects whether the installed `nixos-rebuild` is the classic
shell script or the newer `-ng` rewrite and uses the compatible flags:
`--elevate=sudo` and `--no-reexec` on `-ng`, `sudo` and `--fast` on
classic. The self re-exec is always skipped to avoid its extra
evaluation.

## Project Structure

```
build.zig            Build configuration
build/coverage.zig   kcov JSON parser (Zig)
build/serve.zig      Static HTTP server for autodoc (Zig)
src/main.zig         Entry point, port wiring, exit codes
src/app/init.zig     Arg parsing (Intent), hostname, dispatch
src/app/cli.zig      Workflow pipeline, Deps, error/exit mapping
src/app/config.zig   Config struct: defaults, validation, ~ expansion
src/app/hostname.zig Hostname resolution chain
src/core/commands.zig argv builders for git and nix
src/core/io.zig      Formatted output + ANSI style constants
src/core/process.zig CommandRunner port + std.process implementation
src/core/dry_run.zig --dry-run CommandRunner
src/core/ui.zig      UserIo port + terminal implementation
src/core/static_allocator.zig Two-phase allocator (init → static → deinit)
tests/integration.zig End-to-end tests for the compiled binary
```

## License

MIT. See LICENSE.

## Style Guide

This project follows [TigerBeetle's TIGER_STYLE](docs/TIGER_STYLE.md).

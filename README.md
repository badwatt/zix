# ZIX

![](vhs/zix.gif)

CLI tool for managing NixOS configuration.

> :warning: **Work in Progress**: Under active development. Features may change.

## Requirements

- **Zig 0.16.0** or later
- **Nix** (for nix-shell, kcov)

## Installation

```sh
git clone https://github.com/alvaro17f/zix.git
cd zix
zig build run
```

Move binary to PATH:

```sh
sudo mv zig-out/bin/zix <PATH>
```

### NixOS

```sh
nix run github:alvaro17f/zix#target.x86_64-linux-musl
```

Add to flake:

```nix
{
    inputs = {
        zix.url = "github:alvaro17f/zix";
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
| `zig build test --summary all` | Run test suite |
| `zig build coverage` | Run tests under kcov, print line coverage |
| `zig build docs` | Generate autodoc HTML |
| `zig build docs:serve` | Build docs + serve at `localhost:8000` |
| `zig build fmt` | Not available — use `zig fmt src/` directly |

## Coverage

100% line coverage via **kcov**:

```sh
zig build coverage
# 100.0% (423/423 lines)
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
 ***************************************************
 ZIX - A simple CLI tool to update your nixos system
 ***************************************************
 -r : set repo path (default is $HOME/.dotfiles)
 -n : set hostname (default is OS hostname)
 -k : set generations to keep (default is 10)
 -u : set update to true (default is false)
 -d : set diff to true (default is false)
 -h, help : Display this help message
 -v, version : Display the current version
```

## Project Structure

```
build.zig            Build configuration
build/coverage.zig   kcov JSON parser (Zig)
build/serve.zig      Static HTTP server for autodoc (Zig)
src/main.zig         Entry point, allocator setup
src/app/init.zig     CLI flag parsing, app dispatch
src/app/cli.zig      Command building, execution pipeline
src/app/config.zig   Config struct with defaults + validation
src/core/commands.zig Shell command string builders
src/core/io.zig      Formatted output + ANSI style constants
src/core/process.zig  Shell process runner
src/core/ui.zig      Terminal UI: titles, help, prompts
src/core/static_allocator.zig Two-phase allocator (init → static → deinit)
```

## License

MIT. See LICENSE.

## Style Guide

This project follows [TigerBeetle's TIGER_STYLE](docs/TIGER_STYLE.md).
# Project Rules

## Workflow

- **TDD mandatory**: every change requires failing test first, then passing code, then refactor.
- **Commit freely**: commit anytime without asking.
- **Push requires approval**: never push. always ask first.
- **Coverage**: 100% line coverage via kcov. no exceptions.

## Verification Steps

1. Write failing test.
2. Make test pass with minimal code.
3. Refactor.
4. Run `./taskfile test` → all pass.
5. Run `./taskfile coverage` → 100.00%.
6. Commit.

## Technical Constraints

- Zig 0.17.0+
- Dependency injection via `Deps` struct.
- No hardcoded stdout/stdin.
- `use_llvm = true` on test binary for kcov.

## Questions?

Ask before uncertain decisions.

## Style Guide

See [`docs/TIGER_STYLE.md`](docs/TIGER_STYLE.md) for TigerBeetle coding style guidelines.

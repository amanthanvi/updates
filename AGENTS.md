# Agent Guide

This repo is a small, macOS-focused Bash utility. Keep changes minimal, safe, and easy to reason about.

## Development workflow

- Validate: `./scripts/lint.sh` (runs `bash -n`, `shellcheck`, `shfmt -d`).
- Test: `./scripts/test.sh` (runs `./tests/test_cli.sh`).
- Prefer small, focused commits with Conventional Commits (e.g. `feat:`, `fix:`, `docs:`, `chore(ci):`).

## Script conventions (`updates`)

- Don’t print success messages for failed commands.
- Add new functionality as a module function (`module_<name>()`) and register it in:
  - `is_module_known()`
  - `module_description()`
  - `list_modules()`
  - `run_selected_modules()`
- Modules must be auto-detected (skip gracefully if the backing command is missing), unless `--only` is used (then missing deps are an error).
- Keep output stable and easy to parse; prefer `--no-emoji` in tests.

## Releases / versioning

- Use SemVer tags: `vX.Y.Z`.
- Keep `UPDATES_VERSION` in `updates` aligned with the latest release tag.
- Add a `CHANGELOG.md` entry for each release.

## Safety

- Avoid changing user environments unexpectedly. Default behavior should remain predictable.
- Prefer `--dry-run` support for anything that might mutate state.

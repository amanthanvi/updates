# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-02-07

### Removed

- Removed deprecated flags introduced in `0.9.0`: `-q`/`--quiet`, `-v`/`--verbose`, `--python-break-system-packages`, `--[no-]brew-casks`, `--[no-]brew-greedy`.

## [0.9.0] - 2026-02-07

### Added

- `--log-level <error|warn|info|debug>` (replaces `--quiet`/`--verbose`).
- `--json` mode: JSONL events on stdout; human output on stderr.
- `~/.updatesrc` config file support + `--no-config`.
- `--brew-mode <formula|casks|greedy>` (replaces `--brew-casks`/`--brew-greedy`).
- `--pip-force` (replaces `--python-break-system-packages`).
- `-n` alias for `--non-interactive`.
- New modules: `uv`, `mise`, `go` (`go` reads `GO_BINARIES` from `~/.updatesrc`, defaulting to `@latest`).
- CI runs lint/tests on macOS and Linux.

### Deprecated

- `-q` / `--quiet` (use `--log-level warn`).
- `-v` / `--verbose` (use `--log-level debug`).
- `--python-break-system-packages` (use `--pip-force`).
- `--brew-casks`, `--brew-greedy` (use `--brew-mode`).

## [0.8.1] - 2026-01-30

### Fixed

- Self-update now accepts checksum entries that include a path prefix (e.g. `dist/updates`).
- Release `SHA256SUMS` now uses basenames (enables self-update from `v0.8.0`).

## [0.8.0] - 2026-01-30

### Added

- Self-update support: checks GitHub Releases and updates the installed `updates` script.

## [0.7.0] - 2026-01-17

### Added

- `shell` module to update Oh My Zsh and custom git plugins/themes.

## [0.6.0] - 2026-01-04

### Added

- `--full` preset to enable app/system update modules (Homebrew casks, `mas`, `macos`).
- `--brew-casks` / `--no-brew-casks` flags.
- `--mas-upgrade` / `--no-mas-upgrade` flags.
- `--macos-updates` / `--no-macos-updates` flags.

### Changed

- On macOS, Homebrew cask upgrades are disabled by default (formula upgrades still run).
- On macOS, the `mas` and `macos` modules are disabled by default.

## [0.5.1] - 2026-01-02

### Added

- TTY-only ANSI colors for boundary lines and `WARN:`/`ERROR:` prefixes (disable with `--no-color` or `NO_COLOR=1`).

## [0.5.0] - 2026-01-02

### Added

- Standardized per-module boundary lines (`==> <module> START/END`) and a summary line.
- SIGINT/SIGTERM handling with explicit exit codes.

### Changed

- Linux `apt-get` non-interactive upgrades set `DEBIAN_FRONTEND=noninteractive`.
- Python `pip` calls disable the version check to reduce overhead/noise.
- `--only` now validates that selected modules are supported on the current platform.

## [0.4.0] - 2026-01-02

### Added

- `SPEC.md` as a centralized, living specification for the CLI/module contract.
- `PLAN.md` as the execution checklist for this release.
- Linux support (including WSL detection).
- `linux` module to upgrade system packages via an auto-detected package manager.
- `--python-break-system-packages` flag to opt into unsafe PEP 668 overrides.

### Changed

- `updates` now supports macOS and Linux (no longer macOS-only).
- Python upgrades default to user-site packages when PEP 668 externally-managed is detected.

## [0.3.0] - 2025-12-30

### Added

- Modular CLI with `--only/--skip`, `--dry-run`, `--log-file`, and `--strict`.
- Modules: `mas`, `pipx`, `rustup` (in addition to existing brew/npm/pip/claude/macos checks).
- Lint + tests + CI workflow.

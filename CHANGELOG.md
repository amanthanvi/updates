# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

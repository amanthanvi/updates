# Plan: v0.4.0

This is the execution plan for shipping `updates` **v0.4.0**. It is a living checklist and should be updated as work lands.

## Goals

- Fix Python failures on PEP 668 (“externally managed environment”) by defaulting to safe **user-site upgrades**.
- Support **macOS and Linux** (including WSL detection) without changing default behavior on macOS.
- Add a minimal Linux “system packages” module that **upgrades packages** via an auto-detected distro package manager.
- Keep diffs small/medium; land changes as incremental commits on `main`.

## Non-goals (avoid boiling the ocean)

- Managing language toolchains beyond existing modules (no asdf/mise/nix/etc.).
- Distro-specific edge-case tuning (keep Linux module intentionally small and safe).
- Turning `updates` into a general-purpose “system maintenance” tool.

## Execution checklist

### 1) Docs + spec scaffolding

- [x] Update `SPEC.md` with macOS/Linux/WSL platform rules and a module/platform matrix.
- [x] Update `README.md` module list + examples for Linux + WSL.

### 2) Platform support

- [x] Replace macOS-only gating with “supported platforms: macOS + Linux”.
- [x] Add WSL detection and document it (WSL updates apply to the distro, not Windows).

### 3) Python hardening (PEP 668)

- [x] Detect externally-managed Python environments.
- [x] Default to `pip install --user` upgrades when externally-managed.
- [x] Add an explicit opt-in flag to use `--break-system-packages`.
- [x] Add/adjust tests to cover the new behavior.

### 4) Linux system package upgrades (minimal)

- [x] Add a Linux module (name: `linux`) that auto-detects one of:
  - `apt-get`, `dnf`, `yum`, `pacman`, `zypper`, `apk`
- [x] Implement update + upgrade flow per package manager.
- [x] Use `sudo` when needed; honor `--non-interactive` and `--dry-run`.
- [x] Add tests for module selection + command invocation.

### 5) Release prep

- [ ] Update `updates --help` and `SPEC.md` for any new flags/modules.
- [ ] Update `CHANGELOG.md` with a `0.4.0` entry (move items out of `[Unreleased]`).
- [ ] Bump `UPDATES_VERSION` to `0.4.0`.
- [ ] Run `./scripts/lint.sh` and `./scripts/test.sh`.
- [ ] Tag `v0.4.0` and push `main` + tags.

## Notes / decisions

- Linux module should **upgrade packages** (not just list them).
- Homebrew can exist on Linux; `brew` module remains cross-platform (command-based).
- PEP 668 default is **safe** (user-site upgrades); “break system packages” requires explicit opt-in.

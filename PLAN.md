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

- [x] Update `updates --help` and `SPEC.md` for any new flags/modules.
- [x] Update `CHANGELOG.md` with a `0.4.0` entry (move items out of `[Unreleased]`).
- [x] Bump `UPDATES_VERSION` to `0.4.0`.
- [x] Run `./scripts/lint.sh` and `./scripts/test.sh`.
- [x] Tag `v0.4.0` and push `main` + tags.

## Notes / decisions

- Linux module should **upgrade packages** (not just list them).
- Homebrew can exist on Linux; `brew` module remains cross-platform (command-based).
- PEP 668 default is **safe** (user-site upgrades); “break system packages” requires explicit opt-in.

---

# Plan: v0.5.0

This is the execution plan for shipping `updates` **v0.5.0**. It focuses on clearer output, small performance improvements, and safety hardening without adding bloat.

## Goals

- Make output easier to scan: per-module boundaries, per-module statuses, and a concise end summary.
- Preserve performance: reduce unnecessary subprocess usage and avoid extra network-y checks where safe.
- Preserve security and safety: safer non-interactive behavior; clear failure reporting; no risky defaults.

## Non-goals

- Adding heavy output modes (no JSON output, no rich TUI).
- Rewriting modules to wrap/parse tool output (brew/pip/etc. output remains the source).
- Adding new runtime dependencies.

## Execution checklist

### 1) Spec-first: output contract

- [x] Update `SPEC.md` with standardized module boundaries and summary lines.
- [x] Document signal handling behavior (Ctrl-C) and exit codes.

### 2) Implement output scaffolding + timings

- [x] Add a module runner wrapper that prints `START`/`END` lines with `OK/SKIP/FAIL` + duration.
- [x] Print a final summary (counts + failures) and preserve `--quiet` / `--verbose` behavior.
- [x] Switch timing to Bash `SECONDS` (avoid `date` subprocesses).

### 3) Safety + perf hardening

- [x] Add SIGINT/SIGTERM handling with clean “interrupted” output and exit `130`.
- [x] Improve non-interactive Linux upgrades (`DEBIAN_FRONTEND=noninteractive` for `apt-get`).
- [x] Reduce pip overhead/noise where safe (e.g., disable pip version check).

### 4) Tests + docs

- [x] Extend `tests/test_cli.sh` to assert module boundary/summary output (using stubs).
- [x] Update `README.md` with a short example of the new output.
- [x] Add `CHANGELOG.md` entries for 0.5.0 as changes land.

### 5) Release

- [x] Bump `UPDATES_VERSION` to `0.5.0`.
- [x] Finalize `CHANGELOG.md` with `## [0.5.0] - YYYY-MM-DD`.
- [x] Run `./scripts/lint.sh` and `./scripts/test.sh`.
- [x] Tag and push `v0.5.0`.

---

# Plan: v0.5.1

This is the execution plan for shipping `updates` **v0.5.1**. It adds optional, TTY-only ANSI coloring without changing non-TTY output.

## Goals

- Add user-friendly ANSI coloring for module boundary lines and `WARN:`/`ERROR:` prefixes.
- Preserve stable, grep-friendly output when piped and keep `--log-file` output clean.

## Non-goals

- Adding a rich TUI or alternative output modes.
- Colorizing third-party tool output (`brew`, `pip`, etc.).

## Execution checklist

- [x] Add `--no-color` flag and support `NO_COLOR=1`.
- [x] Colorize boundary lines and `WARN:`/`ERROR:` prefixes when output is a TTY.
- [x] Update `SPEC.md`, `README.md`, and `CHANGELOG.md`.
- [x] Run `./scripts/lint.sh` and `./scripts/test.sh`.
- [x] Tag `v0.5.1` and push `main` + tags.

---

# Plan: v0.6.0 (superseded)

This plan was superseded. `v0.6.0` shipped as opt-in app/system update presets; the `shell` module work moved to `v0.7.0`.

## Goals

- Add a `shell` module that detects and updates:
  - Oh My Zsh itself (git fast-forward only)
  - Git-backed Oh My Zsh custom plugins/themes
- Fully align `SPEC.md` with the current CLI (remove stale flags; correct module defaults; correct `--non-interactive` behavior).

## Non-goals (avoid feature creep)

- No rich TUI / heavy output modes.
- No support matrix explosion (start with Oh My Zsh + git-based custom repos only).
- No modifications to the user’s shell config (`.zshrc`, etc.).

## Execution checklist

### 1) Spec-first alignment

- [ ] Remove stale flags from `SPEC.md` that are not implemented (`--full`, `--mas-upgrade`, `--macos-updates`, `--brew-casks`).
- [ ] Update `SPEC.md` module selection rules and `--non-interactive` semantics to match the current code.

### 2) Implement `shell` module (minimal)

- [ ] Add module registration: `is_module_known()`, `module_description()`, `list_modules()`, `run_selected_modules()`, `module_supported()`.
- [ ] Implement detection:
  - `~/.oh-my-zsh` or `$ZSH`
  - `$ZSH_CUSTOM` or `$ZSH/custom` for plugins/themes
- [ ] Implement safe updates:
  - `git pull --ff-only` for each detected repo
  - Honor `--dry-run`
  - In `--non-interactive`, prevent credential prompts

### 3) Tests + docs

- [ ] Add/extend tests for `--only shell` (using stubs + temp HOME fixtures).
- [ ] Update `README.md`, `SPEC.md`, and `CHANGELOG.md` under `[Unreleased]`.

### 4) Release

- [ ] Bump `UPDATES_VERSION` to `0.6.0` and finalize `CHANGELOG.md`.
- [ ] Run `./scripts/lint.sh` and `./scripts/test.sh`.
- [ ] Tag `v0.6.0` and push `main` + tags.

---

# Plan: v0.7.0

This is the execution plan for shipping `updates` **v0.7.0**. It adds a minimal `shell` module for common shell customization tooling (starting with Oh My Zsh) and documents it in `SPEC.md`.

## Goals

- Add a `shell` module that detects and updates:
  - Oh My Zsh itself (git fast-forward only)
  - Git-backed Oh My Zsh custom plugins/themes
- Keep behavior safe and non-invasive (no edits to shell config files).

## Non-goals (avoid feature creep)

- No support matrix explosion (start with Oh My Zsh + git-based custom repos only).
- No rich TUI / alternative output modes.
- No modification of user dotfiles (`.zshrc`, etc.).

## Execution checklist

### 1) Spec + docs

- [x] Update `SPEC.md` module list/matrix to include `shell`.
- [x] Update `README.md` module list + prerequisites.
- [x] Add `CHANGELOG.md` entries under `[Unreleased]`.

### 2) Implement `shell` module (minimal)

- [x] Add module registration: `is_module_known()`, `module_description()`, `list_modules()`, `run_selected_modules()`, `module_supported()`.
- [x] Implement detection:
  - `~/.oh-my-zsh` or `$ZSH`
  - `$ZSH_CUSTOM` or `$ZSH/custom` for plugins/themes
- [x] Implement safe updates:
  - `git pull --ff-only` for each detected repo
  - Honor `--dry-run`
  - In `--non-interactive`, disable git terminal prompts

### 3) Tests

- [x] Add tests for `--only shell` (using stubs + temp HOME fixtures).

### 4) Release

- [x] Bump `UPDATES_VERSION` to `0.7.0` and finalize `CHANGELOG.md`.
- [x] Run `./scripts/lint.sh` and `./scripts/test.sh`.
- [x] Tag `v0.7.0` and push `main` + tags.

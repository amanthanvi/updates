# updates — Specification (Living)

This document is the **source of truth** for how the `updates` CLI behaves: flags, output, exit codes, module contracts, and release invariants.

If anything here disagrees with other docs, update the other docs (or this spec) so they match.

## Scope

This spec describes the Bash script at `./updates` and the workflows/scripts shipped with this repository.

Non-goals:

- Not a general-purpose package manager.
- Not an installer for dependencies (`brew`, `pipx`, `mas`, etc.).
- Not an automatic macOS upgrade tool (the `macos` module lists updates; it does not install them).

## Terminology

The key words **MUST**, **SHOULD**, and **MAY** are to be interpreted as described in RFC 2119.

## Platform support

- **Supported OS:** macOS and Linux (detected by `uname -s`).
- **Bash:** runs via `/bin/bash` (macOS system Bash).

WSL is treated as Linux. The script detects WSL via `WSL_DISTRO_NAME` and/or common `/proc` markers.

On unsupported systems the script **MUST** exit with code `2`, unless the user sets `UPDATES_ALLOW_NON_DARWIN=1` (see Environment).

## Installation (repository-distributed)

Recommended:

- `make install` (installs to `$(PREFIX)/bin`, default `PREFIX=/usr/local`)
- `make uninstall`

Manual:

- `install -m 0755 updates /some/bin/dir/updates`

## CLI contract

### Invocation

`updates [options]`

The CLI takes no positional arguments. Unknown options or unexpected arguments **MUST** error.

### Exit codes

- `0`: success (including cases where some modules were skipped due to missing dependencies)
- `1`: one or more selected modules failed
- `2`: usage / configuration error (unknown flag, missing flag value, invalid flag value, non-macOS without override, etc.)
- `130`: interrupted (SIGINT)
- `143`: terminated (SIGTERM)

### Output + logging

Output is intended to be stable and easy to grep.

- Normal progress goes to **stdout**.
- Warnings and errors go to **stderr** and are prefixed:
  - `WARN: ...`
  - `ERROR: ...`
- `--quiet` suppresses *normal* output, but **MUST NOT** suppress `WARN:`/`ERROR:` messages.
- Emoji is enabled by default; `--no-emoji` removes emoji from output (useful for tests/CI/log parsing).
- ANSI colors are enabled automatically when output is a TTY; set `NO_COLOR=1` or pass `--no-color` to disable. When `--log-file` is used, colors are disabled to keep logs clean.
- `--log-file <path>` duplicates output to the given file by teeing **both stdout and stderr** and appending (`tee -a`).
  - The log directory is created if missing (`mkdir -p`).

Standardized boundaries:

- Each selected module prints boundary lines:
  - `==> <module> START`
  - `==> <module> END (<OK|SKIP|FAIL>) (<Ns>)`
- After the run completes, a summary line is printed:
  - `==> SUMMARY ok=<N> skip=<N> fail=<N> total=<Ns> [failures=<csv>]`

### Options

- `-h`, `--help`: print help and exit `0`.
- `--version`: print the SemVer version (e.g. `0.3.0`) and exit `0`.
- `--list-modules`: print the module list and exit `0`.

Execution control:

- `--dry-run`: **MUST NOT** execute mutating commands; prints what would run.
- `--only <list>`: run only the named modules.
- `--skip <list>`: skip the named modules.
- `--strict`: stop on the first module failure.

Output verbosity:

- `-q`, `--quiet`: reduce output (warnings/errors still print).
- `-v`, `--verbose`: print extra debug lines (including commands, prefixed with `+`).
- `--self-update` / `--no-self-update`: enable/disable self-update (default enabled).
- `--no-emoji`: disable emoji.
- `--no-color`: disable ANSI colors.

Misc:

- `--log-file <path>`: append all output to a log file.
- `--non-interactive`: avoid interactive prompts when possible (affects Linux system package upgrades, Python `pip` upgrades, and `shell` git updates).
- `--parallel <N>`: parallelism for Python package upgrades (default `4`, minimum `1`).
- `--python-break-system-packages`: pass `--break-system-packages` to `pip` (unsafe; for PEP 668 environments).
- `--full`: enable app/system update modules (Homebrew casks, `mas`, and `macos`).

Homebrew flags:

- `--brew-greedy` / `--no-brew-greedy`: include greedy cask upgrades (default enabled).
- `--brew-casks` / `--no-brew-casks`: upgrade Homebrew casks (default disabled on macOS; enabled elsewhere).
- `--brew-cleanup` / `--no-brew-cleanup`: run `brew cleanup` after upgrade (default enabled).

macOS module flags:

- `--mas-upgrade` / `--no-mas-upgrade`: enable the `mas` module in default runs (default disabled; `--only mas` still forces it).
- `--macos-updates` / `--no-macos-updates`: enable the `macos` module in default runs (default disabled; `--only macos` still forces it).

Self-update:

- When enabled, `updates` checks GitHub Releases for `UPDATES_SELF_UPDATE_REPO` (default `amanthanvi/updates`).
- If the latest release tag is newer than `UPDATES_VERSION`, it downloads the `updates` release artifact and verifies it against `SHA256SUMS`.
- If install succeeds, it replaces the current script and re-execs itself once (guarded by `UPDATES_SELF_UPDATED=1`).
- Self-update is skipped in `--dry-run` mode and when `CI` is set.

### Module lists (`--only`, `--skip`)

Module lists are parsed from a **single argument**:

- CSV is recommended: `--only brew,node`
- Whitespace inside the argument is supported, but must be quoted: `--only "brew node"`

If `--only`/`--skip` includes an unknown module, the CLI **MUST** exit with code `2`.
If `--only` includes a module that is not supported on the current platform, the CLI **MUST** exit with code `2`.

Precedence rules:

- `--skip` overrides `--only`.

## Environment variables

- `UPDATES_ALLOW_NON_DARWIN=1`
  - When set, the script runs on unsupported OSes and prints a warning.
  - Intended for tests/CI and advanced usage; behavior is not guaranteed outside macOS/Linux.
- `UPDATES_SELF_UPDATE=0`
  - Disables self-update (useful for tests/CI or locked-down environments).
- `UPDATES_SELF_UPDATE_REPO=owner/repo`
  - GitHub repository to check for releases (default: `amanthanvi/updates`).
  - Self-update downloads the `updates` release artifact and verifies it against `SHA256SUMS`.
- `NO_COLOR=1`
  - Disables ANSI colors in output.

## Module system

### Principles

- Each module is a Bash function named `module_<name>()`.
- Modules are run sequentially in a fixed order:
  `brew`, `shell`, `linux`, `node`, `python`, `mas`, `pipx`, `rustup`, `claude`, `macos`.
- Some modules are **opt-in** in default runs for safety:
  - `mas` (enable with `--mas-upgrade` or `--full`)
  - `macos` (enable with `--macos-updates` or `--full`)
- On macOS, Homebrew casks are disabled by default (enable with `--brew-casks` or `--full`).
- Modules are command-driven; this matrix is informational:

| Module   | macOS | Linux | WSL | Notes |
|----------|:-----:|:-----:|:---:|-------|
| `brew`   |  ✅   |  ✅   | ✅  | Requires `brew` (Homebrew can be installed on Linux) |
| `shell`  |  ✅   |  ✅   | ✅  | Requires `git`; updates Oh My Zsh + git-backed custom plugins/themes when detected |
| `linux`  |  ❌   |  ✅   | ✅  | Requires a supported Linux package manager + optional `sudo` |
| `node`   |  ✅   |  ✅   | ✅  | Requires `ncu` + `npm` |
| `python` |  ✅   |  ✅   | ✅  | Requires `python3 -m pip` |
| `mas`    |  ✅   |  ❌   | ❌  | Requires `mas` |
| `pipx`   |  ✅   |  ✅   | ✅  | Requires `pipx` |
| `rustup` |  ✅   |  ✅   | ✅  | Requires `rustup` |
| `claude` |  ✅   |  ✅   | ✅  | Requires `claude` |
| `macos`  |  ✅   |  ❌   | ❌  | Requires `softwareupdate` |
- Modules are **auto-detected**:
  - If the backing command is missing and the module is not explicitly required, the module is skipped.
  - If the module is selected via `--only`, missing dependencies become an error.
- `--dry-run` is a first-class mode:
  - A module **MUST** not run mutating commands when `--dry-run` is set.
  - Modules **SHOULD** print representative `DRY RUN:` lines.

### Skip vs failure

Internally:

- Return `0`: success
- Return `1`: failure
- Return `2`: skipped due to missing dependency (non-`--only` mode)

User-visible behavior:

- Skipped modules do not make the overall run fail.
- Failed modules make the run exit `1` (unless no selected modules failed).
- With `--strict`, the script stops at the first failure.

## Module specifications

Each module’s contract includes: required commands, what it runs, and side effects.

### `brew`

Purpose: update and upgrade Homebrew formulae (and optionally casks).

- Requires: `brew`
- Non-dry-run commands:
  - `brew update`
  - If casks are disabled (`--no-brew-casks`, default on macOS): `brew upgrade --formula`
  - Otherwise: `brew upgrade [--greedy]`
  - optionally `brew cleanup` (controlled by `--[no-]brew-cleanup`)
- Side effects:
  - Upgrades Homebrew-managed packages and (optionally) cleans up old versions.

### `linux`

Purpose: upgrade Linux system packages using the host distro package manager.

- Runs only on Linux (including WSL).
- Requires:
  - One of: `apt-get`, `dnf`, `yum`, `pacman`, `zypper`, `apk`
  - If not running as root: `sudo` (uses `sudo -n` when `--non-interactive` is set)
- Non-dry-run commands (auto-detected):
  - `apt-get`: `apt-get update`, `apt-get upgrade [-y]`
  - `dnf`: `dnf upgrade [-y]`
  - `yum`: `yum update [-y]`
  - `pacman`: `pacman -Syu [--noconfirm]`
  - `zypper`: `zypper refresh [--non-interactive]`, `zypper update [--non-interactive]`
  - `apk`: `apk update`, `apk upgrade`
- Side effects:
  - Upgrades OS-managed packages and may require elevated privileges.

### `shell`

Purpose: update common shell customization tooling (currently Oh My Zsh) and its git-backed custom plugins/themes.

- Requires: `git`
- Applicable on: macOS and Linux (including WSL)
- Detection:
  - Oh My Zsh directory: `$ZSH` (if set and exists) or `~/.oh-my-zsh`
  - Custom directory: `$ZSH_CUSTOM` (if set) or `<ZSH>/custom`
  - Custom plugin/theme repos are detected in:
    - `<custom>/plugins/*`
    - `<custom>/themes/*`
    - A directory is considered a repo if `<dir>/.git` exists.
- Non-dry-run behavior:
  - For each detected git repo, runs: `git -C <dir> pull --ff-only`
  - With `--non-interactive`, git prompts are disabled by setting `GIT_TERMINAL_PROMPT=0`.
- Side effects:
  - Updates the detected repositories in-place (typically under `~/.oh-my-zsh`).

### `node`

Purpose: upgrade global npm packages using `npm-check-updates`.

- Requires:
  - `ncu` (npm-check-updates)
  - `npm`
  - JSON parsing support via either `python3` or `node` (used to parse `ncu` output)
- Non-dry-run behavior:
  - Runs `ncu -g --jsonUpgraded` to detect upgrades.
  - If upgrades exist, runs: `npm install -g -- <name@version>...`
- Side effects:
  - Upgrades global npm packages.

### `python`

Purpose: upgrade global Python packages with `pip`.

- Requires: `python3` (and a working `pip` module under it)
- Non-dry-run behavior:
  - Detect outdated packages:
    - default: `python3 -m pip list --outdated --format=json`
    - if the environment is externally-managed (PEP 668): `python3 -m pip list --outdated --format=json --user`
  - Upgrade each package:
    - `python3 -m pip install -U <pkg>`
    - With `--non-interactive`: `python3 -m pip install -U --no-input <pkg>`
    - With PEP 668 safe mode: add `--user`
    - With `--python-break-system-packages`: add `--break-system-packages`
  - Upgrades run in parallel batches of `--parallel <N>`.
- Side effects:
  - Upgrades Python packages for the selected install scope (`--user` for PEP 668 safe mode; otherwise environment-wide).

### `mas`

Purpose: upgrade Mac App Store apps.

- Disabled by default unless enabled via `--mas-upgrade` / `--full` or explicitly selected via `--only mas`.
- Requires: `mas`
- Non-dry-run commands:
  - `mas upgrade`
- Side effects:
  - Upgrades App Store apps.

### `pipx`

Purpose: upgrade pipx-managed apps.

- Requires: `pipx`
- Non-dry-run commands:
  - `pipx upgrade-all`
- Side effects:
  - Upgrades pipx-installed tools.

### `rustup`

Purpose: update Rust toolchains.

- Requires: `rustup`
- Non-dry-run commands:
  - `rustup update`
- Side effects:
  - Updates installed Rust toolchains/components.

### `claude`

Purpose: update the Claude Code CLI.

- Requires: `claude`
- Non-dry-run commands:
  - `claude update`
- Side effects:
  - Updates the Claude Code CLI (per Claude’s updater behavior).

### `macos`

Purpose: list available macOS software updates.

- Disabled by default unless enabled via `--macos-updates` / `--full` or explicitly selected via `--only macos`.
- Requires: `softwareupdate`
- Non-dry-run commands:
  - `softwareupdate -l`
- Side effects:
  - Lists updates only (does not install).

## Development + QA

Validated commands:

- Lint: `./scripts/lint.sh`
  - Runs `bash -n`, `shellcheck`, and `shfmt -d`.
  - Requires local tools: `shellcheck`, `shfmt`.
- Tests: `./scripts/test.sh`
  - Runs `./tests/test_cli.sh`.
  - Tests stub external commands via a temporary `PATH` to avoid modifying the developer’s machine.

## Releases

Versioning:

- SemVer versions, tagged as `vX.Y.Z`.
- The script version is `UPDATES_VERSION="<version>"` inside `updates`.

Invariants (enforced in CI/release):

- Tag version `vX.Y.Z` **MUST** match `UPDATES_VERSION="X.Y.Z"`.
- `CHANGELOG.md` **MUST** contain a header `## [X.Y.Z]` for the release.

Maintainer workflow:

- `./scripts/release.sh X.Y.Z` (validates invariants, runs lint/tests, creates an annotated tag).
- Push `main` and tags; GitHub Actions builds and publishes release artifacts.

## Documentation policy (living)

When changing behavior:

- Update `SPEC.md` first (or alongside the change).
- Keep `README.md` as the quick-start; link to this spec for details.
- Update `CHANGELOG.md` under `[Unreleased]` for user-visible changes.

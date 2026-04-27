# updates

A small, modular CLI to update common macOS, Linux, WSL, and Windows tooling.

The current main-branch docs target the in-flight `v2.0.0` release contract: Bash remains the entrypoint on macOS/Linux/WSL, while native Windows support uses `pwsh` via `updates.cmd` and `updates.ps1`.

This script can be disruptive (it updates global environments). Use `--dry-run` and scope with `--only` / `--skip`.

## Spec

See `SPEC.md` for the full CLI/module contract, exit codes, and release invariants.

## Install

Using the Makefile (macOS/Linux/WSL):

```bash
make install
# Recommended (user-writable; enables self-update without sudo):
# make install PREFIX=$HOME/.local
# or: make install PREFIX=/opt/homebrew
```

Manual install (macOS/Linux/WSL):

```bash
chmod +x ./updates
sudo mkdir -p /usr/local/bin
sudo install -m 0755 ./updates /usr/local/bin/updates
```

Planned native Windows install (`v2.0.0`):

```powershell
# Official channel: GitHub Releases only
# Extract updates-windows.zip to:
$env:LOCALAPPDATA\Programs\updates

# Then run:
$env:LOCALAPPDATA\Programs\updates\updates.cmd
```

## Usage

```bash
updates
updates --dry-run
updates --only brew,node --brew-mode formula
updates --only linux -n
updates --only winget,node,bun
updates --full
updates --skip python --log-file ./updates.log
updates --json -n --no-self-update --log-level warn
```

Example output (trimmed):

```text
Starting updates...
==> brew START
Homebrew 🍺
==> brew END (OK) (12s)
==> SUMMARY ok=1 skip=0 fail=0 total=12s
Done in 12s. 🎉
```

List available modules:

```bash
updates --list-modules
```

Show help:

```bash
updates --help
```

## Modules

Modules are auto-detected: if the underlying command isn’t installed, the module is skipped (unless you used `--only`, in which case it’s an error).

- `brew`: update/upgrade Homebrew formulae (+ casks when enabled via `--brew-mode casks` / `--brew-mode greedy` / `--full`)
- `shell`: update Oh My Zsh and custom git plugins/themes (auto-detected)
- `repos`: update aman dev repos under `~/GitRepos` (auto-detected `aman-*-setup` dirs)
- `linux`: upgrade Linux system packages (auto-detects `apt-get`/`dnf`/`yum`/`pacman`/`zypper`/`apk`)
- `winget`: upgrade installed Windows packages/apps via `winget` (Windows only)
- `node`: upgrade global npm packages via resolved npm-check-updates + `npm`
- `bun`: upgrade Bun global packages everywhere; native Windows only self-updates the Bun CLI when it appears standalone-installed
- `python`: upgrade global/user Python packages via a resolved launcher (`py -3`, `python`, then `python3`)
- `uv`: update uv-managed tools everywhere; native Windows only self-updates uv when it appears standalone-installed
- `mas`: upgrade Mac App Store apps via `mas` (disabled by default; enable with `--mas-upgrade` or `--full`)
- `pipx`: upgrade pipx-managed apps via `pipx upgrade-all`
- `rustup`: update Rust toolchains via `rustup update`
- `claude`: update Claude Code CLI via `claude update`
- `pi`: update pi AI CLI extensions via `pi update`
- `mise`: update mise and upgrade installed tools (`mise self-update`, `mise upgrade`)
- `go`: update Go binaries from `GO_BINARIES` in `~/.updatesrc` (entries default to `@latest`)
- `macos`: list available macOS software updates via `softwareupdate -l` (disabled by default; enable with `--macos-updates` or `--full`)

Native Windows `v2.0.0` default-on modules: `winget`, `node`, `bun`, `python`, `uv`, `pipx`, `rustup`, `go`.
On native Windows, `--full` selects every supported Windows module even if `SKIP_MODULES` in config would otherwise omit one; explicit `--skip` still wins.

## Configuration (`~/.updatesrc`)

`updates` optionally reads `~/.updatesrc` for defaults (CLI flags override; pass `--no-config` to ignore). The file is parsed as line-oriented `KEY=value`, tolerates a UTF-8 BOM, and resolves home via `HOME` or `USERPROFILE` on Windows.

Native Windows note: `PARALLEL` remains part of the shared config surface for the Bash implementation, but the PowerShell runtime warns and ignores it; explicit `--parallel <N>` is rejected on native Windows.

Example:

```bash
# ~/.updatesrc
SKIP_MODULES=mas,macos
BREW_MODE=formula
BREW_CLEANUP=1
LOG_LEVEL=info
GO_BINARIES="golang.org/x/tools/gopls,github.com/go-delve/delve/cmd/dlv"
```

For `GO_BINARIES`, entries may be `module` or `module@version`. If `@version` is omitted, it defaults to `@latest`.

## Prerequisites

Install what you actually use:

- `brew` (Homebrew)
- `git` (for the `shell` and `repos` modules)
- `ncu` or `npx npm-check-updates` (for the `node` module)
- `pwsh` (PowerShell 7) for native Windows support
- `winget` for the `winget` module on Windows
- `bun` for the `bun` module
- `uv`: https://github.com/astral-sh/uv
- `mas`: `brew install mas`
- `mise`: https://mise.jdx.dev
- `pipx`: `brew install pipx`
- `rustup`: from https://rustup.rs
- `claude` (Claude Code CLI) for the `claude` module
- `pi` (npm-installed AI coding CLI) for the `pi` module
- `go` (for the `go` module)
- On Linux: a supported system package manager (`apt-get`, `dnf`, `yum`, `pacman`, `zypper`, or `apk`) and `sudo` (if not running as root)

## Development

```bash
./scripts/lint.sh
./scripts/test.sh
```

## Notes / Safety

- This script updates _global_ environments (`npm -g`, `pip`), which can be disruptive.
- Use `--dry-run` first, and consider `--only`/`--skip` to control scope.
- `updates` itself is distributed through GitHub Releases only. No third-party package-manager channel is supported for `updates` in `v2.0.0`.
- Self-update is fixed to the canonical GitHub repo `amanthanvi/updates`; `UPDATES_SELF_UPDATE_REPO` is removed in `v2.0.0` and setting it is an error.
- Official self-update artifacts for `v2.0.0` are `updates`, `updates-windows.zip`, `updates-release.json`, and `SHA256SUMS`.
- Normal runs throttle GitHub release checks to about once every 24 hours using a small local cache under `XDG_CACHE_HOME`, `~/Library/Caches`, `~/.cache`, or `%LOCALAPPDATA%\\updates`; explicit `--self-update` forces a live check.
- Native Windows self-update works only for official standalone installs rooted at `%LOCALAPPDATA%\\Programs\\updates` with a valid `install-source.json` receipt. Manual file copies warn and skip instead of being overwritten.
- On macOS, Homebrew casks are disabled by default; enable with `--brew-mode casks` or `--brew-mode greedy` (or `--full`). On macOS 26+, cask upgrades may be blocked unless your terminal app is allowed under **Privacy & Security → App Management** (e.g. Ghostty). If you see a system notification like “\<Terminal App\> tried modifying your system…”, enable App Management or rerun with `--brew-mode formula`.
- On WSL, updates apply to the Linux distro; native Windows updates require the native Windows entrypoints.
- Output uses ANSI colors when run in a TTY; disable with `--no-color` or `NO_COLOR=1`. When `--log-file` is used, colors are disabled to keep logs clean.
- If Python is externally-managed (PEP 668), `updates` upgrades user-site packages by default; use `--pip-force` to override (dangerous).

## Contributing

See `CONTRIBUTING.md`.

## License

MIT — see `LICENSE`.

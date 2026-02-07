# updates

A small, modular Bash CLI to update common macOS and Linux tooling (Homebrew, global npm packages, global Python packages, etc.).

This script can be disruptive (it updates global environments). Use `--dry-run` and scope with `--only` / `--skip`.

## Spec

See `SPEC.md` for the full CLI/module contract, exit codes, and release invariants.

## Install

Using the Makefile:

```bash
make install
# Recommended (user-writable; enables self-update without sudo):
# make install PREFIX=$HOME/.local
# or: make install PREFIX=/opt/homebrew
```

Manual install:

```bash
chmod +x ./updates
sudo mkdir -p /usr/local/bin
sudo install -m 0755 ./updates /usr/local/bin/updates
```

## Usage

```bash
updates
updates --dry-run
updates --only brew,node --brew-mode formula
updates --only linux -n
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
- `linux`: upgrade Linux system packages (auto-detects `apt-get`/`dnf`/`yum`/`pacman`/`zypper`/`apk`)
- `node`: upgrade global npm packages via `ncu` + `npm`
- `python`: upgrade global Python packages via `python3 -m pip`
- `uv`: update uv and uv-managed tools (`uv self update`, `uv tool upgrade --all`)
- `mas`: upgrade Mac App Store apps via `mas` (disabled by default; enable with `--mas-upgrade` or `--full`)
- `pipx`: upgrade pipx-managed apps via `pipx upgrade-all`
- `rustup`: update Rust toolchains via `rustup update`
- `claude`: update Claude Code CLI via `claude update`
- `mise`: update mise and upgrade installed tools (`mise self-update`, `mise upgrade`)
- `go`: update Go binaries from `GO_BINARIES` in `~/.updatesrc` (entries default to `@latest`)
- `macos`: list available macOS software updates via `softwareupdate -l` (disabled by default; enable with `--macos-updates` or `--full`)

## Configuration (`~/.updatesrc`)

`updates` optionally reads `~/.updatesrc` for defaults (CLI flags override; pass `--no-config` to ignore).

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
- `git` (for the `shell` module)
- `ncu` (npm-check-updates): `npm install -g npm-check-updates`
- `uv`: https://github.com/astral-sh/uv
- `mas`: `brew install mas`
- `mise`: https://mise.jdx.dev
- `pipx`: `brew install pipx`
- `rustup`: from https://rustup.rs
- `claude` (Claude Code CLI) for the `claude` module
- `go` (for the `go` module)
- On Linux: a supported system package manager (`apt-get`, `dnf`, `yum`, `pacman`, `zypper`, or `apk`) and `sudo` (if not running as root)

## Development

```bash
./scripts/lint.sh
./scripts/test.sh
```

## Notes / Safety

- This script updates *global* environments (`npm -g`, `pip`), which can be disruptive.
- Use `--dry-run` first, and consider `--only`/`--skip` to control scope.
- `updates` can self-update from GitHub Releases; disable with `--no-self-update` or `UPDATES_SELF_UPDATE=0`. Self-update works best when installed to a user-writable location (e.g. `PREFIX=$HOME/.local`).
- On macOS, Homebrew casks are disabled by default; enable with `--brew-mode casks` or `--brew-mode greedy` (or `--full`). On macOS 26+, cask upgrades may be blocked unless your terminal app is allowed under **Privacy & Security → App Management** (e.g. Ghostty). If you see a system notification like “\<Terminal App\> tried modifying your system…”, enable App Management or rerun with `--brew-mode formula`.
- On WSL, updates apply to the Linux distro (not Windows itself).
- Output uses ANSI colors when run in a TTY; disable with `--no-color` or `NO_COLOR=1`. When `--log-file` is used, colors are disabled to keep logs clean.
- If Python is externally-managed (PEP 668), `updates` upgrades user-site packages by default; use `--pip-force` to override (dangerous).

## Contributing

See `CONTRIBUTING.md`.

## License

MIT — see `LICENSE`.

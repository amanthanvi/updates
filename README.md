# updates

A small, modular Bash CLI to update common macOS and Linux tooling (Homebrew, global npm packages, global Python packages, etc.).

This script can be disruptive (it updates global environments). Use `--dry-run` and scope with `--only` / `--skip`.

## Spec

See `SPEC.md` for the full CLI/module contract, exit codes, and release invariants.

## Install

Using the Makefile:

```bash
make install
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
updates --only brew,node
updates --only linux --non-interactive
updates --full
updates --skip python --log-file ./updates.log
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

- `brew`: update/upgrade Homebrew formulae (+ casks when enabled via `--brew-casks` / `--full`)
- `shell`: update Oh My Zsh and custom git plugins/themes (auto-detected)
- `linux`: upgrade Linux system packages (auto-detects `apt-get`/`dnf`/`yum`/`pacman`/`zypper`/`apk`)
- `node`: upgrade global npm packages via `ncu` + `npm`
- `python`: upgrade global Python packages via `python3 -m pip`
- `mas`: upgrade Mac App Store apps via `mas` (disabled by default; enable with `--mas-upgrade` or `--full`)
- `pipx`: upgrade pipx-managed apps via `pipx upgrade-all`
- `rustup`: update Rust toolchains via `rustup update`
- `claude`: update Claude Code CLI via `claude update`
- `macos`: list available macOS software updates via `softwareupdate -l` (disabled by default; enable with `--macos-updates` or `--full`)

## Prerequisites

Install what you actually use:

- `brew` (Homebrew)
- `git` (for the `shell` module)
- `ncu` (npm-check-updates): `npm install -g npm-check-updates`
- `mas`: `brew install mas`
- `pipx`: `brew install pipx`
- `rustup`: from https://rustup.rs
- `claude` (Claude Code CLI) for the `claude` module
- On Linux: a supported system package manager (`apt-get`, `dnf`, `yum`, `pacman`, `zypper`, or `apk`) and `sudo` (if not running as root)

## Development

```bash
./scripts/lint.sh
./scripts/test.sh
```

## Notes / Safety

- This script updates *global* environments (`npm -g`, `pip`), which can be disruptive.
- Use `--dry-run` first, and consider `--only`/`--skip` to control scope.
- On macOS, Homebrew casks are disabled by default; enable with `--brew-casks` (or `--full`). On macOS 26+, cask upgrades may be blocked unless your terminal app is allowed under **Privacy & Security → App Management** (e.g. Ghostty). If you see a system notification like “\<Terminal App\> tried modifying your system…”, enable App Management or rerun with `--no-brew-casks`.
- On WSL, updates apply to the Linux distro (not Windows itself).
- Output uses ANSI colors when run in a TTY; disable with `--no-color` or `NO_COLOR=1`. When `--log-file` is used, colors are disabled to keep logs clean.
- If Python is externally-managed (PEP 668), `updates` upgrades user-site packages by default; use `--python-break-system-packages` to override (dangerous).

## Contributing

See `CONTRIBUTING.md`.

## License

MIT — see `LICENSE`.

# updates

Opinionated macOS update script for common tooling (Homebrew, npm globals, pip globals, etc.).

## Install

```bash
chmod +x ./updates
sudo ln -sf "$(pwd)/updates" /usr/local/bin/updates  # or ~/bin/updates
```

## Usage

```bash
updates
updates --dry-run
updates --only brew,node
updates --skip python --log-file ./updates.log
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

- `brew`: update/upgrade Homebrew formulae + casks
- `node`: upgrade global npm packages via `ncu` + `npm`
- `python`: upgrade global Python packages via `python3 -m pip`
- `mas`: upgrade Mac App Store apps via `mas`
- `pipx`: upgrade pipx-managed apps via `pipx upgrade-all`
- `rustup`: update Rust toolchains via `rustup update`
- `claude`: update Claude Code CLI via `claude update`
- `macos`: list available macOS software updates via `softwareupdate -l`

## Prerequisites

Install what you actually use:

- `brew` (Homebrew)
- `ncu` (npm-check-updates): `npm install -g npm-check-updates`
- `mas`: `brew install mas`
- `pipx`: `brew install pipx`
- `rustup`: from https://rustup.rs

## Development

```bash
./scripts/lint.sh
./scripts/test.sh
```

## Notes / Safety

- This script updates *global* environments (`npm -g`, `pip`), which can be disruptive.
- Use `--dry-run` first, and consider `--only`/`--skip` to control scope.

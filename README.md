# updates

A small, modular CLI to update common macOS, Linux, WSL, and Windows tooling.

The v2 contract uses Bash on macOS/Linux/WSL and PowerShell 7 via `updates.cmd`/`updates.ps1` on native Windows. The v2.1 release adds offline diagnosis and safer Windows activation without changing existing v2 interfaces.

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

Native Windows (`v2.1.1`, PowerShell 7):

```powershell
$version = '2.1.1'
$installer = Join-Path $env:TEMP 'install-updates-windows.ps1'

Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/amanthanvi/updates/v$version/install-windows.ps1" -OutFile $installer
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer -Version $version

& "$env:LOCALAPPDATA\Programs\updates\updates.cmd" --version
```

The installer downloads and authenticates the official `updates-windows.zip` GitHub Release asset before laying out `updates.cmd`, `updates.ps1`, versioned payload files, `current.txt`, `previous.txt`, and `install-source.json` under `%LOCALAPPDATA%\Programs\updates`. For a local ZIP, pass `-SourceZip .\updates-windows.zip` and preferably `-SourceZipSha256 <sha256>`; v2.1 accepts an unhashed local ZIP with a prominent trust warning as a compatibility bridge. The installer does not modify PATH.

The receipt's `installed_version` records the newest payload that finished installation and validation. It may temporarily differ from `current.txt` when activation fails safely and the previously active payload remains runnable.

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
updates --doctor
updates --doctor --json
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
- `shell`: update Oh My Zsh and custom git plugins/themes (auto-detected; detached, missing-upstream, or dirty tracked repos warn and skip)
- `repos`: update aman dev repos under `~/GitRepos` (auto-detected `aman-*-setup` dirs; only clean tracked branches are pulled)
- `linux`: upgrade Linux system packages (auto-detects `apt-get`/`dnf`/`yum`/`pacman`/`zypper`/`apk`)
- `winget`: upgrade installed Windows packages/apps via `winget` (Windows only)
- `node`: plan global npm upgrades via npm-check-updates, verify each candidate against the active Node runtime with npm's engine-strict dry-run, then install compatible candidates one at a time (sources NVM first when available on macOS/Linux)
- `bun`: upgrade Bun global packages everywhere; native Windows only self-updates the Bun CLI when it appears standalone-installed
- `python`: upgrade global/user Python packages via a resolved launcher (`py -3`, `python`, then `python3`); externally-managed Bash environments use a guarded user-site path
- `uv`: update uv-managed tools everywhere; native Windows only self-updates uv when it appears standalone-installed
- `mas`: upgrade Mac App Store apps via `mas` (disabled by default; enable with `--mas-upgrade` or `--full`)
- `pipx`: upgrade pipx-managed apps via `pipx upgrade-all`
- `rustup`: update Rust toolchains via `rustup update`
- `claude`: update Claude Code CLI via `claude update`
- `pi`: update pi AI CLI extensions via `pi update`
- `mise`: update mise and upgrade installed tools (`mise self-update`, `mise upgrade`)
- `go`: update Go binaries from `GO_BINARIES` in `~/.updatesrc` (entries default to `@latest`)
- `macos`: list available macOS software updates via `softwareupdate -l` (disabled by default; enable with `--macos-updates` or `--full`)

Native Windows v2.1 default-on modules: `winget`, `node`, `bun`, `python`, `uv`, `pipx`, `rustup`, `claude`, `pi`, `go`.
On native Windows, `--full` selects every supported Windows module even if `SKIP_MODULES` in config would otherwise omit one; explicit `--skip` still wins.

Platform support summary:

| Module | macOS | Linux/WSL | Windows |
| --- | :---: | :---: | :---: |
| brew, shell, repos | Yes | Yes | No |
| linux | No | Yes | No |
| winget | No | No | Yes |
| node, bun, python, uv, pipx, rustup, claude, pi, go | Yes | Yes | Yes |
| mas, macos | Yes | No | No |
| mise | Yes | Yes | Deferred |

Unsupported modules skip during default selection; explicitly selecting one with `--only` is a usage error.

## Doctor

`updates --doctor` diagnoses only local state. It performs no network access and no repair. Exit `0` means required checks passed (warnings are allowed), exit `1` means at least one integrity check failed, and exit `2` means usage or configuration was invalid. With `--json`, stdout remains JSONL-only and contains `doctor_check` plus one `doctor_summary` event.

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
NODE_NPM_INSTALL_FLAGS="--legacy-peer-deps"
```

For `GO_BINARIES`, entries may be `module` or `module@version`. If `@version` is omitted, it defaults to `@latest`.

`NODE_NPM_INSTALL_FLAGS` passes extra whitespace-separated flags to `npm install -g` in the `node` module, before the `--` package separator. Default is empty (no extra flags). This is useful when peer-dependency conflicts require a scoped flag such as `--legacy-peer-deps` without setting it globally in `~/.npmrc`.

## Prerequisites

Install what you actually use:

- `brew` (Homebrew)
- `git` (for the `shell` and `repos` modules)
- NVM-managed `npm`/`ncu` are preferred when `$NVM_DIR/nvm.sh` or `~/.nvm/nvm.sh` exists; direct `ncu` must support `--enginesNode`, otherwise `updates` falls back to `npx npm-check-updates`. Every returned candidate is also checked with npm's engine-strict dry-run; incompatible candidates warn and skip.
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

Tests require `python3` with either public `packaging` or pip's vendored packaging module available; lint additionally requires `shellcheck` and `shfmt`. `tests/test_release.sh` exercises release guards in isolated temporary repositories.

```bash
./scripts/lint.sh
./scripts/test.sh
```

## Notes / Safety

- This script updates _global_ environments (`npm -g`, `pip`), which can be disruptive.
- Use `--dry-run` first, and consider `--only`/`--skip` to control scope.
- For npm 11+ global installs, `updates` may retry once with npm's suggested one-shot `--allow-scripts=...` list so package postinstall steps can finish without changing persistent npm config.
- Node updates are filtered against the active Node runtime and installed per package. An unexpected incompatible or otherwise failed package does not prevent later compatible packages from being attempted, but still fails the node module.
- Git-backed `shell`/`repos` updates never infer tracking branches or alter local work. Detached HEADs, branches without upstreams, and dirty worktrees warn and skip; diverged histories and failed pulls/post-pull actions fail the module.
- These resilience changes preserve the public v2 CLI and JSONL contracts.
- Since `v2.0.0`, `updates` itself is distributed through GitHub Releases only. No third-party package manager channel is supported.
- Since `v2.0.0`, self-update is fixed to the canonical GitHub repo `amanthanvi/updates`; `UPDATES_SELF_UPDATE_REPO` is removed and setting it is an error.
- Official self-update artifacts for `v2.1.1` are `updates`, `updates-windows.zip`, `updates-release.json`, and `SHA256SUMS`.
- Normal runs throttle GitHub release checks to about once every 24 hours using a small local cache under `XDG_CACHE_HOME`, `~/Library/Caches`, `~/.cache`, or `%LOCALAPPDATA%\\updates`; explicit `--self-update` forces a live check. Cached tags are untrusted hints and never replace live release, digest, checksum, or manifest verification before applying an update.
- Native Windows self-update works only for official standalone installs rooted at `%LOCALAPPDATA%\\Programs\\updates` with a valid `install-source.json` receipt. Manual file copies warn and skip instead of being overwritten.
- On macOS, Homebrew casks are disabled by default; enable with `--brew-mode casks` or `--brew-mode greedy` (or `--full`). On macOS 26+, cask upgrades may be blocked unless your terminal app is allowed under **Privacy & Security → App Management** (e.g. Ghostty). If you see a system notification like “\<Terminal App\> tried modifying your system…”, enable App Management or rerun with `--brew-mode formula`.
- On WSL, updates apply to the Linux distro; native Windows updates require the native Windows entrypoints.
- Output uses ANSI colors when run in a TTY; disable with `--no-color` or `NO_COLOR=1`. When `--log-file` is used, colors are disabled to keep logs clean.
- If Python is externally-managed (PEP 668), Bash runs a guarded user-site upgrade by default: it lists user packages, dry-runs wheel-only plans, skips packages that would add packages absent from the user site, use source distributions, or violate installed requirements, re-checks the safe subset in one combined dry-run, installs only that set, then runs `pip check`. Pip must support `--dry-run --report` for the guarded path; missing support is an error under `--only` and a safe skip otherwise. Remaining `pip check` failures that were already present before install are warned after install instead of failing the guarded run. Guarded pip calls include `--break-system-packages` only when pip supports it. `--pip-force` skips the guard and uses pip's system-protection override (dangerous).

## Contributing

See `CONTRIBUTING.md`.

## License

MIT — see `LICENSE`.

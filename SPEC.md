# updates — Specification (v1.0.0)

This document is the **source of truth** for how the `updates` CLI behaves: flags, output, exit codes, module contracts, configuration, and release invariants.

If anything here disagrees with other docs, update the other docs (or this spec) so they match.

## 0) Metadata

- **Title:** updates v1.0.0 specification
- **Owner (DRI):** Aman Thanvi (@amanthanvi)
- **Status:** Draft
- **Last updated:** 2026-02-07
- **Target ship date:** TBD (0.9.0 deprecation release first, then 1.0.0)
- **Links:** [Repository](https://github.com/amanthanvi/updates)

## 1) Executive Summary

### 1.1 What we're building

A modular Bash CLI that updates common macOS and Linux development tooling (Homebrew, npm, pip, uv, mise, Go binaries, pipx, rustup, Claude Code, shell customization, Mac App Store, and macOS system updates) with a single command.

### 1.2 Problem statement / why now

Developers maintain a growing set of global tools and runtimes that each have their own update workflow. Running 5-10 separate update commands is tedious, easy to forget, and error-prone. `updates` consolidates this into a single, safe-by-default command with dry-run, scoping, and structured output for automation.

v1.0 signals a stable CLI contract: flag names, module names, exit codes, output format, and environment variables are frozen. New flags/modules may be added in minor versions; removing or renaming requires a major version bump.

### 1.3 Success metrics

- **Primary KPIs:**
  - All 13 modules pass lint + stub tests on macOS and Linux (CI matrix).
  - JSONL output is parseable by `jq` for all event types.
  - Config file (`~/.updatesrc`) correctly sets defaults overridden by CLI flags.
- **Guardrails:**
  - No module mutates state in `--dry-run` mode.
  - Self-update never corrupts the installed script (SHA256-verified).
  - `--json` mode produces valid JSONL on stdout with zero human-readable text mixed in.
- **"Done means":**
  - A user can run `updates` on a fresh macOS or Linux machine, have all available modules detected and updated, and pipe `--json` output to a script for CI integration.

### 1.4 Non-goals / out of scope

- Not a general-purpose package manager.
- Not an installer for dependencies (`brew`, `pipx`, `mas`, etc.).
- Not an automatic macOS upgrade tool (the `macos` module lists updates; it does not install them).
- No rich TUI, no interactive prompts (beyond what underlying tools produce).
- No telemetry or phone-home beyond self-update checks.
- No plugin/extension system for user-defined modules (modules are hardcoded).

## 2) Users & UX

### 2.1 Personas

- **Solo developer (primary):** Uses a Mac or Linux workstation with Homebrew, Node, Python, Rust, etc. Wants a single command to keep everything current. Runs manually or via cron.
- **CI/automation user:** Runs `updates --json -n --no-self-update` in a pipeline to produce structured upgrade reports or keep build images current.
- **Polyglot developer:** Uses mise/asdf for runtime management, uv for Python tooling, Go for CLI tools. Wants all of these covered without remembering individual update commands.

### 2.2 Primary flows

- **Flow 1 — Default run:** `updates` (auto-detects available modules, runs safe defaults, prints human-readable progress and summary).
- **Flow 2 — Scoped run:** `updates --only brew,node --dry-run` (preview what would change for specific modules).
- **Flow 3 — Full upgrade:** `updates --full` (includes casks, mas, macos — everything).
- **Flow 4 — CI/scripted:** `updates --json -n --no-self-update --log-level warn` (structured output, non-interactive, quiet).

### 2.3 UX states checklist

- **Loading:** Module boundary line printed (`==> <module> START`); underlying tool output streams through.
- **Empty:** "All packages are up-to-date" message per module when nothing to upgrade.
- **Error:** `ERROR: ...` on stderr; module marked FAIL in summary; exit code 1.
- **Permission denied:** `WARN:` message when self-update lacks write access; module skips gracefully when `sudo` is unavailable.
- **Offline/degraded:** Self-update silently skips on network failure; individual modules fail based on their own tool's behavior.
- **Accessibility:** Plain-text output; emoji disabled with `--no-emoji`; colors disabled with `--no-color` / `NO_COLOR=1`.

## 3) CLI Contract (v1.0 stability guarantee)

The v1.0 contract freezes: flag names, module names, exit codes, output format (boundary lines + summary), environment variables, and JSONL event types. Adding new flags/modules in minor versions is allowed; removing or renaming is a breaking change requiring a major version bump.

### 3.1 Invocation

`updates [options]`

The CLI takes no positional arguments. Unknown options or unexpected arguments **MUST** error with exit code `2`.

### 3.2 Exit codes

| Code | Meaning |
|------|---------|
| `0`  | Success (including modules skipped due to missing deps) |
| `1`  | One or more selected modules failed |
| `2`  | Usage / configuration error (unknown flag, invalid value, unsupported platform, etc.) |
| `130` | Interrupted (SIGINT) |
| `143` | Terminated (SIGTERM) |

### 3.3 Options

Information:

- `-h`, `--help`: print help and exit `0`.
- `--version`: print the SemVer version (e.g. `1.0.0`) and exit `0`.
- `--list-modules`: print the module list and exit `0`.

Execution control:

- `--dry-run`: **MUST NOT** execute mutating commands; prints what would run.
- `--only <list>`: run only the named modules (CSV or quoted space-separated).
- `--skip <list>`: skip the named modules.
- `--strict`: stop on the first module failure.
- `-n`, `--non-interactive`: avoid interactive prompts when possible.

Output:

- `--log-level <level>`: set output verbosity. Levels: `error`, `warn`, `info` (default), `debug`.
  - `error`: only ERROR messages.
  - `warn`: WARN + ERROR messages.
  - `info`: normal progress output (default; equivalent to previous behavior without `--quiet` or `--verbose`).
  - `debug`: all output including commands being run (prefixed with `+`).
- `--json`: emit JSONL events to stdout; human-readable output goes to stderr.
- `--no-emoji`: disable emoji in output.
- `--no-color`: disable ANSI colors.
- `--log-file <path>`: append all output to a log file (colors disabled in file).

Self-update:

- `--self-update` / `--no-self-update`: enable/disable self-update (default enabled).

Configuration:

- `--no-config`: ignore `~/.updatesrc` config file.

Brew:

- `--brew-mode <mode>`: Homebrew upgrade scope. Modes:
  - `formula` (default on macOS): upgrade formulae only.
  - `casks`: upgrade formulae + casks.
  - `greedy`: upgrade formulae + casks (greedy).
- `--brew-cleanup` / `--no-brew-cleanup`: run `brew cleanup` after upgrade (default enabled).

Module presets:

- `--full`: enable the "everything" preset:
  - sets `--brew-mode greedy`
  - enables `--mas-upgrade` and `--macos-updates`
  - runs all other auto-detected modules (including `uv`, `mise`, and `go`; `go` still requires `GO_BINARIES` to be configured)
- `--mas-upgrade` / `--no-mas-upgrade`: enable the `mas` module (default disabled).
- `--macos-updates` / `--no-macos-updates`: enable the `macos` module (default disabled).

Python:

- `--pip-force`: pass `--break-system-packages` to `pip` (unsafe; for PEP 668 environments).
- `--parallel <N>`: parallelism for pip upgrades (default `4`, minimum `1`).

**Deprecated flags (accepted with WARN in 0.9.0; removed in 1.0.0):**

| Old flag | Replacement |
|----------|-------------|
| `--brew-casks` | `--brew-mode greedy` | Matches v0.x default (`--brew-greedy` enabled) |
| `--no-brew-casks` | `--brew-mode formula` | |
| `--brew-greedy` | `--brew-mode greedy` | Only meaningful when casks are enabled |
| `--no-brew-greedy` | `--brew-mode casks` | Keeps casks but disables greedy |
| `-q`, `--quiet` | `--log-level warn` |
| `-v`, `--verbose` | `--log-level debug` |
| `--python-break-system-packages` | `--pip-force` |

If you previously used `--brew-casks --no-brew-greedy`, the equivalent is `--brew-mode casks`.

### 3.4 --brew-mode details

`--brew-mode` replaces the previous `--brew-casks` and `--brew-greedy` boolean flags with a single enum:

| Mode | `brew update` | `brew upgrade` args | Notes |
|------|:---:|---|---|
| `formula` | Yes | `--formula` | Default on macOS. Safe; no app bundle changes. |
| `casks` | Yes | _(no flag — upgrades formulae + casks)_ | Includes cask upgrades. |
| `greedy` | Yes | `--greedy` | Includes greedy cask upgrades. |

On non-macOS platforms, the default is `formula` (casks are irrelevant on Linux).

`--full` sets `--brew-mode greedy` (among other things).

### 3.5 --log-level details

Replaces the previous `--quiet` / `--verbose` boolean flags with a single enum:

| Level | Behavior |
|-------|----------|
| `error` | Only `ERROR:` messages on stderr. Module boundaries and summary suppressed. |
| `warn` | `WARN:` + `ERROR:` messages. Module boundaries and summary still print. |
| `info` | Normal progress output (default). |
| `debug` | All output, including commands prefixed with `+`. |

When `--json` is active, `--log-level` controls the verbosity of human output on stderr. JSONL on stdout always includes all event types regardless of log level.

### 3.6 --pip-force details

Replaces `--python-break-system-packages`. Passes `--break-system-packages` to `pip install` calls. This is dangerous on PEP 668 externally-managed environments and should only be used when the user explicitly wants to override system Python protections.

### 3.7 Module lists (--only, --skip)

Module lists are parsed from a **single argument**:

- CSV is recommended: `--only brew,node`
- Whitespace inside the argument is supported, but must be quoted: `--only "brew node"`

If `--only`/`--skip` includes an unknown module, the CLI **MUST** exit with code `2`.
If `--only` includes a module that is not supported on the current platform, the CLI **MUST** exit with code `2`.

Precedence: `--skip` overrides `--only`.

### 3.8 --json (JSONL streaming output)

When `--json` is passed:

- **stdout** emits one JSON object per line (JSONL). No human-readable text is mixed in.
- **stderr** receives human-readable output (controlled by `--log-level`).
- Each JSON line has an `"event"` field. Event types:

| Event | Fields | Emitted when |
|-------|--------|--------------|
| `module_start` | `event`, `module`, `timestamp` | A module begins execution |
| `module_end` | `event`, `module`, `status` (`ok`\|`skip`\|`fail`), `seconds`, `timestamp` | A module finishes |
| `upgrade` | `event`, `module`, `package`, `from`, `to` | A package upgrade is detected (when parseable) |
| `log` | `event`, `module`, `message`, `timestamp` | A normal log line is emitted |
| `warn` | `event`, `module`, `message`, `timestamp` | A warning is emitted |
| `error` | `event`, `module`, `message`, `timestamp` | An error is emitted |
| `summary` | `event`, `ok`, `skip`, `fail`, `total_seconds`, `failures`, `timestamp` | Run completes |

`timestamp` is ISO 8601 UTC (e.g. `2026-02-07T12:00:00Z`).

Modules that cannot parse upgrade details (e.g., `brew`, `rustup`) emit `module_start`/`module_end` but no `upgrade` events. The `upgrade` event is best-effort for modules where output is parseable (e.g., `node`, `python`, `uv`).

## 4) Configuration File (~/.updatesrc)

### 4.1 Format & precedence

`~/.updatesrc` is an optional, source-able shell file containing `KEY=value` pairs. Lines starting with `#` are comments. Empty lines are ignored.

**Precedence:** config file < CLI flags. CLI flags always win. Environment variables (`UPDATES_*`) are separate and follow existing behavior.

The file is skipped if it does not exist. Pass `--no-config` to ignore it entirely.

### 4.2 Supported keys

| Key | Type | Maps to | Example |
|-----|------|---------|---------|
| `SKIP_MODULES` | CSV | `--skip` | `SKIP_MODULES=python,mas` |
| `BREW_MODE` | enum | `--brew-mode` | `BREW_MODE=greedy` |
| `BREW_CLEANUP` | 0/1 | `--[no-]brew-cleanup` | `BREW_CLEANUP=0` |
| `MAS_UPGRADE` | 0/1 | `--[no-]mas-upgrade` | `MAS_UPGRADE=1` |
| `MACOS_UPDATES` | 0/1 | `--[no-]macos-updates` | `MACOS_UPDATES=1` |
| `LOG_LEVEL` | enum | `--log-level` | `LOG_LEVEL=warn` |
| `PARALLEL` | int | `--parallel` | `PARALLEL=8` |
| `PIP_FORCE` | 0/1 | `--pip-force` | `PIP_FORCE=1` |
| `SELF_UPDATE` | 0/1 | `--[no-]self-update` | `SELF_UPDATE=0` |
| `NO_EMOJI` | 0/1 | `--no-emoji` | `NO_EMOJI=1` |
| `NO_COLOR` | 0/1 | `--no-color` | `NO_COLOR=1` |
| `GO_BINARIES` | CSV (module[@version]) | go module binary list | `GO_BINARIES="golang.org/x/tools/gopls,github.com/go-delve/delve/cmd/dlv"` |

Unknown keys are silently ignored (forward compatibility).

### 4.3 --no-config flag

When passed, `~/.updatesrc` is not read. Useful for CI, testing, and debugging.

## 5) Output & Logging

### 5.1 Human output (boundary lines, summary)

Output is intended to be stable and easy to grep.

- Normal progress goes to **stdout** (or **stderr** when `--json` is active).
- Warnings and errors go to **stderr** and are prefixed:
  - `WARN: ...`
  - `ERROR: ...`
- `--log-level warn` (and below) suppress normal output but **MUST NOT** suppress `WARN:`/`ERROR:` messages.
- Emoji is enabled by default; `--no-emoji` removes emoji.
- ANSI colors are enabled automatically when output is a TTY; set `NO_COLOR=1` or pass `--no-color` to disable. When `--log-file` is used, colors are disabled in the log file.

Standardized boundaries:

- Each selected module prints boundary lines:
  - `==> <module> START`
  - `==> <module> END (<OK|SKIP|FAIL>) (<Ns>)`
- After the run completes, a summary line is printed:
  - `==> SUMMARY ok=<N> skip=<N> fail=<N> total=<Ns> [failures=<csv>]`

### 5.2 JSONL event stream contract

See [Section 3.8](#38---json-jsonl-streaming-output) for the full event type table.

- Every JSONL line is a valid JSON object terminated by `\n`.
- The `event` field is always present and is one of the defined event types.
- Unknown event types **MAY** be added in minor versions; consumers **SHOULD** ignore unknown types.

### 5.3 --log-file behavior

`--log-file <path>` duplicates output to the given file by teeing **both stdout and stderr** and appending (`tee -a`). The log directory is created if missing (`mkdir -p`). Colors are stripped from the log file.

When `--json` is active, the log file receives the human-readable stderr output, not the JSONL stream.

### 5.4 Color / emoji

- ANSI colors are enabled when stderr/stdout are TTYs and `NO_COLOR` is not set.
- `--no-color` or `NO_COLOR=1` disables colors globally.
- `--no-emoji` disables emoji in output.
- `TERM=dumb` disables colors.

## 6) Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `UPDATES_ALLOW_NON_DARWIN=1` | unset | Allow running on unsupported OSes (prints warning) |
| `UPDATES_SELF_UPDATE=0` | `1` | Disable self-update |
| `UPDATES_SELF_UPDATE_REPO=owner/repo` | `amanthanvi/updates` | GitHub repo for self-update releases |
| `NO_COLOR=1` | unset | Disable ANSI colors |
| `CI` | unset | When set, self-update is disabled |

## 7) Module System

### 7.1 Principles

- Each module is a Bash function named `module_<name>()`.
- Modules are run sequentially in a fixed order.
- Some modules are **opt-in** in default runs for safety (`mas`, `macos`).
- On macOS, `--brew-mode` defaults to `formula` (safe).
- Modules are command-driven and auto-detected.

### 7.2 Module list & platform matrix

Execution order: `brew`, `shell`, `linux`, `node`, `python`, `uv`, `mas`, `pipx`, `rustup`, `claude`, `mise`, `go`, `macos`.

| Module   | macOS | Linux | WSL | Notes |
|----------|:-----:|:-----:|:---:|-------|
| `brew`   |  Yes  |  Yes  | Yes | Requires `brew` |
| `shell`  |  Yes  |  Yes  | Yes | Requires `git`; updates Oh My Zsh + custom plugins/themes |
| `linux`  |  No   |  Yes  | Yes | Requires a supported package manager + optional `sudo` |
| `node`   |  Yes  |  Yes  | Yes | Requires `ncu` + `npm` |
| `python` |  Yes  |  Yes  | Yes | Requires `python3 -m pip` |
| `uv`     |  Yes  |  Yes  | Yes | Requires `uv` |
| `mas`    |  Yes  |  No   | No  | Requires `mas` (opt-in) |
| `pipx`   |  Yes  |  Yes  | Yes | Requires `pipx` |
| `rustup` |  Yes  |  Yes  | Yes | Requires `rustup` |
| `claude` |  Yes  |  Yes  | Yes | Requires `claude` |
| `mise`   |  Yes  |  Yes  | Yes | Requires `mise` |
| `go`     |  Yes  |  Yes  | Yes | Requires `go`; binary list from config |
| `macos`  |  Yes  |  No   | No  | Requires `softwareupdate` (opt-in) |

### 7.3 Module execution order

Fixed: `brew` > `shell` > `linux` > `node` > `python` > `uv` > `mas` > `pipx` > `rustup` > `claude` > `mise` > `go` > `macos`.

Rationale: package managers first (brew, linux), then language-specific tools, then opt-in system modules last.

### 7.4 Skip vs failure semantics

Internally:

- Return `0`: success.
- Return `1`: failure.
- Return `2`: skipped (missing dependency in auto-detect mode).

User-visible:

- Skipped modules do not make the overall run fail.
- Failed modules make the run exit `1`.
- With `--strict`, the script stops at the first failure.

## 8) Module Specifications

Each module's contract includes: required commands, what it runs, and side effects.

### 8.1 `brew`

Purpose: update and upgrade Homebrew formulae (and optionally casks).

- Requires: `brew`
- Non-dry-run commands:
  - `brew update`
  - `--brew-mode formula`: `brew upgrade --formula`
  - `--brew-mode casks`: `brew upgrade`
  - `--brew-mode greedy`: `brew upgrade --greedy`
  - If `--brew-cleanup` (default): `brew cleanup`
- Side effects: upgrades Homebrew-managed packages.

### 8.2 `shell`

Purpose: update common shell customization tooling (Oh My Zsh) and its git-backed custom plugins/themes.

- Requires: `git`
- Detection:
  - Oh My Zsh directory: `$ZSH` (if set and exists) or `~/.oh-my-zsh`
  - Custom directory: `$ZSH_CUSTOM` (if set) or `<ZSH>/custom`
  - Plugin/theme repos detected in `<custom>/plugins/*` and `<custom>/themes/*` (directories with `.git`).
- Non-dry-run: `git -C <dir> pull --ff-only` for each detected repo.
- With `-n`: sets `GIT_TERMINAL_PROMPT=0`.
- Side effects: updates repos in-place.

### 8.3 `linux`

Purpose: upgrade Linux system packages using the host distro package manager.

- Runs only on Linux (including WSL).
- Requires one of: `apt-get`, `dnf`, `yum`, `pacman`, `zypper`, `apk`. Requires `sudo` if not root.
- Non-dry-run commands (auto-detected):
  - `apt-get`: `apt-get update` + `apt-get upgrade [-y]` (with `DEBIAN_FRONTEND=noninteractive` when `-n`)
  - `dnf`: `dnf upgrade [-y]`
  - `yum`: `yum update [-y]`
  - `pacman`: `pacman -Syu [--noconfirm]`
  - `zypper`: `zypper refresh [--non-interactive]` + `zypper update [--non-interactive]`
  - `apk`: `apk update` + `apk upgrade`
- Side effects: upgrades OS-managed packages.

### 8.4 `node`

Purpose: upgrade global npm packages using `npm-check-updates`.

- Requires: `ncu`, `npm`, and JSON parsing support (`python3` or `node`).
- Non-dry-run: `ncu -g --jsonUpgraded` to detect upgrades, then `npm install -g -- <name@version>...`.
- Side effects: upgrades global npm packages.

### 8.5 `python`

Purpose: upgrade global Python packages with `pip`.

- Requires: `python3` with a working `pip` module.
- PEP 668 detection: if externally-managed, defaults to `--user` scope.
- `--pip-force`: passes `--break-system-packages` to pip.
- Non-dry-run: `python3 -m pip list --outdated --format=json [--user]`, then `python3 -m pip install -U <pkg>` in parallel batches of `--parallel <N>`.
- With `-n`: adds `--no-input` to pip calls.
- Side effects: upgrades Python packages.

### 8.6 `uv`

Purpose: update the `uv` tool itself and all uv-managed tools.

- Requires: `uv`
- Non-dry-run commands:
  - `uv self update`
  - `uv tool upgrade --all`
- Side effects: updates uv binary and all uv-installed tools.

### 8.7 `mas`

Purpose: upgrade Mac App Store apps.

- Disabled by default (enable with `--mas-upgrade`, `--full`, or `--only mas`).
- Requires: `mas`
- Non-dry-run: `mas upgrade`
- Side effects: upgrades App Store apps.

### 8.8 `pipx`

Purpose: upgrade pipx-managed apps.

- Requires: `pipx`
- Non-dry-run: `pipx upgrade-all`
- Side effects: upgrades pipx-installed tools.

### 8.9 `rustup`

Purpose: update Rust toolchains.

- Requires: `rustup`
- Non-dry-run: `rustup update`
- Side effects: updates installed Rust toolchains/components.

### 8.10 `claude`

Purpose: update the Claude Code CLI.

- Requires: `claude`
- Non-dry-run: `claude update`
- Side effects: updates the Claude Code CLI.

### 8.11 `mise`

Purpose: update mise itself and upgrade all installed tool versions.

- Requires: `mise`
- Non-dry-run commands:
  - `mise self-update`
  - `mise upgrade`
- Side effects: updates mise binary and installed tool versions to latest matching constraints.

### 8.12 `go`

Purpose: update Go binaries from a user-specified list.

- Requires: `go`
- Binary list: read from `GO_BINARIES` in `~/.updatesrc` (CSV of `module` or `module@version` entries).
  - If an entry omits `@version`, it defaults to `@latest` (hands-off).
- Non-dry-run: `go install <module>@<version>` for each entry.
- If `GO_BINARIES` is empty or unset:
  - default runs: skipped (return `2`)
  - `--only go`: error (return `1`)
- Side effects: rebuilds and installs Go binaries to `$GOBIN` or `$GOPATH/bin`.

### 8.13 `macos`

Purpose: list available macOS software updates.

- Disabled by default (enable with `--macos-updates`, `--full`, or `--only macos`).
- Requires: `softwareupdate`
- Non-dry-run: `softwareupdate -l`
- Side effects: lists updates only (does not install).

## 9) Self-Update

- When enabled, `updates` checks GitHub Releases for `UPDATES_SELF_UPDATE_REPO` (default `amanthanvi/updates`).
- If the latest release tag is newer than `UPDATES_VERSION`, it downloads the `updates` release artifact and verifies it against `SHA256SUMS`.
- Verification: HTTPS transport + SHA256 checksum. No GPG/cosign signatures (sufficient for v1.0).
- If install succeeds, it replaces the current script and re-execs itself once (guarded by `UPDATES_SELF_UPDATED=1`).
- Self-update is skipped when:
  - `--no-self-update` or `UPDATES_SELF_UPDATE=0`
  - `--dry-run` mode
  - `CI` environment variable is set
  - Running from a git checkout (development)
  - Installed as a symlink
- If the install path is not writable, self-update attempts `sudo install` (with `sudo -n` when `-n` is set).

## 10) Security & Privacy

- **Secrets:** No secrets are stored or required. Self-update uses unauthenticated GitHub API calls.
- **Supply chain:** Self-update verifies SHA256 checksums from the same GitHub Release. The script validates that the downloaded file contains `UPDATES_VERSION=` before replacing itself.
- **PII:** No user data is collected or transmitted.
- **Abuse cases:**
  - Malicious GitHub release: mitigated by SHA256 verification + HTTPS.
  - pip parallel upgrades: stderr interleaving is cosmetic, not a security issue.
  - `--pip-force` is explicitly opt-in and documented as unsafe.
- **Privilege escalation:** `sudo` is only used for Linux system package upgrades and self-update to non-writable paths. With `-n`, `sudo -n` is used (no password prompt).

## 11) Reliability & Failure Modes

### 11.1 Failure modes table

| Failure | Detection | User impact | System behavior | Recovery | Blast radius |
|---------|-----------|-------------|-----------------|----------|--------------|
| Module dep missing (auto) | `command -v` check | Module skipped | Return `2`, continue | None needed | Single module |
| Module dep missing (`--only`) | `command -v` check | Error message | Return `1`, module fails | Install the dep | Single module |
| Module command fails | Non-zero exit | Module marked FAIL | Continue (or stop if `--strict`) | Re-run or fix manually | Single module |
| Self-update download fails | `curl` non-zero | Warning printed | Continues without update | Re-run later | None |
| Self-update checksum mismatch | SHA256 compare | Warning printed | Continues without update | Report issue | None |
| Network unreachable | Tool-specific timeout | Module fails | Continue | Fix network, re-run | Affected modules |
| Config file parse error | Source fails | Warning printed | Continues with defaults | Fix `~/.updatesrc` | All config values |
| Disk full | Write fails | Module fails | Continue | Free space | Affected module |
| SIGINT received | Trap handler | Interrupted message | Exit `130` | Re-run | Current module may be partial |

### 11.2 Retries/timeouts

- Self-update: `curl` connect timeout 2s, max time 5s (API) / 20s (download). No retries.
- Module commands: no retries. Modules run the underlying tool once; if it fails, the module fails.
- No circuit breakers (modules are independent and run sequentially).

## 12) Observability

- **Logging:** `--log-level` controls verbosity (error/warn/info/debug). `--log-file` persists output.
- **What not to log:** No PII, no environment variable values, no file contents.
- **Metrics:** JSONL events include per-module timing (`seconds` field) and overall `total_seconds`.
- **Alerts:** Not applicable (CLI tool, not a service). Users can parse JSONL `summary` events for CI alerting.
- **Debugging:**
  - `--log-level debug` prints every command before execution.
  - `--json` provides structured events for programmatic analysis.
  - Self-update logs detailed skip reasons at debug level.

## 13) Rollout, Migration, Compatibility

### 13.1 v0.9.0 deprecation release

Ship all v1.0 features (config file, `--json`, new modules, `--brew-mode`, `--log-level`, `--pip-force`, `-n`) with:

- Old flags still accepted.
- Each use of a deprecated flag prints `WARN: --<old-flag> is deprecated; use <new-flag> instead`.
- No behavior change — deprecated flags map to their replacements internally.

### 13.2 v1.0.0 stable release

- Remove all deprecated flags. Using them produces `ERROR:` and exit code `2`.
- CLI contract is frozen.

### 13.3 Flag migration table

| v0.x flag | v1.0 replacement | Notes |
|-----------|------------------|-------|
| `--brew-casks` | `--brew-mode greedy` | Matches v0.x default (`--brew-greedy` enabled) |
| `--no-brew-casks` | `--brew-mode formula` | |
| `--brew-greedy` | `--brew-mode greedy` | |
| `--no-brew-greedy` | `--brew-mode casks` | Disables greedy but keeps casks |
| `-q`, `--quiet` | `--log-level warn` | |
| `-v`, `--verbose` | `--log-level debug` | |
| `--python-break-system-packages` | `--pip-force` | |

## 14) Development & QA

### 14.1 Lint / test commands

- Lint: `./scripts/lint.sh` (runs `bash -n`, `shellcheck`, `shfmt -d`).
- Tests: `./scripts/test.sh` (runs `./tests/test_cli.sh`).
- Tests use temporary `PATH` stubs to avoid modifying the developer's machine.

### 14.2 Test plan

- **Unit/integration (stub-based):**
  - Existing tests for brew, node, python, linux, shell, mas, macos, self-update.
  - New stubs for: uv, mise, go modules.
  - Config file parsing tests (precedence, unknown keys, `--no-config`).
  - `--brew-mode` enum validation tests.
  - `--log-level` output filtering tests.
  - `--json` JSONL output validation (parse each line as JSON in tests).
  - Deprecated flags error tests (1.0.0).
- **Edge cases:**
  - `GO_BINARIES` empty/unset (go module skips).
  - `--json` + `--log-file` interaction.
  - `--only` with new module names.
- **Not in scope for v1.0 test suite:**
  - Real-tool integration tests (would require installing all tools).
  - Linux CI matrix (nice-to-have; not blocking).
  - Signal handling tests (hard to make deterministic).

### 14.3 Acceptance criteria (Given/When/Then)

1. **Given** a macOS machine with brew, node, python, uv, mise, go, pipx, rustup, claude installed, **when** `updates` runs, **then** all detected modules execute successfully and summary shows `fail=0`.
2. **Given** `--dry-run`, **when** any module runs, **then** no mutating commands are executed.
3. **Given** `--json`, **when** `updates` runs, **then** stdout contains only valid JSONL and stderr contains human output.
4. **Given** `~/.updatesrc` with `SKIP_MODULES=python` and CLI flag `--only python`, **then** CLI flag wins and python module runs.
5. **Given** `--brew-mode greedy`, **when** brew module runs, **then** `brew upgrade --greedy` is called.
6. **Given** `GO_BINARIES="golang.org/x/tools/gopls"` in config, **when** go module runs, **then** `go install golang.org/x/tools/gopls@latest` is called.
7. **Given** a deprecated flag (e.g., `--verbose`) in 0.9.0, **when** used, **then** a `WARN:` deprecation message is printed and the flag maps to `--log-level debug`.
8. **Given** a deprecated flag in 1.0.0, **when** used, **then** `ERROR:` is printed and exit code is `2`.

## 15) Releases

Versioning:

- SemVer, tagged as `vX.Y.Z`.
- Script version is `UPDATES_VERSION="<version>"` inside `updates`.

Invariants (enforced in CI/release):

- Tag version `vX.Y.Z` **MUST** match `UPDATES_VERSION="X.Y.Z"`.
- `CHANGELOG.md` **MUST** contain a header `## [X.Y.Z]` for the release.

Maintainer workflow:

- `./scripts/release.sh X.Y.Z` (validates invariants, runs lint/tests, creates annotated tag).
- Push `main` and tags; GitHub Actions builds and publishes release artifacts.

## 16) Decision Log

| Date | Decision | Alternatives | Rationale | Consequences |
|------|----------|--------------|-----------|--------------|
| 2026-02-07 | Full CLI surface frozen at 1.0 | Partial freeze (flags only) | Users need confidence the contract is stable | Must bump major version for any removal/rename |
| 2026-02-07 | `--brew-mode` enum replaces 3 booleans | Keep booleans, add short aliases | Single flag is clearer; reduces flag sprawl | Breaking change; needs 0.9.0 deprecation period |
| 2026-02-07 | `--log-level` replaces `--quiet`/`--verbose` | Keep both pairs | More granular; standard pattern | Breaking change |
| 2026-02-07 | `--pip-force` replaces `--python-break-system-packages` | Keep long name | Too verbose; confusing for users | Breaking change |
| 2026-02-07 | `-n` = `--non-interactive` | `-n` = `--dry-run` (make convention) | Matches apt/apt-get convention | `--dry-run` has no short alias |
| 2026-02-07 | JSONL to stdout, human to stderr | JSON replaces human; JSON to file | Allows piping + visual progress simultaneously | `--log-file` captures stderr (human) only |
| 2026-02-07 | Full JSONL event stream (start/log/upgrade/warn/error/end/summary) | Summary-only JSON | Maximum fidelity for automation | More complex to implement; verbose output |
| 2026-02-07 | `~/.updatesrc` as source-able env file | TOML, XDG config dir | No parser needed; simple for Bash | No structured nesting; flat keys only |
| 2026-02-07 | Config < flags (flags always win) | Config < env < flags | Simpler model; env vars are separate concern | Users can't override config via env (use flags) |
| 2026-02-07 | New modules: uv, mise, go | Also docker | Docker pulls are slow/large; poor fit for quick update tool | Can add docker in a minor if demand exists |
| 2026-02-07 | Go module reads module list from config | Auto-detect from binaries | Can't reliably infer module path from binary name | Requires user to maintain GO_BINARIES list (module paths; versions default to `@latest`) |
| 2026-02-07 | uv: self update + tool upgrade --all | Tool upgrade only | uv's self-update is fast and safe | Touches uv's own binary |
| 2026-02-07 | mise: self-update + upgrade | Also plugins upgrade | Keeps scope minimal; plugins update implicitly | Users with stale plugins must update manually |
| 2026-02-07 | `--full` runs uv/mise/go too | Keep `--full` system-only | "One command" should mean everything possible | `go` still needs `GO_BINARIES` configured |
| 2026-02-07 | SHA256 sufficient for self-update (no cosign/GPG) | Add cosign verification | Adds complexity + dependency; HTTPS+SHA256 is pragmatic | Weaker supply-chain guarantee |
| 2026-02-07 | 0.9.0 deprecation release, then 1.0.0 | Direct to 1.0; incremental 0.9.x | Gives users a migration window for renamed flags | Two releases to manage |
| 2026-02-07 | Test bar: current level + new module stubs | Full split suite + Linux CI | Practical for a single-maintainer project | No Linux CI; limited edge-case coverage |

## 17) Assumptions, Open Questions, Risks

### Assumptions

- Users install and manage dependencies (brew, ncu, uv, mise, etc.) themselves.
- Bash `/bin/bash` is available on all target platforms (macOS system Bash is 3.2; features used are compatible).
- GitHub Releases remain available and free for self-update checks.
- `uv self update` and `mise self-update` remain stable subcommands.

### Open questions

- None (current behavior: in `--json` mode, `--log-file` captures the human stderr stream; JSONL remains on stdout).

### Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Bash 3.2 compatibility issues with new features (JSONL, config parsing) | Medium | High | Test on macOS system Bash explicitly |
| `uv self update` or `mise self-update` changes behavior | Low | Medium | Pin to known-good behavior; skip gracefully on failure |
| JSONL format changes needed post-1.0 | Low | High | Design events to be additive; consumers ignore unknown fields |
| Go module is low-value (few users maintain GO_BINARIES list) | Medium | Low | Module is opt-in by nature; low maintenance cost |
| Flag migration breaks existing user scripts | Medium | Medium | 0.9.0 deprecation warnings give a migration window |

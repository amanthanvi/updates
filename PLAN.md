# Release preparation: v2.2.0

- [x] Include merged project/global skill support, the Windows project-directory fix, and Unix cancellation/progress improvements.
- [x] Align Unix/Windows versions, installer defaults, self-update test fixtures, README, SPEC, and the dated changelog for v2.2.0.
- Release gates: `./scripts/release.sh 2.2.0`, green cross-platform CI, and the existing GitHub release workflow's artifact and attestation verification.

---

# Plan: macOS stalls and visible update progress

## Goal

- Make Unix updates cancellable and expose the active phase without automatic installation timeouts or changes to public flags and JSONL events.

## Live diagnosis

- Reproduced the apparent stall after Homebrew 6.0.22's upgrade table: its default ask mode was waiting for confirmation, rather than a frozen command.
- The initial diagnostic run updated Homebrew itself, shell repositories, and one npm package. The first Ctrl+C failed the brew module but allowed later modules to run; the second stopped the run at npm preflight. The identified pause is covered by isolated Homebrew prompt regressions; no additional live upgrade is needed for validation.

## Execution checklist

- [x] Introduce Bash 3.2-compatible managed execution/capture helpers with interruptible waits, owned-child cleanup, preserved stdin, and accurate exit statuses.
- [x] Announce slow phases and emit elapsed human progress every 30 seconds at info/debug log levels, routing human output to stderr with JSON.
- [x] Stream npm stderr and guarded pip installation diagnostics; report parallel pip completion with separate package logs.
- [x] Disable background pip prompts and discovery/planning prompts under `-n`.
- [x] Scope `HOMEBREW_NO_ASK=1` to brew commands under `-n`; preserve interactive confirmation with a clear hint.
- [x] Document cancellation, progress, and diagnostics in README, SPEC, and CHANGELOG without a release/version bump.
- [x] Verify synchronized SIGINT/SIGTERM cleanup for commands, captures, npm preflights, and parallel pip workers, plus interactive stdin under a pseudo-terminal.
- [x] Verify live diagnostics, failure propagation, JSONL purity with logging, and existing npm/Python safety behavior.
- [x] Run lint and full tests on macOS Bash 3.2 and shared-runner coverage on Linux; use isolated homes and stub commands for installed-copy checks.
- [x] Reproduce the table pause in a real update run and identify Homebrew confirmation as the cause.
- [x] Validate Homebrew non-interactive environment scoping and interactive prompt behavior.

---

# Plan: skills module updates

## Goal

- Add a `skills` module that updates agent skills in both project and global scopes by default, matching `npx skills update`'s interactive "Both" option without prompting.

## Execution checklist

- [x] Register a default-on `skills` module between `pi` and `mise` on Bash and native Windows.
- [x] Resolve the backing command as the `skills` CLI first, then `npx --yes skills`; skip gracefully when neither exists and fail under `--only`.
- [x] Run `skills update --project --global`, appending `--yes` under `--non-interactive`; dry-run prints the resolved command without executing.
- [x] Cover direct, npx-fallback, non-interactive, dry-run, and missing-dependency behavior in Bash tests; mirror success, fallback, and missing-dependency coverage in native Windows tests.
- [x] Preserve the caller's project directory on native Windows and cover project paths containing spaces on both platforms.
- [x] Update README, SPEC (module matrix, execution order, §8.15), CHANGELOG, and this plan.
- [x] Pass lint and full local tests; record native Windows validation availability.

Validation: `./scripts/lint.sh`, `./scripts/test.sh`, and the focused skills tests under `/bin/bash` passed on macOS. An isolated PowerShell handler check reproduced the wrong working directory before the fix and passed for direct/npx adapters afterward. Native Windows execution remains unverified on this host; all skill update commands were stubbed.

---

# Plan: v2.1.3 fnm and complete pi updates

## Goal

- Keep global Node updates on the intended fnm runtime and make the pi module cover both the CLI and installed extensions.

## Execution checklist

- [x] Prefer fnm initialization from PATH, `$FNM_DIR`, or the standard Linux install path.
- [x] Preserve NVM as the fallback manager.
- [x] Run `pi update --all` on Bash and native Windows.
- [x] Add manager-precedence and exact-command regression coverage.
- [x] Pass lint and Bash tests; native-Windows tests unavailable on this Linux host.
- [x] Release `v2.1.3` from a clean, reviewed, green commit.

---

# Plan: v2.1.2 authoritative Node engine validation

## Goal

- Close the npm-check-updates `--enginesNode` acceptance gap without changing the public v2 CLI/JSONL contract or adding runtime dependencies.

## Execution checklist

- [x] Reproduce npm-check-updates returning `npm@12.0.1` under incompatible NVM Node `v24.13.0`.
- [x] Confirm npm's engine-strict dry-run rejects the same candidate.
- [x] Preflight each planned candidate before its mutating install on Bash and native Windows.
- [x] Warn and skip only on `EBADENGINE`; preserve the real-install path for inconclusive preflight failures.
- [x] Retain resolution flags, exclude engine overrides from preflight, and preserve all configured flags for the real install.
- [x] Cover warning/skip, later-package continuation, real-install `EBADENGINE`, configured flags, and JSONL purity.
- [x] Complete clean bot reviews and squash-merge the hotfix.
- [x] Release `v2.1.2` from a clean, reviewed, green commit.

---

# Plan: v2.1.1 Node and Git resilience

## Goal

- Prevent persistent runtime-incompatible npm upgrades and unsafe Git pulls without changing the public v2 CLI or JSONL contracts.

## Execution checklist

- [x] Require npm-check-updates `--enginesNode` support and fall back from incapable direct adapters to `npx`.
- [x] Skip by default or fail under `--only node` when no engine-aware updater exists.
- [x] Install npm globals per package and normalize peer, install-script, incompatible-engine, and fatal outcomes.
- [x] Preserve existing bounded peer/install-script retries; do not retry engine, network, auth, or permission failures.
- [x] Share Git preflight and result aggregation across `shell` and `repos`.
- [x] Warn and skip detached, missing-upstream, and dirty repos without mutating branch state.
- [x] Fail diverged histories, pull failures, and post-pull action failures while continuing other repos.
- [x] Add Bash real-repository coverage and native Windows Node parity fixtures.
- [x] Keep flags, config keys, exit codes, JSONL event types, summaries, and runtime dependencies unchanged.
- [x] Update README and SPEC contracts.
- [x] Release `v2.1.1` only from a clean, reviewed, green commit.

---

# Plan: v2.1.0

## Goal

Ship a safer, diagnosable `updates` release while preserving the v2 CLI contract and dependency-free distribution model.

## Execution checklist

### Safety characterization

- [x] Add selectable Bash test cases without changing the default full-suite invocation.
- [x] Synchronize SIGINT/SIGTERM tests and verify active-child termination with exit `130`/`143`.
- [x] Centralize release invariants and cover unsafe paths, dirty trees, existing tags, verification failure, and annotated-tag creation.
- [x] Add Windows failure injection at every install/self-update commit boundary.

### Windows install and self-update

- [x] Authenticate network release metadata and assets before extraction.
- [x] Add optional `-SourceZipSha256`; warn when a local ZIP is accepted without it.
- [x] Stage and validate complete version directories before atomically committing bootstrap, receipt, and pointers.
- [x] Keep the previously runnable payload active through every interrupted or failed upgrade state.

### Cross-platform doctor

- [x] Add local-only, read-only `--doctor` with stable human checks.
- [x] Add JSONL `doctor_check` and `doctor_summary` events with stdout purity.
- [x] Return `0` for healthy/warnings, `1` for failed checks, and `2` for usage/configuration errors.
- [x] Cover healthy, warning, failure, offline, JSONL, exit-code, and no-mutation behavior on Bash and Windows.

### Windows parity and simplification

- [x] Add default-on native Windows `claude` and `pi` modules.
- [x] Route all Windows module metadata, selection, and invocation through one registry.
- [x] Investigate `mise` ownership behavior; defer unless one safe command sequence covers supported installs.
- [x] Preserve the dependency-free Bash self-update parser fallback and independently distributed containment helpers.

### Documentation and release

- [x] Add the v2.1 glossary and `--doctor` ADR.
- [x] Align README, SPEC, help, platform matrix, and changelog with final implemented behavior.
- [x] Pass Bash lint/tests, native Windows tests, release build, and distribution verification.
- [x] Release `v2.1.0` only from a clean, reviewed, green commit.

## Locked boundaries

- No new runtime dependencies, plugin system, telemetry, automatic repair, or networked doctor checks.
- Bash remains a Bash 3.2-compatible single-file distribution.
- PowerShell 7 remains the native Windows runtime and GitHub Releases remain the sole official channel.
- Existing v2 flags, config keys, module names, exit codes, and layout paths remain compatible.

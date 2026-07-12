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
- [ ] Release `v2.1.0` only from a clean, reviewed, green commit.

## Locked boundaries

- No new runtime dependencies, plugin system, telemetry, automatic repair, or networked doctor checks.
- Bash remains a Bash 3.2-compatible single-file distribution.
- PowerShell 7 remains the native Windows runtime and GitHub Releases remain the sole official channel.
- Existing v2 flags, config keys, module names, exit codes, and layout paths remain compatible.

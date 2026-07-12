# ADR 0001: Local, read-only doctor

- Status: Accepted
- Date: 2026-07-12

## Context

Install, pointer, receipt, cache, and command-resolution failures can currently require manual diagnosis. Automatic repair would mutate user state and network probing would make diagnosis depend on external availability.

## Decision

Expose one cross-platform `--doctor` information mode. It performs only local reads, never contacts the network, and never repairs state. Human output uses stable per-check lines and a summary. JSON mode emits `doctor_check` and `doctor_summary` JSONL events while preserving stdout purity.

Warnings do not fail the command. Failed integrity checks return `1`; usage or configuration errors return `2`. Recovery text points to existing reinstall or self-update commands.

## Consequences

- Diagnosis remains deterministic, offline-capable, and safe to run in automation.
- Bash and Windows share the public interface while platform-specific checks remain independent.
- Repair remains an explicit user action; a future repair command requires a separate decision.

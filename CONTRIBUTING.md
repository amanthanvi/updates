# Contributing

Thanks for considering a contribution!

For the canonical CLI/module contract (flags, exit codes, module behavior), see `SPEC.md`.

## Quick start

```bash
./scripts/lint.sh
./scripts/test.sh
```

## Guidelines

- Keep changes small and focused.
- Prefer adding new functionality as a new module function in `updates` (`module_<name>()`) instead of ad-hoc commands.
- If you change user-visible behavior (flags, output, module semantics), update `SPEC.md` and `README.md` accordingly.
- Modules should be:
  - auto-detected (skip if the backing command isn’t installed), and
  - runnable via `--only <module>` (where missing dependencies become an error).
- Keep output stable; tests typically run with `--no-emoji`.

## Commit messages

This repo uses Conventional Commits:

- `feat: ...` (new functionality)
- `fix: ...` (bug fixes)
- `docs: ...` (documentation only)
- `chore(ci): ...` (CI/workflow changes)

## Release process (maintainers)

1. Update `CHANGELOG.md` for the release.
2. Bump `UPDATES_VERSION` in `updates` to the release version.
3. Run `./scripts/lint.sh` and `./scripts/test.sh`.
4. Tag and push (manual), or use `./scripts/release.sh X.Y.Z`:
   - `git tag -a vX.Y.Z -m "vX.Y.Z"`
   - `git push origin main --tags`
5. GitHub Actions publishes the release assets.

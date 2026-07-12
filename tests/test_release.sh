#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
set -euo pipefail

# Release fixtures must not inherit signing, hooks, aliases, or other host Git
# policy. Each fixture supplies its own repository-local author identity below.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
pass() {
	PASS=$((PASS + 1))
	printf 'ok - %s\n' "$1"
}
fail() {
	FAIL=$((FAIL + 1))
	printf 'not ok - %s\n' "$1" >&2
}
expect_failure() {
	local name="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		fail "$name"
	else
		pass "$name"
	fi
}
expect_success() {
	local name="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		pass "$name"
	else
		fail "$name"
	fi
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/updates-release-tests.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
fixture="$TMP_ROOT/invariants"
mkdir -p "$fixture"
cp "$ROOT/scripts/release-lib.sh" "$fixture/release-lib.sh"
printf 'UPDATES_VERSION="9.8.7"\n' >"$fixture/updates"
printf '$script:UpdatesVersion = '\''9.8.7'\''\n' >"$fixture/updates-main.ps1"
printf '# Changelog\n\n## [9.8.7]\n' >"$fixture/CHANGELOG.md"

validate_fixture() {
	(
		cd "$fixture"
		# shellcheck source=/dev/null
		source ./release-lib.sh
		release_validate_invariants "$@"
	)
}

expect_success "shared validator accepts aligned inputs" validate_fixture 9.8.7 v9.8.7
expect_failure "shared validator rejects malformed version" validate_fixture 9.8 v9.8
expect_failure "shared validator rejects mismatched tag" validate_fixture 9.8.7 v9.8.6
printf 'UPDATES_VERSION="9.8.6"\n' >"$fixture/updates"
expect_failure "shared validator rejects Unix mismatch" validate_fixture 9.8.7 v9.8.7
printf 'UPDATES_VERSION="9.8.7"\n' >"$fixture/updates"
printf '$script:UpdatesVersion = '\''9.8.6'\''\n' >"$fixture/updates-main.ps1"
expect_failure "shared validator rejects Windows mismatch" validate_fixture 9.8.7 v9.8.7
printf '$script:UpdatesVersion = '\''9.8.7'\''\n' >"$fixture/updates-main.ps1"
printf '# Changelog\n' >"$fixture/CHANGELOG.md"
expect_failure "shared validator rejects missing changelog entry" validate_fixture 9.8.7 v9.8.7
printf '# Changelog\n\n## [9.8.7]\n' >"$fixture/CHANGELOG.md"
printf 'UPDATES_VERSION="9.8.7"\nUPDATES_VERSION="9.8.6"\n' >"$fixture/updates"
expect_failure "shared validator rejects duplicate Unix version assignments" validate_fixture 9.8.7 v9.8.7
printf 'UPDATES_VERSION="9.8.7"\n' >"$fixture/updates"
printf '$script:UpdatesVersion = '\''9.8.7'\''\n$script:UpdatesVersion = Get-Version\n' >"$fixture/updates-main.ps1"
expect_failure "shared validator rejects Windows version reassignment" validate_fixture 9.8.7 v9.8.7
printf '$script:UpdatesVersion = '\''9.8.7'\''\n' >"$fixture/updates-main.ps1"

validate_output() {
	(
		# shellcheck source=/dev/null
		source "$ROOT/scripts/release-lib.sh"
		release_validate_output_dir "$1" "$2"
	)
}
expect_failure "output guard rejects repository root" validate_output . "$ROOT"
expect_failure "output guard rejects parent traversal" validate_output ../dist "$ROOT/../dist"
expect_failure "output guard rejects filesystem root" validate_output / /

make_release_repo() {
	local repo="$1" script=""
	mkdir -p "$repo/scripts" "$repo/tests"
	cp "$ROOT/scripts/release.sh" "$repo/scripts/release.sh"
	cp "$ROOT/scripts/release-lib.sh" "$repo/scripts/release-lib.sh"
	printf 'UPDATES_VERSION="9.8.7"\n' >"$repo/updates"
	printf '$script:UpdatesVersion = '\''9.8.7'\''\n' >"$repo/updates-main.ps1"
	printf '# Changelog\n\n## [9.8.7]\n' >"$repo/CHANGELOG.md"
	for script in lint test release-build release-verify-dist; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/scripts/$script.sh"
		chmod +x "$repo/scripts/$script.sh"
	done
	printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/tests/test_release.sh"
	chmod +x "$repo/tests/test_release.sh"
	GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$repo" init -q
	GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$repo" config user.name test
	GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$repo" config user.email test@example.com
	GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$repo" add .
	GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$repo" commit -qm initial
}

repo="$TMP_ROOT/release-repo"
make_release_repo "$repo"
expect_success "release orchestration creates a tag" bash "$repo/scripts/release.sh" 9.8.7
if git -C "$repo" cat-file -t v9.8.7 2>/dev/null | grep -qx tag; then
	pass "release tag is annotated"
else
	fail "release tag is annotated"
fi
expect_failure "release orchestration rejects existing tag" bash "$repo/scripts/release.sh" 9.8.7

dirty_repo="$TMP_ROOT/dirty-repo"
make_release_repo "$dirty_repo"
printf 'dirty\n' >>"$dirty_repo/CHANGELOG.md"
expect_failure "release orchestration rejects dirty tree" bash "$dirty_repo/scripts/release.sh" 9.8.7

verify_repo="$TMP_ROOT/verify-repo"
make_release_repo "$verify_repo"
printf '#!/usr/bin/env bash\nexit 1\n' >"$verify_repo/scripts/release-verify-dist.sh"
chmod +x "$verify_repo/scripts/release-verify-dist.sh"
git -C "$verify_repo" add scripts/release-verify-dist.sh
git -C "$verify_repo" commit -qm verifier
expect_failure "release orchestration stops on verification failure" bash "$verify_repo/scripts/release.sh" 9.8.7
if git -C "$verify_repo" rev-parse -q --verify refs/tags/v9.8.7 >/dev/null; then
	fail "verification failure leaves no tag"
else
	pass "verification failure leaves no tag"
fi

printf 'release tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

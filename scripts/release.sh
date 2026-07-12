#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=scripts/release-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/release-lib.sh"

release_cd_root

if [ "${1:-}" = "" ]; then
	echo "Usage: scripts/release.sh X.Y.Z" >&2
	exit 2
fi

VERSION="$(release_normalize_version "$1")"
TAG="$(release_tag_for_version "$VERSION")"

release_validate_invariants "$VERSION" "$TAG"

if [ -n "$(git status --porcelain=v1)" ]; then
	echo "Working tree must be clean" >&2
	exit 2
fi

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
	echo "Tag already exists locally: $TAG" >&2
	exit 2
fi

./scripts/lint.sh
./scripts/test.sh
bash ./scripts/release-build.sh "$VERSION"
bash ./scripts/release-verify-dist.sh "$VERSION"

git tag -a "$TAG" -m "$TAG"
echo "Created tag: $TAG"
echo "Built release artifacts: dist/updates dist/updates-windows.zip dist/updates-release.json dist/SHA256SUMS"
echo "Next: git push origin main --tags"

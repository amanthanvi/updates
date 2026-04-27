#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ "${1:-}" = "" ]; then
	echo "Usage: scripts/release.sh X.Y.Z" >&2
	exit 2
fi

VERSION="$1"
TAG="v${VERSION}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "Version must be SemVer: X.Y.Z" >&2
	exit 2
fi

if [ -n "$(git status --porcelain=v1)" ]; then
	echo "Working tree must be clean" >&2
	exit 2
fi

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
	echo "Tag already exists locally: $TAG" >&2
	exit 2
fi

SCRIPT_VERSION="$(awk -F'"' '/^UPDATES_VERSION=/{print $2; exit}' updates)"
if [ "$SCRIPT_VERSION" != "$VERSION" ]; then
	echo "UPDATES_VERSION (${SCRIPT_VERSION}) does not match requested version (${VERSION})" >&2
	exit 2
fi

if ! grep -q "^## \\[$VERSION\\]" CHANGELOG.md; then
	echo "CHANGELOG.md missing entry for version $VERSION" >&2
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

#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=scripts/release-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/release-lib.sh"

release_cd_root

if [ "${1:-}" = "" ] || [ "${2:-}" = "" ]; then
	echo "Usage: scripts/release-verify-github.sh draft|published X.Y.Z|vX.Y.Z [dist-dir]" >&2
	exit 2
fi

MODE="$1"
VERSION="$(release_normalize_version "$2")"
TAG="$(release_tag_for_version "$VERSION")"
DIST_DIR="${3:-dist}"
REPO="${GITHUB_REPOSITORY:-$RELEASE_CANONICAL_REPO}"

case "$MODE" in
draft | published) ;;
*)
	echo "Mode must be draft or published" >&2
	exit 2
	;;
esac

release_validate_version "$VERSION"
release_require_command gh
release_require_command jq

RELEASE_JSON="$(gh api "repos/$REPO/releases/tags/$TAG")"
DRAFT_STATE="$(printf '%s' "$RELEASE_JSON" | jq -r '.draft')"
PRERELEASE_STATE="$(printf '%s' "$RELEASE_JSON" | jq -r '.prerelease')"
IMMUTABLE_STATE="$(printf '%s' "$RELEASE_JSON" | jq -r '.immutable')"

if [ "$MODE" = "draft" ] && [ "$DRAFT_STATE" != "true" ]; then
	release_fail "Release $TAG is not a draft"
fi
if [ "$MODE" = "published" ] && [ "$DRAFT_STATE" != "false" ]; then
	release_fail "Release $TAG is still a draft"
fi
if [ "$PRERELEASE_STATE" != "false" ]; then
	release_fail "Release $TAG must not be a prerelease"
fi
if [ "$MODE" = "published" ] && [ "$IMMUTABLE_STATE" != "true" ]; then
	release_fail "Release $TAG is not immutable after publish"
fi

EXPECTED_ASSETS="$(release_expected_assets)"
ACTUAL_ASSETS="$(printf '%s' "$RELEASE_JSON" | jq -r '.assets[].name' | sort)"
if [ "$ACTUAL_ASSETS" != "$EXPECTED_ASSETS" ]; then
	echo "Unexpected GitHub release assets for $TAG" >&2
	echo "Expected:" >&2
	printf '%s\n' "$EXPECTED_ASSETS" >&2
	echo "Actual:" >&2
	printf '%s\n' "$ACTUAL_ASSETS" >&2
	exit 1
fi

while IFS= read -r asset; do
	local_digest="sha256:$(release_sha256 "$DIST_DIR/$asset")"
	remote_digest="$(
		printf '%s' "$RELEASE_JSON" |
			jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest'
	)"
	if [ -z "$remote_digest" ] || [ "$remote_digest" = "null" ]; then
		release_fail "GitHub release asset $asset missing digest"
	fi
	if [ "$remote_digest" != "$local_digest" ]; then
		release_fail "Digest mismatch for $asset: expected $local_digest, got $remote_digest"
	fi
done <<EOF
$(release_expected_assets)
EOF

if [ "$MODE" = "draft" ]; then
	echo "Verified uploaded draft release assets for $TAG" >&2
	exit 0
fi

TMP_DIR="$(release_make_tmpdir)"
trap 'rm -rf "$TMP_DIR"' EXIT

gh release download "$TAG" --repo "$REPO" --dir "$TMP_DIR"
bash "$RELEASE_REPO_ROOT/scripts/release-verify-dist.sh" "$VERSION" "$TMP_DIR"

gh release verify "$TAG" --repo "$REPO" >/dev/null
while IFS= read -r asset; do
	gh release verify-asset "$TAG" "$DIST_DIR/$asset" --repo "$REPO" >/dev/null
done <<EOF
$(release_expected_assets)
EOF

echo "Verified published release $TAG" >&2

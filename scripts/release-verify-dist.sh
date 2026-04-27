#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=scripts/release-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/release-lib.sh"

release_cd_root

if [ "${1:-}" = "" ]; then
	echo "Usage: scripts/release-verify-dist.sh X.Y.Z|vX.Y.Z [dist-dir]" >&2
	exit 2
fi

VERSION="$(release_normalize_version "$1")"
DIST_DIR="${2:-dist}"
EXPECTED_VERSION_OUTPUT="${VERSION}"

release_validate_version "$VERSION"
release_require_command unzip
release_require_file "$DIST_DIR/$RELEASE_ASSET_UPDATES"
release_require_file "$DIST_DIR/$RELEASE_ASSET_WINDOWS_ZIP"
release_require_file "$DIST_DIR/$RELEASE_ASSET_MANIFEST"
release_require_file "$DIST_DIR/$RELEASE_ASSET_SUMS"

EXPECTED_TOP_LEVEL="$(release_expected_assets)"
ACTUAL_TOP_LEVEL="$(release_top_level_files "$DIST_DIR")"
while IFS= read -r asset; do
	[ -n "$asset" ] || continue
	if ! printf '%s\n' "$ACTUAL_TOP_LEVEL" | grep -Fxq "$asset"; then
		release_fail "Missing required dist asset: $asset"
	fi
done <<EOF
$EXPECTED_TOP_LEVEL
EOF

EXPECTED_SUM_LINES="$(release_expected_checksum_subjects)"
ACTUAL_SUM_LINES="$(awk '{print $2}' "$DIST_DIR/$RELEASE_ASSET_SUMS" | sort)"
while IFS= read -r asset; do
	[ -n "$asset" ] || continue
	if ! printf '%s\n' "$ACTUAL_SUM_LINES" | grep -Fxq "$asset"; then
		release_fail "Missing required SHA256SUMS subject: $asset"
	fi
done <<EOF
$EXPECTED_SUM_LINES
EOF

release_check_sha256sums "$DIST_DIR" "$RELEASE_ASSET_SUMS" >/dev/null

if ! grep -Fq "\"version\": \"$VERSION\"" "$DIST_DIR/$RELEASE_ASSET_MANIFEST"; then
	release_fail "updates-release.json missing version $VERSION"
fi
if ! grep -Fq "\"source_repo\": \"$RELEASE_CANONICAL_REPO\"" "$DIST_DIR/$RELEASE_ASSET_MANIFEST"; then
	release_fail "updates-release.json missing canonical source_repo"
fi
if ! grep -Fq "\"channel\": \"$RELEASE_CHANNEL\"" "$DIST_DIR/$RELEASE_ASSET_MANIFEST"; then
	release_fail "updates-release.json missing release channel"
fi
if ! grep -Fq "\"bootstrap_min\": $RELEASE_BOOTSTRAP_MIN" "$DIST_DIR/$RELEASE_ASSET_MANIFEST"; then
	release_fail "updates-release.json missing bootstrap_min"
fi
if ! grep -Fq "\"windows_asset\": \"$RELEASE_ASSET_WINDOWS_ZIP\"" "$DIST_DIR/$RELEASE_ASSET_MANIFEST"; then
	release_fail "updates-release.json missing windows asset"
fi
if ! grep -Fq "\"unix_asset\": \"$RELEASE_ASSET_UPDATES\"" "$DIST_DIR/$RELEASE_ASSET_MANIFEST"; then
	release_fail "updates-release.json missing unix asset"
fi
if ! grep -Fq "\"checksum_asset\": \"$RELEASE_ASSET_SUMS\"" "$DIST_DIR/$RELEASE_ASSET_MANIFEST"; then
	release_fail "updates-release.json missing checksum asset"
fi

bash -n "$DIST_DIR/$RELEASE_ASSET_UPDATES"
VERSION_OUTPUT="$("$DIST_DIR/$RELEASE_ASSET_UPDATES" --version | tr -d '\r')"
if [ "$VERSION_OUTPUT" != "$EXPECTED_VERSION_OUTPUT" ]; then
	release_fail "Unexpected version output from dist/updates: $VERSION_OUTPUT"
fi

TMP_DIR="$(release_make_tmpdir)"
trap 'rm -rf "$TMP_DIR"' EXIT

unzip -q "$DIST_DIR/$RELEASE_ASSET_WINDOWS_ZIP" -d "$TMP_DIR"

EXPECTED_ZIP_FILES="$(
	printf '%s\n' \
		"current.txt" \
		"install-source.json" \
		"previous.txt" \
		"updates.cmd" \
		"updates.ps1" \
		"versions/$VERSION/manifest.json" \
		"versions/$VERSION/updates-main.ps1"
)"
ACTUAL_ZIP_FILES="$(
	cd "$TMP_DIR"
	find . -type f | sed 's#^\./##' | sort
)"
if [ "$ACTUAL_ZIP_FILES" != "$EXPECTED_ZIP_FILES" ]; then
	echo "Unexpected Windows zip contents" >&2
	echo "Expected:" >&2
	printf '%s\n' "$EXPECTED_ZIP_FILES" >&2
	echo "Actual:" >&2
	printf '%s\n' "$ACTUAL_ZIP_FILES" >&2
	exit 1
fi

CURRENT_VERSION="$(tr -d '\r\n' <"$TMP_DIR/current.txt")"
if [ "$CURRENT_VERSION" != "$VERSION" ]; then
	release_fail "Windows zip current.txt does not match version $VERSION"
fi
if [ -s "$TMP_DIR/previous.txt" ]; then
	release_fail "Windows zip previous.txt must be empty for a fresh release"
fi

if ! grep -Fq "\"kind\": \"standalone\"" "$TMP_DIR/install-source.json"; then
	release_fail "install-source.json missing standalone kind"
fi
if ! grep -Fq "\"channel\": \"$RELEASE_CHANNEL\"" "$TMP_DIR/install-source.json"; then
	release_fail "install-source.json missing release channel"
fi
if ! grep -Fq "\"source_repo\": \"$RELEASE_CANONICAL_REPO\"" "$TMP_DIR/install-source.json"; then
	release_fail "install-source.json missing canonical source_repo"
fi
if ! grep -Fq "\"scope\": \"user\"" "$TMP_DIR/install-source.json"; then
	release_fail "install-source.json missing user scope"
fi
if ! grep -Fq "\"installed_version\": \"$VERSION\"" "$TMP_DIR/install-source.json"; then
	release_fail "install-source.json missing installed version"
fi

WINDOWS_MANIFEST="$TMP_DIR/versions/$VERSION/manifest.json"
if ! grep -Fq "\"version\": \"$VERSION\"" "$WINDOWS_MANIFEST"; then
	release_fail "Windows payload manifest missing version $VERSION"
fi
if ! grep -Fq "\"bootstrap_min\": $RELEASE_BOOTSTRAP_MIN" "$WINDOWS_MANIFEST"; then
	release_fail "Windows payload manifest missing bootstrap_min"
fi
if ! grep -Fq "\"entry_script\": \"updates-main.ps1\"" "$WINDOWS_MANIFEST"; then
	release_fail "Windows payload manifest missing entry_script"
fi

echo "Verified release artifacts in $DIST_DIR" >&2

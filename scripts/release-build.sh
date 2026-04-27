#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=scripts/release-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/release-lib.sh"

release_cd_root

if [ "${1:-}" = "" ]; then
	echo "Usage: scripts/release-build.sh X.Y.Z|vX.Y.Z [dist-dir]" >&2
	exit 2
fi

VERSION="$(release_normalize_version "$1")"
DIST_DIR="${2:-dist}"
WINDOWS_CMD_SOURCE="${UPDATES_WINDOWS_CMD_SOURCE:-updates.cmd}"
WINDOWS_BOOTSTRAP_SOURCE="${UPDATES_WINDOWS_BOOTSTRAP_SOURCE:-updates.ps1}"
WINDOWS_PAYLOAD_SOURCE="${UPDATES_WINDOWS_PAYLOAD_SOURCE:-updates-main.ps1}"

release_validate_version "$VERSION"
release_require_command zip
release_require_file updates
release_require_file "$WINDOWS_CMD_SOURCE"
release_require_file "$WINDOWS_BOOTSTRAP_SOURCE"
release_require_file "$WINDOWS_PAYLOAD_SOURCE"

SCRIPT_VERSION="$(release_script_version)"
if [ "$SCRIPT_VERSION" != "$VERSION" ]; then
	release_fail "UPDATES_VERSION (${SCRIPT_VERSION}) does not match requested version (${VERSION})"
fi
WINDOWS_VERSION="$(release_windows_payload_version "$WINDOWS_PAYLOAD_SOURCE")"
if [ "$WINDOWS_VERSION" != "$VERSION" ]; then
	release_fail "UpdatesVersion (${WINDOWS_VERSION}) does not match requested version (${VERSION})"
fi

DIST_DIR_ABS="$(release_resolve_path "$DIST_DIR")"
release_validate_output_dir "$DIST_DIR" "$DIST_DIR_ABS"

TMP_DIR="$(release_make_tmpdir)"
trap 'rm -rf "$TMP_DIR"' EXIT

WINDOWS_ROOT="$TMP_DIR/windows-root"
WINDOWS_VERSION_DIR="$WINDOWS_ROOT/versions/$VERSION"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR" "$WINDOWS_VERSION_DIR"

cp updates "$DIST_DIR/$RELEASE_ASSET_UPDATES"
chmod +x "$DIST_DIR/$RELEASE_ASSET_UPDATES"

cp "$WINDOWS_CMD_SOURCE" "$WINDOWS_ROOT/updates.cmd"
cp "$WINDOWS_BOOTSTRAP_SOURCE" "$WINDOWS_ROOT/updates.ps1"
cp "$WINDOWS_PAYLOAD_SOURCE" "$WINDOWS_VERSION_DIR/updates-main.ps1"

printf '%s\n' "$VERSION" >"$WINDOWS_ROOT/current.txt"
: >"$WINDOWS_ROOT/previous.txt"
release_windows_install_receipt "$VERSION" "$WINDOWS_ROOT/install-source.json"
release_windows_payload_manifest "$VERSION" "$WINDOWS_VERSION_DIR/manifest.json"
release_manifest_file "$VERSION" "$DIST_DIR/$RELEASE_ASSET_MANIFEST"

(
	cd "$WINDOWS_ROOT"
	zip -q -r "$DIST_DIR_ABS/$RELEASE_ASSET_WINDOWS_ZIP" .
)

{
	while IFS= read -r asset; do
		printf '%s  %s\n' "$(release_sha256 "$DIST_DIR/$asset")" "$asset"
	done <<EOF
$RELEASE_ASSET_MANIFEST
$RELEASE_ASSET_UPDATES
$RELEASE_ASSET_WINDOWS_ZIP
EOF
} >"$DIST_DIR/$RELEASE_ASSET_SUMS"

echo "Built release artifacts in $DIST_DIR" >&2

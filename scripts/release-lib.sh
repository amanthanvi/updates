#!/usr/bin/env bash

set -euo pipefail

RELEASE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_CANONICAL_REPO="amanthanvi/updates"
RELEASE_CHANNEL="github-release"
RELEASE_BOOTSTRAP_MIN="${UPDATES_RELEASE_BOOTSTRAP_MIN:-1}"
RELEASE_ASSET_UPDATES="updates"
RELEASE_ASSET_WINDOWS_ZIP="updates-windows.zip"
RELEASE_ASSET_MANIFEST="updates-release.json"
RELEASE_ASSET_SUMS="SHA256SUMS"

release_cd_root() {
	cd "$RELEASE_REPO_ROOT"
}

release_fail() {
	echo "$*" >&2
	exit 1
}

release_require_command() {
	local cmd="$1"
	command -v "$cmd" >/dev/null 2>&1 || release_fail "Missing required command: $cmd"
}

release_require_file() {
	local path="$1"
	[ -f "$path" ] || release_fail "Missing required file: $path"
}

release_normalize_version() {
	local input="${1:-}"
	case "$input" in
	v*) printf '%s\n' "${input#v}" ;;
	*) printf '%s\n' "$input" ;;
	esac
}

release_tag_for_version() {
	printf 'v%s\n' "$1"
}

release_validate_version() {
	local version="$1"
	[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || release_fail "Version must be SemVer: X.Y.Z"
}

release_script_version() {
	awk -F'"' '/^UPDATES_VERSION=/{print $2; exit}' updates
}

release_sha256() {
	local path="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$path" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$path" | awk '{print $1}'
	else
		release_fail "Missing required command: sha256sum or shasum"
	fi
}

release_check_sha256sums() {
	local directory="$1"
	local sums_file="$2"
	if command -v sha256sum >/dev/null 2>&1; then
		(
			cd "$directory"
			sha256sum -c "$sums_file"
		)
	elif command -v shasum >/dev/null 2>&1; then
		(
			cd "$directory"
			shasum -a 256 -c "$sums_file"
		)
	else
		release_fail "Missing required command: sha256sum or shasum"
	fi
}

release_make_tmpdir() {
	local base="${TMPDIR:-/tmp}"
	mktemp -d "${base%/}/updates-release.XXXXXX"
}

release_expected_assets() {
	printf '%s\n' \
		"$RELEASE_ASSET_SUMS" \
		"$RELEASE_ASSET_UPDATES" \
		"$RELEASE_ASSET_MANIFEST" \
		"$RELEASE_ASSET_WINDOWS_ZIP"
}

release_expected_checksum_subjects() {
	printf '%s\n' \
		"$RELEASE_ASSET_UPDATES" \
		"$RELEASE_ASSET_MANIFEST" \
		"$RELEASE_ASSET_WINDOWS_ZIP"
}

release_manifest_file() {
	local version="$1"
	local output="$2"
	cat >"$output" <<EOF
{
  "version": "$version",
  "source_repo": "$RELEASE_CANONICAL_REPO",
  "channel": "$RELEASE_CHANNEL",
  "bootstrap_min": $RELEASE_BOOTSTRAP_MIN,
  "windows_asset": "$RELEASE_ASSET_WINDOWS_ZIP",
  "unix_asset": "$RELEASE_ASSET_UPDATES",
  "checksum_asset": "$RELEASE_ASSET_SUMS"
}
EOF
}

release_windows_install_receipt() {
	local version="$1"
	local output="$2"
	cat >"$output" <<EOF
{
  "kind": "standalone",
  "channel": "$RELEASE_CHANNEL",
  "source_repo": "$RELEASE_CANONICAL_REPO",
  "scope": "user",
  "installed_version": "$version"
}
EOF
}

release_windows_payload_manifest() {
	local version="$1"
	local output="$2"
	cat >"$output" <<EOF
{
  "version": "$version",
  "bootstrap_min": $RELEASE_BOOTSTRAP_MIN,
  "entry_script": "updates-main.ps1"
}
EOF
}

release_top_level_files() {
	local directory="$1"
	local path=""
	for path in "$directory"/*; do
		[ -f "$path" ] || continue
		basename "$path"
	done | sort
}

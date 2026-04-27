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
	release_script_version_from_path updates
}

release_script_version_from_path() {
	local path="${1:-updates}"
	awk -F'"' '/^UPDATES_VERSION=/{print $2; exit}' "$path"
}

release_windows_payload_version() {
	local path="${1:-updates-main.ps1}"
	awk -F"'" '/^\$script:UpdatesVersion[[:space:]]*=/{print $2; exit}' "$path"
}

release_resolve_path() {
	local path="$1"
	# Git Bash on Windows can pass absolute Windows paths through to bash.
	case "$path" in
	/* | [A-Za-z]:/* | [A-Za-z]:\\*)
		printf '%s\n' "$path"
		;;
	*)
		printf '%s\n' "$RELEASE_REPO_ROOT/$path"
		;;
	esac
}

release_normalize_path_string() {
	local path="${1:-}"
	path="${path//\\//}"
	while :; do
		case "$path" in
		*/.) path="${path%/.}" ;;
		*/) path="${path%/}" ;;
		*) break ;;
		esac
	done
	printf '%s\n' "$path"
}

release_path_has_parent_traversal() {
	local path="$1"
	local normalized=""
	normalized="$(release_normalize_path_string "$path")"
	case "/$normalized/" in
	*/../*) return 0 ;;
	*) return 1 ;;
	esac
}

release_validate_output_dir() {
	local raw_path="${1:-}"
	local resolved_path="${2:-}"
	local raw_normalized=""
	local resolved_normalized=""
	local repo_normalized=""

	[ -n "$raw_path" ] || release_fail "Output directory path must not be empty"

	raw_normalized="$(release_normalize_path_string "$raw_path")"
	resolved_normalized="$(release_normalize_path_string "$resolved_path")"
	repo_normalized="$(release_normalize_path_string "$RELEASE_REPO_ROOT")"

	case "$raw_normalized" in
	'' | .) release_fail "Output directory path is unsafe: $raw_path" ;;
	esac

	if release_path_has_parent_traversal "$raw_normalized"; then
		release_fail "Output directory path must not contain parent traversal: $raw_path"
	fi

	case "$resolved_normalized" in
	/ | [A-Za-z]:) release_fail "Refusing to delete root output directory: $resolved_path" ;;
	esac

	if [ "$resolved_normalized" = "$repo_normalized" ]; then
		release_fail "Refusing to delete repository root as output directory: $resolved_path"
	fi
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

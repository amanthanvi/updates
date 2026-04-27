#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ensure_windows_cli_aliases_on_path() {
	local links_dir=""

	case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*)
		# Native Windows shells can translate LOCALAPPDATA directly.
		if [ -n "${LOCALAPPDATA:-}" ] && command -v cygpath >/dev/null 2>&1; then
			links_dir="$(cygpath -u "${LOCALAPPDATA}\\Microsoft\\WinGet\\Links" 2>/dev/null || true)"
		fi
		;;
	Linux)
		[ -n "${WSL_INTEROP:-}" ] || return 0
		if command -v powershell.exe >/dev/null 2>&1; then
			local localappdata_win=""
			# WSL needs the Windows LOCALAPPDATA path translated into /mnt/<drive>/...
			# shellcheck disable=SC2016
			localappdata_win="$(powershell.exe -NoLogo -NoProfile -Command '[Console]::Write($env:LOCALAPPDATA)' 2>/dev/null | tr -d '\r')"
			if [ -n "$localappdata_win" ]; then
				links_dir="/mnt/$(printf '%s' "${localappdata_win}\\Microsoft\\WinGet\\Links" | sed -E 's#^([A-Za-z]):#\L\1#; s#\\#/#g')"
			fi
		fi
		if [ -z "${links_dir:-}" ]; then
			local candidate=""
			for candidate in /mnt/c/Users/*/AppData/Local/Microsoft/WinGet/Links; do
				[ -d "$candidate" ] || continue
				links_dir="$candidate"
				break
			done
		fi
		;;
	*) return 0 ;;
	esac

	[ -n "$links_dir" ] || return 0
	[ -d "$links_dir" ] || return 0

	case ":$PATH:" in
	*":$links_dir:"*) ;;
	*) PATH="$links_dir:$PATH" ;;
	esac
}

ensure_windows_cli_aliases_on_path

resolve_tool_cmd() {
	local base="$1"
	if command -v "$base" >/dev/null 2>&1; then
		command -v "$base"
		return 0
	fi
	if command -v "${base}.exe" >/dev/null 2>&1; then
		command -v "${base}.exe"
		return 0
	fi
	return 1
}

bash -n updates
bash -n scripts/*.sh
bash -n tests/*.sh

if command -v pwsh >/dev/null 2>&1; then
	# shellcheck disable=SC2016
	pwsh -NoLogo -NoProfile -Command '
		$files = @(
			"updates.ps1",
			"updates-main.ps1",
			"tests/test_windows_native.ps1"
		)
		$files += @(Get-ChildItem -Path tests/helpers -Filter *.ps1 -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
		$failures = @()
		foreach ($file in $files) {
			$tokens = $null
			$errors = $null
			[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file), [ref]$tokens, [ref]$errors) > $null
			if ($errors) {
				$failures += $errors | ForEach-Object { "{0}: {1}" -f $file, $_.Message }
			}
		}
		if ($failures.Count -gt 0) {
			$failures | ForEach-Object { Write-Error $_ }
			exit 1
		}
	'
fi

SHELLCHECK_BIN="$(resolve_tool_cmd shellcheck || true)"
if [ -z "$SHELLCHECK_BIN" ]; then
	echo "shellcheck is required (try: brew install shellcheck)" >&2
	exit 1
fi

SHFMT_BIN="$(resolve_tool_cmd shfmt || true)"
if [ -z "$SHFMT_BIN" ]; then
	echo "shfmt is required (try: brew install shfmt)" >&2
	exit 1
fi

"$SHELLCHECK_BIN" -x updates scripts/*.sh tests/*.sh
"$SHFMT_BIN" -d updates scripts/*.sh tests/*.sh

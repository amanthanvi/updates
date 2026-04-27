#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

./tests/test_cli.sh

if command -v pwsh >/dev/null 2>&1; then
	# shellcheck disable=SC2016
	if [ "$(pwsh -NoLogo -NoProfile -Command '$IsWindows')" = "True" ]; then
		pwsh -NoLogo -NoProfile -File ./tests/test_windows_native.ps1
	fi
fi

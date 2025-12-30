#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

bash -n updates
bash -n scripts/*.sh
bash -n tests/*.sh

if ! command -v shellcheck >/dev/null 2>&1; then
	echo "shellcheck is required (try: brew install shellcheck)" >&2
	exit 1
fi

if ! command -v shfmt >/dev/null 2>&1; then
	echo "shfmt is required (try: brew install shfmt)" >&2
	exit 1
fi

shellcheck updates scripts/*.sh tests/*.sh
shfmt -d updates scripts/*.sh tests/*.sh

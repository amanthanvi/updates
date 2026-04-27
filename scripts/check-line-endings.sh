#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

pathspecs=(
	updates
	Makefile
	.gitattributes
	.editorconfig
	':(glob)**/*.sh'
	':(glob)**/*.bash'
	':(glob)**/*.ps1'
	':(glob)**/*.psm1'
	':(glob)**/*.psd1'
	':(glob)**/*.cmd'
	':(glob)**/*.bat'
	':(glob).github/workflows/*.yml'
	':(glob).github/workflows/*.yaml'
)

if [ "$#" -gt 0 ]; then
	pathspecs=("$@")
fi

bad_attr=""
bad_worktree=""

while IFS= read -r line; do
	[ -n "$line" ] || continue

	case "$line" in
	*" eol=lf "* | *" eol=lf"$'\t'*)
		;;
	*)
		bad_attr="${bad_attr}${line}"$'\n'
		;;
	esac

	case "$line" in
	*" w/lf "* | *" w/lf"$'\t'*)
		;;
	*)
		bad_worktree="${bad_worktree}${line}"$'\n'
		;;
	esac
done < <(git ls-files --eol -- "${pathspecs[@]}")

if [ -n "$bad_attr" ]; then
	echo "Missing eol=lf attributes for checkout-critical files:" >&2
	printf '%s' "$bad_attr" >&2
fi

if [ -n "$bad_worktree" ]; then
	echo "Non-LF working tree files detected:" >&2
	printf '%s' "$bad_worktree" >&2
fi

if [ -n "$bad_attr" ] || [ -n "$bad_worktree" ]; then
	exit 1
fi

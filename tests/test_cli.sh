#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/updates"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

stub_bin="${tmp_dir}/bin"
mkdir -p "$stub_bin"

BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH="${stub_bin}:${BASE_PATH}"

write_stub() {
	local name="$1"
	shift
	local body="$*"

	cat >"${stub_bin}/${name}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
	chmod +x "${stub_bin}/${name}"
}

CALL_LOG="${tmp_dir}/calls.log"
export CALL_LOG

write_stub uname 'echo Darwin'
# shellcheck disable=SC2016
write_stub brew 'echo "brew $*" >>"$CALL_LOG"'
write_stub ncu 'echo "{\"npm\":\"11.7.0\"}"'
# shellcheck disable=SC2016
write_stub npm 'echo "npm $*" >>"$CALL_LOG"'
# shellcheck disable=SC2016
write_stub pipx 'echo "pipx $*" >>"$CALL_LOG"'
# shellcheck disable=SC2016
write_stub rustup 'echo "rustup $*" >>"$CALL_LOG"'
# shellcheck disable=SC2016
write_stub claude 'echo "claude $*" >>"$CALL_LOG"'
# shellcheck disable=SC2016
write_stub softwareupdate 'echo "softwareupdate $*" >>"$CALL_LOG"'

echo "Test: help works"
"$SCRIPT" --help >/dev/null

echo "Test: list-modules works"
out="$("$SCRIPT" --list-modules)"
echo "$out" | grep -q '^brew'
echo "$out" | grep -q '^linux'

echo "Test: --skip overrides --only"
out="$(UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --dry-run --only brew,node --skip node --verbose)"
echo "$out" | grep -q 'Homebrew'
if echo "$out" | grep -q 'npm globals'; then
	echo "Expected node module to be skipped" >&2
	exit 1
fi
echo "$out" | grep -q '^==> brew START$'
if echo "$out" | grep -q '^==> node START$'; then
	echo "Expected node module to not start" >&2
	exit 1
fi

echo "Test: selected modules run in non-dry-run mode"
out="$(UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --only brew,node --no-emoji)"
echo "$out" | grep -q '^==> brew START$'
echo "$out" | grep -q '^==> brew END (OK)'
echo "$out" | grep -q '^==> node START$'
echo "$out" | grep -q '^==> node END (OK)'
echo "$out" | grep -q '^==> SUMMARY ok=2 skip=0 fail=0 total='
grep -q '^brew update$' "$CALL_LOG"
grep -q '^brew upgrade --formula$' "$CALL_LOG"
grep -q '^npm install -g -- npm@11.7.0$' "$CALL_LOG"

echo "Test: default macOS run is safe (no mas/macos; brew formula only)"
out="$("$SCRIPT" --dry-run --skip node,python,pipx,rustup,claude,linux --no-emoji)"
echo "$out" | grep -q '^==> brew START$'
echo "$out" | grep -q '^DRY RUN: brew upgrade --formula$'
if echo "$out" | grep -q '^==> mas START$'; then
	echo "Expected mas module to be disabled by default" >&2
	exit 1
fi
if echo "$out" | grep -q '^==> macos START$'; then
	echo "Expected macos module to be disabled by default" >&2
	exit 1
fi

echo "Test: missing dependency errors in --only mode"
set +e
UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --dry-run --only mas >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
	echo "Expected failure when --only mas but mas is missing" >&2
	exit 1
fi

echo "Test: --brew-casks enables brew upgrade (greedy) on macOS"
: >"$CALL_LOG"
"$SCRIPT" --only brew --brew-casks --no-emoji >/dev/null
grep -q '^brew upgrade --greedy$' "$CALL_LOG"
if grep -q '^brew upgrade --formula$' "$CALL_LOG"; then
	echo "Expected brew formula-only upgrades to be disabled when --brew-casks is set" >&2
	exit 1
fi

echo "Test: --only mas runs even when opt-in by default"
# shellcheck disable=SC2016
write_stub mas 'echo "mas $*" >>"$CALL_LOG"'
: >"$CALL_LOG"
"$SCRIPT" --only mas --no-emoji >/dev/null
grep -q '^mas upgrade$' "$CALL_LOG"

echo "Test: --only macos runs even when opt-in by default"
: >"$CALL_LOG"
"$SCRIPT" --only macos --no-emoji >/dev/null
grep -q '^softwareupdate -l$' "$CALL_LOG"

echo "Test: --full enables brew casks + mas + macos"
: >"$CALL_LOG"
out="$("$SCRIPT" --full --skip node,python,pipx,rustup,claude,linux --no-emoji)"
echo "$out" | grep -q '^==> brew START$'
echo "$out" | grep -q '^==> mas START$'
echo "$out" | grep -q '^==> macos START$'
grep -q '^brew upgrade --greedy$' "$CALL_LOG"
grep -q '^mas upgrade$' "$CALL_LOG"
grep -q '^softwareupdate -l$' "$CALL_LOG"

echo "Test: python uses --user in externally-managed env"
# shellcheck disable=SC2016
write_stub python3 '
if [ "${1:-}" = "-c" ]; then
	code="${2:-}"
	if echo "$code" | grep -q "EXTERNALLY-MANAGED"; then
		echo "1"
		exit 0
	fi
	echo "pillow"
	exit 0
fi

	if [ "${1:-}" = "-m" ] && [ "${2:-}" = "pip" ]; then
		shift 2
		if [ "${1:-}" = "--version" ]; then
			echo "pip 25.0 from /dev/null (python 3.12)"
			exit 0
		fi
		if [ "${1:-}" = "--disable-pip-version-check" ]; then
			shift
		fi
		cmd="${1:-}"
		shift || true
		case "$cmd" in
	list)
		echo "python3 -m pip list $*" >>"$CALL_LOG"
		echo "[{\"name\":\"pillow\"}]"
		exit 0
		;;
	install)
		echo "python3 -m pip install $*" >>"$CALL_LOG"
		exit 0
		;;
	esac
fi

echo "python3 stub: unexpected args: $*" >&2
exit 1
'

: >"$CALL_LOG"
"$SCRIPT" --only python --no-emoji >/dev/null
grep -q '^python3 -m pip list --outdated --format=json --user$' "$CALL_LOG"
grep -q '^python3 -m pip install -U --user pillow$' "$CALL_LOG"

echo "Test: python break-system-packages opt-in"
: >"$CALL_LOG"
"$SCRIPT" --only python --python-break-system-packages --no-emoji >/dev/null
grep -q '^python3 -m pip list --outdated --format=json$' "$CALL_LOG"
grep -q '^python3 -m pip install -U --break-system-packages pillow$' "$CALL_LOG"

echo "Test: linux module (apt-get) runs in non-interactive mode"
write_stub uname 'echo Linux'
# shellcheck disable=SC2016
write_stub sudo 'echo "sudo $*" >>"$CALL_LOG"; if [ "${1:-}" = "-n" ]; then shift; fi; "$@"'
# shellcheck disable=SC2016
write_stub apt-get 'echo "apt-get $*" >>"$CALL_LOG"'

: >"$CALL_LOG"
"$SCRIPT" --only linux --non-interactive --no-emoji >/dev/null
grep -q '^sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update$' "$CALL_LOG"
grep -q '^sudo -n env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y$' "$CALL_LOG"
grep -q '^apt-get update$' "$CALL_LOG"
grep -q '^apt-get upgrade -y$' "$CALL_LOG"

echo "All tests passed."

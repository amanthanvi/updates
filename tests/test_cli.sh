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

echo "Test: selected modules run in non-dry-run mode"
UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --only brew,node --no-emoji >/dev/null
grep -q '^brew update$' "$CALL_LOG"
grep -q '^npm install -g -- npm@11.7.0$' "$CALL_LOG"

echo "Test: missing dependency errors in --only mode"
set +e
UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --dry-run --only mas >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
	echo "Expected failure when --only mas but mas is missing" >&2
	exit 1
fi

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
grep -q '^sudo -n apt-get update$' "$CALL_LOG"
grep -q '^sudo -n apt-get upgrade -y$' "$CALL_LOG"
grep -q '^apt-get update$' "$CALL_LOG"
grep -q '^apt-get upgrade -y$' "$CALL_LOG"

echo "All tests passed."

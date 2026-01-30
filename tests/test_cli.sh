#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/updates"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

HOME_DIR="${tmp_dir}/home"
mkdir -p "$HOME_DIR"
export HOME="$HOME_DIR"
export ZSH=""
export ZSH_CUSTOM=""

stub_bin="${tmp_dir}/bin"
mkdir -p "$stub_bin"

BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH="${stub_bin}:${BASE_PATH}"

# Self-update hits the network by default; disable for deterministic tests.
export UPDATES_SELF_UPDATE=0

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
write_stub git 'echo "GIT_TERMINAL_PROMPT=${GIT_TERMINAL_PROMPT:-} git $*" >>"$CALL_LOG"'
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
echo "$out" | grep -q '^shell'
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
echo "$out" | grep -q '^==> shell START$'
echo "$out" | grep -q '^==> shell END (SKIP)'
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
echo "$out" | grep -q '^==> shell START$'
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

echo "Test: shell module updates Oh My Zsh repos"
shell_home="${tmp_dir}/home-shell"
omz_dir="${shell_home}/.oh-my-zsh"
mkdir -p "${omz_dir}/custom/plugins/zsh-autosuggestions"
mkdir -p "${omz_dir}/custom/themes/powerlevel10k"
touch "${omz_dir}/.git"
touch "${omz_dir}/custom/plugins/zsh-autosuggestions/.git"
touch "${omz_dir}/custom/themes/powerlevel10k/.git"

: >"$CALL_LOG"
HOME="$shell_home" "$SCRIPT" --only shell --non-interactive --no-emoji >/dev/null
grep -q "^GIT_TERMINAL_PROMPT=0 git -C ${omz_dir} pull --ff-only$" "$CALL_LOG"
grep -q "^GIT_TERMINAL_PROMPT=0 git -C ${omz_dir}/custom/plugins/zsh-autosuggestions pull --ff-only$" "$CALL_LOG"
grep -q "^GIT_TERMINAL_PROMPT=0 git -C ${omz_dir}/custom/themes/powerlevel10k pull --ff-only$" "$CALL_LOG"

echo "Test: self-update accepts checksum paths (dist/updates)"
self_update_home="${tmp_dir}/home-self-update"
mkdir -p "$self_update_home"

self_update_bin="${tmp_dir}/self-update-bin"
mkdir -p "$self_update_bin"

self_update_fixtures="${tmp_dir}/self-update-fixtures"
mkdir -p "$self_update_fixtures"

self_update_old="${self_update_bin}/updates"
self_update_new="${self_update_fixtures}/updates.new"

mk_versioned_copy() {
	local src="$1"
	local dest="$2"
	local ver="$3"
	local tmp="${dest}.tmp"

	awk -v ver="$ver" '
		BEGIN { done = 0 }
		{
			if (done == 0 && $0 ~ /^UPDATES_VERSION="/) {
				print "UPDATES_VERSION=\"" ver "\""
				done = 1
				next
			}
			print
		}
	' "$src" >"$tmp"
	mv "$tmp" "$dest"
	chmod +x "$dest"
}

mk_versioned_copy "$SCRIPT" "$self_update_old" "0.0.1"
mk_versioned_copy "$SCRIPT" "$self_update_new" "0.0.2"

sha256_file() {
	local f="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$f" | awk '{print $1}'
		return 0
	fi
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$f" | awk '{print $1}'
		return 0
	fi
	echo "No sha256 tool available (sha256sum/shasum)" >&2
	return 1
}

sha="$(sha256_file "$self_update_new")"
printf '%s  dist/updates\n' "$sha" >"${self_update_fixtures}/SHA256SUMS"

export SELF_UPDATE_FIXTURES="$self_update_fixtures"
# shellcheck disable=SC2016
write_stub curl '
out=""
url=""
while [ $# -gt 0 ]; do
	case "$1" in
	-o)
		out="${2:-}"
		shift 2
		;;
	http*://*)
		url="$1"
		shift
		;;
	*)
		shift
		;;
	esac
done

case "$url" in
*/releases/latest)
	echo "{\"tag_name\":\"v0.0.2\"}"
	;;
*/updates)
	cp "${SELF_UPDATE_FIXTURES}/updates.new" "$out"
	;;
*/SHA256SUMS)
	cp "${SELF_UPDATE_FIXTURES}/SHA256SUMS" "$out"
	;;
*)
	echo "curl stub: unexpected url: $url" >&2
	exit 1
	;;
esac
'

# Ensure self-update isn't skipped due to our git stub always succeeding.
write_stub git 'exit 1'

out="$(UPDATES_SELF_UPDATE=1 CI="" UPDATES_SELF_UPDATE_REPO=fake/repo HOME="$self_update_home" "$self_update_old" --only brew --no-emoji --no-color 2>&1)"
echo "$out" | grep -q 'updates: self-update available (0.0.1 -> 0.0.2)'
echo "$out" | grep -q 'updates: updated to 0.0.2; restarting'

if [ "$("$self_update_old" --version)" != "0.0.2" ]; then
	echo "Expected self-update to replace the installed script" >&2
	exit 1
fi

echo "All tests passed."

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
write_stub uv 'echo "uv $*" >>"$CALL_LOG"'
# shellcheck disable=SC2016
write_stub mise 'echo "mise $*" >>"$CALL_LOG"'
# shellcheck disable=SC2016
write_stub go 'echo "go $*" >>"$CALL_LOG"'
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
actual_modules="$(printf '%s\n' "$out" | awk '{print $1}' | paste -sd' ' -)"
expected_modules='brew shell linux node python uv mas pipx rustup claude mise go macos'
if [ "$actual_modules" != "$expected_modules" ]; then
	echo "Expected module order: $expected_modules" >&2
	echo "Actual module order:   $actual_modules" >&2
	exit 1
fi

echo "Test: --log-level filters output"
warn_stderr="${tmp_dir}/warn-stderr.log"
: >"$warn_stderr"
out="$(UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --dry-run --only brew --log-level warn --no-emoji --no-color 2>"$warn_stderr")"
echo "$out" | grep -q '^==> brew START$'
echo "$out" | grep -q '^==> brew END (OK)'
echo "$out" | grep -q '^==> SUMMARY ok=1 skip=0 fail=0 total='
if echo "$out" | grep -q 'Starting updates...'; then
	echo "Expected info logs to be suppressed at --log-level warn" >&2
	exit 1
fi
if echo "$out" | grep -q 'Homebrew'; then
	echo "Expected module info logs to be suppressed at --log-level warn" >&2
	exit 1
fi
if grep -q 'Defaulting to brew formula upgrades only on macOS' "$warn_stderr"; then
	echo "Expected brew default reminder to be info-level, not warn-level" >&2
	exit 1
fi

error_stderr="${tmp_dir}/error-stderr.log"
: >"$error_stderr"
out="$(UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --dry-run --only brew --log-level error --no-emoji --no-color 2>"$error_stderr")"
if [ -n "$out" ]; then
	echo "Expected no stdout output at --log-level error" >&2
	exit 1
fi
if [ -s "$error_stderr" ]; then
	echo "Expected no stderr output at --log-level error for default brew dry-run" >&2
	exit 1
fi

echo "Test: config defaults + --no-config"
config_home="${tmp_dir}/home-config"
mkdir -p "$config_home"
cat >"${config_home}/.updatesrc" <<EOF
BREW_CLEANUP=0
BREW_MODE=greedy
EOF

out="$(HOME="$config_home" "$SCRIPT" --dry-run --only brew --no-emoji --no-color)"
if echo "$out" | grep -q '^DRY RUN: brew cleanup$'; then
	echo "Expected BREW_CLEANUP=0 to disable brew cleanup" >&2
	exit 1
fi
echo "$out" | grep -q '^DRY RUN: brew upgrade --greedy$'

out="$(HOME="$config_home" "$SCRIPT" --dry-run --only brew --no-config --no-emoji --no-color)"
echo "$out" | grep -q '^DRY RUN: brew cleanup$'

out="$(HOME="$config_home" "$SCRIPT" --dry-run --only brew --brew-mode formula --no-emoji --no-color)"
echo "$out" | grep -q '^DRY RUN: brew upgrade --formula$'

echo "Test: config SKIP_MODULES does not override --only"
config_home_skip="${tmp_dir}/home-config-skip"
mkdir -p "$config_home_skip"
cat >"${config_home_skip}/.updatesrc" <<EOF
SKIP_MODULES=node
EOF
out="$(HOME="$config_home_skip" "$SCRIPT" --dry-run --only node --no-emoji --no-color)"
echo "$out" | grep -q '^==> node START$'

echo "Test: --brew-mode validates input"
set +e
UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --dry-run --only brew --brew-mode nope >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
	echo "Expected exit code 2 for invalid --brew-mode" >&2
	exit 1
fi

echo "Test: deprecated flags error (exit 2)"
for flag in \
	-q \
	--quiet \
	-v \
	--verbose \
	--python-break-system-packages \
	--brew-casks \
	--no-brew-casks \
	--brew-greedy \
	--no-brew-greedy; do
	set +e
	out="$(UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --dry-run --only brew "$flag" --no-emoji --no-color 2>&1)"
	rc=$?
	set -e
	if [ "$rc" -ne 2 ]; then
		echo "Expected exit code 2 for deprecated flag $flag (got $rc)" >&2
		exit 1
	fi
	echo "$out" | grep -q 'Unknown option'
done

echo "Test: --json emits JSONL to stdout only"
json_stderr="${tmp_dir}/json-stderr.log"
: >"$json_stderr"
json_out="$("$SCRIPT" --json --dry-run --only brew --no-emoji --no-color 2>"$json_stderr")"
if echo "$json_out" | grep -q '^==>'; then
	echo "Expected JSON stdout to contain no human boundary lines" >&2
	exit 1
fi
grep -q '^==> brew START$' "$json_stderr"
grep -q '^Defaulting to brew formula upgrades only on macOS\. Enable casks with --brew-mode casks (or --full)\.$' "$json_stderr"
if grep -q '^WARN: Defaulting to brew formula upgrades only on macOS' "$json_stderr"; then
	echo "Expected brew default reminder to be logged without WARN prefix" >&2
	exit 1
fi
json_out_file="${tmp_dir}/json-out.jsonl"
printf '%s\n' "$json_out" >"$json_out_file"
python3 - "$json_out_file" <<'PY'
import json, sys

events = []
modules = []
with open(sys.argv[1], "r", encoding="utf-8") as f:
    lines = f.readlines()

for raw in lines:
    raw = raw.strip()
    if not raw:
        continue
    obj = json.loads(raw)
    events.append(obj.get("event"))
    modules.append(obj.get("module"))

assert "module_start" in events
assert "module_end" in events
assert "summary" in events
assert "brew" in modules
PY

echo "Test: --skip overrides --only"
out="$(UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --dry-run --only brew,node --skip node --log-level debug)"
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

echo "Test: --brew-mode greedy enables brew upgrade (greedy) on macOS"
: >"$CALL_LOG"
greedy_stderr="${tmp_dir}/greedy-stderr.log"
: >"$greedy_stderr"
"$SCRIPT" --only brew --brew-mode greedy --no-emoji >/dev/null 2>"$greedy_stderr"
grep -q '^brew upgrade --greedy$' "$CALL_LOG"
if grep -q '^brew upgrade --formula$' "$CALL_LOG"; then
	echo "Expected brew formula-only upgrades to be disabled when --brew-mode greedy is set" >&2
	exit 1
fi
grep -q '^WARN: Homebrew cask upgrades may modify /Applications\.$' "$greedy_stderr"

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
full_stderr="${tmp_dir}/full-stderr.log"
: >"$full_stderr"
out="$("$SCRIPT" --full --skip node,python,pipx,rustup,claude,linux --no-emoji 2>"$full_stderr")"
echo "$out" | grep -q '^==> brew START$'
echo "$out" | grep -q '^==> shell START$'
echo "$out" | grep -q '^==> mas START$'
echo "$out" | grep -q '^==> macos START$'
grep -q '^brew upgrade --greedy$' "$CALL_LOG"
grep -q '^mas upgrade$' "$CALL_LOG"
grep -q '^softwareupdate -l$' "$CALL_LOG"
grep -q '^WARN: Homebrew cask upgrades may modify /Applications\.$' "$full_stderr"

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

echo "Test: python break-system-packages opt-in (pip-force)"
: >"$CALL_LOG"
"$SCRIPT" --only python --pip-force --no-emoji >/dev/null
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

echo "Test: uv module runs"
: >"$CALL_LOG"
"$SCRIPT" --only uv --no-emoji >/dev/null
grep -q '^uv self update$' "$CALL_LOG"
grep -q '^uv tool upgrade --all$' "$CALL_LOG"

echo "Test: mise module runs"
: >"$CALL_LOG"
"$SCRIPT" --only mise --no-emoji >/dev/null
grep -q '^mise self-update$' "$CALL_LOG"
grep -q '^mise upgrade$' "$CALL_LOG"

echo "Test: go module requires GO_BINARIES in --only mode"
go_home_empty="${tmp_dir}/home-go-empty"
mkdir -p "$go_home_empty"
set +e
out="$(HOME="$go_home_empty" "$SCRIPT" --only go --no-emoji --no-color 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
	echo "Expected exit code 1 when --only go without GO_BINARIES configured" >&2
	exit 1
fi
echo "$out" | grep -q 'GO_BINARIES is not configured'

echo "Test: go module installs configured binaries (defaults to @latest)"
go_home="${tmp_dir}/home-go"
mkdir -p "$go_home"
cat >"${go_home}/.updatesrc" <<EOF
GO_BINARIES="golang.org/x/tools/gopls,github.com/go-delve/delve/cmd/dlv@v1.2.3"
EOF
: >"$CALL_LOG"
HOME="$go_home" "$SCRIPT" --only go --no-emoji --no-color >/dev/null
grep -q '^go install golang.org/x/tools/gopls@latest$' "$CALL_LOG"
grep -q '^go install github.com/go-delve/delve/cmd/dlv@v1.2.3$' "$CALL_LOG"

echo "Test: self-update accepts checksum paths (dist/updates)"
self_update_home="${tmp_dir}/home-self-update"
mkdir -p "$self_update_home"

self_update_bin="${tmp_dir}/self-update-bin"
mkdir -p "$self_update_bin"

self_update_fixtures="${tmp_dir}/self-update-fixtures"
mkdir -p "$self_update_fixtures"
SELF_UPDATE_CURL_LOG="${tmp_dir}/self-update-curl.log"
export SELF_UPDATE_CURL_LOG

self_update_old="${self_update_bin}/updates"
self_update_current="${self_update_bin}/updates-current"
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
mk_versioned_copy "$SCRIPT" "$self_update_current" "0.0.2"
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

self_update_cache_file_for() {
	local repo="$1"
	local key="${repo//\//_}"
	printf '%s/updates/self-update-%s.cache' "$SELF_UPDATE_CACHE_ROOT" "$key"
}

run_self_update_script() {
	local script_path="$1"
	shift

	UPDATES_SELF_UPDATE=1 \
		CI="" \
		UPDATES_SELF_UPDATE_REPO="${UPDATES_SELF_UPDATE_REPO_TEST:-fake/repo}" \
		XDG_CACHE_HOME="$SELF_UPDATE_CACHE_ROOT" \
		SELF_UPDATE_FIXTURES="$self_update_fixtures" \
		SELF_UPDATE_CURL_LOG="$SELF_UPDATE_CURL_LOG" \
		SELF_UPDATE_LATEST_TAG="${SELF_UPDATE_LATEST_TAG:-v0.0.2}" \
		SELF_UPDATE_LATEST_FAIL="${SELF_UPDATE_LATEST_FAIL:-0}" \
		HOME="$self_update_home" \
		"$script_path" "$@"
}

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

if [ -n "$url" ]; then
	echo "curl $url" >>"$SELF_UPDATE_CURL_LOG"
fi

case "$url" in
*/releases/latest)
	if [ "${SELF_UPDATE_LATEST_FAIL:-0}" = "1" ]; then
		exit 1
	fi
	echo "{\"tag_name\":\"${SELF_UPDATE_LATEST_TAG:-v0.0.2}\"}"
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

echo "Test: self-update cache hit skips GitHub release API call"
SELF_UPDATE_CACHE_ROOT="${tmp_dir}/self-update-cache-hit"
mkdir -p "$SELF_UPDATE_CACHE_ROOT/updates"
fresh_cache_file="$(self_update_cache_file_for fake/repo)"
fresh_epoch="$(date +%s)"
cat >"$fresh_cache_file" <<EOF
checked_at=${fresh_epoch}
latest_tag=v0.0.2
EOF
: >"$SELF_UPDATE_CURL_LOG"
run_self_update_script "$self_update_current" --only brew --no-emoji --no-color >/dev/null 2>&1
if [ -s "$SELF_UPDATE_CURL_LOG" ]; then
	echo "Expected fresh self-update cache to skip all curl calls" >&2
	exit 1
fi

echo "Test: stale self-update cache refreshes and rewrites cache"
SELF_UPDATE_CACHE_ROOT="${tmp_dir}/self-update-cache-stale"
mkdir -p "$SELF_UPDATE_CACHE_ROOT/updates"
stale_cache_file="$(self_update_cache_file_for fake/repo)"
cat >"$stale_cache_file" <<EOF
checked_at=0
latest_tag=v0.0.1
EOF
: >"$SELF_UPDATE_CURL_LOG"
SELF_UPDATE_LATEST_TAG="v0.0.2"
SELF_UPDATE_LATEST_FAIL=0
run_self_update_script "$self_update_current" --only brew --no-emoji --no-color >/dev/null 2>&1
grep -q '^curl https://api.github.com/repos/fake/repo/releases/latest$' "$SELF_UPDATE_CURL_LOG"
grep -q '^latest_tag=v0.0.2$' "$stale_cache_file"
if grep -q '^checked_at=0$' "$stale_cache_file"; then
	echo "Expected stale self-update cache to be rewritten" >&2
	exit 1
fi

echo "Test: explicit --self-update bypasses a fresh cache"
SELF_UPDATE_CACHE_ROOT="${tmp_dir}/self-update-cache-force"
mkdir -p "$SELF_UPDATE_CACHE_ROOT/updates"
force_cache_file="$(self_update_cache_file_for fake/repo)"
force_epoch="$(date +%s)"
cat >"$force_cache_file" <<EOF
checked_at=${force_epoch}
latest_tag=v0.0.2
EOF
: >"$SELF_UPDATE_CURL_LOG"
run_self_update_script "$self_update_current" --self-update --only brew --no-emoji --no-color >/dev/null 2>&1
grep -q '^curl https://api.github.com/repos/fake/repo/releases/latest$' "$SELF_UPDATE_CURL_LOG"

echo "Test: repo-scoped cache does not cross repo overrides"
SELF_UPDATE_CACHE_ROOT="${tmp_dir}/self-update-cache-repo"
mkdir -p "$SELF_UPDATE_CACHE_ROOT/updates"
other_repo_cache_file="$(self_update_cache_file_for fake/repo)"
other_repo_epoch="$(date +%s)"
cat >"$other_repo_cache_file" <<EOF
checked_at=${other_repo_epoch}
latest_tag=v0.0.2
EOF
: >"$SELF_UPDATE_CURL_LOG"
UPDATES_SELF_UPDATE_REPO_TEST="other/repo"
run_self_update_script "$self_update_current" --only brew --no-emoji --no-color >/dev/null 2>&1
unset UPDATES_SELF_UPDATE_REPO_TEST
grep -q '^curl https://api.github.com/repos/other/repo/releases/latest$' "$SELF_UPDATE_CURL_LOG"
new_repo_cache_file="$(self_update_cache_file_for other/repo)"
[ -f "$new_repo_cache_file" ]

echo "Test: invalid self-update cache is ignored and refreshed"
SELF_UPDATE_CACHE_ROOT="${tmp_dir}/self-update-cache-invalid"
mkdir -p "$SELF_UPDATE_CACHE_ROOT/updates"
invalid_cache_file="$(self_update_cache_file_for fake/repo)"
cat >"$invalid_cache_file" <<EOF
checked_at=not-a-number
latest_tag=definitely-not-semver
EOF
: >"$SELF_UPDATE_CURL_LOG"
run_self_update_script "$self_update_current" --only brew --no-emoji --no-color >/dev/null 2>&1
grep -q '^curl https://api.github.com/repos/fake/repo/releases/latest$' "$SELF_UPDATE_CURL_LOG"
grep -q '^latest_tag=v0.0.2$' "$invalid_cache_file"

echo "Test: failed live self-update check falls back to cached tag"
SELF_UPDATE_CACHE_ROOT="${tmp_dir}/self-update-cache-fallback"
mkdir -p "$SELF_UPDATE_CACHE_ROOT/updates"
fallback_cache_file="$(self_update_cache_file_for fake/repo)"
cat >"$fallback_cache_file" <<EOF
checked_at=0
latest_tag=v0.0.2
EOF
: >"$SELF_UPDATE_CURL_LOG"
SELF_UPDATE_LATEST_FAIL=1
out="$(run_self_update_script "$self_update_old" --only brew --no-emoji --no-color 2>&1)"
SELF_UPDATE_LATEST_FAIL=0
echo "$out" | grep -q 'updates: self-update available (0.0.1 -> 0.0.2)'
echo "$out" | grep -q 'updates: updated to 0.0.2; restarting'
grep -q '^curl https://api.github.com/repos/fake/repo/releases/latest$' "$SELF_UPDATE_CURL_LOG"
grep -q '^curl https://github.com/fake/repo/releases/download/v0.0.2/updates$' "$SELF_UPDATE_CURL_LOG"
grep -q '^curl https://github.com/fake/repo/releases/download/v0.0.2/SHA256SUMS$' "$SELF_UPDATE_CURL_LOG"

echo "Test: symlink install skips before any GitHub release API call"
SELF_UPDATE_CACHE_ROOT="${tmp_dir}/self-update-cache-symlink"
mkdir -p "$SELF_UPDATE_CACHE_ROOT"
self_update_symlink="${self_update_bin}/updates-symlink"
ln -sf "$self_update_current" "$self_update_symlink"
: >"$SELF_UPDATE_CURL_LOG"
run_self_update_script "$self_update_symlink" --only brew --no-emoji --no-color >/dev/null 2>&1
if [ -s "$SELF_UPDATE_CURL_LOG" ]; then
	echo "Expected symlink-installed self-update to skip curl entirely" >&2
	exit 1
fi

echo "Test: self-update accepts checksum paths (dist/updates)"
SELF_UPDATE_CACHE_ROOT="${tmp_dir}/self-update-cache-install"
: >"$SELF_UPDATE_CURL_LOG"
SELF_UPDATE_LATEST_TAG="v0.0.2"
SELF_UPDATE_LATEST_FAIL=0
mk_versioned_copy "$SCRIPT" "$self_update_old" "0.0.1"
out="$(run_self_update_script "$self_update_old" --only brew --no-emoji --no-color 2>&1)"
echo "$out" | grep -q 'updates: self-update available (0.0.1 -> 0.0.2)'
echo "$out" | grep -q 'updates: updated to 0.0.2; restarting'

if [ "$("$self_update_old" --version)" != "0.0.2" ]; then
	echo "Expected self-update to replace the installed script" >&2
	exit 1
fi

echo "All tests passed."

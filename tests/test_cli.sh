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

SYSTEM_NODE="$(command -v node 2>/dev/null || true)"
BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH="${stub_bin}:${BASE_PATH}"

# Self-update hits the network by default; disable for deterministic tests.
export UPDATES_SELF_UPDATE=0

write_stub_to_dir() {
	local dir="$1"
	local name="$2"
	shift 2
	local body="$*"

	cat >"${dir}/${name}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
	chmod +x "${dir}/${name}"
}

write_stub() {
	write_stub_to_dir "$stub_bin" "$@"
}

sha256_file_test() {
	local path="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$path" | awk '{print $1}'
		return 0
	fi
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$path" | awk '{print $1}'
		return 0
	fi
	echo "Missing sha256 tool for test fixture generation" >&2
	exit 1
}

make_installed_copy() {
	local install_root="$1"
	mkdir -p "$install_root"
	cp "$SCRIPT" "${install_root}/updates"
	chmod +x "${install_root}/updates"
	printf '%s\n' "${install_root}/updates"
}

write_self_update_curl_stub() {
	local dir="$1"
	cat >"${dir}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

out=""
url=""

while [ $# -gt 0 ]; do
	case "$1" in
	-o)
		out="$2"
		shift 2
		;;
	--connect-timeout | --max-time)
		shift 2
		;;
	-f | -s | -S | -L | -fsSL | -fsS | -sSL)
		shift
		;;
	-*)
		shift
		;;
	*)
		url="$1"
		shift
		;;
	esac
done

if [ -n "${SELF_UPDATE_CALL_LOG:-}" ]; then
	printf 'curl %s\n' "$url" >>"$SELF_UPDATE_CALL_LOG"
fi

case "$url" in
https://api.github.com/repos/amanthanvi/updates/releases/latest)
	cat "${SELF_UPDATE_FIXTURE_DIR}/release.json"
	;;
https://example.invalid/updates)
	if [ -n "$out" ]; then
		cp "${SELF_UPDATE_FIXTURE_DIR}/updates" "$out"
	else
		cat "${SELF_UPDATE_FIXTURE_DIR}/updates"
	fi
	;;
https://example.invalid/updates-release.json)
	if [ -n "$out" ]; then
		cp "${SELF_UPDATE_FIXTURE_DIR}/updates-release.json" "$out"
	else
		cat "${SELF_UPDATE_FIXTURE_DIR}/updates-release.json"
	fi
	;;
https://example.invalid/SHA256SUMS)
	if [ -n "$out" ]; then
		cp "${SELF_UPDATE_FIXTURE_DIR}/SHA256SUMS" "$out"
	else
		cat "${SELF_UPDATE_FIXTURE_DIR}/SHA256SUMS"
	fi
	;;
*)
	echo "Unexpected curl URL: $url" >&2
	exit 1
	;;
esac
EOF
	chmod +x "${dir}/curl"
}

create_self_update_fixture() {
	local dir="$1"
	local version="$2"
	local mode="${3:-valid}"
	local manifest_source_repo="amanthanvi/updates"
	local updates_path="${dir}/updates"
	local manifest_path="${dir}/updates-release.json"
	local sums_path="${dir}/SHA256SUMS"
	local updates_digest=""
	local manifest_digest=""
	local manifest_release_digest=""
	local sums_digest=""

	mkdir -p "$dir"
	sed "s/^UPDATES_VERSION=\"[^\"]*\"/UPDATES_VERSION=\"${version}\"/" "$SCRIPT" >"$updates_path"
	chmod +x "$updates_path"

	if [ "$mode" = "invalid-manifest" ]; then
		manifest_source_repo="example/invalid"
	fi

	cat >"$manifest_path" <<EOF
{
  "version": "${version}",
  "source_repo": "${manifest_source_repo}",
  "channel": "github-release",
  "bootstrap_min": "0",
  "windows_asset": "updates-windows.zip",
  "unix_asset": "updates",
  "checksum_asset": "SHA256SUMS"
}
EOF

	updates_digest="$(sha256_file_test "$updates_path")"
	printf '%s  updates\n' "$updates_digest" >"$sums_path"
	manifest_digest="$(sha256_file_test "$manifest_path")"
	manifest_release_digest="sha256:${manifest_digest}"
	sums_digest="$(sha256_file_test "$sums_path")"

	if [ "$mode" = "unsupported-digest" ]; then
		manifest_release_digest="md5:deadbeef"
	fi

	cat >"${dir}/release.json" <<EOF
{
  "tag_name": "v${version}",
  "draft": false,
  "prerelease": false,
  "immutable": true,
  "assets": [
    {
      "name": "updates",
      "digest": "sha256:${updates_digest}",
      "browser_download_url": "https://example.invalid/updates"
    },
    {
      "name": "updates-release.json",
      "digest": "${manifest_release_digest}",
      "browser_download_url": "https://example.invalid/updates-release.json"
    },
    {
      "name": "SHA256SUMS",
      "digest": "sha256:${sums_digest}",
      "browser_download_url": "https://example.invalid/SHA256SUMS"
    }
  ]
}
EOF
}

write_self_update_cache_with_metadata() {
	local path="$1"
	local checked_at="$2"
	local latest_tag="$3"
	local fixture_dir="$4"
	local manifest_digest_override="${5:-}"
	local manifest_digest=""

	manifest_digest="sha256:$(sha256_file_test "${fixture_dir}/updates-release.json")"

	if [ -n "$manifest_digest_override" ]; then
		manifest_digest="$manifest_digest_override"
	fi

	mkdir -p "$(dirname "$path")"
	cat >"$path" <<EOF
checked_at=${checked_at}
latest_tag=${latest_tag}
draft=0
prerelease=0
immutable=1
updates_url=https://example.invalid/updates
updates_digest=sha256:$(sha256_file_test "${fixture_dir}/updates")
manifest_url=https://example.invalid/updates-release.json
manifest_digest=${manifest_digest}
sums_url=https://example.invalid/SHA256SUMS
sums_digest=sha256:$(sha256_file_test "${fixture_dir}/SHA256SUMS")
EOF
}

assert_self_update_override_rejected() {
	local override_value="$1"
	local label="$2"
	local out=""
	local rc=0

	set +e
	out="$(UPDATES_SELF_UPDATE_REPO="$override_value" "$SCRIPT" --dry-run --only brew --no-emoji --no-color 2>&1)"
	rc=$?
	set -e

	if [ "$rc" -ne 2 ]; then
		echo "Expected exit code 2 when UPDATES_SELF_UPDATE_REPO is ${label} (got $rc)" >&2
		echo "$out" >&2
		exit 1
	fi
	echo "$out" | grep -q 'UPDATES_SELF_UPDATE_REPO'
	echo "$out" | grep -Eq 'no longer supported|fixed to'
	if echo "$out" | grep -q '^DRY RUN:'; then
		echo "Expected UPDATES_SELF_UPDATE_REPO validation to stop before any dry-run action (${label})" >&2
		echo "$out" >&2
		exit 1
	fi
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
write_stub bun 'echo "bun $*" >>"$CALL_LOG"'
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
write_stub pi 'echo "pi $*" >>"$CALL_LOG"'
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
expected_modules='brew shell repos linux winget node bun python uv mas pipx rustup claude pi mise go macos'
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
out="$("$SCRIPT" --dry-run --skip node,python,pipx,rustup,claude,pi,linux --no-emoji)"
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
out="$("$SCRIPT" --full --skip node,python,pipx,rustup,claude,pi,linux --no-emoji 2>"$full_stderr")"
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
# shellcheck disable=SC2016
write_stub python '
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
		echo "python -m pip list $*" >>"$CALL_LOG"
		echo "[{\"name\":\"pillow\"}]"
		exit 0
		;;
	install)
		echo "python -m pip install $*" >>"$CALL_LOG"
		exit 0
		;;
	esac
fi

echo "python stub: unexpected args: $*" >&2
exit 1
'

: >"$CALL_LOG"
"$SCRIPT" --only python --no-emoji >/dev/null
grep -Eq '^(python|python3) -m pip list --outdated --format=json --user$' "$CALL_LOG"
grep -Eq '^(python|python3) -m pip install -U --user pillow$' "$CALL_LOG"

echo "Test: python break-system-packages opt-in (pip-force)"
: >"$CALL_LOG"
"$SCRIPT" --only python --pip-force --no-emoji >/dev/null
grep -Eq '^(python|python3) -m pip list --outdated --format=json$' "$CALL_LOG"
grep -Eq '^(python|python3) -m pip install -U --break-system-packages pillow$' "$CALL_LOG"

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

echo "Test: bun module runs global upgrades"
: >"$CALL_LOG"
"$SCRIPT" --only bun --no-emoji >/dev/null
grep -q '^bun update -g$' "$CALL_LOG"

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

echo "Test: repos module updates git repos"
repos_home="${tmp_dir}/home-repos"
repos_dir="${repos_home}/GitRepos"
mkdir -p "${repos_dir}/aman-claude-code-setup"
mkdir -p "${repos_dir}/aman-codex-setup"
mkdir -p "${repos_dir}/aman-claude-code-setup/.git"
mkdir -p "${repos_dir}/aman-codex-setup/.git"
# shellcheck disable=SC2016
write_stub git 'echo "git $*" >>"$CALL_LOG"'
: >"$CALL_LOG"
HOME="$repos_home" "$SCRIPT" --only repos --non-interactive --no-emoji --no-color >/dev/null 2>&1
grep -q "git -C ${repos_dir}/aman-claude-code-setup pull --ff-only" "$CALL_LOG"
grep -q "git -C ${repos_dir}/aman-codex-setup pull --ff-only" "$CALL_LOG"

echo "Test: repos module respects REPOS_DIR config"
repos_config_home="${tmp_dir}/home-repos-config"
repos_config_dir="${repos_config_home}/custom-repos"
mkdir -p "${repos_config_dir}/aman-test-setup"
mkdir -p "${repos_config_dir}/aman-test-setup/.git"
cat >"${repos_config_home}/.updatesrc" <<UPDATESRC
REPOS_DIR=${repos_config_dir}
UPDATESRC
# shellcheck disable=SC2016
write_stub git 'echo "git $*" >>"$CALL_LOG"'
: >"$CALL_LOG"
HOME="$repos_config_home" "$SCRIPT" --only repos --non-interactive --no-emoji --no-color >/dev/null 2>&1
grep -q "git -C ${repos_config_dir}/aman-test-setup pull --ff-only" "$CALL_LOG"

echo "Test: repos module skips when no repos exist"
repos_empty_home="${tmp_dir}/home-repos-empty"
mkdir -p "${repos_empty_home}/GitRepos"
out="$(HOME="$repos_empty_home" "$SCRIPT" --only repos --non-interactive --no-emoji --no-color 2>&1)" || true
echo "$out" | grep -q 'repos END (SKIP)'

echo "Test: repos module dry-run shows post-pull script"
repos_dry_home="${tmp_dir}/home-repos-dry"
repos_dry_dir="${repos_dry_home}/GitRepos"
mkdir -p "${repos_dry_dir}/aman-dry-setup/.git"
mkdir -p "${repos_dry_dir}/aman-dry-setup/scripts"
printf '#!/bin/bash\necho ok\n' >"${repos_dry_dir}/aman-dry-setup/scripts/update.sh"
chmod +x "${repos_dry_dir}/aman-dry-setup/scripts/update.sh"
out="$(HOME="$repos_dry_home" "$SCRIPT" --dry-run --only repos --no-emoji --no-color 2>&1)"
echo "$out" | grep -q "DRY RUN: git -C ${repos_dry_dir}/aman-dry-setup pull --ff-only"
echo "$out" | grep -q "DRY RUN: (cd ${repos_dry_dir}/aman-dry-setup && ./scripts/update.sh)"

echo "Test: removed self-update repo override errors"
assert_self_update_override_rejected 'fake/repo' 'non-empty'
assert_self_update_override_rejected '' 'empty'

echo "Test: Unix self-update fresh newer-version cache reuses cached metadata"
self_update_cache_install="${tmp_dir}/self-update-install-cache"
self_update_cache_script="$(make_installed_copy "$self_update_cache_install")"
self_update_cache_bin="${tmp_dir}/self-update-bin-cache"
self_update_cache_fixture="${tmp_dir}/self-update-fixture-cache"
self_update_cache_xdg="${tmp_dir}/self-update-xdg-cache"
self_update_cache_http_log="${tmp_dir}/self-update-http-cache.log"
mkdir -p "${self_update_cache_xdg}/updates" "$self_update_cache_fixture" "$self_update_cache_bin"
write_stub_to_dir "$self_update_cache_bin" uname 'echo Darwin'
# shellcheck disable=SC2016
write_stub_to_dir "$self_update_cache_bin" brew 'echo "brew $*" >>"$CALL_LOG"'
write_self_update_curl_stub "$self_update_cache_bin"
create_self_update_fixture "$self_update_cache_fixture" '2.0.1' 'unsupported-digest'
write_self_update_cache_with_metadata "${self_update_cache_xdg}/updates/self-update-amanthanvi_updates.cache" "$(date +%s)" 'v2.0.1' "$self_update_cache_fixture" 'md5:deadbeef'
: >"$self_update_cache_http_log"
: >"$CALL_LOG"
out="$(UPDATES_SELF_UPDATE=1 XDG_CACHE_HOME="$self_update_cache_xdg" SELF_UPDATE_FIXTURE_DIR="$self_update_cache_fixture" SELF_UPDATE_CALL_LOG="$self_update_cache_http_log" PATH="${self_update_cache_bin}:${BASE_PATH}" "$self_update_cache_script" --only brew --no-emoji --no-color 2>&1)"
if grep -q '^curl https://api.github.com/repos/amanthanvi/updates/releases/latest$' "$self_update_cache_http_log"; then
	echo "Expected cached release metadata to suppress live GitHub metadata fetches" >&2
	cat "$self_update_cache_http_log" >&2
	exit 1
fi
grep -q '^curl https://example.invalid/updates-release.json$' "$self_update_cache_http_log"
echo "$out" | grep -q 'self-update manifest digest missing or unsupported; continuing'
if [ "$("$self_update_cache_script" --version)" != "2.0.0" ]; then
	echo "Expected cached unsupported digest metadata to leave installed version unchanged" >&2
	exit 1
fi
grep -q '^brew update$' "$CALL_LOG"

echo "Test: Unix self-update fresh newer-version tag-only cache fetches live metadata"
self_update_digest_install="${tmp_dir}/self-update-install-digest"
self_update_digest_script="$(make_installed_copy "$self_update_digest_install")"
self_update_digest_bin="${tmp_dir}/self-update-bin-digest"
self_update_digest_fixture="${tmp_dir}/self-update-fixture-digest"
self_update_digest_xdg="${tmp_dir}/self-update-xdg-digest"
self_update_digest_http_log="${tmp_dir}/self-update-http-digest.log"
mkdir -p "$self_update_digest_bin" "$self_update_digest_xdg" "${self_update_digest_xdg}/updates"
write_stub_to_dir "$self_update_digest_bin" uname 'echo Darwin'
# shellcheck disable=SC2016
write_stub_to_dir "$self_update_digest_bin" brew 'echo "brew $*" >>"$CALL_LOG"'
write_self_update_curl_stub "$self_update_digest_bin"
create_self_update_fixture "$self_update_digest_fixture" '2.0.1' 'unsupported-digest'
printf 'checked_at=%s\nlatest_tag=%s\n' "$(date +%s)" 'v2.0.1' >"${self_update_digest_xdg}/updates/self-update-amanthanvi_updates.cache"
: >"$self_update_digest_http_log"
: >"$CALL_LOG"
out="$(UPDATES_SELF_UPDATE=1 XDG_CACHE_HOME="$self_update_digest_xdg" SELF_UPDATE_FIXTURE_DIR="$self_update_digest_fixture" SELF_UPDATE_CALL_LOG="$self_update_digest_http_log" PATH="${self_update_digest_bin}:${BASE_PATH}" "$self_update_digest_script" --only brew --no-emoji --no-color 2>&1)"
echo "$out" | grep -q 'self-update manifest digest missing or unsupported; continuing'
grep -q '^curl https://api.github.com/repos/amanthanvi/updates/releases/latest$' "$self_update_digest_http_log"
grep -q '^curl https://example.invalid/updates-release.json$' "$self_update_digest_http_log"
if [ "$("$self_update_digest_script" --version)" != "2.0.0" ]; then
	echo "Expected unsupported digest metadata to leave installed version unchanged" >&2
	exit 1
fi

echo "Test: Unix self-update skips when release manifest is invalid"
self_update_manifest_install="${tmp_dir}/self-update-install-manifest"
self_update_manifest_script="$(make_installed_copy "$self_update_manifest_install")"
self_update_manifest_bin="${tmp_dir}/self-update-bin-manifest"
self_update_manifest_fixture="${tmp_dir}/self-update-fixture-manifest"
self_update_manifest_xdg="${tmp_dir}/self-update-xdg-manifest"
self_update_manifest_http_log="${tmp_dir}/self-update-http-manifest.log"
mkdir -p "$self_update_manifest_bin" "$self_update_manifest_xdg"
write_stub_to_dir "$self_update_manifest_bin" uname 'echo Darwin'
# shellcheck disable=SC2016
write_stub_to_dir "$self_update_manifest_bin" brew 'echo "brew $*" >>"$CALL_LOG"'
write_self_update_curl_stub "$self_update_manifest_bin"
create_self_update_fixture "$self_update_manifest_fixture" '2.0.1' 'invalid-manifest'
: >"$self_update_manifest_http_log"
: >"$CALL_LOG"
out="$(UPDATES_SELF_UPDATE=1 XDG_CACHE_HOME="$self_update_manifest_xdg" SELF_UPDATE_FIXTURE_DIR="$self_update_manifest_fixture" SELF_UPDATE_CALL_LOG="$self_update_manifest_http_log" PATH="${self_update_manifest_bin}:${BASE_PATH}" "$self_update_manifest_script" --only brew --no-emoji --no-color 2>&1)"
echo "$out" | grep -q 'self-update manifest is invalid; continuing'
grep -q '^curl https://example.invalid/updates$' "$self_update_manifest_http_log"
if [ "$("$self_update_manifest_script" --version)" != "2.0.0" ]; then
	echo "Expected invalid manifest to leave installed version unchanged" >&2
	exit 1
fi

echo "Test: Unix self-update works without Python or Node parsers"
self_update_fallback_install="${tmp_dir}/self-update-install-fallback"
self_update_fallback_script="$(make_installed_copy "$self_update_fallback_install")"
self_update_fallback_bin="${tmp_dir}/self-update-bin-fallback"
self_update_fallback_fixture="${tmp_dir}/self-update-fixture-fallback"
self_update_fallback_xdg="${tmp_dir}/self-update-xdg-fallback"
self_update_fallback_http_log="${tmp_dir}/self-update-http-fallback.log"
mkdir -p "$self_update_fallback_bin" "$self_update_fallback_fixture" "${self_update_fallback_xdg}/updates"
write_stub_to_dir "$self_update_fallback_bin" uname 'echo Darwin'
# shellcheck disable=SC2016
write_stub_to_dir "$self_update_fallback_bin" brew 'echo "brew $*" >>"$CALL_LOG"'
write_self_update_curl_stub "$self_update_fallback_bin"
create_self_update_fixture "$self_update_fallback_fixture" '2.0.1'
: >"$self_update_fallback_http_log"
: >"$CALL_LOG"
out="$(UPDATES_SELF_UPDATE=1 XDG_CACHE_HOME="$self_update_fallback_xdg" SELF_UPDATE_FIXTURE_DIR="$self_update_fallback_fixture" SELF_UPDATE_CALL_LOG="$self_update_fallback_http_log" PATH="${self_update_fallback_bin}:${BASE_PATH}" "$self_update_fallback_script" --only brew --no-emoji --no-color 2>&1)"
grep -q '^curl https://api.github.com/repos/amanthanvi/updates/releases/latest$' "$self_update_fallback_http_log"
grep -q '^curl https://example.invalid/updates-release.json$' "$self_update_fallback_http_log"
grep -q '^curl https://example.invalid/updates$' "$self_update_fallback_http_log"
if [ "$("$self_update_fallback_script" --version)" != "2.0.1" ]; then
	echo "Expected shell-only self-update fallback to install version 2.0.1" >&2
	echo "$out" >&2
	exit 1
fi
grep -q '^brew update$' "$CALL_LOG"

if [ -n "$SYSTEM_NODE" ]; then
	echo "Test: Unix self-update works with Node manifest parsing and no Python"
	self_update_node_install="${tmp_dir}/self-update-install-node"
	self_update_node_script="$(make_installed_copy "$self_update_node_install")"
	self_update_node_bin="${tmp_dir}/self-update-bin-node"
	self_update_node_fixture="${tmp_dir}/self-update-fixture-node"
	self_update_node_xdg="${tmp_dir}/self-update-xdg-node"
	self_update_node_http_log="${tmp_dir}/self-update-http-node.log"
	mkdir -p "$self_update_node_bin" "$self_update_node_fixture" "${self_update_node_xdg}/updates"
	write_stub_to_dir "$self_update_node_bin" uname 'echo Darwin'
	# shellcheck disable=SC2016
	write_stub_to_dir "$self_update_node_bin" brew 'echo "brew $*" >>"$CALL_LOG"'
	write_stub_to_dir "$self_update_node_bin" node "exec \"$SYSTEM_NODE\" \"\$@\""
	write_self_update_curl_stub "$self_update_node_bin"
	create_self_update_fixture "$self_update_node_fixture" '2.0.1'
	: >"$self_update_node_http_log"
	: >"$CALL_LOG"
	out="$(UPDATES_SELF_UPDATE=1 XDG_CACHE_HOME="$self_update_node_xdg" SELF_UPDATE_FIXTURE_DIR="$self_update_node_fixture" SELF_UPDATE_CALL_LOG="$self_update_node_http_log" PATH="${self_update_node_bin}:${BASE_PATH}" "$self_update_node_script" --only brew --no-emoji --no-color 2>&1)"
	if [ "$("$self_update_node_script" --version)" != "2.0.1" ]; then
		echo "Expected node-only self-update parsing to preserve bootstrap_min=0 and install version 2.0.1" >&2
		echo "$out" >&2
		exit 1
	fi
	grep -q '^brew update$' "$CALL_LOG"
fi

echo "Test: config BOM is tolerated"
config_home_bom="${tmp_dir}/home-config-bom"
mkdir -p "$config_home_bom"
printf '\357\273\277BREW_MODE=greedy\n' >"${config_home_bom}/.updatesrc"
out="$(HOME="$config_home_bom" "$SCRIPT" --dry-run --only brew --no-emoji --no-color)"
echo "$out" | grep -q '^DRY RUN: brew upgrade --greedy$'

echo "Test: USERPROFILE fallback finds config when HOME is empty"
config_home_userprofile="${tmp_dir}/home-config-userprofile"
mkdir -p "$config_home_userprofile"
cat >"${config_home_userprofile}/.updatesrc" <<EOF
BREW_MODE=greedy
EOF
out="$(HOME="" USERPROFILE="$config_home_userprofile" "$SCRIPT" --dry-run --only brew --no-emoji --no-color)"
echo "$out" | grep -q '^DRY RUN: brew upgrade --greedy$'

echo "Test: pipx module logs correct commands"
write_stub uname 'echo Darwin'
# shellcheck disable=SC2016
write_stub git 'echo "GIT_TERMINAL_PROMPT=${GIT_TERMINAL_PROMPT:-} git $*" >>"$CALL_LOG"'
: >"$CALL_LOG"
"$SCRIPT" --only pipx --no-emoji >/dev/null
grep -q '^pipx upgrade-all$' "$CALL_LOG"

echo "Test: rustup module logs correct commands"
: >"$CALL_LOG"
"$SCRIPT" --only rustup --no-emoji >/dev/null
grep -q '^rustup update$' "$CALL_LOG"

echo "Test: claude module logs correct commands"
: >"$CALL_LOG"
"$SCRIPT" --only claude --no-emoji >/dev/null
grep -q '^claude update$' "$CALL_LOG"

echo "Test: pi module logs correct commands"
: >"$CALL_LOG"
"$SCRIPT" --only pi --no-emoji >/dev/null
grep -q '^pi update$' "$CALL_LOG"

echo "Test: empty ncu output means node module reports up-to-date"
rm -f "${stub_bin}/python" "${stub_bin}/python3"
write_stub ncu 'echo "{}"'
out="$("$SCRIPT" --only node --no-emoji --no-color)"
echo "$out" | grep -q 'All global npm packages are up-to-date'
write_stub ncu 'echo "{\"npm\":\"11.7.0\"}"'

echo "Test: node falls back to npx npm-check-updates"
rm -f "${stub_bin}/ncu"
# shellcheck disable=SC2016
write_stub npx '
echo "npx $*" >>"$CALL_LOG"
echo "{\"npm\":\"11.8.0\"}"
'
node_fallback_bin="${tmp_dir}/node-fallback-bin"
mkdir -p "$node_fallback_bin"
ln -sf "${stub_bin}/uname" "${node_fallback_bin}/uname"
ln -sf "${stub_bin}/npx" "${node_fallback_bin}/npx"
ln -sf "${stub_bin}/npm" "${node_fallback_bin}/npm"
: >"$CALL_LOG"
PATH="${node_fallback_bin}:${BASE_PATH}" "$SCRIPT" --only node --no-emoji --no-color >/dev/null
grep -q '^npx --yes npm-check-updates -g --jsonUpgraded$' "$CALL_LOG"
grep -q '^npm install -g -- npm@11.8.0$' "$CALL_LOG"
rm -f "${stub_bin}/npx"
write_stub ncu 'echo "{\"npm\":\"11.7.0\"}"'

# Build a clean system PATH that excludes all Linux package managers so that
# PM variant tests can control which manager is detected first.  This prevents
# real system binaries (e.g. /usr/bin/apt-get on Ubuntu CI) from interfering.
linux_sys_bin="${tmp_dir}/linux-sys-bin"
mkdir -p "$linux_sys_bin"
for dir in /usr/bin /bin /usr/sbin /sbin; do
	[ -d "$dir" ] || continue
	for f in "$dir"/*; do
		[ -x "$f" ] || continue
		name="$(basename "$f")"
		case "$name" in
		apt-get | dnf | yum | pacman | zypper | apk) continue ;;
		esac
		[ ! -e "${linux_sys_bin}/${name}" ] || continue
		ln -s "$f" "${linux_sys_bin}/${name}" 2>/dev/null || true
	done
done
LINUX_PM_PATH="${stub_bin}:${linux_sys_bin}"

echo "Test: Linux dnf module (non-interactive dry-run)"
write_stub uname 'echo Linux'
# shellcheck disable=SC2016
write_stub dnf 'echo "dnf $*" >>"$CALL_LOG"'
rm -f "${stub_bin}/apt-get"
# shellcheck disable=SC2016
write_stub sudo 'echo "sudo $*" >>"$CALL_LOG"; if [ "${1:-}" = "-n" ]; then shift; fi; "$@"'
: >"$CALL_LOG"
out="$(PATH="$LINUX_PM_PATH" "$SCRIPT" --only linux --non-interactive --dry-run --no-emoji --no-color)"
echo "$out" | grep -q 'DRY RUN:.*dnf upgrade'

echo "Test: Linux pacman module (non-interactive dry-run)"
write_stub uname 'echo Linux'
# shellcheck disable=SC2016
write_stub pacman 'echo "pacman $*" >>"$CALL_LOG"'
rm -f "${stub_bin}/apt-get" "${stub_bin}/dnf"
# shellcheck disable=SC2016
write_stub sudo 'echo "sudo $*" >>"$CALL_LOG"; if [ "${1:-}" = "-n" ]; then shift; fi; "$@"'
: >"$CALL_LOG"
out="$(PATH="$LINUX_PM_PATH" "$SCRIPT" --only linux --non-interactive --dry-run --no-emoji --no-color)"
echo "$out" | grep -q 'DRY RUN:.*pacman -Syu'

echo "Test: Linux zypper module (non-interactive dry-run)"
write_stub uname 'echo Linux'
# shellcheck disable=SC2016
write_stub zypper 'echo "zypper $*" >>"$CALL_LOG"'
rm -f "${stub_bin}/apt-get" "${stub_bin}/dnf" "${stub_bin}/pacman"
# shellcheck disable=SC2016
write_stub sudo 'echo "sudo $*" >>"$CALL_LOG"; if [ "${1:-}" = "-n" ]; then shift; fi; "$@"'
: >"$CALL_LOG"
out="$(PATH="$LINUX_PM_PATH" "$SCRIPT" --only linux --non-interactive --dry-run --no-emoji --no-color)"
echo "$out" | grep -q 'DRY RUN:.*zypper refresh'
echo "$out" | grep -q 'DRY RUN:.*zypper update'

echo "Test: Linux apk module (non-interactive dry-run)"
write_stub uname 'echo Linux'
# shellcheck disable=SC2016
write_stub apk 'echo "apk $*" >>"$CALL_LOG"'
rm -f "${stub_bin}/apt-get" "${stub_bin}/dnf" "${stub_bin}/pacman" "${stub_bin}/zypper"
# shellcheck disable=SC2016
write_stub sudo 'echo "sudo $*" >>"$CALL_LOG"; if [ "${1:-}" = "-n" ]; then shift; fi; "$@"'
: >"$CALL_LOG"
out="$(PATH="$LINUX_PM_PATH" "$SCRIPT" --only linux --non-interactive --dry-run --no-emoji --no-color)"
echo "$out" | grep -q 'DRY RUN:.*apk update'
echo "$out" | grep -q 'DRY RUN:.*apk upgrade'

# Restore Darwin uname and clean up Linux-only stubs
write_stub uname 'echo Darwin'
rm -f "${stub_bin}/dnf" "${stub_bin}/pacman" "${stub_bin}/zypper" "${stub_bin}/apk" "${stub_bin}/sudo"
# shellcheck disable=SC2016
write_stub apt-get 'echo "apt-get $*" >>"$CALL_LOG"'

echo "Test: config quoted values parse correctly"
config_home_quoted="${tmp_dir}/home-config-quoted"
mkdir -p "$config_home_quoted"
cat >"${config_home_quoted}/.updatesrc" <<EOF
BREW_MODE="greedy"
EOF
out="$(HOME="$config_home_quoted" "$SCRIPT" --dry-run --only brew --no-emoji --no-color)"
echo "$out" | grep -q '^DRY RUN: brew upgrade --greedy$'

config_home_squoted="${tmp_dir}/home-config-squoted"
mkdir -p "$config_home_squoted"
cat >"${config_home_squoted}/.updatesrc" <<EOF
BREW_MODE='greedy'
EOF
out="$(HOME="$config_home_squoted" "$SCRIPT" --dry-run --only brew --no-emoji --no-color)"
echo "$out" | grep -q '^DRY RUN: brew upgrade --greedy$'

echo "Test: config boolean keys work from config file"
config_home_bools="${tmp_dir}/home-config-bools"
mkdir -p "$config_home_bools"
cat >"${config_home_bools}/.updatesrc" <<EOF
MAS_UPGRADE=1
MACOS_UPDATES=1
EOF
# shellcheck disable=SC2016
write_stub mas 'echo "mas $*" >>"$CALL_LOG"'
out="$(HOME="$config_home_bools" "$SCRIPT" --dry-run --skip node,python,pipx,rustup,claude,pi,linux --no-emoji --no-color)"
echo "$out" | grep -q '^==> mas START$'
echo "$out" | grep -q '^==> macos START$'

echo "Test: --strict stops on first module failure"
write_stub uname 'echo Darwin'
write_stub brew 'exit 1'
set +e
strict_out="$(UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --strict --only brew,node --no-emoji --no-color 2>&1)"
strict_rc=$?
set -e
if [ "$strict_rc" -ne 1 ]; then
	echo "Expected exit code 1 for --strict with failing module (got $strict_rc)" >&2
	exit 1
fi
echo "$strict_out" | grep -q '==> brew END (FAIL)'
if echo "$strict_out" | grep -q '==> node START'; then
	echo "Expected --strict to stop before node module" >&2
	exit 1
fi
# Restore brew stub
# shellcheck disable=SC2016
write_stub brew 'echo "brew $*" >>"$CALL_LOG"'

echo "Test: --log-file writes output to file"
write_stub uname 'echo Darwin'
log_file="${tmp_dir}/test-log-file.log"
logfile_out="$(UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --dry-run --only brew --log-file "$log_file" --no-emoji --no-color 2>&1)"
if [ ! -f "$log_file" ]; then
	echo "Expected log file to exist" >&2
	exit 1
fi
grep -q 'brew START' "$log_file"
echo "$logfile_out" | grep -q 'brew START'

echo "Test: --log-file + --json interaction"
log_file_json="${tmp_dir}/test-log-file-json.log"
json_log_stderr="${tmp_dir}/json-log-stderr.log"
json_log_stdout="$(UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --json --dry-run --only brew --log-file "$log_file_json" --no-emoji --no-color 2>"$json_log_stderr")"
printf '%s\n' "$json_log_stdout" | python3 -c "
import json, sys
found = False
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    obj = json.loads(line)
    if obj.get('event') == 'module_start':
        found = True
assert found, 'Expected module_start event in JSON stdout'
"
grep -q '==> brew START' "$log_file_json"

echo "Test: --parallel validation"
write_stub uname 'echo Darwin'
set +e
UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --parallel 0 --dry-run --only brew --no-emoji --no-color >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
	echo "Expected exit code 2 for --parallel 0 (got $rc)" >&2
	exit 1
fi
set +e
UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --parallel abc --dry-run --only brew --no-emoji --no-color >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
	echo "Expected exit code 2 for --parallel abc (got $rc)" >&2
	exit 1
fi
set +e
UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --parallel 2 --dry-run --only brew --no-emoji --no-color >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
	echo "Expected exit code 0 for --parallel 2 (got $rc)" >&2
	exit 1
fi

echo "Test: --only linux on macOS exits with error"
write_stub uname 'echo Darwin'
set +e
linux_on_mac_out="$("$SCRIPT" --only linux --no-emoji --no-color 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
	echo "Expected exit code 2 for --only linux on macOS (got $rc)" >&2
	exit 1
fi
echo "$linux_on_mac_out" | grep -q 'not supported'

echo "All tests passed."

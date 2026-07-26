#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/updates"
TEST_FILTER="${1:-}"
TEST_MATCHED=0

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

HOME_DIR="${tmp_dir}/home"
mkdir -p "$HOME_DIR"
export HOME="$HOME_DIR"
export ZSH=""
export ZSH_CUSTOM=""
unset NVM_DIR

stub_bin="${tmp_dir}/bin"
mkdir -p "$stub_bin"

# Referenced by heredoc-backed test bodies evaluated through run_test.
# shellcheck disable=SC2034
SYSTEM_NODE="$(command -v node 2>/dev/null || true)"
SYSTEM_GIT="$(command -v git 2>/dev/null || true)"
if [ -z "$SYSTEM_GIT" ]; then
	echo "tests: git is required for Git fixture coverage" >&2
	exit 1
fi
SYSTEM_PYTHON3="$(command -v python3 2>/dev/null || true)"
if [ -z "$SYSTEM_PYTHON3" ]; then
	echo "python3 is required for tests/test_cli.sh" >&2
	exit 1
fi
if ! "$SYSTEM_PYTHON3" - <<'PY' >/dev/null 2>&1; then
try:
    import packaging.requirements
except Exception:
    import pip._vendor.packaging.requirements
PY
	echo "python3 with packaging or pip vendored packaging is required for guard helper tests" >&2
	exit 1
fi
BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH="${stub_bin}:${BASE_PATH}"
export SYSTEM_PYTHON3

# Self-update hits the network by default; disable for deterministic tests.
export UPDATES_SELF_UPDATE=0
# Referenced by heredoc-backed test bodies evaluated through run_test.
# shellcheck disable=SC2034
SELF_UPDATE_CURRENT_TEST_VERSION="2.1.2"
# shellcheck disable=SC2034
SELF_UPDATE_NEXT_TEST_VERSION="2.1.3"

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

write_ncu_stub() {
	local json="$1"
	cat >"${stub_bin}/ncu" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "ncu \$*" >>"\$CALL_LOG"
if [ "\${1:-}" = "--help" ]; then
	echo "--enginesNode"
	exit 0
fi
printf '%s\n' '${json}'
EOF
	chmod +x "${stub_bin}/ncu"
}

git_test_commit() {
	local repo="$1"
	local message="$2"
	"$SYSTEM_GIT" -C "$repo" -c user.name=Updates-Test -c user.email=updates-test@example.invalid add -A
	"$SYSTEM_GIT" -C "$repo" -c user.name=Updates-Test -c user.email=updates-test@example.invalid commit -q -m "$message"
}

create_tracked_git_repo() {
	local target="$1"
	local fixture_root="$2"
	local name="$3"
	local seed="${fixture_root}/${name}-seed"
	local remote="${fixture_root}/${name}.git"

	mkdir -p "$seed"
	"$SYSTEM_GIT" init -q "$seed"
	"$SYSTEM_GIT" -C "$seed" checkout -q -b main
	printf 'initial\n' >"${seed}/tracked.txt"
	git_test_commit "$seed" "initial"
	"$SYSTEM_GIT" init -q --bare "$remote"
	"$SYSTEM_GIT" --git-dir="$remote" symbolic-ref HEAD refs/heads/main
	"$SYSTEM_GIT" -C "$seed" remote add origin "$remote"
	"$SYSTEM_GIT" -C "$seed" push -q -u origin main
	"$SYSTEM_GIT" clone -q "$remote" "$target"
}

write_git_ready_stub() {
	# shellcheck disable=SC2016
	write_stub git '
echo "GIT_TERMINAL_PROMPT=${GIT_TERMINAL_PROMPT:-} git $*" >>"$CALL_LOG"
case " $* " in
*" symbolic-ref --quiet --short HEAD ") echo "main" ;;
*" rev-parse --abbrev-ref --symbolic-full-name @{upstream} "*) echo "origin/main" ;;
*" status --porcelain --untracked-files=no "*) ;;
*" rev-list --left-right --count HEAD...@{upstream} "*) printf "0\t0\n" ;;
esac
'
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
  "bootstrap_min": 0,
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
write_ncu_stub '{"npm":"11.7.0"}'
# shellcheck disable=SC2016
write_stub npm 'echo "npm $*" >>"$CALL_LOG"'
# shellcheck disable=SC2016
write_stub bun 'echo "bun $*" >>"$CALL_LOG"'
# shellcheck disable=SC2016
write_stub pipx 'echo "pipx $*" >>"$CALL_LOG"'
write_git_ready_stub
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

test_selected() {
	local name="$1"
	[ -z "$TEST_FILTER" ] || case "$name" in *"$TEST_FILTER"*) return 0 ;; *) return 1 ;; esac
}

run_doctor_tests() {
	local doctor_home="${tmp_dir}/doctor-home"
	local doctor_before="${tmp_dir}/doctor-before"
	local doctor_after="${tmp_dir}/doctor-after"
	local doctor_log="${doctor_home}/nested/doctor.log"
	local json_file="${tmp_dir}/doctor.jsonl"
	local json_stderr="${tmp_dir}/doctor.stderr"
	local bad_cache_home="${tmp_dir}/doctor-bad-cache"
	local out=""
	local rc=0
	mkdir -p "$doctor_home"

	if test_selected "doctor human output is local and read-only"; then
		TEST_MATCHED=1
		echo "Test: doctor human output is local and read-only"
		find "$doctor_home" -print | sort >"$doctor_before"
		out="$(HOME="$doctor_home" UPDATES_SELF_UPDATE=1 "$SCRIPT" --doctor --no-color --no-emoji)"
		find "$doctor_home" -print | sort >"$doctor_after"
		cmp "$doctor_before" "$doctor_after"
		printf '%s\n' "$out" | grep -q '^OK    executable'
		printf '%s\n' "$out" | grep -q '^OK    version'
		printf '%s\n' "$out" | grep -q '^SUMMARY ok='
	fi

	if test_selected "doctor ignores log-file without mutation"; then
		TEST_MATCHED=1
		echo "Test: doctor ignores log-file without mutation"
		HOME="$doctor_home" "$SCRIPT" --doctor --log-file "$doctor_log" --no-color --no-emoji >/dev/null
		[ ! -e "$doctor_log" ]
		[ ! -e "$(dirname "$doctor_log")" ]
	fi

	if test_selected "doctor JSONL is pure and order independent"; then
		TEST_MATCHED=1
		echo "Test: doctor JSONL is pure and order independent"
		HOME="$doctor_home" "$SCRIPT" --doctor --json >"$json_file" 2>"$json_stderr"
		[ ! -s "$json_stderr" ]
		"$SYSTEM_PYTHON3" - "$json_file" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert rows[-1]["event"] == "doctor_summary"
assert rows[-1]["fail"] == 0
assert all(row["event"] in {"doctor_check", "doctor_summary"} for row in rows)
assert {"executable", "version", "platform", "self_update_path", "checksum", "self_update_cache"} <= {
    row.get("check") for row in rows
}
PY
	fi

	if test_selected "invalid doctor cache exits 1"; then
		TEST_MATCHED=1
		echo "Test: invalid doctor cache exits 1"
		mkdir -p "${bad_cache_home}/updates"
		printf 'checked_at=invalid\nlatest_tag=not-semver\n' >"${bad_cache_home}/updates/self-update-amanthanvi_updates.cache"
		set +e
		HOME="$doctor_home" XDG_CACHE_HOME="$bad_cache_home" "$SCRIPT" --json --doctor >"$json_file" 2>"$json_stderr"
		rc=$?
		set -e
		[ "$rc" -eq 1 ]
		"$SYSTEM_PYTHON3" - "$json_file" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert rows[-1]["event"] == "doctor_summary"
assert rows[-1]["fail"] == 1
assert any(row.get("check") == "self_update_cache" and row["status"] == "fail" for row in rows)
PY
	fi
}

run_signal_tests() {
	local signal expected signal_bin pid_file ready_file output rc child_pid
	for signal in INT TERM; do
		case "$signal" in INT) expected=130 ;; TERM) expected=143 ;; esac
		if ! test_selected "${signal} exits ${expected} and terminates active child"; then
			continue
		fi
		TEST_MATCHED=1
		echo "Test: ${signal} exits ${expected} and terminates active child"
		pid_file="${tmp_dir}/signal-${signal}.pid"
		ready_file="${tmp_dir}/signal-${signal}.ready"
		output="${tmp_dir}/signal-${signal}.out"
		signal_bin="${tmp_dir}/signal-${signal}-bin"
		mkdir -p "$signal_bin"
		cat >"${signal_bin}/python" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "-c" ]; then
	if printf '%s' "\${2:-}" | grep -q 'EXTERNALLY-MANAGED'; then
		echo 0
		exit 0
	fi
	exec "$SYSTEM_PYTHON3" "\$@"
fi
if [ "\${1:-}" = "-m" ] && [ "\${2:-}" = "pip" ]; then
	shift 2
	if [ "\${1:-}" = "--disable-pip-version-check" ]; then
		shift
	fi
	case "\${1:-}" in
	--version)
		echo 'pip 25.0 from /dev/null (python 3.12)'
		;;
	list)
		echo '[{"name":"interrupt-probe","version":"1.0","latest_version":"2.0"}]'
		;;
	install)
		printf '%s\n' "\$\$" >"$pid_file"
		: >"$ready_file"
		exec sleep 30
		;;
	*) exit 1 ;;
	esac
	exit 0
fi
exit 1
EOF
		chmod +x "${signal_bin}/python"
		cp "${signal_bin}/python" "${signal_bin}/python3"
		set +e
		"$SYSTEM_PYTHON3" - "$SCRIPT" "$signal_bin" "$ready_file" "$output" "$signal" <<'PY'
import os, signal, subprocess, sys, time
script, signal_bin, ready, output, signal_name = sys.argv[1:]
env = os.environ.copy()
env["PATH"] = signal_bin + os.pathsep + env["PATH"]
with open(output, "wb") as stream:
    process = subprocess.Popen(
        ["bash", script, "--only", "python", "--parallel", "1", "--no-emoji"],
        env=env,
        start_new_session=True,
        stdout=stream,
        stderr=subprocess.STDOUT,
    )
    for _ in range(200):
        if os.path.exists(ready):
            break
        if process.poll() is not None:
            raise SystemExit(f"helper exited before ready: {process.returncode}")
        time.sleep(0.01)
    else:
        process.kill()
        raise SystemExit("updates did not start the module child")
    # Signal only the updates parent. The active pip child must be terminated
    # by the real updates trap, not by terminal process-group delivery.
    os.kill(process.pid, getattr(signal, "SIG" + signal_name))
    raise SystemExit(process.wait(timeout=5))
PY
		rc=$?
		set -e
		child_pid="$(cat "$pid_file")"
		[ "$rc" -eq "$expected" ]
		if kill -0 "$child_pid" 2>/dev/null; then
			echo "Expected ${signal} handler to terminate child ${child_pid}" >&2
			kill "$child_pid" 2>/dev/null || true
			exit 1
		fi
		grep -q "Interrupted (SIG${signal})" "$output"
	done
}

run_doctor_tests
run_signal_tests

run_test() {
	local name="$1"
	local body=""
	body="$(cat)"
	if ! test_selected "$name"; then
		return 0
	fi
	TEST_MATCHED=1
	echo "Test: $name"
	eval "$body"
}

run_test "help works" <<'UPDATES_TEST_CASE'
"$SCRIPT" --help >/dev/null

UPDATES_TEST_CASE

run_test "list-modules works" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

run_test "--log-level filters output" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

run_test "config defaults + --no-config" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

run_test "config SKIP_MODULES does not override --only" <<'UPDATES_TEST_CASE'
config_home_skip="${tmp_dir}/home-config-skip"
mkdir -p "$config_home_skip"
cat >"${config_home_skip}/.updatesrc" <<EOF
SKIP_MODULES=node
EOF
out="$(HOME="$config_home_skip" "$SCRIPT" --dry-run --only node --no-emoji --no-color)"
echo "$out" | grep -q '^==> node START$'

UPDATES_TEST_CASE

run_test "--brew-mode validates input" <<'UPDATES_TEST_CASE'
set +e
UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --dry-run --only brew --brew-mode nope >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
	echo "Expected exit code 2 for invalid --brew-mode" >&2
	exit 1
fi

UPDATES_TEST_CASE

run_test "deprecated flags error (exit 2)" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

run_test "--json emits JSONL to stdout only" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

run_test "--skip overrides --only" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

run_test "selected modules run in non-dry-run mode" <<'UPDATES_TEST_CASE'
out="$(UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --only brew,node --no-emoji)"
echo "$out" | grep -q '^==> brew START$'
echo "$out" | grep -q '^==> brew END (OK)'
echo "$out" | grep -q '^==> node START$'
echo "$out" | grep -q '^==> node END (OK)'
echo "$out" | grep -q '^==> SUMMARY ok=2 skip=0 fail=0 total='
grep -q '^brew update$' "$CALL_LOG"
grep -q '^brew upgrade --formula$' "$CALL_LOG"
grep -q '^npm install -g -- npm@11.7.0$' "$CALL_LOG"

UPDATES_TEST_CASE

run_test "default macOS run is safe (no mas/macos; brew formula only)" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

run_test "missing dependency errors in --only mode" <<'UPDATES_TEST_CASE'
set +e
UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --dry-run --only mas >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
	echo "Expected failure when --only mas but mas is missing" >&2
	exit 1
fi

UPDATES_TEST_CASE

run_test "--brew-mode greedy enables brew upgrade (greedy) on macOS" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

run_test "--only mas runs even when opt-in by default" <<'UPDATES_TEST_CASE'
# shellcheck disable=SC2016
write_stub mas 'echo "mas $*" >>"$CALL_LOG"'
: >"$CALL_LOG"
"$SCRIPT" --only mas --no-emoji >/dev/null
grep -q '^mas upgrade$' "$CALL_LOG"

UPDATES_TEST_CASE

run_test "--only macos runs even when opt-in by default" <<'UPDATES_TEST_CASE'
: >"$CALL_LOG"
"$SCRIPT" --only macos --no-emoji >/dev/null
grep -q '^softwareupdate -l$' "$CALL_LOG"

UPDATES_TEST_CASE

run_test "--full enables brew casks + mas + macos" <<'UPDATES_TEST_CASE'
# shellcheck disable=SC2016
write_stub mas 'echo "mas $*" >>"$CALL_LOG"'
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

UPDATES_TEST_CASE

setup_python_guard_fixture() {
	rm -f "${stub_bin}/py" "${stub_bin}/python3"

	python_user_base="${tmp_dir}/python-userbase"
	python_site="$(
		PYTHONUSERBASE="$python_user_base" "$SYSTEM_PYTHON3" - <<'PY'
import site

print(site.getusersitepackages())
PY
	)"
	python_system_site="${tmp_dir}/python-system-site"
	# Referenced by heredoc-backed test bodies evaluated through run_test.
	# shellcheck disable=SC2034
	python_path="${python_site}:${python_system_site}"
	mkdir -p "${python_site}/idna-3.1.dist-info" "${python_site}/pyelftools-0.31.dist-info" "${python_site}/unicorn-2.1.2.dist-info" "${python_site}/pwntools-4.15.0.dist-info" "${python_site}/legacyowner-1.0.dist-info" "${python_site}/legacydep-1.0.dist-info" "${python_system_site}/chardet-5.2.0.dist-info"
	cat >"${python_site}/idna-3.1.dist-info/METADATA" <<'EOF'
Metadata-Version: 2.1
Name: idna
Version: 3.1
EOF
	cat >"${python_site}/pyelftools-0.31.dist-info/METADATA" <<'EOF'
Metadata-Version: 2.1
Name: pyelftools
Version: 0.31
EOF
	cat >"${python_site}/unicorn-2.1.2.dist-info/METADATA" <<'EOF'
Metadata-Version: 2.1
Name: unicorn
Version: 2.1.2
EOF
	cat >"${python_site}/pwntools-4.15.0.dist-info/METADATA" <<'EOF'
Metadata-Version: 2.1
Name: pwntools
Version: 4.15.0
Requires-Dist: unicorn!=2.1.3,!=2.1.4,>=2.0.1
EOF
	cat >"${python_site}/legacyowner-1.0.dist-info/METADATA" <<'EOF'
Metadata-Version: 2.1
Name: legacyowner
Version: 1.0
Requires-Dist: legacydep<2
EOF
	cat >"${python_site}/legacydep-1.0.dist-info/METADATA" <<'EOF'
Metadata-Version: 2.1
Name: legacydep
Version: 1.0
EOF
	cat >"${python_system_site}/chardet-5.2.0.dist-info/METADATA" <<'EOF'
Metadata-Version: 2.1
Name: chardet
Version: 5.2.0
EOF

	# shellcheck disable=SC2016
	write_stub python '
if [ "${1:-}" = "-c" ]; then
	code="${2:-}"
	if echo "$code" | grep -q "EXTERNALLY-MANAGED"; then
		echo "1"
		exit 0
	fi
	exec "$SYSTEM_PYTHON3" "$@"
fi

if [ "${1:-}" = "-" ]; then
	exec "$SYSTEM_PYTHON3" "$@"
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
		if [ "$cmd" = "install" ] && [ "${1:-}" = "--help" ]; then
			echo "  --dry-run"
			if [ "${PYTHON_GUARD_NO_REPORT_HELP:-0}" != "1" ]; then
				echo "  --report <file>"
			fi
			if [ "${PYTHON_GUARD_NO_BREAK_HELP:-0}" != "1" ]; then
				echo "  --break-system-packages"
			fi
			exit 0
	fi
		case "$cmd" in
		list)
			echo "python -m pip list $*" >>"$CALL_LOG"
			if [ "${PYTHON_GUARD_PLANNED_OWNER_CONFLICT:-0}" = "1" ]; then
				echo "[{\"name\":\"legacyowner\",\"version\":\"1.0\",\"latest_version\":\"2.0\"},{\"name\":\"legacydep\",\"version\":\"1.0\",\"latest_version\":\"2.0\"}]"
				exit 0
			fi
			echo "[{\"name\":\"idna\",\"version\":\"3.1\",\"latest_version\":\"3.11\"},{\"name\":\"pyelftools\",\"version\":\"0.31\",\"latest_version\":\"0.32\"},{\"name\":\"unicorn\",\"version\":\"2.1.2\",\"latest_version\":\"2.1.4\"}]"
			exit 0
			;;
	install)
		echo "python -m pip install $*" >>"$CALL_LOG"
		dry_run=0
		report=""
		pkg=""
		pkgs=""
		while [ $# -gt 0 ]; do
			case "$1" in
			--dry-run)
				dry_run=1
				shift
				;;
			--report)
				report="$2"
				shift 2
				;;
			-*)
				shift
				;;
			*)
				pkg="$1"
				pkgs="${pkgs}${pkgs:+ }$1"
				shift
				;;
			esac
		done
			if [ "$dry_run" -eq 1 ]; then
				case "$pkgs" in
				idna)
					if [ "${PYTHON_GUARD_SYSTEM_ONLY_DEP:-0}" = "1" ]; then
						cat >"$report" <<JSON
{"install":[{"download_info":{"url":"https://example.invalid/idna-3.11-py3-none-any.whl"},"metadata":{"name":"idna","version":"3.11","requires_dist":["chardet>=5"]}},{"download_info":{"url":"https://example.invalid/chardet-5.2.0-py3-none-any.whl"},"metadata":{"name":"chardet","version":"5.2.0"}}]}
JSON
						exit 0
					fi
					cat >"$report" <<JSON
{"install":[{"download_info":{"url":"https://example.invalid/idna-3.11-py3-none-any.whl"},"metadata":{"name":"idna","version":"3.11"}}]}
JSON
				exit 0
				;;
			pyelftools)
				cat >"$report" <<JSON
{"install":[{"download_info":{"url":"https://example.invalid/pyelftools-0.32-py3-none-any.whl"},"metadata":{"name":"pyelftools","version":"0.32"}}]}
JSON
				exit 0
				;;
				unicorn)
					cat >"$report" <<JSON
{"install":[{"download_info":{"url":"https://example.invalid/unicorn-2.1.4-py3-none-any.whl"},"metadata":{"name":"unicorn","version":"2.1.4"}}]}
JSON
					exit 0
					;;
				legacyowner)
					cat >"$report" <<JSON
{"install":[{"download_info":{"url":"https://example.invalid/legacyowner-2.0-py3-none-any.whl"},"metadata":{"name":"legacyowner","version":"2.0","requires_dist":["legacydep>=2"]}},{"download_info":{"url":"https://example.invalid/legacydep-2.0-py3-none-any.whl"},"metadata":{"name":"legacydep","version":"2.0"}}]}
JSON
					exit 0
					;;
				legacydep)
					cat >"$report" <<JSON
{"install":[{"download_info":{"url":"https://example.invalid/legacydep-2.0-py3-none-any.whl"},"metadata":{"name":"legacydep","version":"2.0"}}]}
JSON
					exit 0
					;;
				"idna pyelftools")
					if [ "${PYTHON_GUARD_COMBINED_CONFLICT:-0}" = "1" ]; then
						cat >"$report" <<JSON
{"install":[{"download_info":{"url":"https://example.invalid/idna-3.11-py3-none-any.whl"},"metadata":{"name":"idna","version":"3.11"}},{"download_info":{"url":"https://example.invalid/pyelftools-0.32-py3-none-any.whl"},"metadata":{"name":"pyelftools","version":"0.32"}},{"download_info":{"url":"https://example.invalid/unicorn-2.1.4-py3-none-any.whl"},"metadata":{"name":"unicorn","version":"2.1.4"}}]}
JSON
					exit 0
				fi
				cat >"$report" <<JSON
{"install":[{"download_info":{"url":"https://example.invalid/idna-3.11-py3-none-any.whl"},"metadata":{"name":"idna","version":"3.11"}},{"download_info":{"url":"https://example.invalid/pyelftools-0.32-py3-none-any.whl"},"metadata":{"name":"pyelftools","version":"0.32"}}]}
JSON
					exit 0
					;;
				esac
				echo "unexpected dry-run package set: $pkgs" >&2
				exit 1
			fi
			echo "pip install human stdout"
			exit 0
			;;
		check)
			if [ "$#" -eq 0 ]; then
				echo "python -m pip check" >>"$CALL_LOG"
			else
				echo "python -m pip check $*" >>"$CALL_LOG"
			fi
			if [ "${PYTHON_GUARD_CHECK_FAIL:-0}" = "1" ]; then
				echo "pre-existing system package conflict"
				exit 1
			fi
			if [ "${PYTHON_GUARD_CHECK_PARTIAL_FIX:-0}" = "1" ]; then
				check_count=0
				if [ -n "${PYTHON_GUARD_CHECK_STATE:-}" ] && [ -f "$PYTHON_GUARD_CHECK_STATE" ]; then
					check_count="$(cat "$PYTHON_GUARD_CHECK_STATE")"
				fi
				check_count=$((check_count + 1))
				if [ -n "${PYTHON_GUARD_CHECK_STATE:-}" ]; then
					echo "$check_count" >"$PYTHON_GUARD_CHECK_STATE"
				fi
				if [ "${PYTHON_GUARD_CHECK_VOLATILE_STDERR:-0}" = "1" ]; then
					echo "pip check warning $check_count" >&2
				fi
				echo "pre-existing system package conflict"
				if [ "$check_count" -eq 1 ]; then
					echo "pre-existing package conflict resolved by upgrade"
				fi
				exit 1
			fi
			echo "pip check human stdout"
			exit 0
			;;
	esac
fi

echo "python stub: unexpected args: $*" >&2
exit 1
'
}

run_test "python guards externally-managed user-site upgrades" <<'UPDATES_TEST_CASE'
setup_python_guard_fixture

: >"$CALL_LOG"
python_guard_stderr="${tmp_dir}/python-guard-stderr.log"
PYTHONUSERBASE="$python_user_base" PYTHONPATH="$python_path" "$SCRIPT" --only python --no-emoji >/dev/null 2>"$python_guard_stderr"
grep -q '^python -m pip list --outdated --format=json --user$' "$CALL_LOG"
grep -Eq '^python -m pip install -U --user --break-system-packages --only-binary=:all: --dry-run --report .+ idna$' "$CALL_LOG"
grep -Eq '^python -m pip install -U --user --break-system-packages --only-binary=:all: --dry-run --report .+ pyelftools$' "$CALL_LOG"
grep -Eq '^python -m pip install -U --user --break-system-packages --only-binary=:all: --dry-run --report .+ unicorn$' "$CALL_LOG"
grep -Eq '^python -m pip install -U --user --break-system-packages --only-binary=:all: --dry-run --report .+ idna pyelftools$' "$CALL_LOG"
grep -q '^python -m pip install -U --user --break-system-packages --only-binary=:all: idna pyelftools$' "$CALL_LOG"
grep -q '^python -m pip check$' "$CALL_LOG"
if grep -q '^python -m pip install -U --user --break-system-packages --only-binary=:all: unicorn$' "$CALL_LOG"; then
	echo "Expected guarded Python path to skip unsafe unicorn upgrade" >&2
	exit 1
fi
grep -q '^WARN: python: skipping unicorn: pwntools requires unicorn!=2\.1\.3,!=2\.1\.4,>=2\.0\.1, planned unicorn==2\.1\.4$' "$python_guard_stderr"

UPDATES_TEST_CASE

run_test "python guarded user-site ignores superseded planned-owner requirements" <<'UPDATES_TEST_CASE'
setup_python_guard_fixture
: >"$CALL_LOG"
python_planned_owner_stderr="${tmp_dir}/python-planned-owner-stderr.log"
PYTHON_GUARD_PLANNED_OWNER_CONFLICT=1 PYTHONUSERBASE="$python_user_base" PYTHONPATH="$python_path" "$SCRIPT" --only python --no-emoji >/dev/null 2>"$python_planned_owner_stderr"
grep -Eq '^python -m pip install -U --user --break-system-packages --only-binary=:all: --dry-run --report .+ legacyowner$' "$CALL_LOG"
grep -Eq '^python -m pip install -U --user --break-system-packages --only-binary=:all: --dry-run --report .+ legacydep$' "$CALL_LOG"
grep -q '^python -m pip install -U --user --break-system-packages --only-binary=:all: legacyowner$' "$CALL_LOG"
grep -q '^WARN: python: skipping legacydep: legacyowner requires legacydep<2, planned legacydep==2\.0$' "$python_planned_owner_stderr"
if grep -q '^WARN: python: skipping legacyowner:' "$python_planned_owner_stderr"; then
	echo "Expected guarded Python path to ignore old requirements for packages being upgraded" >&2
	exit 1
fi
if grep -q '^python -m pip install -U --user --break-system-packages --only-binary=:all: legacydep$' "$CALL_LOG"; then
	echo "Expected guarded Python path to install legacydep only through legacyowner plan" >&2
	exit 1
fi

UPDATES_TEST_CASE

run_test "python guarded user-site keeps JSON stdout JSONL-only" <<'UPDATES_TEST_CASE'
setup_python_guard_fixture
: >"$CALL_LOG"
python_guard_json_stdout="${tmp_dir}/python-guard-json-stdout.log"
python_guard_json_stderr="${tmp_dir}/python-guard-json-stderr.log"
PYTHONUSERBASE="$python_user_base" PYTHONPATH="$python_path" "$SCRIPT" --only python --json --no-emoji >"$python_guard_json_stdout" 2>"$python_guard_json_stderr"
"$SYSTEM_PYTHON3" - "$python_guard_json_stdout" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    lines = [line for line in fh.read().splitlines() if line]
assert lines, "expected JSONL stdout"
for line in lines:
    json.loads(line)
PY
if grep -Eq 'pip (install|check) human stdout' "$python_guard_json_stdout"; then
	echo "Expected guarded Python JSON stdout to contain only JSONL" >&2
	exit 1
fi
grep -q '^pip install human stdout$' "$python_guard_json_stderr"
grep -q '^pip check human stdout$' "$python_guard_json_stderr"

UPDATES_TEST_CASE

run_test "python guarded user-site skips system-only dependency installs" <<'UPDATES_TEST_CASE'
setup_python_guard_fixture
: >"$CALL_LOG"
python_system_dep_stderr="${tmp_dir}/python-system-dep-stderr.log"
PYTHON_GUARD_SYSTEM_ONLY_DEP=1 PYTHONUSERBASE="$python_user_base" PYTHONPATH="$python_path" "$SCRIPT" --only python --no-emoji >/dev/null 2>"$python_system_dep_stderr"
grep -q '^WARN: python: skipping idna: would install new package(s): chardet$' "$python_system_dep_stderr"
grep -q '^python -m pip install -U --user --break-system-packages --only-binary=:all: pyelftools$' "$CALL_LOG"
if grep -q '^python -m pip install -U --user --break-system-packages --only-binary=:all: idna$' "$CALL_LOG"; then
	echo "Expected guarded Python path to skip idna when its dependency is system-only" >&2
	exit 1
fi

UPDATES_TEST_CASE

run_test "python guarded user-site tolerates pre-existing pip check failures" <<'UPDATES_TEST_CASE'
setup_python_guard_fixture
: >"$CALL_LOG"
python_check_stdout="${tmp_dir}/python-check-stdout.log"
python_check_stderr="${tmp_dir}/python-check-stderr.log"
PYTHON_GUARD_CHECK_FAIL=1 PYTHONUSERBASE="$python_user_base" PYTHONPATH="$python_path" "$SCRIPT" --only python --no-emoji >"$python_check_stdout" 2>"$python_check_stderr"
grep -q '^WARN: python: pip check still reports pre-existing issues after guarded upgrade$' "$python_check_stderr"
grep -q '^pre-existing system package conflict$' "$python_check_stdout"
check_count="$(grep -c '^python -m pip check$' "$CALL_LOG")"
if [ "$check_count" -ne 2 ]; then
	echo "Expected guarded Python path to run pip check before and after install" >&2
	exit 1
fi

UPDATES_TEST_CASE

run_test "python guarded user-site tolerates partially fixed pip check failures" <<'UPDATES_TEST_CASE'
setup_python_guard_fixture
: >"$CALL_LOG"
python_partial_check_stdout="${tmp_dir}/python-partial-check-stdout.log"
python_partial_check_stderr="${tmp_dir}/python-partial-check-stderr.log"
python_partial_check_state="${tmp_dir}/python-partial-check-state"
rm -f "$python_partial_check_state"
PYTHON_GUARD_CHECK_PARTIAL_FIX=1 PYTHON_GUARD_CHECK_VOLATILE_STDERR=1 PYTHON_GUARD_CHECK_STATE="$python_partial_check_state" PYTHONUSERBASE="$python_user_base" PYTHONPATH="$python_path" "$SCRIPT" --only python --no-emoji >"$python_partial_check_stdout" 2>"$python_partial_check_stderr"
grep -q '^WARN: python: pip check still reports pre-existing issues after guarded upgrade$' "$python_partial_check_stderr"
grep -q '^pre-existing system package conflict$' "$python_partial_check_stdout"
grep -q '^pip check warning 2$' "$python_partial_check_stdout"
if grep -q '^pre-existing package conflict resolved by upgrade$' "$python_partial_check_stdout"; then
	echo "Expected guarded Python path to report only remaining pip check failures" >&2
	exit 1
fi
check_count="$(grep -c '^python -m pip check$' "$CALL_LOG")"
if [ "$check_count" -ne 2 ]; then
	echo "Expected guarded Python path to run pip check before and after partial fix" >&2
	exit 1
fi

UPDATES_TEST_CASE

run_test "python guarded user-site errors when pip lacks dry-run reports" <<'UPDATES_TEST_CASE'
setup_python_guard_fixture
: >"$CALL_LOG"
python_no_report_stderr="${tmp_dir}/python-no-report-stderr.log"
set +e
PYTHON_GUARD_NO_REPORT_HELP=1 PYTHONUSERBASE="$python_user_base" PYTHONPATH="$python_path" "$SCRIPT" --only python --no-emoji >/dev/null 2>"$python_no_report_stderr"
no_report_status=$?
set -e
if [ "$no_report_status" -eq 0 ]; then
	echo "Expected guarded Python path to fail in --only mode when pip lacks --report" >&2
	exit 1
fi
grep -q '^ERROR: python: pip is too old for guarded user-site upgrades (--dry-run --report required)$' "$python_no_report_stderr"
if grep -q -- '--dry-run --report' "$CALL_LOG"; then
	echo "Expected guarded Python path to stop before dry-run reports when pip lacks --report" >&2
	exit 1
fi

UPDATES_TEST_CASE

run_test "python guarded user-site skips when pip lacks dry-run reports outside --only" <<'UPDATES_TEST_CASE'
setup_python_guard_fixture
: >"$CALL_LOG"
python_no_report_skip_stderr="${tmp_dir}/python-no-report-skip-stderr.log"
python_no_report_skip_out="$(
	PYTHON_GUARD_NO_REPORT_HELP=1 PYTHONUSERBASE="$python_user_base" PYTHONPATH="$python_path" "$SCRIPT" --skip brew,shell,linux,node,uv,mas,pipx,rustup,claude,mise,go,macos,repos,bun,pi --no-emoji --no-color 2>"$python_no_report_skip_stderr"
)"
echo "$python_no_report_skip_out" | grep -q '^==> python END (SKIP)'
grep -q '^WARN: python: skipping guarded user-site upgrades: pip does not support --dry-run --report$' "$python_no_report_skip_stderr"
if grep -q -- '--dry-run --report' "$CALL_LOG"; then
	echo "Expected non-only guarded Python path to skip before dry-run reports when pip lacks --report" >&2
	exit 1
fi

UPDATES_TEST_CASE

run_test "python guarded user-site omits break-system flag when pip lacks it" <<'UPDATES_TEST_CASE'
setup_python_guard_fixture
: >"$CALL_LOG"
python_no_break_stderr="${tmp_dir}/python-no-break-stderr.log"
PYTHON_GUARD_NO_BREAK_HELP=1 PYTHONUSERBASE="$python_user_base" PYTHONPATH="$python_path" "$SCRIPT" --only python --no-emoji >/dev/null 2>"$python_no_break_stderr"
grep -Eq '^python -m pip install -U --user --only-binary=:all: --dry-run --report .+ idna$' "$CALL_LOG"
grep -Eq '^python -m pip install -U --user --only-binary=:all: --dry-run --report .+ idna pyelftools$' "$CALL_LOG"
grep -q '^python -m pip install -U --user --only-binary=:all: idna pyelftools$' "$CALL_LOG"
if grep -q -- '--break-system-packages' "$CALL_LOG"; then
	echo "Expected guarded Python path to omit unsupported --break-system-packages" >&2
	exit 1
fi

UPDATES_TEST_CASE

run_test "python skips install when combined guard plan is unsafe" <<'UPDATES_TEST_CASE'
setup_python_guard_fixture
: >"$CALL_LOG"
python_combined_stderr="${tmp_dir}/python-combined-stderr.log"
PYTHON_GUARD_COMBINED_CONFLICT=1 PYTHONUSERBASE="$python_user_base" PYTHONPATH="$python_path" "$SCRIPT" --only python --no-emoji >/dev/null 2>"$python_combined_stderr"
grep -Eq '^python -m pip install -U --user --break-system-packages --only-binary=:all: --dry-run --report .+ idna pyelftools$' "$CALL_LOG"
if grep -q '^python -m pip install -U --user --break-system-packages --only-binary=:all: idna pyelftools$' "$CALL_LOG"; then
	echo "Expected guarded Python path to skip unsafe combined package set" >&2
	exit 1
fi
if grep -q '^python -m pip check$' "$CALL_LOG"; then
	echo "Expected guarded Python path to skip pip check when combined dry-run is unsafe" >&2
	exit 1
fi
grep -q '^WARN: python: skipping guarded user-site install: pwntools requires unicorn!=2\.1\.3,!=2\.1\.4,>=2\.0\.1, planned unicorn==2\.1\.4$' "$python_combined_stderr"

UPDATES_TEST_CASE

run_test "python break-system-packages opt-in (pip-force)" <<'UPDATES_TEST_CASE'
setup_python_guard_fixture
: >"$CALL_LOG"
"$SCRIPT" --only python --pip-force --no-emoji >/dev/null
grep -q '^python -m pip list --outdated --format=json$' "$CALL_LOG"
grep -q '^python -m pip install -U --break-system-packages idna$' "$CALL_LOG"
grep -q '^python -m pip install -U --break-system-packages pyelftools$' "$CALL_LOG"
grep -q '^python -m pip install -U --break-system-packages unicorn$' "$CALL_LOG"

UPDATES_TEST_CASE

run_test "linux module (apt-get) runs in non-interactive mode" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

run_test "shell module updates Oh My Zsh repos" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

run_test "uv module runs" <<'UPDATES_TEST_CASE'
: >"$CALL_LOG"
"$SCRIPT" --only uv --no-emoji >/dev/null
grep -q '^uv self update$' "$CALL_LOG"
grep -q '^uv tool upgrade --all$' "$CALL_LOG"

UPDATES_TEST_CASE

run_test "bun module runs global upgrades" <<'UPDATES_TEST_CASE'
: >"$CALL_LOG"
"$SCRIPT" --only bun --no-emoji >/dev/null
grep -q '^bun update -g$' "$CALL_LOG"

UPDATES_TEST_CASE

run_test "mise module runs" <<'UPDATES_TEST_CASE'
: >"$CALL_LOG"
"$SCRIPT" --only mise --no-emoji >/dev/null
grep -q '^mise self-update$' "$CALL_LOG"
grep -q '^mise upgrade$' "$CALL_LOG"

UPDATES_TEST_CASE

run_test "go module requires GO_BINARIES in --only mode" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

run_test "go module installs configured binaries (defaults to @latest)" <<'UPDATES_TEST_CASE'
go_home="${tmp_dir}/home-go"
mkdir -p "$go_home"
cat >"${go_home}/.updatesrc" <<EOF
GO_BINARIES="golang.org/x/tools/gopls,github.com/go-delve/delve/cmd/dlv@v1.2.3"
EOF
: >"$CALL_LOG"
HOME="$go_home" "$SCRIPT" --only go --no-emoji --no-color >/dev/null
grep -q '^go install golang.org/x/tools/gopls@latest$' "$CALL_LOG"
grep -q '^go install github.com/go-delve/delve/cmd/dlv@v1.2.3$' "$CALL_LOG"

UPDATES_TEST_CASE

run_test "repos module updates git repos" <<'UPDATES_TEST_CASE'
repos_home="${tmp_dir}/home-repos"
repos_dir="${repos_home}/GitRepos"
mkdir -p "${repos_dir}/aman-claude-code-setup"
mkdir -p "${repos_dir}/aman-codex-setup"
mkdir -p "${repos_dir}/aman-claude-code-setup/.git"
mkdir -p "${repos_dir}/aman-codex-setup/.git"
write_git_ready_stub
: >"$CALL_LOG"
HOME="$repos_home" "$SCRIPT" --only repos --non-interactive --no-emoji --no-color >/dev/null 2>&1
grep -q "git -C ${repos_dir}/aman-claude-code-setup pull --ff-only" "$CALL_LOG"
grep -q "git -C ${repos_dir}/aman-codex-setup pull --ff-only" "$CALL_LOG"

UPDATES_TEST_CASE

run_test "repos module respects REPOS_DIR config" <<'UPDATES_TEST_CASE'
repos_config_home="${tmp_dir}/home-repos-config"
repos_config_dir="${repos_config_home}/custom-repos"
mkdir -p "${repos_config_dir}/aman-test-setup"
mkdir -p "${repos_config_dir}/aman-test-setup/.git"
cat >"${repos_config_home}/.updatesrc" <<UPDATESRC
REPOS_DIR=${repos_config_dir}
UPDATESRC
write_git_ready_stub
: >"$CALL_LOG"
HOME="$repos_config_home" "$SCRIPT" --only repos --non-interactive --no-emoji --no-color >/dev/null 2>&1
grep -q "git -C ${repos_config_dir}/aman-test-setup pull --ff-only" "$CALL_LOG"

UPDATES_TEST_CASE

run_test "repos module skips when no repos exist" <<'UPDATES_TEST_CASE'
repos_empty_home="${tmp_dir}/home-repos-empty"
mkdir -p "${repos_empty_home}/GitRepos"
out="$(HOME="$repos_empty_home" "$SCRIPT" --only repos --non-interactive --no-emoji --no-color 2>&1)" || true
echo "$out" | grep -q 'repos END (SKIP)'

UPDATES_TEST_CASE

run_test "repos module dry-run shows post-pull script" <<'UPDATES_TEST_CASE'
repos_dry_home="${tmp_dir}/home-repos-dry"
repos_dry_dir="${repos_dry_home}/GitRepos"
mkdir -p "${repos_dry_dir}/aman-dry-setup/.git"
mkdir -p "${repos_dry_dir}/aman-dry-setup/scripts"
printf '#!/bin/bash\necho ok\n' >"${repos_dry_dir}/aman-dry-setup/scripts/update.sh"
chmod +x "${repos_dry_dir}/aman-dry-setup/scripts/update.sh"
out="$(HOME="$repos_dry_home" "$SCRIPT" --dry-run --only repos --no-emoji --no-color 2>&1)"
echo "$out" | grep -q "DRY RUN: git -C ${repos_dry_dir}/aman-dry-setup pull --ff-only"
echo "$out" | grep -q "DRY RUN: (cd ${repos_dry_dir}/aman-dry-setup && ./scripts/update.sh)"

UPDATES_TEST_CASE

run_test "repos module preflights Git state and updates only eligible repos" <<'UPDATES_TEST_CASE'
git_sync_home="${tmp_dir}/home-repos-git-sync"
git_sync_dir="${git_sync_home}/GitRepos"
git_sync_fixtures="${tmp_dir}/repos-git-fixtures"
mkdir -p "$git_sync_dir" "$git_sync_fixtures"
create_tracked_git_repo "${git_sync_dir}/aman-clean-setup" "$git_sync_fixtures" clean
mkdir -p "${git_sync_dir}/aman-clean-setup/scripts"
cat >"${git_sync_dir}/aman-clean-setup/scripts/update.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ran\n' >>"$POST_PULL_MARKER"
EOF
chmod +x "${git_sync_dir}/aman-clean-setup/scripts/update.sh"
git_test_commit "${git_sync_dir}/aman-clean-setup" "add post-pull"
"$SYSTEM_GIT" -C "${git_sync_dir}/aman-clean-setup" push -q
printf 'untracked files do not make a tracked worktree dirty\n' >"${git_sync_dir}/aman-clean-setup/untracked.txt"

mkdir -p "${git_sync_dir}/aman-local-only-setup"
"$SYSTEM_GIT" init -q "${git_sync_dir}/aman-local-only-setup"
"$SYSTEM_GIT" -C "${git_sync_dir}/aman-local-only-setup" checkout -q -b local-work
printf 'local\n' >"${git_sync_dir}/aman-local-only-setup/tracked.txt"
git_test_commit "${git_sync_dir}/aman-local-only-setup" "local only"

create_tracked_git_repo "${git_sync_dir}/aman-dirty-setup" "$git_sync_fixtures" dirty
printf 'dirty\n' >>"${git_sync_dir}/aman-dirty-setup/tracked.txt"

create_tracked_git_repo "${git_sync_dir}/aman-detached-setup" "$git_sync_fixtures" detached
"$SYSTEM_GIT" -C "${git_sync_dir}/aman-detached-setup" checkout -q --detach

cat >"${git_sync_home}/.updatesrc" <<EOF
REPOS_DIR=${git_sync_dir}
EOF
post_pull_marker="${tmp_dir}/post-pull-marker"
git_sync_stderr="${tmp_dir}/repos-git-sync-stderr.log"
out="$(PATH="$BASE_PATH" HOME="$git_sync_home" POST_PULL_MARKER="$post_pull_marker" "$SCRIPT" --only repos --non-interactive --no-emoji --no-color 2>"$git_sync_stderr")"
echo "$out" | grep -q '^==> repos END (OK)'
grep -q '^ran$' "$post_pull_marker"
grep -q 'aman-local-only-setup.*no upstream' "$git_sync_stderr"
grep -q 'aman-dirty-setup.*uncommitted changes' "$git_sync_stderr"
grep -q 'aman-detached-setup.*detached HEAD' "$git_sync_stderr"

UPDATES_TEST_CASE

run_test "repos module skips when every Git repo is ineligible" <<'UPDATES_TEST_CASE'
git_all_skip_home="${tmp_dir}/home-repos-all-skip"
git_all_skip_dir="${git_all_skip_home}/GitRepos"
mkdir -p "${git_all_skip_dir}/aman-local-only-setup"
"$SYSTEM_GIT" init -q "${git_all_skip_dir}/aman-local-only-setup"
"$SYSTEM_GIT" -C "${git_all_skip_dir}/aman-local-only-setup" checkout -q -b local-work
printf 'local\n' >"${git_all_skip_dir}/aman-local-only-setup/tracked.txt"
git_test_commit "${git_all_skip_dir}/aman-local-only-setup" "local only"
cat >"${git_all_skip_home}/.updatesrc" <<EOF
REPOS_DIR=${git_all_skip_dir}
EOF
out="$(PATH="$BASE_PATH" HOME="$git_all_skip_home" "$SCRIPT" --only repos --non-interactive --no-emoji --no-color 2>"${tmp_dir}/repos-all-skip-stderr.log")"
echo "$out" | grep -q '^==> repos END (SKIP)'

UPDATES_TEST_CASE

run_test "repos module fails on diverged history" <<'UPDATES_TEST_CASE'
git_diverged_home="${tmp_dir}/home-repos-diverged"
git_diverged_dir="${git_diverged_home}/GitRepos"
git_diverged_fixtures="${tmp_dir}/repos-diverged-fixtures"
mkdir -p "$git_diverged_dir" "$git_diverged_fixtures"
create_tracked_git_repo "${git_diverged_dir}/aman-diverged-setup" "$git_diverged_fixtures" diverged
printf 'local\n' >>"${git_diverged_dir}/aman-diverged-setup/tracked.txt"
git_test_commit "${git_diverged_dir}/aman-diverged-setup" "local commit"
"$SYSTEM_GIT" clone -q "${git_diverged_fixtures}/diverged.git" "${git_diverged_fixtures}/diverged-other"
printf 'remote\n' >>"${git_diverged_fixtures}/diverged-other/tracked.txt"
git_test_commit "${git_diverged_fixtures}/diverged-other" "remote commit"
"$SYSTEM_GIT" -C "${git_diverged_fixtures}/diverged-other" push -q
"$SYSTEM_GIT" -C "${git_diverged_dir}/aman-diverged-setup" fetch -q origin
cat >"${git_diverged_home}/.updatesrc" <<EOF
REPOS_DIR=${git_diverged_dir}
EOF
set +e
out="$(PATH="$BASE_PATH" HOME="$git_diverged_home" "$SCRIPT" --only repos --non-interactive --no-emoji --no-color 2>"${tmp_dir}/repos-diverged-stderr.log")"
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
	echo "Expected diverged repos module to fail (got $rc)" >&2
	exit 1
fi
echo "$out" | grep -q '^==> repos END (FAIL)'
grep -q 'aman-diverged-setup.*diverged' "${tmp_dir}/repos-diverged-stderr.log"

UPDATES_TEST_CASE

run_test "repos module fails when an eligible Git pull fails" <<'UPDATES_TEST_CASE'
git_pull_fail_home="${tmp_dir}/home-repos-pull-fail"
git_pull_fail_dir="${git_pull_fail_home}/GitRepos"
git_pull_fail_fixtures="${tmp_dir}/repos-pull-fail-fixtures"
mkdir -p "$git_pull_fail_dir" "$git_pull_fail_fixtures"
create_tracked_git_repo "${git_pull_fail_dir}/aman-pull-fail-setup" "$git_pull_fail_fixtures" pull-fail
mv "${git_pull_fail_fixtures}/pull-fail.git" "${git_pull_fail_fixtures}/pull-fail.git.offline"
cat >"${git_pull_fail_home}/.updatesrc" <<EOF
REPOS_DIR=${git_pull_fail_dir}
EOF
set +e
out="$(PATH="$BASE_PATH" HOME="$git_pull_fail_home" "$SCRIPT" --only repos --non-interactive --no-emoji --no-color 2>"${tmp_dir}/repos-pull-fail-stderr.log")"
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
	echo "Expected failed Git pull to fail repos module (got $rc)" >&2
	exit 1
fi
echo "$out" | grep -q '^==> repos END (FAIL)'
grep -q 'aman-pull-fail-setup.*pull --ff-only failed' "${tmp_dir}/repos-pull-fail-stderr.log"

UPDATES_TEST_CASE

run_test "repos module fails when post-pull action fails" <<'UPDATES_TEST_CASE'
git_post_fail_home="${tmp_dir}/home-repos-post-fail"
git_post_fail_dir="${git_post_fail_home}/GitRepos"
git_post_fail_fixtures="${tmp_dir}/repos-post-fail-fixtures"
mkdir -p "$git_post_fail_dir" "$git_post_fail_fixtures"
create_tracked_git_repo "${git_post_fail_dir}/aman-post-fail-setup" "$git_post_fail_fixtures" post-fail
mkdir -p "${git_post_fail_dir}/aman-post-fail-setup/scripts"
printf '#!/usr/bin/env bash\nexit 9\n' >"${git_post_fail_dir}/aman-post-fail-setup/scripts/update.sh"
chmod +x "${git_post_fail_dir}/aman-post-fail-setup/scripts/update.sh"
git_test_commit "${git_post_fail_dir}/aman-post-fail-setup" "add failing post-pull"
"$SYSTEM_GIT" -C "${git_post_fail_dir}/aman-post-fail-setup" push -q
cat >"${git_post_fail_home}/.updatesrc" <<EOF
REPOS_DIR=${git_post_fail_dir}
EOF
set +e
out="$(PATH="$BASE_PATH" HOME="$git_post_fail_home" "$SCRIPT" --only repos --non-interactive --no-emoji --no-color 2>"${tmp_dir}/repos-post-fail-stderr.log")"
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
	echo "Expected failing post-pull action to fail repos module (got $rc)" >&2
	exit 1
fi
echo "$out" | grep -q '^==> repos END (FAIL)'
grep -q 'post-pull action failed.*aman-post-fail-setup' "${tmp_dir}/repos-post-fail-stderr.log"

UPDATES_TEST_CASE

run_test "removed self-update repo override errors" <<'UPDATES_TEST_CASE'
assert_self_update_override_rejected 'fake/repo' 'non-empty'
assert_self_update_override_rejected '' 'empty'

UPDATES_TEST_CASE

run_test "Unix self-update never trusts forged newer-version cache metadata" <<'UPDATES_TEST_CASE'
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
create_self_update_fixture "$self_update_cache_fixture" "$SELF_UPDATE_NEXT_TEST_VERSION"
write_self_update_cache_with_metadata "${self_update_cache_xdg}/updates/self-update-amanthanvi_updates.cache" "$(date +%s)" "v${SELF_UPDATE_NEXT_TEST_VERSION}" "$self_update_cache_fixture"
sed -i.bak 's#https://example.invalid/#https://forged.invalid/#g' "${self_update_cache_xdg}/updates/self-update-amanthanvi_updates.cache"
rm -f "${self_update_cache_xdg}/updates/self-update-amanthanvi_updates.cache.bak"
: >"$self_update_cache_http_log"
: >"$CALL_LOG"
out="$(CI='' UPDATES_SELF_UPDATE=1 XDG_CACHE_HOME="$self_update_cache_xdg" SELF_UPDATE_FIXTURE_DIR="$self_update_cache_fixture" SELF_UPDATE_CALL_LOG="$self_update_cache_http_log" PATH="${self_update_cache_bin}:${BASE_PATH}" "$self_update_cache_script" --only brew --no-emoji --no-color 2>&1)"
grep -q '^curl https://api.github.com/repos/amanthanvi/updates/releases/latest$' "$self_update_cache_http_log"
if grep -q 'https://forged.invalid/' "$self_update_cache_http_log"; then
	echo "Expected forged cached URLs to be ignored" >&2
	cat "$self_update_cache_http_log" >&2
	exit 1
fi
grep -q '^curl https://example.invalid/updates-release.json$' "$self_update_cache_http_log"
cache_file="${self_update_cache_xdg}/updates/self-update-amanthanvi_updates.cache"
[ "$(wc -l <"$cache_file" | tr -d ' ')" -eq 2 ]
grep -q '^checked_at=[0-9][0-9]*$' "$cache_file"
grep -q "^latest_tag=v${SELF_UPDATE_NEXT_TEST_VERSION}$" "$cache_file"
if [ "$("$self_update_cache_script" --version)" != "$SELF_UPDATE_NEXT_TEST_VERSION" ]; then
	echo "Expected live canonical metadata to authorize the newer version" >&2
	exit 1
fi
grep -q '^brew update$' "$CALL_LOG"

UPDATES_TEST_CASE

run_test "Unix self-update fresh newer-version tag-only cache fetches live metadata" <<'UPDATES_TEST_CASE'
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
create_self_update_fixture "$self_update_digest_fixture" "$SELF_UPDATE_NEXT_TEST_VERSION" 'unsupported-digest'
printf 'checked_at=%s\nlatest_tag=%s\n' "$(date +%s)" "v${SELF_UPDATE_NEXT_TEST_VERSION}" >"${self_update_digest_xdg}/updates/self-update-amanthanvi_updates.cache"
: >"$self_update_digest_http_log"
: >"$CALL_LOG"
out="$(CI='' UPDATES_SELF_UPDATE=1 XDG_CACHE_HOME="$self_update_digest_xdg" SELF_UPDATE_FIXTURE_DIR="$self_update_digest_fixture" SELF_UPDATE_CALL_LOG="$self_update_digest_http_log" PATH="${self_update_digest_bin}:${BASE_PATH}" "$self_update_digest_script" --only brew --no-emoji --no-color 2>&1)"
echo "$out" | grep -q 'self-update manifest digest missing or unsupported; continuing'
grep -q '^curl https://api.github.com/repos/amanthanvi/updates/releases/latest$' "$self_update_digest_http_log"
grep -q '^curl https://example.invalid/updates-release.json$' "$self_update_digest_http_log"
if [ "$("$self_update_digest_script" --version)" != "$SELF_UPDATE_CURRENT_TEST_VERSION" ]; then
	echo "Expected unsupported digest metadata to leave installed version unchanged" >&2
	exit 1
fi

UPDATES_TEST_CASE

run_test "Unix self-update skips when release manifest is invalid" <<'UPDATES_TEST_CASE'
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
create_self_update_fixture "$self_update_manifest_fixture" "$SELF_UPDATE_NEXT_TEST_VERSION" 'invalid-manifest'
: >"$self_update_manifest_http_log"
: >"$CALL_LOG"
out="$(CI='' UPDATES_SELF_UPDATE=1 XDG_CACHE_HOME="$self_update_manifest_xdg" SELF_UPDATE_FIXTURE_DIR="$self_update_manifest_fixture" SELF_UPDATE_CALL_LOG="$self_update_manifest_http_log" PATH="${self_update_manifest_bin}:${BASE_PATH}" "$self_update_manifest_script" --only brew --no-emoji --no-color 2>&1)"
echo "$out" | grep -q 'self-update manifest is invalid; continuing'
grep -q '^curl https://example.invalid/updates$' "$self_update_manifest_http_log"
if [ "$("$self_update_manifest_script" --version)" != "$SELF_UPDATE_CURRENT_TEST_VERSION" ]; then
	echo "Expected invalid manifest to leave installed version unchanged" >&2
	exit 1
fi

UPDATES_TEST_CASE

run_test "Unix self-update works without Python or Node parsers" <<'UPDATES_TEST_CASE'
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
write_stub_to_dir "$self_update_fallback_bin" python 'exit 127'
write_stub_to_dir "$self_update_fallback_bin" python3 'exit 127'
write_stub_to_dir "$self_update_fallback_bin" node 'exit 127'
write_self_update_curl_stub "$self_update_fallback_bin"
create_self_update_fixture "$self_update_fallback_fixture" "$SELF_UPDATE_NEXT_TEST_VERSION"
: >"$self_update_fallback_http_log"
: >"$CALL_LOG"
out="$(CI='' UPDATES_SELF_UPDATE=1 XDG_CACHE_HOME="$self_update_fallback_xdg" SELF_UPDATE_FIXTURE_DIR="$self_update_fallback_fixture" SELF_UPDATE_CALL_LOG="$self_update_fallback_http_log" PATH="${self_update_fallback_bin}:${BASE_PATH}" "$self_update_fallback_script" --only brew --no-emoji --no-color 2>&1)"
grep -q '^curl https://api.github.com/repos/amanthanvi/updates/releases/latest$' "$self_update_fallback_http_log"
grep -q '^curl https://example.invalid/updates-release.json$' "$self_update_fallback_http_log"
grep -q '^curl https://example.invalid/updates$' "$self_update_fallback_http_log"
if [ "$("$self_update_fallback_script" --version)" != "$SELF_UPDATE_NEXT_TEST_VERSION" ]; then
	echo "Expected shell-only self-update fallback to install version ${SELF_UPDATE_NEXT_TEST_VERSION}" >&2
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
	create_self_update_fixture "$self_update_node_fixture" "$SELF_UPDATE_NEXT_TEST_VERSION"
	: >"$self_update_node_http_log"
	: >"$CALL_LOG"
	out="$(CI='' UPDATES_SELF_UPDATE=1 XDG_CACHE_HOME="$self_update_node_xdg" SELF_UPDATE_FIXTURE_DIR="$self_update_node_fixture" SELF_UPDATE_CALL_LOG="$self_update_node_http_log" PATH="${self_update_node_bin}:${BASE_PATH}" "$self_update_node_script" --only brew --no-emoji --no-color 2>&1)"
	if [ "$("$self_update_node_script" --version)" != "$SELF_UPDATE_NEXT_TEST_VERSION" ]; then
		echo "Expected node-only self-update parsing to preserve bootstrap_min=0 and install version ${SELF_UPDATE_NEXT_TEST_VERSION}" >&2
		echo "$out" >&2
		exit 1
	fi
	grep -q '^brew update$' "$CALL_LOG"
fi

if command -v perl >/dev/null 2>&1; then
	echo "Test: shell JSON unescape handles standard escapes"
	actual="$(
		TEST_SCRIPT="$SCRIPT" bash <<'EOF'
set -e
probe="$(mktemp)"
trap 'rm -f "$probe"' EXIT
sed '/^ORIGINAL_ARGS=(/,$d' "$TEST_SCRIPT" >"$probe"
. "$probe"
self_update_json_unescape 'line\npath\u002Ffile\tquote:\"'
EOF
	)"
	expected="$(printf 'line\npath/file\tquote:"')"
	if [ "$actual" != "$expected" ]; then
		echo "Expected shell JSON unescape helper to decode standard escapes" >&2
		printf 'expected: [%s]\n' "$expected" >&2
		printf 'actual:   [%s]\n' "$actual" >&2
		exit 1
	fi
fi

UPDATES_TEST_CASE

run_test "config BOM is tolerated" <<'UPDATES_TEST_CASE'
config_home_bom="${tmp_dir}/home-config-bom"
mkdir -p "$config_home_bom"
printf '\357\273\277BREW_MODE=greedy\n' >"${config_home_bom}/.updatesrc"
out="$(HOME="$config_home_bom" "$SCRIPT" --dry-run --only brew --no-emoji --no-color)"
echo "$out" | grep -q '^DRY RUN: brew upgrade --greedy$'

UPDATES_TEST_CASE

run_test "USERPROFILE fallback finds config when HOME is empty" <<'UPDATES_TEST_CASE'
config_home_userprofile="${tmp_dir}/home-config-userprofile"
mkdir -p "$config_home_userprofile"
cat >"${config_home_userprofile}/.updatesrc" <<EOF
BREW_MODE=greedy
EOF
out="$(HOME="" USERPROFILE="$config_home_userprofile" "$SCRIPT" --dry-run --only brew --no-emoji --no-color)"
echo "$out" | grep -q '^DRY RUN: brew upgrade --greedy$'

UPDATES_TEST_CASE

run_test "pipx module logs correct commands" <<'UPDATES_TEST_CASE'
write_stub uname 'echo Darwin'
write_git_ready_stub
: >"$CALL_LOG"
"$SCRIPT" --only pipx --no-emoji >/dev/null
grep -q '^pipx upgrade-all$' "$CALL_LOG"

UPDATES_TEST_CASE

run_test "rustup module logs correct commands" <<'UPDATES_TEST_CASE'
: >"$CALL_LOG"
"$SCRIPT" --only rustup --no-emoji >/dev/null
grep -q '^rustup update$' "$CALL_LOG"

UPDATES_TEST_CASE

run_test "claude module logs correct commands" <<'UPDATES_TEST_CASE'
: >"$CALL_LOG"
"$SCRIPT" --only claude --no-emoji >/dev/null
grep -q '^claude update$' "$CALL_LOG"

UPDATES_TEST_CASE

run_test "pi module logs correct commands" <<'UPDATES_TEST_CASE'
: >"$CALL_LOG"
"$SCRIPT" --only pi --no-emoji >/dev/null
grep -q '^pi update$' "$CALL_LOG"

UPDATES_TEST_CASE

run_test "empty ncu output means node module reports up-to-date" <<'UPDATES_TEST_CASE'
rm -f "${stub_bin}/python" "${stub_bin}/python3"
write_ncu_stub '{}'
out="$("$SCRIPT" --only node --no-emoji --no-color)"
echo "$out" | grep -q 'All global npm packages are up-to-date'
write_ncu_stub '{"npm":"11.7.0"}'

UPDATES_TEST_CASE

run_test "node requests only upgrades compatible with the active Node engine" <<'UPDATES_TEST_CASE'
: >"$CALL_LOG"
out="$("$SCRIPT" --only node --no-emoji --no-color)"
echo "$out" | grep -q '^==> node END (OK)'
grep -q '^ncu -g --enginesNode --jsonUpgraded$' "$CALL_LOG"

UPDATES_TEST_CASE

run_test "node rejects an engine-incompatible candidate returned by ncu" <<'UPDATES_TEST_CASE'
write_ncu_stub '{"npm":"12.0.1","example-cli":"2.0.0"}'
# shellcheck disable=SC2016
write_stub npm '
echo "npm $*" >>"$CALL_LOG"
case " $* " in
*" --dry-run --ignore-scripts --engine-strict --loglevel=error -- npm@12.0.1 "*)
	echo "npm error code EBADENGINE" >&2
	echo "npm error notsup Required: {\"node\":\"^24.15.0\"}" >&2
	echo "npm error notsup Actual: {\"node\":\"v24.13.0\"}" >&2
	exit 1
	;;
*" install -g -- npm@12.0.1 "*)
	echo "Engine-incompatible npm candidate must be rejected before install" >&2
	exit 1
	;;
esac
'
: >"$CALL_LOG"
node_filter_stderr="${tmp_dir}/node-filter-stderr.log"
out="$("$SCRIPT" --only node --no-emoji --no-color 2>"$node_filter_stderr")"
echo "$out" | grep -q '^==> node END (OK)'
grep -q '^npm install -g --dry-run --ignore-scripts --engine-strict --loglevel=error -- npm@12.0.1$' "$CALL_LOG"
grep -q '^npm install -g -- example-cli@2.0.0$' "$CALL_LOG"
if grep -q '^npm install -g -- npm@12.0.1$' "$CALL_LOG"; then
	echo "Expected engine-incompatible npm candidate to be skipped" >&2
	exit 1
fi
grep -q 'node: skipping npm@12.0.1 because it is incompatible with the active Node runtime' "$node_filter_stderr"
node_filter_json="${tmp_dir}/node-filter.jsonl"
"$SCRIPT" --json --only node --no-emoji --no-color >"$node_filter_json" 2>"${tmp_dir}/node-filter-json.stderr"
"$SYSTEM_PYTHON3" - "$node_filter_json" <<'PY'
import json, sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert any(
    event.get("event") == "warn"
    and "skipping npm@12.0.1 because it is incompatible with the active Node runtime" in event.get("message", "")
    for event in events
)
assert any(
    event.get("event") == "module_end"
    and event.get("module") == "node"
    and event.get("status") == "ok"
    for event in events
)
PY

UPDATES_TEST_CASE

run_test "node engine preflight preserves resolution flags but ignores force" <<'UPDATES_TEST_CASE'
write_ncu_stub '{"example-cli":"2.0.0"}'
config_home_node_engine_flags="${tmp_dir}/home-node-engine-flags"
mkdir -p "$config_home_node_engine_flags"
cat >"${config_home_node_engine_flags}/.updatesrc" <<EOF
NODE_NPM_INSTALL_FLAGS=--registry=https://registry.example.invalid --force false -f=true -fg --silent
EOF
# shellcheck disable=SC2016
write_stub npm '
echo "npm $*" >>"$CALL_LOG"
case " $* " in
*" --dry-run "*)
	[ "${NPM_CONFIG_FORCE:-}" = "false" ]
	[ "${NPM_CONFIG_ENGINE_STRICT:-}" = "true" ]
	[ "${NPM_CONFIG_LOGLEVEL:-}" = "error" ]
	[ "${npm_config_force:-}" = "false" ]
	[ "${npm_config_engine_strict:-}" = "true" ]
	[ "${npm_config_loglevel:-}" = "error" ]
	;;
*)
	[ -z "${NPM_CONFIG_FORCE+x}" ]
	[ -z "${NPM_CONFIG_ENGINE_STRICT+x}" ]
	[ -z "${NPM_CONFIG_LOGLEVEL+x}" ]
	[ "${npm_config_force:-}" = "true" ]
	[ -z "${npm_config_engine_strict+x}" ]
	[ "${npm_config_loglevel:-}" = "silent" ]
	;;
esac
'
: >"$CALL_LOG"
out="$(npm_config_force=true npm_config_loglevel=silent HOME="$config_home_node_engine_flags" "$SCRIPT" --only node --no-emoji --no-color)"
echo "$out" | grep -q '^==> node END (OK)'
grep -q '^npm install -g --registry=https://registry.example.invalid --dry-run --ignore-scripts --engine-strict --loglevel=error -- example-cli@2.0.0$' "$CALL_LOG"
grep -q '^npm install -g --registry=https://registry.example.invalid --force false -f=true -fg --silent -- example-cli@2.0.0$' "$CALL_LOG"
if grep -- '--dry-run' "$CALL_LOG" | grep -q -- '--force'; then
	echo "Expected engine preflight to ignore --force" >&2
	exit 1
fi
if grep -- '--dry-run' "$CALL_LOG" | grep -Eq -- '(^| )-f(=| |g)|--silent'; then
	echo "Expected engine preflight to remove short force and silent flags" >&2
	exit 1
fi

UPDATES_TEST_CASE

run_test "node falls back from an incapable local ncu to engine-aware npx" <<'UPDATES_TEST_CASE'
# shellcheck disable=SC2016
write_stub ncu '
echo "ncu $*" >>"$CALL_LOG"
if [ "${1:-}" = "--help" ]; then
	echo "legacy ncu help"
	exit 0
fi
echo "incapable ncu query should not run" >&2
exit 1
'
# shellcheck disable=SC2016
write_stub npx '
echo "npx $*" >>"$CALL_LOG"
echo "{\"example-cli\":\"2.0.0\"}"
'
# shellcheck disable=SC2016
write_stub npm 'echo "npm $*" >>"$CALL_LOG"'
: >"$CALL_LOG"
out="$("$SCRIPT" --dry-run --only node --no-emoji --no-color)"
echo "$out" | grep -q 'DRY RUN: npx --yes npm-check-updates -g --enginesNode --jsonUpgraded'
if grep -q '^npx ' "$CALL_LOG"; then
	echo "Expected node dry-run not to execute the npx fallback" >&2
	exit 1
fi
out="$("$SCRIPT" --only node --no-emoji --no-color)"
echo "$out" | grep -q '^==> node END (OK)'
grep -q '^npx --yes npm-check-updates -g --enginesNode --jsonUpgraded$' "$CALL_LOG"

UPDATES_TEST_CASE

run_test "node fails safe when no engine-aware updater is available" <<'UPDATES_TEST_CASE'
# shellcheck disable=SC2016
write_stub ncu '
if [ "${1:-}" = "--help" ]; then
	echo "legacy ncu help"
	exit 0
fi
exit 1
'
rm -f "${stub_bin}/npx"
node_skip_args=(--skip "brew,shell,repos,linux,winget,bun,python,uv,mas,pipx,rustup,claude,pi,mise,go,macos" --no-emoji --no-color)
node_capability_stderr="${tmp_dir}/node-capability-stderr.log"
out="$("$SCRIPT" "${node_skip_args[@]}" 2>"$node_capability_stderr")"
echo "$out" | grep -q '^==> node END (SKIP)'
grep -q 'node: no npm-check-updates adapter supports --enginesNode' "$node_capability_stderr"
set +e
out="$("$SCRIPT" --only node --no-emoji --no-color 2>"$node_capability_stderr")"
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
	echo "Expected --only node to fail without an engine-aware updater (got $rc)" >&2
	exit 1
fi
echo "$out" | grep -q '^==> node END (FAIL)'
grep -q 'node: no npm-check-updates adapter supports --enginesNode' "$node_capability_stderr"

UPDATES_TEST_CASE

run_test "node isolates package installs and does not retry EBADENGINE" <<'UPDATES_TEST_CASE'
write_ncu_stub '{"npm":"12.0.1","example-cli":"2.0.0"}'
# shellcheck disable=SC2016
write_stub npm '
echo "npm $*" >>"$CALL_LOG"
case " $* " in
*" --dry-run "*" npm@12.0.1 "*)
	exit 0
	;;
*" npm@12.0.1 "*)
	echo "npm error code EBADENGINE" >&2
	exit 0
	;;
*" example-cli@2.0.0 "*)
	exit 0
	;;
esac
exit 1
'
: >"$CALL_LOG"
npm_engine_stderr="${tmp_dir}/npm-engine-stderr.log"
set +e
out="$("$SCRIPT" --only node --no-emoji --no-color 2>"$npm_engine_stderr")"
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
	echo "Expected node to fail after one incompatible package (got $rc)" >&2
	exit 1
fi
grep -q '^npm install -g -- npm@12.0.1$' "$CALL_LOG"
grep -q '^npm install -g -- example-cli@2.0.0$' "$CALL_LOG"
if [ "$(grep -c '^npm install -g -- npm@12.0.1$' "$CALL_LOG")" -ne 1 ]; then
	echo "Expected EBADENGINE package to be attempted exactly once" >&2
	exit 1
fi
grep -q 'node: npm@12.0.1 is incompatible with the active Node runtime' "$npm_engine_stderr"

UPDATES_TEST_CASE

run_test "node retries npm ERESOLVE with legacy peer deps" <<'UPDATES_TEST_CASE'
write_ncu_stub '{"@tarquinen/opencode-dcp":"3.1.13"}'
# shellcheck disable=SC2016
write_stub npm '
echo "npm $*" >>"$CALL_LOG"
case " $* " in
*" --allow-scripts=opencode-ai,koffi "*)
	;;
*" --legacy-peer-deps "*)
	echo "npm warn allow-scripts Run \`npm install -g --allow-scripts=opencode-ai,koffi\` to allow these scripts once" >&2
	;;
*" @tarquinen/opencode-dcp@3.1.13 "*)
	echo "npm error code ERESOLVE" >&2
	exit 1
	;;
esac
'
: >"$CALL_LOG"
npm_eresolve_stderr="${tmp_dir}/npm-eresolve-stderr.log"
out="$("$SCRIPT" --only node --no-emoji --no-color 2>"$npm_eresolve_stderr")"
echo "$out" | grep -q '^==> node END (OK)'
grep -q '^npm install -g -- @tarquinen/opencode-dcp@3.1.13$' "$CALL_LOG"
grep -q '^npm install -g --legacy-peer-deps -- @tarquinen/opencode-dcp@3.1.13$' "$CALL_LOG"
grep -q '^npm install -g --allow-scripts=opencode-ai,koffi --legacy-peer-deps -- @tarquinen/opencode-dcp@3.1.13$' "$CALL_LOG"
if grep -q 'npm error code ERESOLVE' "$npm_eresolve_stderr"; then
	echo "Expected successful ERESOLVE retry to suppress first-pass npm error details" >&2
	exit 1
fi
if grep -q 'npm warn allow-scripts' "$npm_eresolve_stderr"; then
	echo "Expected successful allow-scripts retry to suppress first-pass npm warning details" >&2
	exit 1
fi
grep -q 'retrying with --legacy-peer-deps' "$npm_eresolve_stderr"
grep -q 'retrying once with npm-provided allow-scripts list' "$npm_eresolve_stderr"

UPDATES_TEST_CASE

run_test "node fails when npm ERESOLVE retry fails" <<'UPDATES_TEST_CASE'
write_ncu_stub '{"@tarquinen/opencode-dcp":"3.1.13"}'
# shellcheck disable=SC2016
write_stub npm '
echo "npm $*" >>"$CALL_LOG"
echo "npm error code ERESOLVE" >&2
exit 1
'
: >"$CALL_LOG"
npm_eresolve_retry_stderr="${tmp_dir}/npm-eresolve-retry-stderr.log"
set +e
out="$("$SCRIPT" --only node --no-emoji --no-color 2>"$npm_eresolve_retry_stderr")"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
	echo "Expected node to fail when the legacy peer deps retry also fails" >&2
	exit 1
fi
echo "$out" | grep -q '^==> node END (FAIL)'
grep -q '^npm install -g -- @tarquinen/opencode-dcp@3.1.13$' "$CALL_LOG"
grep -q '^npm install -g --legacy-peer-deps -- @tarquinen/opencode-dcp@3.1.13$' "$CALL_LOG"
grep -q 'npm error code ERESOLVE' "$npm_eresolve_retry_stderr"
grep -q 'retrying with --legacy-peer-deps' "$npm_eresolve_retry_stderr"

UPDATES_TEST_CASE

run_test "node retry keeps configured npm flags literal and dedupes legacy peer deps" <<'UPDATES_TEST_CASE'
write_ncu_stub '{"@tarquinen/opencode-dcp":"3.1.13"}'
npm_eresolve_stderr="${tmp_dir}/npm-eresolve-stderr.log"
touch "${tmp_dir}/--flag=literal-glob-target"
config_home_npm_retry_flags="${tmp_dir}/home-npm-retry-flags"
mkdir -p "$config_home_npm_retry_flags"
cat >"${config_home_npm_retry_flags}/.updatesrc" <<EOF
NODE_NPM_INSTALL_FLAGS=--flag=* --legacy-peer-deps --strict-peer-deps
EOF
# shellcheck disable=SC2016
write_stub npm '
echo "npm $*" >>"$CALL_LOG"
case " $* " in
*" --dry-run "*) exit 0 ;;
esac
count=0
if [ -s "$NPM_RETRY_COUNT_FILE" ]; then
	count="$(cat "$NPM_RETRY_COUNT_FILE")"
fi
count=$((count + 1))
echo "$count" >"$NPM_RETRY_COUNT_FILE"
if [ "$count" -eq 1 ]; then
	echo "npm error code ERESOLVE" >&2
	exit 1
fi
case " $* " in
*" --legacy-peer-deps "*)
	exit 0
	;;
esac
exit 1
'
: >"$CALL_LOG"
out="$(cd "$tmp_dir" && NPM_RETRY_COUNT_FILE="${tmp_dir}/npm-retry-count" HOME="$config_home_npm_retry_flags" "$SCRIPT" --only node --no-emoji --no-color 2>"$npm_eresolve_stderr")"
echo "$out" | grep -q '^==> node END (OK)'
grep -q '^npm install -g --flag=\* --legacy-peer-deps --strict-peer-deps -- @tarquinen/opencode-dcp@3.1.13$' "$CALL_LOG"
grep -q '^npm install -g --flag=\* --strict-peer-deps --legacy-peer-deps -- @tarquinen/opencode-dcp@3.1.13$' "$CALL_LOG"
if grep -q -- '--flag=literal-glob-target' "$CALL_LOG"; then
	echo "Expected NODE_NPM_INSTALL_FLAGS globs to remain literal" >&2
	exit 1
fi
retry_legacy_count="$(grep '^npm install -g --flag=\* --strict-peer-deps --legacy-peer-deps -- @tarquinen/opencode-dcp@3.1.13$' "$CALL_LOG" | grep -o -- '--legacy-peer-deps' | wc -l | tr -d ' ')"
if [ "$retry_legacy_count" -ne 1 ]; then
	echo "Expected retry command to include --legacy-peer-deps exactly once (got $retry_legacy_count)" >&2
	exit 1
fi

UPDATES_TEST_CASE

run_test "node reruns npm with allow-scripts when npm requests approval" <<'UPDATES_TEST_CASE'
write_ncu_stub '{"opencode-ai":"1.17.8"}'
# shellcheck disable=SC2016
write_stub npm '
echo "npm $*" >>"$CALL_LOG"
case " $* " in
*" --allow-scripts=opencode-ai,koffi "*)
	;;
*)
	echo "npm warn allow-scripts Run npm install -g --allow-scripts=opencode-ai,koffi to allow these scripts once" >&2
	;;
esac
'
: >"$CALL_LOG"
npm_allow_scripts_stderr="${tmp_dir}/npm-allow-scripts-stderr.log"
out="$("$SCRIPT" --only node --no-emoji --no-color 2>"$npm_allow_scripts_stderr")"
echo "$out" | grep -q '^==> node END (OK)'
grep -q '^npm install -g -- opencode-ai@1.17.8$' "$CALL_LOG"
grep -q '^npm install -g --allow-scripts=opencode-ai,koffi -- opencode-ai@1.17.8$' "$CALL_LOG"
if grep -q 'npm warn allow-scripts' "$npm_allow_scripts_stderr"; then
	echo "Expected successful allow-scripts retry to suppress npm warning details" >&2
	exit 1
fi
grep -q 'retrying once with npm-provided allow-scripts list' "$npm_allow_scripts_stderr"

UPDATES_TEST_CASE

run_test "node keeps a successful install after allow-scripts retry exhaustion" <<'UPDATES_TEST_CASE'
write_ncu_stub '{"opencode-ai":"1.17.8"}'
# shellcheck disable=SC2016
write_stub npm '
echo "npm $*" >>"$CALL_LOG"
case " $* " in
*" --dry-run "*) exit 0 ;;
esac
echo "npm warn allow-scripts approve with --allow-scripts=opencode-ai,koffi" >&2
'
: >"$CALL_LOG"
npm_allow_scripts_exhausted_stderr="${tmp_dir}/npm-allow-scripts-exhausted-stderr.log"
out="$("$SCRIPT" --only node --no-emoji --no-color 2>"$npm_allow_scripts_exhausted_stderr")"
echo "$out" | grep -q '^==> node END (OK)'
if [ "$(grep '^npm install -g ' "$CALL_LOG" | grep -vc -- '--dry-run')" -ne 2 ]; then
	echo "Expected one allow-scripts retry and no further attempts" >&2
	exit 1
fi
grep -q '^npm install -g --allow-scripts=opencode-ai,koffi -- opencode-ai@1.17.8$' "$CALL_LOG"
grep -q 'npm install completed for opencode-ai@1.17.8, but npm still reports install scripts needing approval after retry' "$npm_allow_scripts_exhausted_stderr"
grep -q 'npm warn allow-scripts approve with --allow-scripts=opencode-ai,koffi' "$npm_allow_scripts_exhausted_stderr"

UPDATES_TEST_CASE

run_test "node extracts allow-scripts flag without npm command wording" <<'UPDATES_TEST_CASE'
write_ncu_stub '{"opencode-ai":"1.17.8"}'
# shellcheck disable=SC2016
write_stub npm '
echo "npm $*" >>"$CALL_LOG"
case " $* " in
*" --allow-scripts=opencode-ai,koffi "*)
	;;
*)
	echo "npm warn allow-scripts approve with --allow-scripts=opencode-ai,koffi" >&2
	;;
esac
'
: >"$CALL_LOG"
npm_allow_scripts_flag_only_stderr="${tmp_dir}/npm-allow-scripts-flag-only-stderr.log"
out="$("$SCRIPT" --only node --no-emoji --no-color 2>"$npm_allow_scripts_flag_only_stderr")"
echo "$out" | grep -q '^==> node END (OK)'
grep -q '^npm install -g -- opencode-ai@1.17.8$' "$CALL_LOG"
grep -q '^npm install -g --allow-scripts=opencode-ai,koffi -- opencode-ai@1.17.8$' "$CALL_LOG"
if grep -q 'npm warn allow-scripts' "$npm_allow_scripts_flag_only_stderr"; then
	echo "Expected successful flag-only allow-scripts retry to suppress npm warning details" >&2
	exit 1
fi
grep -q 'retrying once with npm-provided allow-scripts list' "$npm_allow_scripts_flag_only_stderr"

UPDATES_TEST_CASE

run_test "node surfaces unparseable allow-scripts warnings without retrying" <<'UPDATES_TEST_CASE'
write_ncu_stub '{"opencode-ai":"1.17.8"}'
# shellcheck disable=SC2016
write_stub npm '
echo "npm $*" >>"$CALL_LOG"
echo "npm warn allow-scripts install scripts need approval" >&2
'
: >"$CALL_LOG"
npm_allow_scripts_unparseable_stderr="${tmp_dir}/npm-allow-scripts-unparseable-stderr.log"
out="$("$SCRIPT" --only node --no-emoji --no-color 2>"$npm_allow_scripts_unparseable_stderr")"
echo "$out" | grep -q '^==> node END (OK)'
grep -q '^npm install -g -- opencode-ai@1.17.8$' "$CALL_LOG"
if grep -q '^npm install -g --allow-scripts=' "$CALL_LOG"; then
	echo "Expected unparseable allow-scripts warning to avoid a guessed retry" >&2
	exit 1
fi
grep -q 'no allow-scripts list could be parsed' "$npm_allow_scripts_unparseable_stderr"
grep -q 'npm warn allow-scripts install scripts need approval' "$npm_allow_scripts_unparseable_stderr"

UPDATES_TEST_CASE

run_test "NODE_NPM_INSTALL_FLAGS appears in node dry-run output" <<'UPDATES_TEST_CASE'
write_ncu_stub '{"npm":"11.7.0"}'
# shellcheck disable=SC2016
write_stub npm 'echo "npm $*" >>"$CALL_LOG"'
config_home_npm_flags="${tmp_dir}/home-npm-flags"
mkdir -p "$config_home_npm_flags"
cat >"${config_home_npm_flags}/.updatesrc" <<EOF
NODE_NPM_INSTALL_FLAGS=--legacy-peer-deps
EOF
out="$(HOME="$config_home_npm_flags" UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --dry-run --only node --no-emoji --no-color)"
echo "$out" | grep -q 'DRY RUN: npm install -g --legacy-peer-deps -- <packages\.\.\.>'

UPDATES_TEST_CASE

run_test "node dry-run without NODE_NPM_INSTALL_FLAGS omits extra flags" <<'UPDATES_TEST_CASE'
config_home_no_npm_flags="${tmp_dir}/home-no-npm-flags"
mkdir -p "$config_home_no_npm_flags"
cat >"${config_home_no_npm_flags}/.updatesrc" <<EOF
EOF
out="$(HOME="$config_home_no_npm_flags" UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --dry-run --only node --no-emoji --no-color)"
echo "$out" | grep -q 'DRY RUN: npm install -g -- <packages\.\.\.>'

UPDATES_TEST_CASE

run_test "node dry-run without NODE_NPM_INSTALL_FLAGS works under nounset" <<'UPDATES_TEST_CASE'
config_home_no_npm_flags="${tmp_dir}/home-no-npm-flags-nounset"
mkdir -p "$config_home_no_npm_flags"
out="$(HOME="$config_home_no_npm_flags" UPDATES_ALLOW_NON_DARWIN=1 bash -u "$SCRIPT" --dry-run --only node --no-emoji --no-color)"
echo "$out" | grep -q 'DRY RUN: npm install -g -- <packages\.\.\.>'

write_ncu_stub '{"npm":"11.7.0"}'
# shellcheck disable=SC2016
write_stub npm 'echo "npm $*" >>"$CALL_LOG"'

UPDATES_TEST_CASE

run_test "node sources nvm before resolving npm tools" <<'UPDATES_TEST_CASE'
nvm_home="${tmp_dir}/home-nvm"
nvm_root="${nvm_home}/.nvm"
nvm_bin="${nvm_root}/versions/node/v99.0.0/bin"
mkdir -p "$nvm_bin"
write_stub_to_dir "$nvm_bin" ncu '
if [ "${1:-}" = "--help" ]; then
	echo "--enginesNode"
	exit 0
fi
echo "{\"npm\":\"11.7.0\"}"
'
# shellcheck disable=SC2016
write_stub_to_dir "$nvm_bin" npm 'echo "nvm npm $*" >>"$CALL_LOG"'
cat >"${nvm_root}/nvm.sh" <<EOF
export NVM_BIN="${nvm_bin}"
export PATH="${nvm_bin}:\$PATH"
nvm() { return 0; }
EOF
: >"$CALL_LOG"
out="$(HOME="$nvm_home" NVM_DIR="$nvm_root" PATH="$BASE_PATH" "$SCRIPT" --only node --no-emoji --no-color)"
echo "$out" | grep -q '^==> node END (OK)'
grep -q '^nvm npm install -g -- npm@11.7.0$' "$CALL_LOG"

UPDATES_TEST_CASE

run_test "node tolerates failing nvm.sh" <<'UPDATES_TEST_CASE'
failing_nvm_home="${tmp_dir}/home-nvm-failing"
failing_nvm_root="${failing_nvm_home}/.nvm"
mkdir -p "$failing_nvm_root"
cat >"${failing_nvm_root}/nvm.sh" <<'EOF'
false
return 1
EOF
write_ncu_stub '{"npm":"11.7.0"}'
# shellcheck disable=SC2016
write_stub npm 'echo "fallback npm $*" >>"$CALL_LOG"'
: >"$CALL_LOG"
out="$(HOME="$failing_nvm_home" NVM_DIR="$failing_nvm_root" "$SCRIPT" --only node --no-emoji --no-color)"
echo "$out" | grep -q '^==> node END (OK)'
grep -q '^fallback npm install -g -- npm@11.7.0$' "$CALL_LOG"

UPDATES_TEST_CASE

run_test "node falls back to npx npm-check-updates" <<'UPDATES_TEST_CASE'
rm -f "${stub_bin}/ncu"
# shellcheck disable=SC2016
write_stub npm 'echo "npm $*" >>"$CALL_LOG"'
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
grep -q '^npx --yes npm-check-updates -g --enginesNode --jsonUpgraded$' "$CALL_LOG"
grep -q '^npm install -g -- npm@11.8.0$' "$CALL_LOG"
rm -f "${stub_bin}/npx"
write_ncu_stub '{"npm":"11.7.0"}'

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

UPDATES_TEST_CASE

run_test "Linux dnf module (non-interactive dry-run)" <<'UPDATES_TEST_CASE'
write_stub uname 'echo Linux'
# shellcheck disable=SC2016
write_stub dnf 'echo "dnf $*" >>"$CALL_LOG"'
rm -f "${stub_bin}/apt-get"
# shellcheck disable=SC2016
write_stub sudo 'echo "sudo $*" >>"$CALL_LOG"; if [ "${1:-}" = "-n" ]; then shift; fi; "$@"'
: >"$CALL_LOG"
out="$(PATH="$LINUX_PM_PATH" "$SCRIPT" --only linux --non-interactive --dry-run --no-emoji --no-color)"
echo "$out" | grep -q 'DRY RUN:.*dnf upgrade'

UPDATES_TEST_CASE

run_test "Linux pacman module (non-interactive dry-run)" <<'UPDATES_TEST_CASE'
write_stub uname 'echo Linux'
# shellcheck disable=SC2016
write_stub pacman 'echo "pacman $*" >>"$CALL_LOG"'
rm -f "${stub_bin}/apt-get" "${stub_bin}/dnf"
# shellcheck disable=SC2016
write_stub sudo 'echo "sudo $*" >>"$CALL_LOG"; if [ "${1:-}" = "-n" ]; then shift; fi; "$@"'
: >"$CALL_LOG"
out="$(PATH="$LINUX_PM_PATH" "$SCRIPT" --only linux --non-interactive --dry-run --no-emoji --no-color)"
echo "$out" | grep -q 'DRY RUN:.*pacman -Syu'

UPDATES_TEST_CASE

run_test "Linux zypper module (non-interactive dry-run)" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

run_test "Linux apk module (non-interactive dry-run)" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

run_test "config quoted values parse correctly" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

run_test "config boolean keys work from config file" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

run_test "--strict stops on first module failure" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

run_test "--log-file writes output to file" <<'UPDATES_TEST_CASE'
write_stub uname 'echo Darwin'
log_file="${tmp_dir}/test-log-file.log"
logfile_out="$(UPDATES_ALLOW_NON_DARWIN=1 "$SCRIPT" --dry-run --only brew --log-file "$log_file" --no-emoji --no-color 2>&1)"
if [ ! -f "$log_file" ]; then
	echo "Expected log file to exist" >&2
	exit 1
fi
grep -q 'brew START' "$log_file"
echo "$logfile_out" | grep -q 'brew START'

UPDATES_TEST_CASE

run_test "--log-file + --json interaction" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

run_test "--parallel validation" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

run_test "--only linux on macOS exits with error" <<'UPDATES_TEST_CASE'
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

UPDATES_TEST_CASE

if [ -n "$TEST_FILTER" ] && [ "$TEST_MATCHED" -eq 0 ]; then
	echo "No selectable test matched: $TEST_FILTER" >&2
	exit 2
fi
if [ -n "$TEST_FILTER" ]; then
	echo "Selected tests passed."
else
	echo "All tests passed."
fi

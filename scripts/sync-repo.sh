#!/bin/bash
# Automated git fetch + fast-forward pull for updates repo.
# Runs periodically via cron to keep local repo in sync with origin/main.
# Only pulls when working tree is clean; skips if dirty or diverged.

set -euo pipefail

REPO_DIR="${UPDATES_SYNC_REPO_DIR:-/home/athanvi/updates}"
LOG_FILE="${UPDATES_SYNC_LOG_FILE:-/home/athanvi/.local/log/repo-sync.log}"

mkdir -p "$(dirname "$LOG_FILE")"

timestamp() {
	date "+%Y-%m-%d %H:%M:%S"
}

log() {
	echo "[$(timestamp)] $1" >>"$LOG_FILE"
}

# Rotate log if > 1MB
if [[ -f "$LOG_FILE" ]]; then
	size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE")
	if [[ "$size" -gt 1048576 ]]; then
		mv "$LOG_FILE" "${LOG_FILE}.old"
	fi
fi

log "Starting sync for updates repo"

if [[ ! -d "$REPO_DIR/.git" ]]; then
	log "ERROR: $REPO_DIR is not a git repository"
	exit 1
fi

cd "$REPO_DIR" || exit 1

# Fetch from all remotes
if ! output=$(git fetch --all 2>&1); then
	log "ERROR: Fetch failed: $output"
	exit 1
fi

if [[ -n "$output" ]]; then
	log "Fetched updates: $output"
else
	log "No new updates"
fi

behind=$(git rev-list HEAD..origin/main --count 2>/dev/null || echo 0)
if [[ "$behind" -gt 0 ]]; then
	log "INFO: Local is $behind commit(s) behind origin/main"

	# Auto-pull only when working tree is clean
	if [[ -z "$(git status --porcelain 2>/dev/null)" ]]; then
		if pull_output=$(git pull --ff-only origin main 2>&1); then
			log "Pulled $behind commit(s): $pull_output"
		else
			log "WARN: Fast-forward pull failed (branch may have diverged): $pull_output"
		fi
	else
		log "WARN: Working tree is dirty; skipping auto-pull"
	fi
fi

log "Sync complete"

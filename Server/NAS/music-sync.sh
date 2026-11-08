#!/bin/bash
set -euo pipefail

REMOTE="mobile@192.168.1.2"
REMOTE_PATH="/var/mobile/Documents/AudioStreamMusic/"
DEST="/music/"
LOCK_FILE="/var/lock/music-sync.lock"
TRASH_ROOT="/music-trash"
RETENTION_DAYS=30
MIN_FREE_KB=5242880

MERGE_DIR=/var/lib/music-server
STATUS_FILE="$MERGE_DIR/sync-status.json"
LAST_SUCCESS_FILE="$MERGE_DIR/sync-success.txt"
mkdir -p "$MERGE_DIR"

SSH_CMD=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

write_status() {
    local result="$1" message="${2:-}" last_success="" free_kb=0 dest_count=0
    if [ -f "$LAST_SUCCESS_FILE" ]; then
        last_success=$(cat "$LAST_SUCCESS_FILE")
    fi
    if free_kb=$(df -Pk "$DEST" 2>/dev/null | awk 'NR==2 {print $4}') && [ -n "$free_kb" ]; then
        :
    else
        free_kb=0
    fi
    dest_count=$(find "$DEST" -type f ! -name '.*' 2>/dev/null | wc -l)
    printf '{"lastAttempt":"%s","lastSuccess":"%s","result":"%s","message":"%s","remoteFiles":%s,"localFiles":%s,"freeKB":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$last_success" "$result" "$message" \
        "${REMOTE_COUNT:-0}" "$dest_count" "${free_kb:-0}" > "$STATUS_FILE.tmp"
    mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "music-sync: another run is already active"
    exit 0
fi

if ! "${SSH_CMD[@]}" "$REMOTE" true; then
    echo "music-sync: iPhone is unreachable, skipping"
    write_status "iphone-unreachable" "iPhone is unreachable"
    exit 0
fi

REMOTE_COUNT=$("${SSH_CMD[@]}" "$REMOTE" "find /var/mobile/Documents/AudioStreamMusic -type f ! -name '.*' | wc -l")
if [ "$REMOTE_COUNT" -lt 100 ]; then
    echo "music-sync: remote library only has $REMOTE_COUNT files, refusing to sync"
    write_status "remote-too-small" "Remote library only has $REMOTE_COUNT files"
    exit 1
fi

AVAILABLE_KB=$(df -Pk "$DEST" | awk 'NR==2 {print $4}')
if [ "${AVAILABLE_KB:-0}" -lt "$MIN_FREE_KB" ]; then
    echo "music-sync: less than 5 GB free on $DEST, refusing to sync"
    write_status "low-space" "Less than 5 GB free on the music share"
    exit 1
fi

scp -q -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    "$REMOTE:/tmp/audiostream_mergegroups.json" "$MERGE_DIR/mergegroups.json" 2>/dev/null || true
scp -q -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    "$REMOTE:/tmp/audiostream_artistmergegroups.json" "$MERGE_DIR/artistmergegroups.json" 2>/dev/null || true

DATE_DIR="$TRASH_ROOT/$(date +%F)"
mkdir -p "$DATE_DIR"

VERBOSE=()
if [ "${1:-}" = "--verbose" ]; then
    VERBOSE=(--itemize-changes)
fi

echo "music-sync: starting $(date -Is), remote files=$REMOTE_COUNT, free=${AVAILABLE_KB}KB"
if ! rsync -rltp --size-only --delete "${VERBOSE[@]}" --stats \
    --exclude=.daemon_metadata_cache.json \
    --exclude='._*' \
    --iconv=UTF-8,UTF-8-MAC \
    --backup --backup-dir="$DATE_DIR" \
    --rsync-path=/var/jb/usr/bin/rsync \
    -e "${SSH_CMD[*]}" \
    "$REMOTE:$REMOTE_PATH" "$DEST"; then
    echo "music-sync: rsync failed"
    write_status "error" "rsync failed"
    exit 1
fi

find "$TRASH_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -exec rm -rf {} +

curl -s --max-time 30 http://127.0.0.1:18080/api/rescan >/dev/null 2>&1 || true

DEST_COUNT=$(find "$DEST" -type f ! -name '.*' | wc -l)
date -u +%Y-%m-%dT%H:%M:%SZ > "$LAST_SUCCESS_FILE"
write_status "ok" ""
echo "music-sync: finished $(date -Is), local files=$DEST_COUNT"

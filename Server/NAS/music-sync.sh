#!/bin/bash
set -euo pipefail

REMOTE="mobile@192.168.1.2"
REMOTE_PATH="/var/mobile/Documents/AudioStreamMusic/"
DEST="/music/"
LOCK_FILE="/var/lock/music-sync.lock"
TRASH_ROOT="/music-trash"
RETENTION_DAYS=30
MIN_FREE_KB=5242880

SSH_CMD=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "music-sync: another run is already active"
    exit 0
fi

if ! "${SSH_CMD[@]}" "$REMOTE" true; then
    echo "music-sync: iPhone is unreachable, skipping"
    exit 0
fi

REMOTE_COUNT=$("${SSH_CMD[@]}" "$REMOTE" "find /var/mobile/Documents/AudioStreamMusic -type f ! -name '.*' | wc -l")
if [ "$REMOTE_COUNT" -lt 100 ]; then
    echo "music-sync: remote library only has $REMOTE_COUNT files, refusing to sync"
    exit 1
fi

AVAILABLE_KB=$(df -Pk "$DEST" | awk 'NR==2 {print $4}')
if [ "${AVAILABLE_KB:-0}" -lt "$MIN_FREE_KB" ]; then
    echo "music-sync: less than 5 GB free on $DEST, refusing to sync"
    exit 1
fi

MERGE_DIR=/var/lib/music-server
mkdir -p "$MERGE_DIR"
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
rsync -rltp --size-only --delete "${VERBOSE[@]}" --stats \
    --exclude=.daemon_metadata_cache.json \
    --exclude='._*' \
    --iconv=UTF-8,UTF-8-MAC \
    --backup --backup-dir="$DATE_DIR" \
    --rsync-path=/var/jb/usr/bin/rsync \
    -e "${SSH_CMD[*]}" \
    "$REMOTE:$REMOTE_PATH" "$DEST"

find "$TRASH_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -exec rm -rf {} +

curl -s --max-time 30 http://127.0.0.1:18080/api/rescan >/dev/null 2>&1 || true

DEST_COUNT=$(find "$DEST" -type f ! -name '.*' | wc -l)
echo "music-sync: finished $(date -Is), local files=$DEST_COUNT"

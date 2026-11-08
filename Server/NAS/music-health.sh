#!/bin/bash
set -euo pipefail

STATE_FILE="${MUSIC_HEALTH_STATE_FILE:-/var/lib/music-health.state}"
COOLDOWN_SECONDS=21600

ENV_FILE="${MUSIC_HEALTH_ENV_FILE:-/etc/music-health.env}"
if [ -r "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

STATUS_URL="${MUSIC_STATUS_URL:-http://192.168.1.210:18080/api/status}"

if [ -z "${MUSIC_HEALTH_WEBHOOK:-}" ]; then
    echo "music-health: MUSIC_HEALTH_WEBHOOK is not configured"
    exit 0
fi

alert() {
    local key="$1" message="$2" now last_key="" last_time=0 payload
    now=$(date +%s)
    if [ -r "$STATE_FILE" ]; then
        IFS='|' read -r last_key last_time < "$STATE_FILE" || true
    fi
    if [ "$last_key" = "$key" ] && [ $((now - ${last_time:-0})) -lt "$COOLDOWN_SECONDS" ]; then
        echo "music-health: suppressing duplicate alert ($key)"
        return 0
    fi
    payload=$(jq -n --arg title "AudioStream NAS" --arg message "$message" '{title:$title, message:$message}')
    if curl -fsS --max-time 10 -X POST -H 'Content-Type: application/json' -d "$payload" "$MUSIC_HEALTH_WEBHOOK" >/dev/null; then
        printf '%s|%s\n' "$key" "$now" > "$STATE_FILE"
        echo "music-health: sent alert: $message"
    else
        echo "music-health: failed to send alert: $message" >&2
    fi
}

clear_alert() {
    rm -f "$STATE_FILE"
}

if ! status_json=$(curl -fsS --max-time 10 "$STATUS_URL" 2>/dev/null); then
    alert "server-down" "The music server at 192.168.1.210:18080 is not responding."
    exit 0
fi

result=$(echo "$status_json" | jq -r '.lastSync.result // "unknown"')
message=$(echo "$status_json" | jq -r '.lastSync.message // ""')
last_attempt=$(echo "$status_json" | jq -r '.lastSync.lastAttempt // ""')
last_success=$(echo "$status_json" | jq -r '.lastSync.lastSuccess // ""')
free_kb=$(echo "$status_json" | jq -r '.lastSync.freeKB // 0')
songs=$(echo "$status_json" | jq -r '.songsCount // 0')

now=$(date +%s)

case "$result" in
    error|low-space|remote-too-small)
        alert "sync-$result" "Music sync failed: $message"
        exit 0
        ;;
esac

if [ "$songs" -lt 100 ]; then
    alert "library-empty" "The music server only sees $songs songs."
    exit 0
fi

if [ -n "$last_attempt" ]; then
    attempt_epoch=$(date -d "$last_attempt" +%s 2>/dev/null || echo 0)
    if [ "$attempt_epoch" -gt 0 ] && [ $((now - attempt_epoch)) -gt 5400 ]; then
        alert "sync-stale" "The music sync timer has not run in over 90 minutes."
        exit 0
    fi
fi

if [ -z "$last_success" ]; then
    alert "no-success" "The music library has never completed a sync."
    exit 0
fi

success_epoch=$(date -d "$last_success" +%s 2>/dev/null || echo 0)
if [ "$success_epoch" -gt 0 ] && [ $((now - success_epoch)) -gt 86400 ]; then
    alert "no-success-24h" "The iPhone library has not synced successfully in over 24 hours."
    exit 0
fi

if [ "${free_kb:-0}" -gt 0 ] && [ "$free_kb" -lt 10485760 ]; then
    alert "low-space-warning" "The music share has less than 10 GB free."
    exit 0
fi

clear_alert
echo "music-health: ok (result=$result, lastSuccess=$last_success, freeKB=$free_kb)"

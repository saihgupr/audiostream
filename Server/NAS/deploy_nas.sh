#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o build/music-server .

scp build/music-server proxmox:/tmp/music-server
scp music-sync.sh proxmox:/tmp/music-sync.sh
ssh proxmox 'pct exec 110 -- systemctl stop music-server || true; pct push 110 /tmp/music-server /usr/local/bin/music-server --perms 755; pct push 110 /tmp/music-sync.sh /usr/local/bin/music-sync.sh --perms 755; pct exec 110 -- systemctl start music-server'

scp music-health.sh proxmox:/usr/local/bin/music-health.sh
scp music-health.service music-health.timer proxmox:/etc/systemd/system/
ssh proxmox 'chmod 755 /usr/local/bin/music-health.sh; systemctl daemon-reload; systemctl enable --now music-health.timer'

sleep 2
curl -fsS http://192.168.1.210:18080/api/ping
echo
echo "Deployed to music (110) at 192.168.1.210:18080"

#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o build/music-server .

scp build/music-server proxmox:/tmp/music-server
ssh proxmox 'pct exec 110 -- systemctl stop music-server || true; pct push 110 /tmp/music-server /usr/local/bin/music-server --perms 755; pct exec 110 -- systemctl start music-server'

sleep 2
curl -fsS http://192.168.1.210:18080/api/ping
echo
echo "Deployed to music (110) at 192.168.1.210:18080"

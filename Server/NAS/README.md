# AudioStream NAS server

A small Go HTTP server that serves the mirrored iPhone library from the Proxmox
host. It speaks the same API the iOS app already uses, so switching the app's
server URL is the only client change.

## Layout

- `/music` is the read-only mirror of the iPhone's
  `/var/mobile/Documents/AudioStreamMusic`.
- `/var/lib/music-server/library.json` caches scanned metadata.
- `/var/lib/music-server/artwork` caches embedded and folder artwork.
- The server listens on `:18080`.
- LXC: `music` (VMID 110) at `192.168.1.210`.

## Endpoints

- `GET /api/ping`
- `GET /api/status` (adds the last sync result from `sync-status.json`)
- `GET /api/songs` (add `?refresh=true` to rescan first)
- `GET /api/playlists` (empty; the iOS app generates Recently Added and the
  other date playlists itself)
- `GET /api/rescan`, `GET /api/refresh`
- `GET /music/<relative-path>` with HTTP Range support
- `GET /artwork/<persistentId>` with embedded/folder artwork
- `DELETE` is not supported. The iPhone remains the source of truth.

## Sync

The iPhone library is mirrored by `music-sync.timer` every 30 minutes from
inside the same LXC. The script is `/usr/local/bin/music-sync.sh`.

- Uses rsync over SSH to `mobile@192.168.1.2`.
- `--size-only` so unchanged files are not re-read.
- `--delete` with `--backup --backup-dir=/music-trash/YYYY-MM-DD` so removed or
  replaced files are recoverable for 30 days.
- Refuses to run if the iPhone is unreachable or reports fewer than 100 files.
- `--iconv=UTF-8,UTF-8-MAC` normalizes macOS filenames.
- Writes `/var/lib/music-server/sync-status.json` on every attempt with the
  result, file counts, free space, and the last success time.

## Monitoring

`music-health.timer` runs on the Proxmox host every 5 minutes and checks
`http://192.168.1.210:18080/api/status`. It posts a notification to Home
Assistant through a local-only webhook when:

- the server does not respond,
- the last sync failed (rsync, low space, or a too-small remote library),
- the sync timer has not run for 90 minutes,
- no sync has succeeded for 24 hours,
- the server sees fewer than 100 songs,
- the share has less than 10 GB free.

The webhook URL lives in `/etc/music-health.env` on the Proxmox host (mode
600) and is not stored in this repository. Alerts repeat at most once every
6 hours for the same condition. The matching Home Assistant automation is
`automation.audiostream_nas_alert`.

The LXC needs the sync user's SSH key in the iPhone's
`~/.ssh/authorized_keys`. The key is `/root/.ssh/id_ed25519` inside the LXC.

## Build and deploy

From this directory run:

```bash
./deploy_nas.sh
```

It builds the server, installs the server binary and `music-sync.sh` in the
LXC, and installs the health script and timer on the Proxmox host. The
health webhook URL is configured separately in `/etc/music-health.env` on
the host.

## Client

In the AudioStream app, set the server URL to:

```text
http://192.168.1.210:18080
```

The app's disk cache is keyed by host, so artwork is fetched once from the NAS
after switching. The iPhone daemon can stay configured as a fallback.

## Notes

- Metadata and duration are read with `dhowden/tag` and a lightweight MP4
  `mvhd` parser. FLAC/WAV/AIFF durations are currently 0; the library is
  M4A/MP3.
- Custom playlists are not synced yet. The app's date-based playlists are
  generated on the client.
- The server is read-only. Delete songs on the iPhone; the next sync removes
  them from the mirror and keeps them in `/music-trash`.

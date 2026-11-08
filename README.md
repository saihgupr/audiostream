# AudioStream <img src="images/Icon.png" width="80" align="right" alt="AudioStream" />

AudioStream is a self-hosted music server for jailbroken iOS. It serves your device's native iTunes library over HTTP or locally, letting you stream your own collection to the AudioStream app or any compatible client on your network.

<p align="center">
  <a href="#features">Features</a> •
  <a href="#http-api">HTTP API</a> •
  <a href="#cli-administration">CLI</a> •
  <a href="#apple-watch--remote-controls">Apple Watch</a> •
  <a href="#requirements--setup">Setup</a> •
  <a href="#entitlements">Entitlements</a>
</p>

---

## Screenshots

<p align="center">
  <img src="images/screenshot_library.png" width="22%" alt="Library — Albums view" />
  <img src="images/screenshot_artists.png" width="22%" alt="Library — Artists view" />
  <img src="images/screenshot_settings1.png" width="22%" alt="Settings — Streaming server" />
  <img src="images/screenshot_settings2.png" width="22%" alt="Settings — Connection & Migration" />
</p>

---

## Features

- **Local iOS Library Server (`audiostreamerd`)** — Reads the native iTunes database from `/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb` and serves audio and artwork via a lightweight HTTP API on port `18080`.
- **Hybrid Player Client** — Seamlessly switch between Local media (via Media Player framework) and Remote media (streaming over HTTP from another AudioStream instance). Both modes share the same queue, Now Playing screen, and controls.
- **Album Merging** — Tap "Merge" or long-press any album to enter interactive merge mode directly on the albums grid. Select a primary target, pick additional albums to combine, and merge in one tap. Manage and unmerge groups in Settings.
- **Artist Merging** — Long-press any artist to combine aliases, feature variations, or split names into a single canonical artist. All songs across merged artists are pooled for playback, queueing, and navigation.
- **Album Cover Art Downloader** — Long-press any album cover to download high-resolution artwork directly from Apple Music or MusicBrainz. The file is saved as `cover.jpg` into the album folder on disk, persisting across rescans and the streaming daemon. Includes a manual search modal for fine-grained query adjustments.
- **Smart Playlists** — Automatically generates and keeps current date-based playlists: Recently Added, Month, 3 Months, 6 Months, and Year. Dates pull from filesystem attributes or iTunes properties, with a chronological fallback for remote streaming.
- **Dynamic Artist Profile Images** — Fetches artist profile pictures from Deezer's public API and caches them in memory. Falls back to local album art if offline.
- **Mac Import Tool (`import_from_mac.sh`)** — Imports ZIP packages and folders over SSH. Parses Tidal metadata in FLAC files, downloads missing artwork from Tidal, converts tracks to M4A ALAC, and transfers them to the device.
- **Track Deletion** — Delete songs directly from the track context menu or swipe-to-delete, with automatic disk cleanup and library state sync.
- **Auto-off Idle Protection** — A detached background monitor (`autooff_monitor.sh`) watches HTTP traffic and shuts down the daemon after 10 minutes of inactivity to preserve battery.
- **Apple Watch and Lock Screen Controls** — Full integration with `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`. Supports shuffle, repeat, scrubbing, and queue position reporting from the system Now Playing interface without requiring a watchOS app.
- **RemoteCompanion Integration** — Supports actions such as shuffle all songs, queue current album, and queue current artist from the RemoteCompanion app.
- **Command Line Administration** — A helper (`audiostream`) installed to `/var/jb/usr/bin/` for starting, stopping, and querying the daemon directly from the terminal.
- **NAS Music Server (optional)** — Runs the same HTTP API from an always-on Proxmox LXC that mirrors the iPhone library, so playback does not keep the phone awake. Setup is in [NAS Music Server](#nas-music-server-optional).

---

## NAS Music Server (optional)

<details>
<summary><strong>Run the library from an always-on Proxmox LXC</strong></summary>

The same HTTP API can run on a small LXC that mirrors the iPhone library, so
playback no longer keeps the phone awake. The server is read-only. The iPhone
stays the source of truth and the next sync copies every change.

Tested layout: LXC `music` (VMID 110), 1 core, 256 MB RAM, 8 GB root disk,
`192.168.1.210`, with `/music` and `/music-trash` bind-mounted from the Proxmox
host.

<details>
<summary><strong>Setup</strong></summary>

The `pct` commands below run on the Proxmox host.

1. Create an unprivileged Debian or Ubuntu LXC (VMID 110 in the commands
   below) with a static address. No GPU or nesting is needed. Install `rsync`,
   `openssh-client` and `curl` inside it.

2. Bind-mount two host folders into the LXC, one for the mirror and one for
   deleted files:

   ```text
   mp0: /mnt/pve/Downloads/dump/Music Backup/AudioStream,mp=/music
   mp1: /mnt/pve/Downloads/dump/MusicTrash,mp=/music-trash
   ```

3. Give the LXC SSH access to the iPhone. Generate a key inside it, then add
   the public key to `~/.ssh/authorized_keys` for `mobile` on the iPhone:

   ```bash
   pct exec 110 -- ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
   pct exec 110 -- ssh mobile@192.168.1.2 'ls /var/mobile/Documents/AudioStreamMusic | head'
   ```

4. Install the services inside the LXC. `deploy_nas.sh` pushes the binary and
   the sync script, but the units are installed once:

   ```bash
   cd Server/NAS
   scp music-server.service music-sync.service music-sync.timer proxmox:/tmp/
   ssh proxmox 'pct push 110 /tmp/music-server.service /etc/systemd/system/music-server.service && \
     pct push 110 /tmp/music-sync.service /etc/systemd/system/music-sync.service && \
     pct push 110 /tmp/music-sync.timer /etc/systemd/system/music-sync.timer && \
     pct exec 110 -- systemctl daemon-reload && \
     pct exec 110 -- systemctl enable --now music-server music-sync.timer'
   ```

5. Build and deploy from `Server/NAS`. This needs Go on the Mac and `pct`
   access to the Proxmox host:

   ```bash
   ./deploy_nas.sh
   ```

   The script builds for `linux/amd64`, installs the binary and
   `music-sync.sh`, restarts the server, and installs `music-health.timer` on
   the host.

6. Optional health alerts: create `/etc/music-health.env` on the Proxmox host,
   mode `600`, with the Home Assistant webhook:

   ```bash
   MUSIC_HEALTH_WEBHOOK=http://homeassistant.local:8123/api/webhook/...
   ```

   `MUSIC_STATUS_URL` overrides the checked URL. The default is
   `http://192.168.1.210:18080/api/status`.

</details>

<details>
<summary><strong>Sync</strong></summary>

`music-sync.timer` runs `/usr/local/bin/music-sync.sh` every 30 minutes inside
the LXC.

- rsync over SSH from `mobile@192.168.1.2:/var/mobile/Documents/AudioStreamMusic/`
- `--size-only` so unchanged files are not re-read
- `--delete` with `--backup --backup-dir=/music-trash/YYYY-MM-DD`, kept 30 days
- refuses to run when the iPhone is unreachable or reports fewer than 100 files
- `--iconv=UTF-8,UTF-8-MAC` for macOS filenames
- writes `/var/lib/music-server/sync-status.json` with the result, file counts,
  free space and last success

</details>

<details>
<summary><strong>Monitoring</strong></summary>

`music-health.timer` runs on the Proxmox host every 5 minutes and checks
`/api/status`. It sends a Home Assistant webhook alert when:

- the server does not respond
- the last sync failed
- the sync timer has not run for 90 minutes
- no sync has succeeded for 24 hours
- the server sees fewer than 100 songs
- the share has less than 10 GB free

Alerts repeat at most every 6 hours for the same condition. The webhook lives in
`/etc/music-health.env` (mode `600`) and is not stored in this repository.

</details>

<details>
<summary><strong>Endpoints</strong></summary>

The NAS serves the same API as the iPhone daemon:

- `GET /api/ping`
- `GET /api/status` (adds the last sync result)
- `GET /api/songs` (`?refresh=true` rescans first)
- `GET /api/playlists` (empty; date playlists are generated in the app)
- `GET /api/rescan`, `GET /api/refresh`
- `GET /music/<path>` with HTTP Range support
- `GET /artwork/<persistentId>`

There is no authentication. Keep it on the local network.

</details>

<details>
<summary><strong>Client</strong></summary>

Set the app's server URL to `http://192.168.1.210:18080`. While it points at the
NAS the app does not wake the iPhone or add `iphone.local` as a fallback.

To use the iPhone again, set the URL to `http://iphone.local:18080` and turn on
**Allow Auto-Start** in RemoteCompanion under Settings > Add-ons > AudioStream.

</details>

<details>
<summary><strong>Operations</strong></summary>

```bash
pct exec 110 -- systemctl status music-server
pct exec 110 -- journalctl -u music-server -n 50
pct exec 110 -- cat /var/lib/music-server/sync-status.json
pct exec 110 -- systemctl start music-sync.service   # sync now
curl http://192.168.1.210:18080/api/rescan           # rescan now
```

</details>

<details>
<summary><strong>Limitations</strong></summary>

- Read-only. Delete songs on the iPhone; the next sync moves them to
  `/music-trash`.
- Custom playlists are not mirrored. Date playlists are generated in the app.
- FLAC, WAV and AIFF durations are 0; the mirror is M4A/MP3.

</details>

Full reference: [`Server/NAS/README.md`](Server/NAS/README.md).

</details>

---

## HTTP API

The streaming daemon (`audiostreamerd`) exposes a lightweight HTTP API on port `18080`.

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/songs` | Returns all songs from the iTunes library and custom folders as a JSON array. |
| `GET` | `/api/playlists` | Returns all native iTunes playlists and autogenerated smart playlists. |
| `GET` | `/music/<filename>` | Streams an audio file. Supports HTTP range requests for efficient scrubbing. |
| `GET` | `/artwork/<persistentId>` | Serves embedded album artwork or falls back to a folder image. |

Example:

```bash
curl http://iphone.local:18080/api/songs > songs.json
```

---

## CLI Administration

Once deployed, the daemon is controlled from the device terminal:

```bash
# Start the streaming server
audiostream start

# Start with battery-saving auto-off (10-min idle timeout)
audiostream start --auto-off

# Stop the streaming server
audiostream stop

# Check whether the server is running
audiostream status
```
---

## iPad

<p align="center">
  <img src="images/ipad_1.png" width="40%" alt="iPad 1" />
  <img src="images/ipad_2.png" width="40%" alt="iPad 2" />
</p>

---

## Browser

<p align="center">
  <img src="images/screenshot_browser.png" width="100%" alt="Browser" />
</p>

---

## Apple Watch & Remote Controls

AudioStream maps system Now Playing remote feedback actions to in-app functions, available from the Apple Watch "..." (More) menu and the iOS Lock Screen.

| Watch Menu Label | Action |
|:---|:---|
| Play More Like This | Queue Album — adds remaining tracks from the active album to the queue. |
| Bookmark | Queue Artist — queues and shuffles all songs by the active track's artist. |
| Play Less Like This | Shuffle All — shuffles the entire library and starts playback immediately. |

Standard controls (shuffle, repeat, scrubbing, queue index) are fully supported and sync bidirectionally.

---

## Requirements & Setup

- Xcode 15.0 or later
- iOS 14.6 or later (deployment target)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Jailbroken iOS device with `appinst`, `sbdidlaunch`, and `sshpass` available

### Install via Sileo / Zebra

Add the AudioStream Repo to your package manager of choice:

- **Repository URL:** `https://saihgupr.github.io/audiostream/`

- **Sileo:** `sileo://source/https://saihgupr.github.io/audiostream/`
- **Zebra:** `zbra://sources/add/https://saihgupr.github.io/audiostream/`

Once added, search for **AudioStream** and tap Install.

### Generate the Xcode project

```bash
xcodegen generate
```

### Build and deploy

The repo includes deployment scripts (not tracked in source control) that automate the archive, IPA packaging, ad-hoc codesign, installation, and daemon deployment over SSH.

```bash
export DEVICE_PASS=yourpassword
./deploy.sh          # Deploy to iPhone
./deploy.sh ipad     # Deploy to iPad (set IPAD_HOST env var)
```

The scripts compile the streaming daemon (`audiostreamerd`) directly using `swiftc`, sign it with the required entitlements via `ldid`, and install the CLI helper to `/var/jb/usr/bin/audiostream`.

---

## Repository Structure

```
App/                  Application entry point, Info.plist, entitlements, assets
Models/               Codable data structures (Track, Album, Playlist, ServerSong)
Services/
  AudioPlayerService        AVPlayer wrapper for local and network streaming
  AlbumMergeService         Album merge group management and application
  ArtistMergeService        Artist merge group management and application
  ArtworkDownloadService    Apple Music and MusicBrainz album art downloader
  LocalFileLibraryScanner   Filesystem crawler, metadata parsing, artwork cache
  MusicLibraryService       iTunes library queries and remote HTTP endpoints
  MusicMigrationService     Library migration and embedded artwork extraction
  MusicServerManager        Daemon toggle and auto-off control
  ServerConnectionService   Network discovery and connection state tracking
  NavigationManager         Tab routing state
Server/
  Daemon/             Daemon entry point and filesystem scanner (main.swift)
  Core/               HTTP server and web UI (MusicServerCore, MusicServerHTML)
  NAS/                Optional Proxmox LXC server, sync scripts and health checks
UI/
  Components/         MiniPlayer, AlbumCard, CustomTabBar, RemoteImage,
                      PlaylistArtworkView, AlbumMergeSheet, ArtistMergeSheet
  Views/              ContentView, LibraryView, NowPlayingView, SettingsView,
                      SearchView, ArtistDetailView, AlbumDetailView,
                      MergeManagementView
project.yml           XcodeGen project specification
audiostream           CLI helper script for device administration
CHANGELOG.md          Project changelog
README_SETUP.md       Manual setup and configuration reference
```

---

## Entitlements

Reading the system iTunes SQLite database requires specific private entitlements, necessitating jailbroken deployment:

- `com.apple.private.security.no-sandbox = true`
- `kTCCServiceAppleMusic = allowed`
- `com.apple.security.network.server = true`
- `com.apple.security.network.client = true`

---

## Contributing

Issues and pull requests are welcome. Please use the [develop branch](https://github.com/saihgupr/AudioStream/tree/develop) for all contributions. Open an [issue](https://github.com/saihgupr/AudioStream/issues) to discuss significant changes before submitting a PR.

---

## Support

For questions or bug reports, open a [GitHub Issue](https://github.com/saihgupr/AudioStream/issues).

If AudioStream is useful to you, consider supporting via [Ko-fi](https://ko-fi.com/saihgupr).

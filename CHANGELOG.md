# Changelog

All notable changes to AudioStream will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- **RemoteCompanion add-on**: AudioStream now ships `audiostream.json`, a RemoteCompanion add-on with actions for Transfer Playback, Shuffle All, Queue Album, Queue Artist, Delete Current Song, Play Playlist, Start and Stop, a Running condition, and an Allow Auto-Start setting. Transfer Playback opens `audiostream://handoff`, so the same action works from the app, a hardware button, or the command line. It installs with the package and only appears while AudioStream is installed. The `audiostream` command gained `wake`, `shuffle`, `queuealbum`, `queueartist`, `deletesong`, `playlist` and `is-running` for the add-on to call.
- **NAS Music Server**: added `Server/NAS`, a small Go HTTP server that serves the mirrored library from an always-on Proxmox LXC. The mirror is refreshed from the iPhone over rsync every 30 minutes, with a 30-day trash folder for deleted or replaced files.
- **NAS Sync Monitoring**: `/api/status` now reports the last sync result, counts, and free space. A Proxmox host timer checks it every 5 minutes and sends a Home Assistant notification if the server, sync, storage, or library count is unhealthy.
- **AirPlay Button in Now Playing**: Added a native AirPlay route picker (`AVRoutePickerView`) to `NowPlayingView` in a bottom utility row below the playback controls, matching Apple Music placement. Available in both portrait and landscape layouts, balanced with the device transfer button. The icon matches the volume button styling: white while actively casting, dimmed grey otherwise.
- **Playback Handoff Between Devices**: The speaker button in the now playing utility row is now a transfer button. It stores the playback session on the library server, then pauses the sending device one second later so the other device is already playing before this one goes quiet. The other device picks it up automatically within a second and starts playing the same track at the same position, with the same queue order, shuffle state, and repeat mode. Queue entries are keyed by library-relative file path so the NAS mirror and the iPhone local library resolve to the same songs even though their internal track IDs differ. The receiving app long-polls `/api/session`, so delivery is immediate instead of waiting for a timer and nothing runs while the app is backgrounded. A RemoteCompanion add-on is included so the transfer can be bound to a hardware button.
- **Album Cover Art Downloader**: Long-press on the album cover in `AlbumDetailView` (including placeholder/grey covers) to open a context menu and download high-resolution album artwork.
  - Automatically searches Apple Music / iTunes and MusicBrainz APIs using clean artist and album metadata.
  - Automatically saves `cover.jpg` directly into the album's local folder so future library scans and the streaming daemon recognize it permanently.
  - Updates in-memory and disk caches (`LocalFileArtworkCache`, `ImageLoader`, and `Documents/AlbumArtwork`), immediately refreshing the cover across `AlbumDetailView`, `LibraryView`, `NowPlayingView`, and `AlbumCard`.
  - **Manual Artwork Search**: Added a dedicated search sheet to search Apple Music using custom search terms when automated tag matching needs manual adjustment.
- **Track & Album Context Menus**: Added long-press context menus across library views and track lists for quick queuing, playing, and managing items.
- **In-Place Album Merging**: Streamlined album merge mode with selection badges, primary target labels, and direct merge action without leaving the main library grid.

### Fixed
- **Remote Wake Uses the Add-on**: the app asks RemoteCompanion to run `audiostream wake` through its command endpoint instead of the old `/api/audiostream/start` route. The wake command only starts a server that is down, so a streaming server is not restarted.
- **NAS-Only Streaming No Longer Wakes the iPhone**: the app now only sends RemoteCompanion wake requests and adds `iphone.local` as a fallback when the configured server is actually an iPhone. A NAS timeout no longer starts the iPhone streaming daemon.
- **NAS Stream URL Encoding**: fixed stream URLs being percent-encoded twice (`%2520`), which the iPhone daemon tolerated but the NAS server rejected with a 404. The NAS server also accepts legacy double-encoded paths so older app builds keep working.
- **Quick Action Fetch Lifetime**: the library service is now kept alive while Shuffle All fetches are in flight, so quick actions no longer receive an empty library.
- **Cold Launch Quick Actions Retry Until Library Ready**: Home Screen quick actions (`Shuffle All`, `Recently Added`, `Random Album`) fired their library fetch immediately on cold launch, racing server wake/auto-connect and local scan, so the first tap opened the app but silently played nothing. Each handler now retries up to 3 times at 1.5s intervals on failure or empty results.
- **Downloaded Covers Now Reach Remote Clients**: Fixed three compounding caches that hid freshly downloaded `cover.jpg` files from remote clients. The daemon revalidates its negative artwork cache with a folder probe instead of 404ing forever, clears all artwork caches on rescan, and honors `?refresh=1` on `/artwork/<id>`; clients no longer cache HTTP error bodies as artwork (retry can succeed), evict undecodable disk entries, and notify the daemon after each download.
- **Remote Artwork No Longer Flips to Grey**: Failed or cancelled refetches (e.g. after the connection settles on a different host spelling and rebuilds artwork URLs) no longer wipe the loaded image, stale cell-reuse completions are ignored, and album artwork IDs are picked deterministically so refreshes yield stable URLs.
- **Playlist Collage Tiles Match Album Art**: The 2x2 playlist collage now picks tile artwork with the same deterministic ordering as the album grid, so remote tiles resolve instead of 404ing grey. The image disk cache also uses a stable filename hash, so cached art survives app restarts instead of refetching every cold start.
- **Dead Home Screen Quick Actions Replaced with Random Album**: `Queue Album` and `Queue Artist` shortcuts silently did nothing on cold launch (both require a current track). Replaced them with a single `Random Album` shortcut that picks a random album from the library and starts playback from the first track.
- **Missing Artwork on Imported Albums**: Fixed placeholder/grey background on imported songs that lacked embedded artwork tags by enabling on-demand artwork downloading and caching.
- **Local File Metadata Resolution**: Improved track number extraction and fallback artwork resolution from `cover.jpg` / `folder.jpg` in local folders.
- **Auto-Connect Stability**: Improved reconnect logic and state restoration when switching between local playback and network streaming.

### Changed
- **Faster Library Launch**: the remote library cache now stores each track once, rehydrates URLs with dictionary lookups instead of linear playlist scans, and keeps a decoded in-memory snapshot. Cold-start album rendering on iPad dropped from ~2.9s to under a second.
- **Single Library Fetch at Launch**: remote refresh now downloads `/api/songs` once and builds albums, tracks, and playlists from that response instead of fetching the full song list twice.
- **Faster Streaming Server Requests**: the daemon now caches merged song results and the serialized `/api/songs` payload, and applies album/artist merge groups through lookup tables. Warm `/api/songs` responses dropped from ~2s to ~20ms.
- **Battery Saver Mode**: Optimized streaming daemon auto-off idle monitor to shut down background server after inactivity timeout, preserving battery life.

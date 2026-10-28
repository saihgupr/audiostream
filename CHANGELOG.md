# Changelog

All notable changes to AudioStream will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- **Album Cover Art Downloader**: Long-press on the album cover in `AlbumDetailView` (including placeholder/grey covers) to open a context menu and download high-resolution album artwork.
  - Automatically searches Apple Music / iTunes and MusicBrainz APIs using clean artist and album metadata.
  - Automatically saves `cover.jpg` directly into the album's local folder so future library scans and the streaming daemon recognize it permanently.
  - Updates in-memory and disk caches (`LocalFileArtworkCache`, `ImageLoader`, and `Documents/AlbumArtwork`), immediately refreshing the cover across `AlbumDetailView`, `LibraryView`, `NowPlayingView`, and `AlbumCard`.
  - **Manual Artwork Search**: Added a dedicated search sheet to search Apple Music using custom search terms when automated tag matching needs manual adjustment.
- **Track & Album Context Menus**: Added long-press context menus across library views and track lists for quick queuing, playing, and managing items.
- **In-Place Album Merging**: Streamlined album merge mode with selection badges, primary target labels, and direct merge action without leaving the main library grid.

### Fixed
- **Downloaded Covers Now Reach Remote Clients**: Fixed three compounding caches that hid freshly downloaded `cover.jpg` files from remote clients. The daemon revalidates its negative artwork cache with a folder probe instead of 404ing forever, clears all artwork caches on rescan, and honors `?refresh=1` on `/artwork/<id>`; clients no longer cache HTTP error bodies as artwork (retry can succeed), evict undecodable disk entries, and notify the daemon after each download.
- **Remote Artwork No Longer Flips to Grey**: Failed or cancelled refetches (e.g. after the connection settles on a different host spelling and rebuilds artwork URLs) no longer wipe the loaded image, stale cell-reuse completions are ignored, and album artwork IDs are picked deterministically so refreshes yield stable URLs.
- **Playlist Collage Tiles Match Album Art**: The 2x2 playlist collage now picks tile artwork with the same deterministic ordering as the album grid, so remote tiles resolve instead of 404ing grey. The image disk cache also uses a stable filename hash, so cached art survives app restarts instead of refetching every cold start.
- **Dead Home Screen Quick Actions Replaced with Random Album**: `Queue Album` and `Queue Artist` shortcuts silently did nothing on cold launch (both require a current track). Replaced them with a single `Random Album` shortcut that picks a random album from the library and starts playback from the first track.
- **Missing Artwork on Imported Albums**: Fixed placeholder/grey background on imported songs that lacked embedded artwork tags by enabling on-demand artwork downloading and caching.
- **Local File Metadata Resolution**: Improved track number extraction and fallback artwork resolution from `cover.jpg` / `folder.jpg` in local folders.
- **Auto-Connect Stability**: Improved reconnect logic and state restoration when switching between local playback and network streaming.

### Changed
- **Battery Saver Mode**: Optimized streaming daemon auto-off idle monitor to shut down background server after inactivity timeout, preserving battery life.

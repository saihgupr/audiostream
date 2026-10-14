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
- **Missing Artwork on Imported Albums**: Fixed placeholder/grey background on imported songs that lacked embedded artwork tags by enabling on-demand artwork downloading and caching.
- **Local File Metadata Resolution**: Improved track number extraction and fallback artwork resolution from `cover.jpg` / `folder.jpg` in local folders.
- **Auto-Connect Stability**: Improved reconnect logic and state restoration when switching between local playback and network streaming.

### Changed
- **Battery Saver Mode**: Optimized streaming daemon auto-off idle monitor to shut down background server after inactivity timeout, preserving battery life.

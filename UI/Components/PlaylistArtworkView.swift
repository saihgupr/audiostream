import SwiftUI

struct PlaylistArtworkView: View {
    let tracks: [Track]
    let size: CGFloat
    let playlistId: String
    
    // Fallback configurations
    var fallbackSystemName: String = "music.note.list"
    var fallbackBgColor: Color = Color.gray.opacity(0.3)
    var fallbackFgColor: Color = .white
    
    private func stableHash(_ string: String) -> Int {
        var hash = 5381
        for scalar in string.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return hash
    }
    
    private func primaryArtist(from artist: String) -> String {
        let lower = artist.lowercased()
        let delimiters = [" feat.", " ft.", " featuring ", " & ", ", "]
        var result = lower
        for delim in delimiters {
            if let range = result.range(of: delim) {
                result = String(result[..<range.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func albumKey(for track: Track) -> String {
        let cleanAlbum = track.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        // If no album name or placeholder, treat as individual track so standalone singles don't collide
        guard !cleanAlbum.isEmpty,
              cleanAlbum != "unknown",
              cleanAlbum != "unknown album",
              cleanAlbum != "single",
              cleanAlbum != "singles" else {
            return "track_\(track.persistentId)"
        }
        
        let genericTitles: Set<String> = [
            "greatest hits", "the greatest hits",
            "best of", "the best of",
            "anthology", "live", "ep",
            "remixes", "the remixes",
            "self-titled"
        ]
        
        if genericTitles.contains(cleanAlbum) {
            let cleanArtist: String
            if let albumArtist = track.albumArtist, !albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cleanArtist = albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            } else {
                cleanArtist = primaryArtist(from: track.artist)
            }
            return "\(cleanAlbum)__\(cleanArtist)"
        }
        
        return cleanAlbum
    }

    private var artworkUrls: [URL] {
        let processedTracks = AlbumMergeService.shared.process(tracks: tracks)
        
        // Group tracks by unique album key
        var albumTrackMap: [String: [Track]] = [:]
        for track in processedTracks {
            let key = albumKey(for: track)
            albumTrackMap[key, default: []].append(track)
        }
        
        // For each album key, find an artwork URL from its tracks.
        // Sort each group with Track.compareTrackOrder first so the tile pick
        // matches the album grid's deterministic pick (MusicLibraryService.fetchAlbums).
        var albumArtworkMap: [String: URL] = [:]
        for (key, albumTracks) in albumTrackMap {
            let ordered = albumTracks.sorted(by: Track.compareTrackOrder)
            if let url = ordered.compactMap({ $0.artworkUrl }).first {
                albumArtworkMap[key] = url
            }
        }
        
        // Sort album keys deterministically based on a combined hash of albumKey + playlistId.
        // This ensures distinct collages for different playlists without causing view scroll flicker.
        let sortedKeys = albumArtworkMap.keys.sorted { lhs, rhs in
            let lhsHash = stableHash("\(lhs)-\(playlistId)")
            let rhsHash = stableHash("\(rhs)-\(playlistId)")
            if lhsHash != rhsHash {
                return lhsHash < rhsHash
            }
            return lhs < rhs
        }
        
        var urls: [URL] = []
        var seenUrls: Set<URL> = []
        for key in sortedKeys {
            if let url = albumArtworkMap[key], !seenUrls.contains(url) {
                seenUrls.insert(url)
                urls.append(url)
                if urls.count == 4 {
                    break
                }
            }
        }
        return urls
    }
    
    var body: some View {
        let urls = artworkUrls
        
        Group {
            if urls.isEmpty {
                // Fallback icon
                ZStack {
                    fallbackBgColor
                    Image(systemName: fallbackSystemName)
                        .font(.system(size: size * 0.45))
                        .foregroundColor(fallbackFgColor)
                }
                .frame(width: size, height: size)
            } else if urls.count == 1 {
                // Single artwork
                RemoteImage(url: urls[0])
                    .frame(width: size, height: size)
            } else if urls.count == 2 {
                // 2 artworks: Split vertical columns
                HStack(spacing: 0) {
                    RemoteImage(url: urls[0])
                        .frame(width: size / 2, height: size)
                        .clipped()
                    RemoteImage(url: urls[1])
                        .frame(width: size / 2, height: size)
                        .clipped()
                }
                .frame(width: size, height: size)
            } else if urls.count == 3 {
                // 3 artworks: Masonry collage
                // Left half: 1 large image. Right half: 2 stacked vertically
                HStack(spacing: 0) {
                    RemoteImage(url: urls[0])
                        .frame(width: size / 2, height: size)
                        .clipped()
                    VStack(spacing: 0) {
                        RemoteImage(url: urls[1])
                            .frame(width: size / 2, height: size / 2)
                            .clipped()
                        RemoteImage(url: urls[2])
                            .frame(width: size / 2, height: size / 2)
                            .clipped()
                    }
                }
                .frame(width: size, height: size)
            } else {
                // 4 artworks: 2x2 grid
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        RemoteImage(url: urls[0])
                            .frame(width: size / 2, height: size / 2)
                            .clipped()
                        RemoteImage(url: urls[1])
                            .frame(width: size / 2, height: size / 2)
                            .clipped()
                    }
                    HStack(spacing: 0) {
                        RemoteImage(url: urls[2])
                            .frame(width: size / 2, height: size / 2)
                            .clipped()
                        RemoteImage(url: urls[3])
                            .frame(width: size / 2, height: size / 2)
                            .clipped()
                    }
                }
                .frame(width: size, height: size)
            }
        }
    }
}

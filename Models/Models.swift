import Foundation
import Combine

enum LibrarySource: String, Codable, CaseIterable, Identifiable {
    case remote
    case local
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .remote: return "Remote Server"
        case .local: return "This Device"
        }
    }
}

struct Track: Identifiable, Codable, Equatable {
    let id: Int64
    let persistentId: String
    let title: String
    var artist: String
    var album: String
    let filename: String
    let duration: TimeInterval
    var dateAdded: Date?
    
    // Computed properties to help with UI binding, generated at runtime based on server URL
    var artworkUrl: URL?
    var streamUrl: URL?
    
    // Optional fields (encoded/decoded from remote JSON if present)
    var albumArtist: String?
    var trackNumber: Int?
    
    enum CodingKeys: String, CodingKey {
        case id, persistentId, title, artist, album, filename, duration, dateAdded, trackNumber
    }
    
    init(id: Int64, persistentId: String, title: String, artist: String, album: String, filename: String, duration: TimeInterval, dateAdded: Date? = nil, artworkUrl: URL? = nil, streamUrl: URL? = nil, albumArtist: String? = nil, trackNumber: Int? = nil) {
        self.id = id
        self.persistentId = persistentId
        self.title = title
        self.artist = artist
        self.album = album
        self.filename = filename
        self.duration = duration
        self.dateAdded = dateAdded
        self.artworkUrl = artworkUrl
        self.streamUrl = streamUrl
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        persistentId = try container.decode(String.self, forKey: .persistentId)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        album = try container.decode(String.self, forKey: .album)
        filename = try container.decode(String.self, forKey: .filename)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        
        if let timestamp = try? container.decode(Double.self, forKey: .dateAdded) {
            dateAdded = Date(timeIntervalSince1970: timestamp)
        } else if let date = try? container.decode(Date.self, forKey: .dateAdded) {
            dateAdded = date
        } else {
            dateAdded = nil
        }
        
        let decodedTrackNum = try? container.decodeIfPresent(Int.self, forKey: .trackNumber)
        trackNumber = decodedTrackNum ?? Track.extractTrackNumberFromFilename(filename)
    }
}

extension Track {
    private static let discTrackRegex = try! NSRegularExpression(pattern: "^\\d+[._-](\\d{1,3})(?![0-9A-Za-z])")
    private static let leadingNumRegex = try! NSRegularExpression(pattern: "^(?:track|trk)?\\s*(\\d{1,3})(?![0-9A-Za-z])", options: .caseInsensitive)

    static func extractTrackNumberFromFilename(_ filename: String) -> Int? {
        let base = (filename as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        
        // 1. Match disc-track numbers at start e.g. "1-01", "1.01", "1_01"
        if let match = discTrackRegex.firstMatch(in: base, range: NSRange(location: 0, length: base.utf16.count)),
           let range = Range(match.range(at: 1), in: base),
           let num = Int(base[range]), num > 0 {
            return num
        }

        // 2. Match leading numbers e.g. "01 - Title", "01. Title", "01_Title", "01 Title", "Track 01"
        if let match = leadingNumRegex.firstMatch(in: base, range: NSRange(location: 0, length: base.utf16.count)),
           let range = Range(match.range(at: 1), in: base),
           let num = Int(base[range]), num > 0 {
            return num
        }

        return nil
    }

    /// Compares two tracks to order them correctly within an album:
    /// 1. Track number (ascending)
    /// 2. Extracted filename track number (ascending)
    /// 3. Natural filename/title sorting (Finder-style localizedStandardCompare)
    static func compareTrackOrder(_ lhs: Track, _ rhs: Track) -> Bool {
        let lNum = lhs.trackNumber ?? extractTrackNumberFromFilename(lhs.filename) ?? extractTrackNumberFromFilename(lhs.title)
        let rNum = rhs.trackNumber ?? extractTrackNumberFromFilename(rhs.filename) ?? extractTrackNumberFromFilename(rhs.title)
        
        if let l = lNum, let r = rNum {
            if l != r {
                return l < r
            }
        } else if lNum != nil {
            return true
        } else if rNum != nil {
            return false
        }
        
        let lStr = lhs.filename.isEmpty ? lhs.title : lhs.filename
        let rStr = rhs.filename.isEmpty ? rhs.title : rhs.filename
        return lStr.localizedStandardCompare(rStr) == .orderedAscending
    }
}

struct Album: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var artist: String
    var artworkUrl: URL?
    var tracks: [Track]
    var dateAdded: Date?
    
    init(id: String, title: String, artist: String, artworkUrl: URL? = nil, tracks: [Track], dateAdded: Date? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artworkUrl = artworkUrl
        self.tracks = tracks
        self.dateAdded = dateAdded
    }
}

struct Playlist: Identifiable, Codable {
    let id: Int64
    let name: String
    let songIds: [Int64]
    
    // Populated client-side
    var tracks: [Track] = []
    
    enum CodingKeys: String, CodingKey {
        case id, name, songIds
    }
}

enum RepeatMode: String, Codable, CaseIterable {
    case off
    case all
    case one
}

final class PlaybackProgress: ObservableObject {
    @Published var currentTime: TimeInterval = 0
}

struct PlaybackState {
    var isPlaying: Bool = false
    var currentTrack: Track?
    var volume: Float = 1.0
    var isShuffleEnabled: Bool = false
    var repeatMode: RepeatMode = .all
}

/// Shared storage-bounding utilities for disk caches and temporary logs.
enum AppCacheStorage {
    private static let maintenanceQueue = DispatchQueue(label: "com.audiostream.cache.maintenance", qos: .utility)

    /// Trims the oldest files (by access/modification date) in a cache directory when total size exceeds `maxBytes`.
    static func pruneDirectory(_ directory: URL, maxBytes: UInt64, targetBytes: UInt64) {
        maintenanceQueue.async {
            let fm = FileManager.default
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .fileSizeKey,
                .contentAccessDateKey,
                .contentModificationDateKey
            ]
            guard let urls = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { return }

            var entries: [(url: URL, size: UInt64, date: Date)] = []
            entries.reserveCapacity(urls.count)
            var totalBytes: UInt64 = 0

            for url in urls {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true else { continue }
                let size = UInt64(max(0, values.fileSize ?? 0))
                let date = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
                totalBytes &+= size
                entries.append((url, size, date))
            }

            guard totalBytes > maxBytes else { return }
            entries.sort { $0.date < $1.date }

            for entry in entries {
                guard totalBytes > targetBytes else { break }
                if (try? fm.removeItem(at: entry.url)) != nil {
                    totalBytes = totalBytes > entry.size ? (totalBytes - entry.size) : 0
                }
            }
        }
    }

    /// Appends a timestamped log line asynchronously while keeping the log file bounded to `maxBytes`.
    static func appendBoundedLog(_ message: String, to logPath: String, maxBytes: UInt64 = 256 * 1024) {
        let timestampDate = Date()
        maintenanceQueue.async {
            let timestamp = DateFormatter.localizedString(from: timestampDate, dateStyle: .short, timeStyle: .medium)
            let logMessage = "[\(timestamp)] \(message)\n"
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: logPath),
               let fileSize = attrs[.size] as? UInt64,
               fileSize >= maxBytes {
                // Trim to the trailing half instead of deleting everything so recent context survives.
                if let handle = FileHandle(forReadingAtPath: logPath) {
                    let keepBytes = maxBytes / 2
                    let offset = fileSize > keepBytes ? fileSize - keepBytes : 0
                    try? handle.seek(toOffset: offset)
                    let tail = handle.readDataToEndOfFile()
                    handle.closeFile()
                    try? tail.write(to: URL(fileURLWithPath: logPath), options: .atomic)
                } else {
                    try? fm.removeItem(atPath: logPath)
                }
            }

            if let fileHandle = FileHandle(forWritingAtPath: logPath) {
                fileHandle.seekToEndOfFile()
                if let data = logMessage.data(using: .utf8) {
                    fileHandle.write(data)
                }
                fileHandle.closeFile()
            } else {
                try? logMessage.write(toFile: logPath, atomically: true, encoding: .utf8)
            }
        }
    }

    static func directorySizeBytes(at url: URL) -> UInt64 {
        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)),
                  values.isRegularFile == true else {
                continue
            }
            let size = UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            total += size
        }
        return total
    }

    static func fileSizeBytes(at url: URL) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else {
            return 0
        }
        return size
    }

    static func formattedByteCount(_ bytes: UInt64) -> String {
        let clamped = Int64(min(bytes, UInt64(Int64.max)))
        return ByteCountFormatter.string(fromByteCount: clamped, countStyle: .file)
    }

    static func clearDirectoryContents(at url: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return
        }
        for item in items {
            try? fm.removeItem(at: item)
        }
    }

    static func removeItemIfExists(at url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
    }
}

struct RemoteSyncStatus: Codable, Equatable {
    let result: String?
    let message: String?
    let lastAttempt: String?
    let lastSuccess: String?
    let freeKB: Double?
}

struct RemoteServerStatus: Codable, Equatable {
    let status: String
    let songsCount: Int
    let playlistsCount: Int?
    let version: String?
    let lastSync: RemoteSyncStatus?
}

enum AlbumGrouping {
    /// Extracts a normalized primary artist name without splitting multi-artist band names like "Simon & Garfunkel".
    static func primaryArtistKey(for artist: String) -> String {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown artist" }

        let lowered = trimmed.lowercased()
        for separator in [" feat. ", " ft. ", " featuring ", " (feat. ", " (ft. ", " [feat. "] {
            if let range = lowered.range(of: separator) {
                let prefix = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty {
                    return prefix.lowercased()
                }
            }
        }
        return lowered
    }

    /// Computes a stable disambiguated remote album key from album title, metadata, and relative path structure.
    static func remoteAlbumOwnerKey(albumName: String, track: Track) -> String {
        let cleanAlbum = albumName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let albumArtist = track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines),
           !albumArtist.isEmpty {
            return "\(cleanAlbum)__\(albumArtist.lowercased())"
        }

        // AudioStreamMusic / NAS paths follow Artist/Album/[Disc N/]Track.ext (>= 3 segments).
        // Avoid using iTunes F00/XXXX.mp3 2-segment directories as artist identifiers.
        let pathComponents = track.filename
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        if pathComponents.count >= 3, !pathComponents[0].isEmpty {
            return "\(cleanAlbum)__dir:\(pathComponents[0].lowercased())"
        }

        return "\(cleanAlbum)__\(primaryArtistKey(for: track.artist))"
    }
}

enum LibraryPlaylistBuilder {
    static func buildSpecialPlaylists(albums: [Album], tracks: [Track], now: Date = Date()) -> [Playlist] {
        var albumDates: [String: Date] = [:]
        for album in albums {
            if let date = album.dateAdded {
                albumDates[album.id] = date
                albumDates["\(album.title.lowercased())|\(album.artist.lowercased())"] = date
            }
        }

        var tracksWithDates: [(track: Track, date: Date)] = []
        tracksWithDates.reserveCapacity(tracks.count)

        for track in tracks {
            var trackDate: Date? = track.dateAdded
            if trackDate == nil {
                let directKey = "\(track.album.lowercased())|\(track.artist.lowercased())"
                trackDate = albumDates[directKey]
            }
            if trackDate == nil, let albumArtist = track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines), !albumArtist.isEmpty {
                let albumArtistKey = "\(track.album.lowercased())|\(albumArtist.lowercased())"
                trackDate = albumDates[albumArtistKey]
            }
            tracksWithDates.append((track, trackDate ?? Date(timeIntervalSince1970: 0)))
        }

        let sortedTracksWithDates = tracksWithDates.sorted { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date > rhs.date
            }
            return lhs.track.title.localizedCaseInsensitiveCompare(rhs.track.title) == .orderedAscending
        }

        let twoWeeksAgo = now.addingTimeInterval(-14 * 24 * 3600)
        let oneMonthAgo = now.addingTimeInterval(-30 * 24 * 3600)
        let threeMonthsAgo = now.addingTimeInterval(-90 * 24 * 3600)
        let sixMonthsAgo = now.addingTimeInterval(-180 * 24 * 3600)
        let oneYearAgo = now.addingTimeInterval(-365 * 24 * 3600)

        let recentByDate = sortedTracksWithDates.prefix { $0.date >= twoWeeksAgo }.map { $0.track }
        let recentlyAddedTracks: [Track]
        if recentByDate.count < 20 {
            recentlyAddedTracks = Array(sortedTracksWithDates.prefix(100).map { $0.track })
        } else {
            recentlyAddedTracks = Array(recentByDate.prefix(100))
        }

        let monthTracks = sortedTracksWithDates.prefix { $0.date >= oneMonthAgo }.map { $0.track }
        let threeMonthsTracks = sortedTracksWithDates.prefix { $0.date >= threeMonthsAgo }.map { $0.track }
        let sixMonthsTracks = sortedTracksWithDates.prefix { $0.date >= sixMonthsAgo }.map { $0.track }
        let yearTracks = sortedTracksWithDates.prefix { $0.date >= oneYearAgo }.map { $0.track }

        var specialPlaylists: [Playlist] = []
        if !recentlyAddedTracks.isEmpty {
            specialPlaylists.append(Playlist(id: -1, name: "Recently Added", songIds: recentlyAddedTracks.map { $0.id }, tracks: recentlyAddedTracks))
        }
        if !monthTracks.isEmpty {
            specialPlaylists.append(Playlist(id: -2, name: "Month", songIds: monthTracks.map { $0.id }, tracks: monthTracks))
        }
        if !threeMonthsTracks.isEmpty {
            specialPlaylists.append(Playlist(id: -3, name: "3 Months", songIds: threeMonthsTracks.map { $0.id }, tracks: threeMonthsTracks))
        }
        if !sixMonthsTracks.isEmpty {
            specialPlaylists.append(Playlist(id: -4, name: "6 Months", songIds: sixMonthsTracks.map { $0.id }, tracks: sixMonthsTracks))
        }
        if !yearTracks.isEmpty {
            specialPlaylists.append(Playlist(id: -5, name: "Year", songIds: yearTracks.map { $0.id }, tracks: yearTracks))
        }

        return specialPlaylists
    }

    static func combinePlaylists(userPlaylists: [Playlist], albums: [Album], tracks: [Track], source: LibrarySource, now: Date = Date()) -> [Playlist] {
        var result = userPlaylists
        if source == .remote && !result.isEmpty {
            let tracksById = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            result = result.map { playlist in
                var p = playlist
                p.tracks = playlist.songIds.compactMap { tracksById[$0] }
                return p
            }
        }

        result.removeAll { $0.id < 0 }
        let special = buildSpecialPlaylists(albums: albums, tracks: tracks, now: now)
        result.insert(contentsOf: special, at: 0)
        return result
    }
}

extension Notification.Name {
    static let trackDidDelete = Notification.Name("trackDidDelete")
    static let albumArtworkDidUpdate = Notification.Name("albumArtworkDidUpdate")
    static let mergeGroupsDidChange = Notification.Name("mergeGroupsDidChange")
    static let appStateDidRestore = Notification.Name("appStateDidRestore")
    static let libraryNeedsRefresh = Notification.Name("libraryNeedsRefresh")
}


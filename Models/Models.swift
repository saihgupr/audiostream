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
    private static let discTrackRegex = try! NSRegularExpression(pattern: "^\\d+[.-_](\\d{1,3})\\b")
    private static let leadingNumRegex = try! NSRegularExpression(pattern: "^(?:track|trk)?\\s*(\\d{1,3})\\b", options: .caseInsensitive)

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
}

extension Notification.Name {
    static let trackDidDelete = Notification.Name("trackDidDelete")
    static let albumArtworkDidUpdate = Notification.Name("albumArtworkDidUpdate")
}


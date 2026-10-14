import Foundation

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
    static func extractTrackNumberFromFilename(_ filename: String) -> Int? {
        let base = (filename as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        
        // 1. Match disc-track numbers at start e.g. "1-01", "1.01", "1_01"
        let discTrackPattern = "^\\d+[.-_](\\d{1,3})\\b"
        if let regex = try? NSRegularExpression(pattern: discTrackPattern),
           let match = regex.firstMatch(in: base, range: NSRange(location: 0, length: base.utf16.count)),
           let range = Range(match.range(at: 1), in: base),
           let num = Int(base[range]), num > 0 {
            return num
        }

        // 2. Match leading numbers e.g. "01 - Title", "01. Title", "01_Title", "01 Title", "Track 01"
        let leadingNumPattern = "^(?:track|trk)?\\s*(\\d{1,3})\\b"
        if let regex = try? NSRegularExpression(pattern: leadingNumPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: base, range: NSRange(location: 0, length: base.utf16.count)),
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

struct Album: Identifiable, Codable {
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

struct PlaybackState {
    var isPlaying: Bool = false
    var currentTrack: Track?
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var volume: Float = 1.0
    var isShuffleEnabled: Bool = false
    var repeatMode: RepeatMode = .all
}

extension Notification.Name {
    static let trackDidDelete = Notification.Name("trackDidDelete")
    static let albumArtworkDidUpdate = Notification.Name("albumArtworkDidUpdate")
}


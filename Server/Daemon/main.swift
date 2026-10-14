import Foundation
import Network
import SQLite3
import AVFoundation

struct AlbumIdentifier: Codable, Hashable {
    let title: String
    let artist: String
    
    func matches(title otherTitle: String, artist otherArtist: String) -> Bool {
        let cleanSelfTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSelfArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOtherTitle = otherTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOtherArtist = otherArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleanSelfTitle.localizedCaseInsensitiveCompare(cleanOtherTitle) == .orderedSame &&
               cleanSelfArtist.localizedCaseInsensitiveCompare(cleanOtherArtist) == .orderedSame
    }
}

struct MergeGroup: Codable, Hashable {
    let id: UUID
    var members: Set<AlbumIdentifier>
    var memberAlbumIds: Set<String>?
    var targetTitle: String
    var targetArtist: String
}

struct ArtistMergeGroup: Codable, Hashable {
    let id: UUID
    var members: Set<String>
    var targetArtist: String
}

struct CachedSongMetadata: Codable {
    let id: Int64
    let persistentId: UInt64
    let title: String
    let artist: String
    let album: String
    let filename: String
    let duration: TimeInterval
    let dateAdded: TimeInterval?
    let trackNumber: Int?
    let modDate: TimeInterval
    let fileSize: Int64
}

// MARK: - Daemon Manager
class AudioStreamerDaemon {
    private let port: UInt16 = 18080
    private let musicBasePaths = [
        "/var/mobile/Documents/AudioStreamMusic",
        "/private/var/mobile/Documents/AudioStreamMusic",
        "/var/mobile/Media/iTunes_Control/Music/Filza",
        "/private/var/mobile/Media/iTunes_Control/Music/Filza",
        "/var/mobile/Media/Purchases",
        "/private/var/mobile/Media/Purchases"
    ]
    private let dbPath = "/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
    private let customMusicFolder = "/var/mobile/Documents/AudioStreamMusic"
    
    private let cacheFileUrl: URL = {
        let preferredDir = URL(fileURLWithPath: "/var/mobile/Documents/AudioStreamMusic")
        if FileManager.default.fileExists(atPath: preferredDir.path) {
            return preferredDir.appendingPathComponent(".daemon_metadata_cache.json")
        }
        return URL(fileURLWithPath: "/tmp/audiostream_metadata_cache.json")
    }()
    private var persistentCache: [String: CachedSongMetadata] = [:]
    private let songsLock = NSLock()
    
    // Cached counts for ultra-fast, lock-free /api/ping probes
    private var cachedSongsCount: Int = 0
    private var cachedPlaylistsCount: Int = 0
    private let countsLock = NSLock()
    
    // Cached merge groups with modification timestamp checking
    private var cachedAlbumGroups: [MergeGroup] = []
    private var cachedArtistGroups: [ArtistMergeGroup] = []
    private var lastAlbumGroupsModDate: Date? = nil
    private var lastArtistGroupsModDate: Date? = nil
    private let mergeGroupsLock = NSLock()
    
    private var httpServer: SimpleHTTPServer?
    private var songs: [Song] = []
    private var playlists: [Playlist] = []
    private var songFilePaths: [UInt64: String] = [:]
    
    private func updateCachedCounts(songs: Int? = nil, playlists: Int? = nil) {
        countsLock.lock()
        defer { countsLock.unlock() }
        if let s = songs { cachedSongsCount = s }
        if let p = playlists { cachedPlaylistsCount = p }
    }
    
    private func getCachedSongsCount() -> Int {
        countsLock.lock()
        defer { countsLock.unlock() }
        return cachedSongsCount
    }
    
    private func getCachedPlaylistsCount() -> Int {
        countsLock.lock()
        defer { countsLock.unlock() }
        return cachedPlaylistsCount
    }
    
    private func getCachedMergeGroups() -> ([MergeGroup], [ArtistMergeGroup]) {
        mergeGroupsLock.lock()
        defer { mergeGroupsLock.unlock() }
        
        let fm = FileManager.default
        let sharedMergeGroupsPath = "/tmp/audiostream_mergegroups.json"
        let sharedArtistGroupsPath = "/tmp/audiostream_artistmergegroups.json"
        
        // Album groups check
        if fm.fileExists(atPath: sharedMergeGroupsPath) {
            let modDate = (try? fm.attributesOfItem(atPath: sharedMergeGroupsPath))?[.modificationDate] as? Date
            if modDate != lastAlbumGroupsModDate {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: sharedMergeGroupsPath)),
                   let groups = try? JSONDecoder().decode([MergeGroup].self, from: data) {
                    cachedAlbumGroups = groups
                    lastAlbumGroupsModDate = modDate
                }
            }
        } else {
            cachedAlbumGroups = []
            lastAlbumGroupsModDate = nil
        }
        
        // Artist groups check
        if fm.fileExists(atPath: sharedArtistGroupsPath) {
            let modDate = (try? fm.attributesOfItem(atPath: sharedArtistGroupsPath))?[.modificationDate] as? Date
            if modDate != lastArtistGroupsModDate {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: sharedArtistGroupsPath)),
                   let groups = try? JSONDecoder().decode([ArtistMergeGroup].self, from: data) {
                    cachedArtistGroups = groups
                    lastArtistGroupsModDate = modDate
                }
            }
        } else {
            cachedArtistGroups = []
            lastArtistGroupsModDate = nil
        }
        
        return (cachedAlbumGroups, cachedArtistGroups)
    }
    
    private func loadPersistentCache() {
        guard let data = try? Data(contentsOf: cacheFileUrl),
              let decoded = try? JSONDecoder().decode([String: CachedSongMetadata].self, from: data) else {
            return
        }
        self.persistentCache = decoded
        self.updateCachedCounts(songs: decoded.count)
        serverLog("Loaded \(decoded.count) cached song entries from \(cacheFileUrl.path)")
    }
    
    private func savePersistentCache() {
        if let encoded = try? JSONEncoder().encode(persistentCache) {
            try? encoded.write(to: cacheFileUrl)
        }
    }
    
    func start() {
        signal(SIGPIPE, SIG_IGN)
        serverLog("=== AudioStreamer Daemon Starting ===")
        loadPersistentCache()
        
        // Open HTTP server listener immediately so port 18080 is available for health checks right away
        httpServer = SimpleHTTPServer(
            port: port,
            musicBasePaths: musicBasePaths,
            songsProvider: { [weak self] in
                guard let self = self else { return [] }
                self.songsLock.lock()
                defer { self.songsLock.unlock() }
                return self.applyMergeGroups(to: self.songs)
            },
            playlistsProvider: { [weak self] in
                guard let self = self else { return [] }
                self.songsLock.lock()
                defer { self.songsLock.unlock() }
                return self.playlists
            },
            songFilePathsProvider: { [weak self] in
                guard let self = self else { return [:] }
                self.songsLock.lock()
                defer { self.songsLock.unlock() }
                return self.songFilePaths
            },
            songsCountProvider: { [weak self] in
                self?.getCachedSongsCount() ?? 0
            },
            playlistsCountProvider: { [weak self] in
                self?.getCachedPlaylistsCount() ?? 0
            },
            deleteHandler: { [weak self] type, params in
                guard let self = self else { return false }
                if type == "song" {
                    if let idNum = (params["id"] as? NSNumber)?.int64Value {
                        return self.deleteSong(id: idNum)
                    } else if let idStr = params["id"] as? String, let idNum = Int64(idStr) {
                        return self.deleteSong(id: idNum)
                    }
                } else if type == "album" {
                    if let album = params["album"] as? String, let artist = params["artist"] as? String {
                        return self.deleteAlbum(title: album, artist: artist)
                    }
                }
                return false
            },
            rescanHandler: { [weak self] _ in
                guard let self = self else { return }
                serverLog("Triggered fast rescan")
                self.loadSongs(forceRefresh: false)
            }
        )
        httpServer?.start()
        serverLog("HTTP Server listener started on port \(port)")
        
        // Synchronously load full song library
        self.loadSongs()
        serverLog("Daemon loaded \(self.songs.count) songs and \(self.playlists.count) playlists.")
        serverLog("Daemon is running on port \(port).")
        
        // Keep the daemon alive indefinitely
        dispatchMain()
    }
    
    func loadSongs(forceRefresh: Bool = false) {
        songsLock.lock()
        defer { songsLock.unlock() }
        
        // 1. Load native iTunes database tracks
        let itunesSongs = loadITunesSongs()
        
        // 2. Scan custom files in /var/mobile/Documents/AudioStreamMusic
        let customSongs = scanCustomMusicFolder(forceRefresh: forceRefresh)
        
        // Deduplicate: prefer custom files if title + artist + album matches
        var seenKeys = Set<String>()
        var dedupedCustom: [Song] = []
        for song in customSongs {
            let key = "\(song.title.lowercased())|\(song.artist.lowercased())|\(song.album.lowercased())"
            seenKeys.insert(key)
            dedupedCustom.append(song)
        }
        
        var dedupedITunes: [Song] = []
        for song in itunesSongs {
            let key = "\(song.title.lowercased())|\(song.artist.lowercased())|\(song.album.lowercased())"
            if !seenKeys.contains(key) {
                dedupedITunes.append(song)
            }
        }
        
        var loadedSongs = dedupedCustom + dedupedITunes
        serverLog("Loaded total \(loadedSongs.count) songs (\(dedupedITunes.count) iTunes, \(dedupedCustom.count) custom files)")
        
        // Sort songs by artist, album, track number / title
        loadedSongs.sort { s1, s2 in
            if s1.artist != s2.artist {
                return s1.artist.localizedCaseInsensitiveCompare(s2.artist) == .orderedAscending
            }
            if s1.album != s2.album {
                return s1.album.localizedCaseInsensitiveCompare(s2.album) == .orderedAscending
            }
            let t1 = s1.trackNumber ?? 0
            let t2 = s2.trackNumber ?? 0
            if t1 != t2 && t1 > 0 && t2 > 0 {
                return t1 < t2
            }
            return s1.title.localizedCaseInsensitiveCompare(s2.title) == .orderedAscending
        }
        
        // Map songFilePaths for artwork/stream lookup
        var map: [UInt64: String] = [:]
        for song in loadedSongs {
            map[song.persistentId] = song.filename
        }
        
        self.songs = loadedSongs
        self.songFilePaths = map
        self.updateCachedCounts(songs: loadedSongs.count)
        loadPlaylists()
    }
    
    private func loadITunesSongs() -> [Song] {
        var db: OpaquePointer?
        if sqlite3_open_v2(self.dbPath, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            serverLog("Failed to open DB: \(errorMsg)")
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        
        let query = """
            SELECT ie.item_pid, ie.title, ia.item_artist, a.album, ie.location, ie.total_time_ms, i.persistent_id
            FROM item_extra ie 
            JOIN item i ON ie.item_pid = i.item_pid 
            LEFT JOIN item_artist ia ON i.item_artist_pid = ia.item_artist_pid 
            LEFT JOIN album a ON i.album_pid = a.album_pid 
            WHERE ie.location != '' 
            ORDER BY ia.item_artist, a.album, i.track_number
        """
        
        var statement: OpaquePointer?
        var usedFallback = false
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) != SQLITE_OK {
            let fallbackQuery = """
                SELECT ie.item_pid, ie.title, ia.item_artist, a.album, ie.location, ie.total_time_ms 
                FROM item_extra ie 
                JOIN item i ON ie.item_pid = i.item_pid 
                LEFT JOIN item_artist ia ON i.item_artist_pid = ia.item_artist_pid 
                LEFT JOIN album a ON i.album_pid = a.album_pid 
                WHERE ie.location != '' 
                ORDER BY ia.item_artist, a.album, i.track_number
            """
            if sqlite3_prepare_v2(db, fallbackQuery, -1, &statement, nil) != SQLITE_OK {
                serverLog("Query Error")
                return []
            }
            usedFallback = true
        }
        defer { sqlite3_finalize(statement) }
        
        var list: [Song] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let artist = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "Unknown Artist"
            let album = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "Unknown Album"
            let filename = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
            let durationMs = sqlite3_column_double(statement, 5)
            
            var persistentId: Int64 = 0
            if !usedFallback && sqlite3_column_count(statement) > 6 {
                persistentId = sqlite3_column_int64(statement, 6)
            } else {
                persistentId = id
            }
            
            let fileModDate = self.getFileModificationDate(for: filename) ?? Date().timeIntervalSince1970
            
            list.append(Song(
                id: id,
                persistentId: UInt64(bitPattern: persistentId),
                title: title.isEmpty ? "Unknown" : title,
                artist: artist.isEmpty ? "Unknown Artist" : artist,
                album: album.isEmpty ? "Unknown Album" : album,
                filename: filename,
                duration: durationMs / 1000.0,
                dateAdded: fileModDate
            ))
        }
        return list
    }
    
    private func getFileModificationDate(for filename: String) -> TimeInterval? {
        let fm = FileManager.default
        var foundPath: String? = nil
        
        if filename.hasPrefix("/") && fm.fileExists(atPath: filename) {
            foundPath = filename
        } else {
            for basePath in musicBasePaths {
                let trialPath = "\(basePath)/\(filename)"
                if fm.fileExists(atPath: trialPath) {
                    foundPath = trialPath
                    break
                }
            }
            if foundPath == nil {
                let itunesMusicBase = "/var/mobile/Media/iTunes_Control/Music"
                let trialPath = "\(itunesMusicBase)/\(filename)"
                if fm.fileExists(atPath: trialPath) {
                    foundPath = trialPath
                }
            }
        }
        
        if let path = foundPath,
           let attrs = try? fm.attributesOfItem(atPath: path),
           let date = attrs[.modificationDate] as? Date {
            return date.timeIntervalSince1970
        }
        return nil
    }
    
    private func applyMergeGroups(to songs: [Song]) -> [Song] {
        let (albumGroups, artistGroups) = getCachedMergeGroups()
        
        guard !albumGroups.isEmpty || !artistGroups.isEmpty else {
            return songs
        }
        
        return songs.map { song in
            var updatedArtist = song.artist
            var updatedAlbum = song.album
            
            // 1. Apply Album merge
            if let group = albumGroups.first(where: { group in
                group.members.contains(where: { member in
                    member.matches(title: song.album, artist: song.artist)
                })
            }) {
                updatedArtist = group.targetArtist
                updatedAlbum = group.targetTitle
            }
            
            // 2. Apply Artist merge (mapping comma-separated components)
            if !artistGroups.isEmpty {
                let parts = updatedArtist.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                var canonicalParts: [String] = []
                for part in parts {
                    let canonical: String
                    if let group = artistGroups.first(where: { g in
                        g.members.contains(where: { $0.localizedCaseInsensitiveCompare(part) == .orderedSame })
                    }) {
                        canonical = group.targetArtist
                    } else {
                        canonical = part
                    }
                    if !canonicalParts.contains(where: { $0.localizedCaseInsensitiveCompare(canonical) == .orderedSame }) {
                        canonicalParts.append(canonical)
                    }
                }
                updatedArtist = canonicalParts.joined(separator: ", ")
            }
            
            if updatedArtist != song.artist || updatedAlbum != song.album {
                return Song(
                    id: song.id,
                    persistentId: song.persistentId,
                    title: song.title,
                    artist: updatedArtist,
                    album: updatedAlbum,
                    filename: song.filename,
                    duration: song.duration,
                    dateAdded: song.dateAdded,
                    trackNumber: song.trackNumber
                )
            }
            return song
        }
    }
    
    private func scanCustomMusicFolder(forceRefresh: Bool = false) -> [Song] {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: customMusicFolder)
        guard fm.fileExists(atPath: customMusicFolder) else { return [] }
        
        let rootPath = URL(fileURLWithPath: customMusicFolder).resolvingSymlinksInPath().path
        
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        
        let validExtensions = Set(["mp3", "m4a", "flac", "wav", "aac", "aiff", "aif"])
        var customSongs: [Song] = []
        var nextId: Int64 = 9000000
        var foundKeys = Set<String>()
        var cacheUpdated = false
        
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard validExtensions.contains(ext) else { continue }
            
            let filePath = fileURL.path
            foundKeys.insert(filePath)
            
            let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modDate = resourceValues?.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
            let fileSize = Int64(resourceValues?.fileSize ?? 0)
            
            let resolvedFilePath = fileURL.resolvingSymlinksInPath().path
            let relativePath: String
            if resolvedFilePath.hasPrefix(rootPath + "/") {
                relativePath = String(resolvedFilePath.dropFirst(rootPath.count + 1))
            } else if fileURL.path.hasPrefix(customMusicFolder + "/") {
                relativePath = String(fileURL.path.dropFirst(customMusicFolder.count + 1))
            } else {
                relativePath = fileURL.lastPathComponent
            }
            
            if !forceRefresh, let cached = persistentCache[filePath],
               cached.modDate == modDate, cached.fileSize == fileSize {
                customSongs.append(Song(
                    id: cached.id,
                    persistentId: cached.persistentId,
                    title: cached.title,
                    artist: cached.artist,
                    album: cached.album,
                    filename: cached.filename,
                    duration: cached.duration,
                    dateAdded: cached.dateAdded,
                    trackNumber: cached.trackNumber
                ))
                if cached.id >= nextId {
                    nextId = cached.id
                }
                continue
            }
            
            let asset = AVAsset(url: fileURL)
            var title = ""
            var artist = ""
            var album = ""
            var trackNumber: Int? = nil
            let duration = CMTimeGetSeconds(asset.duration)
            
            let allItems = asset.commonMetadata + asset.metadata
            for item in allItems {
                if let commonKey = item.commonKey {
                    switch commonKey {
                    case .commonKeyTitle:
                        if title.isEmpty, let s = item.stringValue, !s.isEmpty { title = s }
                    case .commonKeyArtist:
                        if artist.isEmpty, let s = item.stringValue, !s.isEmpty { artist = s }
                    case .commonKeyAlbumName:
                        if album.isEmpty, let s = item.stringValue, !s.isEmpty { album = s }
                    default:
                        break
                    }
                }
                
                guard let key = keyString(for: item) else { continue }
                switch key {
                case "©ART", "aART", "TPE1", "artist":
                    if artist.isEmpty, let s = item.stringValue, !s.isEmpty { artist = s }
                case "©alb", "TALB", "album":
                    if album.isEmpty, let s = item.stringValue, !s.isEmpty { album = s }
                case "©nam", "TIT2", "title":
                    if title.isEmpty, let s = item.stringValue, !s.isEmpty { title = s }
                case "trkn", "TRCK", "TRACKNUMBER", "TRACK", "©trk":
                    if trackNumber == nil {
                        if let num = item.numberValue?.intValue, num > 0 {
                            trackNumber = num
                        } else if let s = item.stringValue {
                            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let firstPart = trimmed.split(separator: "/").first,
                               let num = Int(firstPart.trimmingCharacters(in: .whitespaces)), num > 0 {
                                trackNumber = num
                            }
                        }
                    }
                default:
                    break
                }
            }
            
            if trackNumber == nil {
                trackNumber = extractTrackNumber(from: fileURL.lastPathComponent)
            }
            
            if title.isEmpty {
                title = fileURL.deletingPathExtension().lastPathComponent
            }
            
            let pathComponents = relativePath.components(separatedBy: "/")
            if pathComponents.count >= 3 {
                if artist.isEmpty { artist = pathComponents[0] }
                if album.isEmpty { album = pathComponents[1] }
            } else if pathComponents.count == 2 {
                if album.isEmpty { album = pathComponents[0] }
                if artist.isEmpty { artist = "Unknown Artist" }
            } else {
                if album.isEmpty {
                    let parentName = fileURL.deletingLastPathComponent().lastPathComponent
                    album = (parentName.isEmpty || parentName == "/" || parentName == "AudioStreamMusic") ? "Unknown Album" : parentName
                }
                if artist.isEmpty { artist = "Unknown Artist" }
            }
            
            let persistentId = generatePersistentId(for: relativePath)
            nextId += 1
            
            let song = Song(
                id: nextId,
                persistentId: persistentId,
                title: title,
                artist: artist,
                album: album,
                filename: relativePath,
                duration: duration > 0 ? duration : 0.0,
                dateAdded: modDate,
                trackNumber: trackNumber
            )
            customSongs.append(song)
            persistentCache[filePath] = CachedSongMetadata(
                id: song.id,
                persistentId: song.persistentId,
                title: song.title,
                artist: song.artist,
                album: song.album,
                filename: song.filename,
                duration: song.duration,
                dateAdded: song.dateAdded,
                trackNumber: song.trackNumber,
                modDate: modDate,
                fileSize: fileSize
            )
            cacheUpdated = true
        }
        
        let staleKeys = persistentCache.keys.filter { !foundKeys.contains($0) }
        if !staleKeys.isEmpty {
            for key in staleKeys {
                persistentCache.removeValue(forKey: key)
            }
            cacheUpdated = true
        }
        
        if cacheUpdated {
            savePersistentCache()
        }
        
        return customSongs
    }
    
    private func extractTrackNumber(from filename: String) -> Int? {
        let base = (filename as NSString).deletingPathExtension
        let pattern = #"^(?:track|trk)?\s*(\d{1,3})\b"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: base, range: NSRange(location: 0, length: base.utf16.count)),
           let range = Range(match.range(at: 1), in: base),
           let num = Int(base[range]), num > 0 {
            return num
        }
        return nil
    }
    
    private func generatePersistentId(for string: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = 127 * (hash & 0x00FFFFFFFFFFFFFF) + UInt64(byte)
        }
        return hash == 0 ? 1 : hash
    }
    
    private func loadPlaylists() {
        var loadedPlaylists: [Playlist] = []
        
        var db: OpaquePointer?
        if sqlite3_open_v2(self.dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            defer { sqlite3_close(db) }
            let query = "SELECT container_pid, name FROM container WHERE distinguished_kind = 0 AND is_hidden = 0 AND name != ''"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    let id = sqlite3_column_int64(statement, 0)
                    let name = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                    
                    var songIds: [Int64] = []
                    let itemQuery = "SELECT item_pid FROM container_item WHERE container_pid = \(id) ORDER BY position"
                    var itemStmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, itemQuery, -1, &itemStmt, nil) == SQLITE_OK {
                        while sqlite3_step(itemStmt) == SQLITE_ROW {
                            songIds.append(sqlite3_column_int64(itemStmt, 0))
                        }
                        sqlite3_finalize(itemStmt)
                    }
                    if !songIds.isEmpty {
                        loadedPlaylists.append(Playlist(id: id, name: name, songIds: songIds))
                    }
                }
                sqlite3_finalize(statement)
            }
        }
        
        let now = Date().timeIntervalSince1970
        let daySecs: TimeInterval = 86400
        
        let sortedByDate = songs.sorted { ($0.dateAdded ?? 0) > ($1.dateAdded ?? 0) }
        let recentlyAddedIds = Array(sortedByDate.prefix(100).map { $0.id })
        let monthIds = sortedByDate.filter { now - ($0.dateAdded ?? 0) <= 30 * daySecs }.map { $0.id }
        let threeMonthIds = sortedByDate.filter { now - ($0.dateAdded ?? 0) <= 90 * daySecs }.map { $0.id }
        let sixMonthIds = sortedByDate.filter { now - ($0.dateAdded ?? 0) <= 180 * daySecs }.map { $0.id }
        let yearIds = sortedByDate.filter { now - ($0.dateAdded ?? 0) <= 365 * daySecs }.map { $0.id }
        
        var smartPlaylists: [Playlist] = []
        if !recentlyAddedIds.isEmpty {
            smartPlaylists.append(Playlist(id: -1, name: "Recently Added", songIds: recentlyAddedIds))
        }
        if !monthIds.isEmpty {
            smartPlaylists.append(Playlist(id: -2, name: "Month", songIds: monthIds))
        }
        if !threeMonthIds.isEmpty {
            smartPlaylists.append(Playlist(id: -3, name: "3 Months", songIds: threeMonthIds))
        }
        if !sixMonthIds.isEmpty {
            smartPlaylists.append(Playlist(id: -4, name: "6 Months", songIds: sixMonthIds))
        }
        if !yearIds.isEmpty {
            smartPlaylists.append(Playlist(id: -5, name: "Year", songIds: yearIds))
        }
        
        self.playlists = smartPlaylists + loadedPlaylists
        self.updateCachedCounts(playlists: self.playlists.count)
    }
    
    func deleteSong(id: Int64) -> Bool {
        songsLock.lock()
        defer { songsLock.unlock() }
        
        serverLog("Daemon deleteSong called for id: \(id)")
        guard let songIndex = songs.firstIndex(where: { $0.id == id }) else {
            serverLog("Song not found with id: \(id)")
            return false
        }
        let song = songs[songIndex]
        var fileDeleted = false
        
        // 1. Check custom music folder / local file
        let customPath = "\(customMusicFolder)/\(song.filename)"
        if FileManager.default.fileExists(atPath: customPath) {
            do {
                try FileManager.default.removeItem(atPath: customPath)
                serverLog("Deleted custom file: \(customPath)")
                fileDeleted = true
            } catch {
                serverLog("Failed to delete custom file \(customPath): \(error)")
            }
        }
        
        if !fileDeleted {
            for basePath in musicBasePaths {
                let trialPath = "\(basePath)/\(song.filename)"
                if FileManager.default.fileExists(atPath: trialPath) {
                    do {
                        try FileManager.default.removeItem(atPath: trialPath)
                        serverLog("Deleted file at: \(trialPath)")
                        fileDeleted = true
                        break
                    } catch {
                        serverLog("Failed to delete file \(trialPath): \(error)")
                    }
                }
            }
        }
        
        // 2. Check iTunes DB track deletion
        var db: OpaquePointer?
        if sqlite3_open_v2(self.dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK {
            defer { sqlite3_close(db) }
            
            let query = "SELECT e.location, i.base_location_id FROM item i JOIN item_extra e ON i.item_pid = e.item_pid WHERE i.item_pid = ?"
            var stmt: OpaquePointer?
            var location: String?
            var baseLocationId: Int64?
            
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, song.id)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let cLoc = sqlite3_column_text(stmt, 0) { location = String(cString: cLoc) }
                    baseLocationId = sqlite3_column_int64(stmt, 1)
                }
                sqlite3_finalize(stmt)
            }
            
            if let loc = location, let baseId = baseLocationId {
                var basePath = ""
                let baseQuery = "SELECT path FROM base_location WHERE base_location_id = ?"
                if sqlite3_prepare_v2(db, baseQuery, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmt, 1, baseId)
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        if let cPath = sqlite3_column_text(stmt, 0) { basePath = String(cString: cPath) }
                    }
                    sqlite3_finalize(stmt)
                }
                
                var fullPath = "/var/mobile/Media"
                if !basePath.isEmpty { fullPath += "/" + basePath }
                fullPath += "/" + loc
                
                if FileManager.default.fileExists(atPath: fullPath) {
                    try? FileManager.default.removeItem(atPath: fullPath)
                    serverLog("Deleted iTunes file: \(fullPath)")
                }
            }
            
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            let deleteQueries = [
                "DELETE FROM item_extra WHERE item_pid = ?",
                "DELETE FROM item WHERE item_pid = ?",
                "DELETE FROM item_stats WHERE item_pid = ?",
                "DELETE FROM item_playback WHERE item_pid = ?"
            ]
            for q in deleteQueries {
                var deleteStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, q, -1, &deleteStmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(deleteStmt, 1, song.id)
                    sqlite3_step(deleteStmt)
                    sqlite3_finalize(deleteStmt)
                }
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
        
        songs.remove(at: songIndex)
        songFilePaths.removeValue(forKey: song.persistentId)
        self.updateCachedCounts(songs: songs.count)
        
        if persistentCache.removeValue(forKey: customPath) != nil {
            savePersistentCache()
        }
        
        loadPlaylists()
        return true
    }
    
    func deleteAlbum(title: String, artist: String) -> Bool {
        serverLog("Daemon deleteAlbum called for '\(title)' by '\(artist)'")
        let matchingSongIds: [Int64] = {
            songsLock.lock()
            defer { songsLock.unlock() }
            return songs.filter { s in
                s.album.localizedCaseInsensitiveCompare(title) == .orderedSame &&
                s.artist.localizedCaseInsensitiveCompare(artist) == .orderedSame
            }.map { $0.id }
        }()
        
        guard !matchingSongIds.isEmpty else {
            serverLog("No matching songs found for album '\(title)'")
            return false
        }
        var allSuccess = true
        for songId in matchingSongIds {
            if !deleteSong(id: songId) {
                allSuccess = false
            }
        }
        return allSuccess
    }
}

let daemon = AudioStreamerDaemon()
daemon.start()

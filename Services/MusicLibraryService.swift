import Foundation
import Combine
import MediaPlayer
import SQLite3

enum MusicLibraryError: LocalizedError {
    case musicAccessDenied
    
    var errorDescription: String? {
        switch self {
        case .musicAccessDenied:
            return "Music library access is needed to play songs from this device."
        }
    }
}

struct RemoteLibraryCacheData: Codable {
    static let currentVersion = 2
    let version: Int
    let serverURL: String
    let albums: [Album]
    let playlists: [Playlist]
    let tracks: [Track]
    let dateSaved: Date
}

class RemoteLibraryDiskCache {
    static let shared = RemoteLibraryDiskCache()
    private let cacheFileUrl: URL = {
        let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        return urls.first!.appendingPathComponent("remote_library_cache.json")
    }()
    
    func save(albums: [Album], playlists: [Playlist], tracks: [Track], serverURL: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let cacheObj = RemoteLibraryCacheData(version: RemoteLibraryCacheData.currentVersion, serverURL: serverURL, albums: albums, playlists: playlists, tracks: tracks, dateSaved: Date())
            if let encoded = try? JSONEncoder().encode(cacheObj) {
                try? encoded.write(to: self.cacheFileUrl)
            }
        }
    }
    
    func load(serverURL: String) -> (albums: [Album], playlists: [Playlist], tracks: [Track])? {
        guard let data = try? Data(contentsOf: cacheFileUrl),
              let cacheObj = try? JSONDecoder().decode(RemoteLibraryCacheData.self, from: data) else {
            return nil
        }
        
        // Invalidate cache if schema version is outdated
        guard cacheObj.version == RemoteLibraryCacheData.currentVersion else {
            try? FileManager.default.removeItem(at: cacheFileUrl)
            return nil
        }
        
        let rawTargetURL = serverURL.isEmpty ? (UserDefaults.standard.string(forKey: "RC_ServerURL") ?? "") : serverURL
        let targetURL = rawTargetURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let cachedURL = cacheObj.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        
        // If server URL is non-empty and doesn't match cached URL, don't return mismatched cache (but don't delete file)
        if !targetURL.isEmpty && !cachedURL.isEmpty && targetURL.lowercased() != cachedURL.lowercased() {
            return nil
        }
        
        let activeURLString = targetURL.isEmpty ? cachedURL : targetURL
        let baseURL = URL(string: activeURLString)
        
        let rehydratedTracks = cacheObj.tracks.map { track -> Track in
            var t = track
            if let baseURL = baseURL {
                t.streamUrl = baseURL.appendingPathComponent("/music/\(track.filename)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? track.filename)
                t.artworkUrl = baseURL.appendingPathComponent("/artwork/\(track.persistentId)")
            }
            return t
        }
        
        let rehydratedAlbums = cacheObj.albums.map { album -> Album in
            let updatedTracks = album.tracks.map { track -> Track in
                var t = track
                if let baseURL = baseURL {
                    t.streamUrl = baseURL.appendingPathComponent("/music/\(track.filename)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? track.filename)
                    t.artworkUrl = baseURL.appendingPathComponent("/artwork/\(track.persistentId)")
                }
                return t
            }
            let artUrl = baseURL.flatMap { bURL in
                album.tracks.first.map { bURL.appendingPathComponent("/artwork/\($0.persistentId)") }
            } ?? album.artworkUrl
            
            return Album(
                id: album.id,
                title: album.title,
                artist: album.artist,
                artworkUrl: artUrl,
                tracks: updatedTracks,
                dateAdded: album.dateAdded
            )
        }
        
        let rehydratedPlaylists = cacheObj.playlists.map { playlist -> Playlist in
            var p = playlist
            p.tracks = playlist.songIds.compactMap { id in
                rehydratedTracks.first(where: { $0.id == id })
            }
            return p
        }
        
        return (albums: rehydratedAlbums, playlists: rehydratedPlaylists, tracks: rehydratedTracks)
    }
}

class MusicLibraryService: ObservableObject {
    private let connectionService: ServerConnectionService
    
    init(connectionService: ServerConnectionService) {
        self.connectionService = connectionService
    }
    
    func fetchAlbums(forceRefresh: Bool = false) -> AnyPublisher<[Album], Error> {
        if connectionService.librarySource == .local {
            return fetchLocalAlbums(forceRefresh: forceRefresh)
        }
        
        guard let baseURL = URL(string: connectionService.serverURL) else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        
        var songsURL = baseURL.appendingPathComponent("/api/songs")
        if forceRefresh, var components = URLComponents(url: songsURL, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "refresh", value: "true")]
            if let u = components.url {
                songsURL = u
            }
        }
        var request = URLRequest(url: songsURL)
        if forceRefresh {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        
        return URLSession.shared.dataTaskPublisher(for: request)
            .handleEvents(receiveOutput: { [weak self] _ in
                self?.connectionService.markConnected(url: baseURL.absoluteString)
            })
            .map { $0.data }
            .decode(type: [Track].self, decoder: JSONDecoder())
            .map { tracks -> [Album] in
                // Group tracks by Album Name (and Artist to be safe)
                let grouped = Dictionary(grouping: tracks) { $0.album }
                
                let rawAlbums = grouped.map { (albumName, albumTracks) -> Album in
                    let artist = albumTracks.first?.artist ?? "Unknown Artist"
                    // Use the persistentId of the first track for album artwork
                    let firstTrack = albumTracks.first
                    let artworkUrl = firstTrack.map { 
                        baseURL.appendingPathComponent("/artwork/\($0.persistentId)") 
                    }
                    
                    // Update tracks with stream/artwork URLs
                    let updatedTracks = albumTracks.map { track -> Track in
                        var t = track
                        t.streamUrl = baseURL.appendingPathComponent("/music/\(track.filename)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? track.filename)
                        t.artworkUrl = baseURL.appendingPathComponent("/artwork/\(track.persistentId)")
                        return t
                    }
                    
                    let latestDate = albumTracks.compactMap { $0.dateAdded }.max()
                    
                    return Album(
                        id: albumName, // Simple ID for now
                        title: albumName,
                        artist: artist,
                        artworkUrl: artworkUrl,
                        tracks: updatedTracks.sorted(by: Track.compareTrackOrder),
                        dateAdded: latestDate
                    )
                }
                let albumProcessed = AlbumMergeService.shared.process(albums: rawAlbums)
                let processed = ArtistMergeService.shared.process(albums: albumProcessed)
                return processed.sorted { lhs, rhs in
                    let lhsDate = lhs.dateAdded ?? Date(timeIntervalSince1970: 0)
                    let rhsDate = rhs.dateAdded ?? Date(timeIntervalSince1970: 0)
                    if lhsDate != rhsDate {
                        return lhsDate > rhsDate
                    }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func fetchPlaylists(forceRefresh: Bool = false) -> AnyPublisher<[Playlist], Error> {
        if connectionService.librarySource == .local {
            return fetchLocalPlaylists()
        }
        
        guard let baseURL = URL(string: connectionService.serverURL) else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        
        var playlistsURL = baseURL.appendingPathComponent("/api/playlists")
        if forceRefresh, var components = URLComponents(url: playlistsURL, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "refresh", value: "true")]
            if let u = components.url {
                playlistsURL = u
            }
        }
        var request = URLRequest(url: playlistsURL)
        if forceRefresh {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        
        return URLSession.shared.dataTaskPublisher(for: request)
            .handleEvents(receiveOutput: { [weak self] _ in
                self?.connectionService.markConnected(url: baseURL.absoluteString)
            })
            .map { $0.data }
            .decode(type: [Playlist].self, decoder: JSONDecoder())
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    func fetchAllTracks(forceRefresh: Bool = false) -> AnyPublisher<[Track], Error> {
        if connectionService.librarySource == .local {
            return fetchLocalTracks(forceRefresh: forceRefresh)
        }
        
        // Helper to get raw tracks for playlist mapping
        guard let baseURL = URL(string: connectionService.serverURL) else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var songsURL = baseURL.appendingPathComponent("/api/songs")
        if forceRefresh, var components = URLComponents(url: songsURL, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "refresh", value: "true")]
            if let u = components.url {
                songsURL = u
            }
        }
        var request = URLRequest(url: songsURL)
        if forceRefresh {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        return URLSession.shared.dataTaskPublisher(for: request)
            .handleEvents(receiveOutput: { [weak self] _ in
                self?.connectionService.markConnected(url: baseURL.absoluteString)
            })
            .map { $0.data }
            .decode(type: [Track].self, decoder: JSONDecoder())
            .map { tracks in
                let updated = tracks.map { track -> Track in
                    var t = track
                    t.streamUrl = baseURL.appendingPathComponent("/music/\(track.filename)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? track.filename)
                    t.artworkUrl = baseURL.appendingPathComponent("/artwork/\(track.persistentId)")
                    return t
                }
                let albumProcessed = AlbumMergeService.shared.process(tracks: updated)
                return ArtistMergeService.shared.process(tracks: albumProcessed)
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    private func fetchLocalAlbums(forceRefresh: Bool = false) -> AnyPublisher<[Album], Error> {
        requestLocalMusicAccess()
            .replaceError(with: ())
            .setFailureType(to: Error.self)
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .map { _ -> [Album] in
                // 1. Native iTunes library albums (via MPMediaQuery, if available)
                let collections: [MPMediaItemCollection]
                if MPMediaLibrary.authorizationStatus() == .authorized {
                    collections = MPMediaQuery.albums().collections ?? []
                } else {
                    collections = []
                }
                
                let iTunesAlbums = collections.compactMap { collection -> Album? in
                    let tracks = collection.items.compactMap(Self.track(from:))
                        .sorted(by: Track.compareTrackOrder)
                    
                    guard !tracks.isEmpty else { return nil }
                    
                    let representativeItem = collection.representativeItem
                    let title = representativeItem?.albumTitle ?? tracks.first?.album ?? "Unknown Album"
                    let artist = representativeItem?.albumArtist ?? representativeItem?.artist ?? tracks.first?.artist ?? "Unknown Artist"
                    let albumID = representativeItem.map { String($0.albumPersistentID) } ?? title
                    
                    let artworkPersistentID = representativeItem?.persistentID ?? collection.items.first?.persistentID ?? 0
                    let artworkUrlStr = "local-artwork://\(artworkPersistentID)"
                    let artworkUrl = URL(string: artworkUrlStr)
                    
                    return Album(
                        id: "local-album-\(albumID)",
                        title: title,
                        artist: artist,
                        artworkUrl: artworkUrl,
                        tracks: tracks,
                        dateAdded: representativeItem?.dateAdded
                    )
                }
                
                // 2. Custom AudioStreamMusic folder albums
                let fileAlbums = LocalFileLibraryScanner.shared.scanAlbums(forceRefresh: forceRefresh)
                
                // Combine raw albums (prefer custom AudioStreamMusic files over iTunes)
                let rawLocalAlbums = fileAlbums + iTunesAlbums
                
                // 3. Combine raw albums that have matching title and artist so no tracks are lost
                var albumsByKey: [String: Album] = [:]
                var keyOrder: [String] = []
                for album in rawLocalAlbums {
                    let cleanTitle = album.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let cleanArtist = album.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let key = "\(cleanTitle)|\(cleanArtist)"
                    
                    if var existing = albumsByKey[key] {
                        // Merge tracks into existing album
                        var seenTrackKeys = Set<String>()
                        var combined: [Track] = []
                        for t in (existing.tracks + album.tracks) {
                            let tKey = "\(t.title.lowercased())|\(t.trackNumber ?? 0)"
                            if !seenTrackKeys.contains(tKey) {
                                seenTrackKeys.insert(tKey)
                                combined.append(t)
                            }
                        }
                        existing.tracks = combined.sorted(by: Track.compareTrackOrder)
                        if existing.artworkUrl == nil {
                            existing.artworkUrl = album.artworkUrl
                        }
                        let maxDate = [existing.dateAdded, album.dateAdded].compactMap { $0 }.max()
                        existing.dateAdded = maxDate
                        albumsByKey[key] = existing
                    } else {
                        albumsByKey[key] = album
                        keyOrder.append(key)
                    }
                }
                let dedupedRawAlbums = keyOrder.compactMap { albumsByKey[$0] }
                
                // 4. Process all merged groups on the final unique list of local albums
                let albumProcessedLocalAlbums = AlbumMergeService.shared.process(albums: dedupedRawAlbums)
                let processedLocalAlbums = ArtistMergeService.shared.process(albums: albumProcessedLocalAlbums)
                
                return processedLocalAlbums
                    .sorted { lhs, rhs in
                        let lhsDate = lhs.dateAdded ?? Date(timeIntervalSince1970: 0)
                        let rhsDate = rhs.dateAdded ?? Date(timeIntervalSince1970: 0)
                        if lhsDate != rhsDate {
                            return lhsDate > rhsDate
                        }
                        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    }
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    private func fetchLocalPlaylists() -> AnyPublisher<[Playlist], Error> {
        requestLocalMusicAccess()
            .replaceError(with: ())
            .setFailureType(to: Error.self)
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .map { _ in
                let collections: [MPMediaItemCollection]
                if MPMediaLibrary.authorizationStatus() == .authorized {
                    collections = MPMediaQuery.playlists().collections ?? []
                } else {
                    collections = []
                }
                
                return collections.compactMap { collection -> Playlist? in
                    guard let mediaPlaylist = collection as? MPMediaPlaylist else { return nil }
                    let tracks = mediaPlaylist.items.compactMap(Self.track(from:))
                    guard !tracks.isEmpty else { return nil }
                    
                    return Playlist(
                        id: Int64(bitPattern: mediaPlaylist.persistentID),
                        name: mediaPlaylist.name ?? "Playlist",
                        songIds: tracks.map { $0.id },
                        tracks: tracks
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    private func fetchLocalTracks(forceRefresh: Bool = false) -> AnyPublisher<[Track], Error> {
        requestLocalMusicAccess()
            .replaceError(with: ())
            .setFailureType(to: Error.self)
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .map { _ -> [Track] in
                // 1. Native iTunes library tracks (if available)
                let iTunesTracks: [Track]
                if MPMediaLibrary.authorizationStatus() == .authorized {
                    iTunesTracks = (MPMediaQuery.songs().items ?? []).compactMap(Self.track(from:))
                } else {
                    iTunesTracks = []
                }
                
                // 2. Custom AudioStreamMusic folder tracks
                let fileTracks = LocalFileLibraryScanner.shared.scanTracks(forceRefresh: forceRefresh)
                
                // 3. Merge: prefer custom fileTracks over iTunesTracks, deduplicate by title+artist+album
                var seenKeys = Set<String>()
                var rawLocalTracks: [Track] = []
                for track in (fileTracks + iTunesTracks) {
                    let cleanT = track.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let cleanA = track.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let cleanAlb = track.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let key = "\(cleanT)|\(cleanA)|\(cleanAlb)"
                    if !seenKeys.contains(key) {
                        seenKeys.insert(key)
                        rawLocalTracks.append(track)
                    }
                }
                
                // 4. Process all merged groups on the final list of local tracks
                let albumProcessedLocalTracks = AlbumMergeService.shared.process(tracks: rawLocalTracks)
                let processedLocalTracks = ArtistMergeService.shared.process(tracks: albumProcessedLocalTracks)
                
                return processedLocalTracks
                    .sorted { lhs, rhs in lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    private func requestLocalMusicAccess() -> AnyPublisher<Void, Error> {
        Future { promise in
            switch MPMediaLibrary.authorizationStatus() {
            case .authorized:
                promise(.success(()))
            case .notDetermined:
                MPMediaLibrary.requestAuthorization { status in
                    if status == .authorized {
                        promise(.success(()))
                    } else {
                        promise(.failure(MusicLibraryError.musicAccessDenied))
                    }
                }
            default:
                promise(.failure(MusicLibraryError.musicAccessDenied))
            }
        }
        .eraseToAnyPublisher()
    }
    
    private static func track(from item: MPMediaItem) -> Track? {
        guard let assetURL = item.assetURL else {
            return nil
        }
        
        let persistentID = item.persistentID
        let artworkUrlStr = "local-artwork://\(persistentID)"
        
        var track = Track(
            id: Int64(bitPattern: persistentID),
            persistentId: "local-\(persistentID)",
            title: item.title ?? "Unknown Title",
            artist: item.artist ?? item.albumArtist ?? "Unknown Artist",
            album: item.albumTitle ?? "Unknown Album",
            filename: assetURL.lastPathComponent,
            duration: item.playbackDuration
        )
        track.streamUrl = assetURL
        track.artworkUrl = URL(string: artworkUrlStr)
        track.albumArtist = item.albumArtist
        track.trackNumber = item.albumTrackNumber != 0 ? item.albumTrackNumber : Track.extractTrackNumberFromFilename(assetURL.lastPathComponent)
        return track
    }
    
    func search(query: String) -> AnyPublisher<[Track], Error> {
        // For now, simpler to fetch all and filter in memory since API doesn't support server-side search
        return fetchAlbums()
            .map { albums in
                albums.flatMap { $0.tracks }.filter { track in
                    track.title.localizedCaseInsensitiveContains(query) ||
                    track.artist.localizedCaseInsensitiveContains(query) ||
                    track.album.localizedCaseInsensitiveContains(query)
                }
            }
            .eraseToAnyPublisher()
    }
    
    func deleteAlbum(_ album: Album) -> Bool {
        var success = true
        for track in album.tracks {
            if !deleteTrack(track) {
                success = false
            }
        }
        return success
    }
    
    func deleteTrack(_ track: Track) -> Bool {
        deletionLog("deleteTrack called for '\(track.title)' (id: \(track.id), persistentId: '\(track.persistentId)')")
        if connectionService.librarySource == .remote {
            guard let baseURL = URL(string: connectionService.serverURL) else {
                deletionLog("Remote delete FAILED: invalid serverURL")
                return false
            }
            let deleteURL = baseURL.appendingPathComponent("/api/delete")
            var request = URLRequest(url: deleteURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload: [String: Any] = ["type": "song", "id": track.id]
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            
            let semaphore = DispatchSemaphore(value: 0)
            var success = false
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    success = true
                }
                semaphore.signal()
            }.resume()
            _ = semaphore.wait(timeout: .now() + 5.0)
            deletionLog("Remote delete completed. Success: \(success)")
            return success
        }
        
        // Branch A: local file track (from AudioStreamMusic folder) – just delete the file
        if track.persistentId.hasPrefix("localfile-") {
            guard let fileURL = track.streamUrl else {
                deletionLog("Branch A FAILED: streamUrl is nil")
                return false
            }
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                    deletionLog("Branch A: deleted file at \(fileURL.path)")
                }
                return true
            } catch {
                deletionLog("Branch A FAILED to delete file \(fileURL.path): \(error)")
                return false
            }
        }
        
        // Branch B: iTunes library track – remove via SQLite
        var db: OpaquePointer?
        let dbPath = "/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
        
        let openStatus = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil)
        guard openStatus == SQLITE_OK else {
            deletionLog("Branch B FAILED: sqlite3_open_v2 status=\(openStatus)")
            return false
        }
        defer { sqlite3_close(db) }
        
        // 1. Get location and base_location_id for this track from the database
        let query = "SELECT e.location, i.base_location_id FROM item i JOIN item_extra e ON i.item_pid = e.item_pid WHERE i.item_pid = ?"
        var stmt: OpaquePointer?
        var location: String?
        var baseLocationId: Int64?
        
        let prepStatus = sqlite3_prepare_v2(db, query, -1, &stmt, nil)
        if prepStatus == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, track.id)
            
            if sqlite3_step(stmt) == SQLITE_ROW {
                if let cLoc = sqlite3_column_text(stmt, 0) {
                    location = String(cString: cLoc)
                }
                baseLocationId = sqlite3_column_int64(stmt, 1)
            } else {
                deletionLog("Branch B query step failed or no rows returned. errmsg: \(String(cString: sqlite3_errmsg(db)))")
            }
            sqlite3_finalize(stmt)
        } else {
            deletionLog("Branch B query prepare FAILED: status=\(prepStatus), errmsg: \(String(cString: sqlite3_errmsg(db)))")
        }
        
        guard let loc = location, let baseId = baseLocationId else {
            deletionLog("Branch B FAILED: Could not resolve location/baseId for track \(track.id)")
            return false
        }
        
        // 2. Resolve base_location path
        var basePath = ""
        let baseQuery = "SELECT path FROM base_location WHERE base_location_id = ?"
        if sqlite3_prepare_v2(db, baseQuery, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, baseId)
            if sqlite3_step(stmt) == SQLITE_ROW {
                if let cPath = sqlite3_column_text(stmt, 0) {
                    basePath = String(cString: cPath)
                }
            }
            sqlite3_finalize(stmt)
        }
        
        // 3. Compute absolute file path
        var fullPath = "/var/mobile/Media"
        if !basePath.isEmpty {
            fullPath += "/" + basePath
        }
        fullPath += "/" + loc
        
        deletionLog("Branch B computed file path: \(fullPath)")
        var success = true
        
        // 4. Delete the physical file
        do {
            if FileManager.default.fileExists(atPath: fullPath) {
                try FileManager.default.removeItem(atPath: fullPath)
                deletionLog("Branch B: deleted physical file: \(fullPath)")
            } else {
                deletionLog("Branch B: physical file does not exist: \(fullPath)")
            }
        } catch {
            deletionLog("Branch B FAILED to delete physical file \(fullPath): \(error)")
            success = false
        }
        
        // 5. Delete the database records
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        
        var deleteStmt: OpaquePointer?
        let deleteExtraQuery = "DELETE FROM item_extra WHERE item_pid = ?"
        if sqlite3_prepare_v2(db, deleteExtraQuery, -1, &deleteStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(deleteStmt, 1, track.id)
            let step = sqlite3_step(deleteStmt)
            deletionLog("delete item_extra step status: \(step)")
            sqlite3_finalize(deleteStmt)
        } else {
            deletionLog("prepare delete item_extra FAILED: \(String(cString: sqlite3_errmsg(db)))")
        }
        
        let deleteItemQuery = "DELETE FROM item WHERE item_pid = ?"
        if sqlite3_prepare_v2(db, deleteItemQuery, -1, &deleteStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(deleteStmt, 1, track.id)
            let step = sqlite3_step(deleteStmt)
            deletionLog("delete item step status: \(step)")
            sqlite3_finalize(deleteStmt)
        } else {
            deletionLog("prepare delete item FAILED: \(String(cString: sqlite3_errmsg(db)))")
        }
        
        let deleteStatsQuery = "DELETE FROM item_stats WHERE item_pid = ?"
        if sqlite3_prepare_v2(db, deleteStatsQuery, -1, &deleteStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(deleteStmt, 1, track.id)
            let step = sqlite3_step(deleteStmt)
            deletionLog("delete item_stats step status: \(step)")
            sqlite3_finalize(deleteStmt)
        }
        
        let deletePlaybackQuery = "DELETE FROM item_playback WHERE item_pid = ?"
        if sqlite3_prepare_v2(db, deletePlaybackQuery, -1, &deleteStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(deleteStmt, 1, track.id)
            let step = sqlite3_step(deleteStmt)
            deletionLog("delete item_playback step status: \(step)")
            sqlite3_finalize(deleteStmt)
        }
        
        let commitStatus = sqlite3_exec(db, "COMMIT", nil, nil, nil)
        deletionLog("sqlite transaction commit status: \(commitStatus) (errmsg: \(String(cString: sqlite3_errmsg(db))))")
        
        if commitStatus != SQLITE_OK {
            success = false
        }
        
        return success
    }
    
    private func deletionLog(_ message: String) {
        let logPath = "/tmp/audiostream_deletion_debug.log"
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        let logMessage = "[\(timestamp)] \(message)\n"
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
    
    func deletePlaylist(_ playlist: Playlist) -> Bool {
        var db: OpaquePointer?
        let dbPath = "/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
        
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            print("Failed to open MediaLibrary database for playlist deletion")
            return false
        }
        defer { sqlite3_close(db) }
        
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        
        var stmt: OpaquePointer?
        // Delete container items first
        let deleteItemsQuery = "DELETE FROM container_item WHERE container_pid = ?"
        if sqlite3_prepare_v2(db, deleteItemsQuery, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, playlist.id)
            _ = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        
        // Delete container playlist
        let deleteContainerQuery = "DELETE FROM container WHERE container_pid = ?"
        if sqlite3_prepare_v2(db, deleteContainerQuery, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, playlist.id)
            _ = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return true
    }
}

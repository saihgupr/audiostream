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
    static let currentVersion = 4
    let version: Int
    let serverURL: String
    let albums: [Album]
    let playlists: [Playlist]
    let dateSaved: Date
}

class RemoteLibraryDiskCache {
    static let shared = RemoteLibraryDiskCache()
    private let cacheFileUrl: URL = {
        let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        return urls.first!.appendingPathComponent("remote_library_cache.json")
    }()

    var diskSizeBytes: UInt64 {
        AppCacheStorage.fileSizeBytes(at: cacheFileUrl)
    }

    func clear() {
        lock.lock()
        snapshot = nil
        lock.unlock()
        AppCacheStorage.removeItemIfExists(at: cacheFileUrl)
    }
    
    private struct Snapshot {
        let serverURL: String
        let albums: [Album]
        let playlists: [Playlist]
        let tracks: [Track]
    }
    
    private let lock = NSLock()
    private var snapshot: Snapshot?
    
    func save(albums: [Album], playlists: [Playlist], tracks: [Track], serverURL: String) {
        lock.lock()
        snapshot = Snapshot(serverURL: serverURL, albums: albums, playlists: playlists, tracks: tracks)
        lock.unlock()
        
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let cacheObj = RemoteLibraryCacheData(version: RemoteLibraryCacheData.currentVersion, serverURL: serverURL, albums: albums, playlists: playlists, dateSaved: Date())
            if let encoded = try? JSONEncoder().encode(cacheObj) {
                try? encoded.write(to: self.cacheFileUrl, options: .atomic)
            }
        }
    }
    
    func load(serverURL: String) -> (albums: [Album], playlists: [Playlist], tracks: [Track])? {
        let rawTargetURL = serverURL.isEmpty ? (UserDefaults.standard.string(forKey: "RC_ServerURL") ?? "") : serverURL
        let targetURL = rawTargetURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        
        lock.lock()
        let existing = snapshot
        lock.unlock()
        
        if let existing = existing {
            if normalizedURL(existing.serverURL) == normalizedURL(targetURL) {
                return (existing.albums, existing.playlists, existing.tracks)
            }
            let rehydrated = rehydrate(albums: existing.albums, playlists: existing.playlists, tracks: existing.tracks, baseURLString: targetURL.isEmpty ? existing.serverURL : targetURL)
            if let result = rehydrated {
                lock.lock()
                snapshot = Snapshot(serverURL: targetURL.isEmpty ? existing.serverURL : targetURL, albums: result.albums, playlists: result.playlists, tracks: result.tracks)
                lock.unlock()
                return result
            }
            return nil
        }
        
        guard let data = try? Data(contentsOf: cacheFileUrl) else { return nil }
        guard let cacheObj = try? JSONDecoder().decode(RemoteLibraryCacheData.self, from: data) else {
            try? FileManager.default.removeItem(at: cacheFileUrl)
            return nil
        }
        
        // Invalidate cache if schema version is outdated
        guard cacheObj.version == RemoteLibraryCacheData.currentVersion else {
            try? FileManager.default.removeItem(at: cacheFileUrl)
            return nil
        }
        
        let cachedURL = cacheObj.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        
        // A changed host spelling (iphone.local vs a LAN IP) is fine: all URLs
        // are rebuilt below. Only reject an entirely different server endpoint.
        if let target = URL(string: targetURL.isEmpty ? cachedURL : targetURL),
           let cached = URL(string: cachedURL),
           target.port != cached.port {
            return nil
        }
        
        let activeURLString = targetURL.isEmpty ? cachedURL : targetURL
        guard let result = rehydrate(albums: cacheObj.albums, playlists: cacheObj.playlists, tracks: nil, baseURLString: activeURLString) else {
            return nil
        }
        
        lock.lock()
        snapshot = Snapshot(serverURL: activeURLString, albums: result.albums, playlists: result.playlists, tracks: result.tracks)
        lock.unlock()
        
        return result
    }
    
    private func normalizedURL(_ string: String) -> String {
        string.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
    }
    
    private func rehydrate(albums: [Album], playlists: [Playlist], tracks: [Track]?, baseURLString: String) -> (albums: [Album], playlists: [Playlist], tracks: [Track])? {
        guard let baseURL = URL(string: baseURLString) else { return nil }
        
        var rehydratedAlbums: [Album] = []
        rehydratedAlbums.reserveCapacity(albums.count)
        var allTracks: [Track] = []
        allTracks.reserveCapacity(tracks?.count ?? albums.reduce(0) { $0 + $1.tracks.count })
        var seenTrackIds = Set<String>()
        
        func hydrate(_ track: Track) -> Track {
            var t = track
            t.streamUrl = baseURL.appendingPathComponent("/music/\(track.filename)")
            t.artworkUrl = baseURL.appendingPathComponent("/artwork/\(track.persistentId)")
            return t
        }
        
        for album in albums {
            let updatedTracks = album.tracks.map(hydrate)
            let artworkTrack = updatedTracks.first
            let artUrl = artworkTrack.map { baseURL.appendingPathComponent("/artwork/\($0.persistentId)") } ?? album.artworkUrl
            
            rehydratedAlbums.append(Album(
                id: album.id,
                title: album.title,
                artist: album.artist,
                artworkUrl: artUrl,
                tracks: updatedTracks,
                dateAdded: album.dateAdded
            ))
            
            for t in updatedTracks where seenTrackIds.insert(t.persistentId).inserted {
                allTracks.append(t)
            }
        }
        
        if let tracks = tracks, !tracks.isEmpty {
            for t in tracks where seenTrackIds.insert(t.persistentId).inserted {
                allTracks.append(hydrate(t))
            }
        }
        
        var tracksById = [Int64: Track](minimumCapacity: allTracks.count)
        for t in allTracks {
            tracksById[t.id] = t
        }
        let rehydratedPlaylists = playlists.map { playlist -> Playlist in
            var p = playlist
            p.tracks = playlist.songIds.compactMap { tracksById[$0] }
            return p
        }
        
        return (albums: rehydratedAlbums, playlists: rehydratedPlaylists, tracks: allTracks)
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
        
        return fetchRemoteTracks(forceRefresh: forceRefresh, baseURL: baseURL)
            .map { tracks -> [Album] in
                let hydrated = tracks.map { self.hydrate($0, baseURL: baseURL) }
                return self.makeAlbums(from: hydrated, baseURL: baseURL)
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    private func fetchRemoteJSON<T: Decodable>(_ type: T.Type, path: String, forceRefresh: Bool, baseURL: URL) -> AnyPublisher<T, Error> {
        let url = apiURL(baseURL: baseURL, path: path, forceRefresh: forceRefresh)
        let request = makeRequest(url: url, forceRefresh: forceRefresh)

        return URLSession.shared.dataTaskPublisher(for: request)
            .handleEvents(receiveOutput: { [weak self] _ in
                self?.connectionService.markConnected(url: baseURL.absoluteString)
            })
            .map { $0.data }
            .decode(type: T.self, decoder: JSONDecoder())
            .eraseToAnyPublisher()
    }

    private func fetchRemoteTracks(forceRefresh: Bool, baseURL: URL) -> AnyPublisher<[Track], Error> {
        fetchRemoteJSON([Track].self, path: "/api/songs", forceRefresh: forceRefresh, baseURL: baseURL)
    }
    
    private func hydrate(_ track: Track, baseURL: URL) -> Track {
        var t = track
        t.streamUrl = baseURL.appendingPathComponent("/music/\(track.filename)")
        t.artworkUrl = baseURL.appendingPathComponent("/artwork/\(track.persistentId)")
        return t
    }
    
    private func makeAlbums(from tracks: [Track], baseURL: URL) -> [Album] {
        let grouped = Dictionary(grouping: tracks) {
            AlbumGrouping.remoteAlbumOwnerKey(albumName: $0.album, track: $0)
        }
        
        let rawAlbums = grouped.map { (ownerKey, albumTracks) -> Album in
            // Deterministic artwork pick: sort before picking first so
            // repeated fetches (server JSON order varies) yield same id.
            let orderedForArtwork = albumTracks.sorted(by: Track.compareTrackOrder)
            let firstTrack = orderedForArtwork.first
            let albumName = firstTrack?.album ?? "Unknown Album"
            let artist: String = {
                if let albumArtist = orderedForArtwork.compactMap({ $0.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }) {
                    return albumArtist
                }
                let primaryKeys = Set(orderedForArtwork.map { AlbumGrouping.primaryArtistKey(for: $0.artist) })
                if primaryKeys.count == 1,
                   let canonical = orderedForArtwork.map({ $0.artist.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }).min(by: { $0.count < $1.count }) {
                    return canonical
                }
                if let path = firstTrack?.filename {
                    let components = path.split(separator: "/", omittingEmptySubsequences: true)
                    if components.count >= 3, !components[0].isEmpty {
                        return String(components[0])
                    }
                }
                return firstTrack?.artist ?? "Unknown Artist"
            }()
            // Use the persistentId of the first track for album artwork
            let artworkUrl = firstTrack.map {
                baseURL.appendingPathComponent("/artwork/\($0.persistentId)")
            }
            
            let latestDate = albumTracks.compactMap { $0.dateAdded }.max()
            
            return Album(
                id: ownerKey,
                title: albumName,
                artist: artist,
                artworkUrl: artworkUrl,
                tracks: orderedForArtwork,
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
    
    /// Fetches songs and playlists in one pass so a launch refresh doesn't
    /// download and decode the full song list twice.
    func fetchRemoteLibraryAsync(forceRefresh: Bool = false) async throws -> (albums: [Album], tracks: [Track], playlists: [Playlist]) {
        guard let baseURL = URL(string: connectionService.serverURL) else {
            throw URLError(.badURL)
        }
        
        let songsURL = apiURL(baseURL: baseURL, path: "/api/songs", forceRefresh: forceRefresh)
        let songsRequest = makeRequest(url: songsURL, forceRefresh: forceRefresh)
        
        let playlistsURL = apiURL(baseURL: baseURL, path: "/api/playlists", forceRefresh: forceRefresh)
        let playlistsRequest = makeRequest(url: playlistsURL, forceRefresh: forceRefresh)
        
        async let songsResult = URLSession.shared.data(for: songsRequest)
        async let playlistsResult = URLSession.shared.data(for: playlistsRequest)
        
        let (songsData, songsResponse) = try await songsResult
        let (playlistsData, playlistsResponse) = try await playlistsResult
        
        guard let songsHTTP = songsResponse as? HTTPURLResponse, (200...299).contains(songsHTTP.statusCode),
              let playlistsHTTP = playlistsResponse as? HTTPURLResponse, (200...299).contains(playlistsHTTP.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        connectionService.markConnected(url: baseURL.absoluteString)
        
        let rawTracks = try JSONDecoder().decode([Track].self, from: songsData)
        let hydratedTracks = rawTracks.map { hydrate($0, baseURL: baseURL) }
        let albums = makeAlbums(from: hydratedTracks, baseURL: baseURL)
        
        let mergedTracks = ArtistMergeService.shared.process(
            tracks: AlbumMergeService.shared.process(tracks: hydratedTracks)
        )
        
        let rawPlaylists = try JSONDecoder().decode([Playlist].self, from: playlistsData)
        var tracksById = [Int64: Track](minimumCapacity: mergedTracks.count)
        for track in mergedTracks {
            tracksById[track.id] = track
        }
        let playlists = rawPlaylists.map { playlist -> Playlist in
            var p = playlist
            p.tracks = playlist.songIds.compactMap { tracksById[$0] }
            return p
        }
        
        return (albums: albums, tracks: mergedTracks, playlists: playlists)
    }
    
    private func apiURL(baseURL: URL, path: String, forceRefresh: Bool) -> URL {
        var url = baseURL.appendingPathComponent(path)
        if forceRefresh, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "refresh", value: "true")]
            if let u = components.url {
                url = u
            }
        }
        return url
    }
    
    private func makeRequest(url: URL, forceRefresh: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        if forceRefresh {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        return request
    }
    
    func fetchPlaylists(forceRefresh: Bool = false) -> AnyPublisher<[Playlist], Error> {
        if connectionService.librarySource == .local {
            return fetchLocalPlaylists()
        }
        
        guard let baseURL = URL(string: connectionService.serverURL) else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        
        return fetchRemoteJSON([Playlist].self, path: "/api/playlists", forceRefresh: forceRefresh, baseURL: baseURL)
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
        return fetchRemoteTracks(forceRefresh: forceRefresh, baseURL: baseURL)
            .map { tracks in
                let updated = tracks.map { self.hydrate($0, baseURL: baseURL) }
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

    func deleteAlbumAsync(_ album: Album) async -> Bool {
        var success = true
        for track in album.tracks {
            if !(await deleteTrackAsync(track)) {
                success = false
            }
        }
        return success
    }

    func deleteTrackAsync(_ track: Track) async -> Bool {
        deletionLog("deleteTrackAsync called for '\(track.title)' (id: \(track.id), persistentId: '\(track.persistentId)')")
        if connectionService.librarySource == .remote {
            guard let baseURL = URL(string: connectionService.serverURL) else {
                deletionLog("Remote delete FAILED: invalid serverURL")
                return false
            }
            let deleteURL = baseURL.appendingPathComponent("/api/delete")
            var request = URLRequest(url: deleteURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 8.0
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload: [String: Any] = ["type": "song", "id": track.id]
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let success = (response as? HTTPURLResponse)?.statusCode == 200
                deletionLog("Remote async delete completed. Success: \(success)")
                return success
            } catch {
                deletionLog("Remote async delete FAILED: \(error)")
                return false
            }
        }

        return await Task.detached(priority: .userInitiated) {
            self.deleteLocalTrack(track)
        }.value
    }

    func deletePlaylistAsync(_ playlist: Playlist) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            self.deletePlaylist(playlist)
        }.value
    }
    
    func deleteTrack(_ track: Track) -> Bool {
        deletionLog("deleteTrack called for '\(track.title)' (id: \(track.id), persistentId: '\(track.persistentId)')")
        if connectionService.librarySource == .remote {
            deletionLog("deleteTrack synchronous call is unsupported for .remote; use deleteTrackAsync")
            return false
        }
        return deleteLocalTrack(track)
    }

    private func deleteLocalTrack(_ track: Track) -> Bool {
        
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
        AppCacheStorage.appendBoundedLog(message, to: "/tmp/audiostream_deletion_debug.log")
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

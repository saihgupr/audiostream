import SwiftUI
import Combine

private final class PlaylistCollageCache {
    static let shared = PlaylistCollageCache()
    static let didInvalidateNotification = Notification.Name("PlaylistCollageCacheDidInvalidate")

    private let lock = NSLock()
    private var cacheEpoch: Int = 0
    private var entries: [String: [URL]] = [:]
    private var pendingCompletions: [String: [([URL]) -> Void]] = [:]
    private let queue = DispatchQueue(label: "com.audiostream.playlistArtwork", qos: .userInitiated)
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        NotificationCenter.default.publisher(for: .albumArtworkDidUpdate)
            .sink { [weak self] _ in
                self?.invalidateAll()
            }
            .store(in: &cancellables)

        AlbumMergeService.shared.$mergeGroups
            .dropFirst()
            .sink { [weak self] _ in
                self?.invalidateAll()
            }
            .store(in: &cancellables)
    }

    func urls(for signature: String) -> [URL]? {
        lock.lock()
        let cached = entries[signature]
        lock.unlock()
        return cached
    }

    func invalidateAll() {
        lock.lock()
        cacheEpoch &+= 1
        entries.removeAll()
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didInvalidateNotification, object: nil)
        }
    }

    func computeIfNeeded(
        signature: String,
        tracks: [Track],
        playlistId: String,
        completion: (([URL]) -> Void)? = nil
    ) {
        lock.lock()
        if let cached = entries[signature] {
            lock.unlock()
            if let completion = completion {
                DispatchQueue.main.async {
                    completion(cached)
                }
            }
            return
        }

        let capturedEpoch = cacheEpoch
        let alreadyInFlight = pendingCompletions[signature] != nil
        if let completion = completion {
            pendingCompletions[signature, default: []].append(completion)
        } else if !alreadyInFlight {
            pendingCompletions[signature] = []
        }
        lock.unlock()

        if alreadyInFlight {
            return
        }

        queue.async { [weak self] in
            guard let self = self else { return }

            self.lock.lock()
            let cached = self.entries[signature]
            if let cached = cached {
                let callbacks = self.pendingCompletions.removeValue(forKey: signature) ?? []
                self.lock.unlock()
                if !callbacks.isEmpty {
                    DispatchQueue.main.async {
                        callbacks.forEach { $0(cached) }
                    }
                }
                return
            }
            self.lock.unlock()

            let urls = PlaylistArtworkView.computeArtworkUrls(tracks: tracks, playlistId: playlistId)

            self.lock.lock()
            if self.cacheEpoch == capturedEpoch {
                if self.entries.count >= 200 {
                    self.entries.removeAll()
                }
                self.entries[signature] = urls
            }
            let callbacks = self.pendingCompletions.removeValue(forKey: signature) ?? []
            self.lock.unlock()

            if !callbacks.isEmpty {
                DispatchQueue.main.async {
                    callbacks.forEach { $0(urls) }
                }
            }
        }
    }

    func precompute(playlists: [Playlist]) {
        let snapshots = playlists
            .filter { !$0.tracks.isEmpty }
            .map { playlist in
                (
                    signature: PlaylistArtworkView.signature(playlistId: String(playlist.id), tracks: playlist.tracks),
                    tracks: playlist.tracks,
                    playlistId: String(playlist.id)
                )
            }

        guard !snapshots.isEmpty else { return }

        lock.lock()
        let capturedEpoch = cacheEpoch
        lock.unlock()

        queue.async { [weak self] in
            guard let self = self else { return }
            var urlsToPrewarm: [URL] = []

            for (index, item) in snapshots.enumerated() {
                self.lock.lock()
                if self.cacheEpoch != capturedEpoch {
                    self.lock.unlock()
                    return
                }
                let existing = self.entries[item.signature]
                self.lock.unlock()

                let urls: [URL]
                if let existing = existing {
                    urls = existing
                } else {
                    urls = PlaylistArtworkView.computeArtworkUrls(tracks: item.tracks, playlistId: item.playlistId)
                    self.lock.lock()
                    if self.cacheEpoch == capturedEpoch {
                        if self.entries.count >= 200 {
                            self.entries.removeAll()
                        }
                        self.entries[item.signature] = urls
                    }
                    let callbacks = self.pendingCompletions.removeValue(forKey: item.signature) ?? []
                    self.lock.unlock()

                    if !callbacks.isEmpty {
                        DispatchQueue.main.async {
                            callbacks.forEach { $0(urls) }
                        }
                    }
                }

                if index < 15 {
                    urlsToPrewarm.append(contentsOf: urls)
                }
            }

            if !urlsToPrewarm.isEmpty {
                ImageLoader.prewarm(urls: urlsToPrewarm)
            }
        }
    }
}

struct PlaylistArtworkView: View {
    let tracks: [Track]
    let size: CGFloat
    let playlistId: String
    
    // Fallback configurations
    var fallbackSystemName: String = "music.note.list"
    var fallbackBgColor: Color = Color.gray.opacity(0.3)
    var fallbackFgColor: Color = .white

    @State private var cachedUrls: [URL] = []

    static func precomputeCollages(for playlists: [Playlist]) {
        PlaylistCollageCache.shared.precompute(playlists: playlists)
    }

    static func invalidateCache() {
        PlaylistCollageCache.shared.invalidateAll()
    }

    static func signature(playlistId: String, tracks: [Track]) -> String {
        let firstId = tracks.first?.persistentId ?? ""
        let firstArt = tracks.first?.artworkUrl?.absoluteString ?? ""
        let midTrack = tracks.isEmpty ? nil : tracks[tracks.count / 2]
        let midId = midTrack?.persistentId ?? ""
        let midArt = midTrack?.artworkUrl?.absoluteString ?? ""
        let lastId = tracks.last?.persistentId ?? ""
        let lastArt = tracks.last?.artworkUrl?.absoluteString ?? ""
        return "\(playlistId)|\(tracks.count)|\(firstId)|\(firstArt)|\(midId)|\(midArt)|\(lastId)|\(lastArt)"
    }

    private var cacheSignature: String {
        Self.signature(playlistId: playlistId, tracks: tracks)
    }
    
    private static func stableHash(_ string: String) -> Int {
        var hash = 5381
        for scalar in string.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return hash
    }
    
    private static func primaryArtist(from artist: String) -> String {
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

    private static func albumKey(for track: Track, resolvedAlbum: String, resolvedArtist: String) -> String {
        let cleanAlbum = resolvedAlbum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
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
                cleanArtist = primaryArtist(from: resolvedArtist)
            }
            return "\(cleanAlbum)__\(cleanArtist)"
        }
        
        return cleanAlbum
    }

    static func computeArtworkUrls(tracks: [Track], playlistId: String) -> [URL] {
        // Group tracks with artwork by unique album key using O(1) merge resolution
        var albumTrackMap: [String: [Track]] = [:]
        for track in tracks {
            guard track.artworkUrl != nil else { continue }
            let resolved = AlbumMergeService.shared.resolvedAlbumAndArtist(for: track)
            let key = albumKey(
                for: track,
                resolvedAlbum: resolved.album,
                resolvedArtist: resolved.artist
            )
            albumTrackMap[key, default: []].append(track)
        }
        
        guard !albumTrackMap.isEmpty else { return [] }

        // Sort album keys deterministically based on a combined hash of albumKey + playlistId.
        // This ensures distinct collages for different playlists without causing view scroll flicker.
        let hashedKeys = albumTrackMap.keys.map { key in
            (key: key, hash: stableHash("\(key)-\(playlistId)"))
        }
        let sortedKeys = hashedKeys.sorted { lhs, rhs in
            if lhs.hash != rhs.hash {
                return lhs.hash < rhs.hash
            }
            return lhs.key < rhs.key
        }
        
        // Only resolve track ordering for the winning albums until 4 unique URLs are collected.
        var urls: [URL] = []
        var seenUrls: Set<URL> = []
        urls.reserveCapacity(4)

        for entry in sortedKeys {
            guard let albumTracks = albumTrackMap[entry.key],
                  let firstUrl = albumTracks.first?.artworkUrl else { continue }

            let chosenUrl: URL?
            if albumTracks.count == 1 || albumTracks.allSatisfy({ $0.artworkUrl == firstUrl }) {
                chosenUrl = firstUrl
            } else {
                let ordered = albumTracks.sorted(by: Track.compareTrackOrder)
                chosenUrl = ordered.compactMap({ $0.artworkUrl }).first
            }

            if let url = chosenUrl, !seenUrls.contains(url) {
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
        let signature = cacheSignature
        let urls = tracks.isEmpty ? [] : (PlaylistCollageCache.shared.urls(for: signature) ?? cachedUrls)
        
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
        .onAppear {
            syncOrComputeArtworkUrls()
        }
        .onChange(of: cacheSignature) { _ in
            syncOrComputeArtworkUrls()
        }
        .onReceive(NotificationCenter.default.publisher(for: PlaylistCollageCache.didInvalidateNotification)) { _ in
            syncOrComputeArtworkUrls()
        }
    }

    private func syncOrComputeArtworkUrls() {
        if tracks.isEmpty {
            if !cachedUrls.isEmpty {
                cachedUrls = []
            }
            return
        }

        let signature = cacheSignature
        if let hit = PlaylistCollageCache.shared.urls(for: signature) {
            if cachedUrls != hit {
                cachedUrls = hit
            }
            return
        }

        let currentTracks = tracks
        let currentPlaylistId = playlistId
        PlaylistCollageCache.shared.computeIfNeeded(
            signature: signature,
            tracks: currentTracks,
            playlistId: currentPlaylistId
        ) { urls in
            if self.cacheSignature == signature {
                self.cachedUrls = urls
            }
        }
    }
}

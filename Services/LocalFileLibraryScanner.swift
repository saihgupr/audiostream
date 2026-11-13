import Foundation
import AVFoundation
import ImageIO
import UIKit

// MARK: - Artwork Cache

/// Shared cache mapping track ID → extracted UIImage artwork, backed by disk storage
/// and lazy on-demand extraction from audio files.
class LocalFileArtworkCache {
    static let shared = LocalFileArtworkCache()
    private static let maxDiskCacheBytes: UInt64 = 30 * 1024 * 1024
    private static let targetDiskCacheBytes: UInt64 = 20 * 1024 * 1024

    private let memoryCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 60
        c.totalCostLimit = 20 * 1024 * 1024 // 20 MB (ImageLoader holds the primary 350px thumbnail cache)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            c.removeAllObjects()
        }
        return c
    }()
    private let lock = NSLock()
    private let diskWriteQueue = DispatchQueue(label: "com.audiostream.localartwork.disk", qos: .utility)
    private let extractionSemaphore = DispatchSemaphore(value: 2)
    private var audioFileURLs: [String: URL] = [:]
    private var missingEmbeddedKeys = Set<String>()
    private var writeCountSincePrune = 0

    private lazy var cacheDir: URL = {
        let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let dir = urls.first!.appendingPathComponent("LocalArtworkCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        AppCacheStorage.pruneDirectory(dir, maxBytes: Self.maxDiskCacheBytes, targetBytes: Self.targetDiskCacheBytes)
        return dir
    }()

    private func recordDiskWrite() {
        lock.lock()
        writeCountSincePrune += 1
        let shouldPrune = writeCountSincePrune >= 25
        if shouldPrune {
            writeCountSincePrune = 0
        }
        lock.unlock()

        if shouldPrune {
            AppCacheStorage.pruneDirectory(cacheDir, maxBytes: Self.maxDiskCacheBytes, targetBytes: Self.targetDiskCacheBytes)
        }
    }

    func registerAudioFile(_ url: URL, for key: String) {
        lock.lock()
        audioFileURLs[key] = url
        lock.unlock()
    }

    func set(_ image: UIImage, for key: String, memoryOnly: Bool = false) {
        // Downscale before caching in memory to avoid huge memory usage
        let downscaled = ImageLoader.predecode(Self.downscaledThumbnail(from: image, maxPixelSize: 600))
        let cost = Int(downscaled.size.width * downscaled.size.height * 4)
        lock.lock()
        memoryCache.setObject(downscaled, forKey: key as NSString, cost: cost)
        missingEmbeddedKeys.remove(key)
        lock.unlock()

        guard !memoryOnly else { return }

        diskWriteQueue.async { [weak self] in
            guard let self = self else { return }
            let fileURL = self.cacheDir.appendingPathComponent("\(key).jpg")
            if let data = downscaled.jpegData(compressionQuality: 0.78) {
                try? data.write(to: fileURL, options: .atomic)
                self.recordDiskWrite()
            }
        }
    }

    func getFromMemory(for key: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return memoryCache.object(forKey: key as NSString)
    }

    func get(for key: String, maxPixelSize: CGFloat = 600) -> UIImage? {
        lock.lock()
        if let cached = memoryCache.object(forKey: key as NSString) {
            lock.unlock()
            return cached
        }
        let sourceURL = audioFileURLs[key]
        let isMissing = missingEmbeddedKeys.contains(key)
        lock.unlock()

        // Try reading from disk with downscaled thumbnail decoder
        let fileURL = cacheDir.appendingPathComponent("\(key).jpg")
        if FileManager.default.fileExists(atPath: fileURL.path),
           let thumb = Self.downscaledThumbnail(fromURL: fileURL, maxPixelSize: maxPixelSize) {
            let cost = Int(thumb.size.width * thumb.size.height * 4)
            lock.lock()
            memoryCache.setObject(thumb, forKey: key as NSString, cost: cost)
            lock.unlock()
            return thumb
        }

        if let audioURL = sourceURL, !isMissing {
            return extractAndCacheEmbeddedArtwork(from: audioURL, for: key, maxPixelSize: maxPixelSize)
        }

        return nil
    }

    private func extractAndCacheEmbeddedArtwork(from audioURL: URL, for key: String, maxPixelSize: CGFloat) -> UIImage? {
        extractionSemaphore.wait()
        defer { extractionSemaphore.signal() }

        lock.lock()
        if let cached = memoryCache.object(forKey: key as NSString) {
            lock.unlock()
            return cached
        }
        let alreadyMissing = missingEmbeddedKeys.contains(key)
        lock.unlock()
        if alreadyMissing { return nil }

        let fileURL = cacheDir.appendingPathComponent("\(key).jpg")
        if FileManager.default.fileExists(atPath: fileURL.path),
           let thumb = Self.downscaledThumbnail(fromURL: fileURL, maxPixelSize: maxPixelSize) {
            let cost = Int(thumb.size.width * thumb.size.height * 4)
            lock.lock()
            memoryCache.setObject(thumb, forKey: key as NSString, cost: cost)
            lock.unlock()
            return thumb
        }

        var extractedData: Data?
        autoreleasepool {
            let asset = AVURLAsset(url: audioURL)
            let allItems = asset.commonMetadata + asset.metadata
            for item in allItems {
                if item.commonKey == .commonKeyArtwork,
                   let data = item.dataValue, !data.isEmpty {
                    extractedData = data
                    break
                }
                if let k = LocalFileLibraryScanner.metadataKeyString(for: item),
                   k == "covr" || k == "APIC" || k == "PIC" || k == "artwork",
                   let data = item.dataValue, !data.isEmpty {
                    extractedData = data
                    break
                }
            }
        }

        guard let data = extractedData else {
            lock.lock()
            missingEmbeddedKeys.insert(key)
            lock.unlock()
            return nil
        }

        // Decode directly at the target size via ImageIO rather than decoding full-res bitmaps.
        let diskImage = Self.downscaledThumbnail(from: data, maxPixelSize: 600)
            ?? UIImage(data: data).map { Self.downscaledThumbnail(from: $0, maxPixelSize: 600) }
        guard let cachedImage = diskImage else {
            lock.lock()
            missingEmbeddedKeys.insert(key)
            lock.unlock()
            return nil
        }

        diskWriteQueue.async { [weak self] in
            guard let self = self else { return }
            let destURL = self.cacheDir.appendingPathComponent("\(key).jpg")
            if !FileManager.default.fileExists(atPath: destURL.path),
               let jpegData = cachedImage.jpegData(compressionQuality: 0.78) {
                try? jpegData.write(to: destURL, options: .atomic)
                self.recordDiskWrite()
            }
        }

        let resultImage: UIImage
        if maxPixelSize < 600, let smallThumb = Self.downscaledThumbnail(from: data, maxPixelSize: maxPixelSize) {
            resultImage = smallThumb
        } else {
            resultImage = cachedImage
        }

        let cost = Int(resultImage.size.width * resultImage.size.height * 4)
        lock.lock()
        memoryCache.setObject(resultImage, forKey: key as NSString, cost: cost)
        lock.unlock()
        return resultImage
    }

    func clear() {
        lock.lock()
        memoryCache.removeAllObjects()
        missingEmbeddedKeys.removeAll()
        lock.unlock()
    }

    func clearDisk() {
        lock.lock()
        memoryCache.removeAllObjects()
        missingEmbeddedKeys.removeAll()
        audioFileURLs.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    static func downscaledThumbnail(fromURL url: URL, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return downscaledThumbnail(fromSource: source, maxPixelSize: maxPixelSize)
    }

    static func downscaledThumbnail(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downscaledThumbnail(fromSource: source, maxPixelSize: maxPixelSize)
    }

    private static func downscaledThumbnail(fromSource source: CGImageSource, maxPixelSize: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return ImageLoader.predecode(UIImage(cgImage: cgImage))
    }

    static func downscaledThumbnail(from image: UIImage, maxPixelSize: CGFloat) -> UIImage {
        let maxDim = max(image.size.width, image.size.height)
        if maxDim <= maxPixelSize { return image }
        let scale = maxPixelSize / maxDim
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - Persistent Track Cache Models

struct CachedTrack: Codable {
    let persistentId: String
    let title: String
    let artist: String
    let album: String
    let filename: String
    let duration: TimeInterval
    let albumArtist: String?
    let trackNumber: Int?
    var artworkUrlString: String?
    let fileModificationDate: Date
    let fileSize: Int64
}

private struct MetadataCacheData: Codable {
    static let currentVersion = 2
    let version: Int
    let tracks: [String: CachedTrack]
}

// MARK: - Local Library Snapshot

struct LocalLibraryCacheData: Codable {
    static let currentVersion = 2
    let version: Int
    let albums: [CachedLocalAlbum]
    let playlists: [Playlist]
    let dateSaved: Date
}

struct CachedLocalAlbum: Codable {
    let id: String
    let title: String
    let artist: String
    let artworkUrlString: String?
    let dateAdded: Date?
    let tracks: [CachedLocalTrack]
}

struct CachedLocalTrack: Codable {
    let id: Int64
    let persistentId: String
    let title: String
    let artist: String
    let album: String
    let filename: String
    let duration: TimeInterval
    let dateAdded: Date?
    let albumArtist: String?
    let trackNumber: Int?
    let streamUrlString: String?
    let artworkUrlString: String?
    
    init(_ track: Track) {
        id = track.id
        persistentId = track.persistentId
        title = track.title
        artist = track.artist
        album = track.album
        filename = track.filename
        duration = track.duration
        dateAdded = track.dateAdded
        albumArtist = track.albumArtist
        trackNumber = track.trackNumber
        streamUrlString = track.streamUrl?.absoluteString
        artworkUrlString = track.artworkUrl?.absoluteString
    }
    
    var track: Track {
        var t = Track(
            id: id,
            persistentId: persistentId,
            title: title,
            artist: artist,
            album: album,
            filename: filename,
            duration: duration,
            dateAdded: dateAdded,
            artworkUrl: artworkUrlString.flatMap(URL.init(string:)),
            streamUrl: streamUrlString.flatMap(URL.init(string:)),
            albumArtist: albumArtist,
            trackNumber: trackNumber
        )
        t.albumArtist = albumArtist
        t.trackNumber = trackNumber
        return t
    }
}

/// Instant-launch snapshot of the processed local library. The folder scan
/// still runs in the background, but the grid paints from this cache first.
class LocalLibraryDiskCache {
    static let shared = LocalLibraryDiskCache()
    
    private let cacheFileUrl: URL = {
        let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        return urls.first!.appendingPathComponent("local_library_cache.json")
    }()
    
    private let lock = NSLock()
    private var snapshot: (albums: [Album], playlists: [Playlist], tracks: [Track])?
    
    func save(albums: [Album], playlists: [Playlist]) {
        var allTracks: [Track] = []
        var seenIds = Set<String>()
        for album in albums {
            for track in album.tracks where seenIds.insert(track.persistentId).inserted {
                allTracks.append(track)
            }
        }
        
        lock.lock()
        snapshot = (albums, playlists, allTracks)
        lock.unlock()
        
        let cachedAlbums = albums.map { album in
            CachedLocalAlbum(
                id: album.id,
                title: album.title,
                artist: album.artist,
                artworkUrlString: album.artworkUrl?.absoluteString,
                dateAdded: album.dateAdded,
                tracks: album.tracks.map(CachedLocalTrack.init)
            )
        }
        let cacheObj = LocalLibraryCacheData(
            version: LocalLibraryCacheData.currentVersion,
            albums: cachedAlbums,
            playlists: playlists,
            dateSaved: Date()
        )
        
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.createDirectory(
                at: self.cacheFileUrl.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let encoded = try? JSONEncoder().encode(cacheObj) {
                try? encoded.write(to: self.cacheFileUrl, options: .atomic)
            }
        }
    }
    
    func load() -> (albums: [Album], playlists: [Playlist], tracks: [Track])? {
        lock.lock()
        if let snapshot = snapshot {
            lock.unlock()
            return snapshot
        }
        lock.unlock()
        
        guard let data = try? Data(contentsOf: cacheFileUrl),
              let cacheObj = try? JSONDecoder().decode(LocalLibraryCacheData.self, from: data) else {
            return nil
        }
        guard cacheObj.version == LocalLibraryCacheData.currentVersion else {
            try? FileManager.default.removeItem(at: cacheFileUrl)
            return nil
        }
        
        var albums: [Album] = []
        albums.reserveCapacity(cacheObj.albums.count)
        var allTracks: [Track] = []
        var seenIds = Set<String>()
        
        for cachedAlbum in cacheObj.albums {
            let tracks = cachedAlbum.tracks.map { $0.track }
            for track in tracks {
                if track.artworkUrl?.scheme == "local-file-artwork", let streamUrl = track.streamUrl {
                    LocalFileArtworkCache.shared.registerAudioFile(streamUrl, for: track.persistentId)
                }
            }
            albums.append(Album(
                id: cachedAlbum.id,
                title: cachedAlbum.title,
                artist: cachedAlbum.artist,
                artworkUrl: cachedAlbum.artworkUrlString.flatMap(URL.init(string:)),
                tracks: tracks,
                dateAdded: cachedAlbum.dateAdded
            ))
            for track in tracks where seenIds.insert(track.persistentId).inserted {
                allTracks.append(track)
            }
        }
        
        var tracksById = [Int64: Track](minimumCapacity: allTracks.count)
        for track in allTracks {
            tracksById[track.id] = track
        }
        let playlists = cacheObj.playlists.map { playlist -> Playlist in
            var p = playlist
            p.tracks = playlist.songIds.compactMap { tracksById[$0] }
            return p
        }
        
        let result = (albums: albums, playlists: playlists, tracks: allTracks)
        lock.lock()
        snapshot = result
        lock.unlock()
        return result
    }
}

// MARK: - Scanner

/// Scans /var/mobile/Documents/AudioStreamMusic/ for audio files and builds
/// Track/Album model objects, using memory and persistent caching to load instantly.
class LocalFileLibraryScanner {

    static let shared = LocalFileLibraryScanner()

    /// Root folder where import_from_mac.sh drops albums.
    static let musicRoot = URL(fileURLWithPath: "/var/mobile/Documents/AudioStreamMusic")

    private var cachedTracks: [Track]?
    private let lock = NSLock()
    
    private let cacheFileUrl: URL = {
        let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        return urls.first!.appendingPathComponent("local_metadata_cache.json")
    }()
    
    private var persistentCache: [String: CachedTrack] = [:]

    private init() {
        loadPersistentCache()
    }

    private func loadPersistentCache() {
        guard let data = try? Data(contentsOf: cacheFileUrl) else { return }
        do {
            let decoder = JSONDecoder()
            let cacheObj = try decoder.decode(MetadataCacheData.self, from: data)
            guard cacheObj.version == MetadataCacheData.currentVersion else {
                try? FileManager.default.removeItem(at: cacheFileUrl)
                return
            }
            self.persistentCache = cacheObj.tracks
        } catch {
            // Legacy unversioned caches may contain broken artwork URLs; rebuild cleanly.
            try? FileManager.default.removeItem(at: cacheFileUrl)
            self.persistentCache = [:]
        }
    }

    private func savePersistentCache() {
        do {
            try FileManager.default.createDirectory(
                at: cacheFileUrl.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            let payload = MetadataCacheData(version: MetadataCacheData.currentVersion, tracks: persistentCache)
            let data = try encoder.encode(payload)
            try data.write(to: cacheFileUrl, options: .atomic)
        } catch {
            print("Failed to save local metadata cache: \(error)")
        }
    }

    private static func stableHash64(_ string: String) -> UInt64 {
        // FNV-1a 64-bit over UTF-8 bytes: stable across process launches.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    private static let folderArtworkCandidates = [
        "cover.jpg", "folder.jpg", "cover.jpeg", "folder.jpeg",
        "cover.png", "folder.png", "artwork.jpg", "artwork.png",
        "Cover.jpg", "Folder.jpg", "Cover.png", "Folder.png"
    ]

    private static func folderArtworkURL(forDirectory dir: URL, cache: inout [String: URL?]) -> URL? {
        if let cached = cache[dir.path] {
            return cached
        }
        let fm = FileManager.default
        let resolved = findFolderArtwork(in: dir, fileManager: fm)
            ?? findParentAlbumArtwork(for: dir, fileManager: fm)
        cache[dir.path] = resolved
        return resolved
    }

    private static func findFolderArtwork(in dir: URL, fileManager: FileManager) -> URL? {
        for candidate in folderArtworkCandidates {
            let candidateURL = dir.appendingPathComponent(candidate)
            if fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }
        return nil
    }

    private static func findParentAlbumArtwork(for dir: URL, fileManager: FileManager) -> URL? {
        let parent = dir.deletingLastPathComponent()
        let rootPath = musicRoot.resolvingSymlinksInPath().path
        let parentPath = parent.resolvingSymlinksInPath().path
        guard parentPath != rootPath, parentPath.hasPrefix(rootPath + "/") else {
            return nil
        }
        let dirName = dir.lastPathComponent.lowercased()
        let isDiscSubfolder = dirName.hasPrefix("disc") || dirName.hasPrefix("disk") || dirName.hasPrefix("cd")
        let isNestedAlbumSubdir = parent.deletingLastPathComponent().resolvingSymlinksInPath().path != rootPath
        guard isDiscSubfolder || isNestedAlbumSubdir else {
            return nil
        }
        return findFolderArtwork(in: parent, fileManager: fileManager)
    }

    func clearCache() {
        lock.lock()
        cachedTracks = nil
        lock.unlock()
    }

    // MARK: - Public API

    /// Synchronously scan the music root and return all found albums.
    func scanAlbums(forceRefresh: Bool = false) -> [Album] {
        let tracks = scanTracks(forceRefresh: forceRefresh)
        let rawAlbums = buildAlbums(from: tracks)
        let albumProcessed = AlbumMergeService.shared.process(albums: rawAlbums)
        let processedAlbums = ArtistMergeService.shared.process(albums: albumProcessed)
        return processedAlbums.sorted { lhs, rhs in
            let lhsDate = lhs.dateAdded ?? Date(timeIntervalSince1970: 0)
            let rhsDate = rhs.dateAdded ?? Date(timeIntervalSince1970: 0)
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// Synchronously scan the music root and return all found tracks.
    func scanTracks(forceRefresh: Bool = false) -> [Track] {
        lock.lock()
        if !forceRefresh, let cached = cachedTracks {
            lock.unlock()
            return cached
        }
        
        // Clear memory cache on forced refresh
        if forceRefresh {
            LocalFileArtworkCache.shared.clear()
        }

        guard FileManager.default.fileExists(atPath: Self.musicRoot.path) else {
            lock.unlock()
            return []
        }

        var results: [Track] = []
        let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "aiff", "alac", "flac"]
        var cacheUpdated = false
        var newTracksBuilt = 0
        var foundCacheKeys = Set<String>()
        var folderArtworkCache: [String: URL?] = [:]

        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let resourceKeySet = Set(resourceKeys)
        if let enumerator = FileManager.default.enumerator(
            at: Self.musicRoot,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                autoreleasepool {
                    let ext = fileURL.pathExtension.lowercased()
                    guard audioExtensions.contains(ext) else { return }

                    let values = try? fileURL.resourceValues(forKeys: resourceKeySet)
                    if values?.isRegularFile == false { return }
                    let modDate = values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                    let size = Int64(values?.fileSize ?? 0)
                    let cacheKey = fileURL.path
                    foundCacheKeys.insert(cacheKey)

                    let dir = fileURL.deletingLastPathComponent()
                    let folderArtwork = Self.folderArtworkURL(forDirectory: dir, cache: &folderArtworkCache)

                    if var cached = persistentCache[cacheKey],
                       cached.fileModificationDate == modDate,
                       cached.fileSize == size {
                        let rawHash = Self.stableHash64(fileURL.path)
                        let safeId = Int64(bitPattern: rawHash & 0x7FFFFFFFFFFFFFFF)

                        var resolvedArtworkUrl: URL?
                        var needsReparse = false

                        if let folderURL = folderArtwork {
                            resolvedArtworkUrl = folderURL
                        } else if let artworkStr = cached.artworkUrlString, let artURL = URL(string: artworkStr) {
                            if artURL.isFileURL {
                                if FileManager.default.fileExists(atPath: artURL.path) {
                                    resolvedArtworkUrl = artURL
                                } else {
                                    needsReparse = true
                                }
                            } else {
                                resolvedArtworkUrl = artURL
                                if artURL.scheme == "local-file-artwork" {
                                    LocalFileArtworkCache.shared.registerAudioFile(fileURL, for: cached.persistentId)
                                }
                            }
                        }

                        if !needsReparse {
                            var track = Track(
                                id: safeId,
                                persistentId: cached.persistentId,
                                title: cached.title,
                                artist: cached.artist,
                                album: cached.album,
                                filename: cached.filename,
                                duration: cached.duration,
                                dateAdded: cached.fileModificationDate
                            )
                            track.albumArtist = cached.albumArtist
                            track.trackNumber = cached.trackNumber ?? Track.extractTrackNumberFromFilename(cached.filename)
                            track.streamUrl = fileURL
                            track.artworkUrl = resolvedArtworkUrl

                            if cached.artworkUrlString != resolvedArtworkUrl?.absoluteString {
                                cached.artworkUrlString = resolvedArtworkUrl?.absoluteString
                                persistentCache[cacheKey] = cached
                                cacheUpdated = true
                            }

                            results.append(track)
                            return
                        }
                    }

                    // Full parse without decoding artwork; drain per-track AVURLAsset temporaries.
                    if let track = buildTrack(from: fileURL, modDate: modDate, size: size, folderArtwork: folderArtwork) {
                        results.append(track)
                        cacheUpdated = true
                        newTracksBuilt += 1
                        if newTracksBuilt % 250 == 0 {
                            savePersistentCache()
                        }
                    }
                }
            }
        }

        let staleKeys = persistentCache.keys.filter { !foundCacheKeys.contains($0) }
        if !staleKeys.isEmpty {
            for key in staleKeys {
                persistentCache.removeValue(forKey: key)
            }
            cacheUpdated = true
        }

        let sorted = results.sorted {
            if $0.album != $1.album { return $0.album < $1.album }
            return Track.compareTrackOrder($0, $1)
        }
        
        cachedTracks = sorted
        
        if cacheUpdated {
            savePersistentCache()
        }
        
        lock.unlock()
        return sorted
    }

    // MARK: - Private Helpers

    private func buildTrack(from url: URL, modDate: Date, size: Int64, folderArtwork: URL?) -> Track? {
        let asset = AVURLAsset(url: url)
        let meta = loadMetadata(from: asset, checkEmbeddedArtwork: folderArtwork == nil)

        let rawHash = Self.stableHash64(url.path)
        let safeId = Int64(bitPattern: rawHash & 0x7FFFFFFFFFFFFFFF)
        let trackId = "localfile-\(rawHash)"

        // Avoid decoding images during the scan: point directly at folder cover files
        // when present, or defer embedded artwork extraction until the item is rendered.
        let artworkUrl: URL?
        if let folderArtwork = folderArtwork {
            artworkUrl = folderArtwork
        } else if meta.hasEmbeddedArtwork {
            LocalFileArtworkCache.shared.registerAudioFile(url, for: trackId)
            artworkUrl = URL(string: "local-file-artwork://\(trackId)")
        } else {
            artworkUrl = nil
        }

        let cleanTitle = (meta.title ?? url.deletingPathExtension().lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = (meta.artist ?? "Unknown Artist").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAlbum = (meta.album ?? url.deletingLastPathComponent().lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAlbumArtist = meta.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)

        var track = Track(
            id: safeId,
            persistentId: trackId,
            title: cleanTitle,
            artist: cleanArtist,
            album: cleanAlbum,
            filename: url.lastPathComponent,
            duration: asset.duration.seconds.isNaN ? 0 : asset.duration.seconds,
            dateAdded: modDate
        )
        track.albumArtist = cleanAlbumArtist
        track.trackNumber = meta.trackNumber ?? Track.extractTrackNumberFromFilename(url.lastPathComponent)
        track.streamUrl = url
        track.artworkUrl = artworkUrl
        
        // Save to persistent cache dictionary
        let cached = CachedTrack(
            persistentId: trackId,
            title: track.title,
            artist: track.artist,
            album: track.album,
            filename: track.filename,
            duration: track.duration,
            albumArtist: track.albumArtist,
            trackNumber: track.trackNumber,
            artworkUrlString: track.artworkUrl?.absoluteString,
            fileModificationDate: modDate,
            fileSize: size
        )
        persistentCache[url.path] = cached
        
        return track
    }

    private func buildAlbums(from tracks: [Track]) -> [Album] {
        let grouped = Dictionary(grouping: tracks) { track -> String in
            let cleanAlbum = track.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let albumArtist = (track.albumArtist ?? track.artist).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return "\(cleanAlbum)__\(albumArtist)"
        }

        var folderArtworkCache: [String: URL?] = [:]

        return grouped.map { (_, albumTracks) -> Album in
            let sorted = albumTracks.sorted(by: Track.compareTrackOrder)
            let rep = sorted.first!
            let albumArtist = (rep.albumArtist ?? rep.artist).trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanAlbum = rep.album.trimmingCharacters(in: .whitespacesAndNewlines)
            
            let latestDate = sorted.compactMap { $0.dateAdded }.max() ?? Date()
            
            // Prefer folder cover URLs (loaded lazily by ImageLoader), then embedded artwork URLs,
            // falling back to scanning the representative track's directory if needed.
            let trackArtworks = sorted.compactMap { $0.artworkUrl }
            var artworkUrl = trackArtworks.first(where: { $0.isFileURL }) ?? trackArtworks.first
            if artworkUrl == nil, let streamUrl = rep.streamUrl {
                artworkUrl = Self.folderArtworkURL(forDirectory: streamUrl.deletingLastPathComponent(), cache: &folderArtworkCache)
            }
            
            let albumHash = Self.stableHash64("\(cleanAlbum)\(albumArtist)") & 0x7FFFFFFFFFFFFFFF
            return Album(
                id: "localfile-album-\(albumHash)",
                title: cleanAlbum,
                artist: albumArtist,
                artworkUrl: artworkUrl,
                tracks: sorted,
                dateAdded: latestDate
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Metadata Extraction

    private struct SongMeta {
        var title: String?
        var artist: String?
        var albumArtist: String?
        var album: String?
        var trackNumber: Int?
        var hasEmbeddedArtwork: Bool = false
    }

    static func metadataKeyString(for item: AVMetadataItem) -> String? {
        if let str = item.key as? String {
            return str
        }
        if let num = item.key as? NSNumber {
            let u = num.uint32Value
            let chars: [UInt8] = [
                UInt8((u >> 24) & 0xFF),
                UInt8((u >> 16) & 0xFF),
                UInt8((u >> 8) & 0xFF),
                UInt8(u & 0xFF)
            ]
            return String(bytes: chars, encoding: .ascii)
        }
        if let identifier = item.identifier?.rawValue {
            let parts = identifier.split(separator: "/")
            if let last = parts.last {
                return String(last)
            }
        }
        return nil
    }

    private func parseTrackNumber(from item: AVMetadataItem) -> Int? {
        if let num = item.numberValue?.intValue, num > 0 {
            return num
        }
        if let s = item.stringValue {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let firstPart = trimmed.split(separator: "/").first,
               let num = Int(firstPart.trimmingCharacters(in: .whitespaces)), num > 0 {
                return num
            }
        }
        if let data = item.dataValue {
            if data.count >= 4 {
                let num = (UInt16(data[2]) << 8) | UInt16(data[3])
                if num > 0 { return Int(num) }
            }
            if data.count >= 2 {
                let num = (UInt16(data[0]) << 8) | UInt16(data[1])
                if num > 0 { return Int(num) }
            }
        }
        return nil
    }

    private func loadMetadata(from asset: AVURLAsset, checkEmbeddedArtwork: Bool) -> SongMeta {
        var meta = SongMeta()

        let allItems = asset.commonMetadata + asset.metadata
        for item in allItems {
            if let commonKey = item.commonKey {
                switch commonKey {
                case .commonKeyTitle:
                    if meta.title == nil { meta.title = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                case .commonKeyArtist:
                    if meta.artist == nil { meta.artist = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                case .commonKeyAlbumName:
                    if meta.album == nil { meta.album = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                case .commonKeyArtwork:
                    if checkEmbeddedArtwork { meta.hasEmbeddedArtwork = true }
                default:
                    break
                }
            }

            guard let key = Self.metadataKeyString(for: item) else { continue }
            switch key {
            case "©ART", "TPE1", "artist":
                if meta.artist == nil { meta.artist = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            case "aART", "TPE2", "albumArtist":
                if meta.albumArtist == nil { meta.albumArtist = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            case "©alb", "TALB", "album":
                if meta.album == nil { meta.album = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            case "©nam", "TIT2", "title":
                if meta.title == nil { meta.title = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            case "trkn", "TRCK", "TRACKNUMBER", "TRACK", "©trk":
                if meta.trackNumber == nil {
                    meta.trackNumber = parseTrackNumber(from: item)
                }
            case "covr", "APIC", "PIC", "artwork":
                if checkEmbeddedArtwork { meta.hasEmbeddedArtwork = true }
            default:
                break
            }
        }

        return meta
    }
}

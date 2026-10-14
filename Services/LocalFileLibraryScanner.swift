import Foundation
import AVFoundation
import UIKit

// MARK: - Artwork Cache

/// Shared cache mapping track ID → extracted UIImage artwork, backed by disk storage.
class LocalFileArtworkCache {
    static let shared = LocalFileArtworkCache()
    private let memoryCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 150
        c.totalCostLimit = 60 * 1024 * 1024 // 60 MB
        return c
    }()
    private let lock = NSLock()
    
    private let cacheDir: URL = {
        let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let dir = urls.first!.appendingPathComponent("LocalArtworkCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func set(_ image: UIImage, for key: String) {
        // Downscale before caching in memory to avoid huge memory usage during scanning
        let downscaled = Self.downscaledThumbnail(from: image, maxPixelSize: 600)
        let cost = Int(downscaled.size.width * downscaled.size.height * 4)
        lock.lock()
        memoryCache.setObject(downscaled, forKey: key as NSString, cost: cost)
        lock.unlock()
        
        // Write to disk asynchronously if not already present
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let fileURL = self.cacheDir.appendingPathComponent("\(key).jpg")
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                if let data = downscaled.jpegData(compressionQuality: 0.75) {
                    try? data.write(to: fileURL)
                }
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
        lock.unlock()
        
        // Try reading from disk with downscaled thumbnail decoder
        let fileURL = cacheDir.appendingPathComponent("\(key).jpg")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        
        if let thumb = Self.downscaledThumbnail(fromURL: fileURL, maxPixelSize: maxPixelSize) {
            let cost = Int(thumb.size.width * thumb.size.height * 4)
            lock.lock()
            memoryCache.setObject(thumb, forKey: key as NSString, cost: cost)
            lock.unlock()
            return thumb
        }
        
        return nil
    }

    func clear() {
        lock.lock()
        memoryCache.removeAllObjects()
        lock.unlock()
    }
    
    func clearDisk() {
        lock.lock()
        memoryCache.removeAllObjects()
        lock.unlock()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    static func downscaledThumbnail(fromURL url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
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
    let artworkUrlString: String?
    let fileModificationDate: Date
    let fileSize: Int64
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
            self.persistentCache = try decoder.decode([String: CachedTrack].self, from: data)
        } catch {
            print("Failed to decode local metadata cache: \(error)")
        }
    }

    private func savePersistentCache() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(persistentCache)
            try data.write(to: cacheFileUrl)
        } catch {
            print("Failed to save local metadata cache: \(error)")
        }
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
        var foundCacheKeys = Set<String>()

        func recurse(directory: URL) {
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                return
            }
            for fileURL in contents {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fileURL.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        recurse(directory: fileURL)
                    } else {
                        let ext = fileURL.pathExtension.lowercased()
                        if audioExtensions.contains(ext) {
                            let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
                            let modDate = (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
                            let size = (attrs?[.size] as? Int64) ?? 0
                            let cacheKey = fileURL.path
                            foundCacheKeys.insert(cacheKey)
                            
                            if let cached = persistentCache[cacheKey],
                               cached.fileModificationDate == modDate,
                               cached.fileSize == size {
                                // Load from cache
                                let rawHash = UInt64(bitPattern: Int64(truncatingIfNeeded: fileURL.path.hashValue))
                                let safeId = Int64(bitPattern: rawHash & 0x7FFFFFFFFFFFFFFF)
                                
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
                                if let artworkStr = cached.artworkUrlString {
                                    track.artworkUrl = URL(string: artworkStr)
                                }
                                results.append(track)
                            } else {
                                // Full parse
                                if let track = buildTrack(from: fileURL, modDate: modDate, size: size) {
                                    results.append(track)
                                    cacheUpdated = true
                                }
                            }
                        }
                    }
                }
            }
        }

        recurse(directory: Self.musicRoot)

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

    private func buildTrack(from url: URL, modDate: Date, size: Int64) -> Track? {
        let asset = AVURLAsset(url: url)
        let meta = loadMetadata(from: asset)

        let rawHash = UInt64(bitPattern: Int64(truncatingIfNeeded: url.path.hashValue))
        let safeId = Int64(bitPattern: rawHash & 0x7FFFFFFFFFFFFFFF)
        let trackId = "localfile-\(rawHash)"

        // Extract artwork and cache it
        if let artworkImage = meta.artwork {
            LocalFileArtworkCache.shared.set(artworkImage, for: trackId)
        }

        // Fall back to folder.jpg / cover.jpg / folder.png in the same directory
        if meta.artwork == nil {
            let dir = url.deletingLastPathComponent()
            let artworkCandidates = ["folder.jpg", "cover.jpg", "folder.png", "cover.png", "artwork.jpg"]
            for candidate in artworkCandidates {
                let candidateURL = dir.appendingPathComponent(candidate)
                if FileManager.default.fileExists(atPath: candidateURL.path),
                   let img = UIImage(contentsOfFile: candidateURL.path) {
                    LocalFileArtworkCache.shared.set(img, for: trackId)
                    break
                }
            }
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
        track.artworkUrl = URL(string: "local-file-artwork://\(trackId)")
        
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

        return grouped.map { (_, albumTracks) -> Album in
            let sorted = albumTracks.sorted(by: Track.compareTrackOrder)
            let rep = sorted.first!
            let albumArtist = (rep.albumArtist ?? rep.artist).trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanAlbum = rep.album.trimmingCharacters(in: .whitespacesAndNewlines)
            
            let latestDate = sorted.compactMap { $0.dateAdded }.max() ?? Date()
            
            // Prefer first track with artwork, or look for cover.jpg/folder.jpg in album folder
            var artworkUrl = sorted.compactMap { $0.artworkUrl }.first
            if artworkUrl == nil, let streamUrl = rep.streamUrl {
                let dir = streamUrl.deletingLastPathComponent()
                let candidates = ["cover.jpg", "folder.jpg", "cover.png", "folder.png", "artwork.jpg"]
                for c in candidates {
                    let candUrl = dir.appendingPathComponent(c)
                    if FileManager.default.fileExists(atPath: candUrl.path) {
                        artworkUrl = candUrl
                        break
                    }
                }
            }
            
            return Album(
                id: "localfile-album-\(abs("\(cleanAlbum)\(albumArtist)".hashValue))",
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
        var artwork: UIImage?
    }

    private func keyString(for item: AVMetadataItem) -> String? {
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

    private func loadMetadata(from asset: AVURLAsset) -> SongMeta {
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
                    if meta.artwork == nil, let data = item.dataValue, let img = UIImage(data: data) {
                        meta.artwork = img
                    }
                default:
                    break
                }
            }

            guard let key = keyString(for: item) else { continue }
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
            case "covr", "APIC", "artwork":
                if meta.artwork == nil, let data = item.dataValue, let img = UIImage(data: data) {
                    meta.artwork = img
                }
            default:
                break
            }
        }

        return meta
    }
}

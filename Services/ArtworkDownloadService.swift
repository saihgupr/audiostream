import Foundation
import UIKit

class ArtworkDownloadService {
    static let shared = ArtworkDownloadService()
    
    private init() {}
    
    enum DownloadError: LocalizedError {
        case notFound
        case invalidImageData
        case networkError(String)
        
        var errorDescription: String? {
            switch self {
            case .notFound:
                return "No album artwork could be found for this album."
            case .invalidImageData:
                return "The downloaded artwork could not be processed."
            case .networkError(let details):
                return "Network error: \(details)"
            }
        }
    }
    
    // MARK: - Public API
    
    /// Finds and downloads album cover art, saves it to disk (including cover.jpg if local files exist),
    /// updates caches, and returns the downloaded UIImage and local file URL.
    func findAndDownloadArtwork(for album: Album, customQuery: String? = nil) async throws -> (image: UIImage, fileUrl: URL) {
        let candidateUrls: [URL]
        
        if let custom = customQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            candidateUrls = await searchITunes(term: custom)
        } else {
            candidateUrls = await generateAndSearchCandidates(for: album)
        }
        
        guard !candidateUrls.isEmpty else {
            // Try MusicBrainz as fallback
            if let mbUrl = await searchMusicBrainz(album: album) {
                return try await downloadAndSave(from: mbUrl, for: album)
            }
            throw DownloadError.notFound
        }
        
        // Try each candidate until one successfully downloads as valid image
        for url in candidateUrls {
            if let result = try? await downloadAndSave(from: url, for: album) {
                return result
            }
        }
        
        // Secondary fallback to MusicBrainz
        if let mbUrl = await searchMusicBrainz(album: album) {
            return try await downloadAndSave(from: mbUrl, for: album)
        }
        
        throw DownloadError.notFound
    }
    
    // MARK: - Search Logic
    
    private func cleanText(_ text: String) -> String {
        var cleaned = text
        // Remove trailing or parenthetical expressions like "(Deluxe Edition)", "[Remastered 2021]", "(feat. ...)"
        let patterns = [
            "\\s*\\([^(]*?(?:deluxe|remaster|expanded|anniversary|special|bonus|edition|version|explicit|feat\\.|ft\\.|with).*?\\)",
            "\\s*\\[[^\\[]*?(?:deluxe|remaster|expanded|anniversary|special|bonus|edition|version|explicit|feat\\.|ft\\.|with).*?\\]",
            "\\s*-\\s*(?:single|ep|deluxe|remastered|anniversary|expanded).*$"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: cleaned.utf16.count)
                cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
            }
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func generateAndSearchCandidates(for album: Album) async -> [URL] {
        let cleanAlbumTitle = cleanText(album.title)
        let cleanArtistName = cleanText(album.artist)
        
        var queryTerms: [String] = []
        
        // 1. Cleaned Artist + Album
        if !cleanArtistName.isEmpty && !cleanAlbumTitle.isEmpty &&
           cleanArtistName.lowercased() != "unknown artist" &&
           cleanArtistName.lowercased() != "various artists" &&
           cleanArtistName.lowercased() != "playlist" {
            queryTerms.append("\(cleanArtistName) \(cleanAlbumTitle)")
        }
        
        // 2. First track artist + album (if different from album artist)
        if let firstTrack = album.tracks.first {
            let trackArtist = cleanText(firstTrack.artist)
            if !trackArtist.isEmpty && trackArtist != cleanArtistName && !cleanAlbumTitle.isEmpty {
                queryTerms.append("\(trackArtist) \(cleanAlbumTitle)")
            }
        }
        
        // 3. Raw Artist + Album
        if !album.artist.isEmpty && !album.title.isEmpty {
            let rawQuery = "\(album.artist) \(album.title)"
            if !queryTerms.contains(rawQuery) {
                queryTerms.append(rawQuery)
            }
        }
        
        // 4. Album title alone
        if !cleanAlbumTitle.isEmpty && !queryTerms.contains(cleanAlbumTitle) {
            queryTerms.append(cleanAlbumTitle)
        }
        
        var foundUrls: [URL] = []
        for term in queryTerms {
            let urls = await searchITunes(term: term)
            for u in urls {
                if !foundUrls.contains(u) {
                    foundUrls.append(u)
                }
            }
            if !foundUrls.isEmpty {
                break
            }
        }
        
        // If no album results, try iTunes song search with first track
        if foundUrls.isEmpty, let firstTrack = album.tracks.first {
            let trackQuery = "\(cleanText(firstTrack.artist)) \(cleanText(firstTrack.title))"
            let songUrls = await searchITunes(term: trackQuery, entity: "song")
            foundUrls.append(contentsOf: songUrls)
        }
        
        return foundUrls
    }
    
    private func searchITunes(term: String, entity: String = "album") async -> [URL] {
        guard let encodedTerm = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchUrl = URL(string: "https://itunes.apple.com/search?term=\(encodedTerm)&entity=\(entity)&limit=5") else {
            return []
        }
        
        var request = URLRequest(url: searchUrl)
        request.setValue("AudioStream/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8.0
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return []
            }
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return []
            }
            
            var urls: [URL] = []
            for item in results {
                if let rawUrlStr = item["artworkUrl100"] as? String ?? item["artworkUrl60"] as? String {
                    // Upgrade resolution to 600x600 for sharp cover art
                    let highResStr = rawUrlStr.replacingOccurrences(
                        of: "\\d+x\\d+bb",
                        with: "600x600bb",
                        options: .regularExpression
                    )
                    if let u = URL(string: highResStr) {
                        urls.append(u)
                    } else if let fallbackU = URL(string: rawUrlStr) {
                        urls.append(fallbackU)
                    }
                }
            }
            return urls
        } catch {
            return []
        }
    }
    
    private func searchMusicBrainz(album: Album) async -> URL? {
        let cleanAlbumTitle = cleanText(album.title)
        let cleanArtistName = cleanText(album.artist)
        guard !cleanAlbumTitle.isEmpty else { return nil }
        
        var query = "release:\(cleanAlbumTitle)"
        if !cleanArtistName.isEmpty &&
           cleanArtistName.lowercased() != "unknown artist" &&
           cleanArtistName.lowercased() != "various artists" {
            query += " AND artist:\(cleanArtistName)"
        }
        
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let mbUrl = URL(string: "https://musicbrainz.org/ws/2/release/?query=\(encodedQuery)&fmt=json&limit=1") else {
            return nil
        }
        
        var request = URLRequest(url: mbUrl)
        request.setValue("AudioStream/1.0 (contact@audiostream.app)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8.0
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let releases = json["releases"] as? [[String: Any]],
                  let firstRelease = releases.first,
                  let mbid = firstRelease["id"] as? String else {
                return nil
            }
            
            return URL(string: "https://coverartarchive.org/release/\(mbid)/front-500")
        } catch {
            return nil
        }
    }
    
    // MARK: - Download & Persistence
    
    private func downloadAndSave(from remoteUrl: URL, for album: Album) async throws -> (image: UIImage, fileUrl: URL) {
        var request = URLRequest(url: remoteUrl)
        request.setValue("AudioStream/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15.0
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DownloadError.networkError("Server returned code \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        
        guard let image = UIImage(data: data) else {
            throw DownloadError.invalidImageData
        }
        
        // Determine primary storage URL
        let finalFileUrl = saveArtworkLocally(data: data, image: image, for: album)
        
        // Populate in-memory and disk caches
        populateCaches(image: image, finalUrl: finalFileUrl, album: album)
        
        return (image, finalFileUrl)
    }
    
    private func saveArtworkLocally(data: Data, image: UIImage, for album: Album) -> URL {
        let fm = FileManager.default
        
        // 1. Permanent documents directory: Documents/AlbumArtwork/<albumId>.jpg
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let artworkDir = docs.appendingPathComponent("AlbumArtwork", isDirectory: true)
        try? fm.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        
        let safeKey = album.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "\(abs(album.title.hashValue))"
        let persistentFileUrl = artworkDir.appendingPathComponent("\(safeKey).jpg")
        try? data.write(to: persistentFileUrl, options: .atomic)
        
        // 2. If album has local file tracks in AudioStreamMusic, save cover.jpg directly into folder
        var localCoverUrl: URL? = nil
        for track in album.tracks {
            if let streamUrl = track.streamUrl, streamUrl.isFileURL {
                let folder = streamUrl.deletingLastPathComponent()
                if fm.fileExists(atPath: folder.path) {
                    let coverJpg = folder.appendingPathComponent("cover.jpg")
                    try? data.write(to: coverJpg, options: .atomic)
                    localCoverUrl = coverJpg
                    break
                }
            }
        }

        // Notify the daemon so a newly saved cover.jpg is picked up on
        // rescan. Best-effort fire-and-forget: silently ignored when no
        // server is configured or reachable (local-only use).
        if localCoverUrl != nil {
            notifyDaemonRescan()
        }

        return localCoverUrl ?? persistentFileUrl
    }
    
    private func notifyDaemonRescan() {
        guard let url = URL(string: "http://127.0.0.1:18080/api/refresh") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req).resume()
    }

    private func populateCaches(image: UIImage, finalUrl: URL, album: Album) {
        // 1. Update LocalFileArtworkCache for album ID and all tracks
        LocalFileArtworkCache.shared.set(image, for: album.id)
        for track in album.tracks {
            LocalFileArtworkCache.shared.set(image, for: track.persistentId)
        }
        
        // 2. Update ImageLoader memory cache for all relevant keys
        ImageLoader.setCachedImage(image, for: finalUrl.absoluteString)
        if let existingArtworkUrl = album.artworkUrl {
            ImageLoader.setCachedImage(image, for: existingArtworkUrl.absoluteString)
        }
        for track in album.tracks {
            if let tArt = track.artworkUrl {
                ImageLoader.setCachedImage(image, for: tArt.absoluteString)
            }
            ImageLoader.setCachedImage(image, for: "local-file-artwork://\(track.persistentId)")
        }
        
        // 3. Clear LocalFileLibraryScanner memory cache so next read uses new artwork
        LocalFileLibraryScanner.shared.clearCache()
    }
}

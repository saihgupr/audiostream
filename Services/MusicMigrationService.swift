import Foundation
import Combine
import SQLite3

public struct MigrationItem {
    public let itemPid: Int64
    public let title: String
    public let artist: String
    public let album: String
    public let location: String
    public let trackNumber: Int?
    public let durationMs: Double
    public let dateAdded: Date
    public let artworkRelativePath: String?
}

public class MusicMigrationService: ObservableObject {
    public static let shared = MusicMigrationService()
    
    @Published public var isMigrating: Bool = false
    @Published public var progress: Double = 0.0
    @Published public var statusMessage: String = ""
    @Published public var migratedCount: Int = 0
    @Published public var skippedCount: Int = 0
    @Published public var totalCount: Int = 0
    @Published public var lastError: String? = nil
    @Published public var showCompletionAlert: Bool = false
    @Published public var completionSummary: String = ""
    
    private let dbPath = "/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
    private let targetMusicFolder = "/var/mobile/Documents/AudioStreamMusic"
    private let searchBases = [
        "/var/mobile/Documents/AudioStreamMusic",
        "/var/mobile/Media/iTunes_Control/Music",
        "/var/mobile/Media/Purchases"
    ]
    
    // Apple Cocoa reference date offset (2001-01-01 00:00:00 UTC)
    private let cocoaEpochOffset: TimeInterval = 978307200
    
    private init() {}
    
    public func getAvailableFreeSpaceMB() -> Int {
        var stat = statfs()
        if statfs("/var/mobile", &stat) == 0 {
            let freeBytes = Int64(stat.f_bavail) * Int64(stat.f_bsize)
            return Int(freeBytes / (1024 * 1024))
        }
        return 0
    }
    
    public func startMigration() {
        guard !isMigrating else { return }
        
        isMigrating = true
        progress = 0.0
        migratedCount = 0
        skippedCount = 0
        totalCount = 0
        lastError = nil
        statusMessage = "Scanning music library..."
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.performMigration()
        }
    }
    
    private func performMigration() {
        let fm = FileManager.default
        
        // Ensure destination folder exists
        if !fm.fileExists(atPath: targetMusicFolder) {
            try? fm.createDirectory(atPath: targetMusicFolder, withIntermediateDirectories: true, attributes: nil)
        }
        
        // 1. Query MediaLibrary.sqlitedb
        var db: OpaquePointer?
        if sqlite3_open_v2(self.dbPath, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            DispatchQueue.main.async {
                self.isMigrating = false
                self.lastError = "Could not open system MediaLibrary database."
            }
            return
        }
        defer { sqlite3_close(db) }
        
        let query = """
            SELECT ie.item_pid, ie.title, ia.item_artist, a.album, ie.location, i.track_number, ie.total_time_ms, i.date_added, aw.relative_path
            FROM item_extra ie
            JOIN item i ON ie.item_pid = i.item_pid
            LEFT JOIN item_artist ia ON i.item_artist_pid = ia.item_artist_pid
            LEFT JOIN album a ON i.album_pid = a.album_pid
            LEFT JOIN best_artwork_token bat ON i.item_pid = bat.entity_pid
            LEFT JOIN artwork aw ON bat.available_artwork_token = aw.artwork_token
            WHERE ie.location != ''
            ORDER BY ia.item_artist, a.album, i.track_number
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            DispatchQueue.main.async {
                self.isMigrating = false
                self.lastError = "Failed to query system MediaLibrary."
            }
            return
        }
        defer { sqlite3_finalize(stmt) }
        
        var items: [MigrationItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let itemPid = sqlite3_column_int64(stmt, 0)
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let artist = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "Unknown Artist"
            let album = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "Unknown Album"
            let location = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let trackNum = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 5)) : nil
            let durationMs = sqlite3_column_double(stmt, 6)
            
            let dateAddedRaw = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? sqlite3_column_double(stmt, 7) : 0.0
            let dateAdded: Date
            if dateAddedRaw > 0 {
                dateAdded = Date(timeIntervalSince1970: dateAddedRaw + self.cocoaEpochOffset)
            } else {
                dateAdded = Date()
            }
            
            let artRel = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            
            items.append(MigrationItem(
                itemPid: itemPid,
                title: title.isEmpty ? "Unknown" : title,
                artist: artist.isEmpty ? "Unknown Artist" : artist,
                album: album.isEmpty ? "Unknown Album" : album,
                location: location,
                trackNumber: trackNum,
                durationMs: durationMs,
                dateAdded: dateAdded,
                artworkRelativePath: artRel
            ))
        }
        
        let total = items.count
        DispatchQueue.main.async {
            self.totalCount = total
            self.statusMessage = "Indexing files on device..."
        }
        
        // 2. Index physical source files on device
        var fileMap: [String: String] = [:]
        for base in searchBases {
            guard fm.fileExists(atPath: base) else { continue }
            if let enumerator = fm.enumerator(atPath: base) {
                while let rel = enumerator.nextObject() as? String {
                    let filename = (rel as NSString).lastPathComponent
                    if !filename.hasPrefix(".") && fileMap[filename] == nil {
                        fileMap[filename] = (base as NSString).appendingPathComponent(rel)
                    }
                }
            }
        }
        
        var migrated = 0
        var skipped = 0
        
        for (index, item) in items.enumerated() {
            let filename = (item.location as NSString).lastPathComponent
            let sourcePath = fileMap[filename]
            
            let cleanArtist = sanitize(item.artist)
            let cleanAlbum = sanitize(item.album)
            let cleanTitle = sanitize(item.title)
            let ext = (filename as NSString).pathExtension.isEmpty ? "m4a" : (filename as NSString).pathExtension
            
            let trackPrefix: String
            if let tn = item.trackNumber, tn > 0 {
                trackPrefix = String(format: "%02d - ", tn)
            } else {
                trackPrefix = ""
            }
            let destFilename = "\(trackPrefix)\(cleanTitle).\(ext)"
            let destDirPath = "\(targetMusicFolder)/\(cleanArtist)/\(cleanAlbum)"
            let destFilePath = "\(destDirPath)/\(destFilename)"
            
            if !fm.fileExists(atPath: destDirPath) {
                try? fm.createDirectory(atPath: destDirPath, withIntermediateDirectories: true, attributes: nil)
            }
            
            // Copy album artwork to cover.jpg in album directory if available
            let coverPath = "\(destDirPath)/cover.jpg"
            if !fm.fileExists(atPath: coverPath), let rel = item.artworkRelativePath {
                let artSrc = "/var/mobile/Media/iTunes_Control/iTunes/Artwork/Originals/\(rel)"
                if fm.fileExists(atPath: artSrc) {
                    _ = self.cloneOrCopy(from: artSrc, to: coverPath)
                }
            }
            
            if let src = sourcePath, fm.fileExists(atPath: src) {
                // If source and dest are the exact same physical path, skip
                if src == destFilePath {
                    skipped += 1
                } else if fm.fileExists(atPath: destFilePath) {
                    // Check if already copied and non-empty
                    let srcSize = (try? fm.attributesOfItem(atPath: src)[.size] as? Int64) ?? 0
                    let destSize = (try? fm.attributesOfItem(atPath: destFilePath)[.size] as? Int64) ?? 0
                    if destSize > 0 && destSize == srcSize {
                        skipped += 1
                    } else {
                        // Re-copy
                        try? fm.removeItem(atPath: destFilePath)
                        if self.cloneOrCopy(from: src, to: destFilePath) {
                            try? fm.setAttributes([.modificationDate: item.dateAdded], ofItemAtPath: destFilePath)
                            migrated += 1
                        } else {
                            print("Error cloning file from \(src)")
                        }
                    }
                } else {
                    if self.cloneOrCopy(from: src, to: destFilePath) {
                        try? fm.setAttributes([.modificationDate: item.dateAdded], ofItemAtPath: destFilePath)
                        migrated += 1
                    } else {
                        print("Error cloning item from \(src)")
                    }
                }
            } else {
                skipped += 1
            }
            
            let currentProgress = Double(index + 1) / Double(max(total, 1))
            let currentMigrated = migrated
            let currentSkipped = skipped
            
            if (index + 1) % 10 == 0 || index + 1 == total {
                DispatchQueue.main.async {
                    self.progress = currentProgress
                    self.migratedCount = currentMigrated
                    self.skippedCount = currentSkipped
                    self.statusMessage = "Migrated \(currentMigrated) tracks (\(index + 1)/\(total))..."
                }
            }
        }
        
        // Invalidate scanners
        LocalFileLibraryScanner.shared.clearCache()
        _ = LocalFileLibraryScanner.shared.scanAlbums(forceRefresh: true)
        
        // Notify daemon if running via rescan trigger
        notifyDaemonRescan()
        
        DispatchQueue.main.async {
            self.isMigrating = false
            self.progress = 1.0
            self.migratedCount = migrated
            self.skippedCount = skipped
            self.completionSummary = "Successfully copied \(migrated) tracks into AudioStream! (\(skipped) already up to date). Original addition dates have been preserved."
            self.showCompletionAlert = true
            self.statusMessage = "Migration complete."
        }
    }
    
    private func sanitize(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "Unknown" }
        
        let invalidChars = CharacterSet(charactersIn: "\\/*?:\"<>|")
        s = s.components(separatedBy: invalidChars).joined(separator: "_")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return s.isEmpty ? "Unknown" : s
    }
    
    private func cloneOrCopy(from src: String, to dst: String) -> Bool {
        // Use copyfile with COPYFILE_CLONE (1 << 24) for instant APFS copy-on-write
        // Takes 0 bytes of storage until modified, avoiding out of space errors
        let COPYFILE_CLONE: Int32 = 1 << 24
        if copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 {
            return true
        }
        // Fallback to regular file copy if clone fails
        do {
            try FileManager.default.copyItem(atPath: src, toPath: dst)
            return true
        } catch {
            print("Failed to copy \(src) to \(dst): \(error)")
            return false
        }
    }
    
    private func notifyDaemonRescan() {
        guard let url = URL(string: "http://127.0.0.1:18080/api/refresh") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req).resume()
    }
}

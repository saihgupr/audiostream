import Foundation
import Network
import SQLite3
import AVFoundation

// MARK: - Logger
private let serverLogLock = NSLock()
private let serverLogMaxBytes: UInt64 = 512 * 1024

public func serverLog(_ message: String) {
    let msg = "[\(Date())] \(message)\n"
    if let data = msg.data(using: .utf8) {
        let logURL = URL(fileURLWithPath: "/tmp/audiostreamer.log")
        serverLogLock.lock()
        defer { serverLogLock.unlock() }

        let fm = FileManager.default
        if fm.fileExists(atPath: logURL.path) {
            if let attrs = try? fm.attributesOfItem(atPath: logURL.path),
               let size = attrs[.size] as? UInt64,
               size >= serverLogMaxBytes,
               let existing = try? Data(contentsOf: logURL) {
                let keepBytes = Int(serverLogMaxBytes / 2)
                if existing.count > keepBytes {
                    var slice = existing.suffix(keepBytes)
                    if let newlineIdx = slice.firstIndex(of: 0x0A), newlineIdx < slice.endIndex {
                        let afterNewline = slice.index(after: newlineIdx)
                        if afterNewline < slice.endIndex {
                            slice = slice[afterNewline...]
                        }
                    }
                    try? Data(slice).write(to: logURL, options: .atomic)
                }
            }
            if let fileHandle = try? FileHandle(forWritingTo: logURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            } else {
                try? data.write(to: logURL)
            }
        } else {
            try? data.write(to: logURL)
        }
    }
    print(message)
}

// MARK: - Helper
func keyString(for item: AVMetadataItem) -> String? {
    if let str = item.key as? String { return str }
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
        return identifier.components(separatedBy: "/").last
    }
    return nil
}

// MARK: - Models
public struct Song: Codable, Identifiable {
    public let id: Int64
    public let persistentId: UInt64
    public let title: String
    public let artist: String
    public let album: String
    public let filename: String
    public let duration: TimeInterval
    public var dateAdded: TimeInterval?
    public var trackNumber: Int?
    
    public init(id: Int64, persistentId: UInt64, title: String, artist: String, album: String, filename: String, duration: TimeInterval, dateAdded: TimeInterval? = nil, trackNumber: Int? = nil) {
        self.id = id
        self.persistentId = persistentId
        self.title = title
        self.artist = artist
        self.album = album
        self.filename = filename
        self.duration = duration
        self.dateAdded = dateAdded
        self.trackNumber = trackNumber
    }
    
    public var durationFormatted: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

public struct Playlist: Codable, Identifiable {
    public let id: Int64
    public let name: String
    public let songIds: [Int64]
    
    public init(id: Int64, name: String, songIds: [Int64]) {
        self.id = id
        self.name = name
        self.songIds = songIds
    }
}

// MARK: - Server
public class SimpleHTTPServer {
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private let port: UInt16
    private let musicBasePaths: [String]
    private let songsProvider: () -> [Song]
    private let playlistsProvider: () -> [Playlist]
    private let songFilePathsProvider: () -> [UInt64: String]
    private let songsCountProvider: () -> Int
    private let playlistsCountProvider: () -> Int
    private let deleteHandler: ((String, [String: Any]) -> Bool)?
    private let rescanHandler: ((Bool) -> Void)?
    
    private let artworkCache = NSCache<NSNumber, NSData>()
    private let artworkMimeCache = NSCache<NSNumber, NSString>()
    private var noArtworkIds = Set<UInt64>()
    private let noArtworkLock = NSLock()
    
    private var songsJSONCache: Data?
    private let songsJSONLock = NSLock()
    
    private let libraryReadyCondition = NSCondition()
    private var libraryReady = false
    private let serverQueue = DispatchQueue(label: "com.audiostream.httpserver", attributes: .concurrent)
    
    public init(
        port: UInt16,
        musicBasePaths: [String],
        songsProvider: @escaping () -> [Song],
        playlistsProvider: @escaping () -> [Playlist],
        songFilePathsProvider: @escaping () -> [UInt64: String] = { [:] },
        songsCountProvider: (() -> Int)? = nil,
        playlistsCountProvider: (() -> Int)? = nil,
        deleteHandler: ((String, [String: Any]) -> Bool)? = nil,
        rescanHandler: ((Bool) -> Void)? = nil
    ) {
        signal(SIGPIPE, SIG_IGN)
        self.port = port
        self.musicBasePaths = musicBasePaths
        self.songsProvider = songsProvider
        self.playlistsProvider = playlistsProvider
        self.songFilePathsProvider = songFilePathsProvider
        self.songsCountProvider = songsCountProvider ?? { songsProvider().count }
        self.playlistsCountProvider = playlistsCountProvider ?? { playlistsProvider().count }
        self.deleteHandler = deleteHandler
        self.rescanHandler = rescanHandler
        self.artworkCache.countLimit = 300
    }

    /// Clears cached artwork. With no id, evicts everything (positive
    /// caches plus the negative no-artwork set); with an id, evicts just
    /// that song. Called on rescan and on per-artwork ?refresh=1.
    public func invalidateArtworkCache(id: UInt64? = nil) {
        if let id = id {
            let key = NSNumber(value: id)
            artworkCache.removeObject(forKey: key)
            artworkMimeCache.removeObject(forKey: key)
            noArtworkLock.lock()
            noArtworkIds.remove(id)
            noArtworkLock.unlock()
        } else {
            artworkCache.removeAllObjects()
            artworkMimeCache.removeAllObjects()
            noArtworkLock.lock()
            noArtworkIds.removeAll()
            noArtworkLock.unlock()
        }
    }
    
    /// Drops the serialized /api/songs payload. Call whenever the song list or
    /// merge groups change so the next request rebuilds it.
    public func invalidateSongsJSONCache() {
        songsJSONLock.lock()
        songsJSONCache = nil
        songsJSONLock.unlock()
    }
    
    /// Marks the initial library scan as complete. Requests for songs or
    /// playlists wait for this instead of returning an empty list to clients
    /// that connect while the daemon is still starting up.
    public func markLibraryReady() {
        libraryReadyCondition.lock()
        libraryReady = true
        libraryReadyCondition.broadcast()
        libraryReadyCondition.unlock()
    }
    
    private func waitForLibraryReady(timeout: TimeInterval = 30) -> Bool {
        libraryReadyCondition.lock()
        defer { libraryReadyCondition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !libraryReady {
            if !libraryReadyCondition.wait(until: deadline) {
                break
            }
        }
        return libraryReady
    }
    
    public func start() {
        signal(SIGPIPE, SIG_IGN)
        serverQueue.async { [weak self] in
            self?.runServer()
        }
    }
    
    public func stop() {
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }
    
    private func runServer() {
        signal(SIGPIPE, SIG_IGN)
        serverLog("SimpleHTTPServer.start() initializing POSIX socket on port \(port)...")
        
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            serverLog("Failed to create socket: \(errno)")
            return
        }
        
        var opt: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
        #if os(iOS) || os(macOS)
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEPORT, &opt, socklen_t(MemoryLayout<Int32>.size))
        #endif
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = in_addr_t(0) // INADDR_ANY
        addr.sin_port = port.bigEndian
        
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        guard bindResult >= 0 else {
            serverLog("Failed to bind socket to port \(port): \(errno) (\(String(cString: strerror(errno))))")
            close(serverSocket)
            serverSocket = -1
            return
        }
        
        guard listen(serverSocket, 128) >= 0 else {
            serverLog("Failed to listen on socket: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }
        
        isRunning = true
        serverLog("HTTP Server listener is READY on port \(port)")
        
        while isRunning {
            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            
            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverSocket, $0, &clientAddrLen)
                }
            }
            
            guard clientSocket >= 0 else {
                if !isRunning { break }
                continue
            }
            
            var noSigPipe: Int32 = 1
            setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientSocket)
            }
        }
    }
    
    private func handleClient(_ clientSocket: Int32) {
        defer { close(clientSocket) }
        
        var noSigPipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientSocket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        
        var buffer = [UInt8](repeating: 0, count: 16384)
        let bytesRead = read(clientSocket, &buffer, buffer.count - 1)
        guard bytesRead > 0 else { return }
        
        guard let request = String(bytes: buffer[0..<bytesRead], encoding: .utf8) else { return }
        processRequest(request, clientSocket: clientSocket)
    }
    
    private func processRequest(_ request: String, clientSocket: Int32) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        
        let method = parts[0]
        let rawPath = parts[1].removingPercentEncoding ?? parts[1]
        let pathComponents = rawPath.components(separatedBy: "?")
        let path = pathComponents[0]
        let queryString = pathComponents.count > 1 ? pathComponents[1] : ""
        let isForceRefresh = queryString.contains("refresh=true") || queryString.contains("refresh=1")
        
        serverLog("Request: \(method) \(rawPath)")
        
        if method == "POST" && path == "/api/delete" {
            handleDeleteRequest(request: request, clientSocket: clientSocket)
            return
        }
        
        var rangeStart: Int64? = nil
        var rangeEnd: Int64? = nil
        for line in lines {
            if line.lowercased().hasPrefix("range:") {
                let rangeValue = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if let match = rangeValue.range(of: #"bytes=(\d+)-(\d*)"#, options: .regularExpression) {
                    let rangeStr = String(rangeValue[match])
                    let nums = rangeStr.replacingOccurrences(of: "bytes=", with: "").components(separatedBy: "-")
                    rangeStart = Int64(nums[0])
                    if nums.count > 1 && !nums[1].isEmpty {
                        rangeEnd = Int64(nums[1])
                    }
                }
            }
        }
        
        switch path {
        case "/":
            sendWebPlayer(clientSocket: clientSocket)
        case "/favicon.ico", "/favicon.png", "/icon.png":
            sendFavicon(clientSocket: clientSocket)
        case "/api/ping", "/api/status", "/ping", "/status":
            let songsCount = songsCountProvider()
            let playlistsCount = playlistsCountProvider()
            sendJSONResponse(jsonObject: [
                "status": "ok",
                "songsCount": songsCount,
                "playlistsCount": playlistsCount,
                "version": "1.0.0"
            ], status: "200 OK", clientSocket: clientSocket)
        case "/api/songs":
            if isForceRefresh {
                rescanHandler?(true)
                invalidateSongsJSONCache()
            }
            sendSongsJSON(clientSocket: clientSocket)
        case "/api/rescan", "/api/refresh":
            rescanHandler?(true)
            invalidateSongsJSONCache()
            sendJSONResponse(jsonObject: [
                "status": "ok",
                "songsCount": songsCountProvider()
            ], status: "200 OK", clientSocket: clientSocket)
        case "/api/playlists":
            if isForceRefresh {
                rescanHandler?(true)
            }
            sendPlaylistsJSON(clientSocket: clientSocket)
        case _ where path.hasPrefix("/music/"):
            let filename = String(path.dropFirst(7))
            sendAudioFile(filename: filename, clientSocket: clientSocket, rangeStart: rangeStart, rangeEnd: rangeEnd)
        case _ where path.hasPrefix("/artwork/"):
            let idStr = String(path.dropFirst(9))
            if let id = UInt64(idStr) {
                if isForceRefresh {
                    invalidateArtworkCache(id: id)
                }
                sendArtwork(persistentId: id, clientSocket: clientSocket)
            } else {
                send404(clientSocket: clientSocket)
            }
        default:
            send404(clientSocket: clientSocket)
        }
    }
    
    private func handleDeleteRequest(request: String, clientSocket: Int32) {
        guard let bodyIndex = request.range(of: "\r\n\r\n")?.upperBound else {
            sendJSONResponse(jsonObject: ["success": false, "error": "No body"], status: "400 Bad Request", clientSocket: clientSocket)
            return
        }
        let bodyString = String(request[bodyIndex...])
        guard let bodyData = bodyString.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
              let type = json["type"] as? String,
              let deleteHandler = deleteHandler else {
            sendJSONResponse(jsonObject: ["success": false, "error": "Invalid payload or deleteHandler"], status: "400 Bad Request", clientSocket: clientSocket)
            return
        }
        
        let success = deleteHandler(type, json)
        if success {
            invalidateSongsJSONCache()
            sendJSONResponse(jsonObject: ["success": true], status: "200 OK", clientSocket: clientSocket)
        } else {
            sendJSONResponse(jsonObject: ["success": false, "error": "Deletion failed"], status: "500 Internal Server Error", clientSocket: clientSocket)
        }
    }
    
    private func sendData(_ data: Data, clientSocket: Int32) {
        data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress else { return }
            var totalSent = 0
            while totalSent < data.count {
                let sent = write(clientSocket, ptr.advanced(by: totalSent), data.count - totalSent)
                if sent <= 0 { break }
                totalSent += sent
            }
        }
    }
    
    private func sendJSONResponse(jsonObject: [String: Any], status: String, clientSocket: Int32) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            send500(clientSocket: clientSocket)
            return
        }
        let response = "HTTP/1.1 \(status)\r\nServer: AudioStreamer\r\nContent-Type: application/json\r\nContent-Length: \(jsonString.utf8.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n\(jsonString)"
        if let data = response.data(using: .utf8) {
            sendData(data, clientSocket: clientSocket)
        }
    }
    
    private func sendWebPlayer(clientSocket: Int32) {
        let html = MusicServerHTML.content
        let response = "HTTP/1.1 200 OK\r\nServer: AudioStreamer\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        if let data = response.data(using: .utf8) {
            sendData(data, clientSocket: clientSocket)
        }
    }
    
    private func sendFavicon(clientSocket: Int32) {
        let fileManager = FileManager.default
        let candidates = [
            "/var/mobile/Documents/icon.png",
            Bundle.main.path(forResource: "icon", ofType: "png"),
            "icon.png"
        ].compactMap { $0 }
        
        for path in candidates {
            if fileManager.fileExists(atPath: path), let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty {
                sendImage(data: data, mimeType: "image/png", clientSocket: clientSocket)
                return
            }
        }
        
        send404(clientSocket: clientSocket)
    }
    
    private func sendSongsJSON(clientSocket: Int32) {
        guard waitForLibraryReady() else {
            sendServiceUnavailable(clientSocket: clientSocket)
            return
        }
        // Touch the provider first: it refreshes merge-group revisions and
        // invalidates the serialized cache when they changed.
        let currentSongs = songsProvider()
        
        songsJSONLock.lock()
        let cachedData = songsJSONCache
        songsJSONLock.unlock()
        
        if let cachedData = cachedData {
            sendJSONData(cachedData, clientSocket: clientSocket)
            return
        }
        
        let songsWithDetails = currentSongs.map { song -> [String: Any] in
            var dict: [String: Any] = [
                "id": song.id,
                "persistentId": String(song.persistentId),
                "title": song.title,
                "artist": song.artist,
                "album": song.album,
                "filename": song.filename,
                "duration": song.duration,
                "durationFormatted": song.durationFormatted
            ]
            if let date = song.dateAdded { dict["dateAdded"] = date }
            if let trackNum = song.trackNumber { dict["trackNumber"] = trackNum }
            return dict
        }
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: songsWithDetails) else {
            send500(clientSocket: clientSocket)
            return
        }
        
        songsJSONLock.lock()
        songsJSONCache = jsonData
        songsJSONLock.unlock()
        
        sendJSONData(jsonData, clientSocket: clientSocket)
    }
    
    private func sendJSONData(_ jsonData: Data, clientSocket: Int32) {
        let headers = "HTTP/1.1 200 OK\r\nServer: AudioStreamer\r\nContent-Type: application/json\r\nContent-Length: \(jsonData.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var response = headers.data(using: .utf8)!
        response.append(jsonData)
        sendData(response, clientSocket: clientSocket)
    }
    
    private func sendPlaylistsJSON(clientSocket: Int32) {
        guard waitForLibraryReady() else {
            sendServiceUnavailable(clientSocket: clientSocket)
            return
        }
        let encoder = JSONEncoder()
        if let jsonData = try? encoder.encode(playlistsProvider()) {
            let headers = "HTTP/1.1 200 OK\r\nServer: AudioStreamer\r\nContent-Type: application/json\r\nContent-Length: \(jsonData.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            var response = headers.data(using: .utf8)!
            response.append(jsonData)
            sendData(response, clientSocket: clientSocket)
        } else {
            send500(clientSocket: clientSocket)
        }
    }
    
    private func isAllowedAudioPath(_ candidatePath: String) -> Bool {
        let resolvedCandidate = URL(fileURLWithPath: candidatePath).resolvingSymlinksInPath().standardizedFileURL.path
        let allowedRoots = musicBasePaths + [
            "/var/mobile/Media/iTunes_Control/Music",
            "/var/mobile/Media/Purchases"
        ]
        for root in allowedRoots {
            let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
            let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
            if resolvedCandidate == resolvedRoot || resolvedCandidate.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }

    private func validatedExistingFilePath(_ candidatePath: String) -> String? {
        let resolved = URL(fileURLWithPath: candidatePath).resolvingSymlinksInPath().standardizedFileURL.path
        guard isAllowedAudioPath(resolved) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return resolved
    }

    private func sendAudioFile(filename: String, clientSocket: Int32, rangeStart: Int64?, rangeEnd: Int64?) {
        var foundPath: String? = nil
        var blockedUnauthorized = false
        let decodedFilename = filename.removingPercentEncoding ?? filename

        func checkCandidate(_ candidate: String) -> String? {
            if !isAllowedAudioPath(candidate) {
                blockedUnauthorized = true
                return nil
            }
            return validatedExistingFilePath(candidate)
        }

        // 1. Direct absolute path or relative to musicBasePaths
        if decodedFilename.hasPrefix("/") {
            foundPath = checkCandidate(decodedFilename)
        } else {
            for basePath in musicBasePaths {
                let trialPath = (basePath as NSString).appendingPathComponent(decodedFilename)
                if let resolved = checkCandidate(trialPath) {
                    foundPath = resolved
                    blockedUnauthorized = false
                    break
                }
            }
        }

        // 2. Try raw filename if decoded differed
        if foundPath == nil && filename != decodedFilename {
            if filename.hasPrefix("/") {
                foundPath = checkCandidate(filename)
            } else {
                for basePath in musicBasePaths {
                    let trialPath = (basePath as NSString).appendingPathComponent(filename)
                    if let resolved = checkCandidate(trialPath) {
                        foundPath = resolved
                        blockedUnauthorized = false
                        break
                    }
                }
            }
        }

        // 3. Fallback: Lookup in song providers by filename
        if foundPath == nil && !blockedUnauthorized {
            let songs = songsProvider()
            if let song = songs.first(where: { $0.filename == decodedFilename || $0.filename == filename }) {
                if song.filename.hasPrefix("/") {
                    foundPath = validatedExistingFilePath(song.filename)
                } else {
                    for basePath in musicBasePaths {
                        let fullPath = (basePath as NSString).appendingPathComponent(song.filename)
                        if let resolved = validatedExistingFilePath(fullPath) {
                            foundPath = resolved
                            break
                        }
                    }
                }
            }
        }

        if foundPath == nil && blockedUnauthorized {
            serverLog("⚠️ Blocked unauthorized audio path request: \(filename)")
            send403(clientSocket: clientSocket)
            return
        }

        guard let filePath = foundPath, let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            serverLog("Audio file not found: \(filename)")
            send404(clientSocket: clientSocket)
            return
        }
        defer { fileHandle.closeFile() }

        let fileSize = Int64(fileHandle.seekToEndOfFile())
        if fileSize <= 0 {
            if rangeStart != nil {
                send416(fileSize: 0, clientSocket: clientSocket)
            } else {
                let headers = "HTTP/1.1 200 OK\r\nServer: AudioStreamer\r\nContent-Length: 0\r\nAccept-Ranges: bytes\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
                if let headerData = headers.data(using: .utf8) {
                    sendData(headerData, clientSocket: clientSocket)
                }
            }
            return
        }

        let start = rangeStart ?? 0
        let requestedEnd = rangeEnd ?? (fileSize - 1)
        let end = min(requestedEnd, fileSize - 1)
        if start < 0 || start >= fileSize || start > end {
            send416(fileSize: fileSize, clientSocket: clientSocket)
            return
        }
        let totalToRead = end - start + 1
        
        var headers = ""
        if rangeStart != nil {
            headers = "HTTP/1.1 206 Partial Content\r\n"
            headers += "Server: AudioStreamer\r\n"
            headers += "Content-Range: bytes \(start)-\(end)/\(fileSize)\r\n"
        } else {
            headers = "HTTP/1.1 200 OK\r\n"
            headers += "Server: AudioStreamer\r\n"
        }
        
        let pathExtension = (filePath as NSString).pathExtension.lowercased()
        let contentType: String
        switch pathExtension {
        case "mp3": contentType = "audio/mpeg"
        case "m4a", "mp4", "alac": contentType = "audio/mp4"
        case "aac": contentType = "audio/aac"
        case "wav": contentType = "audio/wav"
        case "flac": contentType = "audio/flac"
        case "aiff", "aif": contentType = "audio/aiff"
        default: contentType = "application/octet-stream"
        }
        
        headers += "Content-Type: \(contentType)\r\n"
        headers += "Content-Length: \(totalToRead)\r\n"
        headers += "Accept-Ranges: bytes\r\n"
        headers += "Access-Control-Allow-Origin: *\r\n"
        headers += "Connection: close\r\n\r\n"
        
        if let headerData = headers.data(using: .utf8) {
            sendData(headerData, clientSocket: clientSocket)
        }
        
        // Stream audio in 128KB chunks
        let chunkSize = 128 * 1024
        var currentOffset = UInt64(start)
        var remaining = totalToRead
        
        while remaining > 0 {
            let toRead = Int(min(Int64(chunkSize), remaining))
            fileHandle.seek(toFileOffset: currentOffset)
            let data = fileHandle.readData(ofLength: toRead)
            if data.isEmpty { break }
            
            var sentInChunk = false
            data.withUnsafeBytes { rawBuffer in
                guard let ptr = rawBuffer.baseAddress else { return }
                var totalSent = 0
                while totalSent < data.count {
                    let sent = write(clientSocket, ptr.advanced(by: totalSent), data.count - totalSent)
                    if sent <= 0 { break }
                    totalSent += sent
                }
                if totalSent == data.count { sentInChunk = true }
            }
            if !sentInChunk { break }
            
            currentOffset += UInt64(data.count)
            remaining -= Int64(data.count)
        }
    }
    
    private static let folderArtworkNames = ["folder.jpg", "cover.jpg", "folder.png", "cover.png", "artwork.jpg", "artwork.png", "Cover.jpg", "Folder.jpg", "Cover.png", "Folder.png", "cover.jpeg", "folder.jpeg"]

    /// Resolves the on-disk audio file for a song id via the path map,
    /// falling back to the song list + base paths. Returns nil if unknown or outside allowed roots.
    private func resolveSongFilePath(persistentId: UInt64) -> String? {
        let pathMap = songFilePathsProvider()

        if let path = pathMap[persistentId] {
            if path.hasPrefix("/") {
                if let resolved = validatedExistingFilePath(path) {
                    return resolved
                }
            } else {
                for basePath in musicBasePaths {
                    let fullPath = (basePath as NSString).appendingPathComponent(path)
                    if let resolved = validatedExistingFilePath(fullPath) {
                        return resolved
                    }
                }
            }
        }

        let songs = songsProvider()
        if let song = songs.first(where: { $0.persistentId == persistentId }) {
            if song.filename.hasPrefix("/") {
                if let resolved = validatedExistingFilePath(song.filename) {
                    return resolved
                }
            } else {
                for basePath in musicBasePaths {
                    let fullPath = (basePath as NSString).appendingPathComponent(song.filename)
                    if let resolved = validatedExistingFilePath(fullPath) {
                        return resolved
                    }
                }
            }
        }
        return nil
    }

    /// Cheap folder-image probe: same candidate names + up-to-3-level dir
    /// walk as the sendArtwork fallback. No AVAsset parsing, safe to call
    /// on every negative-cache hit.
    private func folderImageData(forFilePath path: String) -> (Data, String)? {
        let fileManager = FileManager.default
        var dirURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        for _ in 0..<3 {
            for name in Self.folderArtworkNames {
                let imgPath = dirURL.appendingPathComponent(name).path
                if fileManager.fileExists(atPath: imgPath),
                   let data = try? Data(contentsOf: URL(fileURLWithPath: imgPath)),
                   !data.isEmpty {
                    let mime = name.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg"
                    return (data, mime)
                }
            }
            let parent = dirURL.deletingLastPathComponent()
            if parent == dirURL || parent.path == "/var/mobile/Documents" { break }
            dirURL = parent
        }
        return nil
    }

    private func sendArtwork(persistentId: UInt64, clientSocket: Int32) {
        let key = NSNumber(value: persistentId)
        
        // 0. Fast cache checks. The negative set is revalidated with a cheap
        // folder-image probe so a cover.jpg added after a 404 is picked up
        // instead of 404ing forever.
        noArtworkLock.lock()
        let wasNegative = noArtworkIds.contains(persistentId)
        noArtworkLock.unlock()
        if wasNegative {
            if let probePath = resolveSongFilePath(persistentId: persistentId),
               folderImageData(forFilePath: probePath) != nil {
                noArtworkLock.lock()
                noArtworkIds.remove(persistentId)
                noArtworkLock.unlock()
            } else {
                send404(clientSocket: clientSocket)
                return
            }
        }
        
        if let cachedData = artworkCache.object(forKey: key) as Data?,
           let cachedMime = artworkMimeCache.object(forKey: key) as String? {
            sendImage(data: cachedData, mimeType: cachedMime, clientSocket: clientSocket)
            return
        }
        
        guard let path = resolveSongFilePath(persistentId: persistentId) else {
            noArtworkLock.lock()
            noArtworkIds.insert(persistentId)
            noArtworkLock.unlock()
            send404(clientSocket: clientSocket)
            return
        }
        
        // 1. Extract artwork from audio metadata
        let asset = AVAsset(url: URL(fileURLWithPath: path))
        let allMeta = asset.commonMetadata + asset.metadata
        
        for item in allMeta {
            if item.commonKey == .commonKeyArtwork, let data = item.dataValue, !data.isEmpty {
                let mime = (data.count > 4 && data[0] == 0x89) ? "image/png" : "image/jpeg"
                artworkCache.setObject(data as NSData, forKey: key)
                artworkMimeCache.setObject(mime as NSString, forKey: key)
                sendImage(data: data, mimeType: mime, clientSocket: clientSocket)
                return
            }
            if let keyStr = keyString(for: item), (keyStr == "covr" || keyStr == "APIC" || keyStr == "PIC" || keyStr.lowercased().contains("art")), let data = item.dataValue, !data.isEmpty {
                let mime = (data.count > 4 && data[0] == 0x89) ? "image/png" : "image/jpeg"
                artworkCache.setObject(data as NSData, forKey: key)
                artworkMimeCache.setObject(mime as NSString, forKey: key)
                sendImage(data: data, mimeType: mime, clientSocket: clientSocket)
                return
            }
            if let data = item.dataValue, data.count > 100 {
                if (data[0] == 0xFF && data[1] == 0xD8) || (data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) {
                    let mime = (data[0] == 0x89) ? "image/png" : "image/jpeg"
                    artworkCache.setObject(data as NSData, forKey: key)
                    artworkMimeCache.setObject(mime as NSString, forKey: key)
                    sendImage(data: data, mimeType: mime, clientSocket: clientSocket)
                    return
                }
            }
        }
        
        // 2. Folder image fallback
        if let (data, mime) = folderImageData(forFilePath: path) {
            artworkCache.setObject(data as NSData, forKey: key)
            artworkMimeCache.setObject(mime as NSString, forKey: key)
            sendImage(data: data, mimeType: mime, clientSocket: clientSocket)
            return
        }
        
        noArtworkLock.lock()
        noArtworkIds.insert(persistentId)
        noArtworkLock.unlock()
        send404(clientSocket: clientSocket)
    }
    
    private func sendImage(data: Data, mimeType: String, clientSocket: Int32) {
        let headers = "HTTP/1.1 200 OK\r\nServer: AudioStreamer\r\nContent-Type: \(mimeType)\r\nContent-Length: \(data.count)\r\nCache-Control: max-age=86400\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var responseData = headers.data(using: .utf8)!
        responseData.append(data)
        sendData(responseData, clientSocket: clientSocket)
    }
    
    private func send403(clientSocket: Int32) {
        let response = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        if let data = response.data(using: .utf8) {
            sendData(data, clientSocket: clientSocket)
        }
    }

    private func send404(clientSocket: Int32) {
        let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        if let data = response.data(using: .utf8) {
            sendData(data, clientSocket: clientSocket)
        }
    }

    private func send416(fileSize: Int64, clientSocket: Int32) {
        let response = "HTTP/1.1 416 Range Not Satisfiable\r\nServer: AudioStreamer\r\nContent-Range: bytes */\(fileSize)\r\nContent-Length: 0\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        if let data = response.data(using: .utf8) {
            sendData(data, clientSocket: clientSocket)
        }
    }
    
    private func send500(clientSocket: Int32) {
        let response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        if let data = response.data(using: .utf8) {
            sendData(data, clientSocket: clientSocket)
        }
    }
    
    private func sendServiceUnavailable(clientSocket: Int32) {
        let response = "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 2\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        if let data = response.data(using: .utf8) {
            sendData(data, clientSocket: clientSocket)
        }
    }
}

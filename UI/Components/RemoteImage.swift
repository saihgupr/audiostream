import SwiftUI
import Combine
import MediaPlayer

class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    private var cancellable: AnyCancellable?
    private var currentURL: URL?

    private static let diskWriteQueue = DispatchQueue(label: "com.audiostream.imagecache.disk", qos: .utility)
    private static let pruneLock = NSLock()
    private static var writeCountSincePrune = 0
    private static let maxDiskCacheBytes: UInt64 = 40 * 1024 * 1024
    private static let targetDiskCacheBytes: UInt64 = 28 * 1024 * 1024

    private static let prewarmQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.audiostream.artwork.prewarm"
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 2
        return q
    }()

    // Memory cache to prevent redundant fetches and enable smooth scrolling
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 250
        c.totalCostLimit = 45 * 1024 * 1024 // 45 MB (shared with LocalFileArtworkCache's 20 MB budget)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            c.removeAllObjects()
        }
        return c
    }()

    static func setCachedImage(_ image: UIImage, for urlString: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: urlString as NSString, cost: cost)
    }

    static func getCachedImage(for urlString: String) -> UIImage? {
        return cache.object(forKey: urlString as NSString)
    }

    static func fastMemoryImage(for url: URL) -> UIImage? {
        if let cached = cache.object(forKey: url.absoluteString as NSString) {
            return cached
        }
        if url.scheme == "local-file-artwork", let host = url.host {
            return LocalFileArtworkCache.shared.getFromMemory(for: host)
        }
        return nil
    }

    static let cacheDirectory: URL = {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let cachePath = paths[0].appendingPathComponent("AudioStreamImageCache")
        if !FileManager.default.fileExists(atPath: cachePath.path) {
            try? FileManager.default.createDirectory(at: cachePath, withIntermediateDirectories: true)
        }
        AppCacheStorage.pruneDirectory(cachePath, maxBytes: maxDiskCacheBytes, targetBytes: targetDiskCacheBytes)
        return cachePath
    }()

    static func stableFilename(for string: String) -> String {
        // FNV-1a 64-bit over UTF-8 bytes: stable across launches (unlike String.hashValue).
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    static func diskCacheURL(for url: URL) -> URL {
        return cacheDirectory.appendingPathComponent(stableFilename(for: url.absoluteString))
    }

    static func removeDiskCache(for url: URL) {
        let diskURL = diskCacheURL(for: url)
        cache.removeObject(forKey: url.absoluteString as NSString)
        diskWriteQueue.async {
            try? FileManager.default.removeItem(at: diskURL)
        }
    }

    static func recordDiskWrite() {
        pruneLock.lock()
        writeCountSincePrune += 1
        let shouldPrune = writeCountSincePrune >= 25
        if shouldPrune {
            writeCountSincePrune = 0
        }
        pruneLock.unlock()

        if shouldPrune {
            AppCacheStorage.pruneDirectory(cacheDirectory, maxBytes: maxDiskCacheBytes, targetBytes: targetDiskCacheBytes)
        }
    }

    static func predecode(_ image: UIImage) -> UIImage {
        if #available(iOS 15.0, *) {
            if let prepared = image.preparingForDisplay() {
                return prepared
            }
        }
        guard let cgImage = image.cgImage else { return image }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return image }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return image
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let decoded = ctx.makeImage() else { return image }
        return UIImage(cgImage: decoded, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func downscaledCGImage(from data: Data, maxPixelSize: CGFloat = 350) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func downscaledCGImage(fromURL url: URL, maxPixelSize: CGFloat = 350) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func downscaledThumbnail(from data: Data, maxPixelSize: CGFloat = 350) -> UIImage? {
        guard let cgImage = downscaledCGImage(from: data, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return predecode(UIImage(cgImage: cgImage))
    }

    private static func downscaledThumbnail(fromURL url: URL, maxPixelSize: CGFloat = 350) -> UIImage? {
        guard let cgImage = downscaledCGImage(fromURL: url, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return predecode(UIImage(cgImage: cgImage))
    }

    private static func loadLocalFileThumbnail(from url: URL, key: String, maxPixelSize: CGFloat = 350) -> UIImage? {
        let diskURL = diskCacheURL(for: url)
        let fm = FileManager.default
        let sourceModDate = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date

        if let thumbModDate = (try? fm.attributesOfItem(atPath: diskURL.path)[.modificationDate]) as? Date,
           sourceModDate == nil || thumbDateIsFresh(thumbDate: thumbModDate, sourceDate: sourceModDate!),
           let cachedThumb = downscaledThumbnail(fromURL: diskURL, maxPixelSize: maxPixelSize) {
            return cachedThumb
        }

        guard let cgImage = downscaledCGImage(fromURL: url, maxPixelSize: maxPixelSize) else {
            return nil
        }
        let rawImage = UIImage(cgImage: cgImage)
        let displayImage = predecode(rawImage)

        // Persist a compact 350px thumbnail so subsequent launches / NSCache evictions avoid full-res cover decoding.
        diskWriteQueue.async {
            if let jpegData = rawImage.jpegData(compressionQuality: 0.8) {
                try? jpegData.write(to: diskURL, options: .atomic)
                recordDiskWrite()
            }
        }
        return displayImage
    }

    private static func thumbDateIsFresh(thumbDate: Date, sourceDate: Date) -> Bool {
        thumbDate >= sourceDate
    }

    static func prewarm(urls: [URL]) {
        guard !urls.isEmpty else { return }
        prewarmQueue.cancelAllOperations()
        for url in urls.prefix(30) {
            let key = url.absoluteString
            if cache.object(forKey: key as NSString) != nil { continue }
            prewarmQueue.addOperation {
                if cache.object(forKey: key as NSString) != nil { return }
                if url.isFileURL {
                    if let img = loadLocalFileThumbnail(from: url, key: key, maxPixelSize: 350) {
                        setCachedImage(img, for: key)
                    }
                } else if url.scheme == "local-file-artwork", let host = url.host {
                    if let img = LocalFileArtworkCache.shared.get(for: host, maxPixelSize: 350) {
                        setCachedImage(img, for: key)
                    }
                }
            }
        }
    }

    func loadIfNeeded(url: URL) {
        if currentURL == url && image != nil {
            return
        }
        load(url: url)
    }

    func reset() {
        cancellable?.cancel()
        cancellable = nil
        currentURL = nil
        image = nil
    }

    func load(url: URL) {
        currentURL = url
        let requestedURL = url
        let key = url.absoluteString
        let nsKey = key as NSString

        // Fast path: synchronous memory cache hit
        if let cachedImage = Self.cache.object(forKey: nsKey) {
            cancellable?.cancel()
            cancellable = nil
            if self.image !== cachedImage {
                self.image = cachedImage
            }
            return
        }

        if url.scheme == "local-file-artwork" {
            cancellable?.cancel()
            cancellable = nil

            guard let hostKey = url.host else {
                self.image = nil
                return
            }

            // Instant path: check LocalFileArtworkCache memory cache
            if let cached = LocalFileArtworkCache.shared.getFromMemory(for: hostKey) {
                Self.setCachedImage(cached, for: key)
                if self.image !== cached {
                    self.image = cached
                }
                return
            }

            // Asynchronous background load with thumbnail downscaling + pre-decode
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                if let img = LocalFileArtworkCache.shared.get(for: hostKey, maxPixelSize: 350) {
                    Self.setCachedImage(img, for: key)
                    DispatchQueue.main.async {
                        guard self.currentURL == requestedURL else { return }
                        self.image = img
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.currentURL == requestedURL, self.image == nil else { return }
                        self.image = nil
                    }
                }
            }
            return
        }

        if url.isFileURL {
            cancellable?.cancel()
            cancellable = nil
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                if let img = Self.loadLocalFileThumbnail(from: url, key: key, maxPixelSize: 350) {
                    Self.setCachedImage(img, for: key)
                    DispatchQueue.main.async {
                        guard self.currentURL == requestedURL else { return }
                        self.image = img
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.currentURL == requestedURL, self.image == nil else { return }
                        self.image = nil
                    }
                }
            }
            return
        }

        if url.scheme == "local-artwork" {
            cancellable?.cancel()
            cancellable = nil

            guard let host = url.host, let persistentID = UInt64(host) else {
                self.image = nil
                return
            }

            let diskURL = Self.diskCacheURL(for: url)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                if FileManager.default.fileExists(atPath: diskURL.path),
                   let cached = Self.downscaledThumbnail(fromURL: diskURL, maxPixelSize: 350) {
                    Self.setCachedImage(cached, for: key)
                    DispatchQueue.main.async {
                        guard self.currentURL == requestedURL else { return }
                        self.image = cached
                    }
                    return
                }

                let predicate = MPMediaPropertyPredicate(value: persistentID, forProperty: MPMediaItemPropertyPersistentID)
                let query = MPMediaQuery(filterPredicates: [predicate])
                if let artworkImage = query.items?.first?.artwork?.image(at: CGSize(width: 350, height: 350)) {
                    let predecoded = Self.predecode(artworkImage)
                    Self.setCachedImage(predecoded, for: key)
                    Self.diskWriteQueue.async {
                        if let data = predecoded.jpegData(compressionQuality: 0.8) {
                            try? data.write(to: diskURL, options: .atomic)
                            Self.recordDiskWrite()
                        }
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.currentURL == requestedURL else { return }
                        self.image = predecoded
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.currentURL == requestedURL, self.image == nil else { return }
                        self.image = nil
                    }
                }
            }
            return
        }

        let diskURL = Self.diskCacheURL(for: url)
        cancellable?.cancel()
        cancellable = nil

        // Check disk cache off the main thread before kicking off a network download.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if FileManager.default.fileExists(atPath: diskURL.path) {
                if let img = Self.downscaledThumbnail(fromURL: diskURL, maxPixelSize: 350)
                    ?? (try? Data(contentsOf: diskURL)).flatMap(UIImage.init(data:)).map(Self.predecode) {
                    Self.setCachedImage(img, for: key)
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.currentURL == requestedURL else { return }
                        self.image = img
                    }
                    return
                } else {
                    // Evict poisoned entry (e.g. a previously cached HTTP error body)
                    try? FileManager.default.removeItem(at: diskURL)
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.currentURL == requestedURL else { return }
                self.startRemoteDownload(url: url, requestedURL: requestedURL, key: key, diskURL: diskURL)
            }
        }
    }

    private func startRemoteDownload(url: URL, requestedURL: URL, key: String, diskURL: URL) {
        // Download if not found in disk cache. Only 2xx responses with
        // non-empty bodies are cached; HTTP errors (e.g. 404) map to nil
        // WITHOUT caching so a later retry can succeed.
        // Failure/cancellation NEVER writes nil over an existing good image,
        // and stale completions (cell reuse) are ignored via currentURL guard.
        cancellable = URLSession.shared.dataTaskPublisher(for: url)
            .tryMap { output -> Data in
                if let http = output.response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                guard !output.data.isEmpty else {
                    throw URLError(.zeroByteResource)
                }
                return output.data
            }
            .map { data -> UIImage? in
                let rawImage: UIImage?
                if let cgImage = Self.downscaledCGImage(from: data, maxPixelSize: 350) {
                    rawImage = UIImage(cgImage: cgImage)
                } else {
                    rawImage = UIImage(data: data)
                }
                guard let unencoded = rawImage else { return nil }
                Self.diskWriteQueue.async {
                    if let jpegData = unencoded.jpegData(compressionQuality: 0.8) {
                        try? jpegData.write(to: diskURL, options: .atomic)
                    } else {
                        try? data.write(to: diskURL, options: .atomic)
                    }
                    Self.recordDiskWrite()
                }
                return Self.predecode(unencoded)
            }
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in
                // Intentionally ignore failures AND cancellation:
                // never nil-out a good image on transient errors.
            }, receiveValue: { [weak self] img in
                guard let self = self, self.currentURL == requestedURL else { return }
                guard let img = img else { return }
                Self.setCachedImage(img, for: key)
                self.image = img
            })
    }

    deinit {
        cancellable?.cancel()
    }
}

struct RemoteImage: View {
    let url: URL?
    var fallbackView: AnyView? = nil
    @StateObject private var loader = ImageLoader()

    var body: some View {
        let displayImage = loader.image ?? url.flatMap { ImageLoader.fastMemoryImage(for: $0) }
        Group {
            if let image = displayImage {
                Image(uiImage: image)
                    .resizable()
            } else if let fallback = fallbackView {
                fallback
            } else {
                Color.gray.opacity(0.3) // Placeholder
            }
        }
        .onAppear {
            if let url = url {
                loader.loadIfNeeded(url: url)
            }
        }
        .onChange(of: url) { newUrl in
            if let newUrl = newUrl {
                loader.load(url: newUrl)
            } else {
                loader.reset()
            }
        }
    }
}

// MARK: - Artist Image Loader & View

class ArtistImageLoader: ObservableObject {
    @Published var imageURL: URL? = nil
    private var cancellable: AnyCancellable?
    
    private static var mappingFileURL: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("ArtistImageCache.json")
    }
    
    private static func loadCache() -> [String: String] {
        guard let data = try? Data(contentsOf: mappingFileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }
    
    private static func saveCache(_ dict: [String: String]) {
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(dict) {
                try? data.write(to: mappingFileURL)
            }
        }
    }
    
    private static var urlCache: [String: URL] = {
        var cache: [String: URL] = [:]
        let loaded = loadCache()
        for (key, val) in loaded {
            if let url = URL(string: val) {
                cache[key] = url
            }
        }
        return cache
    }()
    
    private static func updateCache(artist: String, url: URL) {
        urlCache[artist.lowercased()] = url
        var dict: [String: String] = [:]
        for (key, val) in urlCache {
            dict[key] = val.absoluteString
        }
        saveCache(dict)
    }
    
    func load(artistName: String) {
        let trimmed = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let primaryArtist = trimmed
            .components(separatedBy: ",")[0]
            .components(separatedBy: "&")[0]
            .components(separatedBy: " feat. ")[0]
            .components(separatedBy: " ft. ")[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            
        let cacheKey = (primaryArtist.isEmpty ? trimmed : primaryArtist).lowercased()
        
        if let cached = Self.urlCache[cacheKey] {
            self.imageURL = cached
            return
        }
        
        let searchTerm = primaryArtist.isEmpty ? trimmed : primaryArtist
        guard let encoded = searchTerm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search/artist?q=\(encoded)") else {
            return
        }
        
        cancellable = URLSession.shared.dataTaskPublisher(for: url)
            .map { $0.data }
            .decode(type: DeezerArtistSearchResponse.self, decoder: JSONDecoder())
            .map { response -> URL? in
                if let firstArtist = response.data.first {
                    return URL(string: firstArtist.picture_medium)
                }
                return nil
            }
            .replaceError(with: nil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                if let url = url {
                    Self.updateCache(artist: cacheKey, url: url)
                    self?.imageURL = url
                }
            }
    }
}

struct DeezerArtistSearchResponse: Codable {
    let data: [DeezerArtist]
}

struct DeezerArtist: Codable {
    let name: String
    let picture_medium: String
}

struct ArtistPlaceholderView: View {
    let size: CGFloat
    
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [Color.gray.opacity(0.4), Color.gray.opacity(0.2)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "person.fill")
                .resizable()
                .scaledToFit()
                .foregroundColor(.white.opacity(0.6))
                .padding(size * 0.25)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct ArtistImage: View {
    let artistName: String
    let fallbackTracks: [Track]
    let size: CGFloat
    
    @StateObject private var loader = ArtistImageLoader()
    
    private var candidateArtworkUrl: URL? {
        if let url = loader.imageURL {
            return url
        }
        return fallbackTracks.first(where: { $0.artworkUrl != nil })?.artworkUrl
    }
    
    var body: some View {
        Group {
            if let url = candidateArtworkUrl {
                RemoteImage(url: url, fallbackView: AnyView(ArtistPlaceholderView(size: size)))
            } else {
                ArtistPlaceholderView(size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .onAppear {
            loader.load(artistName: artistName)
        }
        .onChange(of: artistName) { newName in
            loader.load(artistName: newName)
        }
    }
}

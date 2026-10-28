import SwiftUI
import Combine
import MediaPlayer

class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    private var cancellable: AnyCancellable?
    
    // Memory cache to prevent redundant fetches and enable 60fps smooth scrolling
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 200
        c.totalCostLimit = 60 * 1024 * 1024 // 60 MB
        return c
    }()
    
    static func setCachedImage(_ image: UIImage, for urlString: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: urlString as NSString, cost: cost)
    }
    
    static func getCachedImage(for urlString: String) -> UIImage? {
        return cache.object(forKey: urlString as NSString)
    }
    
    private static var cacheDirectory: URL {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let cachePath = paths[0].appendingPathComponent("AudioStreamImageCache")
        if !FileManager.default.fileExists(atPath: cachePath.path) {
            try? FileManager.default.createDirectory(at: cachePath, withIntermediateDirectories: true)
        }
        return cachePath
    }
    
    private static func diskCacheURL(for url: URL) -> URL {
        let filename = abs(url.absoluteString.hashValue).description
        return cacheDirectory.appendingPathComponent(filename)
    }
    
    private static func downscaledThumbnail(from data: Data, maxPixelSize: CGFloat = 350) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
    
    private static func downscaledThumbnail(fromURL url: URL, maxPixelSize: CGFloat = 350) -> UIImage? {
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
    
    func load(url: URL) {
        let key = url.absoluteString
        let nsKey = key as NSString
        
        // Fast path: synchronous memory cache hit
        if let cachedImage = Self.cache.object(forKey: nsKey) {
            self.image = cachedImage
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
                self.image = cached
                return
            }
            
            // Asynchronous background load with thumbnail downscaling
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                if let img = LocalFileArtworkCache.shared.get(for: hostKey, maxPixelSize: 350) {
                    Self.setCachedImage(img, for: key)
                    DispatchQueue.main.async {
                        self.image = img
                    }
                } else {
                    DispatchQueue.main.async {
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
                if let img = Self.downscaledThumbnail(fromURL: url, maxPixelSize: 350) {
                    Self.setCachedImage(img, for: key)
                    DispatchQueue.main.async {
                        self.image = img
                    }
                } else {
                    DispatchQueue.main.async {
                        self.image = nil
                    }
                }
            }
            return
        }
        
        let diskURL = Self.diskCacheURL(for: url)
        
        // Check disk cache first for any cached image file
        if FileManager.default.fileExists(atPath: diskURL.path) {
            cancellable?.cancel()
            cancellable = nil
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                if let data = try? Data(contentsOf: diskURL),
                   let img = Self.downscaledThumbnail(from: data, maxPixelSize: 350) ?? UIImage(data: data) {
                    Self.setCachedImage(img, for: key)
                    DispatchQueue.main.async {
                        self?.image = img
                    }
                } else {
                    // Evict poisoned entry (e.g. a previously cached HTTP error
                    // body) so a later retry can fetch from the network.
                    try? FileManager.default.removeItem(at: diskURL)
                    DispatchQueue.main.async {
                        self?.image = nil
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
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let predicate = MPMediaPropertyPredicate(value: persistentID, forProperty: MPMediaItemPropertyPersistentID)
                let query = MPMediaQuery(filterPredicates: [predicate])
                if let artworkImage = query.items?.first?.artwork?.image(at: CGSize(width: 350, height: 350)) {
                    let downscaledImage: UIImage
                    if let data = artworkImage.jpegData(compressionQuality: 0.8) {
                        try? data.write(to: diskURL)
                        downscaledImage = Self.downscaledThumbnail(from: data, maxPixelSize: 350) ?? artworkImage
                    } else {
                        downscaledImage = artworkImage
                    }
                    Self.setCachedImage(downscaledImage, for: key)
                    DispatchQueue.main.async {
                        self?.image = downscaledImage
                    }
                } else {
                    DispatchQueue.main.async {
                        self?.image = nil
                    }
                }
            }
            return
        }
        
        // Download if not found in disk cache. Only 2xx responses with
        // non-empty bodies are cached; HTTP errors (e.g. 404) map to nil
        // WITHOUT caching so a later retry can succeed.
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
            .handleEvents(receiveOutput: { data in
                if let downscaled = Self.downscaledThumbnail(from: data, maxPixelSize: 350),
                   let jpegData = downscaled.jpegData(compressionQuality: 0.8) {
                    try? jpegData.write(to: diskURL)
                } else {
                    try? data.write(to: diskURL)
                }
            })
            .map { data -> UIImage? in
                Self.downscaledThumbnail(from: data, maxPixelSize: 350) ?? UIImage(data: data)
            }
            .replaceError(with: nil)
            .receive(on: DispatchQueue.main)
            .handleEvents(receiveOutput: { img in
                if let img = img {
                    Self.setCachedImage(img, for: key)
                }
            })
            .assign(to: \.image, on: self)
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
        Group {
            if let image = loader.image {
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
                loader.load(url: url)
            }
        }
        .onChange(of: url) { newUrl in
            if let newUrl = newUrl {
                loader.load(url: newUrl)
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

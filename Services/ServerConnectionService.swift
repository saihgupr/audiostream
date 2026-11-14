import Foundation
import Combine
import UIKit

struct ServerConnectionSnapshot {
    let librarySource: LibrarySource
    let serverURL: String
    let autoConnect: Bool
    let batterySaverMode: Bool

    static func current(defaults: UserDefaults = .standard) -> ServerConnectionSnapshot {
        let source = LibrarySource(rawValue: defaults.string(forKey: "RC_LibrarySource") ?? "") ?? .remote
        let serverURL = defaults.string(forKey: "RC_ServerURL") ?? ""
        let autoConnect = defaults.object(forKey: "RC_AutoConnect") as? Bool ?? true
        let batterySaver = defaults.object(forKey: "RC_BatterySaverMode") as? Bool ?? true
        return ServerConnectionSnapshot(
            librarySource: source,
            serverURL: serverURL,
            autoConnect: autoConnect,
            batterySaverMode: batterySaver
        )
    }
}

class ServerConnectionService: ObservableObject {
    @Published var serverURL: String = ""
    @Published var isConnected: Bool = false
    @Published var isSearching: Bool = false
    @Published var discoveredServers: [String] = []
    @Published var savedServers: [String] = []
    @Published var remoteStatus: RemoteServerStatus?
    @Published var isFetchingStatus: Bool = false
    @Published var librarySource: LibrarySource = .remote {
        didSet {
            saveSettings()
            guard !isUpdatingSettings else { return }
            if librarySource == .local {
                stopAutoConnect()
                stopConnectionTimer()
                isConnected = false
                remoteStatus = nil
                statusMessage = "Using Local Library"
            } else {
                updateConnectionTimerState()
            }
        }
    }
    @Published var autoConnect: Bool = true {
        didSet {
            saveSettings()
            guard !isUpdatingSettings else { return }
            updateConnectionTimerState()
        }
    }
    @Published var batterySaverMode: Bool = true {
        didSet {
            saveSettings()
        }
    }
    @Published var isAutoConnecting: Bool = false
    @Published var statusMessage: String = "Disconnected"
    
    private var isUpdatingSettings = false
    private let monitorsLifecycle: Bool
    private var observers: [NSObjectProtocol] = []
    
    private let kServerURLKey = "RC_ServerURL"
    private let kLibrarySourceKey = "RC_LibrarySource"
    private let kAutoConnectKey = "RC_AutoConnect"
    private let kBatterySaverModeKey = "RC_BatterySaverMode"
    private let kLastConnectedServerKey = "RC_LastConnectedServer"
    private let kSavedServersKey = "RC_SavedServers"
    
    private var connectionTimer: Timer?
    private var probeTimer: Timer?
    private var probeAttempt = 0
    private let maxProbeAttempts = 18
    
    init(startMonitoring: Bool = true) {
        self.monitorsLifecycle = startMonitoring
        loadSettings()
        if startMonitoring {
            updateConnectionTimerState()
            setupLifecycleObservers()
        }
    }

    static func currentSnapshot() -> ServerConnectionSnapshot {
        ServerConnectionSnapshot.current()
    }

    static func normalizeServerURL(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        if !lowered.hasPrefix("http://") && !lowered.hasPrefix("https://") {
            trimmed = "http://" + trimmed
        }

        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }

        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        return components.string
    }
    
    private var isBatterySaverEnabled: Bool {
        batterySaverMode
    }
    
    private func setupLifecycleObservers() {
        let bgObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if self.isBatterySaverEnabled {
                self.stopConnectionTimer()
                self.stopAutoConnect()
            }
        }
        observers.append(bgObserver)
        
        let fgObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            guard self.librarySource == .remote else {
                self.stopConnectionTimer()
                return
            }
            if !self.serverURL.isEmpty && !self.isAutoConnecting && (self.autoConnect || self.isConnected) {
                self.checkConnection()
            }
            self.updateConnectionTimerState()
        }
        observers.append(fgObserver)

        let restoreObserver = NotificationCenter.default.addObserver(forName: .appStateDidRestore, object: nil, queue: .main) { [weak self] _ in
            self?.reloadFromDefaultsAfterRestore()
        }
        observers.append(restoreObserver)
    }

    private func updateConnectionTimerState() {
        guard monitorsLifecycle else { return }
        if librarySource == .remote && (autoConnect || isConnected) {
            startConnectionTimer()
        } else {
            stopConnectionTimer()
        }
    }
    
    private func startConnectionTimer() {
        guard monitorsLifecycle, connectionTimer == nil else { return }
        // Periodic lightweight check (every 25s) to verify connection without spamming host
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.librarySource == .remote && !self.serverURL.isEmpty && !self.isAutoConnecting && (self.autoConnect || self.isConnected) {
                self.checkConnection()
            }
        }
    }
    
    private func stopConnectionTimer() {
        connectionTimer?.invalidate()
        connectionTimer = nil
    }
    
    deinit {
        connectionTimer?.invalidate()
        probeTimer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    @discardableResult
    func connect(url: String) -> Bool {
        stopAutoConnect()
        
        guard let normalizedURL = Self.normalizeServerURL(url) else {
            print("Invalid URL: \(url)")
            DispatchQueue.main.async {
                self.statusMessage = "Invalid server URL"
            }
            return false
        }
        
        self.serverURL = normalizedURL
        addSavedServer(normalizedURL)
        saveSettings()
        
        // Start deterministic connect flow targeting this URL
        startAutoConnect(targetURL: normalizedURL)
        return true
    }

    func addSavedServer(_ rawURL: String) {
        guard let normalized = Self.normalizeServerURL(rawURL) else { return }
        var updated = savedServers.filter { $0.caseInsensitiveCompare(normalized) != .orderedSame }
        updated.insert(normalized, at: 0)
        if updated.count > 8 {
            updated = Array(updated.prefix(8))
        }
        savedServers = updated
        saveSettings()
    }

    func removeSavedServer(_ url: String) {
        savedServers.removeAll { $0.caseInsensitiveCompare(url) == .orderedSame }
        saveSettings()
    }
    
    func setLibrarySource(_ source: LibrarySource) {
        librarySource = source
        if source == .remote && !isConnected && autoConnect {
            startAutoConnect()
        }
    }
    
    // MARK: - Lightweight Health Check (/api/ping)
    func markConnected(url: String? = nil) {
        DispatchQueue.main.async {
            self.isConnected = true
            self.statusMessage = "Connected"
            self.stopAutoConnect()
            self.updateConnectionTimerState()
            if let u = url, let normalized = Self.normalizeServerURL(u) {
                if self.serverURL.isEmpty {
                    self.serverURL = normalized
                    self.saveSettings()
                }
                self.addSavedServer(normalized)
                UserDefaults.standard.set(normalized, forKey: self.kLastConnectedServerKey)
                UserDefaults.standard.set(normalized, forKey: self.kServerURLKey)
            }
            self.fetchRemoteStatus(targetURL: url)
        }
    }
    
    func checkConnection(targetURL: String? = nil, completion: ((Bool) -> Void)? = nil) {
        let rawURL = (targetURL != nil && !targetURL!.isEmpty) ? targetURL! : serverURL
        guard let normalized = Self.normalizeServerURL(rawURL), let baseURL = URL(string: normalized) else {
            DispatchQueue.main.async {
                self.isConnected = false
                self.remoteStatus = nil
                self.statusMessage = "Disconnected"
                completion?(false)
            }
            return
        }
        
        let pingURL = baseURL.appendingPathComponent("/api/ping")
        var request = URLRequest(url: pingURL)
        request.timeoutInterval = 3.0
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else {
                    completion?(false)
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200, error == nil {
                    var isValid = false
                    if let serverHeader = httpResponse.value(forHTTPHeaderField: "Server"), serverHeader.contains("AudioStreamer") {
                        isValid = true
                    } else if let data = data,
                              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                              (json["status"] as? String) == "ok" {
                        isValid = true
                    }
                    
                    if isValid {
                        let wasConnected = self.isConnected
                        self.isConnected = true
                        self.statusMessage = "Connected"
                        self.serverURL = normalized
                        self.addSavedServer(normalized)
                        UserDefaults.standard.set(normalized, forKey: self.kLastConnectedServerKey)
                        UserDefaults.standard.set(normalized, forKey: self.kServerURLKey)
                        self.updateConnectionTimerState()
                        if !wasConnected || self.remoteStatus == nil {
                            self.fetchRemoteStatus(targetURL: normalized)
                        }
                        completion?(true)
                        return
                    }
                }
                
                self.isConnected = false
                if !self.isAutoConnecting {
                    self.statusMessage = "Disconnected"
                }
                completion?(false)
            }
        }.resume()
    }

    func fetchRemoteStatus(targetURL: String? = nil) {
        guard librarySource == .remote else {
            DispatchQueue.main.async { self.remoteStatus = nil }
            return
        }
        let rawURL = (targetURL != nil && !targetURL!.isEmpty) ? targetURL! : serverURL
        guard let normalized = Self.normalizeServerURL(rawURL),
              let statusURL = URL(string: normalized)?.appendingPathComponent("/api/status") else {
            return
        }

        DispatchQueue.main.async {
            self.isFetchingStatus = true
        }

        var request = URLRequest(url: statusURL)
        request.timeoutInterval = 3.0
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isFetchingStatus = false
                guard error == nil,
                      let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200,
                      let data = data,
                      let decoded = try? JSONDecoder().decode(RemoteServerStatus.self, from: data) else {
                    return
                }
                self.remoteStatus = decoded
            }
        }.resume()
    }
    
    // MARK: - Remote Wake Trigger (RemoteCompanion :8080 / :8081)
    var isUsingIPhoneServer: Bool {
        isIPhoneServerURL(serverURL)
    }

    func wakeRemoteServer(targetHost: String? = nil, completion: ((Bool) -> Void)? = nil) {
        // The NAS is a normal HTTP server and does not need a wake signal. Only
        // wake an iPhone server, and only when the app is explicitly pointed at
        // one. This prevents a NAS timeout from starting the iPhone daemon
        // through RemoteCompanion.
        guard isIPhoneServerURL(serverURL) else {
            completion?(false)
            return
        }

        var hostsToTry: [String] = []
        if let targetHost = targetHost, !targetHost.isEmpty, isIPhoneHost(targetHost), !hostsToTry.contains(targetHost) {
            hostsToTry.append(targetHost)
        }
        if let url = URL(string: serverURL), let h = url.host, h != "localhost" && h != "127.0.0.1", !hostsToTry.contains(h) {
            hostsToTry.append(h)
        }
        if let lastUrl = UserDefaults.standard.string(forKey: kLastConnectedServerKey),
           isIPhoneServerURL(lastUrl),
           let url = URL(string: lastUrl), let h = url.host, h != "localhost" && h != "127.0.0.1", !hostsToTry.contains(h) {
            hostsToTry.append(h)
        }
        if !hostsToTry.contains("iphone.local") {
            hostsToTry.append("iphone.local")
        }
        
        let ports: [UInt16] = [8080, 8081]
        let group = DispatchGroup()
        var anyAccepted = false
        
        for host in hostsToTry {
            for p in ports {
                guard let wakeURL = URL(string: "http://\(host):\(p)/api/audiostream/start") else { continue }
                group.enter()
                var request = URLRequest(url: wakeURL)
                request.httpMethod = "POST"
                request.httpBody = Data()
                request.setValue("0", forHTTPHeaderField: "Content-Length")
                request.timeoutInterval = 2.0
                
                URLSession.shared.dataTask(with: request) { data, response, error in
                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                        print("RemoteCompanion wake signal accepted on \(host):\(p)")
                        anyAccepted = true
                    }
                    group.leave()
                }.resume()
            }
        }
        
        group.notify(queue: .main) {
            completion?(anyAccepted)
        }
    }
    
    // MARK: - Deterministic Wake & Stepped Polling Pipeline
    func retryConnection() {
        startAutoConnect()
    }
    
    func startAutoConnect(targetURL: String? = nil) {
        stopAutoConnect()
        
        let candidates = resolveCandidateURLs(preferredURL: targetURL)
        guard let primaryURL = candidates.first else {
            print("No valid server candidates found to connect.")
            statusMessage = "Disconnected"
            return
        }
        
        isAutoConnecting = true
        statusMessage = "Waking server..."
        
        // Quick probe: is server already running and alive?
        checkConnection(targetURL: primaryURL) { [weak self] isAlive in
            guard let self = self else { return }
            if isAlive {
                self.isAutoConnecting = false
                self.statusMessage = "Connected"
                return
            }
            
            // Server not alive: send wake POST to RemoteCompanion
            let targetHost = URL(string: primaryURL)?.host
            self.wakeRemoteServer(targetHost: targetHost) { [weak self] _ in
                guard let self = self else { return }
                self.statusMessage = "Connecting..."
                self.startSteppedProbe(candidates: candidates, candidateIndex: 0)
            }
        }
    }
    
    private func startSteppedProbe(candidates: [String], candidateIndex: Int) {
        guard candidateIndex < candidates.count else {
            // All candidates exhausted
            stopAutoConnect()
            self.isConnected = false
            self.statusMessage = "Disconnected"
            print("All server candidates failed to respond.")
            return
        }
        
        let currentURL = candidates[candidateIndex]
        self.probeAttempt = 0
        self.runProbeAttempt(currentURL: currentURL, candidates: candidates, candidateIndex: candidateIndex, delay: 0.5)
    }
    
    private func runProbeAttempt(currentURL: String, candidates: [String], candidateIndex: Int, delay: TimeInterval) {
        probeTimer?.invalidate()
        probeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            guard self.isAutoConnecting else { return }
            
            self.probeAttempt += 1
            print("Probing \(currentURL) (attempt \(self.probeAttempt)/\(self.maxProbeAttempts))...")
            
            self.checkConnection(targetURL: currentURL) { [weak self] success in
                guard let self = self else { return }
                guard self.isAutoConnecting else { return }
                
                if success {
                    self.stopAutoConnect()
                    self.isConnected = true
                    self.statusMessage = "Connected"
                    self.serverURL = currentURL
                    self.saveSettings()
                    print("Successfully connected to \(currentURL) on probe \(self.probeAttempt)!")
                    return
                }
                
                if self.probeAttempt < self.maxProbeAttempts {
                    // Probe every 1.0s
                    self.runProbeAttempt(currentURL: currentURL, candidates: candidates, candidateIndex: candidateIndex, delay: 1.0)
                } else {
                    // Try next candidate host
                    print("Candidate \(currentURL) timed out. Trying next candidate...")
                    self.startSteppedProbe(candidates: candidates, candidateIndex: candidateIndex + 1)
                }
            }
        }
    }
    
    func stopAutoConnect() {
        probeTimer?.invalidate()
        probeTimer = nil
        isAutoConnecting = false
    }
    
    private func isIPhoneHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "iphone.local" || normalized == "localhost" || normalized == "127.0.0.1"
    }

    private func isIPhoneServerURL(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host else { return false }
        return isIPhoneHost(host)
    }

    private func isAllowedServerCandidate(_ urlString: String) -> Bool {
        // When the app is configured for a non-iPhone server (the NAS), never
        // silently fall back to the iPhone.
        if serverURL.isEmpty || isIPhoneServerURL(serverURL) {
            return true
        }
        return !isIPhoneServerURL(urlString)
    }

    private func resolveCandidateURLs(preferredURL: String? = nil) -> [String] {
        var candidates: [String] = []
        
        if let explicit = preferredURL, !explicit.isEmpty {
            candidates.append(explicit)
        }
        
        if !serverURL.isEmpty && !candidates.contains(serverURL) {
            candidates.append(serverURL)
        }
        
        for discovered in discoveredServers {
            if !candidates.contains(discovered) && isAllowedServerCandidate(discovered) {
                candidates.append(discovered)
            }
        }
        
        if let lastUrl = UserDefaults.standard.string(forKey: kLastConnectedServerKey),
           !lastUrl.isEmpty && !candidates.contains(lastUrl) && isAllowedServerCandidate(lastUrl) {
            candidates.append(lastUrl)
        }
        
        // Only fall back to the iPhone when the app is configured for the
        // iPhone (or has no server configured yet). A NAS setup must never
        // silently connect to the phone.
        let iphoneLocalURL = "http://iphone.local:18080"
        if (serverURL.isEmpty || isIPhoneServerURL(serverURL)) && !candidates.contains(iphoneLocalURL) {
            candidates.append(iphoneLocalURL)
        }
        
        return candidates
    }
    
    // MARK: - Subnet Auto-Discovery (Manual Trigger Only)
    func startAutoDiscovery() {
        guard !isSearching else { return }
        isSearching = true
        discoveredServers.removeAll()
        
        let localIP = getIPAddress()
        guard localIP != "localhost" && localIP != "127.0.0.1" else {
            checkDiscovery(urlStr: "http://localhost:18080") { [weak self] success in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isSearching = false
                    if success {
                        self.discoveredServers = ["http://localhost:18080"]
                        if self.librarySource == .remote && !self.isConnected && self.autoConnect && self.serverURL.isEmpty {
                            self.connect(url: "http://localhost:18080")
                        }
                    }
                }
            }
            return
        }
        
        let components = localIP.split(separator: ".")
        guard components.count == 4 else {
            isSearching = false
            return
        }
        
        let subnet = components[0...2].joined(separator: ".") + "."
        let batchSize = 32
        var currentHostIndex = 1
        
        func scanNextBatch() {
            if currentHostIndex > 254 {
                self.isSearching = false
                if self.librarySource == .remote && !self.isConnected && !self.discoveredServers.isEmpty {
                    if self.discoveredServers.contains(self.serverURL) {
                        self.markConnected(url: self.serverURL)
                    } else if self.serverURL.isEmpty && self.autoConnect {
                        self.connect(url: self.discoveredServers[0])
                    }
                }
                return
            }
            
            let batchGroup = DispatchGroup()
            let end = min(currentHostIndex + batchSize - 1, 254)
            
            for i in currentHostIndex...end {
                let host = "\(subnet)\(i)"
                if host == localIP { continue }
                
                let urlStr = "http://\(host):18080"
                batchGroup.enter()
                self.checkDiscovery(urlStr: urlStr) { success in
                    if success {
                        DispatchQueue.main.async {
                            if !self.discoveredServers.contains(urlStr) {
                                self.discoveredServers.append(urlStr)
                            }
                            if self.librarySource == .remote && !self.isConnected {
                                if self.serverURL == urlStr {
                                    self.markConnected(url: urlStr)
                                } else if self.serverURL.isEmpty && self.autoConnect {
                                    self.connect(url: urlStr)
                                }
                            }
                        }
                    }
                    batchGroup.leave()
                }
            }
            
            currentHostIndex += batchSize
            batchGroup.notify(queue: .main) {
                scanNextBatch()
            }
        }
        
        scanNextBatch()
    }
    
    private func checkDiscovery(urlStr: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: urlStr)?.appendingPathComponent("/api/ping") else {
            completion(false)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200, error == nil {
                var isValid = false
                if let serverHeader = httpResponse.value(forHTTPHeaderField: "Server"), serverHeader.contains("AudioStreamer") {
                    isValid = true
                } else if let data = data,
                          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          (json["status"] as? String) == "ok" {
                    isValid = true
                }
                completion(isValid)
            } else {
                completion(false)
            }
        }.resume()
    }
    
    private func getIPAddress() -> String {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { continue }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    let ip = String(cString: hostname)
                    if name == "en0" {
                        address = ip
                        break
                    } else if name != "lo0" && address == nil {
                        address = ip
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address ?? "localhost"
    }
    
    // MARK: - Persistence & App Lifecycle
    private func saveSettings() {
        guard !isUpdatingSettings else { return }
        UserDefaults.standard.set(serverURL, forKey: kServerURLKey)
        UserDefaults.standard.set(librarySource.rawValue, forKey: kLibrarySourceKey)
        UserDefaults.standard.set(autoConnect, forKey: kAutoConnectKey)
        UserDefaults.standard.set(batterySaverMode, forKey: kBatterySaverModeKey)
        UserDefaults.standard.set(savedServers, forKey: kSavedServersKey)
    }
    
    private func loadSettings() {
        isUpdatingSettings = true
        defer { isUpdatingSettings = false }
        
        if UserDefaults.standard.object(forKey: kAutoConnectKey) != nil {
            self.autoConnect = UserDefaults.standard.bool(forKey: kAutoConnectKey)
        } else {
            self.autoConnect = true
        }

        if UserDefaults.standard.object(forKey: kBatterySaverModeKey) != nil {
            self.batterySaverMode = UserDefaults.standard.bool(forKey: kBatterySaverModeKey)
        } else {
            self.batterySaverMode = true
        }
        
        if let savedSource = UserDefaults.standard.string(forKey: kLibrarySourceKey),
           let source = LibrarySource(rawValue: savedSource) {
            self.librarySource = source
        } else {
            self.librarySource = .remote
        }

        var loadedSaved = UserDefaults.standard.stringArray(forKey: kSavedServersKey) ?? []
        if let savedURL = UserDefaults.standard.string(forKey: kServerURLKey) {
            let normalized = Self.normalizeServerURL(savedURL) ?? savedURL
            self.serverURL = normalized
            if !normalized.isEmpty && !loadedSaved.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
                loadedSaved.insert(normalized, at: 0)
            }
        } else {
            self.serverURL = ""
        }
        if let lastURL = UserDefaults.standard.string(forKey: kLastConnectedServerKey),
           let normalizedLast = Self.normalizeServerURL(lastURL),
           !loadedSaved.contains(where: { $0.caseInsensitiveCompare(normalizedLast) == .orderedSame }) {
            loadedSaved.append(normalizedLast)
        }
        self.savedServers = loadedSaved
        
        if monitorsLifecycle {
            triggerInitialConnection()
        }
    }

    func reloadFromDefaultsAfterRestore() {
        stopAutoConnect()
        loadSettings()
        if librarySource == .local {
            stopConnectionTimer()
            isConnected = false
            remoteStatus = nil
            statusMessage = "Using Local Library"
        } else {
            isConnected = false
            remoteStatus = nil
            updateConnectionTimerState()
            if autoConnect && !serverURL.isEmpty {
                startAutoConnect()
            }
        }
    }
    
    private func triggerInitialConnection() {
        guard monitorsLifecycle else { return }
        if librarySource == .remote {
            if autoConnect {
                startAutoConnect()
            } else {
                statusMessage = serverURL.isEmpty ? "Not configured" : "Auto-connect off"
            }
        } else {
            statusMessage = "Using Local Library"
        }
    }
    
    func handleAppActive() {
        guard monitorsLifecycle else { return }
        if librarySource == .remote {
            if !isConnected && !isAutoConnecting {
                if autoConnect {
                    startAutoConnect()
                }
            } else if isConnected {
                // Quiet background verification
                checkConnection { [weak self] alive in
                    guard let self = self else { return }
                    if !alive && self.autoConnect {
                        self.startAutoConnect()
                    }
                }
            }
            updateConnectionTimerState()
        } else {
            stopConnectionTimer()
        }
    }
}

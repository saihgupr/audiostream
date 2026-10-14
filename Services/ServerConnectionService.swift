import Foundation
import Combine
import UIKit

class ServerConnectionService: ObservableObject {
    @Published var serverURL: String = ""
    @Published var isConnected: Bool = false
    @Published var isSearching: Bool = false
    @Published var discoveredServers: [String] = []
    @Published var librarySource: LibrarySource = .remote {
        didSet {
            saveSettings()
        }
    }
    @Published var autoConnect: Bool = true {
        didSet {
            saveSettings()
        }
    }
    @Published var isAutoConnecting: Bool = false
    @Published var statusMessage: String = "Disconnected"
    
    private var isUpdatingSettings = false
    
    private let kServerURLKey = "RC_ServerURL"
    private let kLibrarySourceKey = "RC_LibrarySource"
    private let kAutoConnectKey = "RC_AutoConnect"
    private let kLastConnectedServerKey = "RC_LastConnectedServer"
    
    private var connectionTimer: Timer?
    private var probeTimer: Timer?
    private var probeAttempt = 0
    private let maxProbeAttempts = 18
    
    init() {
        loadSettings()
        startConnectionTimer()
        setupLifecycleObservers()
    }
    
    private var isBatterySaverEnabled: Bool {
        if UserDefaults.standard.object(forKey: "RC_BatterySaverMode") == nil {
            return true // Default enabled
        }
        return UserDefaults.standard.bool(forKey: "RC_BatterySaverMode")
    }
    
    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if self.isBatterySaverEnabled {
                self.stopConnectionTimer()
                self.stopAutoConnect()
            }
        }
        
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if self.librarySource == .remote && !self.serverURL.isEmpty && !self.isAutoConnecting {
                self.checkConnection()
            }
            self.startConnectionTimer()
        }
    }
    
    private func startConnectionTimer() {
        guard connectionTimer == nil else { return }
        // Periodic lightweight check (every 25s) to verify connection without spamming host
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.librarySource == .remote && !self.serverURL.isEmpty && !self.isAutoConnecting {
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
    }
    
    func connect(url: String) {
        stopAutoConnect()
        
        guard let _ = URL(string: url) else {
            print("Invalid URL: \(url)")
            return
        }
        
        self.serverURL = url
        saveSettings()
        
        // Start deterministic connect flow targeting this URL
        startAutoConnect(targetURL: url)
    }
    
    func setLibrarySource(_ source: LibrarySource) {
        librarySource = source
        if source == .remote && !isConnected {
            startAutoConnect()
        }
    }
    
    // MARK: - Lightweight Health Check (/api/ping)
    func markConnected(url: String? = nil) {
        DispatchQueue.main.async {
            self.isConnected = true
            self.statusMessage = "Connected"
            self.stopAutoConnect()
            if let u = url, !u.isEmpty {
                if self.serverURL.isEmpty {
                    self.serverURL = u
                    self.saveSettings()
                }
                UserDefaults.standard.set(u, forKey: self.kLastConnectedServerKey)
                UserDefaults.standard.set(u, forKey: self.kServerURLKey)
            }
        }
    }
    
    func checkConnection(targetURL: String? = nil, completion: ((Bool) -> Void)? = nil) {
        let rawURL = (targetURL != nil && !targetURL!.isEmpty) ? targetURL! : serverURL
        guard let baseURL = URL(string: rawURL) else {
            DispatchQueue.main.async {
                self.isConnected = false
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
                        self.isConnected = true
                        self.statusMessage = "Connected"
                        if !rawURL.isEmpty {
                            self.serverURL = rawURL
                            UserDefaults.standard.set(rawURL, forKey: self.kLastConnectedServerKey)
                            UserDefaults.standard.set(rawURL, forKey: self.kServerURLKey)
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
    
    // MARK: - Remote Wake Trigger (RemoteCompanion :8080 / :8081)
    func wakeRemoteServer(targetHost: String? = nil, completion: ((Bool) -> Void)? = nil) {
        var hostsToTry: [String] = []
        if let targetHost = targetHost, !targetHost.isEmpty {
            hostsToTry.append(targetHost)
        }
        if let url = URL(string: serverURL), let h = url.host, h != "localhost" && h != "127.0.0.1", !hostsToTry.contains(h) {
            hostsToTry.append(h)
        }
        if let lastUrl = UserDefaults.standard.string(forKey: kLastConnectedServerKey),
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
    
    private func resolveCandidateURLs(preferredURL: String? = nil) -> [String] {
        var candidates: [String] = []
        
        if let explicit = preferredURL, !explicit.isEmpty {
            candidates.append(explicit)
        }
        
        if !serverURL.isEmpty && !candidates.contains(serverURL) {
            candidates.append(serverURL)
        }
        
        for discovered in discoveredServers {
            if !candidates.contains(discovered) {
                candidates.append(discovered)
            }
        }
        
        if let lastUrl = UserDefaults.standard.string(forKey: kLastConnectedServerKey),
           !lastUrl.isEmpty && !candidates.contains(lastUrl) {
            candidates.append(lastUrl)
        }
        
        let iphoneLocalURL = "http://iphone.local:18080"
        if !candidates.contains(iphoneLocalURL) {
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
                    self?.isSearching = false
                    if success {
                        self?.discoveredServers = ["http://localhost:18080"]
                        if self?.isConnected == false {
                            self?.connect(url: "http://localhost:18080")
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
                if !self.isConnected && !self.discoveredServers.isEmpty {
                    if self.discoveredServers.contains(self.serverURL) {
                        self.markConnected(url: self.serverURL)
                    } else if self.serverURL.isEmpty {
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
                            if !self.isConnected {
                                if self.serverURL == urlStr {
                                    self.markConnected(url: urlStr)
                                } else if self.serverURL.isEmpty {
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
    }
    
    private func loadSettings() {
        isUpdatingSettings = true
        defer { isUpdatingSettings = false }
        
        if UserDefaults.standard.object(forKey: kAutoConnectKey) != nil {
            self.autoConnect = UserDefaults.standard.bool(forKey: kAutoConnectKey)
        } else {
            self.autoConnect = true
        }
        
        if let savedSource = UserDefaults.standard.string(forKey: kLibrarySourceKey),
           let source = LibrarySource(rawValue: savedSource) {
            self.librarySource = source
        }
        
        if let savedURL = UserDefaults.standard.string(forKey: kServerURLKey) {
            self.serverURL = savedURL
        }
        
        triggerInitialConnection()
    }
    
    private func triggerInitialConnection() {
        if librarySource == .remote {
            startAutoConnect()
        }
    }
    
    func handleAppActive() {
        if librarySource == .remote {
            if !isConnected && !isAutoConnecting {
                startAutoConnect()
            } else if isConnected {
                // Quiet background verification
                checkConnection { [weak self] alive in
                    if !alive {
                        self?.startAutoConnect()
                    }
                }
            }
        }
    }
}

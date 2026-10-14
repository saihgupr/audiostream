import Foundation
import Network
import SQLite3
import MediaPlayer
import AVFoundation
import UIKit

struct ServerSong: Codable, Identifiable {
    let id: Int64
    let persistentId: UInt64
    let title: String
    let artist: String
    let album: String
    let filename: String
    let duration: TimeInterval
    
    var durationFormatted: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

class MusicServerManager: ObservableObject {
    static let shared = MusicServerManager()
    
    @Published var isRunning = false
    @Published var serverStatus = "Stopped"
    @Published var serverAddress: String?
    @Published var songCount = 0
    @Published var songs: [ServerSong] = []
    @Published var playlists: [Playlist] = []
    @Published var errorMessage: String?
    @Published var autoOffEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(autoOffEnabled, forKey: "RC_AutoOffEnabled")
            // Sync to shared files so the CLI script knows the setting
            let flagPath = "/tmp/audiostream_autooff.enabled"
            let timeoutPath = "/tmp/audiostream_autooff.timeout"
            try? (autoOffEnabled ? "1" : "0").write(toFile: flagPath, atomically: true, encoding: .utf8)
            try? "\(autoOffInterval)".write(toFile: timeoutPath, atomically: true, encoding: .utf8)
        }
    }
    
    private let port: UInt16 = 18080
    private let dbPath = "/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
    private let logPath = "/tmp/audiostreamer.log"
    private let monitorScriptPath = "/tmp/autooff_monitor.sh"
    private let monitorPidPath = "/tmp/autooff_monitor.pid"
    private let autoOffInterval: Int = 600 // 10 minutes for production
    
    private var statusTimer: Timer?
    private var startupRetries = 0
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 3
    private var isCheckingStatus = false
    
    private init() {
        signal(SIGCHLD, SIG_IGN) // Automatically reap terminated child processes (prevents zombies)
        self.autoOffEnabled = UserDefaults.standard.bool(forKey: "RC_AutoOffEnabled")
        
        // Sync initial state to shared files
        let flagPath = "/tmp/audiostream_autooff.enabled"
        let timeoutPath = "/tmp/audiostream_autooff.timeout"
        try? (self.autoOffEnabled ? "1" : "0").write(toFile: flagPath, atomically: true, encoding: .utf8)
        try? "\(autoOffInterval)".write(toFile: timeoutPath, atomically: true, encoding: .utf8)
        
        let userWantsRunning = UserDefaults.standard.bool(forKey: "RC_UserWantsServerRunning")
        if userWantsRunning {
            self.isRunning = true
            self.serverStatus = "Starting..."
        }
        
        checkServerStatus()
        startStatusTimer()
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
                self.stopStatusTimer()
            }
        }
        
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.checkServerStatus()
            self.startStatusTimer()
        }
    }
    
    private func startStatusTimer() {
        guard statusTimer == nil else { return }
        // Poll server status every 3 seconds (UI refresh only — NOT for idle detection)
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Do not compete with startup retry loop
            if self.serverStatus == "Starting..." { return }
            self.checkServerStatus()
        }
    }
    
    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }
    
    func isDaemonProcessActive() -> Bool {
        var pid: pid_t = 0
        let shPath = FileManager.default.fileExists(atPath: "/var/jb/bin/sh") ? "/var/jb/bin/sh" : "/bin/sh"
        let command = "ps aux 2>/dev/null | grep -i '[a]udiostreamerd' | grep -v ' Z ' >/dev/null"
        var cArgs: [UnsafeMutablePointer<CChar>?] = [strdup(shPath), strdup("-c"), strdup(command), nil]
        var envArgs = createEnvArgs()
        let status = posix_spawn(&pid, shPath, nil, nil, &cArgs, &envArgs)
        for arg in cArgs { if let arg = arg { free(arg) } }
        freeEnvArgs(envArgs)
        
        if status == 0 {
            var exitStatus: Int32 = 0
            waitpid(pid, &exitStatus, 0)
            return ((exitStatus >> 8) & 0xFF) == 0 && (exitStatus & 0x7F) == 0
        }
        return false
    }

    func checkServerStatus() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isCheckingStatus { return }
            self.isCheckingStatus = true
            self.performStatusCheck()
        }
    }
    
    private func performStatusCheck() {
        guard let url = URL(string: "http://127.0.0.1:\(self.port)/api/ping") else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isCheckingStatus = false
                self.isRunning = false
                self.serverStatus = "Stopped"
                self.serverAddress = nil
            }
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 4.0
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                defer { self.isCheckingStatus = false }
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200, error == nil {
                    UserDefaults.standard.set(true, forKey: "RC_UserWantsServerRunning")
                    self.consecutiveFailures = 0
                    self.startupRetries = 0
                    self.isRunning = true
                    self.serverStatus = "Running"
                    self.serverAddress = "http://\(self.getIPAddress()):\(self.port)"
                    self.errorMessage = nil
                    
                    if let data = data,
                       let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                       let count = json["songsCount"] as? Int {
                        self.songCount = count
                    }
                } else {
                    // Probe failed or timed out
                    
                    // Case 1: In Starting... phase
                    if self.serverStatus == "Starting..." {
                        if self.startupRetries < 15 {
                            self.startupRetries += 1
                            serverLog("Server check retry \(self.startupRetries)/15...")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                                self?.performStatusCheck()
                            }
                            return
                        }
                        
                        // Startup retries exceeded 15 seconds. Fallback check if daemon process is active before giving up.
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            guard let self = self else { return }
                            let daemonActive = self.isDaemonProcessActive()
                            DispatchQueue.main.async {
                                if daemonActive {
                                    serverLog("Daemon process is active after 15s startup grace window. Maintaining running state.")
                                    self.startupRetries = 0
                                    self.consecutiveFailures = 0
                                    self.isRunning = true
                                    self.serverStatus = "Running"
                                    self.serverAddress = "http://\(self.getIPAddress()):\(self.port)"
                                    self.errorMessage = nil
                                } else {
                                    serverLog("Daemon failed to start and process is not running after 15 retries.")
                                    self.errorMessage = "Could not connect to the streaming server on port \(self.port)."
                                    UserDefaults.standard.set(false, forKey: "RC_UserWantsServerRunning")
                                    self.startupRetries = 0
                                    self.consecutiveFailures = 0
                                    self.isRunning = false
                                    self.serverStatus = "Stopped"
                                    self.serverAddress = nil
                                }
                            }
                        }
                        return
                    }
                    
                    // Case 2: Server was Running or user wants it running
                    let userWantsRunning = UserDefaults.standard.bool(forKey: "RC_UserWantsServerRunning")
                    if self.isRunning || userWantsRunning {
                        self.consecutiveFailures += 1
                        serverLog("Server probe failure (\(self.consecutiveFailures)/\(self.maxConsecutiveFailures)).")
                        
                        if self.consecutiveFailures < self.maxConsecutiveFailures {
                            // Retain running state within hysteresis window
                            return
                        }
                        
                        // Reached consecutive failure threshold: verify process liveness via isDaemonProcessActive
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            guard let self = self else { return }
                            let daemonActive = self.isDaemonProcessActive()
                            DispatchQueue.main.async {
                                if daemonActive {
                                    serverLog("Probe failed \(self.maxConsecutiveFailures) times, but daemon PID is active. Retaining running state (Busy).")
                                    self.isRunning = true
                                    self.serverStatus = "Busy"
                                    UserDefaults.standard.set(true, forKey: "RC_UserWantsServerRunning")
                                } else {
                                    serverLog("Probe failed \(self.maxConsecutiveFailures) times and daemon process is dead. Transitioning to Stopped.")
                                    UserDefaults.standard.set(false, forKey: "RC_UserWantsServerRunning")
                                    self.consecutiveFailures = 0
                                    self.startupRetries = 0
                                    self.isRunning = false
                                    self.serverStatus = "Stopped"
                                    self.serverAddress = nil
                                }
                            }
                        }
                        return
                    }
                    
                    // Case 3: Already Stopped and user does not want server running
                    self.consecutiveFailures = 0
                    self.startupRetries = 0
                    self.isRunning = false
                    self.serverStatus = "Stopped"
                    self.serverAddress = nil
                }
            }
        }.resume()
    }
    
    func startServer() {
        serverLog("Starting server...")
        
        // Persist user intent so checkServerStatus() and init() know the server should be running
        UserDefaults.standard.set(true, forKey: "RC_UserWantsServerRunning")
        
        self.startupRetries = 0
        self.consecutiveFailures = 0
        self.isRunning = true
        self.serverStatus = "Starting..."
        self.errorMessage = nil
        
        // Immediately perform health check to see if server is already active
        guard let checkURL = URL(string: "http://127.0.0.1:\(port)/api/ping") else { return }
        var request = URLRequest(url: checkURL)
        request.timeoutInterval = 1.0
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let httpResponse = response as? HTTPURLResponse, error == nil,
                   let serverHeader = httpResponse.value(forHTTPHeaderField: "Server"),
                   serverHeader == "AudioStreamer" {
                    serverLog("Server is already active and healthy — keeping active state.")
                    self.startupRetries = 0
                    self.consecutiveFailures = 0
                    self.isRunning = true
                    self.serverStatus = "Running"
                    self.serverAddress = "http://\(self.getIPAddress()):\(self.port)"
                    if let data = data,
                       let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                       let count = json["songsCount"] as? Int {
                        self.songCount = count
                    }
                    self.loadSongs()
                    return
                }
                
                self.performDaemonSpawn()
            }
        }.resume()
    }
    
    private func createEnvArgs() -> [UnsafeMutablePointer<CChar>?] {
        let envVars = [
            "PATH=/var/jb/usr/bin:/var/jb/usr/local/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR=/tmp",
            "HOME=/var/mobile",
            "SHELL=/bin/sh"
        ]
        return envVars.map { strdup($0) } + [nil]
    }
    
    private func freeEnvArgs(_ envArgs: [UnsafeMutablePointer<CChar>?]) {
        for arg in envArgs {
            if let arg = arg { free(arg) }
        }
    }

    private func performDaemonSpawn() {
        let audiostreamCmd = FileManager.default.fileExists(atPath: "/var/jb/usr/bin/audiostream")
            ? "/var/jb/usr/bin/audiostream"
            : (FileManager.default.fileExists(atPath: "/usr/bin/audiostream") ? "/usr/bin/audiostream" : nil)
        let shPath = FileManager.default.fileExists(atPath: "/var/jb/bin/sh")
            ? "/var/jb/bin/sh"
            : "/bin/sh"
        
        let autoOffArg = autoOffEnabled ? " --auto-off" : ""
        let command: String
        if let cmd = audiostreamCmd {
            command = "\(cmd) start\(autoOffArg)"
        } else {
            let daemonPath = FileManager.default.fileExists(atPath: "/var/jb/usr/libexec/audiostreamerd")
                ? "/var/jb/usr/libexec/audiostreamerd"
                : "/usr/libexec/audiostreamerd"
            command = "\(daemonPath) >> \(logPath) 2>&1 &"
        }
        
        serverLog("Executing daemon start command: \(command)")
        
        var daemonPid: pid_t = 0
        var daemonArgs: [UnsafeMutablePointer<CChar>?] = [strdup(shPath), strdup("-c"), strdup(command), nil]
        var envArgs = createEnvArgs()
        
        var spawnAttrs: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttrs)
        posix_spawnattr_setflags(&spawnAttrs, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&spawnAttrs, 0)
        
        let result = posix_spawn(&daemonPid, shPath, nil, &spawnAttrs, &daemonArgs, &envArgs)
        serverLog("posix_spawn audiostream result: \(result), pid: \(daemonPid)")
        
        posix_spawnattr_destroy(&spawnAttrs)
        for arg in daemonArgs { if let arg = arg { free(arg) } }
        freeEnvArgs(envArgs)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.checkServerStatus()
        }
    }
    
    /// Writes and launches a standalone shell script that monitors activity in the log
    /// and kills audiostreamerd after `autoOffInterval` seconds of idle.
    /// The script runs in its own process group — completely independent of the app.
    private func startMonitor(daemonPid: pid_t, shPath: String) {
        let timeout = autoOffInterval
        
        let script = """
#!/bin/sh
LOG="\(logPath)"
TIMEOUT=\(timeout)
DAEMON_PID=\(daemonPid)
LAST_COUNT=0
LAST_ACTIVITY=$(date +%s)

while true; do
    sleep 15

    # Stop monitor if daemon is already gone
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
        exit 0
    fi

    # Count real remote activity (artwork, music stream requests) — excludes healthchecks
    CURR=$(grep -v -e '/api/songs' -e 'New connection received' "$LOG" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$CURR" -gt "$LAST_COUNT" ]; then
        LAST_COUNT=$CURR
        LAST_ACTIVITY=$(date +%s)
    fi

    AGE=$(( $(date +%s) - LAST_ACTIVITY ))
    if [ "$AGE" -ge "$TIMEOUT" ]; then
        echo "[$(date)] Auto-off monitor: idle ${AGE}s >= ${TIMEOUT}s, killing daemon PID $DAEMON_PID" >> "$LOG"
        kill -9 "$DAEMON_PID" 2>/dev/null
        exit 0
    fi
done
"""
        
        do {
            try script.write(toFile: monitorScriptPath, atomically: true, encoding: .utf8)
        } catch {
            serverLog("Failed to write monitor script: \(error)")
            return
        }
        
        // chmod +x then launch it in its own process group
        var monitorPid: pid_t = 0
        let command = "chmod +x \(monitorScriptPath) && exec \(monitorScriptPath)"
        var monitorArgs: [UnsafeMutablePointer<CChar>?] = [strdup(shPath), strdup("-c"), strdup(command), nil]
        var envArgs = createEnvArgs()
        
        var spawnAttrs: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttrs)
        // Detach into its own process group — survives app backgrounding/suspension
        posix_spawnattr_setflags(&spawnAttrs, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&spawnAttrs, 0)
        
        let monitorResult = posix_spawn(&monitorPid, shPath, nil, &spawnAttrs, &monitorArgs, &envArgs)
        posix_spawnattr_destroy(&spawnAttrs)
        for arg in monitorArgs { if let arg = arg { free(arg) } }
        freeEnvArgs(envArgs)
        
        if monitorResult == 0 {
            // Save monitor PID so we can kill it on stopServer()
            try? "\(monitorPid)".write(toFile: monitorPidPath, atomically: true, encoding: .utf8)
            serverLog("Auto-off monitor started: pid=\(monitorPid), timeout=\(timeout)s, watching daemon pid=\(daemonPid)")
        } else {
            serverLog("Failed to start monitor: error \(monitorResult)")
        }
    }
    
    /// Kill the running monitor process if one exists.
    private func killMonitor() {
        guard let pidStr = try? String(contentsOfFile: monitorPidPath, encoding: .utf8),
              let monitorPid = pid_t(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        kill(monitorPid, SIGKILL)
        try? FileManager.default.removeItem(atPath: monitorPidPath)
        serverLog("Killed existing monitor pid=\(monitorPid)")
    }
    
    private func killExistingDaemonProcesses() {
        var pid: pid_t = 0
        let path = FileManager.default.fileExists(atPath: "/var/jb/bin/sh") ? "/var/jb/bin/sh" : "/bin/sh"
        let command = "for p in $(ps aux 2>/dev/null | grep '[a]udiostreamerd' | awk '{print $2}'); do kill -9 $p 2>/dev/null; done"
        var cArgs: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup("-c"), strdup(command), nil]
        var envArgs = createEnvArgs()
        let result = posix_spawn(&pid, path, nil, nil, &cArgs, &envArgs)
        serverLog("killExistingDaemonProcesses result: \(result), pid: \(pid)")
        for arg in cArgs { if let arg = arg { free(arg) } }
        freeEnvArgs(envArgs)
    }
    
    func stopServer() {
        serverLog("Stopping server...")
        
        UserDefaults.standard.set(false, forKey: "RC_UserWantsServerRunning")
        
        self.consecutiveFailures = 0
        self.startupRetries = 0
        self.isRunning = false
        self.serverStatus = "Stopped"
        self.serverAddress = nil
        self.errorMessage = nil
        
        // Kill the monitor first so it doesn't race with our kill
        killMonitor()
        
        // Execute audiostream stop if available, or killall -9
        let audiostreamCmd = FileManager.default.fileExists(atPath: "/var/jb/usr/bin/audiostream")
            ? "/var/jb/usr/bin/audiostream"
            : (FileManager.default.fileExists(atPath: "/usr/bin/audiostream") ? "/usr/bin/audiostream" : nil)
        let shPath = FileManager.default.fileExists(atPath: "/var/jb/bin/sh")
            ? "/var/jb/bin/sh"
            : "/bin/sh"
        
        let command: String
        if let cmd = audiostreamCmd {
            command = "\(cmd) stop"
        } else {
            command = "/var/jb/usr/bin/killall -9 audiostreamerd 2>/dev/null; /usr/bin/killall -9 audiostreamerd 2>/dev/null; for p in $(ps aux 2>/dev/null | grep '[a]udiostreamerd' | awk '{print $2}'); do kill -9 $p 2>/dev/null; done"
        }
        
        var pid: pid_t = 0
        var cArgs: [UnsafeMutablePointer<CChar>?] = [strdup(shPath), strdup("-c"), strdup(command), nil]
        var envArgs = createEnvArgs()
        let result = posix_spawn(&pid, shPath, nil, nil, &cArgs, &envArgs)
        serverLog("posix_spawn stop result: \(result), pid: \(pid)")
        for arg in cArgs { if let arg = arg { free(arg) } }
        freeEnvArgs(envArgs)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.checkServerStatus()
        }
    }
    
    func loadSongs() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var db: OpaquePointer?
            if sqlite3_open_v2(self.dbPath, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
                return
            }
            defer { sqlite3_close(db) }
            
            let query = "SELECT COUNT(*) FROM item_extra WHERE location != ''"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    let count = sqlite3_column_int(statement, 0)
                    DispatchQueue.main.async {
                        self.songCount = Int(count)
                    }
                }
                sqlite3_finalize(statement)
            }
        }
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
}

private func serverLog(_ message: String) {
    let msg = "[\(Date())] \(message)\n"
    if let data = msg.data(using: .utf8) {
        let logURL = URL(fileURLWithPath: "/tmp/audiostreamer.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let fileHandle = try? FileHandle(forWritingTo: logURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            try? data.write(to: logURL)
        }
    }
    print(message)
}

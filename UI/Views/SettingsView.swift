import SwiftUI

private enum SettingsAlert: Identifiable {
    case info(title: String, message: String)
    case confirmMigration(freeMB: Int)
    case confirmClearCaches

    var id: String {
        switch self {
        case .info(let title, let message): return "info-\(title)-\(message)"
        case .confirmMigration(let freeMB): return "migration-\(freeMB)"
        case .confirmClearCaches: return "clear-caches"
        }
    }

    var title: String {
        switch self {
        case .info(let title, _): return title
        case .confirmMigration: return "Transfer Music"
        case .confirmClearCaches: return "Clear Caches?"
        }
    }

    var message: String {
        switch self {
        case .info(_, let message):
            return message
        case .confirmMigration(let freeMB):
            return "This will copy your downloaded songs from Apple Music into AudioStream (/var/mobile/Documents/AudioStreamMusic).\n\n• Available Free Space: \(freeMB) MB\n• Storage Used: 0 MB (uses APFS Copy-on-Write)\n• Original addition dates will be preserved so album order and playlists stay intact."
        case .confirmClearCaches:
            return "This clears cached album artwork thumbnails, artist photos, and local/remote library indexes. Your music files, settings, and merge groups will not be deleted."
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var connectionService: ServerConnectionService
    @EnvironmentObject var audioService: AudioPlayerService
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    @StateObject private var serverManager = MusicServerManager.shared
    @ObservedObject private var albumMergeService = AlbumMergeService.shared
    @ObservedObject private var artistMergeService = ArtistMergeService.shared
    @ObservedObject private var migrationService = MusicMigrationService.shared

    @AppStorage("RC_ShowVolumeSlider") private var showVolumeSlider: Bool = true
    @AppStorage("RC_PreservePlaybackModes") private var preservePlaybackModes: Bool = true
    @AppStorage("RC_ShowHostTools") private var showHostTools: Bool = false

    @State private var serverAddress: String = ""
    @State private var activeAlert: SettingsAlert? = nil
    @State private var copiedAddress: Bool = false
    @State private var imageCacheSizeText: String = "Calculating..."
    @State private var libraryCacheSizeText: String = "Calculating..."
    @State private var showLogViewer: Bool = false
    @State private var logViewerText: String = ""

    private var appVersionText: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(shortVersion) (\(buildNumber))"
    }

    private var showStreamingServerSection: Bool {
        serverManager.canHostLocalServer || showHostTools
    }

    private var showMigrationSection: Bool {
        serverManager.hasLocalMediaDatabase || showHostTools
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Music Source")) {
                    Picker("Library", selection: $connectionService.librarySource) {
                        ForEach(LibrarySource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }

                    NavigationLink(destination: MergeManagementView()) {
                        HStack {
                            Text("Manage Merged Items")
                            Spacer()
                            let totalMerges = albumMergeService.mergeGroups.count + artistMergeService.mergeGroups.count
                            Text("\(totalMerges)")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(
                    header: Text("Playback & Power"),
                    footer: Text("Battery Saver pauses background server polling timers. Preserve Repeat & Shuffle prevents album or queue starts from resetting your active modes.")
                ) {
                    Toggle("Volume Slider", isOn: $showVolumeSlider)
                        .onChange(of: showVolumeSlider) { isEnabled in
                            if !isEnabled {
                                audioService.setVolume(1.0)
                            } else {
                                let savedVolume = UserDefaults.standard.object(forKey: "audio_player_volume") as? Float ?? 1.0
                                audioService.setVolume(savedVolume)
                            }
                        }

                    Toggle("Preserve Repeat & Shuffle", isOn: $preservePlaybackModes)
                    Toggle("Battery Saver Mode", isOn: $connectionService.batterySaverMode)
                }

                if connectionService.librarySource == .remote {
                    Section(header: Text("Remote Server Status")) {
                        HStack {
                            Text("Connection")
                            Spacer()
                            if connectionService.isAutoConnecting {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text(connectionService.statusMessage)
                                        .foregroundColor(.orange)
                                }
                            } else {
                                Text(connectionService.isConnected ? "Connected" : connectionService.statusMessage)
                                    .foregroundColor(connectionService.isConnected ? .green : .red)
                            }
                        }

                        if !connectionService.serverURL.isEmpty {
                            HStack {
                                Text("Active URL")
                                Spacer()
                                Text(connectionService.serverURL)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        if let status = connectionService.remoteStatus {
                            HStack {
                                Text("Remote Tracks")
                                Spacer()
                                Text("\(status.songsCount)")
                                    .foregroundColor(.secondary)
                            }

                            if let lastSync = status.lastSync {
                                HStack {
                                    Text("NAS Sync")
                                    Spacer()
                                    let isOK = (lastSync.result ?? "").lowercased() == "ok"
                                    Text((lastSync.result ?? "unknown").uppercased())
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(isOK ? .green : .orange)
                                }

                                if let timestamp = formatSyncTimestamp(lastSync.lastSuccess ?? lastSync.lastAttempt) {
                                    HStack {
                                        Text("Last Synced")
                                        Spacer()
                                        Text(timestamp)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }

                                if let freeKB = lastSync.freeKB, freeKB > 0 {
                                    HStack {
                                        Text("NAS Free Space")
                                        Spacer()
                                        Text(AppCacheStorage.formattedByteCount(UInt64(freeKB) * 1024))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }

                                if let msg = lastSync.message, !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(msg)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Toggle("Auto Connect on Launch", isOn: $connectionService.autoConnect)

                        if !connectionService.isConnected {
                            Button(connectionService.isUsingIPhoneServer ? "Wake & Connect Server" : "Retry Connection") {
                                connectionService.retryConnection()
                            }
                        } else {
                            Button(action: {
                                connectionService.fetchRemoteStatus()
                            }) {
                                HStack {
                                    Text("Refresh Server Telemetry")
                                    Spacer()
                                    if connectionService.isFetchingStatus {
                                        ProgressView()
                                    }
                                }
                            }
                        }
                    }

                    if !connectionService.savedServers.isEmpty {
                        Section(header: Text("Saved Servers")) {
                            ForEach(connectionService.savedServers, id: \.self) { savedURL in
                                Button(action: {
                                    serverAddress = savedURL
                                    connectionService.connect(url: savedURL)
                                }) {
                                    HStack {
                                        Image(systemName: "server.rack")
                                            .foregroundColor(.blue)
                                            .padding(.trailing, 4)
                                        Text(savedURL)
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        if connectionService.serverURL.caseInsensitiveCompare(savedURL) == .orderedSame && connectionService.isConnected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                        }
                                    }
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                            .onDelete { offsets in
                                for idx in offsets {
                                    connectionService.removeSavedServer(connectionService.savedServers[idx])
                                }
                            }
                        }
                    }

                    Section(
                        header: Text("Manual Connection"),
                        footer: Text("Enter a host, IP:port, or full URL (e.g. 192.168.1.210:18080). http:// is added automatically if omitted.")
                    ) {
                        TextField("192.168.1.210:18080 or http://...", text: $serverAddress)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .submitLabel(.go)
                            .onSubmit {
                                connectManualAddress()
                            }

                        Button(action: {
                            connectManualAddress()
                        }) {
                            HStack {
                                Text("Connect")
                                Spacer()
                                if let normalizedInput = ServerConnectionService.normalizeServerURL(serverAddress),
                                   connectionService.isConnected && connectionService.serverURL.caseInsensitiveCompare(normalizedInput) == .orderedSame {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                }
                            }
                        }
                        .disabled(serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Section(header: HStack {
                        Text("Network Discovery")
                        Spacer()
                        if connectionService.isSearching {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Button(action: {
                                connectionService.startAutoDiscovery()
                            }) {
                                Label("Scan", systemImage: "arrow.clockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }) {
                        if connectionService.discoveredServers.isEmpty {
                            Text(connectionService.isSearching ? "Scanning local network..." : "Tap Scan to search your local subnet for AudioStreamer servers.")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        } else {
                            ForEach(connectionService.discoveredServers, id: \.self) { server in
                                Button(action: {
                                    connectionService.connect(url: server)
                                }) {
                                    HStack {
                                        Image(systemName: "bonjour")
                                            .foregroundColor(.blue)
                                            .padding(.trailing, 4)
                                        Text(server)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        if connectionService.serverURL.caseInsensitiveCompare(server) == .orderedSame && connectionService.isConnected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                        }
                                    }
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                        }
                    }
                }

                if showStreamingServerSection {
                    Section(header: Text("Web Streaming Server")) {
                        Toggle("Enable Streaming Server", isOn: Binding(
                            get: { serverManager.isRunning },
                            set: { newValue in
                                if newValue {
                                    serverManager.startServer()
                                } else {
                                    serverManager.stopServer()
                                }
                            }
                        ))

                        if serverManager.isRunning {
                            HStack {
                                Text("Status")
                                Spacer()
                                Text(serverManager.serverStatus)
                                    .foregroundColor(.green)
                            }

                            if let address = serverManager.serverAddress {
                                HStack {
                                    Text("Address")
                                    Spacer()
                                    Button(action: {
                                        UIPasteboard.general.string = address
                                        let generator = UINotificationFeedbackGenerator()
                                        generator.notificationOccurred(.success)
                                        copiedAddress = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                            copiedAddress = false
                                        }
                                    }) {
                                        HStack(spacing: 4) {
                                            Text(copiedAddress ? "Copied" : address)
                                                .font(.system(.body, design: .monospaced))
                                                .foregroundColor(.blue)
                                            Image(systemName: copiedAddress ? "checkmark" : "doc.on.doc")
                                                .font(.caption)
                                                .foregroundColor(.blue)
                                        }
                                    }
                                }
                            }

                            HStack {
                                Text("Songs Served")
                                Spacer()
                                Text("\(serverManager.songCount)")
                                    .foregroundColor(.secondary)
                            }
                        }

                        Toggle("Auto-off when idle", isOn: $serverManager.autoOffEnabled)
                        if serverManager.autoOffEnabled {
                            Picker("Idle Timeout", selection: $serverManager.autoOffTimeoutMinutes) {
                                Text("5 minutes").tag(5)
                                Text("10 minutes").tag(10)
                                Text("15 minutes").tag(15)
                                Text("30 minutes").tag(30)
                                Text("60 minutes").tag(60)
                            }
                        }
                    }
                }

                if showMigrationSection {
                    Section(
                        header: Text("Music Library Migration"),
                        footer: Text("Copies downloaded songs from Apple Music into AudioStream (/var/mobile/Documents/AudioStreamMusic) organized by Artist/Album while preserving date-added timestamps.")
                    ) {
                        if migrationService.isMigrating {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(migrationService.statusMessage)
                                        .font(.subheadline)
                                    Spacer()
                                    Text("\(Int(migrationService.progress * 100))%")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                ProgressView(value: migrationService.progress)
                                    .accentColor(.blue)
                            }
                            .padding(.vertical, 4)
                        } else {
                            Button(action: {
                                activeAlert = .confirmMigration(freeMB: migrationService.getAvailableFreeSpaceMB())
                            }) {
                                HStack {
                                    Image(systemName: "square.and.arrow.down")
                                        .foregroundColor(.blue)
                                    Text("Transfer Music App to AudioStream")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }

                Section(header: Text("Storage & Library Maintenance")) {
                    HStack {
                        Text("Artwork & Artist Cache")
                        Spacer()
                        Text(imageCacheSizeText)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Library Index Cache")
                        Spacer()
                        Text(libraryCacheSizeText)
                            .foregroundColor(.secondary)
                    }

                    Button("Refresh Library Now") {
                        libraryViewModel.loadData(connectionService: connectionService, clearData: false, forceRefresh: true)
                    }

                    Button("Clear Image & Library Caches", role: .destructive) {
                        activeAlert = .confirmClearCaches
                    }
                }

                Section(
                    header: Text("Backup & Restore"),
                    footer: Text("Saves app settings and merge groups to Documents/audiostream_appstate.plist for backup and cross-device sync.")
                ) {
                    Button("Back Up Settings and Merges") {
                        if AppStateBackupService.shared.save(force: true) {
                            activeAlert = .info(
                                title: "Backup Saved",
                                message: "Saved settings and merge groups to Documents/audiostream_appstate.plist."
                            )
                        } else {
                            activeAlert = .info(
                                title: "Backup Failed",
                                message: "Could not write the backup file."
                            )
                        }
                    }

                    Button("Restore from Backup") {
                        do {
                            if let result = try AppStateBackupService.shared.restoreAll() {
                                activeAlert = .info(title: "Restore Complete", message: result.summary)
                            } else {
                                activeAlert = .info(
                                    title: "No Backup Found",
                                    message: "Run the NAS restore first or back up from another device."
                                )
                            }
                        } catch {
                            activeAlert = .info(title: "Restore Failed", message: error.localizedDescription)
                        }
                    }
                }

                Section(
                    header: Text("Diagnostics & About"),
                    footer: Color.clear.frame(height: 80)
                ) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersionText)
                            .foregroundColor(.secondary)
                    }

                    Toggle("Show Host & Migration Tools", isOn: $showHostTools)

                    if serverManager.hasAnyHostCapability || showHostTools {
                        Button("View Daemon Logs") {
                            logViewerText = MusicServerManager.readLogTail()
                            showLogViewer = true
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                serverAddress = connectionService.serverURL
                refreshCacheSizes()
                if serverManager.canHostLocalServer || showHostTools {
                    serverManager.checkServerStatus()
                    if serverManager.isRunning {
                        serverManager.loadSongs()
                    }
                }
                if connectionService.librarySource == .remote {
                    if !connectionService.serverURL.isEmpty && !connectionService.isConnected && connectionService.autoConnect {
                        connectionService.checkConnection()
                    } else if connectionService.isConnected {
                        connectionService.fetchRemoteStatus()
                    }
                }
            }
            .onChange(of: connectionService.serverURL) { newURL in
                serverAddress = newURL
            }
            .onChange(of: migrationService.showCompletionAlert) { show in
                if show {
                    activeAlert = .info(title: "Transfer Complete", message: migrationService.completionSummary)
                    migrationService.showCompletionAlert = false
                }
            }
            .onChange(of: serverManager.errorMessage) { err in
                if let err = err {
                    activeAlert = .info(title: "Server Status", message: err)
                    serverManager.errorMessage = nil
                }
            }
            .alert(
                activeAlert?.title ?? "",
                isPresented: Binding(
                    get: { activeAlert != nil },
                    set: { if !$0 { activeAlert = nil } }
                ),
                presenting: activeAlert
            ) { alert in
                switch alert {
                case .info:
                    Button("OK", role: .cancel) {}
                case .confirmMigration:
                    Button("Start Transfer") {
                        migrationService.startMigration()
                    }
                    Button("Cancel", role: .cancel) {}
                case .confirmClearCaches:
                    Button("Clear Caches", role: .destructive) {
                        clearAllCaches()
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } message: { alert in
                Text(alert.message)
            }
            .sheet(isPresented: $showLogViewer) {
                NavigationView {
                    ScrollView {
                        Text(logViewerText.isEmpty ? "No daemon log entries found." : logViewerText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle("Daemon Logs")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Close") { showLogViewer = false }
                        }
                        ToolbarItemGroup(placement: .navigationBarTrailing) {
                            Button("Clear") {
                                MusicServerManager.clearLogs()
                                logViewerText = ""
                            }
                            Button("Refresh") {
                                logViewerText = MusicServerManager.readLogTail()
                            }
                        }
                    }
                }
                .preferredColorScheme(.dark)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func connectManualAddress() {
        let trimmed = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = ServerConnectionService.normalizeServerURL(trimmed) else {
            activeAlert = .info(
                title: "Invalid URL",
                message: "Enter a valid host or IP address, such as 192.168.1.210:18080."
            )
            return
        }
        serverAddress = normalized
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        connectionService.connect(url: normalized)
    }

    private func refreshCacheSizes() {
        DispatchQueue.global(qos: .utility).async {
            let imageBytes = ImageLoader.diskSizeBytes
                + LocalFileArtworkCache.shared.diskSizeBytes
                + ArtistImageLoader.diskSizeBytes
            let libraryBytes = RemoteLibraryDiskCache.shared.diskSizeBytes
                + LocalLibraryDiskCache.shared.diskSizeBytes
                + LocalFileLibraryScanner.shared.metadataCacheSizeBytes

            let formattedImages = AppCacheStorage.formattedByteCount(imageBytes)
            let formattedLibrary = AppCacheStorage.formattedByteCount(libraryBytes)
            DispatchQueue.main.async {
                self.imageCacheSizeText = formattedImages
                self.libraryCacheSizeText = formattedLibrary
            }
        }
    }

    private func clearAllCaches() {
        ImageLoader.clearAllCaches()
        ArtistImageLoader.clearCache()
        RemoteLibraryDiskCache.shared.clear()
        LocalFileLibraryScanner.shared.clearAllCaches()
        libraryViewModel.loadData(connectionService: connectionService, clearData: false, forceRefresh: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            refreshCacheSizes()
        }
    }

    private func formatSyncTimestamp(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let isoWithFraction = ISO8601DateFormatter()
        isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        guard let date = isoWithFraction.date(from: raw) ?? isoBasic.date(from: raw) else {
            return raw
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

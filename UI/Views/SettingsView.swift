import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var connectionService: ServerConnectionService
    @EnvironmentObject var audioService: AudioPlayerService
    @StateObject private var serverManager = MusicServerManager.shared
    @ObservedObject private var albumMergeService = AlbumMergeService.shared
    @ObservedObject private var artistMergeService = ArtistMergeService.shared
    @ObservedObject private var migrationService = MusicMigrationService.shared
    @State private var showMigrationConfirmAlert: Bool = false
    @AppStorage("RC_ShowVolumeSlider") private var showVolumeSlider: Bool = false
    @State private var serverAddress: String = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Music Source")) {
                    Picker("Library", selection: $connectionService.librarySource) {
                        ForEach(LibrarySource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    Toggle("Auto Connect on Launch", isOn: $connectionService.autoConnect)
                    
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
                
                Section(header: Text("Playback")) {
                    Toggle("Volume Slider", isOn: $showVolumeSlider)
                        .onChange(of: showVolumeSlider) { isEnabled in
                            if !isEnabled {
                                audioService.setVolume(1.0)
                            } else {
                                let savedVolume = UserDefaults.standard.object(forKey: "audio_player_volume") as? Float ?? 1.0
                                audioService.setVolume(savedVolume)
                            }
                        }
                }
                
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
                                }) {
                                    HStack(spacing: 4) {
                                        Text(address)
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundColor(.blue)
                                        Image(systemName: "doc.on.doc")
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
                        
                        Toggle("Auto-off when idle", isOn: $serverManager.autoOffEnabled)
                    }
                }
                
                Section(header: HStack {
                    Text("Discovered Servers")
                    Spacer()
                    if connectionService.isSearching {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                    } else {
                        Button(action: {
                            connectionService.startAutoDiscovery()
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                }) {
                    if connectionService.discoveredServers.isEmpty {
                        Text(connectionService.isSearching ? "Searching local network..." : "No servers found on your network.")
                            .foregroundColor(.gray)
                            .font(.subheadline)
                    } else {
                        ForEach(connectionService.discoveredServers, id: \.self) { server in
                            Button(action: {
                                connectionService.connect(url: server)
                            }) {
                                HStack {
                                    Image(systemName: "server.rack")
                                        .foregroundColor(.blue)
                                        .padding(.trailing, 4)
                                    Text(server)
                                        .foregroundColor(.white)
                                    Spacer()
                                    if connectionService.serverURL == server && connectionService.isConnected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                }
                
                Section(header: Text("Manual Connection"), footer: Text("Enter a server URL manually if it was not auto-discovered.")) {
                    TextField("Server URL (http://...)", text: $serverAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    
                    Button(action: {
                        connectionService.connect(url: serverAddress)
                    }) {
                        HStack {
                            Text("Connect")
                            Spacer()
                            if connectionService.isConnected && connectionService.serverURL == serverAddress {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
                

                Section(header: Text("Music Library Migration"), footer: Text("Copies downloaded songs from Apple Music into AudioStream (/var/mobile/Documents/AudioStreamMusic) organized by Artist/Album. Preserves exact date added timestamps so album sorting and special playlists are not disrupted.")) {
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
                            showMigrationConfirmAlert = true
                        }) {
                            HStack {
                                Image(systemName: "square.and.arrow.down")
                                    .foregroundColor(.blue)
                                Text("Transfer Music App to AudioStream")
                                    .foregroundColor(.blue)
                            }
                        }
                        .alert(isPresented: $showMigrationConfirmAlert) {
                            let freeMB = migrationService.getAvailableFreeSpaceMB()
                            return Alert(
                                title: Text("Transfer Music"),
                                message: Text("This will copy your downloaded songs from Apple Music into AudioStream (/var/mobile/Documents/AudioStreamMusic).\n\n• Available Free Space: \(freeMB) MB\n• Storage Used: 0 MB (uses APFS Copy-on-Write)\n• Original addition dates will be preserved so album order and playlists stay intact."),
                                primaryButton: .default(Text("Start Transfer")) {
                                    migrationService.startMigration()
                                },
                                secondaryButton: .cancel()
                            )
                        }
                    }
                }
                
                Section(header: Text("Status"), footer: Color.clear.frame(height: 80)) {
                    HStack {
                        Text("Connection Status")
                        Spacer()
                        if connectionService.isAutoConnecting {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(connectionService.statusMessage)
                                    .foregroundColor(.orange)
                            }
                        } else {
                            Text(connectionService.isConnected ? "Connected" : "Disconnected")
                                .foregroundColor(connectionService.isConnected ? .green : .red)
                        }
                    }
                    
                    if connectionService.librarySource == .remote && !connectionService.isConnected {
                        Button("Wake & Connect Server") {
                            connectionService.retryConnection()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .alert(isPresented: $migrationService.showCompletionAlert) {
                Alert(
                    title: Text("Transfer Complete"),
                    message: Text(migrationService.completionSummary),
                    dismissButton: .default(Text("Done"))
                )
            }
            .onAppear {
                serverAddress = connectionService.serverURL
                serverManager.checkServerStatus()
                if serverManager.isRunning {
                    serverManager.loadSongs()
                }
                if connectionService.librarySource == .remote && !connectionService.serverURL.isEmpty && !connectionService.isConnected {
                    connectionService.checkConnection()
                }
                connectionService.startAutoDiscovery()
            }
            .onChange(of: connectionService.serverURL) { newURL in
                serverAddress = newURL
            }
            .alert(isPresented: Binding<Bool>(
                get: { serverManager.errorMessage != nil },
                set: { newValue in
                    if !newValue {
                        serverManager.errorMessage = nil
                    }
                }
            )) {
                Alert(
                    title: Text("Server Status"),
                    message: Text(serverManager.errorMessage ?? ""),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

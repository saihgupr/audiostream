import SwiftUI

struct AlbumDetailView: View {
    @State var album: Album
    @EnvironmentObject var audioService: AudioPlayerService
    @EnvironmentObject var navManager: NavigationManager
    @EnvironmentObject var connectionService: ServerConnectionService
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @State private var showJustAdded = false
    @State private var selectedTrackForDelete: Track? = nil
    @State private var showTrackDeleteConfirmation = false
    @State private var isDownloadingArtwork = false
    @State private var artworkAlertTitle = ""
    @State private var artworkAlertMessage = ""
    @State private var showArtworkAlert = false
    @State private var showManualSearchPrompt = false
    @State private var downloadSuccessBanner = false
    @State private var showArtworkActionSheet = false
    
    var onTrackDeleted: ((Track) -> Void)? = nil
    var onArtworkUpdated: ((Album) -> Void)? = nil
    
    init(album: Album, onTrackDeleted: ((Track) -> Void)? = nil, onArtworkUpdated: ((Album) -> Void)? = nil) {
        _album = State(initialValue: album)
        self.onTrackDeleted = onTrackDeleted
        self.onArtworkUpdated = onArtworkUpdated
    }
    
    var body: some View {
        List {
            // Header Section
            Section {
                if horizontalSizeClass == .compact {
                    // Vertical adaptive layout for iPhone (compact)
                    VStack(alignment: .center, spacing: 16) {
                        albumArtworkView(size: 200)
                        
                        VStack(alignment: .center, spacing: 6) {
                            Text(album.title)
                                .font(.title2)
                                .bold()
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                            
                            HStack(spacing: 0) {
                                let artistParts = album.artist.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                                ForEach(artistParts.indices, id: \.self) { index in
                                    let artist = artistParts[index]
                                    Text(artist)
                                        .font(.title3)
                                        .foregroundColor(.gray)
                                        .onTapGesture {
                                            presentationMode.wrappedValue.dismiss()
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                                navManager.navigateToArtist(name: artist)
                                            }
                                        }
                                    
                                    if index < artistParts.count - 1 {
                                        Text(", ")
                                            .font(.title3)
                                            .foregroundColor(.gray)
                                    }
                                }
                            }
                            
                            Text("\(album.tracks.count) Songs")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack(spacing: 12) {
                            AlbumPlayButton(
                                album: album,
                                onPlay: {
                                    if !album.tracks.isEmpty {
                                        audioService.play(tracks: album.tracks, startingAt: 0)
                                    }
                                },
                                onShuffle: {
                                    if !album.tracks.isEmpty {
                                        audioService.state.isShuffleEnabled = true
                                        audioService.play(tracks: album.tracks.shuffled(), startingAt: 0)
                                    }
                                },
                                isCompact: true
                            )
                            
                            Button(action: {
                                if !album.tracks.isEmpty {
                                    audioService.addToQueue(albumTitle: album.title, tracks: album.tracks)
                                    withAnimation {
                                        showJustAdded = true
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        withAnimation {
                                            showJustAdded = false
                                        }
                                    }
                                }
                            }) {
                                let isQueued = audioService.queuedAlbumTitles.contains(album.title)
                                HStack {
                                    if showJustAdded {
                                        Image(systemName: "checkmark")
                                        Text("Added")
                                    } else {
                                        Image(systemName: "text.badge.plus")
                                        Text("Queue")
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(isQueued ? Color.blue : Color.white.opacity(0.15))
                                .foregroundColor(.white)
                                .cornerRadius(10)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(.top, 8)
                    }
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .buttonStyle(PlainButtonStyle())
                } else {
                    // Original horizontal layout for iPad (regular)
                    HStack(alignment: .top, spacing: 20) {
                        albumArtworkView(size: 150)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text(album.title)
                                .font(.title2)
                                .bold()
                                .foregroundColor(.white)
                            
                            HStack(spacing: 0) {
                                let artistParts = album.artist.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                                ForEach(artistParts.indices, id: \.self) { index in
                                    let artist = artistParts[index]
                                    Text(artist)
                                        .font(.title3)
                                        .foregroundColor(.gray)
                                        .onTapGesture {
                                            presentationMode.wrappedValue.dismiss()
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                                navManager.navigateToArtist(name: artist)
                                            }
                                        }
                                    
                                    if index < artistParts.count - 1 {
                                        Text(", ")
                                            .font(.title3)
                                            .foregroundColor(.gray)
                                    }
                                }
                            }
                            
                            Text("\(album.tracks.count) Songs")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            HStack(spacing: 12) {
                                AlbumPlayButton(
                                    album: album,
                                    onPlay: {
                                        if !album.tracks.isEmpty {
                                            audioService.play(tracks: album.tracks, startingAt: 0)
                                        }
                                    },
                                    onShuffle: {
                                        if !album.tracks.isEmpty {
                                            audioService.state.isShuffleEnabled = true
                                            audioService.play(tracks: album.tracks.shuffled(), startingAt: 0)
                                        }
                                    },
                                    isCompact: false
                                )
                                
                                Button(action: {
                                    if !album.tracks.isEmpty {
                                    audioService.addToQueue(albumTitle: album.title, tracks: album.tracks)
                                        withAnimation {
                                            showJustAdded = true
                                        }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                            withAnimation {
                                                showJustAdded = false
                                            }
                                        }
                                    }
                                }) {
                                    let isQueued = audioService.queuedAlbumTitles.contains(album.title)
                                    HStack {
                                        if showJustAdded {
                                            Image(systemName: "checkmark")
                                            Text("Added")
                                        } else {
                                            Image(systemName: "text.badge.plus")
                                            Text("Queue")
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(isQueued ? Color.blue : Color.white.opacity(0.15))
                                    .foregroundColor(.white)
                                    .cornerRadius(20)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.top, 10)
                        }
                    }
                    .padding(.vertical)
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .buttonStyle(PlainButtonStyle())
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            
            // Track List Section
            Section {
                ForEach(album.tracks) { track in
                    HStack {
                        if let current = audioService.state.currentTrack, current.persistentId == track.persistentId {
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundColor(.white)
                                .frame(width: 30)
                        } else {
                            Text("\(album.tracks.firstIndex(of: track)! + 1)")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .frame(width: 30)
                        }
                        
                        VStack(alignment: .leading) {
                            Text(track.title)
                                .foregroundColor(.white)
                                .fontWeight(audioService.state.currentTrack?.persistentId == track.persistentId ? .bold : .regular)
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(formatDuration(track.duration))
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let index = album.tracks.firstIndex(where: { $0.persistentId == track.persistentId }) {
                            audioService.play(tracks: album.tracks, startingAt: index)
                        }
                    }
                    .contextMenu {
                        Button(action: {
                            audioService.addToQueue(tracks: [track])
                        }) {
                            Label("Add to Queue", systemImage: "text.badge.plus")
                        }
                        
                        Button(action: {
                            if let index = album.tracks.firstIndex(where: { $0.persistentId == track.persistentId }) {
                                audioService.play(tracks: album.tracks, startingAt: index)
                            }
                        }) {
                            Label("Play", systemImage: "play.fill")
                        }
                        
                        if connectionService.librarySource == .local {
                            Button(action: {
                                selectedTrackForDelete = track
                                showTrackDeleteConfirmation = true
                            }) {
                                Label("Delete Song", systemImage: "trash")
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
                .onDelete(perform: connectionService.librarySource == .local ? { indexSet in
                    if let index = indexSet.first {
                        selectedTrackForDelete = album.tracks[index]
                        showTrackDeleteConfirmation = true
                    }
                } : nil)
            }
            
            // Bottom spacer for Player bar
            Color.clear.frame(height: 120)
                .listRowBackground(Color.clear)
        }
        .listStyle(PlainListStyle())
        .background(Color.black.edgesIgnoringSafeArea(.all))
        .navigationBarTitleDisplayMode(.inline)
        .alert(isPresented: $showTrackDeleteConfirmation) {
            Alert(
                title: Text("Delete Song"),
                message: Text("Are you sure you want to permanently delete '\(selectedTrackForDelete?.title ?? "")' from this device? This action cannot be undone."),
                primaryButton: .destructive(Text("Delete")) {
                    if let track = selectedTrackForDelete {
                        let libraryService = MusicLibraryService(connectionService: connectionService)
                        if libraryService.deleteTrack(track) {
                            var updatedTracks = album.tracks
                            updatedTracks.removeAll { $0.persistentId == track.persistentId }
                            album = Album(
                                id: album.id,
                                title: album.title,
                                artist: album.artist,
                                artworkUrl: album.artworkUrl,
                                tracks: updatedTracks
                            )
                            onTrackDeleted?(track)
                        }
                    }
                    selectedTrackForDelete = nil
                },
                secondaryButton: .cancel {
                    selectedTrackForDelete = nil
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .trackDidDelete)) { notification in
            if let deletedTrack = notification.object as? Track {
                var updatedTracks = album.tracks
                updatedTracks.removeAll { $0.persistentId == deletedTrack.persistentId }
                if updatedTracks.isEmpty {
                    presentationMode.wrappedValue.dismiss()
                } else {
                    album = Album(
                        id: album.id,
                        title: album.title,
                        artist: album.artist,
                        artworkUrl: album.artworkUrl,
                        tracks: updatedTracks
                    )
                }
                onTrackDeleted?(deletedTrack)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .albumArtworkDidUpdate)) { notification in
            if let updated = notification.object as? Album, updated.id == album.id {
                album = updated
            }
        }
        .sheet(isPresented: $showManualSearchPrompt) {
            ArtworkSearchSheet(album: album, isPresented: $showManualSearchPrompt) { customQuery in
                downloadArtwork(customQuery: customQuery)
            }
        }
        .alert(isPresented: $showArtworkAlert) {
            Alert(
                title: Text(artworkAlertTitle),
                message: Text(artworkAlertMessage),
                dismissButton: .default(Text("OK"))
            )
        }
        .actionSheet(isPresented: $showArtworkActionSheet) {
            ActionSheet(
                title: Text("Album Artwork"),
                buttons: [
                    .default(Text("Download Album Artwork")) {
                        downloadArtwork()
                    },
                    .default(Text("Search Artwork Manually...")) {
                        showManualSearchPrompt = true
                    },
                    .cancel()
                ]
            )
        }
    }
    
    @ViewBuilder
    private func albumArtworkView(size: CGFloat) -> some View {
        ZStack {
            if let url = album.artworkUrl {
                RemoteImage(url: url)
                    .aspectRatio(1.0, contentMode: .fit)
                    .frame(width: size, height: size)
                    .cornerRadius(12)
                    .shadow(radius: 8)
            } else {
                if album.artist == "Playlist" {
                    PlaylistArtworkView(
                        tracks: album.tracks,
                        size: size,
                        playlistId: album.id,
                        fallbackSystemName: album.id.hasPrefix("-") ? "clock.arrow.circlepath" : "music.note.list",
                        fallbackBgColor: album.id.hasPrefix("-") ? Color.purple.opacity(0.2) : Color.gray.opacity(0.3),
                        fallbackFgColor: album.id.hasPrefix("-") ? .purple : .white
                    )
                    .shadow(radius: 8)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: size, height: size)
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.4))
                            .foregroundColor(.white)
                    }
                    .shadow(radius: 8)
                }
            }
            
            if isDownloadingArtwork {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.65))
                    .frame(width: size, height: size)
                    .overlay(
                        VStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.2)
                            Text("Downloading...")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                        }
                    )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onLongPressGesture(minimumDuration: 0.4) {
            if album.artist != "Playlist" {
                showArtworkActionSheet = true
            }
        }
    }
    
    private func downloadArtwork(customQuery: String? = nil) {
        guard !isDownloadingArtwork else { return }
        isDownloadingArtwork = true
        
        Task {
            do {
                let result = try await ArtworkDownloadService.shared.findAndDownloadArtwork(
                    for: album,
                    customQuery: customQuery
                )
                
                await MainActor.run {
                    self.isDownloadingArtwork = false
                    
                    let updatedTracks = album.tracks.map { track -> Track in
                        var t = track
                        t.artworkUrl = result.fileUrl
                        return t
                    }
                    
                    let updatedAlbum = Album(
                        id: album.id,
                        title: album.title,
                        artist: album.artist,
                        artworkUrl: result.fileUrl,
                        tracks: updatedTracks,
                        dateAdded: album.dateAdded
                    )
                    
                    self.album = updatedAlbum
                    self.onArtworkUpdated?(updatedAlbum)
                    NotificationCenter.default.post(name: .albumArtworkDidUpdate, object: updatedAlbum)
                }
            } catch {
                await MainActor.run {
                    self.isDownloadingArtwork = false
                    self.artworkAlertTitle = "Artwork Download"
                    self.artworkAlertMessage = error.localizedDescription
                    self.showArtworkAlert = true
                }
            }
        }
    }
    
    func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct AlbumPlayButton: View {
    let album: Album
    let onPlay: () -> Void
    let onShuffle: () -> Void
    var isCompact: Bool = true
    
    @State private var isPressed = false
    @State private var isShuffleMode = false
    @State private var longPressTask: Task<Void, Never>? = nil
    @State private var resetShuffleTask: Task<Void, Never>? = nil
    @State private var buttonSize: CGSize = .zero
    
    private var isEffectivelyShuffle: Bool {
        isShuffleMode || album.artist == "Playlist"
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isEffectivelyShuffle ? "shuffle" : "play.fill")
                .font(.system(size: isCompact ? 16 : 14, weight: .bold))
            Text(isEffectivelyShuffle ? "Shuffle" : "Play")
                .fontWeight(.semibold)
        }
        .frame(maxWidth: isCompact ? .infinity : nil)
        .padding(.horizontal, isCompact ? 16 : 24)
        .padding(.vertical, isCompact ? 12 : 10)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { buttonSize = proxy.size }
                    .onChange(of: proxy.size) { newSize in buttonSize = newSize }
            }
        )
        .background(
            isEffectivelyShuffle
                ? Color.blue
                : (isPressed ? Color.white.opacity(0.8) : Color.white)
        )
        .foregroundColor(isEffectivelyShuffle ? .white : .black)
        .cornerRadius(isCompact ? 10 : 20)
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isShuffleMode)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let rect = CGRect(origin: .zero, size: buttonSize)
                    let isInside = buttonSize == .zero || rect.contains(value.location)
                    
                    if !isInside {
                        // User slid finger off: immediately cancel long press and remove blue/text
                        longPressTask?.cancel()
                        longPressTask = nil
                        if isShuffleMode {
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                                isShuffleMode = false
                            }
                        }
                        if isPressed {
                            isPressed = false
                        }
                        return
                    }
                    
                    if !isPressed {
                        isPressed = true
                        resetShuffleTask?.cancel()
                        longPressTask?.cancel()
                        longPressTask = Task {
                            try? await Task.sleep(nanoseconds: 350_000_000) // 350ms
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    isShuffleMode = true
                                }
                                let generator = UIImpactFeedbackGenerator(style: .medium)
                                generator.impactOccurred()
                            }
                        }
                    }
                }
                .onEnded { value in
                    longPressTask?.cancel()
                    let rect = CGRect(origin: .zero, size: buttonSize)
                    let slidedAway = buttonSize != .zero && !rect.contains(value.location)
                    
                    isPressed = false
                    
                    if slidedAway {
                        // User slid away: cancel action and immediately revert shuffle mode
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            isShuffleMode = false
                        }
                        return
                    }
                    
                    let didShuffle = isShuffleMode || album.artist == "Playlist"
                    if didShuffle {
                        // Stay blue for 2 seconds after release
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            isShuffleMode = true
                        }
                        resetShuffleTask?.cancel()
                        resetShuffleTask = Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                    isShuffleMode = false
                                }
                            }
                        }
                        onShuffle()
                    } else {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            isShuffleMode = false
                        }
                        onPlay()
                    }
                }
        )
    }
}

struct ArtworkSearchSheet: View {
    let album: Album
    @Binding var isPresented: Bool
    let onSearch: (String) -> Void
    
    @State private var query: String = ""
    
    init(album: Album, isPresented: Binding<Bool>, onSearch: @escaping (String) -> Void) {
        self.album = album
        self._isPresented = isPresented
        self.onSearch = onSearch
        self._query = State(initialValue: "\(album.artist) \(album.title)".trimmingCharacters(in: .whitespaces))
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 20) {
                    Text("Search Apple Music for artwork matching this album:")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    
                    TextField("Artist and album name", text: $query)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .foregroundColor(.white)
                    
                    Button(action: {
                        isPresented = false
                        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !q.isEmpty {
                            onSearch(q)
                        }
                    }) {
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Find & Download Artwork")
                                .bold()
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .background(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray.opacity(0.3) : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Search Artwork")
            .navigationBarItems(
                leading: Button("Cancel") {
                    isPresented = false
                }
                .foregroundColor(.white)
            )
        }
    }
}


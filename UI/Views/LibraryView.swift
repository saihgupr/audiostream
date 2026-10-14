import SwiftUI
import Combine

enum LibraryCategory: String, CaseIterable, Identifiable {
    case albums = "Albums"
    case playlists = "Playlists"
    case artists = "Artists"
    case songs = "Songs"
    
    var id: String { self.rawValue }
}

enum LibraryDeleteTarget: Identifiable {
    case album(Album)
    case track(Track)
    case playlist(Playlist)
    
    var id: String {
        switch self {
        case .album(let a): return "album-\(a.id)"
        case .track(let t): return "track-\(t.id)"
        case .playlist(let p): return "playlist-\(p.id)"
        }
    }
}

struct ArtistMergeTarget: Identifiable {
    let artist: String
    var id: String { artist }
}

struct LibraryView: View {
    @EnvironmentObject var connectionService: ServerConnectionService
    @EnvironmentObject var audioService: AudioPlayerService
    @EnvironmentObject var navManager: NavigationManager
    @StateObject private var viewModel = LibraryViewModel()
    @State private var selectedCategory: LibraryCategory = .albums
    @State private var artistSearchQuery = ""
    @State private var songSearchQuery = ""
    @State private var albumSearchQuery = ""
    @State private var selectedAlbum: Album? = nil
    @State private var navigateToAlbumActive: Bool = false
    @State private var selectedAlbumForMerge: Album? = nil
    @State private var isAlbumMergeMode: Bool = false
    @State private var primaryMergeAlbum: Album? = nil
    @State private var selectedMergeAlbumIds: Set<String> = []
    @State private var showingMergeConfirmation: Bool = false
    @State private var selectedArtist: String? = nil
    @State private var navigateToArtistActive: Bool = false
    @State private var selectedArtistForMerge: ArtistMergeTarget? = nil
    @State private var deleteTarget: LibraryDeleteTarget? = nil
    var stackId: UUID
    @State private var hasLoadedInitialData = false
    
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    
    private var columns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 5 : 2
        return Array(repeating: GridItem(.flexible(), spacing: count == 5 ? 16 : 12), count: count)
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                NavigationBarHider() // hides bar at instance level, removing safe area inset

                // Hidden programmatic link for navigating to an album from NowPlayingView
                if let album = selectedAlbum {
                    NavigationLink(
                        destination: AlbumDetailView(album: album, onTrackDeleted: { track in
                            viewModel.removeTrackState(track)
                        }, onArtworkUpdated: { updatedAlbum in
                            viewModel.updateAlbumArtwork(album: updatedAlbum)
                            if selectedAlbum?.id == updatedAlbum.id {
                                selectedAlbum = updatedAlbum
                            }
                        }),
                        isActive: $navigateToAlbumActive
                    ) { EmptyView() }
                        .hidden()
                }
                
                // Hidden programmatic link for navigating to an artist from NowPlayingView
                if let artist = selectedArtist {
                    let tracks = viewModel.tracksForArtist(artist)
                    NavigationLink(
                        destination: ArtistDetailView(artist: artist, tracks: tracks),
                        isActive: $navigateToArtistActive
                    ) { EmptyView() }
                        .hidden()
                }
                
                VStack(spacing: 0) {
                    if isAlbumMergeMode {
                        HStack(spacing: 12) {
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isAlbumMergeMode = false
                                    primaryMergeAlbum = nil
                                    selectedMergeAlbumIds.removeAll()
                                }
                            }) {
                                Text("Cancel")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.white.opacity(0.85))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Color.white.opacity(0.12))
                                    .cornerRadius(8)
                            }
                            
                            Spacer()
                            
                            VStack(spacing: 2) {
                                Text("Merge Albums")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)
                                if let primary = primaryMergeAlbum {
                                    Text("Into “\(primary.title)” (\(selectedMergeAlbumIds.count) selected)")
                                        .font(.system(size: 11))
                                        .foregroundColor(.gray)
                                        .lineLimit(1)
                                } else {
                                    Text("\(selectedMergeAlbumIds.count) selected")
                                        .font(.system(size: 11))
                                        .foregroundColor(.gray)
                                }
                            }
                            
                            Spacer()
                            
                            Button(action: {
                                showingMergeConfirmation = true
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.combine")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text("Merge")
                                        .font(.system(size: 15, weight: .semibold))
                                }
                                .foregroundColor(selectedMergeAlbumIds.count >= 2 ? .white : Color.white.opacity(0.4))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(selectedMergeAlbumIds.count >= 2 ? Color.blue : Color.gray.opacity(0.2))
                                .cornerRadius(8)
                            }
                            .disabled(selectedMergeAlbumIds.count < 2)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(UIColor.secondarySystemBackground).opacity(0.95))
                        .cornerRadius(12)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 6)
                        .alert(isPresented: $showingMergeConfirmation) {
                            let targetTitle = primaryMergeAlbum?.title ?? "Selected Album"
                            let targetArtist = primaryMergeAlbum?.artist ?? "Artist"
                            return Alert(
                                title: Text("Merge \(selectedMergeAlbumIds.count) Albums?"),
                                message: Text("These albums will be combined into '\(targetTitle)' by '\(targetArtist)'. All tracks will be preserved."),
                                primaryButton: .default(Text("Merge")) {
                                    performInPlaceAlbumMerge()
                                },
                                secondaryButton: .cancel()
                            )
                        }
                    } else {
                        // Category Picker
                        Picker("Category", selection: $selectedCategory) {
                            ForEach(LibraryCategory.allCases) { category in
                                Text(category.rawValue).tag(category)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 8)
                    }
                    
                    let isCategoryEmpty: Bool = {
                        switch selectedCategory {
                        case .albums: return viewModel.albums.isEmpty
                        case .playlists: return viewModel.playlists.isEmpty
                        case .artists: return viewModel.artists.isEmpty
                        case .songs: return viewModel.allTracks.isEmpty
                        }
                    }()
                    
                    if (viewModel.isLoading || connectionService.isAutoConnecting) && isCategoryEmpty && selectedCategory != .albums {
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            if connectionService.isAutoConnecting {
                                Text(connectionService.statusMessage)
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                            
                    } else if let message = viewModel.message {
                        ScrollView {
                            VStack(spacing: 16) {
                                Spacer(minLength: 80)
                                Image(systemName: connectionService.librarySource == .local ? "music.note.house" : "wifi.slash")
                                    .font(.system(size: 52))
                                    .foregroundColor(.gray)
                                Text(message)
                                    .font(.headline)
                                    .foregroundColor(.gray)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                                
                                if connectionService.librarySource == .remote {
                                    Button(action: {
                                        connectionService.retryConnection()
                                        viewModel.loadData(connectionService: connectionService)
                                    }) {
                                        Text("Retry Connection")
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 24)
                                            .padding(.vertical, 12)
                                            .background(Color.white.opacity(0.15))
                                            .foregroundColor(.white)
                                            .cornerRadius(10)
                                    }
                                    .padding(.top, 8)
                                } else {
                                    Text("Drag down to refresh")
                                        .font(.subheadline)
                                        .foregroundColor(.gray.opacity(0.6))
                                        .padding(.top, 4)
                                }
                                Spacer(minLength: 80)
                            }
                            .frame(maxWidth: .infinity, minHeight: 400)
                        }
                        .background(Color.black)
                        .refreshableIfAvailable {
                            await viewModel.loadDataAsync(connectionService: connectionService, clearData: false, forceRefresh: true)
                        }
                        
                    } else if selectedCategory == .songs {
                        let filteredTracks = viewModel.allTracks.filter {
                            songSearchQuery.isEmpty ? true :
                            $0.title.localizedCaseInsensitiveContains(songSearchQuery) ||
                            $0.artist.localizedCaseInsensitiveContains(songSearchQuery)
                        }
                        
                        List {
                            VStack(spacing: 10) {
                                Button(action: {
                                    if !viewModel.allTracks.isEmpty {
                                        audioService.play(tracks: viewModel.allTracks.shuffled(), startingAt: 0)
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: "shuffle")
                                        Text("Shuffle All Songs")
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .background(Color.white)
                                    .foregroundColor(.black)
                                    .cornerRadius(10)
                                }
                                
                                HStack {
                                    Image(systemName: "magnifyingglass").foregroundColor(.gray)
                                    TextField("Search Songs", text: $songSearchQuery)
                                        .textFieldStyle(PlainTextFieldStyle())
                                        .foregroundColor(.white)
                                    
                                    if !songSearchQuery.isEmpty {
                                        Button(action: { songSearchQuery = "" }) {
                                            Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                                        }
                                    }
                                }
                                .padding(10)
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(10)
                            }
                            .background(
                                RefreshControlInstaller(onRefresh: {
                                    await viewModel.loadDataAsync(connectionService: connectionService, clearData: false, forceRefresh: true)
                                })
                            )
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            
                            ForEach(filteredTracks) { track in
                                HStack(spacing: 12) {
                                    Group {
                                        if let url = track.artworkUrl {
                                            RemoteImage(url: url)
                                                .frame(width: 40, height: 40)
                                                .cornerRadius(4)
                                        } else {
                                            Image(systemName: "music.note")
                                                .frame(width: 40, height: 40)
                                                .background(Color.gray.opacity(0.3))
                                                .cornerRadius(4)
                                                .foregroundColor(.white)
                                        }
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
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
                                    if let current = audioService.state.currentTrack, current.persistentId == track.persistentId {
                                        Image(systemName: "speaker.wave.3.fill")
                                            .foregroundColor(.white)
                                            .font(.caption)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let index = filteredTracks.firstIndex(where: { $0.persistentId == track.persistentId }) {
                                        audioService.play(tracks: filteredTracks, startingAt: index)
                                    }
                                }
                                .contextMenu {
                                    Button(action: {
                                        audioService.addToQueue(tracks: [track])
                                    }) {
                                        Label("Add to Queue", systemImage: "text.badge.plus")
                                    }
                                    
                                    Button(action: {
                                        audioService.play(tracks: [track], startingAt: 0)
                                    }) {
                                        Label("Play", systemImage: "play.fill")
                                    }
                                    
                                    if connectionService.librarySource == .local {
                                        Button(action: {
                                            deleteTarget = .track(track)
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
                                    deleteTarget = .track(filteredTracks[index])
                                }
                            } : nil)
                            
                            Color.clear.frame(height: 80)
                                .listRowBackground(Color.clear)
                        }
                        .listStyle(PlainListStyle())
                        .background(Color.black)
                        .refreshableIfAvailable {
                            await viewModel.loadDataAsync(connectionService: connectionService, clearData: false, forceRefresh: true)
                        }
                        
                    } else if selectedCategory == .playlists {
                        List {
                            ForEach(viewModel.playlists) { playlist in
                                let playlistAlbum = Album(
                                    id: String(playlist.id),
                                    title: playlist.name,
                                    artist: "Playlist",
                                    artworkUrl: nil,
                                    tracks: playlist.tracks
                                )
                                NavigationLink(destination: AlbumDetailView(album: playlistAlbum, onTrackDeleted: { track in
                                    viewModel.removeTrackState(track)
                                }, onArtworkUpdated: { updatedAlbum in
                                    viewModel.updateAlbumArtwork(album: updatedAlbum)
                                })) {
                                    HStack(spacing: 12) {
                                        PlaylistArtworkView(
                                            tracks: playlist.tracks,
                                            size: 44,
                                            playlistId: String(playlist.id),
                                            fallbackSystemName: playlist.id < 0 ? "clock.arrow.circlepath" : "music.note.list",
                                            fallbackBgColor: playlist.id < 0 ? Color.purple.opacity(0.2) : Color.gray.opacity(0.3),
                                            fallbackFgColor: playlist.id < 0 ? .purple : .white
                                        )
                                        Text(playlist.name)
                                            .foregroundColor(.white)
                                            .font(.headline)
                                            .lineLimit(1)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            }
                            .onDelete(perform: connectionService.librarySource == .local ? { indexSet in
                                if let index = indexSet.first {
                                    let playlist = viewModel.playlists[index]
                                    if playlist.id >= 0 {
                                        deleteTarget = .playlist(playlist)
                                    }
                                }
                            } : nil)
                            
                            Color.clear.frame(height: 80)
                                .listRowBackground(Color.clear)
                        }
                        .listStyle(PlainListStyle())
                        .background(Color.black)
                        .background(
                            RefreshControlInstaller(onRefresh: {
                                await viewModel.loadDataAsync(connectionService: connectionService, clearData: false, forceRefresh: true)
                            })
                        )
                        .refreshableIfAvailable {
                            await viewModel.loadDataAsync(connectionService: connectionService, clearData: false, forceRefresh: true)
                        }
                        
                    } else if selectedCategory == .albums {
                        ScrollView {
                            VStack(spacing: 0) {
                                HStack {
                                    Image(systemName: "magnifyingglass").foregroundColor(.gray)
                                    TextField("Search Albums", text: $albumSearchQuery)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .foregroundColor(.white)
                                    if !albumSearchQuery.isEmpty {
                                        Button(action: { albumSearchQuery = "" }) {
                                            Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                                        }
                                    }
                                }
                                .padding(10)
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(10)
                                .padding(.horizontal, 16)
                                .padding(.top, 0)
                                .padding(.bottom, 8)
                                // RefreshControlInstaller as background puts the VC's view INSIDE
                                // the UIScrollView subtree so it can find and attach UIRefreshControl.
                                .background(
                                    RefreshControlInstaller(onRefresh: {
                                        await viewModel.loadDataAsync(connectionService: connectionService, clearData: false, forceRefresh: true)
                                    })
                                    .frame(width: 0, height: 0)
                                )
                                
                                let filteredAlbums = viewModel.albums.filter {
                                    albumSearchQuery.isEmpty ? true :
                                    $0.title.localizedCaseInsensitiveContains(albumSearchQuery) ||
                                    $0.artist.localizedCaseInsensitiveContains(albumSearchQuery)
                                }
                                
                                if viewModel.albums.isEmpty && (viewModel.isLoading || connectionService.isAutoConnecting) {
                                    LazyVGrid(columns: columns, spacing: 16) {
                                        ForEach(0..<14, id: \.self) { _ in
                                            SkeletonAlbumCard()
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.top, 4)
                                } else {
                                    LazyVGrid(columns: columns, spacing: 16) {
                                        ForEach(filteredAlbums) { album in
                                        Button(action: {
                                            if isAlbumMergeMode {
                                                withAnimation(.easeInOut(duration: 0.15)) {
                                                    if selectedMergeAlbumIds.contains(album.id) {
                                                        selectedMergeAlbumIds.remove(album.id)
                                                        if primaryMergeAlbum?.id == album.id {
                                                            primaryMergeAlbum = filteredAlbums.first { selectedMergeAlbumIds.contains($0.id) }
                                                        }
                                                        if selectedMergeAlbumIds.isEmpty {
                                                            isAlbumMergeMode = false
                                                            primaryMergeAlbum = nil
                                                        }
                                                    } else {
                                                        selectedMergeAlbumIds.insert(album.id)
                                                        if primaryMergeAlbum == nil {
                                                            primaryMergeAlbum = album
                                                        }
                                                    }
                                                }
                                            } else {
                                                selectedAlbum = album
                                                navigateToAlbumActive = true
                                            }
                                        }) {
                                            ZStack(alignment: .topTrailing) {
                                                AlbumCard(album: album)
                                                
                                                if isAlbumMergeMode {
                                                    let isSelected = selectedMergeAlbumIds.contains(album.id)
                                                    let isPrimary = primaryMergeAlbum?.id == album.id
                                                    
                                                    VStack {
                                                        HStack {
                                                            if isPrimary && selectedMergeAlbumIds.count > 1 {
                                                                Image(systemName: "star.fill")
                                                                    .font(.system(size: 9, weight: .bold))
                                                                    .foregroundColor(.white)
                                                                    .frame(width: 20, height: 20)
                                                                    .background(Color.blue)
                                                                    .clipShape(Circle())
                                                                    .shadow(color: Color.black.opacity(0.35), radius: 3)
                                                                    .padding(7)
                                                            }
                                                            Spacer()
                                                            ZStack {
                                                                if isSelected {
                                                                    Image(systemName: "checkmark.circle.fill")
                                                                        .font(.system(size: 24, weight: .semibold))
                                                                        .foregroundColor(.blue)
                                                                        .background(Circle().fill(Color.white).frame(width: 18, height: 18))
                                                                } else {
                                                                    Circle()
                                                                        .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
                                                                        .background(Circle().fill(Color.black.opacity(0.35)))
                                                                        .frame(width: 22, height: 22)
                                                                }
                                                            }
                                                            .shadow(color: Color.black.opacity(0.3), radius: 3, x: 0, y: 1)
                                                            .padding(7)
                                                        }
                                                        Spacer()
                                                    }
                                                }
                                            }
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(
                                                        isAlbumMergeMode && selectedMergeAlbumIds.contains(album.id) ? Color.blue : Color.clear,
                                                        lineWidth: 2.5
                                                    )
                                            )
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .contextMenu {
                                            if !isAlbumMergeMode {
                                                Button(action: {
                                                    if !album.tracks.isEmpty {
                                                        audioService.addToQueue(albumTitle: album.title, tracks: album.tracks)
                                                    }
                                                }) {
                                                    Label("Add to Queue", systemImage: "text.badge.plus")
                                                }
                                                
                                                Button(action: {
                                                    if !album.tracks.isEmpty {
                                                        audioService.play(tracks: album.tracks, startingAt: 0)
                                                    }
                                                }) {
                                                    Label("Play", systemImage: "play.fill")
                                                }
                                                
                                                Button(action: {
                                                    if !album.tracks.isEmpty {
                                                        audioService.state.isShuffleEnabled = true
                                                        audioService.play(tracks: album.tracks.shuffled(), startingAt: 0)
                                                    }
                                                }) {
                                                    Label("Shuffle", systemImage: "shuffle")
                                                }

                                                Button(action: {
                                                    withAnimation(.easeInOut(duration: 0.2)) {
                                                        isAlbumMergeMode = true
                                                        primaryMergeAlbum = album
                                                        selectedMergeAlbumIds = [album.id]
                                                    }
                                                }) {
                                                    Label("Merge Album...", systemImage: "arrow.combine")
                                                }
                                                if connectionService.librarySource == .local {
                                                    Button(action: {
                                                        deleteTarget = .album(album)
                                                    }) {
                                                        Label("Delete Album", systemImage: "trash")
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.top, 4)
                                }
                                }
                                
                                Color.clear.frame(height: 80)
                            }
                        }
                        .background(Color.black)
                    } else { // Artists
                        List {
                            HStack {
                                Image(systemName: "magnifyingglass").foregroundColor(.gray)
                                TextField("Search Artists", text: $artistSearchQuery)
                                .textFieldStyle(PlainTextFieldStyle())
                                .foregroundColor(.white)
                                if !artistSearchQuery.isEmpty {
                                    Button(action: { artistSearchQuery = "" }) {
                                        Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                                    }
                                }
                            }
                            .padding(10)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(10)
                            .background(
                                RefreshControlInstaller(onRefresh: {
                                    await viewModel.loadDataAsync(connectionService: connectionService, clearData: false, forceRefresh: true)
                                })
                            )
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            
                            let filteredArtists = viewModel.artists.filter {
                                artistSearchQuery.isEmpty ? true : $0.localizedCaseInsensitiveContains(artistSearchQuery)
                            }
                            ForEach(filteredArtists, id: \.self) { artist in
                                let artistTracks = viewModel.tracksForArtist(artist)
                                ZStack(alignment: .leading) {
                                    NavigationLink(destination: ArtistDetailView(artist: artist, tracks: artistTracks)) {
                                        EmptyView()
                                    }
                                    .opacity(0)
                                    
                                    VStack(alignment: .leading, spacing: 0) {
                                        HStack(spacing: 16) {
                                            ArtistImage(artistName: artist, fallbackTracks: artistTracks, size: 50)
                                            
                                            Text(artist)
                                                .font(.headline)
                                                .foregroundColor(.white)
                                            
                                            Spacer()
                                            
                                            Image(systemName: "chevron.right")
                                                .foregroundColor(.gray)
                                                .font(.footnote)
                                        }
                                        .padding(.vertical, 8)
                                        
                                        Divider().background(Color.gray.opacity(0.3))
                                    }
                                    .background(Color.black.opacity(0.01))
                                }
                                .contextMenu {
                                    Button(action: {
                                        selectedArtistForMerge = ArtistMergeTarget(artist: artist)
                                    }) {
                                        Label("Merge Artist...", systemImage: "arrow.combine")
                                    }
                                    
                                    Button(action: {
                                        if !artistTracks.isEmpty {
                                            audioService.play(tracks: artistTracks, startingAt: 0)
                                        }
                                    }) {
                                        Label("Play", systemImage: "play.fill")
                                    }
                                    
                                    Button(action: {
                                        if !artistTracks.isEmpty {
                                            audioService.play(tracks: artistTracks.shuffled(), startingAt: 0)
                                        }
                                    }) {
                                        Label("Shuffle", systemImage: "shuffle")
                                    }
                                    
                                    Button(action: {
                                        if !artistTracks.isEmpty {
                                            audioService.addToQueue(tracks: artistTracks)
                                        }
                                    }) {
                                        Label("Queue Artist", systemImage: "text.badge.plus")
                                    }
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            
                            Color.clear.frame(height: 80)
                                .listRowBackground(Color.clear)
                        }
                        .listStyle(PlainListStyle())
                        .background(Color.black)
                        .refreshableIfAvailable {
                            await viewModel.loadDataAsync(connectionService: connectionService, clearData: false, forceRefresh: true)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .id(stackId)
        .onAppear {
            guard !hasLoadedInitialData else { return }
            hasLoadedInitialData = true
            viewModel.loadData(connectionService: connectionService)
        }
        .onChange(of: connectionService.librarySource) { _ in
            // Mode changed (local ↔ remote) — always reload with fresh data
            viewModel.loadData(connectionService: connectionService, clearData: true, forceRefresh: true)
        }
        .keyboardDoneButton()
        .onChange(of: connectionService.serverURL) { _ in
            // Server URL changed — reload but don't clear so existing cache stays visible
            viewModel.loadData(connectionService: connectionService)
        }
        .onChange(of: connectionService.isConnected) { isConnected in
            if isConnected {
                viewModel.loadData(connectionService: connectionService, clearData: false, forceRefresh: false)
            }
        }

        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                connectionService.handleAppActive()
                // Library data remains loaded; no disruptive full reload on every foreground transition.
                // A fresh load is triggered if connectivity state changes (onChange isConnected below).
            }
        }
        .onChange(of: navManager.resetLibraryToAlbums) { shouldReset in
            if shouldReset {
                selectedCategory = .albums
                navManager.resetLibraryToAlbums = false
            }
        }
        .onChange(of: navManager.currentTab) { newTab in
            if newTab == "Library" {
                selectedCategory = .albums
            }
        }
        .onChange(of: navManager.requestedAlbumTitle) { title in
            guard let title = title else { return }
            if let album = viewModel.albums.first(where: { $0.title == title }) {
                selectedCategory = .albums
                selectedAlbum = album
                navigateToAlbumActive = true
            }
            navManager.requestedAlbumTitle = nil
        }
        .onChange(of: navManager.requestedArtistName) { name in
            guard let name = name else { return }
            let canonical = ArtistMergeService.shared.canonicalArtist(for: name)
            selectedCategory = .artists
            selectedArtist = canonical
            navigateToArtistActive = true
            navManager.requestedArtistName = nil
        }
        .sheet(item: $selectedAlbumForMerge) { targetAlbum in
            AlbumMergeSheet(targetAlbum: targetAlbum, allAlbums: viewModel.albums) {
                viewModel.loadData(connectionService: connectionService)
            }
        }
        .sheet(item: $selectedArtistForMerge) { target in
            ArtistMergeSheet(
                targetArtist: target.artist,
                allArtists: viewModel.artists,
                tracksForArtist: { viewModel.tracksForArtist($0) }
            ) {
                viewModel.loadData(connectionService: connectionService)
            }
        }
        .alert(item: $deleteTarget) { target in
            switch target {
            case .album(let album):
                return Alert(
                    title: Text("Delete Album"),
                    message: Text("Are you sure you want to permanently delete '\(album.title)' and all its \(album.tracks.count) songs from this device? This action cannot be undone."),
                    primaryButton: .destructive(Text("Delete")) {
                        let libraryService = MusicLibraryService(connectionService: connectionService)
                        if libraryService.deleteAlbum(album) {
                            viewModel.removeAlbumState(album)
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .track(let track):
                return Alert(
                    title: Text("Delete Song"),
                    message: Text("Are you sure you want to permanently delete '\(track.title)' from this device? This action cannot be undone."),
                    primaryButton: .destructive(Text("Delete")) {
                        let libraryService = MusicLibraryService(connectionService: connectionService)
                        if libraryService.deleteTrack(track) {
                            viewModel.removeTrackState(track)
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .playlist(let playlist):
                return Alert(
                    title: Text("Delete Playlist"),
                    message: Text("Are you sure you want to permanently delete the playlist '\(playlist.name)'? This action cannot be undone."),
                    primaryButton: .destructive(Text("Delete")) {
                        let libraryService = MusicLibraryService(connectionService: connectionService)
                        if libraryService.deletePlaylist(playlist) {
                            viewModel.removePlaylistState(playlist)
                        }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .trackDidDelete)) { notification in
            if let track = notification.object as? Track {
                viewModel.removeTrackState(track)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .albumArtworkDidUpdate)) { notification in
            if let updatedAlbum = notification.object as? Album {
                viewModel.updateAlbumArtwork(album: updatedAlbum)
                if selectedAlbum?.id == updatedAlbum.id {
                    selectedAlbum = updatedAlbum
                }
            }
        }
    }
    
    private func performInPlaceAlbumMerge() {
        let selectedAlbums = viewModel.albums.filter { selectedMergeAlbumIds.contains($0.id) }
        guard selectedAlbums.count >= 2 else { return }
        
        let primary = primaryMergeAlbum ?? selectedAlbums.first!
        let targetTitle = primary.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetArtist = primary.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        
        var members = Set<AlbumIdentifier>()
        var memberIds = Set<String>()
        
        for album in selectedAlbums {
            members.insert(AlbumIdentifier(
                title: album.title.trimmingCharacters(in: .whitespacesAndNewlines),
                artist: album.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            memberIds.insert(album.id)
        }
        
        AlbumMergeService.shared.addMergeGroup(
            members: members,
            memberAlbumIds: memberIds,
            targetTitle: targetTitle,
            targetArtist: targetArtist
        )
        
        withAnimation(.easeInOut(duration: 0.2)) {
            isAlbumMergeMode = false
            primaryMergeAlbum = nil
            selectedMergeAlbumIds.removeAll()
        }
        
        viewModel.loadData(connectionService: connectionService, forceRefresh: true)
    }
}

@MainActor class LibraryViewModel: ObservableObject {
    @Published var albums: [Album] = []
    @Published var playlists: [Playlist] = []
    @Published var artists: [String] = []
    @Published var allTracks: [Track] = []
    @Published var isLoading: Bool = false
    @Published var message: String?
    let loadingFinished = PassthroughSubject<Void, Never>()
    
    private var cancellables = Set<AnyCancellable>()
    private var isLoadInFlight: Bool = false
    private var pendingLoadTask: Task<Void, Never>? = nil
    private var debounceTask: Task<Void, Never>? = nil
    private var albumStreamingTask: Task<Void, Never>? = nil
    
    init() {
        loadCacheSynchronously()
    }
    
    func streamAlbumsProgressively(_ targetAlbums: [Album]) {
        albumStreamingTask?.cancel()
        
        // If the album counts are identical or new list is small, publish immediately
        if targetAlbums.count <= 20 || (self.albums.count == targetAlbums.count && self.albums.first?.id == targetAlbums.first?.id) {
            self.albums = targetAlbums
            return
        }
        
        // If we already had cached albums rendered, update in place without flashing empty
        if !self.albums.isEmpty {
            self.albums = targetAlbums
            return
        }
        
        // Cold start: publish the top 16 albums immediately so visible rows appear instantly
        let initialChunkSize = 16
        self.albums = Array(targetAlbums.prefix(initialChunkSize))
        
        // Stream subsequent chunks progressively down the screen without blocking
        albumStreamingTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            var currentIndex = initialChunkSize
            let chunkSize = 24
            
            while currentIndex < targetAlbums.count {
                if Task.isCancelled { return }
                // Micro-yield to allow UI run loop to render each chunk smoothly
                try? await Task.sleep(nanoseconds: 16_000_000) // ~16ms (1 frame)
                if Task.isCancelled { return }
                
                let nextIndex = Swift.min(currentIndex + chunkSize, targetAlbums.count)
                withAnimation(.none) {
                    self.albums = Array(targetAlbums.prefix(nextIndex))
                }
                currentIndex = nextIndex
            }
        }
    }
    
    func loadCacheSynchronously(serverURL: String? = nil) {
        guard albums.isEmpty else { return }
        
        // Instant synchronous fast path: load from disk cache if available
        if let cached = RemoteLibraryDiskCache.shared.load(serverURL: serverURL ?? "") {
            self.albums = cached.albums
            self.playlists = cached.playlists
            self.allTracks = cached.tracks
            let allArt = cached.albums.flatMap { $0.artist.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            self.artists = ArtistMergeService.shared.process(artists: allArt)
            self.generateSpecialPlaylists()
        }
    }
    
    func loadData(connectionService: ServerConnectionService, clearData: Bool = false, forceRefresh: Bool = false) {
        // Hydrate immediately if currently empty before any debounce fires
        if albums.isEmpty && !clearData && !forceRefresh {
            loadCacheSynchronously(serverURL: connectionService.serverURL)
        }
        
        // Debounce: cancel previous pending load and coalesce rapid calls (e.g. multiple onChange fires on startup)
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
            guard !Task.isCancelled else { return }
            await loadDataAsync(connectionService: connectionService, clearData: clearData, forceRefresh: forceRefresh)
        }
    }
    
    func loadDataAsync(connectionService: ServerConnectionService, clearData: Bool = false, forceRefresh: Bool = false) async {
        let source = connectionService.librarySource
        message = nil
        
        if clearData {
            albums = []
            playlists = []
            artists = []
            allTracks = []
            isLoading = true
        }
        
        // Fast path: load from disk cache instantly if empty
        if albums.isEmpty {
            if source == .remote {
                loadCacheSynchronously(serverURL: connectionService.serverURL)
            } else if source == .local {
                let cachedAlbums = await Task.detached(priority: .userInitiated) {
                    LocalFileLibraryScanner.shared.scanAlbums(forceRefresh: false)
                }.value
                if !cachedAlbums.isEmpty {
                    self.albums = cachedAlbums
                    let rawTracks = cachedAlbums.flatMap { $0.tracks }
                    var seenIds = Set<Int64>()
                    var uniqueTracks: [Track] = []
                    for track in rawTracks {
                        if !seenIds.contains(track.id) {
                            seenIds.insert(track.id)
                            uniqueTracks.append(track)
                        }
                    }
                    self.allTracks = uniqueTracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                    let allArt = cachedAlbums.flatMap { $0.artist.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                    self.artists = ArtistMergeService.shared.process(artists: allArt)
                    self.generateSpecialPlaylists()
                }
            }
        }
        
        // Show spinner only if we have zero cached items to display
        if albums.isEmpty {
            isLoading = true
        }
        
        if forceRefresh && source == .local {
            LocalFileLibraryScanner.shared.clearCache()
        }
        
        let service = MusicLibraryService(connectionService: connectionService)
        
        do {
            async let albumsTask = service.fetchAlbums(forceRefresh: forceRefresh).asyncValue()
            async let playlistsTask = service.fetchPlaylists(forceRefresh: forceRefresh).asyncValue()
            
            let loadedAlbums = try await albumsTask
            var loadedPlaylists = try await playlistsTask
            
            let loadedTracks: [Track]
            if source == .local {
                let rawTracks = loadedAlbums.flatMap { $0.tracks }
                var seenIds = Set<Int64>()
                var uniqueTracks: [Track] = []
                for track in rawTracks {
                    if !seenIds.contains(track.id) {
                        seenIds.insert(track.id)
                        uniqueTracks.append(track)
                    }
                }
                loadedTracks = uniqueTracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            } else {
                loadedTracks = try await service.fetchAllTracks(forceRefresh: forceRefresh).asyncValue()
            }
            
            if source == .remote {
                let hydrated = loadedPlaylists.map { playlist -> Playlist in
                    var p = playlist
                    p.tracks = playlist.songIds.compactMap { id in
                        loadedTracks.first(where: { $0.id == id })
                    }
                    return p
                }
                loadedPlaylists = hydrated
                // Persist updated remote library to disk cache
                RemoteLibraryDiskCache.shared.save(albums: loadedAlbums, playlists: loadedPlaylists, tracks: loadedTracks, serverURL: connectionService.serverURL)
            }
            
            // Suppress animation to avoid visible flash when background fetch replaces cached data
            withAnimation(.none) {
                let allArtists = loadedAlbums.flatMap { album in
                    album.artist.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                self.artists = ArtistMergeService.shared.process(artists: allArtists)
                self.allTracks = loadedTracks
                self.playlists = loadedPlaylists
                self.generateSpecialPlaylists()
            }
            
            // Progressive top-to-bottom streaming so top albums are visible immediately
            self.streamAlbumsProgressively(loadedAlbums)
            
            if loadedTracks.isEmpty {
                self.message = source == .local
                    ? "No downloaded local songs found on this device."
                    : "No songs found from the remote server."
            }
            self.isLoading = false
        } catch {
            self.isLoading = false
            if self.albums.isEmpty {
                if source == .remote {
                    self.message = "Could not connect to the remote server. Please check your network connection and server settings."
                } else {
                    self.message = error.localizedDescription
                }
            }
        }
        loadingFinished.send()
    }
    
    private func generateSpecialPlaylists() {
        // 1. Create a map of album ID/title to dateAdded
        var albumDates: [String: Date] = [:]
        for album in albums {
            if let date = album.dateAdded {
                albumDates[album.id] = date
                albumDates["\(album.title.lowercased())|\(album.artist.lowercased())"] = date
            }
        }
        
        let now = Date()
        var trackDates: [String: Date] = [:]
        var tracksWithDates: [(track: Track, date: Date)] = []
        
        for track in allTracks {
            var trackDate: Date? = track.dateAdded
            
            if trackDate == nil {
                let albumKey = "\(track.album.lowercased())|\(track.artist.lowercased())"
                trackDate = albumDates[albumKey]
            }
            
            let dateToUse = trackDate ?? Date(timeIntervalSince1970: 0)
            trackDates[track.persistentId] = dateToUse
            tracksWithDates.append((track, dateToUse))
        }
        
        let sortedTracksWithDates = tracksWithDates.sorted { $0.date > $1.date }
        
        let twoWeeksAgo = now.addingTimeInterval(-14 * 24 * 3600)
        let oneMonthAgo = now.addingTimeInterval(-30 * 24 * 3600)
        let threeMonthsAgo = now.addingTimeInterval(-90 * 24 * 3600)
        let sixMonthsAgo = now.addingTimeInterval(-180 * 24 * 3600)
        let oneYearAgo = now.addingTimeInterval(-365 * 24 * 3600)
        
        let recentByDate = sortedTracksWithDates.filter { $0.date >= twoWeeksAgo }.map { $0.track }
        let recentlyAddedTracks: [Track]
        if recentByDate.count < 20 {
            recentlyAddedTracks = Array(sortedTracksWithDates.prefix(100).map { $0.track })
        } else {
            recentlyAddedTracks = Array(recentByDate.prefix(100))
        }
        
        let monthTracks = sortedTracksWithDates.filter { $0.date >= oneMonthAgo }.map { $0.track }
        let threeMonthsTracks = sortedTracksWithDates.filter { $0.date >= threeMonthsAgo }.map { $0.track }
        let sixMonthsTracks = sortedTracksWithDates.filter { $0.date >= sixMonthsAgo }.map { $0.track }
        let yearTracks = sortedTracksWithDates.filter { $0.date >= oneYearAgo }.map { $0.track }
        
        var specialPlaylists: [Playlist] = []
        
        func sortTracksByDate(_ tracksToSort: [Track]) -> [Track] {
            return tracksToSort.sorted { lhs, rhs in
                let lhsDate = trackDates[lhs.persistentId] ?? Date(timeIntervalSince1970: 0)
                let rhsDate = trackDates[rhs.persistentId] ?? Date(timeIntervalSince1970: 0)
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
        
        if !recentlyAddedTracks.isEmpty {
            specialPlaylists.append(Playlist(
                id: -1,
                name: "Recently Added",
                songIds: recentlyAddedTracks.map { $0.id },
                tracks: sortTracksByDate(recentlyAddedTracks)
            ))
        }
        
        if !monthTracks.isEmpty {
            specialPlaylists.append(Playlist(
                id: -2,
                name: "Month",
                songIds: monthTracks.map { $0.id },
                tracks: sortTracksByDate(monthTracks)
            ))
        }
        
        if !threeMonthsTracks.isEmpty {
            specialPlaylists.append(Playlist(
                id: -3,
                name: "3 Months",
                songIds: threeMonthsTracks.map { $0.id },
                tracks: sortTracksByDate(threeMonthsTracks)
            ))
        }
        
        if !sixMonthsTracks.isEmpty {
            specialPlaylists.append(Playlist(
                id: -4,
                name: "6 Months",
                songIds: sixMonthsTracks.map { $0.id },
                tracks: sortTracksByDate(sixMonthsTracks)
            ))
        }
        
        if !yearTracks.isEmpty {
            specialPlaylists.append(Playlist(
                id: -5,
                name: "Year",
                songIds: yearTracks.map { $0.id },
                tracks: sortTracksByDate(yearTracks)
            ))
        }
        
        self.playlists.removeAll { $0.id < 0 }
        self.playlists.insert(contentsOf: specialPlaylists, at: 0)
        self.allTracks = sortTracksByDate(self.allTracks)
    }
    
    func tracksForArtist(_ artist: String) -> [Track] {
        let targetMembers = ArtistMergeService.shared.allMemberArtists(for: artist)
        return allTracks.filter { track in
            let contributors = track.artist.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return contributors.contains(where: { contributor in
                targetMembers.contains(where: { $0.localizedCaseInsensitiveCompare(contributor) == .orderedSame }) ||
                ArtistMergeService.shared.canonicalArtist(for: contributor).localizedCaseInsensitiveCompare(artist) == .orderedSame
            })
        }.sorted { lhs, rhs in
            if lhs.album != rhs.album {
                return lhs.album.localizedCaseInsensitiveCompare(rhs.album) == .orderedAscending
            }
            return Track.compareTrackOrder(lhs, rhs)
        }
    }
    
    func removeAlbumState(_ album: Album) {
        self.albums.removeAll { $0.id == album.id }
        self.allTracks.removeAll { track in
            album.tracks.contains { $0.persistentId == track.persistentId }
        }
        
        let allArtists = self.albums.flatMap { album in
            album.artist.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        self.artists = ArtistMergeService.shared.process(artists: allArtists)
    }
    
    func removeTrackState(_ track: Track) {
        self.allTracks.removeAll { $0.persistentId == track.persistentId }
        
        for idx in self.albums.indices {
            let album = self.albums[idx]
            if album.tracks.contains(where: { $0.persistentId == track.persistentId }) {
                var updatedTracks = album.tracks
                updatedTracks.removeAll { $0.persistentId == track.persistentId }
                
                if updatedTracks.isEmpty {
                    self.albums.remove(at: idx)
                } else {
                    let updatedAlbum = Album(
                        id: album.id,
                        title: album.title,
                        artist: album.artist,
                        artworkUrl: album.artworkUrl,
                        tracks: updatedTracks
                    )
                    self.albums[idx] = updatedAlbum
                }
                break
            }
        }
        
        let allArtists = self.albums.flatMap { album in
            album.artist.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        self.artists = ArtistMergeService.shared.process(artists: allArtists)
    }
    
    func updateAlbumArtwork(album: Album) {
        if let idx = self.albums.firstIndex(where: { $0.id == album.id }) {
            self.albums[idx] = album
        } else if let idx = self.albums.firstIndex(where: {
            $0.title.caseInsensitiveCompare(album.title) == .orderedSame &&
            $0.artist.caseInsensitiveCompare(album.artist) == .orderedSame
        }) {
            self.albums[idx] = album
        }
        
        for track in album.tracks {
            if let tIdx = self.allTracks.firstIndex(where: { $0.persistentId == track.persistentId }) {
                self.allTracks[tIdx].artworkUrl = album.artworkUrl
            }
        }
    }
    
    func removePlaylistState(_ playlist: Playlist) {
        self.playlists.removeAll { $0.id == playlist.id }
    }
}

// UIViewControllerRepresentable that finds the actual UINavigationController
// and hides its bar at the instance level — this removes the ~44pt safe area
// inset that NavigationView reserves even when the bar is visually hidden.
private struct NavigationBarHider: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> NavigationBarHiderVC {
        NavigationBarHiderVC()
    }
    func updateUIViewController(_ uiViewController: NavigationBarHiderVC, context: Context) {}
}

class NavigationBarHiderVC: UIViewController {
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hide()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hide()
    }
    private func hide() {
        guard let nav = navigationController else { return }
        nav.setNavigationBarHidden(true, animated: false)
        // Zero out the extra top inset the nav bar added to the child's safe area
        nav.additionalSafeAreaInsets.top = 0
    }
}

extension View {
    /// Attaches pull-to-refresh. Works correctly on SwiftUI `List` on iOS 15+.
    /// For SwiftUI `ScrollView`, use `.background(RefreshControlInstaller(...))` directly
    /// on a child view inside the scroll content instead.
    @ViewBuilder
    func refreshableIfAvailable(action: @escaping () async -> Void) -> some View {
        if #available(iOS 15.0, *) {
            self.refreshable {
                await action()
            }
        } else {
            // iOS 14: no .refreshable; callers using List should embed a
            // RefreshControlInstaller as a listRowBackground or use the albums pattern.
            self
        }
    }
    
    @ViewBuilder
    func keyboardDoneButton() -> some View {
        if #available(iOS 15.0, *) {
            self.toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .foregroundColor(.blue)
                }
            }
        } else {
            self
        }
    }
}

// MARK: - Pull-to-Refresh Infrastructure

/// A UIViewControllerRepresentable that reliably installs a UIRefreshControl on the
/// UIScrollView backing a SwiftUI ScrollView or List. Unlike UIViewRepresentable,
/// the VC's view is embedded INSIDE the scroll view's content area, so walking
/// the parent view hierarchy correctly finds the UIScrollView.
private struct RefreshControlInstaller: UIViewControllerRepresentable {
    let onRefresh: () async -> Void

    func makeCoordinator() -> RefreshCoordinator {
        RefreshCoordinator(onRefresh: onRefresh)
    }

    func makeUIViewController(context: Context) -> RefreshHostViewController {
        let vc = RefreshHostViewController()
        vc.coordinator = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: RefreshHostViewController, context: Context) {
        context.coordinator.onRefresh = onRefresh
        vc.coordinator = context.coordinator
    }
}

private final class RefreshCoordinator: NSObject {
    var onRefresh: () async -> Void
    let refreshControl = UIRefreshControl()
    private var isRefreshing = false
    private weak var installedOn: UIScrollView?

    init(onRefresh: @escaping () async -> Void) {
        self.onRefresh = onRefresh
        super.init()
        refreshControl.tintColor = .white
        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
    }

    func install(on scrollView: UIScrollView) {
        guard installedOn !== scrollView else { return }
        // Remove from previous scroll view if different
        if let prev = installedOn, prev.refreshControl === refreshControl {
            prev.refreshControl = nil
        }
        scrollView.alwaysBounceVertical = true
        scrollView.refreshControl = refreshControl
        installedOn = scrollView
    }

    @objc private func handleRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.onRefresh()
            self.refreshControl.endRefreshing()
            self.isRefreshing = false
        }
    }
}

private final class RefreshHostViewController: UIViewController {
    weak var coordinator: RefreshCoordinator?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        attachRefreshControl()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attachRefreshControl()
    }

    private func attachRefreshControl() {
        guard let coordinator = coordinator else { return }
        // Walk up from our view to find the UIScrollView that SwiftUI placed us in
        if let scrollView = findScrollView(in: view) {
            coordinator.install(on: scrollView)
            return
        }
        // Fallback: walk ancestor views from parent VC
        var ancestorView: UIView? = view.superview
        while let current = ancestorView {
            if let sv = current as? UIScrollView {
                coordinator.install(on: sv)
                return
            }
            if let sv = findScrollView(in: current) {
                coordinator.install(on: sv)
                return
            }
            ancestorView = current.superview
        }
    }

    /// BFS through subviews to find the first UIScrollView
    private func findScrollView(in root: UIView) -> UIScrollView? {
        var queue: [UIView] = [root]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if let sv = current as? UIScrollView { return sv }
            queue.append(contentsOf: current.subviews)
        }
        return nil
    }
}



extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

extension Publisher {
    func asyncValue() async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = self.first().sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        continuation.resume(throwing: error)
                    }
                    cancellable?.cancel()
                },
                receiveValue: { value in
                    continuation.resume(returning: value)
                }
            )
        }
    }
}

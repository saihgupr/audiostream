import SwiftUI
import Combine

struct SearchView: View {
    @EnvironmentObject var connectionService: ServerConnectionService
    @EnvironmentObject var audioService: AudioPlayerService
    @EnvironmentObject var navManager: NavigationManager
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    @StateObject private var viewModel = SearchViewModel()
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                        
                        TextField("Search Songs, Albums, Artists...", text: $viewModel.query)
                            .foregroundColor(.white)
                            .disableAutocorrection(true)
                        
                        if !viewModel.query.isEmpty {
                            Button(action: {
                                viewModel.query = ""
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(10)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    
                    let hasResults = !viewModel.tracks.isEmpty || !viewModel.albums.isEmpty || !viewModel.artists.isEmpty
                    if viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass.circle")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                            Text("Find your music")
                                .foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                    } else if !hasResults {
                        VStack(spacing: 10) {
                            Image(systemName: "music.note")
                                .font(.system(size: 44))
                                .foregroundColor(.gray.opacity(0.6))
                            Text("No results for “\(viewModel.query)”")
                                .foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                if !viewModel.artists.isEmpty {
                                    Text("Artists")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 16)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 14) {
                                            ForEach(viewModel.artists.prefix(20), id: \.self) { artist in
                                                Button(action: {
                                                    navManager.navigateToArtist(name: artist)
                                                }) {
                                                    VStack(spacing: 6) {
                                                        ArtistImage(
                                                            artistName: artist,
                                                            fallbackTracks: libraryViewModel.tracksForArtist(artist),
                                                            size: 64
                                                        )
                                                        Text(artist)
                                                            .font(.caption)
                                                            .foregroundColor(.white)
                                                            .lineLimit(1)
                                                            .frame(width: 72)
                                                    }
                                                }
                                                .buttonStyle(PlainButtonStyle())
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                    }
                                }

                                if !viewModel.albums.isEmpty {
                                    Text("Albums")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 16)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 12) {
                                            ForEach(viewModel.albums.prefix(20)) { album in
                                                Button(action: {
                                                    navManager.navigateToAlbum(title: album.title, artist: album.artist)
                                                }) {
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        if let url = album.artworkUrl {
                                                            RemoteImage(url: url)
                                                                .frame(width: 110, height: 110)
                                                                .cornerRadius(8)
                                                        } else {
                                                            Image(systemName: "opticaldisc")
                                                                .frame(width: 110, height: 110)
                                                                .background(Color.gray.opacity(0.25))
                                                                .foregroundColor(.gray)
                                                                .cornerRadius(8)
                                                        }
                                                        Text(album.title)
                                                            .font(.caption.weight(.semibold))
                                                            .foregroundColor(.white)
                                                            .lineLimit(1)
                                                        Text(album.artist)
                                                            .font(.caption2)
                                                            .foregroundColor(.gray)
                                                            .lineLimit(1)
                                                    }
                                                    .frame(width: 110, alignment: .leading)
                                                }
                                                .buttonStyle(PlainButtonStyle())
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                    }
                                }

                                if !viewModel.tracks.isEmpty {
                                    Text("Songs")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 16)

                                    ForEach(viewModel.tracks) { track in
                                        Button(action: {
                                            if let index = viewModel.tracks.firstIndex(where: { $0.persistentId == track.persistentId }) {
                                                audioService.play(tracks: viewModel.tracks, startingAt: index)
                                            } else {
                                                audioService.play(track: track)
                                            }
                                            withAnimation {
                                                navManager.showFullPlayer = true
                                            }
                                        }) {
                                            HStack(spacing: 12) {
                                                if let url = track.artworkUrl {
                                                    RemoteImage(url: url)
                                                        .frame(width: 48, height: 48)
                                                        .cornerRadius(6)
                                                } else {
                                                    Image(systemName: "music.note")
                                                        .frame(width: 48, height: 48)
                                                        .background(Color.gray.opacity(0.3))
                                                        .foregroundColor(.white)
                                                        .cornerRadius(6)
                                                }
                                                
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(track.title)
                                                        .foregroundColor(.white)
                                                        .lineLimit(1)
                                                    Text("\(track.artist) • \(track.album)")
                                                        .font(.caption)
                                                        .foregroundColor(.gray)
                                                        .lineLimit(1)
                                                }
                                                Spacer()
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 6)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .contextMenu {
                                            Button(action: {
                                                audioService.play(tracks: [track], startingAt: 0)
                                            }) {
                                                Label("Play", systemImage: "play.fill")
                                            }
                                            Button(action: {
                                                audioService.addToQueue(tracks: [track])
                                            }) {
                                                Label("Add to Queue", systemImage: "text.badge.plus")
                                            }
                                            Button(action: {
                                                navManager.navigateToAlbum(title: track.album, artist: track.artist)
                                            }) {
                                                Label("Go to Album", systemImage: "square.stack")
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.top, 4)
                            
                            // Spacer for Bottom Tab Bar / Mini Player
                            Color.clear.frame(height: 120)
                        }
                        .gesture(
                            DragGesture().onChanged { _ in
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            }
                        )
                    }
                }
            }
            .navigationTitle("Search")
            .keyboardDoneButton()
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            if libraryViewModel.allTracks.isEmpty && !libraryViewModel.isLoading {
                libraryViewModel.loadData(connectionService: connectionService)
            }
            viewModel.filter(
                query: viewModel.query,
                tracks: libraryViewModel.allTracks,
                albums: libraryViewModel.albums,
                artists: libraryViewModel.artists,
                immediate: true
            )
        }
        .onChange(of: viewModel.query) { newValue in
            viewModel.filter(
                query: newValue,
                tracks: libraryViewModel.allTracks,
                albums: libraryViewModel.albums,
                artists: libraryViewModel.artists
            )
        }
        .onChange(of: libraryViewModel.allTracks) { newTracks in
            viewModel.filter(
                query: viewModel.query,
                tracks: newTracks,
                albums: libraryViewModel.albums,
                artists: libraryViewModel.artists,
                immediate: true
            )
        }
    }
}

@MainActor
class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var tracks: [Track] = []
    @Published var albums: [Album] = []
    @Published var artists: [String] = []
    
    private var searchTask: Task<Void, Never>?
    
    func filter(query: String, tracks: [Track], albums: [Album], artists: [String], immediate: Bool = false) {
        searchTask?.cancel()
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanQuery.isEmpty else {
            self.tracks = []
            self.albums = []
            self.artists = []
            return
        }

        let applyFilter = { [weak self] in
            guard let self = self else { return }
            self.tracks = tracks.filter {
                $0.title.localizedCaseInsensitiveContains(cleanQuery) ||
                $0.artist.localizedCaseInsensitiveContains(cleanQuery) ||
                $0.album.localizedCaseInsensitiveContains(cleanQuery)
            }
            self.albums = albums.filter {
                $0.title.localizedCaseInsensitiveContains(cleanQuery) ||
                $0.artist.localizedCaseInsensitiveContains(cleanQuery)
            }
            self.artists = artists.filter {
                $0.localizedCaseInsensitiveContains(cleanQuery)
            }
        }

        if immediate {
            applyFilter()
            return
        }

        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            applyFilter()
        }
    }
}

import SwiftUI
import Combine

struct SearchView: View {
    @EnvironmentObject var connectionService: ServerConnectionService
    @EnvironmentObject var audioService: AudioPlayerService
    @EnvironmentObject var navManager: NavigationManager
    @StateObject private var viewModel = SearchViewModel()
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                VStack {
                    HStack {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.gray)
                            
                            TextField("Search Songs, Artists...", text: $viewModel.query)
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
                        .padding(12)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    }
                    .padding(.horizontal)
                    .padding(.top)
                    
                    if viewModel.tracks.isEmpty {
                         VStack {
                            Image(systemName: "magnifyingglass.circle")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                                .padding()
                            Text("Find your music")
                                .foregroundColor(.gray)
                        }
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Dismiss Keyboard on background tap
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(viewModel.tracks) { track in
                                    Button(action: {
                                        audioService.play(track: track)
                                        withAnimation {
                                            navManager.showFullPlayer = true
                                        }
                                    }) {
                                        HStack {
                                            if let url = track.artworkUrl {
                                                RemoteImage(url: url)
                                                    .frame(width: 50, height: 50)
                                                    .cornerRadius(6)
                                            } else {
                                                Image(systemName: "music.note")
                                                    .frame(width: 50, height: 50)
                                                    .background(Color.gray.opacity(0.3))
                                                    .cornerRadius(6)
                                            }
                                            
                                            VStack(alignment: .leading) {
                                                Text(track.title)
                                                    .foregroundColor(.white)
                                                Text(track.artist)
                                                    .font(.caption)
                                                    .foregroundColor(.gray)
                                            }
                                            Spacer()
                                        }
                                        .padding(.horizontal)
                                        .padding(.vertical, 8)
                                        .contentShape(Rectangle())
                                    }
                                }
                            }
                            
                            // Spacer for Bottom Tab Bar / Mini Player
                            Color.clear.frame(height: 120)
                        }
                        .gesture(
                            DragGesture().onChanged { _ in
                                // Dismiss Keyboard on scroll drag
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
        .onChange(of: viewModel.query) { newValue in
            viewModel.search(query: newValue, connectionService: connectionService)
        }
        .onChange(of: connectionService.librarySource) { _ in
            viewModel.search(query: viewModel.query, connectionService: connectionService)
        }
        .onReceive(NotificationCenter.default.publisher(for: .trackDidDelete)) { notification in
            if let track = notification.object as? Track {
                viewModel.tracks.removeAll { $0.persistentId == track.persistentId }
            }
        }
    }
}

class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var tracks: [Track] = []
    
    private var cancellables = Set<AnyCancellable>()
    
    func search(query: String, connectionService: ServerConnectionService) {
        guard !query.isEmpty else {
            self.tracks = []
            return
        }
        
        let service = MusicLibraryService(connectionService: connectionService)
        
        service.search(query: query)
            .sink(receiveCompletion: { [weak self] completion in
                if case .failure = completion {
                    self?.tracks = []
                }
            }, receiveValue: { [weak self] tracks in
                self?.tracks = tracks
            })
            .store(in: &cancellables)
    }
}

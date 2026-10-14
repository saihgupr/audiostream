import SwiftUI

struct ArtistDetailView: View {
    let artist: String
    @State var tracks: [Track]
    @EnvironmentObject var audioService: AudioPlayerService
    @State private var showJustAdded = false
    
    init(artist: String, tracks: [Track]) {
        self.artist = artist
        self._tracks = State(initialValue: tracks)
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 20) {
                        ArtistImage(artistName: artist, fallbackTracks: tracks, size: 90)
                            .shadow(radius: 8)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text(artist)
                                .font(.largeTitle)
                                .bold()
                                .foregroundColor(.white)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                            
                            Text("\(tracks.count) Songs")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    
                    HStack(spacing: 12) {
                        Button(action: {
                            if !tracks.isEmpty {
                                audioService.play(tracks: tracks, startingAt: 0)
                            }
                        }) {
                            HStack {
                                Image(systemName: "play.fill")
                                Text("Play")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white)
                            .foregroundColor(.black)
                            .cornerRadius(10)
                        }
                        
                        Button(action: {
                            if !tracks.isEmpty {
                                let shuffled = tracks.shuffled()
                                audioService.play(tracks: shuffled, startingAt: 0)
                            }
                        }) {
                            HStack {
                                Image(systemName: "shuffle")
                                Text("Shuffle")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.gray.opacity(0.3))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        
                        Button(action: {
                            if !tracks.isEmpty {
                                audioService.addToQueue(tracks: tracks)
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
                            .background(Color.white.opacity(0.15))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                    }
                    .padding(.top, 5)
                }
                .padding()
                
                // Track List
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(tracks) { track in
                        Button(action: {
                            if let index = tracks.firstIndex(where: { $0.persistentId == track.persistentId }) {
                                audioService.play(tracks: tracks, startingAt: index)
                            }
                        }) {
                            HStack {
                                if let current = audioService.state.currentTrack, current.persistentId == track.persistentId {
                                    Image(systemName: "speaker.wave.3.fill")
                                        .foregroundColor(.white)
                                        .frame(width: 30)
                                } else {
                                    VStack {
                                        if let url = track.artworkUrl {
                                            RemoteImage(url: url)
                                                .frame(width: 40, height: 40)
                                                .cornerRadius(4)
                                        } else {
                                            Image(systemName: "music.note")
                                                .frame(width: 40, height: 40)
                                                .background(Color.gray.opacity(0.3))
                                                .cornerRadius(4)
                                        }
                                    }
                                    .frame(width: 40)
                                }
                                
                                VStack(alignment: .leading) {
                                    Text(track.title)
                                        .foregroundColor(.white)
                                        .fontWeight(audioService.state.currentTrack?.persistentId == track.persistentId ? .bold : .regular)
                                    Text(track.album)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                Text(formatDuration(track.duration))
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            .padding()
                            .contentShape(Rectangle())
                        }
                    }
                }
                
                // Spacer for Bottom Tab Bar / Mini Player
                Color.clear.frame(height: 120)
            }
        }
        .background(Color.black.edgesIgnoringSafeArea(.all))
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: .trackDidDelete)) { notification in
            if let deletedTrack = notification.object as? Track {
                tracks.removeAll { $0.persistentId == deletedTrack.persistentId }
            }
        }
    }
    
    func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

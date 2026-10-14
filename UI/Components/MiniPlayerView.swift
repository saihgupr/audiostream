import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject var audioService: AudioPlayerService
    @Binding var expand: Bool
    var height: CGFloat = 60
    
    var body: some View {
        HStack(spacing: 0) {
            // Artwork + Info section
            HStack(spacing: 12) {
                if let track = audioService.state.currentTrack {
                    if let url = track.artworkUrl {
                        RemoteImage(url: url)
                            .frame(width: 44, height: 44)
                            .cornerRadius(6)
                            .shadow(radius: 2)
                    } else {
                        Image(systemName: "music.note")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .background(Color.gray.opacity(0.3))
                            .cornerRadius(6)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.headline)
                            .lineLimit(1)
                            .foregroundColor(.white)
                        Text(track.artist)
                            .font(.subheadline)
                            .lineLimit(1)
                            .foregroundColor(.gray)
                    }
                } else {
                    Text("Not Playing")
                        .foregroundColor(.gray)
                }
            }
            .padding(.leading, 12)
            
            Spacer()
            
            // Controls section - each with large hit targets
            HStack(spacing: 4) {
                Button(action: {
                    audioService.previous()
                }) {
                    Image(systemName: "backward.fill")
                        .font(.title3)
                        .foregroundColor(.white)
                        .frame(width: 44, height: height)
                        .contentShape(Rectangle())
                }
                
                Button(action: {
                    if audioService.state.isPlaying {
                        audioService.pause()
                    } else {
                        audioService.play()
                    }
                }) {
                    Image(systemName: audioService.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 44, height: height)
                        .contentShape(Rectangle())
                }
                
                Button(action: {
                    audioService.next()
                }) {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .foregroundColor(.white)
                        .frame(width: 44, height: height)
                        .contentShape(Rectangle())
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: height)
        .background(BlurView(style: .systemMaterialDark))
        .contentShape(Rectangle())
        .onTapGesture {
            expand = true
        }
    }
}

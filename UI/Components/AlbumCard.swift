import SwiftUI

struct AlbumCard: View {
    let album: Album
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Artwork — fills the grid cell width
            Group {
                if let url = album.artworkUrl {
                    RemoteImage(url: url)
                        .aspectRatio(1.0, contentMode: .fill)
                        .cornerRadius(10)
                        .shadow(radius: 3)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .aspectRatio(1.0, contentMode: .fill)
                        .overlay(
                            Image(systemName: "music.note")
                                .foregroundColor(.gray)
                                .font(.system(size: 26))
                        )
                        .cornerRadius(10)
                        .shadow(radius: 3)
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .foregroundColor(.white)
                
                Text(album.artist)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 2)
        }
    }
}

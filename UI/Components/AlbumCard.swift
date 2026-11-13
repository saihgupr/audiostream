import SwiftUI

struct AlbumCard: View {
    let album: Album
    
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            // Fixed 1:1 container clipped cleanly without offscreen shadow passes per card
            Color.clear
                .aspectRatio(1.0, contentMode: .fit)
                .overlay(
                    Group {
                        if let url = album.artworkUrl {
                            RemoteImage(url: url)
                                .scaledToFill()
                        } else {
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .overlay(
                                    Image(systemName: "music.note")
                                        .foregroundColor(.gray)
                                        .font(.system(size: 26))
                                )
                        }
                    }
                )
                .clipShape(shape)
                .overlay(
                    shape.stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
            
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

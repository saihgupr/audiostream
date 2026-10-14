import SwiftUI

struct SkeletonAlbumCard: View {
    @State private var isPulsing = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Artwork placeholder matching AlbumCard dimensions exactly
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(isPulsing ? 0.12 : 0.05))
                .aspectRatio(1.0, contentMode: .fill)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 26))
                        .foregroundColor(Color.white.opacity(isPulsing ? 0.2 : 0.1))
                )
            
            // Metadata placeholders matching caption & caption2 heights
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(isPulsing ? 0.12 : 0.05))
                    .frame(height: 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(isPulsing ? 0.08 : 0.03))
                    .frame(width: 80, height: 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 2)
            .padding(.top, 2)
        }
        .onAppear {
            withAnimation(Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

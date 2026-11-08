import SwiftUI

/// Incoming-session banner plus transient status toast. Applied to both the
/// library root and the full screen player so a handoff is visible wherever
/// the user happens to be.
private struct HandoffOverlay: ViewModifier {
    @EnvironmentObject var audioService: AudioPlayerService
    @EnvironmentObject var connectionService: ServerConnectionService
    @ObservedObject private var handoff = HandoffService.shared

    func body(content: Content) -> some View {
        content
            .overlay(
                VStack(spacing: 8) {
                    if let state = handoff.incoming {
                        incomingBanner(state)
                    }
                    if let message = handoff.statusMessage {
                        Text(message)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color(white: 0.18))
                            .clipShape(Capsule())
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .animation(.easeInOut(duration: 0.2)),
                alignment: .top
            )
    }

    private func incomingBanner(_ state: HandoffState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: HandoffDevice.isPad ? "iphone" : "ipad")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))

            VStack(alignment: .leading, spacing: 2) {
                Text("Continue from \(state.fromDeviceName)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(bannerSubtitle(state))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: {
                handoff.resume(state, in: audioService, connection: connectionService)
            }) {
                Text("Continue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white)
                    .clipShape(Capsule())
            }

            Button(action: { handoff.dismissIncoming() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(white: 0.16))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    private func bannerSubtitle(_ state: HandoffState) -> String {
        let title = state.queue.first(where: { $0.path == state.trackPath })?.title ?? ""
        let count = state.queue.count
        if !title.isEmpty {
            return count > 1 ? "\(title) · \(count) songs" : title
        }
        return "\(count) songs"
    }
}

extension View {
    func handoffOverlay() -> some View {
        modifier(HandoffOverlay())
    }
}

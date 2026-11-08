import SwiftUI

/// Transient handoff status toast. Applied to both the library root and the
/// full screen player so the message is visible wherever the user happens to be.
private struct HandoffOverlay: ViewModifier {
    @ObservedObject private var handoff = HandoffService.shared

    func body(content: Content) -> some View {
        content
            .overlay(
                VStack {
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
}

extension View {
    func handoffOverlay() -> some View {
        modifier(HandoffOverlay())
    }
}

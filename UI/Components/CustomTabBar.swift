import SwiftUI

struct CustomTabBar: View {
    @Binding var currentTab: String
    var onReTap: (String) -> Void = { _ in }
    
    var body: some View {
        HStack(spacing: 0) {
            TabBarButton(title: "Library", image: "house.fill", currentTab: $currentTab, onReTap: onReTap)
            TabBarButton(title: "Search", image: "magnifyingglass", currentTab: $currentTab, onReTap: onReTap)
            // TabBarButton(title: "Now Playing", image: "play.circle.fill", currentTab: $currentTab) // Now Playing is now global
            TabBarButton(title: "Settings", image: "gear", currentTab: $currentTab, onReTap: onReTap)
        }
        .padding(.top, 6)
        .padding(.bottom, 5) // Tighter bottom padding
        .background(BlurView(style: .systemChromeMaterialDark))
    }
}

struct TabBarButton: View {
    var title: String
    var image: String
    @Binding var currentTab: String
    var onReTap: (String) -> Void
    
    var body: some View {
        Button(action: {
            if currentTab == title {
                onReTap(title)
            } else {
                currentTab = title
            }
        }) {
            VStack(spacing: 4) {
                Image(systemName: image)
                    .font(.system(size: 20))
                Text(title)
                    .font(.caption)
            }
            .foregroundColor(currentTab == title ? .white : .gray)
            .frame(maxWidth: .infinity)
        }
    }
}

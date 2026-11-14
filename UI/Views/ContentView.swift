import SwiftUI

struct ContentView: View {
    @EnvironmentObject var connectionService: ServerConnectionService
    @EnvironmentObject var audioService: AudioPlayerService
    
    // Navigation State
    @StateObject private var navManager = NavigationManager()
    @StateObject private var libraryViewModel = LibraryViewModel()
    @StateObject private var quickActionManager = QuickActionManager.shared
    @State private var libraryStackId = UUID()
    @State private var searchStackId = UUID()
    @State private var settingsStackId = UUID()
    @State private var playerDragProgress: CGFloat = 0
    @State private var fullScreenHeight: CGFloat = 1000
    
    // Hide standard tab bar
    init() {
        UITabBar.appearance().isHidden = true
        // Make all ScrollViews truly transparent at UIKit level so ZStack backgrounds show through
        UIScrollView.appearance().backgroundColor = .clear
        UITableView.appearance().sectionHeaderTopPadding = 0
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithTransparentBackground()
        navAppearance.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
    }
    
    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }
    
    var body: some View {
        ZStack {
            ZStack(alignment: .bottom) {
                // Main Content Layer
                ZStack {
                    LibraryView(stackId: libraryStackId)
                        .id(libraryStackId)
                        .opacity(navManager.currentTab == "Library" ? 1.0 : 0.0)
                        .disabled(navManager.currentTab != "Library")
                    
                    SearchView()
                        .id(searchStackId)
                        .opacity(navManager.currentTab == "Search" ? 1.0 : 0.0)
                        .disabled(navManager.currentTab != "Search")
                    
                    SettingsView()
                        .id(settingsStackId)
                        .opacity(navManager.currentTab == "Settings" ? 1.0 : 0.0)
                        .disabled(navManager.currentTab != "Settings")
                }
                .background(Color.black.edgesIgnoringSafeArea(.all)) // Ensure main background is black
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Floating UI Layer (MiniPlayer + TabBar)
                VStack(spacing: 0) {
                    // Mini Player (Only show if track exists)
                    if audioService.state.currentTrack != nil {
                         MiniPlayerView(expand: $navManager.showFullPlayer)
                            .transition(.move(edge: .bottom))
                    }
                    
                    CustomTabBar(currentTab: $navManager.currentTab, onReTap: { tab in
                        if tab == "Library" {
                            libraryStackId = UUID()
                            navManager.resetLibraryToAlbums.toggle()
                        } else if tab == "Search" {
                            searchStackId = UUID()
                        } else if tab == "Settings" {
                            settingsStackId = UUID()
                        }
                    })
                }
            }
            .edgesIgnoringSafeArea(.bottom) // This allows TabBar to go to the bottom edge
            .allowsHitTesting(isPad || !navManager.showFullPlayer)
            .accessibilityHidden(!isPad && navManager.showFullPlayer)
            .zIndex(0)

            // iPhone: Overlay directly over the app so pulling down reveals the screen behind it.
            if !isPad && navManager.showFullPlayer {
                Color.black.opacity(0.45 * (1 - min(max(playerDragProgress, 0), 1)))
                    .edgesIgnoringSafeArea(.all)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .zIndex(1)

                NowPlayingView(expand: $navManager.showFullPlayer, dragProgress: $playerDragProgress)
                    .environmentObject(audioService)
                    .environmentObject(navManager)
                    .environmentObject(connectionService)
                    .transition(.offset(y: fullScreenHeight))
                    .zIndex(2)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { fullScreenHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { fullScreenHeight = $0 }
            }
            .edgesIgnoringSafeArea(.all)
        )
        .animation(.easeOut(duration: 0.28), value: navManager.showFullPlayer)
        .preferredColorScheme(.dark)
        // iPad: Full screen cover so it takes up the entire iPad screen in landscape & portrait
        .fullScreenCover(isPresented: Binding(
            get: { isPad && navManager.showFullPlayer },
            set: { navManager.showFullPlayer = $0 }
        )) {
            NowPlayingView(expand: $navManager.showFullPlayer)
                .environmentObject(audioService)
                .environmentObject(navManager)
                .environmentObject(connectionService)
        }
        .environmentObject(navManager)
        .environmentObject(libraryViewModel)
        .onAppear {
            audioService.configure(connectionService: connectionService)
            handlePendingQuickAction()
        }
        .onChange(of: navManager.showFullPlayer) { isShown in
            if isShown {
                playerDragProgress = 0
            }
        }
        .onReceive(quickActionManager.$pendingAction) { _ in
            handlePendingQuickAction()
        }
    }
    
    private func handlePendingQuickAction() {
        guard let action = quickActionManager.consumePendingAction() else { return }
        audioService.performQuickAction(action)
    }
}

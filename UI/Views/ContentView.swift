import SwiftUI

struct ContentView: View {
    @EnvironmentObject var connectionService: ServerConnectionService
    @EnvironmentObject var audioService: AudioPlayerService
    
    // Navigation State
    @StateObject private var navManager = NavigationManager()
    @State private var libraryStackId = UUID()
    @State private var searchStackId = UUID()
    @State private var settingsStackId = UUID()
    
    // Hide standard tab bar
    init() {
        UITabBar.appearance().isHidden = true
        // Make all ScrollViews truly transparent at UIKit level so ZStack backgrounds show through
        UIScrollView.appearance().backgroundColor = .clear
        if #available(iOS 15.0, *) {
            UITableView.appearance().sectionHeaderTopPadding = 0
        }
    }
    
    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }
    
    var body: some View {
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
        // iPhone: Sheet presentation with large detent and pull-down dismissal to mini player
        .sheet(isPresented: Binding(
            get: { !isPad && navManager.showFullPlayer },
            set: { navManager.showFullPlayer = $0 }
        )) {
            if #available(iOS 16.0, *) {
                NowPlayingView(expand: $navManager.showFullPlayer)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .environmentObject(audioService)
                    .environmentObject(navManager)
                    .environmentObject(connectionService)
            } else {
                NowPlayingView(expand: $navManager.showFullPlayer)
                    .environmentObject(audioService)
                    .environmentObject(navManager)
                    .environmentObject(connectionService)
            }
        }
        .environmentObject(navManager)
    }
}

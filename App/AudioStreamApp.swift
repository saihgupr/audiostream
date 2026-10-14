import SwiftUI

@main
struct AudioStreamApp: App {
    @StateObject private var connectionService = ServerConnectionService()
    @StateObject private var audioService = AudioPlayerService()
    // MusicLibraryService depends on ConnectionService, so we might need to initialize it differently 
    // or just pass connectionService to it in views for now.
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectionService)
                .environmentObject(audioService)
                .preferredColorScheme(.dark)
        }
    }
}

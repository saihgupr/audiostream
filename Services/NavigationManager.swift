import SwiftUI
import Combine

class NavigationManager: ObservableObject {
    @Published var currentTab: String = "Library"
    @Published var requestedAlbumTitle: String?
    @Published var requestedArtistName: String?
    @Published var resetLibraryToAlbums: Bool = false
    @Published var showFullPlayer: Bool = false
    
    func navigateToAlbum(title: String) {
        currentTab = "Library"
        requestedAlbumTitle = title
    }
    
    func navigateToArtist(name: String) {
        currentTab = "Library"
        requestedArtistName = name
    }
}

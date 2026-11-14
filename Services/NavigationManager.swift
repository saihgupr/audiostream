import SwiftUI
import Combine

struct AlbumNavigationTarget: Equatable {
    let title: String
    let artist: String?
}

class NavigationManager: ObservableObject {
    @Published var currentTab: String = "Library"
    @Published var requestedAlbumTarget: AlbumNavigationTarget?
    @Published var requestedArtistName: String?
    @Published var resetLibraryToAlbums: Bool = false
    @Published var showFullPlayer: Bool = false
    
    func navigateToAlbum(title: String, artist: String? = nil) {
        currentTab = "Library"
        requestedAlbumTarget = AlbumNavigationTarget(title: title, artist: artist)
    }
    
    func navigateToArtist(name: String) {
        currentTab = "Library"
        requestedArtistName = name
    }
}

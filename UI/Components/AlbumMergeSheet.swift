import SwiftUI

struct AlbumMergeSheet: View {
    @Environment(\.presentationMode) var presentationMode
    
    let targetAlbum: Album
    let allAlbums: [Album]
    let onMerge: () -> Void
    
    @State private var selectedAlbumIds = Set<String>()
    @State private var searchQuery = ""
    @State private var customTitle = ""
    @State private var customArtist = ""
    
    init(targetAlbum: Album, allAlbums: [Album], onMerge: @escaping () -> Void) {
        self.targetAlbum = targetAlbum
        self.allAlbums = allAlbums.filter { $0.id != targetAlbum.id }
        self.onMerge = onMerge
        
        _customTitle = State(initialValue: targetAlbum.title)
        _customArtist = State(initialValue: targetAlbum.artist)
    }
    
    var filteredAlbums: [Album] {
        if searchQuery.isEmpty {
            return allAlbums
        } else {
            return allAlbums.filter { album in
                album.title.localizedCaseInsensitiveContains(searchQuery) ||
                album.artist.localizedCaseInsensitiveContains(searchQuery)
            }
        }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Header Description
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Merge into '\(targetAlbum.title)'")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("Select the other split parts of this album from the list below. They will be combined into a single entry.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.horizontal)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                    
                    // Merged Metadata Settings
                    VStack(spacing: 12) {
                        HStack {
                            Text("Merged Metadata")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.gray)
                                .textCase(.uppercase)
                            Spacer()
                        }
                        .padding(.horizontal)
                        
                        VStack(spacing: 8) {
                            HStack {
                                Text("Title")
                                    .foregroundColor(.gray)
                                    .frame(width: 60, alignment: .leading)
                                TextField("Album Title", text: $customTitle)
                                    .foregroundColor(.white)
                                    .textFieldStyle(PlainTextFieldStyle())
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(8)
                            
                            HStack {
                                Text("Artist")
                                    .foregroundColor(.gray)
                                    .frame(width: 60, alignment: .leading)
                                TextField("Album Artist", text: $customArtist)
                                    .foregroundColor(.white)
                                    .textFieldStyle(PlainTextFieldStyle())
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(8)
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 16)
                    
                    // Search Bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                        TextField("Search other albums...", text: $searchQuery)
                            .foregroundColor(.white)
                            .textFieldStyle(PlainTextFieldStyle())
                        if !searchQuery.isEmpty {
                            Button(action: { searchQuery = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(10)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    
                    // Album Selection List
                    List {
                        ForEach(filteredAlbums) { album in
                            Button(action: {
                                if selectedAlbumIds.contains(album.id) {
                                    selectedAlbumIds.remove(album.id)
                                } else {
                                    selectedAlbumIds.insert(album.id)
                                }
                            }) {
                                HStack(spacing: 12) {
                                    // Checkbox
                                    Image(systemName: selectedAlbumIds.contains(album.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selectedAlbumIds.contains(album.id) ? .blue : .gray)
                                        .font(.title3)
                                    
                                    // Artwork
                                    if let url = album.artworkUrl {
                                        RemoteImage(url: url)
                                            .frame(width: 44, height: 44)
                                            .cornerRadius(6)
                                    } else {
                                        Image(systemName: "music.note")
                                            .frame(width: 44, height: 44)
                                            .background(Color.gray.opacity(0.3))
                                            .cornerRadius(6)
                                            .foregroundColor(.white)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.title)
                                            .foregroundColor(.white)
                                            .font(.body)
                                            .lineLimit(1)
                                        Text(album.artist)
                                            .foregroundColor(.gray)
                                            .font(.footnote)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    
                                    Text("\(album.tracks.count) tracks")
                                        .foregroundColor(.gray)
                                        .font(.caption)
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(PlainListStyle())
                    .background(Color.clear)
                }
            }
            .navigationBarTitle("Merge Albums", displayMode: .inline)
            .navigationBarItems(
                leading: Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                }
                .foregroundColor(.white),
                trailing: Button("Merge") {
                    performMerge()
                }
                .foregroundColor(selectedAlbumIds.isEmpty ? .gray : .white)
                .disabled(selectedAlbumIds.isEmpty)
            )
        }
        .preferredColorScheme(.dark)
    }
    
    private func performMerge() {
        guard !selectedAlbumIds.isEmpty else { return }
        
        // Build set of AlbumIdentifiers to merge
        var members = Set<AlbumIdentifier>()
        
        // Add the target/primary album
        members.insert(AlbumIdentifier(title: targetAlbum.title, artist: targetAlbum.artist))
        
        // Add selected albums
        var memberIds = selectedAlbumIds
        memberIds.insert(targetAlbum.id)
        
        for id in selectedAlbumIds {
            if let album = allAlbums.first(where: { $0.id == id }) {
                members.insert(AlbumIdentifier(title: album.title, artist: album.artist))
            }
        }
        
        // Perform merge
        AlbumMergeService.shared.addMergeGroup(
            members: members,
            memberAlbumIds: memberIds,
            targetTitle: customTitle.isEmpty ? targetAlbum.title : customTitle,
            targetArtist: customArtist.isEmpty ? targetAlbum.artist : customArtist
        )
        
        onMerge()
        presentationMode.wrappedValue.dismiss()
    }
}

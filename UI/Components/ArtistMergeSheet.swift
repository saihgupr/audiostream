import SwiftUI

struct ArtistMergeSheet: View {
    @Environment(\.presentationMode) var presentationMode
    
    let targetArtist: String
    let allArtists: [String]
    let tracksForArtist: (String) -> [Track]
    let onMerge: () -> Void
    
    @State private var selectedArtists = Set<String>()
    @State private var searchQuery = ""
    @State private var customArtist = ""
    
    init(targetArtist: String, allArtists: [String], tracksForArtist: @escaping (String) -> [Track], onMerge: @escaping () -> Void) {
        self.targetArtist = targetArtist
        self.allArtists = allArtists.filter { $0.localizedCaseInsensitiveCompare(targetArtist) != .orderedSame }
        self.tracksForArtist = tracksForArtist
        self.onMerge = onMerge
        _customArtist = State(initialValue: targetArtist)
    }
    
    var filteredArtists: [String] {
        if searchQuery.isEmpty {
            return allArtists
        } else {
            return allArtists.filter { artist in
                artist.localizedCaseInsensitiveContains(searchQuery)
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
                        Text("Merge into '\(targetArtist)'")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("Select other artist names from the list below. Their songs and albums will be combined under a single artist entry.")
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
                                Text("Artist")
                                    .foregroundColor(.gray)
                                    .frame(width: 60, alignment: .leading)
                                TextField("Artist Name", text: $customArtist)
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
                        TextField("Search other artists...", text: $searchQuery)
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
                    
                    // Artist Selection List
                    List {
                        ForEach(filteredArtists, id: \.self) { artist in
                            let artistTracks = tracksForArtist(artist)
                            Button(action: {
                                if selectedArtists.contains(artist) {
                                    selectedArtists.remove(artist)
                                } else {
                                    selectedArtists.insert(artist)
                                }
                            }) {
                                HStack(spacing: 12) {
                                    // Checkbox
                                    Image(systemName: selectedArtists.contains(artist) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selectedArtists.contains(artist) ? .blue : .gray)
                                        .font(.title3)
                                    
                                    // Artist Artwork / Avatar
                                    ArtistImage(artistName: artist, fallbackTracks: artistTracks, size: 44)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(artist)
                                            .foregroundColor(.white)
                                            .font(.body)
                                            .lineLimit(1)
                                    }
                                    
                                    Spacer()
                                    
                                    Text("\(artistTracks.count) songs")
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
            .navigationBarTitle("Merge Artists", displayMode: .inline)
            .navigationBarItems(
                leading: Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                }
                .foregroundColor(.white),
                trailing: Button("Merge") {
                    performMerge()
                }
                .foregroundColor(selectedArtists.isEmpty ? .gray : .white)
                .disabled(selectedArtists.isEmpty)
            )
        }
        .preferredColorScheme(.dark)
    }
    
    private func performMerge() {
        guard !selectedArtists.isEmpty else { return }
        
        var members = selectedArtists
        members.insert(targetArtist)
        
        let finalTarget = customArtist.trimmingCharacters(in: .whitespaces).isEmpty ? targetArtist : customArtist.trimmingCharacters(in: .whitespaces)
        
        ArtistMergeService.shared.addMergeGroup(
            members: members,
            targetArtist: finalTarget
        )
        
        onMerge()
        presentationMode.wrappedValue.dismiss()
    }
}

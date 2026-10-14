import SwiftUI

enum MergeTab: String, CaseIterable, Identifiable {
    case albums = "Albums"
    case artists = "Artists"
    
    var id: String { rawValue }
}

struct MergeManagementView: View {
    @ObservedObject var albumMergeService = AlbumMergeService.shared
    @ObservedObject var artistMergeService = ArtistMergeService.shared
    @State private var selectedTab: MergeTab = .albums
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                Picker("Merge Type", selection: $selectedTab) {
                    Text("Albums (\(albumMergeService.mergeGroups.count))").tag(MergeTab.albums)
                    Text("Artists (\(artistMergeService.mergeGroups.count))").tag(MergeTab.artists)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                
                if selectedTab == .albums {
                    if albumMergeService.mergeGroups.isEmpty {
                        VStack(spacing: 12) {
                            Spacer()
                            Image(systemName: "arrow.combine")
                                .font(.system(size: 48))
                                .foregroundColor(.gray)
                            Text("No Merged Albums")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("Long-press an album card in the library section to merge it with other albums.")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                            Spacer()
                        }
                    } else {
                        List {
                            ForEach(albumMergeService.mergeGroups) { group in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(group.targetTitle)
                                        .font(.headline)
                                        .foregroundColor(.white)
                                    Text("Artist: \(group.targetArtist)")
                                        .font(.subheadline)
                                        .foregroundColor(.gray)
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Merged from:")
                                            .font(.caption2)
                                            .fontWeight(.bold)
                                            .foregroundColor(.gray)
                                            .textCase(.uppercase)
                                        
                                        ForEach(Array(group.members), id: \.self) { member in
                                            HStack(spacing: 4) {
                                                Image(systemName: "music.note")
                                                    .font(.caption)
                                                    .foregroundColor(.blue)
                                                Text("\(member.title) — \(member.artist)")
                                                    .font(.caption)
                                                    .foregroundColor(.gray)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                                .padding(.vertical, 6)
                                .listRowBackground(Color.white.opacity(0.05))
                            }
                            .onDelete(perform: deleteAlbumMerge)
                        }
                        .listStyle(InsetGroupedListStyle())
                    }
                } else {
                    if artistMergeService.mergeGroups.isEmpty {
                        VStack(spacing: 12) {
                            Spacer()
                            Image(systemName: "person.2.slash")
                                .font(.system(size: 48))
                                .foregroundColor(.gray)
                            Text("No Merged Artists")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("Long-press an artist row in the Artists tab to merge it with other artist names.")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                            Spacer()
                        }
                    } else {
                        List {
                            ForEach(artistMergeService.mergeGroups) { group in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(group.targetArtist)
                                        .font(.headline)
                                        .foregroundColor(.white)
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Merged aliases:")
                                            .font(.caption2)
                                            .fontWeight(.bold)
                                            .foregroundColor(.gray)
                                            .textCase(.uppercase)
                                        
                                        ForEach(Array(group.members), id: \.self) { member in
                                            HStack(spacing: 4) {
                                                Image(systemName: "person.fill")
                                                    .font(.caption)
                                                    .foregroundColor(.purple)
                                                Text(member)
                                                    .font(.caption)
                                                    .foregroundColor(.gray)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                                .padding(.vertical, 6)
                                .listRowBackground(Color.white.opacity(0.05))
                            }
                            .onDelete(perform: deleteArtistMerge)
                        }
                        .listStyle(InsetGroupedListStyle())
                    }
                }
            }
        }
        .navigationTitle("Manage Merged Items")
        .preferredColorScheme(.dark)
    }
    
    private func deleteAlbumMerge(at offsets: IndexSet) {
        for index in offsets {
            let group = albumMergeService.mergeGroups[index]
            albumMergeService.removeMergeGroup(id: group.id)
        }
    }
    
    private func deleteArtistMerge(at offsets: IndexSet) {
        for index in offsets {
            let group = artistMergeService.mergeGroups[index]
            artistMergeService.removeMergeGroup(id: group.id)
        }
    }
}

import Foundation

struct ArtistMergeGroup: Codable, Identifiable, Hashable {
    let id: UUID
    var members: Set<String>
    var targetArtist: String
}

class ArtistMergeService: ObservableObject {
    static let shared = ArtistMergeService()
    
    @Published var mergeGroups: [ArtistMergeGroup] = []
    
    private let storageKey = "com.audiostream.artistMergeGroups"
    
    private init() {
        loadGroups()
        syncMergeGroupsToSharedPath()
    }
    
    func loadGroups() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            self.mergeGroups = []
            return
        }
        do {
            self.mergeGroups = try JSONDecoder().decode([ArtistMergeGroup].self, from: data)
        } catch {
            print("Error decoding artist merge groups: \(error)")
            self.mergeGroups = []
        }
    }
    
    func saveGroups() {
        do {
            let data = try JSONEncoder().encode(mergeGroups)
            UserDefaults.standard.set(data, forKey: storageKey)
            syncMergeGroupsToSharedPath()
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        } catch {
            print("Error encoding artist merge groups: \(error)")
        }
    }
    
    private func syncMergeGroupsToSharedPath() {
        let sharedMergeGroupsPath = "/tmp/audiostream_artistmergegroups.json"
        let groupsToSync = mergeGroups
        DispatchQueue.global(qos: .utility).async {
            do {
                let data = try JSONEncoder().encode(groupsToSync)
                try data.write(to: URL(fileURLWithPath: sharedMergeGroupsPath))
            } catch {
                print("Failed to sync artist merge groups: \(error)")
            }
        }
    }
    
    func addMergeGroup(members: Set<String>, targetArtist: String) {
        var combinedMembers = members
        
        // Find overlapping groups
        var remainingGroups = mergeGroups.filter { group in
            let overlaps = !group.members.isDisjoint(with: members)
            if overlaps {
                combinedMembers.formUnion(group.members)
            }
            return !overlaps
        }
        
        let newGroup = ArtistMergeGroup(
            id: UUID(),
            members: combinedMembers,
            targetArtist: targetArtist
        )
        remainingGroups.append(newGroup)
        self.mergeGroups = remainingGroups
        saveGroups()
    }
    
    func removeMergeGroup(id: UUID) {
        self.mergeGroups.removeAll { $0.id == id }
        saveGroups()
    }
    
    /// Returns the canonical target artist if the given artist is in a merge group, otherwise returns the artist itself.
    func canonicalArtist(for artist: String) -> String {
        let trimmed = artist.trimmingCharacters(in: .whitespaces)
        if let group = mergeGroups.first(where: { group in
            group.members.contains(where: { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame })
        }) {
            return group.targetArtist
        }
        return trimmed
    }
    
    /// Returns all member names associated with the given artist name if merged, otherwise just the artist name.
    func allMemberArtists(for artist: String) -> Set<String> {
        let trimmed = artist.trimmingCharacters(in: .whitespaces)
        if let group = mergeGroups.first(where: { group in
            group.targetArtist.localizedCaseInsensitiveCompare(trimmed) == .orderedSame ||
            group.members.contains(where: { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame })
        }) {
            var all = group.members
            all.insert(group.targetArtist)
            return all
        }
        return [trimmed]
    }
    
    /// Replaces member artists within a comma-separated artist string with their canonical names.
    func canonicalArtistString(for artistString: String) -> String {
        let parts = artistString.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return artistString }
        
        var canonicalParts: [String] = []
        for part in parts {
            let canonical = canonicalArtist(for: part)
            if !canonicalParts.contains(where: { $0.localizedCaseInsensitiveCompare(canonical) == .orderedSame }) {
                canonicalParts.append(canonical)
            }
        }
        return canonicalParts.joined(separator: ", ")
    }
    
    func process(artists: [String]) -> [String] {
        var uniqueArtists: [String] = []
        for artist in artists {
            let canonical = canonicalArtist(for: artist)
            if !uniqueArtists.contains(where: { $0.localizedCaseInsensitiveCompare(canonical) == .orderedSame }) {
                uniqueArtists.append(canonical)
            }
        }
        return uniqueArtists.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    
    func process(albums: [Album]) -> [Album] {
        return albums.map { album in
            let updatedArtist = canonicalArtistString(for: album.artist)
            let updatedTracks = process(tracks: album.tracks)
            return Album(
                id: album.id,
                title: album.title,
                artist: updatedArtist,
                artworkUrl: album.artworkUrl,
                tracks: updatedTracks,
                dateAdded: album.dateAdded
            )
        }
    }
    
    func process(tracks: [Track]) -> [Track] {
        return tracks.map { track in
            var updated = track
            updated.artist = canonicalArtistString(for: track.artist)
            if let albumArtist = track.albumArtist {
                updated.albumArtist = canonicalArtistString(for: albumArtist)
            }
            return updated
        }
    }
}

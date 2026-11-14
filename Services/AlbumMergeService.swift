import Foundation

struct AlbumIdentifier: Codable, Hashable {
    let title: String
    let artist: String
    
    func matches(title otherTitle: String, artist otherArtist: String) -> Bool {
        let cleanSelfTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSelfArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOtherTitle = otherTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOtherArtist = otherArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleanSelfTitle.localizedCaseInsensitiveCompare(cleanOtherTitle) == .orderedSame &&
               cleanSelfArtist.localizedCaseInsensitiveCompare(cleanOtherArtist) == .orderedSame
    }
}

struct MergeGroup: Codable, Identifiable, Hashable {
    let id: UUID
    var members: Set<AlbumIdentifier>
    var memberAlbumIds: Set<String>?
    var targetTitle: String
    var targetArtist: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case members
        case memberAlbumIds
        case targetTitle
        case targetArtist
    }
    
    init(id: UUID, members: Set<AlbumIdentifier>, memberAlbumIds: Set<String>? = nil, targetTitle: String, targetArtist: String) {
        self.id = id
        self.members = members
        self.memberAlbumIds = memberAlbumIds
        self.targetTitle = targetTitle
        self.targetArtist = targetArtist
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.members = try container.decode(Set<AlbumIdentifier>.self, forKey: .members)
        self.memberAlbumIds = try container.decodeIfPresent(Set<String>.self, forKey: .memberAlbumIds)
        self.targetTitle = try container.decode(String.self, forKey: .targetTitle)
        self.targetArtist = try container.decode(String.self, forKey: .targetArtist)
    }
}

class AlbumMergeService: ObservableObject {
    static let shared = AlbumMergeService()
    
    private struct NormalizedPair: Hashable {
        let title: String
        let artist: String
    }

    @Published var mergeGroups: [MergeGroup] = [] {
        didSet {
            rebuildLookupIndex()
        }
    }
    
    private let storageKey = "com.audiostream.albumMergeGroups"
    private let indexLock = NSLock()
    private var memberLookup: [NormalizedPair: (index: Int, group: MergeGroup)] = [:]
    
    private init() {
        loadGroups()
        rebuildLookupIndex()
        syncMergeGroupsToSharedPath()
    }
    
    func loadGroups() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            self.mergeGroups = []
            syncMergeGroupsToSharedPath()
            return
        }
        do {
            self.mergeGroups = try JSONDecoder().decode([MergeGroup].self, from: data)
        } catch {
            print("Error decoding merge groups: \(error)")
            self.mergeGroups = []
        }
        syncMergeGroupsToSharedPath()
    }
    
    func saveGroups() {
        do {
            let data = try JSONEncoder().encode(mergeGroups)
            UserDefaults.standard.set(data, forKey: storageKey)
            syncMergeGroupsToSharedPath()
            // Trigger objectWillChange manually since it's a singleton
            DispatchQueue.main.async {
                self.objectWillChange.send()
                NotificationCenter.default.post(name: .mergeGroupsDidChange, object: nil)
            }
        } catch {
            print("Error encoding merge groups: \(error)")
        }
    }
    
    private func syncMergeGroupsToSharedPath() {
        let sharedMergeGroupsPath = "/tmp/audiostream_mergegroups.json"
        let groupsToSync = mergeGroups
        DispatchQueue.global(qos: .utility).async {
            do {
                let data = try JSONEncoder().encode(groupsToSync)
                try data.write(to: URL(fileURLWithPath: sharedMergeGroupsPath))
            } catch {
                print("Failed to sync merge groups: \(error)")
            }
        }
    }
    
    func addMergeGroup(
        members: Set<AlbumIdentifier>,
        memberAlbumIds: Set<String>? = nil,
        targetTitle: String,
        targetArtist: String
    ) {
        var combinedMembers = members
        var combinedIds = memberAlbumIds ?? Set<String>()
        
        // Find overlapping groups
        var remainingGroups = mergeGroups.filter { group in
            let idOverlaps: Bool
            if let groupIds = group.memberAlbumIds, !combinedIds.isEmpty {
                idOverlaps = !groupIds.isDisjoint(with: combinedIds)
            } else {
                idOverlaps = false
            }
            
            let memberOverlaps = group.members.contains { gm in
                members.contains { m in gm.matches(title: m.title, artist: m.artist) }
            }
            
            let overlaps = idOverlaps || memberOverlaps
            if overlaps {
                combinedMembers.formUnion(group.members)
                if let gIds = group.memberAlbumIds {
                    combinedIds.formUnion(gIds)
                }
            }
            return !overlaps
        }
        
        let newGroup = MergeGroup(
            id: UUID(),
            members: combinedMembers,
            memberAlbumIds: combinedIds.isEmpty ? nil : combinedIds,
            targetTitle: targetTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            targetArtist: targetArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        remainingGroups.append(newGroup)
        self.mergeGroups = remainingGroups
        saveGroups()
    }
    
    func removeMergeGroup(id: UUID) {
        self.mergeGroups.removeAll { $0.id == id }
        saveGroups()
    }
    
    /// Replaces the current merge groups with the ones decoded from a backup file.
    @discardableResult
    func restoreGroups(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let groups = try JSONDecoder().decode([MergeGroup].self, from: data)
        self.mergeGroups = groups
        saveGroups()
        return groups.count
    }
    
    func process(albums: [Album]) -> [Album] {
        var result: [Album] = []
        var mergedIdentifiers = Set<AlbumIdentifier>()
        var mergedIds = Set<String>()
        
        for group in mergeGroups {
            // Find all albums matching the members or IDs of this group
            let matchingAlbums = albums.filter { album in
                if let ids = group.memberAlbumIds, ids.contains(album.id) {
                    return true
                }
                return group.members.contains(where: { member in
                    member.matches(title: album.title, artist: album.artist)
                })
            }
            
            guard !matchingAlbums.isEmpty else { continue }
            
            // Mark as merged
            for album in matchingAlbums {
                mergedIdentifiers.insert(AlbumIdentifier(
                    title: album.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    artist: album.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                mergedIds.insert(album.id)
            }
            
            // Combine and update tracks
            let allGroupTracks = matchingAlbums.flatMap { album -> [Track] in
                album.tracks.map { track in
                    var updated = track
                    updated.album = group.targetTitle
                    updated.artist = group.targetArtist
                    return updated
                }
            }
            
            // Deduplicate tracks (by persistentId or title+trackNumber)
            var seenTrackKeys = Set<String>()
            var uniqueTracks: [Track] = []
            for track in allGroupTracks {
                let trackKey = "\(track.persistentId)_\(track.title.lowercased())_\(track.trackNumber ?? 0)"
                if !seenTrackKeys.contains(trackKey) {
                    seenTrackKeys.insert(trackKey)
                    uniqueTracks.append(track)
                }
            }
            let sortedTracks = uniqueTracks.sorted(by: Track.compareTrackOrder)
            
            // First non-nil artwork URL
            let artworkUrl = matchingAlbums.first(where: { $0.artworkUrl != nil })?.artworkUrl
            let latestDate = matchingAlbums.compactMap { $0.dateAdded }.max()
            
            let mergedAlbum = Album(
                id: matchingAlbums.first?.id ?? UUID().uuidString,
                title: group.targetTitle,
                artist: group.targetArtist,
                artworkUrl: artworkUrl,
                tracks: sortedTracks,
                dateAdded: latestDate
            )
            result.append(mergedAlbum)
        }
        
        // Add non-merged albums
        for album in albums {
            if mergedIds.contains(album.id) { continue }
            let isMerged = mergedIdentifiers.contains(where: {
                $0.matches(title: album.title, artist: album.artist)
            })
            if !isMerged {
                result.append(album)
            }
        }
        
        return result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    
    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .caseInsensitive, locale: .current)
    }

    private func rebuildLookupIndex() {
        var lookup: [NormalizedPair: (index: Int, group: MergeGroup)] = [:]
        lookup.reserveCapacity(mergeGroups.reduce(0) { $0 + $1.members.count })

        for (index, group) in mergeGroups.enumerated() {
            for member in group.members {
                let pair = NormalizedPair(
                    title: Self.normalize(member.title),
                    artist: Self.normalize(member.artist)
                )
                if lookup[pair] == nil {
                    lookup[pair] = (index, group)
                }
            }
        }

        indexLock.lock()
        memberLookup = lookup
        indexLock.unlock()
    }

    private func lookupMergeGroup(album: String, artist: String, albumArtist: String?) -> MergeGroup? {
        let normalizedAlbum = Self.normalize(album)
        let normalizedArtist = Self.normalize(artist)
        let normalizedAlbumArtist = albumArtist.map(Self.normalize)

        indexLock.lock()
        let firstMatch = memberLookup[NormalizedPair(title: normalizedAlbum, artist: normalizedArtist)]
        let secondMatch = normalizedAlbumArtist.flatMap {
            memberLookup[NormalizedPair(title: normalizedAlbum, artist: $0)]
        }
        indexLock.unlock()

        switch (firstMatch, secondMatch) {
        case let (a?, b?):
            return a.index <= b.index ? a.group : b.group
        case let (a?, nil):
            return a.group
        case let (nil, b?):
            return b.group
        case (nil, nil):
            return nil
        }
    }

    func resolvedAlbumAndArtist(for track: Track) -> (album: String, artist: String) {
        if let group = lookupMergeGroup(album: track.album, artist: track.artist, albumArtist: track.albumArtist) {
            return (group.targetTitle, group.targetArtist)
        }
        return (track.album, track.artist)
    }

    func process(tracks: [Track]) -> [Track] {
        return tracks.map { track in
            if let group = lookupMergeGroup(album: track.album, artist: track.artist, albumArtist: track.albumArtist) {
                var updated = track
                updated.album = group.targetTitle
                updated.artist = group.targetArtist
                return updated
            }
            return track
        }
    }
}

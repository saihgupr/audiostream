import Foundation

/// Saves the app's whole preferences domain to a single plist so a device
/// restore can bring back every setting, not just the merge groups.
final class AppStateBackupService {
    static let shared = AppStateBackupService()
    static let fileName = "audiostream_appstate.plist"

    private let documents = URL(fileURLWithPath: "/var/mobile/Documents")
    private let domain = Bundle.main.bundleIdentifier ?? "com.saihgupr.audiostream"

    private init() {}

    var backupURL: URL {
        documents.appendingPathComponent(Self.fileName)
    }

    /// Copy made by the NAS restore script. The app never writes this file, so
    /// a fresh install cannot overwrite it before the user presses Restore.
    var restoreURL: URL {
        documents.appendingPathComponent("audiostream_restore.plist")
    }

    /// Writes the persistent UserDefaults domain to Documents. Automatic
    /// saves skip a fresh install so they cannot overwrite a backup that was
    /// copied back before the user pressed Restore.
    @discardableResult
    func save(force: Bool = false) -> Bool {
        guard let state = UserDefaults.standard.persistentDomain(forName: domain),
              !state.isEmpty else {
            return false
        }
        if !force && !hasMeaningfulState(state) {
            return false
        }
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: state,
                format: .binary,
                options: 0
            )
            try data.write(to: backupURL, options: .atomic)
            return true
        } catch {
            print("App state backup failed: \(error)")
            return false
        }
    }

    private func hasMeaningfulState(_ state: [String: Any]) -> Bool {
        if let url = state["RC_ServerURL"] as? String, !url.isEmpty {
            return true
        }
        if let data = state["com.audiostream.albumMergeGroups"] as? Data, !data.isEmpty {
            return true
        }
        if let data = state["com.audiostream.artistMergeGroups"] as? Data, !data.isEmpty {
            return true
        }
        return false
    }

    /// Restores every app setting and merge group. Returns nil when no backup
    /// exists, so callers can fall back to the older merge-only files.
    func restoreAll() throws -> AppStateRestoreResult? {
        let candidates = [restoreURL, backupURL]
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            let settingsCount = try restoreState(from: url)
            let albumService = AlbumMergeService.shared
            let artistService = ArtistMergeService.shared
            albumService.loadGroups()
            artistService.loadGroups()
            return AppStateRestoreResult(
                settingsCount: settingsCount,
                albumGroups: albumService.mergeGroups.count,
                artistGroups: artistService.mergeGroups.count,
                usedFullBackup: true
            )
        }

        let albumURL = documents.appendingPathComponent("audiostream_mergegroups.json")
        let artistURL = documents.appendingPathComponent("audiostream_artistmergegroups.json")
        let fileExists = FileManager.default.fileExists(atPath:)
        var restoredAny = false

        if fileExists(albumURL.path) {
            try AlbumMergeService.shared.restoreGroups(from: albumURL)
            restoredAny = true
        }
        if fileExists(artistURL.path) {
            try ArtistMergeService.shared.restoreGroups(from: artistURL)
            restoredAny = true
        }

        guard restoredAny else { return nil }
        return AppStateRestoreResult(
            settingsCount: 0,
            albumGroups: AlbumMergeService.shared.mergeGroups.count,
            artistGroups: ArtistMergeService.shared.mergeGroups.count,
            usedFullBackup: false
        )
    }

    private func restoreState(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        guard let state = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              !state.isEmpty else {
            throw AppStateBackupError.invalidFile
        }
        UserDefaults.standard.setPersistentDomain(state, forName: domain)
        UserDefaults.standard.synchronize()
        return state.count
    }
}

struct AppStateRestoreResult {
    let settingsCount: Int
    let albumGroups: Int
    let artistGroups: Int
    let usedFullBackup: Bool

    var summary: String {
        let merges = "\(albumGroups) album\(albumGroups == 1 ? "" : "s") and \(artistGroups) artist\(artistGroups == 1 ? "" : "s")"
        if usedFullBackup {
            return "Restored \(settingsCount) settings, including \(merges).\n\nClose and reopen AudioStream so the server and playback settings apply."
        }
        return "Restored \(merges). No full app backup was found, so settings were left as they are."
    }
}

enum AppStateBackupError: LocalizedError {
    case invalidFile

    var errorDescription: String? {
        "The backup file is not a valid settings plist."
    }
}

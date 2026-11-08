import Foundation
import UIKit

/// A single entry in the transferred queue. The path is relative to the
/// library root, which is the only identifier the local library and the
/// NAS server share (node IDs differ between the two).
struct HandoffQueueItem: Codable, Equatable {
    let path: String
    let title: String
    let duration: TimeInterval
}

/// Playback session handed from one device to another. Stored as an opaque
/// blob by the server, so both sides decode it with this type.
struct HandoffState: Codable, Equatable {
    static let currentVersion = 1
    static let maxAge: TimeInterval = 300

    let version: Int
    let id: String
    let fromDeviceID: String
    let fromDeviceName: String
    let createdAt: Date
    let updatedAt: Date
    let trackPath: String
    let position: TimeInterval
    let isPlaying: Bool
    let queue: [HandoffQueueItem]
    let queueIndex: Int
    let shuffle: Bool
    let repeatMode: RepeatMode
}

enum HandoffDevice {
    private static let idKey = "RC_DeviceID"

    static var id: String {
        if let existing = UserDefaults.standard.string(forKey: idKey), !existing.isEmpty {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: idKey)
        return newID
    }

    static var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    static var name: String {
        isPad ? "iPad" : "iPhone"
    }
}

extension Track {
    /// Stable cross-device key: the file path relative to the library root.
    /// Remote tracks already carry that path in `filename`; local tracks
    /// derive it from the file URL. Returns nil for tracks that only exist
    /// in the on-device iTunes library and have no file the server can see.
    var handoffPath: String? {
        if let url = streamUrl {
            if url.isFileURL {
                let root = LocalFileLibraryScanner.musicRoot.standardizedFileURL.path
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(root + "/") else { return nil }
                return String(path.dropFirst(root.count + 1))
            }
            if url.scheme == "ipod-library" {
                return nil
            }
        }

        let name = filename
        guard !name.isEmpty else { return nil }
        if name.hasPrefix("/") {
            let rootPrefix = LocalFileLibraryScanner.musicRoot.path + "/"
            guard name.hasPrefix(rootPrefix) else { return nil }
            return String(name.dropFirst(rootPrefix.count))
        }
        return name
    }
}

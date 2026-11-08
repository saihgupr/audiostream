import Foundation
import UIKit
import Combine

/// Moves the current playback session between devices through the library
/// server. The server only stores the JSON blob; all resolution happens here.
@MainActor
final class HandoffService: ObservableObject {
    static let shared = HandoffService()

    @Published var incoming: HandoffState?
    @Published var statusMessage: String?
    @Published var isBusy = false

    private weak var connection: ServerConnectionService?
    private var observer: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var dismissedID: String?
    private var resumeCancellable: AnyCancellable?
    private var statusClearWorkItem: DispatchWorkItem?

    private let session: URLSession = .shared
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private init() {}

    // MARK: - Lifecycle

    func startMonitoring(connection: ServerConnectionService) {
        self.connection = connection

        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.checkForIncoming()
                    self.startPolling()
                }
            }
        }

        if backgroundObserver == nil {
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.pollTimer?.invalidate()
                self?.pollTimer = nil
            }
        }

        Task { await checkForIncoming() }
        startPolling()
    }

    /// The receiving device is often already open when the other one sends,
    /// so a foreground check alone would miss the handoff.
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.checkForIncoming()
            }
        }
    }

    // MARK: - Sending

    func send(from player: AudioPlayerService) async {
        guard !isBusy else { return }
        guard let url = sessionURL() else {
            showStatus("Connect to the server first")
            return
        }
        guard let track = player.state.currentTrack, let trackPath = track.handoffPath else {
            showStatus("This track can't be transferred")
            return
        }

        var items: [HandoffQueueItem] = []
        for queued in player.queue {
            guard let path = queued.handoffPath else { continue }
            items.append(HandoffQueueItem(path: path, title: queued.title, duration: queued.duration))
        }
        guard let index = items.firstIndex(where: { $0.path == trackPath }) else {
            showStatus("This track can't be transferred")
            return
        }

        let now = Date()
        let snapshot = HandoffState(
            version: HandoffState.currentVersion,
            id: UUID().uuidString,
            fromDeviceID: HandoffDevice.id,
            fromDeviceName: HandoffDevice.name,
            createdAt: now,
            updatedAt: now,
            trackPath: trackPath,
            position: player.currentPlaybackPosition(),
            isPlaying: player.state.isPlaying,
            queue: items,
            queueIndex: index,
            shuffle: player.state.isShuffleEnabled,
            repeatMode: player.state.repeatMode
        )

        isBusy = true
        defer { isBusy = false }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? encoder.encode(snapshot)

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                showStatus("Couldn't reach the server")
                return
            }
            player.pause()
            showStatus("Sent to \(HandoffDevice.isPad ? "iPhone" : "iPad")")
        } catch {
            showStatus("Couldn't reach the server")
        }
    }

    // MARK: - Receiving

    func checkForIncoming() async {
        guard let url = sessionURL() else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let state = try decoder.decode(HandoffState.self, from: data)
            guard state.version == HandoffState.currentVersion,
                  state.fromDeviceID != HandoffDevice.id,
                  Date().timeIntervalSince(state.updatedAt) < HandoffState.maxAge,
                  state.id != dismissedID else {
                return
            }
            incoming = state
        } catch {
            // No pending session, or the server is unreachable. Nothing to show.
        }
    }

    func resume(_ state: HandoffState, in player: AudioPlayerService, connection: ServerConnectionService) {
        let library = MusicLibraryService(connectionService: connection)

        resumeCancellable = library.fetchAllTracks(forceRefresh: false)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] completion in
                guard let self else { return }
                if case .failure = completion {
                    self.showStatus("Couldn't load your library")
                }
                self.resumeCancellable = nil
            }, receiveValue: { [weak self] tracks in
                guard let self else { return }
                self.apply(state, tracks: tracks, player: player)
                self.resumeCancellable = nil
            })
    }

    func dismissIncoming() {
        if let incoming {
            dismissedID = incoming.id
        }
        incoming = nil
    }

    private func apply(_ state: HandoffState, tracks: [Track], player: AudioPlayerService) {
        var byPath: [String: Track] = [:]
        for track in tracks {
            guard let path = track.handoffPath, byPath[path] == nil else { continue }
            byPath[path] = track
        }

        guard byPath[state.trackPath] != nil else {
            showStatus("That song isn't in this device's library")
            dismissIncoming()
            return
        }

        var resolved: [Track] = []
        var resolvedIndex = 0
        for item in state.queue {
            guard let track = byPath[item.path] else { continue }
            if item.path == state.trackPath {
                resolvedIndex = resolved.count
            }
            resolved.append(track)
        }

        guard !resolved.isEmpty else {
            showStatus("None of those songs are on this device")
            dismissIncoming()
            return
        }

        player.applyHandoff(
            queue: resolved,
            index: resolvedIndex,
            position: state.position,
            shuffle: state.shuffle,
            repeatMode: state.repeatMode,
            autoplay: true
        )

        dismissedID = state.id
        incoming = nil
        showStatus("Continuing from \(state.fromDeviceName)")
        Task { await deleteSession() }
    }

    // MARK: - Helpers

    private func sessionURL() -> URL? {
        guard let connection, !connection.serverURL.isEmpty,
              let base = URL(string: connection.serverURL) else { return nil }
        return base.appendingPathComponent("api/session")
    }

    private func deleteSession() async {
        guard let url = sessionURL() else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 3
        _ = try? await session.data(for: request)
    }

    private func showStatus(_ message: String) {
        statusMessage = message
        statusClearWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard self?.statusMessage == message else { return }
            self?.statusMessage = nil
        }
        statusClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: workItem)
    }
}

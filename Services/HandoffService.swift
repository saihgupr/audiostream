import Foundation
import UIKit
import Combine

/// Moves the current playback session between devices through the library
/// server. The server only stores the JSON blob; all resolution happens here.
@MainActor
final class HandoffService: ObservableObject {
    static let shared = HandoffService()

    @Published var statusMessage: String?
    @Published var isBusy = false

    private weak var connection: ServerConnectionService?
    private weak var player: AudioPlayerService?
    private var observer: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var pollTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var lastSeq: UInt64 = 0
    private var retryDelay: TimeInterval = 2
    private var dismissedID: String?
    private var applyingID: String?
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

    func startMonitoring(connection: ServerConnectionService, player: AudioPlayerService) {
        self.connection = connection
        self.player = player

        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.refreshNow()
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
                self?.stopPolling()
            }
        }

        Task { @MainActor in
            await refreshNow()
            startPolling()
        }
    }

    /// Long poll: the server holds the request open until the session
    /// changes, so a handoff shows up in well under a second instead of
    /// waiting for the next timer tick.
    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.waitForChange()
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func waitForChange() async {
        guard let base = sessionURL() else {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return
        }

        guard lastSeq != 0 else {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refreshNow()
            return
        }

        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "seq", value: String(lastSeq))]
        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 35

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            retryDelay = 2
            updateSeq(from: http)
            if http.statusCode == 200 {
                present(data)
            }
        } catch {
            // Server asleep or off the network: back off instead of hammering
            // it every couple of seconds while the app is open.
            try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            retryDelay = min(retryDelay * 2, 30)
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
            showStatus("Sent to \(HandoffDevice.isPad ? "iPhone" : "iPad")")

            // Keep playing briefly so the other device has a moment to start
            // before this one goes quiet, instead of a gap at the switch.
            schedulePause(of: player)
        } catch {
            showStatus("Couldn't reach the server")
        }
    }

    /// Stops this device a moment after the transfer, giving the receiving
    /// device time to start so the switch isn't audible as a gap.
    private func schedulePause(of player: AudioPlayerService) {
        pauseTask?.cancel()
        pauseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            player.pause()
            self?.pauseTask = nil
        }
    }

    // MARK: - Receiving

    func refreshNow() async {
        guard let url = sessionURL() else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            updateSeq(from: http)
            if http.statusCode == 200 {
                present(data)
            }
        } catch {
            // No pending session, or the server is unreachable. Nothing to show.
        }
    }

    private func present(_ data: Data) {
        guard let state = try? decoder.decode(HandoffState.self, from: data) else { return }
        guard state.version == HandoffState.currentVersion,
              state.fromDeviceID != HandoffDevice.id,
              Date().timeIntervalSince(state.updatedAt) < HandoffState.maxAge,
              state.id != dismissedID,
              state.id != applyingID,
              let player,
              let connection else {
            return
        }
        applyingID = state.id
        resume(state, in: player, connection: connection)
    }

    private func updateSeq(from response: HTTPURLResponse) {
        if let raw = response.value(forHTTPHeaderField: "X-Session-Seq"), let value = UInt64(raw) {
            lastSeq = value
        } else {
            // Server without long-poll support: fall back to short polling.
            lastSeq = 0
        }
    }

    func resume(_ state: HandoffState, in player: AudioPlayerService, connection: ServerConnectionService) {
        let library = MusicLibraryService(connectionService: connection)

        resumeCancellable = library.fetchAllTracks(forceRefresh: false)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] completion in
                guard let self else { return }
                if case .failure = completion {
                    self.applyingID = nil
                    self.showStatus("Couldn't load your library")
                }
                self.resumeCancellable = nil
            }, receiveValue: { [weak self] tracks in
                guard let self else { return }
                self.apply(state, tracks: tracks, player: player)
                self.resumeCancellable = nil
            })
    }

    private func apply(_ state: HandoffState, tracks: [Track], player: AudioPlayerService) {
        defer { applyingID = nil }

        var byPath: [String: Track] = [:]
        for track in tracks {
            guard let path = track.handoffPath, byPath[path] == nil else { continue }
            byPath[path] = track
        }

        guard byPath[state.trackPath] != nil else {
            dismissedID = state.id
            showStatus("That song isn't in this device's library")
            Task { await deleteSession() }
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
            dismissedID = state.id
            showStatus("None of those songs are on this device")
            Task { await deleteSession() }
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

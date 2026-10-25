import Foundation
import AVFoundation
import MediaPlayer
import Combine

@_silgen_name("notify_register_dispatch")
func notify_register_dispatch(
    _ name: UnsafePointer<CChar>,
    _ token: UnsafeMutablePointer<Int32>,
    _ queue: DispatchQueue,
    _ handler: @escaping @convention(block) (Int32) -> Void
) -> UInt32

class AudioPlayerService: ObservableObject {
    @Published var state = PlaybackState()
    
    @Published var queue: [Track] = []
    @Published var queueIndex: Int = 0
    private var originalQueue: [Track] = []
    @Published var queuedAlbumTitles: Set<String> = []
    
    private var librarySource: LibrarySource {
        let sourceString = UserDefaults.standard.string(forKey: "RC_LibrarySource") ?? LibrarySource.local.rawValue
        return LibrarySource(rawValue: sourceString) ?? .local
    }
    
    private var serverURL: String {
        return UserDefaults.standard.string(forKey: "RC_ServerURL") ?? ""
    }
    
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var artworkTask: URLSessionDataTask?
    
    // Artwork caching to prevent stale album art in Control Center
    private var currentArtwork: MPMediaItemArtwork?
    private var currentArtworkTrackId: Int64?
    private var lastRequestedArtworkTrackId: Int64?
    
    init() {
        let showVolume = UserDefaults.standard.bool(forKey: "RC_ShowVolumeSlider")
        if showVolume {
            let savedVolume = UserDefaults.standard.object(forKey: "audio_player_volume") as? Float ?? 1.0
            state.volume = savedVolume
        } else {
            state.volume = 1.0
        }
        configureAudioSession()
        setupRemoteCommandCenter()
        setupDarwinCommandListeners()
    }
    
    // MARK: - Audio Session
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP])
            try AVAudioSession.sharedInstance().setActive(true)
            UIApplication.shared.beginReceivingRemoteControlEvents()
            setupAudioSessionObservers()
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
    
    private var isBatterySaverEnabled: Bool {
        if UserDefaults.standard.object(forKey: "RC_BatterySaverMode") == nil {
            return true // Default enabled
        }
        return UserDefaults.standard.bool(forKey: "RC_BatterySaverMode")
    }
    
    private func setupAudioSessionObservers() {
        // 1. Audio Interruptions (e.g. phone call, Siri)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        
        // 2. Route Changes (e.g. AirPods returned to case, Bluetooth disconnect)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }
    
    @objc private func handleAudioSessionInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            print("[AudioSession] Interruption began. Pausing playback.")
            DispatchQueue.main.async { [weak self] in
                self?.pause()
            }
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                print("[AudioSession] Interruption ended with shouldResume. Resuming playback.")
                DispatchQueue.main.async { [weak self] in
                    self?.play()
                }
            } else {
                print("[AudioSession] Interruption ended without shouldResume.")
            }
        @unknown default:
            break
        }
    }
    
    @objc private func handleAudioSessionRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .oldDeviceUnavailable:
            // Headphones/AirPods or Bluetooth device disconnected
            if isBatterySaverEnabled {
                print("[AudioSession] Route change: old device unavailable (headphones/BT disconnected). Battery saver active -> pausing playback.")
                DispatchQueue.main.async { [weak self] in
                    self?.pause()
                }
            } else {
                print("[AudioSession] Route change: old device unavailable, but Battery Saver Mode is OFF.")
            }
        default:
            break
        }
    }
    
    // MARK: - Remote Commands
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Enable and configure play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        
        // Enable and configure pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        
        // Enable and configure next track command
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }
        
        // Enable and configure previous track command
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
        
        // Enable and configure toggle play/pause command
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            if self?.state.isPlaying == true {
                self?.pause()
            } else {
                self?.play()
            }
            return .success
        }
        
        // Feedback commands (exposed under the Apple Watch "..." More menu)
        // 1. Queue Album (likeCommand -> "Play More Like This" on watchOS)
        commandCenter.likeCommand.isEnabled = true
        commandCenter.likeCommand.localizedTitle = "Queue Album"
        commandCenter.likeCommand.localizedShortTitle = "Queue Album"
        commandCenter.likeCommand.addTarget { [weak self] _ in
            print("[RemoteCommand] likeCommand (Play More Like This) triggered -> Queue Album")
            DispatchQueue.main.async {
                self?.handleQueueAlbumCommand()
            }
            return .success
        }
        
        // 2. Queue Artist (bookmarkCommand -> "Bookmark" on watchOS)
        commandCenter.bookmarkCommand.isEnabled = true
        commandCenter.bookmarkCommand.localizedTitle = "Queue Artist"
        commandCenter.bookmarkCommand.localizedShortTitle = "Queue Artist"
        commandCenter.bookmarkCommand.addTarget { [weak self] _ in
            print("[RemoteCommand] bookmarkCommand (Bookmark) triggered -> Queue Artist")
            DispatchQueue.main.async {
                self?.handleQueueArtistCommand()
            }
            return .success
        }
        
        // 3. Shuffle All (dislikeCommand -> "Play Less Like This" on watchOS)
        commandCenter.dislikeCommand.isEnabled = true
        commandCenter.dislikeCommand.localizedTitle = "Shuffle All"
        commandCenter.dislikeCommand.localizedShortTitle = "Shuffle All"
        commandCenter.dislikeCommand.addTarget { [weak self] _ in
            print("[RemoteCommand] dislikeCommand (Play Less Like This) triggered -> Shuffle All")
            DispatchQueue.main.async {
                self?.handleShuffleAllCommand()
            }
            return .success
        }
        
        // Shuffle Mode Command
        commandCenter.changeShuffleModeCommand.isEnabled = true
        commandCenter.changeShuffleModeCommand.currentShuffleType = state.isShuffleEnabled ? .items : .off
        commandCenter.changeShuffleModeCommand.addTarget { [weak self] event in
            print("[RemoteCommand] changeShuffleModeCommand triggered")
            guard let self = self else { return .commandFailed }
            DispatchQueue.main.async {
                if let shuffleEvent = event as? MPChangeShuffleModeCommandEvent {
                    switch shuffleEvent.shuffleType {
                    case .off:
                        if self.state.isShuffleEnabled { self.toggleShuffle() }
                    case .items, .collections:
                        if !self.state.isShuffleEnabled { self.toggleShuffle() }
                    @unknown default:
                        self.toggleShuffle()
                    }
                } else {
                    self.toggleShuffle()
                }
                MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType = self.state.isShuffleEnabled ? .items : .off
                self.updateNowPlayingInfo()
            }
            return .success
        }
        
        // Repeat Mode Command
        commandCenter.changeRepeatModeCommand.isEnabled = true
        switch state.repeatMode {
        case .off: commandCenter.changeRepeatModeCommand.currentRepeatType = .off
        case .one: commandCenter.changeRepeatModeCommand.currentRepeatType = .one
        case .all: commandCenter.changeRepeatModeCommand.currentRepeatType = .all
        }
        commandCenter.changeRepeatModeCommand.addTarget { [weak self] event in
            print("[RemoteCommand] changeRepeatModeCommand triggered")
            guard let self = self else { return .commandFailed }
            DispatchQueue.main.async {
                if let repeatEvent = event as? MPChangeRepeatModeCommandEvent {
                    switch repeatEvent.repeatType {
                    case .off:
                        self.state.repeatMode = .off
                    case .one:
                        self.state.repeatMode = .one
                    case .all:
                        self.state.repeatMode = .all
                    @unknown default:
                        self.cycleRepeatMode()
                    }
                } else {
                    self.cycleRepeatMode()
                }
                switch self.state.repeatMode {
                case .off: MPRemoteCommandCenter.shared().changeRepeatModeCommand.currentRepeatType = .off
                case .one: MPRemoteCommandCenter.shared().changeRepeatModeCommand.currentRepeatType = .one
                case .all: MPRemoteCommandCenter.shared().changeRepeatModeCommand.currentRepeatType = .all
                }
                self.updateNowPlayingInfo()
            }
            return .success
        }
        
        // Scrubber / Position Command
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            DispatchQueue.main.async {
                self?.seek(to: positionEvent.positionTime)
            }
            return .success
        }
    }
    
    // MARK: - Playback Control
    func play(tracks: [Track], startingAt index: Int) {
        originalQueue = tracks
        state.repeatMode = .all // Default to loop playback when starting an album/queue
        if state.isShuffleEnabled {
            let currentTrack = tracks[index]
            var remainingTracks = tracks
            remainingTracks.remove(at: index)
            queue = [currentTrack] + remainingTracks.shuffled()
            queueIndex = 0
        } else {
            queue = tracks
            queueIndex = index
        }
        
        // Clear previously queued album titles on new selection
        queuedAlbumTitles.removeAll()
        
        loadTrack(at: queueIndex)
    }
    
    private func setQueueWithNewTracks(_ tracks: [Track], currentTrack: Track, shuffle: Bool = false) {
        debugLog("setQueueWithNewTracks called with \(tracks.count) tracks, currentTrack='\(currentTrack.title)' (persistentId: '\(currentTrack.persistentId)'), shuffle=\(shuffle)")
        
        self.originalQueue = tracks
        self.state.repeatMode = .all // Default to loop playback when setting new queue
        
        if shuffle || self.state.isShuffleEnabled {
            // Shuffle EXCEPT the current track, which goes to index 0
            var remainingTracks = tracks
            remainingTracks.removeAll { $0.persistentId == currentTrack.persistentId }
            self.queue = [currentTrack] + remainingTracks.shuffled()
            self.queueIndex = 0
        } else {
            self.queue = tracks
            if let index = tracks.firstIndex(where: { $0.persistentId == currentTrack.persistentId }) {
                self.queueIndex = index
            } else {
                debugLog("setQueueWithNewTracks: currentTrack persistentId '\(currentTrack.persistentId)' not found in tracks! Resetting queueIndex to 0.")
                self.queueIndex = 0
            }
        }
        
        // Add current album to queued titles for UI feedback
        self.queuedAlbumTitles.insert(currentTrack.album)
        debugLog("setQueueWithNewTracks finished: New queue size=\(self.queue.count), active queueIndex=\(self.queueIndex)")
        print("New queue size: \(self.queue.count), active index: \(self.queueIndex)")
        updateNowPlayingInfo()
    }
    
    func play(track: Track) {
        // Legacy/Single track support - creates a single item queue
        play(tracks: [track], startingAt: 0)
    }
    
    func removeTrackFromQueue(track: Track) {
        let isCurrentTrack = (state.currentTrack?.persistentId == track.persistentId)
        
        // Remove from current queue
        var removedIndex: Int? = nil
        if let idx = queue.firstIndex(where: { $0.persistentId == track.persistentId }) {
            removedIndex = idx
            queue.remove(at: idx)
        }
        
        // Remove from originalQueue
        originalQueue.removeAll { $0.persistentId == track.persistentId }
        
        if isCurrentTrack {
            if queue.isEmpty {
                // No tracks left, reset state
                player?.pause()
                player = nil
                state.currentTrack = nil
                state.isPlaying = false
                state.currentTime = 0
                state.duration = 0
                updateNowPlayingInfo()
            } else {
                // If there are tracks left, adjust queueIndex and load next
                if let idx = removedIndex {
                    if idx < queue.count {
                        // Play the track that took its place
                        queueIndex = idx
                        loadTrack(at: queueIndex)
                    } else {
                        // If it was the last track, play the new last track
                        queueIndex = queue.count - 1
                        loadTrack(at: queueIndex)
                    }
                }
            }
        } else {
            // Adjust queueIndex if the deleted track was before the currently playing track
            if let idx = removedIndex, queueIndex > idx {
                queueIndex -= 1
            }
        }
    }
    
    private func loadTrack(at index: Int) {
        debugLog("loadTrack(at: \(index)) called. queueIndex=\(queueIndex), queue.count=\(queue.count)")
        guard index >= 0 && index < queue.count else {
            debugLog("loadTrack(at: \(index)) FAILED: index out of bounds [0..<\(queue.count)]")
            return
        }
        let track = queue[index]
        state.currentTrack = track
        debugLog("loadTrack(at: \(index)) active track set: '\(track.title)' (persistentId: '\(track.persistentId)')")
        
        // Reset artwork tracking for the new track
        currentArtwork = nil
        currentArtworkTrackId = nil
        
        // Remove from persistent queue feedback once it starts playing
        queuedAlbumTitles.remove(track.album)
        
        guard let url = track.streamUrl else {
            debugLog("loadTrack(at: \(index)) FAILED: No stream URL for track '\(track.title)'")
            print("Error: No stream URL for track")
            return
        }
        
        let playerItem = AVPlayerItem(url: url)
        
        // Notify player change if needed, or just replace current item
        // For AVPlayer, replaceCurrentItem is better if player exists
        if player == nil {
            let newPlayer = AVPlayer(playerItem: playerItem)
            newPlayer.allowsExternalPlayback = false
            player = newPlayer
        } else {
            player?.allowsExternalPlayback = false
            player?.replaceCurrentItem(with: playerItem)
        }
        let showVolume = UserDefaults.standard.bool(forKey: "RC_ShowVolumeSlider")
        player?.volume = showVolume ? state.volume : 1.0
        
        // Ensure we stop old observer
        stopObservingTime()
        
        play()
        
        // Observe for end of track to auto-advance
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(playerDidFinishPlaying), name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
    }
    
    @objc func playerDidFinishPlaying(note: NSNotification) {
        if state.repeatMode == .one {
            loadTrack(at: queueIndex)
        } else if queueIndex < queue.count - 1 {
            next()
        } else if state.repeatMode == .all {
            queueIndex = 0
            loadTrack(at: queueIndex)
        } else {
            state.isPlaying = false
        }
    }
    
    func play() {
        player?.play()
        state.isPlaying = true
        startObservingTime()
        updateNowPlayingInfo()
    }
    
    func seek(to time: TimeInterval) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 1))
        updateNowPlayingInfo()
    }
    
    func pause() {
        player?.pause()
        state.isPlaying = false
        stopObservingTime()
        updateNowPlayingInfo()
    }
    
    func setVolume(_ volume: Float) {
        state.volume = volume
        player?.volume = volume
        UserDefaults.standard.set(volume, forKey: "audio_player_volume")
    }
    
    func next() {
        debugLog("next() called. current queueIndex=\(queueIndex), queue.count=\(queue.count), repeatMode=\(state.repeatMode)")
        if queueIndex < queue.count - 1 {
            queueIndex += 1
            loadTrack(at: queueIndex)
        } else if state.repeatMode == .all {
            queueIndex = 0
            loadTrack(at: queueIndex)
        } else {
            debugLog("next() did not advance: Already at end of queue (\(queueIndex + 1)/\(queue.count))")
            print("Already at end of queue (\(queueIndex + 1)/\(queue.count))")
        }
    }
    
    func previous() {
        // If within first 3 seconds, go to previous track, otherwise restart
        if let currentTime = player?.currentTime().seconds, currentTime > 3.0 {
            player?.seek(to: .zero)
            updateNowPlayingInfo()
        } else if queueIndex > 0 {
            queueIndex -= 1
            loadTrack(at: queueIndex)
        } else if state.repeatMode == .all {
            queueIndex = queue.count - 1
            loadTrack(at: queueIndex)
        }
    }
    
    func toggleShuffle() {
        state.isShuffleEnabled.toggle()
        let currentTrack = state.currentTrack
        
        if state.isShuffleEnabled {
            // Shuffle EXCEPT the current track
            var newQueue = queue
            if let current = currentTrack {
                newQueue.removeAll { $0.persistentId == current.persistentId }
                queue = [current] + newQueue.shuffled()
                queueIndex = 0
            } else {
                queue = queue.shuffled()
                queueIndex = 0
            }
        } else {
            // Restore original order
            queue = originalQueue
            if let current = currentTrack {
                if let index = queue.firstIndex(where: { $0.persistentId == current.persistentId }) {
                    queueIndex = index
                }
            }
        }
        updateNowPlayingInfo()
    }
    
    func cycleRepeatMode() {
        switch state.repeatMode {
        case .off: state.repeatMode = .all
        case .all: state.repeatMode = .one
        case .one: state.repeatMode = .off
        }
        updateNowPlayingInfo()
    }
    
    func addToQueue(albumTitle: String, tracks: [Track]) {
        print("Adding album '\(albumTitle)' (\(tracks.count) tracks) to queue. Current queue size: \(queue.count), current index: \(queueIndex)")
        state.isShuffleEnabled = false // Default to unshuffled playback when queuing an album
        state.repeatMode = .all // Default to loop playback when queuing an album
        var newTracks = tracks
        
        // If the currently playing track is the first song of the queued album, skip that first song
        if let current = state.currentTrack, let firstTrack = newTracks.first,
           current.persistentId == firstTrack.persistentId ||
           (current.title.localizedCaseInsensitiveCompare(firstTrack.title) == .orderedSame &&
            current.album.localizedCaseInsensitiveCompare(firstTrack.album) == .orderedSame) {
            if newTracks.count > 1 {
                newTracks.removeFirst()
                print("Current track '\(current.title)' is the first song of queued album, skipping first song")
            }
        }
        
        guard !newTracks.isEmpty else { return }
        
        // Insert tracks AFTER the current song, not at the end
        // This way, pressing "Next" will immediately go to the queued album
        let insertIndex = queueIndex + 1
        queue.insert(contentsOf: newTracks, at: insertIndex)
        originalQueue.insert(contentsOf: newTracks, at: insertIndex)
        queuedAlbumTitles.insert(albumTitle)
        print("New queue size: \(queue.count), queued album will start at index \(insertIndex)")
        
        // If nothing is playing, start playing the first newly added track
        if state.currentTrack == nil {
            print("Nothing playing, starting first new track")
            play(tracks: queue, startingAt: queue.count - newTracks.count)
        } else if !state.isPlaying && queueIndex >= queue.count - newTracks.count - 1 {
            // If we reached the end and stopped, but now have more songs,
            // we don't auto-play (traditional behavior), but the user expects "Next" to work.
            // The next() call will now see that queueIndex < queue.count - 1.
            print("At end of queue, tracks added. Next call should work.")
        }
        updateNowPlayingInfo()
    }
    
    func addToQueue(tracks: [Track]) {
        print("Adding \(tracks.count) tracks to queue. Current queue size: \(queue.count), current index: \(queueIndex)")
        state.repeatMode = .all // Default to loop playback when queuing tracks
        let newTracks = tracks
        
        let insertIndex = queueIndex + 1
        queue.insert(contentsOf: newTracks, at: insertIndex)
        originalQueue.insert(contentsOf: newTracks, at: insertIndex)
        print("New queue size: \(queue.count), queued tracks will start at index \(insertIndex)")
        
        if state.currentTrack == nil {
            print("Nothing playing, starting first new track")
            play(tracks: queue, startingAt: queue.count - newTracks.count)
        } else if !state.isPlaying && queueIndex >= queue.count - newTracks.count - 1 {
            print("At end of queue, tracks added. Next call should work.")
        }
        updateNowPlayingInfo()
    }
    
    // MARK: - Home Screen Quick Actions
    
    func performQuickAction(_ action: QuickAction) {
        switch action {
        case .shuffleAll:
            handleShuffleAllCommand()
        case .recentlyAdded:
            handlePlayPlaylistCommand(name: "Recently Added", shuffle: true)
        case .queueAlbum:
            handleQueueAlbumCommand()
        case .queueArtist:
            handleQueueArtistCommand()
        }
    }
    
    // MARK: - Remote Control (Darwin Notifications)
    
    private var commandCancellables = Set<AnyCancellable>()
    private var queueAlbumToken: Int32 = -1
    private var queueArtistToken: Int32 = -1
    private var shuffleAllToken: Int32 = -1
    private var playPlaylistToken: Int32 = -1
    private var deleteSongToken: Int32 = -1
    
    private func setupDarwinCommandListeners() {
        var albumToken: Int32 = -1
        let albumStatus = notify_register_dispatch(
            "com.saihgupr.audiostream.queuealbum",
            &albumToken,
            DispatchQueue.main
        ) { [weak self] _ in
            self?.handleQueueAlbumCommand()
        }
        if albumStatus == 0 { // NOTIFY_STATUS_OK
            queueAlbumToken = albumToken
            print("[AudioReceiver] Registered for queuealbum notifications (token=\(albumToken))")
        } else {
            print("[AudioReceiver] Failed to register for queuealbum notifications (status=\(albumStatus))")
        }
        
        var artistToken: Int32 = -1
        let artistStatus = notify_register_dispatch(
            "com.saihgupr.audiostream.queueartist",
            &artistToken,
            DispatchQueue.main
        ) { [weak self] _ in
            self?.handleQueueArtistCommand()
        }
        if artistStatus == 0 { // NOTIFY_STATUS_OK
            queueArtistToken = artistToken
            print("[AudioReceiver] Registered for queueartist notifications (token=\(artistToken))")
        } else {
            print("[AudioReceiver] Failed to register for queueartist notifications (status=\(artistStatus))")
        }
        
        var shuffleToken: Int32 = -1
        let shuffleStatus = notify_register_dispatch(
            "com.saihgupr.audiostream.shuffleall",
            &shuffleToken,
            DispatchQueue.main
        ) { [weak self] _ in
            self?.handleShuffleAllCommand()
        }
        if shuffleStatus == 0 { // NOTIFY_STATUS_OK
            shuffleAllToken = shuffleToken
            print("[AudioReceiver] Registered for shuffleall notifications (token=\(shuffleToken))")
        } else {
            print("[AudioReceiver] Failed to register for shuffleall notifications (status=\(shuffleStatus))")
        }
        
        var playlistToken: Int32 = -1
        let playlistStatus = notify_register_dispatch(
            "com.saihgupr.audiostream.playplaylist",
            &playlistToken,
            DispatchQueue.main
        ) { [weak self] _ in
            self?.handlePlayPlaylistCommand()
        }
        if playlistStatus == 0 {
            playPlaylistToken = playlistToken
            print("[AudioReceiver] Registered for playplaylist notifications (token=\(playlistToken))")
        } else {
            print("[AudioReceiver] Failed to register for playplaylist notifications (status=\(playlistStatus))")
        }
        
        var deleteToken: Int32 = -1
        let deleteStatus = notify_register_dispatch(
            "com.saihgupr.audiostream.deletesong",
            &deleteToken,
            DispatchQueue.main
        ) { [weak self] _ in
            self?.handleDeleteCurrentSongCommand()
        }
        if deleteStatus == 0 {
            deleteSongToken = deleteToken
            print("[AudioReceiver] Registered for deletesong notifications (token=\(deleteToken))")
        } else {
            print("[AudioReceiver] Failed to register for deletesong notifications (status=\(deleteStatus))")
        }
        
        checkForPendingCommand()
    }
    
    private func checkForPendingCommand() {
        let pendingCmdPath = "/tmp/audiostream_pending_cmd"
        guard FileManager.default.fileExists(atPath: pendingCmdPath) else { return }
        
        do {
            let command = try String(contentsOfFile: pendingCmdPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            print("[AudioReceiver] Found pending command on launch: \(command)")
            
            // Delete the file first to prevent duplicate execution
            deletePendingCommandFile()
            
            // Execute command with a short delay to ensure app initialization is complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                if command == "shuffleall" || command == "shuffle all songs" || command == "suffle all songs" {
                    self.handleShuffleAllCommand()
                } else if command == "queuealbum" || command == "queue album" {
                    self.handleQueueAlbumCommand()
                } else if command == "queueartist" || command == "queue artist" {
                    self.handleQueueArtistCommand()
                } else if command == "deletesong" || command == "delete song" || command == "delete current song" || command == "delete" {
                    self.handleDeleteCurrentSongCommand()
                } else if command.hasPrefix("playlist:") {
                    let name = String(command.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
                    self.handlePlayPlaylistCommand(name: name)
                } else {
                    print("[AudioReceiver] Unknown pending command: \(command)")
                }
            }
        } catch {
            print("[AudioReceiver] Failed to read pending command file: \(error)")
        }
    }
    
    private func deletePendingCommandFile() {
        let pendingCmdPath = "/tmp/audiostream_pending_cmd"
        if FileManager.default.fileExists(atPath: pendingCmdPath) {
            try? FileManager.default.removeItem(atPath: pendingCmdPath)
        }
    }
    
    private func handleDeleteCurrentSongCommand() {
        deletePendingCommandFile()
        guard let currentTrack = state.currentTrack ?? (queue.indices.contains(queueIndex) ? queue[queueIndex] : nil) else {
            print("[AudioReceiver] deletesong: no current track playing")
            return
        }
        
        print("[AudioReceiver] deletesong: deleting current track '\(currentTrack.title)' (id: \(currentTrack.id))")
        
        // Remove track from active queue and advance playback
        removeTrackFromQueue(track: currentTrack)
        
        // Delete track from library database and storage
        let connectionService = ServerConnectionService()
        let libraryService = MusicLibraryService(connectionService: connectionService)
        if libraryService.deleteTrack(currentTrack) {
            print("[AudioReceiver] deletesong: successfully deleted '\(currentTrack.title)'")
            NotificationCenter.default.post(name: .trackDidDelete, object: currentTrack)
        } else {
            print("[AudioReceiver] deletesong: failed to delete '\(currentTrack.title)'")
        }
    }
    
    private func handleQueueAlbumCommand() {
        deletePendingCommandFile()
        guard let currentTrack = state.currentTrack ?? (queue.indices.contains(queueIndex) ? queue[queueIndex] : nil) else {
            print("[AudioReceiver] queuealbum: no current track")
            return
        }
        
        let albumName = currentTrack.album
        print("[AudioReceiver] queuealbum: queuing album '\(albumName)' for track '\(currentTrack.title)'")
        
        let connectionService = ServerConnectionService()
        let service = MusicLibraryService(connectionService: connectionService)
        
        service.fetchAllTracks()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let err) = completion {
                        print("[AudioReceiver] queuealbum: failed to fetch tracks: \(err)")
                    }
                },
                receiveValue: { [weak self] allTracks in
                    guard let self = self else { return }
                    
                    var albumTracks = allTracks.filter { $0.album.localizedCaseInsensitiveCompare(albumName) == .orderedSame }
                    
                    if albumTracks.isEmpty {
                        albumTracks = allTracks.filter { track in
                            let trackKey = "\(track.album.lowercased())|\(track.artist.lowercased())"
                            let currentKey = "\(currentTrack.album.lowercased())|\(currentTrack.artist.lowercased())"
                            return trackKey == currentKey || track.album.localizedCaseInsensitiveContains(albumName)
                        }
                    }
                    
                    guard !albumTracks.isEmpty else {
                        print("[AudioReceiver] queuealbum: no tracks found for album '\(albumName)'")
                        return
                    }
                    
                    let sortedTracks = albumTracks.sorted(by: Track.compareTrackOrder)
                    print("[AudioReceiver] queuealbum: queuing \(sortedTracks.count) tracks for album '\(albumName)'")
                    self.addToQueue(albumTitle: albumName, tracks: sortedTracks)
                }
            )
            .store(in: &commandCancellables)
    }
    
    private func handleQueueArtistCommand() {
        deletePendingCommandFile()
        guard let currentTrack = state.currentTrack ?? (queue.indices.contains(queueIndex) ? queue[queueIndex] : nil) else {
            print("[AudioReceiver] queueartist: no current track")
            return
        }
        
        let artistName = currentTrack.artist
        print("[AudioReceiver] queueartist: queuing artist '\(artistName)' for track '\(currentTrack.title)'")
        
        let connectionService = ServerConnectionService()
        let service = MusicLibraryService(connectionService: connectionService)
        
        service.fetchAllTracks()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let err) = completion {
                        print("[AudioReceiver] queueartist: failed to fetch tracks: \(err)")
                    }
                },
                receiveValue: { [weak self] allTracks in
                    guard let self = self else { return }
                    
                    let artistTracks = allTracks.filter { track in
                        if track.artist.localizedCaseInsensitiveCompare(artistName) == .orderedSame {
                            return true
                        }
                        let contributors = track.artist.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        return contributors.contains { $0.localizedCaseInsensitiveCompare(artistName) == .orderedSame }
                    }
                    
                    guard !artistTracks.isEmpty else {
                        print("[AudioReceiver] queueartist: no tracks found for artist '\(artistName)'")
                        return
                    }
                    
                    self.setQueueWithNewTracks(artistTracks, currentTrack: currentTrack, shuffle: true)
                }
            )
            .store(in: &commandCancellables)
    }
    
    private func handleShuffleAllCommand() {
        deletePendingCommandFile()
        print("[AudioReceiver] shuffleall: shuffling all songs")
        
        let connectionService = ServerConnectionService()
        let service = MusicLibraryService(connectionService: connectionService)
        
        service.fetchAllTracks()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let err) = completion {
                        print("[AudioReceiver] shuffleall: failed to fetch tracks: \(err)")
                    }
                },
                receiveValue: { [weak self] allTracks in
                    guard let self = self else { return }
                    guard !allTracks.isEmpty else {
                        print("[AudioReceiver] shuffleall: no tracks found")
                        return
                    }
                    
                    let shuffledTracks = allTracks.shuffled()
                    self.state.isShuffleEnabled = true
                    self.play(tracks: shuffledTracks, startingAt: 0)
                }
            )
            .store(in: &commandCancellables)
    }
    
    private func handlePlayPlaylistCommand(name: String? = nil, shuffle: Bool = true) {
        let pendingPlaylistPath = "/tmp/audiostream_pending_playlist"
        let pendingCmdPath = "/tmp/audiostream_pending_cmd"
        
        var targetPlaylistName = name
        if targetPlaylistName == nil || targetPlaylistName?.isEmpty == true {
            if let cmd = try? String(contentsOfFile: pendingCmdPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), cmd.hasPrefix("playlist:") {
                targetPlaylistName = String(cmd.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let plName = try? String(contentsOfFile: pendingPlaylistPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !plName.isEmpty {
                targetPlaylistName = plName
            }
        }
        
        deletePendingCommandFile()
        try? FileManager.default.removeItem(atPath: pendingPlaylistPath)
        
        guard var playlistName = targetPlaylistName?.trimmingCharacters(in: .whitespacesAndNewlines), !playlistName.isEmpty else {
            print("[AudioReceiver] playplaylist: no playlist specified")
            return
        }
        playlistName = playlistName.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        
        print("[AudioReceiver] playplaylist: searching for playlist '\(playlistName)'")
        
        let connectionService = ServerConnectionService()
        let service = MusicLibraryService(connectionService: connectionService)
        let source = connectionService.librarySource
        
        Publishers.CombineLatest3(
            service.fetchAlbums().catch { _ in Just([]) },
            service.fetchPlaylists().catch { _ in Just([]) },
            service.fetchAllTracks().catch { _ in Just([]) }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] loadedAlbums, loadedPlaylists, loadedTracks in
            guard let self = self else { return }
            
            let allPlaylists = self.buildAllPlaylists(albums: loadedAlbums, userPlaylists: loadedPlaylists, tracks: loadedTracks, source: source)
            
            let matchedPlaylist = allPlaylists.first { $0.name.localizedCaseInsensitiveCompare(playlistName) == .orderedSame }
                ?? allPlaylists.first { $0.name.localizedCaseInsensitiveContains(playlistName) }
            
            guard let targetPlaylist = matchedPlaylist else {
                print("[AudioReceiver] playplaylist: playlist '\(playlistName)' not found")
                return
            }
            
            var tracksToPlay: [Track]
            if !targetPlaylist.tracks.isEmpty {
                tracksToPlay = targetPlaylist.tracks
            } else {
                tracksToPlay = targetPlaylist.songIds.compactMap { id in
                    loadedTracks.first(where: { $0.id == id })
                }
            }
            
            guard !tracksToPlay.isEmpty else {
                print("[AudioReceiver] playplaylist: playlist '\(targetPlaylist.name)' contains 0 playable tracks")
                return
            }
            
            tracksToPlay = shuffle ? tracksToPlay.shuffled() : tracksToPlay
            print("[AudioReceiver] playplaylist: playing \(tracksToPlay.count) tracks for '\(targetPlaylist.name)' (shuffle: \(shuffle))")
            
            self.state.isShuffleEnabled = shuffle
            self.play(tracks: tracksToPlay, startingAt: 0)
        }
        .store(in: &commandCancellables)
    }
    
    private func buildAllPlaylists(albums: [Album], userPlaylists: [Playlist], tracks: [Track], source: LibrarySource) -> [Playlist] {
        var result = userPlaylists
        
        if source == .remote {
            result = result.map { playlist -> Playlist in
                var p = playlist
                p.tracks = playlist.songIds.compactMap { id in
                    tracks.first(where: { $0.id == id })
                }
                return p
            }
        }
        
        var albumDates: [String: Date] = [:]
        for album in albums {
            if let date = album.dateAdded {
                albumDates[album.id] = date
                albumDates["\(album.title.lowercased())|\(album.artist.lowercased())"] = date
            }
        }
        
        let now = Date()
        let maxTrackId = tracks.map { $0.id }.max() ?? 0
        var trackDates: [String: Date] = [:]
        var tracksWithDates: [(track: Track, date: Date)] = []
        
        for track in tracks {
            var trackDate: Date? = nil
            let albumKey = "\(track.album.lowercased())|\(track.artist.lowercased())"
            if let date = albumDates[albumKey] {
                trackDate = date
            }
            if trackDate == nil {
                let diff = Double(maxTrackId - track.id)
                trackDate = now.addingTimeInterval(-diff * 3600)
            }
            if let date = trackDate {
                trackDates[track.persistentId] = date
                tracksWithDates.append((track, date))
            }
        }
        
        let twoWeeksAgo = now.addingTimeInterval(-14 * 24 * 3600)
        let oneMonthAgo = now.addingTimeInterval(-30 * 24 * 3600)
        let threeMonthsAgo = now.addingTimeInterval(-90 * 24 * 3600)
        let sixMonthsAgo = now.addingTimeInterval(-180 * 24 * 3600)
        let oneYearAgo = now.addingTimeInterval(-365 * 24 * 3600)
        
        let recentlyAddedTracks = tracksWithDates.filter { $0.date >= twoWeeksAgo }.map { $0.track }
        let monthTracks = tracksWithDates.filter { $0.date >= oneMonthAgo }.map { $0.track }
        let threeMonthsTracks = tracksWithDates.filter { $0.date >= threeMonthsAgo }.map { $0.track }
        let sixMonthsTracks = tracksWithDates.filter { $0.date >= sixMonthsAgo }.map { $0.track }
        let yearTracks = tracksWithDates.filter { $0.date >= oneYearAgo }.map { $0.track }
        
        var specialPlaylists: [Playlist] = []
        
        func sortTracksByDate(_ tracksToSort: [Track]) -> [Track] {
            return tracksToSort.sorted { lhs, rhs in
                let lhsDate = trackDates[lhs.persistentId] ?? Date(timeIntervalSince1970: 0)
                let rhsDate = trackDates[rhs.persistentId] ?? Date(timeIntervalSince1970: 0)
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
        
        if !recentlyAddedTracks.isEmpty {
            specialPlaylists.append(Playlist(id: -1, name: "Recently Added", songIds: recentlyAddedTracks.map { $0.id }, tracks: sortTracksByDate(recentlyAddedTracks)))
        }
        if !monthTracks.isEmpty {
            specialPlaylists.append(Playlist(id: -2, name: "Month", songIds: monthTracks.map { $0.id }, tracks: sortTracksByDate(monthTracks)))
        }
        if !threeMonthsTracks.isEmpty {
            specialPlaylists.append(Playlist(id: -3, name: "3 Months", songIds: threeMonthsTracks.map { $0.id }, tracks: sortTracksByDate(threeMonthsTracks)))
        }
        if !sixMonthsTracks.isEmpty {
            specialPlaylists.append(Playlist(id: -4, name: "6 Months", songIds: sixMonthsTracks.map { $0.id }, tracks: sortTracksByDate(sixMonthsTracks)))
        }
        if !yearTracks.isEmpty {
            specialPlaylists.append(Playlist(id: -5, name: "Year", songIds: yearTracks.map { $0.id }, tracks: sortTracksByDate(yearTracks)))
        }
        
        result.removeAll { $0.id < 0 }
        result.insert(contentsOf: specialPlaylists, at: 0)
        return result
    }
    
    private func startObservingTime() {
        guard let player = player else { return }
        // Remove existing to be safe
        stopObservingTime()
        
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] time in
            self?.state.currentTime = time.seconds
            self?.updateNowPlayingInfo()
        }
    }
    
    private func stopObservingTime() {
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }
    
    // MARK: - Now Playing Info
    private static var imageCacheDirectory: URL {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let cachePath = paths[0].appendingPathComponent("AudioStreamImageCache")
        if !FileManager.default.fileExists(atPath: cachePath.path) {
            try? FileManager.default.createDirectory(at: cachePath, withIntermediateDirectories: true)
        }
        return cachePath
    }
    
    private static func diskCacheURL(for url: URL) -> URL {
        let filename = abs(url.absoluteString.hashValue).description
        return imageCacheDirectory.appendingPathComponent(filename)
    }

    private func updateNowPlayingInfo(artwork: MPMediaItemArtwork? = nil) {
        guard let track = state.currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            currentArtwork = nil
            currentArtworkTrackId = nil
            lastRequestedArtworkTrackId = nil
            return
        }
        
        var nowPlayingInfo = [String: Any]()
        
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        nowPlayingInfo[MPMediaItemPropertyTitle] = track.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = track.artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = track.album
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = track.duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player?.currentTime().seconds
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = state.isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
        
        // Reset feedback active states so buttons in Now Playing behave as triggers
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.likeCommand.isActive = false
        commandCenter.bookmarkCommand.isActive = false
        commandCenter.dislikeCommand.isActive = false
        
        // Update shuffle and repeat states on command center so watchOS and iOS UI reflect them
        commandCenter.changeShuffleModeCommand.currentShuffleType = state.isShuffleEnabled ? .items : .off
        switch state.repeatMode {
        case .off: commandCenter.changeRepeatModeCommand.currentRepeatType = .off
        case .one: commandCenter.changeRepeatModeCommand.currentRepeatType = .one
        case .all: commandCenter.changeRepeatModeCommand.currentRepeatType = .all
        }
        
        if let artwork = artwork {
            currentArtwork = artwork
            currentArtworkTrackId = track.id
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        } else if currentArtworkTrackId == track.id, let cachedArtwork = currentArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = cachedArtwork
        } else {
            // No artwork yet or track changed, start loading it
            if let url = track.artworkUrl {
                if lastRequestedArtworkTrackId != track.id {
                    lastRequestedArtworkTrackId = track.id
                    downloadArtwork(for: url, trackId: track.id)
                }
            }
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    private func downloadArtwork(for url: URL, trackId: Int64) {
        artworkTask?.cancel()
        
        if url.scheme == "local-artwork" {
            guard let host = url.host, let persistentID = UInt64(host) else { return }
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let predicate = MPMediaPropertyPredicate(value: persistentID, forProperty: MPMediaItemPropertyPersistentID)
                let query = MPMediaQuery(filterPredicates: [predicate])
                if let mediaItem = query.items?.first,
                   let artwork = mediaItem.artwork,
                   let image = artwork.image(at: CGSize(width: 600, height: 600)) {
                    
                    DispatchQueue.main.async {
                        guard let self = self, self.state.currentTrack?.id == trackId else { return }
                        let mediaArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        self.updateNowPlayingInfo(artwork: mediaArtwork)
                    }
                }
            }
            return
        }
        
        if url.scheme == "local-file-artwork" {
            guard let host = url.host else { return }
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                if let image = LocalFileArtworkCache.shared.get(for: host) {
                    DispatchQueue.main.async {
                        guard let self = self, self.state.currentTrack?.id == trackId else { return }
                        let mediaArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        self.updateNowPlayingInfo(artwork: mediaArtwork)
                    }
                }
            }
            return
        }
        
        // Check disk cache first for web URLs (http/https)
        if url.scheme == "http" || url.scheme == "https" {
            let diskURL = Self.diskCacheURL(for: url)
            if FileManager.default.fileExists(atPath: diskURL.path),
               let data = try? Data(contentsOf: diskURL),
               let image = UIImage(data: data) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.updateNowPlayingInfo(artwork: artwork)
                return
            }
        }
        
        artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let image = UIImage(data: data) else { return }
            
            // Save to disk cache
            let diskURL = Self.diskCacheURL(for: url)
            try? data.write(to: diskURL)
            
            DispatchQueue.main.async {
                guard self.state.currentTrack?.id == trackId else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.updateNowPlayingInfo(artwork: artwork)
            }
        }
        artworkTask?.resume()
    }
    
    private func debugLog(_ message: String) {
        let logPath = "/tmp/audiostream_debug.log"
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        let logMessage = "[\(timestamp)] \(message)\n"
        if let fileHandle = FileHandle(forWritingAtPath: logPath) {
            fileHandle.seekToEndOfFile()
            if let data = logMessage.data(using: .utf8) {
                fileHandle.write(data)
            }
            fileHandle.closeFile()
        } else {
            try? logMessage.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }
}


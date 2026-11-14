import SwiftUI
import AVKit
import Combine

struct MenuAnchorKey: PreferenceKey {
    typealias Value = Anchor<CGRect>?
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct NowPlayingView: View {
    @EnvironmentObject var audioService: AudioPlayerService
    @EnvironmentObject var navManager: NavigationManager
    @EnvironmentObject var connectionService: ServerConnectionService
    @Binding var expand: Bool
    @AppStorage("RC_ShowVolumeSlider") private var showVolumeSlider: Bool = true
    @State private var selectedTrackForDelete: Track? = nil
    @State private var showTrackDeleteConfirmation = false
    @State private var showMenu = false
    @State private var showQueue = false
    @State private var audioOutputName: String = ""
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    
    // iPhone uses the dedicated Music-matched layout for both portrait and landscape
    private var usesMusicPlayerLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }
    
    var body: some View {
        ZStack {
            if usesMusicPlayerLayout {
                MusicPlayerScreen(
                    expand: $expand,
                    showQueue: $showQueue,
                    showMenu: $showMenu,
                    audioOutputName: audioOutputName,
                    showVolumeSlider: showVolumeSlider
                )
            } else {
            // Background Layer
            ZStack {
                if let track = audioService.state.currentTrack, let url = track.artworkUrl {
                    RemoteImage(url: url)
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .blur(radius: 45, opaque: true)
                        .overlay(Color.black.opacity(0.55))
                        .clipped()
                } else {
                    Color.black
                }
            }
            .ignoresSafeArea()
            
            GeometryReader { geometry in
                let screenHeight = geometry.size.height
                let showsHeader = UIDevice.current.userInterfaceIdiom == .pad || geometry.size.width > geometry.size.height
                let contentHeight = screenHeight - (showsHeader ? 50 : 0)
                // Music sizes the artwork to the width; cap it by what is left after
                // the controls so nothing has to scroll on shorter phones.
                let artworkSide = min(geometry.size.width - 52, contentHeight - 421)
                
                VStack(spacing: 0) {
                    // Header (Dismiss button) - iPhone portrait uses the sheet grabber, like Music
                    if showsHeader {
                        HStack {
                            Button(action: {
                                withAnimation {
                                    expand = false
                                }
                            }) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 24))
                                    .foregroundColor(.white.opacity(0.8))
                                    .padding()
                            }
                            Spacer()
                        }
                        .frame(height: 50)
                        .contentShape(Rectangle())
                    }
                    
                    if geometry.size.width > geometry.size.height {
                        // Landscape Layout (iPad Landscape & iPhone Landscape)
                        HStack(spacing: 36) {
                            // Left Side: Artwork
                            VStack {
                                Spacer(minLength: 10)
                                Group {
                                    if let artworkUrl = audioService.state.currentTrack?.artworkUrl {
                                        RemoteImage(url: artworkUrl)
                                            .aspectRatio(1.0, contentMode: .fit)
                                            .cornerRadius(16)
                                            .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 10)
                                    } else {
                                        Rectangle()
                                            .fill(Color.gray.opacity(0.3))
                                            .aspectRatio(1.0, contentMode: .fit)
                                            .overlay(
                                                Image(systemName: "music.note")
                                                    .font(.system(size: 70))
                                                    .foregroundColor(.white)
                                            )
                                            .cornerRadius(16)
                                            .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 10)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let track = audioService.state.currentTrack {
                                        navManager.navigateToAlbum(title: track.album, artist: track.artist)
                                        withAnimation { expand = false }
                                    }
                                }
                                Spacer(minLength: 10)
                            }
                            .frame(maxWidth: min(geometry.size.width * 0.45, geometry.size.height * 0.75))
                            .padding(.leading, 32)
                            
                            // Right Side: Info, Scrub Bar, Controls, Volume Slider
                            VStack(spacing: 16) {
                                Spacer()
                                
                                // Track Info
                                HStack(alignment: .center) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(audioService.state.currentTrack?.title ?? "Not Playing")
                                            .font(.title2)
                                            .bold()
                                            .foregroundColor(.white)
                                            .lineLimit(2)
                                        
                                        HStack(spacing: 0) {
                                            let artistParts = (audioService.state.currentTrack?.artist ?? "Select Music").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                                            
                                            ForEach(artistParts.indices, id: \.self) { index in
                                                let artist = artistParts[index]
                                                Text(artist)
                                                    .font(.body)
                                                    .foregroundColor(.gray)
                                                    .onTapGesture {
                                                        navManager.navigateToArtist(name: artist)
                                                        withAnimation { expand = false }
                                                    }
                                                
                                                if index < artistParts.count - 1 {
                                                    Text(", ")
                                                        .font(.body)
                                                        .foregroundColor(.gray)
                                                }
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    
                                    menuButton
                                }
                                
                                // Scrub Bar
                                NowPlayingScrubberView(
                                    playbackProgress: audioService.progress,
                                    trackDuration: audioService.state.currentTrack?.duration ?? 0,
                                    barHeight: 36,
                                    knobSize: 8,
                                    cornerRadius: 2,
                                    onSeek: { audioService.seek(to: $0) }
                                )
                                
                                // Playback Controls
                                HStack(alignment: .center) {
                                    Button(action: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            audioService.toggleShuffle()
                                        }
                                    }) {
                                        Image(systemName: "shuffle")
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundColor(audioService.state.isShuffleEnabled ? Color.white.opacity(0.85) : Color.white.opacity(0.35))
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    
                                    Spacer()
                                    
                                    Button(action: { audioService.previous() }) {
                                        Image(systemName: "backward.fill")
                                            .font(.system(size: 28))
                                            .foregroundColor(.white)
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    
                                    Spacer()
                                    
                                    Button(action: {
                                        if audioService.state.isPlaying {
                                            audioService.pause()
                                        } else {
                                            audioService.play()
                                        }
                                    }) {
                                        Image(systemName: audioService.state.isPlaying ? "pause.fill" : "play.fill")
                                            .font(.system(size: 44))
                                            .foregroundColor(.white)
                                            .frame(width: 68, height: 68)
                                            .contentShape(Rectangle())
                                    }
                                    
                                    Spacer()
                                    
                                    Button(action: { audioService.next() }) {
                                        Image(systemName: "forward.fill")
                                            .font(.system(size: 28))
                                            .foregroundColor(.white)
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    
                                    Spacer()
                                    
                                    Button(action: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            audioService.cycleRepeatMode()
                                        }
                                    }) {
                                        Image(systemName: audioService.state.repeatMode == .one ? "repeat.1" : "repeat")
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundColor(audioService.state.repeatMode != .off ? Color.white.opacity(0.85) : Color.white.opacity(0.35))
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                }
                                
                                if showVolumeSlider {
                                    // Volume Section
                                    HStack(spacing: 12) {
                                        Image(systemName: "speaker.fill")
                                            .foregroundColor(.white.opacity(0.6))
                                            .font(.system(size: 12))
                                        
                                        GeometryReader { sliderGeo in
                                            ZStack(alignment: .leading) {
                                                Rectangle()
                                                    .fill(Color.black.opacity(0.001))
                                                    .frame(width: sliderGeo.size.width, height: 30)
                                                
                                                Rectangle()
                                                    .fill(Color.white.opacity(0.2))
                                                    .frame(width: sliderGeo.size.width, height: 4)
                                                    .cornerRadius(2)
                                                
                                                Rectangle()
                                                    .fill(Color.white)
                                                    .frame(width: sliderGeo.size.width * CGFloat(audioService.state.volume), height: 4)
                                                    .cornerRadius(2)
                                                
                                                Circle()
                                                    .fill(Color.white)
                                                    .frame(width: 10, height: 10)
                                                    .offset(x: sliderGeo.size.width * CGFloat(audioService.state.volume) - 5)
                                            }
                                            .contentShape(Rectangle())
                                            .gesture(
                                                DragGesture(minimumDistance: 0)
                                                    .onChanged { value in
                                                        let percentage = min(max(0, Float(value.location.x / sliderGeo.size.width)), 1.0)
                                                        audioService.setVolume(percentage)
                                                    }
                                            )
                                        }
                                        .frame(height: 30)
                                        
                                        Image(systemName: "speaker.wave.3.fill")
                                            .foregroundColor(.white.opacity(0.6))
                                            .font(.system(size: 12))
                                    }
                                }

                                // Bottom utility row (AirPlay, like Apple Music)
                                HStack {
                                    AirPlayButton()
                                        .frame(width: 44, height: 44)
                                        .accessibilityLabel("AirPlay")

                                    Spacer()

                                    Button(action: { showQueue = true }) {
                                        Image(systemName: "list.bullet")
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.85))
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .accessibilityLabel("Queue")
                                }

                                Text(audioOutputName)
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                                    .padding(.top, 4)

                                Spacer()
                            }
                            .padding(.trailing, 40)
                        }
                        .frame(width: geometry.size.width, height: contentHeight)
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 0) {
                                // Main content taking up full visible height
                                VStack {
                                    Spacer().frame(height: 86)

                                    // Artwork
                                    Group {
                                        if let artworkUrl = audioService.state.currentTrack?.artworkUrl {
                                            RemoteImage(url: artworkUrl)
                                                .frame(width: artworkSide, height: artworkSide)
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                                // Keep the artwork's depth below it so its shadow does not
                                                // darken the backdrop behind the fixed Now Playing header.
                                                .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 8)
                                        } else {
                                            Rectangle()
                                                .fill(Color.gray.opacity(0.3))
                                                .frame(width: artworkSide, height: artworkSide)
                                                .overlay(
                                                    Image(systemName: "music.note")
                                                        .font(.system(size: 60))
                                                        .foregroundColor(.white)
                                                )
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                                .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 8)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if let track = audioService.state.currentTrack {
                                            navManager.navigateToAlbum(title: track.album, artist: track.artist)
                                            withAnimation { expand = false }
                                        }
                                    }

                                    Spacer().frame(height: 59)

                                    // Info
                                    HStack(alignment: .center) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(audioService.state.currentTrack?.title ?? "Not Playing")
                                                .font(.title2)
                                                .bold()
                                                .foregroundColor(.white)
                                                .multilineTextAlignment(.leading)
                                                .lineLimit(2)

                                            HStack(spacing: 0) {
                                                let artistParts = (audioService.state.currentTrack?.artist ?? "Select Music").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }

                                                ForEach(artistParts.indices, id: \.self) { index in
                                                    let artist = artistParts[index]
                                                    Text(artist)
                                                        .font(.body)
                                                        .foregroundColor(.gray)
                                                        .onTapGesture {
                                                            navManager.navigateToArtist(name: artist)
                                                            withAnimation { expand = false }
                                                        }

                                                    if index < artistParts.count - 1 {
                                                        Text(", ")
                                                            .font(.body)
                                                            .foregroundColor(.gray)
                                                    }
                                                }
                                            }
                                            .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                        menuButton
                                    }
                                    .padding(.horizontal, 26)

                                    // Scrub Bar
                                    NowPlayingScrubberView(
                                        playbackProgress: audioService.progress,
                                        trackDuration: audioService.state.currentTrack?.duration ?? 0,
                                        barHeight: 26,
                                        knobSize: 12,
                                        cornerRadius: 0,
                                        onSeek: { audioService.seek(to: $0) }
                                    )
                                    .padding(.horizontal, 32)

                                    Spacer().frame(height: 26)

                                    // Controls
                                    HStack(alignment: .center) {
                                        Button(action: {
                                            withAnimation(.easeInOut(duration: 0.15)) {
                                                audioService.toggleShuffle()
                                            }
                                        }) {
                                            Image(systemName: "shuffle")
                                                .font(.system(size: 20, weight: .semibold))
                                                .foregroundColor(audioService.state.isShuffleEnabled ? Color.white.opacity(0.85) : Color.white.opacity(0.35))
                                                .frame(width: 44, height: 44)
                                                .contentShape(Rectangle())
                                        }
                                        
                                        Spacer()
                                        
                                        Button(action: {
                                            audioService.previous()
                                        }) {
                                            Image(systemName: "backward.fill")
                                                .font(.system(size: 28))
                                                .foregroundColor(.white)
                                                .frame(width: 44, height: 44)
                                                .contentShape(Rectangle())
                                        }
                                        
                                        Spacer()
                                        
                                        Button(action: {
                                            if audioService.state.isPlaying {
                                                audioService.pause()
                                            } else {
                                                audioService.play()
                                            }
                                        }) {
                                            Image(systemName: audioService.state.isPlaying ? "pause.fill" : "play.fill")
                                                .font(.system(size: 40))
                                                .foregroundColor(.white)
                                                .frame(width: 44, height: 44)
                                                .contentShape(Rectangle())
                                        }
                                        
                                        Spacer()
                                        
                                        Button(action: {
                                            audioService.next()
                                        }) {
                                            Image(systemName: "forward.fill")
                                                .font(.system(size: 28))
                                                .foregroundColor(.white)
                                                .frame(width: 44, height: 44)
                                                .contentShape(Rectangle())
                                        }
                                        
                                        Spacer()
                                        
                                        Button(action: {
                                            withAnimation(.easeInOut(duration: 0.15)) {
                                                audioService.cycleRepeatMode()
                                            }
                                        }) {
                                            Image(systemName: audioService.state.repeatMode == .one ? "repeat.1" : "repeat")
                                                .font(.system(size: 20, weight: .semibold))
                                                .foregroundColor(audioService.state.repeatMode != .off ? Color.white.opacity(0.85) : Color.white.opacity(0.35))
                                                .frame(width: 44, height: 44)
                                                .contentShape(Rectangle())
                                        }
                                    }
                                    .padding(.horizontal, 32)

                                    if showVolumeSlider {
                                        // Volume slider sits low, just above the utility row (Apple Music order)
                                        HStack(spacing: 12) {
                                            Image(systemName: "speaker.fill")
                                                .foregroundColor(.white.opacity(0.6))
                                                .font(.system(size: 12))

                                            GeometryReader { sliderGeo in
                                                ZStack(alignment: .leading) {
                                                    // Hit Zone
                                                    Rectangle()
                                                        .fill(Color.black.opacity(0.001))
                                                        .frame(width: sliderGeo.size.width, height: 28)

                                                    // Track background
                                                    Rectangle()
                                                        .fill(Color.white.opacity(0.2))
                                                        .frame(width: sliderGeo.size.width, height: 4)
                                                        .cornerRadius(2)

                                                    // Active progress
                                                    Rectangle()
                                                        .fill(Color.white)
                                                        .frame(width: sliderGeo.size.width * CGFloat(audioService.state.volume), height: 4)
                                                        .cornerRadius(2)

                                                    // Minimal circular thumb
                                                    Circle()
                                                        .fill(Color.white)
                                                        .frame(width: 16, height: 16)
                                                        .offset(x: sliderGeo.size.width * CGFloat(audioService.state.volume) - 8)
                                                }
                                                .contentShape(Rectangle())
                                                .gesture(
                                                    DragGesture(minimumDistance: 0)
                                                        .onChanged { value in
                                                            let percentage = min(max(0, Float(value.location.x / sliderGeo.size.width)), 1.0)
                                                            audioService.setVolume(percentage)
                                                        }
                                                )
                                            }
                                            .frame(height: 28)

                                            Image(systemName: "speaker.wave.3.fill")
                                                .foregroundColor(.white.opacity(0.6))
                                                .font(.system(size: 12))
                                        }
                                        .padding(.horizontal, 32)
                                        .padding(.top, 20)
                                    }

                                    Spacer(minLength: 4)

                                    // Bottom utility row (AirPlay and queue, like Apple Music)
                                    HStack {
                                        Color.clear
                                            .frame(width: 34, height: 34)

                                        Spacer()

                                        AirPlayButton()
                                            .frame(width: 34, height: 34)
                                            .accessibilityLabel("AirPlay")

                                        Spacer()

                                        Button(action: { showQueue = true }) {
                                            Image(systemName: "list.bullet")
                                                .font(.system(size: 20, weight: .semibold))
                                                .foregroundColor(.white.opacity(0.85))
                                                .frame(width: 34, height: 34)
                                                .contentShape(Rectangle())
                                        }
                                        .accessibilityLabel("Queue")
                                    }
                                    .padding(.horizontal, 78)

                                    Text(audioOutputName)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.7))
                                        .lineLimit(1)
                                        .padding(.top, -5)
                                        .padding(.bottom, 19)
                                }
                                .frame(width: geometry.size.width, height: contentHeight)
                                .contentShape(Rectangle())
                            }
                            .frame(width: geometry.size.width)
                        }
                        .background(Color.clear)
                        .hideScrollBackground()
                    }
                }
                .ipadSwipeDownGesture {
                    withAnimation {
                        expand = false
                    }
                }
            }
            }
            
            if showMenu {
                // Capture taps outside the menu to dismiss it without propagating to other views
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showMenu = false
                        }
                    }
                

            }
        }
        .background(Color.black.edgesIgnoringSafeArea(.all))
        .overlayPreferenceValue(MenuAnchorKey.self) { anchor in
            GeometryReader { geo in
                if showMenu, let anchor = anchor {
                    let rect = geo[anchor]
                    menuCard
                        .offset(
                            x: min(max(rect.maxX - 204, 8), geo.size.width - 228),
                            y: rect.maxY + 8
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)))
                        .zIndex(200)
                }
            }
        }
        .onAppear { updateAudioOutput() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: DispatchQueue.main)) { _ in
            updateAudioOutput()
        }
        .sheet(isPresented: $showQueue) {
            QueueView()
                .environmentObject(audioService)
        }
        .alert(isPresented: $showTrackDeleteConfirmation) {
            Alert(
                title: Text("Delete Song"),
                message: Text("Are you sure you want to permanently delete '\(selectedTrackForDelete?.title ?? "")' from this device? This action cannot be undone."),
                primaryButton: .destructive(Text("Delete")) {
                    if let track = selectedTrackForDelete {
                        let libraryService = MusicLibraryService(connectionService: connectionService)
                        Task { @MainActor in
                            if await libraryService.deleteTrackAsync(track) {
                                audioService.removeTrackFromQueue(track: track)
                                NotificationCenter.default.post(name: .trackDidDelete, object: track)
                            }
                        }
                    }
                    selectedTrackForDelete = nil
                },
                secondaryButton: .cancel {
                    selectedTrackForDelete = nil
                }
            )
        }
    }
    
    private var menuCard: some View {
        VStack(alignment: .leading, spacing: 0) {
                            if let currentTrack = audioService.state.currentTrack {
                                Button(action: {
                                    withAnimation { showMenu = false }
                                    navManager.navigateToAlbum(title: currentTrack.album, artist: currentTrack.artist)
                                    withAnimation { expand = false }
                                }) {
                                    HStack {
                                        Image(systemName: "music.note.list")
                                            .font(.system(size: 16))
                                            .frame(width: 20)
                                        Text("Go to Album")
                                            .font(.body)
                                    }
                                    .foregroundColor(.white)
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }

                                Button(action: {
                                    withAnimation { showMenu = false }
                                    audioService.queueCurrentAlbum()
                                }) {
                                    HStack {
                                        Image(systemName: "text.badge.plus")
                                            .font(.system(size: 16))
                                            .frame(width: 20)
                                        Text("Queue Album")
                                            .font(.body)
                                    }
                                    .foregroundColor(.white)
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }

                                Divider().background(Color.white.opacity(0.15))

                                let artistParts = currentTrack.artist.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                                ForEach(artistParts, id: \.self) { artist in
                                    Button(action: {
                                        withAnimation { showMenu = false }
                                        navManager.navigateToArtist(name: artist)
                                        withAnimation { expand = false }
                                    }) {
                                        HStack {
                                            Image(systemName: "person.fill")
                                                .font(.system(size: 16))
                                                .frame(width: 20)
                                            Text(artistParts.count > 1 ? "Go to \(artist)" : "Go to Artist")
                                                .font(.body)
                                        }
                                        .foregroundColor(.white)
                                        .padding(.vertical, 12)
                                        .padding(.horizontal, 16)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }

                                    Divider().background(Color.white.opacity(0.15))
                                }

                                Button(action: {
                                    withAnimation { showMenu = false }
                                    audioService.queueCurrentArtist()
                                }) {
                                    HStack {
                                        Image(systemName: "text.badge.plus")
                                            .font(.system(size: 16))
                                            .frame(width: 20)
                                        Text("Queue Artist")
                                            .font(.body)
                                    }
                                    .foregroundColor(.white)
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }

                                Divider().background(Color.white.opacity(0.15))

                                if connectionService.librarySource == .local {
                                    Button(action: {
                                        withAnimation { showMenu = false }
                                        selectedTrackForDelete = currentTrack
                                        showTrackDeleteConfirmation = true
                                    }) {
                                        HStack {
                                            Image(systemName: "trash")
                                                .font(.system(size: 16))
                                                .frame(width: 20)
                                            Text("Delete Song")
                                                .font(.body)
                                        }
                                        .foregroundColor(.red)
                                        .padding(.vertical, 12)
                                        .padding(.horizontal, 16)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                }
                            }
        }
        .frame(width: 220)
        .background(
            BlurView(style: .systemUltraThinMaterialDark)
                .cornerRadius(14)
                .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private var menuButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                showMenu.toggle()
            }
        }) {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.15))
                .clipShape(Circle())
        }
        .anchorPreference(key: MenuAnchorKey.self, value: .bounds) { $0 }
        .accessibilityLabel("More")
    }

    // Source device arrow output device, like the Music player ("iPhone -> Computer Speaker")
    private func updateAudioOutput() {
        let port = AVAudioSession.sharedInstance().currentRoute.outputs.first
        guard let port = port else {
            audioOutputName = ""
            return
        }
        if port.portType == .builtInSpeaker {
            audioOutputName = UIDevice.current.name
        } else {
            audioOutputName = "\(UIDevice.current.name) → \(port.portName)"
        }
    }

    func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct AirPlayButton: View {
    var body: some View {
        ZStack {
            AirPlayRoutePicker()
            // Keep the Music-style white glyph even while casting; the picker
            // below stays invisible but still handles the tap.
            Image(systemName: "airplayaudio")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.white.opacity(0.85))
                .allowsHitTesting(false)
        }
    }
}

struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .clear
        picker.activeTintColor = .clear
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
// Struct moved to top

extension View {
    @ViewBuilder
    func hideScrollBackground() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
    
    @ViewBuilder
    func ipadSwipeDownGesture(onDismiss: @escaping () -> Void) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.gesture(
                DragGesture().onEnded { value in
                    if abs(value.translation.height) > abs(value.translation.width),
                       value.translation.height > 45 {
                        onDismiss()
                    }
                }
            )
        } else {
            self
        }
    }
}

private struct NowPlayingScrubberView: View {
    @ObservedObject var playbackProgress: PlaybackProgress
    let trackDuration: TimeInterval
    let barHeight: CGFloat
    let knobSize: CGFloat
    let cornerRadius: CGFloat
    let onSeek: (TimeInterval) -> Void

    private var ratio: CGFloat {
        let safeDuration = max(trackDuration, 1)
        return CGFloat(min(max(playbackProgress.currentTime / safeDuration, 0), 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.black.opacity(0.001))
                        .frame(width: geometry.size.width, height: barHeight)

                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: geometry.size.width, height: 4)
                        .cornerRadius(cornerRadius)

                    Rectangle()
                        .fill(Color.white)
                        .frame(width: geometry.size.width * ratio, height: 4)
                        .cornerRadius(cornerRadius)

                    Circle()
                        .fill(Color.white)
                        .frame(width: knobSize, height: knobSize)
                        .offset(x: geometry.size.width * ratio - knobSize / 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let percentage = min(max(0, Double(value.location.x / max(geometry.size.width, 1))), 1.0)
                            playbackProgress.currentTime = percentage * trackDuration
                        }
                        .onEnded { value in
                            let percentage = min(max(0, Double(value.location.x / max(geometry.size.width, 1))), 1.0)
                            onSeek(percentage * trackDuration)
                        }
                )
            }
            .frame(height: barHeight)

            HStack {
                Text(formatDuration(playbackProgress.currentTime))
                    .font(.caption2)
                    .foregroundColor(.gray)
                Spacer()
                Text("-\(formatDuration(max(0, trackDuration - playbackProgress.currentTime)))")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let total = Int(max(0, duration))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct QueueView: View {
    @EnvironmentObject var audioService: AudioPlayerService
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            List {
                ForEach(Array(audioService.queue.enumerated()), id: \.offset) { index, track in
                    Button(action: {
                        audioService.playFromQueue(at: index)
                    }) {
                        HStack(spacing: 12) {
                            if index == audioService.queueIndex {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                    .frame(width: 20)
                            } else {
                                Color.clear
                                    .frame(width: 20, height: 1)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .foregroundColor(index == audioService.queueIndex ? .white : .primary)
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Playing Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button(action: { audioService.toggleShuffle() }) {
                        Image(systemName: "shuffle")
                            .foregroundColor(audioService.state.isShuffleEnabled ? .white : .gray)
                    }
                    Button(action: { audioService.cycleRepeatMode() }) {
                        Image(systemName: audioService.state.repeatMode == .one ? "repeat.1" : "repeat")
                            .foregroundColor(audioService.state.repeatMode != .off ? .white : .gray)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

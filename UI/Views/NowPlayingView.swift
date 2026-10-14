import SwiftUI

struct ScrollOffsetPreferenceKey: PreferenceKey {
    typealias Value = CGFloat
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct NowPlayingView: View {
    @EnvironmentObject var audioService: AudioPlayerService
    @EnvironmentObject var navManager: NavigationManager
    @EnvironmentObject var connectionService: ServerConnectionService
    @Binding var expand: Bool
    @AppStorage("RC_ShowVolumeSlider") private var showVolumeSlider: Bool = false
    @State private var isScrubbing: Bool = false
    @State private var scrollOffset: CGFloat = 0
    @State private var selectedTrackForDelete: Track? = nil
    @State private var showTrackDeleteConfirmation = false
    @State private var showMenu = false
    
    var body: some View {
        ZStack {
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
                
                VStack(spacing: 0) {
                    // Header (Dismiss button) - Fixed at top
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
                        Text("Now Playing")
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        if let _ = audioService.state.currentTrack {
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showMenu.toggle()
                                }
                            }) {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 24))
                                    .foregroundColor(.white.opacity(0.8))
                                    .padding()
                            }
                        } else {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 24))
                                .foregroundColor(.white.opacity(0.8))
                                .opacity(0)
                                .padding()
                        }
                    }
                    .frame(height: 50)
                    .contentShape(Rectangle())
                    .ipadSwipeDownGesture {
                        withAnimation {
                            expand = false
                        }
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
                                        navManager.navigateToAlbum(title: track.album)
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
                                
                                // Scrub Bar
                                VStack(spacing: 0) {
                                    GeometryReader { scrubGeo in
                                        ZStack(alignment: .leading) {
                                            Rectangle()
                                                .fill(Color.black.opacity(0.001))
                                                .frame(width: scrubGeo.size.width, height: 36)
                                            
                                            Rectangle()
                                                .fill(Color.white.opacity(0.2))
                                                .frame(width: scrubGeo.size.width, height: 4)
                                                .cornerRadius(2)
                                            
                                            Rectangle()
                                                .fill(Color.white)
                                                .frame(width: scrubGeo.size.width * CGFloat(audioService.state.currentTime / max(audioService.state.currentTrack?.duration ?? 1, 1)), height: 4)
                                                .cornerRadius(2)
                                        }
                                        .contentShape(Rectangle())
                                        .gesture(
                                            DragGesture(minimumDistance: 0)
                                                .onChanged { value in
                                                    isScrubbing = true
                                                    let percentage = min(max(0, Double(value.location.x / scrubGeo.size.width)), 1.0)
                                                    let newTime = percentage * (audioService.state.currentTrack?.duration ?? 0)
                                                    audioService.state.currentTime = newTime
                                                }
                                                .onEnded { value in
                                                    let percentage = min(max(0, Double(value.location.x / scrubGeo.size.width)), 1.0)
                                                    let newTime = percentage * (audioService.state.currentTrack?.duration ?? 0)
                                                    audioService.seek(to: newTime)
                                                    isScrubbing = false
                                                }
                                        )
                                    }
                                    .frame(height: 36)
                                    
                                    HStack {
                                        Text(formatDuration(audioService.state.currentTime))
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                        Spacer()
                                        Text(formatDuration(audioService.state.currentTrack?.duration ?? 0))
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                }
                                
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
                                        Image(systemName: audioService.state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                            .font(.system(size: 68))
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
                                
                                Spacer()
                            }
                            .padding(.trailing, 40)
                        }
                        .frame(width: geometry.size.width, height: screenHeight - 50)
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 0) {
                                // Anchor to track scroll offset
                                GeometryReader { geo in
                                    Color.clear
                                        .preference(key: ScrollOffsetPreferenceKey.self, value: geo.frame(in: .named("scroll")).minY)
                                }
                                .frame(height: 0)
                                
                                // Main content taking up full visible height
                                VStack {
                                    Spacer(minLength: 10)
                                    
                                    // Artwork - Maximize size with high priority
                                    Group {
                                        if let artworkUrl = audioService.state.currentTrack?.artworkUrl {
                                            RemoteImage(url: artworkUrl)
                                                .aspectRatio(1.0, contentMode: .fit)
                                                .cornerRadius(12)
                                                // Keep the artwork's depth below it so its shadow does not
                                                // darken the backdrop behind the fixed Now Playing header.
                                                .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 8)
                                        } else {
                                            Rectangle()
                                                .fill(Color.gray.opacity(0.3))
                                                .aspectRatio(1.0, contentMode: .fit)
                                                .overlay(
                                                    Image(systemName: "music.note")
                                                        .font(.system(size: 60))
                                                        .foregroundColor(.white)
                                                )
                                                .cornerRadius(12)
                                                .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 8)
                                        }
                                    }
                                    .layoutPriority(1) // Ensure artwork gets space first
                                    .padding(.horizontal, 10)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if let track = audioService.state.currentTrack {
                                            navManager.navigateToAlbum(title: track.album)
                                            withAnimation { expand = false }
                                        }
                                    }
                                    
                                    Spacer(minLength: 20)
                                    
                                    // Info + Scrub Bar group
                                    VStack(spacing: 15) {
                                        // Info
                                        VStack(spacing: 4) {
                                            Text(audioService.state.currentTrack?.title ?? "Not Playing")
                                                .font(.title2)
                                                .bold()
                                                .foregroundColor(.white)
                                                .multilineTextAlignment(.center)
                                            
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
                                        .padding(.horizontal, 20)
                                        
                                        // Scrub Bar
                                        VStack(spacing: 0) {
                                            GeometryReader { geometry in
                                                ZStack(alignment: .leading) {
                                                    // Hit Zone
                                                    Rectangle()
                                                        .fill(Color.black.opacity(0.001))
                                                        .frame(width: geometry.size.width, height: 40)
                                                    
                                                    // Visible Track background
                                                    Rectangle()
                                                        .fill(Color.white.opacity(0.2))
                                                        .frame(width: geometry.size.width, height: 4)
                                                    
                                                    // Active progress
                                                    Rectangle()
                                                        .fill(Color.white)
                                                        .frame(width: geometry.size.width * CGFloat(audioService.state.currentTime / max(audioService.state.currentTrack?.duration ?? 1, 1)), height: 4)
                                                }
                                                .contentShape(Rectangle())
                                                .gesture(
                                                    DragGesture(minimumDistance: 0)
                                                        .onChanged { value in
                                                            isScrubbing = true
                                                            let percentage = min(max(0, Double(value.location.x / geometry.size.width)), 1.0)
                                                            let newTime = percentage * (audioService.state.currentTrack?.duration ?? 0)
                                                            audioService.state.currentTime = newTime
                                                        }
                                                        .onEnded { value in
                                                            let percentage = min(max(0, Double(value.location.x / geometry.size.width)), 1.0)
                                                            let newTime = percentage * (audioService.state.currentTrack?.duration ?? 0)
                                                            audioService.seek(to: newTime)
                                                            isScrubbing = false
                                                        }
                                                )
                                            }
                                            .frame(height: 40)
                                            
                                            HStack {
                                                Text(formatDuration(audioService.state.currentTime))
                                                    .font(.caption2)
                                                    .foregroundColor(.gray)
                                                Spacer()
                                                Text(formatDuration(audioService.state.currentTrack?.duration ?? 0))
                                                    .font(.caption2)
                                                    .foregroundColor(.gray)
                                            }
                                        }
                                        .padding(.horizontal, 40)
                                    }
                                    
                                    Spacer(minLength: 20)
                                    
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
                                            Image(systemName: audioService.state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                                .font(.system(size: 68))
                                                .foregroundColor(.white)
                                                .frame(width: 68, height: 68)
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
                                    
                                    Spacer(minLength: 30)
                                }
                                .frame(width: geometry.size.width, height: screenHeight - 50)
                                .contentShape(Rectangle())
                                
                                if showVolumeSlider {
                                    // Volume Section (Sits below the fold)
                                    HStack(spacing: 15) {
                                        Image(systemName: "speaker.fill")
                                            .foregroundColor(.white.opacity(0.6))
                                            .font(.system(size: 12))
                                        
                                        GeometryReader { sliderGeo in
                                            ZStack(alignment: .leading) {
                                                // Hit Zone
                                                Rectangle()
                                                    .fill(Color.black.opacity(0.001))
                                                    .frame(width: sliderGeo.size.width, height: 30)
                                                
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
                                    .padding(.horizontal, 40)
                                    .padding(.bottom, 50)
                                    .frame(height: 100)
                                }
                            }
                            .frame(width: geometry.size.width)
                        }
                        .background(Color.clear)
                        .hideScrollBackground()
                        .coordinateSpace(name: "scroll")
                        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                            scrollOffset = value
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
                
                // Floating options menu card
                VStack {
                    HStack {
                        Spacer()
                        VStack(alignment: .leading, spacing: 0) {
                            if let currentTrack = audioService.state.currentTrack {
                                Button(action: {
                                    withAnimation { showMenu = false }
                                    navManager.navigateToAlbum(title: currentTrack.album)
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
                        .padding(.top, 55) // Align below the header
                        .padding(.trailing, 16)
                    }
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)))
                .zIndex(100)
            }
        }
        .background(Color.black.edgesIgnoringSafeArea(.all))
        .alert(isPresented: $showTrackDeleteConfirmation) {
            Alert(
                title: Text("Delete Song"),
                message: Text("Are you sure you want to permanently delete '\(selectedTrackForDelete?.title ?? "")' from this device? This action cannot be undone."),
                primaryButton: .destructive(Text("Delete")) {
                    if let track = selectedTrackForDelete {
                        let libraryService = MusicLibraryService(connectionService: connectionService)
                        if libraryService.deleteTrack(track) {
                            audioService.removeTrackFromQueue(track: track)
                            NotificationCenter.default.post(name: .trackDidDelete, object: track)
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
    
    func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
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
                    if value.translation.height > 40 {
                        onDismiss()
                    }
                }
            )
        } else {
            self
        }
    }
}

import SwiftUI
import AVKit

/// iPhone Now Playing (portrait and landscape), styled after the iOS 15 Music app.
/// Measurements live in `MusicPlayerMetrics`.
struct MusicPlayerScreen: View {
    @EnvironmentObject var audioService: AudioPlayerService
    @EnvironmentObject var navManager: NavigationManager
    @Binding var expand: Bool
    @Binding var showQueue: Bool
    @Binding var showMenu: Bool
    let audioOutputName: String
    let showVolumeSlider: Bool

    @StateObject private var tint = ArtworkTintProvider()
    @State private var dragOffset: CGFloat = 0
    @State private var isScrubbing = false

    private typealias M = MusicPlayerMetrics

    private var track: Track? { audioService.state.currentTrack }
    private var duration: Double { max(track?.duration ?? 1, 1) }
    private var progress: CGFloat { CGFloat(min(max(audioService.state.currentTime / duration, 0), 1)) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let insets = geo.safeAreaInsets

            ZStack(alignment: .topLeading) {
                MusicPlayerBackground(tint: tint.color)
                    .frame(width: w, height: h)

                if w > h {
                    landscape(width: w, height: h, insets: insets)
                } else {
                    portrait(width: w, height: h, insets: insets)
                }
            }
            .frame(width: w, height: h, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .offset(y: dragOffset)
        .onAppear { tint.update(url: track?.artworkUrl) }
        .onChange(of: track?.artworkUrl) { tint.update(url: $0) }
    }

    // MARK: - Portrait

    private func portrait(width w: CGFloat, height h: CGFloat, insets: EdgeInsets) -> some View {
        let bottom = h - insets.bottom
        let artworkTop = insets.top + M.grabberCenterBelowSafeTop
        let artworkBottom = bottom - M.titleBlockHeightFromBottom
        let playingSide = min(w - M.artworkHorizontalInset * 2, artworkBottom - artworkTop)
        let side = audioService.state.isPlaying ? playingSide : playingSide * M.artworkPausedScale

        return ZStack(alignment: .topLeading) {
            // Grabber + artwork (drag to dismiss)
            ZStack {
                Capsule()
                    .musicAdditive(MusicPlayerAlpha.grabber)
                    .frame(width: M.grabberSize.width, height: M.grabberSize.height)
                    .position(x: w / 2, y: artworkTop)

                artwork(side: side)
                    .position(x: w / 2, y: (artworkTop + artworkBottom) / 2)
            }
            .frame(width: w, height: artworkBottom)
            .contentShape(Rectangle())
            .gesture(dismissDrag)

            portraitTitleBlock(width: w, bottom: bottom)
            portraitScrubber(width: w, bottom: bottom)
            portraitTransport(width: w, bottom: bottom)
            if showVolumeSlider {
                portraitVolume(width: w, bottom: bottom)
            }
            portraitUtilityRow(width: w, bottom: bottom)
        }
    }

    private func portraitTitleBlock(width w: CGFloat, bottom: CGFloat) -> some View {
        let textWidth = w - M.titleLeading - M.moreButtonTrailing - M.moreButtonDiameter - 8
        let title = track?.title ?? "Not Playing"
        let artistText = track?.artist ?? "Select Music"
        let artistParts = artistText.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }

        return ZStack(alignment: .topLeading) {
            MarqueeContainer(id: title) {
                Text(title)
                    .font(.system(size: M.titleFontSize, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: textWidth, height: M.titleLineHeight)
            .position(x: M.titleLeading + textWidth / 2, y: bottom - M.titleCenterFromBottom)

            MarqueeContainer(id: artistText) {
                HStack(spacing: 0) {
                    ForEach(artistParts.indices, id: \.self) { index in
                        Text(artistParts[index])
                            .onTapGesture {
                                navManager.navigateToArtist(name: artistParts[index])
                                withAnimation { expand = false }
                            }
                        if index < artistParts.count - 1 {
                            Text(", ")
                        }
                    }
                }
                .font(.system(size: M.titleFontSize, weight: .regular))
                .musicAdditive(MusicPlayerAlpha.secondary)
            }
            .frame(width: textWidth, height: M.titleLineHeight)
            .position(x: M.titleLeading + textWidth / 2, y: bottom - M.artistCenterFromBottom)

            moreButton
                .position(x: w - M.moreButtonTrailing - M.moreButtonDiameter / 2, y: bottom - M.moreButtonCenterFromBottom)
        }
    }

    private func portraitScrubber(width w: CGFloat, bottom: CGFloat) -> some View {
        let trackWidth = w - M.sideMargin * 2
        let thickness = isScrubbing ? M.scrubberTrackActive : M.scrubberTrack

        return ZStack(alignment: .topLeading) {
            scrubberTrack(width: trackWidth, thickness: thickness)
                .position(x: w / 2, y: bottom - M.scrubberCenterFromBottom)

            timeLabels(width: trackWidth)
                .position(x: w / 2, y: bottom - M.timeCenterFromBottom)
        }
    }

    private func portraitTransport(width w: CGFloat, bottom: CGFloat) -> some View {
        let y = bottom - M.transportCenterFromBottom
        return ZStack {
            Button(action: { audioService.previous() }) {
                MusicSkipGlyph(forward: false)
                    .foregroundColor(.white)
                    .frame(width: 64, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MusicPressStyle())
            .accessibilityLabel("Previous")
            .position(x: w / 2 - M.transportSideOffset, y: y)

            Button(action: {
                if audioService.state.isPlaying { audioService.pause() } else { audioService.play() }
            }) {
                Group {
                    if audioService.state.isPlaying { MusicPauseGlyph() } else { MusicPlayGlyph() }
                }
                .foregroundColor(.white)
                .frame(width: 72, height: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(MusicPressStyle())
            .accessibilityLabel(audioService.state.isPlaying ? "Pause" : "Play")
            .position(x: w / 2 + M.playOpticalShift, y: y)

            Button(action: { audioService.next() }) {
                MusicSkipGlyph(forward: true)
                    .foregroundColor(.white)
                    .frame(width: 64, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MusicPressStyle())
            .accessibilityLabel("Next")
            .position(x: w / 2 + M.transportSideOffset, y: y)
        }
    }

    private func portraitVolume(width w: CGFloat, bottom: CGFloat) -> some View {
        let trackWidth = w - M.volumeTrackLeading * 2
        let y = bottom - M.volumeCenterFromBottom
        let level = CGFloat(audioService.state.volume)

        return ZStack(alignment: .topLeading) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11))
                .musicAdditive(MusicPlayerAlpha.secondary)
                .position(x: 36, y: y)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11))
                .musicAdditive(MusicPlayerAlpha.secondary)
                .position(x: w - 40, y: y)

            volumeSlider(trackWidth: trackWidth, level: level)
                .position(x: w / 2, y: y)
        }
    }

    private func portraitUtilityRow(width w: CGFloat, bottom: CGFloat) -> some View {
        let y = bottom - M.utilityCenterFromBottom

        return ZStack(alignment: .topLeading) {
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: 19))
                .musicAdditive(MusicPlayerAlpha.disabled)
                .position(x: w / 2 - M.utilitySideOffset, y: y)

            airPlayButton
                .position(x: w / 2, y: y)

            queueButton
                .position(x: w / 2 + M.utilitySideOffset, y: y)

            if let badge = queueBadgeSymbol {
                queueBadge(symbol: badge)
                    .position(x: w / 2 + M.utilitySideOffset + 12, y: y - 12.3)
            }

            Text(audioOutputName)
                .font(.system(size: M.deviceNameFontSize, weight: .semibold))
                .musicAdditive(MusicPlayerAlpha.secondary)
                .lineLimit(1)
                .frame(width: w - 64)
                .position(x: w / 2, y: bottom - M.deviceNameCenterFromBottom)
        }
    }

    // MARK: - Landscape

    private func landscape(width w: CGFloat, height h: CGFloat, insets: EdgeInsets) -> some View {
        let leftMargin = max(insets.leading, 24)
        let rightMargin = max(insets.trailing, 24)
        let availableH = h - insets.top - insets.bottom
        let maxSide = min(availableH - 24, (w - leftMargin - rightMargin - 44) * 0.44)
        let side = audioService.state.isPlaying ? maxSide : maxSide * M.artworkPausedScale
        let controlsW = max(240, w - maxSide - leftMargin - rightMargin - 44)

        return HStack(spacing: 36) {
            // Left column: dismiss button + artwork
            VStack(alignment: .leading, spacing: 10) {
                Button(action: {
                    withAnimation(.easeOut(duration: 0.25)) { expand = false }
                }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 20, weight: .semibold))
                        .musicAdditive(MusicPlayerAlpha.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MusicPressStyle())
                .accessibilityLabel("Close")

                Spacer(minLength: 0)

                HStack {
                    Spacer(minLength: 0)
                    artwork(side: side)
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)
            }
            .frame(width: maxSide)
            .padding(.leading, leftMargin)
            .gesture(dismissDrag)

            // Right column: responsive controls matching portrait exactly
            landscapeControls(width: controlsW)
                .padding(.trailing, rightMargin)
        }
        .frame(width: w, height: h)
    }

    private func landscapeControls(width w: CGFloat) -> some View {
        let title = track?.title ?? "Not Playing"
        let artistText = track?.artist ?? "Select Music"
        let artistParts = artistText.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let textWidth = max(100, w - M.moreButtonDiameter - 16)
        let thickness = isScrubbing ? M.scrubberTrackActive : M.scrubberTrack

        return VStack(spacing: 0) {
            Spacer(minLength: 2)

            // 1. Title Block
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeContainer(id: title) {
                        Text(title)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(width: textWidth, height: 24)

                    MarqueeContainer(id: artistText) {
                        HStack(spacing: 0) {
                            ForEach(artistParts.indices, id: \.self) { index in
                                Text(artistParts[index])
                                    .onTapGesture {
                                        navManager.navigateToArtist(name: artistParts[index])
                                        withAnimation { expand = false }
                                    }
                                if index < artistParts.count - 1 {
                                    Text(", ")
                                }
                            }
                        }
                        .font(.system(size: 19, weight: .regular))
                        .musicAdditive(MusicPlayerAlpha.secondary)
                    }
                    .frame(width: textWidth, height: 24)
                }

                Spacer(minLength: 0)

                moreButton
            }
            .frame(width: w)

            Spacer(minLength: 8)

            // 2. Scrubber
            VStack(spacing: 4) {
                scrubberTrack(width: w, thickness: thickness)
                timeLabels(width: w)
            }
            .frame(width: w)

            Spacer(minLength: 8)

            // 3. Transport
            HStack(spacing: 0) {
                Spacer()
                Button(action: { audioService.previous() }) {
                    MusicSkipGlyph(forward: false)
                        .foregroundColor(.white)
                        .frame(width: 56, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MusicPressStyle())
                .accessibilityLabel("Previous")

                Spacer()

                Button(action: {
                    if audioService.state.isPlaying { audioService.pause() } else { audioService.play() }
                }) {
                    Group {
                        if audioService.state.isPlaying { MusicPauseGlyph() } else { MusicPlayGlyph() }
                    }
                    .foregroundColor(.white)
                    .frame(width: 64, height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MusicPressStyle())
                .accessibilityLabel(audioService.state.isPlaying ? "Pause" : "Play")

                Spacer()

                Button(action: { audioService.next() }) {
                    MusicSkipGlyph(forward: true)
                        .foregroundColor(.white)
                        .frame(width: 56, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MusicPressStyle())
                .accessibilityLabel("Next")
                Spacer()
            }
            .frame(width: w)

            Spacer(minLength: 8)

            // 4. Volume
            if showVolumeSlider {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 11))
                        .musicAdditive(MusicPlayerAlpha.secondary)

                    volumeSlider(trackWidth: max(60, w - 64), level: CGFloat(audioService.state.volume))

                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 11))
                        .musicAdditive(MusicPlayerAlpha.secondary)
                }
                .frame(width: w)

                Spacer(minLength: 8)
            }

            // 5. Utility Row & Output device
            VStack(spacing: 3) {
                HStack {
                    Spacer()
                    Image(systemName: "quote.bubble.fill")
                        .font(.system(size: 19))
                        .musicAdditive(MusicPlayerAlpha.disabled)

                    Spacer()

                    airPlayButton

                    Spacer()

                    ZStack(alignment: .topTrailing) {
                        queueButton
                        if let badge = queueBadgeSymbol {
                            queueBadge(symbol: badge)
                                .offset(x: 2, y: -2)
                        }
                    }

                    Spacer()
                }

                Text(audioOutputName)
                    .font(.system(size: M.deviceNameFontSize, weight: .semibold))
                    .musicAdditive(MusicPlayerAlpha.secondary)
                    .lineLimit(1)
            }
            .frame(width: w)

            Spacer(minLength: 2)
        }
    }

    // MARK: - Shared Subviews

    private var dismissDrag: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 400 {
                    withAnimation(.easeOut(duration: 0.25)) { expand = false }
                    dragOffset = 0
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dragOffset = 0 }
                }
            }
    }

    @ViewBuilder
    private func artwork(side: CGFloat) -> some View {
        Group {
            if let url = track?.artworkUrl {
                RemoteImage(url: url)
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .overlay(Image(systemName: "music.note").font(.system(size: 60)).foregroundColor(.white.opacity(0.6)))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: M.artworkRadius, style: .continuous))
        .shadow(color: Color.black.opacity(audioService.state.isPlaying ? 0.35 : 0.3), radius: 12, x: 0, y: 6)
        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: audioService.state.isPlaying)
        .onTapGesture {
            if let track = track {
                navManager.navigateToAlbum(title: track.album)
                withAnimation { expand = false }
            }
        }
    }

    private var moreButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) { showMenu.toggle() }
        }) {
            ZStack {
                Circle()
                    .musicAdditive(MusicPlayerAlpha.control)
                HStack(spacing: 2.5) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().frame(width: 3.5, height: 3.5)
                    }
                }
                .foregroundColor(.white.opacity(0.9))
            }
            .frame(width: M.moreButtonDiameter, height: M.moreButtonDiameter)
            .contentShape(Circle())
        }
        .buttonStyle(MusicPressStyle())
        .anchorPreference(key: MenuAnchorKey.self, value: .bounds) { $0 }
        .accessibilityLabel("More")
    }

    private func scrubberTrack(width trackWidth: CGFloat, thickness: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Color.clear.frame(width: trackWidth, height: 32)

            Capsule()
                .musicAdditive(MusicPlayerAlpha.remaining)
                .frame(width: trackWidth, height: thickness)

            Capsule()
                .musicAdditive(MusicPlayerAlpha.secondary)
                .frame(width: max(thickness, trackWidth * progress), height: thickness)

            if !isScrubbing {
                Circle()
                    .musicAdditive(MusicPlayerAlpha.secondary)
                    .frame(width: M.scrubberKnob, height: M.scrubberKnob)
                    .offset(x: trackWidth * progress - M.scrubberKnob / 2)
            }
        }
        .frame(width: trackWidth, height: 32)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    withAnimation(.easeOut(duration: 0.12)) { isScrubbing = true }
                    let pct = min(max(0, Double(value.location.x / trackWidth)), 1)
                    audioService.state.currentTime = pct * (track?.duration ?? 0)
                }
                .onEnded { value in
                    let pct = min(max(0, Double(value.location.x / trackWidth)), 1)
                    audioService.seek(to: pct * (track?.duration ?? 0))
                    withAnimation(.easeOut(duration: 0.12)) { isScrubbing = false }
                }
        )
    }

    private func timeLabels(width: CGFloat) -> some View {
        HStack {
            Text(formatTime(audioService.state.currentTime))
            Spacer()
            Text("-" + formatTime(max(0, (track?.duration ?? 0) - audioService.state.currentTime)))
        }
        .font(.system(size: M.timeFontSize, weight: .medium).monospacedDigit())
        .musicAdditive(MusicPlayerAlpha.time)
        .frame(width: width)
    }

    private func volumeSlider(trackWidth: CGFloat, level: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Color.clear.frame(width: trackWidth + M.volumeKnob, height: 36)

            Capsule()
                .musicAdditive(MusicPlayerAlpha.remaining)
                .frame(width: trackWidth, height: M.volumeTrack)
                .offset(x: M.volumeKnob / 2)

            Capsule()
                .musicAdditive(MusicPlayerAlpha.secondary)
                .frame(width: trackWidth * level, height: M.volumeTrack)
                .offset(x: M.volumeKnob / 2)

            Circle()
                .fill(Color.white)
                .frame(width: M.volumeKnob, height: M.volumeKnob)
                .offset(x: trackWidth * level)
        }
        .frame(width: trackWidth + M.volumeKnob, height: 36)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let pct = min(max(0, Float((value.location.x - M.volumeKnob / 2) / trackWidth)), 1)
                    audioService.setVolume(pct)
                }
        )
    }

    private var airPlayButton: some View {
        ZStack {
            AirPlayRoutePicker()
            Image(systemName: "airplayaudio")
                .font(.system(size: 22))
                .musicAdditive(MusicPlayerAlpha.secondary)
                .allowsHitTesting(false)
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel("AirPlay")
    }

    private var queueButton: some View {
        Button(action: { showQueue = true }) {
            MusicQueueGlyph()
                .musicAdditive(MusicPlayerAlpha.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(MusicPressStyle())
        .accessibilityLabel("Queue")
    }

    private func queueBadge(symbol: String) -> some View {
        ZStack {
            Circle().musicAdditive(0.12)
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: 19.5, height: 19.5)
        .allowsHitTesting(false)
    }

    private var queueBadgeSymbol: String? {
        if audioService.state.isShuffleEnabled { return "shuffle" }
        switch audioService.state.repeatMode {
        case .off: return nil
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let total = Int(max(0, t))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

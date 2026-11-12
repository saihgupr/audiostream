import SwiftUI
import UIKit
import Combine

// MARK: - Metrics
//
// Every value here was measured from iOS 15 Apple Music screenshots taken on a
// 414 x 736 pt iPhone (Plus, @3x). Vertical positions of the lower controls are
// stored as distance from the bottom of the screen so they hold on other heights.

enum MusicPlayerMetrics {
    static let sideMargin: CGFloat = 32

    // Top
    static let grabberSize = CGSize(width: 36, height: 5)
    static let grabberCenterBelowSafeTop: CGFloat = 24
    static let artworkRadius: CGFloat = 10
    static let artworkPausedScale: CGFloat = 0.8
    static let artworkHorizontalInset: CGFloat = 42      // playing artwork = width - 2 * inset

    // Title block (center Y, measured up from the bottom anchor)
    static let titleCenterFromBottom: CGFloat = 267.5
    static let artistCenterFromBottom: CGFloat = 243.5
    static let titleLineHeight: CGFloat = 24
    static let titleLeading: CGFloat = 28
    static let titleFontSize: CGFloat = 21
    static let moreButtonDiameter: CGFloat = 28
    static let moreButtonCenterFromBottom: CGFloat = 256
    static let moreButtonTrailing: CGFloat = 32

    // Scrubber
    static let scrubberCenterFromBottom: CGFloat = 225
    static let scrubberTrack: CGFloat = 3
    static let scrubberTrackActive: CGFloat = 7
    static let scrubberKnob: CGFloat = 6
    static let timeCenterFromBottom: CGFloat = 205
    static let timeFontSize: CGFloat = 13

    // Transport
    static let transportCenterFromBottom: CGFloat = 154.5
    static let transportSideOffset: CGFloat = 97
    static let playOpticalShift: CGFloat = 2
    static let rewindSize = CGSize(width: 33, height: 19)
    static let playSize = CGSize(width: 28, height: 31)

    // Volume
    static let volumeCenterFromBottom: CGFloat = 89.7
    static let volumeTrackLeading: CGFloat = 56
    static let volumeTrack: CGFloat = 3
    static let volumeKnob: CGFloat = 20

    // Utility row
    static let utilityCenterFromBottom: CGFloat = 44
    static let utilitySideOffset: CGFloat = 102.5
    static let deviceNameCenterFromBottom: CGFloat = 17.7
    static let deviceNameFontSize: CGFloat = 12.5

    // The reference is 736 pt tall; Music lays the title block out at this offset from the top of the controls
    static let titleBlockHeightFromBottom: CGFloat = 280
}

// MARK: - Secondary color
//
// Music draws every secondary element as white that is *added* to the tinted
// background (plus-lighter), which is why they pick up the artwork color.

enum MusicPlayerAlpha {
    static let secondary: Double = 0.45       // artist, elapsed track, utility icons, device name
    static let remaining: Double = 0.17       // un-played track
    static let time: Double = 0.2             // time labels
    static let disabled: Double = 0.08        // unavailable lyrics button
    static let control: Double = 0.08         // more-button disc
    static let grabber: Double = 0.18
}

extension View {
    func musicAdditive(_ alpha: Double) -> some View {
        self.foregroundColor(Color.white.opacity(alpha)).blendMode(.plusLighter)
    }
}

// MARK: - Artwork tint

final class ArtworkTintProvider: ObservableObject {
    @Published var color: Color = Color(red: 0.2, green: 0.2, blue: 0.21)

    private let loader = ImageLoader()
    private var cancellable: AnyCancellable?
    private var currentURL: URL?

    init() {
        cancellable = loader.$image
            .compactMap { $0 }
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .map { Self.backgroundColor(for: $0) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ui in
                self?.color = Color(ui)
            }
    }

    func update(url: URL?) {
        guard url != currentURL else { return }
        currentURL = url
        if let url = url {
            loader.load(url: url)
        } else {
            color = Color(red: 0.2, green: 0.2, blue: 0.21)
        }
    }

    /// Average the artwork, then push saturation and brightness up slightly the way Music's
    /// backdrop does (measured: artwork avg 89/66/51 became 93/64/44).
    static func backgroundColor(for image: UIImage) -> UIColor {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let cg = image.cgImage,
              let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return UIColor(red: 0.2, green: 0.2, blue: 0.21, alpha: 1)
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        let count = CGFloat(side * side)
        for i in 0..<(side * side) {
            r += CGFloat(pixels[i * 4])
            g += CGFloat(pixels[i * 4 + 1])
            b += CGFloat(pixels[i * 4 + 2])
        }
        let avg = UIColor(red: r / count / 255, green: g / count / 255, blue: b / count / 255, alpha: 1)

        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        avg.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return UIColor(hue: h, saturation: min(1, s * 1.2), brightness: min(1, max(v * 1.05, 0.18)), alpha: 1)
    }
}

// MARK: - Background

struct MusicPlayerBackground: View {
    let tint: Color

    var body: some View {
        ZStack {
            tint
            // Slight horizontal falloff (left reads a little lighter than right)
            LinearGradient(colors: [.clear, Color.black.opacity(0.08)], startPoint: .leading, endPoint: .trailing)
            // Bottom half fades to half-black, starting 52.6% down (387 of 736 pt)
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0.526),
                    .init(color: Color.black.opacity(0.5), location: 1)
                ]),
                startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.5), value: tint)
    }
}

// MARK: - Glyphs

private struct RoundedTriangle: Shape {
    var pointsRight: Bool
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = radius
        let inner = rect.insetBy(dx: r, dy: r)
        var p = Path()
        if pointsRight {
            p.move(to: CGPoint(x: inner.minX, y: inner.minY))
            p.addLine(to: CGPoint(x: inner.maxX, y: inner.midY))
            p.addLine(to: CGPoint(x: inner.minX, y: inner.maxY))
        } else {
            p.move(to: CGPoint(x: inner.maxX, y: inner.minY))
            p.addLine(to: CGPoint(x: inner.minX, y: inner.midY))
            p.addLine(to: CGPoint(x: inner.maxX, y: inner.maxY))
        }
        p.closeSubpath()
        return p
    }
}

private struct RoundedTriangleGlyph: View {
    var pointsRight: Bool
    var radius: CGFloat
    var size: CGSize

    var body: some View {
        ZStack {
            RoundedTriangle(pointsRight: pointsRight, radius: radius).fill(Color.white)
            RoundedTriangle(pointsRight: pointsRight, radius: radius)
                .stroke(Color.white, style: StrokeStyle(lineWidth: radius * 2, lineJoin: .round))
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Two touching triangles, 33 x 19 pt (rewind) like Music's transport glyph.
struct MusicSkipGlyph: View {
    var forward: Bool

    var body: some View {
        let size = MusicPlayerMetrics.rewindSize
        let tri = CGSize(width: 17, height: size.height)
        HStack(spacing: -0.5) {
            RoundedTriangleGlyph(pointsRight: forward, radius: 1.6, size: tri)
            RoundedTriangleGlyph(pointsRight: forward, radius: 1.6, size: tri)
        }
        .frame(width: size.width, height: size.height)
    }
}

struct MusicPlayGlyph: View {
    var body: some View {
        RoundedTriangleGlyph(pointsRight: true, radius: 2.6, size: MusicPlayerMetrics.playSize)
    }
}

struct MusicPauseGlyph: View {
    var body: some View {
        let size = MusicPlayerMetrics.playSize
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Color.white).frame(width: 9.5, height: size.height - 1)
            RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Color.white).frame(width: 9.5, height: size.height - 1)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// List glyph used by Music's "Playing Next" button: bullets plus three lines, the first one shorter.
struct MusicQueueGlyph: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3.4) {
            row(lineWidth: 12)
            row(lineWidth: 15)
            row(lineWidth: 15)
        }
        .frame(width: 21, height: 18)
    }

    private func row(lineWidth: CGFloat) -> some View {
        HStack(spacing: 2.6) {
            Circle().frame(width: 3.4, height: 3.4)
            Capsule().frame(width: lineWidth, height: 3.4)
        }
    }
}

struct MusicPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Marquee

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Single-line container that scrolls its content back and forth when it does not fit,
/// fading the trailing edge, like Music's title and artist lines.
struct MarqueeContainer<Content: View>: View {
    let id: String
    let content: Content
    @State private var contentWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    init(id: String, @ViewBuilder content: () -> Content) {
        self.id = id
        self.content = content()
    }

    var body: some View {
        GeometryReader { geo in
            let overflow = max(0, contentWidth - geo.size.width)
            content
                .fixedSize()
                .background(
                    GeometryReader { inner in
                        Color.clear.preference(key: MarqueeWidthKey.self, value: inner.size.width)
                    }
                )
                .offset(x: offset)
                .frame(width: geo.size.width, alignment: .leading)
                .mask(
                    HStack(spacing: 0) {
                        Color.black
                        if overflow > 0 {
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 20)
                        }
                    }
                )
                .onPreferenceChange(MarqueeWidthKey.self) { width in
                    contentWidth = width
                    restart(overflow: max(0, width - geo.size.width))
                }
                .onChange(of: id) { _ in
                    offset = 0
                    restart(overflow: max(0, contentWidth - geo.size.width))
                }
        }
        .clipped()
    }

    private func restart(overflow: CGFloat) {
        offset = 0
        guard overflow > 0 else { return }
        let distance = overflow + 24
        withAnimation(.linear(duration: Double(distance) / 30).delay(2).repeatForever(autoreverses: true)) {
            offset = -distance
        }
    }
}


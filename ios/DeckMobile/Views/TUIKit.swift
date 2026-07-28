import SwiftUI
import UIKit

// MARK: - Panel

/// The framed box the desktop app draws everything inside.
///
/// The header keeps the `deck://` path convention rather than a plain title — it is the
/// single strongest cue that this is the same app, and it survives the move to a phone
/// where the surrounding chrome cannot.
struct TUIPanel<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder var content: Content
    @EnvironmentObject var app: MobileState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(app.theme.accent)
                    .frame(width: 2, height: 12)
                Text(title)
                    .font(DeckFont.mono(12))
                    .foregroundStyle(app.theme.fg)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(DeckFont.mono(10))
                        .foregroundStyle(app.theme.muted)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(app.theme.bgInset)
            .overlay(alignment: .bottom) {
                Rectangle().fill(app.theme.border).frame(height: 1)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(app.theme.bgAlt)
        .overlay(Rectangle().strokeBorder(app.theme.border, lineWidth: 1))
    }
}

// MARK: - Section label

struct SectionLabel: View {
    let text: String
    @EnvironmentObject var app: MobileState

    var body: some View {
        Text(text.uppercased())
            .font(DeckFont.mono(9, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(app.theme.muted)
    }
}

// MARK: - Bracket button

/// `[ label ]` — literal brackets, no chrome, as on the desktop.
///
/// The hit area is padded well beyond the glyphs: the desktop version could rely on a
/// cursor landing precisely, and a 24pt-tall run of text is not a touch target.
struct BracketButton: View {
    let label: String
    var tint: Color?
    var disabled: Bool = false
    let action: () -> Void

    @EnvironmentObject var app: MobileState

    var body: some View {
        Button(action: action) {
            Text("[ \(label) ]")
                .font(DeckFont.mono(12))
                .foregroundStyle(disabled ? app.theme.muted.opacity(0.4) : (tint ?? app.theme.accent))
                .padding(.vertical, 10)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - Artwork

/// Album art, loaded lazily and cached.
///
/// `MPMediaItemArtwork.image(at:)` renders on demand and is slow enough to stutter a
/// scroll if called synchronously in a row body, so the work happens in a task and the
/// result is cached by id and size bucket.
struct Artwork: View {
    let trackID: String?
    var size: CGFloat
    var cornerFallbackSymbol: String = "music.note"

    @EnvironmentObject var app: MobileState
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(app.theme.bgInset)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: cornerFallbackSymbol)
                    .font(.system(size: max(10, size * 0.28), weight: .light))
                    .foregroundStyle(app.theme.muted.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .overlay(Rectangle().strokeBorder(app.theme.border, lineWidth: 1))
        .task(id: trackID) { await load() }
    }

    private func load() async {
        guard let trackID else {
            ArtworkProbe.record(.nilID, size: size)
            image = nil
            return
        }
        if let cached = ArtworkCache.shared.image(for: trackID, size: size) {
            image = cached
            return
        }
        let pixels = CGSize(width: size * 2, height: size * 2)
        let loaded = await Task.detached(priority: .utility) {
            MusicLibrary.artwork(forID: trackID, size: pixels)
        }.value

        guard !Task.isCancelled else {
            ArtworkProbe.record(.cancelled, size: size)
            return
        }
        if let loaded { ArtworkCache.shared.store(loaded, for: trackID, size: size) }
        ArtworkProbe.record(loaded == nil ? .nilImage : .loaded, size: size)
        image = loaded
    }
}

/// Bounded in count rather than bytes, because the sizes here are known and small —
/// a row thumbnail and a full-width cover, nothing in between.
final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() { cache.countLimit = 240 }

    private func key(_ id: String, _ size: CGFloat) -> NSString {
        // Bucketed, so a 44pt row and a 52pt row share one decode.
        "\(id)@\(Int(size / 40))" as NSString
    }

    func image(for id: String, size: CGFloat) -> UIImage? {
        cache.object(forKey: key(id, size))
    }

    func store(_ image: UIImage, for id: String, size: CGFloat) {
        cache.setObject(image, forKey: key(id, size))
    }
}

// MARK: - Track row

/// One song. Swipe actions rather than a hover menu, since there is no hover.
struct TrackRow: View {
    let track: Track
    var index: Int?
    var showsArtwork: Bool = true
    var isCurrent: Bool = false
    let onTap: () -> Void

    @EnvironmentObject var app: MobileState

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                if let index {
                    Text(String(format: "%2d", index))
                        .font(DeckFont.mono(11))
                        .foregroundStyle(app.theme.muted.opacity(0.7))
                        .frame(width: 22, alignment: .trailing)
                }

                if showsArtwork {
                    Artwork(trackID: track.externalID, size: 44)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(DeckFont.mono(13))
                        .foregroundStyle(isCurrent ? app.theme.accent : app.theme.fg)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(DeckFont.mono(10))
                        .foregroundStyle(app.theme.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Text(track.duration.clockString)
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted.opacity(0.8))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isCurrent ? app.theme.selection.opacity(0.5) : Color.clear)
    }
}

// MARK: - Spectrum

/// The bar visualiser.
///
/// Draws whatever levels it is handed; it does not know or care whether they were
/// measured or generated. The labelling of that distinction belongs to the screen that
/// shows it, not here.
struct SpectrumBars: View {
    let levels: [Float]
    var tint: Color
    var barSpacing: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let count = max(levels.count, 1)
            let total = geo.size.width
            let width = max(1, (total - barSpacing * CGFloat(count - 1)) / CGFloat(count))

            HStack(alignment: .bottom, spacing: barSpacing) {
                ForEach(0..<count, id: \.self) { i in
                    let level = CGFloat(levels.indices.contains(i) ? levels[i] : 0)
                    Rectangle()
                        .fill(tint.opacity(0.35 + 0.65 * level))
                        .frame(
                            width: width,
                            height: max(2, level * geo.size.height))
                }
            }
            .frame(width: total, height: geo.size.height, alignment: .bottom)
            .animation(.linear(duration: 1.0 / 30.0), value: levels)
        }
    }
}

/// The spectrum, wired to the visualiser.
///
/// A separate view from `SpectrumBars` so that observing a 30 Hz object stays confined
/// to the bars themselves. If the enclosing screen observed it, the whole now-playing
/// layout would re-render thirty times a second.
struct SpectrumView: View {
    var tint: Color
    var barSpacing: CGFloat = 3

    @EnvironmentObject var visualizer: Visualizer

    var body: some View {
        SpectrumBars(levels: visualizer.levels, tint: tint, barSpacing: barSpacing)
    }
}

/// Elapsed-progress rule, one pixel tall.
///
/// Isolated for the same reason as `SpectrumView`: it is the only part of the mini
/// player that changes with the clock.
struct ProgressHairline: View {
    var color: Color

    @EnvironmentObject var clock: PlaybackClock

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(color)
                .frame(width: geo.size.width * CGFloat(clock.fraction), height: 1)
        }
        .frame(height: 1)
        .allowsHitTesting(false)
    }
}

// MARK: - Empty / status states

struct StatusMessage: View {
    let title: String
    var detail: String?
    var actionLabel: String?
    var action: (() -> Void)?

    @EnvironmentObject var app: MobileState

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(DeckFont.mono(13))
                .foregroundStyle(app.theme.fg)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(DeckFont.mono(11))
                    .foregroundStyle(app.theme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionLabel, let action {
                BracketButton(label: actionLabel, action: action)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Haptics

/// Used sparingly — on the transport and on swipe actions committing, where the finger
/// is already moving and there is no visual settle to confirm the action.
enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func commit() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

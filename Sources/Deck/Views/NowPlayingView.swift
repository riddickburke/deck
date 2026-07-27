import DeckCore
import SwiftUI

/// Full-window now-playing screen, opened by clicking the artwork in the transport bar.
/// Oversized cover, a large spectrum, and the transport — the "flip the record over and
/// just look at it" view. Escape or the close bracket dismisses it.
struct NowPlayingView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var player: Player
    @State private var tint: Color?

    private var album: Album? {
        guard let track = player.currentTrack else { return nil }
        return app.album(for: track.albumKey)
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                header

                GeometryReader { geo in
                    let artSize = min(geo.size.height * 0.62, geo.size.width * 0.42, 420)
                    HStack(spacing: 44) {
                        Spacer(minLength: 0)

                        ArtworkView(album: album, size: artSize)
                            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)

                        VStack(alignment: .leading, spacing: 14) {
                            trackInfo
                            BigSpectrum(bands: player.spectrum, height: 96)
                            scrubber
                            transport
                            details
                        }
                        .frame(maxWidth: 460, alignment: .leading)

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                upNext
            }
        }
        .task(id: album?.key) { await loadTint() }
    }

    // MARK: Background

    private var background: some View {
        ZStack {
            app.theme.bg
            // A wash of the cover's dominant colour, kept low so the screen still
            // reads as a terminal surface rather than a media player skin.
            RadialGradient(
                colors: [(tint ?? app.theme.accent).opacity(0.30), .clear],
                center: .center, startRadius: 40, endRadius: 620)
            if app.config.scanlines { Scanlines() }
        }
        .ignoresSafeArea()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(app.theme.accent)
                .frame(width: 2, height: 11)
            Text("nebula://now-playing")
                .font(DeckFont.mono(11))
                .foregroundStyle(app.theme.fg)
            Spacer()
            if let track = player.currentTrack {
                BracketButton(label: "go to album", compact: true) {
                    app.showNowPlaying = false
                    app.navigate(to: .album(track.albumKey))
                }
            }
            BracketButton(label: "close", compact: true) { app.showNowPlaying = false }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(app.theme.bgInset)
        .overlay(alignment: .bottom) { TUIDivider() }
    }

    // MARK: Info

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(player.currentTrack?.title ?? "nothing playing")
                .font(DeckFont.mono(24, weight: .semibold))
                .foregroundStyle(app.theme.fg)
                .lineLimit(2)
            Text(player.currentTrack?.artist ?? "—")
                .font(DeckFont.mono(14))
                .foregroundStyle(app.theme.accent)
                .lineLimit(1)
            Text(player.currentTrack?.album ?? "")
                .font(DeckFont.mono(11))
                .foregroundStyle(app.theme.muted)
                .lineLimit(1)
        }
    }

    private var details: some View {
        HStack(spacing: 14) {
            if let track = player.currentTrack {
                if track.isLossless {
                    tag("lossless", color: app.theme.green)
                }
                tag(track.codec.uppercased(), color: app.theme.muted)
                if let rate = track.sampleRate {
                    tag("\(String(format: "%.1f", Double(rate) / 1000)) kHz", color: app.theme.muted)
                }
                if let bitrate = track.bitrate {
                    tag("\(bitrate) kbps", color: app.theme.muted)
                }
                if let year = track.year {
                    tag(String(year), color: app.theme.muted)
                }
            }
            Spacer()
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(DeckFont.mono(9))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(Rectangle().strokeBorder(color.opacity(0.45), lineWidth: 1))
    }

    // MARK: Transport

    private var scrubber: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let fraction = player.duration > 0
                    ? min(1, max(0, player.position / player.duration)) : 0
                ZStack(alignment: .leading) {
                    Rectangle().fill(app.theme.border).frame(height: 4)
                    Rectangle().fill(app.theme.accent)
                        .frame(width: geo.size.width * fraction, height: 4)
                    Rectangle()
                        .fill(app.theme.fg)
                        .frame(width: 3, height: 12)
                        .offset(x: max(0, geo.size.width * fraction - 1.5))
                }
                .frame(height: 14)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onEnded { value in
                        guard player.duration > 0, geo.size.width > 0 else { return }
                        player.seek(to: min(1, max(0, value.location.x / geo.size.width))
                            * player.duration)
                    }
                )
            }
            .frame(height: 14)

            HStack {
                Text(player.position.clockString)
                Spacer()
                Text("-\(max(0, player.duration - player.position).clockString)")
            }
            .font(DeckFont.mono(10))
            .foregroundStyle(app.theme.muted)
        }
    }

    private var transport: some View {
        HStack(spacing: 16) {
            BracketButton(
                label: "⇄", tint: player.shuffle ? app.theme.green : nil
            ) { app.toggleShuffle() }
            BracketButton(label: "|◀") { player.previous() }
            BracketButton(
                label: player.isPlaying ? "‖ pause" : "▶ play", tint: app.theme.accent
            ) { player.toggle() }
            BracketButton(label: "▶|") { player.next() }
            BracketButton(
                label: player.repeatMode == .one ? "↻1" : "↻",
                tint: player.repeatMode == .off ? nil : app.theme.green
            ) { app.cycleRepeat() }
            Spacer()
            BlockMeter(fraction: Double(player.volume), width: 8, tint: app.theme.accent)
        }
    }

    // MARK: Up next

    private var upNext: some View {
        let upcoming = Array(player.queue.dropFirst(player.currentIndex + 1).prefix(4))
        return Group {
            if !upcoming.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    SectionLabel(text: "up next")
                        .padding(.bottom, 2)
                    ForEach(upcoming) { track in
                        HStack(spacing: 8) {
                            Text("·")
                                .foregroundStyle(app.theme.muted)
                            Text(track.title)
                                .foregroundStyle(app.theme.fg)
                                .lineLimit(1)
                            Text(track.artist)
                                .foregroundStyle(app.theme.muted)
                                .lineLimit(1)
                            Spacer()
                            Text(track.duration.clockString)
                                .foregroundStyle(app.theme.muted)
                        }
                        .font(DeckFont.mono(10))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(app.theme.bgAlt.opacity(0.75))
                .overlay(alignment: .top) { TUIDivider() }
            }
        }
    }

    private func loadTint() async {
        guard let album,
              let image = await ArtworkStore.shared.artwork(for: album),
              let dominant = image.dominantColor
        else { tint = nil; return }
        await MainActor.run { tint = Color(nsColor: dominant) }
    }
}

// MARK: - Large spectrum

/// The transport bar's meter scaled up: one column per band, drawn as stacked blocks so
/// it still reads as terminal output rather than a graphics-equaliser widget.
struct BigSpectrum: View {
    let bands: [Float]
    var height: CGFloat = 96
    @EnvironmentObject var app: AppState

    var body: some View {
        GeometryReader { geo in
            let count = max(bands.count, 1)
            let spacing: CGFloat = 3
            let columnWidth = max(2, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(bands.enumerated()), id: \.offset) { _, level in
                    let value = CGFloat(max(0.02, min(1, level)))
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(gradient(for: level))
                            .frame(width: columnWidth, height: geo.size.height * value)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .frame(height: height)
        .animation(.linear(duration: 0.07), value: bands)
    }

    private func gradient(for level: Float) -> LinearGradient {
        let top: Color = level > 0.82 ? app.theme.red
            : (level > 0.6 ? app.theme.yellow : app.theme.accent)
        return LinearGradient(
            colors: [top, top.opacity(0.35)],
            startPoint: .top, endPoint: .bottom)
    }
}

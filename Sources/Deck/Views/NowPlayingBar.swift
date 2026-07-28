import DeckCore
import SwiftUI

/// The transport strip that spans the full width of the window, the way Spotify and
/// Apple Music both anchor playback. Art and metadata on the left, transport and
/// scrubber in the middle, spectrum and volume on the right.
struct NowPlayingBar: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var player: Player
    @State private var artHovering = false

    var body: some View {
        VStack(spacing: 0) {
            TUIDivider()
            HStack(spacing: 14) {
                nowPlayingInfo
                    .frame(width: 250, alignment: .leading)

                VStack(spacing: 4) {
                    transportControls
                    scrubber
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 14) {
                    SpectrumView(bands: app.spectrum)
                    volumeControl
                }
                .frame(width: 250, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(app.theme.bgAlt)
        }
    }

    // MARK: Left

    private var nowPlayingInfo: some View {
        HStack(spacing: 10) {
            // Tapping the cover opens the full now-playing screen.
            ArtworkView(album: currentAlbum, size: 46)
                .overlay {
                    if artHovering {
                        ZStack {
                            Color.black.opacity(0.45)
                            Text("⤢")
                                .font(DeckFont.mono(16))
                                .foregroundStyle(app.theme.fg)
                        }
                    }
                }
                .onHover { artHovering = $0 }
                .onTapGesture { app.showNowPlaying = true }
                .help("open now playing")

            VStack(alignment: .leading, spacing: 2) {
                Text(app.currentTrack?.title ?? "nothing playing")
                    .font(DeckFont.mono(11))
                    .foregroundStyle(app.currentTrack == nil ? app.theme.muted : app.theme.fg)
                    .lineLimit(1)
                Text(app.currentTrack.map { "\($0.artist) — \($0.album)" } ?? "—")
                    .font(DeckFont.mono(9))
                    .foregroundStyle(app.theme.muted)
                    .lineLimit(1)
            }
            // The text still jumps to the album; only the cover opens now playing.
            .contentShape(Rectangle())
            .onTapGesture {
                guard let track = app.currentTrack else { return }
                app.navigate(to: .album(track.albumKey))
            }

            Spacer(minLength: 0)
        }
    }

    private var currentAlbum: Album? {
        guard let track = app.currentTrack else { return nil }
        return app.album(for: track.albumKey)
    }

    // MARK: Centre

    private var transportControls: some View {
        HStack(spacing: 12) {
            BracketButton(
                label: "⇄", tint: player.shuffle ? app.theme.green : nil, compact: true
            ) { app.toggleShuffle() }

            BracketButton(label: "|◀", compact: true) { app.previousTrack() }

            BracketButton(
                label: app.isPlaying ? "‖ pause" : "▶ play",
                tint: app.theme.accent
            ) { app.togglePlayPause() }

            BracketButton(label: "▶|", compact: true) { app.nextTrack() }

            BracketButton(
                label: player.repeatMode == .one ? "↻1" : "↻",
                tint: player.repeatMode == .off ? nil : app.theme.green,
                compact: true
            ) { app.cycleRepeat() }
        }
    }

    private var scrubber: some View {
        HStack(spacing: 8) {
            Text(app.position.clockString)
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted)
                .frame(width: 38, alignment: .trailing)

            GeometryReader { geo in
                let fraction = app.duration > 0
                    ? min(1, max(0, app.position / app.duration)) : 0
                ZStack(alignment: .leading) {
                    Rectangle().fill(app.theme.border).frame(height: 3)
                    Rectangle().fill(app.theme.accent)
                        .frame(width: geo.size.width * fraction, height: 3)
                    // Square knob — a circle would break the terminal language.
                    Rectangle()
                        .fill(app.theme.fg)
                        .frame(width: 3, height: 9)
                        .offset(x: max(0, geo.size.width * fraction - 1.5))
                }
                .frame(height: 12)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onEnded { value in
                        guard app.duration > 0, geo.size.width > 0 else { return }
                        let ratio = min(1, max(0, value.location.x / geo.size.width))
                        app.seek(to: ratio * app.duration)
                    }
                )
            }
            .frame(height: 12)

            Text(app.duration.clockString)
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted)
                .frame(width: 38, alignment: .leading)
        }
        .frame(maxWidth: 520)
    }

    // MARK: Right

    private var volumeControl: some View {
        HStack(spacing: 6) {
            Text("vol")
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted)
            BlockMeter(fraction: Double(player.volume), width: 10, tint: app.theme.accent)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        // 10 blocks wide; map the drag across that span.
                        let ratio = min(1, max(0, value.location.x / 72))
                        player.volume = Float(ratio)
                        app.config.volume = Float(ratio)
                    }
                )
            Text(String(format: "%3d", Int(player.volume * 100)))
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted)
        }
    }
}

// MARK: - Spectrum

/// FFT bands rendered as block characters, which is how a terminal would draw a
/// level meter. Eight glyphs give eight steps of resolution per band.
struct SpectrumView: View {
    let bands: [Float]
    @EnvironmentObject var app: AppState

    private static let blocks = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(bands.enumerated()), id: \.offset) { _, level in
                Text(glyph(for: level))
                    .font(DeckFont.mono(11))
                    .foregroundStyle(color(for: level))
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.08), value: bands)
    }

    private func glyph(for level: Float) -> String {
        let index = Int((Double(level) * Double(Self.blocks.count - 1)).rounded())
        return Self.blocks[max(0, min(Self.blocks.count - 1, index))]
    }

    /// Green through yellow to red as bands approach clipping.
    private func color(for level: Float) -> Color {
        if !app.hasSpectrumSignal { return app.theme.muted.opacity(0.25) }
        if level > 0.82 { return app.theme.red }
        if level > 0.6 { return app.theme.yellow }
        if level > 0.05 { return app.theme.accent }
        return app.theme.muted.opacity(0.35)
    }
}

// MARK: - Status bar

/// Vim-style: mode indicator, context, position, flags.
struct StatusBar: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var player: Player

    var body: some View {
        HStack(spacing: 0) {
            segment(modeLabel, background: modeColor, foreground: app.theme.bg)
            segment(contextLabel, background: app.theme.selection, foreground: app.theme.fg)

            if app.isScanning, let progress = app.scanProgress {
                segment(
                    "indexing \(progress.scanned)/\(progress.total)",
                    background: app.theme.bgInset, foreground: app.theme.yellow)
            }
            if app.isEnriching, let progress = app.enrichProgress {
                segment(
                    "lookup \(progress.done)/\(progress.total)",
                    background: app.theme.bgInset, foreground: app.theme.magenta)
            }
            if app.isSyncing, let progress = app.syncProgress {
                segment(
                    "\(progress.phase) \(progress.completed)/\(progress.total)",
                    background: app.theme.bgInset, foreground: app.theme.green)
            }
            if app.isConverting, let progress = app.convertProgress {
                segment(
                    "converting \(progress.done)/\(progress.total)",
                    background: app.theme.bgInset, foreground: app.theme.cyan)
            }

            if let message = app.statusMessage {
                Text(message)
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted)
                    .padding(.horizontal, 10)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let error = player.lastError {
                segment(error, background: app.theme.red, foreground: app.theme.bg)
            }

            segment(app.player.repeatMode.symbol, background: .clear, foreground: app.theme.muted)
            segment(
                player.shuffle ? "shuf:on" : "shuf:off",
                background: .clear, foreground: app.theme.muted)
            segment(
                "\(app.position.clockString)/\(app.duration.clockString)",
                background: .clear, foreground: app.theme.muted)
            segment(app.theme.id, background: app.theme.selection, foreground: app.theme.fg)
        }
        .frame(height: 22)
        .background(app.theme.bgInset)
        .overlay(alignment: .top) { TUIDivider() }
    }

    private var modeLabel: String {
        if app.textInputFocused { return "SEARCH" }
        if app.showCommandPalette { return "COMMAND" }
        return "NORMAL"
    }

    private var modeColor: Color {
        if app.textInputFocused { return app.theme.yellow }
        if app.showCommandPalette { return app.theme.magenta }
        return app.theme.accent
    }

    private var contextLabel: String {
        switch app.route {
        case .albums: return "albums (\(app.filteredAlbums.count))"
        case .artists: return "artists (\(app.artistNames.count))"
        case .songs: return "songs (\(app.filteredTracks.count))"
        case .album(let key): return key.album
        case .artist(let name): return name
        case .playlist(let id): return app.playlist(id)?.name ?? "playlist"
        case .queue: return "queue (\(player.queue.count))"
        case .sync: return "sync"
        case .settings: return "settings"
        case .streaming: return "streaming"
        }
    }

    private func segment(_ text: String, background: Color, foreground: Color) -> some View {
        Text(text)
            .font(DeckFont.mono(10))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .background(background)
            .lineLimit(1)
    }
}

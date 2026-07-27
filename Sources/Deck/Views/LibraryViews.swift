import DeckCore
import SwiftUI

// MARK: - Album grid

/// The Spotify/Apple Music library surface: a dense grid of covers with the title and
/// artist beneath. Cards are square, unrounded, and gain an accent border on hover.
struct AlbumGridView: View {
    let albums: [Album]
    @EnvironmentObject var app: AppState

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(Array(albums.enumerated()), id: \.element.key) { index, album in
                        AlbumCard(album: album, selected: index == app.selectionIndex)
                            .id(index)
                            .onTapGesture(count: 2) { app.play(album: album) }
                            .onTapGesture {
                                app.selectionIndex = index
                                app.navigate(to: .album(album.key))
                            }
                    }
                }
                .padding(16)
            }
            .onChange(of: app.selectionIndex) { _, new in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }
}

struct AlbumCard: View {
    let album: Album
    var selected: Bool
    @EnvironmentObject var app: AppState
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(album: album, size: 150)
                if album.isLossless {
                    Text("lossless")
                        .font(DeckFont.mono(8))
                        .foregroundStyle(app.theme.bg)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(app.theme.green)
                        .padding(5)
                }
            }
            .overlay(
                Rectangle().strokeBorder(
                    selected ? app.theme.accent : (hovering ? app.theme.fg.opacity(0.5) : .clear),
                    lineWidth: 1)
            )

            Text(album.title)
                .font(DeckFont.mono(11))
                .foregroundStyle(app.theme.fg)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(album.artist)
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted)
                    .lineLimit(1)
                if let year = album.year {
                    Text("· \(String(year))")
                        .font(DeckFont.mono(10))
                        .foregroundStyle(app.theme.muted.opacity(0.7))
                }
            }
        }
        .frame(width: 150, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { AlbumMenu(album: album) }
    }
}

struct AlbumMenu: View {
    let album: Album
    @EnvironmentObject var app: AppState

    var body: some View {
        Button("play") { app.play(album: album) }
        Button("play next") { app.player.playNext(album.tracks) }
        Button("add to queue") { app.player.enqueue(album.tracks) }
        Divider()
        Menu("add to playlist") {
            ForEach(app.playlists) { playlist in
                Button(playlist.name) { app.addToPlaylist(playlist.id, tracks: album.tracks) }
            }
            if app.playlists.isEmpty { Text("no playlists yet") }
        }
        Button("new playlist from album") {
            app.createPlaylist(named: album.title, tracks: album.tracks)
        }
        Divider()
        ConvertMenu(tracks: album.tracks, label: "convert album to mp3")
        Divider()
        Button("refetch artwork") { app.refetchArtwork(for: album) }
        Button("reveal in finder") {
            if let dir = album.directory { NSWorkspace.shared.open(dir) }
        }
    }
}

// MARK: - Convert menu

/// Right-click → convert. Writes a new `.mp3` beside the original (or into a folder you
/// pick) and never touches the source file. Lossy tracks are filtered out, so converting
/// a mixed album only re-encodes the lossless parts.
struct ConvertMenu: View {
    let tracks: [Track]
    let label: String
    @EnvironmentObject var app: AppState

    private var convertible: [Track] {
        tracks.filter { Transcoder.convertibleFormats.contains($0.url.pathExtension.lowercased()) }
    }

    var body: some View {
        Menu(label) {
            if convertible.isEmpty {
                Text("nothing lossless to convert")
            } else {
                Text("\(convertible.count) file\(convertible.count == 1 ? "" : "s") · originals kept")
                Divider()
                ForEach(Self.qualities, id: \.value) { quality in
                    Button("\(quality.name) — beside original") {
                        app.convertToMP3(convertible, quality: quality.value)
                    }
                }
                Divider()
                Button("choose folder…") {
                    app.convertToMP3ChoosingFolder(convertible, quality: 0)
                }
            }
        }
        .disabled(app.isConverting)
    }

    private static let qualities: [(name: String, value: Int)] = [
        ("V0 · ~245 kbps", 0),
        ("V2 · ~190 kbps", 2),
        ("V4 · ~165 kbps", 4),
    ]
}

// MARK: - Album detail

/// Apple Music's album page: oversized art on the left, metadata and actions beside it,
/// tracklist below. The header is tinted with the cover's dominant colour.
struct AlbumDetailView: View {
    let album: Album
    @EnvironmentObject var app: AppState
    @State private var tint: Color?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                TUIDivider()
                TrackListView(tracks: album.tracks, showArtist: isCompilation, numbered: true)
                    .padding(.top, 4)
            }
        }
        .task(id: album.key) { await loadTint() }
    }

    private var isCompilation: Bool {
        Set(album.tracks.map(\.artist)).count > 1
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            ArtworkView(album: album, size: 190)

            VStack(alignment: .leading, spacing: 6) {
                Text(album.title)
                    .font(DeckFont.mono(20, weight: .semibold))
                    .foregroundStyle(app.theme.fg)
                    .lineLimit(2)

                Text(album.artist)
                    .font(DeckFont.mono(13))
                    .foregroundStyle(app.theme.accent)

                Text(metaLine)
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted)

                Spacer(minLength: 10)

                HStack(spacing: 10) {
                    BracketButton(label: "▶ play", tint: app.theme.green) { app.play(album: album) }
                    BracketButton(label: "⇄ shuffle") {
                        app.player.shuffle = true
                        app.config.shuffle = true
                        app.play(album: album)
                    }
                    BracketButton(label: "+ queue") { app.player.enqueue(album.tracks) }
                    BracketButton(label: "↻ art") { app.refetchArtwork(for: album) }
                }
            }
            Spacer()
        }
        .padding(18)
        .background(
            // Spotify-style wash from the cover's average colour, kept very low so the
            // panel still reads as a terminal surface.
            LinearGradient(
                colors: [(tint ?? app.theme.accent).opacity(0.22), .clear],
                startPoint: .top, endPoint: .bottom)
        )
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append("\(album.tracks.count) tracks")
        parts.append(album.duration.longString)
        parts.append(album.totalSize.byteString)
        let codecs = Set(album.tracks.map(\.codec)).sorted().joined(separator: "/")
        if !codecs.isEmpty { parts.append(codecs) }
        return parts.joined(separator: "  ·  ")
    }

    private func loadTint() async {
        guard let image = await ArtworkStore.shared.artwork(for: album),
              let dominant = image.dominantColor else { tint = nil; return }
        await MainActor.run { tint = Color(nsColor: dominant) }
    }
}

// MARK: - Track list

struct TrackListView: View {
    let tracks: [Track]
    var showArtist: Bool = true
    var numbered: Bool = false
    @EnvironmentObject var app: AppState

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(
                    track: track,
                    index: index,
                    showArtist: showArtist,
                    numbered: numbered,
                    selected: index == app.selectionIndex,
                    isCurrent: app.player.currentTrack?.id == track.id
                )
                .onTapGesture(count: 2) { app.play(tracks: tracks, startingAt: index) }
                .onTapGesture { app.selectionIndex = index }
                .contextMenu {
                    Button("play") { app.play(tracks: tracks, startingAt: index) }
                    Button("play next") { app.player.playNext([track]) }
                    Button("add to queue") { app.player.enqueue([track]) }
                    Divider()
                    Menu("add to playlist") {
                        ForEach(app.playlists) { playlist in
                            Button(playlist.name) { app.addToPlaylist(playlist.id, tracks: [track]) }
                        }
                        if app.playlists.isEmpty { Text("no playlists yet") }
                    }
                    Divider()
                    ConvertMenu(tracks: [track], label: "convert to mp3")
                    Divider()
                    Button("reveal in finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([track.url])
                    }
                }
            }
        }
    }
}

struct TrackRow: View {
    let track: Track
    let index: Int
    var showArtist: Bool
    var numbered: Bool
    var selected: Bool
    var isCurrent: Bool

    @EnvironmentObject var app: AppState
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            // Playing indicator replaces the number, the way every player does it.
            Group {
                if isCurrent {
                    Text(app.player.isPlaying ? "▶" : "‖")
                        .foregroundStyle(app.theme.green)
                } else {
                    Text(numbered ? String(format: "%2d", track.trackNumber ?? index + 1) : "  ")
                        .foregroundStyle(app.theme.muted.opacity(0.6))
                }
            }
            .font(DeckFont.mono(10))
            .frame(width: 20, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(DeckFont.mono(11))
                    .foregroundStyle(isCurrent ? app.theme.green : app.theme.fg)
                    .lineLimit(1)
                if showArtist {
                    Text(track.artist)
                        .font(DeckFont.mono(9))
                        .foregroundStyle(app.theme.muted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if track.needsMetadata {
                Text("!")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.yellow)
                    .help("missing tags — run metadata repair")
            }
            if track.enriched {
                Text("~")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.magenta)
                    .help("tags repaired from MusicBrainz")
            }

            Text(track.codec)
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted.opacity(0.6))
                .frame(width: 42, alignment: .trailing)

            Text(track.duration.clockString)
                .font(DeckFont.mono(10))
                .foregroundStyle(app.theme.muted)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, showArtist ? 4 : 3)
        .contentShape(Rectangle())
        .rowBackground(selected: selected, hovering: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Artist list

struct ArtistListView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(app.artistNames.enumerated()), id: \.element) { index, artist in
                    ArtistRow(
                        artist: artist,
                        albumCount: app.albums(for: artist).count,
                        selected: index == app.selectionIndex
                    )
                    .onTapGesture {
                        app.selectionIndex = index
                        app.navigate(to: .artist(artist))
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }
}

struct ArtistRow: View {
    let artist: String
    let albumCount: Int
    var selected: Bool
    @EnvironmentObject var app: AppState
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(artist)
                .font(DeckFont.mono(11))
                .foregroundStyle(app.theme.fg)
            Spacer()
            Text("\(albumCount) album\(albumCount == 1 ? "" : "s")")
                .font(DeckFont.mono(10))
                .foregroundStyle(app.theme.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .rowBackground(selected: selected, hovering: hovering)
        .onHover { hovering = $0 }
    }
}

import SwiftUI

/// The landing screen: pinned things on top, the rest of the library as rows below.
///
/// Replaces opening straight into the album grid. Three thousand tracks and three
/// hundred albums is too much to be met with — the shape Apple Music uses works because
/// it puts a handful of chosen things first and leaves everything else one tap away.
struct HomePage: View {
    @EnvironmentObject var app: MobileState

    private static let spacing: CGFloat = 12
    private static let padding: CGFloat = 14

    var body: some View {
        TUIPanel(title: "deck://library", trailing: "\(app.tracks.count) tracks") {
            if app.authorization == .denied || app.authorization == .restricted {
                StatusMessage(
                    title: "no access to your library",
                    detail: "Deck needs permission to read Apple Music. Enable it in Settings › Privacy & Security › Media & Apple Music.",
                    actionLabel: "open settings",
                    action: openSystemSettings)
            } else if app.isLoading && app.tracks.isEmpty {
                StatusMessage(title: "reading library…")
            } else {
                // Measured once here, as on the album grid — a GeometryReader inside
                // each cell has no intrinsic size and collapses the layout.
                GeometryReader { geo in
                    let available = geo.size.width - Self.padding * 2
                    let cell = max(80, (available - Self.spacing) / 2)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if !app.pins.isEmpty {
                                pinned(cell: cell)
                            }
                            libraryRows
                        }
                        .padding(Self.padding)
                        .padding(.bottom, 90)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: Pinned

    private func pinned(cell: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "pinned")
                Spacer()
                Text("hold to unpin")
                    .font(DeckFont.mono(8))
                    .foregroundStyle(app.theme.muted.opacity(0.6))
            }

            LazyVGrid(
                columns: [
                    GridItem(.fixed(cell), spacing: Self.spacing),
                    GridItem(.fixed(cell), spacing: Self.spacing),
                ],
                spacing: 16
            ) {
                ForEach(app.pins) { pin in
                    PinCell(pin: pin, width: cell)
                }
            }
        }
    }

    // MARK: Library rows

    private var libraryRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "library")

            VStack(spacing: 0) {
                ForEach(LibraryPage.allCases) { page in
                    NavigationLink(value: NavigationTarget.library(page)) {
                        row(label: page.title, count: count(for: page))
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(app.theme.border)
                }

                NavigationLink(value: NavigationTarget.queue) {
                    row(label: "queue", count: app.playback.queue.count)
                }
                .buttonStyle(.plain)
            }
            .background(app.theme.bgInset.opacity(0.5))
            .overlay(Rectangle().strokeBorder(app.theme.border, lineWidth: 1))
        }
    }

    private func count(for page: LibraryPage) -> Int {
        switch page {
        case .albums: return app.albums.count
        case .artists: return app.artists.count
        case .songs: return app.tracks.count
        case .playlists: return app.playlists.count
        }
    }

    private func row(label: String, count: Int) -> some View {
        HStack(spacing: 10) {
            Text("›")
                .font(DeckFont.mono(13))
                .foregroundStyle(app.theme.accent)
            Text(label)
                .font(DeckFont.mono(14))
                .foregroundStyle(app.theme.fg)
            Spacer()
            Text("\(count)")
                .font(DeckFont.mono(11))
                .foregroundStyle(app.theme.muted)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(app.theme.muted.opacity(0.7))
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .contentShape(Rectangle())
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Pin cell

/// One pinned album or playlist.
///
/// Resolves its target at render time rather than storing a copy, so a pin survives the
/// library changing underneath it — and shows itself as missing if the album is gone,
/// instead of silently vanishing.
private struct PinCell: View {
    let pin: PinTarget
    let width: CGFloat

    @EnvironmentObject var app: MobileState

    var body: some View {
        switch pin {
        case .album(let key):
            if let album = app.albums.first(where: { $0.key == key }) {
                cell(
                    destination: .album(key),
                    artworkID: album.tracks.first?.externalID,
                    title: album.title,
                    subtitle: album.artist,
                    symbol: "music.note",
                    tracks: { album.tracks })
            } else {
                missing(title: key.album)
            }

        case .playlist(let id):
            if let playlist = app.playlists.first(where: { $0.id == id }) {
                cell(
                    destination: .playlist(id),
                    artworkID: app.tracks(in: playlist).first?.externalID,
                    title: playlist.name,
                    subtitle: "\(playlist.trackCount) tracks",
                    symbol: "list.bullet",
                    tracks: { app.tracks(in: playlist) })
            } else {
                missing(title: "playlist")
            }
        }
    }

    private func cell(
        destination: NavigationTarget,
        artworkID: String?,
        title: String,
        subtitle: String,
        symbol: String,
        tracks: @escaping () -> [Track]
    ) -> some View {
        NavigationLink(value: destination) {
            VStack(alignment: .leading, spacing: 6) {
                Artwork(trackID: artworkID, size: width, cornerFallbackSymbol: symbol)
                Text(title)
                    .font(DeckFont.mono(11))
                    .foregroundStyle(app.theme.fg)
                    .lineLimit(1)
                Text(subtitle)
                    .font(DeckFont.mono(9))
                    .foregroundStyle(app.theme.muted)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("play") { app.playback.play(tracks: tracks()) }
            Button("play next") { app.playback.playNext(tracks()) }
            Button("add to queue") { app.playback.enqueue(tracks()) }
            Divider()
            Button("unpin", role: .destructive) { app.togglePin(pin) }
        }
    }

    /// A pin whose album or playlist is no longer in the library.
    private func missing(title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(app.theme.bgInset)
                Image(systemName: "questionmark")
                    .font(.system(size: width * 0.2, weight: .light))
                    .foregroundStyle(app.theme.muted.opacity(0.5))
            }
            .frame(width: width, height: width)
            .overlay(Rectangle().strokeBorder(app.theme.border, lineWidth: 1))

            Text(title)
                .font(DeckFont.mono(11))
                .foregroundStyle(app.theme.muted)
                .lineLimit(1)
            Text("not in your library")
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.yellow.opacity(0.8))
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .contextMenu {
            Button("unpin", role: .destructive) { app.togglePin(pin) }
        }
    }
}

import SwiftUI

// MARK: - Shared scaffolding

/// Wraps a page in the framed panel and handles the three states every page shares:
/// not yet authorised, loading, and empty.
///
/// Written once because getting these wrong is what makes an app feel broken — an empty
/// grid and a grid that has not loaded yet are indistinguishable without it.
struct LibraryPageFrame<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var content: Content

    @EnvironmentObject var app: MobileState

    var body: some View {
        TUIPanel(title: title, trailing: count > 0 ? "\(count)" : nil) {
            if app.authorization == .denied || app.authorization == .restricted {
                StatusMessage(
                    title: "no access to your library",
                    detail: "Deck needs permission to read Apple Music. Enable it in Settings › Privacy & Security › Media & Apple Music.",
                    actionLabel: "open settings",
                    action: openSystemSettings)
            } else if app.isLoading && count == 0 {
                StatusMessage(title: "reading library…")
            } else if app.isEmptyLibrary {
                StatusMessage(
                    title: "library is empty",
                    detail: "Add songs or albums to your library in the Music app and they will appear here.",
                    actionLabel: "reload",
                    action: { Task { await app.reload() } })
            } else if count == 0 {
                StatusMessage(title: "nothing here")
            } else {
                content
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// A plain list styled to disappear, leaving only our own row chrome.
///
/// `.plain` still paints separators and a system background; both have to be turned off
/// explicitly or the TUI framing sits inside a stock iOS list.
private struct BareList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        List {
            content
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
    }
}

/// Swipe-to-queue, attached to anything that resolves to a list of tracks.
///
/// Leading edge is "play next" and trailing is "queue", matching the direction the
/// action moves the track: pulling right brings it closer, pulling left pushes it back.
private struct QueueSwipeActions: ViewModifier {
    let tracks: () -> [Track]
    @EnvironmentObject var app: MobileState

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    app.playback.playNext(tracks())
                    Haptics.commit()
                } label: {
                    Label("next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .tint(app.theme.accent)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button {
                    app.playback.enqueue(tracks())
                    Haptics.commit()
                } label: {
                    Label("queue", systemImage: "text.append")
                }
                .tint(app.theme.green)
            }
    }
}

private extension View {
    func queueSwipeActions(_ tracks: @escaping () -> [Track]) -> some View {
        modifier(QueueSwipeActions(tracks: tracks))
    }
}

// MARK: - Albums

struct AlbumsPage: View {
    @EnvironmentObject var app: MobileState

    private static let spacing: CGFloat = 10
    private static let padding: CGFloat = 12

    var body: some View {
        LibraryPageFrame(title: "deck://albums", count: app.albums.count) {
            // One GeometryReader for the whole grid, not one per cell.
            //
            // A GeometryReader inside a LazyVGrid cell has no intrinsic size of its
            // own, so the grid cannot work out a row height and lays out a single
            // enormous cell — which looked exactly like "album art is broken".
            // Measuring once here and passing a plain number down keeps every cell a
            // simple, self-sizing stack.
            GeometryReader { geo in
                let available = geo.size.width - Self.padding * 2
                let cell = max(80, (available - Self.spacing) / 2)

                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.fixed(cell), spacing: Self.spacing),
                            GridItem(.fixed(cell), spacing: Self.spacing),
                        ],
                        spacing: 16
                    ) {
                        ForEach(app.albums) { album in
                            NavigationLink(value: NavigationTarget.album(album.key)) {
                                AlbumCell(album: album, width: cell)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("play") { app.playback.play(tracks: album.tracks) }
                                Button("play next") { app.playback.playNext(album.tracks) }
                                Button("add to queue") { app.playback.enqueue(album.tracks) }
                                Divider()
                                PinButton(target: .album(album.key))
                            }
                        }
                    }
                    .padding(Self.padding)
                    .padding(.bottom, 90)
                }
            }
        }
    }
}

private struct AlbumCell: View {
    let album: Album
    let width: CGFloat
    @EnvironmentObject var app: MobileState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(trackID: album.tracks.first?.externalID, size: width)
            Text(album.title)
                .font(DeckFont.mono(11))
                .foregroundStyle(app.theme.fg)
                .lineLimit(1)
            Text(album.artist)
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }
}

// MARK: - Artists

struct ArtistsPage: View {
    @EnvironmentObject var app: MobileState

    var body: some View {
        LibraryPageFrame(title: "deck://artists", count: app.artists.count) {
            BareList {
                ForEach(app.artists, id: \.self) { artist in
                    NavigationLink(value: NavigationTarget.artist(artist)) {
                        HStack(spacing: 10) {
                            Text("›")
                                .font(DeckFont.mono(12))
                                .foregroundStyle(app.theme.accent.opacity(0.6))
                            Text(artist)
                                .font(DeckFont.mono(13))
                                .foregroundStyle(app.theme.fg)
                                .lineLimit(1)
                            Spacer()
                            Text("\(app.albums(byArtist: artist).count)")
                                .font(DeckFont.mono(10))
                                .foregroundStyle(app.theme.muted)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .queueSwipeActions {
                        app.albums(byArtist: artist).flatMap(\.tracks)
                    }
                }
                Spacer().frame(height: 90).listRowBackground(Color.clear)
            }
        }
    }
}

// MARK: - Songs

struct SongsPage: View {
    @EnvironmentObject var app: MobileState
    // Observed, not just called: the row highlight has to follow the current track.
    @EnvironmentObject var playback: Playback

    var body: some View {
        LibraryPageFrame(title: "deck://songs", count: app.tracks.count) {
            // Sorted by title rather than in library order, which is whatever order iOS
            // happens to return. Computed once at load, not here — see `sortedTracks`.
            let songs = app.sortedTracks
            BareList {
                ForEach(Array(songs.enumerated()), id: \.element.id) { offset, track in
                    TrackRow(
                        track: track,
                        isCurrent: playback.currentTrack?.id == track.id
                    ) {
                        app.playback.play(tracks: songs, startingAt: offset)
                        Haptics.tap()
                    }
                    .queueSwipeActions { [track] }
                }
                Spacer().frame(height: 90).listRowBackground(Color.clear)
            }
        }
    }
}

// MARK: - Playlists

struct PlaylistsPage: View {
    @EnvironmentObject var app: MobileState

    var body: some View {
        LibraryPageFrame(title: "deck://playlists", count: app.playlists.count) {
            BareList {
                ForEach(app.playlists) { playlist in
                    NavigationLink(value: NavigationTarget.playlist(playlist.id)) {
                        HStack(spacing: 10) {
                            Artwork(
                                trackID: app.tracks(in: playlist).first?.externalID,
                                size: 44,
                                cornerFallbackSymbol: "list.bullet")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                    .font(DeckFont.mono(13))
                                    .foregroundStyle(app.theme.fg)
                                    .lineLimit(1)
                                Text("\(playlist.trackCount) tracks")
                                    .font(DeckFont.mono(10))
                                    .foregroundStyle(app.theme.muted)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .queueSwipeActions { app.tracks(in: playlist) }
                    .contextMenu {
                        Button("play") { app.playback.play(tracks: app.tracks(in: playlist)) }
                        Divider()
                        PinButton(target: .playlist(playlist.id))
                    }
                }
                Spacer().frame(height: 90).listRowBackground(Color.clear)
            }
        }
    }
}

// MARK: - Album detail

struct AlbumDetail: View {
    let album: Album
    @EnvironmentObject var app: MobileState
    @EnvironmentObject var playback: Playback

    var body: some View {
        DetailScaffold(title: "deck://album") {
            BareList {
                VStack(spacing: 12) {
                    Artwork(trackID: album.tracks.first?.externalID, size: 200)

                    VStack(spacing: 4) {
                        Text(album.title)
                            .font(DeckFont.mono(16, weight: .semibold))
                            .foregroundStyle(app.theme.fg)
                            .multilineTextAlignment(.center)
                        Text(album.artist)
                            .font(DeckFont.mono(12))
                            .foregroundStyle(app.theme.muted)
                        Text(metaLine)
                            .font(DeckFont.mono(10))
                            .foregroundStyle(app.theme.muted.opacity(0.8))
                    }

                    HStack(spacing: 18) {
                        BracketButton(label: "play") {
                            app.playback.play(tracks: album.tracks)
                            Haptics.tap()
                        }
                        BracketButton(label: "shuffle") {
                            app.playback.shuffleMode = .songs
                            app.playback.play(tracks: album.tracks.shuffled())
                            Haptics.tap()
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)

                ForEach(Array(album.tracks.enumerated()), id: \.element.id) { offset, track in
                    TrackRow(
                        track: track,
                        index: track.trackNumber ?? offset + 1,
                        showsArtwork: false,
                        isCurrent: playback.currentTrack?.id == track.id
                    ) {
                        app.playback.play(tracks: album.tracks, startingAt: offset)
                        Haptics.tap()
                    }
                    .queueSwipeActions { [track] }
                }

                Spacer().frame(height: 90).listRowBackground(Color.clear)
            }
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append("\(album.tracks.count) tracks")
        parts.append(album.duration.longString)
        return parts.joined(separator: " · ")
    }
}

// MARK: - Artist detail

struct ArtistDetail: View {
    let artist: String
    @EnvironmentObject var app: MobileState

    var body: some View {
        DetailScaffold(title: "deck://artist") {
            // Same single-measurement approach as AlbumsPage.
            GeometryReader { geo in
                let cell = max(80, (geo.size.width - 24 - 10) / 2)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(artist)
                            .font(DeckFont.mono(17, weight: .semibold))
                            .foregroundStyle(app.theme.fg)
                            .padding(.horizontal, 12)
                            .padding(.top, 14)

                        LazyVGrid(
                            columns: [
                                GridItem(.fixed(cell), spacing: 10),
                                GridItem(.fixed(cell), spacing: 10),
                            ],
                            spacing: 16
                        ) {
                            ForEach(app.albums(byArtist: artist)) { album in
                                NavigationLink(value: NavigationTarget.album(album.key)) {
                                    AlbumCell(album: album, width: cell)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .padding(.bottom, 90)
                }
            }
        }
    }
}

// MARK: - Playlist detail

struct PlaylistDetail: View {
    let playlist: ServicePlaylist
    @EnvironmentObject var app: MobileState
    @EnvironmentObject var playback: Playback

    var body: some View {
        let tracks = app.tracks(in: playlist)

        DetailScaffold(title: "deck://playlist") {
            BareList {
                VStack(spacing: 8) {
                    Text(playlist.name)
                        .font(DeckFont.mono(16, weight: .semibold))
                        .foregroundStyle(app.theme.fg)
                        .multilineTextAlignment(.center)
                    Text("\(tracks.count) tracks")
                        .font(DeckFont.mono(10))
                        .foregroundStyle(app.theme.muted)

                    HStack(spacing: 18) {
                        BracketButton(label: "play") {
                            app.playback.play(tracks: tracks)
                            Haptics.tap()
                        }
                        BracketButton(label: "shuffle") {
                            app.playback.play(tracks: tracks.shuffled())
                            Haptics.tap()
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)

                if tracks.count < playlist.trackCount {
                    // Honest rather than silent: a playlist can reference tracks that are
                    // no longer in the library, and a short list with no explanation
                    // looks like the app failed to load them.
                    Text("\(playlist.trackCount - tracks.count) tracks are not in your library")
                        .font(DeckFont.mono(10))
                        .foregroundStyle(app.theme.yellow.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 10)
                }

                ForEach(Array(tracks.enumerated()), id: \.element.id) { offset, track in
                    TrackRow(
                        track: track,
                        index: offset + 1,
                        isCurrent: playback.currentTrack?.id == track.id
                    ) {
                        app.playback.play(tracks: tracks, startingAt: offset)
                        Haptics.tap()
                    }
                    .queueSwipeActions { [track] }
                }

                Spacer().frame(height: 90).listRowBackground(Color.clear)
            }
        }
    }
}

// MARK: - Detail scaffold

/// Detail screens keep the framed panel but hide the system navigation bar, since a
/// stock iOS bar above a TUI panel reads as two competing headers.
///
/// The back affordance is the standard edge swipe plus an explicit bracket button —
/// hiding the bar removes the system back button, and an edge swipe alone is not
/// discoverable.
private struct DetailScaffold<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    @EnvironmentObject var app: MobileState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TUIPanel(title: title) {
            content
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(app.theme.bg)
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                BracketButton(label: "← back") { dismiss() }
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(app.theme.bgInset)
            .overlay(alignment: .bottom) {
                Rectangle().fill(app.theme.border).frame(height: 1)
            }
        }
    }
}

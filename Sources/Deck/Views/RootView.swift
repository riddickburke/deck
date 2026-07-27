import DeckCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState
    @FocusState private var keyboardFocused: Bool
    @FocusState private var searchFocused: Bool
    /// Set after `g`, so `gg` can act as a chord without a modifier.
    @State private var pendingG = false

    var body: some View {
        ZStack {
            app.theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                TUITitlebar(
                    title: "nebula://deck",
                    focused: true,
                    trailing: app.selectedDevice.map { "device: \($0.volumeName)" } ?? "no device")

                HStack(spacing: 0) {
                    SidebarView()
                    contentPanel
                }
                .padding(6)

                NowPlayingBar(player: app.player)
                StatusBar(player: app.player)
            }

            if app.config.scanlines { Scanlines().ignoresSafeArea() }

            if app.showNowPlaying {
                NowPlayingView(player: app.player)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(1)
            }
            if app.showCommandPalette { CommandPalette().zIndex(2) }
        }
        .animation(.easeOut(duration: 0.18), value: app.showNowPlaying)
        .foregroundStyle(app.theme.fg)
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .onAppear {
            keyboardFocused = true
            if app.tracks.isEmpty { app.scanLibrary() }
        }
        .onKeyPress(phases: .down) { press in handle(press) }
    }

    // MARK: - Content

    private var contentPanel: some View {
        TUIPanel(
            title: panelTitle,
            focused: app.focusedPane == .content,
            trailing: app.isSearching ? nil : "\(itemCount) items"
        ) {
            VStack(spacing: 0) {
                if app.isSearching { searchField }
                content
            }
        }
        .onTapGesture { app.focusedPane = .content }
    }

    @ViewBuilder
    private var content: some View {
        switch app.route {
        case .albums:
            if app.albums.isEmpty { emptyState } else { AlbumGridView(albums: app.filteredAlbums) }
        case .artists:
            ArtistListView()
        case .songs:
            ScrollView { TrackListView(tracks: app.filteredTracks) }
        case .album(let key):
            if let album = app.album(for: key) {
                AlbumDetailView(album: album)
            } else { missingState("album not found") }
        case .artist(let name):
            AlbumGridView(albums: app.albums(for: name))
        case .playlist(let id):
            if let playlist = app.playlist(id) {
                PlaylistDetailView(playlist: playlist)
            } else { missingState("playlist not found") }
        case .queue:
            ScrollView { TrackListView(tracks: app.player.queue) }
        case .sync:
            SyncView()
        case .settings:
            SettingsView()
        }
    }

    private var panelTitle: String {
        switch app.route {
        case .albums: return "nebula://albums"
        case .artists: return "nebula://artists"
        case .songs: return "nebula://songs"
        case .album(let key): return "nebula://albums/\(key.album)"
        case .artist(let name): return "nebula://artists/\(name)"
        case .playlist(let id): return "nebula://playlists/\(app.playlist(id)?.name ?? "")"
        case .queue: return "nebula://queue"
        case .sync: return "nebula://sync"
        case .settings: return "nebula://settings"
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Text("/")
                .font(DeckFont.mono(12))
                .foregroundStyle(app.theme.yellow)
            TUITextField(
                placeholder: "search",
                text: $app.searchQuery,
                onSubmit: {
                    app.isSearching = false
                    keyboardFocused = true
                },
                onCancel: {
                    app.isSearching = false
                    app.searchQuery = ""
                    keyboardFocused = true
                },
                focusOnAppear: true
            )
            Spacer()
            Text("\(itemCount) matches")
                .font(DeckFont.mono(10))
                .foregroundStyle(app.theme.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(app.theme.bgInset)
        .overlay(alignment: .bottom) { TUIDivider() }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("◎")
                .font(DeckFont.mono(46))
                .foregroundStyle(app.theme.muted.opacity(0.4))
            Text(app.isScanning ? "indexing library…" : "no music indexed yet")
                .font(DeckFont.mono(12))
                .foregroundStyle(app.theme.muted)
            if !app.isScanning {
                BracketButton(label: "+ add a music folder", tint: app.theme.accent) {
                    app.addLibraryRoot()
                }
            }
            if let progress = app.scanProgress {
                Text("\(progress.scanned)/\(progress.total)")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func missingState(_ message: String) -> some View {
        Text(message)
            .font(DeckFont.mono(12))
            .foregroundStyle(app.theme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Keyboard

    /// The number of selectable rows in the current view, used to clamp j/k.
    private var itemCount: Int {
        switch app.route {
        case .albums: return app.filteredAlbums.count
        case .artists: return app.artistNames.count
        case .songs: return app.filteredTracks.count
        case .album(let key): return app.album(for: key)?.tracks.count ?? 0
        case .artist(let name): return app.albums(for: name).count
        case .playlist(let id): return app.playlist(id).map { app.tracks(in: $0).count } ?? 0
        case .queue: return app.player.queue.count
        case .sync, .settings: return 0
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // While a text field owns the keyboard it gets every key, so typing "shuffle"
        // into a playlist name does not also toggle shuffle and skip a track.
        if app.keyboardShortcutsSuppressed { return .ignored }

        let key = press.key
        let chars = press.characters

        // `gg` chord.
        if pendingG {
            pendingG = false
            if chars == "g" { app.selectionIndex = 0; return .handled }
        }

        switch key {
        case .escape:
            if app.showNowPlaying { app.showNowPlaying = false }
            else { app.searchQuery = "" }
            return .handled
        case .return:
            activateSelection()
            return .handled
        case .space:
            app.player.toggle()
            return .handled
        case .upArrow:
            move(-1); return .handled
        case .downArrow:
            move(1); return .handled
        case .leftArrow:
            app.player.seekRelative(-5); return .handled
        case .rightArrow:
            app.player.seekRelative(5); return .handled
        default:
            break
        }

        switch chars {
        case "j": move(1)
        case "k": move(-1)
        case "g": pendingG = true
        case "G": app.selectionIndex = max(0, itemCount - 1)
        case "h": app.goBack()
        case "l": activateSelection()
        case "/": app.isSearching = true
        case ":": app.showCommandPalette = true
        case "n": app.player.next()
        case "p": app.player.previous()
        case "H": app.player.seekRelative(-10)
        case "L": app.player.seekRelative(10)
        case "+", "=": app.adjustVolume(0.05)
        case "-", "_": app.adjustVolume(-0.05)
        case "s": app.toggleShuffle()
        case "r": app.cycleRepeat()
        case "t": cycleTheme()
        case "f": app.showNowPlaying.toggle()
        case "1": app.navigate(to: .albums)
        case "2": app.navigate(to: .artists)
        case "3": app.navigate(to: .songs)
        case "4": app.navigate(to: .queue)
        case "S": app.navigate(to: .sync)
        case ",": app.navigate(to: .settings)
        case "R": app.scanLibrary()
        case "?": app.showCommandPalette = true
        default: return .ignored
        }
        return .handled
    }

    private func move(_ delta: Int) {
        guard itemCount > 0 else { return }
        app.selectionIndex = max(0, min(itemCount - 1, app.selectionIndex + delta))
    }

    private func cycleTheme() {
        let all = Theme.all
        let i = all.firstIndex { $0.id == app.config.themeID } ?? 0
        app.config.themeID = all[(i + 1) % all.count].id
        app.statusMessage = "theme: \(app.theme.name)"
    }

    /// Enter / `l` behaviour, which differs per view the way it does in a file manager.
    private func activateSelection() {
        let index = app.selectionIndex
        switch app.route {
        case .albums:
            let list = app.filteredAlbums
            guard list.indices.contains(index) else { return }
            app.navigate(to: .album(list[index].key))
        case .artists:
            let list = app.artistNames
            guard list.indices.contains(index) else { return }
            app.navigate(to: .artist(list[index]))
        case .artist(let name):
            let list = app.albums(for: name)
            guard list.indices.contains(index) else { return }
            app.navigate(to: .album(list[index].key))
        case .songs:
            app.play(tracks: app.filteredTracks, startingAt: index)
        case .album(let key):
            guard let album = app.album(for: key) else { return }
            app.play(album: album, startingAt: index)
        case .playlist(let id):
            guard let playlist = app.playlist(id) else { return }
            app.play(tracks: app.tracks(in: playlist), startingAt: index)
        case .queue:
            app.player.playTrack(at: index)
        case .sync, .settings:
            break
        }
    }
}

// MARK: - Playlist detail

struct PlaylistDetailView: View {
    let playlist: Playlist
    @EnvironmentObject var app: AppState

    var body: some View {
        let list = app.tracks(in: playlist)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(playlist.name)
                            .font(DeckFont.mono(20, weight: .semibold))
                            .foregroundStyle(app.theme.fg)
                        Text("\(list.count) tracks · \(list.reduce(0) { $0 + $1.duration }.longString) · \(list.reduce(Int64(0)) { $0 + $1.fileSize }.byteString)")
                            .font(DeckFont.mono(10))
                            .foregroundStyle(app.theme.muted)

                        HStack(spacing: 10) {
                            BracketButton(label: "▶ play", tint: app.theme.green) {
                                app.play(tracks: list)
                            }
                            BracketButton(label: "⇄ shuffle") {
                                app.player.shuffle = true
                                app.play(tracks: list)
                            }
                            BracketButton(
                                label: playlist.syncEnabled ? "◆ syncing" : "◇ sync to device",
                                tint: playlist.syncEnabled ? app.theme.green : nil
                            ) { app.toggleSync(playlist.id) }
                        }
                        .padding(.top, 6)
                    }
                    Spacer()
                }
                .padding(18)

                TUIDivider()
                TrackListView(tracks: list)
                    .padding(.top, 4)
            }
        }
    }
}

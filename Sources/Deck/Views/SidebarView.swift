import DeckCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var app: AppState
    @State private var newPlaylistName = ""
    @State private var creatingPlaylist = false

    var body: some View {
        TUIPanel(title: "deck://library", focused: app.focusedPane == .sidebar) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    group("browse") {
                        navRow("albums", count: app.albums.count, route: .albums)
                        navRow("artists", count: app.artistNames.count, route: .artists)
                        navRow("songs", count: app.tracks.count, route: .songs)
                        navRow("queue", count: app.player.queue.count, route: .queue)
                    }

                    group("sources") {
                        sourceRow(nil, label: "all", count: app.localTracks.count + app.appleMusicTracks.count + app.spotifyTracks.count)
                        sourceRow(.local, label: "local", count: app.localTracks.count)

                        if app.appleMusicTracks.isEmpty {
                            HStack {
                                BracketButton(
                                    label: app.isImportingAppleMusic ? "reading…" : "+ apple music",
                                    tint: app.theme.magenta,
                                    disabled: app.isImportingAppleMusic
                                ) { app.importAppleMusic() }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                        } else {
                            sourceRow(
                                .appleMusic, label: "apple music",
                                count: app.appleMusicTracks.count)
                        }

                        if app.spotifyTracks.isEmpty {
                            HStack {
                                BracketButton(
                                    label: app.isImportingSpotify ? "reading…"
                                        : (app.spotify.isAuthorized ? "+ import spotify" : "+ connect spotify"),
                                    tint: app.theme.green,
                                    disabled: app.isImportingSpotify || app.spotify.isSigningIn
                                ) {
                                    app.spotify.isAuthorized ? app.importSpotify() : app.signInToSpotify()
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                        } else {
                            sourceRow(.spotify, label: "spotify", count: app.spotifyTracks.count)
                        }

                        if let error = app.spotify.lastError {
                            Text(error)
                                .font(DeckFont.mono(9))
                                .foregroundStyle(app.theme.red)
                                .padding(.horizontal, 12)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let error = app.appleMusicError {
                            Text(error)
                                .font(DeckFont.mono(9))
                                .foregroundStyle(app.theme.red)
                                .padding(.horizontal, 12)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    group("playlists") {
                        ForEach(app.playlists) { playlist in
                            playlistRow(playlist)
                        }
                        if creatingPlaylist {
                            TUITextField(
                                placeholder: "name",
                                text: $newPlaylistName,
                                onSubmit: commitPlaylist,
                                onCancel: {
                                    newPlaylistName = ""
                                    creatingPlaylist = false
                                },
                                focusOnAppear: true
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                        }
                        HStack {
                            BracketButton(label: "+ new", compact: true) {
                                creatingPlaylist = true
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 2)
                    }

                    group("device") {
                        if app.devices.isEmpty {
                            Text("no device mounted")
                                .font(DeckFont.mono(10))
                                .foregroundStyle(app.theme.muted)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(app.devices) { device in
                                deviceRow(device)
                            }
                        }
                        navRow("sync", count: nil, route: .sync)
                    }

                    group("") {
                        navRow("settings", count: nil, route: .settings)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(width: 210)
        .onTapGesture { app.focusedPane = .sidebar }
    }

    // MARK: Rows

    @ViewBuilder
    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        if !title.isEmpty {
            SectionLabel(text: title)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
        } else {
            Spacer().frame(height: 10)
        }
        content()
    }

    /// Filters the browsable library to one source. Streaming sources are tinted so it
    /// is obvious at a glance which rows cannot be synced to a device.
    private func sourceRow(_ source: TrackSource?, label: String, count: Int) -> some View {
        let active = app.sourceFilter == source
        let streaming = source?.isStreaming == true
        return HStack(spacing: 6) {
            Text(active ? "›" : " ")
                .font(DeckFont.mono(11))
                .foregroundStyle(app.theme.accent)
            Text(label)
                .font(DeckFont.mono(11))
                .foregroundStyle(active ? app.theme.fg : app.theme.muted)
            if streaming {
                Text("☁")
                    .font(DeckFont.mono(9))
                    .foregroundStyle(app.theme.magenta)
                    .help("streams via Music.app — cannot be synced to a device")
            }
            Spacer()
            Text("\(count)")
                .font(DeckFont.mono(10))
                .foregroundStyle(app.theme.muted.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(active ? app.theme.selection.opacity(0.55) : .clear)
        .onTapGesture { app.sourceFilter = source }
        .contextMenu {
            if source == .appleMusic {
                Button("refresh from Music.app") { app.importAppleMusic() }
            }
            if source == .spotify {
                Button("refresh from Spotify") { app.importSpotify() }
                Button("sign out") { app.signOutOfSpotify() }
            }
        }
    }

    private func navRow(_ label: String, count: Int?, route: Route) -> some View {
        let active = app.route == route
        return HStack(spacing: 6) {
            Text(active ? "›" : " ")
                .font(DeckFont.mono(11))
                .foregroundStyle(app.theme.accent)
            Text(label)
                .font(DeckFont.mono(11))
                .foregroundStyle(active ? app.theme.fg : app.theme.muted)
            Spacer()
            if let count {
                Text("\(count)")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted.opacity(0.7))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(active ? app.theme.selection.opacity(0.55) : .clear)
        .onTapGesture { app.navigate(to: route) }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        let active = app.route == .playlist(playlist.id)
        return HStack(spacing: 6) {
            // A filled marker means this playlist goes to the device on next sync.
            Text(playlist.syncEnabled ? "◆" : "◇")
                .font(DeckFont.mono(10))
                .foregroundStyle(playlist.syncEnabled ? app.theme.green : app.theme.muted.opacity(0.5))
                .onTapGesture { app.toggleSync(playlist.id) }
                .help(playlist.syncEnabled ? "syncing to device" : "not syncing")
            Text(playlist.name)
                .font(DeckFont.mono(11))
                .foregroundStyle(active ? app.theme.fg : app.theme.muted)
                .lineLimit(1)
            Spacer()
            Text("\(playlist.trackPaths.count)")
                .font(DeckFont.mono(10))
                .foregroundStyle(app.theme.muted.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(active ? app.theme.selection.opacity(0.55) : .clear)
        .onTapGesture { app.navigate(to: .playlist(playlist.id)) }
        .contextMenu {
            Button(playlist.syncEnabled ? "stop syncing" : "sync to device") {
                app.toggleSync(playlist.id)
            }
            Button("play") { app.play(tracks: app.tracks(in: playlist)) }
            Divider()
            Button("delete", role: .destructive) { app.deletePlaylist(playlist.id) }
        }
    }

    private func deviceRow(_ device: RockboxDevice) -> some View {
        let selected = app.selectedDevice?.id == device.id
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(selected ? "▸" : " ")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.green)
                Text(device.volumeName)
                    .font(DeckFont.mono(11))
                    .foregroundStyle(selected ? app.theme.fg : app.theme.muted)
                    .lineLimit(1)
                Spacer()
                if !device.hasRockbox {
                    Text("?")
                        .font(DeckFont.mono(10))
                        .foregroundStyle(app.theme.yellow)
                        .help("no .rockbox folder found on this volume")
                }
            }
            if device.totalCapacity > 0 {
                HStack(spacing: 6) {
                    BlockMeter(
                        fraction: device.capacityFraction, width: 12,
                        tint: device.capacityFraction > 0.9 ? app.theme.red : app.theme.accent)
                    Text("\(device.availableCapacity.byteString) free")
                        .font(DeckFont.mono(9))
                        .foregroundStyle(app.theme.muted)
                }
                .padding(.leading, 16)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(selected ? app.theme.selection.opacity(0.55) : .clear)
        .onTapGesture {
            app.selectedDevice = device
            app.syncPlan = nil
        }
    }

    private func commitPlaylist() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { app.createPlaylist(named: name) }
        newPlaylistName = ""
        creatingPlaylist = false
    }
}

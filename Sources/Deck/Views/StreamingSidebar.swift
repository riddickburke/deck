import DeckCore
import SwiftUI

/// The sidebar shown while a streaming service is open.
///
/// Deliberately not the local one with rows hidden. Streaming has no device sync, and
/// local playlists point at file paths that mean nothing here — presenting them greyed
/// out would only invite clicking. What is left is the service's own library.
struct StreamingSidebar: View {
    @EnvironmentObject var app: AppState

    private var source: TrackSource { app.sourceFilter ?? .appleMusic }

    private var accent: Color {
        source == .spotify ? app.theme.green : app.theme.magenta
    }

    private var trackCount: Int {
        source == .spotify ? app.spotifyTracks.count : app.appleMusicTracks.count
    }

    private var isRefreshing: Bool {
        source == .spotify ? app.isImportingSpotify : app.isImportingAppleMusic
    }

    var body: some View {
        TUIPanel(
            title: "deck://\(source == .spotify ? "spotify" : "apple-music")",
            focused: app.focusedPane == .sidebar
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    serviceHeader

                    group("browse") {
                        navRow("albums", count: app.albums.count, route: .albums)
                        navRow("artists", count: app.artistNames.count, route: .artists)
                        navRow("songs", count: app.tracks.count, route: .songs)
                        navRow("queue", count: app.player.queue.count, route: .queue)
                    }

                    if !app.currentServicePlaylists.isEmpty {
                        group("playlists") {
                            ForEach(app.currentServicePlaylists) { playlist in
                                playlistRow(playlist)
                            }
                        }
                    }

                    group("service") {
                        actionRow(
                            isRefreshing ? "refreshing…" : "refresh library",
                            disabled: isRefreshing
                        ) {
                            source == .spotify ? app.importSpotify() : app.importAppleMusic()
                        }
                        actionRow("switch service") { app.navigate(to: .streaming) }
                        if source == .spotify {
                            actionRow("sign out") { app.signOutOfSpotify() }
                        }
                    }

                    group("") {
                        actionRow("← local library", tint: app.theme.accent) {
                            app.exitStreamingMode()
                        }
                        navRow("settings", count: nil, route: .settings)
                    }

                    playbackNote
                }
                .padding(.vertical, 8)
            }
        }
        .frame(width: 210)
        .onTapGesture { app.focusedPane = .sidebar }
    }

    // MARK: Pieces

    private var serviceHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Rectangle().fill(accent).frame(width: 2, height: 12)
                Text(source.label)
                    .font(DeckFont.mono(12, weight: .semibold))
                    .foregroundStyle(app.theme.fg)
            }
            Text("\(trackCount) tracks")
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted)
                .padding(.leading, 8)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    /// The one thing that genuinely differs from local playback, said once and quietly.
    private var playbackNote: some View {
        Text(source == .spotify
            ? "plays on an official spotify client. cannot be synced to a device."
            : "plays through Music.app. cannot be synced to a device.")
            .font(DeckFont.mono(8))
            .foregroundStyle(app.theme.muted.opacity(0.7))
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        if !title.isEmpty {
            SectionLabel(text: title)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)
        } else {
            Spacer().frame(height: 12)
        }
        content()
    }

    private func navRow(_ label: String, count: Int?, route: Route) -> some View {
        let active = app.route == route
        return HStack(spacing: 6) {
            Text(active ? "›" : " ")
                .font(DeckFont.mono(11))
                .foregroundStyle(accent)
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

    private func playlistRow(_ playlist: ServicePlaylist) -> some View {
        let active = app.route == .servicePlaylist(playlist.id)
        return HStack(spacing: 6) {
            Text(active ? "›" : " ")
                .font(DeckFont.mono(11))
                .foregroundStyle(accent)
            Text(playlist.name)
                .font(DeckFont.mono(11))
                .foregroundStyle(active ? app.theme.fg : app.theme.muted)
                .lineLimit(1)
            Spacer()
            Text("\(playlist.trackCount)")
                .font(DeckFont.mono(10))
                .foregroundStyle(app.theme.muted.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(active ? app.theme.selection.opacity(0.55) : .clear)
        .onTapGesture { app.navigate(to: .servicePlaylist(playlist.id)) }
        .contextMenu {
            Button("play") { app.play(tracks: app.tracks(in: playlist)) }
        }
    }

    private func actionRow(
        _ label: String, tint: Color? = nil, disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            BracketButton(label: label, tint: tint, disabled: disabled, compact: true, action: action)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
    }
}

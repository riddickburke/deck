import DeckCore
import SwiftUI

/// A streaming service's own playlist. Read-only: Deck never modifies anything in an
/// Apple Music or Spotify account.
struct ServicePlaylistView: View {
    let playlist: ServicePlaylist
    @EnvironmentObject var app: AppState

    var body: some View {
        let tracks = app.tracks(in: playlist)
        let missing = playlist.trackCount - tracks.count

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(tracks: tracks, missing: missing)
                TUIDivider()
                TrackListView(tracks: tracks)
                    .padding(.top, 4)
            }
        }
    }

    private func header(tracks: [Track], missing: Int) -> some View {
        let accent = playlist.source == .spotify ? app.theme.green : app.theme.magenta
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Rectangle().fill(accent).frame(width: 2, height: 18)
                Text(playlist.name)
                    .font(DeckFont.mono(20, weight: .semibold))
                    .foregroundStyle(app.theme.fg)
            }

            Text("\(tracks.count) tracks · \(tracks.reduce(0) { $0 + $1.duration }.longString) · \(playlist.source.label)")
                .font(DeckFont.mono(10))
                .foregroundStyle(app.theme.muted)

            if missing > 0 {
                // A playlist can reference something unavailable in this region or
                // removed from the service; those are dropped rather than faked.
                Text("\(missing) track\(missing == 1 ? "" : "s") unavailable and not shown")
                    .font(DeckFont.mono(9))
                    .foregroundStyle(app.theme.yellow)
            }

            HStack(spacing: 10) {
                BracketButton(label: "▶ play", tint: accent) {
                    app.play(tracks: tracks)
                }
                BracketButton(label: "⇄ shuffle") {
                    app.player.shuffle = true
                    app.play(tracks: tracks.shuffled())
                }
            }
            .padding(.top, 4)
        }
        .padding(18)
    }
}

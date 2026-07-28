import DeckCore
import SwiftUI

/// Full-page search. One field, three kinds of result at once, because deciding whether
/// you are looking for an artist or an album before you type is a thing the app should
/// not ask of you.
///
/// The scope follows whichever source is active, so the same page serves the local
/// library and a streaming one.
struct SearchView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                field

                if app.searchQuery.isEmpty {
                    prompt
                } else if !app.searchHasResults {
                    empty
                } else {
                    results
                }
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: Field

    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("/")
                    .font(DeckFont.mono(26))
                    .foregroundStyle(app.theme.yellow)

                TUITextField(
                    placeholder: "search \(app.searchScopeLabel)",
                    text: $app.searchQuery,
                    large: true,
                    focusTrigger: app.searchFocusTrigger)

                if !app.searchQuery.isEmpty {
                    BracketButton(label: "clear") { app.searchQuery = "" }
                }
            }

            HStack(spacing: 10) {
                Text("searching \(app.searchScopeLabel)")
                    .font(DeckFont.mono(9))
                    .foregroundStyle(
                        app.isStreamingMode ? app.theme.magenta : app.theme.muted)
                if !app.searchQuery.isEmpty {
                    Text("\(app.filteredArtists.count) artists · \(app.filteredAlbums.count) albums · \(app.filteredTracks.count) songs")
                        .font(DeckFont.mono(9))
                        .foregroundStyle(app.theme.muted)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(app.theme.bgInset)
        .overlay(alignment: .bottom) { TUIDivider() }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("type to search artists, albums and songs at once.")
                .font(DeckFont.mono(11))
                .foregroundStyle(app.theme.muted)
            Text("results are limited to \(app.searchScopeLabel). switch sources from the toolbar to search elsewhere.")
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted.opacity(0.7))
        }
        .padding(20)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("nothing matches \"\(app.searchQuery)\" in \(app.searchScopeLabel).")
                .font(DeckFont.mono(11))
                .foregroundStyle(app.theme.muted)
            if !app.isStreamingMode, !app.appleMusicTracks.isEmpty || !app.spotifyTracks.isEmpty {
                BracketButton(label: "search streaming instead", tint: app.theme.magenta) {
                    app.navigate(to: .streaming)
                }
            }
        }
        .padding(20)
    }

    // MARK: Results

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !app.filteredArtists.isEmpty {
                section("artists", count: app.filteredArtists.count) {
                    ForEach(app.filteredArtists.prefix(12), id: \.self) { artist in
                        artistRow(artist)
                    }
                }
            }

            if !app.filteredAlbums.isEmpty {
                section("albums", count: app.filteredAlbums.count) {
                    ForEach(app.filteredAlbums.prefix(24), id: \.key) { album in
                        albumRow(album)
                    }
                }
            }

            if !app.filteredTracks.isEmpty {
                section("songs", count: app.filteredTracks.count) {
                    // Capped: a broad query can match thousands, and rendering them all
                    // costs more than it helps.
                    let songs = Array(app.filteredTracks.prefix(60))
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, track in
                        songRow(track, in: songs, at: index)
                    }
                    if app.filteredTracks.count > songs.count {
                        Text("… and \(app.filteredTracks.count - songs.count) more")
                            .font(DeckFont.mono(9))
                            .foregroundStyle(app.theme.muted)
                            .padding(.horizontal, 20)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section<C: View>(
        _ title: String, count: Int, @ViewBuilder content: () -> C
    ) -> some View {
        HStack(spacing: 8) {
            SectionLabel(text: title)
            Text("\(count)")
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted.opacity(0.6))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 6)

        content()
    }

    private func artistRow(_ artist: String) -> some View {
        let count = app.albums(for: artist).count
        return HStack(spacing: 10) {
            Text("◦")
                .font(DeckFont.mono(11))
                .foregroundStyle(app.theme.muted)
            Text(artist)
                .font(DeckFont.mono(12))
                .foregroundStyle(app.theme.fg)
            Spacer()
            Text("\(count) album\(count == 1 ? "" : "s")")
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { app.navigate(to: .artist(artist)) }
    }

    private func albumRow(_ album: Album) -> some View {
        HStack(spacing: 10) {
            ArtworkView(album: album, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title)
                    .font(DeckFont.mono(11))
                    .foregroundStyle(app.theme.fg)
                    .lineLimit(1)
                Text(album.year.map { "\(album.artist) · \($0)" } ?? album.artist)
                    .font(DeckFont.mono(9))
                    .foregroundStyle(app.theme.muted)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(album.tracks.count)")
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted)
            BracketButton(label: "▶", tint: app.theme.green, compact: true) {
                app.play(album: album)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { app.navigate(to: .album(album.key)) }
    }

    private func songRow(_ track: Track, in songs: [Track], at index: Int) -> some View {
        HStack(spacing: 10) {
            Text(app.currentTrack?.id == track.id ? "▶" : "·")
                .font(DeckFont.mono(10))
                .foregroundStyle(
                    app.currentTrack?.id == track.id ? app.theme.green : app.theme.muted)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(DeckFont.mono(11))
                    .foregroundStyle(app.theme.fg)
                    .lineLimit(1)
                Text("\(track.artist) · \(track.album)")
                    .font(DeckFont.mono(9))
                    .foregroundStyle(app.theme.muted)
                    .lineLimit(1)
            }
            Spacer()
            if track.isStreaming {
                Text("☁")
                    .font(DeckFont.mono(9))
                    .foregroundStyle(app.theme.magenta)
            }
            Text(track.duration.clockString)
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { app.play(tracks: songs, startingAt: index) }
    }
}

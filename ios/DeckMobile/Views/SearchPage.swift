import SwiftUI

/// One big field over the whole library — songs, albums and artists at once, as on the
/// desktop, rather than a scope picker the user has to set before typing.
struct SearchPage: View {
    @EnvironmentObject var app: MobileState
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    private var results: SearchResults { app.search(query) }

    var body: some View {
        ZStack {
            app.theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                field

                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    StatusMessage(
                        title: "search your library",
                        detail: "songs, albums and artists at once")
                } else if results.isEmpty {
                    StatusMessage(title: "no matches for \"\(query)\"")
                } else {
                    resultsList
                }
            }
        }
        .onAppear { fieldFocused = true }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Text("/")
                .font(DeckFont.mono(20, weight: .semibold))
                .foregroundStyle(app.theme.accent)

            TextField("", text: $query, prompt: Text("search")
                .foregroundColor(app.theme.muted))
                .font(DeckFont.mono(19))
                .foregroundStyle(app.theme.fg)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)

            if !query.isEmpty {
                Button {
                    query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(app.theme.muted)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(app.theme.bgInset)
        .overlay(alignment: .bottom) {
            Rectangle().fill(app.theme.border).frame(height: 1)
        }
        .padding(.top, 12)
    }

    private var resultsList: some View {
        let found = results

        return List {
            if !found.artists.isEmpty {
                section("artists · \(found.artists.count)") {
                    ForEach(found.artists.prefix(8), id: \.self) { artist in
                        row(title: artist, subtitle: "artist", trackID: nil) {
                            play(app.albums(byArtist: artist).flatMap(\.tracks))
                        }
                    }
                }
            }

            if !found.albums.isEmpty {
                section("albums · \(found.albums.count)") {
                    ForEach(found.albums.prefix(12)) { album in
                        row(
                            title: album.title,
                            subtitle: album.artist,
                            trackID: album.tracks.first?.externalID
                        ) {
                            play(album.tracks)
                        }
                    }
                }
            }

            if !found.tracks.isEmpty {
                section("songs · \(found.tracks.count)") {
                    ForEach(Array(found.tracks.prefix(40).enumerated()), id: \.element.id) { offset, track in
                        TrackRow(track: track) {
                            play(Array(found.tracks.prefix(40)), startingAt: offset)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        Section {
            content()
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } header: {
            SectionLabel(text: title)
                .padding(.vertical, 4)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
    }

    private func row(
        title: String, subtitle: String, trackID: String?, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Artwork(trackID: trackID, size: 40,
                        cornerFallbackSymbol: trackID == nil ? "person.fill" : "music.note")
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DeckFont.mono(13))
                        .foregroundStyle(app.theme.fg)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(DeckFont.mono(9))
                        .foregroundStyle(app.theme.muted)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func play(_ tracks: [Track], startingAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        app.playback.play(tracks: tracks, startingAt: index)
        Haptics.tap()
        dismiss()
    }
}

import SwiftUI

struct SettingsPage: View {
    @EnvironmentObject var app: MobileState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            app.theme.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header

                    group("theme") {
                        // A grid rather than a picker: the choice is visual, so the
                        // swatches have to be visible at the point of choosing.
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 104), spacing: 10)],
                            spacing: 10
                        ) {
                            ForEach(Theme.all) { theme in
                                themeSwatch(theme)
                            }
                        }
                    }

                    group("visualiser") {
                        Toggle(isOn: $app.showsVisualizer) {
                            Text("animate while playing")
                                .font(DeckFont.mono(12))
                                .foregroundStyle(app.theme.fg)
                        }
                        .tint(app.theme.accent)

                        Text("""
                            Apple Music decodes audio in the system music player, not in \
                            this app, so there are no samples here to analyse. The bars \
                            are generated from the track and its position — decorative, \
                            not a measurement of the sound.
                            """)
                            .font(DeckFont.mono(10))
                            .foregroundStyle(app.theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    group("library") {
                        LabeledRow(label: "songs", value: "\(app.tracks.count)")
                        LabeledRow(label: "albums", value: "\(app.albums.count)")
                        LabeledRow(label: "artists", value: "\(app.artists.count)")
                        LabeledRow(label: "playlists", value: "\(app.playlists.count)")

                        BracketButton(label: app.isLoading ? "reloading…" : "reload library",
                                      disabled: app.isLoading) {
                            Task { await app.reload() }
                        }
                    }

                    group("about") {
                        Text("""
                            Deck plays the Apple Music library on this device, including \
                            subscription tracks you have added. It reads your library and \
                            never changes it.

                            Syncing to a Rockbox player lives in the desktop app — iOS \
                            gives no access to USB storage.
                            """)
                            .font(DeckFont.mono(10))
                            .foregroundStyle(app.theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
                .padding(.bottom, 40)
            }
        }
    }

    private var header: some View {
        HStack {
            Rectangle().fill(app.theme.accent).frame(width: 2, height: 14)
            Text("deck://settings")
                .font(DeckFont.mono(13, weight: .semibold))
                .foregroundStyle(app.theme.fg)
            Spacer()
            BracketButton(label: "done") { dismiss() }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: title)
            content()
        }
    }

    private func themeSwatch(_ theme: Theme) -> some View {
        let selected = app.theme.id == theme.id

        return Button {
            app.theme = theme
            Haptics.tap()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach([theme.accent, theme.green, theme.yellow, theme.red], id: \.self) { color in
                        Rectangle().fill(color).frame(height: 14)
                    }
                }
                Text(theme.name)
                    .font(DeckFont.mono(9))
                    .foregroundStyle(selected ? theme.fg : theme.muted)
                    .lineLimit(1)
            }
            .padding(8)
            .background(theme.bgAlt)
            .overlay(
                Rectangle().strokeBorder(
                    selected ? app.theme.accent : theme.border,
                    lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    @EnvironmentObject var app: MobileState

    var body: some View {
        HStack {
            Text(label)
                .font(DeckFont.mono(11))
                .foregroundStyle(app.theme.muted)
            Spacer()
            Text(value)
                .font(DeckFont.mono(11))
                .foregroundStyle(app.theme.fg)
        }
    }
}

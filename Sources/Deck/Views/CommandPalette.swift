import DeckCore
import SwiftUI

struct Command: Identifiable {
    let id = UUID()
    let name: String
    let hint: String
    let run: (AppState) -> Void
}

/// `:` opens this. Modals get a 2px accent top border — the one place 2px is allowed.
struct CommandPalette: View {
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // Click-off to dismiss.
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                Rectangle()
                    .fill(app.theme.accent)
                    .frame(height: 2)

                HStack(spacing: 8) {
                    Text(":")
                        .font(DeckFont.mono(14))
                        .foregroundStyle(app.theme.magenta)
                    TextField("command", text: $query)
                        .textFieldStyle(.plain)
                        .font(DeckFont.mono(13))
                        .foregroundStyle(app.theme.fg)
                        .focused($fieldFocused)
                        .onSubmit { runSelected() }
                        .onExitCommand { dismiss() }
                        .onChange(of: query) { _, _ in selection = 0 }
                        .onChange(of: fieldFocused) { _, focused in
                            app.setTextInputFocused(focused)
                        }
                        .onDisappear { if fieldFocused { app.setTextInputFocused(false) } }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(app.theme.bgInset)

                TUIDivider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, command in
                            HStack(spacing: 8) {
                                Text(index == selection ? "›" : " ")
                                    .foregroundStyle(app.theme.accent)
                                Text(command.name)
                                    .foregroundStyle(app.theme.fg)
                                Spacer()
                                Text(command.hint)
                                    .foregroundStyle(app.theme.muted)
                            }
                            .font(DeckFont.mono(11))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(index == selection ? app.theme.selection : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { command.run(app); dismiss() }
                        }
                        if filtered.isEmpty {
                            Text("no matching command")
                                .font(DeckFont.mono(11))
                                .foregroundStyle(app.theme.muted)
                                .padding(14)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            .frame(width: 520)
            .background(app.theme.bgAlt)
            .overlay(Rectangle().strokeBorder(app.theme.border, lineWidth: 1))
            .padding(.top, 90)
            .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
            .onKeyPress(.downArrow) {
                selection = min(max(0, filtered.count - 1), selection + 1); return .handled
            }
        }
        .onAppear { fieldFocused = true }
    }

    private var filtered: [Command] {
        guard !query.isEmpty else { return commands }
        let q = query.lowercased()
        return commands.filter {
            $0.name.lowercased().contains(q) || $0.hint.lowercased().contains(q)
        }
    }

    private func runSelected() {
        guard filtered.indices.contains(selection) else { return }
        filtered[selection].run(app)
        dismiss()
    }

    private func dismiss() {
        app.showCommandPalette = false
        query = ""
    }

    // MARK: Commands

    private var commands: [Command] {
        var list: [Command] = [
            Command(name: "play / pause", hint: "space") { $0.player.toggle() },
            Command(name: "next track", hint: "n") { $0.player.next() },
            Command(name: "previous track", hint: "p") { $0.player.previous() },
            Command(name: "now playing", hint: "f") { $0.showNowPlaying.toggle() },
            Command(name: "toggle shuffle", hint: "s") { $0.toggleShuffle() },
            Command(name: "cycle repeat", hint: "r") { $0.cycleRepeat() },
            Command(name: "go to albums", hint: "1") { $0.navigate(to: .albums) },
            Command(name: "go to artists", hint: "2") { $0.navigate(to: .artists) },
            Command(name: "go to songs", hint: "3") { $0.navigate(to: .songs) },
            Command(name: "go to queue", hint: "4") { $0.navigate(to: .queue) },
            Command(name: "go to sync", hint: "S") { $0.navigate(to: .sync) },
            Command(name: "go to settings", hint: ",") { $0.navigate(to: .settings) },
            Command(name: "rescan library", hint: "R") { $0.scanLibrary() },
            Command(name: "add library folder", hint: "") { $0.addLibraryRoot() },
            Command(name: "repair missing tags", hint: "musicbrainz") { $0.enrichMissingMetadata() },
            Command(name: "rescan devices", hint: "") { $0.refreshDevices() },
            Command(name: "build sync plan", hint: "dry run") {
                $0.navigate(to: .sync); $0.buildPlan()
            },
            Command(name: "start sync", hint: "") { $0.runSync() },
            Command(name: "toggle scanlines", hint: "") { $0.config.scanlines.toggle() },
            Command(name: "clear conversion cache", hint: "") {
                Transcoder.clearCache()
                $0.statusMessage = "cleared conversion cache"
            },
            Command(name: "quit", hint: "cmd+q") { _ in NSApplication.shared.terminate(nil) },
        ]

        for theme in Theme.all {
            list.append(Command(name: "theme: \(theme.name)", hint: theme.id) {
                $0.config.themeID = theme.id
            })
        }
        return list
    }
}

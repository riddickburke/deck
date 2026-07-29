import DeckCore
import SwiftUI

@main
struct DeckApp: App {
    @StateObject private var app = AppState()

    init() {
        // `deck --scan` indexes the configured folders and prints a summary without
        // opening a window. Useful for checking that a library is actually reachable,
        // and for seeing what the app sees when the UI looks empty.
        if CommandLine.arguments.contains("--scan") {
            HeadlessScan.run()
        }
        // `deck --apple-music` verifies the Music.app bridge without opening a window.
        if CommandLine.arguments.contains("--apple-music") {
            AppleMusicProbe.run()
        }
        // `deck --check-update` asks GitHub whether a newer release exists.
        if CommandLine.arguments.contains("--check-update") {
            UpdateProbe.run()
        }
    }

    var body: some Scene {
        Window("deck", id: "main") {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 940, minHeight: 620)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("playback") {
                Button("play / pause") { app.player.toggle() }
                Button("next") { app.player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("previous") { app.player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("shuffle") { app.toggleShuffle() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("repeat") { app.cycleRepeat() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            CommandMenu("library") {
                Button("rescan library") { app.scanLibrary() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("add folder…") { app.addLibraryRoot() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("repair missing tags") { app.enrichMissingMetadata() }
                Divider()
                Button("command palette") { app.showCommandPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
            }

            CommandMenu("device") {
                Button("rescan devices") { app.refreshDevices() }
                Button("build sync plan") { app.navigate(to: .sync); app.buildPlan() }
                Button("start sync") { app.runSync() }
            }
        }
    }
}

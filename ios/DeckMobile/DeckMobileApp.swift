import SwiftUI

@main
struct DeckMobileApp: App {
    @StateObject private var app = MobileState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                // Injected alongside, not republished through `MobileState`. A view then
                // observes only what it reads: the album grid never redraws for a
                // visualiser frame, and the songs list never redraws for a clock tick.
                .environmentObject(app.playback)
                .environmentObject(app.playback.clock)
                .environmentObject(app.visualizer)
                // The whole app is dark by construction, and the palettes are chosen
                // rather than derived, so light mode is not a variant that exists.
                .preferredColorScheme(.dark)
                .tint(app.theme.accent)
        }
    }
}

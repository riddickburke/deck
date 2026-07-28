import DeckCore
import SwiftUI

/// The streaming chooser. Picking a service pins the browser to it and hides local
/// files entirely — streaming and owned music are different modes, and mixing them
/// makes it unclear what can actually be synced to a device.
struct StreamingView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 14)],
                    alignment: .leading, spacing: 14
                ) {
                    appleMusicCard
                    spotifyCard
                }

                footer
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("streaming")
                .font(DeckFont.mono(20, weight: .semibold))
                .foregroundStyle(app.theme.fg)
            Text("browse a subscription library in deck. playback runs in the service's own app, because neither service lets a third party decode its audio.")
                .font(DeckFont.mono(10))
                .foregroundStyle(app.theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Services

    private var appleMusicCard: some View {
        serviceCard(
            source: .appleMusic,
            title: "apple music",
            subtitle: "plays through Music.app",
            accent: app.theme.magenta,
            count: app.appleMusicTracks.count,
            busy: app.isImportingAppleMusic,
            connected: !app.appleMusicTracks.isEmpty,
            error: app.appleMusicError,
            primaryLabel: app.appleMusicTracks.isEmpty ? "connect" : "open",
            primaryAction: {
                if app.appleMusicTracks.isEmpty {
                    app.importAppleMusic()
                } else {
                    app.enterStreamingMode(.appleMusic)
                }
            },
            secondary: app.appleMusicTracks.isEmpty ? nil : ("refresh", { app.importAppleMusic() }),
            note: "needs permission to control Music, which macOS asks for once."
        )
    }

    private var spotifyCard: some View {
        let hasClientID = !(app.config.spotifyClientID ?? "").isEmpty
        return serviceCard(
            source: .spotify,
            title: "spotify",
            subtitle: "plays through an official spotify client",
            accent: app.theme.green,
            count: app.spotifyTracks.count,
            busy: app.isImportingSpotify || app.spotify.isSigningIn,
            connected: !app.spotifyTracks.isEmpty,
            error: app.spotify.lastError,
            primaryLabel: {
                if !app.spotifyTracks.isEmpty { return "open" }
                if app.spotify.isAuthorized { return "import library" }
                return hasClientID ? "connect" : "needs a client id"
            }(),
            primaryAction: {
                if !app.spotifyTracks.isEmpty {
                    app.enterStreamingMode(.spotify)
                } else if app.spotify.isAuthorized {
                    app.importSpotify()
                } else if hasClientID {
                    app.signInToSpotify()
                } else {
                    app.navigate(to: .settings)
                }
            },
            secondary: app.spotify.isAuthorized ? ("sign out", { app.signOutOfSpotify() }) : nil,
            note: hasClientID
                ? "playback control requires premium; browsing does not."
                : "add a client id in settings first — spotify requires you to register your own app."
        )
    }

    private func serviceCard(
        source: TrackSource,
        title: String,
        subtitle: String,
        accent: Color,
        count: Int,
        busy: Bool,
        connected: Bool,
        error: String?,
        primaryLabel: String,
        primaryAction: @escaping () -> Void,
        secondary: (String, () -> Void)?,
        note: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Rectangle().fill(accent).frame(width: 2, height: 14)
                Text(title)
                    .font(DeckFont.mono(14, weight: .semibold))
                    .foregroundStyle(app.theme.fg)
                Spacer()
                if connected {
                    Text("\(count) tracks")
                        .font(DeckFont.mono(9))
                        .foregroundStyle(app.theme.green)
                }
            }

            Text(subtitle)
                .font(DeckFont.mono(10))
                .foregroundStyle(app.theme.muted)

            if let error {
                Text(error)
                    .font(DeckFont.mono(9))
                    .foregroundStyle(app.theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(note)
                    .font(DeckFont.mono(9))
                    .foregroundStyle(app.theme.muted.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                BracketButton(
                    label: busy ? "working…" : primaryLabel,
                    tint: accent,
                    disabled: busy
                ) { primaryAction() }

                if let secondary {
                    BracketButton(label: secondary.0, disabled: busy) { secondary.1() }
                }
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(app.theme.bgInset)
        .overlay(Rectangle().strokeBorder(
            app.sourceFilter == source ? accent : app.theme.border, lineWidth: 1))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            TUIDivider()
            Text("streaming tracks cannot be synced to a rockbox player: there is no file to copy. only your local library can.")
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted)
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)

            if app.isStreamingMode {
                BracketButton(label: "← back to local library") { app.exitStreamingMode() }
                    .padding(.top, 4)
            }
        }
    }
}

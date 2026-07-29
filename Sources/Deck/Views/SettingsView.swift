import DeckCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var updater = Updater()
    @State private var transcodeCacheSize: Int64 = 0
    @State private var decodedCacheSize: Int64 = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                librarySection
                themeSection
                eqSection
                visualiserSection
                metadataSection
                streamingSection
                toolingSection
                cacheSection
                updateSection
            }
            .padding(18)
        }
        .task {
            transcodeCacheSize = Transcoder.cacheSize()
            decodedCacheSize = SourceResolver.cacheSize()
        }
    }

    // MARK: Library

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "library folders")

            if app.config.libraryRoots.isEmpty {
                Text("no folders added yet.")
                    .font(DeckFont.mono(11))
                    .foregroundStyle(app.theme.muted)
            }

            ForEach(app.config.libraryRoots, id: \.self) { path in
                HStack(spacing: 8) {
                    Text("·")
                        .font(DeckFont.mono(11))
                        .foregroundStyle(app.theme.muted)
                    Text(path)
                        .font(DeckFont.mono(10))
                        .foregroundStyle(app.theme.fg)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    BracketButton(label: "remove", tint: app.theme.red, compact: true) {
                        app.removeLibraryRoot(path)
                    }
                }
            }

            HStack(spacing: 10) {
                BracketButton(label: "+ add folder") { app.addLibraryRoot() }
                BracketButton(
                    label: app.isScanning ? "scanning…" : "rescan",
                    disabled: app.isScanning
                ) { app.scanLibrary() }
            }

            if let progress = app.scanProgress {
                VStack(alignment: .leading, spacing: 3) {
                    BlockMeter(
                        fraction: progress.total > 0
                            ? Double(progress.scanned) / Double(progress.total) : 0,
                        width: 30, tint: app.theme.accent)
                    Text("\(progress.scanned)/\(progress.total) · \(progress.fromCache) cached · \(progress.currentPath)")
                        .font(DeckFont.mono(9))
                        .foregroundStyle(app.theme.muted)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: Theme

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "colour scheme")

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 10)],
                alignment: .leading, spacing: 10
            ) {
                ForEach(Theme.all) { theme in
                    themeCard(theme)
                }
            }

            toggleRow("scanline overlay", isOn: Binding(
                get: { app.config.scanlines },
                set: { app.config.scanlines = $0 }))
        }
    }

    private func themeCard(_ theme: Theme) -> some View {
        let active = app.config.themeID == theme.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(active ? "[x]" : "[ ]")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(active ? theme.accent : app.theme.muted)
                Text(theme.name)
                    .font(DeckFont.mono(11))
                    .foregroundStyle(app.theme.fg)
                Spacer()
            }
            // Swatch row doubles as a live preview of the palette.
            HStack(spacing: 0) {
                ForEach(
                    Array([theme.bg, theme.bgAlt, theme.fg, theme.muted, theme.accent,
                           theme.green, theme.yellow, theme.red, theme.magenta, theme.cyan]
                        .enumerated()), id: \.offset
                ) { _, color in
                    Rectangle().fill(color).frame(height: 16)
                }
            }
            .overlay(Rectangle().strokeBorder(theme.border, lineWidth: 1))
        }
        .padding(8)
        .background(theme.bgAlt)
        .overlay(Rectangle().strokeBorder(
            active ? theme.accent : app.theme.border, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { app.config.themeID = theme.id }
    }

    // MARK: EQ

    private var eqSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "equaliser")
                Spacer()
                BracketButton(label: "flat", compact: true) { app.player.resetEQ() }
            }

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(Player.eqFrequencies.enumerated()), id: \.offset) { index, freq in
                    VStack(spacing: 4) {
                        Text(String(format: "%+.0f", app.player.eqGains[index]))
                            .font(DeckFont.mono(8))
                            .foregroundStyle(app.theme.muted)
                        // Vertical slider built from a rotated standard slider; the
                        // native vertical style does not exist on macOS.
                        Slider(
                            value: Binding(
                                get: { Double(app.player.eqGains[index]) },
                                set: { app.player.eqGains[index] = Float($0) }),
                            in: -12...12
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 90, height: 20)
                        .frame(width: 22, height: 90)
                        Text(freq >= 1000 ? "\(Int(freq / 1000))k" : "\(Int(freq))")
                            .font(DeckFont.mono(8))
                            .foregroundStyle(app.theme.muted)
                    }
                }
                Spacer()
            }
            .padding(10)
            .background(app.theme.bgInset)
            .overlay(Rectangle().strokeBorder(app.theme.border, lineWidth: 1))
        }
    }

    private var visualiserSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "visualiser")

            HStack(spacing: 10) {
                Text("sensitivity")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted)
                Slider(
                    value: Binding(
                        get: { app.config.resolvedSpectrumSensitivity },
                        set: { app.config.spectrumSensitivity = $0 }),
                    in: 0...1)
                    .frame(width: 200)
                Text(String(format: "%.2f", app.config.resolvedSpectrumSensitivity))
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.fg)
                BracketButton(label: "default", compact: true) {
                    app.config.spectrumSensitivity = 0.35
                }
            }

            let scaling = Spectrum.Scaling.forSensitivity(
                app.config.resolvedSpectrumSensitivity, fftSize: 1024)
            Text(String(
                format: "bars fill at %.0f dBFS and empty at %.0f dBFS. higher sensitivity fills on quieter material.",
                scaling.ceilingDecibels, scaling.floorDecibels))
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Text("the visualiser analyses audio played by deck itself. while apple music or spotify is playing, the audio never passes through this process and there is nothing to analyse.")
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)

            toggleRow("animate during streaming", isOn: Binding(
                get: { app.config.streamingVisualiserAnimates },
                set: { app.config.animateStreamingVisualiser = $0 }))

            Text("draws a generated animation instead of a flat meter while a service is playing. it follows play, pause and seek, and each track animates differently — but it is decorative, not a measurement of the audio. it is labelled on the now playing screen.")
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Metadata

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "metadata")

            toggleRow("look up missing tags online", isOn: Binding(
                get: { app.config.onlineLookupEnabled },
                set: { app.config.onlineLookupEnabled = $0 }))

            Text("sources: musicbrainz for tags, cover art archive then itunes for art. no api key needed. musicbrainz allows one request per second, so repair runs slowly in the background.")
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            let needing = app.tracks.count { $0.needsMetadata && !$0.enriched }
            HStack(spacing: 10) {
                Text("\(needing) tracks missing tags")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(needing > 0 ? app.theme.yellow : app.theme.green)
                if app.isEnriching {
                    BracketButton(label: "stop", tint: app.theme.red) { app.stopEnriching() }
                } else {
                    BracketButton(
                        label: "repair tags", disabled: needing == 0
                    ) { app.enrichMissingMetadata() }
                }
            }

            HStack(spacing: 8) {
                Text("device folder layout")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted)
                TUITextField(
                    placeholder: "{albumartist}/{album}",
                    text: Binding(
                        get: { app.config.deviceFolderTemplate },
                        set: { app.config.deviceFolderTemplate = $0; app.syncPlan = nil }),
                    width: 240)
            }
            Text("tokens: {albumartist} {artist} {album} {year} {genre}")
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted.opacity(0.7))
        }
    }

    // MARK: Tooling

    private var streamingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "streaming")

            Text("apple music plays through Music.app, because subscription tracks are DRM-protected streams Deck cannot decode itself. spotify plays through an official spotify client over Connect, for the same reason. neither can be synced to a rockbox player.")
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text("apple music")
                    .font(DeckFont.mono(11))
                    .foregroundStyle(app.theme.fg)
                Text("\(app.appleMusicTracks.count) tracks")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted)
                BracketButton(
                    label: app.isImportingAppleMusic ? "reading…" : "import",
                    disabled: app.isImportingAppleMusic
                ) { app.importAppleMusic() }
            }

            Divider().background(app.theme.border)

            HStack(spacing: 8) {
                Text("spotify client id")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted)
                TUITextField(
                    placeholder: "from developer.spotify.com",
                    text: Binding(
                        get: { app.config.spotifyClientID ?? "" },
                        set: { app.config.spotifyClientID = $0.isEmpty ? nil : $0 }),
                    width: 280)
            }

            Text("register an app at developer.spotify.com/dashboard and add exactly this redirect uri: \(SpotifySession.redirectURI) — spotify matches it character for character. playback control needs premium; browsing does not.")
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if app.spotify.isAuthorized {
                    Text("signed in")
                        .font(DeckFont.mono(10))
                        .foregroundStyle(app.theme.green)
                    BracketButton(label: "import library") { app.importSpotify() }
                    BracketButton(label: "sign out", tint: app.theme.red) { app.signOutOfSpotify() }
                } else {
                    BracketButton(
                        label: app.spotify.isSigningIn ? "waiting for browser…" : "connect spotify",
                        tint: app.theme.green,
                        disabled: app.spotify.isSigningIn
                    ) { app.signInToSpotify() }
                }
            }
        }
    }

    private var toolingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "external tools")
            toolRow("ffmpeg", present: Shell.has("ffmpeg"), why: "flac→mp3 conversion, embedded art, opus/ogg playback")
            toolRow("ffprobe", present: Shell.has("ffprobe"), why: "reads vorbis comments that avfoundation cannot")
            if !Shell.has("ffmpeg") {
                Text("install with:  brew install ffmpeg")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.yellow)
            }
        }
    }

    private func toolRow(_ name: String, present: Bool, why: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(present ? "[ok]" : "[--]")
                .font(DeckFont.mono(10))
                .foregroundStyle(present ? app.theme.green : app.theme.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(DeckFont.mono(11))
                    .foregroundStyle(app.theme.fg)
                Text(why)
                    .font(DeckFont.mono(9))
                    .foregroundStyle(app.theme.muted)
            }
            Spacer()
        }
    }

    // MARK: Updates

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "updates")

            HStack(spacing: 10) {
                Text("version \(Updater.currentVersion.description)")
                    .font(DeckFont.mono(11))
                    .foregroundStyle(app.theme.fg)

                BracketButton(
                    label: updater.isBusy ? "working…" : "check for updates",
                    disabled: updater.isBusy
                ) { updater.check() }

                Spacer()
            }

            updateStatus
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updater.state {
        case .idle:
            Text("installs over the current version — no need to delete the old one first.")
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted.opacity(0.75))

        case .checking:
            Text("checking github…")
                .font(DeckFont.mono(10))
                .foregroundStyle(app.theme.muted)

        case .upToDate(let version):
            Text("[ok] \(version) is the latest release")
                .font(DeckFont.mono(10))
                .foregroundStyle(app.theme.green)

        case .available(let update):
            VStack(alignment: .leading, spacing: 6) {
                Text("\(update.version) is available · \(update.sizeInBytes.byteString)")
                    .font(DeckFont.mono(11))
                    .foregroundStyle(app.theme.accent)

                if !update.notes.isEmpty {
                    ScrollView {
                        Text(update.notes)
                            .font(DeckFont.mono(9))
                            .foregroundStyle(app.theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                    .padding(8)
                    .background(app.theme.bgInset)
                    .overlay(Rectangle().strokeBorder(app.theme.border, lineWidth: 1))
                }

                HStack(spacing: 10) {
                    BracketButton(label: "download & install", tint: app.theme.green) {
                        updater.downloadAndInstall(update)
                    }
                    BracketButton(label: "release notes") {
                        NSWorkspace.shared.open(update.pageURL)
                    }
                }
            }

        case .downloading(let update, let fraction):
            VStack(alignment: .leading, spacing: 4) {
                Text("downloading \(update.version)…  \(Int(fraction * 100))%")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.fg)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(app.theme.bgInset)
                        Rectangle()
                            .fill(app.theme.accent)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 4)
            }

        case .installing(let update):
            Text("verifying and installing \(update.version)…")
                .font(DeckFont.mono(10))
                .foregroundStyle(app.theme.fg)

        case .readyToRestart:
            Text("installing — Deck will quit and reopen on the new version.")
                .font(DeckFont.mono(10))
                .foregroundStyle(app.theme.green)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text("[--] \(message)")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.red)
                    .fixedSize(horizontal: false, vertical: true)
                BracketButton(label: "open releases page") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/\(UpdateChecker.repository)/releases/latest")!)
                }
            }
        }
    }

    // MARK: Cache

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "caches")
            HStack(spacing: 10) {
                Text("converted mp3s: \(transcodeCacheSize.byteString)")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted)
                BracketButton(label: "clear", tint: app.theme.red) {
                    Transcoder.clearCache()
                    transcodeCacheSize = 0
                    app.statusMessage = "cleared conversion cache"
                }
            }
            HStack(spacing: 10) {
                Text("decoded audio: \(decodedCacheSize.byteString)")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted)
                BracketButton(label: "clear", tint: app.theme.red) {
                    SourceResolver.clearCache()
                    decodedCacheSize = 0
                    app.statusMessage = "cleared decoded audio cache"
                }
            }
            Text("opus and ogg are decoded to pcm for playback and cached, capped at \(SourceResolver.maxCacheBytes.byteString) with oldest evicted first.")
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text("album art cache")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted)
                BracketButton(label: "clear", tint: app.theme.red) {
                    Task {
                        await ArtworkStore.shared.clearAll()
                        await MainActor.run { app.statusMessage = "cleared artwork cache" }
                    }
                }
            }
            Text(Config.appSupportDirectory.path)
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted.opacity(0.6))
        }
    }

    // MARK: Shared

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(isOn.wrappedValue ? "[x]" : "[ ]")
                .font(DeckFont.mono(11))
                .foregroundStyle(isOn.wrappedValue ? app.theme.green : app.theme.muted)
            Text(label)
                .font(DeckFont.mono(11))
                .foregroundStyle(app.theme.fg)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.wrappedValue.toggle() }
    }
}

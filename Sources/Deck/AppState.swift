import AppKit
import DeckCore
import SwiftUI

enum Route: Hashable {
    case albums
    case artists
    case songs
    case album(AlbumKey)
    case artist(String)
    case playlist(UUID)
    case queue
    case sync
    case settings
    /// Picker for choosing a streaming service.
    case streaming
}

enum Pane: Hashable { case sidebar, content }

@MainActor
final class AppState: ObservableObject {
    // MARK: Library

    /// Everything currently browsable — local plus any imported streaming sources.
    @Published var tracks: [Track] = []
    /// Just what the filesystem scan produced.
    @Published var localTracks: [Track] = []
    @Published var albums: [Album] = []
    @Published var playlists: [Playlist] = []

    @Published var isScanning = false
    @Published var scanProgress: ScanProgress?

    // MARK: Navigation

    @Published var route: Route = .albums
    @Published var history: [Route] = []
    /// Routes popped by Back, so Forward can replay them.
    @Published var future: [Route] = []
    @Published var focusedPane: Pane = .content
    @Published var selectionIndex = 0

    // MARK: Search / command

    @Published var searchQuery = ""
    @Published var isSearching = false
    /// Bumped to move keyboard focus into the toolbar search field.
    @Published var searchFocusTrigger = 0
    @Published var showCommandPalette = false
    @Published var showNowPlaying = false
    @Published var statusMessage: String?

    /// True while any text field has the keyboard. Single-key vim bindings are suppressed
    /// while this holds, otherwise typing "s" in a playlist name would toggle shuffle.
    @Published private(set) var textInputFocused = false
    private var focusedFieldCount = 0

    /// Counted rather than a plain flag: moving between two fields can report the new
    /// field's focus before the old field's blur, and a bool would end up stuck off.
    func setTextInputFocused(_ focused: Bool) {
        focusedFieldCount = max(0, focusedFieldCount + (focused ? 1 : -1))
        let active = focusedFieldCount > 0
        if active != textInputFocused { textInputFocused = active }
    }

    /// Keyboard shortcuts should be ignored entirely while typing or in a modal.
    var keyboardShortcutsSuppressed: Bool {
        textInputFocused || showCommandPalette || isSearching
    }

    // MARK: Devices

    @Published var devices: [RockboxDevice] = []
    @Published var selectedDevice: RockboxDevice?
    @Published var syncPlan: SyncPlan?
    @Published var syncProgress: SyncProgress?
    @Published var syncReport: SyncReport?
    @Published var isSyncing = false
    @Published var isPlanning = false
    @Published var removeOrphans = false

    // MARK: Enrichment

    @Published var isEnriching = false
    @Published var enrichProgress: (done: Int, total: Int)?

    // MARK: Settings

    @Published var config: Config {
        didSet {
            config.save()
            if config.themeID != oldValue.themeID { theme = Theme.named(config.themeID) }
            if config.volume != oldValue.volume { player.volume = config.volume }
            if config.spectrumSensitivity != oldValue.spectrumSensitivity {
                player.spectrumSensitivity = config.resolvedSpectrumSensitivity
            }
        }
    }
    @Published var theme: Theme

    let player = Player()
    private let scanner = LibraryScanner()
    private let syncEngine = SyncEngine()
    private var deviceTimer: Timer?
    private(set) var mediaRemote: MediaRemote!

    init() {
        // Must run before anything touches the support directories, since the app's
        // identifier changed and the old location holds the existing index and playlists.
        Config.migrateLegacyDataIfNeeded()

        let loaded = Config.load()
        config = loaded
        theme = Theme.named(loaded.themeID)
        playlists = Self.loadPlaylists()

        // `didSet` does not fire during init, so a first launch would otherwise never
        // write the seeded defaults to disk.
        if !FileManager.default.fileExists(atPath: Config.configURL.path) { loaded.save() }

        player.volume = loaded.volume
        player.shuffle = loaded.shuffle
        player.repeatMode = loaded.repeatMode
        player.spectrumSensitivity = loaded.resolvedSpectrumSensitivity

        // System media keys and the Control Centre tile.
        mediaRemote = MediaRemote(player: player)
        mediaRemote.artworkProvider = { [weak self] track in
            guard let self else { return nil }
            guard let album = await MainActor.run(body: { self.album(for: track.albumKey) })
            else { return nil }
            return await ArtworkStore.shared.artwork(for: album)
        }

        let clientID = loaded.spotifyClientID
        Task { await spotify.restore(clientID: clientID) }

        refreshDevices()
        // Volumes appear and disappear without notice; polling is simpler and cheap
        // enough at this interval than subscribing to workspace mount notifications
        // for every volume type.
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        }
    }

    // MARK: - Derived collections

    var filteredAlbums: [Album] {
        guard !searchQuery.isEmpty else { return albums }
        let q = searchQuery.lowercased()
        return albums.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
    }

    var filteredTracks: [Track] {
        guard !searchQuery.isEmpty else { return tracks }
        let q = searchQuery.lowercased()
        return tracks.filter {
            $0.title.lowercased().contains(q)
                || $0.artist.lowercased().contains(q)
                || $0.album.lowercased().contains(q)
        }
    }

    var artistNames: [String] { LibraryGrouping.artists(from: albums) }

    func albums(for artist: String) -> [Album] {
        albums.filter { $0.artist == artist }
    }

    func album(for key: AlbumKey) -> Album? {
        albums.first { $0.key == key }
    }

    func playlist(_ id: UUID) -> Playlist? { playlists.first { $0.id == id } }

    func tracks(in playlist: Playlist) -> [Track] {
        let byPath = Dictionary(tracks.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        return playlist.trackPaths.compactMap { byPath[$0] }
    }

    /// Tracks that will be pushed to the device: everything in every sync-enabled playlist.
    var syncSelection: [Track] {
        let enabled = playlists.filter(\.syncEnabled)
        guard !enabled.isEmpty else { return [] }
        var seen = Set<String>()
        var result: [Track] = []
        for playlist in enabled {
            for track in tracks(in: playlist) where seen.insert(track.url.path).inserted {
                result.append(track)
            }
        }
        return result
    }

    // MARK: - Scanning

    func scanLibrary() {
        guard !isScanning else { return }
        guard !config.rootURLs.isEmpty else {
            statusMessage = "no library folder set — press , for settings"
            return
        }
        isScanning = true
        scanProgress = nil

        Task {
            await scanner.loadCache()
            let found = await scanner.scan(roots: config.rootURLs) { progress in
                Task { @MainActor in self.scanProgress = progress }
            }
            await MainActor.run {
                self.localTracks = found.sorted {
                    $0.artist.localizedStandardCompare($1.artist) == .orderedAscending
                }
                self.rebuildLibrary()
                self.isScanning = false
                self.scanProgress = nil
                self.statusMessage = "indexed \(found.count) tracks in \(self.albums.count) albums"
            }
        }
    }

    func addLibraryRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "add"
        panel.message = "choose a folder containing music"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !config.libraryRoots.contains(url.path) {
            config.libraryRoots.append(url.path)
        }
        scanLibrary()
    }

    func removeLibraryRoot(_ path: String) {
        config.libraryRoots.removeAll { $0 == path }
    }

    // MARK: - Playback helpers

    func play(album: Album, startingAt index: Int = 0) {
        play(tracks: album.tracks, startingAt: index)
    }

    func play(tracks list: [Track], startingAt index: Int = 0) {
        guard list.indices.contains(index) else { return }
        let track = list[index]

        // Apple Music tracks are DRM-protected streams with no file, so Music.app has to
        // do the decoding. Anything local stays on the in-process engine, which is what
        // keeps the EQ and spectrum working for the library Deck actually owns.
        if track.source == .appleMusic {
            startRemotePlayback(track)
            return
        }
        if track.source == .spotify {
            startSpotifyPlayback(track)
            return
        }

        if isRemoteActive { stopRemotePlayback() }
        player.setQueue(list.filter { !$0.isStreaming }, startAt: index)
        persistPlaybackPrefs()
    }

    // MARK: Unified transport

    func togglePlayPause() {
        guard isRemoteActive else { player.toggle(); return }
        let playing = remoteIsPlaying
        remoteIsPlaying.toggle()
        if activeBackend == .spotify {
            Task {
                do { playing ? try await spotify.client.pause() : try await spotify.client.resume() }
                catch { self.statusMessage = error.localizedDescription }
            }
            return
        }
        let remote = appleMusicRemote
        Task { playing ? await remote.pause() : await remote.resume() }
    }

    func nextTrack() {
        guard isRemoteActive else { player.next(); return }
        if activeBackend == .spotify {
            Task { try? await spotify.client.next() }
            return
        }
        let remote = appleMusicRemote
        Task { await remote.next() }
    }

    func previousTrack() {
        guard isRemoteActive else { player.previous(); return }
        if activeBackend == .spotify {
            Task { try? await spotify.client.previous() }
            return
        }
        let remote = appleMusicRemote
        Task { await remote.previous() }
    }

    func seek(to seconds: TimeInterval) {
        guard isRemoteActive else { player.seek(to: seconds); return }
        remotePosition = seconds
        if activeBackend == .spotify {
            Task { try? await spotify.client.seek(to: seconds) }
            return
        }
        let remote = appleMusicRemote
        Task { await remote.seek(to: seconds) }
    }

    func seekRelative(_ delta: TimeInterval) {
        seek(to: max(0, min(duration, position + delta)))
    }

    func toggleShuffle() {
        player.shuffle.toggle()
        config.shuffle = player.shuffle
        statusMessage = player.shuffle ? "shuffle on" : "shuffle off"
    }

    func cycleRepeat() {
        let modes = Config.RepeatMode.allCases
        let i = modes.firstIndex(of: player.repeatMode) ?? 0
        player.repeatMode = modes[(i + 1) % modes.count]
        config.repeatMode = player.repeatMode
        statusMessage = player.repeatMode.symbol
    }

    func adjustVolume(_ delta: Float) {
        let v = max(0, min(1, config.volume + delta))
        player.volume = v
        config.volume = v
        if isRemoteActive {
            let remote = appleMusicRemote
            Task { await remote.setVolume(v) }
        }
    }

    private func persistPlaybackPrefs() {
        config.shuffle = player.shuffle
        config.repeatMode = player.repeatMode
    }

    // MARK: - Playlists

    static func loadPlaylists() -> [Playlist] {
        guard let data = try? Data(contentsOf: Config.playlistsURL),
              let decoded = try? JSONDecoder().decode([Playlist].self, from: data)
        else { return [] }
        return decoded
    }

    func savePlaylists() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(playlists) else { return }
        try? data.write(to: Config.playlistsURL, options: .atomic)
    }

    @discardableResult
    func createPlaylist(named name: String, tracks list: [Track] = []) -> Playlist {
        let playlist = Playlist(name: name, trackPaths: list.map(\.url.path))
        playlists.append(playlist)
        savePlaylists()
        return playlist
    }

    func addToPlaylist(_ id: UUID, tracks list: [Track]) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let existing = Set(playlists[i].trackPaths)
        playlists[i].trackPaths.append(contentsOf: list.map(\.url.path).filter { !existing.contains($0) })
        savePlaylists()
        statusMessage = "added \(list.count) to \(playlists[i].name)"
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        savePlaylists()
        if case .playlist(let current) = route, current == id { route = .albums }
    }

    func toggleSync(_ id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].syncEnabled.toggle()
        savePlaylists()
        syncPlan = nil
    }

    // MARK: - Devices & sync

    func refreshDevices() {
        let found = DeviceScanner.scan()
        devices = found
        if let current = selectedDevice, !found.contains(where: { $0.id == current.id }) {
            selectedDevice = nil
            syncPlan = nil
        }
        if selectedDevice == nil { selectedDevice = found.first { $0.hasRockbox } ?? found.first }
    }

    func buildPlan() {
        guard let device = selectedDevice else {
            statusMessage = "no device selected"
            return
        }
        let selection = syncSelection
        guard !selection.isEmpty else {
            statusMessage = "nothing marked for sync — enable a playlist first"
            return
        }
        isPlanning = true
        syncReport = nil
        Task {
            let plan = await syncEngine.plan(
                tracks: selection, playlists: playlists, device: device, config: config)
            await MainActor.run {
                self.syncPlan = plan
                self.isPlanning = false
                self.statusMessage = plan.fits
                    ? "\(plan.transfers.count) to transfer, \(plan.upToDateCount) up to date"
                    : "plan exceeds free space by \((-plan.headroomAfterSync).byteString)"
            }
        }
    }

    func runSync() {
        guard let plan = syncPlan, !isSyncing else { return }
        guard plan.fits else {
            statusMessage = "not enough free space on device"
            return
        }
        isSyncing = true
        syncReport = nil
        let currentConfig = config
        let shouldRemove = removeOrphans

        Task {
            await syncEngine.resetCancellation()
            let report = await syncEngine.execute(
                plan: plan,
                config: currentConfig,
                removeOrphans: shouldRemove,
                artworkFor: { key in
                    // Reuse the same resolution chain the UI uses, so device art
                    // matches what is on screen.
                    guard let album = await MainActor.run(body: { self.album(for: key) })
                    else { return nil }
                    return await ArtworkStore.shared.deviceArtwork(
                        for: album, maxDimension: currentConfig.deviceArtworkSize)
                },
                progress: { progress in
                    Task { @MainActor in self.syncProgress = progress }
                }
            )
            await MainActor.run {
                self.isSyncing = false
                self.syncProgress = nil
                self.syncReport = report
                self.syncPlan = nil
                self.refreshDevices()
                self.statusMessage =
                    "synced \(report.copied + report.converted) files in \(report.duration.clockString)"
            }
        }
    }

    func cancelSync() {
        Task { await syncEngine.cancel() }
        statusMessage = "cancelling…"
    }

    // MARK: - Streaming sources

    @Published var appleMusicTracks: [Track] = []
    @Published var isImportingAppleMusic = false
    @Published var appleMusicError: String?
    /// nil shows everything; otherwise only that source.
    @Published var sourceFilter: TrackSource? { didSet { rebuildLibrary() } }

    let appleMusicRemote = AppleMusicRemote()

    @Published var spotifyTracks: [Track] = []
    @Published var isImportingSpotify = false
    @Published var spotifyDeviceName: String?
    let spotify = SpotifySession()

    /// Which engine owns playback right now. Apple Music tracks are played by Music.app,
    /// so the transport has to be pointed at whichever is actually running.
    @Published private(set) var activeBackend: TrackSource = .local
    @Published private(set) var remoteTrack: Track?
    @Published private(set) var remoteIsPlaying = false
    @Published private(set) var remotePosition: TimeInterval = 0
    @Published private(set) var remoteDuration: TimeInterval = 0
    private var remoteTimer: Timer?

    var isRemoteActive: Bool { activeBackend != .local }

    /// The spectrum is tapped from our own audio engine. When a service is doing the
    /// playing, the audio never passes through this process, so there is nothing to
    /// analyse — that has to be said rather than drawn as a flat, broken-looking meter.
    var hasSpectrumSignal: Bool { !isRemoteActive }

    /// Where the audio is actually coming out, for the visualiser's empty state.
    var playbackHostName: String? {
        switch activeBackend {
        case .local: return nil
        case .appleMusic: return "Music.app"
        case .spotify: return spotifyDeviceName ?? "Spotify"
        }
    }

    /// Live bars, or a flat set while a service is playing.
    var spectrum: [Float] {
        hasSpectrumSignal ? player.spectrum : Array(repeating: 0, count: Spectrum.bandCount)
    }

    // Unified transport, so views do not have to know which engine is playing.
    var currentTrack: Track? { isRemoteActive ? remoteTrack : player.currentTrack }
    var isPlaying: Bool { isRemoteActive ? remoteIsPlaying : player.isPlaying }
    var position: TimeInterval { isRemoteActive ? remotePosition : player.position }
    var duration: TimeInterval { isRemoteActive ? remoteDuration : player.duration }

    var availableSources: [TrackSource] {
        var sources: [TrackSource] = [.local]
        if !appleMusicTracks.isEmpty { sources.append(.appleMusic) }
        if !spotifyTracks.isEmpty { sources.append(.spotify) }
        return sources
    }

    // MARK: Spotify

    func signInToSpotify() {
        guard let id = config.spotifyClientID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            statusMessage = "add a Spotify client ID in settings first"
            return
        }
        Task {
            await spotify.signIn(clientID: id)
            if spotify.isAuthorized {
                statusMessage = "signed in to Spotify"
                importSpotify()
            } else if let error = spotify.lastError {
                statusMessage = error
            }
        }
    }

    func signOutOfSpotify() {
        Task {
            await spotify.signOut()
            spotifyTracks = []
            rebuildLibrary()
            statusMessage = "signed out of Spotify"
        }
    }

    func importSpotify() {
        guard !isImportingSpotify else { return }
        isImportingSpotify = true
        statusMessage = "reading Spotify library…"

        Task {
            do {
                // Saved albums and saved tracks are separate collections in the API;
                // a track saved on its own never appears in the albums response.
                let albums = try await spotify.client.savedAlbums { count in
                    Task { @MainActor in self.statusMessage = "spotify: \(count) tracks…" }
                }
                let singles = try await spotify.client.savedTracks()

                var seen = Set<String>()
                let merged = (albums + singles).filter {
                    guard let id = $0.externalID else { return false }
                    return seen.insert(id).inserted
                }

                await spotify.persistCurrentTokens()
                self.spotifyTracks = merged
                self.isImportingSpotify = false
                self.rebuildLibrary()
                self.statusMessage = "spotify: \(merged.count) tracks"
            } catch {
                self.isImportingSpotify = false
                self.statusMessage = error.localizedDescription
            }
        }
    }

    /// Recomputes the browsable library from the enabled sources.
    func rebuildLibrary() {
        let combined: [Track]
        switch sourceFilter {
        case .local: combined = localTracks
        case .appleMusic: combined = appleMusicTracks
        case .spotify: combined = spotifyTracks
        case nil: combined = localTracks + appleMusicTracks + spotifyTracks
        }
        tracks = combined
        albums = LibraryGrouping.albums(from: combined)
    }

    func importAppleMusic() {
        guard !isImportingAppleMusic else { return }
        isImportingAppleMusic = true
        appleMusicError = nil
        statusMessage = "reading Music.app library…"

        Task {
            do {
                let imported = try await AppleMusicLibrary.importLibrary()
                await MainActor.run {
                    self.appleMusicTracks = imported
                    self.isImportingAppleMusic = false
                    self.rebuildLibrary()
                    let cloud = imported.count { AppleMusicLibrary.isCloudBacked($0) }
                    self.statusMessage =
                        "apple music: \(imported.count) tracks, \(cloud) from the cloud"
                }
            } catch {
                await MainActor.run {
                    self.isImportingAppleMusic = false
                    self.appleMusicError = error.localizedDescription
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func startSpotifyPlayback(_ track: Track) {
        guard let uri = track.externalID else { return }
        player.pause()

        activeBackend = .spotify
        remoteTrack = track
        remoteDuration = track.duration
        remotePosition = 0
        remoteIsPlaying = true

        Task {
            do {
                // Connect can only target a device that already exists, so an active
                // Spotify client is a precondition rather than something Deck can create.
                let devices = try await spotify.client.devices()
                let target = devices.first { $0.isActive } ?? devices.first
                guard let target else {
                    throw SpotifyClient.Failure.noActiveDevice
                }
                self.spotifyDeviceName = target.name
                try await spotify.client.play(uri: uri, deviceID: target.id)
                await spotify.persistCurrentTokens()
            } catch {
                self.statusMessage = error.localizedDescription
                self.remoteIsPlaying = false
                self.activeBackend = .local
            }
        }
        startRemotePolling()
    }

    // MARK: Remote transport

    private func startRemotePlayback(_ track: Track) {
        guard let id = track.externalID else { return }

        // Stop the local engine first; two things playing at once is the obvious failure.
        player.pause()

        activeBackend = .appleMusic
        remoteTrack = track
        remoteDuration = track.duration
        remotePosition = 0
        remoteIsPlaying = true

        Task {
            do {
                try await appleMusicRemote.play(trackID: id)
                await appleMusicRemote.setVolume(config.volume)
            } catch {
                await MainActor.run {
                    self.statusMessage = error.localizedDescription
                    self.remoteIsPlaying = false
                }
            }
        }
        startRemotePolling()
    }

    /// Music.app is a separate process, so its state can only be observed by asking.
    private func startRemotePolling() {
        remoteTimer?.invalidate()
        remoteTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRemoteActive else { return }

                if self.activeBackend == .spotify {
                    // `try?` on a throwing call returning an Optional gives a double
                    // Optional, so it has to be flattened before binding.
                    if let state = (try? await self.spotify.client.playbackState()) ?? nil {
                        self.remoteIsPlaying = state.isPlaying
                        self.remotePosition = state.position
                        if state.duration > 0 { self.remoteDuration = state.duration }
                        self.spotifyDeviceName = state.deviceName
                        if let uri = state.trackURI, uri != self.remoteTrack?.externalID,
                           let match = self.spotifyTracks.first(where: { $0.externalID == uri }) {
                            self.remoteTrack = match
                        }
                    }
                    return
                }

                let state = await self.appleMusicRemote.refreshState()
                self.remoteIsPlaying = state.isPlaying
                self.remotePosition = state.position
                if state.duration > 0 { self.remoteDuration = state.duration }

                // Music.app advancing on its own should move our queue with it.
                if let id = state.trackID, id != self.remoteTrack?.externalID,
                   let match = self.appleMusicTracks.first(where: { $0.externalID == id }) {
                    self.remoteTrack = match
                }
            }
        }
    }

    private func stopRemotePlayback() {
        remoteTimer?.invalidate()
        remoteTimer = nil
        let remote = appleMusicRemote
        Task { await remote.stop() }
        activeBackend = .local
        remoteTrack = nil
        remoteIsPlaying = false
    }

    // MARK: - Conversion

    @Published var isConverting = false
    @Published var convertProgress: (done: Int, total: Int, file: String)?

    /// Converts tracks to MP3 and writes the result next to the original, leaving the
    /// original in place. Reached from the right-click menu on an album or a track.
    func convertToMP3(_ list: [Track], quality: Int, destination: URL? = nil) {
        guard !isConverting else {
            statusMessage = "a conversion is already running"
            return
        }
        guard Shell.has("ffmpeg") else {
            statusMessage = "ffmpeg not installed — brew install ffmpeg"
            return
        }
        let convertible = list.filter {
            Transcoder.convertibleFormats.contains($0.url.pathExtension.lowercased())
        }
        guard !convertible.isEmpty else {
            statusMessage = "nothing to convert — those files are already lossy"
            return
        }

        isConverting = true
        convertProgress = (0, convertible.count, "")

        Task {
            var written = 0
            var skipped = 0
            var errors: [String] = []

            for (i, track) in convertible.enumerated() {
                await MainActor.run {
                    self.convertProgress = (i, convertible.count, track.url.lastPathComponent)
                }

                let folder = destination ?? track.url.deletingLastPathComponent()
                let target = folder
                    .appendingPathComponent(track.url.deletingPathExtension().lastPathComponent)
                    .appendingPathExtension("mp3")

                if FileManager.default.fileExists(atPath: target.path) {
                    skipped += 1
                    continue
                }

                do {
                    // Reuse the sync transcode cache, then copy out — a track already
                    // converted for the device costs nothing to export.
                    let cached = try await Transcoder.transcodeToMP3(track, quality: quality)
                    try FileManager.default.copyItem(at: cached, to: target)
                    written += 1
                } catch {
                    errors.append("\(track.url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                self.isConverting = false
                self.convertProgress = nil
                var summary = "converted \(written) to mp3"
                if skipped > 0 { summary += ", \(skipped) already existed" }
                if !errors.isEmpty { summary += ", \(errors.count) failed" }
                self.statusMessage = summary
                if written > 0 { self.scanLibrary() }
            }
        }
    }

    /// Asks where to put the converted files, then converts.
    func convertToMP3ChoosingFolder(_ list: [Track], quality: Int) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "convert here"
        panel.message = "choose where to write the converted mp3s"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        convertToMP3(list, quality: quality, destination: folder)
    }

    // MARK: - Metadata enrichment

    /// Repairs tags for tracks missing them, one online lookup at a time. MusicBrainz
    /// is rate-limited to one request per second, so this is deliberately slow and
    /// runs in the background while the app stays usable.
    func enrichMissingMetadata() {
        guard !isEnriching else { return }
        guard config.onlineLookupEnabled else {
            statusMessage = "online lookup is disabled in settings"
            return
        }
        let candidates = tracks.filter { $0.needsMetadata && !$0.enriched }
        guard !candidates.isEmpty else {
            statusMessage = "no tracks need metadata"
            return
        }

        isEnriching = true
        enrichProgress = (0, candidates.count)

        Task {
            var repaired = 0
            for (i, track) in candidates.enumerated() {
                if await MainActor.run(body: { !self.isEnriching }) { break }
                if let match = await OnlineMetadata.shared.identify(track: track) {
                    var updated = track
                    if let v = match.title, !v.isEmpty { updated.title = v }
                    if let v = match.artist, !v.isEmpty { updated.artist = v }
                    if let v = match.album, !v.isEmpty { updated.album = v }
                    if let v = match.albumArtist, !v.isEmpty { updated.albumArtist = v }
                    if let v = match.year { updated.year = v }
                    if let v = match.trackNumber, updated.trackNumber == nil { updated.trackNumber = v }
                    updated.mbid = match.recordingMBID
                    updated.enriched = true

                    await scanner.updateCache(updated)
                    await MainActor.run { self.replaceTrack(updated) }
                    repaired += 1
                }
                await MainActor.run { self.enrichProgress = (i + 1, candidates.count) }
            }
            await scanner.saveCache()
            await MainActor.run {
                self.isEnriching = false
                self.enrichProgress = nil
                self.statusMessage = "repaired \(repaired) of \(candidates.count) tracks"
            }
        }
    }

    func stopEnriching() { isEnriching = false }

    private func replaceTrack(_ updated: Track) {
        guard let i = tracks.firstIndex(where: { $0.url == updated.url }) else { return }
        tracks[i] = updated
        albums = LibraryGrouping.albums(from: tracks)
    }

    /// Forces artwork re-resolution for one album, including a fresh online lookup.
    func refetchArtwork(for album: Album) {
        Task {
            await ArtworkStore.shared.invalidate(album.key)
            _ = await ArtworkStore.shared.artwork(for: album)
            await MainActor.run {
                self.statusMessage = "refreshed art for \(album.title)"
                // Nudge SwiftUI to re-read the store.
                self.albums = self.albums
            }
        }
    }

    // MARK: - Navigation

    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !future.isEmpty }

    func navigate(to newRoute: Route) {
        guard newRoute != route else { return }
        history.append(route)
        // A new destination invalidates anything that was ahead, the way a browser does.
        future.removeAll()
        route = newRoute
        selectionIndex = 0
    }

    func goForward() {
        guard let next = future.popLast() else { return }
        history.append(route)
        route = next
        selectionIndex = 0
    }

    // MARK: Streaming mode

    /// True while the browser is pinned to a single streaming service.
    var isStreamingMode: Bool { sourceFilter?.isStreaming == true }

    /// Shows only that service's library. Local files are hidden entirely, which is the
    /// point: streaming and owned music are different mental modes.
    func enterStreamingMode(_ source: TrackSource) {
        sourceFilter = source
        searchQuery = ""
        navigate(to: .albums)

        // Pull the library on first entry so the page is not empty.
        switch source {
        case .appleMusic where appleMusicTracks.isEmpty: importAppleMusic()
        case .spotify where spotifyTracks.isEmpty && spotify.isAuthorized: importSpotify()
        default: break
        }
    }

    func exitStreamingMode() {
        sourceFilter = .local
        searchQuery = ""
        navigate(to: .albums)
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        future.append(route)
        route = previous
        selectionIndex = 0
    }
}

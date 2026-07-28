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
}

enum Pane: Hashable { case sidebar, content }

@MainActor
final class AppState: ObservableObject {
    // MARK: Library

    @Published var tracks: [Track] = []
    @Published var albums: [Album] = []
    @Published var playlists: [Playlist] = []

    @Published var isScanning = false
    @Published var scanProgress: ScanProgress?

    // MARK: Navigation

    @Published var route: Route = .albums
    @Published var history: [Route] = []
    @Published var focusedPane: Pane = .content
    @Published var selectionIndex = 0

    // MARK: Search / command

    @Published var searchQuery = ""
    @Published var isSearching = false
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

        // System media keys and the Control Centre tile.
        mediaRemote = MediaRemote(player: player)
        mediaRemote.artworkProvider = { [weak self] track in
            guard let self else { return nil }
            guard let album = await MainActor.run(body: { self.album(for: track.albumKey) })
            else { return nil }
            return await ArtworkStore.shared.artwork(for: album)
        }

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
                self.tracks = found.sorted {
                    $0.artist.localizedStandardCompare($1.artist) == .orderedAscending
                }
                self.albums = LibraryGrouping.albums(from: found)
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
        player.setQueue(album.tracks, startAt: index)
        persistPlaybackPrefs()
    }

    func play(tracks list: [Track], startingAt index: Int = 0) {
        player.setQueue(list, startAt: index)
        persistPlaybackPrefs()
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
        let v = max(0, min(1, player.volume + delta))
        player.volume = v
        config.volume = v
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
                    guard let image = await ArtworkStore.shared.artwork(for: album) else { return nil }
                    return image.jpegData(maxDimension: currentConfig.deviceArtworkSize)
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

    func navigate(to newRoute: Route) {
        history.append(route)
        route = newRoute
        selectionIndex = 0
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        route = previous
        selectionIndex = 0
    }
}

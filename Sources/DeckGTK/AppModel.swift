import DeckCore
import Foundation

/// Application state for the GTK front end.
///
/// GTK is not reactive, so this holds the data and the window explicitly re-renders the
/// affected section when something changes. Every mutation happens on the GTK main
/// thread; background work hops back through `onMainThread`.
final class AppModel {
    enum Route: Equatable {
        case albums
        case artists
        case songs
        case album(AlbumKey)
        case queue
        case sync
        case settings
    }

    var config: Config
    var theme: Theme

    var tracks: [Track] = []
    var albums: [Album] = []
    var playlists: [Playlist] = []

    var route: Route = .albums
    var selection = 0
    var statusMessage = ""

    var devices: [RockboxDevice] = []
    var selectedDevice: RockboxDevice?
    var syncPlan: SyncPlan?

    var isScanning = false
    var scanProgress: ScanProgress?
    var isSyncing = false
    var syncProgress: SyncProgress?

    // Playback
    var queue: [Track] = []
    var currentIndex = 0
    var isPlaying = false
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var shuffle = false
    var repeatMode: Config.RepeatMode = .off
    var playOrder: [Int] = []
    var orderPosition = 0

    let player = MPVPlayer()
    private let scanner = LibraryScanner()
    private let syncEngine = SyncEngine()

    /// Called whenever something changed that the window should redraw.
    var onChange: () -> Void = {}

    init() {
        Config.migrateLegacyDataIfNeeded()
        config = Config.load()
        theme = Theme.named(config.themeID)
        playlists = Self.loadPlaylists()
        shuffle = config.shuffle
        repeatMode = config.repeatMode
    }

    var currentTrack: Track? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    func album(for key: AlbumKey) -> Album? { albums.first { $0.key == key } }

    var artistNames: [String] { LibraryGrouping.artists(from: albums) }

    func tracks(in playlist: Playlist) -> [Track] {
        let byPath = Dictionary(tracks.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        return playlist.trackPaths.compactMap { byPath[$0] }
    }

    var syncSelection: [Track] {
        var seen = Set<String>()
        var result: [Track] = []
        for playlist in playlists where playlist.syncEnabled {
            for track in tracks(in: playlist) where seen.insert(track.url.path).inserted {
                result.append(track)
            }
        }
        return result
    }

    // MARK: - Library

    func scanLibrary() {
        guard !isScanning, !config.rootURLs.isEmpty else {
            if config.rootURLs.isEmpty { statusMessage = "no library folder set — open settings" }
            onChange()
            return
        }
        isScanning = true
        statusMessage = "indexing…"
        onChange()

        Task.detached { [weak self] in
            guard let self else { return }
            await self.scanner.loadCache()
            let found = await self.scanner.scan(roots: self.config.rootURLs) { progress in
                onMainThread {
                    self.scanProgress = progress
                    // Redrawing per file would swamp the main loop on a large library.
                    if progress.scanned % 200 == 0 { self.onChange() }
                }
            }
            onMainThread {
                self.tracks = found
                self.albums = LibraryGrouping.albums(from: found)
                self.isScanning = false
                self.scanProgress = nil
                self.statusMessage = "indexed \(found.count) tracks in \(self.albums.count) albums"
                self.onChange()
            }
        }
    }

    func addLibraryRoot(_ path: String) {
        guard !config.libraryRoots.contains(path) else { return }
        config.libraryRoots.append(path)
        config.save()
        scanLibrary()
    }

    // MARK: - Playback

    func play(tracks list: [Track], startingAt index: Int = 0) {
        queue = list
        rebuildOrder()
        guard list.indices.contains(index) else { return }
        currentIndex = index
        orderPosition = playOrder.firstIndex(of: index) ?? 0
        startCurrent()
    }

    private func rebuildOrder() {
        let indices = Array(queue.indices)
        if shuffle {
            var rest = indices.filter { $0 != currentIndex }
            rest.shuffle()
            playOrder = queue.indices.contains(currentIndex) ? [currentIndex] + rest : rest
        } else {
            playOrder = indices
        }
        orderPosition = playOrder.firstIndex(of: currentIndex) ?? 0
    }

    private func startCurrent() {
        guard let track = currentTrack else { return }
        let path = track.url.path
        duration = track.duration
        position = 0
        isPlaying = true
        onChange()

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await self.player.load(path: path)
                // Queue the next file so mpv can hand over gaplessly.
                await self.queueNextForGapless()
            } catch {
                onMainThread {
                    self.statusMessage = "playback failed: \(error.localizedDescription)"
                    self.isPlaying = false
                    self.onChange()
                }
            }
        }
    }

    private func queueNextForGapless() async {
        let next: String? = await MainActorish.run { [weak self] in
            guard let self, self.orderPosition + 1 < self.playOrder.count else { return nil }
            let index = self.playOrder[self.orderPosition + 1]
            return self.queue.indices.contains(index) ? self.queue[index].url.path : nil
        }
        guard let next else { return }
        try? await player.appendNext(path: next)
    }

    func togglePlayPause() {
        isPlaying.toggle()
        let wantsPlay = isPlaying
        Task.detached { [weak self] in
            guard let self else { return }
            if wantsPlay { try? await self.player.play() } else { await self.player.pause() }
        }
        onChange()
    }

    func next() {
        guard !playOrder.isEmpty else { return }
        if orderPosition + 1 < playOrder.count {
            orderPosition += 1
        } else if repeatMode == .all {
            orderPosition = 0
        } else {
            return
        }
        currentIndex = playOrder[orderPosition]
        startCurrent()
    }

    func previous() {
        guard !playOrder.isEmpty else { return }
        // Restart the track unless pressed early, matching every other player.
        if position > 3 { seek(to: 0); return }
        if orderPosition > 0 { orderPosition -= 1 }
        currentIndex = playOrder[orderPosition]
        startCurrent()
    }

    func seek(to seconds: TimeInterval) {
        position = seconds
        Task.detached { [weak self] in await self?.player.seek(to: seconds) }
        onChange()
    }

    func seekRelative(_ delta: TimeInterval) {
        seek(to: max(0, min(duration, position + delta)))
    }

    func setVolume(_ value: Float) {
        config.volume = max(0, min(1, value))
        config.save()
        let volume = config.volume
        Task.detached { [weak self] in await self?.player.setVolume(volume) }
    }

    func toggleShuffle() {
        shuffle.toggle()
        config.shuffle = shuffle
        config.save()
        rebuildOrder()
        statusMessage = shuffle ? "shuffle on" : "shuffle off"
        onChange()
    }

    func cycleRepeat() {
        let modes = Config.RepeatMode.allCases
        repeatMode = modes[((modes.firstIndex(of: repeatMode) ?? 0) + 1) % modes.count]
        config.repeatMode = repeatMode
        config.save()
        statusMessage = repeatMode.symbol
        onChange()
    }

    func cycleTheme() {
        let all = Theme.all
        let index = all.firstIndex { $0.id == config.themeID } ?? 0
        let next = all[(index + 1) % all.count]
        config.themeID = next.id
        config.save()
        theme = next
        Styling.apply(next)
        statusMessage = "theme: \(next.name)"
        onChange()
    }

    /// Polls mpv and advances the queue when a track ends. Driven by the window's timer.
    func tick() {
        Task.detached { [weak self] in
            guard let self else { return }
            let state = await self.player.refreshState()
            onMainThread {
                // Ignore mpv's position while it is between files, otherwise the
                // scrubber jumps to zero for a frame during a gapless hand-off.
                if state.duration > 0 {
                    self.position = state.position
                    self.duration = state.duration
                }
                self.isPlaying = state.isPlaying

                // mpv going idle means the playlist drained: advance ourselves.
                if state.idle, !self.queue.isEmpty, self.isPlaying == false, self.position > 0 {
                    self.next()
                }
                self.onChange()
            }
        }
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

    func toggleSync(_ id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].syncEnabled.toggle()
        savePlaylists()
        syncPlan = nil
        onChange()
    }

    // MARK: - Devices

    func refreshDevices() {
        devices = DeviceScanner.scan()
        if let current = selectedDevice, !devices.contains(where: { $0.id == current.id }) {
            selectedDevice = nil
            syncPlan = nil
        }
        if selectedDevice == nil {
            selectedDevice = devices.first { $0.hasRockbox } ?? devices.first
        }
        onChange()
    }

    func buildPlan() {
        guard let device = selectedDevice else {
            statusMessage = "no device selected"; onChange(); return
        }
        let selection = syncSelection
        guard !selection.isEmpty else {
            statusMessage = "nothing marked for sync — enable a playlist"; onChange(); return
        }
        statusMessage = "planning…"
        onChange()

        let currentPlaylists = playlists
        let currentConfig = config
        Task.detached { [weak self] in
            guard let self else { return }
            let plan = await self.syncEngine.plan(
                tracks: selection, playlists: currentPlaylists,
                device: device, config: currentConfig)
            onMainThread {
                self.syncPlan = plan
                self.statusMessage = plan.fits
                    ? "\(plan.transfers.count) to transfer, \(plan.upToDateCount) current"
                    : "over capacity by \((-plan.headroomAfterSync).byteString)"
                self.onChange()
            }
        }
    }

    func runSync() {
        guard let plan = syncPlan, plan.fits, !isSyncing else { return }
        isSyncing = true
        onChange()

        let currentConfig = config
        Task.detached { [weak self] in
            guard let self else { return }
            await self.syncEngine.resetCancellation()
            let report = await self.syncEngine.execute(
                plan: plan, config: currentConfig, removeOrphans: false,
                artworkFor: { key in
                    guard let album = await MainActorish.run({ self.album(for: key) })
                    else { return nil }
                    return await ArtworkStore.shared.deviceArtwork(
                        for: album, maxDimension: currentConfig.deviceArtworkSize)
                },
                progress: { progress in
                    onMainThread { self.syncProgress = progress; self.onChange() }
                })
            onMainThread {
                self.isSyncing = false
                self.syncProgress = nil
                self.syncPlan = nil
                self.statusMessage =
                    "synced \(report.copied + report.converted) files"
                    + (report.errors.isEmpty ? "" : ", \(report.errors.count) errors")
                self.refreshDevices()
                self.onChange()
            }
        }
    }
}

/// Reads state owned by the GTK main thread from inside a detached task.
///
/// The GTK build has no MainActor to hop onto, so this bounces through the GLib main
/// loop and waits for the answer. Only used for short property reads.
enum MainActorish {
    static func run<T: Sendable>(_ body: @escaping () -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            onMainThread {
                continuation.resume(returning: body())
            }
        }
    }
}

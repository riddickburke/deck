import Combine
import Foundation
import MediaPlayer
import SwiftUI

/// Which library page the pager is showing.
///
/// Ordered as they appear left to right, so the page index and the tab index are the
/// same number and swiping cannot drift out of step with the tab bar.
enum LibraryPage: Int, CaseIterable, Identifiable {
    case albums, artists, songs, playlists

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .albums: return "albums"
        case .artists: return "artists"
        case .songs: return "songs"
        case .playlists: return "playlists"
        }
    }
}

/// Everything the views read.
///
/// The desktop app splits this across several objects; on a phone there is one window
/// and one navigation stack, so a single state object is simpler and avoids the
/// cross-object publishing that made the desktop version's updates hard to follow.
@MainActor
final class MobileState: ObservableObject {

    // MARK: - Library

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var albums: [Album] = []
    @Published private(set) var artists: [String] = []
    @Published private(set) var playlists: [ServicePlaylist] = []

    /// Title-sorted, computed once per load.
    ///
    /// The songs page had this as a computed property, which re-sorted three thousand
    /// tracks on every single body evaluation — including every frame of a scroll.
    @Published private(set) var sortedTracks: [Track] = []

    @Published private(set) var isLoading = false
    @Published private(set) var authorization: MPMediaLibraryAuthorizationStatus =
        MusicLibrary.authorizationStatus

    /// Set when the library loaded successfully but held nothing — a real state that
    /// looks identical to a failure unless it is distinguished.
    var isEmptyLibrary: Bool { !isLoading && tracks.isEmpty && authorization == .authorized }

    // MARK: - Navigation

    /// Whether the full-screen now-playing screen is up.
    ///
    /// A plain flag driving a `fullScreenCover`, rather than the drag-progress value
    /// this used to be. Hand-offsetting an overlay gave an interactive open gesture, but
    /// it put a full-size, always-present view on top of the whole app and depended on
    /// hit-testing being disabled correctly to stay out of the way. A cover is what
    /// "full screen" actually means on iOS, and it cannot swallow touches when closed.
    @Published var isNowPlayingOpen = false

    // MARK: - Pins

    /// What sits at the top of the home screen. Capped at six, which is what fits
    /// above the library rows without the home screen becoming a scrolling grid of
    /// its own.
    @Published private(set) var pins: [PinTarget] = Defaults.pins

    static let maxPins = 6

    func isPinned(_ target: PinTarget) -> Bool { pins.contains(target) }

    /// Pinning a seventh drops the oldest rather than refusing, so the gesture always
    /// does something visible.
    func togglePin(_ target: PinTarget) {
        if let index = pins.firstIndex(of: target) {
            pins.remove(at: index)
        } else {
            pins.append(target)
            if pins.count > Self.maxPins { pins.removeFirst(pins.count - Self.maxPins) }
        }
        Defaults.pins = pins
        Defaults.hasSeededPins = true
    }

    /// Gives a first run something to look at.
    ///
    /// An empty home screen with only a hint reads as a broken screen. Playlists first
    /// because someone who made them is likelier to want them; albums fill any gap.
    /// Only ever runs once — after that the pins are the user's business.
    private func seedPinsIfNeeded() {
        guard !Defaults.hasSeededPins, pins.isEmpty else { return }
        var seeded: [PinTarget] = playlists.prefix(Self.maxPins).map { .playlist($0.id) }
        if seeded.count < Self.maxPins {
            seeded += albums.prefix(Self.maxPins - seeded.count).map { .album($0.key) }
        }
        guard !seeded.isEmpty else { return }
        pins = seeded
        Defaults.pins = seeded
        Defaults.hasSeededPins = true
    }

    // MARK: - Appearance

    @Published var theme: Theme = .named(Defaults.themeID) {
        didSet { Defaults.themeID = theme.id }
    }
    @Published var showsVisualizer: Bool = Defaults.visualizerEnabled {
        didSet {
            Defaults.visualizerEnabled = showsVisualizer
            visualizer.isEnabled = showsVisualizer
        }
    }

    // MARK: - Playback

    /// Playback and the visualiser are handed to the view tree as their own environment
    /// objects rather than republished through here.
    ///
    /// Forwarding their `objectWillChange` into this one would be less code, but it
    /// would also mean every 30 Hz visualiser frame invalidates the album grid, the
    /// songs list and everything else holding a `MobileState`. Keeping them separate
    /// means a view re-renders only for the state it actually reads.
    let playback = Playback()
    let visualizer: Visualizer

    init() {
        let visualizer = Visualizer(clock: playback.clock)
        visualizer.isEnabled = Defaults.visualizerEnabled
        self.visualizer = visualizer

        playback.onStateChange = { [weak visualizer] trackID, isPlaying in
            visualizer?.update(trackID: trackID, isPlaying: isPlaying)
        }
    }

    // MARK: - Loading

    func loadIfNeeded() async {
        guard tracks.isEmpty, !isLoading else { return }
        await reload()
    }

    func reload() async {
        if authorization != .authorized {
            authorization = await MusicLibrary.requestAuthorization()
            Log.library.notice("authorization status: \(self.authorization.rawValue)")
            guard authorization == .authorized else {
                Log.library.error("not authorized, nothing will load")
                return
            }
        }

        isLoading = true
        defer { isLoading = false }

        let snapshot = await MusicLibrary.load()
        tracks = snapshot.tracks
        playlists = snapshot.playlists
        rebuildDerived()
        seedPinsIfNeeded()
        Log.library.notice(
            "loaded \(self.tracks.count) tracks, \(self.albums.count) albums, \(self.playlists.count) playlists")
    }

    /// Albums and artists are derived rather than stored, so they cannot drift out of
    /// sync with the track list.
    private func rebuildDerived() {
        var grouped: [AlbumKey: [Track]] = [:]
        for track in tracks {
            grouped[track.albumKey, default: []].append(track)
        }
        albums = grouped
            .map { Album(key: $0.key, tracks: $0.value) }
            .sorted {
                let byArtist = $0.artist.localizedStandardCompare($1.artist)
                if byArtist != .orderedSame { return byArtist == .orderedAscending }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }

        artists = Set(tracks.map { $0.albumArtist.isEmpty ? $0.artist : $0.albumArtist })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        sortedTracks = tracks.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    // MARK: - Queries

    func albums(byArtist artist: String) -> [Album] {
        albums.filter { $0.artist.localizedCaseInsensitiveCompare(artist) == .orderedSame }
    }

    func tracks(in playlist: ServicePlaylist) -> [Track] {
        playlist.resolve(against: tracks)
    }

    /// One pass over the library for all three result kinds.
    ///
    /// Separate filters would walk the track list three times; on a large library that
    /// is enough to show up as lag between keystroke and results.
    func search(_ query: String) -> SearchResults {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= 1 else { return SearchResults() }

        var results = SearchResults()
        var albumKeys = Set<AlbumKey>()
        var artistNames = Set<String>()

        for track in tracks {
            if track.title.lowercased().contains(needle) {
                results.tracks.append(track)
            }
            if track.album.lowercased().contains(needle), albumKeys.insert(track.albumKey).inserted {
                results.albumKeys.append(track.albumKey)
            }
            let artist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
            if artist.lowercased().contains(needle), artistNames.insert(artist).inserted {
                results.artists.append(artist)
            }
        }

        results.albums = results.albumKeys.compactMap { key in
            albums.first { $0.key == key }
        }
        return results
    }

}

/// Drives the generated spectrum.
///
/// Apple Music decodes in the media services process, so no samples reach this app and
/// there is nothing to run an FFT over. The bars are therefore synthesised — the same
/// situation, and the same solution, as streaming services in the desktop build.
///
/// Position-driven rather than wall-clock driven, so seeking moves the animation and a
/// paused track's bars settle instead of continuing to dance.
@MainActor
final class Visualizer: ObservableObject {
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: Spectrum.bandCount)

    var isEnabled = true {
        didSet { if !isEnabled { reset() } }
    }

    private let clock: PlaybackClock
    private var spectrum = SyntheticSpectrum(seed: 0)
    private var timer: Timer?
    /// Eased rather than switched, so pausing fades the bars down instead of freezing
    /// them mid-animation.
    private var intensity: Float = 0
    private var seededTrackID: String?
    private var isPlaying = false

    init(clock: PlaybackClock) {
        self.clock = clock
        start()
    }

    deinit { timer?.invalidate() }

    /// Told rather than observed: subscribing to `Playback` here would recreate exactly
    /// the coupling this split exists to avoid.
    func update(trackID: String?, isPlaying: Bool) {
        self.isPlaying = isPlaying
        if let trackID, trackID != seededTrackID {
            seededTrackID = trackID
            // Seeded per track, so two songs do not animate identically, and the same
            // song animates the same way across launches.
            spectrum = SyntheticSpectrum.forTrack(trackID)
        }
    }

    /// 30 Hz. The motion is smooth at that rate and the bars are only a few dozen
    /// points tall; 60 would double the wakeups for no visible gain.
    private func start() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func step() {
        guard isEnabled else { return }

        let target: Float = isPlaying ? 1 : 0
        intensity += (target - intensity) * 0.12

        guard intensity > 0.005 else {
            reset()
            return
        }
        levels = spectrum.levels(at: clock.position, intensity: intensity)
    }

    private func reset() {
        intensity = 0
        if levels.contains(where: { $0 > 0 }) {
            levels = Array(repeating: 0, count: Spectrum.bandCount)
        }
    }
}

/// Something the user has pinned to the home screen.
///
/// Stored as a reference rather than a copy: an `Album` holds its tracks, so persisting
/// one would freeze a snapshot of the library that goes stale the moment anything is
/// added in the Music app.
enum PinTarget: Codable, Hashable, Identifiable {
    case album(AlbumKey)
    case playlist(String)

    var id: String {
        switch self {
        case .album(let key): return "album:\(key.artist)|\(key.album)"
        case .playlist(let id): return "playlist:\(id)"
        }
    }
}

/// Results of a single search pass, kept as one value so the view updates atomically.
struct SearchResults {
    var tracks: [Track] = []
    var albums: [Album] = []
    var artists: [String] = []
    fileprivate var albumKeys: [AlbumKey] = []

    var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && artists.isEmpty }
    var total: Int { tracks.count + albums.count + artists.count }
}

/// Thin wrapper over UserDefaults.
///
/// The desktop app persists a JSON index under Application Support because it owns a
/// scanned library. Here the library belongs to iOS, so the only thing worth persisting
/// is preference, and UserDefaults is the right size for that.
enum Defaults {
    private static let store = UserDefaults.standard

    static var themeID: String {
        get { store.string(forKey: "theme") ?? Theme.dark.id }
        set { store.set(newValue, forKey: "theme") }
    }

    static var visualizerEnabled: Bool {
        get { store.object(forKey: "visualizer") as? Bool ?? true }
        set { store.set(newValue, forKey: "visualizer") }
    }

    static var pins: [PinTarget] {
        get {
            guard let data = store.data(forKey: "pins") else { return [] }
            return (try? JSONDecoder().decode([PinTarget].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            store.set(data, forKey: "pins")
        }
    }

    /// Distinguishes "never pinned anything" from "deliberately unpinned everything",
    /// so clearing the home screen is not undone on the next launch.
    static var hasSeededPins: Bool {
        get { store.bool(forKey: "hasSeededPins") }
        set { store.set(newValue, forKey: "hasSeededPins") }
    }
}

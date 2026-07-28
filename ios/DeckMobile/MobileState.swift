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

    @Published private(set) var isLoading = false
    @Published private(set) var authorization: MPMediaLibraryAuthorizationStatus =
        MusicLibrary.authorizationStatus

    /// Set when the library loaded successfully but held nothing — a real state that
    /// looks identical to a failure unless it is distinguished.
    var isEmptyLibrary: Bool { !isLoading && tracks.isEmpty && authorization == .authorized }

    // MARK: - Navigation

    @Published var page: LibraryPage = .albums
    @Published var searchText = ""
    /// Raised while a text field holds focus. Nothing on iOS depends on it the way the
    /// desktop key bindings did, but the now-playing drag gesture uses it to stay out of
    /// the way of the keyboard.
    @Published var isEditingText = false

    /// 0 = mini player docked, 1 = now playing fully open. Intermediate values are live
    /// drag positions, which is what lets the sheet track a finger instead of snapping.
    @Published var nowPlayingProgress: CGFloat = 0
    var isNowPlayingOpen: Bool { nowPlayingProgress > 0.5 }

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
            guard authorization == .authorized else { return }
        }

        isLoading = true
        defer { isLoading = false }

        let snapshot = await MusicLibrary.load()
        tracks = snapshot.tracks
        playlists = snapshot.playlists
        rebuildDerived()
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
}

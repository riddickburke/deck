import Foundation
import MediaPlayer
import UIKit

/// Reads the on-device Apple Music library.
///
/// Uses MediaPlayer (`MPMediaQuery`) rather than MusicKit. MusicKit is the newer API, but
/// it is gated behind the MusicKit app service, which can only be enabled on an App ID
/// belonging to a paid Apple Developer Program account. MediaPlayer needs nothing but
/// `NSAppleMusicUsageDescription` in the Info.plist and the user's consent, so the app
/// installs and works with a free personal team.
///
/// This mirrors the decision the macOS app already makes, where Music.app is driven over
/// AppleScript for the same reason.
///
/// What that costs: no catalog search. Everything here is the user's *library* — which
/// includes Apple Music subscription tracks, but only ones they have added. Playing
/// something they have never added is not reachable without MusicKit.
enum MusicLibrary {

    // MARK: - Authorisation

    static var authorizationStatus: MPMediaLibraryAuthorizationStatus {
        MPMediaLibrary.authorizationStatus()
    }

    static func requestAuthorization() async -> MPMediaLibraryAuthorizationStatus {
        await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Import

    struct Snapshot: Sendable {
        var tracks: [Track] = []
        var playlists: [ServicePlaylist] = []
    }

    /// Reads the whole library and the user's playlists.
    ///
    /// Runs off the main actor: on a large library this is hundreds of milliseconds of
    /// synchronous work inside MediaPlayer, and doing it on the main thread drops the
    /// first frames of the launch animation.
    static func load() async -> Snapshot {
        await Task.detached(priority: .userInitiated) {
            var snapshot = Snapshot()
            snapshot.tracks = loadTracks()
            snapshot.playlists = loadPlaylists()
            return snapshot
        }.value
    }

    /// Every song in the library, including Apple Music cloud items.
    ///
    /// Also refreshes the id → item index, since this is the one place that already
    /// holds every item and building it here avoids a second full query.
    private static func loadTracks() -> [Track] {
        let query = MPMediaQuery.songs()
        // Restricting to music keeps podcasts, audiobooks and voice memos out; they are
        // in the songs query but do not belong in an album grid.
        query.addFilterPredicate(MPMediaPropertyPredicate(
            value: MPMediaType.music.rawValue,
            forProperty: MPMediaItemPropertyMediaType))

        guard let items = query.items else {
            Log.library.error("MPMediaQuery.songs() returned nil items")
            return []
        }
        index.replace(with: items)
        let tracks = items.compactMap(track(from:))
        Log.library.notice(
            "query returned \(items.count) items, \(tracks.count) usable tracks")
        return tracks
    }

    /// Converts one MediaPlayer item into the shared model.
    ///
    /// Returns nil for anything that cannot be played back — an item whose asset is
    /// protected and not downloaded still appears in the query but fails silently at
    /// play time, which reads as the app being broken.
    static func track(from item: MPMediaItem) -> Track? {
        let persistentID = item.persistentID
        guard persistentID != 0 else { return nil }

        let artist = item.artist ?? Track.unknown

        var track = Track(
            source: .appleMusic,
            externalID: String(persistentID),
            title: item.title ?? Track.unknown,
            artist: artist,
            albumArtist: item.albumArtist ?? artist,
            album: item.albumTitle ?? Track.unknown,
            genre: item.genre,
            year: year(of: item),
            trackNumber: item.albumTrackNumber > 0 ? item.albumTrackNumber : nil,
            discNumber: item.discNumber > 0 ? item.discNumber : nil,
            duration: item.playbackDuration,
            // The codec field carries the provenance label, matching what the macOS app
            // stores from Music.app's cloud status. There is no real codec to report:
            // MediaPlayer does not expose one, and for a subscription track the answer
            // depends on what the device streams at the time.
            codec: item.isCloudItem ? "subscription" : "local")
        track.source = .appleMusic
        return track
    }

    /// MediaPlayer has no year property. `releaseDate` is undocumented but present, and
    /// the album's own year is the useful one, so this falls back to it.
    private static func year(of item: MPMediaItem) -> Int? {
        if let date = item.value(forProperty: "year") as? Int, date > 0 { return date }
        if let released = item.releaseDate {
            return Calendar.current.component(.year, from: released)
        }
        return nil
    }

    // MARK: - Playlists

    /// The user's playlists, each holding its track ids in playlist order.
    ///
    /// Folders are skipped: iOS models a playlist folder as a playlist with no items,
    /// and showing those gives a sidebar full of rows that open onto nothing.
    private static func loadPlaylists() -> [ServicePlaylist] {
        let query = MPMediaQuery.playlists()
        guard let collections = query.collections else { return [] }

        var out: [ServicePlaylist] = []
        for collection in collections {
            guard let playlist = collection as? MPMediaPlaylist else { continue }

            let attributes = playlist.playlistAttributes
            // `.onTheGo` is the transient "Recently Added"-style container iOS builds
            // itself; it is not something the user made.
            guard !attributes.contains(.onTheGo) else { continue }

            let name = (playlist.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            let ids = playlist.items.compactMap { item -> String? in
                item.persistentID == 0 ? nil : String(item.persistentID)
            }
            guard !ids.isEmpty else { continue }

            out.append(ServicePlaylist(
                id: String(playlist.persistentID),
                name: name,
                source: .appleMusic,
                trackIDs: ids))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Lookup

    /// Maps track ids back to the MediaPlayer items behind them.
    ///
    /// Playback and artwork both need real `MPMediaItem`s, while everything above this
    /// layer deals only in `Track`. Rather than run a predicate query per lookup — which
    /// on a scrolling list of rows is one media-library round trip per visible cell —
    /// the items from the import are kept and indexed by id.
    ///
    /// `MPMediaItem` is a lightweight proxy onto the library database, not a decoded
    /// asset, so holding the full set costs little.
    private final class ItemIndex: @unchecked Sendable {
        private var storage: [UInt64: MPMediaItem] = [:]
        private let lock = NSLock()

        func replace(with items: [MPMediaItem]) {
            var built: [UInt64: MPMediaItem] = [:]
            built.reserveCapacity(items.count)
            for item in items where item.persistentID != 0 {
                built[item.persistentID] = item
            }
            lock.lock()
            storage = built
            lock.unlock()
        }

        func item(_ id: UInt64) -> MPMediaItem? {
            lock.lock()
            defer { lock.unlock() }
            return storage[id]
        }
    }

    private static let index = ItemIndex()

    /// Resolves shared-model ids back to MediaPlayer items, preserving the order given.
    ///
    /// Ids that no longer resolve are dropped rather than substituted: a playlist can
    /// reference a track that has since been removed from the library, and silently
    /// playing a different one is worse than playing one fewer.
    static func items(forIDs ids: [String]) -> [MPMediaItem] {
        ids.compactMap { UInt64($0).flatMap(index.item) }
    }

    static func item(forID id: String) -> MPMediaItem? {
        UInt64(id).flatMap(index.item)
    }

    /// Artwork for a track, at roughly the size it will be drawn.
    ///
    /// `MPMediaItemArtwork` renders on demand at the requested size, so this avoids
    /// decoding a full-resolution cover to fill a 44pt row.
    static func artwork(forID id: String, size: CGSize) -> UIImage? {
        guard let item = item(forID: id) else {
            Log.artwork.error("no item in index for requested id")
            return nil
        }
        guard let artwork = item.artwork else {
            Log.artwork.notice("item has no artwork")
            return nil
        }
        let image = artwork.image(at: size)
        if image == nil {
            Log.artwork.error(
                "image(at: \(Int(size.width))) returned nil, artwork bounds \(Int(artwork.bounds.width))")
        }
        return image
    }
}

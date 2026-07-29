import Foundation

/// Works out which tracks a sync should push to the device.
///
/// Pulled out of the app layer so it can be tested. Getting this wrong is expensive in a
/// way most UI bugs are not: too few tracks and an album silently never arrives, too many
/// and the device fills up or files the user never asked for get written to it.
public enum SyncSelection {

    /// Resolves a scope into the concrete list of tracks to copy.
    ///
    /// Order is deliberate: playlists first, then marked albums, deduplicated by source
    /// path. A track in both is copied once, and the destination layout does not depend
    /// on which selection reached it first.
    ///
    /// Streaming tracks are always excluded. They have no file behind them, so including
    /// one would add work to the plan that cannot succeed — and would make the size
    /// estimate lie.
    public static func resolve(
        scope: Config.SyncScope,
        localTracks: [Track],
        playlists: [Playlist],
        markedAlbums: [AlbumKey]
    ) -> [Track] {
        let copyable = localTracks.filter { !$0.isStreaming }

        switch scope {
        case .entireLibrary:
            return copyable

        case .selection:
            let byPath = Dictionary(
                copyable.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })

            var byAlbum: [AlbumKey: [Track]] = [:]
            for track in copyable {
                byAlbum[track.albumKey, default: []].append(track)
            }

            var seen = Set<String>()
            var result: [Track] = []

            for playlist in playlists where playlist.syncEnabled {
                for path in playlist.trackPaths {
                    guard let track = byPath[path], seen.insert(path).inserted else { continue }
                    result.append(track)
                }
            }

            for key in markedAlbums {
                // An album marked before a rescan may no longer exist. Skipping is
                // correct — the caller surfaces it as "not in library" rather than
                // failing the whole sync over one stale mark.
                guard let tracks = byAlbum[key] else { continue }
                for track in tracks where seen.insert(track.url.path).inserted {
                    result.append(track)
                }
            }

            return result
        }
    }
}

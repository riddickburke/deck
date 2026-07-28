import Foundation

/// A playlist belonging to a streaming service.
///
/// Kept separate from `Playlist`, which stores file paths and exists to drive Rockbox
/// syncing. A service playlist references the service's own track identifiers, has no
/// files behind it, and is read-only from Deck's point of view — Deck never modifies
/// anything in the user's Apple Music or Spotify account.
public struct ServicePlaylist: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let source: TrackSource
    /// The service's own track identifiers, in playlist order.
    public let trackIDs: [String]

    public var trackCount: Int { trackIDs.count }

    public init(id: String, name: String, source: TrackSource, trackIDs: [String]) {
        self.id = id
        self.name = name
        self.source = source
        self.trackIDs = trackIDs
    }

    /// Resolves the playlist against an imported library, preserving playlist order.
    ///
    /// Tracks that are not in the library are dropped rather than faked: a playlist can
    /// reference something unavailable in the user's region or removed from the service.
    public func resolve(against tracks: [Track]) -> [Track] {
        let byID = Dictionary(
            tracks.compactMap { track -> (String, Track)? in
                guard let id = track.externalID else { return nil }
                return (id, track)
            },
            uniquingKeysWith: { first, _ in first })
        return trackIDs.compactMap { byID[$0] }
    }
}

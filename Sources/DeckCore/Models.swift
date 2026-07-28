import Foundation

// MARK: - Source

/// Where a track's audio actually lives.
///
/// Streaming tracks have no file on disk. They are browsable and playable, but the
/// playing is delegated to the service's own client, and they can never be synced to a
/// Rockbox player because there is nothing to copy.
public enum TrackSource: String, Codable, Sendable, CaseIterable {
    case local
    case appleMusic
    case spotify

    public var label: String {
        switch self {
        case .local: return "local"
        case .appleMusic: return "apple music"
        case .spotify: return "spotify"
        }
    }

    /// True when the audio is streamed and no local file backs it.
    public var isStreaming: Bool { self != .local }
}

// MARK: - Track

public struct Track: Identifiable, Hashable, Codable, Sendable {
    /// Local tracks are identified by path. Streaming tracks have no meaningful path, so
    /// they are identified by service plus the service's own id.
    public var id: String {
        source == .local ? url.path : "\(source.rawValue):\(externalID ?? url.path)"
    }

    /// Which service owns this track. Defaults to `.local` so an index written before
    /// streaming existed still decodes.
    public var source: TrackSource = .local

    /// The service's identifier — a Music.app database ID, or a Spotify URI.
    public var externalID: String?

    public var isStreaming: Bool { source.isStreaming }

    public var url: URL
    public var title: String
    public var artist: String
    public var albumArtist: String
    public var album: String
    public var genre: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: TimeInterval
    public var bitrate: Int?
    public var sampleRate: Int?
    public var channels: Int?
    public var codec: String
    public var fileSize: Int64
    public var modified: Date
    /// True when the tags were repaired from an online source rather than read from the file.
    public var enriched: Bool = false
    /// MusicBrainz recording id, when we matched one.
    public var mbid: String?

    public var isLossless: Bool {
        ["flac", "alac", "wav", "aiff", "ape", "wv"].contains(codec.lowercased())
    }

    /// The key used to group tracks into albums. Album artist wins so compilations stay together.
    public var albumKey: AlbumKey {
        AlbumKey(album: album, artist: albumArtist.isEmpty ? artist : albumArtist)
    }

    /// A track is "incomplete" when it is missing the fields we would want to look up online.
    public var needsMetadata: Bool {
        title.isEmpty || artist.isEmpty || artist == Track.unknown
            || album.isEmpty || album == Track.unknown
    }

    public static let unknown = "unknown"

    /// Written by hand rather than synthesised.
    ///
    /// A synthesised `init(from:)` ignores property defaults and fails outright on a
    /// missing key, so adding `source` would have invalidated every existing index and
    /// forced a full rescan. `decodeIfPresent` lets an older index load unchanged.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(TrackSource.self, forKey: .source) ?? .local
        externalID = try c.decodeIfPresent(String.self, forKey: .externalID)
        url = try c.decode(URL.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        albumArtist = try c.decode(String.self, forKey: .albumArtist)
        album = try c.decode(String.self, forKey: .album)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        trackNumber = try c.decodeIfPresent(Int.self, forKey: .trackNumber)
        discNumber = try c.decodeIfPresent(Int.self, forKey: .discNumber)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate)
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate)
        channels = try c.decodeIfPresent(Int.self, forKey: .channels)
        codec = try c.decode(String.self, forKey: .codec)
        fileSize = try c.decode(Int64.self, forKey: .fileSize)
        modified = try c.decode(Date.self, forKey: .modified)
        enriched = try c.decodeIfPresent(Bool.self, forKey: .enriched) ?? false
        mbid = try c.decodeIfPresent(String.self, forKey: .mbid)
    }

    /// A track streamed from a service. There is no file, so the URL is synthetic and
    /// exists only to keep the rest of the model uniform.
    public init(
        source: TrackSource,
        externalID: String,
        title: String, artist: String, albumArtist: String, album: String,
        genre: String? = nil, year: Int? = nil, trackNumber: Int? = nil,
        discNumber: Int? = nil, duration: TimeInterval, codec: String = "stream"
    ) {
        self.source = source
        self.externalID = externalID
        self.url = URL(string: "\(source.rawValue)://\(externalID)")
            ?? URL(fileURLWithPath: "/\(source.rawValue)/\(externalID)")
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.bitrate = nil
        self.sampleRate = nil
        self.channels = nil
        self.codec = codec
        self.fileSize = 0
        self.modified = .distantPast
        self.enriched = false
        self.mbid = nil
    }

    public init(
        url: URL, title: String, artist: String, albumArtist: String, album: String,
        genre: String? = nil, year: Int? = nil, trackNumber: Int? = nil,
        discNumber: Int? = nil, duration: TimeInterval, bitrate: Int? = nil,
        sampleRate: Int? = nil, channels: Int? = nil, codec: String,
        fileSize: Int64, modified: Date, enriched: Bool = false, mbid: String? = nil
    ) {
        self.url = url
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
        self.codec = codec
        self.fileSize = fileSize
        self.modified = modified
        self.enriched = enriched
        self.mbid = mbid
    }
}

// MARK: - Album

public struct AlbumKey: Hashable, Codable, Sendable {
    public let album: String
    public let artist: String

    public init(album: String, artist: String) {
        // Normalised so "Kid A" / "kid a " collapse to one album.
        self.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct Album: Identifiable, Hashable, Sendable {
    public var id: AlbumKey { key }
    public var key: AlbumKey
    public var tracks: [Track]

    public var title: String { key.album }
    public var artist: String { key.artist }
    public var year: Int? { tracks.compactMap(\.year).min() }
    public var genre: String? { tracks.compactMap(\.genre).first }
    public var duration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }
    public var totalSize: Int64 { tracks.reduce(0) { $0 + $1.fileSize } }
    public var isLossless: Bool { tracks.contains(where: \.isLossless) }

    /// Directory the album lives in — used to find folder-level cover art.
    public var directory: URL? { tracks.first?.url.deletingLastPathComponent() }

    public init(key: AlbumKey, tracks: [Track]) {
        self.key = key
        self.tracks = tracks.sorted {
            let d0 = $0.discNumber ?? 1, d1 = $1.discNumber ?? 1
            if d0 != d1 { return d0 < d1 }
            let t0 = $0.trackNumber ?? Int.max, t1 = $1.trackNumber ?? Int.max
            if t0 != t1 { return t0 < t1 }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

// MARK: - Playlist

public struct Playlist: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Stored as file paths so a playlist survives a library rescan.
    public var trackPaths: [String]
    /// Whether this playlist is included in the next device sync.
    public var syncEnabled: Bool

    public init(id: UUID = UUID(), name: String, trackPaths: [String] = [], syncEnabled: Bool = false) {
        self.id = id
        self.name = name
        self.trackPaths = trackPaths
        self.syncEnabled = syncEnabled
    }
}

// MARK: - Formatting helpers

public extension TimeInterval {
    /// `3:07` / `1:02:44` — the transport clock format.
    var clockString: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// `12 min` / `1 hr 4 min` — used for album totals.
    var longString: String {
        let total = Int(rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h) hr \(m) min" }
        return "\(max(m, 1)) min"
    }
}

public extension Int64 {
    var byteString: String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: self)
    }
}

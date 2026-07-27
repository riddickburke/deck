import Foundation

// MARK: - Track

public struct Track: Identifiable, Hashable, Codable, Sendable {
    public var id: String { url.path }

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

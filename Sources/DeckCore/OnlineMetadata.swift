import Foundation

// On Linux, URLSession lives in a separate module from the rest of Foundation.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Metadata repair and artwork lookup against free, key-less services.
///
///  - **MusicBrainz** for canonical artist/album/track/year.
///  - **Cover Art Archive** for the art attached to a MusicBrainz release.
///  - **iTunes Search** as a fallback for art, since CAA coverage is patchy for
///    recent and non-Western releases.
///
/// MusicBrainz asks for a descriptive User-Agent and at most one request per second.
/// Both are enforced here rather than left to the caller.
public actor OnlineMetadata {
    public static let shared = OnlineMetadata()

    public struct Match: Sendable, Equatable {
        public var title: String?
        public var artist: String?
        public var album: String?
        public var albumArtist: String?
        public var year: Int?
        public var trackNumber: Int?
        public var genre: String?
        public var recordingMBID: String?
        public var releaseMBID: String?
        public var releaseGroupMBID: String?
        public var score: Int
    }

    private let userAgent = "Deck/1.0 ( https://github.com/local/deck )"
    private let session: URLSession
    private var lastMusicBrainzRequest: Date = .distantPast
    private var artworkMemo: [String: Data?] = [:]

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.urlCache = URLCache(
            memoryCapacity: 8 << 20, diskCapacity: 128 << 20,
            directory: Config.cacheDirectory.appendingPathComponent("http"))
        // Use the cache when we have it, but always allow a live request.
        config.requestCachePolicy = .useProtocolCachePolicy
        session = URLSession(configuration: config)
    }

    // MARK: - Track/album identification

    /// Best-effort identification from whatever tags the file already has.
    /// Returns nil rather than guessing when there is nothing to search on.
    public func identify(track: Track) async -> Match? {
        let title = track.title.trimmingCharacters(in: .whitespaces)
        let artist = track.artist == Track.unknown ? "" : track.artist
        let album = track.album == Track.unknown ? "" : track.album

        // With no artist and no album, a title-only search returns noise. Fall back to
        // parsing the filename, which is very often "Artist - Title".
        var searchArtist = artist
        var searchTitle = title
        if searchArtist.isEmpty {
            let stem = track.url.deletingPathExtension().lastPathComponent
            if let parsed = Self.parseArtistTitle(from: stem) {
                searchArtist = parsed.artist
                if searchTitle.isEmpty || searchTitle == stem { searchTitle = parsed.title }
            }
        }
        guard !searchTitle.isEmpty || !album.isEmpty else { return nil }

        var terms: [String] = []
        if !searchTitle.isEmpty { terms.append("recording:\(Self.lucene(searchTitle))") }
        if !searchArtist.isEmpty { terms.append("artist:\(Self.lucene(searchArtist))") }
        if !album.isEmpty { terms.append("release:\(Self.lucene(album))") }

        let query = terms.joined(separator: " AND ")
        guard var comps = URLComponents(string: "https://musicbrainz.org/ws/2/recording/") else { return nil }
        comps.queryItems = [
            .init(name: "query", value: query),
            .init(name: "fmt", value: "json"),
            .init(name: "limit", value: "5"),
        ]
        guard let url = comps.url,
              let data = try? await musicBrainzGet(url),
              let response = try? JSONDecoder().decode(MBRecordingSearch.self, from: data),
              let best = response.recordings.first
        else { return nil }

        // MusicBrainz scores 0-100. Below ~70 the match is usually wrong, and writing a
        // wrong tag is worse than leaving the file alone.
        guard best.score >= 70 else { return nil }

        let release = best.releases?.first
        return Match(
            title: best.title,
            artist: best.artistCredit?.first?.name,
            album: release?.title,
            albumArtist: release?.artistCredit?.first?.name ?? best.artistCredit?.first?.name,
            year: MetadataReader.parseYear(release?.date),
            trackNumber: release?.media?.first?.track?.first?.position,
            genre: nil,
            recordingMBID: best.id,
            releaseMBID: release?.id,
            releaseGroupMBID: release?.releaseGroup?.id,
            score: best.score
        )
    }

    // MARK: - Artwork

    /// Returns JPEG/PNG data for an album cover, or nil. Tries Cover Art Archive via a
    /// MusicBrainz release-group lookup, then iTunes.
    public func artwork(album: String, artist: String) async -> Data? {
        let memoKey = "\(artist.lowercased())::\(album.lowercased())"
        if let memo = artworkMemo[memoKey] { return memo }

        var result: Data?
        if let mbid = await releaseGroupMBID(album: album, artist: artist) {
            result = await coverArtArchive(releaseGroupMBID: mbid)
        }
        if result == nil {
            result = await itunesArtwork(album: album, artist: artist)
        }
        artworkMemo[memoKey] = result
        return result
    }

    private func releaseGroupMBID(album: String, artist: String) async -> String? {
        guard !album.isEmpty, album != Track.unknown else { return nil }
        var terms = ["releasegroup:\(Self.lucene(album))"]
        if !artist.isEmpty, artist != Track.unknown {
            terms.append("artist:\(Self.lucene(artist))")
        }
        guard var comps = URLComponents(string: "https://musicbrainz.org/ws/2/release-group/")
        else { return nil }
        comps.queryItems = [
            .init(name: "query", value: terms.joined(separator: " AND ")),
            .init(name: "fmt", value: "json"),
            .init(name: "limit", value: "3"),
        ]
        guard let url = comps.url,
              let data = try? await musicBrainzGet(url),
              let response = try? JSONDecoder().decode(MBReleaseGroupSearch.self, from: data)
        else { return nil }
        return response.releaseGroups.first { $0.score >= 70 }?.id
    }

    private func coverArtArchive(releaseGroupMBID mbid: String) async -> Data? {
        let url = URL(string: "https://coverartarchive.org/release-group/\(mbid)/front-500")!
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count > 1024
        else { return nil }
        return data
    }

    private func itunesArtwork(album: String, artist: String) async -> Data? {
        let term = [artist, album].filter { !$0.isEmpty && $0 != Track.unknown }
            .joined(separator: " ")
        guard !term.isEmpty,
              var comps = URLComponents(string: "https://itunes.apple.com/search")
        else { return nil }
        comps.queryItems = [
            .init(name: "term", value: term),
            .init(name: "entity", value: "album"),
            .init(name: "limit", value: "3"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await session.data(from: url),
              let response = try? JSONDecoder().decode(ITunesSearch.self, from: data),
              let art = response.results.first?.artworkUrl100
        else { return nil }

        // iTunes serves 100px by default; the same URL pattern yields 600px.
        let hiRes = art.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        guard let hiResURL = URL(string: hiRes),
              let (imageData, _) = try? await session.data(from: hiResURL),
              imageData.count > 1024
        else { return nil }
        return imageData
    }

    // MARK: - Request plumbing

    /// Serialises MusicBrainz calls to one per second, as their terms require.
    private func musicBrainzGet(_ url: URL) async throws -> Data {
        let minimumGap: TimeInterval = 1.1
        let elapsed = Date().timeIntervalSince(lastMusicBrainzRequest)
        if elapsed < minimumGap {
            try? await Task.sleep(nanoseconds: UInt64((minimumGap - elapsed) * 1_000_000_000))
        }
        lastMusicBrainzRequest = Date()

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: request)
        return data
    }

    /// Escapes Lucene syntax and quotes the phrase, so a title with a colon or a
    /// stray bracket does not produce a malformed query.
    public static func lucene(_ raw: String) -> String {
        var escaped = ""
        for ch in raw {
            if "+-&|!(){}[]^\"~*?:\\/".contains(ch) { escaped.append("\\") }
            escaped.append(ch)
        }
        return "\"\(escaped)\""
    }

    /// Recognises `Artist - Title`, `01 - Artist - Title`, and `01. Title`.
    public static func parseArtistTitle(from stem: String) -> (artist: String, title: String)? {
        var working = stem
        // Strip a leading track number.
        if let range = working.range(of: #"^\s*\d{1,3}\s*[-._)]\s*"#, options: .regularExpression) {
            working.removeSubrange(range)
        }
        let parts = working.components(separatedBy: " - ")
        guard parts.count >= 2 else { return nil }
        let artist = parts[0].trimmingCharacters(in: .whitespaces)
        let title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        guard !artist.isEmpty, !title.isEmpty else { return nil }
        return (artist, title)
    }
}

// MARK: - Response shapes

private struct MBRecordingSearch: Decodable {
    struct ArtistCredit: Decodable { let name: String }
    struct Track: Decodable { let position: Int? }
    struct Media: Decodable { let track: [Track]? }
    struct ReleaseGroup: Decodable { let id: String }
    struct Release: Decodable {
        let id: String
        let title: String?
        let date: String?
        let media: [Media]?
        let releaseGroup: ReleaseGroup?
        let artistCredit: [ArtistCredit]?
        enum CodingKeys: String, CodingKey {
            case id, title, date, media
            case releaseGroup = "release-group"
            case artistCredit = "artist-credit"
        }
    }
    struct Recording: Decodable {
        let id: String
        let title: String?
        let score: Int
        let releases: [Release]?
        let artistCredit: [ArtistCredit]?
        enum CodingKeys: String, CodingKey {
            case id, title, score, releases
            case artistCredit = "artist-credit"
        }
    }
    let recordings: [Recording]
}

private struct MBReleaseGroupSearch: Decodable {
    struct Group: Decodable { let id: String; let score: Int }
    let releaseGroups: [Group]
    enum CodingKeys: String, CodingKey { case releaseGroups = "release-groups" }
}

private struct ITunesSearch: Decodable {
    struct Result: Decodable { let artworkUrl100: String? }
    let results: [Result]
}

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Spotify Web API client: OAuth for sign-in, library reads, and Connect for transport.
///
/// Spotify does not permit third-party applications to stream its audio, so Deck cannot
/// decode it. What the API does allow is driving playback on a device already running an
/// official Spotify client. Deck therefore browses and commands, and Spotify plays —
/// the same arrangement used for Apple Music via Music.app.
///
/// Authorization uses PKCE with a loopback redirect. That flow exists precisely for
/// installed apps: it needs no client secret, which is important because a secret shipped
/// inside a distributed binary is not a secret.
public actor SpotifyClient {
    public struct Tokens: Codable, Sendable {
        public var accessToken: String
        public var refreshToken: String
        public var expiresAt: Date

        public var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
    }

    public struct Device: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let type: String
        public let isActive: Bool
        public let volumePercent: Int?
    }

    public enum Failure: LocalizedError {
        case notConfigured
        case notAuthorized
        case premiumRequired
        case noActiveDevice
        case http(Int, String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Set a Spotify client ID in settings first."
            case .notAuthorized:
                return "Not signed in to Spotify."
            case .premiumRequired:
                return "Spotify Premium is required to control playback."
            case .noActiveDevice:
                return "No Spotify device is active. Open Spotify somewhere and play "
                    + "something once, then try again."
            case .http(let code, let body):
                return "Spotify API error \(code): \(body.prefix(160))"
            }
        }
    }

    /// Scopes: library reads plus playback read/control. Deliberately no write access to
    /// the user's playlists — Deck never modifies a Spotify account.
    public static let scopes = [
        "user-library-read",
        "playlist-read-private",
        "user-read-playback-state",
        "user-modify-playback-state",
    ].joined(separator: " ")

    private let session: URLSession
    private var tokens: Tokens?
    private var clientID: String?

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    public func configure(clientID: String?, tokens: Tokens?) {
        self.clientID = clientID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tokens = tokens
    }

    public var isAuthorized: Bool { tokens != nil }
    public var currentTokens: Tokens? { tokens }

    // MARK: - Authorization

    /// The URL to open in a browser, plus the verifier that must be kept for the exchange.
    public static func authorizationURL(
        clientID: String, redirectURI: String
    ) -> (url: URL, verifier: String, state: String)? {
        let verifier = randomURLSafeString(64)
        guard let challenge = PKCE.challenge(for: verifier) else { return nil }
        let state = randomURLSafeString(16)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")
        components?.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: scopes),
            .init(name: "state", value: state),
        ]
        guard let url = components?.url else { return nil }
        return (url, verifier, state)
    }

    public func exchange(
        code: String, verifier: String, redirectURI: String
    ) async throws -> Tokens {
        guard let clientID else { throw Failure.notConfigured }

        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ]
        let tokens = try await tokenRequest(body)
        self.tokens = tokens
        return tokens
    }

    @discardableResult
    public func refreshIfNeeded() async throws -> Tokens {
        guard let existing = tokens else { throw Failure.notAuthorized }
        guard existing.isExpired else { return existing }
        guard let clientID else { throw Failure.notConfigured }

        var refreshed = try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": existing.refreshToken,
            "client_id": clientID,
        ])
        // Spotify omits the refresh token when it has not rotated.
        if refreshed.refreshToken.isEmpty { refreshed.refreshToken = existing.refreshToken }
        tokens = refreshed
        return refreshed
    }

    public func signOut() { tokens = nil }

    private func tokenRequest(_ form: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.http(status, String(decoding: data, as: UTF8.self))
        }

        struct Payload: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return Tokens(
            accessToken: payload.access_token,
            refreshToken: payload.refresh_token ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expires_in)))
    }

    // MARK: - Library

    /// Saved albums, expanded into tracks. Paged 50 at a time, which is the API maximum.
    public func savedAlbums(
        progress: @Sendable (Int) -> Void = { _ in }
    ) async throws -> [Track] {
        var tracks: [Track] = []
        var next: String? = "https://api.spotify.com/v1/me/albums?limit=50"

        while let url = next {
            let page: SavedAlbumsPage = try await get(url)
            for item in page.items {
                let album = item.album
                let artist = album.artists.first?.name ?? Track.unknown
                let year = album.release_date.flatMap { MetadataReader.parseYear($0) }

                for t in album.tracks?.items ?? [] {
                    guard let uri = t.uri else { continue }
                    tracks.append(Track(
                        source: .spotify,
                        externalID: uri,
                        title: t.name,
                        artist: t.artists.first?.name ?? artist,
                        albumArtist: artist,
                        album: album.name,
                        year: year,
                        trackNumber: t.track_number,
                        discNumber: t.disc_number,
                        duration: Double(t.duration_ms) / 1000,
                        codec: "spotify"))
                }
            }
            progress(tracks.count)
            next = page.next
        }
        return tracks
    }

    /// Saved tracks, which are not covered by saved albums.
    public func savedTracks(
        progress: @Sendable (Int) -> Void = { _ in }
    ) async throws -> [Track] {
        var tracks: [Track] = []
        var next: String? = "https://api.spotify.com/v1/me/tracks?limit=50"

        while let url = next {
            let page: SavedTracksPage = try await get(url)
            for item in page.items {
                let t = item.track
                guard let uri = t.uri else { continue }
                tracks.append(Track(
                    source: .spotify,
                    externalID: uri,
                    title: t.name,
                    artist: t.artists.first?.name ?? Track.unknown,
                    albumArtist: t.album?.artists.first?.name
                        ?? t.artists.first?.name ?? Track.unknown,
                    album: t.album?.name ?? Track.unknown,
                    year: t.album?.release_date.flatMap { MetadataReader.parseYear($0) },
                    trackNumber: t.track_number,
                    discNumber: t.disc_number,
                    duration: Double(t.duration_ms) / 1000,
                    codec: "spotify"))
            }
            progress(tracks.count)
            next = page.next
        }
        return tracks
    }

    /// Cover art URL for an album, taken from the saved-albums payload.
    public func albumArtworkURL(forTrackURI uri: String) async throws -> URL? {
        let id = uri.split(separator: ":").last.map(String.init) ?? uri
        struct TrackPayload: Decodable {
            struct Album: Decodable { struct Image: Decodable { let url: String }
                let images: [Image] }
            let album: Album
        }
        let payload: TrackPayload = try await get("https://api.spotify.com/v1/tracks/\(id)")
        return payload.album.images.first.flatMap { URL(string: $0.url) }
    }

    // MARK: - Connect playback

    public func devices() async throws -> [Device] {
        struct Payload: Decodable {
            struct Item: Decodable {
                let id: String?
                let name: String
                let type: String
                let is_active: Bool
                let volume_percent: Int?
            }
            let devices: [Item]
        }
        let payload: Payload = try await get("https://api.spotify.com/v1/me/player/devices")
        return payload.devices.compactMap { item in
            guard let id = item.id else { return nil }
            return Device(
                id: id, name: item.name, type: item.type,
                isActive: item.is_active, volumePercent: item.volume_percent)
        }
    }

    public func play(uri: String, deviceID: String? = nil) async throws {
        var endpoint = "https://api.spotify.com/v1/me/player/play"
        if let deviceID { endpoint += "?device_id=\(deviceID)" }
        let body = try JSONSerialization.data(withJSONObject: ["uris": [uri]])
        try await send("PUT", endpoint, body: body)
    }

    public func pause() async throws {
        try await send("PUT", "https://api.spotify.com/v1/me/player/pause")
    }

    public func resume() async throws {
        try await send("PUT", "https://api.spotify.com/v1/me/player/play")
    }

    public func next() async throws {
        try await send("POST", "https://api.spotify.com/v1/me/player/next")
    }

    public func previous() async throws {
        try await send("POST", "https://api.spotify.com/v1/me/player/previous")
    }

    public func seek(to seconds: TimeInterval) async throws {
        try await send(
            "PUT",
            "https://api.spotify.com/v1/me/player/seek?position_ms=\(Int(seconds * 1000))")
    }

    public func setVolume(_ volume: Float) async throws {
        let percent = Int(max(0, min(1, volume)) * 100)
        try await send(
            "PUT", "https://api.spotify.com/v1/me/player/volume?volume_percent=\(percent)")
    }

    public struct PlaybackState: Sendable {
        public var isPlaying: Bool
        public var position: TimeInterval
        public var duration: TimeInterval
        public var trackURI: String?
        public var deviceName: String?
    }

    public func playbackState() async throws -> PlaybackState? {
        struct Payload: Decodable {
            struct Item: Decodable { let uri: String?; let duration_ms: Int? }
            struct Dev: Decodable { let name: String? }
            let is_playing: Bool
            let progress_ms: Int?
            let item: Item?
            let device: Dev?
        }
        // 204 means nothing is playing at all, which is not an error.
        guard let payload: Payload = try await getOptional(
            "https://api.spotify.com/v1/me/player") else { return nil }

        return PlaybackState(
            isPlaying: payload.is_playing,
            position: Double(payload.progress_ms ?? 0) / 1000,
            duration: Double(payload.item?.duration_ms ?? 0) / 1000,
            trackURI: payload.item?.uri,
            deviceName: payload.device?.name)
    }

    // MARK: - Transport plumbing

    private func authorizedRequest(_ url: URL) async throws -> URLRequest {
        let tokens = try await refreshIfNeeded()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func get<T: Decodable>(_ urlString: String) async throws -> T {
        guard let value: T = try await getOptional(urlString) else {
            throw Failure.http(204, "empty response")
        }
        return value
    }

    private func getOptional<T: Decodable>(_ urlString: String) async throws -> T? {
        guard let url = URL(string: urlString) else { throw Failure.notConfigured }
        let request = try await authorizedRequest(url)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 204 || data.isEmpty { return nil }
        guard (200..<300).contains(status) else {
            throw mapError(status: status, data: data)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ method: String, _ urlString: String, body: Data? = nil) async throws {
        guard let url = URL(string: urlString) else { throw Failure.notConfigured }
        var request = try await authorizedRequest(url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw mapError(status: status, data: data)
        }
    }

    private func mapError(status: Int, data: Data) -> Error {
        let body = String(decoding: data, as: UTF8.self)
        switch status {
        case 401: return Failure.notAuthorized
        // Spotify returns 403 for free accounts attempting playback control, and 404
        // when there is no device to control.
        case 403 where body.contains("PREMIUM_REQUIRED") || body.lowercased().contains("premium"):
            return Failure.premiumRequired
        case 404: return Failure.noActiveDevice
        default: return Failure.http(status, body)
        }
    }

    // MARK: - Helpers

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func randomURLSafeString(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }
}

// MARK: - Response shapes

private struct SpotifyArtist: Decodable { let name: String }

private struct SpotifyTrackPayload: Decodable {
    let uri: String?
    let name: String
    let artists: [SpotifyArtist]
    let duration_ms: Int
    let track_number: Int?
    let disc_number: Int?
    let album: SpotifyAlbumPayload?
}

private struct SpotifyAlbumPayload: Decodable {
    struct Tracks: Decodable { let items: [SpotifyTrackPayload] }
    let name: String
    let artists: [SpotifyArtist]
    let release_date: String?
    let tracks: Tracks?
}

private struct SavedAlbumsPage: Decodable {
    struct Item: Decodable { let album: SpotifyAlbumPayload }
    let items: [Item]
    let next: String?
}

private struct SavedTracksPage: Decodable {
    struct Item: Decodable { let track: SpotifyTrackPayload }
    let items: [Item]
    let next: String?
}

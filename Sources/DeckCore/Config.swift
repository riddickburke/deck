import Foundation

/// Persisted settings. Deliberately a flat Codable struct written as JSON —
/// no defaults system, so the config is inspectable and editable by hand.
public struct Config: Codable, Equatable, Sendable {
    public var libraryRoots: [String]
    public var themeID: String
    public var scanlines: Bool
    public var volume: Float
    public var shuffle: Bool
    public var repeatMode: RepeatMode

    /// Convert FLAC to MP3 when copying to the device. The local original is never touched;
    /// the converted copy is written to a cache and only the cache copy goes to the device.
    public var convertFlacToMP3: Bool
    public var mp3Quality: Int          // lame -q:a, 0 = ~245kbps VBR
    public var deviceFolderTemplate: String
    public var writeDeviceArtwork: Bool
    public var deviceArtworkSize: Int
    public var onlineLookupEnabled: Bool
    /// Spotify application client ID. The user registers their own; there is no secret,
    /// because PKCE does not need one and a secret in a shipped binary is not a secret.
    public var spotifyClientID: String?

    public enum RepeatMode: String, Codable, CaseIterable, Sendable {
        case off, all, one
        public var symbol: String {
            switch self {
            case .off: return "rpt:off"
            case .all: return "rpt:all"
            case .one: return "rpt:one"
            }
        }
    }

    public static let `default` = Config(
        libraryRoots: [],
        themeID: "dark",
        scanlines: true,
        volume: 0.8,
        shuffle: false,
        repeatMode: .off,
        convertFlacToMP3: false,
        mp3Quality: 0,
        deviceFolderTemplate: "{albumartist}/{album}",
        writeDeviceArtwork: true,
        deviceArtworkSize: 500,
        onlineLookupEnabled: true,
        spotifyClientID: nil
    )

    // MARK: - Paths

    public static let bundleID = "com.riddickburke.deck"

    /// The identifier used before the app dropped its original branding. Data written
    /// under it is moved across once, so an existing library index, playlists and
    /// settings survive the rename instead of silently resetting.
    static let legacyBundleID = "com.nebula.deck"

    /// Moves `~/Library/Application Support` and `~/Library/Caches` data from the old
    /// identifier. Runs at most once: it only acts when the old directory exists and the
    /// new one has not been populated yet, so it can be called on every launch.
    public static func migrateLegacyDataIfNeeded() {
        let fm = FileManager.default
        let bases: [URL] = [.applicationSupportDirectory, .cachesDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first }
        migrate(bases: bases, from: legacyBundleID, to: bundleID)
    }

    /// Split out from the caller so it can be exercised against temporary directories
    /// rather than the real Library. Safe to call repeatedly: it never overwrites data
    /// already present under the new identifier.
    public static func migrate(bases: [URL], from legacy: String, to current: String) {
        let fm = FileManager.default

        for base in bases {
            let old = base.appendingPathComponent(legacy, isDirectory: true)
            let new = base.appendingPathComponent(current, isDirectory: true)

            guard fm.fileExists(atPath: old.path) else { continue }

            // Never clobber a newer install's data.
            let existing = (try? fm.contentsOfDirectory(atPath: new.path)) ?? []
            guard existing.isEmpty else { continue }

            // Move the whole directory when the destination is absent, otherwise merge
            // entry by entry — an empty directory auto-created by `appSupportDirectory`
            // would otherwise block the move.
            if !fm.fileExists(atPath: new.path) {
                try? fm.moveItem(at: old, to: new)
            } else {
                for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] {
                    try? fm.moveItem(
                        at: old.appendingPathComponent(name),
                        to: new.appendingPathComponent(name))
                }
                try? fm.removeItem(at: old)
            }
        }
    }

    /// macOS uses the reverse-DNS identifier under Application Support, which is the
    /// platform convention. Linux follows the XDG base directory spec instead, so
    /// settings land in ~/.config/deck rather than an Apple-shaped path.
    public static var appSupportDirectory: URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        #else
        let dir = xdgDirectory(variable: "XDG_CONFIG_HOME", fallback: ".config")
            .appendingPathComponent("deck", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var cacheDirectory: URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        #else
        let dir = xdgDirectory(variable: "XDG_CACHE_HOME", fallback: ".cache")
            .appendingPathComponent("deck", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    #if !os(macOS)
    /// Honours the XDG variable when set to an absolute path, as the spec requires
    /// relative values be ignored, and falls back to the conventional location.
    static func xdgDirectory(variable: String, fallback: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let value = ProcessInfo.processInfo.environment[variable],
           value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return home.appendingPathComponent(fallback, isDirectory: true)
    }

    /// The user's music folder, honouring XDG_MUSIC_DIR from user-dirs.dirs when set.
    static func defaultMusicDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let value = ProcessInfo.processInfo.environment["XDG_MUSIC_DIR"],
           value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return home.appendingPathComponent("Music", isDirectory: true)
    }
    #endif

    public static var configURL: URL {
        appSupportDirectory.appendingPathComponent("config.json")
    }

    public static var playlistsURL: URL {
        appSupportDirectory.appendingPathComponent("playlists.json")
    }

    /// OAuth tokens are kept separate from the settings file so the file itself can be
    /// restricted to the owner, and so sharing a config never leaks credentials.
    public static var spotifyTokensURL: URL {
        appSupportDirectory.appendingPathComponent("spotify-tokens.json")
    }

    // MARK: - Load / save

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(Config.self, from: data)
        else {
            var fresh = Config.default
            // Seed with the user's Music folder so first launch is not an empty screen.
            #if os(macOS)
            let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            #else
            let music: URL? = defaultMusicDirectory()
            #endif
            if let music, FileManager.default.fileExists(atPath: music.path) {
                fresh.libraryRoots = [music.path]
            }
            return fresh
        }
        return decoded
    }

    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Config.configURL, options: .atomic)
    }

    public var rootURLs: [URL] {
        libraryRoots.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }
}

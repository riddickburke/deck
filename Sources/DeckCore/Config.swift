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
        onlineLookupEnabled: true
    )

    // MARK: - Paths

    public static let bundleID = "com.nebula.deck"

    public static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var configURL: URL {
        appSupportDirectory.appendingPathComponent("config.json")
    }

    public static var playlistsURL: URL {
        appSupportDirectory.appendingPathComponent("playlists.json")
    }

    // MARK: - Load / save

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(Config.self, from: data)
        else {
            var fresh = Config.default
            // Seed with the user's Music folder so first launch is not an empty screen.
            let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
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

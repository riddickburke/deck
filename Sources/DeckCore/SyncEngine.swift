import Foundation

// MARK: - Plan

public struct SyncAction: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case copy       // straight file copy
        case convert    // FLAC/ALAC -> MP3, device copy only
        case upToDate   // already present and unchanged
    }

    public var id: String { destination.path }
    public let track: Track
    public let destination: URL
    public let kind: Kind
    /// Best estimate of bytes that will land on the device.
    public let estimatedBytes: Int64

    public init(track: Track, destination: URL, kind: Kind, estimatedBytes: Int64) {
        self.track = track
        self.destination = destination
        self.kind = kind
        self.estimatedBytes = estimatedBytes
    }
}

public struct SyncPlan: Sendable {
    public var actions: [SyncAction]
    public var orphans: [URL]
    public var device: RockboxDevice
    public var playlists: [Playlist]
    /// Tracks left out because they stream and have no file to copy.
    public var skippedStreaming: Int = 0

    public var transfers: [SyncAction] { actions.filter { $0.kind != .upToDate } }
    public var upToDateCount: Int { actions.count { $0.kind == .upToDate } }
    public var convertCount: Int { actions.count { $0.kind == .convert } }
    public var bytesToTransfer: Int64 { transfers.reduce(0) { $0 + $1.estimatedBytes } }
    public var orphanBytes: Int64 {
        orphans.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Negative means the transfer will not fit.
    public var headroomAfterSync: Int64 {
        device.availableCapacity - bytesToTransfer
    }
    public var fits: Bool { headroomAfterSync >= 0 }

    public init(
        actions: [SyncAction], orphans: [URL], device: RockboxDevice,
        playlists: [Playlist], skippedStreaming: Int = 0
    ) {
        self.actions = actions
        self.orphans = orphans
        self.device = device
        self.playlists = playlists
        self.skippedStreaming = skippedStreaming
    }
}

public struct SyncProgress: Sendable {
    public var completed: Int
    public var total: Int
    public var bytesWritten: Int64
    public var bytesTotal: Int64
    public var currentFile: String
    public var currentFileFraction: Double
    public var phase: String
}

public struct SyncReport: Sendable {
    public var copied: Int
    public var converted: Int
    public var skipped: Int
    public var removed: Int
    public var bytesWritten: Int64
    public var errors: [String]
    public var duration: TimeInterval
    public var playlistsWritten: Int
}

public enum SyncError: LocalizedError {
    case cancelled
    case deviceNotWritable(String)
    case insufficientSpace(needed: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "sync cancelled"
        case .deviceNotWritable(let path): return "device is not writable: \(path)"
        case .insufficientSpace(let needed, let available):
            return "need \(needed.byteString), only \(available.byteString) free"
        }
    }
}

// MARK: - Engine

public actor SyncEngine {
    private var cancelled = false

    public init() {}

    public func cancel() { cancelled = true }
    public func resetCancellation() { cancelled = false }

    // MARK: Planning

    /// Works out what would change without touching the device.
    public func plan(
        tracks: [Track],
        playlists: [Playlist],
        device: RockboxDevice,
        config: Config
    ) async -> SyncPlan {
        let manifest = Manifest.load(device: device)
        var actions: [SyncAction] = []
        var claimed = Set<String>()
        var skippedStreaming = 0

        for track in tracks {
            // Streaming tracks have no file behind them. Skipping here rather than
            // failing mid-transfer keeps the plan's counts and size estimate honest.
            guard !track.isStreaming else {
                skippedStreaming += 1
                continue
            }
            let convert = Transcoder.shouldConvert(track, config: config)
            let destination = Self.destinationURL(
                for: track, device: device, template: config.deviceFolderTemplate, asMP3: convert)
            // Two tracks can collide on one destination path after sanitising; keep the first.
            guard claimed.insert(destination.path).inserted else { continue }

            let stamp = Manifest.Stamp(
                sourcePath: track.url.path,
                sourceSize: track.fileSize,
                sourceModified: track.modified.timeIntervalSince1970,
                converted: convert,
                quality: convert ? config.mp3Quality : -1
            )

            let present = FileManager.default.fileExists(atPath: destination.path)
            if present, manifest.entries[destination.path] == stamp {
                actions.append(SyncAction(
                    track: track, destination: destination, kind: .upToDate,
                    estimatedBytes: 0))
                continue
            }

            // A converted file is roughly 245kbps VBR; good enough for a space estimate.
            let estimate: Int64 = convert
                ? Int64(track.duration * 245_000 / 8)
                : track.fileSize

            actions.append(SyncAction(
                track: track, destination: destination,
                kind: convert ? .convert : .copy, estimatedBytes: estimate))
        }

        let orphans = Self.findOrphans(manifest: manifest, expected: claimed)
        return SyncPlan(
            actions: actions, orphans: orphans, device: device,
            playlists: playlists, skippedStreaming: skippedStreaming)
    }

    /// Files we previously wrote that are no longer part of the selection. We only ever
    /// consider paths recorded in our own manifest, so nothing the user put on the
    /// device by hand is ever a deletion candidate.
    public static func findOrphans(manifest: Manifest, expected: Set<String>) -> [URL] {
        manifest.entries.keys
            .filter { !expected.contains($0) && FileManager.default.fileExists(atPath: $0) }
            .sorted()
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: Execution

    public func execute(
        plan: SyncPlan,
        config: Config,
        removeOrphans: Bool,
        artworkFor: @Sendable @escaping (AlbumKey) async -> Data?,
        progress: @Sendable @escaping (SyncProgress) -> Void
    ) async -> SyncReport {
        let started = Date()
        cancelled = false

        var report = SyncReport(
            copied: 0, converted: 0, skipped: 0, removed: 0,
            bytesWritten: 0, errors: [], duration: 0, playlistsWritten: 0)

        let transfers = plan.transfers
        let bytesTotal = plan.bytesToTransfer
        var manifest = Manifest.load(device: plan.device)
        let fm = FileManager.default

        guard fm.isWritableFilePath(plan.device.mountPoint.path) else {
            report.errors.append(SyncError.deviceNotWritable(plan.device.mountPoint.path).localizedDescription)
            report.duration = Date().timeIntervalSince(started)
            return report
        }

        var albumsWritten = Set<AlbumKey>()

        for (i, action) in transfers.enumerated() {
            if cancelled { report.errors.append("cancelled after \(i) of \(transfers.count)"); break }

            progress(SyncProgress(
                completed: i, total: transfers.count,
                bytesWritten: report.bytesWritten, bytesTotal: bytesTotal,
                currentFile: action.destination.lastPathComponent,
                currentFileFraction: 0,
                phase: action.kind == .convert ? "converting" : "copying"))

            do {
                try fm.createDirectory(
                    at: action.destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)

                let source: URL
                if action.kind == .convert {
                    // Snapshot the byte count: the closure runs concurrently while
                    // ffmpeg reports progress, so it must not read the mutating total.
                    let bytesSoFar = report.bytesWritten
                    let label = action.destination.lastPathComponent
                    let index = i
                    source = try await Transcoder.transcodeToMP3(
                        action.track, quality: config.mp3Quality
                    ) { fraction in
                        progress(SyncProgress(
                            completed: index, total: transfers.count,
                            bytesWritten: bytesSoFar, bytesTotal: bytesTotal,
                            currentFile: label,
                            currentFileFraction: fraction, phase: "converting"))
                    }
                    report.converted += 1
                } else {
                    source = action.track.url
                    report.copied += 1
                }

                // Replace atomically-ish: remove then copy, since FAT has no atomic swap.
                if fm.fileExists(atPath: action.destination.path) {
                    try fm.removeItem(at: action.destination)
                }
                try fm.copyItem(at: source, to: action.destination)

                let written = Int64((try? action.destination.resourceValues(
                    forKeys: [.fileSizeKey]).fileSize) ?? 0)
                report.bytesWritten += written

                manifest.entries[action.destination.path] = Manifest.Stamp(
                    sourcePath: action.track.url.path,
                    sourceSize: action.track.fileSize,
                    sourceModified: action.track.modified.timeIntervalSince1970,
                    converted: action.kind == .convert,
                    quality: action.kind == .convert ? config.mp3Quality : -1
                )

                albumsWritten.insert(action.track.albumKey)
            } catch is CancellationError {
                report.errors.append("cancelled")
                break
            } catch {
                report.skipped += 1
                report.errors.append("\(action.destination.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Album art beside the tracks, sized down for the device screen.
        if config.writeDeviceArtwork, !cancelled {
            progress(SyncProgress(
                completed: transfers.count, total: transfers.count,
                bytesWritten: report.bytesWritten, bytesTotal: bytesTotal,
                currentFile: "cover.jpg", currentFileFraction: 0, phase: "artwork"))

            for key in albumsWritten {
                if cancelled { break }
                guard let dir = Self.albumDirectory(for: key, in: plan) else { continue }
                let cover = dir.appendingPathComponent("cover.jpg")
                guard !fm.fileExists(atPath: cover.path) else { continue }
                // The provider returns art already sized for the device, so the engine
                // stays free of any platform imaging framework.
                guard let data = await artworkFor(key), !data.isEmpty else { continue }
                try? data.write(to: cover, options: .atomic)
            }
        }

        // Playlists, rewritten to device-relative paths.
        if !cancelled {
            report.playlistsWritten = Self.writePlaylists(plan: plan, manifest: manifest)
        }

        if removeOrphans, !cancelled {
            for url in plan.orphans {
                progress(SyncProgress(
                    completed: transfers.count, total: transfers.count,
                    bytesWritten: report.bytesWritten, bytesTotal: bytesTotal,
                    currentFile: url.lastPathComponent, currentFileFraction: 0, phase: "removing"))
                do {
                    try fm.removeItem(at: url)
                    manifest.entries[url.path] = nil
                    report.removed += 1
                } catch {
                    report.errors.append("remove \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            Self.pruneEmptyDirectories(under: plan.device.musicDirectory)
        }

        manifest.save(device: plan.device)
        report.duration = Date().timeIntervalSince(started)
        return report
    }

    // MARK: - Destination paths

    static func albumDirectory(for key: AlbumKey, in plan: SyncPlan) -> URL? {
        plan.actions.first { $0.track.albumKey == key }?
            .destination.deletingLastPathComponent()
    }

    /// Builds `Music/<Album Artist>/<Album>/<##> <Title>.<ext>` with every component
    /// made safe for the FAT filesystem Rockbox players use.
    public static func destinationURL(
        for track: Track, device: RockboxDevice, template: String, asMP3: Bool
    ) -> URL {
        let ext = asMP3 ? "mp3" : track.url.pathExtension.lowercased()

        let albumArtist = track.albumArtist.isEmpty ? track.artist : track.albumArtist

        // Token values are sanitised *before* substitution. Doing it afterwards lets a
        // slash inside a tag ("AC/DC") split into an extra directory level on the device.
        var folder = template
            .replacingOccurrences(of: "{albumartist}", with: sanitize(albumArtist))
            .replacingOccurrences(of: "{artist}", with: sanitize(track.artist))
            .replacingOccurrences(of: "{album}", with: sanitize(track.album))
            .replacingOccurrences(of: "{year}", with: track.year.map(String.init) ?? "")
            .replacingOccurrences(of: "{genre}", with: sanitize(track.genre ?? ""))
        if folder.isEmpty { folder = "Unsorted" }

        var url = device.musicDirectory
        for component in folder.split(separator: "/") {
            url.appendPathComponent(sanitize(String(component)))
        }

        var name = ""
        if let disc = track.discNumber, disc > 1 {
            name += String(format: "%d-", disc)
        }
        if let number = track.trackNumber {
            name += String(format: "%02d ", number)
        }
        name += track.title.isEmpty ? track.url.deletingPathExtension().lastPathComponent : track.title

        return url.appendingPathComponent("\(sanitize(name)).\(ext)")
    }

    /// FAT32/exFAT reject these characters outright, and trailing dots or spaces
    /// silently corrupt names. Also caps length so deep paths stay under the limit.
    public static func sanitize(_ raw: String, maxLength: Int = 90) -> String {
        let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|\u{0}")
        var cleaned = raw.components(separatedBy: illegal).joined(separator: "_")
        cleaned = cleaned.components(separatedBy: .controlCharacters).joined()
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        while cleaned.hasSuffix(".") || cleaned.hasSuffix(" ") { cleaned.removeLast() }
        if cleaned.count > maxLength { cleaned = String(cleaned.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }

        // Names reserved by the DOS lineage FAT inherited.
        let reserved: Set<String> = [
            "CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "LPT1", "LPT2", "LPT3",
        ]
        if reserved.contains(cleaned.uppercased()) { cleaned = "_" + cleaned }

        // A name made only of replacement characters carries no information; a
        // placeholder is more useful on the device than "___".
        if cleaned.isEmpty || cleaned.allSatisfy({ $0 == "_" }) { return "Untitled" }
        return cleaned
    }

    // MARK: - Playlists

    /// Rockbox reads `.m3u8` with paths relative to the card root, written with a
    /// leading slash. We only emit entries that actually made it onto the device.
    static func writePlaylists(plan: SyncPlan, manifest: Manifest) -> Int {
        let enabled = plan.playlists.filter { $0.syncEnabled && !$0.trackPaths.isEmpty }
        guard !enabled.isEmpty else { return 0 }

        let dir = plan.device.mountPoint.appendingPathComponent("Playlists")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // source path -> device path, from what we just wrote.
        var placement: [String: String] = [:]
        for action in plan.actions {
            placement[action.track.url.path] = action.destination.path
        }

        let rootPath = plan.device.mountPoint.path
        var written = 0

        for playlist in enabled {
            var lines = ["#EXTM3U"]
            for source in playlist.trackPaths {
                guard let devicePath = placement[source],
                      FileManager.default.fileExists(atPath: devicePath) else { continue }
                var relative = devicePath.replacingOccurrences(of: rootPath, with: "")
                if !relative.hasPrefix("/") { relative = "/" + relative }
                lines.append(relative)
            }
            guard lines.count > 1 else { continue }

            let file = dir.appendingPathComponent("\(sanitize(playlist.name)).m3u8")
            if (try? lines.joined(separator: "\n").appending("\n")
                .write(to: file, atomically: true, encoding: .utf8)) != nil {
                written += 1
            }
        }
        return written
    }

    static func pruneEmptyDirectories(under root: URL) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        // Deepest first, so emptying a child lets the parent be removed too.
        let dirs = (e.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.pathComponents.count > $1.pathComponents.count }
        for dir in dirs {
            let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            let meaningful = contents.filter { $0 != ".DS_Store" }
            if meaningful.isEmpty { try? fm.removeItem(at: dir) }
        }
    }
}

// MARK: - Manifest

/// Record of what this app put on the device, stored on the device itself so the
/// pairing survives moving between machines.
public struct Manifest: Codable, Sendable {
    public struct Stamp: Codable, Equatable, Sendable {
        public var sourcePath: String
        public var sourceSize: Int64
        public var sourceModified: TimeInterval
        public var converted: Bool
        public var quality: Int

        public init(
            sourcePath: String, sourceSize: Int64, sourceModified: TimeInterval,
            converted: Bool, quality: Int
        ) {
            self.sourcePath = sourcePath
            self.sourceSize = sourceSize
            self.sourceModified = sourceModified
            self.converted = converted
            self.quality = quality
        }
    }

    public var entries: [String: Stamp] = [:]

    public init(entries: [String: Stamp] = [:]) { self.entries = entries }

    static func url(device: RockboxDevice) -> URL {
        device.mountPoint.appendingPathComponent(".deck-sync.json")
    }

    public static func load(device: RockboxDevice) -> Manifest {
        guard let data = try? Data(contentsOf: url(device: device)),
              let decoded = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return Manifest() }
        return decoded
    }

    public func save(device: RockboxDevice) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Manifest.url(device: device), options: .atomic)
    }
}

extension FileManager {
    func isWritableFilePath(_ path: String) -> Bool { isWritableFile(atPath: path) }
}

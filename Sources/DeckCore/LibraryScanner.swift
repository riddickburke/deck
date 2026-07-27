import Foundation

public struct ScanProgress: Sendable {
    public var scanned: Int
    public var total: Int
    public var currentPath: String
    public var fromCache: Int
}

/// Walks the library roots and produces tracks.
///
/// Two decisions that keep this fast on a large library:
///  - the index is cached on disk keyed by path + mtime + size, so a rescan only
///    pays ffprobe cost for files that actually changed;
///  - probing runs in a bounded task group, because spawning one ffprobe per file
///    with no limit will happily open several thousand processes at once.
public actor LibraryScanner {
    public static let maxConcurrentProbes = 8

    private var cache: [String: CachedEntry] = [:]
    private let cacheURL: URL

    struct CachedEntry: Codable {
        let modified: Date
        let size: Int64
        let track: Track
    }

    public init(cacheURL: URL = Config.appSupportDirectory.appendingPathComponent("index.json")) {
        self.cacheURL = cacheURL
    }

    public func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: CachedEntry].self, from: data)
        else { return }
        cache = decoded
    }

    public func saveCache() {
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// Replaces a cached track — used after online enrichment so repaired tags survive a restart.
    public func updateCache(_ track: Track) {
        cache[track.url.path] = CachedEntry(
            modified: track.modified, size: track.fileSize, track: track)
    }

    public func scan(
        roots: [URL],
        progress: @Sendable @escaping (ScanProgress) -> Void
    ) async -> [Track] {
        let files = Self.enumerateAudioFiles(roots: roots)
        guard !files.isEmpty else { return [] }

        var results: [Track] = []
        results.reserveCapacity(files.count)
        var scanned = 0
        var cacheHits = 0

        // Drop cache entries for files that no longer exist, so the index does not
        // grow forever as the library is reorganised.
        let livePaths = Set(files.map(\.path))
        cache = cache.filter { livePaths.contains($0.key) }

        var iterator = files.makeIterator()

        await withTaskGroup(of: Track?.self) { group in
            var inFlight = 0

            func enqueueNext() -> Bool {
                guard let url = iterator.next() else { return false }
                let cached = self.cachedTrack(for: url)
                if let cached {
                    cacheHits += 1
                    group.addTask { cached }
                } else {
                    group.addTask { await MetadataReader.read(url) }
                }
                return true
            }

            while inFlight < Self.maxConcurrentProbes, enqueueNext() { inFlight += 1 }

            while let finished = await group.next() {
                inFlight -= 1
                scanned += 1
                if let track = finished {
                    results.append(track)
                    cache[track.url.path] = CachedEntry(
                        modified: track.modified, size: track.fileSize, track: track)
                    progress(ScanProgress(
                        scanned: scanned, total: files.count,
                        currentPath: track.url.lastPathComponent, fromCache: cacheHits))
                }
                if enqueueNext() { inFlight += 1 }
            }
        }

        saveCache()
        return results
    }

    private func cachedTrack(for url: URL) -> Track? {
        guard let entry = cache[url.path],
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              size == entry.size,
              abs(modified.timeIntervalSince(entry.modified)) < 1
        else { return nil }
        return entry.track
    }

    // MARK: - Enumeration

    public nonisolated static func enumerateAudioFiles(roots: [URL]) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        let fm = FileManager.default

        for root in roots {
            guard let e = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in e {
                // Never walk into an iTunes/Music .musiclibrary package or our own
                // transcode cache — both are full of files we would misread as library content.
                let name = url.lastPathComponent
                if name.hasSuffix(".musiclibrary") || name == "Automatically Add to Music.localized" {
                    e.skipDescendants()
                    continue
                }
                guard MetadataReader.isAudioFile(url) else { continue }
                let resolved = url.resolvingSymlinksInPath().path
                if seen.insert(resolved).inserted { found.append(url) }
            }
        }
        return found.sorted { $0.path < $1.path }
    }
}

// MARK: - Grouping

public enum LibraryGrouping {
    public static func albums(from tracks: [Track]) -> [Album] {
        Dictionary(grouping: tracks, by: \.albumKey)
            .map { Album(key: $0.key, tracks: $0.value) }
            .sorted {
                let a = $0.artist.localizedStandardCompare($1.artist)
                if a != .orderedSame { return a == .orderedAscending }
                // Within an artist, oldest release first reads more naturally than A-Z.
                if let y0 = $0.year, let y1 = $1.year, y0 != y1 { return y0 < y1 }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    public static func artists(from albums: [Album]) -> [String] {
        Array(Set(albums.map(\.artist)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

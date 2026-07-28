import DeckCore
import Foundation

enum DeckVersion {
    static let current = "1.3.0"
}

/// Console diagnostics for `deck --scan`. Reports aggregate counts only — it never
/// prints the library's contents.
enum HeadlessScan {
    static func run() -> Never {
        // Line-buffer, otherwise nothing appears until exit when stdout is a pipe.
        setvbuf(stdout, nil, _IOLBF, 0)
        Config.migrateLegacyDataIfNeeded()
        let config = Config.load()

        print("deck \(DeckVersion.current) — library scan")
        print("  config:  \(Config.configURL.path)")
        print("  ffprobe: \(Shell.which("ffprobe")?.path ?? "NOT FOUND")")
        print("  ffmpeg:  \(Shell.which("ffmpeg")?.path ?? "NOT FOUND")")
        print("  mpv:     \(Shell.which("mpv")?.path ?? "NOT FOUND")")

        guard !config.rootURLs.isEmpty else {
            print("\n  no library folders configured.")
            exit(1)
        }

        for root in config.rootURLs {
            let exists = FileManager.default.fileExists(atPath: root.path)
            let readable = FileManager.default.isReadableFile(atPath: root.path)
            print("\n  root: \(root.path)")
            print("    exists: \(exists)   readable: \(readable)")
            print("    audio files: \(LibraryScanner.enumerateAudioFiles(roots: [root]).count)")
        }

        let all = LibraryScanner.enumerateAudioFiles(roots: config.rootURLs)
        guard !all.isEmpty else {
            print("\n  nothing to index.")
            exit(1)
        }

        print("\n  indexing \(all.count) files…")
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var tracks: [Track] = []
        nonisolated(unsafe) var lastReport = 0

        Task.detached(priority: .userInitiated) {
            let scanner = LibraryScanner()
            await scanner.loadCache()
            tracks = await scanner.scan(roots: config.rootURLs) { progress in
                if progress.scanned - lastReport >= 250 || progress.scanned == progress.total {
                    lastReport = progress.scanned
                    print("    \(progress.scanned)/\(progress.total) (\(progress.fromCache) cached)")
                }
            }
            semaphore.signal()
        }
        semaphore.wait()

        let albums = LibraryGrouping.albums(from: tracks)
        let missing = tracks.count { $0.needsMetadata }
        let totalBytes = tracks.reduce(Int64(0)) { $0 + $1.fileSize }

        print("\n  tracks:  \(tracks.count)")
        print("  albums:  \(albums.count)")
        print("  artists: \(LibraryGrouping.artists(from: albums).count)")
        print("  size:    \(totalBytes.byteString)")
        print("  missing tags: \(missing)")
        exit(0)
    }
}

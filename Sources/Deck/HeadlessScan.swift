import DeckCore
import Foundation

/// Console diagnostics for `deck --scan`. Reports aggregate counts only — it never
/// prints the library's contents.
enum HeadlessScan {
    static func run() -> Never {
        // Line-buffer, otherwise nothing appears until exit when stdout is a pipe.
        setvbuf(stdout, nil, _IOLBF, 0)
        Config.migrateLegacyDataIfNeeded()
        let config = Config.load()

        print("deck — library scan")
        print("  config:  \(Config.configURL.path)")
        print("  ffprobe: \(Shell.which("ffprobe")?.path ?? "NOT FOUND (brew install ffmpeg)")")
        print("  ffmpeg:  \(Shell.which("ffmpeg")?.path ?? "NOT FOUND (brew install ffmpeg)")")

        guard !config.rootURLs.isEmpty else {
            print("\n  no library folders configured.")
            exit(1)
        }

        for root in config.rootURLs {
            let exists = FileManager.default.fileExists(atPath: root.path)
            let readable = FileManager.default.isReadableFile(atPath: root.path)
            print("\n  root: \(root.path)")
            print("    exists: \(exists)   readable: \(readable)")

            let files = LibraryScanner.enumerateAudioFiles(roots: [root])
            print("    audio files found: \(files.count)")

            if files.isEmpty, exists, readable {
                // Distinguish "empty of music" from "we were denied access".
                let entries = (try? FileManager.default
                    .contentsOfDirectory(atPath: root.path).count) ?? -1
                print("    entries visible at top level: \(entries)")
                if entries <= 0 {
                    print("    → the folder reads as empty. this is usually macOS privacy")
                    print("      blocking access. grant Deck access under System Settings →")
                    print("      Privacy & Security → Files and Folders (or Full Disk Access).")
                }
            }
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

        // Must be detached: this runs from App.init, which is main-actor isolated, so a
        // plain Task would inherit that isolation and deadlock against the wait below.
        Task.detached(priority: .userInitiated) {
            let scanner = LibraryScanner()
            await scanner.loadCache()
            tracks = await scanner.scan(roots: config.rootURLs) { progress in
                // Report every 250 files so a long scan visibly moves.
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
        let codecs = Dictionary(grouping: tracks, by: \.codec)
            .mapValues(\.count)
            .sorted { $0.value > $1.value }

        print("\n  tracks:  \(tracks.count)")
        print("  albums:  \(albums.count)")
        print("  artists: \(LibraryGrouping.artists(from: albums).count)")
        print("  size:    \(totalBytes.byteString)")
        print("  missing tags: \(missing)")
        print("  formats: " + codecs.prefix(8).map { "\($0.key)×\($0.value)" }.joined(separator: " "))
        print("\n  index written to \(Config.appSupportDirectory.path)/index.json")
        exit(0)
    }
}

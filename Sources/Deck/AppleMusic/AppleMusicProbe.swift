import DeckCore
import Foundation

/// Console check for `deck --apple-music`. Imports the Music.app library and reports
/// aggregate counts, so the Apple Events path can be verified without the UI.
enum AppleMusicProbe {
    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var exitCode: Int32 = 0

        // Detached: this is called from App.init, which is main-actor isolated, and a
        // plain Task would deadlock against the wait below.
        Task.detached(priority: .userInitiated) {
            print("deck — Apple Music library")

            switch await AppleMusicRemote.probe() {
            case .success(let version):
                print("  Music.app: \(version)")
            case .failure(let error):
                print("  Music.app: unreachable — \(error.localizedDescription)")
                exitCode = 1
                semaphore.signal()
                return
            }

            let started = Date()
            do {
                let tracks = try await AppleMusicLibrary.importLibrary()
                let elapsed = Date().timeIntervalSince(started)

                let albums = LibraryGrouping.albums(from: tracks)
                let cloud = tracks.count { AppleMusicLibrary.isCloudBacked($0) }
                let withNumbers = tracks.count { $0.trackNumber != nil }
                let withYears = tracks.count { $0.year != nil }
                let unknownTitles = tracks.count { $0.title == Track.unknown }

                print(String(format: "  imported %d tracks in %.2fs", tracks.count, elapsed))
                print("  albums:    \(albums.count)")
                print("  artists:   \(LibraryGrouping.artists(from: albums).count)")
                print("  cloud-backed: \(cloud)   plain files: \(tracks.count - cloud)")
                print("  parsed track numbers: \(withNumbers)   years: \(withYears)")

                let byStatus = Dictionary(grouping: tracks, by: \.codec)
                    .mapValues(\.count).sorted { $0.value > $1.value }
                print("  cloud status: " + byStatus.map { "\($0.key)=\($0.value)" }
                    .joined(separator: " "))
                if unknownTitles > 0 { print("  !! untitled after parse: \(unknownTitles)") }

                print("\n  sample:")
                for album in albums.prefix(5) {
                    let flag = album.tracks.first.map(\.codec) ?? "?"
                    print("    [\(flag)] \(album.title) — \(album.artist) (\(album.tracks.count))")
                }

                // Artwork is fetched per track and is the slowest part, so measure one.
                if let first = tracks.first(where: { AppleMusicLibrary.isCloudBacked($0) }),
                   let id = first.externalID {
                    let artStart = Date()
                    let data = await AppleMusicLibrary.artwork(forTrackID: id)
                    let artElapsed = Date().timeIntervalSince(artStart)
                    print(String(
                        format: "\n  artwork for a streaming track: %@ in %.2fs",
                        data.map { "\($0.count) bytes" } ?? "unavailable", artElapsed))
                }
            } catch {
                print("  import failed: \(error.localizedDescription)")
                exitCode = 1
            }
            semaphore.signal()
        }

        semaphore.wait()
        exit(exitCode)
    }
}

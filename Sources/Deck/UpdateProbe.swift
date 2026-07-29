import DeckCore
import Foundation

/// Console update check for `deck --check-update`.
///
/// Exists for two reasons. It is the only way to exercise the live GitHub request
/// without a window and a mouse — the parser is unit tested against captured payloads,
/// but that says nothing about whether the request itself is well formed. And it gives
/// anyone running Deck without the settings pane, or from a terminal, a way to ask.
///
/// Prints the release and version only. Nothing about the user's library is involved.
enum UpdateProbe {
    static func run() {
        // Line buffering, or nothing appears until the process exits when stdout is a pipe.
        setvbuf(stdout, nil, _IOLBF, 0)

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        // Detached: `App.init` runs on the main actor, so an inherited-context Task would
        // deadlock against the semaphore this thread is about to wait on.
        Task.detached {
            let current = Updater.currentVersion
            print("deck \(current)")

            switch await UpdateChecker.check(current: current) {
            case .failure(let error):
                print("  error: \(error.errorDescription ?? "check failed")")
                exitCode = 1

            case .success(.upToDate(let version)):
                print("  up to date (latest release is \(version))")

            case .success(.available(let update)):
                print("  update available: \(update.version) · \(update.sizeInBytes.byteString)")
                print("  \(update.pageURL.absoluteString)")
                if !update.notes.isEmpty {
                    print("")
                    for line in update.notes.split(separator: "\n").prefix(20) {
                        print("  \(line)")
                    }
                }

            case .success(.newerReleaseWithoutDownload(let version, let page)):
                print("  \(version) is out, but that release has no macOS build")
                print("  \(page.absoluteString)")
            }
            semaphore.signal()
        }

        semaphore.wait()
        exit(exitCode)
    }
}

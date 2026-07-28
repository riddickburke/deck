import DeckCore
import Foundation

/// Runs AppleScript against Music.app.
///
/// Deliberately via `osascript` rather than NSAppleScript. NSAppleScript must be driven
/// from the main thread and blocks it for the duration — a full library read would
/// freeze the UI. Spawning osascript costs about 50ms, which is irrelevant next to the
/// Apple Event round trip, and it runs happily off the main thread.
enum AppleEvents {
    /// Field and record separators. ASCII unit/record separators cannot occur in track
    /// metadata, so no escaping is needed and no title can corrupt the parse.
    static let fieldSeparator = "\u{1F}"
    static let recordSeparator = "\u{1E}"

    enum Failure: LocalizedError {
        case notInstalled
        case permissionDenied
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Music.app was not found"
            case .permissionDenied:
                return "Deck needs permission to control Music. Grant it under System "
                    + "Settings → Privacy & Security → Automation."
            case .failed(let message):
                return message
            }
        }
    }

    static var isMusicInstalled: Bool {
        FileManager.default.fileExists(atPath: "/System/Applications/Music.app")
            || FileManager.default.fileExists(atPath: "/Applications/Music.app")
    }

    @discardableResult
    static func run(_ script: String) async throws -> String {
        guard isMusicInstalled else { throw Failure.notInstalled }

        let result = try await Shell.run("osascript", ["-e", script])
        guard result.ok else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            // -1743 is "not authorised to send Apple events", the TCC denial.
            if message.contains("-1743") || message.lowercased().contains("not authori") {
                throw Failure.permissionDenied
            }
            throw Failure.failed(message.isEmpty ? "osascript failed" : message)
        }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a script and ignores any failure. For fire-and-forget transport commands
    /// where a thrown error would be noise.
    static func runIgnoringErrors(_ script: String) async {
        _ = try? await run(script)
    }

    /// Wraps a body in `tell application "Music"`.
    static func music(_ body: String) -> String {
        """
        tell application "Music"
        \(body)
        end tell
        """
    }
}

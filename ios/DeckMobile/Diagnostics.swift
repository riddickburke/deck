import Foundation
import os

/// Diagnostic logging for the parts of this app that cannot be tested off-device.
///
/// The media library only exists on real hardware — a simulator returns an empty
/// `MPMediaQuery` no matter what — so the usual loop of running locally and watching
/// does not apply.
///
/// Messages go to the unified log *and* to a file in the app's Documents directory.
/// The file exists because `log stream --device` was removed in macOS 26 and devicectl
/// has no console subcommand, leaving no way to read a device's unified log from a
/// script; the container file can be pulled back with `devicectl device copy from`.
///
/// Reports counts and outcomes only. It never records a title, artist, album or file
/// path: this file can be copied off the device by anything with it attached, and the
/// contents of someone's music library are not ours to spill into it.
enum Log {
    static let library = Category(name: "library")
    static let playback = Category(name: "playback")
    static let artwork = Category(name: "artwork")

    struct Category: Sendable {
        let name: String
        private var logger: Logger { Logger(subsystem: "com.riddickburke.deckmobile", category: name) }

        func notice(_ message: String) {
            logger.notice("\(message, privacy: .public)")
            DiagnosticsFile.shared.append("[\(name)] \(message)")
        }

        func error(_ message: String) {
            logger.error("\(message, privacy: .public)")
            DiagnosticsFile.shared.append("[\(name)] ERROR \(message)")
        }
    }

    /// Path shown in Settings, so the file can be found without a Mac.
    static var fileURL: URL { DiagnosticsFile.shared.url }

    static func readAll() -> String {
        (try? String(contentsOf: DiagnosticsFile.shared.url, encoding: .utf8)) ?? "(empty)"
    }

    static func clear() { DiagnosticsFile.shared.clear() }
}

/// Counts what the artwork views actually did.
///
/// Per-cell logging would write a line per row per scroll, so this aggregates and emits
/// a single summary shortly after the first load. The question it answers is narrow but
/// was not otherwise answerable: the data layer resolves artwork fine, so if the views
/// show none, either they are asking with no id, being cancelled, or never running.
@MainActor
enum ArtworkProbe {
    enum Outcome { case loaded, nilImage, nilID, cancelled }

    private static var counts: [String: Int] = [:]
    private static var scheduled = false

    static func record(_ outcome: Outcome, size: CGFloat) {
        let key: String
        switch outcome {
        case .loaded: key = "loaded"
        case .nilImage: key = "nil image"
        case .nilID: key = "nil id"
        case .cancelled: key = "cancelled"
        }
        counts["\(key)@\(Int(size))pt", default: 0] += 1

        guard !scheduled else { return }
        scheduled = true
        Task {
            // Long enough for a screen's worth of cells to settle.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let summary = counts.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            Log.artwork.notice("views: \(summary.isEmpty ? "no attempts" : summary)")
            scheduled = false
            counts.removeAll()
        }
    }
}

/// Append-only text file, truncated at launch so it reflects one session rather than
/// growing without bound.
final class DiagnosticsFile: @unchecked Sendable {
    static let shared = DiagnosticsFile()

    let url: URL
    private let queue = DispatchQueue(label: "deck.diagnostics")
    private let formatter: DateFormatter

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = documents.appendingPathComponent("deck-diagnostics.txt")

        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        try? "deck diagnostics — session started \(Date())\n".write(
            to: url, atomically: true, encoding: .utf8)
    }

    func append(_ line: String) {
        let stamped = "\(formatter.string(from: Date()))  \(line)\n"
        queue.async { [url] in
            guard let data = stamped.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? stamped.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    func clear() {
        queue.async { [url] in
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

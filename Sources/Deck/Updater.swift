import AppKit
import CryptoKit
import DeckCore
import Foundation

/// Downloads a release and installs it over the running app.
///
/// The manual route is worse than it sounds. Because the app is ad-hoc signed rather
/// than notarised, a DMG fetched in a browser arrives with a quarantine flag, Gatekeeper
/// refuses to open what comes out of it, and the fix is a `xattr -dr` in Terminal — every
/// time, on every machine. Downloading through URLSession sidesteps that entirely:
/// quarantine is applied by the downloading application, and nothing here sets it. The
/// installed copy launches normally.
@MainActor
final class Updater: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case upToDate(Version)
        case available(UpdateChecker.Update)
        /// 0...1
        case downloading(UpdateChecker.Update, Double)
        case installing(UpdateChecker.Update)
        /// The swap runs after this process exits, so this is the last state seen.
        case readyToRestart
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// What is running, from the bundle rather than a constant, so it cannot drift from
    /// what was actually shipped.
    ///
    /// `nonisolated` because reading Info.plist touches nothing main-actor bound, and the
    /// headless `--check-update` path needs it from off the main actor.
    nonisolated static var currentVersion: Version {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return raw.flatMap(Version.init) ?? Version(major: 0, minor: 0, patch: 0)
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    // MARK: - Check

    func check() {
        guard !isBusy else { return }
        state = .checking

        Task {
            let current = Self.currentVersion
            switch await UpdateChecker.check(current: current) {
            case .failure(let error):
                state = .failed(error.errorDescription ?? "check failed")

            case .success(.upToDate(let version)):
                state = .upToDate(version)

            case .success(.available(let update)):
                state = .available(update)

            case .success(.newerReleaseWithoutDownload(let version, _)):
                state = .failed("\(version) is out, but that release has no macOS build")
            }
        }
    }

    // MARK: - Install

    func downloadAndInstall(_ update: UpdateChecker.Update) {
        guard !isBusy else { return }

        // Checked before downloading anything: finding out the app cannot be replaced
        // after pulling down a disk image wastes the user's time and bandwidth.
        guard let target = Self.installedAppURL() else {
            state = .failed("cannot find the running app bundle")
            return
        }
        guard Self.isReplaceable(target) else {
            state = .failed(
                "\(target.path) is not writable — move Deck to /Applications, or update by hand")
            return
        }

        state = .downloading(update, 0)

        Task {
            do {
                let dmg = try await download(update)
                defer { try? FileManager.default.removeItem(at: dmg) }

                try await verify(dmg, update: update)

                state = .installing(update)
                let staged = try await extractApp(from: dmg)

                try Self.scheduleSwap(from: staged, to: target)
                state = .readyToRestart

                // Give the UI a moment to show the message before the app goes away.
                try? await Task.sleep(nanoseconds: 900_000_000)
                NSApplication.shared.terminate(nil)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Steps

    private func download(_ update: UpdateChecker.Update) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: update.downloadURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.message("download failed with HTTP \(http.statusCode)")
        }

        let expected = response.expectedContentLength > 0
            ? response.expectedContentLength : update.sizeInBytes
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-update-\(update.version).dmg")
        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path, contents: nil)

        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw UpdateError.message("could not write to the temporary directory")
        }
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var written: Int64 = 0
        var lastReported = 0.0

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                let fraction = expected > 0 ? Double(written) / Double(expected) : 0
                // Republishing per chunk would drive a SwiftUI update thousands of times
                // for a progress bar a few hundred points wide.
                if fraction - lastReported > 0.01 {
                    lastReported = fraction
                    state = .downloading(update, min(fraction, 1))
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        state = .downloading(update, 1)

        guard written > 0 else { throw UpdateError.message("downloaded nothing") }
        return destination
    }

    /// Checks the disk image against the release's own `SHA256SUMS`.
    ///
    /// This is about to replace the running application, which is the one moment where
    /// silently installing a truncated or tampered download is unacceptable. If the
    /// release publishes no checksums the download still proceeds — refusing would make
    /// the updater useless against older releases — but a mismatch always stops it.
    private func verify(_ dmg: URL, update: UpdateChecker.Update) async throws {
        guard let checksumsURL = update.checksumsURL else { return }

        guard let (data, _) = try? await URLSession.shared.data(from: checksumsURL),
              let text = String(data: data, encoding: .utf8)
        else { return }

        let fileName = update.downloadURL.lastPathComponent
        guard let expected = UpdateChecker.expectedDigest(for: fileName, in: text) else { return }

        let digest = try Self.sha256(of: dmg)
        guard digest == expected else {
            throw UpdateError.message(
                "checksum mismatch — the download does not match the release, so it was discarded")
        }
    }

    /// Mounts the image, copies the app out, unmounts.
    private func extractApp(from dmg: URL) async throws -> URL {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-update-mount-\(UUID().uuidString)")

        // `-nobrowse` keeps it out of Finder; `-readonly` avoids any chance of writing
        // back to the image we just verified.
        let attach = try await Shell.run("/usr/bin/hdiutil", [
            "attach", dmg.path, "-nobrowse", "-readonly", "-noverify",
            "-mountpoint", mountPoint.path,
        ])
        guard attach.ok else {
            throw UpdateError.message("could not open the disk image")
        }
        // Always detached, including on the failure paths below.
        defer {
            Task { _ = try? await Shell.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }
        }

        let source = mountPoint.appendingPathComponent("Deck.app")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw UpdateError.message("the disk image does not contain Deck.app")
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-update-staged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("Deck.app")

        // `ditto` rather than copyItem: it preserves the bundle's symlinks, extended
        // attributes and the code signature, which a naive copy can quietly break.
        let copy = try await Shell.run("/usr/bin/ditto", [source.path, staged.path])
        guard copy.ok else {
            throw UpdateError.message("could not copy the new version out of the image")
        }
        return staged
    }

    // MARK: Helpers

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The `.app` bundle this process is running from, or nil when running loose (from
    /// `swift run`, say) where there is nothing to replace.
    static func installedAppURL() -> URL? {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" ? bundle : nil
    }

    /// Can we actually replace it? The *parent* directory has to be writable, since the
    /// swap moves the bundle aside rather than writing through it.
    static func isReplaceable(_ app: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    /// Writes and launches the script that swaps the bundle once this process is gone.
    ///
    /// It cannot be done in-process: the running executable is inside the bundle being
    /// replaced. The script waits for this pid to disappear, then moves the old bundle
    /// aside before putting the new one in place — and puts the old one back if the move
    /// fails, so a failure halfway leaves a working app rather than none.
    static func scheduleSwap(from staged: URL, to target: URL) throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-update-\(UUID().uuidString).sh")

        let body = """
        #!/bin/bash
        set -u
        PID=\(ProcessInfo.processInfo.processIdentifier)
        STAGED=\(shellQuote(staged.path))
        TARGET=\(shellQuote(target.path))
        STAGING_ROOT=\(shellQuote(staged.deletingLastPathComponent().path))

        # Wait for Deck to exit, but never forever — if it hangs, leave everything alone.
        for _ in $(seq 1 300); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.2
        done
        if kill -0 "$PID" 2>/dev/null; then
            rm -rf "$STAGING_ROOT"
            exit 1
        fi

        BACKUP="$TARGET.old-$$"
        if mv "$TARGET" "$BACKUP" 2>/dev/null; then
            if mv "$STAGED" "$TARGET" 2>/dev/null; then
                rm -rf "$BACKUP"
            else
                # Put the working copy back rather than leaving no app at all.
                mv "$BACKUP" "$TARGET"
                rm -rf "$STAGING_ROOT"
                exit 1
            fi
        else
            rm -rf "$STAGING_ROOT"
            exit 1
        fi

        rm -rf "$STAGING_ROOT"
        open "$TARGET"
        rm -f "$0"
        """

        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        // Detached from our process group, so it survives this app terminating.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

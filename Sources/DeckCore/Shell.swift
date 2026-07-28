import Dispatch
import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String
    public var ok: Bool { status == 0 }
    public var text: String { String(decoding: stdout, as: UTF8.self) }
}

public enum ShellError: LocalizedError {
    case notFound(String)
    case failed(String, Int32, String)
    case launchFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let tool):
            return "\(tool) not found. Install it with: brew install \(tool.hasPrefix("ff") ? "ffmpeg" : tool)"
        case .failed(let tool, let code, let err):
            let trimmed = err.split(separator: "\n").suffix(3).joined(separator: " ")
            return "\(tool) exited \(code): \(trimmed)"
        case .launchFailed(let tool, let reason):
            return "could not launch \(tool): \(reason)"
        }
    }
}

/// Minimal async wrapper around Process. Everything external (ffmpeg/ffprobe) goes
/// through here so tool discovery and failure reporting live in exactly one place.
///
/// The important detail: this never calls `Process.waitUntilExit()`. That method spins a
/// run loop and blocks the calling thread, and when it is called from an async context it
/// blocks a thread in Swift's *cooperative* pool — which has only as many threads as the
/// machine has cores. Run a handful of probes concurrently and the pool starves: no task
/// can make progress, the pipe readers never drain, the child blocks writing to a full
/// pipe, and nothing ever exits. Completion is delivered through `terminationHandler`
/// instead, and the pipes are drained on regular dispatch queues that can grow on demand.
public enum Shell {
    /// Homebrew on Apple Silicon and Intel, plus the standard locations. We resolve
    /// explicitly rather than relying on PATH, because a GUI .app does not inherit the
    /// user's shell PATH.
    static let searchPaths = [
        // macOS: Homebrew on Apple Silicon and Intel, then MacPorts.
        "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
        // Linux distributions, plus Nix and Flatpak layouts.
        "/usr/bin", "/bin", "/usr/local/sbin", "/usr/sbin",
        "/var/lib/flatpak/exports/bin", "/run/current-system/sw/bin",
        "/snap/bin",
    ]

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: URL] = [:]

    /// Pipe draining happens here rather than on the cooperative pool.
    private static let ioQueue = DispatchQueue(
        label: "com.riddickburke.deck.shell.io", qos: .userInitiated, attributes: .concurrent)

    public static func which(_ tool: String) -> URL? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[tool] { return hit }
        for dir in searchPaths {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                cache[tool] = candidate
                return candidate
            }
        }
        return nil
    }

    public static func has(_ tool: String) -> Bool { which(tool) != nil }

    /// Runs `tool`, optionally feeding `input` to its stdin.
    ///
    /// stdin is written on its own queue while stdout and stderr are being drained.
    /// Doing it inline would deadlock as soon as the input exceeds one pipe buffer:
    /// we would block writing while the child blocks writing output nobody is reading.
    @discardableResult
    public static func run(
        _ tool: String,
        _ args: [String],
        input: Data? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ShellResult {
        guard let exe = which(tool) else { throw ShellError.notFound(tool) }

        let handle = ProcessHandle()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumer = Resumer(continuation)

                let process = Process()
                process.executableURL = exe
                process.arguments = args

                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                let inPipe: Pipe?
                if input != nil {
                    let pipe = Pipe()
                    inPipe = pipe
                    process.standardInput = pipe
                } else {
                    inPipe = nil
                    // Without this a child that reads stdin inherits ours and can hang.
                    process.standardInput = FileHandle.nullDevice
                }

                let collected = Collected()
                let group = DispatchGroup()

                if let inPipe, let input {
                    ioQueue.async {
                        let writer = inPipe.fileHandleForWriting
                        // A child that exits early (ffmpeg rejecting the input) leaves us
                        // writing to a closed pipe; SIGPIPE would kill this process, so
                        // the failure has to be swallowed rather than propagated.
                        if !input.isEmpty {
                            try? writer.write(contentsOf: input)
                        }
                        try? writer.close()
                    }
                }

                group.enter()
                ioQueue.async {
                    let data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                    collected.setStdout(data)
                    group.leave()
                }

                group.enter()
                ioQueue.async {
                    var accumulated = Data()
                    var pending = ""
                    let reader = errPipe.fileHandleForReading
                    while true {
                        let chunk = reader.availableData
                        if chunk.isEmpty { break }
                        accumulated.append(chunk)
                        guard let onStderrLine else { continue }
                        pending += String(decoding: chunk, as: UTF8.self)
                        // ffmpeg writes progress with \r, not \n.
                        let parts = pending.components(
                            separatedBy: CharacterSet(charactersIn: "\r\n"))
                        for line in parts.dropLast() where !line.isEmpty { onStderrLine(line) }
                        pending = parts.last ?? ""
                    }
                    collected.setStderr(String(decoding: accumulated, as: UTF8.self))
                    group.leave()
                }

                process.terminationHandler = { finished in
                    // Wait for both pipes to reach EOF so the captured output is complete.
                    group.notify(queue: ioQueue) {
                        resumer.finish(.success(ShellResult(
                            status: finished.terminationStatus,
                            stdout: collected.stdout,
                            stderr: collected.stderr)))
                    }
                }

                handle.adopt(process)

                do {
                    try process.run()
                } catch {
                    // The child never started, so terminationHandler will not fire.
                    // Close the write ends or the readers above would block forever.
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    resumer.finish(.failure(
                        ShellError.launchFailed(tool, error.localizedDescription)))
                }
            }
        } onCancel: {
            handle.terminate()
        }
    }

    /// Runs and throws unless the exit status is zero.
    @discardableResult
    public static func runChecked(
        _ tool: String,
        _ args: [String],
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ShellResult {
        let r = try await run(tool, args, onStderrLine: onStderrLine)
        guard r.ok else { throw ShellError.failed(tool, r.status, r.stderr) }
        return r
    }

    /// Convenience for filters that read stdin and write stdout, such as ffmpeg
    /// operating on image bytes we already hold in memory.
    @discardableResult
    public static func runWithInput(
        _ tool: String,
        _ args: [String],
        input: Data
    ) async throws -> ShellResult {
        try await run(tool, args, input: input)
    }
}

// MARK: - Supporting boxes

/// Guarantees the continuation is resumed exactly once, whichever path gets there first.
private final class Resumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ShellResult, Error>?

    init(_ continuation: CheckedContinuation<ShellResult, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<ShellResult, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// Output accumulated from two concurrent readers.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var _stdout = Data()
    private var _stderr = ""

    var stdout: Data { lock.lock(); defer { lock.unlock() }; return _stdout }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return _stderr }

    func setStdout(_ data: Data) { lock.lock(); _stdout = data; lock.unlock() }
    func setStderr(_ text: String) { lock.lock(); _stderr = text; lock.unlock() }
}

/// Lets the cancellation handler reach a process that may not exist yet.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func adopt(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldStop = cancelled
        lock.unlock()
        if shouldStop, process.isRunning { process.terminate() }
    }

    func terminate() {
        lock.lock()
        cancelled = true
        let target = process
        lock.unlock()
        if let target, target.isRunning { target.terminate() }
    }
}

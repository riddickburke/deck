import Foundation

#if canImport(Glibc)
import Glibc

/// Linux playback, driven by an mpv process over its JSON IPC socket.
///
/// mpv rather than raw ALSA/PipeWire because it already solves everything the
/// AVAudioEngine build gets for free on macOS: every codec Rockbox users actually have
/// (FLAC, Opus, Ogg, ALAC, WavPack), gapless album playback, accurate seeking, ReplayGain
/// and an equaliser. Writing that against a bare audio device would be a project in itself.
///
/// IPC rather than linking libmpv because it needs no extra `-dev` package at build time
/// and no C interop, and a crashed mpv cannot take the UI down with it.
public actor MPVPlayer {
    public struct State: Sendable, Equatable {
        public var isPlaying = false
        public var position: TimeInterval = 0
        public var duration: TimeInterval = 0
        public var currentPath: String?
        public var idle = true
    }

    private var process: Process?
    private var socketPath: String
    private var socketFD: Int32 = -1
    private var requestID = 0
    private var readBuffer = Data()

    public private(set) var state = State()

    public init() {
        socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-mpv-\(getpid()).sock").path
    }

    deinit {
        if socketFD >= 0 { close(socketFD) }
        process?.terminate()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    public static var isAvailable: Bool { Shell.has("mpv") }

    // MARK: - Lifecycle

    /// Starts mpv idle, with video disabled and the IPC socket open. Safe to call twice.
    public func start() throws {
        guard process == nil else { return }
        guard let mpv = Shell.which("mpv") else { throw ShellError.notFound("mpv") }

        try? FileManager.default.removeItem(atPath: socketPath)

        let task = Process()
        task.executableURL = mpv
        task.arguments = [
            "--idle=yes",
            "--no-video",
            "--no-terminal",
            "--no-config",
            // Gapless, matching the macOS engine's pre-scheduling behaviour.
            "--gapless-audio=yes",
            "--audio-display=no",
            "--keep-open=no",
            "--input-ipc-server=\(socketPath)",
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice

        try task.run()
        process = task

        try connect()
    }

    /// mpv creates the socket a moment after launch, so the connect is retried briefly
    /// rather than assuming it is ready.
    private func connect() throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath), openSocket() {
                return
            }
            usleep(50_000)
        }
        throw ShellError.launchFailed("mpv", "IPC socket did not appear at \(socketPath)")
    }

    private func openSocket() -> Bool {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(fd, $0, size)
            }
        }
        guard result == 0 else { close(fd); return false }

        socketFD = fd
        return true
    }

    public func shutdown() {
        _ = try? command(["quit"])
        if socketFD >= 0 { close(socketFD); socketFD = -1 }
        process?.terminate()
        process = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - Transport

    public func load(path: String, startAt offset: TimeInterval = 0) throws {
        try start()
        _ = try command(["loadfile", path, "replace"])
        if offset > 0 {
            _ = try? command(["seek", String(offset), "absolute"])
        }
        _ = try? setProperty("pause", false)
        state.currentPath = path
        state.isPlaying = true
    }

    /// Queues a file to play immediately after the current one, which is how gapless
    /// album playback is achieved without re-loading between tracks.
    public func appendNext(path: String) throws {
        try start()
        _ = try command(["loadfile", path, "append"])
    }

    public func clearQueue() {
        _ = try? command(["playlist-clear"])
    }

    public func play() throws {
        try start()
        _ = try setProperty("pause", false)
        state.isPlaying = true
    }

    public func pause() {
        _ = try? setProperty("pause", true)
        state.isPlaying = false
    }

    public func togglePause() throws {
        state.isPlaying ? pause() : try play()
    }

    public func seek(to seconds: TimeInterval) {
        _ = try? command(["seek", String(seconds), "absolute"])
        state.position = seconds
    }

    public func seekRelative(_ delta: TimeInterval) {
        _ = try? command(["seek", String(delta), "relative"])
    }

    /// 0...1, mapped onto mpv's 0...100 scale.
    public func setVolume(_ volume: Float) {
        _ = try? setProperty("volume", Double(max(0, min(1, volume)) * 100))
    }

    /// Ten bands of gain in dB, applied through mpv's lavfi equalizer chain.
    public func setEqualizer(gains: [Float], frequencies: [Float]) {
        guard gains.count == frequencies.count else { return }
        let active = zip(frequencies, gains).filter { abs($0.1) > 0.01 }
        guard !active.isEmpty else {
            _ = try? command(["af", "set", ""])
            return
        }
        let chain = active
            .map { "equalizer=f=\(Int($0.0)):width_type=o:width=2:g=\(String(format: "%.1f", $0.1))" }
            .joined(separator: ",")
        _ = try? command(["af", "set", "lavfi=[\(chain)]"])
    }

    /// Polls the properties the UI needs. Called on a timer by the front end.
    @discardableResult
    public func refreshState() -> State {
        if let value = try? getProperty("time-pos"), let seconds = value as? Double {
            state.position = seconds
        }
        if let value = try? getProperty("duration"), let seconds = value as? Double {
            state.duration = seconds
        }
        if let value = try? getProperty("pause"), let paused = value as? Bool {
            state.isPlaying = !paused
        }
        if let value = try? getProperty("idle-active"), let idle = value as? Bool {
            state.idle = idle
        }
        if let value = try? getProperty("path"), let path = value as? String {
            state.currentPath = path
        }
        return state
    }

    /// True once mpv has run out of queued files, so the caller can advance the queue.
    public func hasFinished() -> Bool {
        refreshState().idle
    }

    // MARK: - IPC

    private func setProperty(_ name: String, _ value: Any) throws -> Any? {
        try command(["set_property", name, value])
    }

    private func getProperty(_ name: String) throws -> Any? {
        try command(["get_property", name])
    }

    /// Sends one command and reads until its matching reply arrives.
    ///
    /// mpv interleaves unsolicited event messages with command replies on the same
    /// socket, so replies are matched on request_id rather than assuming the next line
    /// belongs to us.
    @discardableResult
    private func command(_ parts: [Any]) throws -> Any? {
        guard socketFD >= 0 else { throw ShellError.launchFailed("mpv", "IPC socket not open") }

        requestID += 1
        let id = requestID
        let payload: [String: Any] = ["command": parts, "request_id": id]

        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        data.append(0x0A)

        try data.withUnsafeBytes { raw -> Void in
            var sent = 0
            while sent < raw.count {
                let n = send(socketFD, raw.baseAddress!.advanced(by: sent), raw.count - sent, Int32(MSG_NOSIGNAL))
                guard n > 0 else {
                    throw ShellError.launchFailed("mpv", "IPC write failed")
                }
                sent += n
            }
        }

        return try awaitReply(id: id)
    }

    private func awaitReply(id: Int) throws -> Any? {
        let deadline = Date().addingTimeInterval(2)

        while Date() < deadline {
            while let line = nextLine() {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { continue }
                // Events have no request_id; skip them.
                guard let replyID = object["request_id"] as? Int, replyID == id else { continue }
                guard (object["error"] as? String) == "success" else { return nil }
                return object["data"]
            }
            guard readMore() else { break }
        }
        return nil
    }

    private func nextLine() -> Data? {
        guard let index = readBuffer.firstIndex(of: 0x0A) else { return nil }
        let line = readBuffer[readBuffer.startIndex..<index]
        readBuffer.removeSubrange(readBuffer.startIndex...index)
        return line.isEmpty ? nextLine() : Data(line)
    }

    private func readMore() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 8192)
        // Short timeout so a hung mpv cannot block the UI thread indefinitely.
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let n = recv(socketFD, &chunk, chunk.count, 0)
        guard n > 0 else { return false }
        readBuffer.append(contentsOf: chunk[0..<n])
        return true
    }
}
#endif

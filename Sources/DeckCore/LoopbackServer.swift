import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A single-shot HTTP listener on 127.0.0.1, used to catch an OAuth redirect.
///
/// This is the flow OAuth defines for installed applications: the browser is sent to
/// the provider, the provider redirects back to a loopback port, and the app reads the
/// authorization code from that request. It requires no client secret, which matters
/// because a secret embedded in a distributed binary is not a secret.
///
/// Written on POSIX sockets so the same code serves both the macOS and Linux builds.
public actor LoopbackServer {
    public struct Callback: Sendable {
        public let code: String?
        public let state: String?
        public let error: String?
    }

    private var socketFD: Int32 = -1
    public private(set) var port: UInt16 = 0

    public init() {}

    deinit {
        if socketFD >= 0 { close(socketFD) }
    }

    /// Binds the listener.
    ///
    /// A fixed port is required rather than an ephemeral one: providers match the
    /// redirect URI against the registered value exactly, port included, so the port has
    /// to be knowable in advance and stable across sign-ins. Passing 0 asks the kernel
    /// to choose, which is only useful for tests.
    public func start(preferredPort: UInt16 = 0) throws -> UInt16 {
        let fd = socket(AF_INET, Int32(SOCK_STREAM_VALUE), 0)
        guard fd >= 0 else { throw Failure.cannotBind }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = preferredPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            // A stale listener from a previous attempt is the usual cause, and the
            // message has to say so because the user cannot change the port.
            throw preferredPort == 0 ? Failure.cannotBind : Failure.portInUse(preferredPort)
        }

        // Read back whichever port the kernel assigned.
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }

        socketFD = fd
        port = UInt16(bigEndian: actual.sin_port)
        return port
    }

    /// Waits for the provider's redirect and returns the query it carried.
    ///
    /// `accept` blocks, so this runs on a detached thread rather than occupying a slot
    /// in Swift's cooperative pool, which has only as many threads as the machine has
    /// cores and would otherwise starve.
    public func waitForCallback(timeout: TimeInterval = 300) async throws -> Callback {
        let fd = socketFD
        guard fd >= 0 else { throw Failure.notStarted }

        return try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                var timeoutValue = timeval(
                    tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(
                    fd, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue,
                    socklen_t(MemoryLayout<timeval>.size))

                let client = accept(fd, nil, nil)
                guard client >= 0 else {
                    continuation.resume(throwing: Failure.timedOut)
                    return
                }
                defer { close(client) }

                var buffer = [UInt8](repeating: 0, count: 8192)
                let count = recv(client, &buffer, buffer.count, 0)
                guard count > 0 else {
                    continuation.resume(throwing: Failure.timedOut)
                    return
                }

                let request = String(decoding: buffer[0..<count], as: UTF8.self)
                let callback = Self.parse(request)

                // Something has to be shown in the browser tab the user is staring at.
                let page = Self.responsePage(success: callback.code != nil)
                let response = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Content-Length: \(page.utf8.count)\r
                Connection: close\r
                \r
                \(page)
                """
                _ = response.withCString { send(client, $0, strlen($0), 0) }

                continuation.resume(returning: callback)
            }
            thread.stackSize = 1 << 19
            thread.start()
        }
    }

    public func stop() {
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    // MARK: - Parsing

    /// Pulls the query parameters out of the request line: `GET /callback?code=… HTTP/1.1`.
    public static func parse(_ request: String) -> Callback {
        guard let line = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first,
              let target = line.split(separator: " ").dropFirst().first,
              let queryStart = target.firstIndex(of: "?")
        else { return Callback(code: nil, state: nil, error: "malformed request") }

        let query = target[target.index(after: queryStart)...]
        var values: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1])
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? String(parts[1])
        }
        return Callback(code: values["code"], state: values["state"], error: values["error"])
    }

    static func responsePage(success: Bool) -> String {
        let message = success ? "Signed in. You can close this tab." : "Sign-in failed."
        return """
        <!doctype html><meta charset="utf-8"><title>deck</title>
        <body style="background:#121212;color:#e8e8e8;font-family:ui-monospace,monospace;
        display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
        <div style="text-align:center">
        <div style="color:#8ab4f8;font-size:13px;letter-spacing:2px">DECK</div>
        <p style="font-size:14px">\(message)</p></div></body>
        """
    }

    public enum Failure: LocalizedError {
        case cannotBind
        case portInUse(UInt16)
        case notStarted
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .cannotBind:
                return "could not open a local port for sign-in"
            case .portInUse(let port):
                return "port \(port) is already in use, so the sign-in redirect cannot "
                    + "be received. Close whatever is using it and try again."
            case .notStarted:
                return "sign-in listener was not started"
            case .timedOut:
                return "sign-in timed out"
            }
        }
    }
}

/// SOCK_STREAM is an enum on Linux and a plain Int32 on Darwin.
#if canImport(Glibc)
private let SOCK_STREAM_VALUE = SOCK_STREAM.rawValue
#else
private let SOCK_STREAM_VALUE = SOCK_STREAM
#endif

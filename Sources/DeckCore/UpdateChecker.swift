import Foundation

// On Linux, URLSession lives in a separate module from the rest of Foundation.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Looks for a newer release on GitHub.
///
/// Deliberately not Sparkle. Sparkle is the right answer for a signed, notarised app with
/// a hosted appcast; this app is ad-hoc signed and released as a plain DMG attached to a
/// GitHub release, so the release list *is* the appcast and a dependency would buy
/// nothing but a signing key it cannot use.
public enum UpdateChecker {
    public static let repository = "riddickburke/deck"

    /// A release newer than what is running.
    public struct Update: Sendable, Equatable {
        public let version: Version
        public let title: String
        public let notes: String
        public let pageURL: URL
        public let downloadURL: URL
        public let checksumsURL: URL?
        public let sizeInBytes: Int64

        public init(
            version: Version, title: String, notes: String, pageURL: URL,
            downloadURL: URL, checksumsURL: URL?, sizeInBytes: Int64
        ) {
            self.version = version
            self.title = title
            self.notes = notes
            self.pageURL = pageURL
            self.downloadURL = downloadURL
            self.checksumsURL = checksumsURL
            self.sizeInBytes = sizeInBytes
        }
    }

    public enum Result: Sendable, Equatable {
        case upToDate(current: Version)
        case available(Update)
        /// A newer release exists but carries no macOS disk image — a Linux-only
        /// release, say. Worth saying so rather than reporting "up to date", which
        /// would be false.
        case newerReleaseWithoutDownload(version: Version, pageURL: URL)
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case network(String)
        case rateLimited
        case noReleases
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .network(let detail): return "could not reach GitHub: \(detail)"
            case .rateLimited:
                return "GitHub rate limit reached — try again in a few minutes"
            case .noReleases: return "no releases published yet"
            case .malformed(let detail): return "unexpected response: \(detail)"
            }
        }
    }

    /// Asks GitHub for the newest release and compares it with what is running.
    public static func check(
        current: Version,
        repository: String = UpdateChecker.repository,
        session: URLSession = .shared
    ) async -> Swift.Result<Result, Failure> {
        let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects API requests with no user agent.
        request.setValue("Deck/\(current.description)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .failure(.network(error.localizedDescription))
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200: break
            case 403, 429: return .failure(.rateLimited)
            case 404: return .failure(.noReleases)
            default: return .failure(.network("HTTP \(http.statusCode)"))
            }
        }

        return parse(data, current: current)
    }

    /// Split out from the request so it can be tested against captured payloads.
    public static func parse(
        _ data: Data, current: Version
    ) -> Swift.Result<Result, Failure> {
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
                let size: Int64
            }
            let tag_name: String
            let name: String?
            let body: String?
            let html_url: URL
            let assets: [Asset]
            let draft: Bool?
            let prerelease: Bool?
        }

        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            return .failure(.malformed("could not decode the release"))
        }
        guard release.draft != true, release.prerelease != true else {
            return .success(.upToDate(current: current))
        }
        guard let version = Version(release.tag_name) else {
            return .failure(.malformed("unrecognised tag \(release.tag_name)"))
        }
        guard version > current else {
            return .success(.upToDate(current: current))
        }

        guard let dmg = release.assets.first(where: {
            $0.name.lowercased().hasSuffix(".dmg")
        }) else {
            return .success(.newerReleaseWithoutDownload(
                version: version, pageURL: release.html_url))
        }

        let checksums = release.assets.first { $0.name == "SHA256SUMS" }

        return .success(.available(Update(
            version: version,
            title: release.name ?? release.tag_name,
            notes: (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            pageURL: release.html_url,
            downloadURL: dmg.browser_download_url,
            checksumsURL: checksums?.browser_download_url,
            sizeInBytes: dmg.size)))
    }

    /// Pulls the expected digest for one file out of a `SHA256SUMS` body.
    ///
    /// The format is `<hex>  <filename>` per line, as written by `shasum -a 256`.
    /// Matching on the file name rather than taking the first line means the file can
    /// list every platform's artefact, which it does.
    public static func expectedDigest(for fileName: String, in checksums: String) -> String? {
        for line in checksums.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            // The name may be prefixed with `*` for binary mode.
            let listed = parts[parts.count - 1].trimmingCharacters(
                in: CharacterSet(charactersIn: "*"))
            if listed == fileName { return String(parts[0]).lowercased() }
        }
        return nil
    }
}

// MARK: - Version

/// A dotted release version, compared numerically.
///
/// String comparison gets this wrong in the one case that matters: "1.10.0" sorts before
/// "1.9.0" alphabetically, so the update would be offered backwards exactly when a
/// project has shipped more than nine minor releases.
public struct Version: Comparable, Sendable, Equatable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Accepts `1.2.3`, `v1.2.3`, and short forms like `1.2`.
    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        // Drop any build or pre-release suffix: 1.2.3-beta.1, 1.2.3+build7.
        if let cut = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            text = String(text[text.startIndex..<cut])
        }
        guard !text.isEmpty else { return nil }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 3, !parts.isEmpty else { return nil }

        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: Version, b: Version) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

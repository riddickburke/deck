import AppKit
import DeckCore
import Foundation

/// Owns the Spotify sign-in flow and persists the resulting tokens.
///
/// Sign-in opens the system browser and waits on a loopback listener for the redirect.
/// That is the flow OAuth specifies for installed applications, and it avoids embedding
/// a client secret — which would not stay secret inside a distributed binary anyway.
@MainActor
final class SpotifySession: ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published private(set) var isSigningIn = false
    @Published var lastError: String?

    let client = SpotifyClient()

    /// Fixed because Spotify matches the redirect URI exactly. This is the value that
    /// must be registered on the dashboard.
    static let redirectPort: UInt16 = 8888
    static var redirectURI: String { "http://127.0.0.1:\(redirectPort)/callback" }

    func restore(clientID: String?) async {
        let tokens = Self.loadTokens()
        await client.configure(clientID: clientID, tokens: tokens)
        isAuthorized = tokens != nil
    }

    func signIn(clientID: String) async {
        guard !isSigningIn else { return }
        isSigningIn = true
        lastError = nil
        defer { isSigningIn = false }

        let server = LoopbackServer()
        do {
            _ = try await server.start(preferredPort: Self.redirectPort)
            let redirect = Self.redirectURI

            guard let auth = SpotifyClient.authorizationURL(
                clientID: clientID, redirectURI: redirect) else {
                lastError = "could not build the authorization URL"
                return
            }

            await client.configure(clientID: clientID, tokens: nil)
            NSWorkspace.shared.open(auth.url)

            let callback = try await server.waitForCallback()
            await server.stop()

            if let error = callback.error {
                lastError = "Spotify refused the sign-in: \(error)"
                return
            }
            // The state check is what stops a different page in the browser from
            // injecting its own code into our listener.
            guard callback.state == auth.state else {
                lastError = "sign-in state mismatch — ignoring the response"
                return
            }
            guard let code = callback.code else {
                lastError = "no authorization code came back"
                return
            }

            let tokens = try await client.exchange(
                code: code, verifier: auth.verifier, redirectURI: redirect)
            Self.saveTokens(tokens)
            isAuthorized = true
        } catch {
            await server.stop()
            lastError = error.localizedDescription
        }
    }

    func signOut() async {
        await client.signOut()
        try? FileManager.default.removeItem(at: Config.spotifyTokensURL)
        isAuthorized = false
    }

    /// Persists refreshed tokens after any API call that may have rotated them.
    func persistCurrentTokens() async {
        guard let tokens = await client.currentTokens else { return }
        Self.saveTokens(tokens)
    }

    // MARK: - Token storage

    static func loadTokens() -> SpotifyClient.Tokens? {
        guard let data = try? Data(contentsOf: Config.spotifyTokensURL) else { return nil }
        return try? JSONDecoder().decode(SpotifyClient.Tokens.self, from: data)
    }

    static func saveTokens(_ tokens: SpotifyClient.Tokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let url = Config.spotifyTokensURL
        try? data.write(to: url, options: .atomic)
        // Owner-only: these are live credentials to the user's account.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

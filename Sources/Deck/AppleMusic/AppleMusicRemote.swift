import DeckCore
import Foundation

/// Drives playback in Music.app.
///
/// Deck cannot decode Apple Music streams itself — they are DRM-protected and there is
/// no file. Music.app can, so Deck browses and commands while Music.app does the
/// playing. This is the same arrangement as Spotify Connect, and it is why subscription
/// tracks work at all without a MusicKit entitlement.
actor AppleMusicRemote {
    struct State: Sendable, Equatable {
        var isPlaying = false
        var position: TimeInterval = 0
        var duration: TimeInterval = 0
        /// Music.app's own idea of what is playing, used to detect it moving on.
        var trackID: String?
    }

    private(set) var lastState = State()

    /// Plays a specific track by its Music.app database ID.
    func play(trackID: String) async throws {
        // Addressed through the library playlist so the whole library is in scope,
        // not just whatever Music happens to be showing.
        let script = AppleEvents.music("""
            set matches to (every track of library playlist 1 whose database ID is \(trackID))
            if (count of matches) is 0 then return "missing"
            play (item 1 of matches)
            return "ok"
            """)
        let result = try await AppleEvents.run(script)
        guard result == "ok" else {
            throw AppleEvents.Failure.failed("track \(trackID) is no longer in the library")
        }
    }

    func pause() async {
        await AppleEvents.runIgnoringErrors(AppleEvents.music("pause"))
    }

    func resume() async {
        await AppleEvents.runIgnoringErrors(AppleEvents.music("play"))
    }

    func stop() async {
        await AppleEvents.runIgnoringErrors(AppleEvents.music("stop"))
    }

    func next() async {
        await AppleEvents.runIgnoringErrors(AppleEvents.music("next track"))
    }

    func previous() async {
        await AppleEvents.runIgnoringErrors(AppleEvents.music("previous track"))
    }

    func seek(to seconds: TimeInterval) async {
        await AppleEvents.runIgnoringErrors(
            AppleEvents.music("set player position to \(Int(seconds))"))
    }

    /// 0...1, mapped onto Music.app's 0...100 scale.
    func setVolume(_ volume: Float) async {
        let value = Int(max(0, min(1, volume)) * 100)
        await AppleEvents.runIgnoringErrors(AppleEvents.music("set sound volume to \(value)"))
    }

    /// One Apple Event for everything the transport bar needs.
    @discardableResult
    func refreshState() async -> State {
        let script = AppleEvents.music("""
            set fs to (ASCII character 31)
            set s to (player state as text)
            set p to 0
            set d to 0
            set tid to ""
            try
                set p to player position
                set d to duration of current track
                set tid to (database ID of current track) as text
            end try
            return s & fs & p & fs & d & fs & tid
            """)

        guard let raw = try? await AppleEvents.run(script) else { return lastState }
        let f = raw.components(separatedBy: AppleEvents.fieldSeparator)
        guard f.count >= 4 else { return lastState }

        var state = State()
        state.isPlaying = f[0].trimmingCharacters(in: .whitespaces) == "playing"
        state.position = Double(f[1].trimmingCharacters(in: .whitespaces)) ?? 0
        state.duration = Double(f[2].trimmingCharacters(in: .whitespaces)) ?? 0
        let id = f[3].trimmingCharacters(in: .whitespaces)
        state.trackID = id.isEmpty ? nil : id

        lastState = state
        return state
    }

    /// True when Music.app is reachable and the user has granted automation access.
    static func probe() async -> Result<String, Error> {
        do {
            let version = try await AppleEvents.run(AppleEvents.music("return version as text"))
            return .success(version)
        } catch {
            return .failure(error)
        }
    }
}

import Foundation
import MediaPlayer

/// An on-device probe of the things that cannot be checked from a Mac.
///
/// The media library exists only on real hardware, and there is no way to drive the UI
/// from a script, so the paths that depend on both — does artwork actually come back for
/// these items, does the player actually start — are otherwise unobservable except by
/// asking someone to tap and describe what happened.
///
/// Enabled by launching with `DECK_SELFTEST=1`:
///
///     xcrun devicectl device process launch --device <id> \
///         --environment-variables '{"DECK_SELFTEST":"1"}' com.riddickburke.deckmobile
///
/// Results land in the diagnostics file. Counts only — never titles or artists.
enum SelfTest {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["DECK_SELFTEST"] == "1"
    }

    static func run(playback: Playback) async {
        Log.library.notice("selftest: begin")

        probeArtwork()
        await probePlayback(playback)

        Log.library.notice("selftest: end")
    }

    /// Does artwork actually come back for the items in this library?
    ///
    /// Apple Music tracks that live only in the cloud frequently return nil artwork
    /// through MediaPlayer, so "no album art" may be the library rather than the code.
    /// This distinguishes the two before anything is changed.
    private static func probeArtwork() {
        let query = MPMediaQuery.songs()
        guard let items = query.items, !items.isEmpty else {
            Log.artwork.error("selftest: no items to probe")
            return
        }

        // A sample, not the whole library: `artwork` is a fetch per item and 3000 of
        // them would stall the launch this test is running inside.
        let sample = Array(items.prefix(200))
        var hasArtwork = 0
        var cloud = 0
        var noAsset = 0
        var rendered = 0

        for item in sample {
            if item.isCloudItem { cloud += 1 }
            if item.assetURL == nil { noAsset += 1 }
            guard let artwork = item.artwork else { continue }
            hasArtwork += 1
            // Having an artwork object is not the same as it producing an image —
            // `image(at:)` returns nil when the requested size exceeds its bounds.
            if artwork.image(at: CGSize(width: 88, height: 88)) != nil { rendered += 1 }
        }

        Log.artwork.notice(
            "selftest: sampled \(sample.count) — \(hasArtwork) have artwork, \(rendered) rendered at 88pt, \(cloud) cloud items, \(noAsset) without a local asset")

        // The above talks to MediaPlayer directly. This goes through the id-based index
        // the views actually use, at the sizes they actually ask for — if the two
        // disagree, the fault is the lookup rather than the library.
        guard let id = sample.first.map({ String($0.persistentID) }) else { return }
        for size in [CGSize(width: 88, height: 88), CGSize(width: 340, height: 340)] {
            let image = MusicLibrary.artwork(forID: id, size: size)
            Log.artwork.notice(
                "selftest: via index at \(Int(size.width))pt — \(image == nil ? "nil" : "ok")")
        }
    }

    /// Does the player actually start?
    private static func probePlayback(_ playback: Playback) async {
        let query = MPMediaQuery.songs()
        guard let first = query.items?.first,
              let track = MusicLibrary.track(from: first)
        else {
            Log.playback.error("selftest: no track to play")
            return
        }

        let controller = MPMusicPlayerController.applicationMusicPlayer
        Log.playback.notice("selftest: state before \(describe(controller.playbackState))")

        await MainActor.run { playback.play(tracks: [track]) }

        // Long enough for prepareToPlay to call back and the player to spin up.
        try? await Task.sleep(nanoseconds: 4_000_000_000)

        let state = controller.playbackState
        let item = controller.nowPlayingItem
        Log.playback.notice(
            "selftest: state after \(describe(state)), nowPlayingItem \(item == nil ? "nil" : "set"), time \(Int(controller.currentPlaybackTime))s")
    }

    private static func describe(_ state: MPMusicPlaybackState) -> String {
        switch state {
        case .stopped: return "stopped"
        case .playing: return "playing"
        case .paused: return "paused"
        case .interrupted: return "interrupted"
        case .seekingForward: return "seekingForward"
        case .seekingBackward: return "seekingBackward"
        @unknown default: return "unknown"
        }
    }
}

import AppKit
import Combine
import DeckCore
import MediaPlayer

/// Bridges playback to the system: the Now Playing tile in Control Centre and the
/// notification centre, and the F7/F8/F9 media keys plus Bluetooth/headset controls.
///
/// Both halves are required. `MPRemoteCommandCenter` receives the button presses, and
/// `MPNowPlayingInfoCenter` is what tells macOS this app is the thing currently playing —
/// without populated Now Playing info the system has no reason to route media keys here,
/// so registering commands alone does nothing.
@MainActor
final class MediaRemote {
    private let player: Player
    /// Resolves cover art for a track. Set by AppState, which owns the album index.
    var artworkProvider: ((Track) async -> NSImage?)?

    private var cancellables = Set<AnyCancellable>()
    private var drift: Timer?
    private var artworkTrackID: String?

    init(player: Player) {
        self.player = player
        configureCommands()
        observePlayer()
    }

    deinit {
        drift?.invalidate()
    }

    // MARK: - Remote commands

    private func configureCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.player.resume()
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.player.pause()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.player.toggle()
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            guard !self.player.queue.isEmpty else { return .noSuchContent }
            self.player.next()
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            guard !self.player.queue.isEmpty else { return .noSuchContent }
            self.player.previous()
            return .success
        }

        // Lets you scrub from the Control Centre tile rather than only inside the app.
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            self.player.seek(to: event.positionTime)
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.player.seekRelative(15)
            return .success
        }

        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.player.seekRelative(-15)
            return .success
        }

        // Nothing here is a rating/like surface, so leave those off rather than
        // advertising commands that would silently do nothing.
        center.likeCommand.isEnabled = false
        center.dislikeCommand.isEnabled = false
        center.bookmarkCommand.isEnabled = false
    }

    // MARK: - Now Playing info

    private func observePlayer() {
        // A new track replaces everything, including artwork.
        player.$currentTrack
            .removeDuplicates()
            .sink { [weak self] track in self?.publish(track: track, includeArtwork: true) }
            .store(in: &cancellables)

        // Play/pause only needs the rate and elapsed time corrected.
        player.$isPlaying
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.publish(track: self.player.currentTrack, includeArtwork: false)
            }
            .store(in: &cancellables)

        // The system extrapolates elapsed time from the playback rate, so this only has
        // to correct drift and catch seeks — polling at UI rate would be wasteful.
        drift = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player.isPlaying else { return }
                self.publish(track: self.player.currentTrack, includeArtwork: false)
            }
        }

        NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.teardown() }
            .store(in: &cancellables)
    }

    private func publish(track: Track?, includeArtwork: Bool) {
        let center = MPNowPlayingInfoCenter.default()

        guard let track else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            artworkTrackID = nil
            return
        }

        // Preserve any artwork already attached for this track so a play/pause update
        // does not blank the cover for a moment while it is refetched.
        var info = center.nowPlayingInfo ?? [:]
        if artworkTrackID != track.id {
            info[MPMediaItemPropertyArtwork] = nil
        }

        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artist
        info[MPMediaItemPropertyAlbumTitle] = track.album
        info[MPMediaItemPropertyAlbumArtist] = track.albumArtist
        info[MPMediaItemPropertyPlaybackDuration] = player.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.position
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        if let number = track.trackNumber {
            info[MPMediaItemPropertyAlbumTrackNumber] = number
        }
        if let genre = track.genre {
            info[MPMediaItemPropertyGenre] = genre
        }
        if !player.queue.isEmpty {
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = player.queue.count
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = player.currentIndex
        }

        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused

        if includeArtwork { loadArtwork(for: track) }
    }

    private func loadArtwork(for track: Track) {
        guard let artworkProvider else { return }
        artworkTrackID = nil

        Task { [weak self] in
            guard let image = await artworkProvider(track) else { return }
            await MainActor.run {
                guard let self,
                      // The track may have changed while the art was loading.
                      self.player.currentTrack?.id == track.id
                else { return }

                let artwork = MPMediaItemArtwork(boundsSize: image.size) { size in
                    let resized = NSImage(size: size)
                    resized.lockFocus()
                    image.draw(in: NSRect(origin: .zero, size: size))
                    resized.unlockFocus()
                    return resized
                }

                let center = MPNowPlayingInfoCenter.default()
                var info = center.nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                center.nowPlayingInfo = info
                self.artworkTrackID = track.id
            }
        }
    }

    /// Removes the app from the system Now Playing surface. Called on quit so the tile
    /// does not linger showing a track nothing is playing.
    func teardown() {
        drift?.invalidate()
        drift = nil
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }
}

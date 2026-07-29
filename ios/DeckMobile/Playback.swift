import AVFoundation
import Combine
import Foundation
import MediaPlayer

/// Drives playback through the system music player.
///
/// `applicationMusicPlayer` rather than `systemMusicPlayer`: the application player owns
/// its own queue, so building a queue here does not overwrite whatever the user had
/// going in the Music app. The trade-off is that the queue does not survive the app being
/// killed, which for a player that rebuilds its queue on launch is not a loss.
///
/// This is also the only way to play Apple Music subscription tracks without the MusicKit
/// entitlement — the audio is decoded in the media services process, not here.
///
/// One consequence runs through the whole app: because the samples never pass through
/// this process, there is nothing to run an FFT over. The visualiser is therefore
/// synthetic, exactly as it is for streaming services on the desktop build.
@MainActor
final class Playback: ObservableObject {

    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var queue: [Track] = []
    @Published private(set) var queueIndex: Int = 0

    /// Elapsed time lives on its own object, deliberately.
    ///
    /// It changes four times a second. Publishing it from `Playback` would make every
    /// view that reads *any* playback state — the songs list, the album grid, the row
    /// highlight — invalidate on every tick, because SwiftUI observes the object, not
    /// the property. Only the scrubber and the mini player's progress rule observe this.
    let clock = PlaybackClock()

    @Published var repeatMode: MPMusicRepeatMode = .none {
        didSet { player.repeatMode = repeatMode }
    }
    @Published var shuffleMode: MPMusicShuffleMode = .off {
        didSet { player.shuffleMode = shuffleMode }
    }

    /// `applicationQueuePlayer`, not `applicationMusicPlayer`.
    ///
    /// The two behave identically — both own a private queue that leaves the Music app's
    /// own playback alone — but only the queue player is an
    /// `MPMusicPlayerApplicationController`, which is where `performQueueTransaction` is
    /// declared. Without it the queue is read-only and cannot be reordered.
    private let player = MPMusicPlayerController.applicationQueuePlayer
    private var ticker: Timer?
    private var observers: [NSObjectProtocol] = []

    /// Set while a queue is being handed to the player.
    ///
    /// Assigning a queue makes the player report a nil now-playing item for a moment
    /// before it settles on the first track. Without this the UI blanks the transport
    /// on every play command.
    private var isLoadingQueue = false

    init() {
        configureAudioSession()

        // Nothing is delivered until this is called — the notifications below simply
        // never fire, which looks like a wiring bug rather than a missing opt-in.
        player.beginGeneratingPlaybackNotifications()

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: player, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.nowPlayingItemChanged() }
        })
        observers.append(center.addObserver(
            forName: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: player, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.playbackStateChanged() }
        })

        repeatMode = player.repeatMode
        shuffleMode = player.shuffleMode
        syncFromPlayer()
        startTicker()
    }

    deinit {
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
    }

    /// Required for playback to continue with the screen locked. `.playback` also means
    /// the app is not silenced by the ring/silent switch, which is what a music player
    /// should do.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    // MARK: - Commands

    /// Replaces the queue and starts at `startIndex`.
    func play(tracks: [Track], startingAt startIndex: Int = 0) {
        guard !tracks.isEmpty else { return }
        let items = MusicLibrary.items(forIDs: tracks.compactMap(\.externalID))
        Log.playback.notice("play: \(tracks.count) tracks, \(items.count) resolved to items")
        guard !items.isEmpty else {
            Log.playback.error("play: nothing resolved, aborting")
            return
        }

        // Resolution can drop tracks the library no longer has, so the requested index
        // is remapped onto what actually resolved rather than used directly.
        let resolvedIDs = items.map { String($0.persistentID) }
        let wantedID = tracks.indices.contains(startIndex) ? tracks[startIndex].externalID : nil
        let index = wantedID.flatMap { resolvedIDs.firstIndex(of: $0) } ?? 0

        queue = tracks.filter { $0.externalID.map(resolvedIDs.contains) ?? false }
        queueIndex = index

        isLoadingQueue = true
        player.setQueue(with: MPMediaItemCollection(items: items))

        // Only the id crosses into the completion handler, not the item.
        //
        // `prepareToPlay` calls back on an arbitrary queue, and `MPMediaItem` is a
        // non-Sendable reference into the media library, so capturing one here would be
        // handing a library object between threads. Re-resolving on the main actor costs
        // a dictionary lookup.
        let startID = resolvedIDs[index]

        // `prepareToPlay` is what actually applies the queue. Setting nowPlayingItem
        // before the queue is prepared is ignored on a cold player.
        player.prepareToPlay { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.isLoadingQueue = false
                if let error {
                    Log.playback.error("prepareToPlay failed: \(error.localizedDescription)")
                } else {
                    Log.playback.notice("prepareToPlay ok, starting")
                    if let item = MusicLibrary.item(forID: startID) {
                        self.player.nowPlayingItem = item
                    }
                    self.player.play()
                    // Reconcile against what the player actually accepted, which can
                    // differ from what was handed to it.
                    self.refreshQueue()
                }
                self.syncFromPlayer()
            }
        }
    }

    /// Inserts after the current track.
    ///
    /// `prepend` on the application player means "next", not "at the front of the whole
    /// queue" — the descriptor is spliced in after whatever is playing.
    func playNext(_ tracks: [Track]) {
        guard let descriptor = descriptor(for: tracks) else { return }
        player.prepend(descriptor)
        syncQueueTail(tracks, atFront: true)
    }

    func enqueue(_ tracks: [Track]) {
        guard let descriptor = descriptor(for: tracks) else { return }
        player.append(descriptor)
        syncQueueTail(tracks, atFront: false)
    }

    private func descriptor(for tracks: [Track]) -> MPMusicPlayerMediaItemQueueDescriptor? {
        let items = MusicLibrary.items(forIDs: tracks.compactMap(\.externalID))
        guard !items.isEmpty else { return nil }
        return MPMusicPlayerMediaItemQueueDescriptor(
            itemCollection: MPMediaItemCollection(items: items))
    }

    /// The local copy is updated to match what was just handed over, then reconciled
    /// against the player's own queue once it settles.
    private func syncQueueTail(_ tracks: [Track], atFront: Bool) {
        if queue.isEmpty {
            queue = tracks
        } else {
            let insertion = min(queueIndex + 1, queue.count)
            queue.insert(contentsOf: tracks, at: atFront ? insertion : queue.count)
        }
        refreshQueue()
    }

    // MARK: - Queue editing

    /// Reads the player's real queue back into `queue`.
    ///
    /// There is no property for this. An empty queue transaction is the only way to be
    /// handed the current items, so that is what this is — a read dressed as a write.
    func refreshQueue() {
        // The `queueTransaction:` label is required, not stylistic: with a trailing
        // closure this resolves to NSObject's `perform(_:with:)` instead.
        player.perform(queueTransaction: { _ in
            // Deliberately no mutation.
        }, completionHandler: { [weak self] queue, error in
            let items = queue.items
            Task { @MainActor in
                guard let self, error == nil else {
                    if let error {
                        Log.playback.error("refreshQueue failed: \(error.localizedDescription)")
                    }
                    return
                }
                self.queue = items.compactMap(MusicLibrary.track(from:))
                if let id = self.currentTrack?.externalID,
                   let index = self.queue.firstIndex(where: { $0.externalID == id }) {
                    self.queueIndex = index
                }
            }
        })
    }

    /// Moves one track within the queue.
    ///
    /// The queue belongs to the media services process, so it cannot simply be replaced
    /// with a reordered array — doing that with `setQueue` restarts playback from the
    /// top. A transaction expresses the move as a removal plus an insertion after the
    /// track it should now follow, which the player applies without interrupting audio.
    func moveQueueItem(from source: IndexSet, to destination: Int) {
        guard let from = source.first, from < queue.count else { return }

        // Applied locally first so the row lands where the finger dropped it, rather
        // than snapping back until the player's callback arrives.
        var reordered = queue
        reordered.move(fromOffsets: source, toOffset: destination)
        let moved = queue[from]
        // `move(fromOffsets:toOffset:)` uses a pre-removal index; the item it should
        // follow is whatever ends up before it afterwards.
        let newIndex = reordered.firstIndex(where: { $0.id == moved.id }) ?? 0
        let predecessor = newIndex > 0 ? reordered[newIndex - 1] : nil
        queue = reordered

        player.perform(queueTransaction: { mutable in
            guard let item = mutable.items.first(where: {
                String($0.persistentID) == moved.externalID
            }) else { return }

            mutable.remove(item)

            let descriptor = MPMusicPlayerMediaItemQueueDescriptor(
                itemCollection: MPMediaItemCollection(items: [item]))
            if let predecessor,
               let after = mutable.items.first(where: {
                   String($0.persistentID) == predecessor.externalID
               }) {
                mutable.insert(descriptor, after: after)
            } else {
                // nil means the head of the queue.
                mutable.insert(descriptor, after: nil)
            }
        }, completionHandler: { [weak self] _, error in
            if let error {
                Log.playback.error("queue move failed: \(error.localizedDescription)")
            }
            Task { @MainActor in self?.refreshQueue() }
        })
    }

    /// Removes tracks from the queue.
    func removeQueueItems(at offsets: IndexSet) {
        let removing = offsets.compactMap { $0 < queue.count ? queue[$0] : nil }
        guard !removing.isEmpty else { return }

        // Removing what is playing would stop playback with no obvious cause, so it is
        // skipped — the row for the current track is not swipeable in the UI either.
        let ids = Set(removing.compactMap(\.externalID)).subtracting(
            [currentTrack?.externalID].compactMap { $0 })
        guard !ids.isEmpty else { return }

        queue.removeAll { $0.externalID.map(ids.contains) ?? false }

        player.perform(queueTransaction: { mutable in
            for item in mutable.items where ids.contains(String(item.persistentID)) {
                mutable.remove(item)
            }
        }, completionHandler: { [weak self] _, error in
            if let error {
                Log.playback.error("queue remove failed: \(error.localizedDescription)")
            }
            Task { @MainActor in self?.refreshQueue() }
        })
    }

    func toggle() {
        isPlaying ? player.pause() : player.play()
    }

    func pause() { player.pause() }
    func resume() { player.play() }

    func next() { player.skipToNextItem() }

    /// Matches every other player: part-way into a track, back means restart.
    func previous() {
        if player.currentPlaybackTime > 3 {
            player.skipToBeginning()
        } else {
            player.skipToPreviousItem()
        }
    }

    func seek(to time: TimeInterval) {
        player.currentPlaybackTime = max(0, min(time, clock.duration))
        clock.position = player.currentPlaybackTime
    }

    func cycleRepeat() {
        switch repeatMode {
        case .none: repeatMode = .all
        case .all: repeatMode = .one
        default: repeatMode = .none
        }
    }

    func toggleShuffle() {
        shuffleMode = shuffleMode == .off ? .songs : .off
    }

    // MARK: - State

    private func nowPlayingItemChanged() {
        syncFromPlayer()
    }

    private func playbackStateChanged() {
        isPlaying = player.playbackState == .playing
        syncFromPlayer()
    }

    /// Called after the track or the play/pause state settles.
    ///
    /// A closure rather than an `objectWillChange` subscription, because that publisher
    /// fires *before* the properties update — an observer would read the previous track
    /// and stay one behind.
    var onStateChange: ((_ trackID: String?, _ isPlaying: Bool) -> Void)?

    private func syncFromPlayer() {
        isPlaying = player.playbackState == .playing
        defer { onStateChange?(currentTrack?.id, isPlaying) }

        guard let item = player.nowPlayingItem else {
            // Mid-queue-assignment the player briefly reports nothing; keeping the last
            // track avoids the transport flickering empty on every play.
            if !isLoadingQueue {
                currentTrack = nil
                clock.duration = 0
                clock.position = 0
            }
            return
        }

        let id = String(item.persistentID)
        if currentTrack?.externalID != id {
            currentTrack = MusicLibrary.track(from: item)
            if let index = queue.firstIndex(where: { $0.externalID == id }) {
                queueIndex = index
            }
        }
        clock.duration = item.playbackDuration
        clock.position = player.currentPlaybackTime
    }

    /// The player publishes no progress callback, so position is polled.
    ///
    /// 4 Hz: the transport clock shows whole seconds and the progress bar is a few
    /// hundred points wide, so faster costs battery for nothing.
    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.clock.position = self.player.currentPlaybackTime
                // The player's own duration is authoritative once streaming has begun;
                // the library's value can be a placeholder for a cloud item.
                if let item = self.player.nowPlayingItem, item.playbackDuration > 0 {
                    self.clock.duration = item.playbackDuration
                }
            }
        }
        // Common mode, or the clock freezes for as long as a finger is on a scroll view.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }
}

/// Elapsed position and track length, published separately from the rest of playback.
///
/// See the note on `Playback.clock` — this exists purely to keep a 4 Hz update from
/// invalidating views that only care about which track is playing.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var position: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    /// 0...1, guarding the zero-length case that a cloud item shows before it loads.
    var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

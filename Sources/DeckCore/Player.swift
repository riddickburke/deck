import AVFoundation
import Accelerate
import Combine
import Foundation

/// Audio playback built on AVAudioEngine rather than AVPlayer, because the engine gives
/// us three things the simpler API cannot: a real parametric EQ, a render tap for the
/// spectrum visualiser, and sample-accurate scheduling for gapless album playback.
///
/// Scheduling model: tracks are pre-scheduled onto a single player node and recorded in
/// `segments` with their start frame. "Which track is playing" is then derived from the
/// node's sample time rather than tracked by completion callbacks, which is what makes
/// gapless transitions report the right track at the right moment.
@MainActor
public final class Player: ObservableObject {
    // MARK: Published state

    @Published public private(set) var currentTrack: Track?
    @Published public private(set) var isPlaying = false
    @Published public private(set) var position: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var queue: [Track] = []
    @Published public private(set) var currentIndex: Int = 0
    @Published public private(set) var spectrum: [Float] = Array(repeating: 0, count: Player.bandCount)
    @Published public private(set) var isBuffering = false
    @Published public var lastError: String?

    @Published public var shuffle = false { didSet { rebuildOrder() } }
    @Published public var repeatMode: Config.RepeatMode = .off

    @Published public var volume: Float = 0.8 {
        didSet { engine.mainMixerNode.outputVolume = max(0, min(1, volume)) }
    }

    /// Ten-band EQ gains in dB, -12...+12.
    @Published public var eqGains: [Float] = Array(repeating: 0, count: 10) {
        didSet { applyEQ() }
    }

    public static let bandCount = 28
    public static let eqFrequencies: [Float] = [
        32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
    ]

    // MARK: Engine

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)

    private var connectionFormat: AVAudioFormat?
    private var engineRunning = false

    // MARK: Scheduling

    private struct Segment {
        let queueIndex: Int
        let startFrame: AVAudioFramePosition
        let frameCount: AVAudioFramePosition
        let sampleRate: Double
        /// Frames skipped at the head of the file, so a seek still reports absolute position.
        let seekOffsetFrames: AVAudioFramePosition
    }

    private var segments: [Segment] = []
    private var scheduleCursor: AVAudioFramePosition = 0
    private var playOrder: [Int] = []
    private var orderPosition: Int = 0
    private var ticker: AnyCancellable?
    private var prefetching = false

    // MARK: - Init

    public init() {
        engine.attach(playerNode)
        engine.attach(eq)
        for (i, band) in eq.bands.enumerated() where i < Self.eqFrequencies.count {
            band.filterType = .parametric
            band.frequency = Self.eqFrequencies[i]
            band.bandwidth = 0.7
            band.bypass = false
            band.gain = 0
        }
        engine.mainMixerNode.outputVolume = volume
        installSpectrumTap()
        startTicker()
    }

    deinit {
        // Tap removal must happen before the engine deallocates.
        engine.mainMixerNode.removeTap(onBus: 0)
    }

    // MARK: - Queue control

    public func setQueue(_ tracks: [Track], startAt index: Int = 0) {
        queue = tracks
        rebuildOrder()
        guard !tracks.isEmpty else { stop(); return }
        let clamped = max(0, min(index, tracks.count - 1))
        orderPosition = playOrder.firstIndex(of: clamped) ?? 0
        playTrack(at: clamped)
    }

    public func enqueue(_ tracks: [Track]) {
        let wasEmpty = queue.isEmpty
        queue.append(contentsOf: tracks)
        rebuildOrder()
        if wasEmpty, let first = playOrder.first { playTrack(at: first) }
    }

    public func playNext(_ tracks: [Track]) {
        guard !queue.isEmpty else { enqueue(tracks); return }
        queue.insert(contentsOf: tracks, at: min(currentIndex + 1, queue.count))
        rebuildOrder()
    }

    private func rebuildOrder() {
        guard !queue.isEmpty else { playOrder = []; return }
        let indices = Array(queue.indices)
        if shuffle {
            var rest = indices.filter { $0 != currentIndex }
            rest.shuffle()
            playOrder = queue.indices.contains(currentIndex) ? [currentIndex] + rest : rest
        } else {
            playOrder = indices
        }
        orderPosition = playOrder.firstIndex(of: currentIndex) ?? 0
    }

    // MARK: - Transport

    public func playTrack(at index: Int) {
        guard queue.indices.contains(index) else { return }
        Task { await load(index: index, startAt: 0) }
    }

    public func toggle() { isPlaying ? pause() : resume() }

    public func resume() {
        guard currentTrack != nil else {
            if let first = playOrder.first { playTrack(at: first) }
            return
        }
        do {
            if !engineRunning { try engine.start(); engineRunning = true }
            playerNode.play()
            isPlaying = true
        } catch {
            lastError = "engine start failed: \(error.localizedDescription)"
        }
    }

    public func pause() {
        playerNode.pause()
        isPlaying = false
    }

    public func stop() {
        playerNode.stop()
        segments.removeAll()
        scheduleCursor = 0
        isPlaying = false
        currentTrack = nil
        position = 0
        duration = 0
    }

    public func next() {
        guard !playOrder.isEmpty else { return }
        if repeatMode == .one, let track = currentTrack, let i = queue.firstIndex(of: track) {
            Task { await load(index: i, startAt: 0) }
            return
        }
        if orderPosition + 1 < playOrder.count {
            orderPosition += 1
            playTrack(at: playOrder[orderPosition])
        } else if repeatMode == .all {
            orderPosition = 0
            playTrack(at: playOrder[0])
        } else {
            stop()
        }
    }

    public func previous() {
        // Matches every other player: restart the track unless you press it early.
        if position > 3 { seek(to: 0); return }
        guard !playOrder.isEmpty else { return }
        if orderPosition > 0 {
            orderPosition -= 1
            playTrack(at: playOrder[orderPosition])
        } else {
            seek(to: 0)
        }
    }

    public func seek(to time: TimeInterval) {
        guard queue.indices.contains(currentIndex) else { return }
        let target = max(0, min(time, duration))
        Task { await load(index: currentIndex, startAt: target) }
    }

    public func seekRelative(_ delta: TimeInterval) { seek(to: position + delta) }

    // MARK: - Loading

    private func load(index: Int, startAt offset: TimeInterval) async {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        isBuffering = true
        defer { isBuffering = false }

        let playbackURL: URL
        do {
            playbackURL = try await SourceResolver.playableURL(for: track)
        } catch {
            lastError = "cannot decode \(track.url.lastPathComponent): \(error.localizedDescription)"
            // Skip past the unplayable file rather than stalling the queue.
            advancePastFailure(from: index)
            return
        }

        guard let file = try? AVAudioFile(forReading: playbackURL) else {
            lastError = "unreadable audio: \(track.url.lastPathComponent)"
            advancePastFailure(from: index)
            return
        }

        playerNode.stop()
        segments.removeAll()
        scheduleCursor = 0

        do {
            try ensureConnected(format: file.processingFormat)
        } catch {
            lastError = "audio route failed: \(error.localizedDescription)"
            return
        }

        currentIndex = index
        currentTrack = track
        orderPosition = playOrder.firstIndex(of: index) ?? orderPosition
        duration = Double(file.length) / file.processingFormat.sampleRate
        position = offset

        schedule(file: file, queueIndex: index, startingAt: offset)
        resume()
    }

    private func advancePastFailure(from index: Int) {
        guard let pos = playOrder.firstIndex(of: index), pos + 1 < playOrder.count else {
            stop(); return
        }
        orderPosition = pos + 1
        playTrack(at: playOrder[orderPosition])
    }

    /// The player node's output format is fixed at connect time, so a file with a
    /// different sample rate needs the graph rebuilt. Albums rarely mix rates, so this
    /// costs nothing in the common case.
    private func ensureConnected(format: AVAudioFormat) throws {
        if let current = connectionFormat,
           current.sampleRate == format.sampleRate,
           current.channelCount == format.channelCount {
            if !engineRunning { try engine.start(); engineRunning = true }
            return
        }
        if engineRunning { engine.stop(); engineRunning = false }
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(eq)
        engine.connect(playerNode, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        connectionFormat = format
        engine.prepare()
        try engine.start()
        engineRunning = true
    }

    private func schedule(file: AVAudioFile, queueIndex: Int, startingAt offset: TimeInterval) {
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(offset * sampleRate)
        let remaining = file.length - startFrame
        guard remaining > 0 else { return }

        let segment = Segment(
            queueIndex: queueIndex,
            startFrame: scheduleCursor,
            frameCount: remaining,
            sampleRate: sampleRate,
            seekOffsetFrames: startFrame
        )
        segments.append(segment)
        scheduleCursor += remaining

        playerNode.scheduleSegment(
            file, startingFrame: startFrame, frameCount: AVAudioFrameCount(remaining),
            at: nil, completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSegmentFinished(queueIndex: queueIndex) }
        }
    }

    /// Fires when a scheduled segment has actually been heard. If nothing follows it,
    /// the queue is done.
    private func handleSegmentFinished(queueIndex: Int) {
        guard segments.last?.queueIndex == queueIndex else { return }
        if repeatMode == .one {
            Task { await load(index: queueIndex, startAt: 0) }
            return
        }
        guard let pos = playOrder.firstIndex(of: queueIndex) else { stop(); return }
        if pos + 1 < playOrder.count {
            orderPosition = pos + 1
            playTrack(at: playOrder[orderPosition])
        } else if repeatMode == .all, let first = playOrder.first {
            orderPosition = 0
            playTrack(at: first)
        } else {
            stop()
        }
    }

    // MARK: - Gapless prefetch

    /// Schedules the next track onto the same node shortly before the current one ends,
    /// which is what removes the gap. Only possible when formats match; otherwise the
    /// completion handler path takes over and there is a brief pause.
    private func prefetchIfNeeded() {
        guard isPlaying, !prefetching, repeatMode != .one,
              let last = segments.last,
              let nodeFrame = currentNodeFrame()
        else { return }

        let framesLeft = scheduleCursor - nodeFrame
        let secondsLeft = Double(framesLeft) / last.sampleRate
        guard secondsLeft < 8, secondsLeft > 0 else { return }

        guard let pos = playOrder.firstIndex(of: last.queueIndex) else { return }
        let nextIndex: Int
        if pos + 1 < playOrder.count { nextIndex = playOrder[pos + 1] }
        else if repeatMode == .all, let first = playOrder.first { nextIndex = first }
        else { return }
        guard queue.indices.contains(nextIndex) else { return }

        prefetching = true
        let track = queue[nextIndex]
        Task { [weak self] in
            defer { Task { @MainActor in self?.prefetching = false } }
            guard let url = try? await SourceResolver.playableURL(for: track),
                  let file = try? AVAudioFile(forReading: url) else { return }
            await MainActor.run {
                guard let self,
                      let format = self.connectionFormat,
                      file.processingFormat.sampleRate == format.sampleRate,
                      file.processingFormat.channelCount == format.channelCount,
                      self.segments.last?.queueIndex == last.queueIndex
                else { return }
                self.schedule(file: file, queueIndex: nextIndex, startingAt: 0)
            }
        }
    }

    // MARK: - Position tracking

    private func startTicker() {
        ticker = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func currentNodeFrame() -> AVAudioFramePosition? {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else { return nil }
        return playerTime.sampleTime
    }

    private func tick() {
        guard isPlaying, let frame = currentNodeFrame() else { return }

        // Derive the playing track from the sample clock so a gapless hand-off
        // updates the UI at the exact moment the audio changes.
        if let segment = segments.last(where: { $0.startFrame <= frame }) {
            let into = frame - segment.startFrame
            let absolute = segment.seekOffsetFrames + into
            position = Double(absolute) / segment.sampleRate

            if segment.queueIndex != currentIndex, queue.indices.contains(segment.queueIndex) {
                currentIndex = segment.queueIndex
                currentTrack = queue[segment.queueIndex]
                duration = Double(segment.seekOffsetFrames + segment.frameCount) / segment.sampleRate
                orderPosition = playOrder.firstIndex(of: segment.queueIndex) ?? orderPosition
            }
        }
        prefetchIfNeeded()
    }

    // MARK: - EQ

    private func applyEQ() {
        for (i, gain) in eqGains.enumerated() where i < eq.bands.count {
            eq.bands[i].gain = max(-12, min(12, gain))
        }
    }

    public func resetEQ() { eqGains = Array(repeating: 0, count: 10) }

    // MARK: - Spectrum

    /// Taps the mixer and reduces each buffer to a small set of log-spaced magnitude
    /// bands — the data behind the block-character visualiser in the now-playing bar.
    private func installSpectrumTap() {
        let mixer = engine.mainMixerNode
        let fftSize = 1024
        guard let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self) else { return }

        mixer.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: nil) {
            [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let count = min(Int(buffer.frameLength), fftSize)
            guard count == fftSize else { return }

            var windowed = [Float](repeating: 0, count: fftSize)
            var window = [Float](repeating: 0, count: fftSize)
            vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
            vDSP_vmul(channel, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

            var real = [Float](repeating: 0, count: fftSize / 2)
            var imag = [Float](repeating: 0, count: fftSize / 2)
            var magnitudes = [Float](repeating: 0, count: fftSize / 2)

            real.withUnsafeMutableBufferPointer { realPtr in
                imag.withUnsafeMutableBufferPointer { imagPtr in
                    var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    windowed.withUnsafeBufferPointer { inPtr in
                        inPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                        }
                    }
                    fft.forward(input: split, output: &split)
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
                }
            }

            let bands = Self.foldIntoBands(magnitudes, bandCount: Self.bandCount)
            Task { @MainActor [weak self] in self?.applySpectrum(bands) }
        }
    }

    /// Log-spaced buckets, because linear FFT bins put almost everything in the first
    /// few bars and the visualiser looks dead.
    public static func foldIntoBands(_ magnitudes: [Float], bandCount: Int) -> [Float] {
        guard !magnitudes.isEmpty, bandCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: bandCount)
        let binCount = magnitudes.count
        for band in 0..<bandCount {
            let lo = Double(band) / Double(bandCount)
            let hi = Double(band + 1) / Double(bandCount)
            let start = Int(pow(Double(binCount), lo)) - 1
            let end = Int(pow(Double(binCount), hi))
            let range = max(0, min(start, binCount - 1))...max(0, min(max(end, start + 1), binCount - 1))
            let slice = magnitudes[range]
            let peak = slice.max() ?? 0
            // Compress to something that reads well as bar height.
            out[band] = min(1, sqrt(peak) * 0.55)
        }
        return out
    }

    private func applySpectrum(_ bands: [Float]) {
        guard bands.count == spectrum.count else { spectrum = bands; return }
        // Fast attack, slow release — bars that fall instantly look like noise.
        var smoothed = spectrum
        for i in bands.indices {
            smoothed[i] = bands[i] > smoothed[i]
                ? bands[i]
                : smoothed[i] * 0.82 + bands[i] * 0.18
        }
        spectrum = smoothed
    }
}

// MARK: - Source resolution

/// AVAudioFile handles mp3/aac/alac/wav/aiff/flac natively. Anything else is decoded
/// to a temporary CAF by ffmpeg and cached, so Opus and Ogg Vorbis still play.
///
/// Decoded PCM is large — roughly 10 MB per minute — so the cache is capped and the
/// least recently used files are evicted rather than left to grow without limit.
public enum SourceResolver {
    public static let nativeFormats: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "alac", "wav", "aiff", "aif", "caf", "flac",
    ]

    /// Ceiling for decoded PCM held on disk.
    public static let maxCacheBytes: Int64 = 4 << 30  // 4 GB

    public static var cacheDirectory: URL {
        let dir = Config.cacheDirectory.appendingPathComponent("decoded", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func needsDecoding(_ url: URL) -> Bool {
        !nativeFormats.contains(url.pathExtension.lowercased())
    }

    public static func playableURL(for track: Track) async throws -> URL {
        guard needsDecoding(track.url) else { return track.url }

        // FNV-1a rather than hashValue: Swift's hashValue is seeded per process, so a
        // cached file would never be found again after a restart.
        let stamp = "\(track.url.path)|\(track.fileSize)|\(Int(track.modified.timeIntervalSince1970))"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in stamp.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        let target = cacheDirectory.appendingPathComponent(String(format: "%016llx.caf", hash))

        if FileManager.default.fileExists(atPath: target.path) {
            // Touch it so eviction treats it as recently used.
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: target.path)
            return target
        }

        do {
            try await Shell.runChecked("ffmpeg", [
                "-v", "error", "-y", "-i", track.url.path,
                "-c:a", "pcm_s16le", "-f", "caf", target.path,
            ])
        } catch {
            // A partial file would be treated as a valid cache hit next time.
            try? FileManager.default.removeItem(at: target)
            throw error
        }

        pruneCache()
        return target
    }

    public static func cacheSize() -> Int64 {
        entries().reduce(0) { $0 + $1.size }
    }

    public static func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    /// Drops the oldest files until the cache is back under the ceiling.
    static func pruneCache() {
        var all = entries()
        var total = all.reduce(Int64(0)) { $0 + $1.size }
        guard total > maxCacheBytes else { return }

        all.sort { $0.accessed < $1.accessed }
        for entry in all {
            guard total > maxCacheBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private struct Entry {
        let url: URL
        let size: Int64
        let accessed: Date
    }

    private static func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: keys) else { return [] }
        return contents.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return Entry(
                url: url,
                size: Int64(values.fileSize ?? 0),
                accessed: values.contentModificationDate ?? .distantPast)
        }
    }
}

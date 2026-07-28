import Foundation

/// A generated spectrum for when the real one cannot exist.
///
/// Apple Music and Spotify play in their own processes, so there is no audio passing
/// through Deck to analyse. This produces something that moves like a spectrum instead:
/// decorative, not measured. It is labelled as such in the UI rather than passed off as
/// analysis.
///
/// What makes it read as music rather than noise:
///  - a spectral tilt, since real music has far more energy at the bottom;
///  - several detuned oscillators per band, so neighbours drift rather than march;
///  - a periodic emphasis on the low bands, which the eye reads as a beat;
///  - a per-track seed, so two tracks do not animate identically.
public struct SyntheticSpectrum: Sendable {
    public let bandCount: Int
    private let seed: UInt64
    /// Per-band oscillator rates and phases, derived once from the seed.
    private let rates: [Float]
    private let phases: [Float]
    private let tilt: [Float]
    /// Beats per second for the low-end pulse.
    private let beatRate: Float

    public init(seed: UInt64, bandCount: Int = Spectrum.bandCount) {
        self.bandCount = max(1, bandCount)
        self.seed = seed

        var generator = SplitMix64(seed: seed &+ 0x9E37_79B9_7F4A_7C15)

        // 96–132 bpm covers most of what people listen to, and the eye is not fussy.
        beatRate = (96 + generator.nextUnit() * 36) / 60

        var rates: [Float] = []
        var phases: [Float] = []
        var tilt: [Float] = []
        rates.reserveCapacity(self.bandCount)
        phases.reserveCapacity(self.bandCount)
        tilt.reserveCapacity(self.bandCount)

        for band in 0..<self.bandCount {
            let position = Float(band) / Float(max(self.bandCount - 1, 1))
            // Higher bands flicker faster, the way real treble content does.
            rates.append(1.1 + position * 3.4 + generator.nextUnit() * 1.2)
            phases.append(generator.nextUnit() * 6.283)
            // Roughly a -12 dB/decade slope, flattened so the top is not dead.
            tilt.append(0.5 + 0.5 * pow(1 - position, 0.8))
        }
        self.rates = rates
        self.phases = phases
        self.tilt = tilt
    }

    /// Band levels at a point in time.
    ///
    /// `intensity` scales the whole thing, so playback can fade it in and pause can fade
    /// it out rather than freezing mid-animation.
    public func levels(at time: TimeInterval, intensity: Float = 1) -> [Float] {
        guard intensity > 0.001 else { return [Float](repeating: 0, count: bandCount) }
        let t = Float(time)

        // Sharp attack, exponential decay — a plausible transient.
        let beatPhase = (t * beatRate).truncatingRemainder(dividingBy: 1)
        let beat = exp(-beatPhase * 5.5)

        var out = [Float](repeating: 0, count: bandCount)
        for band in 0..<bandCount {
            let rate = rates[band]
            let phase = phases[band]

            // Three detuned components stop the whole row moving as one.
            let a = sin(t * rate + phase)
            let b = sin(t * rate * 0.47 + phase * 1.7)
            let c = sin(t * rate * 2.13 + phase * 0.4)
            let wobble = (a * 0.5 + b * 0.32 + c * 0.18) * 0.58 + 0.5

            // The pulse lands mostly on the bass, as it does in real material.
            let position = Float(band) / Float(max(bandCount - 1, 1))
            let beatWeight = pow(1 - position, 2.2)
            let level = (wobble * 0.95 + beat * beatWeight * 0.55) * tilt[band]

            out[band] = min(1, max(0, level * intensity))
        }
        return out
    }
}

/// Small deterministic generator, so a given track always animates the same way.
/// Foundation's RNG is seeded per process and would differ between launches.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0..<1
    mutating func nextUnit() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }
}

public extension SyntheticSpectrum {
    /// Seeds from a track identifier so each track has its own motion, stable across
    /// launches.
    static func forTrack(_ identifier: String, bandCount: Int = Spectrum.bandCount) -> SyntheticSpectrum {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in identifier.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return SyntheticSpectrum(seed: hash, bandCount: bandCount)
    }
}

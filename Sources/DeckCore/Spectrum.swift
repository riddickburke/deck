import Foundation

/// Turns raw FFT magnitudes into the bar heights the visualisers draw.
///
/// Lives outside the player because both front ends render a spectrum but obtain the
/// samples differently, and the shaping should be identical either way.
public enum Spectrum {
    /// How many bars the visualisers draw.
    public static let bandCount = 28

    /// How loudness maps to bar height.
    ///
    /// Hearing is logarithmic, so bars have to be driven in decibels. The original code
    /// used `sqrt(magnitude) * 0.55` on raw vDSP output, where a full-scale tone through
    /// a 1024-point FFT peaks near 256 — that is `sqrt(256) * 0.55 ≈ 8.8`, clamped to 1.
    /// Every bar sat at maximum for anything louder than silence.
    public struct Scaling: Sendable, Equatable {
        /// Magnitude treated as 0 dBFS. For a Hann-windowed real FFT computed through
        /// `vDSP_ctoz` this is about `fftSize / 4`: the window has a coherent gain of
        /// 0.5, and the split-complex packing halves it again.
        public var reference: Float
        /// Below this the bar is empty.
        public var floorDecibels: Float
        /// At or above this the bar is full.
        public var ceilingDecibels: Float

        public init(reference: Float, floorDecibels: Float = -78, ceilingDecibels: Float = -22) {
            self.reference = reference
            self.floorDecibels = floorDecibels
            self.ceilingDecibels = ceilingDecibels
        }

        /// Builds a scaling from a 0...1 sensitivity dial.
        ///
        /// A single band of real music sits well below full scale, because the energy is
        /// spread across the spectrum, so the useful ceiling is far under 0 dBFS.
        ///
        /// More sensitive means a *lower* ceiling: less signal is needed to fill a bar.
        /// Getting this backwards is what makes a visualiser sit permanently at maximum.
        public static func forSensitivity(_ sensitivity: Double, fftSize: Int) -> Scaling {
            let clamped = Float(max(0, min(1, sensitivity)))
            let ceiling = -6 - clamped * 30            // 0.0 -> -6 dB, 1.0 -> -36 dB
            return Scaling(
                reference: Float(fftSize) / 4,
                floorDecibels: ceiling - 56,
                ceilingDecibels: ceiling)
        }
    }

    /// Log-spaced buckets, because linear FFT bins put almost everything in the first
    /// few bars and the visualiser looks dead.
    public static func foldIntoBands(
        _ magnitudes: [Float],
        bandCount: Int = bandCount,
        scaling: Scaling
    ) -> [Float] {
        guard !magnitudes.isEmpty, bandCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: bandCount)
        let binCount = magnitudes.count
        let span = max(scaling.ceilingDecibels - scaling.floorDecibels, 0.001)

        for band in 0..<bandCount {
            let lo = Double(band) / Double(bandCount)
            let hi = Double(band + 1) / Double(bandCount)
            let start = Int(pow(Double(binCount), lo)) - 1
            let end = Int(pow(Double(binCount), hi))
            let range = max(0, min(start, binCount - 1))
                ... max(0, min(max(end, start + 1), binCount - 1))

            let peak = magnitudes[range].max() ?? 0
            out[band] = level(for: peak, scaling: scaling, span: span)
        }
        return out
    }

    /// Magnitude to 0...1 bar height, through decibels.
    public static func level(for magnitude: Float, scaling: Scaling, span: Float? = nil) -> Float {
        let range = span ?? max(scaling.ceilingDecibels - scaling.floorDecibels, 0.001)
        let normalized = magnitude / max(scaling.reference, .leastNormalMagnitude)
        // Floor the input so log10 cannot return -inf on a silent band.
        let decibels = 20 * log10(max(normalized, 1e-9))
        return max(0, min(1, (decibels - scaling.floorDecibels) / range))
    }

    /// Fast attack, slow release. Bars that fall instantly read as noise rather than music.
    public static func smooth(
        previous: [Float], toward next: [Float], release: Float = 0.82
    ) -> [Float] {
        guard previous.count == next.count else { return next }
        var out = previous
        for i in next.indices {
            out[i] = next[i] > out[i] ? next[i] : out[i] * release + next[i] * (1 - release)
        }
        return out
    }
}

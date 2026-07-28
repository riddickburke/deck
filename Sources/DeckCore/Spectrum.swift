import Foundation

/// Turns raw FFT magnitudes into the small set of bar heights the visualisers draw.
///
/// Lives outside the player because both front ends render a spectrum but obtain the
/// samples very differently — the macOS build taps AVAudioEngine's mixer, the Linux
/// build reads mpv's audio filter output — and the shaping should be identical either way.
public enum Spectrum {
    /// How many bars the visualisers draw.
    public static let bandCount = 28

    /// Log-spaced buckets, because linear FFT bins put almost everything in the first
    /// few bars and the visualiser looks dead.
    public static func foldIntoBands(_ magnitudes: [Float], bandCount: Int = bandCount) -> [Float] {
        guard !magnitudes.isEmpty, bandCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: bandCount)
        let binCount = magnitudes.count

        for band in 0..<bandCount {
            let lo = Double(band) / Double(bandCount)
            let hi = Double(band + 1) / Double(bandCount)
            let start = Int(pow(Double(binCount), lo)) - 1
            let end = Int(pow(Double(binCount), hi))
            let range = max(0, min(start, binCount - 1))
                ... max(0, min(max(end, start + 1), binCount - 1))
            let peak = magnitudes[range].max() ?? 0
            // Compress to something that reads well as bar height.
            out[band] = min(1, sqrt(peak) * 0.55)
        }
        return out
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

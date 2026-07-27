import Foundation

/// FLAC to MP3 conversion for the device copy only.
///
/// The user's original file is never read-modified-written — output goes to a cache
/// directory and only the cached copy is transferred. Re-syncing an unchanged album
/// therefore costs nothing after the first conversion.
public enum Transcoder {
    public static var cacheDirectory: URL {
        let dir = Config.cacheDirectory.appendingPathComponent("transcoded", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Formats worth converting. Lossy sources are already small and re-encoding them
    /// only loses quality, so they are always copied as-is.
    public static let convertibleFormats: Set<String> = ["flac", "alac", "wav", "aiff", "aif", "ape", "wv"]

    public static func shouldConvert(_ track: Track, config: Config) -> Bool {
        guard config.convertFlacToMP3 else { return false }
        return convertibleFormats.contains(track.url.pathExtension.lowercased())
    }

    public static func cachedURL(for track: Track, quality: Int) -> URL {
        let stamp = "\(track.url.path)|\(track.fileSize)|\(Int(track.modified.timeIntervalSince1970))|q\(quality)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in stamp.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return cacheDirectory.appendingPathComponent(String(format: "%016llx.mp3", hash))
    }

    /// Converts if the cached output is missing, otherwise returns it immediately.
    @discardableResult
    public static func transcodeToMP3(
        _ track: Track,
        quality: Int,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let output = cachedURL(for: track, quality: quality)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: output.path),
           let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0 {
            return output
        }

        let duration = track.duration
        let args = [
            "-v", "error", "-y",
            "-i", track.url.path,
            "-map", "0:a:0",
            // Carry the embedded cover across if there is one; `?` makes it optional.
            "-map", "0:v:0?",
            "-c:a", "libmp3lame", "-q:a", String(quality),
            "-c:v", "mjpeg", "-disposition:v:0", "attached_pic",
            "-map_metadata", "0",
            "-id3v2_version", "3",
            "-write_id3v1", "1",
            "-progress", "pipe:2", "-nostats",
            output.path,
        ]

        do {
            try await Shell.runChecked("ffmpeg", args) { line in
                guard let onProgress, duration > 0,
                      line.hasPrefix("out_time_ms=")
                else { return }
                let raw = line.dropFirst("out_time_ms=".count)
                guard let micros = Double(raw) else { return }
                onProgress(min(1, micros / 1_000_000 / duration))
            }
        } catch {
            // A partial file would be treated as a valid cache hit next time.
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    public static func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    public static func cacheSize() -> Int64 {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return entries.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Resolves album art in a fixed precedence: embedded in the file, then a cover image
/// sitting beside it, then an online lookup. Results are cached on disk so the second
/// launch never re-extracts or re-downloads.
///
/// The store deals in raw image `Data`, not a platform image type, so the same code
/// serves the macOS and Linux front ends. Decoding and drawing belong to the UI layer.
///
/// Nothing here writes to the user's library. Fetched art lands in the app cache only.
public actor ArtworkStore {
    public static let shared = ArtworkStore()

    private var memory: [AlbumKey: Data] = [:]
    private var misses: Set<AlbumKey> = []
    private var inFlight: [AlbumKey: Task<Data?, Never>] = [:]

    /// Bounded so a large library cannot pin every cover in RAM at once.
    private static let memoryLimit = 120
    private var recency: [AlbumKey] = []

    private var cacheDir: URL {
        let dir = Config.cacheDirectory.appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static let folderArtNames = [
        "cover", "folder", "front", "album", "albumart", "artwork", "thumb",
    ]
    static let imageExtensions = ["jpg", "jpeg", "png", "webp", "bmp"]

    // MARK: - Lookup

    public func artworkData(for album: Album, allowNetwork: Bool = true) async -> Data? {
        let key = album.key
        if let hit = memory[key] { touch(key); return hit }
        if misses.contains(key) { return nil }
        if let running = inFlight[key] { return await running.value }

        let task = Task<Data?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.resolve(album: album, allowNetwork: allowNetwork)
        }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil

        if let data { store(key, data) } else { misses.insert(key) }
        return data
    }

    private func store(_ key: AlbumKey, _ data: Data) {
        memory[key] = data
        touch(key)
        while recency.count > Self.memoryLimit, let oldest = recency.first {
            recency.removeFirst()
            memory[oldest] = nil
        }
    }

    private func touch(_ key: AlbumKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func resolve(album: Album, allowNetwork: Bool) async -> Data? {
        let cacheFile = cachePath(for: album.key)

        // 0. Previously resolved and written to our own cache.
        if let data = try? Data(contentsOf: cacheFile), !data.isEmpty { return data }

        // 1. Embedded in one of the album's files.
        for track in album.tracks.prefix(3) {
            if let data = await Self.embeddedArtwork(in: track.url), !data.isEmpty {
                try? data.write(to: cacheFile, options: .atomic)
                return data
            }
        }

        // 2. A cover image sitting in the album directory.
        if let dir = album.directory, let url = Self.folderArtwork(in: dir),
           let data = try? Data(contentsOf: url), !data.isEmpty {
            try? data.write(to: cacheFile, options: .atomic)
            return data
        }

        // 3. Online.
        guard allowNetwork else { return nil }
        if let data = await OnlineMetadata.shared.artwork(
            album: album.title, artist: album.artist), !data.isEmpty {
            try? data.write(to: cacheFile, options: .atomic)
            return data
        }
        return nil
    }

    /// Adopts artwork obtained elsewhere — for example from Music.app over Apple
    /// Events — so it participates in the same memory and disk cache as everything else.
    public func store(_ data: Data, for key: AlbumKey) {
        guard !data.isEmpty else { return }
        try? data.write(to: cachePath(for: key), options: .atomic)
        store(key, data)
        misses.remove(key)
    }

    public func cachePath(for key: AlbumKey) -> URL {
        let raw = "\(key.artist.lowercased())::\(key.album.lowercased())"
        return cacheDir.appendingPathComponent("\(StableHash.hex(raw)).jpg")
    }

    /// Forgets a cached result so the next request re-resolves it.
    public func invalidate(_ key: AlbumKey) {
        memory[key] = nil
        recency.removeAll { $0 == key }
        misses.remove(key)
        try? FileManager.default.removeItem(at: cachePath(for: key))
    }

    public func clearAll() {
        memory.removeAll()
        recency.removeAll()
        misses.removeAll()
        try? FileManager.default.removeItem(at: cacheDir)
    }

    // MARK: - Derived forms

    /// Square-cropped JPEG sized for a player's screen. Rockbox targets have small
    /// displays and limited RAM, so a 3000px cover must never reach the device.
    public func deviceArtwork(for album: Album, maxDimension: Int) async -> Data? {
        guard let source = await artworkData(for: album) else { return nil }
        return await ImageOps.square(source, size: maxDimension)
    }

    /// Average colour of the art, used to tint album headers the way Spotify does.
    public func dominantColor(for album: Album) async -> RGB? {
        guard let data = await artworkData(for: album) else { return nil }
        return await ImageOps.dominantColor(data)
    }

    // MARK: - Sources

    /// Pulls the attached picture stream out via ffmpeg, re-encoding to JPEG so we get
    /// one predictable format regardless of what was embedded.
    static func embeddedArtwork(in url: URL) async -> Data? {
        if Shell.has("ffmpeg") {
            let args = [
                "-v", "quiet", "-i", url.path,
                "-an", "-map", "0:v:0", "-c:v", "mjpeg",
                "-f", "image2pipe", "-",
            ]
            if let r = try? await Shell.run("ffmpeg", args), r.ok, !r.stdout.isEmpty {
                return r.stdout
            }
        }
        #if canImport(AVFoundation)
        // Fallback for mp3/m4a on an Apple machine without ffmpeg.
        return await avFoundationArtwork(url)
        #else
        return nil
        #endif
    }

    #if canImport(AVFoundation)
    private static func avFoundationArtwork(_ url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue) { return data }
        }
        return nil
    }
    #endif

    public static func folderArtwork(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return nil }

        let images = entries.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        guard !images.isEmpty else { return nil }

        // Prefer conventional names in priority order, then fall back to any image.
        for name in folderArtNames {
            if let match = images.first(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(name)
            }) { return match }
        }
        return images.first
    }
}

// MARK: - Portable image operations

/// Image work done by shelling out to ffmpeg rather than a platform imaging framework,
/// so resizing and colour sampling behave identically on macOS and Linux. ffmpeg is
/// already required for tags and conversion, so this adds no new dependency.
public enum ImageOps {
    /// Aspect-fills into a square and re-encodes as JPEG.
    public static func square(_ data: Data, size: Int, quality: Int = 3) async -> Data? {
        guard Shell.has("ffmpeg") else { return nil }
        let filter = "scale=\(size):\(size):force_original_aspect_ratio=increase,"
            + "crop=\(size):\(size)"
        return await pipe(
            data,
            args: ["-v", "error", "-i", "pipe:0", "-vf", filter,
                   "-q:v", String(quality), "-f", "mjpeg", "pipe:1"])
    }

    /// Averages an 8×8 reduction, skipping near-black and near-white pixels so the tint
    /// comes from actual colour rather than the letterboxing or a white sleeve.
    public static func dominantColor(_ data: Data) async -> RGB? {
        guard Shell.has("ffmpeg") else { return nil }
        guard let raw = await pipe(
            data,
            args: ["-v", "error", "-i", "pipe:0", "-vf", "scale=8:8",
                   "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"]),
            raw.count >= 3
        else { return nil }

        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        let bytes = [UInt8](raw)
        for i in stride(from: 0, to: bytes.count - 2, by: 3) {
            let pr = Double(bytes[i]) / 255
            let pg = Double(bytes[i + 1]) / 255
            let pb = Double(bytes[i + 2]) / 255
            let brightness = (pr + pg + pb) / 3
            guard brightness > 0.08, brightness < 0.97 else { continue }
            r += pr; g += pg; b += pb; n += 1
        }
        guard n > 0 else { return nil }
        return RGB(String(
            format: "#%02x%02x%02x",
            Int(r / n * 255), Int(g / n * 255), Int(b / n * 255)))
    }

    /// Natural pixel dimensions, or nil if the data is not a readable image.
    public static func size(_ data: Data) async -> (width: Int, height: Int)? {
        guard Shell.has("ffprobe") else { return nil }
        let result = try? await Shell.runWithInput(
            "ffprobe", ["-v", "error", "-select_streams", "v:0",
                        "-show_entries", "stream=width,height",
                        "-of", "csv=p=0", "-i", "pipe:0"],
            input: data)
        guard let text = result?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              case let parts = text.split(separator: ","),
              parts.count == 2,
              let w = Int(parts[0]), let h = Int(parts[1])
        else { return nil }
        return (w, h)
    }

    private static func pipe(_ data: Data, args: [String]) async -> Data? {
        guard let result = try? await Shell.runWithInput("ffmpeg", args, input: data),
              result.ok, !result.stdout.isEmpty
        else { return nil }
        return result.stdout
    }
}

// MARK: - Apple convenience

#if canImport(AppKit)
public extension ArtworkStore {
    /// NSImage wrapper for the macOS front end.
    func artwork(for album: Album, allowNetwork: Bool = true) async -> NSImage? {
        guard let data = await artworkData(for: album, allowNetwork: allowNetwork) else { return nil }
        return NSImage(data: data)
    }
}

public extension NSImage {
    /// Square-crops, scales and encodes JPEG using AppKit, avoiding an ffmpeg round trip
    /// when one is already holding a decoded image.
    func jpegData(maxDimension: Int, quality: Double = 0.85) -> Data? {
        let side = CGFloat(maxDimension)
        let output = NSImage(size: NSSize(width: side, height: side))
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        let sourceSize = size
        guard sourceSize.width > 0, sourceSize.height > 0 else { output.unlockFocus(); return nil }
        let scale = max(side / sourceSize.width, side / sourceSize.height)
        let scaled = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let origin = NSPoint(x: (side - scaled.width) / 2, y: (side - scaled.height) / 2)
        draw(in: NSRect(origin: origin, size: scaled),
             from: NSRect(origin: .zero, size: sourceSize),
             operation: .copy, fraction: 1)
        output.unlockFocus()

        guard let tiff = output.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Average colour of the art, used to tint album hero headers.
    var dominantColor: NSColor? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let w = min(rep.pixelsWide, 32), h = min(rep.pixelsHigh, 32)
        guard w > 0, h > 0 else { return nil }

        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        let stepX = max(rep.pixelsWide / w, 1), stepY = max(rep.pixelsHigh / h, 1)
        for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let brightness = c.brightnessComponent
                guard brightness > 0.08, brightness < 0.97 else { continue }
                r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
            }
        }
        guard n > 0 else { return nil }
        return NSColor(red: r / n, green: g / n, blue: b / n, alpha: 1)
    }
}
#endif

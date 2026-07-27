import AVFoundation
import AppKit
import CryptoKit
import Foundation

/// Resolves album art in a fixed precedence: embedded in the file, then a cover
/// image sitting beside it, then an online lookup. Results are cached on disk so
/// the second launch never re-extracts or re-downloads.
///
/// Nothing here writes to the user's library. Fetched art lands in the app cache only.
public actor ArtworkStore {
    public static let shared = ArtworkStore()

    private var memory: [AlbumKey: NSImage] = [:]
    private var misses: Set<AlbumKey> = []
    private var inFlight: [AlbumKey: Task<NSImage?, Never>] = [:]

    private var cacheDir: URL {
        let dir = Config.cacheDirectory.appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static let folderArtNames = [
        "cover", "folder", "front", "album", "albumart", "artwork", "thumb",
    ]
    static let imageExtensions = ["jpg", "jpeg", "png", "webp", "bmp"]

    public func artwork(for album: Album, allowNetwork: Bool = true) async -> NSImage? {
        let key = album.key
        if let hit = memory[key] { return hit }
        if misses.contains(key) { return nil }
        if let running = inFlight[key] { return await running.value }

        let task = Task<NSImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.resolve(album: album, allowNetwork: allowNetwork)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image { memory[key] = image } else { misses.insert(key) }
        return image
    }

    private func resolve(album: Album, allowNetwork: Bool) async -> NSImage? {
        let key = album.key

        // 0. Previously resolved and written to our own cache.
        let cacheFile = cachePath(for: key)
        if let image = NSImage(contentsOf: cacheFile) { return image }

        // 1. Embedded in one of the album's files.
        for track in album.tracks.prefix(3) {
            if let data = await Self.embeddedArtwork(in: track.url), let image = NSImage(data: data) {
                try? data.write(to: cacheFile, options: .atomic)
                return image
            }
        }

        // 2. A cover image sitting in the album directory.
        if let dir = album.directory, let url = Self.folderArtwork(in: dir),
           let image = NSImage(contentsOf: url) {
            if let data = try? Data(contentsOf: url) { try? data.write(to: cacheFile, options: .atomic) }
            return image
        }

        // 3. Online.
        guard allowNetwork else { return nil }
        if let data = await OnlineMetadata.shared.artwork(album: album.title, artist: album.artist),
           let image = NSImage(data: data) {
            try? data.write(to: cacheFile, options: .atomic)
            return image
        }
        return nil
    }

    public func cachePath(for key: AlbumKey) -> URL {
        let raw = "\(key.artist.lowercased())::\(key.album.lowercased())"
        let digest = SHA256.hash(data: Data(raw.utf8))
        let name = digest.compactMap { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(name).jpg")
    }

    /// Forgets a cached result so the next request re-resolves it.
    public func invalidate(_ key: AlbumKey) {
        memory[key] = nil
        misses.remove(key)
        try? FileManager.default.removeItem(at: cachePath(for: key))
    }

    public func clearAll() {
        memory.removeAll()
        misses.removeAll()
        try? FileManager.default.removeItem(at: cacheDir)
    }

    // MARK: - Sources

    /// Pulls the attached picture stream out via ffmpeg, re-encoding to JPEG so we
    /// get one predictable format regardless of what was embedded.
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
        // AVFoundation fallback covers mp3/m4a on a machine without ffmpeg.
        return await avFoundationArtwork(url)
    }

    private static func avFoundationArtwork(_ url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue) { return data }
        }
        return nil
    }

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

// MARK: - Resizing (used when writing art to the device)

public extension NSImage {
    /// Square-crops and scales, then encodes JPEG. Rockbox targets have small screens
    /// and limited RAM, so we never ship a 3000px cover to the device.
    func jpegData(maxDimension: Int, quality: Double = 0.85) -> Data? {
        let side = CGFloat(maxDimension)
        let target = NSSize(width: side, height: side)

        let output = NSImage(size: target)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        // Aspect-fill into a square so covers are never letterboxed.
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

    /// Average colour of the art, used to tint album hero headers the way Spotify does.
    var dominantColor: NSColor? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let w = min(rep.pixelsWide, 32), h = min(rep.pixelsHigh, 32)
        guard w > 0, h > 0 else { return nil }

        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        let stepX = max(rep.pixelsWide / w, 1), stepY = max(rep.pixelsHigh / h, 1)
        for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                // Skip near-black and near-white so the tint comes from real colour.
                let brightness = c.brightnessComponent
                guard brightness > 0.08, brightness < 0.97 else { continue }
                r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
            }
        }
        guard n > 0 else { return nil }
        return NSColor(red: r / n, green: g / n, blue: b / n, alpha: 1)
    }
}

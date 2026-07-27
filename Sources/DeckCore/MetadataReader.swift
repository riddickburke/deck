import AVFoundation
import Foundation

/// Reads tags off disk. ffprobe is the primary reader because it understands Vorbis
/// comments in FLAC/Ogg/Opus, which AVFoundation on macOS does not surface. AVAsset is
/// the fallback so the app still works on a machine without ffmpeg installed.
public enum MetadataReader {
    public static let audioExtensions: Set<String> = [
        "mp3", "flac", "m4a", "m4b", "aac", "ogg", "oga", "opus",
        "wav", "aiff", "aif", "alac", "wma", "ape", "wv", "mpc",
    ]

    public static func isAudioFile(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    public static func read(_ url: URL) async -> Track? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attrs?[.modificationDate] as? Date ?? .distantPast

        if Shell.has("ffprobe"), let track = await readViaFFprobe(url, size: size, modified: modified) {
            return track
        }
        return await readViaAVAsset(url, size: size, modified: modified)
    }

    // MARK: - ffprobe

    private static func readViaFFprobe(_ url: URL, size: Int64, modified: Date) async -> Track? {
        let args = [
            "-v", "quiet", "-print_format", "json",
            "-show_format", "-show_streams", "-i", url.path,
        ]
        guard let result = try? await Shell.run("ffprobe", args), result.ok,
              let probe = try? JSONDecoder().decode(FFProbeOutput.self, from: result.stdout)
        else { return nil }

        let audio = probe.streams.first { $0.codec_type == "audio" }
        guard let audio else { return nil }

        // Tags live in format.tags for most containers but in stream.tags for
        // Ogg/Opus. Merge with format winning, and match keys case-insensitively.
        var tags = Tags()
        tags.merge(audio.tags ?? [:])
        tags.merge(probe.format.tags ?? [:])

        let duration = Double(probe.format.duration ?? "") ?? Double(audio.duration ?? "") ?? 0
        let bitrate = Int(probe.format.bit_rate ?? "").map { $0 / 1000 }
            ?? Int(audio.bit_rate ?? "").map { $0 / 1000 }

        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let artist = tags["artist"] ?? tags["albumartist"] ?? Track.unknown
        let albumArtist = tags["albumartist"] ?? tags["album_artist"] ?? artist

        return Track(
            url: url,
            title: tags["title"] ?? fallbackTitle,
            artist: artist,
            albumArtist: albumArtist,
            album: tags["album"] ?? inferAlbumFromPath(url),
            genre: tags["genre"],
            year: parseYear(tags["date"] ?? tags["year"] ?? tags["originaldate"]),
            trackNumber: parseIndex(tags["track"] ?? tags["tracknumber"]),
            discNumber: parseIndex(tags["disc"] ?? tags["discnumber"]) ?? 1,
            duration: duration,
            bitrate: bitrate,
            sampleRate: Int(audio.sample_rate ?? ""),
            channels: audio.channels,
            codec: audio.codec_name ?? url.pathExtension.lowercased(),
            fileSize: size,
            modified: modified,
            mbid: tags["musicbrainz_trackid"] ?? tags["musicbrainz_recordingid"]
        )
    }

    // MARK: - AVAsset fallback

    private static func readViaAVAsset(_ url: URL, size: Int64, modified: Date) async -> Track? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }

        var title: String?, artist: String?, album: String?, albumArtist: String?
        var genre: String?, year: Int?, trackNumber: Int?

        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                let value = try? await item.load(.stringValue)
                switch key {
                case .commonKeyTitle: title = value
                case .commonKeyArtist: artist = value
                case .commonKeyAlbumName: album = value
                case .commonKeyCreator where albumArtist == nil: albumArtist = value
                case .commonKeyType: genre = value
                case .commonKeyCreationDate: year = parseYear(value)
                default: break
                }
            }
        }
        // Track number lives in the format-specific metadata, not commonMetadata.
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                guard let items = try? await asset.loadMetadata(for: format) else { continue }
                for item in items {
                    let key = item.identifier?.rawValue.lowercased() ?? ""
                    guard key.contains("track") || key.contains("trkn") else { continue }
                    if let n = try? await item.load(.numberValue) { trackNumber = n.intValue }
                    else if let s = try? await item.load(.stringValue) { trackNumber = parseIndex(s) }
                }
            }
        }

        let resolvedArtist = artist ?? albumArtist ?? Track.unknown
        return Track(
            url: url,
            title: title ?? url.deletingPathExtension().lastPathComponent,
            artist: resolvedArtist,
            albumArtist: albumArtist ?? resolvedArtist,
            album: album ?? inferAlbumFromPath(url),
            genre: genre,
            year: year,
            trackNumber: trackNumber,
            discNumber: 1,
            duration: duration.seconds.isFinite ? duration.seconds : 0,
            bitrate: nil,
            sampleRate: nil,
            channels: nil,
            codec: url.pathExtension.lowercased(),
            fileSize: size,
            modified: modified
        )
    }

    // MARK: - Parsing

    /// A `Music/Artist/Album/01 Track.flac` layout is the common case, so an untagged
    /// file can still land in the right album rather than a giant "unknown" bucket.
    public static func inferAlbumFromPath(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? Track.unknown : parent
    }

    /// Handles `7`, `07`, `7/12`, and `07 of 12`.
    public static func parseIndex(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let head = raw.split(whereSeparator: { $0 == "/" || $0 == " " }).first.map(String.init) ?? raw
        return Int(head.trimmingCharacters(in: .whitespaces).prefix(4))
    }

    /// Handles `2007`, `2007-05-01`, and `05/01/2007`.
    public static func parseYear(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        // First run of exactly four digits that looks like a plausible year.
        var digits = ""
        for ch in raw {
            if ch.isNumber { digits.append(ch) } else {
                if let y = plausibleYear(digits) { return y }
                digits = ""
            }
        }
        return plausibleYear(digits)
    }

    private static func plausibleYear(_ s: String) -> Int? {
        guard s.count == 4, let y = Int(s), (1900...2200).contains(y) else { return nil }
        return y
    }
}

// MARK: - ffprobe JSON shapes

private struct FFProbeOutput: Decodable {
    struct Stream: Decodable {
        let codec_type: String?
        let codec_name: String?
        let sample_rate: String?
        let channels: Int?
        let bit_rate: String?
        let duration: String?
        let tags: [String: String]?
    }
    struct Format: Decodable {
        let duration: String?
        let bit_rate: String?
        let tags: [String: String]?
    }
    let streams: [Stream]
    let format: Format
}

/// Case-insensitive tag bag. Tag casing is wildly inconsistent across formats
/// (`TITLE` in FLAC, `title` in MP4, `Title` from some taggers).
private struct Tags {
    private var storage: [String: String] = [:]

    mutating func merge(_ other: [String: String]) {
        for (k, v) in other {
            let value = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            storage[k.lowercased().replacingOccurrences(of: "-", with: "_")] = value
        }
    }

    subscript(key: String) -> String? { storage[key] }
}

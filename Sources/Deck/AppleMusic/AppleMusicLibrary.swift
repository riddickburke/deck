import DeckCore
import Foundation

/// Reads the Music.app library, including Apple Music subscription tracks.
///
/// Everything is fetched with `get <property> of every track`, which is one Apple Event
/// per property rather than one per track. On a 4,300 track library that is well under a
/// second; asking track by track would take minutes.
///
/// This needs no MusicKit entitlement and no paid developer account — only the user's
/// consent to send Apple events to Music, which macOS prompts for on first use.
enum AppleMusicLibrary {
    struct ImportProgress: Sendable {
        var stage: String
        var imported: Int
    }

    /// Cloud statuses that mean the track streams from Apple Music rather than existing
    /// as a file. `unknown` covers ordinary local files.
    static let streamingStatuses: Set<String> = [
        "subscription", "matched", "uploaded", "purchased", "prerelease",
    ]

    static func importLibrary(
        progress: @Sendable @escaping (ImportProgress) -> Void = { _ in }
    ) async throws -> [Track] {
        progress(ImportProgress(stage: "reading library", imported: 0))

        // `location` is deliberately absent: asking for it in bulk fails outright when
        // any track streams, because a streaming track has no file and AppleScript
        // errors on the whole request rather than returning a gap.
        // Variables are prefixed because Music.app's dictionary defines `artist`,
        // `album` and friends as classes; a plain `set artists to ...` is parsed as an
        // attempt to assign to the class and fails with -10003.
        let script = AppleEvents.music("""
            set fs to (ASCII character 31)
            set rs to (ASCII character 30)
            set lib to library playlist 1
            set vIDs to (get database ID of every track of lib)
            set vTitles to (get name of every track of lib)
            set vArtists to (get artist of every track of lib)
            set vAlbumArtists to (get album artist of every track of lib)
            set vAlbums to (get album of every track of lib)
            set vDurations to (get duration of every track of lib)
            set vNumbers to (get track number of every track of lib)
            set vDiscs to (get disc number of every track of lib)
            set vYears to (get year of every track of lib)
            set vGenres to (get genre of every track of lib)
            set vStatuses to (get cloud status of every track of lib)

            -- Joining each list with `as text` uses AppleScript's own join, which is
            -- linear. Building one delimited string in a repeat loop is quadratic and
            -- took 16 seconds on a 4,000 track library; this takes about one.
            set AppleScript's text item delimiters to fs
            set out to (vIDs as text) & rs & (vTitles as text) & rs & ¬
                (vArtists as text) & rs & (vAlbumArtists as text) & rs & ¬
                (vAlbums as text) & rs & (vDurations as text) & rs & ¬
                (vNumbers as text) & rs & (vDiscs as text) & rs & ¬
                (vYears as text) & rs & (vGenres as text) & rs & ¬
                (vStatuses as text)
            set AppleScript's text item delimiters to ""
            return out
            """)

        let raw = try await AppleEvents.run(script)
        let tracks = parse(raw)
        progress(ImportProgress(stage: "imported", imported: tracks.count))
        return tracks
    }

    /// Parses the column-major payload: one record per property, each a delimited list.
    static func parse(_ raw: String) -> [Track] {
        let columns = raw.components(separatedBy: AppleEvents.recordSeparator)
            .map { $0.components(separatedBy: AppleEvents.fieldSeparator) }
        guard columns.count >= 11, let count = columns.first?.count else { return [] }

        func value(_ column: Int, _ row: Int) -> String {
            let c = columns[column]
            return row < c.count ? c[row] : ""
        }

        var tracks: [Track] = []
        tracks.reserveCapacity(count)

        for row in 0..<count {
            let id = value(0, row).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id != "0" else { continue }

            let artist = clean(value(2, row)) ?? Track.unknown
            let status = value(10, row).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            var track = Track(
                source: .appleMusic,
                externalID: id,
                title: clean(value(1, row)) ?? Track.unknown,
                artist: artist,
                albumArtist: clean(value(3, row)) ?? artist,
                album: clean(value(4, row)) ?? Track.unknown,
                genre: clean(value(9, row)),
                year: positive(value(8, row)),
                trackNumber: positive(value(6, row)),
                discNumber: positive(value(7, row)),
                duration: Double(value(5, row).trimmingCharacters(in: .whitespaces)) ?? 0,
                // The cloud status is kept as the codec label so the UI can show what a
                // track actually is: subscription, matched, uploaded or a plain file.
                codec: status.isEmpty ? "unknown" : status)
            track.source = .appleMusic
            tracks.append(track)
        }
        return tracks
    }

    /// True when Apple reports the track as cloud-backed rather than a plain local file.
    static func isCloudBacked(_ track: Track) -> Bool {
        streamingStatuses.contains(track.codec.lowercased())
    }

    private static func positive(_ raw: String) -> Int? {
        guard let value = Int(raw.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value
    }

    /// AppleScript yields `missing value` for an unset property, which must not become
    /// a literal title.
    private static func clean(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "missing value" else { return nil }
        return value
    }

    /// The user's own playlists, with their track ids in playlist order.
    ///
    /// Smart playlists and the service's editorial playlists are included when Music
    /// exposes them; the built-in ones (Library, Music, Downloaded) are filtered out
    /// because they duplicate the whole library.
    static func importPlaylists() async throws -> (
        playlists: [ServicePlaylist], tracks: [Track]
    ) {
        // Names and ids come back in one event; the track ids need one event per
        // playlist, which is why the count is fetched first and empty ones skipped.
        let namesScript = AppleEvents.music("""
            set fs to (ASCII character 31)
            set rs to (ASCII character 30)
            set vLists to (every user playlist)
            set vNames to {}
            set vIDs to {}
            set vCounts to {}
            repeat with pl in vLists
                set end of vNames to (name of pl)
                set end of vIDs to ((persistent ID of pl) as text)
                set end of vCounts to (count of tracks of pl)
            end repeat
            set AppleScript's text item delimiters to fs
            set out to (vNames as text) & rs & (vIDs as text) & rs & (vCounts as text)
            set AppleScript's text item delimiters to ""
            return out
            """)

        let raw = try await AppleEvents.run(namesScript)
        let columns = raw.components(separatedBy: AppleEvents.recordSeparator)
            .map { $0.components(separatedBy: AppleEvents.fieldSeparator) }
        guard columns.count >= 3 else { return ([], []) }

        let names = columns[0], ids = columns[1], counts = columns[2]
        var playlists: [ServicePlaylist] = []
        var discovered: [Track] = []
        var seenTrackIDs = Set<String>()
        // Music can list the same playlist more than once, for example when a shared
        // playlist also appears under a different source.
        var seenPlaylistIDs = Set<String>()

        for index in 0..<min(names.count, min(ids.count, counts.count)) {
            let name = names[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let id = ids[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let count = Int(counts[index].trimmingCharacters(in: .whitespaces)) ?? 0

            guard !name.isEmpty, !id.isEmpty, count > 0,
                  !builtInPlaylistNames.contains(name.lowercased()),
                  seenPlaylistIDs.insert(id).inserted
            else { continue }

            // Full metadata, not just ids: a playlist routinely contains tracks the user
            // never added to their library, and those are absent from the library import.
            // Resolving against the library alone dropped most of some playlists.
            let contents = await tracks(inPlaylistWithPersistentID: id)
            guard !contents.isEmpty else { continue }

            playlists.append(ServicePlaylist(
                id: id, name: name, source: .appleMusic,
                trackIDs: contents.compactMap(\.externalID)))

            for track in contents {
                guard let trackID = track.externalID,
                      seenTrackIDs.insert(trackID).inserted else { continue }
                discovered.append(track)
            }
        }
        // Music can surface one playlist under two persistent ids — a shared or synced
        // list appearing under more than one source. Matching on name plus identical
        // contents collapses those without merging two genuinely different playlists
        // that happen to share a name.
        var unique: [ServicePlaylist] = []
        var fingerprints = Set<String>()
        for playlist in playlists {
            let fingerprint = "\(playlist.name)|\(playlist.trackIDs.joined(separator: ","))"
            guard fingerprints.insert(fingerprint).inserted else { continue }
            unique.append(playlist)
        }

        return (
            unique.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            discovered)
    }

    /// Music's own containers, which mirror the library rather than being real playlists.
    static let builtInPlaylistNames: Set<String> = [
        "library", "music", "downloaded", "recently added", "recently played",
        "movies", "tv shows", "podcasts", "audiobooks", "purchased",
    ]

    /// One playlist's tracks with full metadata, in playlist order.
    static func tracks(inPlaylistWithPersistentID id: String) async -> [Track] {
        let script = AppleEvents.music("""
            set fs to (ASCII character 31)
            set rs to (ASCII character 30)
            set matches to (every user playlist whose persistent ID is "\(id)")
            if (count of matches) is 0 then return ""
            set pl to item 1 of matches
            set vIDs to (get database ID of every track of pl)
            set vTitles to (get name of every track of pl)
            set vArtists to (get artist of every track of pl)
            set vAlbumArtists to (get album artist of every track of pl)
            set vAlbums to (get album of every track of pl)
            set vDurations to (get duration of every track of pl)
            set vNumbers to (get track number of every track of pl)
            set vDiscs to (get disc number of every track of pl)
            set vYears to (get year of every track of pl)
            set vGenres to (get genre of every track of pl)
            set vStatuses to (get cloud status of every track of pl)
            set AppleScript's text item delimiters to fs
            set out to (vIDs as text) & rs & (vTitles as text) & rs & ¬
                (vArtists as text) & rs & (vAlbumArtists as text) & rs & ¬
                (vAlbums as text) & rs & (vDurations as text) & rs & ¬
                (vNumbers as text) & rs & (vDiscs as text) & rs & ¬
                (vYears as text) & rs & (vGenres as text) & rs & ¬
                (vStatuses as text)
            set AppleScript's text item delimiters to ""
            return out
            """)
        guard let raw = try? await AppleEvents.run(script), !raw.isEmpty else { return [] }
        return parse(raw)
    }

    /// Artwork for one track, as JPEG/PNG data. Fetched per album rather than per track
    /// because the data is large and identical across an album.
    static func artwork(forTrackID id: String) async -> Data? {
        // `raw data` is binary, and osascript renders it as a hex literal that is lossy
        // to recover. Having AppleScript write the bytes to a file and reading that back
        // keeps them exact.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-art-\(id)-\(UUID().uuidString).jpg")

        let script = AppleEvents.music("""
            set matches to (every track of library playlist 1 whose database ID is \(id))
            if (count of matches) is 0 then return "none"
            set t to item 1 of matches
            if (count of artworks of t) is 0 then return "none"
            set d to (get raw data of artwork 1 of t)
            set f to open for access POSIX file "\(temp.path)" with write permission
            set eof f to 0
            write d to f
            close access f
            return "ok"
            """)

        guard let result = try? await AppleEvents.run(script), result == "ok" else { return nil }
        defer { try? FileManager.default.removeItem(at: temp) }
        return try? Data(contentsOf: temp)
    }
}

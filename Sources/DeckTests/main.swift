import AVFoundation
import DeckCore
import Foundation

// MARK: - Helpers

func makeTrack(
    title: String = "Idioteque", artist: String = "Radiohead",
    albumArtist: String? = nil, album: String = "Kid A",
    track: Int? = 7, disc: Int? = 1, ext: String = "flac", duration: Double = 200
) -> Track {
    Track(
        url: URL(fileURLWithPath: "/lib/\(title).\(ext)"),
        title: title, artist: artist, albumArtist: albumArtist ?? artist, album: album,
        trackNumber: track, discNumber: disc, duration: duration,
        codec: ext, fileSize: 1000, modified: Date())
}

let testDevice = RockboxDevice(
    mountPoint: URL(fileURLWithPath: "/Volumes/IPOD"), volumeName: "IPOD",
    rockboxVersion: "3.15", target: "ipodvideo",
    totalCapacity: 1000, availableCapacity: 500, hasRockbox: true)

/// Writes a real, tagged audio file using ffmpeg so the reader has something genuine to parse.
func makeAudio(
    at url: URL, title: String, artist: String, album: String,
    track: Int, seconds: Double = 1
) async throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try await Shell.runChecked("ffmpeg", [
        "-v", "error", "-y",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
        "-metadata", "title=\(title)",
        "-metadata", "artist=\(artist)",
        "-metadata", "album=\(album)",
        "-metadata", "track=\(track)",
        url.path,
    ])
}

// MARK: - FAT-safe filenames

T.suite("FAT-safe filenames")

await T.test("strips characters FAT rejects") {
    T.equal(SyncEngine.sanitize("AC/DC"), "AC_DC")
    T.equal(SyncEngine.sanitize("a:b*c\"d<e>f|g"), "a_b_c_d_e_f_g")
}

await T.test("strips trailing dots and spaces") {
    // FAT silently corrupts these, so they must never reach the device.
    T.equal(SyncEngine.sanitize("Album..."), "Album")
    T.equal(SyncEngine.sanitize("Track   "), "Track")
}

await T.test("escapes names reserved by the DOS lineage") {
    T.equal(SyncEngine.sanitize("CON"), "_CON")
    T.equal(SyncEngine.sanitize("nul"), "_nul")
}

await T.test("never produces an empty component") {
    T.equal(SyncEngine.sanitize("///"), "Untitled")
    T.equal(SyncEngine.sanitize("   "), "Untitled")
}

await T.test("caps length so deep paths stay legal") {
    T.equal(SyncEngine.sanitize(String(repeating: "x", count: 300)).count, 90)
}

// MARK: - Destination paths

T.suite("Device destination paths")

await T.test("builds Music/Artist/Album/NN Title.ext") {
    let url = SyncEngine.destinationURL(
        for: makeTrack(), device: testDevice,
        template: "{albumartist}/{album}", asMP3: false)
    T.equal(url.path, "/Volumes/IPOD/Music/Radiohead/Kid A/07 Idioteque.flac")
}

await T.test("conversion changes only the extension") {
    let url = SyncEngine.destinationURL(
        for: makeTrack(), device: testDevice,
        template: "{albumartist}/{album}", asMP3: true)
    T.equal(url.lastPathComponent, "07 Idioteque.mp3")
}

await T.test("multi-disc albums get a disc prefix") {
    let url = SyncEngine.destinationURL(
        for: makeTrack(disc: 2), device: testDevice,
        template: "{albumartist}/{album}", asMP3: false)
    T.expect(url.lastPathComponent.hasPrefix("2-07 "), "got \(url.lastPathComponent)")
}

await T.test("single-disc albums get no disc prefix") {
    let url = SyncEngine.destinationURL(
        for: makeTrack(disc: 1), device: testDevice,
        template: "{albumartist}/{album}", asMP3: false)
    T.expect(url.lastPathComponent.hasPrefix("07 "), "got \(url.lastPathComponent)")
}

await T.test("a slash in the artist does not create a directory") {
    // "AC/DC" must stay one path component rather than becoming a nested folder.
    let url = SyncEngine.destinationURL(
        for: makeTrack(artist: "AC/DC"), device: testDevice,
        template: "{albumartist}/{album}", asMP3: false)
    T.expect(url.path.contains("AC_DC"), "expected sanitised artist, got \(url.path)")
    T.expect(!url.path.contains("AC/DC"), "artist slash leaked into the path")
}

await T.test("template tokens are honoured") {
    let url = SyncEngine.destinationURL(
        for: makeTrack(), device: testDevice,
        template: "{artist} - {album} ({year})", asMP3: false)
    T.expect(url.path.contains("Radiohead - Kid A"), "got \(url.path)")
}

// MARK: - Tag parsing

T.suite("Tag parsing")

await T.test("reads every common track-index form") {
    for (input, expected) in [("7", 7), ("07", 7), ("7/12", 7), ("07 of 12", 7)] {
        T.equal(MetadataReader.parseIndex(input), expected, "parseIndex(\(input))")
    }
    T.isNil(MetadataReader.parseIndex(nil), "parseIndex(nil)")
}

await T.test("reads every common date form") {
    for (input, expected) in [("2000", 2000), ("2000-10-02", 2000), ("02/10/2000", 2000)] {
        T.equal(MetadataReader.parseYear(input), expected, "parseYear(\(input))")
    }
}

await T.test("rejects values that are not plausible years") {
    T.isNil(MetadataReader.parseYear("not a year"), "parseYear(text)")
    T.isNil(MetadataReader.parseYear("42"), "parseYear(42)")
}

await T.test("recovers artist and title from a filename") {
    let a = OnlineMetadata.parseArtistTitle(from: "Radiohead - Idioteque")
    T.equal(a?.artist, "Radiohead")
    T.equal(a?.title, "Idioteque")

    // A leading track number must be stripped before splitting.
    let b = OnlineMetadata.parseArtistTitle(from: "07 - Radiohead - Idioteque")
    T.equal(b?.artist, "Radiohead")
    T.equal(b?.title, "Idioteque")

    T.isNil(OnlineMetadata.parseArtistTitle(from: "justafilename"), "unsplittable name")
}

await T.test("escapes Lucene syntax in search terms") {
    // An unescaped colon would be read as a field separator and break the query.
    T.equal(OnlineMetadata.lucene("A:B"), "\"A\\:B\"")
    T.equal(OnlineMetadata.lucene("plain"), "\"plain\"")
}

await T.test("flags tracks that need an online lookup") {
    T.expect(makeTrack(artist: Track.unknown).needsMetadata, "unknown artist should need metadata")
    T.expect(!makeTrack().needsMetadata, "fully tagged track should not need metadata")
}

// MARK: - Grouping

T.suite("Album grouping")

await T.test("compilations group under the album artist") {
    let tracks = [
        makeTrack(title: "A", artist: "One", albumArtist: "Various", album: "Mix", track: 1),
        makeTrack(title: "B", artist: "Two", albumArtist: "Various", album: "Mix", track: 2),
    ]
    let albums = LibraryGrouping.albums(from: tracks)
    T.equal(albums.count, 1, "compilation should be one album")
    T.equal(albums[0].tracks.count, 2)
}

await T.test("tracks order by disc then number") {
    let tracks = [
        makeTrack(title: "D2T1", album: "A", track: 1, disc: 2),
        makeTrack(title: "D1T2", album: "A", track: 2, disc: 1),
        makeTrack(title: "D1T1", album: "A", track: 1, disc: 1),
    ]
    T.equal(
        LibraryGrouping.albums(from: tracks)[0].tracks.map(\.title),
        ["D1T1", "D1T2", "D2T1"])
}

await T.test("album keys normalise surrounding whitespace") {
    T.equal(
        AlbumKey(album: " Kid A ", artist: "Radiohead"),
        AlbumKey(album: "Kid A", artist: "Radiohead"))
}

// MARK: - Spectrum

T.suite("Spectrum folding")

await T.test("folds FFT bins into normalised bands") {
    let bands = Player.foldIntoBands((0..<512).map { Float($0) / 512 }, bandCount: 28)
    T.equal(bands.count, 28)
    T.expect(bands.allSatisfy { $0 >= 0 && $0 <= 1 }, "bands must be normalised to 0...1")
}

await T.test("handles empty input without crashing") {
    T.expect(Player.foldIntoBands([], bandCount: 28).isEmpty, "empty input should give no bands")
}

// MARK: - Sync planning

T.suite("Sync planning")

await T.test("plan marks conversions only when the option is on") {
    var config = Config.default
    config.convertFlacToMP3 = true
    T.expect(
        Transcoder.shouldConvert(makeTrack(ext: "flac"), config: config),
        "flac should convert when enabled")
    T.expect(
        !Transcoder.shouldConvert(makeTrack(ext: "mp3"), config: config),
        "already-lossy files must never be re-encoded")

    config.convertFlacToMP3 = false
    T.expect(
        !Transcoder.shouldConvert(makeTrack(ext: "flac"), config: config),
        "no conversion when the option is off")
}

await T.test("capacity headroom is computed from the transfer size") {
    let plan = SyncPlan(
        actions: [SyncAction(
            track: makeTrack(), destination: URL(fileURLWithPath: "/Volumes/IPOD/a.flac"),
            kind: .copy, estimatedBytes: 400)],
        orphans: [], device: testDevice, playlists: [])
    T.equal(plan.bytesToTransfer, 400)
    T.equal(plan.headroomAfterSync, 100)
    T.expect(plan.fits, "400 bytes should fit in 500 free")
}

await T.test("a plan larger than free space does not fit") {
    let plan = SyncPlan(
        actions: [SyncAction(
            track: makeTrack(), destination: URL(fileURLWithPath: "/Volumes/IPOD/a.flac"),
            kind: .copy, estimatedBytes: 900)],
        orphans: [], device: testDevice, playlists: [])
    T.expect(!plan.fits, "900 bytes must not fit in 500 free")
    T.equal(plan.headroomAfterSync, -400)
}

await T.test("only files we recorded can be orphaned") {
    // Files the user placed on the device by hand must never be deletion candidates.
    let dir = try Fixture.tempDirectory("orphan")
    defer { Fixture.remove(dir) }

    let ours = dir.appendingPathComponent("ours.mp3")
    let theirs = dir.appendingPathComponent("user-put-this-here.mp3")
    try Data("x".utf8).write(to: ours)
    try Data("x".utf8).write(to: theirs)

    var manifest = Manifest()
    manifest.entries[ours.path] = Manifest.Stamp(
        sourcePath: "/lib/a.flac", sourceSize: 1,
        sourceModified: 0, converted: false, quality: -1)

    let orphans = SyncEngine.findOrphans(manifest: manifest, expected: [])
    T.equal(orphans.map(\.path), [ours.path])
    T.expect(!orphans.contains(theirs), "a file we never wrote must not be deletable")
}

// MARK: - Identifier migration

T.suite("Legacy data migration")

/// Builds a fake Library base containing `<base>/<bundleID>/<files>`.
func seedSupportDir(_ base: URL, bundle: String, files: [String: String]) throws {
    let dir = base.appendingPathComponent(bundle, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, contents) in files {
        try Data(contents.utf8).write(to: dir.appendingPathComponent(name))
    }
}

func readSupportFile(_ base: URL, bundle: String, _ name: String) -> String? {
    try? String(
        contentsOf: base.appendingPathComponent(bundle).appendingPathComponent(name),
        encoding: .utf8)
}

await T.test("moves settings and index across when the new location is absent") {
    let base = try Fixture.tempDirectory("migrate-fresh")
    defer { Fixture.remove(base) }

    try seedSupportDir(base, bundle: "old.id", files: [
        "config.json": "{\"themeID\":\"nord\"}",
        "index.json": "[1,2,3]",
        "playlists.json": "[]",
    ])

    Config.migrate(bases: [base], from: "old.id", to: "new.id")

    T.equal(readSupportFile(base, bundle: "new.id", "config.json"), "{\"themeID\":\"nord\"}")
    T.equal(readSupportFile(base, bundle: "new.id", "index.json"), "[1,2,3]")
    T.expect(
        !FileManager.default.fileExists(
            atPath: base.appendingPathComponent("old.id").path),
        "old directory should be gone after the move")
}

await T.test("merges into a directory that exists but is empty") {
    // `appSupportDirectory` creates the new folder as a side effect of reading a path,
    // so the destination frequently exists and is empty by the time migration runs.
    let base = try Fixture.tempDirectory("migrate-empty-dest")
    defer { Fixture.remove(base) }

    try seedSupportDir(base, bundle: "old.id", files: ["config.json": "kept"])
    try FileManager.default.createDirectory(
        at: base.appendingPathComponent("new.id"), withIntermediateDirectories: true)

    Config.migrate(bases: [base], from: "old.id", to: "new.id")

    T.equal(readSupportFile(base, bundle: "new.id", "config.json"), "kept")
    T.expect(
        !FileManager.default.fileExists(atPath: base.appendingPathComponent("old.id").path),
        "old directory should be removed after merging")
}

await T.test("never clobbers data already under the new identifier") {
    let base = try Fixture.tempDirectory("migrate-conflict")
    defer { Fixture.remove(base) }

    try seedSupportDir(base, bundle: "old.id", files: ["config.json": "OLD"])
    try seedSupportDir(base, bundle: "new.id", files: ["config.json": "NEW"])

    Config.migrate(bases: [base], from: "old.id", to: "new.id")

    T.equal(readSupportFile(base, bundle: "new.id", "config.json"), "NEW", "existing data wins")
    T.equal(readSupportFile(base, bundle: "old.id", "config.json"), "OLD", "old data left intact")
}

await T.test("is a no-op when there is nothing to migrate") {
    let base = try Fixture.tempDirectory("migrate-none")
    defer { Fixture.remove(base) }

    Config.migrate(bases: [base], from: "old.id", to: "new.id")

    T.expect(
        !FileManager.default.fileExists(atPath: base.appendingPathComponent("new.id").path),
        "should not create a destination when there is no source")
}

await T.test("running twice is safe") {
    let base = try Fixture.tempDirectory("migrate-twice")
    defer { Fixture.remove(base) }

    try seedSupportDir(base, bundle: "old.id", files: ["config.json": "once"])
    Config.migrate(bases: [base], from: "old.id", to: "new.id")
    Config.migrate(bases: [base], from: "old.id", to: "new.id")

    T.equal(readSupportFile(base, bundle: "new.id", "config.json"), "once")
}

// MARK: - Artwork discovery

T.suite("Folder artwork discovery")

await T.test("prefers conventional cover names over any image") {
    let dir = try Fixture.tempDirectory("art")
    defer { Fixture.remove(dir) }
    try Data("x".utf8).write(to: dir.appendingPathComponent("zzz-random.png"))
    try Data("x".utf8).write(to: dir.appendingPathComponent("cover.jpg"))
    T.equal(ArtworkStore.folderArtwork(in: dir)?.lastPathComponent, "cover.jpg")
}

await T.test("returns nil when the folder has no images") {
    let dir = try Fixture.tempDirectory("art-empty")
    defer { Fixture.remove(dir) }
    T.isNil(ArtworkStore.folderArtwork(in: dir), "artwork in empty dir")
}

// MARK: - Device detection

T.suite("Rockbox device detection")

await T.test("parses rockbox-info.txt") {
    let dir = try Fixture.tempDirectory("rbinfo")
    defer { Fixture.remove(dir) }
    let rockbox = dir.appendingPathComponent(".rockbox")
    try FileManager.default.createDirectory(at: rockbox, withIntermediateDirectories: true)
    try """
    Version: 3.15
    Target: ipodvideo
    Memory: 64
    """.write(to: rockbox.appendingPathComponent("rockbox-info.txt"),
              atomically: true, encoding: .utf8)

    let info = DeviceScanner.readInfo(rockbox)
    T.equal(info.version, "3.15")
    T.equal(info.target, "ipodvideo")
}

await T.test("missing info file yields no version") {
    let dir = try Fixture.tempDirectory("rbinfo-missing")
    defer { Fixture.remove(dir) }
    let info = DeviceScanner.readInfo(dir)
    T.isNil(info.version, "version")
    T.isNil(info.target, "target")
}

// MARK: - Integration

T.suite("Scan and transcode (integration)")

if !Shell.has("ffmpeg") {
    T.skip("library scan", "ffmpeg not installed")
    T.skip("rescan cache", "ffmpeg not installed")
    T.skip("non-audio filtering", "ffmpeg not installed")
    T.skip("non-destructive transcode", "ffmpeg not installed")
} else {
    await T.test("scanner reads tags and groups them into an album") {
        let root = try Fixture.tempDirectory("scan")
        defer { Fixture.remove(root) }

        let dir = root.appendingPathComponent("Artist/Album")
        try await makeAudio(
            at: dir.appendingPathComponent("01.flac"),
            title: "First", artist: "Test Artist", album: "Test Album", track: 1)
        try await makeAudio(
            at: dir.appendingPathComponent("02.flac"),
            title: "Second", artist: "Test Artist", album: "Test Album", track: 2)

        let cache = root.appendingPathComponent("index.json")
        let tracks = await LibraryScanner(cacheURL: cache).scan(roots: [root]) { _ in }
        T.equal(tracks.count, 2, "both files should be indexed")

        let albums = LibraryGrouping.albums(from: tracks)
        T.equal(albums.count, 1, "album count")
        T.equal(albums[0].title, "Test Album")
        T.equal(albums[0].artist, "Test Artist")
        T.equal(albums[0].tracks.map(\.title), ["First", "Second"])
        T.equal(albums[0].tracks.map(\.trackNumber), [1, 2])
        T.expect(albums[0].isLossless, "flac should register as lossless")
        T.expect(
            FileManager.default.fileExists(atPath: cache.path),
            "index should be written to disk")
    }

    await T.test("a rescan serves unchanged files from cache") {
        let root = try Fixture.tempDirectory("rescan")
        defer { Fixture.remove(root) }

        try await makeAudio(
            at: root.appendingPathComponent("a/one.flac"),
            title: "One", artist: "A", album: "B", track: 1)

        let cache = root.appendingPathComponent("index.json")
        _ = await LibraryScanner(cacheURL: cache).scan(roots: [root]) { _ in }

        let fresh = LibraryScanner(cacheURL: cache)
        await fresh.loadCache()
        nonisolated(unsafe) var hits = 0
        let tracks = await fresh.scan(roots: [root]) { progress in hits = progress.fromCache }

        T.equal(tracks.count, 1)
        T.equal(hits, 1, "unchanged file should come from cache rather than a fresh probe")
    }

    await T.test("non-audio files are ignored") {
        let root = try Fixture.tempDirectory("filter")
        defer { Fixture.remove(root) }

        try await makeAudio(
            at: root.appendingPathComponent("song.mp3"),
            title: "S", artist: "A", album: "B", track: 1)
        try Data("not audio".utf8).write(to: root.appendingPathComponent("readme.txt"))
        try Data("not audio".utf8).write(to: root.appendingPathComponent("cover.jpg"))

        let tracks = await LibraryScanner(cacheURL: root.appendingPathComponent("index.json"))
            .scan(roots: [root]) { _ in }
        T.equal(tracks.count, 1, "only the audio file should be indexed")
        T.equal(tracks[0].codec, "mp3")
    }

    await T.test("native formats play straight from disk") {
        // No decode step for anything Core Audio already understands.
        for ext in ["mp3", "flac", "m4a", "wav", "aiff"] {
            T.expect(
                !SourceResolver.needsDecoding(URL(fileURLWithPath: "/x/a.\(ext)")),
                "\(ext) should not need decoding")
        }
        for ext in ["opus", "ogg", "wma", "ape"] {
            T.expect(
                SourceResolver.needsDecoding(URL(fileURLWithPath: "/x/a.\(ext)")),
                "\(ext) should need decoding")
        }
    }

    await T.test("opus decodes to something AVAudioFile can actually open") {
        // Opus is the single largest format in a real library here and Core Audio
        // cannot open it, so this path carries most playback.
        let root = try Fixture.tempDirectory("opus")
        defer { Fixture.remove(root) }

        let source = root.appendingPathComponent("tone.opus")
        try await makeAudio(
            at: source, title: "O", artist: "A", album: "B", track: 1, seconds: 2)

        guard let track = T.notNil(await MetadataReader.read(source), "read opus") else { return }
        T.equal(track.codec, "opus", "codec")

        let playable = try await SourceResolver.playableURL(for: track)
        T.expect(playable != source, "opus should be redirected to a decoded file")
        T.equal(playable.pathExtension, "caf")
        defer { try? FileManager.default.removeItem(at: playable) }

        let file = try AVAudioFile(forReading: playable)
        T.expect(file.length > 0, "decoded file should contain audio frames")
        T.expect(
            file.processingFormat.sampleRate > 0,
            "decoded file should report a usable format")

        // A second request must reuse the cached decode rather than re-running ffmpeg.
        let again = try await SourceResolver.playableURL(for: track)
        T.equal(again.path, playable.path, "decode should be cached across calls")
    }

    await T.test("playlist reaches the device in playlist order, not sorted order") {
        // The order is deliberately scrambled against every other order the code could
        // accidentally impose: not alphabetical by title, not by track number, not by
        // filename. If anything sorts along the way, this fails.
        let root = try Fixture.tempDirectory("playlist-order")
        let device = try Fixture.tempDirectory("playlist-device")
        defer { Fixture.remove(root); Fixture.remove(device) }

        let specs = [
            (file: "c.flac", title: "Cool Song", number: 3),
            (file: "a.flac", title: "Alpha Song", number: 1),
            (file: "b.flac", title: "Beta Song", number: 2),
        ]
        for spec in specs {
            try await makeAudio(
                at: root.appendingPathComponent(spec.file),
                title: spec.title, artist: "Order Test", album: "Ordering",
                track: spec.number)
        }

        let scanner = LibraryScanner(cacheURL: root.appendingPathComponent("index.json"))
        let scanned = await scanner.scan(roots: [root]) { _ in }
        T.equal(scanned.count, 3, "all three files indexed")

        // Build the playlist in the scrambled order 3, 1, 2.
        let byTitle = Dictionary(uniqueKeysWithValues: scanned.map { ($0.title, $0) })
        let wanted = ["Cool Song", "Alpha Song", "Beta Song"]
        let ordered = wanted.compactMap { byTitle[$0] }
        T.equal(ordered.count, 3, "resolved all playlist tracks")

        let playlist = Playlist(
            name: "Scrambled", trackPaths: ordered.map(\.url.path), syncEnabled: true)

        let target = RockboxDevice(
            mountPoint: device, volumeName: "TESTDEV",
            rockboxVersion: "3.15", target: "test",
            totalCapacity: 1 << 30, availableCapacity: 1 << 30, hasRockbox: true)

        var config = Config.default
        config.convertFlacToMP3 = false
        config.writeDeviceArtwork = false

        let engine = SyncEngine()
        let plan = await engine.plan(
            tracks: ordered, playlists: [playlist], device: target, config: config)
        T.equal(plan.transfers.count, 3, "three files to transfer")

        let report = await engine.execute(
            plan: plan, config: config, removeOrphans: false,
            artworkFor: { _ in nil }, progress: { _ in })
        T.equal(report.errors.count, 0, "sync errors: \(report.errors)")
        T.equal(report.playlistsWritten, 1, "playlist written")

        let m3u = device.appendingPathComponent("Playlists/Scrambled.m3u8")
        guard let contents = T.notNil(
            try? String(contentsOf: m3u, encoding: .utf8), "m3u8 file") else { return }

        let entries = contents
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }

        T.equal(entries.count, 3, "three playlist entries")
        T.equal(
            entries,
            ["/Music/Order Test/Ordering/03 Cool Song.flac",
             "/Music/Order Test/Ordering/01 Alpha Song.flac",
             "/Music/Order Test/Ordering/02 Beta Song.flac"],
            "entries must follow playlist order, not track/alphabetical order")

        // Rockbox resolves these against the card root, so they must be absolute
        // device-relative paths with forward slashes.
        for entry in entries {
            T.expect(entry.hasPrefix("/"), "entry should be root-relative: \(entry)")
            T.expect(!entry.contains("\\"), "entry must not use backslashes: \(entry)")
            T.expect(
                FileManager.default.fileExists(
                    atPath: device.appendingPathComponent(entry).path),
                "entry should point at a file that exists: \(entry)")
        }
    }

    await T.test("a track missing from the device is dropped, not silently reordered") {
        // If a track cannot be placed, the remaining entries must keep their relative
        // order rather than shifting into a different sequence.
        let root = try Fixture.tempDirectory("playlist-gap")
        let device = try Fixture.tempDirectory("playlist-gap-device")
        defer { Fixture.remove(root); Fixture.remove(device) }

        for (i, name) in ["one", "two", "three"].enumerated() {
            try await makeAudio(
                at: root.appendingPathComponent("\(name).flac"),
                title: name, artist: "Gap", album: "Gap", track: i + 1)
        }

        let scanner = LibraryScanner(cacheURL: root.appendingPathComponent("index.json"))
        let scanned = await scanner.scan(roots: [root]) { _ in }
        let byTitle = Dictionary(uniqueKeysWithValues: scanned.map { ($0.title, $0) })
        guard let one = byTitle["one"], let two = byTitle["two"], let three = byTitle["three"]
        else { return T.fail("could not resolve generated tracks") }

        // The playlist references all three, but only two are actually synced.
        let playlist = Playlist(
            name: "Gapped",
            trackPaths: [three.url.path, two.url.path, one.url.path],
            syncEnabled: true)

        let target = RockboxDevice(
            mountPoint: device, volumeName: "TESTDEV", rockboxVersion: nil, target: nil,
            totalCapacity: 1 << 30, availableCapacity: 1 << 30, hasRockbox: true)

        var config = Config.default
        config.writeDeviceArtwork = false

        let engine = SyncEngine()
        let plan = await engine.plan(
            tracks: [three, one], playlists: [playlist], device: target, config: config)
        _ = await engine.execute(
            plan: plan, config: config, removeOrphans: false,
            artworkFor: { _ in nil }, progress: { _ in })

        let m3u = device.appendingPathComponent("Playlists/Gapped.m3u8")
        guard let contents = T.notNil(
            try? String(contentsOf: m3u, encoding: .utf8), "m3u8 file") else { return }
        let entries = contents.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }

        T.equal(entries.count, 2, "only synced tracks should appear")
        T.equal(
            entries,
            ["/Music/Gap/Gap/03 three.flac", "/Music/Gap/Gap/01 one.flac"],
            "surviving entries must keep their relative playlist order")
    }

    await T.test("FLAC to MP3 leaves the original untouched") {
        // This is the core promise of the conversion option.
        let root = try Fixture.tempDirectory("transcode")
        defer { Fixture.remove(root) }

        let source = root.appendingPathComponent("lossless.flac")
        try await makeAudio(
            at: source, title: "T", artist: "A", album: "B", track: 1, seconds: 2)

        let before = try FileManager.default.attributesOfItem(atPath: source.path)
        let originalSize = (before[.size] as? NSNumber)?.int64Value

        guard let track = T.notNil(await MetadataReader.read(source), "read source") else { return }
        let mp3 = try await Transcoder.transcodeToMP3(track, quality: 4)
        defer { try? FileManager.default.removeItem(at: mp3) }

        T.expect(FileManager.default.fileExists(atPath: mp3.path), "mp3 should exist")
        T.equal(mp3.pathExtension, "mp3")

        let after = try FileManager.default.attributesOfItem(atPath: source.path)
        T.equal((after[.size] as? NSNumber)?.int64Value, originalSize, "original size changed")
        T.expect(
            FileManager.default.fileExists(atPath: source.path),
            "original must still exist")

        // The output must be a real MP3 the reader can parse back.
        let readBack = await MetadataReader.read(mp3)
        T.equal(readBack?.codec, "mp3")
        T.equal(readBack?.title, "T", "tags should carry across the conversion")
    }
}

exit(T.report())

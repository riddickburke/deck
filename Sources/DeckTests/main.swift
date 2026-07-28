import DeckCore
import Foundation

// SourceResolver and AVAudioFile are part of the Apple-only playback path.
#if canImport(AVFoundation)
import AVFoundation
#endif

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

let testScaling = Spectrum.Scaling(reference: 256, floorDecibels: -78, ceilingDecibels: -22)

await T.test("folds FFT bins into the requested number of bands") {
    let bands = Spectrum.foldIntoBands(
        (0..<512).map { Float($0) / 512 }, bandCount: 28, scaling: testScaling)
    T.equal(bands.count, 28)
    T.expect(bands.allSatisfy { $0 >= 0 && $0 <= 1 }, "bands must stay within 0...1")
}

await T.test("handles empty input without crashing") {
    T.expect(
        Spectrum.foldIntoBands([], bandCount: 28, scaling: testScaling).isEmpty,
        "empty input should give no bands")
}

await T.test("silence reads as empty rather than as a floor of noise") {
    let bands = Spectrum.foldIntoBands(
        [Float](repeating: 0, count: 512), bandCount: 28, scaling: testScaling)
    T.expect(bands.allSatisfy { $0 == 0 }, "silence must be flat, got \(bands.prefix(4))")
}

await T.test("a signal at the ceiling fills the bar, and one below it does not") {
    // The old mapping was sqrt(magnitude) * 0.55 on raw vDSP output, where a full-scale
    // tone peaks near 256 — that is 8.8, clamped to 1. Every bar sat at maximum for
    // anything above silence, which is exactly the reported symptom.
    //
    // With reference 256 and a -22 dB ceiling, the bar fills at 256 * 10^(-22/20) ≈ 20.3.
    T.equal(Spectrum.level(for: 256, scaling: testScaling), 1, "full scale is above the ceiling")
    T.equal(Spectrum.level(for: 21, scaling: testScaling), 1, "at the ceiling the bar is full")

    let midRange = Spectrum.level(for: 2, scaling: testScaling)
    T.expect(midRange < 0.85, "20 dB under the ceiling should not be full, got \(midRange)")
    T.expect(midRange > 0.15, "and should still be clearly visible, got \(midRange)")
}

await T.test("bar height rises monotonically across the operating range") {
    // Steps inside the floor..ceiling window, roughly 12 dB apart.
    let levels: [Float] = [0.05, 0.2, 0.8, 3, 12].map {
        Spectrum.level(for: $0, scaling: testScaling)
    }
    for (a, b) in zip(levels, levels.dropFirst()) {
        T.expect(b > a, "level must increase with magnitude: \(levels)")
    }
    T.expect(levels.first! < 0.3, "quietest step should sit low, got \(levels.first!)")
    T.expect(levels.last! > 0.85, "loudest step should sit high, got \(levels.last!)")
}

await T.test("sensitivity lowers the ceiling so quieter material fills the bar") {
    // Direction matters: a higher ceiling demands a louder signal. Inverting this is
    // what pins every bar to the top.
    let sensitive = Spectrum.Scaling.forSensitivity(1.0, fftSize: 1024)
    let dull = Spectrum.Scaling.forSensitivity(0.0, fftSize: 1024)

    T.expect(
        sensitive.ceilingDecibels < dull.ceilingDecibels,
        "more sensitive means a lower ceiling, got \(sensitive.ceilingDecibels) vs \(dull.ceilingDecibels)")
    T.equal(sensitive.reference, 256, "reference is fftSize/4 for a Hann-windowed real FFT")

    let magnitude: Float = 3
    T.expect(
        Spectrum.level(for: magnitude, scaling: sensitive)
            > Spectrum.level(for: magnitude, scaling: dull),
        "identical input should read higher on the sensitive setting")
}

await T.test("the shipped default does not saturate on ordinary material") {
    // The reported bug: bars permanently at maximum. A band sitting around -30 dBFS,
    // typical of real music, must land mid-scale rather than pinned.
    let scaling = Spectrum.Scaling.forSensitivity(0.35, fftSize: 1024)
    let typical = Spectrum.level(for: 256 * pow(10, -30 / 20), scaling: scaling)
    T.expect(typical < 0.9, "a -30 dB band should not be full, got \(typical)")
    T.expect(typical > 0.1, "a -30 dB band should still register, got \(typical)")
}

await T.test("smoothing attacks instantly and releases gradually") {
    let quiet = [Float](repeating: 0, count: 4)
    let loud = [Float](repeating: 1, count: 4)

    // A rising band jumps straight to the new level.
    T.equal(Spectrum.smooth(previous: quiet, toward: loud), loud, "attack should be instant")

    // A falling band decays rather than snapping to zero.
    let decayed = Spectrum.smooth(previous: loud, toward: quiet)
    T.expect(decayed.allSatisfy { $0 > 0 && $0 < 1 }, "release should be gradual, got \(decayed)")
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

// MARK: - PKCE

T.suite("SHA-256 and PKCE")

await T.test("matches the published SHA-256 vectors") {
    // Hand-written because CryptoKit is Apple-only. A wrong digest would not fail
    // loudly — Spotify would simply reject every sign-in — so it is checked against
    // the FIPS 180-4 examples.
    T.equal(
        SHA256.hex(""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "empty string")
    T.equal(
        SHA256.hex("abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "abc")
    T.equal(
        SHA256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
        "two-block message")
}

await T.test("handles a message that lands exactly on a block boundary") {
    // 56 bytes is the worst case for the padding rule: the length no longer fits in
    // the current block, so a whole extra block must be appended.
    T.equal(
        SHA256.hex(String(repeating: "a", count: 55)),
        "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
        "55 bytes")
    T.equal(
        SHA256.hex(String(repeating: "a", count: 56)),
        "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
        "56 bytes")
    T.equal(
        SHA256.hex(String(repeating: "a", count: 64)),
        "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
        "64 bytes")
}

await T.test("produces an unpadded base64url challenge") {
    // RFC 7636 requires base64url with the padding stripped.
    guard let challenge = T.notNil(
        PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
        "challenge") else { return }

    T.expect(!challenge.contains("="), "must be unpadded")
    T.expect(!challenge.contains("+") && !challenge.contains("/"), "must be url-safe")
    T.equal(challenge.count, 43, "sha-256 base64url is always 43 characters")
    T.equal(
        challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        "matches the RFC 7636 worked example")
}

T.suite("OAuth callback")

await T.test("extracts the code and state from the redirect") {
    let request = "GET /callback?code=AQD123abc&state=xyz789 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
    let callback = LoopbackServer.parse(request)
    T.equal(callback.code, "AQD123abc")
    T.equal(callback.state, "xyz789")
    T.isNil(callback.error, "error")
}

await T.test("surfaces a denial instead of pretending it worked") {
    let request = "GET /callback?error=access_denied&state=xyz HTTP/1.1\r\n\r\n"
    let callback = LoopbackServer.parse(request)
    T.equal(callback.error, "access_denied")
    T.isNil(callback.code, "code")
}

await T.test("percent-decodes parameter values") {
    // Authorization codes are URL-encoded, so a raw value would fail the exchange.
    let request = "GET /callback?code=a%2Fb%2Bc%3Dd&state=s HTTP/1.1\r\n\r\n"
    T.equal(LoopbackServer.parse(request).code, "a/b+c=d")
}

await T.test("a request with no query yields nothing rather than crashing") {
    let callback = LoopbackServer.parse("GET /callback HTTP/1.1\r\n\r\n")
    T.isNil(callback.code, "code")
    T.notNil(callback.error, "should report malformed")
}

// MARK: - Streaming sources

T.suite("Streaming sources")

await T.test("an index written before streaming existed still decodes") {
    // Adding a non-optional `source` would normally break every cached index, because
    // a synthesised decoder ignores property defaults and fails on the missing key.
    let legacy = """
    {
      "url": "file:///lib/a.flac",
      "title": "A", "artist": "B", "albumArtist": "B", "album": "C",
      "duration": 100, "codec": "flac", "fileSize": 10,
      "modified": 0
    }
    """
    guard let decoded = T.notNil(
        try? JSONDecoder().decode(Track.self, from: Data(legacy.utf8)),
        "legacy track decode") else { return }

    T.equal(decoded.source, .local, "missing source should default to local")
    T.expect(!decoded.isStreaming, "a legacy track is not streaming")
    T.equal(decoded.title, "A")
    T.isNil(decoded.externalID, "externalID")
}

await T.test("a streaming track round-trips through Codable") {
    let track = Track(
        source: .appleMusic, externalID: "11276",
        title: "Ta Me 'Mo Shui", artist: "Altan", albumArtist: "Altan",
        album: "Blackwater", duration: 210)

    guard let data = try? JSONEncoder().encode(track),
          let back = T.notNil(try? JSONDecoder().decode(Track.self, from: data), "round trip")
    else { return }

    T.equal(back.source, .appleMusic)
    T.equal(back.externalID, "11276")
    T.expect(back.isStreaming, "apple music tracks stream")
    T.equal(back.id, "appleMusic:11276", "streaming identity is service + external id")
}

await T.test("local and streaming tracks do not collide on identity") {
    let local = makeTrack(title: "Same")
    let stream = Track(
        source: .appleMusic, externalID: "1", title: "Same", artist: "Radiohead",
        albumArtist: "Radiohead", album: "Kid A", duration: 200)
    T.expect(local.id != stream.id, "ids must differ across sources")
}

await T.test("streaming tracks are excluded from a sync plan") {
    // They have no file, so including them would fail mid-transfer and make the
    // plan's size estimate a lie.
    let device = try Fixture.tempDirectory("stream-sync")
    defer { Fixture.remove(device) }

    let target = RockboxDevice(
        mountPoint: device, volumeName: "TESTDEV", rockboxVersion: nil, target: nil,
        totalCapacity: 1 << 30, availableCapacity: 1 << 30, hasRockbox: true)

    let local = makeTrack(title: "Local")
    let streaming = Track(
        source: .appleMusic, externalID: "99", title: "Streamed", artist: "X",
        albumArtist: "X", album: "Y", duration: 180)

    let plan = await SyncEngine().plan(
        tracks: [local, streaming], playlists: [], device: target, config: .default)

    T.equal(plan.actions.count, 1, "only the local track should be planned")
    T.equal(plan.skippedStreaming, 1, "the streaming track should be counted as skipped")
    T.equal(plan.actions.first?.track.title, "Local")
    T.expect(
        !plan.actions.contains { $0.track.isStreaming },
        "no streaming track may appear in a plan")
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

    #if canImport(AVFoundation)
    // Decode-path tests: SourceResolver only exists where AVAudioEngine does.
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
    #else
    T.skip("native formats play straight from disk", "apple-only decode path")
    T.skip("opus decodes to something AVAudioFile can open", "apple-only decode path")
    #endif

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

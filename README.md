# deck

A native macOS music player and Rockbox sync tool, built to look and behave like a
terminal application.

Local library playback with real album art and metadata repair, plus a sync engine that
pushes selected playlists onto a Rockbox player over USB.

```
┌─│ nebula://deck ─────────────────────────────── device: IPOD ─┐
│ nebula://library │ nebula://albums                            │
│  › albums    161 │  ┌────────┐ ┌────────┐ ┌────────┐          │
│    artists    67 │  │  art   │ │  art   │ │  art   │          │
│    songs    2758 │  └────────┘ └────────┘ └────────┘          │
│    queue      12 │   Kid A      Vespertine   Homogenic        │
│                  │   Radiohead  Björk        Björk            │
│  ◆ for the ipod  │                                            │
│  ◇ late night    │                                            │
├──────────────────┴────────────────────────────────────────────┤
│ [art] Idioteque      [⇄] [|◀] [‖ pause] [▶|] [↻]   ▂▅█▃▆▁▄▇  │
│       Radiohead      1:12 ━━━━━━●────────── 5:09   vol ███░░  │
├───────────────────────────────────────────────────────────────┤
│ NORMAL │ albums (161) │ indexed 2758 tracks    rpt:off  3:07  │
└───────────────────────────────────────────────────────────────┘
```

## Install

Download the DMG from [Releases](../../releases/latest), then:

1. Drag **Deck.app** onto **Applications**.
2. Run this once in Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Deck.app
   ```
3. Open Deck from Applications.

Step 2 is required. The app is signed ad-hoc rather than with a paid Apple Developer ID,
so without it macOS will claim the app is damaged. That message is Gatekeeper refusing an
unnotarised app — it does not indicate a problem with the download.

Then install ffmpeg, which Deck uses for FLAC/Opus tags, artwork extraction and MP3
conversion:

```bash
brew install ffmpeg
```

Deck runs without ffmpeg but falls back to AVFoundation, which cannot read Vorbis
comments out of FLAC/Ogg/Opus files.

**Requirements:** macOS 14 Sonoma or later (tested on Sequoia and Tahoe). Universal
binary — Apple Silicon and Intel.

## Build from source

Needs only the Swift toolchain. **Full Xcode is not required** — Command Line Tools is
enough.

```bash
./build.sh release run      # build, bundle, and launch
./build.sh release          # build only → dist/Deck.app
./build.sh dmg              # universal build → dist/Deck-<version>.dmg
swift run DeckTests         # run the test suite
.build/release/deck --scan  # index the library from the console and print a summary
```

## Design

Follows a terminal-app aesthetic throughout: everything monospace, 1px borders, no border
radius, no drop shadows, bracket buttons (`[ play ]`), an optional scanline overlay, a vim
status bar, and `path://like/this` panel titles. Focus is communicated by border colour,
and that is the whole focus system.

Layout borrows from Spotify and Apple Music where those apps are genuinely better: a
persistent left sidebar, a dense album-art grid, an album page with oversized art and
metadata beside it, and a full-width transport bar pinned to the bottom. Album headers are
tinted with the cover's dominant colour.

**Now playing** — click the artwork in the transport bar (or press `f`) for a full-window
view: oversized cover, a large spectrum analyser driven by a live FFT of the audio, the
transport, format details, and what's up next.

**15 themes**, switchable live with `t` or from the command palette:
`dark` (default), graphite, midnight, one dark, tokyo night, catppuccin mocha, rosé pine,
nord, gruvbox, everforest, solarized dark, dracula, monokai, amber crt, phosphor.

## Keys

Vim bindings throughout. All single-key bindings are suppressed while a text field has
focus, so typing in a search or playlist name never triggers them.

| key | action | key | action |
|---|---|---|---|
| `j` / `k` | move down / up | `space` | play / pause |
| `gg` / `G` | jump to top / bottom | `n` / `p` | next / previous track |
| `h` / `l` | back / open | `H` / `L` | seek −10s / +10s |
| `enter` | play selection | `+` / `-` | volume |
| `/` | search | `s` | shuffle |
| `:` | command palette | `r` | cycle repeat |
| `f` | now playing | `t` | cycle theme |
| `1`–`4` | albums / artists / songs / queue | `S` | sync view |
| `R` | rescan library | `,` | settings |
| `esc` | close / clear search | | |

## How it works

**Library.** Folders are walked once into an in-memory index; file contents load lazily.
The index is cached on disk keyed by path + mtime + size, so a rescan only re-probes files
that actually changed — a 2758-track library re-indexes in under a second. Tags are read
with `ffprobe` (which understands Vorbis comments), falling back to AVFoundation.

**Playback.** AVAudioEngine rather than AVPlayer, which buys a real 10-band parametric EQ,
a render tap driving the spectrum visualiser, and sample-accurate scheduling for gapless
album playback. Tracks are pre-scheduled onto one player node and the currently-playing
track is derived from the sample clock, so a gapless hand-off updates the UI at exactly the
moment the audio changes. Formats Core Audio cannot open natively (Opus, Ogg Vorbis) are
decoded to a cached PCM file by ffmpeg; that cache is capped at 4 GB with oldest evicted
first.

**Artwork.** Resolved in a fixed order: embedded in the file → `cover.jpg`/`folder.jpg`
beside it → Cover Art Archive → iTunes. Results are cached to disk. Your music files and
folders are never modified.

**Metadata repair.** Tracks with missing or broken tags are matched against MusicBrainz
using whatever tags exist, falling back to parsing `Artist - Title` out of the filename.
Matches scoring below 70 are discarded, because writing a wrong tag is worse than leaving
the file alone. No API key is needed; MusicBrainz permits one request per second, so repair
runs slowly in the background while the app stays usable. Repaired tags live in the app's
index — **the original files are not rewritten**.

**Converting.** Right-click any album or track → *convert to mp3* at V0, V2 or V4. The MP3
is written beside the original (or into a folder you choose) and **the source file is left
untouched**. Lossy tracks are filtered out automatically, so converting a mixed album only
re-encodes the lossless parts. Conversions share a cache with the sync engine, so a track
already converted for the device exports instantly.

## Syncing to Rockbox

Connect the player in USB disk mode. Any volume with a `.rockbox` directory is detected
automatically, along with its target and firmware version; other removable volumes are
offered too, so a freshly formatted player still works.

Mark playlists for sync with the `◇` toggle in the sidebar, then open the sync view and
press `[ dry run ]` to see exactly what would change before anything is written.

- **Layout** — `Music/{albumartist}/{album}/NN Title.ext`, configurable with
  `{albumartist} {artist} {album} {year} {genre}` tokens. Every path component is made safe
  for FAT: illegal characters replaced, trailing dots and spaces stripped, reserved DOS
  names escaped, lengths capped. A slash inside a tag (`AC/DC`) stays one folder.
- **Incremental** — a manifest at `.deck-sync.json` on the device records what was written,
  so re-syncing only transfers what actually changed.
- **FLAC → MP3 (optional)** — off by default. When enabled, lossless files are converted
  for the device at your chosen LAME quality. **Your originals are never touched**; the
  conversion is written to a cache and only that copy is transferred, so re-syncing an
  unchanged album costs nothing after the first conversion. Already-lossy files are never
  re-encoded.
- **Artwork** — `cover.jpg` is written beside each album, resized for the player's screen.
- **Playlists** — exported as `.m3u8` with device-relative paths, containing only tracks
  that actually landed on the device.
- **Cleanup** — off by default. When enabled, it only removes files recorded in the
  manifest, so anything you put on the player by hand is never a deletion candidate.

After a sync, run *Settings → General → Database → Update now* on the player so the new
files appear in its database browser.

## Layout

```
Sources/
  DeckCore/          UI-independent core
    Models          Track, Album, Playlist
    LibraryScanner  walk + cached index
    MetadataReader  ffprobe primary, AVAsset fallback
    ArtworkStore    embedded → folder → online, disk cached
    OnlineMetadata  MusicBrainz, Cover Art Archive, iTunes
    Player          AVAudioEngine, EQ, gapless, FFT, opus decode
    RockboxDevice   volume detection
    Transcoder      FLAC → MP3, cached, non-destructive
    SyncEngine      plan, diff, copy, m3u8, manifest
    Shell           async Process wrapper
    Theme           colour roles + 15 palettes
  Deck/              SwiftUI app
  DeckTests/         test suite (executable — see below)
```

The test suite is a plain executable rather than a `.testTarget`. XCTest and swift-testing
both ship only with full Xcode, and this project deliberately builds with Command Line
Tools alone, so tests run via `swift run DeckTests` and signal failure through the exit
code.

Two notes for anyone reading `Shell.swift`: it never calls `Process.waitUntilExit()`. That
method blocks a thread in Swift's *cooperative* pool, which has only as many threads as the
machine has cores — run a handful of concurrent probes and the pool starves, pipe readers
never drain, children block writing to full pipes, and nothing exits. Completion comes from
`terminationHandler` instead, with pipes drained on regular dispatch queues.

## Files it writes

| path | contents |
|---|---|
| `~/Library/Application Support/com.nebula.deck/config.json` | settings |
| `~/Library/Application Support/com.nebula.deck/index.json` | library index |
| `~/Library/Application Support/com.nebula.deck/playlists.json` | playlists |
| `~/Library/Caches/com.nebula.deck/` | artwork, converted MP3s, decoded audio |
| `<device>/.deck-sync.json` | sync manifest |

Nothing is ever written into your music library unless you explicitly ask for a conversion.

## Licence

MIT — see [LICENSE](LICENSE).

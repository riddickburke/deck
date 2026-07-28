# deck

A native macOS music player and Rockbox sync tool, built to look and behave like a
terminal application.

Local library playback with real album art and metadata repair, plus a sync engine that
pushes selected playlists onto a Rockbox player over USB.

```
┌─│ deck ───────────────────────────────────────── device: IPOD ─┐
│ deck://library   │ deck://albums                              │
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

Runs on **macOS 14+** (SwiftUI) and **Linux** (GTK4). Both front ends are built on the
same core, so library indexing, tag reading, artwork resolution, transcoding and Rockbox
syncing behave identically on either platform.

The user interfaces are not at parity. SwiftUI does not exist on Linux, so the GTK build
is a separate front end rather than a port, and it currently covers less:

| | macOS | Linux |
|---|---|---|
| Library browse, album detail, queue | ✅ | ✅ |
| Playback, seek, shuffle, repeat | ✅ AVAudioEngine | ✅ mpv |
| Rockbox sync incl. dry run | ✅ | ✅ |
| 15 themes | ✅ | ✅ |
| Album art | ✅ | ✅ |
| Gapless playback | ✅ | ✅ |
| Full-screen now playing + spectrum | ✅ | ❌ |
| 10-band EQ | ✅ | ❌ |
| Search and command palette | ✅ | ❌ |
| Convert to MP3 from the UI | ✅ | ❌ |
| Metadata repair from the UI | ✅ | ❌ |
| System media keys | ✅ | ❌ |

The missing pieces are UI wiring, not missing capability — metadata repair and conversion
live in the shared core and work on Linux via `deck --scan` and the sync path.

## Install — Linux

Download from [Releases](../../releases/latest).

**Debian, Ubuntu, Mint, Pop!_OS**
```bash
sudo apt install ./deck_1.3.0_amd64.deb
sudo apt install ffmpeg mpv          # required at runtime
```

**Fedora, RHEL, openSUSE**
```bash
sudo dnf install ./deck-1.3.0-1.x86_64.rpm
sudo dnf install ffmpeg mpv
```

**Arch, Manjaro, EndeavourOS**
```bash
# from the AUR-style PKGBUILD in packaging/
makepkg -si
sudo pacman -S ffmpeg mpv
```

**Anything else** — the generic tarball works on any glibc distribution:
```bash
tar xzf deck-1.3.0-linux-x86_64.tar.gz
sudo ./install.sh            # or ./install.sh --user for ~/.local
```

The binary is built with a static Swift runtime, so **no Swift toolchain is needed** to
run it. The only requirements are GTK 4.6+, glibc, plus `ffmpeg` (tags, artwork,
conversion) and `mpv` (playback).

## Install — macOS

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

**macOS** — needs only the Swift toolchain. Full Xcode is not required; Command Line
Tools is enough.

```bash
./build.sh release run      # build, bundle, and launch
./build.sh release          # build only → dist/Deck.app
./build.sh dmg              # universal build → dist/Deck-<version>.dmg
swift run DeckTests         # run the test suite
.build/release/deck --scan  # index the library from the console and print a summary
```

**Linux** — needs Swift 5.9+, GTK 4.6+ and pkg-config.

```bash
# debian/ubuntu
sudo apt install libgtk-4-dev pkg-config ffmpeg mpv
# fedora
sudo dnf install gtk4-devel pkgconf-pkg-config ffmpeg mpv
# arch
sudo pacman -S gtk4 pkgconf ffmpeg mpv

swift build -c release --product deck --static-swift-stdlib
swift run DeckTests

./packaging/build-linux.sh            # tarball
./packaging/build-linux.sh --deb      # also a .deb
./packaging/build-linux.sh --rpm      # also an .rpm
```

`--static-swift-stdlib` matters: without it the binary needs a Swift runtime installed,
which no distribution ships.

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

## System media controls

Deck registers as the system Now Playing app, so it works with the rest of macOS rather
than only inside its own window:

- **Media keys** — F7/F8/F9 (or the Touch Bar / function row) for previous, play-pause and
  next, even when Deck is in the background.
- **Control Centre and the menu bar** — the Now Playing tile shows the current track,
  artist, album and cover art, and its transport and scrub bar drive playback.
- **Bluetooth and headset controls** — play/pause and track skip from AirPods, headphones
  and car stereos.
- **Lock screen / notification centre** — current track with artwork.

Both halves are required for this and it is a common thing to get half-right: registering
remote commands alone does nothing, because macOS only routes media keys to an app that
has populated `MPNowPlayingInfoCenter`. Deck sets both, and clears them on quit so the
tile does not linger showing a track nothing is playing.

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
- **Playlists** — exported as `.m3u8` to `/Playlists` on the device, with root-relative
  paths, containing only tracks that actually landed there. **Your playlist order is
  preserved exactly**, and there are tests asserting it survives a full plan-and-sync
  against an order that is deliberately neither alphabetical nor by track number. Note
  that order only applies when you *open the playlist* on the player — browsing the same
  files through Rockbox's Database or File browser sorts by tag and filename instead.
  A track can appear only once per playlist.
- **Cleanup** — off by default. When enabled, it only removes files recorded in the
  manifest, so anything you put on the player by hand is never a deletion candidate.

After a sync, run *Settings → General → Database → Update now* on the player so the new
files appear in its database browser.

## Layout

```
Sources/
  DeckCore/          portable — Foundation only, no UI framework
    Models          Track, Album, Playlist
    LibraryScanner  walk + cached index
    MetadataReader  ffprobe primary, AVAsset fallback on Apple
    ArtworkStore    embedded → folder → online, disk cached, Data-based
    ImageOps        resize + dominant colour via ffmpeg
    OnlineMetadata  MusicBrainz, Cover Art Archive, iTunes
    Spectrum        FFT band folding shared by both visualisers
    Player          AVAudioEngine, EQ, gapless      (Apple only)
    MPVPlayer       mpv JSON IPC                    (Linux only)
    RockboxDevice   volume detection, per platform
    Transcoder      FLAC → MP3, cached, non-destructive
    SyncEngine      plan, diff, copy, m3u8, manifest
    Shell           async Process wrapper
    Theme           15 palettes as portable RGB, SwiftUI Colors layered on
    StableHash      process-stable cache keys, replaces CryptoKit
  Deck/              SwiftUI app                    (macOS)
  DeckGTK/           GTK4 app                       (Linux)
  CGtk4/             C inline shim over GTK4
  DeckTests/         test suite (executable — see below)
```

`Package.swift` selects targets by host platform, so Linux never sees the SwiftUI app and
macOS never sees GTK.

### Notes on the GTK layer

Three things about GTK from Swift are worth knowing if you touch `Sources/CGtk4`:

- **The casting macros are macros.** `GTK_BOX`, `GTK_WINDOW` and friends cannot be called
  from Swift, and whether Swift implicitly converts a `GtkWidget*` to a `GtkBox*` depends
  on which instance structs the installed GTK exposes. Every wrapper therefore takes
  `void *` and casts in C, where it is always valid — Swift sees one concrete type.
- **`g_signal_connect` is a macro too**, and `g_signal_connect_data` takes a
  `GConnectFlags` whose Swift import differs across glib versions (`G_CONNECT_DEFAULT`
  only exists from 2.74). The shim does that cast in C.
- **Signal callback arity must match.** A three-argument signal passes user data in the
  third slot, so registering a two-argument callback would read the signal's own argument
  as the closure pointer and crash. `onSignal` and `onSignalWithArgument` are separate
  for that reason.

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
| `~/Library/Application Support/com.riddickburke.deck/config.json` | settings |
| `~/Library/Application Support/com.riddickburke.deck/index.json` | library index |
| `~/Library/Application Support/com.riddickburke.deck/playlists.json` | playlists |
| `~/Library/Caches/com.riddickburke.deck/` | artwork, converted MP3s, decoded audio |
| `<device>/.deck-sync.json` | sync manifest |

Nothing is ever written into your music library unless you explicitly ask for a conversion.

Deck was previously identified as `com.nebula.deck`. On first launch after upgrading, data
under the old identifier is moved across once — settings, library index and playlists all
carry over. The migration never overwrites data already present under the new identifier,
and is a no-op on a fresh install.

## Licence

MIT — see [LICENSE](LICENSE).

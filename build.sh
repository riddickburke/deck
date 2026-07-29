#!/usr/bin/env bash
# Builds deck and wraps it in a macOS .app bundle.
#
# Works with Command Line Tools only — no full Xcode install required.
#   ./build.sh                 debug build
#   ./build.sh release         optimised build
#   ./build.sh release run     build then launch
#   ./build.sh dmg             universal (arm64 + x86_64) build → dist/Deck-<version>.dmg

set -euo pipefail

MODE="${1:-debug}"
ACTION="${2:-}"

cd "$(dirname "$0")"
ROOT="$PWD"
APP_NAME="Deck"
BUNDLE_ID="com.riddickburke.deck"
# Single source of truth — see Sources/DeckCore/Version.swift.
VERSION="$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' Sources/DeckCore/Version.swift)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

CONFIG="$MODE"
[[ "$MODE" == "dmg" ]] && CONFIG="release"

if [[ "$MODE" == "dmg" ]]; then
  # A universal binary so one DMG runs on both Apple Silicon and Intel.
  #
  # SwiftPM's own `--arch a --arch b` needs xcbuild, which only ships with full
  # Xcode. Building each slice against its own triple and joining them with lipo
  # gets the same result using Command Line Tools alone.
  echo "==> building universal (arm64 + x86_64)"
  SLICES=()
  for triple in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
    echo "    $triple"
    scratch=".build-${triple%%-*}"
    swift build -c release --triple "$triple" --scratch-path "$scratch" >/dev/null
    SLICES+=("$(swift build -c release --triple "$triple" --scratch-path "$scratch" --show-bin-path)/deck")
  done
  BIN="$(mktemp -d)/deck"
  lipo -create -output "$BIN" "${SLICES[@]}"
else
  echo "==> building ($CONFIG)"
  swift build -c "$CONFIG"
  BIN="$(swift build -c "$CONFIG" --show-bin-path)/deck"
fi

if [[ ! -x "$BIN" ]]; then
  echo "!! binary not found at $BIN" >&2
  exit 1
fi

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# Icon: drawn procedurally so no binary asset lives in the repo.
if command -v iconutil >/dev/null 2>&1; then
  ICONSET="$(mktemp -d)/deck.iconset"
  if swift "$ROOT/Tools/make-icon.swift" "$ICONSET" >/dev/null 2>&1; then
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/deck.icns" 2>/dev/null || true
  fi
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>deck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <!-- Required from macOS 13 to read a mounted player over USB. -->
  <key>NSRemovableVolumesUsageDescription</key>
  <string>Deck needs access to your connected Rockbox player to sync music to it.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Deck needs access to read music folders you add from your Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>Deck needs access to read music folders you add from your Documents.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Deck needs access to read music folders you add from your Downloads.</string>
  <!-- Apple Music: Deck browses the Music.app library and drives playback there,
       because subscription tracks are DRM-protected streams it cannot decode itself. -->
  <key>NSAppleEventsUsageDescription</key>
  <string>Deck controls Music to browse your Apple Music library and play tracks.</string>
  <key>NSAppleMusicUsageDescription</key>
  <string>Deck reads your Apple Music library so you can browse and play it in Deck.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. Without one, macOS re-prompts for permissions on every rebuild
# because the app has no stable identity.
echo "==> signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
  || echo "   (codesign failed; the app will still run)"

echo "==> built $APP"
file "$APP/Contents/MacOS/$APP_NAME" | sed 's/^/    /'
du -sh "$APP" | awk '{print "    size: " $1}'

if [[ "$MODE" == "dmg" ]]; then
  DMG="$DIST/$APP_NAME-$VERSION.dmg"
  STAGE="$(mktemp -d)/$APP_NAME"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  # Drag-to-install target.
  ln -s /Applications "$STAGE/Applications"

  cat > "$STAGE/READ ME FIRST.txt" <<'NOTE'
Deck is signed ad-hoc, not with a paid Apple Developer ID, so macOS
Gatekeeper will refuse to open it on first launch.

To install:

  1. Drag Deck.app onto the Applications folder in this window.
  2. Open Terminal and run:

       xattr -dr com.apple.quarantine /Applications/Deck.app

  3. Launch Deck normally from Applications.

Step 2 removes the "downloaded from the internet" flag. Without it macOS
will say the app is damaged. This is expected for unnotarised apps and
does not mean anything is wrong with the download.

Deck also needs ffmpeg for FLAC/Opus tags, artwork and MP3 conversion:

       brew install ffmpeg
NOTE

  echo "==> creating dmg"
  rm -f "$DMG"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

  rm -rf "$(dirname "$STAGE")"
  echo "==> built $DMG"
  du -sh "$DMG" | awk '{print "    size: " $1}'
  shasum -a 256 "$DMG" | awk '{print "    sha256: " $1}'
fi

if [[ "$ACTION" == "run" ]]; then
  echo "==> launching"
  open "$APP"
fi

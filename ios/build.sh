#!/usr/bin/env bash
# Builds Deck for iPhone and, if one is plugged in, installs it.
#
# Usage:
#   ./build.sh              build only
#   ./build.sh install      build, then install to the connected device
#   ./build.sh check        type-check the sources without building a bundle
set -euo pipefail

cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
ACTION="${1:-build}"

# --- Xcode ------------------------------------------------------------------
#
# iOS cannot be built with Command Line Tools. If `xcode-select` still points at
# the CLT instance, the whole toolchain is missing rather than merely misconfigured,
# so point at Xcode for this process instead of asking for a sudo xcode-select.
if [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
else
    echo "error: Xcode is required to build for iOS (Command Line Tools are not enough)." >&2
    echo "       Install Xcode from the App Store, then re-run." >&2
    exit 1
fi

SDK_VERSION="$(xcodebuild -showsdks 2>/dev/null | sed -n 's/.*-sdk iphoneos\([0-9.]*\).*/\1/p' | tail -1)"
if [ -z "$SDK_VERSION" ]; then
    echo "error: no iOS SDK found in $DEVELOPER_DIR." >&2
    exit 1
fi

SOURCES=(
    "$REPO"/Sources/DeckCore/Models.swift
    "$REPO"/Sources/DeckCore/Theme.swift
    "$REPO"/Sources/DeckCore/Spectrum.swift
    "$REPO"/Sources/DeckCore/SyntheticSpectrum.swift
    "$REPO"/Sources/DeckCore/ServicePlaylist.swift
    DeckMobile/*.swift
    DeckMobile/Views/*.swift
)

# --- check ------------------------------------------------------------------
#
# Type-checking needs only the SDK, not the installed platform, so this still works
# on a machine where a full build cannot run.
if [ "$ACTION" = "check" ]; then
    echo "==> type-checking against iOS $SDK_VERSION"
    xcrun --sdk "iphoneos$SDK_VERSION" swiftc -typecheck \
        -target arm64-apple-ios17.0 \
        -sdk "$(xcrun --sdk "iphoneos$SDK_VERSION" --show-sdk-path)" \
        "${SOURCES[@]}"
    echo "==> ok"
    exit 0
fi

# --- platform ---------------------------------------------------------------
#
# Xcode ships the iOS SDK headers but downloads the platform support separately, and
# a first-party Xcode install often has the former without the latter. The asset
# catalog compiler is the step that fails, with a message about simulator runtimes
# that does not obviously mean "install the platform", so it is checked up front.
if ! xcrun simctl list runtimes 2>/dev/null | grep -qi ios; then
    cat >&2 <<EOF
error: the iOS platform is not installed in Xcode.

  Only the SDK headers are present, so compiling works but building an .app does
  not — the asset catalog step fails with "No available simulator runtimes".

  Install it with either:
      xcodebuild -downloadPlatform iOS
      Xcode > Settings > Components > iOS

  It is a large download (several GB). Then re-run this script.
EOF
    exit 1
fi

# --- generate ---------------------------------------------------------------
echo "==> rendering icon"
ICON_DIR="DeckMobile/Assets.xcassets/AppIcon.appiconset"
swift "$REPO/Tools/make-ios-icon.swift" "$ICON_DIR/AppIcon.png" >/dev/null

echo "==> generating project"
python3 generate_project.py

# --- build ------------------------------------------------------------------
echo "==> building for iOS $SDK_VERSION"
BUILD_DIR="$PWD/.build"
xcodebuild -project DeckMobile.xcodeproj \
    -scheme DeckMobile \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$BUILD_DIR" \
    -allowProvisioningUpdates \
    build

APP="$BUILD_DIR/Build/Products/Release-iphoneos/DeckMobile.app"
echo "==> built $APP"

# --- install ----------------------------------------------------------------
if [ "$ACTION" = "install" ]; then
    DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk 'NR>2 && $NF=="connected" {print $(NF-2); exit}')"
    if [ -z "$DEVICE" ]; then
        echo "error: no connected iPhone found. Plug it in, unlock it, and trust this Mac." >&2
        exit 1
    fi
    echo "==> installing to $DEVICE"
    xcrun devicectl device install app --device "$DEVICE" "$APP"
    echo "==> installed"
fi

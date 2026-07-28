#!/usr/bin/env bash
# Builds the Linux binary and stages a filesystem tree the packagers share.
#
#   ./packaging/build-linux.sh            build + stage + tarball
#   ./packaging/build-linux.sh --deb      also produce a .deb
#   ./packaging/build-linux.sh --rpm      also produce an .rpm
#
# Output lands in dist/.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION="$(grep -oP '(?<=static let current = ")[^"]+' Sources/DeckGTK/HeadlessScan.swift)"
ARCH="$(uname -m)"
DEB_ARCH="$([ "$ARCH" = "x86_64" ] && echo amd64 || echo arm64)"

DIST="$ROOT/dist"
STAGE="$DIST/stage"
TARBALL="$DIST/deck-$VERSION-linux-$ARCH.tar.gz"

echo "==> building deck $VERSION for $ARCH"

# --static-swift-stdlib is essential: without it the binary needs the Swift runtime
# installed on the user's machine, which no distribution ships. With it the only
# remaining requirements are glibc and GTK, which packages declare as dependencies.
swift build -c release --product deck --static-swift-stdlib

BIN="$(swift build -c release --show-bin-path)/deck"
if [[ ! -x "$BIN" ]]; then
  echo "!! binary not found at $BIN" >&2
  exit 1
fi

echo "==> staging"
rm -rf "$STAGE"
install -Dm755 "$BIN" "$STAGE/usr/bin/deck"
install -Dm644 packaging/deck.desktop "$STAGE/usr/share/applications/deck.desktop"
install -Dm644 packaging/deck.svg "$STAGE/usr/share/icons/hicolor/scalable/apps/deck.svg"
install -Dm644 README.md "$STAGE/usr/share/doc/deck/README.md"
install -Dm644 LICENSE "$STAGE/usr/share/doc/deck/LICENSE"

strip "$STAGE/usr/bin/deck" 2>/dev/null || true

echo "    binary: $(du -h "$STAGE/usr/bin/deck" | cut -f1)"
echo "    runtime deps:"
ldd "$STAGE/usr/bin/deck" 2>/dev/null | grep -oP '(?<=\t)[^ ]+' | grep -v '=>' | head -12 | sed 's/^/      /' || true

echo "==> tarball"
install -Dm755 packaging/install.sh "$STAGE/install.sh"
tar -czf "$TARBALL" -C "$STAGE" .
echo "    $TARBALL ($(du -h "$TARBALL" | cut -f1))"

# MARK: - Debian

if [[ "${1:-}" == "--deb" || "${2:-}" == "--deb" ]]; then
  echo "==> deb"
  DEBROOT="$DIST/debroot"
  rm -rf "$DEBROOT"
  mkdir -p "$DEBROOT/DEBIAN"
  cp -r "$STAGE/usr" "$DEBROOT/"
  rm -f "$DEBROOT/install.sh"

  cat > "$DEBROOT/DEBIAN/control" <<CONTROL
Package: deck
Version: $VERSION
Section: sound
Priority: optional
Architecture: $DEB_ARCH
Depends: libgtk-4-1 (>= 4.6), libglib2.0-0, libcurl4, libxml2
Recommends: ffmpeg, mpv
Maintainer: Riddick Burke <riddickburke7@gmail.com>
Homepage: https://github.com/riddickburke/deck
Description: Music player and Rockbox sync tool
 Deck plays a local music library and syncs selected playlists onto a
 Rockbox player over USB, with FAT-safe paths, incremental transfers and
 optional non-destructive FLAC to MP3 conversion.
 .
 ffmpeg is required for reading tags and artwork and for conversion.
 mpv is required for playback.
CONTROL

  dpkg-deb --root-owner-group --build "$DEBROOT" \
    "$DIST/deck_${VERSION}_${DEB_ARCH}.deb" >/dev/null
  echo "    $DIST/deck_${VERSION}_${DEB_ARCH}.deb"
fi

# MARK: - RPM

if [[ "${1:-}" == "--rpm" || "${2:-}" == "--rpm" ]]; then
  echo "==> rpm"
  RPMTOP="$DIST/rpmbuild"
  rm -rf "$RPMTOP"
  mkdir -p "$RPMTOP"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

  # rpmbuild wants a source tarball whose top directory matches name-version.
  PAYLOAD="$RPMTOP/SOURCES/deck-$VERSION"
  mkdir -p "$PAYLOAD"
  cp -r "$STAGE/usr" "$PAYLOAD/"
  rm -f "$PAYLOAD/install.sh"
  tar -czf "$RPMTOP/SOURCES/deck-$VERSION.tar.gz" -C "$RPMTOP/SOURCES" "deck-$VERSION"

  sed "s/@VERSION@/$VERSION/g" packaging/deck.spec > "$RPMTOP/SPECS/deck.spec"

  rpmbuild --define "_topdir $RPMTOP" -bb "$RPMTOP/SPECS/deck.spec" >/dev/null
  find "$RPMTOP/RPMS" -name '*.rpm' -exec cp {} "$DIST/" \;
  find "$DIST" -maxdepth 1 -name '*.rpm' -printf '    %p\n'
fi

echo "==> done"

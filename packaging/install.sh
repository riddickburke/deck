#!/usr/bin/env sh
# Installs deck from the generic tarball, for distributions without a native package.
#
#   sudo ./install.sh              install to /usr/local
#   ./install.sh --user            install to ~/.local (no root needed)
#   sudo ./install.sh --uninstall  remove
#
# POSIX sh so it runs on minimal systems without bash.

set -eu

PREFIX="/usr/local"
ACTION="install"

for arg in "$@"; do
    case "$arg" in
        --user) PREFIX="$HOME/.local" ;;
        --prefix=*) PREFIX="${arg#--prefix=}" ;;
        --uninstall) ACTION="uninstall" ;;
        -h|--help)
            echo "usage: install.sh [--user] [--prefix=PATH] [--uninstall]"
            exit 0
            ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

SRC="$(cd "$(dirname "$0")" && pwd)"

BIN="$PREFIX/bin/deck"
DESKTOP="$PREFIX/share/applications/deck.desktop"
ICON="$PREFIX/share/icons/hicolor/scalable/apps/deck.svg"
DOC="$PREFIX/share/doc/deck"

if [ "$ACTION" = "uninstall" ]; then
    rm -f "$BIN" "$DESKTOP" "$ICON"
    rm -rf "$DOC"
    echo "removed deck from $PREFIX"
    exit 0
fi

if [ ! -f "$SRC/usr/bin/deck" ]; then
    echo "error: run this from inside the extracted tarball" >&2
    exit 1
fi

mkdir -p "$PREFIX/bin" \
         "$PREFIX/share/applications" \
         "$PREFIX/share/icons/hicolor/scalable/apps" \
         "$DOC"

install -m755 "$SRC/usr/bin/deck" "$BIN"
install -m644 "$SRC/usr/share/applications/deck.desktop" "$DESKTOP"
install -m644 "$SRC/usr/share/icons/hicolor/scalable/apps/deck.svg" "$ICON"
install -m644 "$SRC/usr/share/doc/deck/README.md" "$DOC/README.md" 2>/dev/null || true
install -m644 "$SRC/usr/share/doc/deck/LICENSE" "$DOC/LICENSE" 2>/dev/null || true

# Desktop environments cache these; without a refresh the launcher entry and icon
# may not appear until the next login.
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$PREFIX/share/applications" 2>/dev/null || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -qtf "$PREFIX/share/icons/hicolor" 2>/dev/null || true
fi

echo "installed deck to $PREFIX"

# Report missing runtime tools rather than letting the app fail confusingly later.
missing=""
command -v ffmpeg >/dev/null 2>&1 || missing="$missing ffmpeg"
command -v mpv    >/dev/null 2>&1 || missing="$missing mpv"

if [ -n "$missing" ]; then
    echo
    echo "warning: these are needed and were not found:$missing"
    echo "  ffmpeg — reads tags and artwork, and performs conversion"
    echo "  mpv    — audio playback"
    echo
    echo "  debian/ubuntu : sudo apt install$missing"
    echo "  fedora        : sudo dnf install$missing"
    echo "  arch          : sudo pacman -S$missing"
fi

case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) echo; echo "note: $PREFIX/bin is not on your PATH" ;;
esac

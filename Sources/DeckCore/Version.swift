/// The one place the release version is written down.
///
/// It used to live in three: `VERSION` in `build.sh` for the macOS bundle, a separate
/// `DeckVersion.current` in the GTK front end that the Linux packaging grepped, and
/// `pkgver` in the PKGBUILD. Bumping only the first is what shipped a v1.4.0 release
/// whose Linux packages were all named 1.3.0.
///
/// Both build scripts now read this file, so there is nothing left to forget. Keep the
/// literal on one line in this exact shape — `build.sh` and `packaging/build-linux.sh`
/// parse it with a regex rather than compiling anything.
public enum DeckVersion {
    public static let current = "1.4.0"
}

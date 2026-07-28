Name:           deck
Version:        @VERSION@
Release:        1%{?dist}
Summary:        Music player and Rockbox sync tool

License:        MIT
URL:            https://github.com/riddickburke/deck
Source0:        %{name}-%{version}.tar.gz

BuildArch:      %{_arch}

# The binary is built with a static Swift stdlib, so only the system libraries
# it links against are required at runtime.
Requires:       gtk4 >= 4.6
Requires:       glib2
Requires:       libcurl
Requires:       libxml2

# ffmpeg reads tags and artwork and performs conversion; mpv plays audio.
# Both are recommended rather than required so the app still installs on a
# system without RPM Fusion enabled.
Recommends:     ffmpeg
Recommends:     mpv

%description
Deck plays a local music library and syncs selected playlists onto a Rockbox
player over USB, with FAT-safe path handling, incremental transfers driven by
an on-device manifest, m3u8 playlist export and optional non-destructive
FLAC to MP3 conversion.

Album art is resolved from embedded tags, folder covers, the Cover Art Archive
and iTunes. Missing metadata can be repaired against MusicBrainz without
rewriting your files.

%prep
%setup -q

%install
mkdir -p %{buildroot}
cp -r usr %{buildroot}/

%files
%{_bindir}/deck
%{_datadir}/applications/deck.desktop
%{_datadir}/icons/hicolor/scalable/apps/deck.svg
%dir %{_datadir}/doc/deck
%{_datadir}/doc/deck/README.md
%license %{_datadir}/doc/deck/LICENSE

%changelog
* Tue Jul 28 2026 Riddick Burke <riddickburke7@gmail.com> - @VERSION@-1
- GTK4 front end for Linux sharing the macOS core

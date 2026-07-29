import MediaPlayer
import SwiftUI

/// The app shell: a pager of library pages, a docked mini player, and the now-playing
/// sheet that the mini player drags up into.
///
/// The desktop layout is a sidebar beside a content pane. That does not survive a phone,
/// so the sidebar's job — switching between albums / artists / songs / playlists — moves
/// to a horizontal pager. The rest of the language is unchanged: framed panels, `deck://`
/// headers, bracket buttons, monospace throughout.
struct RootView: View {
    @EnvironmentObject var app: MobileState
    @EnvironmentObject var playback: Playback
    @State private var path = NavigationPath()
    @State private var showsSearch = false
    @State private var showsSettings = false

    var body: some View {
        ZStack(alignment: .bottom) {
            app.theme.bg.ignoresSafeArea()

            NavigationStack(path: $path) {
                VStack(spacing: 0) {
                    header
                    HomePage()
                }
                .background(app.theme.bg)
                .navigationBarHidden(true)
                .navigationDestination(for: NavigationTarget.self) { target in
                    destination(for: target)
                }
            }

            // Docked above the pager. Present whenever there is a track, including
            // while paused — a transport that disappears on pause leaves no way back.
            if playback.currentTrack != nil {
                MiniPlayer()
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: playback.currentTrack?.id)
        .fullScreenCover(isPresented: $app.isNowPlayingOpen) {
            NowPlayingScreen()
                .environmentObject(app)
                .environmentObject(playback)
                .environmentObject(playback.clock)
                .environmentObject(app.visualizer)
        }
        // Sheets are presented in their own environment, so every object the content
        // reads has to be handed across explicitly.
        .sheet(isPresented: $showsSearch) {
            SearchPage()
                .environmentObject(app)
                .environmentObject(playback)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsSettings) {
            SettingsPage()
                .environmentObject(app)
                .environmentObject(playback)
                .presentationDragIndicator(.visible)
        }
        .task {
            await app.loadIfNeeded()
            if SelfTest.isEnabled { await SelfTest.run(playback: playback) }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(app.theme.accent)
                .frame(width: 2, height: 14)

            Text("deck://apple-music")
                .font(DeckFont.mono(13, weight: .semibold))
                .foregroundStyle(app.theme.fg)

            Spacer()

            Button { showsSearch = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(app.theme.muted)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            Button { showsSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(app.theme.muted)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(height: 46)
        .background(app.theme.bgInset)
        .overlay(alignment: .bottom) {
            Rectangle().fill(app.theme.border).frame(height: 1)
        }
    }

    @ViewBuilder
    private func destination(for target: NavigationTarget) -> some View {
        switch target {
        case .library(let page):
            LibraryPager(start: page)
        case .queue:
            QueueView()
        case .album(let key):
            if let album = app.albums.first(where: { $0.key == key }) {
                AlbumDetail(album: album)
            } else {
                StatusMessage(title: "album not found")
            }
        case .artist(let name):
            ArtistDetail(artist: name)
        case .playlist(let id):
            if let playlist = app.playlists.first(where: { $0.id == id }) {
                PlaylistDetail(playlist: playlist)
            } else {
                StatusMessage(title: "playlist not found")
            }
        }
    }
}

// MARK: - Library pager

/// The four library pages, pushed from the home screen.
///
/// Kept as a pager rather than four separate destinations so swiping left and right
/// between albums, artists, songs and playlists still works — that gesture predates the
/// home screen and there was no reason to lose it just because the entry point moved.
struct LibraryPager: View {
    let start: LibraryPage

    @EnvironmentObject var app: MobileState
    @Environment(\.dismiss) private var dismiss
    @State private var page: LibraryPage

    init(start: LibraryPage) {
        self.start = start
        _page = State(initialValue: start)
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            tabs

            TabView(selection: $page) {
                AlbumsPage().tag(LibraryPage.albums)
                ArtistsPage().tag(LibraryPage.artists)
                SongsPage().tag(LibraryPage.songs)
                PlaylistsPage().tag(LibraryPage.playlists)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(app.theme.bg)
        .navigationBarBackButtonHidden(true)
        .navigationBarHidden(true)
    }

    private var bar: some View {
        HStack {
            BracketButton(label: "← library") { dismiss() }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(app.theme.bgInset)
        .overlay(alignment: .bottom) {
            Rectangle().fill(app.theme.border).frame(height: 1)
        }
    }

    /// Tabs and the pager move the same binding, so they cannot disagree.
    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(LibraryPage.allCases) { item in
                let active = page == item
                Button {
                    withAnimation(.easeOut(duration: 0.22)) { page = item }
                } label: {
                    VStack(spacing: 5) {
                        Text(item.title)
                            .font(DeckFont.mono(11, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? app.theme.fg : app.theme.muted)
                        Rectangle()
                            .fill(active ? app.theme.accent : .clear)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(app.theme.bgInset)
        .overlay(alignment: .bottom) {
            Rectangle().fill(app.theme.border).frame(height: 1)
        }
    }
}

/// Navigation is by value, not by view.
///
/// Pushing a `Track`/`Album` directly would capture a stale copy; pushing its key means
/// the destination re-resolves against current state after a library reload.
enum NavigationTarget: Hashable {
    case library(LibraryPage)
    case queue
    case album(AlbumKey)
    case artist(String)
    case playlist(String)
}

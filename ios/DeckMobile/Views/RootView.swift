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
                    pageTabs
                    pager
                }
                .background(app.theme.bg)
                .navigationBarHidden(true)
                .navigationDestination(for: NavigationTarget.self) { target in
                    destination(for: target)
                }
            }

            // Sits above the pager, below the now-playing sheet.
            if playback.currentTrack != nil {
                MiniPlayer()
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    // Fades out as the sheet takes over, so the two are never both
                    // showing the same track at once.
                    .opacity(1 - Double(min(1, app.nowPlayingProgress * 2.2)))
                    .allowsHitTesting(!app.isNowPlayingOpen)
            }

            NowPlayingSheet()
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
        .task { await app.loadIfNeeded() }
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

    /// Tabs mirror the pager rather than drive it exclusively — tapping and swiping both
    /// move the same binding, so they can never disagree.
    private var pageTabs: some View {
        HStack(spacing: 0) {
            ForEach(LibraryPage.allCases) { item in
                let active = app.page == item
                Button {
                    withAnimation(.easeOut(duration: 0.22)) { app.page = item }
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

    /// The primary gesture: swipe left and right to move between library pages.
    private var pager: some View {
        TabView(selection: $app.page) {
            AlbumsPage().tag(LibraryPage.albums)
            ArtistsPage().tag(LibraryPage.artists)
            SongsPage().tag(LibraryPage.songs)
            PlaylistsPage().tag(LibraryPage.playlists)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    @ViewBuilder
    private func destination(for target: NavigationTarget) -> some View {
        switch target {
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

/// Navigation is by value, not by view.
///
/// Pushing a `Track`/`Album` directly would capture a stale copy; pushing its key means
/// the destination re-resolves against current state after a library reload.
enum NavigationTarget: Hashable {
    case album(AlbumKey)
    case artist(String)
    case playlist(String)
}

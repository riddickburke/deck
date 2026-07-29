import MediaPlayer
import SwiftUI

// MARK: - Mini player

/// The docked transport, and the way into the full-screen now-playing screen.
///
/// Three gestures share this one surface:
///   - tap            → open now playing
///   - swipe up       → open now playing
///   - swipe sideways → previous / next track
///
/// The vertical and horizontal cases are told apart by whichever axis the finger commits
/// to first, latched for the rest of the gesture. Deciding per frame instead lets a
/// diagonal drag flip between skipping tracks and opening the screen, which feels broken
/// in a way that is hard to describe but immediate to use.
struct MiniPlayer: View {
    @EnvironmentObject var app: MobileState
    @EnvironmentObject var playback: Playback

    @State private var axis: DragAxis = .undecided
    @State private var horizontalOffset: CGFloat = 0

    private enum DragAxis { case undecided, vertical, horizontal }

    var body: some View {
        let track = playback.currentTrack

        HStack(spacing: 10) {
            Artwork(trackID: track?.externalID, size: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "nothing playing")
                    .font(DeckFont.mono(12))
                    .foregroundStyle(app.theme.fg)
                    .lineLimit(1)
                Text(track?.artist ?? "—")
                    .font(DeckFont.mono(9))
                    .foregroundStyle(app.theme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if app.showsVisualizer {
                SpectrumView(tint: app.theme.accent.opacity(0.55), barSpacing: 2)
                    .frame(width: 42, height: 20)
                    .allowsHitTesting(false)
            }

            Button {
                playback.toggle()
                Haptics.tap()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(app.theme.fg)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: 58)
        .background(app.theme.bgAlt)
        .overlay(Rectangle().strokeBorder(app.theme.border, lineWidth: 1))
        // The only place the mini player shows position, since there is no room for a
        // real scrubber.
        .overlay(alignment: .top) {
            ProgressHairline(color: app.theme.accent.opacity(0.75))
        }
        .offset(x: horizontalOffset)
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .gesture(drag)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if axis == .undecided {
                    axis = abs(value.translation.height) > abs(value.translation.width)
                        ? .vertical : .horizontal
                }
                if axis == .horizontal {
                    // Rubber-banded: follows the finger at a fraction of the distance,
                    // so it reads as a control rather than a scroll view.
                    horizontalOffset = value.translation.width * 0.35
                }
            }
            .onEnded { value in
                switch axis {
                case .vertical:
                    if value.translation.height < -40 { open() }
                case .horizontal:
                    if value.translation.width < -60 {
                        playback.next()
                        Haptics.commit()
                    } else if value.translation.width > 60 {
                        playback.previous()
                        Haptics.commit()
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        horizontalOffset = 0
                    }
                default:
                    break
                }
                axis = .undecided
            }
    }

    private func open() {
        Haptics.tap()
        app.isNowPlayingOpen = true
    }
}

// MARK: - Now playing

/// The full-screen transport.
///
/// Presented as a `fullScreenCover`, which is what full screen means on iOS: it owns the
/// whole display, it cannot intercept touches meant for the library when closed, and it
/// gets the system's own presentation rather than an offset this code has to animate.
///
/// The layout follows the shape people already know from Spotify and Apple Music — art,
/// then titles, then position, then transport, top to bottom — while the surface itself
/// stays in the app's own language: monospace, square corners, bracket buttons.
struct NowPlayingScreen: View {
    @EnvironmentObject var app: MobileState
    @EnvironmentObject var playback: Playback

    @State private var dragOffset: CGFloat = 0
    @State private var showsQueue = false

    var body: some View {
        GeometryReader { geo in
            let art = min(geo.size.width - 48, geo.size.height * 0.42)

            VStack(spacing: 0) {
                header

                Spacer(minLength: 8)

                artwork(size: art)

                Spacer(minLength: 12)

                titles
                    .padding(.horizontal, 24)

                Spacer(minLength: 12)

                if app.showsVisualizer {
                    visualizer.padding(.horizontal, 24)
                    Spacer(minLength: 12)
                }

                Scrubber()
                    .padding(.horizontal, 24)

                transport
                    .padding(.horizontal, 16)

                Spacer(minLength: 8)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(app.theme.bg.ignoresSafeArea())
        .offset(y: dragOffset)
        // Swipe down anywhere to dismiss, the gesture every full-screen player has.
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in dragOffset = max(0, value.translation.height) }
                .onEnded { value in
                    if value.translation.height > 120 || value.predictedEndTranslation.height > 240 {
                        close()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            dragOffset = 0
                        }
                    }
                })
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            Button { close() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(app.theme.fg)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }

            Spacer()

            Text("deck://now-playing")
                .font(DeckFont.mono(10))
                .foregroundStyle(app.theme.muted)

            Spacer()

            Button { showsQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(app.theme.fg)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .sheet(isPresented: $showsQueue) {
            QueueView()
                .environmentObject(app)
                .environmentObject(playback)
                .presentationDragIndicator(.visible)
        }
    }

    /// Artwork doubles as the transport: swipe across it for previous and next.
    private func artwork(size: CGFloat) -> some View {
        Artwork(trackID: playback.currentTrack?.externalID, size: size)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height)
                        else { return }
                        if value.translation.width < -50 {
                            playback.next()
                            Haptics.commit()
                        } else if value.translation.width > 50 {
                            playback.previous()
                            Haptics.commit()
                        }
                    })
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(playback.currentTrack?.title ?? "nothing playing")
                .font(DeckFont.mono(19, weight: .semibold))
                .foregroundStyle(app.theme.fg)
                .lineLimit(2)
            Text(playback.currentTrack?.artist ?? "—")
                .font(DeckFont.mono(13))
                .foregroundStyle(app.theme.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visualizer: some View {
        VStack(spacing: 6) {
            SpectrumView(tint: app.theme.accent)
                .frame(height: 46)
            // The bars are generated, not measured — the audio is decoded by the system
            // music player and never passes through this process. Saying so costs one
            // line and stops the display being a quiet lie.
            Text("visual only · not measured from the audio")
                .font(DeckFont.mono(8))
                .foregroundStyle(app.theme.muted.opacity(0.55))
        }
        .allowsHitTesting(false)
    }

    private var transport: some View {
        HStack(spacing: 0) {
            transportButton("shuffle",
                            active: playback.shuffleMode == .songs,
                            size: 16) { playback.toggleShuffle() }

            transportButton("backward.fill", size: 26) { playback.previous() }

            transportButton(playback.isPlaying ? "pause.fill" : "play.fill",
                            size: 34) { playback.toggle() }

            transportButton("forward.fill", size: 26) { playback.next() }

            transportButton(playback.repeatMode == .one ? "repeat.1" : "repeat",
                            active: playback.repeatMode != MPMusicRepeatMode.none,
                            size: 16) { playback.cycleRepeat() }
        }
    }

    private func transportButton(
        _ symbol: String, active: Bool = false, size: CGFloat, action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            Haptics.tap()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(active ? app.theme.accent : app.theme.fg)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func close() {
        dragOffset = 0
        app.isNowPlayingOpen = false
    }
}

// MARK: - Scrubber

/// Position bar and clock, in its own view so it is the only thing that redraws as time
/// passes.
private struct Scrubber: View {
    @EnvironmentObject var app: MobileState
    @EnvironmentObject var playback: Playback
    @EnvironmentObject var clock: PlaybackClock

    /// Non-nil while a finger is down.
    ///
    /// The bar has to follow the finger rather than the player, because seeking only
    /// happens on release — without this the position springs back to the player's real
    /// value on every tick and the control cannot be dragged at all.
    @State private var scrubbing: Double?

    var body: some View {
        let duration = max(clock.duration, 0.001)
        let shown = scrubbing ?? clock.position

        VStack(spacing: 6) {
            GeometryReader { geo in
                let fraction = CGFloat(min(max(shown / duration, 0), 1))
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(app.theme.bgInset)
                        .frame(height: 4)
                    Rectangle()
                        .fill(app.theme.accent)
                        .frame(width: geo.size.width * fraction, height: 4)
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                // High priority, or the screen's swipe-to-dismiss claims the drag first.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let ratio = value.location.x / max(geo.size.width, 1)
                            scrubbing = Double(min(max(ratio, 0), 1)) * duration
                        }
                        .onEnded { _ in
                            if let target = scrubbing { playback.seek(to: target) }
                            scrubbing = nil
                        })
            }
            // Thin bar, tall hit area: 4pt of drawn control is nowhere near a touch
            // target, so the gesture region is padded well beyond what is visible.
            .frame(height: 28)

            HStack {
                Text(shown.clockString)
                Spacer()
                Text(clock.duration.clockString)
            }
            .font(DeckFont.mono(10))
            .foregroundStyle(app.theme.muted)
        }
    }
}

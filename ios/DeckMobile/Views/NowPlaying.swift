import MediaPlayer
import SwiftUI

// MARK: - Mini player

/// The docked transport, and the handle for the now-playing sheet.
///
/// Three gestures share this one surface:
///   - tap            → open now playing
///   - drag up        → open now playing, following the finger
///   - swipe sideways → previous / next track
///
/// They are disambiguated by whichever axis the finger commits to first, latched for the
/// rest of the gesture. Deciding per frame instead lets a diagonal drag flip between
/// scrubbing tracks and opening the sheet, which feels broken in a way that is hard to
/// describe but immediately obvious to use.
struct MiniPlayer: View {
    @EnvironmentObject var app: MobileState
    @EnvironmentObject var playback: Playback

    @State private var axis: DragAxis = .undecided
    @State private var horizontalOffset: CGFloat = 0

    private enum DragAxis { case undecided, vertical, horizontal }

    /// How far up the finger must travel for the sheet to be fully open.
    private let expandDistance: CGFloat = 260

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

            // A compact spectrum doubles as a playing indicator.
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
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if axis == .undecided {
                    axis = abs(value.translation.height) > abs(value.translation.width)
                        ? .vertical : .horizontal
                }
                switch axis {
                case .vertical:
                    // Only upward travel opens; downward is ignored rather than
                    // producing negative progress.
                    let lifted = max(0, -value.translation.height)
                    app.nowPlayingProgress = min(1, lifted / expandDistance)
                case .horizontal:
                    // Rubber-banded: the row follows the finger but at a fraction of
                    // the distance, so it reads as a control rather than a scroll view.
                    horizontalOffset = value.translation.width * 0.35
                default:
                    break
                }
            }
            .onEnded { value in
                switch axis {
                case .vertical:
                    let flung = value.predictedEndTranslation.height < -180
                    setOpen(flung || app.nowPlayingProgress > 0.35)
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
        setOpen(true)
    }

    private func setOpen(_ open: Bool) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            app.nowPlayingProgress = open ? 1 : 0
        }
    }
}

// MARK: - Now playing sheet

/// The full-screen transport, presented by dragging the mini player up.
///
/// Not a `.sheet`: a system sheet cannot be driven from a drag that starts on another
/// view, and its grabber and inset corners are stock iOS chrome sitting on top of a
/// deliberately non-stock design. Offsetting a plain overlay keeps the whole surface ours
/// and makes the open gesture continuous with the mini player's.
struct NowPlayingSheet: View {
    @EnvironmentObject var app: MobileState
    @EnvironmentObject var playback: Playback
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            let hidden = height * (1 - app.nowPlayingProgress)

            content
                .frame(width: geo.size.width, height: geo.size.height)
                .background(app.theme.bg)
                .offset(y: hidden + dragOffset)
                .ignoresSafeArea(edges: .bottom)
        }
        .ignoresSafeArea()
        // Fully out of the way when closed, so it cannot intercept touches meant for
        // the library underneath.
        .allowsHitTesting(app.isNowPlayingOpen)
    }

    private var content: some View {
        VStack(spacing: 0) {
            handle

            let track = playback.currentTrack

            VStack(spacing: 22) {
                artwork(for: track)

                VStack(spacing: 5) {
                    Text(track?.title ?? "nothing playing")
                        .font(DeckFont.mono(17, weight: .semibold))
                        .foregroundStyle(app.theme.fg)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(track?.artist ?? "—")
                        .font(DeckFont.mono(12))
                        .foregroundStyle(app.theme.muted)
                        .lineLimit(1)
                    Text(track?.album ?? "")
                        .font(DeckFont.mono(10))
                        .foregroundStyle(app.theme.muted.opacity(0.7))
                        .lineLimit(1)
                }
                .padding(.horizontal, 28)

                visualizer

                Scrubber()
                transport
            }
            .padding(.horizontal, 22)

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    // MARK: Pieces

    private var handle: some View {
        VStack(spacing: 10) {
            Rectangle()
                .fill(app.theme.border)
                .frame(width: 44, height: 3)
            HStack {
                BracketButton(label: "▾ close") { close() }
                Spacer()
                Text("deck://now-playing")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted)
            }
            .padding(.horizontal, 18)
        }
        .padding(.top, 46)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(dismissDrag)
    }

    /// Artwork is also the transport: swipe across it for previous and next.
    private func artwork(for track: Track?) -> some View {
        Artwork(trackID: track?.externalID, size: 280)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        if value.translation.width < -50 {
                            playback.next()
                            Haptics.commit()
                        } else if value.translation.width > 50 {
                            playback.previous()
                            Haptics.commit()
                        }
                    })
    }

    @ViewBuilder
    private var visualizer: some View {
        if app.showsVisualizer {
            VStack(spacing: 6) {
                SpectrumView(tint: app.theme.accent)
                    .frame(height: 54)
                // The bars are generated, not measured — the audio is decoded by the
                // system music player and never passes through this process. Saying so
                // costs one line and stops the display from being a quiet lie.
                Text("visual only · not measured from the audio")
                    .font(DeckFont.mono(8))
                    .foregroundStyle(app.theme.muted.opacity(0.55))
            }
            .allowsHitTesting(false)
        }
    }

    private var transport: some View {
        HStack(spacing: 0) {
            transportButton("shuffle",
                            active: playback.shuffleMode == .songs,
                            size: 15) {
                playback.toggleShuffle()
            }

            transportButton("backward.fill", size: 22) { playback.previous() }

            transportButton(playback.isPlaying ? "pause.fill" : "play.fill",
                            size: 30) {
                playback.toggle()
            }

            transportButton("forward.fill", size: 22) { playback.next() }

            transportButton(repeatSymbol,
                            active: playback.repeatMode != MPMusicRepeatMode.none,
                            size: 15) {
                playback.cycleRepeat()
            }
        }
        .padding(.top, 2)
    }

    private var repeatSymbol: String {
        playback.repeatMode == .one ? "repeat.1" : "repeat"
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
                .frame(height: 54)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Dismissal

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                let flung = value.predictedEndTranslation.height > 220
                if flung || value.translation.height > 140 {
                    close()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func close() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            app.nowPlayingProgress = 0
            dragOffset = 0
        }
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
    /// happens on release — without this the thumb springs back to the real position on
    /// every frame and the control cannot be dragged at all.
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
                .gesture(
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

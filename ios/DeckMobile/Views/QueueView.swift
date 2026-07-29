import SwiftUI

/// The playing queue, reorderable and removable.
///
/// Edits go to the player's own queue rather than to a local list that is then replayed —
/// see `Playback.moveQueueItem`. The list here is the mirror, not the source.
struct QueueView: View {
    @EnvironmentObject var app: MobileState
    @EnvironmentObject var playback: Playback
    @Environment(\.dismiss) private var dismiss

    /// Reordering on iOS needs edit mode; a drag handle with no mode to enter does
    /// nothing. The button toggles it explicitly rather than relying on a long press,
    /// which is already taken by the context menu.
    @State private var editMode: EditMode = .inactive

    var body: some View {
        ZStack {
            app.theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if playback.queue.isEmpty {
                    StatusMessage(
                        title: "queue is empty",
                        detail: "play an album or a playlist and it will show up here.")
                } else {
                    list
                }
            }
        }
        .environment(\.editMode, $editMode)
        .task { playback.refreshQueue() }
    }

    private var header: some View {
        HStack {
            Rectangle().fill(app.theme.accent).frame(width: 2, height: 14)
            Text("deck://queue")
                .font(DeckFont.mono(13, weight: .semibold))
                .foregroundStyle(app.theme.fg)
            Text("\(playback.queue.count)")
                .font(DeckFont.mono(10))
                .foregroundStyle(app.theme.muted)

            Spacer()

            if !playback.queue.isEmpty {
                BracketButton(label: editMode.isEditing ? "done" : "edit") {
                    withAnimation {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                }
            }
            BracketButton(label: "close") { dismiss() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var list: some View {
        List {
            Section {
                ForEach(Array(playback.queue.enumerated()), id: \.element.id) { index, track in
                    row(track: track, index: index)
                }
                .onMove { source, destination in
                    playback.moveQueueItem(from: source, to: destination)
                    Haptics.commit()
                }
                .onDelete { offsets in
                    playback.removeQueueItems(at: offsets)
                    Haptics.commit()
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } header: {
                SectionLabel(text: "up next")
                    .padding(.vertical, 4)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func row(track: Track, index: Int) -> some View {
        let isCurrent = playback.currentTrack?.id == track.id

        return HStack(spacing: 10) {
            // The playing row is marked rather than numbered, since its position in the
            // list is the one number that is obvious anyway.
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(app.theme.accent)
                    .frame(width: 22)
            } else {
                Text("\(index + 1)")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted.opacity(0.7))
                    .frame(width: 22, alignment: .trailing)
            }

            Artwork(trackID: track.externalID, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(DeckFont.mono(12))
                    .foregroundStyle(isCurrent ? app.theme.accent : app.theme.fg)
                    .lineLimit(1)
                Text(track.artist)
                    .font(DeckFont.mono(9))
                    .foregroundStyle(app.theme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(track.duration.clockString)
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted.opacity(0.8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(isCurrent ? app.theme.selection.opacity(0.5) : .clear)
        .onTapGesture {
            guard !editMode.isEditing else { return }
            playback.play(tracks: playback.queue, startingAt: index)
            Haptics.tap()
        }
        // Removing what is playing would stop the music with no visible cause.
        .deleteDisabled(isCurrent)
    }
}

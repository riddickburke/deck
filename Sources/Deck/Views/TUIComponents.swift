import DeckCore
import SwiftUI

// MARK: - Scanlines

/// Fixed, non-interactive overlay of 2px stripes. Subtle enough to read as texture
/// rather than as a filter — if you can consciously see it, it is too strong.
struct Scanlines: View {
    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let stripe = Path(CGRect(x: 0, y: 0, width: size.width, height: 1))
                var y: CGFloat = 0
                while y < size.height {
                    context.translateBy(x: 0, y: y == 0 ? 0 : 2)
                    context.fill(stripe, with: .color(.black.opacity(0.16)))
                    y += 2
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .blendMode(.multiply)
    }
}

// MARK: - Titlebar

struct TUITitlebar: View {
    let title: String
    var focused: Bool = true
    var trailing: String?
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 8) {
            // A short accent rule marks the focused panel instead of window dots.
            Rectangle()
                .fill(focused ? app.theme.accent : app.theme.border)
                .frame(width: 2, height: 11)
            Text(title)
                .font(DeckFont.mono(11))
                .foregroundStyle(focused ? app.theme.fg : app.theme.muted)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(app.theme.bgInset)
        .overlay(alignment: .bottom) {
            Rectangle().fill(app.theme.border).frame(height: 1)
        }
    }
}

// MARK: - Panel

/// Focus is communicated by border colour. That is the whole focus system.
struct TUIPanel<Content: View>: View {
    let title: String
    var focused: Bool = false
    var trailing: String?
    @ViewBuilder var content: Content
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            TUITitlebar(title: title, focused: focused, trailing: trailing)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(app.theme.bgAlt)
        .overlay(
            Rectangle()
                .strokeBorder(focused ? app.theme.accent : app.theme.border, lineWidth: 1)
        )
    }
}

// MARK: - Bracket button

/// Buttons render as `[ label ]` — literal brackets, no chrome. Hover changes the
/// text colour, never a background fill.
struct BracketButton: View {
    let label: String
    var tint: Color?
    var disabled: Bool = false
    var compact: Bool = false
    let action: () -> Void

    @EnvironmentObject var app: AppState
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("[ \(label) ]")
                .font(DeckFont.mono(compact ? 10 : 11))
                .foregroundStyle(color)
                .padding(.vertical, compact ? 1 : 3)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }

    private var color: Color {
        if disabled { return app.theme.muted.opacity(0.4) }
        if hovering { return tint ?? app.theme.accent }
        return tint?.opacity(0.85) ?? app.theme.muted
    }
}

// MARK: - Text field

/// Every text field in the app goes through this.
///
/// It reports its focus state to `AppState`, which is what stops single-key vim bindings
/// (`r` for repeat, `s` for shuffle, `n` for next…) from firing while you are typing a
/// playlist name or a search. Using the plain `TextField` anywhere would reintroduce that
/// bug, so don't.
struct TUITextField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat?
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var focusOnAppear: Bool = false

    @EnvironmentObject var app: AppState
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(DeckFont.mono(11))
            .foregroundStyle(app.theme.fg)
            .focused($focused)
            .frame(width: width)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(app.theme.bgInset)
            .overlay(Rectangle().strokeBorder(
                focused ? app.theme.accent : app.theme.border, lineWidth: 1))
            .onSubmit(onSubmit)
            .onExitCommand {
                focused = false
                onCancel()
            }
            .onChange(of: focused) { _, isFocused in
                app.setTextInputFocused(isFocused)
            }
            .onAppear { if focusOnAppear { focused = true } }
            .onDisappear {
                // A field removed while focused never reports losing focus, which would
                // otherwise leave the keyboard permanently in "typing" mode.
                if focused { app.setTextInputFocused(false) }
            }
    }
}

// MARK: - Meter

/// Horizontal fill meter drawn with block characters rather than a rounded ProgressView.
struct BlockMeter: View {
    let fraction: Double
    var width: Int = 20
    var tint: Color

    var body: some View {
        let filled = max(0, min(width, Int((fraction * Double(width)).rounded())))
        return Text(String(repeating: "█", count: filled)
            + String(repeating: "░", count: width - filled))
            .font(DeckFont.mono(10))
            .foregroundStyle(tint)
    }
}

// MARK: - Section label

struct SectionLabel: View {
    let text: String
    @EnvironmentObject var app: AppState

    var body: some View {
        Text(text.uppercased())
            .font(DeckFont.mono(9, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(app.theme.muted)
    }
}

// MARK: - Divider

struct TUIDivider: View {
    @EnvironmentObject var app: AppState
    var body: some View { Rectangle().fill(app.theme.border).frame(height: 1) }
}

// MARK: - Artwork

/// Album art with an async load and a terminal-flavoured placeholder.
struct ArtworkView: View {
    let album: Album?
    var size: CGFloat
    var allowNetwork: Bool = true

    @EnvironmentObject var app: AppState
    @State private var image: NSImage?
    @State private var loaded = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .overlay(Rectangle().strokeBorder(app.theme.border, lineWidth: 1))
        .task(id: album?.key) { await load() }
    }

    private var placeholder: some View {
        ZStack {
            app.theme.bgInset
            // A record-shaped glyph reads better than a generic note at small sizes.
            Text(loaded ? "◎" : "…")
                .font(DeckFont.mono(size * 0.34))
                .foregroundStyle(app.theme.muted.opacity(0.5))
        }
    }

    private func load() async {
        guard let album else { image = nil; loaded = true; return }
        image = nil
        loaded = false
        let resolved = await ArtworkStore.shared.artwork(for: album, allowNetwork: allowNetwork)
        await MainActor.run {
            self.image = resolved
            self.loaded = true
        }
    }
}

// MARK: - Hover row background

struct RowBackground: ViewModifier {
    let selected: Bool
    let hovering: Bool
    @EnvironmentObject var app: AppState

    func body(content: Content) -> some View {
        content.background(
            selected ? app.theme.selection
                : (hovering ? app.theme.selection.opacity(0.4) : Color.clear)
        )
    }
}

extension View {
    func rowBackground(selected: Bool, hovering: Bool) -> some View {
        modifier(RowBackground(selected: selected, hovering: hovering))
    }
}

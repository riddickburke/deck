import Foundation

#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

/// A colour role expressed in a way every front end can consume: the source hex for CSS,
/// and normalised components for anything that needs to draw or blend.
public struct RGB: Equatable, Sendable {
    public let r: Double
    public let g: Double
    public let b: Double
    /// The original `#rrggbb`, kept verbatim so GTK CSS and terminal escapes agree
    /// exactly with what the macOS renderer shows.
    public let hex: String

    public init(_ hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        r = Double((v >> 16) & 0xff) / 255
        g = Double((v >> 8) & 0xff) / 255
        b = Double(v & 0xff) / 255
        self.hex = "#" + s.lowercased()
    }

    public var bytes: (UInt8, UInt8, UInt8) {
        (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }

    /// 24-bit ANSI foreground escape, for terminal output.
    public var ansiForeground: String {
        let (r, g, b) = bytes
        return "\u{1B}[38;2;\(r);\(g);\(b)m"
    }

    public var ansiBackground: String {
        let (r, g, b) = bytes
        return "\u{1B}[48;2;\(r);\(g);\(b)m"
    }

    public func mixed(with other: RGB, amount: Double) -> RGB {
        let t = max(0, min(1, amount))
        let mix = { (a: Double, b: Double) in a + (b - a) * t }
        let value = String(
            format: "#%02x%02x%02x",
            Int(mix(r, other.r) * 255), Int(mix(g, other.g) * 255), Int(mix(b, other.b) * 255))
        return RGB(value)
    }
}

/// The portable half of a theme: named colour roles, no UI framework involved.
public struct Palette: Equatable, Sendable {
    public let bg: RGB
    public let bgAlt: RGB
    public let bgInset: RGB
    public let fg: RGB
    public let muted: RGB
    public let border: RGB
    public let selection: RGB
    public let accent: RGB
    public let green: RGB
    public let yellow: RGB
    public let red: RGB
    public let magenta: RGB
    public let cyan: RGB
}

/// A theme is a struct of named colour *roles*, never literal colours at the call site.
/// Styles are constructed from the active theme at render time so switching is live.
public struct Theme: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let palette: Palette

    public init(
        id: String, name: String,
        bg: String, bgAlt: String, bgInset: String, fg: String, muted: String,
        border: String, selection: String, accent: String, green: String,
        yellow: String, red: String, magenta: String, cyan: String
    ) {
        self.id = id
        self.name = name
        self.palette = Palette(
            bg: RGB(bg), bgAlt: RGB(bgAlt), bgInset: RGB(bgInset), fg: RGB(fg),
            muted: RGB(muted), border: RGB(border), selection: RGB(selection),
            accent: RGB(accent), green: RGB(green), yellow: RGB(yellow),
            red: RGB(red), magenta: RGB(magenta), cyan: RGB(cyan))
    }
}

// MARK: - SwiftUI bridge
//
// Exposed as computed properties so existing call sites keep reading `theme.accent`
// unchanged. Building a Color is cheap, and the original design already constructed
// styles at render time rather than caching them, so theme switching stays live.

#if canImport(SwiftUI)
public extension Theme {
    var bg: Color { Color(rgb: palette.bg) }
    var bgAlt: Color { Color(rgb: palette.bgAlt) }
    var bgInset: Color { Color(rgb: palette.bgInset) }
    var fg: Color { Color(rgb: palette.fg) }
    var muted: Color { Color(rgb: palette.muted) }
    var border: Color { Color(rgb: palette.border) }
    var selection: Color { Color(rgb: palette.selection) }
    var accent: Color { Color(rgb: palette.accent) }
    var green: Color { Color(rgb: palette.green) }
    var yellow: Color { Color(rgb: palette.yellow) }
    var red: Color { Color(rgb: palette.red) }
    var magenta: Color { Color(rgb: palette.magenta) }
    var cyan: Color { Color(rgb: palette.cyan) }

    /// Dominant colour used behind album hero headers when art has no usable colour.
    var heroFallback: Color { accent }
}

public extension Color {
    init(rgb: RGB) {
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }

    init(hex: String) {
        self.init(rgb: RGB(hex))
    }
}
#endif

// MARK: - Palettes

public extension Theme {
    /// The default. Deliberately plain: neutral greys, one soft accent, colour reserved
    /// for things that carry meaning (levels, warnings, sync state).
    static let dark = Theme(
        id: "dark", name: "dark",
        bg: "#121212", bgAlt: "#181818", bgInset: "#0d0d0d", fg: "#e8e8e8",
        muted: "#8a8a8a", border: "#2b2b2b", selection: "#2f2f2f",
        accent: "#8ab4f8", green: "#81c995", yellow: "#fdd663",
        red: "#f28b82", magenta: "#d7aefb", cyan: "#78d9ec"
    )

    /// Even plainer — near-monochrome, for when any colour feels like too much.
    static let graphite = Theme(
        id: "graphite", name: "graphite",
        bg: "#141414", bgAlt: "#1b1b1b", bgInset: "#0f0f0f", fg: "#dcdcdc",
        muted: "#767676", border: "#2d2d2d", selection: "#333333",
        accent: "#b9b9b9", green: "#a8b8a4", yellow: "#c9bd9a",
        red: "#c49a9a", magenta: "#b0a6bd", cyan: "#a3b6bd"
    )

    static let midnight = Theme(
        id: "midnight", name: "midnight",
        bg: "#0b0f1a", bgAlt: "#111726", bgInset: "#070a12", fg: "#dbe3f4",
        muted: "#5c6a8a", border: "#1e2637", selection: "#243049",
        accent: "#6ea8fe", green: "#6ee7a8", yellow: "#f5c86b",
        red: "#ff7b8a", magenta: "#c08bfa", cyan: "#67d8ef"
    )

    static let rosePine = Theme(
        id: "rose-pine", name: "rosé pine",
        bg: "#191724", bgAlt: "#1f1d2e", bgInset: "#12111c", fg: "#e0def4",
        muted: "#6e6a86", border: "#26233a", selection: "#403d52",
        accent: "#c4a7e7", green: "#9ccfd8", yellow: "#f6c177",
        red: "#eb6f92", magenta: "#c4a7e7", cyan: "#31748f"
    )

    static let solarizedDark = Theme(
        id: "solarized-dark", name: "solarized dark",
        bg: "#002b36", bgAlt: "#073642", bgInset: "#00212b", fg: "#93a1a1",
        muted: "#586e75", border: "#0d4451", selection: "#0f4c5c",
        accent: "#268bd2", green: "#859900", yellow: "#b58900",
        red: "#dc322f", magenta: "#d33682", cyan: "#2aa198"
    )

    static let oneDark = Theme(
        id: "one-dark", name: "one dark",
        bg: "#282c34", bgAlt: "#21252b", bgInset: "#1b1f24", fg: "#abb2bf",
        muted: "#5c6370", border: "#3e4451", selection: "#3e4451",
        accent: "#61afef", green: "#98c379", yellow: "#e5c07b",
        red: "#e06c75", magenta: "#c678dd", cyan: "#56b6c2"
    )

    static let monokai = Theme(
        id: "monokai", name: "monokai",
        bg: "#272822", bgAlt: "#2e2f28", bgInset: "#1e1f1a", fg: "#f8f8f2",
        muted: "#75715e", border: "#3e3d32", selection: "#49483e",
        accent: "#66d9ef", green: "#a6e22e", yellow: "#e6db74",
        red: "#f92672", magenta: "#ae81ff", cyan: "#66d9ef"
    )

    /// Green phosphor. Single-hue on purpose.
    static let matrix = Theme(
        id: "matrix", name: "phosphor",
        bg: "#040804", bgAlt: "#0a120a", bgInset: "#020402", fg: "#33ff66",
        muted: "#1a6b33", border: "#0f2915", selection: "#123d1e",
        accent: "#66ff99", green: "#33ff66", yellow: "#b6ff7a",
        red: "#ff5f5f", magenta: "#7affc4", cyan: "#5fffb0"
    )

    static let tokyoNight = Theme(
        id: "tokyo-night", name: "tokyo night",
        bg: "#1a1b2e", bgAlt: "#1f2035", bgInset: "#16172a", fg: "#c0caf5",
        muted: "#565f89", border: "#2a2b45", selection: "#283457",
        accent: "#7aa2f7", green: "#9ece6a", yellow: "#e0af68",
        red: "#f7768e", magenta: "#bb9af7", cyan: "#7dcfff"
    )

    static let gruvbox = Theme(
        id: "gruvbox", name: "gruvbox",
        bg: "#1d2021", bgAlt: "#282828", bgInset: "#171a1b", fg: "#ebdbb2",
        muted: "#928374", border: "#3c3836", selection: "#504945",
        accent: "#83a598", green: "#b8bb26", yellow: "#fabd2f",
        red: "#fb4934", magenta: "#d3869b", cyan: "#8ec07c"
    )

    static let nord = Theme(
        id: "nord", name: "nord",
        bg: "#2e3440", bgAlt: "#3b4252", bgInset: "#272c36", fg: "#d8dee9",
        muted: "#616e88", border: "#434c5e", selection: "#4c566a",
        accent: "#88c0d0", green: "#a3be8c", yellow: "#ebcb8b",
        red: "#bf616a", magenta: "#b48ead", cyan: "#8fbcbb"
    )

    static let catppuccin = Theme(
        id: "catppuccin", name: "catppuccin mocha",
        bg: "#1e1e2e", bgAlt: "#181825", bgInset: "#11111b", fg: "#cdd6f4",
        muted: "#6c7086", border: "#313244", selection: "#45475a",
        accent: "#89b4fa", green: "#a6e3a1", yellow: "#f9e2af",
        red: "#f38ba8", magenta: "#cba6f7", cyan: "#94e2d5"
    )

    static let dracula = Theme(
        id: "dracula", name: "dracula",
        bg: "#282a36", bgAlt: "#21222c", bgInset: "#191a21", fg: "#f8f8f2",
        muted: "#6272a4", border: "#44475a", selection: "#44475a",
        accent: "#bd93f9", green: "#50fa7b", yellow: "#f1fa8c",
        red: "#ff5555", magenta: "#ff79c6", cyan: "#8be9fd"
    )

    static let everforest = Theme(
        id: "everforest", name: "everforest",
        bg: "#2d353b", bgAlt: "#343f44", bgInset: "#272e33", fg: "#d3c6aa",
        muted: "#859289", border: "#3d484d", selection: "#475258",
        accent: "#7fbbb3", green: "#a7c080", yellow: "#dbbc7f",
        red: "#e67e80", magenta: "#d699b6", cyan: "#83c092"
    )

    /// Amber CRT — deliberately monochrome, for the full vintage-terminal look.
    static let amber = Theme(
        id: "amber", name: "amber crt",
        bg: "#0d0b06", bgAlt: "#141009", bgInset: "#080602", fg: "#ffb000",
        muted: "#7a5400", border: "#2b1f08", selection: "#3d2c05",
        accent: "#ffcc44", green: "#ffb000", yellow: "#ffd166",
        red: "#ff6b35", magenta: "#ffa94d", cyan: "#ffc971"
    )

    /// Plainest first — the list doubles as the `t` cycle order.
    static let all: [Theme] = [
        .dark, .graphite, .midnight, .oneDark, .tokyoNight, .catppuccin, .rosePine,
        .nord, .gruvbox, .everforest, .solarizedDark, .dracula, .monokai,
        .amber, .matrix,
    ]

    static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? .dark
    }
}

// MARK: - Typography

#if canImport(SwiftUI)
public enum DeckFont {
    /// Preferred in order; falls back to the system monospace if none are installed.
    /// JetBrains Mono is the spec font, but shipping without it must still look right.
    static let preferred = ["JetBrains Mono", "Berkeley Mono", "IBM Plex Mono", "SF Mono", "Menlo"]

    static let resolvedFamily: String? = {
        #if canImport(AppKit)
        let available = Set(NSFontManager.shared.availableFontFamilies)
        return preferred.first { available.contains($0) }
        #else
        return nil
        #endif
    }()

    /// Everything is monospace. No exceptions — proportional type breaks the illusion.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard let family = resolvedFamily else {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        return .custom(family, fixedSize: size).weight(weight)
    }

    /// Display face for titlebars and big headers.
    public static func display(_ size: CGFloat) -> Font {
        #if canImport(AppKit)
        if NSFontManager.shared.availableFontFamilies.contains("VT323") {
            return .custom("VT323", fixedSize: size)
        }
        #endif
        return mono(size, weight: .semibold)
    }
}
#endif

/// Font stack for front ends that take a family name rather than a Font object
/// (GTK CSS, terminal config). Same intent as DeckFont, expressed portably.
public enum FontStack {
    public static let monospace = [
        "JetBrains Mono", "Berkeley Mono", "IBM Plex Mono", "SF Mono",
        "DejaVu Sans Mono", "Liberation Mono", "Menlo", "monospace",
    ]

    /// A CSS `font-family` value.
    public static var cssFamily: String {
        monospace.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: ", ")
    }
}

import CGtk4
import DeckCore
import Foundation

/// Translates a Deck theme into GTK CSS.
///
/// The rules mirror the macOS build's design language: everything monospace, 1px
/// borders, zero border radius, no shadows or gradients, buttons rendered as bracketed
/// text with no chrome, and focus communicated by border colour alone.
enum Styling {
    private static var provider: Widget?

    static func apply(_ theme: Theme) {
        if provider == nil {
            provider = UnsafeMutableRawPointer(gtk_css_provider_new())
            if let provider { deck_css_apply(provider) }
        }
        guard let provider else { return }
        deck_css_load(provider, css(for: theme))
    }

    static func css(for theme: Theme) -> String {
        let p = theme.palette
        let mono = FontStack.cssFamily

        return """
        /* Generated from the "\(theme.id)" palette. */

        * {
          font-family: \(mono);
          font-size: 11pt;
          border-radius: 0;
          box-shadow: none;
          text-shadow: none;
          outline: none;
        }

        window, .background {
          background-color: \(p.bg.hex);
          color: \(p.fg.hex);
        }

        /* Panels are separated by a single hairline, never a shadow. */
        .panel {
          background-color: \(p.bgAlt.hex);
          border: 1px solid \(p.border.hex);
        }

        .panel:focus-within {
          border-color: \(p.accent.hex);
        }

        .titlebar {
          background-color: \(p.bgInset.hex);
          border-bottom: 1px solid \(p.border.hex);
          padding: 4px 10px;
          min-height: 26px;
        }

        .title {
          color: \(p.fg.hex);
          font-size: 10pt;
        }

        /* The short accent rule that marks the focused panel. */
        .rule {
          background-color: \(p.accent.hex);
          min-width: 2px;
        }

        .rule-idle {
          background-color: \(p.border.hex);
          min-width: 2px;
        }

        .muted   { color: \(p.muted.hex); font-size: 9pt; }
        .accent  { color: \(p.accent.hex); }
        .ok      { color: \(p.green.hex); }
        .warn    { color: \(p.yellow.hex); }
        .danger  { color: \(p.red.hex); }
        .special { color: \(p.magenta.hex); }
        .heading { color: \(p.fg.hex); font-size: 16pt; font-weight: bold; }
        .mono-small { font-size: 9pt; }

        /* Bracket buttons: text only, hover changes colour rather than filling. */
        button {
          background: none;
          background-image: none;
          border: none;
          color: \(p.muted.hex);
          padding: 2px 6px;
          min-height: 0;
          min-width: 0;
        }

        button:hover  { color: \(p.accent.hex); background: none; }
        button:active { color: \(p.fg.hex); background: none; }
        button:disabled { color: \(alpha(p.muted, 0.4)); }

        button.primary { color: \(p.accent.hex); }
        button.ok      { color: \(p.green.hex); }
        button.danger  { color: \(p.red.hex); }

        /* Rows: selection is a flat fill, never a rounded pill. */
        list, listview {
          background-color: transparent;
          color: \(p.fg.hex);
        }

        row {
          background-color: transparent;
          color: \(p.fg.hex);
          min-height: 0;
        }

        row:hover    { background-color: \(alpha(p.selection, 0.45)); }
        row:selected { background-color: \(p.selection.hex); color: \(p.fg.hex); }
        row:selected label { color: \(p.fg.hex); }

        .sidebar { background-color: \(p.bgAlt.hex); }
        .inset   { background-color: \(p.bgInset.hex); }

        separator {
          background-color: \(p.border.hex);
          min-width: 1px;
          min-height: 1px;
        }

        /* Transport bar pinned to the bottom, full width. */
        .transport {
          background-color: \(p.bgAlt.hex);
          border-top: 1px solid \(p.border.hex);
          padding: 8px 12px;
        }

        .statusbar {
          background-color: \(p.bgInset.hex);
          border-top: 1px solid \(p.border.hex);
          padding: 2px 8px;
          font-size: 9pt;
        }

        .mode {
          background-color: \(p.accent.hex);
          color: \(p.bg.hex);
          padding: 1px 8px;
        }

        .segment {
          background-color: \(p.selection.hex);
          color: \(p.fg.hex);
          padding: 1px 8px;
        }

        /* Square scrubber, no rounded trough or circular handle. */
        scale trough {
          background-color: \(p.border.hex);
          border: none;
          min-height: 4px;
        }

        scale highlight {
          background-color: \(p.accent.hex);
          border: none;
        }

        scale slider {
          background-color: \(p.fg.hex);
          border: none;
          min-width: 3px;
          min-height: 12px;
          margin: -4px 0;
        }

        progressbar trough {
          background-color: \(p.border.hex);
          min-height: 4px;
        }

        progressbar progress {
          background-color: \(p.accent.hex);
          min-height: 4px;
        }

        /* Album art tiles keep a hairline border and square corners. */
        .art {
          border: 1px solid \(p.border.hex);
          background-color: \(p.bgInset.hex);
        }

        .art-selected { border-color: \(p.accent.hex); }

        entry {
          background-color: \(p.bgInset.hex);
          color: \(p.fg.hex);
          border: 1px solid \(p.border.hex);
          padding: 4px 6px;
          min-height: 0;
        }

        entry:focus { border-color: \(p.accent.hex); }

        checkbutton check {
          background-color: \(p.bgInset.hex);
          border: 1px solid \(p.border.hex);
          min-width: 12px;
          min-height: 12px;
        }

        checkbutton check:checked {
          background-color: \(p.green.hex);
          border-color: \(p.green.hex);
        }

        scrollbar { background-color: transparent; border: none; }
        scrollbar slider {
          background-color: \(p.border.hex);
          min-width: 6px;
          border: none;
        }
        scrollbar slider:hover { background-color: \(p.muted.hex); }

        tooltip {
          background-color: \(p.bgInset.hex);
          color: \(p.fg.hex);
          border: 1px solid \(p.border.hex);
        }
        """
    }

    /// GTK CSS understands rgba(), which is how translucent fills are expressed since
    /// the palette itself stores opaque colours only.
    private static func alpha(_ colour: RGB, _ value: Double) -> String {
        let (r, g, b) = colour.bytes
        return "rgba(\(r), \(g), \(b), \(String(format: "%.2f", value)))"
    }
}

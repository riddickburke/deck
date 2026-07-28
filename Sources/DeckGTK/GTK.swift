import CGtk4
import Foundation

/// Every widget crosses the C boundary as `void *`, so Swift sees one concrete type
/// regardless of which instance structs the installed GTK headers expose.
typealias Widget = UnsafeMutableRawPointer

// MARK: - Signals

/// Retains a Swift closure for the lifetime of a signal connection.
private final class SignalBox {
    let action: (Widget?) -> Void
    init(_ action: @escaping (Widget?) -> Void) { self.action = action }
}

/// Frees the boxed closure when GTK disposes the connection.
private let releaseBox: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { data, _ in
    guard let data else { return }
    Unmanaged<SignalBox>.fromOpaque(data).release()
}

/// Handler for signals whose C signature is `(instance, user_data)` — "clicked",
/// "activate", "destroy", "value-changed".
private let callback2: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
    guard let data else { return }
    Unmanaged<SignalBox>.fromOpaque(data).takeUnretainedValue().action(nil)
}

/// Handler for signals whose C signature is `(instance, arg, user_data)` —
/// "row-activated", "row-selected".
///
/// The arity has to match: with a three-argument signal the user data arrives in the
/// third parameter, so registering a two-argument callback would read the signal's own
/// argument as the closure pointer and crash.
private let callback3: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, arg, data in
    guard let data else { return }
    Unmanaged<SignalBox>.fromOpaque(data).takeUnretainedValue().action(arg)
}

/// Connects a signal with the `(instance, user_data)` shape.
func onSignal(_ instance: Widget, _ name: String, _ handler: @escaping () -> Void) {
    let box = Unmanaged.passRetained(SignalBox { _ in handler() }).toOpaque()
    deck_signal_connect(
        instance, name,
        unsafeBitCast(callback2, to: GCallback.self),
        box, releaseBox)
}

/// Connects a signal with the `(instance, argument, user_data)` shape. The argument is
/// handed to the closure — for "row-activated" it is the GtkListBoxRow.
func onSignalWithArgument(
    _ instance: Widget, _ name: String, _ handler: @escaping (Widget?) -> Void
) {
    let box = Unmanaged.passRetained(SignalBox(handler)).toOpaque()
    deck_signal_connect(
        instance, name,
        unsafeBitCast(callback3, to: GCallback.self),
        box, releaseBox)
}

// MARK: - Keyboard

private final class KeyBox {
    let action: (UInt32, UInt32) -> Bool
    init(_ action: @escaping (UInt32, UInt32) -> Bool) { self.action = action }
}

/// GTK's "key-pressed" is `(controller, keyval, keycode, state, user_data)`. The
/// modifier mask is a C enum, which is ABI-identical to a 32-bit int.
private let keyCallback: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?
) -> gboolean = { _, keyval, _, state, data in
    guard let data else { return 0 }
    let box = Unmanaged<KeyBox>.fromOpaque(data).takeUnretainedValue()
    return box.action(keyval, state) ? 1 : 0
}

/// Handles key presses on a widget. Return true from the closure to stop propagation,
/// which is what prevents a binding firing while a text entry has focus.
func onKeyPressed(_ widget: Widget, _ handler: @escaping (UInt32, UInt32) -> Bool) {
    guard let controller = deck_key_controller_new(widget) else { return }
    let box = Unmanaged.passRetained(KeyBox(handler)).toOpaque()
    deck_signal_connect(
        controller, "key-pressed",
        unsafeBitCast(keyCallback, to: GCallback.self),
        box, releaseBox)
}

/// GDK keyval constants used by the bindings.
enum Key {
    static let escape: UInt32 = 0xff1b
    static let ret: UInt32 = 0xff0d
    static let space: UInt32 = 0x020
    static let left: UInt32 = 0xff51
    static let up: UInt32 = 0xff52
    static let right: UInt32 = 0xff53
    static let down: UInt32 = 0xff54

    /// Printable keyvals match ASCII, so a character maps straight onto its scalar.
    static func character(_ c: Character) -> UInt32 {
        UInt32(c.unicodeScalars.first?.value ?? 0)
    }
}

// MARK: - Main loop

private final class TickBox {
    let action: () -> Bool
    init(_ action: @escaping () -> Bool) { self.action = action }
}

private let tickCallback: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
    guard let data else { return 0 }
    let box = Unmanaged<TickBox>.fromOpaque(data).takeUnretainedValue()
    return box.action() ? 1 : 0
}

/// Repeating timer on the GTK main loop. The closure returns false to stop.
@discardableResult
func everyMilliseconds(_ interval: Int, _ handler: @escaping () -> Bool) -> UInt32 {
    let box = Unmanaged.passRetained(TickBox(handler)).toOpaque()
    return deck_timeout_add(
        guint(interval), unsafeBitCast(tickCallback, to: GSourceFunc.self), box)
}

/// Runs work on the GTK main thread. Widgets must only be touched from there, so every
/// completion coming off a Task hops through this.
func onMainThread(_ handler: @escaping () -> Void) {
    let box = Unmanaged.passRetained(TickBox { handler(); return false }).toOpaque()
    deck_idle_add(unsafeBitCast(tickCallback, to: GSourceFunc.self), box)
}

// MARK: - Widget construction

enum GTK {
    static func box(horizontal: Bool, spacing: Int = 0, css: String? = nil) -> Widget {
        let w = deck_box_new(horizontal ? 1 : 0, Int32(spacing))!
        if let css { deck_add_class(w, css) }
        return w
    }

    static func label(_ text: String, css: String? = nil, centered: Bool = false) -> Widget {
        let w = deck_label_new(text)!
        if centered { deck_label_set_center(w) }
        if let css { deck_add_class(w, css) }
        return w
    }

    static func button(_ title: String, css: String? = nil, action: @escaping () -> Void) -> Widget {
        let w = deck_button_new(title)!
        if let css { deck_add_class(w, css) }
        onSignal(w, "clicked", action)
        return w
    }

    static func scrolled(_ child: Widget) -> Widget {
        let w = deck_scrolled_new()!
        deck_scrolled_set_child(w, child)
        deck_set_vexpand(w, 1)
        return w
    }

    static func list(css: String? = nil) -> Widget {
        let w = deck_listbox_new()!
        if let css { deck_add_class(w, css) }
        return w
    }

    static func separator(horizontal: Bool = true) -> Widget {
        deck_separator_new(horizontal ? 1 : 0)!
    }

    static func picture(size: Int) -> Widget {
        let w = deck_picture_new()!
        deck_set_size(w, Int32(size), Int32(size))
        return w
    }

    static func scale(min: Double, max: Double) -> Widget {
        deck_scale_new(min, max)!
    }

    static func check(_ title: String, active: Bool, action: @escaping (Bool) -> Void) -> Widget {
        let w = deck_check_new(title)!
        deck_check_set_active(w, active ? 1 : 0)
        onSignal(w, "toggled") { action(deck_check_active(w) != 0) }
        return w
    }

    /// A row for a list box: a horizontal container with consistent padding.
    static func row(_ children: [Widget], css: String? = nil) -> Widget {
        let w = box(horizontal: true, spacing: 8, css: css ?? "row")
        deck_set_margins(w, 3, 3, 10, 10)
        for child in children { deck_box_append(w, child) }
        return w
    }
}

// MARK: - Helpers

extension Widget {
    @discardableResult
    func expandHorizontally(_ value: Bool = true) -> Widget {
        deck_set_hexpand(self, value ? 1 : 0)
        return self
    }

    @discardableResult
    func expandVertically(_ value: Bool = true) -> Widget {
        deck_set_vexpand(self, value ? 1 : 0)
        return self
    }

    @discardableResult
    func sized(width: Int = -1, height: Int = -1) -> Widget {
        deck_set_size(self, Int32(width), Int32(height))
        return self
    }

    @discardableResult
    func styled(_ name: String) -> Widget {
        deck_add_class(self, name)
        return self
    }

    func unstyled(_ name: String) {
        deck_remove_class(self, name)
    }

    func setText(_ text: String) {
        deck_label_set(self, text)
    }

    func append(_ child: Widget) {
        deck_box_append(self, child)
    }
}

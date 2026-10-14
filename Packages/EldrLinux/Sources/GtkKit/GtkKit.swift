// SPDX-License-Identifier: Apache-2.0
// GtkKit — a deliberately thin, self-written Swift layer over GTK 4's C API.
// Only what eldr-gtk needs: pointer casts, signal → closure trampolines, and a
// main-loop hop. Everything else is plain C calls. All widget work MUST happen on
// the GTK main thread; `onMain` is the only way back to it from Swift concurrency
// (the Swift MainActor queue is NOT drained while g_application_run owns the thread).
@_exported import CGtk4

public typealias Widget = UnsafeMutablePointer<GtkWidget>

/// Reinterprets a GObject pointer as another GTK type (the C cast macros don't import).
@inlinable public func cast<T>(_ p: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<T> {
    p!.assumingMemoryBound(to: T.self)
}
@inlinable public func cast<T, U>(_ p: UnsafeMutablePointer<U>) -> UnsafeMutablePointer<T> {
    UnsafeMutableRawPointer(p).assumingMemoryBound(to: T.self)
}
/// Same, for GTK types Swift imports as opaque (GtkPaned, GtkListBox, controllers…).
@inlinable public func cast<U>(_ p: UnsafeMutablePointer<U>) -> OpaquePointer { OpaquePointer(p) }
@inlinable public func cast(_ p: UnsafeMutableRawPointer?) -> OpaquePointer { OpaquePointer(p!) }
@inlinable public func cast<T>(_ p: OpaquePointer) -> UnsafeMutablePointer<T> { UnsafeMutablePointer<T>(p) }
@inlinable public func widget<U>(_ p: UnsafeMutablePointer<U>) -> Widget { cast(p) }

// MARK: - Signals

final class Box<F> {
    let f: F
    init(_ f: F) { self.f = f }
}

private let releaseBox: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<AnyObject>.fromOpaque(data).release()
}

@discardableResult
private func connect<F>(_ obj: UnsafeMutableRawPointer, _ signal: String, _ f: F, _ tramp: GCallback) -> gulong {
    let box = Unmanaged.passRetained(Box(f) as AnyObject).toOpaque()
    return g_signal_connect_data(obj, signal, tramp, box, releaseBox, GConnectFlags(rawValue: 0))
}

@discardableResult
public func on(_ obj: OpaquePointer, _ signal: String, _ f: @escaping () -> Void) -> gulong {
    on(UnsafeMutablePointer<GObject>(obj), signal, f)
}
@discardableResult
public func on(_ obj: OpaquePointer, _ signal: String, _ f: @escaping (UnsafeMutableRawPointer?) -> Void) -> gulong {
    on(UnsafeMutablePointer<GObject>(obj), signal, f)
}
@discardableResult
public func onKeyPressed(_ ctrl: OpaquePointer, _ f: @escaping (UInt32, GdkModifierType) -> Bool) -> gulong {
    onKeyPressed(UnsafeMutablePointer<GObject>(ctrl), f)
}

/// Signals of shape `void (*)(GObject *self, gpointer user_data)` — clicked, activate, changed…
@discardableResult
public func on<U>(_ obj: UnsafeMutablePointer<U>, _ signal: String, _ f: @escaping () -> Void) -> gulong {
    let t: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, d in
        (Unmanaged<AnyObject>.fromOpaque(d!).takeUnretainedValue() as! Box<() -> Void>).f()
    }
    return connect(UnsafeMutableRawPointer(obj), signal, f, unsafeBitCast(t, to: GCallback.self))
}

/// Signals of shape `void (*)(GObject *self, gpointer arg, gpointer user_data)` — row-activated…
@discardableResult
public func on<U>(_ obj: UnsafeMutablePointer<U>, _ signal: String, _ f: @escaping (UnsafeMutableRawPointer?) -> Void) -> gulong {
    let t: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, a, d in
        (Unmanaged<AnyObject>.fromOpaque(d!).takeUnretainedValue() as! Box<(UnsafeMutableRawPointer?) -> Void>).f(a)
    }
    return connect(UnsafeMutableRawPointer(obj), signal, f, unsafeBitCast(t, to: GCallback.self))
}

/// GtkEventControllerKey::key-pressed. Return true to stop propagation.
@discardableResult
public func onKeyPressed<U>(_ ctrl: UnsafeMutablePointer<U>, _ f: @escaping (_ keyval: UInt32, _ state: GdkModifierType) -> Bool) -> gulong {
    let t: @convention(c) (UnsafeMutableRawPointer?, guint, guint, GdkModifierType, UnsafeMutableRawPointer?) -> gboolean = { _, kv, _, st, d in
        (Unmanaged<AnyObject>.fromOpaque(d!).takeUnretainedValue() as! Box<(UInt32, GdkModifierType) -> Bool>).f(kv, st) ? 1 : 0
    }
    return connect(UnsafeMutableRawPointer(ctrl), "key-pressed", f, unsafeBitCast(t, to: GCallback.self))
}

// MARK: - Main-loop hop

/// Runs `f` on the GTK main thread at the next idle point. Safe from any thread.
public func onMain(_ f: @escaping @Sendable () -> Void) {
    let box = Unmanaged.passRetained(Box(f)).toOpaque()
    let t: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { d in
        let b = Unmanaged<Box<@Sendable () -> Void>>.fromOpaque(d!).takeRetainedValue()
        b.f()
        return 0  // G_SOURCE_REMOVE
    }
    g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, t, box, nil)
}

/// A repeating timer on the GTK main loop (seconds). Returns the source id.
@discardableResult
public func every(seconds: UInt32, _ f: @escaping () -> Void) -> guint {
    let box = Unmanaged.passRetained(Box(f)).toOpaque()
    let t: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { d in
        Unmanaged<Box<() -> Void>>.fromOpaque(d!).takeUnretainedValue().f()
        return 1
    }
    return g_timeout_add_seconds_full(G_PRIORITY_DEFAULT, seconds, t, box, nil)
}

// MARK: - Small helpers

public func label(_ text: String, wrap: Bool = false, selectable: Bool = false, xalign: Float = 0) -> Widget {
    let l = gtk_label_new(text)!
    let lp: OpaquePointer = cast(l)
    gtk_label_set_xalign(lp, xalign)
    if wrap {
        gtk_label_set_wrap(lp, 1)
        gtk_label_set_wrap_mode(lp, PANGO_WRAP_WORD_CHAR)
    }
    if selectable { gtk_label_set_selectable(lp, 1) }
    return l
}

public func setLabel(_ w: Widget, _ text: String) { gtk_label_set_text(cast(w), text) }

/// Sets Pango markup, falling back to plain `fallback` if Pango rejects it (a label
/// given invalid markup renders EMPTY, which would hide the message).
public func setMarkup(_ w: Widget, _ markup: String, fallback: String) {
    if pango_parse_markup(markup, -1, 0, nil, nil, nil, nil) != 0 {
        gtk_label_set_markup(cast(w), markup)
    } else {
        gtk_label_set_text(cast(w), fallback)
    }
}

public func button(_ text: String, _ f: @escaping () -> Void) -> Widget {
    let b = gtk_button_new_with_label(text)!
    on(b, "clicked", f)
    return b
}

public func vbox(_ spacing: Int32 = 6) -> Widget { gtk_box_new(GTK_ORIENTATION_VERTICAL, spacing) }
public func hbox(_ spacing: Int32 = 6) -> Widget { gtk_box_new(GTK_ORIENTATION_HORIZONTAL, spacing) }
public func append(_ box: Widget, _ child: Widget) { gtk_box_append(cast(box), child) }
public func addClass(_ w: Widget, _ c: String) { gtk_widget_add_css_class(w, c) }
public func margins(_ w: Widget, _ m: Int32) {
    gtk_widget_set_margin_top(w, m); gtk_widget_set_margin_bottom(w, m)
    gtk_widget_set_margin_start(w, m); gtk_widget_set_margin_end(w, m)
}
public func expand(_ w: Widget, h: Bool = false, v: Bool = false) {
    gtk_widget_set_hexpand(w, h ? 1 : 0); gtk_widget_set_vexpand(w, v ? 1 : 0)
}
public func scrolled(_ child: Widget) -> Widget {
    let s = gtk_scrolled_window_new()!
    gtk_scrolled_window_set_child(cast(s), child)
    gtk_scrolled_window_set_policy(cast(s), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
    return s
}
public func entryText(_ e: Widget) -> String { String(cString: gtk_editable_get_text(cast(e))) }
public func setEntryText(_ e: Widget, _ s: String) { gtk_editable_set_text(cast(e), s) }

/// Full text of a GtkTextView (handles arbitrarily large pasted content).
public func textViewText(_ tv: Widget) -> String {
    let buf = gtk_text_view_get_buffer(cast(tv))
    var start = GtkTextIter(), end = GtkTextIter()
    gtk_text_buffer_get_bounds(buf, &start, &end)
    guard let c = gtk_text_buffer_get_text(buf, &start, &end, 0) else { return "" }
    defer { g_free(c) }
    return String(cString: c)
}
public func setTextViewText(_ tv: Widget, _ s: String) {
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(cast(tv)), s, -1)
}

/// Removes every row from a GtkListBox (loop, not gtk_list_box_remove_all: that is
/// GTK 4.12+, and Ubuntu 22.04 / CI ships 4.6).
public func clearList(_ list: Widget) {
    while let child = gtk_widget_get_first_child(list) { gtk_list_box_remove(cast(list), child) }
}

public func installCSS(_ css: String) {
    let p = gtk_css_provider_new()
    gtk_css_provider_load_from_data(p, css, -1)  // 4.0 API (load_from_string is 4.12+)
    gtk_style_context_add_provider_for_display(
        gdk_display_get_default(), cast(p), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
}

public func copyToClipboard(_ w: Widget, _ s: String) {
    gdk_clipboard_set_text(gtk_widget_get_clipboard(w), s)
}

// MARK: - Drawing

/// A GtkDrawingArea whose draw func calls `f(cairo, width, height)`. The closure box is
/// released with the widget.
public func drawingArea(width: Int32, height: Int32, _ f: @escaping (OpaquePointer, Int32, Int32) -> Void) -> Widget? {
    guard let w = gtk_drawing_area_new() else { return nil }
    gtk_widget_set_size_request(w, width, height)
    let box = Unmanaged.passRetained(Box(f) as AnyObject).toOpaque()
    let draw: GtkDrawingAreaDrawFunc = { _, cr, wd, ht, d in
        guard let d, let cr,
            let b = Unmanaged<AnyObject>.fromOpaque(d).takeUnretainedValue() as? Box<(OpaquePointer, Int32, Int32) -> Void>
        else { return }
        b.f(cr, wd, ht)
    }
    let destroy: GDestroyNotify = { d in
        guard let d else { return }
        Unmanaged<AnyObject>.fromOpaque(d).release()
    }
    gtk_drawing_area_set_draw_func(cast(w), draw, box, destroy)
    return w
}
public func redraw(_ w: Widget) { gtk_widget_queue_draw(w) }

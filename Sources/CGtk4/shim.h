// Umbrella header for the GTK4 system library target.
//
// Two things make raw GTK4 awkward from Swift, and both are solved here rather than at
// every call site:
//
//  1. GTK's downcast macros (GTK_BOX, GTK_WINDOW, ...) are C macros, so Swift cannot
//     call them. Whether Swift will implicitly convert a GtkWidget* to a GtkBox*
//     depends on which instance structs the installed GTK exposes, which varies. Every
//     wrapper below therefore takes and returns GtkWidget* and casts internally.
//
//  2. g_signal_connect is a macro, and g_signal_connect_data takes a GConnectFlags
//     whose Swift import differs across glib versions (G_CONNECT_DEFAULT only exists
//     from 2.74). deck_signal_connect does that cast in C, where it is always valid.
//
// Everything is static inline, so this adds no object code and no library to link
// beyond GTK itself.

#pragma once

#include <gtk/gtk.h>
#include <glib.h>
#include <glib-object.h>
#include <gio/gio.h>

// MARK: - Signals and lifecycle

static inline gulong deck_signal_connect(gpointer instance,
                                         const char *detailed_signal,
                                         GCallback handler,
                                         gpointer data,
                                         GClosureNotify destroy_data) {
    return g_signal_connect_data(instance, detailed_signal, handler, data,
                                 destroy_data, (GConnectFlags) 0);
}

/// G_APPLICATION_FLAGS_NONE was deprecated in glib 2.74 for G_APPLICATION_DEFAULT_FLAGS.
static inline void *deck_application_new(const char *app_id) {
#if GLIB_CHECK_VERSION(2, 74, 0)
    return gtk_application_new(app_id, G_APPLICATION_DEFAULT_FLAGS);
#else
    return gtk_application_new(app_id, G_APPLICATION_FLAGS_NONE);
#endif
}

static inline int deck_application_run(void *app, int argc, char **argv) {
    return g_application_run(G_APPLICATION(app), argc, argv);
}

static inline void deck_object_unref(gpointer object) { g_object_unref(object); }

static inline guint deck_timeout_add(guint interval_ms, GSourceFunc fn, gpointer data) {
    return g_timeout_add(interval_ms, fn, data);
}

static inline void deck_source_remove(guint id) { g_source_remove(id); }
static inline void deck_idle_add(GSourceFunc fn, gpointer data) { g_idle_add(fn, data); }

// MARK: - Styling

static inline void deck_css_load(void *provider, const char *css) {
#if GTK_CHECK_VERSION(4, 12, 0)
    gtk_css_provider_load_from_string(GTK_CSS_PROVIDER(provider), css);
#else
    gtk_css_provider_load_from_data(GTK_CSS_PROVIDER(provider), css, -1);
#endif
}

static inline void deck_css_apply(void *provider) {
    gtk_style_context_add_provider_for_display(
        gdk_display_get_default(), GTK_STYLE_PROVIDER(provider),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

static inline void deck_add_class(void *w, const char *name) {
    gtk_widget_add_css_class(GTK_WIDGET(w), name);
}

static inline void deck_remove_class(void *w, const char *name) {
    gtk_widget_remove_css_class(GTK_WIDGET(w), name);
}

// MARK: - Window

static inline void *deck_app_window_new(void *app) {
    return gtk_application_window_new(GTK_APPLICATION(app));
}

static inline void deck_window_set_title(void *w, const char *title) {
    gtk_window_set_title(GTK_WINDOW(GTK_WIDGET(w)), title);
}

static inline void deck_window_set_default_size(void *w, int width, int height) {
    gtk_window_set_default_size(GTK_WINDOW(GTK_WIDGET(w)), width, height);
}

static inline void deck_window_set_child(void *w, void *child) {
    gtk_window_set_child(GTK_WINDOW(GTK_WIDGET(w)), GTK_WIDGET(child));
}

static inline void deck_window_present(void *w) { gtk_window_present(GTK_WINDOW(GTK_WIDGET(w))); }

// MARK: - Containers

static inline void *deck_box_new(int horizontal, int spacing) {
    return gtk_box_new(horizontal ? GTK_ORIENTATION_HORIZONTAL
                                  : GTK_ORIENTATION_VERTICAL,
                       spacing);
}

static inline void deck_box_append(void *box, void *child) {
    gtk_box_append(GTK_BOX(box), child);
}

static inline void deck_box_remove(void *box, void *child) {
    gtk_box_remove(GTK_BOX(box), child);
}

static inline void *deck_scrolled_new(void) {
    GtkWidget *s = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(s),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    return s;
}

static inline void deck_scrolled_set_child(void *s, void *child) {
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(s), child);
}

static inline void *deck_paned_new(int horizontal) {
    return gtk_paned_new(horizontal ? GTK_ORIENTATION_HORIZONTAL
                                    : GTK_ORIENTATION_VERTICAL);
}

static inline void deck_paned_set_start(void *p, void *child) {
    gtk_paned_set_start_child(GTK_PANED(p), child);
}

static inline void deck_paned_set_end(void *p, void *child) {
    gtk_paned_set_end_child(GTK_PANED(p), child);
}

static inline void deck_paned_set_position(void *p, int position) {
    gtk_paned_set_position(GTK_PANED(p), position);
}

// MARK: - List

static inline void *deck_listbox_new(void) {
    GtkWidget *l = gtk_list_box_new();
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(l), GTK_SELECTION_SINGLE);
    return l;
}

static inline void deck_listbox_append(void *list, void *child) {
    gtk_list_box_append(GTK_LIST_BOX(list), child);
}

static inline void deck_listbox_remove_all(void *list) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(GTK_WIDGET(list))) != NULL) {
        gtk_list_box_remove(GTK_LIST_BOX(list), child);
    }
}

static inline int deck_listbox_row_index(void *row) {
    return gtk_list_box_row_get_index(GTK_LIST_BOX_ROW(row));
}

static inline void deck_listbox_select_index(void *list, int index) {
    GtkListBoxRow *row = gtk_list_box_get_row_at_index(GTK_LIST_BOX(list), index);
    if (row) {
        gtk_list_box_select_row(GTK_LIST_BOX(list), row);
        gtk_widget_grab_focus(GTK_WIDGET(row));
    }
}

static inline int deck_listbox_selected_index(void *list) {
    GtkListBoxRow *row = gtk_list_box_get_selected_row(GTK_LIST_BOX(list));
    return row ? gtk_list_box_row_get_index(row) : -1;
}

// MARK: - Leaf widgets

static inline void *deck_label_new(const char *text) {
    GtkWidget *l = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(l), 0.0f);
    gtk_label_set_ellipsize(GTK_LABEL(l), PANGO_ELLIPSIZE_END);
    return l;
}

static inline void deck_label_set(void *l, const char *text) {
    gtk_label_set_text(GTK_LABEL(l), text);
}

static inline void deck_label_set_center(void *l) {
    gtk_label_set_xalign(GTK_LABEL(l), 0.5f);
}

static inline void *deck_button_new(const char *label) {
    return gtk_button_new_with_label(label);
}

static inline void deck_button_set_label(void *b, const char *label) {
    gtk_button_set_label(GTK_BUTTON(b), label);
}

static inline void *deck_picture_new(void) {
    GtkWidget *p = gtk_picture_new();
    gtk_picture_set_can_shrink(GTK_PICTURE(p), TRUE);
    // Content fit arrived in GTK 4.8; Ubuntu 22.04 ships 4.6, where keeping the
    // aspect ratio is the closest equivalent.
#if GTK_CHECK_VERSION(4, 8, 0)
    gtk_picture_set_content_fit(GTK_PICTURE(p), GTK_CONTENT_FIT_COVER);
#else
    gtk_picture_set_keep_aspect_ratio(GTK_PICTURE(p), TRUE);
#endif
    return p;
}

static inline void deck_picture_set_file(void *p, const char *path) {
    if (path == NULL) {
        gtk_picture_set_paintable(GTK_PICTURE(p), NULL);
        return;
    }
    gtk_picture_set_filename(GTK_PICTURE(p), path);
}

static inline void *deck_scale_new(double min, double max) {
    GtkWidget *s = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, min, max, 0.1);
    gtk_scale_set_draw_value(GTK_SCALE(s), FALSE);
    return s;
}

static inline double deck_scale_value(void *s) {
    return gtk_range_get_value(GTK_RANGE(s));
}

static inline void deck_scale_set_value(void *s, double value) {
    gtk_range_set_value(GTK_RANGE(s), value);
}

static inline void deck_scale_set_range(void *s, double min, double max) {
    gtk_range_set_range(GTK_RANGE(s), min, max < min ? min + 0.001 : max);
}

static inline void *deck_separator_new(int horizontal) {
    return gtk_separator_new(horizontal ? GTK_ORIENTATION_HORIZONTAL
                                        : GTK_ORIENTATION_VERTICAL);
}

static inline void *deck_progress_new(void) {
    return gtk_progress_bar_new();
}

static inline void deck_progress_set(void *p, double fraction) {
    gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(p), fraction);
}

static inline void *deck_check_new(const char *label) {
    return gtk_check_button_new_with_label(label);
}

static inline int deck_check_active(void *c) {
    return gtk_check_button_get_active(GTK_CHECK_BUTTON(c)) ? 1 : 0;
}

static inline void deck_check_set_active(void *c, int active) {
    gtk_check_button_set_active(GTK_CHECK_BUTTON(c), active ? TRUE : FALSE);
}

// MARK: - Widget properties

static inline void deck_set_hexpand(void *w, int expand) {
    gtk_widget_set_hexpand(GTK_WIDGET(w), expand ? TRUE : FALSE);
}

static inline void deck_set_vexpand(void *w, int expand) {
    gtk_widget_set_vexpand(GTK_WIDGET(w), expand ? TRUE : FALSE);
}

static inline void deck_set_size(void *w, int width, int height) {
    gtk_widget_set_size_request(GTK_WIDGET(w), width, height);
}

static inline void deck_set_visible(void *w, int visible) {
    gtk_widget_set_visible(GTK_WIDGET(w), visible ? TRUE : FALSE);
}

static inline void deck_set_margins(void *w, int top, int bottom, int start, int end) {
    gtk_widget_set_margin_top(GTK_WIDGET(w), top);
    gtk_widget_set_margin_bottom(GTK_WIDGET(w), bottom);
    gtk_widget_set_margin_start(GTK_WIDGET(w), start);
    gtk_widget_set_margin_end(GTK_WIDGET(w), end);
}

static inline void deck_set_tooltip(void *w, const char *text) {
    gtk_widget_set_tooltip_text(GTK_WIDGET(w), text);
}

// MARK: - Keyboard

/// Attaches a key controller. The callback receives the keyval and modifier mask and
/// returns non-zero to stop propagation.
static inline void *deck_key_controller_new(void *w) {
    GtkEventController *c = gtk_event_controller_key_new();
    gtk_widget_add_controller(GTK_WIDGET(w), c);
    return c;
}

// MARK: - Dialogs

static inline void *deck_file_chooser_new(void *parent, const char *title) {
    return gtk_file_chooser_dialog_new(
        title, GTK_WINDOW(parent), GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
        "Cancel", GTK_RESPONSE_CANCEL, "Select", GTK_RESPONSE_ACCEPT, NULL);
}

static inline char *deck_file_chooser_path(void *dialog) {
    GFile *file = gtk_file_chooser_get_file(GTK_FILE_CHOOSER(dialog));
    if (!file) return NULL;
    char *path = g_file_get_path(file);
    g_object_unref(file);
    return path;
}

static inline void deck_dialog_destroy(void *dialog) {
    gtk_window_destroy(GTK_WINDOW(dialog));
}

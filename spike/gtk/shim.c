// shim.c — the GTK spike's bridge. Where the macOS shim was forced by
// Objective-C (headers, per-signature msgSend casts, ARC), GTK is
// already C, so the direct-call layer lives in main.emo and this file
// holds only the three things FFI cannot name:
//
//   1. the signal handler — g_signal_connect takes a function
//      pointer, which Emo cannot produce; the handler externs the
//      compiler-emitted main__on_click and forwards GObject's
//      user_data as the per-connection handle;
//   2. C `int` returns — a 32-bit return leaves the upper half of the
//      register undefined, so a foreign def declared Int64 would read
//      garbage; wrappers widen it. Definitions here use the int64_t
//      typedef, not long long: the two agree on macOS but Linux's
//      int64_t is long, and emo_defs.h's declarations catch the
//      mismatch at cc time (caught on the first container build).
//   3. the self-driving autotest.

#include <gtk/gtk.h>
#include "emo_c_runtime.h"

// The Emo callback, with the signature of
//   def on_click(tag Int64, title String, label Int64, count Int64) Int64
//
// This TU cannot include emo_defs.h: it declares the FFI view of the
// gtk_* symbols (Int64 handles), which conflicts with gtk.h's typed
// prototypes — the direct-call externs and the library's headers
// cannot share a translation unit. That costs the shim the
// compile-time signature check on this one extern; a defs variant
// without the foreign declarations would restore it.
extern int64_t main__on_click(int64_t tag, emo_str title, int64_t label,
                              int64_t count);

static int64_t g_count = 0;
static GMainLoop *g_loop = NULL;

static void on_clicked(GtkButton *button, gpointer user_data) {
  const char *title = gtk_button_get_label(button);
  g_count = main__on_click(0, emo_str_from_cstr(title),
                           (int64_t)(intptr_t)user_data, g_count);
}

// Connect "clicked" with the label handle as GObject's own
// per-connection context — the userdata slot the callback design
// anticipates. Returns the handler id.
int64_t gui_connect_clicked(int64_t widget, int64_t label_handle) {
  return (int64_t)g_signal_connect(G_OBJECT(widget), "clicked",
                                   G_CALLBACK(on_clicked),
                                   (gpointer)(intptr_t)label_handle);
}

// gtk_widget_get_width returns a C `int`: the shim widens it, because
// a foreign def declared Int64 would read an undefined upper half.
int64_t gui_widget_width(int64_t widget) {
  return gtk_widget_get_width(GTK_WIDGET(widget));
}

// ---- The self-driving autotest ------------------------------------------
// EMO_GUI_AUTOTEST=1: one synthetic click at 1.5 s, then report the
// label text and the real widget width and quit.

static GtkWidget *g_button = NULL;
static GtkWidget *g_label = NULL;

static gboolean fire_click(gpointer data) {
  g_signal_emit_by_name(G_OBJECT(data), "clicked");
  return G_SOURCE_REMOVE;
}

static gboolean report_and_quit(gpointer data) {
  printf("AUTOTEST count=%lld width=%lld label=\"%s\"\n", (long long)g_count,
         (long long)gui_widget_width((int64_t)(intptr_t)g_label),
         gtk_label_get_text(GTK_LABEL(data)));
  fflush(stdout);
  g_main_loop_quit(g_loop);
  return G_SOURCE_REMOVE;
}

void gui_autotest_arm(int64_t button, int64_t label, int64_t loop) {
  if (getenv("EMO_GUI_AUTOTEST") == NULL) {
    return;
  }
  g_button = GTK_WIDGET(button);
  g_label = GTK_WIDGET(label);
  g_loop = (GMainLoop *)loop;
  g_timeout_add(1500, fire_click, g_button);
  g_timeout_add(3000, report_and_quit, g_label);
}

// shim.c — the nine-verb GTK 4 vocabulary `ui_gtk.emo` declares.
//
// Every verb is one C symbol. GTK is already C, so this file is thinner
// than the AppKit shim: two things still need it — the "clicked" signal
// handler, because `g_signal_connect` takes a function pointer Emo cannot
// produce, and the sink's function-pointer pair, which the compiler
// expands from the `ui.Events` interface (`CHECK.md`). The layout, the
// tree walk, and the event loop are Emo side.
//
// Frames are placed from the window's top-left, the same origin the box
// model in `box.emo` measures from, and GtkFixed's own origin, so
// `ui_place` applies x and y unchanged.
//
//   EMO_GUI_AUTOTEST=1 ./app    clicks the script's tags in order,
//                               then quits — the corpus gate runs with
//                               no one at the keyboard

#include <gtk/gtk.h>

#include <stdlib.h>

// The compiler's own declarations for every foreign def above. A
// signature that drifts on either side now fails at cc time.
#include "emo_defs.h"

static GtkWidget *g_window = NULL;
static GtkWidget *g_canvas = NULL;
static GMainLoop *g_loop = NULL;

typedef void (*emo_sink_fn)(int64_t tag, void *userdata);
static emo_sink_fn g_sink = NULL;
static void *g_sink_data = NULL;

static int g_autotest_requested = 0;
static gboolean emo_autotest_tick(gpointer data);

// The tag table is the tree itself: a frame is rebuilt on every event,
// so a button is whichever canvas child carries the tag now.
static GtkWidget *emo_button_with_tag(int64_t tag) {
  for (GtkWidget *w = gtk_widget_get_first_child(g_canvas); w != NULL;
       w = gtk_widget_get_next_sibling(w)) {
    if (GTK_IS_BUTTON(w) &&
        (int64_t)(intptr_t)g_object_get_data(G_OBJECT(w), "emo-tag") == tag) {
      return w;
    }
  }
  return NULL;
}

// Closing the window ends the run, the way the AppKit shim terminates
// after its last window closes.
static gboolean emo_close_request(GtkWindow *window, gpointer data) {
  (void)window;
  (void)data;
  if (g_loop != NULL) {
    g_main_loop_quit(g_loop);
  }
  return FALSE;
}

// ---- The nine verbs -----------------------------------------------------

int64_t ui_window_make(const char *title, double w, double h) {
  gtk_init();
  g_window = gtk_window_new();
  gtk_window_set_title(GTK_WINDOW(g_window), title);
  gtk_window_set_default_size(GTK_WINDOW(g_window), (int)w, (int)h);
  g_canvas = gtk_fixed_new();
  gtk_window_set_child(GTK_WINDOW(g_window), g_canvas);
  g_signal_connect(G_OBJECT(g_window), "close-request",
                   G_CALLBACK(emo_close_request), NULL);
  return (int64_t)(intptr_t)g_window;
}

int64_t ui_label_make(const char *text) {
  GtkWidget *label = gtk_label_new(text);
  gtk_label_set_xalign(GTK_LABEL(label), 0.0);
  return (int64_t)(intptr_t)label;
}

int64_t ui_button_make(const char *text) {
  return (int64_t)(intptr_t)gtk_button_new_with_label(text);
}

void ui_place(int64_t child, double x, double y, double w, double h) {
  GtkWidget *widget = (GtkWidget *)(intptr_t)child;
  gtk_widget_set_size_request(widget, (int)w, (int)h);
  gtk_fixed_put(GTK_FIXED(g_canvas), widget, (int)x, (int)y);
}

// Retire every child of the canvas. The widgets are unparented, not just
// hidden — a full repaint happens per event, and leaking one widget tree
// per click would add up.
void ui_clear(void) {
  GtkWidget *child = gtk_widget_get_first_child(g_canvas);
  while (child != NULL) {
    GtkWidget *next = gtk_widget_get_next_sibling(child);
    gtk_fixed_remove(GTK_FIXED(g_canvas), child);
    child = next;
  }
}

static void emo_clicked(GtkButton *button, gpointer user_data) {
  (void)button;
  if (g_sink != NULL) {
    g_sink((int64_t)(intptr_t)user_data, g_sink_data);
  }
}

void ui_connect(int64_t child, int64_t tag) {
  GtkWidget *widget = (GtkWidget *)(intptr_t)child;
  g_object_set_data(G_OBJECT(widget), "emo-tag", (gpointer)(intptr_t)tag);
  g_signal_connect(G_OBJECT(widget), "clicked", G_CALLBACK(emo_clicked),
                   (gpointer)(intptr_t)tag);
}

int64_t ui_root(void) { return (int64_t)(intptr_t)g_canvas; }

// ---- The event loop -----------------------------------------------------

void ui_run(void (*events_cb)(int64_t __p0, void *userdata),
            void *events_data) {
  g_sink = events_cb;
  g_sink_data = events_data;
  g_loop = g_main_loop_new(NULL, FALSE);
  gtk_window_present(GTK_WINDOW(g_window));
  if (g_autotest_requested) {
    g_timeout_add(400, emo_autotest_tick, NULL);
  }
  g_main_loop_run(g_loop);
  g_main_loop_unref(g_loop);
  g_loop = NULL;
}

// ---- The self-driving script --------------------------------------------
//
// A tag list, clicked one per tick. The gate sets EMO_GUI_AUTOTEST and
// compares the application's stdout; a real run leaves the variable
// unset and `ui_autotest_arm` does nothing.

static int64_t g_script[64];
static int g_script_len = 0;
static int g_script_pos = 0;

static gboolean emo_autotest_tick(gpointer data) {
  (void)data;
  if (g_script_pos < g_script_len) {
    GtkWidget *button = emo_button_with_tag(g_script[g_script_pos++]);
    if (button != NULL) {
      g_signal_emit_by_name(G_OBJECT(button), "clicked");
    }
    return G_SOURCE_CONTINUE;
  }
  fflush(stdout);
  if (g_loop != NULL) {
    g_main_loop_quit(g_loop);
  }
  return G_SOURCE_REMOVE;
}

void ui_autotest_arm(const char *script) {
  if (getenv("EMO_GUI_AUTOTEST") == NULL) {
    return;
  }
  g_autotest_requested = 1;
  const char *p = script;
  while (*p != '\0' && g_script_len < 64) {
    char *end = NULL;
    long long v = strtoll(p, &end, 10);
    if (end == p) {
      break;
    }
    g_script[g_script_len++] = (int64_t)v;
    p = end;
    if (*p == ',') {
      p++;
    }
  }
}

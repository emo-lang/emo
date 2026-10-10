// shim_gtk.c — the GTK 4 painter for the neutral ui_* vocabulary.
// app.emo computes every position; this file only creates widgets and
// places them. It can include emo_defs.h safely: the neutral
// vocabulary means the defs header declares no GTK symbols, so the
// TU-separation conflict from the direct-call spike never arises.

#include <gtk/gtk.h>
#include "emo_defs.h"

static GtkWidget *g_window = NULL;
static GtkWidget *g_canvas = NULL;
static GMainLoop *g_loop = NULL;
static int64_t g_model = 0;
static GtkWidget *g_buttons[8];
static GtkWidget *g_label = NULL;

static void on_clicked(GtkButton *button, gpointer user_data) {
  (void)button;
  g_model = app__on_event((int64_t)(intptr_t)user_data, g_model);
}

int64_t ui_window_make(const char *title, double w, double h) {
  gtk_init();
  g_window = gtk_window_new();
  gtk_window_set_title(GTK_WINDOW(g_window), title);
  gtk_window_set_default_size(GTK_WINDOW(g_window), (int)w, (int)h);
  g_canvas = gtk_fixed_new();
  gtk_window_set_child(GTK_WINDOW(g_window), g_canvas);
  return (int64_t)g_window;
}

int64_t ui_label_make(const char *text) {
  g_label = gtk_label_new(text);
  gtk_label_set_xalign(GTK_LABEL(g_label), 0.0);
  return (int64_t)g_label;
}

int64_t ui_button_make(const char *text) {
  return (int64_t)gtk_button_new_with_label(text);
}

void ui_place(int64_t child, double x, double y, double w, double h) {
  gtk_widget_set_size_request(GTK_WIDGET(child), (int)w, (int)h);
  gtk_fixed_put(GTK_FIXED(g_canvas), GTK_WIDGET(child), (int)x, (int)y);
}

// Retire every child of the canvas. The widgets are destroyed, not
// just hidden — a full repaint happens per event, and leaking one
// widget tree per click would add up.
void ui_clear(void) {
  GtkWidget *c = gtk_widget_get_first_child(g_canvas);
  while (c != NULL) {
    GtkWidget *next = gtk_widget_get_next_sibling(c);
    gtk_fixed_remove(GTK_FIXED(g_canvas), c);
    c = next;
  }
}

void ui_connect(int64_t child, int64_t tag) {
  if (tag >= 0 && tag < 8) {
    g_buttons[tag] = GTK_WIDGET(child);
  }
  g_signal_connect(G_OBJECT(child), "clicked", G_CALLBACK(on_clicked),
                   (gpointer)(intptr_t)tag);
}

int64_t ui_root(void) {
  return (int64_t)g_canvas;
}

void ui_run(void) {
  g_loop = g_main_loop_new(NULL, FALSE);
  gtk_window_present(GTK_WINDOW(g_window));
  g_main_loop_run(g_loop);
}

// ---- The self-driving autotest: +1, -1, +1, then report and quit ----

static gboolean fire_click(gpointer data) {
  int64_t tag = (int64_t)(intptr_t)data;
  if (g_buttons[tag] != NULL) {
    g_signal_emit_by_name(G_OBJECT(g_buttons[tag]), "clicked");
  }
  return G_SOURCE_REMOVE;
}

static gboolean report_and_quit(gpointer data) {
  (void)data;
  printf("AUTOTEST model=%lld label=\"%s\"\n", (long long)g_model,
         gtk_label_get_text(GTK_LABEL(g_label)));
  fflush(stdout);
  g_main_loop_quit(g_loop);
  return G_SOURCE_REMOVE;
}

void ui_autotest_arm(void) {
  if (getenv("EMO_GUI_AUTOTEST") == NULL) {
    return;
  }
  g_timeout_add(1500, fire_click, (gpointer)(intptr_t)1);
  g_timeout_add(2200, fire_click, (gpointer)(intptr_t)2);
  g_timeout_add(2900, fire_click, (gpointer)(intptr_t)1);
  g_timeout_add(3600, report_and_quit, NULL);
}

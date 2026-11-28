// shim.c — the GTK 4 vocabulary `ui_gtk.emo` declares.
//
// Every verb is one C symbol. GTK is already C, so this file is thinner
// than the AppKit shim: three things still need it — the "clicked" and
// "changed" signal handlers, because `g_signal_connect` takes a function
// pointer Emo cannot produce, and the sink's function-pointer pair,
// which the compiler expands from the `ui.Events` interface (`CHECK.md`).
// The layout, the tree walk, and the event loop are Emo side.
//
// Frames are placed from the window's top-left, the same origin the box
// model in `box.emo` measures from, and GtkFixed's own origin, so
// `ui_place` applies x and y unchanged.
//
// A frame keeps the widgets the diff continues — `ui_place` moves a
// widget already on the canvas — and `ui_set_text` and `ui_remove` are
// the two verbs a kept frame needs beside it. A kept field's text is
// written back only where it differs from the model's, and the write is
// flagged so the "changed" signal it fires is not delivered as typing.
//
//   EMO_GUI_AUTOTEST=1 ./app    runs the script's steps in order, a
//                               tag clicked and `tag=text` typed into
//                               the field carrying the tag, then quits
//                               — the corpus gate runs with no one at
//                               the keyboard

#include <gtk/gtk.h>

#include <stdlib.h>
#include <string.h>

// The compiler's own declarations for every foreign def above. A
// signature that drifts on either side now fails at cc time.
#include "emo_defs.h"

static GtkWidget *g_window = NULL;
static GtkWidget *g_canvas = NULL;
static GMainLoop *g_loop = NULL;

// The widgets this process made. A frame keeps the widgets the diff
// continues, and the number is how a gate sees it: EMO_GUI_COUNT names a
// file the autotest writes it to as the run leaves — never one of the
// program's own streams, whose bytes are the program's.
static int g_made = 0;

typedef void (*emo_sink_fn)(int64_t tag, const char *text, int64_t key,
                            void *userdata);
static emo_sink_fn g_sink = NULL;
static void *g_sink_data = NULL;

// Set while `ui_set_text` writes a field's text programmatically, so
// the "changed" signal the write fires is not delivered as typing.
static int g_setting_text = 0;

static int g_autotest_requested = 0;
static gboolean emo_autotest_tick(gpointer data);
static void emo_entry_changed(GtkEditable *editable, gpointer user_data);
static gboolean emo_entry_key(GtkEventControllerKey *controller,
                              guint keyval, guint keycode,
                              GdkModifierType state, gpointer user_data);

// The tag table is the tree itself: a control carries whatever tag the
// last frame gave it, so a button is whichever canvas button carries
// the tag now. Only the widgets `ui_connect` tags carry the datum — a
// label never does, and an unset datum reads as 0, so a click for tag 0
// must not resolve to one.
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

// The field carrying a tag, for the script's typed steps: whichever
// canvas entry carries it now.
static GtkWidget *emo_entry_with_tag(int64_t tag) {
  for (GtkWidget *w = gtk_widget_get_first_child(g_canvas); w != NULL;
       w = gtk_widget_get_next_sibling(w)) {
    if (GTK_IS_ENTRY(w) &&
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

// ---- The ten verbs -----------------------------------------------------

int64_t ui_window_make(const char *title, double w, double h) {
  // The count's file is emptied with the window, so a run that never
  // reaches its end leaves none of a run before's.
  const char *count_path = getenv("EMO_GUI_COUNT");
  if (count_path != NULL) {
    FILE *count = fopen(count_path, "w");
    if (count != NULL) {
      fclose(count);
    }
  }
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
  g_made++;
  GtkWidget *label = gtk_label_new(text);
  gtk_label_set_xalign(GTK_LABEL(label), 0.0);
  return (int64_t)(intptr_t)label;
}

int64_t ui_button_make(const char *text) {
  g_made++;
  return (int64_t)(intptr_t)gtk_button_new_with_label(text);
}

// An editable field. The initial text is set before `ui_run` stores the
// sink, so the "changed" signal the write fires delivers to no one; a
// later write is the flagged one in `ui_set_text`.
int64_t ui_entry_make(const char *text) {
  g_made++;
  GtkWidget *entry = gtk_entry_new();
  gtk_editable_set_text(GTK_EDITABLE(entry), text);
  g_signal_connect(G_OBJECT(entry), "changed",
                   G_CALLBACK(emo_entry_changed), NULL);
  GtkEventControllerKey *keys = gtk_event_controller_key_new();
  g_signal_connect(G_OBJECT(keys), "key-pressed",
                   G_CALLBACK(emo_entry_key), NULL);
  gtk_widget_add_controller(GTK_WIDGET(entry), GTK_EVENT_CONTROLLER(keys));
  return (int64_t)(intptr_t)entry;
}

// Place a widget at a frame: one already on the canvas moves, and a new
// one is put there.
void ui_place(int64_t child, double x, double y, double w, double h) {
  GtkWidget *widget = (GtkWidget *)(intptr_t)child;
  gtk_widget_set_size_request(widget, (int)w, (int)h);
  if (gtk_widget_get_parent(widget) == g_canvas) {
    gtk_fixed_move(GTK_FIXED(g_canvas), widget, (int)x, (int)y);
  } else {
    gtk_fixed_put(GTK_FIXED(g_canvas), widget, (int)x, (int)y);
  }
}

// A kept widget shows the frame's text: a button's label, a label's
// own, and a field's only where it differs from the model's — the
// keystrokes typed since the last frame stay. The write is flagged, so
// the "changed" signal it fires is not delivered as typing.
void ui_set_text(int64_t child, const char *text) {
  GtkWidget *widget = (GtkWidget *)(intptr_t)child;
  if (GTK_IS_BUTTON(widget)) {
    gtk_button_set_label(GTK_BUTTON(widget), text);
  } else if (GTK_IS_ENTRY(widget)) {
    const char *current = gtk_editable_get_text(GTK_EDITABLE(widget));
    if (g_strcmp0(current, text) == 0) {
      return;
    }
    g_setting_text = 1;
    gtk_editable_set_text(GTK_EDITABLE(widget), text);
    g_setting_text = 0;
  } else {
    gtk_label_set_text(GTK_LABEL(widget), text);
  }
}

// A widget no frame keeps leaves the canvas, unparented rather than
// hidden, and nothing else is touched: that is what lets the others keep
// their state.
void ui_remove(int64_t child) {
  gtk_fixed_remove(GTK_FIXED(g_canvas), (GtkWidget *)(intptr_t)child);
}

static void emo_clicked(GtkButton *button, gpointer user_data) {
  (void)user_data;
  if (g_sink != NULL) {
    // The tag is read as the click lands, so a kept button can take a
    // new one between frames. A click carries no text and no key.
    g_sink(
        (int64_t)(intptr_t)g_object_get_data(G_OBJECT(button), "emo-tag"), "",
        0, g_sink_data);
  }
}

// A field's typed text: the tag is whatever the frame gave the entry
// last, and the text is the entry's own. A programmatic write arrives
// flagged and delivers to no one.
static void emo_entry_changed(GtkEditable *editable, gpointer user_data) {
  (void)user_data;
  if (g_sink != NULL && !g_setting_text) {
    g_sink(
        (int64_t)(intptr_t)g_object_get_data(G_OBJECT(GTK_WIDGET(editable)),
                                             "emo-tag"),
        gtk_editable_get_text(editable), 0, g_sink_data);
  }
}

// The keys a field hands the application: Enter and Escape, the two the
// toolkit does not consume as editing. Every other key propagates — the
// controller returns FALSE and the entry edits itself, arriving as the
// "changed" signal's text instead.
static gboolean emo_entry_key(GtkEventControllerKey *controller,
                              guint keyval, guint keycode,
                              GdkModifierType state, gpointer user_data) {
  (void)controller;
  (void)keycode;
  (void)state;
  (void)user_data;
  GtkWidget *entry = gtk_event_controller_get_widget(
      GTK_EVENT_CONTROLLER(controller));
  int64_t key = 0;
  if (keyval == GDK_KEY_Return || keyval == GDK_KEY_KP_Enter) {
    key = 10;
  } else if (keyval == GDK_KEY_Escape) {
    key = 27;
  } else {
    return FALSE;
  }
  if (g_sink != NULL) {
    g_sink(
        (int64_t)(intptr_t)g_object_get_data(G_OBJECT(entry), "emo-tag"), "",
        key, g_sink_data);
  }
  return TRUE;
}

// A control's tag is whatever the frame gave it last. A button's click
// handler is connected once: the verb runs again for a kept button
// whose event changed, and a second handler would deliver one click
// twice. A field's "changed" handler is connected at `ui_entry_make`.
void ui_connect(int64_t child, int64_t tag) {
  GtkWidget *widget = (GtkWidget *)(intptr_t)child;
  g_object_set_data(G_OBJECT(widget), "emo-tag", (gpointer)(intptr_t)tag);
  if (GTK_IS_BUTTON(widget) &&
      g_object_get_data(G_OBJECT(widget), "emo-connected") == NULL) {
    g_object_set_data(G_OBJECT(widget), "emo-connected", GINT_TO_POINTER(1));
    g_signal_connect(G_OBJECT(widget), "clicked", G_CALLBACK(emo_clicked),
                     NULL);
  }
}

int64_t ui_root(void) { return (int64_t)(intptr_t)g_canvas; }

// ---- The event loop -----------------------------------------------------

void ui_run(void (*events_cb)(int64_t __p0, const char *__p1, int64_t __p2,
                              void *userdata),
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
// Steps run one per tick: a bare tag is a click on the control carrying
// it, `tag=text` types into the field carrying the tag — the text goes
// in through `gtk_editable_set_text` unflagged, so the "changed" signal
// delivers it exactly as a keystroke would — and `tag^key` presses a
// key on the field carrying the tag, the same delivery the key
// controller makes. The gate sets
// EMO_GUI_AUTOTEST and compares the application's stdout; a real run
// leaves the variable unset and `ui_autotest_arm` does nothing.

typedef struct {
  int64_t tag;
  char *text;
  int64_t key;
} emo_step;

static emo_step g_script[64];
static int g_script_len = 0;
static int g_script_pos = 0;

static gboolean emo_autotest_tick(gpointer data) {
  (void)data;
  if (g_script_pos < g_script_len) {
    emo_step step = g_script[g_script_pos++];
    if (step.text != NULL) {
      GtkWidget *entry = emo_entry_with_tag(step.tag);
      if (entry != NULL) {
        gtk_editable_set_text(GTK_EDITABLE(entry), step.text);
      }
    } else if (step.key != 0) {
      // The same delivery the key controller makes for a pressed key:
      // the tag the frame gave the field, the key as the number.
      GtkWidget *entry = emo_entry_with_tag(step.tag);
      if (entry != NULL && g_sink != NULL) {
        g_sink((int64_t)(intptr_t)g_object_get_data(G_OBJECT(entry),
                                                    "emo-tag"),
               "", step.key, g_sink_data);
      }
    } else {
      GtkWidget *button = emo_button_with_tag(step.tag);
      if (button != NULL) {
        g_signal_emit_by_name(G_OBJECT(button), "clicked");
      }
    }
    return G_SOURCE_CONTINUE;
  }
  const char *count_path = getenv("EMO_GUI_COUNT");
  if (count_path != NULL) {
    FILE *count = fopen(count_path, "w");
    if (count != NULL) {
      fprintf(count, "ui: made %d widgets\n", g_made);
      fclose(count);
    }
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
    g_script[g_script_len].tag = (int64_t)v;
    g_script[g_script_len].text = NULL;
    g_script[g_script_len].key = 0;
    p = end;
    if (*p == '^') {
      p++;
      char *key_end = NULL;
      long long k = strtoll(p, &key_end, 10);
      if (key_end == p) {
        break;
      }
      g_script[g_script_len].key = (int64_t)k;
      p = key_end;
    } else if (*p == '=') {
      p++;
      const char *start = p;
      while (*p != '\0' && *p != ',') {
        p++;
      }
      size_t n = (size_t)(p - start);
      g_script[g_script_len].text = calloc(n + 1, 1);
      memcpy(g_script[g_script_len].text, start, n);
    }
    g_script_len++;
    if (*p == ',') {
      p++;
    }
  }
}

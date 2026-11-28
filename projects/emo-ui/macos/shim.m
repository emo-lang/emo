// shim.m — the AppKit vocabulary `ui_macos.emo` declares.
//
// Every verb is one C symbol. Emo cannot name an Objective-C selector,
// a struct parameter, or a method chain (E4200: Foreign, Int64,
// Float64, Bool, String, Void), so this file is the whole of what the
// application cannot write itself; the layout, the tree walk, and the
// event loop are Emo side.
//
// The sink arrives through the callback contract: `ui_run` takes the
// `ui.Events` interface as a foreign parameter, which the compiler
// expands to a function pointer plus its userdata (`CHECK.md`). A click
// calls the pair with the button's tag and an empty text; a field's
// edited text calls it with the tag and what was typed.
//
// Frames are placed from the window's top-left, the same origin the box
// model in `box.emo` measures from; AppKit's content view is
// bottom-left, so `ui_place` flips y.
//
// A frame keeps the widgets the diff continues — `ui_place` moves a view
// as readily as it places a new one — and `ui_set_text` and `ui_remove`
// are the two verbs a kept frame needs beside it. A kept field's text is
// written back only where it differs from the model's; a programmatic
// `stringValue` write fires no `controlTextDidChange`, so the write can
// never read as typing.
//
//   EMO_GUI_AUTOTEST=1 ./app    runs the script's steps in order, a
//                               tag clicked and `tag=text` typed into
//                               the field carrying the tag, then
//                               terminates — the corpus gate runs with
//                               no one at the keyboard

#import <AppKit/AppKit.h>

#include <stdlib.h>
#include <string.h>

// The compiler's own declarations for every foreign def above. A
// signature that drifts on either side now fails at cc time.
#include "emo_defs.h"

// Emo handles are pointer-sized Int64s; ARC requires the __bridge hop
// through void * in both directions.
static inline id handle_to_id(int64_t h) {
  return (__bridge id)(void *)(uintptr_t)h;
}
static inline int64_t id_to_handle(id o) {
  return (int64_t)(uintptr_t)(__bridge void *)o;
}

static NSWindow *g_window = nil;
static double g_height = 0.0;

// The widgets this process made. A frame keeps the widgets the diff
// continues, and the number is how a gate sees it: EMO_GUI_COUNT names a
// file the autotest writes it to as the run leaves — never one of the
// program's own streams, whose bytes are the program's.
static int g_made = 0;

typedef void (*emo_sink_fn)(int64_t tag, const char *text, void *userdata);
static emo_sink_fn g_sink = NULL;
static void *g_sink_data = NULL;

// Every button is wired to this one action, and every editable field
// takes this one object as its delegate: the tag is the whole message,
// so no per-control selector or target is needed. The object exists
// before `ui_run` because a frame's controls are made during `mount`,
// which is painted before the run loop starts.
@interface EmoSink : NSObject <NSApplicationDelegate, NSTextFieldDelegate>
@end
static EmoSink *g_delegate = nil;

// ---- The ten verbs -----------------------------------------------------

int64_t ui_window_make(const char *title_utf8, double w, double h) {
  // The count's file is emptied with the window, so a run that never
  // reaches its end leaves none of a run before's.
  const char *count_path = getenv("EMO_GUI_COUNT");
  if (count_path != NULL) {
    FILE *count = fopen(count_path, "w");
    if (count != NULL) {
      fclose(count);
    }
  }
  @autoreleasepool {
    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, w, h)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    win.title = [NSString stringWithUTF8String:title_utf8];
    g_window = win;
    g_height = h;
    return id_to_handle(win);
  }
}

int64_t ui_label_make(const char *text_utf8) {
  g_made++;
  @autoreleasepool {
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.stringValue = [NSString stringWithUTF8String:text_utf8];
    label.editable = NO;
    label.selectable = NO;
    label.bordered = NO;
    label.drawsBackground = NO;
    label.font = [NSFont systemFontOfSize:13.0];
    [g_window.contentView addSubview:label];
    return id_to_handle(label);
  }
}

int64_t ui_button_make(const char *text_utf8) {
  g_made++;
  @autoreleasepool {
    NSButton *btn = [[NSButton alloc] initWithFrame:NSZeroRect];
    btn.title = [NSString stringWithUTF8String:text_utf8];
    btn.bezelStyle = NSBezelStyleRounded;
    [g_window.contentView addSubview:btn];
    return id_to_handle(btn);
  }
}

// An editable field. The initial text is set before `ui_run` stores the
// sink, so even if a programmatic write did deliver, it would reach no
// one; from then on `ui_set_text`'s compare-and-skip keeps the writes
// honest.
int64_t ui_entry_make(const char *text_utf8) {
  g_made++;
  @autoreleasepool {
    NSTextField *entry = [[NSTextField alloc] initWithFrame:NSZeroRect];
    entry.stringValue = [NSString stringWithUTF8String:text_utf8];
    entry.editable = YES;
    entry.selectable = YES;
    entry.bordered = YES;
    entry.font = [NSFont systemFontOfSize:13.0];
    if (g_delegate == nil) {
      g_delegate = [EmoSink new];
    }
    entry.delegate = g_delegate;
    [g_window.contentView addSubview:entry];
    return id_to_handle(entry);
  }
}

void ui_place(int64_t child, double x, double y, double w, double h) {
  @autoreleasepool {
    NSView *view = handle_to_id(child);
    view.frame = NSMakeRect(x, g_height - y - h, w, h);
  }
}

// A kept widget shows the frame's text: a button's title, a label's or
// a field's string — the field's only where it differs from the
// model's, so the keystrokes typed since the last frame stay.
void ui_set_text(int64_t child, const char *text_utf8) {
  @autoreleasepool {
    id view = handle_to_id(child);
    NSString *text = [NSString stringWithUTF8String:text_utf8];
    if ([view isKindOfClass:[NSButton class]]) {
      ((NSButton *)view).title = text;
    } else {
      NSTextField *field = (NSTextField *)view;
      if ([field.stringValue isEqualToString:text]) {
        return;
      }
      field.stringValue = text;
    }
  }
}

// A widget no frame keeps leaves the content view, and nothing else is
// touched: that is what lets the others keep their state.
void ui_remove(int64_t child) {
  @autoreleasepool {
    [handle_to_id(child) removeFromSuperview];
  }
}

// A control's tag is whatever the frame gave it last: the verb runs
// again for a kept control whose event changed, and the target and
// action are the same ones every time. A field takes only the tag — its
// delegate was set at `ui_entry_make`, and a target here would make
// Return deliver a click.
void ui_connect(int64_t child, int64_t tag) {
  @autoreleasepool {
    id view = handle_to_id(child);
    if (g_delegate == nil) {
      g_delegate = [EmoSink new];
    }
    if ([view isKindOfClass:[NSButton class]]) {
      NSButton *btn = (NSButton *)view;
      btn.tag = tag;
      btn.target = g_delegate;
      btn.action = @selector(clicked:);
    } else if ([view isKindOfClass:[NSTextField class]]) {
      ((NSTextField *)view).tag = tag;
    }
  }
}

int64_t ui_root(void) { return id_to_handle(g_window.contentView); }

// ---- The event loop -----------------------------------------------------

@implementation EmoSink

- (void)clicked:(NSButton *)sender {
  if (g_sink != NULL) {
    // The tag is read as the click lands, so a kept button can take a
    // new one between frames. A click carries no text.
    g_sink((int64_t)sender.tag, "", g_sink_data);
  }
}

// A field's typed text: the tag is whatever the frame gave the field
// last, and the text is the field's own. A programmatic `stringValue`
// write fires no `controlTextDidChange`, so the delegate method sees
// only what a person typed.
- (void)controlTextDidChange:(NSNotification *)obj {
  if (g_sink != NULL) {
    NSTextField *field = (NSTextField *)obj.object;
    g_sink((int64_t)field.tag, field.stringValue.UTF8String, g_sink_data);
  }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {
  return YES;
}

@end

// ---- The self-driving script --------------------------------------------
//
// Steps run one per tick: a bare tag is a click on the control carrying
// it, and `tag=text` types into the field carrying the tag — the text
// goes into the field and the delivery is made by hand, because a
// programmatic write fires no `controlTextDidChange` and the simulation
// stands in for a person. The gate sets EMO_GUI_AUTOTEST and compares
// the application's stdout; a real run leaves the variable unset and
// `ui_autotest_arm` does nothing.

typedef struct {
  int64_t tag;
  char *text;
} emo_step;

static emo_step g_script[64];
static int g_script_len = 0;
static int g_script_pos = 0;
static int g_timer_requested = 0;
static NSTimer *g_timer = nil;

void ui_autotest_arm(const char *script) {
  if (getenv("EMO_GUI_AUTOTEST") == NULL) {
    return;
  }
  g_timer_requested = 1;
  const char *p = script;
  while (*p != '\0' && g_script_len < 64) {
    char *end = NULL;
    long v = strtol(p, &end, 10);
    if (end == p) {
      break;
    }
    g_script[g_script_len].tag = (int64_t)v;
    g_script[g_script_len].text = NULL;
    p = end;
    if (*p == '=') {
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

// The tag table is the tree itself: the button for a tag is whichever
// subview button carries it now. Only the controls `ui_connect` tags
// carry a set tag — a label's is the NSControl default 0 — so a click
// for tag 0 must not resolve to one.
static NSButton *emo_button_with_tag(int64_t tag) {
  for (NSView *view in g_window.contentView.subviews) {
    if ([view isKindOfClass:[NSButton class]] && ((NSButton *)view).tag == tag) {
      return (NSButton *)view;
    }
  }
  return nil;
}

// The field carrying a tag, for the script's typed steps: whichever
// editable subview field carries it now — editable is exactly what
// `ui_entry_make` made, and a label (an NSTextField of its own) never
// carries a set tag.
static NSTextField *emo_field_with_tag(int64_t tag) {
  for (NSView *view in g_window.contentView.subviews) {
    if ([view isKindOfClass:[NSTextField class]] &&
        ((NSTextField *)view).editable && ((NSTextField *)view).tag == tag) {
      return (NSTextField *)view;
    }
  }
  return nil;
}

@interface EmoAutotest : NSObject
@end

@implementation EmoAutotest

- (void)tick:(NSTimer *)timer {
  if (g_script_pos < g_script_len) {
    emo_step step = g_script[g_script_pos++];
    if (step.text != NULL) {
      NSTextField *field = emo_field_with_tag(step.tag);
      if (field != nil) {
        field.stringValue = [NSString stringWithUTF8String:step.text];
        if (g_sink != NULL) {
          g_sink((int64_t)field.tag, step.text, g_sink_data);
        }
      }
    } else {
      NSButton *btn = emo_button_with_tag(step.tag);
      if (btn != nil) {
        [btn performClick:nil];
      }
    }
    return;
  }
  [timer invalidate];
  g_timer = nil;
  const char *count_path = getenv("EMO_GUI_COUNT");
  if (count_path != NULL) {
    FILE *count = fopen(count_path, "w");
    if (count != NULL) {
      fprintf(count, "ui: made %d widgets\n", g_made);
      fclose(count);
    }
  }
  fflush(stdout);
  [NSApp terminate:nil];
}

@end

static EmoAutotest *g_autotest = nil;

static void emo_autotest_schedule(void) {
  g_autotest = [EmoAutotest new];
  g_timer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                             target:g_autotest
                                           selector:@selector(tick:)
                                           userInfo:nil
                                            repeats:YES];
}

void ui_run(void (*events_cb)(int64_t __p0, const char *__p1, void *userdata),
            void *events_data) {
  @autoreleasepool {
    g_sink = events_cb;
    g_sink_data = events_data;
    if (g_delegate == nil) {
      g_delegate = [EmoSink new];
    }
    NSApplication *app = [NSApplication sharedApplication];
    app.delegate = g_delegate;
    if (g_timer_requested) {
      emo_autotest_schedule();
    }
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [g_window makeKeyAndOrderFront:nil];
    [app activateIgnoringOtherApps:YES];
    [app run];
  }
}

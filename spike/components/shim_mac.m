// shim_mac.m — the AppKit painter for the neutral ui_* vocabulary.
// Same contract as shim_gtk.c: app.emo computes every position, this
// file only creates widgets and places them. AppKit measures from the
// bottom-left, so ui_place flips the Emo-computed top-left frame.

#import <AppKit/AppKit.h>
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
static int64_t g_model = 0;
static NSButton *g_buttons[8];
static NSTextField *g_label = nil;

@interface SpikeDelegate : NSObject <NSApplicationDelegate>
@end

@implementation SpikeDelegate

- (void)click:(id)sender {
  g_model = app__on_event((int64_t)[sender tag], g_model);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {
  return YES;
}

@end

static SpikeDelegate *delegate(void) {
  static SpikeDelegate *d = nil;
  if (d == nil) {
    d = [SpikeDelegate new];
  }
  return d;
}

int64_t ui_window_make(const char *title, double w, double h) {
  NSWindow *win = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, w, h)
                styleMask:NSWindowStyleMaskTitled |
                          NSWindowStyleMaskClosable |
                          NSWindowStyleMaskMiniaturizable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  [win setTitle:[NSString stringWithUTF8String:title]];
  g_window = win;
  return id_to_handle(win);
}

int64_t ui_label_make(const char *text_utf8) {
  NSTextField *label =
      [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 100, 24)];
  label.editable = NO;
  label.bordered = NO;
  label.bezeled = NO;
  label.drawsBackground = NO;
  label.stringValue = [NSString stringWithUTF8String:text_utf8];
  g_label = label;
  return id_to_handle(label);
}

int64_t ui_button_make(const char *text_utf8) {
  NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 100, 32)];
  btn.title = [NSString stringWithUTF8String:text_utf8];
  btn.bezelStyle = NSBezelStyleRounded;
  return id_to_handle(btn);
}

void ui_place(int64_t child, double x, double y, double w, double h) {
  double ch = [g_window contentView].bounds.size.height;
  NSView *view = (NSView *)handle_to_id(child);
  view.frame = NSMakeRect(x, ch - y - h, w, h);
  [[g_window contentView] addSubview:view];
}

void ui_clear(void) {
  [[[g_window contentView] subviews]
      makeObjectsPerformSelector:@selector(removeFromSuperview)];
}

void ui_connect(int64_t child, int64_t tag) {
  if (tag >= 0 && tag < 8) {
    g_buttons[tag] = (NSButton *)handle_to_id(child);
  }
  NSButton *btn = (NSButton *)handle_to_id(child);
  btn.target = delegate();
  btn.action = @selector(click:);
  btn.tag = tag;
}

int64_t ui_root(void) {
  return id_to_handle([g_window contentView]);
}

void ui_run(void) {
  NSApplication *app = [NSApplication sharedApplication];
  app.delegate = delegate();
  [app setActivationPolicy:NSApplicationActivationPolicyRegular];
  [app activateIgnoringOtherApps:YES];
  if (getenv("EMO_GUI_AUTOTEST") != NULL) {
    // park the window at a known screen position so a region
    // screenshot can frame it
    [g_window setFrameTopLeftPoint:NSMakePoint(
        100.0, [NSScreen mainScreen].frame.size.height - 100.0)];
  }
  [g_window makeKeyAndOrderFront:nil];
  [app run];
}

// ---- The self-driving autotest: +1, -1, +1, then report and quit ----

static void fire_click(int64_t tag) {
  if (g_buttons[tag] != nil) {
    [g_buttons[tag] performClick:nil];
  }
}

void ui_autotest_arm(void) {
  if (getenv("EMO_GUI_AUTOTEST") == NULL) {
    return;
  }
  __block int64_t step = 0;
  [NSTimer scheduledTimerWithTimeInterval:1.5
                                  repeats:YES
                                    block:^(NSTimer *timer) {
    const int64_t tags[3] = {1, 2, 1};
    step = step + 1;
    if (step <= 3) {
      fire_click(tags[step - 1]);
      return;
    }
    printf("AUTOTEST model=%lld label=\"%s\"\n", (long long)g_model,
           g_label.stringValue.UTF8String);
    fflush(stdout);
    [NSApp terminate:nil];
  }];
}

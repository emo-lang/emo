// shim.m — the macOS vocabulary for the Emo GUI spike.
//
// Emo's `foreign def` names C symbols whose parameters are Int64 /
// Float64 / Bool / String, with Int64 or Void as the return (E4200),
// and a C symbol cannot be re-declared under two signatures, so
// objc_msgSend cannot be cast per call site from Emo. This file is
// therefore the whole bridge: a fixed set of generic send helpers
// plus three composite creators, each one an Emo `foreign def`.
// AppKit headers are Objective-C, so the shim compiles as .m — same
// clang, no extra tooling.
//
// Callbacks re-enter Emo through the exported symbol of the entry
// file's top-level def `on_click`: the C backend qualifies entry-module
// defs with the module name, so the symbol is `main__on_click`.
// State travels through the
// callback's signature — the C target gives defs no reachable global
// storage, so there is nowhere else for it to live.
//
//   ./build.sh                          two-pass build: pass 1 fails
//                                       at link on purpose, it writes
//                                       emo_defs.h — the compiler's
//                                       own declarations, which this
//                                       file compiles against
//   ./gui-spike                         the demo: click the button
//   EMO_GUI_AUTOTEST=1 ./gui-spike      self-driving: one synthetic
//                                       click, prints the label,
//                                       terminates

#import <AppKit/AppKit.h>
#import <objc/message.h>

// The compiler's declarations for this program: the main__on_click
// callback and every gui_* symbol below. A signature that drifts on
// either side now breaks at cc time instead of silently at run time.
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
static NSButton *g_button = nil;
static NSTextField *g_label = nil;
static int64_t g_count = 0;

@interface SpikeDelegate : NSObject <NSApplicationDelegate>
@end

@implementation SpikeDelegate

- (void)click:(id)sender {
  emo_str title = emo_str_from_cstr([[sender title] UTF8String]);
  g_count = main__on_click((int64_t)[sender tag], title, g_count);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {
  return YES;
}

@end

// ---- Composite creators -------------------------------------------------
// The AppKit ceremony that cannot be named from Emo: struct
// parameters, method chains, the target wiring.

int64_t gui_window_make(const char *title_utf8, double w, double h) {
  @autoreleasepool {
    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, w, h)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [win setTitle:[NSString stringWithUTF8String:title_utf8]];
    g_window = win;
    return id_to_handle(win);
  }
}

int64_t gui_button_make(double x, double y, double w, double h,
                       const char *title_utf8, int64_t tag) {
  @autoreleasepool {
    static SpikeDelegate *delegate = nil;
    if (delegate == nil) {
      delegate = [SpikeDelegate new];
    }
    NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    btn.title = [NSString stringWithUTF8String:title_utf8];
    btn.bezelStyle = NSBezelStyleRounded;
    btn.tag = tag;
    btn.target = delegate;
    btn.action = @selector(click:);
    [[g_window contentView] addSubview:btn];
    g_button = btn;
    return id_to_handle(btn);
  }
}

int64_t gui_label_make(double x, double y, double w, double h) {
  @autoreleasepool {
    NSTextField *label =
        [[NSTextField alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    label.editable = NO;
    label.bordered = NO;
    label.alignment = NSTextAlignmentLeft;
    [[g_window contentView] addSubview:label];
    g_label = label;
    return id_to_handle(label);
  }
}

// Emo cannot keep handles across callbacks (defs have no reachable
// global storage), so the shim holds what it created and hands them
// back on demand.
int64_t gui_label_handle(void) { return id_to_handle(g_label); }

// ---- The generic send vocabulary ----------------------------------------
// objc_msgSend cast per shape, selector named by a string. Any AppKit
// call that fits one of these five shapes needs no shim code at all;
// the fire-and-forget ones return Void, the way a foreign def does.

// Messages returning an object: alloc, contentView, ...
int64_t gui_obj(int64_t recv, const char *sel_utf8) {
  @autoreleasepool {
    id result =
        ((id (*)(id, SEL))objc_msgSend)(handle_to_id(recv), sel_registerName(sel_utf8));
    return id_to_handle(result);
  }
}

// No-argument void messages: center, orderFrontRegardless, ...
void gui_void(int64_t recv, const char *sel_utf8) {
  @autoreleasepool {
    ((void (*)(id, SEL))objc_msgSend)(handle_to_id(recv), sel_registerName(sel_utf8));
  }
}

// One scalar argument: setTag:, setHidden:, ...
void gui_void_i64(int64_t recv, const char *sel_utf8, int64_t arg) {
  @autoreleasepool {
    ((void (*)(id, SEL, int64_t))objc_msgSend)(handle_to_id(recv),
                                               sel_registerName(sel_utf8), arg);
  }
}

// One UTF-8 string argument, wrapped into an NSString: setTitle:,
// setStringValue:, ...
void gui_set_str(int64_t recv, const char *sel_utf8, const char *utf8) {
  @autoreleasepool {
    NSString *s = [NSString stringWithUTF8String:utf8];
    ((void (*)(id, SEL, id))objc_msgSend)(handle_to_id(recv), sel_registerName(sel_utf8),
                                          s);
  }
}

// ---- The event loop ------------------------------------------------------

void gui_app_run(void) {
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    static SpikeDelegate *app_delegate = nil;
    if (app_delegate == nil) {
      app_delegate = [SpikeDelegate new];
    }
    app.delegate = app_delegate;
    if (getenv("EMO_GUI_AUTOTEST") != NULL) {
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
            [g_button performClick:nil];
          });
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
            printf("AUTOTEST count=%lld label=\"%s\"\n", (long long)g_count,
                   [[g_label stringValue] UTF8String]);
            fflush(stdout);
            [NSApp terminate:nil];
          });
    }
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [app activateIgnoringOtherApps:YES];
    [g_window makeKeyAndOrderFront:nil];
    [app run];
  }
}

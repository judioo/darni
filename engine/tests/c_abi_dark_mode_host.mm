// Dark mode for websites (tab/105, feature "website_dark_mode", ABI 1.73), at
// the engine boundary.
//
// One tab in a window nobody sees, on two hosts the fixture serves
// (127.0.0.1 and localhost). For each step the host reads three things:
//   what the engine says the tab holds (ReArcTabGetWebsiteDarkMode);
//   what the page can tell (the CSS system colour Canvas as computed,
//   (prefers-color-scheme: dark), its own body background);
//   what is drawn: the top row of the page's snapshot (ReArcTabCaptureSnapshot).
// The steps:
//   a page with no dark theme is white while nothing is said;
//   the profile goes dark: the open page is darkened without a reload;
//   its host goes on the light list: white again, without a reload;
//   a navigation to the other host reads the rule: dark;
//   dark only for one host: the other is white, a navigation back is dark;
//   a page with its own dark scheme is drawn in it and not darkened;
//   a page that says "only light" stays white;
//   a private window follows its profile;
//   what the engine refuses, and that a refusal changes nothing.
//
// REARC_DARK_REPORT=1 asserts nothing about pixels and page state and prints
// them instead.
//
// Nothing appears on screen and no input is sent: the window is ordered in
// off every screen, transparent and deaf to the mouse, and the process is a
// UI element (no Dock tile, no menu bar, never activated). The runner passes
// --disable-backgrounding-occluded-windows so the page is drawn all the same.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ImageIO/ImageIO.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>

struct Seen {
  bool engine_dark;      // ReArcTabGetWebsiteDarkMode
  bool prefers_dark;     // (prefers-color-scheme: dark)
  int canvas[3];         // getComputedStyle of an element with background Canvas
  int body[3];           // the body's computed background
  int pixel[3];          // the top row of what is drawn
  double token;          // made once per document: the same means no reload
};
typedef void (^Reply)(NSDictionary* value);
typedef void (^Look)(Seen seen);

static NSWindow* window;
static uint64_t profile_id, tab, private_tab;
static ReArcAttachment lease{};
static std::string port;
static NSString* waiting_title;
static dispatch_block_t waiting_block;
static bool report, stopped;
static int failures, loads;

static void after(int ms, dispatch_block_t block) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * (int64_t)NSEC_PER_MSEC),
                 dispatch_get_main_queue(), block);
}

static void expect(bool ok, const char* step, const char* what) {
  if (ok) {
    return;
  }
  ++failures;
  printf("%s %s: %s\n", report ? "OBSERVED" : "FAILED", step, what);
  assert(report);
}

static bool is_white(const int* c) { return c[0] > 245 && c[1] > 245 && c[2] > 245; }
static bool is_dark(const int* c) { return c[0] < 70 && c[1] < 70 && c[2] < 70; }
static bool is_near(const int* c, int r, int g, int b) {
  return abs(c[0] - r) <= 4 && abs(c[1] - g) <= 4 && abs(c[2] - b) <= 4;
}

static void eval(uint64_t tab_id, const char* source, Reply reply) {
  ReArcStatus status = ReArcTabEvaluateScript2(
      tab_id, source, 1 /* the page's own world */, nullptr, 10000,
      [](void* context, const ReArcScriptResult* result) {
        Reply reply = (__bridge_transfer Reply)context;
        if (result->status != REARC_OK || !result->json) {
          printf("EVAL failed status=%d error=%s\n", result->status,
                 result->error_json ? result->error_json : "(null)");
          assert(false);
        }
        NSData* data = [NSData dataWithBytes:result->json
                                      length:strlen(result->json)];
        id value = [NSJSONSerialization
            JSONObjectWithData:data
                       options:NSJSONReadingFragmentsAllowed
                         error:nil];
        assert([value isKindOfClass:[NSDictionary class]]);
        reply(value);
      },
      (__bridge_retained void*)[reply copy]);
  assert(status == REARC_OK);
}

static void rgb(NSArray* from, int* to) {
  for (int i = 0; i < 3; ++i) {
    to[i] = [from[i] intValue];
  }
}

// The middle of the snapshot's top row (scope 2: the viewport's top 4 CSS px).
static void top_pixel(uint64_t tab_id, void (^reply)(int r, int g, int b)) {
  typedef void (^Pixel)(int, int, int);
  ReArcStatus status = ReArcTabCaptureSnapshot(
      tab_id, 2,
      [](void* context, ReArcStatus status, uint64_t, uint64_t, uint8_t* data,
         size_t size) {
        Pixel reply = (__bridge_transfer Pixel)context;
        if (status != REARC_OK || !data || !size) {
          printf("SNAPSHOT failed status=%d size=%zu\n", status, size);
          assert(false);
        }
        CFDataRef bytes = CFDataCreate(nullptr, data, size);
        ReArcBufferFree(data);
        CGImageSourceRef source = CGImageSourceCreateWithData(bytes, nullptr);
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
        assert(image);
        const size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
        assert(w >= 100 && h >= 1);
        std::vector<uint8_t> px(w * h * 4);
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate(
            px.data(), w, h, 8, w * 4, space, kCGImageAlphaPremultipliedLast);
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
        const size_t i = ((h / 2) * w + w / 2) * 4;
        const int r = px[i], g = px[i + 1], b = px[i + 2];
        CGContextRelease(ctx);
        CGColorSpaceRelease(space);
        CGImageRelease(image);
        CFRelease(source);
        CFRelease(bytes);
        reply(r, g, b);
      },
      (__bridge_retained void*)[reply copy]);
  assert(status == REARC_OK);
}

// What the engine, the page and the picture say about a tab, once the
// renderer has had the preferences and drawn a frame with them.
static void look(uint64_t tab_id, const char* step, Look then) {
  after(600, ^{
    eval(tab_id, "state()", ^(NSDictionary* state) {
      top_pixel(tab_id, ^(int r, int g, int b) {
        Seen seen{};
        assert(ReArcTabGetWebsiteDarkMode(tab_id, &seen.engine_dark) ==
               REARC_OK);
        seen.prefers_dark = [state[@"prefersDark"] boolValue];
        rgb(state[@"canvas"], seen.canvas);
        rgb(state[@"body"], seen.body);
        seen.pixel[0] = r, seen.pixel[1] = g, seen.pixel[2] = b;
        seen.token = [state[@"token"] doubleValue];
        printf("LOOK %-34s engine=%d prefers-dark=%d canvas=%d,%d,%d "
               "body=%d,%d,%d drawn=%d,%d,%d\n",
               step, seen.engine_dark, seen.prefers_dark, seen.canvas[0],
               seen.canvas[1], seen.canvas[2], seen.body[0], seen.body[1],
               seen.body[2], r, g, b);
        then(seen);
      });
    });
  });
}

// Loads a fixture page in `id` and goes on when its title has arrived.
static void load(uint64_t tab_id, const char* host, const char* path,
                 dispatch_block_t then) {
  waiting_title = [NSString stringWithFormat:@"dark-ready-%d", ++loads];
  waiting_block = [then copy];
  const std::string url = std::string("http://") + host + ":" + port + path +
                          "?" + std::to_string(loads);
  assert(ReArcTabNavigate(tab_id, url.c_str(), 0) == REARC_OK);
}

static void tab_event(void*, const ReArcTabEvent* event) {
  if (event->kind != 1 || !(event->changes & 2) || !event->title ||
      !waiting_title || strcmp(event->title, waiting_title.UTF8String)) {
    return;
  }
  dispatch_block_t block = waiting_block;
  waiting_title = nil;
  waiting_block = nil;
  block();
}

static void set(bool dark, const char* dark_hosts, const char* light_hosts) {
  assert(ReArcProfileSetWebsiteDarkMode(profile_id, dark, dark_hosts,
                                        light_hosts) == REARC_OK);
}

static void finish() {
  printf("DARK MODE %d %s\n", failures,
         report ? "observation(s)" : "failure(s)");
  assert(report || !failures);
  assert(ReArcEngineShutdown(
             true,
             [](void*, ReArcStatus status, bool cancelled) {
               assert(status == REARC_OK && !cancelled);
               stopped = true;
               puts(report ? "DARK MODE report done"
                           : "DARK MODE a page with no dark theme is darkened, "
                             "its own dark scheme is kept, rules are read at "
                             "navigation, no reload PASS");
             },
             nullptr) == REARC_OK);
}

static void refusals() {
  bool dark = false;
  assert(ReArcTabGetWebsiteDarkMode(tab, &dark) == REARC_OK);
  const bool was = dark;
  assert(ReArcProfileSetWebsiteDarkMode(profile_id, !was, "[", nullptr) ==
         REARC_INVALID_ARGUMENT);
  assert(ReArcProfileSetWebsiteDarkMode(profile_id, !was, "{}", nullptr) ==
         REARC_INVALID_ARGUMENT);
  assert(ReArcProfileSetWebsiteDarkMode(profile_id, !was, "[1]", nullptr) ==
         REARC_INVALID_ARGUMENT);
  assert(ReArcProfileSetWebsiteDarkMode(profile_id, !was, "[\"Example.com\"]",
                                        nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcProfileSetWebsiteDarkMode(profile_id, !was,
                                        "[\"https://example.com/\"]",
                                        nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcProfileSetWebsiteDarkMode(profile_id, !was, "[\"\"]", nullptr) ==
         REARC_INVALID_ARGUMENT);
  assert(ReArcProfileSetWebsiteDarkMode(profile_id, !was, "[\"a.example\"]",
                                        "[\"a.example\"]") ==
         REARC_INVALID_ARGUMENT);
  assert(ReArcProfileSetWebsiteDarkMode(profile_id + 1000, true, nullptr,
                                        nullptr) == REARC_PROFILE_NOT_FOUND);
  assert(ReArcTabGetWebsiteDarkMode(tab, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcTabGetWebsiteDarkMode(tab + 1000, &dark) == REARC_TAB_NOT_FOUND);
  assert(ReArcTabGetWebsiteDarkMode(tab, &dark) == REARC_OK && dark == was);
  puts("DARK MODE refusals change nothing PASS");
}

// A private window follows its profile and cannot be told otherwise.
static void private_window() {
  assert(ReArcProfileCreateOffTheRecord(
             profile_id,
             [](void*, ReArcStatus status, uint64_t private_profile,
                bool off_the_record) {
               assert(status == REARC_OK && off_the_record);
               assert(ReArcProfileSetWebsiteDarkMode(private_profile, true,
                                                     nullptr, nullptr) ==
                      REARC_INVALID_ARGUMENT);
               assert(ReArcTabCreate(private_profile, 1, nullptr,
                                     &private_tab) == REARC_OK);
               // dark for 127.0.0.1 only, as the step before left it.
               load(private_tab, "127.0.0.1", "/dark-plain", ^{
                 after(300, ^{
                   bool dark = false;
                   assert(ReArcTabGetWebsiteDarkMode(private_tab, &dark) ==
                          REARC_OK);
                   expect(dark, "private window",
                          "a private tab on a dark host is not dark");
                   load(private_tab, "localhost", "/dark-plain", ^{
                     after(300, ^{
                       bool dark = true;
                       assert(ReArcTabGetWebsiteDarkMode(private_tab, &dark) ==
                              REARC_OK);
                       expect(!dark, "private window",
                              "a private tab on another host is dark");
                       puts("DARK MODE private window follows its profile "
                            "PASS");
                       set(false, nullptr, nullptr);
                       after(300, ^{
                         bool dark = true;
                         assert(ReArcTabGetWebsiteDarkMode(tab, &dark) ==
                                REARC_OK && !dark);
                         finish();
                       });
                     });
                   });
                 });
               });
             },
             nullptr) == REARC_OK);
}

static void own_and_opt_out() {
  load(tab, "127.0.0.1", "/dark-own", ^{
    look(tab, "own dark scheme, dark", ^(Seen own) {
      expect(own.engine_dark && own.prefers_dark, "own dark scheme",
             "the page is not told to prefer dark");
      expect(is_near(own.body, 16, 32, 48), "own dark scheme",
             "the page's own dark background is not its computed one");
      expect(is_near(own.pixel, 16, 32, 48), "own dark scheme",
             "the page's own dark background is not drawn as it is");
      load(tab, "127.0.0.1", "/dark-only-light", ^{
        look(tab, "only light, dark", ^(Seen only) {
          expect(only.engine_dark, "only light", "the tab is not dark");
          expect(is_white(only.pixel) && is_white(only.canvas), "only light",
                 "a page that says only light is darkened");
          refusals();
          private_window();
        });
      });
    });
  });
}

static void start() {
  look(tab, "nothing said", ^(Seen off) {
    expect(!off.engine_dark, "nothing said", "the tab is dark");
    expect(is_white(off.pixel) && is_white(off.canvas) && is_white(off.body),
           "nothing said", "the page is not white");
    set(true, nullptr, nullptr);
    look(tab, "profile dark, no reload", ^(Seen on) {
      expect(on.engine_dark, "profile dark", "the tab is not dark");
      expect(on.token == off.token, "profile dark", "the page was reloaded");
      expect(on.prefers_dark, "profile dark",
             "(prefers-color-scheme: dark) does not match");
      expect(is_dark(on.canvas), "profile dark",
             "the computed Canvas colour is not dark");
      expect(is_dark(on.pixel), "profile dark",
             "the white page is not drawn dark");
      // Blink darkens as it paints: the page's own colours are as written.
      expect(is_white(on.body), "profile dark",
             "the body's computed background changed");
      set(true, nullptr, "[\"127.0.0.1\"]");
      look(tab, "host on the light list, no reload", ^(Seen light) {
        expect(!light.engine_dark && light.token == off.token &&
                   is_white(light.pixel) && is_white(light.canvas),
               "light list", "the page is not white again without a reload");
        load(tab, "localhost", "/dark-plain", ^{
          look(tab, "other host after navigation", ^(Seen other) {
            expect(other.engine_dark && is_dark(other.pixel) &&
                       is_dark(other.canvas),
                   "navigation", "the other host's page is not dark");
            set(false, "[\"127.0.0.1\"]", nullptr);
            look(tab, "dark for one host only", ^(Seen single) {
              expect(!single.engine_dark && is_white(single.pixel) &&
                         single.token == other.token,
                     "one host", "a host that is not on the list is dark");
              load(tab, "127.0.0.1", "/dark-plain", ^{
                look(tab, "the listed host after navigation", ^(Seen listed) {
                  expect(listed.engine_dark && is_dark(listed.pixel),
                         "one host", "the listed host's page is not dark");
                  own_and_opt_out();
                });
              });
            });
          });
        });
      });
    });
  });
}

static void ready(void*, uint64_t profile) {
  printf("ENGINE bridge %s abi 1.%u website_dark_mode=%d\n",
         ReArcEngineBridgeVersion(), ReArcEngineABIMinorVersion(),
         ReArcEngineHasFeature("website_dark_mode"));
  assert(ReArcEngineABIMinorVersion() >= 73 &&
         ReArcEngineHasFeature("website_dark_mode"));
  profile_id = profile;
  // Borderless: AppKit keeps a titled window on a screen.
  window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-20000, -20000, 400, 300)
                                       styleMask:NSWindowStyleMaskBorderless
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
  window.alphaValue = 0;
  window.ignoresMouseEvents = YES;
  window.hasShadow = NO;
  window.excludedFromWindowsMenu = YES;
  window.collectionBehavior = NSWindowCollectionBehaviorStationary |
                              NSWindowCollectionBehaviorIgnoresCycle |
                              NSWindowCollectionBehaviorTransient;
  assert(ReArcWindowRegister(1, (__bridge void*)window) == REARC_OK);
  [window orderBack:nil];
  assert(window.visible && !window.keyWindow && !NSApp.active);
  assert(ReArcTabCreate(profile, 1, nullptr, &tab) == REARC_OK);
  assert(ReArcViewAttach(tab, 1, 400, 300, 1, &lease) == REARC_OK);
  [window.contentView addSubview:(__bridge NSView*)lease.native_view];
  assert(ReArcViewSetVisible(tab, lease.attachment_id, true) == REARC_OK);
  load(tab, "127.0.0.1", "/dark-plain", ^{
    start();
  });
}

int main(int argc, const char** argv) {
  @autoreleasepool {
    setbuf(stdout, nullptr);
    // No Dock tile and no menu bar, before Chromium makes the application.
    ProcessSerialNumber process = {0, kCurrentProcess};
    TransformProcessType(&process, kProcessTransformToUIElementApplication);
    report = getenv("REARC_DARK_REPORT") != nullptr;
    port = getenv("REARC_TEST_PORT");
    ReArcCallbacks callbacks{ready, tab_event, nullptr, nullptr};
    assert(ReArcEngineConfigure(1, &callbacks, nullptr) == REARC_OK);
    // A release engine drops --host-resolver-rules without this (ABI 1.56),
    // and then does its first-run network work; the runner's audit refuses it.
    assert(ReArcEngineAllowTestSwitches() == REARC_OK);
    const int code = ReArcEngineRun(argc, argv);
    assert(code == 0 && stopped);
    return code;
  }
}

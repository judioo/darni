// Screen sharing of a tab nobody looks at (tab/102, feature
// "display_capture_hidden_tab", bridge 0.82.0), at the engine boundary.
//
// One page asks (getDisplayMedia) from a tab the window shows; the host
// answers with a tab of its own, as the shell's sheet does. Five shares:
//   a tab the host never attached (no size until it is shared), with sound;
//   another such tab, without sound;
//   a tab that was shown and then detached, with sound, and without;
//   the asking tab itself.
// Each must give the page a live "browser" stream with frames, and must not
// tell the shared page anything: document.hidden keeps its value and no
// visibilitychange fires when the share starts or when it ends (security
// review of tab/102). ReArcTabStopDisplayCapture ends every share.
//
// REARC_CAPTURE_REPORT=1 asserts nothing about the outcome and prints what
// happens instead: for an engine without the patch, where the first two
// shares end after ten seconds and the next two tell the page it is visible.
//
// The asking page must be visible to Chromium (its handler refuses a page
// nobody sees), so this host shows a small window. It sends no input.
#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>

typedef void (^Reply)(NSDictionary* value);

struct Share {
  const char* name;
  uint64_t target;
  bool audio;
  bool shown_before;  // the host attached it once; false: it has no size yet
  bool own;           // the asking tab itself
};

static NSWindow* window;
static uint64_t asker, shown, never_a, never_b;
static ReArcAttachment asker_lease{}, shown_lease{};
static std::string base;
static std::vector<Share> shares;
static size_t current;
static int loaded, requests, ends, failures;
static bool report, started, stopped;
static NSDictionary* before;
static NSDate* asked_at;

static void run_share();

static void after(int ms, dispatch_block_t block) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * (int64_t)NSEC_PER_MSEC),
                 dispatch_get_main_queue(), block);
}

// The value of a page expression, as a dictionary ({"value": x} for a scalar).
static void eval(uint64_t tab, const char* source, Reply reply) {
  ReArcStatus status = ReArcTabEvaluateScript2(
      tab, source, 0, nullptr, 10000,
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
        reply([value isKindOfClass:[NSDictionary class]]
                  ? value
                  : @{@"value" : value ?: [NSNull null]});
      },
      (__bridge_retained void*)[reply copy]);
  assert(status == REARC_OK);
}

static std::string text(NSDictionary* value) {
  NSData* data = [NSJSONSerialization dataWithJSONObject:value
                                                 options:NSJSONWritingSortedKeys
                                                   error:nil];
  return std::string((const char*)data.bytes, data.length);
}

// A check that fails the run, or only says so for an engine without the patch.
static void expect(bool ok, const char* what) {
  if (ok) {
    return;
  }
  ++failures;
  printf("%s %s: %s\n", report ? "OBSERVED" : "FAILED", shares[current].name,
         what);
  assert(report);
}

static bool capturing() {
  ReArcMediaCaptureState state{};
  assert(ReArcTabGetMediaCapture(asker, &state) == REARC_OK);
  return state.capturing_display;
}

static void finish() {
  printf("DISPLAY CAPTURE %zu share(s), %d request(s), %d end(s), %d %s\n",
         shares.size(), requests, ends, failures,
         report ? "observation(s) of an engine without tab/102" : "failure(s)");
  assert(requests == (int)shares.size() && ends == requests);
  assert(report || !failures);
  ReArcEngineSetDisplayCaptureCallback(nullptr, nullptr);
  assert(ReArcEngineShutdown(
             true,
             [](void*, ReArcStatus status, bool cancelled) {
               assert(status == REARC_OK && !cancelled);
               stopped = true;
               puts(report ? "DISPLAY CAPTURE report done"
                           : "DISPLAY CAPTURE hidden tabs: live with frames, "
                             "page stays hidden, no visibilitychange PASS");
             },
             nullptr) == REARC_OK);
}

static void next_share() {
  if (++current == shares.size()) {
    return finish();
  }
  run_share();
}

// What the shared page can tell after the share is over.
static void after_stop() {
  const Share& share = shares[current];
  // A visibility change reaches the renderer after the browser's own state.
  after(700, ^{
    eval(share.target, "state()", ^(NSDictionary* now) {
      printf("AFTER  %s %s capturing=%d\n", shares[current].name,
             text(now).c_str(), capturing());
      expect([now[@"hidden"] isEqual:before[@"hidden"]],
             "document.hidden changed when the share ended");
      expect([now[@"changes"] isEqual:before[@"changes"]],
             "visibilitychange fired when the share ended");
      expect(!capturing(), "media_capture still reports a share");
      next_share();
    });
  });
}

static void stop_share(int tries) {
  eval(asker, "state()", ^(NSDictionary* now) {
    if ([now[@"share"] isEqual:@"ended"] || tries == 0) {
      expect([now[@"share"] isEqual:@"ended"],
             "the page's track did not end after Stop");
      return after_stop();
    }
    after(200, ^{
      stop_share(tries - 1);
    });
  });
}

// The stream is live: what the shared page can tell while it is shared.
static void during_share() {
  const Share& share = shares[current];
  eval(share.target, "state()", ^(NSDictionary* now) {
    printf("DURING %s %s capturing=%d\n", shares[current].name,
           text(now).c_str(), capturing());
    expect([now[@"hidden"] isEqual:before[@"hidden"]],
           "document.hidden changed when the share started");
    expect([now[@"changes"] isEqual:before[@"changes"]],
           "visibilitychange fired when the share started");
    expect([now[@"w"] intValue] > 0 && [now[@"h"] intValue] > 0,
           "the shared page has no size");
    expect(capturing(), "media_capture reports no share");
    assert(ReArcTabStopDisplayCapture(asker) == REARC_OK);
    assert(ReArcTabStopDisplayCapture(asker) == REARC_INVALID_STATE);
    stop_share(25);
  });
}

static void poll_share() {
  eval(asker, "state()", ^(NSDictionary* now) {
    const Share& share = shares[current];
    NSString* state = now[@"share"];
    const double waited = -asked_at.timeIntervalSinceNow;
    if ([state isEqual:@"live"] && [now[@"frames"] intValue] >= 2) {
      printf("LIVE   %s after %.1f s: %s\n", share.name, waited,
             text(now).c_str());
      expect([now[@"surface"] isEqual:@"browser"], "not a tab's stream");
      expect([now[@"audio"] intValue] == (share.audio ? 1 : 0),
             "the stream's sound is not what was answered");
      return during_share();
    }
    if ([state hasPrefix:@"error"] || waited > 25) {
      printf("NOT LIVE %s after %.1f s: %s\n", share.name, waited,
             text(now).c_str());
      expect(false, "the page got no live stream with frames");
      // Report mode only: say what the shared page saw, end what is left.
      eval(share.target, "state()", ^(NSDictionary* target) {
        printf("TARGET %s %s capturing=%d\n", shares[current].name,
               text(target).c_str(), capturing());
        ReArcTabStopDisplayCapture(asker);
        after(700, ^{
          next_share();
        });
      });
      return;
    }
    after(250, ^{
      poll_share();
    });
  });
}

static void run_share() {
  const Share& share = shares[current];
  eval(share.target, "state()", ^(NSDictionary* now) {
    const Share& share = shares[current];
    before = now;
    printf("BEFORE %s %s\n", share.name, text(now).c_str());
    // The premises: a page nobody looks at is hidden, and one the host never
    // attached has no size (the reason its capture had no first frame).
    assert([now[@"hidden"] boolValue] == !share.own);
    if (!share.own && !share.shown_before) {
      assert([now[@"w"] intValue] == 0 && [now[@"h"] intValue] == 0 &&
             [now[@"changes"] intValue] == 0);
    }
    asked_at = [NSDate date];
    eval(asker, share.audio ? "ask(true)" : "ask(false)", ^(NSDictionary*) {
      poll_share();
    });
  });
}

static void display_capture(void*,
                            uint64_t request,
                            uint64_t tab,
                            uint32_t phase,
                            const char* json) {
  assert([NSThread isMainThread] && tab == asker && json);
  if (phase) {
    ++ends;
    printf("REQUEST %llu ended %s\n", request, json);
    assert(report || strstr(json, "\"shared\""));
    return;
  }
  ++requests;
  const Share& share = shares[current];
  const ReArcStatus status =
      ReArcDisplayCaptureRespond(request, 1, share.target, share.audio);
  printf("REQUEST %llu %s -> tab %llu sound %d: status %d\n", request, json,
         share.target, share.audio, status);
  assert(status == REARC_OK);
}

static void media_capture(void*, const ReArcMediaCaptureState* state) {
  printf("MEDIA_CAPTURE tab %llu display %d\n", state->tab_id,
         state->capturing_display);
}

static void attach(uint64_t tab, ReArcAttachment* lease) {
  assert(ReArcViewAttach(tab, 1, 400, 300, 1, lease) == REARC_OK);
  [window.contentView addSubview:(__bridge NSView*)lease->native_view];
  assert(ReArcViewSetVisible(tab, lease->attachment_id, true) == REARC_OK);
}

// Every page is loaded: `shown` has been on screen. Hide it for good and show
// the asking tab instead.
static void start() {
  eval(shown, "state()", ^(NSDictionary* now) {
    printf("SHOWN  %s\n", text(now).c_str());
    assert(![now[@"hidden"] boolValue] && [now[@"w"] intValue] == 400);
    assert(ReArcViewSetVisible(shown, shown_lease.attachment_id, false) ==
           REARC_OK);
    [(__bridge NSView*)shown_lease.native_view removeFromSuperview];
    assert(ReArcViewDetach(shown, shown_lease.attachment_id) == REARC_OK);
    ReArcViewRelease(shown_lease.native_view);
    attach(asker, &asker_lease);
    after(700, ^{
      eval(asker, "state()", ^(NSDictionary* asking) {
        printf("ASKER  %s\n", text(asking).c_str());
        assert(![asking[@"hidden"] boolValue]);
        shares = {
            {"never shown, with sound", never_a, true, false, false},
            {"never shown, without sound", never_b, false, false, false},
            {"shown then hidden, with sound", shown, true, true, false},
            {"shown then hidden, without sound", shown, false, true, false},
            {"its own tab", asker, false, true, true},
        };
        run_share();
      });
    });
  });
}

static void tab_event(void*, const ReArcTabEvent* event) {
  if (event->kind != 1 || !(event->changes & 2) || !event->title ||
      strcmp(event->title, "capture-ready")) {
    return;
  }
  if (++loaded == 4 && !started) {
    started = true;
    // Past the page's first paint in the window.
    after(700, ^{
      start();
    });
  }
}

static void ready(void*, uint64_t profile) {
  assert(ReArcEngineABIMinorVersion() >= 70 &&
         ReArcEngineHasFeature("display_capture"));
  printf("ENGINE bridge %s display_capture_hidden_tab=%d\n",
         ReArcEngineBridgeVersion(),
         ReArcEngineHasFeature("display_capture_hidden_tab"));
  assert(report || ReArcEngineHasFeature("display_capture_hidden_tab"));
  ReArcEngineSetDisplayCaptureCallback(display_capture, nullptr);
  ReArcEngineSetMediaCaptureCallback(media_capture, nullptr);
  window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300)
                                       styleMask:NSWindowStyleMaskTitled
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
  assert(ReArcWindowRegister(1, (__bridge void*)window) == REARC_OK);
  [window orderFront:nil];
  const std::string url = base + "/capture";
  assert(ReArcTabCreate(profile, 1, (url + "?shown").c_str(), &shown) == 0);
  assert(ReArcTabCreate(profile, 1, (url + "?never-a").c_str(), &never_a) == 0);
  assert(ReArcTabCreate(profile, 1, (url + "?never-b").c_str(), &never_b) == 0);
  assert(ReArcTabCreate(profile, 1, (url + "?asker").c_str(), &asker) == 0);
  attach(shown, &shown_lease);
}

int main(int argc, const char** argv) {
  @autoreleasepool {
    setbuf(stdout, nullptr);
    report = getenv("REARC_CAPTURE_REPORT") != nullptr;
    base = "http://127.0.0.1:" + std::string(getenv("REARC_TEST_PORT"));
    ReArcCallbacks callbacks{ready, tab_event, nullptr, nullptr};
    assert(ReArcEngineConfigure(1, &callbacks, nullptr) == REARC_OK);
    const int code = ReArcEngineRun(argc, argv);
    assert(code == 0 && stopped);
    return code;
  }
}

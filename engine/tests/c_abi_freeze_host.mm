// Tab freezing (tab/103, feature "tab_freeze", ABI 1.71), at the engine
// boundary.
//
// A page that nobody looks at is frozen on the host's request: its timer
// stops, the page stays (no reload), and it runs again when the request ends
// or the tab is shown. Each page of the fixture says every tick of its timer
// in its title, so the host hears a running page without asking it anything:
// a script of the host's thaws the tab, which is checked too.
//
// What is checked, in order:
//   refusals: a tab on screen, an unknown tab, null arguments;
//   a tab never shown: frozen, silent for three seconds, thawed by Unfreeze
//     with the same document, one freeze and one resume event;
//   a tab shown and hidden again: frozen once Chromium's protection time is
//     over, thawed by being shown, and thawed by a script of the host's;
//   a tab that plays sound is never frozen;
//   "Leave site?" (security's advance read, 1): a tab with a beforeunload
//     handler may be frozen and is never discarded, frozen or not; a frozen
//     tab without one is discarded, and its request ends;
//   the shared tab (2): a frozen tab that is shared thaws before the capture
//     starts and its picture moves; while it is shared it is not frozen;
//   a tab with a download of its own in progress is not frozen;
//   thawing (3): a page that would open a pop-up, ask for notifications,
//     start a download and show a dialog from a timer does none of it while
//     frozen. At the thaw its timer runs: the pop-up is dropped (no click,
//     no tab), and what else it asks then, as any tab in the background may,
//     is printed and answered with no.
//
// Nothing appears on screen and no input is sent: the window is ordered in
// off every screen, transparent and deaf to the mouse, and the process is a
// UI element (as c_abi_display_capture_host.mm). The runner passes
// --mute-audio, so the sound goes nowhere.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <map>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>

typedef void (^Reply)(NSDictionary* value);

static NSWindow* window;
static uint64_t profile_id;
static uint64_t front, idle, walked, loud, guarded, shared, armed, loader;
static ReArcAttachment front_lease{}, walked_lease{};
static std::string base, downloads;
static std::map<uint64_t, int> beats;  // title changes of a running page
static int loaded;
static bool started, stopped, settled;
// What a page made the host do, counted from the moment the tabs are loaded.
static int popups, permissions, dialogs, armed_downloads;
static int capture_requests, capture_ends;
static bool loader_refused, loader_done;

static void after(int ms, dispatch_block_t block) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * (int64_t)NSEC_PER_MSEC),
                 dispatch_get_main_queue(), block);
}

// The value of a page expression. It thaws the tab: only where that is meant.
static void eval(uint64_t tab, const char* source, Reply reply) {
  ReArcStatus status = ReArcTabEvaluateScript2(
      tab, source, 1 /* the page's own world */, nullptr, 30000,
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
  if (status != REARC_OK) {
    printf("EVAL refused status=%d source=%s\n", status, source);
  }
  assert(status == REARC_OK);
}

static std::string text(NSDictionary* value) {
  NSData* data = [NSJSONSerialization dataWithJSONObject:value
                                                 options:NSJSONWritingSortedKeys
                                                   error:nil];
  return std::string((const char*)data.bytes, data.length);
}

static bool requested(uint64_t tab) {
  bool asked = true, frozen = true;
  assert(ReArcTabGetFreezeState(tab, &asked, &frozen) == REARC_OK);
  return asked;
}

static bool frozen(uint64_t tab) {
  bool asked = true, is_frozen = true;
  assert(ReArcTabGetFreezeState(tab, &asked, &is_frozen) == REARC_OK);
  return is_frozen;
}

static bool discarded(uint64_t tab) {
  bool is_discarded = true;
  assert(ReArcTabGetDiscardState(tab, &is_discarded) == REARC_OK);
  return is_discarded;
}

// Waits until the page's renderer reports the lifecycle state, at most ms.
static void when_frozen(uint64_t tab, bool want, int ms, const char* what,
                        dispatch_block_t then) {
  if (frozen(tab) == want) {
    return then();
  }
  if (ms <= 0) {
    printf("FAILED %s: the page is %s after the wait\n", what,
           want ? "not frozen" : "still frozen");
    assert(false);
  }
  after(100, ^{
    when_frozen(tab, want, ms - 100, what, then);
  });
}

// Waits until the host has heard more than `heard` ticks of the page, at most
// ms: a loaded Mac gives a renderer in the background little time.
static void when_ticking(uint64_t tab, int heard, int ms, const char* what,
                         dispatch_block_t then) {
  if (beats[tab] > heard) {
    return then();
  }
  if (ms <= 0) {
    printf("FAILED %s: no tick of the page's timer\n", what);
    assert(false);
  }
  after(100, ^{
    when_ticking(tab, heard, ms - 100, what, then);
  });
}

static void attach(uint64_t tab, ReArcAttachment* lease) {
  assert(ReArcViewAttach(tab, 1, 400, 300, 1, lease) == REARC_OK);
  [window.contentView addSubview:(__bridge NSView*)lease->native_view];
  assert(ReArcViewSetVisible(tab, lease->attachment_id, true) == REARC_OK);
}

static void detach(uint64_t tab, ReArcAttachment* lease) {
  assert(ReArcViewSetVisible(tab, lease->attachment_id, false) == REARC_OK);
  [(__bridge NSView*)lease->native_view removeFromSuperview];
  assert(ReArcViewDetach(tab, lease->attachment_id) == REARC_OK);
  ReArcViewRelease(lease->native_view);
  *lease = {};
}

static void finish() {
  assert(capture_requests == 1 && capture_ends == 1);
  assert(loader_refused && loader_done);
  ReArcEngineSetDisplayCaptureCallback(nullptr, nullptr);
  ReArcEngineSetPermissionCallback(nullptr, nullptr);
  ReArcEngineSetDownloadCallback(nullptr, nullptr);
  assert(ReArcEngineShutdown(
             true,
             [](void*, ReArcStatus status, bool cancelled) {
               assert(status == REARC_OK && !cancelled);
               stopped = true;
               puts("FREEZE timer stops and resumes without reload, show and "
                    "script thaw, sound/shared/download/beforeunload tabs "
                    "kept, nothing asked while frozen PASS");
             },
             nullptr) == REARC_OK);
}

// --- 8. Thawing: nothing a frozen page would ask reaches the host ----------

static void armed_asked(int tries) {
  eval(armed, "state()", ^(NSDictionary* fired) {
    if (![fired[@"armed"][@"alerted"] boolValue]) {
      assert(tries > 0);
      after(250, ^{
        armed_asked(tries - 1);
      });
      return;
    }
    // Its timer has run to its end; what it asked is on its way to the host.
    after(1500, ^{
    eval(armed, "state()", ^(NSDictionary* now) {
      NSDictionary* asked = now[@"armed"];
      printf("ARMED thawed: %s; popups %d permissions %d dialogs %d "
             "downloads %d\n",
             text(asked).c_str(), popups, permissions, dialogs,
             armed_downloads);
      // The timer ran at the thaw, not before: late by the time frozen.
      assert([asked[@"fired"] boolValue] && [asked[@"late"] intValue] >= 2500);
      // No click outlives the freeze, so the pop-up is dropped as any pop-up
      // without one (tab_adoption.cc): no tab is made for it, the host hears
      // nothing, and the window the page was handed is closed.
      assert([asked[@"activation"] isEqual:@NO]);
      assert(popups == 0);
      assert([asked[@"opened"] isEqual:@NO] ||
             [now[@"popupClosed"] isEqual:@YES]);
      // The rest is asked at the thaw, by the page's own timer, as a tab in
      // the background that was never frozen asks it: at most once each.
      assert(dialogs <= 1 && armed_downloads <= 1 && permissions <= 1);
      finish();
    });
    });
  });
}

static void thaw_armed() {
  // The timer was due three seconds ago.
  printf("ARMED frozen: popups %d permissions %d dialogs %d downloads %d\n",
         popups, permissions, dialogs, armed_downloads);
  assert(frozen(armed) && requested(armed));
  assert(popups == 0 && permissions == 0 && dialogs == 0 &&
         armed_downloads == 0);
  assert(ReArcTabUnfreeze(armed) == REARC_OK && !requested(armed));
  armed_asked(120);
}

static void arm() {
  popups = permissions = dialogs = armed_downloads = 0;
  settled = true;
  // The timer is due in six seconds: the page is frozen well before, and is
  // looked at three seconds after.
  NSDate* armed_at = [NSDate date];
  eval(armed, "arm(6000)", ^(NSDictionary*) {
    assert(ReArcTabFreeze(armed) == REARC_OK);
    when_frozen(armed, true, 4000, "armed", ^{
      assert(-armed_at.timeIntervalSinceNow < 5);
      after(9000, ^{
        thaw_armed();
      });
    });
  });
}

// --- 7. A download of the tab's own ----------------------------------------

static void download(void*, const ReArcDownloadEvent* event) {
  if (event->tab_id == armed && event->kind == 0) {
    ++armed_downloads;
    printf("DOWNLOAD of the armed page %s\n", event->url ? event->url : "");
    return;
  }
  if (event->tab_id != loader) {
    return;
  }
  if (event->state == 0 && !loader_refused) {
    // In progress: the tab is in use.
    const ReArcStatus status = ReArcTabFreeze(loader);
    printf("LOADER download in progress: Freeze -> %d\n", status);
    assert(status == REARC_INVALID_STATE && !requested(loader));
    loader_refused = true;
  }
  if (event->kind == 2 && !loader_done) {
    loader_done = true;
    assert(loader_refused);
    after(300, ^{
      assert(ReArcTabFreeze(loader) == REARC_OK);
      assert(ReArcTabUnfreeze(loader) == REARC_OK);
      puts("LOADER download done: Freeze -> 0");
      arm();
    });
  }
}

static void start_download() {
  eval(loader, "location.href = '/download/slow', true", ^(NSDictionary*) {
  });
}

// --- 6. The shared tab ------------------------------------------------------

static void end_share() {
  assert(ReArcTabStopDisplayCapture(front) == REARC_OK);
  after(1200, ^{
    assert(capture_ends == 1);
    // Nobody captures it any more: it may be frozen again.
    assert(ReArcTabFreeze(shared) == REARC_OK);
    assert(ReArcTabUnfreeze(shared) == REARC_OK);
    puts("SHARED share over: Freeze -> 0");
    start_download();
  });
}

static void poll_share(int tries, int first_frames) {
  eval(front, "state()", ^(NSDictionary* now) {
    NSString* state = now[@"share"];
    const int frames = [now[@"frames"] intValue];
    if ([state isEqual:@"live"] && frames >= 2 && first_frames < 0) {
      // Live. The picture of a frozen page would stand still from here.
      assert(!requested(shared) && !frozen(shared));
      const ReArcStatus status = ReArcTabFreeze(shared);
      printf("SHARED live with %d frames: Freeze -> %d\n", frames, status);
      assert(status == REARC_INVALID_STATE && !requested(shared));
      after(2500, ^{
        poll_share(80, frames);
      });
      return;
    }
    if (first_frames >= 0 && (frames > first_frames || tries == 0)) {
      printf("SHARED %d frames, then %d\n", first_frames, frames);
      assert([state isEqual:@"live"] && frames > first_frames);
      assert(!frozen(shared));
      return end_share();
    }
    if (first_frames >= 0) {
      after(250, ^{
        poll_share(tries - 1, first_frames);
      });
      return;
    }
    if ([state hasPrefix:@"error"] || tries == 0) {
      printf("FAILED shared: %s\n", text(now).c_str());
      assert(false);
    }
    after(250, ^{
      poll_share(tries - 1, -1);
    });
  });
}

static void display_capture(void*,
                            uint64_t request,
                            uint64_t tab,
                            uint32_t phase,
                            const char* json) {
  assert(tab == front && json);
  if (phase) {
    ++capture_ends;
    return;
  }
  ++capture_requests;
  // The tab the person picks is frozen at this moment.
  assert(requested(shared) && frozen(shared));
  assert(ReArcDisplayCaptureRespond(request, 1, shared, false) == REARC_OK);
  // Its request to be frozen is over before the capture starts.
  assert(!requested(shared));
  puts("SHARED answered: the frozen tab's request ended");
}

static void share() {
  assert(ReArcTabFreeze(shared) == REARC_OK);
  when_frozen(shared, true, 20000, "shared", ^{
    eval(front, "ask()", ^(NSDictionary*) {
      poll_share(160, -1);
    });
  });
}

// --- 5. "Leave site?" -------------------------------------------------------

static void discard_frozen() {
  // A frozen tab with nothing to lose is discarded, and its request ends.
  assert(ReArcTabFreeze(idle) == REARC_OK);
  when_frozen(idle, true, 20000, "idle before its discard", ^{
    const ReArcStatus status = ReArcTabDiscard(idle);
    printf("IDLE frozen: Discard -> %d\n", status);
    assert(status == REARC_OK && discarded(idle) && !requested(idle));
    share();
  });
}

static void leave_site() {
  eval(guarded, "guard()", ^(NSDictionary*) {
    // Not frozen: Chromium will not discard a page that asks before it goes.
    assert(ReArcTabDiscard(guarded) == REARC_INVALID_STATE &&
           !discarded(guarded));
    assert(ReArcTabFreeze(guarded) == REARC_OK);
    when_frozen(guarded, true, 20000, "guarded", ^{
      // Frozen: the same, and the refusal leaves it frozen and loaded.
      const ReArcStatus status = ReArcTabDiscard(guarded);
      printf("GUARDED frozen: Discard -> %d\n", status);
      assert(status == REARC_INVALID_STATE && !discarded(guarded));
      assert(requested(guarded) && frozen(guarded));
      assert(ReArcTabUnfreeze(guarded) == REARC_OK);
      when_frozen(guarded, false, 20000, "guarded after Unfreeze", ^{
        eval(guarded, "state()", ^(NSDictionary* now) {
          assert(![now[@"wasDiscarded"] boolValue]);
          discard_frozen();
        });
      });
    });
  });
}

// --- 4. Sound ---------------------------------------------------------------

static void poll_loud(int tries, int refusals) {
  const ReArcStatus status = ReArcTabFreeze(loud);
  if (status == REARC_OK) {
    // Not heard yet: take the request back and look again.
    assert(ReArcTabUnfreeze(loud) == REARC_OK);
    if (refusals || tries == 0) {
      printf("FAILED loud: Freeze -> 0 after %d refusal(s)\n", refusals);
      assert(false);
    }
    after(300, ^{
      poll_loud(tries - 1, 0);
    });
    return;
  }
  assert(status == REARC_INVALID_STATE && !requested(loud) && !frozen(loud));
  if (refusals == 5) {
    const int heard = beats[loud];
    when_ticking(loud, heard, 20000, "loud", ^{
      printf("LOUD refused six times, %d tick(s) meanwhile\n",
             beats[loud] - heard);
      assert(!frozen(loud) && !requested(loud));
      leave_site();
    });
    return;
  }
  after(400, ^{
    poll_loud(tries, refusals + 1);
  });
}

static void sound() {
  eval(loud, "sound()", ^(NSDictionary* now) {
    printf("LOUD audio context %s\n", text(now).c_str());
    assert([now[@"value"] isEqual:@"running"]);
    poll_loud(20, 0);
  });
}

// --- 3. Shown and hidden again ----------------------------------------------

static void thaw_by_script() {
  detach(walked, &walked_lease);
  // Hidden this moment: the request is held, and Chromium freezes the page
  // when its protection time (a second here, five minutes in a release) ends.
  assert(ReArcTabFreeze(walked) == REARC_OK && requested(walked));
  when_frozen(walked, true, 30000, "walked, hidden again", ^{
    eval(walked, "1 + 1", ^(NSDictionary* now) {
      printf("WALKED script on a frozen tab: %s\n", text(now).c_str());
      assert([now[@"value"] isEqual:@2]);
      assert(!requested(walked));
      when_frozen(walked, false, 20000, "walked after a script", ^{
        sound();
      });
    });
  });
}

static void thaw_by_show(NSDictionary* before) {
  assert(ReArcTabFreeze(walked) == REARC_OK && requested(walked));
  when_frozen(walked, true, 30000, "walked", ^{
    const int heard = beats[walked];
    after(2000, ^{
      assert(beats[walked] <= heard + 1 && frozen(walked));
      // On screen it must not stay frozen, and it could not: Freeze refuses.
      attach(walked, &walked_lease);
      assert(!requested(walked));
      assert(ReArcTabFreeze(walked) == REARC_INVALID_STATE);
      when_frozen(walked, false, 20000, "walked when shown", ^{
        when_ticking(walked, heard + 1, 20000, "walked when shown", ^{
          eval(walked, "state()", ^(NSDictionary* now) {
            printf("WALKED shown %s\n", text(now).c_str());
            assert([now[@"boot"] isEqual:before[@"boot"]] &&
                   ![now[@"wasDiscarded"] boolValue] &&
                   ![now[@"hidden"] boolValue]);
            assert([now[@"freezes"] intValue] == 1 &&
                   [now[@"resumes"] intValue] == 1);
            assert([now[@"maxGap"] intValue] >= 1800);
            thaw_by_script();
          });
        });
      });
    });
  });
}

static void walk() {
  eval(walked, "mark()", ^(NSDictionary* before) {
    printf("WALKED on screen %s\n", text(before).c_str());
    assert(![before[@"hidden"] boolValue]);
    assert(ReArcTabFreeze(walked) == REARC_INVALID_STATE && !requested(walked));
    detach(walked, &walked_lease);
    thaw_by_show(before);
  });
}

// --- 2. Never shown ---------------------------------------------------------

static void never_shown() {
  eval(idle, "mark()", ^(NSDictionary* before) {
    printf("IDLE before %s\n", text(before).c_str());
    assert([before[@"hidden"] boolValue] && [before[@"freezes"] intValue] == 0);
    assert(!requested(idle) && !frozen(idle));
    assert(ReArcTabFreeze(idle) == REARC_OK && requested(idle));
    assert(ReArcTabFreeze(idle) == REARC_OK && requested(idle));
    when_frozen(idle, true, 20000, "idle", ^{
      const int heard = beats[idle];
      after(3000, ^{
        // Silent: at most the one tick that was on its way.
        printf("IDLE frozen 3 s: %d tick(s)\n", beats[idle] - heard);
        assert(beats[idle] <= heard + 1 && frozen(idle) && requested(idle));
        const int still = beats[idle];
        assert(ReArcTabUnfreeze(idle) == REARC_OK && !requested(idle));
        assert(ReArcTabUnfreeze(idle) == REARC_OK);
        when_frozen(idle, false, 20000, "idle after Unfreeze", ^{
          when_ticking(idle, still, 20000, "idle after Unfreeze", ^{
            eval(idle, "state()", ^(NSDictionary* now) {
              printf("IDLE thawed %s, %d tick(s) heard\n", text(now).c_str(),
                     beats[idle] - still);
              // The same document went on: nothing was loaded again.
              assert([now[@"boot"] isEqual:before[@"boot"]] &&
                     ![now[@"wasDiscarded"] boolValue] &&
                     [now[@"hidden"] boolValue]);
              assert([now[@"ticks"] intValue] > [before[@"ticks"] intValue]);
              assert([now[@"freezes"] intValue] == 1 &&
                     [now[@"resumes"] intValue] == 1);
              assert([now[@"changes"] intValue] ==
                     [before[@"changes"] intValue]);
              assert([now[@"maxGap"] intValue] >= 2800);
              walk();
            });
          });
        });
      });
    });
  });
}

// --- 1. Refusals ------------------------------------------------------------

static void start() {
  bool a = true, b = true;
  assert(ReArcTabFreeze(999999) == REARC_TAB_NOT_FOUND);
  assert(ReArcTabUnfreeze(999999) == REARC_TAB_NOT_FOUND);
  assert(ReArcTabGetFreezeState(999999, &a, &b) == REARC_TAB_NOT_FOUND && !a &&
         !b);
  assert(ReArcTabGetFreezeState(idle, nullptr, &b) == REARC_INVALID_ARGUMENT);
  assert(ReArcTabGetFreezeState(idle, &a, nullptr) == REARC_INVALID_ARGUMENT);
  // On screen.
  assert(ReArcTabFreeze(front) == REARC_INVALID_STATE && !requested(front));
  assert(ReArcTabUnfreeze(front) == REARC_OK);
  never_shown();
}

static void tab_event(void*, const ReArcTabEvent* event) {
  if (event->kind == 0 && settled) {
    ++popups;
    printf("POPUP tab %llu opener %llu\n", event->tab_id, event->opener_tab_id);
    return;
  }
  if (event->kind != 1 || !(event->changes & 2) || !event->title) {
    return;
  }
  if (!strncmp(event->title, "tick ", 5)) {
    ++beats[event->tab_id];
    return;
  }
  if (!strcmp(event->title, "freeze-ready") && ++loaded == 8 && !started) {
    started = true;
    after(1000, ^{
      start();
    });
  }
}

static void permission(void*, const ReArcPermissionEvent* event) {
  if (event->phase) {
    return;
  }
  ++permissions;
  printf("PERMISSION asked by tab %llu (%zu type(s)): denied\n", event->tab_id,
         event->type_count);
  assert(ReArcPermissionRespond(event->request_id, 1, false) == REARC_OK);
}

static void dialog(void*, const ReArcJavaScriptDialogEvent* event) {
  if (event->phase) {
    return;
  }
  ++dialogs;
  printf("DIALOG kind %u of tab %llu: dismissed\n", event->kind, event->tab_id);
  assert(ReArcJavaScriptDialogRespond(event->request_id, false, nullptr) ==
         REARC_OK);
}

static void ready(void*, uint64_t profile) {
  profile_id = profile;
  printf("ENGINE bridge %s ABI 1.%u tab_freeze=%d\n", ReArcEngineBridgeVersion(),
         ReArcEngineABIMinorVersion(), ReArcEngineHasFeature("tab_freeze"));
  assert(ReArcEngineABIMinorVersion() >= 71 &&
         ReArcEngineHasFeature("tab_freeze"));
  ReArcEngineSetJavaScriptDialogCallback(dialog, nullptr);
  ReArcEngineSetPermissionCallback(permission, nullptr);
  ReArcEngineSetDownloadCallback(download, nullptr);
  ReArcEngineSetDisplayCaptureCallback(display_capture, nullptr);
  assert(ReArcDownloadSetPolicy(profile, downloads.c_str(), 0) == REARC_OK);
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
  printf("WINDOW frame %s on screen %d\n",
         NSStringFromRect(window.frame).UTF8String, window.screen != nil);
  const std::string url = base + "/freeze";
  assert(ReArcTabCreate(profile, 1, (url + "?front").c_str(), &front) == 0);
  assert(ReArcTabCreate(profile, 1, (url + "?idle").c_str(), &idle) == 0);
  assert(ReArcTabCreate(profile, 1, (url + "?walked").c_str(), &walked) == 0);
  assert(ReArcTabCreate(profile, 1, (url + "?loud").c_str(), &loud) == 0);
  assert(ReArcTabCreate(profile, 1, (url + "?guarded").c_str(), &guarded) == 0);
  assert(ReArcTabCreate(profile, 1, (url + "?shared").c_str(), &shared) == 0);
  assert(ReArcTabCreate(profile, 1, (url + "?armed").c_str(), &armed) == 0);
  assert(ReArcTabCreate(profile, 1, (url + "?loader").c_str(), &loader) == 0);
  attach(front, &front_lease);
  attach(walked, &walked_lease);
}

int main(int argc, const char** argv) {
  @autoreleasepool {
    setbuf(stdout, nullptr);
    // No Dock tile and no menu bar, before Chromium makes the application.
    ProcessSerialNumber process = {0, kCurrentProcess};
    TransformProcessType(&process, kProcessTransformToUIElementApplication);
    base = "http://127.0.0.1:" + std::string(getenv("REARC_TEST_PORT"));
    assert(getenv("REARC_DOWNLOAD_DIR"));
    downloads = getenv("REARC_DOWNLOAD_DIR");
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

// "This Mac" passkeys (local_passkeys, ABI 1.72, engine patch tab/104): the list and the delete
// on a host that is not signed with the keychain access group, which is every test host. The
// profile authenticator is unavailable here, so the engine must say so, list nothing and
// refuse to delete, without asking the keychain. No passkey is made, listed or deleted: a
// test must never reach one in the real login keychain (security review PK-08).
// (The profile's metadata secret says nothing here: Chromium writes it when a profile
// starts, for its profile statistics, in every build.)
//
// No window, no tab, no page: nothing appears on screen and the front app does not change.
#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>

static uint64_t profile, private_profile;
static int delivered;
static bool in_call, stopped;

static void never(void*, ReArcStatus, uint64_t, const char*) {
  assert(!"a refused call must not run its completion");
}

static void shutdown_done(void*, ReArcStatus status, bool cancelled) {
  assert(status == REARC_OK && !cancelled);
  stopped = true;
  puts("LOCAL_PASSKEYS unavailable host: empty list, delete refused, arguments, private profile PASS");
}

static void private_closed(void*, ReArcStatus status, bool cancelled) {
  assert(status == REARC_OK && !cancelled);
  assert(ReArcProfileGetLocalPasskeys(private_profile, never, nullptr) == REARC_PROFILE_NOT_FOUND);
  assert(ReArcEngineShutdown(true, shutdown_done, nullptr) == REARC_OK);
}

static void private_opened(void*, ReArcStatus status, uint64_t id, bool off_the_record) {
  assert(status == REARC_OK && off_the_record && id && id != profile);
  private_profile = id;
  // A private profile uses its original profile's passkeys and has none of its own.
  assert(ReArcProfileGetLocalPasskeys(id, never, nullptr) == REARC_UNSUPPORTED);
  assert(ReArcProfileDeleteLocalPasskey(id, "00ff", never, nullptr) == REARC_UNSUPPORTED);
  assert(ReArcProfileClose(id, true, private_closed, nullptr) == REARC_OK);
}

static void listed(void* context, ReArcStatus status, uint64_t id, const char* json) {
  assert(!in_call);  // Deferred: never from inside the call that asked.
  assert(context == &delivered && status == REARC_OK && id == profile && json);
  fprintf(stderr, "LOCAL_PASSKEYS list %d: %s\n", delivered, json);
  assert(std::string(json) == "{\"available\":false,\"passkeys\":[]}");
  if (++delivered < 2) {
    return;
  }
  assert(ReArcProfileCreateOffTheRecord(profile, private_opened, nullptr) == REARC_OK);
}

static void ready(void*, uint64_t id) {
  profile = id;
  assert(ReArcEngineABIMinorVersion() >= 72 && ReArcEngineHasFeature("local_passkeys"));

  // Refused at once, and then no completion.
  assert(ReArcProfileGetLocalPasskeys(id, nullptr, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcProfileGetLocalPasskeys(id + 1000, never, nullptr) == REARC_PROFILE_NOT_FOUND);
  assert(ReArcProfileGetLocalPasskeys(0, never, nullptr) == REARC_PROFILE_NOT_FOUND);
  assert(ReArcProfileDeleteLocalPasskey(id, "00ff", nullptr, nullptr) == REARC_INVALID_ARGUMENT);
  for (const char* bad : {(const char*)nullptr, "", "0", "abc", "zz", "00 ff", "0x00ff", "../../Default"}) {
    assert(ReArcProfileDeleteLocalPasskey(id, bad, never, nullptr) == REARC_INVALID_ARGUMENT);
  }
  assert(ReArcProfileDeleteLocalPasskey(id, std::string(2 * 1025, 'a').c_str(), never, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcProfileDeleteLocalPasskey(id + 1000, "00ff", never, nullptr) == REARC_PROFILE_NOT_FOUND);
  // A well-formed ID of the longest size: this host has no profile authenticator, so there
  // is nothing to delete from, and the keychain is not asked.
  assert(ReArcProfileDeleteLocalPasskey(id, "00ff", never, nullptr) == REARC_UNSUPPORTED);
  assert(ReArcProfileDeleteLocalPasskey(id, std::string(2 * 1024, 'a').c_str(), never, nullptr) == REARC_UNSUPPORTED);

  // The list: accepted, answered later, exactly once per call.
  in_call = true;
  assert(ReArcProfileGetLocalPasskeys(id, listed, &delivered) == REARC_OK);
  assert(ReArcProfileGetLocalPasskeys(id, listed, &delivered) == REARC_OK);
  in_call = false;
  assert(delivered == 0);
}

int main(int argc, const char** argv) {
  @autoreleasepool {
    setbuf(stdout, nullptr);
    // No Dock tile and no menu bar: this host shows nothing.
    ProcessSerialNumber process = {0, kCurrentProcess};
    TransformProcessType(&process, kProcessTransformToUIElementApplication);
    ReArcCallbacks callbacks{ready, nullptr, nullptr, nullptr};
    assert(ReArcEngineConfigure(1, &callbacks, nullptr) == REARC_OK);
    // A release engine drops --host-resolver-rules without this, and the host would go online.
    assert(ReArcEngineAllowTestSwitches() == REARC_OK);
    int result = ReArcEngineRun(argc, argv);
    assert(result == 0 && stopped && delivered == 2);
    return result;
  }
}

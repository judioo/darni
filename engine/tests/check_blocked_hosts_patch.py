#!/usr/bin/env python3
"""tab/098 (the sites behind a tab's blocked count), security BL-01, BL-05, BL-06, BL-07.

The patch keeps, for "ReArc Blocker" only, the site of each blocked request beside the tab's
action count in declarativeNetRequest's ActionTracker. What a person's pages ask for is
sensitive, so the review set conditions (security/PRE-blocked-list.md) that the code must go on
meeting. The overlay has no C++ unit tests, so this reads the patch, as
check_content_blocker_manifest.py does for tab/095:

- The tracker keeps sites for the two blocker IDs and no other, and the IDs are compiled in:
  the same two strings as rearc::kContentBlockerExtensionIds, compared as literals, with nothing
  a preference, a switch or a call could change (BL-05).
- A site is kept only where the action count is incremented, which is never for the unknown
  tab ID, and the code that moves matched rules to that ID is not changed (BL-01).
- The limits are in the code (BL-06), and no added line logs, records a histogram or writes a
  preference or a file (BL-07).
- The patch touches the tracker and the bridge only, and nothing of the blocker's manifest
  (security CB-03).

No engine checkout and no build are needed.

Run: python3 engine/tests/check_blocked_hosts_patch.py
"""
from pathlib import Path
import re
import sys
import unittest

# The sibling test's helpers, also when Python runs isolated (-I) and leaves the script's folder out.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_content_blocker_manifest import FORBIDDEN_LITERALS, function_body, string_literals  # noqa: E402

PATCHES = Path(__file__).resolve().parents[1] / "patches" / "tab"
BLOCKER_PATCH = PATCHES / "095-content-blocker-component.patch"
PATCH = PATCHES / "098-blocked-hosts.patch"
TRACKER = "extensions/browser/api/declarative_net_request/action_tracker.cc"
TRACKER_HEADER = "extensions/browser/api/declarative_net_request/action_tracker.h"
BRIDGE = "chrome/browser/rearc_bridge/rearc_content_blocker.cc"
TOUCHED = {
    "chrome/app/framework.exports", "chrome/app/framework.order", BRIDGE,
    "chrome/browser/rearc_bridge/rearc_engine_abi.h", "chrome/browser/rearc_bridge/rearc_engine_abi.mm",
    "chrome/browser/rearc_bridge/rearc_engine_entry_mac.mm", TRACKER, TRACKER_HEADER,
}
# What would take a site out of memory. None may be in a line the patch adds to the tracker or
# to the bridge. (The bridge's reply to the host is the one way out, and it is JSON in memory.)
LEAKS = ("LOG(", "VLOG(", "DVLOG(", "DLOG(", "PLOG(", "SYSLOG(", "UMA_", "UmaHistogram", "base::debug", "TRACE_EVENT",
         "ExtensionPrefs", "PrefService", "prefs::", "WriteFile", "ImportantFileWriter", "CommandLine", "FeatureList",
         "EventRouter", "DispatchEvent", "url_loader", "SimpleURLLoader")


def file_diff(patch_text, path):
    """The hunks of one file in the patch."""
    start = patch_text.index(f"diff --git a/{path} b/{path}\n")
    end = patch_text.find("\ndiff --git ", start + 1)
    return patch_text[start:] if end < 0 else patch_text[start:end]


def changed(diff, sign):
    """The lines a file's diff adds (`+`) or removes (`-`), without the sign."""
    return [line[1:] for line in diff.split("\n") if line.startswith(sign) and not line.startswith(sign * 3)]


class BlockedHostsPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.patch = PATCH.read_text()
        cls.tracker = "\n".join(changed(file_diff(cls.patch, TRACKER), "+"))
        cls.header = "\n".join(changed(file_diff(cls.patch, TRACKER_HEADER), "+"))
        cls.bridge = "\n".join(changed(file_diff(cls.patch, BRIDGE), "+"))

    def test_the_patch_touches_the_tracker_and_the_bridge_only(self):
        self.assertEqual(set(re.findall(r"^diff --git a/(\S+) b/", self.patch, re.M)), TOUCHED)
        self.assertNotIn("new file mode", self.patch)

    def test_sites_are_kept_for_the_two_blocker_ids_and_they_are_compiled_in(self):
        keeps = function_body(self.tracker, "bool KeepsBlockedSites(")
        ids = string_literals(keeps)
        blocker = BLOCKER_PATCH.read_text()
        declared = blocker[blocker.index("kContentBlockerExtensionIds = {"):]
        self.assertEqual(ids, string_literals(declared[:declared.index("};")]))
        self.assertEqual(len(ids), 2)
        # Two comparisons of the argument with a literal, and nothing else that could say yes.
        code = re.sub(r"\s+", " ", keeps).strip()
        self.assertEqual(code, f'return extension_id == "{ids[0]}" || extension_id == "{ids[1]}";')
        self.assertEqual(self.tracker.count("KeepsBlockedSites("), 3, "its definition and its two uses")

    def test_a_site_is_kept_only_where_the_action_count_is_incremented(self):
        self.assertIn("const bool keep_blocked_site =\n      increment_action_count && KeepsBlockedSites(extension_id);", self.tracker)
        calls = re.findall(r"if \(keep_blocked_site\) \{\s*RecordBlockedSite\((\w+)\.blocked, request_info\.url,\s*request_action\.ruleset_id\);",
                           self.tracker)
        self.assertEqual(calls, ["pending_info", "tracked_info"])
        self.assertEqual(self.tracker.count("RecordBlockedSite("), 3, "its definition and those two calls")
        # Upstream's own lines: the count is not incremented for the unknown tab ID (BL-01).
        diff = file_diff(self.patch, TRACKER)
        self.assertIn("       tab_id != extension_misc::kUnknownTabId &&\n       !request_action.IsAllowOrAllowAllRequests();", diff)
        self.assertIn("     if (increment_action_count) {\n       pending_info.action_count++;\n+      if (keep_blocked_site) {", diff)
        self.assertIn("   size_t action_count = ++tracked_info.action_count;\n+  if (keep_blocked_site) {", diff)

    def test_upstreams_resets_and_clears_are_not_changed(self):
        for path in (TRACKER, TRACKER_HEADER):
            diff = file_diff(self.patch, path)
            self.assertEqual(changed(diff, "-"), [], f"{path}: the patch only adds lines")
        # Moving entries to the unknown tab ID would let them outlive every page.
        for name in ("TransferRulesOnTabInvalid", "unknown_tab_info", "ResetTrackedInfoForTab(", "ClearTabData(", "ClearExtensionData(",
                     "pending_navigation_actions_", "splice("):
            self.assertNotIn(name, self.tracker, name)
        read = function_body(self.tracker, "ActionTracker::BlockedSites ActionTracker::GetBlockedSites(")
        self.assertIn("if (tab_id == extension_misc::kUnknownTabId ||\n      !KeepsBlockedSites(extension_id)) {\n    return BlockedSites();", read)

    def test_the_limits_are_in_the_code(self):
        self.assertIn("static constexpr size_t kMaxBlockedSites = 100;", self.header)
        self.assertIn("static constexpr size_t kMaxBlockedSiteBytes = 253;", self.header)
        self.assertIn("static constexpr size_t kMaxBlockedSiteRulesets = 8;", self.header)
        record = function_body(self.tracker, "void RecordBlockedSite(")
        self.assertIn("if (blocked.sites.size() >= ActionTracker::kMaxBlockedSites) {\n      IncrementUpToMax(blocked.more);\n      return;", record)
        self.assertIn("entry->rulesets.size() < ActionTracker::kMaxBlockedSiteRulesets", record)
        name = function_body(self.tracker, "std::optional<BlockedSiteName> BlockedSiteNameOf(")
        self.assertIn("if (site.name.size() > ActionTracker::kMaxBlockedSiteBytes) {\n    return std::nullopt;", name)
        self.assertIn("net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES", name)
        self.assertIn("site.is_one_site = !site.name.empty();", name, "a name with no registrable domain is not one site")
        self.assertIn("if (count < std::numeric_limits<uint32_t>::max()) {\n    ++count;", function_body(self.tracker, "void IncrementUpToMax("))
        merged = function_body(self.bridge, "std::string BlockedHostsJson(")
        self.assertIn("if (sites.size() >= dnr::ActionTracker::kMaxBlockedSites) {\n          more += from.count;\n          continue;", merged)
        self.assertEqual(merged.count("base::saturated_cast<int>("), 2, "a count and the remainder cannot wrap in the reply")

    def test_only_the_host_of_a_request_is_read(self):
        name = function_body(self.tracker, "std::optional<BlockedSiteName> BlockedSiteNameOf(")
        self.assertEqual(set(re.findall(r"\burl\.(\w+)\(", name)), {"is_valid", "has_host", "host", "HostIsIPAddress"})
        for part in ("spec", "path", "query", "ref", "GetContent", "PathForRequest", "possibly_invalid_spec"):
            self.assertNotIn(f"url.{part}(", self.tracker, part)
        # A request's address is the tracker's alone: the bridge never sees one.
        for request in ("request_info", "WebRequestInfo", "RequestAction"):
            self.assertNotIn(request, self.bridge, request)
        self.assertEqual(len(re.findall(r"request_info\.(\w+)", self.tracker)), 2)
        self.assertEqual(set(re.findall(r"request_info\.(\w+)", self.tracker)), {"url"})

    def test_the_pages_own_site_is_the_committed_one_named_as_a_blocked_site_is(self):
        # Security BL-10, BL-11: the host writes "allow this host on this site" from two names of
        # one reply. The page's must be the committed address (never a pending one), from the
        # same function, and so the same public suffix list, as a blocked site's.
        reply = function_body(self.bridge, "std::string BlockedHostsJson(")
        self.assertIn("const GURL& page = contents->GetLastCommittedURL();", reply)
        for pending in ("GetVisibleURL", "GetURL()", "GetPendingEntry", "GetVirtualURL"):
            self.assertNotIn(pending, self.bridge, pending)
        self.assertIn("if (page.SchemeIsHTTPOrHTTPS() &&\n        dnr::ActionTracker::GetSiteOfUrl(page, &page_site, &page_is_one_site)) {", reply)
        site = function_body(self.tracker, "bool ActionTracker::GetSiteOfUrl(")
        self.assertIn("std::optional<BlockedSiteName> name = BlockedSiteNameOf(url);", site)
        self.assertEqual(self.tracker.count("BlockedSiteNameOf("), 3, "its definition, a blocked request's site and the page's")

    def test_the_site_of_a_host_takes_a_plain_host_and_gives_the_trackers_answer(self):
        # ReArcEngineCopySiteOfHost: the text is the host's own (a typed exception, a boost file's
        # scope), so nothing but a host name may become an address, and the name it gets is the
        # one a blocked request to that host would get.
        site = function_body(self.bridge, "std::optional<std::string> SiteOfHostJson(")
        self.assertIn("constexpr size_t kMaxHostBytes = 253;", site)
        self.assertIn("if (host.empty() || host.size() > kMaxHostBytes ||", site)
        self.assertIn("return base::IsAsciiAlphaNumeric(c) || c == '.' || c == '-' || c == '_';", site)
        self.assertIn('const GURL url(base::StrCat(\n      {url::kHttpScheme, url::kStandardSchemeSeparator, host, "/"}));', site)
        for refused in ("url.has_port()", "url.has_username()", "url.has_password()", 'url.path() != "/"', "url.has_query()", "url.has_ref()"):
            self.assertIn(refused, site, refused)
        self.assertIn("!dnr::ActionTracker::GetSiteOfUrl(url, &site, &is_one_site)) {\n    return std::nullopt;", site)
        # Whether the name is itself a suffix: asked only of a name that is not one site (so never
        # of an address), and only once the name is known to be canonical. Chromium's function
        # checks that itself and stops the process if not, and the text here is a file's or a person's.
        self.assertIn("if (!is_one_site) {", site)
        self.assertIn("net::CanonicalizeHost(site, &info) == site &&\n        info.family == url::CanonHostInfo::NEUTRAL &&\n"
                      "        net::registry_controlled_domains::HostIsRegistryIdentifier(\n"
                      "            site, net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);", site)
        self.assertEqual(self.bridge.count("HostIsRegistryIdentifier("), 1)
        call = function_body(self.bridge, "ReArcStatus ReArcEngineCopySiteOfHost(")
        self.assertIn("CHECK(pthread_main_np());", call)
        self.assertIn("return reply ? rearc::CopyReply(*reply, json) : REARC_INVALID_ARGUMENT;", call)
        # It asks no profile, tab or service: a lookup in the suffix list and nothing else.
        for state in ("Profile", "TabRegistry", "RulesMonitorService", "States()", "WebContents"):
            self.assertNotIn(state, site + call, state)

    def test_nothing_added_takes_a_site_out_of_memory(self):
        for leak in LEAKS:
            self.assertNotIn(leak, self.tracker, leak)
            self.assertNotIn(leak, self.header, leak)
            self.assertNotIn(leak, self.bridge, leak)

    def test_the_blockers_manifest_is_not_touched(self):
        diff = file_diff(self.patch, BRIDGE)
        self.assertEqual(changed(diff, "-"), [], "the bridge file only gains lines")
        for manifest in ("manifest.Set(", "permissions.Append(", "resource.Set(", "rulesets.Set(", "BlockerManifest(", "loader->Add("):
            self.assertNotIn(manifest, self.bridge, manifest)
        # The text the bridge gains: its includes and the empty reply apart, only the reply's keys.
        empty_reply = 'R"({"hosts":[],"more":0})"'
        self.assertEqual(self.bridge.count(empty_reply), 1)
        code = re.sub(r"^#include [^\n]*$", "", self.bridge, flags=re.M).replace(empty_reply, "")
        self.assertEqual(set(string_literals(code)) & FORBIDDEN_LITERALS, set())
        # "/" ends the address ReArcEngineCopySiteOfHost makes of a host name.
        self.assertEqual(set(string_literals(code)), {"page", "host", "count", "registrable", "suffix", "lists", "hosts", "more", "/"})

    def test_the_call_is_exported_and_advertised(self):
        for path in ("chrome/app/framework.exports", "chrome/app/framework.order"):
            self.assertEqual(changed(file_diff(self.patch, path), "+"), ["_ReArcTabCopyBlockedHosts", "_ReArcEngineCopySiteOfHost"])
        self.assertIn('std::string(feature) == "content_blocking_hosts" ||', self.patch)
        self.assertIn('std::string(feature) == "host_sites" ||', self.patch)
        self.assertIn("REARC_ABI_MINOR_VERSION = 69", self.patch)
        self.assertIn('return "0.79.0";', self.patch)
        call = function_body(self.bridge, "ReArcStatus ReArcTabCopyBlockedHosts(")
        self.assertIn("CHECK(pthread_main_np());", call)
        self.assertIn("if (!json) {\n    return REARC_INVALID_ARGUMENT;", call)


if __name__ == "__main__":
    unittest.main()

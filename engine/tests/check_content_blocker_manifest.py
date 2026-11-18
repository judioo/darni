#!/usr/bin/env python3
"""tab/095 (content blocking), security CB-03: what the built-in blocker may touch.

The engine builds the manifest of "ReArc Blocker" in code (BlockerManifest in
rearc_content_blocker.cc). It must ask for declarativeNetRequest and nothing else: no host
permissions, no content scripts, no background script, no pages.

Why this is a test. A declarativeNetRequest rule that redirects a request or changes headers
only takes effect for an extension with access to the request's site (Chromium:
CompositeMatcher::GetAction, RulesetManager::GetModifyHeadersActions). The blocker has none, so
a signed list can block and allow and nothing else, and the blocker cannot read or change a
page. One added manifest key ends both. Phase 2 (per-site CSS) will need access to pages: the
change must then come with the security review, and with PrepareBundle's check that every rule
of a bundle is block, allow or allowAllRequests, which this test also holds in place.

The overlay has no C++ unit tests, so this reads the patch: the manifest is built from string
literals, and the test fails when a key or a permission is added, or when the rule check goes.
No engine checkout and no build are needed.

Run: python3 engine/tests/check_content_blocker_manifest.py
"""
from pathlib import Path
import re
import unittest

PATCH = Path(__file__).resolve().parents[1] / "patches" / "tab" / "095-content-blocker-component.patch"
SOURCE = "chrome/browser/rearc_bridge/rearc_content_blocker.cc"

# Every key the manifest may have. A key that is not here fails the test.
ALLOWED_MANIFEST_KEYS = {
    "manifest_version", "name", "description", "version", "key", "incognito", "permissions",
    "declarative_net_request",
}
ALLOWED_PERMISSIONS = {"declarativeNetRequest"}
ALLOWED_RULESET_KEYS = {"id", "enabled", "path"}
# Manifest keys and permissions that give an extension access to pages, requests or the person's
# data. None may appear anywhere in the file as a string literal. ("action", the toolbar button,
# is not here: a rule has a key of that name. The list of allowed keys keeps it out.)
FORBIDDEN_LITERALS = {
    "host_permissions", "optional_host_permissions", "optional_permissions", "content_scripts",
    "background", "web_accessible_resources", "externally_connectable", "browser_action",
    "page_action", "devtools_page", "options_page", "options_ui", "chrome_url_overrides",
    "sandbox", "content_security_policy", "side_panel", "update_url",
    "declarativeNetRequestWithHostAccess", "declarativeNetRequestFeedback", "webRequest",
    "webRequestBlocking", "scripting", "activeTab", "tabs", "cookies", "debugger", "proxy",
    "nativeMessaging", "<all_urls>", "*://*/*", "http://*/*", "https://*/*",
}


def added_file(patch_text, path):
    """The text of a file the patch adds, without the diff's leading `+`."""
    start = patch_text.index(f"diff --git a/{path} b/{path}\nnew file mode")
    body = patch_text[start:].split("\n@@ ", 1)[1].split("\n", 1)[1]
    end = body.find("\ndiff --git ")
    lines = (body if end < 0 else body[:end]).split("\n")
    assert all(line.startswith("+") for line in lines if line), "a new file's hunk has only added lines"
    return "\n".join(line[1:] for line in lines)


def function_body(source, signature):
    """The body of the function whose definition starts with `signature`."""
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        depth += {"{": 1, "}": -1}.get(source[index], 0)
        if depth == 0:
            return source[brace + 1:index]
    raise AssertionError(f"{signature}: no closing brace")


def string_literals(code):
    """The string literals of C++ code, comments left out."""
    code = re.sub(r"//[^\n]*", "", code)
    return re.findall(r'"((?:[^"\\]|\\.)*)"', code)


class ContentBlockerManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = added_file(PATCH.read_text(), SOURCE)
        cls.manifest = function_body(cls.source, "base::DictValue BlockerManifest(")

    def test_the_manifest_has_only_the_keys_a_blocker_needs(self):
        keys = set(re.findall(r'\bmanifest\.Set\(\s*"([^"]+)"', self.manifest))
        self.assertEqual(keys, ALLOWED_MANIFEST_KEYS)
        # Nothing reaches the manifest another way (a merged dictionary, a path, a parsed string).
        self.assertEqual(len(re.findall(r"\bmanifest\.\w+\(", self.manifest)),
                         len(re.findall(r'\bmanifest\.Set\(\s*"', self.manifest)))
        for other in ("SetByDottedPath", "Merge", "JSONReader", "FromJson"):
            self.assertNotIn(other, self.manifest)

    def test_the_only_permission_is_declarative_net_request(self):
        appended = re.findall(r"\bpermissions\.Append\(([^)]*)\)", self.manifest)
        self.assertEqual(appended, ['"declarativeNetRequest"'])
        self.assertEqual(set(string_literals(" ".join(appended))), ALLOWED_PERMISSIONS)
        self.assertIn('manifest.Set("permissions", std::move(permissions));', self.manifest)

    def test_there_are_no_host_permissions_and_no_content_scripts(self):
        literals = set(string_literals(self.source))
        self.assertEqual(literals & FORBIDDEN_LITERALS, set())
        for literal in literals:
            self.assertNotIn("://*", literal, "a match pattern")

    def test_a_ruleset_entry_names_a_file_and_is_off(self):
        keys = set(re.findall(r'\bresource\.Set\(\s*"([^"]+)"', self.manifest))
        self.assertEqual(keys, ALLOWED_RULESET_KEYS)
        self.assertIn('resource.Set("enabled", false);', self.manifest)
        self.assertIn('resource.Set("path", "rules/" + list.id + ".json");', self.manifest)
        self.assertEqual(set(re.findall(r'\brulesets\.Set\(\s*"([^"]+)"', self.manifest)), {"rule_resources"})

    def test_the_manifest_is_built_in_one_place_and_loaded_as_built(self):
        self.assertEqual(self.source.count("base::DictValue BlockerManifest("), 1)
        self.assertEqual(len(re.findall(r"\bloader->Add\(", self.source)), 1)
        self.assertIn("loader->Add(BlockerManifest(*bundle, slot), bundle->directory)", self.source)

    def test_both_blockers_have_the_same_manifest_but_for_the_key(self):
        # The second blocker exists for list updates (CB-02); it gets no more than the first.
        self.assertIn('manifest.Set("key", kManifestKeys[slot]);', self.manifest)
        self.assertEqual(len(re.findall(r"\bslot\b", self.manifest)), 1)

    def test_a_bundle_whose_rules_do_more_than_block_or_allow_is_refused(self):
        allowed = function_body(self.source, "bool IsBlockOrAllow(")
        self.assertEqual(set(string_literals(allowed)), {"block", "allow", "allowAllRequests"})
        check = function_body(self.source, "bool OnlyBlocksAndAllows(")
        self.assertIn("base::JSON_PARSE_RFC", check)
        self.assertIn('FindStringByDottedPath("action.type")', check)
        self.assertIn("if (!action || !IsBlockOrAllow(*action)) {\n      return false;", check)
        prepare = function_body(self.source, "std::optional<Bundle> PrepareBundle(")
        # Every rules file goes through the check, and what is written is what was checked.
        self.assertIn("!OnlyBlocksAndAllows(text) ||", prepare)
        self.assertIn("base::WriteFile(rules.AppendASCII(name), text)", prepare)
        self.assertNotIn("CopyFile", self.source)

    def test_own_rules_are_held_to_the_same_actions(self):
        own = self.source[self.source.index("ReArcStatus ReArcProfileSetOwnBlockingRules("):]
        self.assertIn("if (!action || !rearc::IsBlockOrAllow(*action)) {\n      return REARC_INVALID_ARGUMENT;", own)


if __name__ == "__main__":
    unittest.main()

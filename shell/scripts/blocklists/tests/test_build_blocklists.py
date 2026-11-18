"""The blocklist builder (build-blocklists.py): filter conversion against golden files, dropped
filter counts, Chromium's DNR limits, the Ed25519 signature and the bundle's file hashes, and
what the build refuses to sign (security CB-04): filters for every site, a list whose counts
jumped, and a fetch that left https.
No network: lists come from golden files and throwaway directories, keys are made per test.

Run: python3 -m unittest discover -s shell/scripts/blocklists/tests
REARC_UPDATE_GOLDEN=1 rewrites golden/*.json from the converter; read the diff before committing.
"""
import base64
import datetime
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "build-blocklists.py"
GOLDEN = Path(__file__).resolve().parent / "golden"
REPO = Path(__file__).resolve().parents[4]
spec = importlib.util.spec_from_file_location("build_blocklists", SCRIPT)
bb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bb)

NOW = datetime.datetime(2026, 11, 18, 9, 30, tzinfo=datetime.timezone.utc)
LISTS = [
    {"id": "trackers", "title": "Trackers", "homepage": "https://example.org/", "license": "CC0-1.0",
     "url": "https://example.org/trackers.txt", "format": "abp", "level": 1},
    {"id": "ads", "title": "Ads", "homepage": "https://example.org/", "license": "CC0-1.0",
     "url": "https://example.org/ads.txt", "format": "abp", "level": 2},
]
RAW = {
    "trackers": "! Version: 7\n||tracker.example^\n||metrics.example^$third-party\n/pixel.gif?$image\n",
    "ads": "! Version: 9\n||ads.example^\n@@||ads.example/ok/\n/banner\\d+/\n##.ad\n||x.example^$csp=default-src\n",
}


def rule(text):
    """The single rule of one filter, without the fixed parts tests do not look at."""
    rules = bb.convert_network_filter(text)
    assert len(rules) == 1, rules
    return rules[0]


def run(*args, env=None):
    return subprocess.run([sys.executable, "-I", str(SCRIPT), *map(str, args)], capture_output=True,
                          text=True, env=env)


class TemporaryDirectoryCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="rearc-blocklists-test."))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def raw_dir(self, raw=None):
        directory = self.tmp / "raw-in"
        directory.mkdir(exist_ok=True)
        for name, text in (raw or RAW).items():
            (directory / f"{name}.txt").write_text(text)
        return directory

    def key(self, name="signing.key"):
        path = self.tmp / "keys" / name
        self.assertTrue(bb.generate_key(path))
        return path

    def bundle(self, name="bundle", key=None, raw=None, lists=LISTS, **options):
        out = self.tmp / name
        manifest = bb.build_bundle(out, lists, key=key, raw_dir=self.raw_dir(raw), now=NOW,
                                   log=lambda _: None, **options)
        return out, manifest


class GoldenTests(unittest.TestCase):
    """Every supported filter form, and every dropped one, in golden/forms.txt."""

    def check(self, name, list_format):
        rules, stats, header = bb.convert_list((GOLDEN / f"{name}.txt").read_text(), list_format)
        bb.validate_rules(rules)
        actual_rules = bb.rules_json(rules)
        actual_stats = json.dumps({"stats": stats, "header": header}, indent=1) + "\n"
        if os.environ.get("REARC_UPDATE_GOLDEN"):
            (GOLDEN / f"{name}.json").write_bytes(actual_rules)
            (GOLDEN / f"{name}.stats.json").write_text(actual_stats)
        self.assertEqual(actual_rules.decode(), (GOLDEN / f"{name}.json").read_text())
        self.assertEqual(actual_stats, (GOLDEN / f"{name}.stats.json").read_text())
        return rules, stats

    def test_adblock_filter_forms(self):
        rules, stats = self.check("forms", "abp")
        # Every network filter is converted, a duplicate, or dropped under a reason.
        self.assertEqual(stats["network"],
                         stats["converted"] + stats["duplicate"] + sum(stats["dropped"].values()))
        self.assertEqual(json.loads(bb.rules_json(rules)), rules)

    def test_hosts_file(self):
        rules, stats = self.check("hosts", "hosts")
        self.assertEqual(len(rules), 1)
        self.assertEqual(stats["dropped"], {"invalid": 6})

    def test_the_golden_list_covers_every_drop_reason_the_converter_has(self):
        stats = json.loads((GOLDEN / "forms.stats.json").read_text())["stats"]
        reasons = set(bb.UNSUPPORTED_OPTIONS.values()) | set(bb.UNSUPPORTED_TYPES.values()) | {
            "badfilter", "cosmetic-exception", "domain-pattern", "invalid", "regex-unsupported",
            "too-broad", "unknown-option"}
        self.assertEqual(reasons - set(stats["dropped"]), set())


class FilterFormTests(unittest.TestCase):
    def test_a_whole_host_becomes_a_request_domain(self):
        self.assertEqual(rule("||ads.example^"), {
            "priority": 1, "action": {"type": "block"}, "condition": {"requestDomains": ["ads.example"]}})

    def test_a_host_with_a_path_or_no_separator_stays_a_url_filter(self):
        self.assertEqual(rule("||ads.example/x")["condition"], {"urlFilter": "||ads.example/x"})
        self.assertEqual(rule("||ads.example")["condition"], {"urlFilter": "||ads.example"})

    def test_third_party_and_first_party(self):
        self.assertEqual(rule("/ads.js$third-party")["condition"]["domainType"], "thirdParty")
        self.assertEqual(rule("/ads.js$~third-party")["condition"]["domainType"], "firstParty")
        self.assertEqual(rule("/ads.js$1p")["condition"]["domainType"], "firstParty")
        self.assertEqual(rule("/ads.js$~first-party")["condition"]["domainType"], "thirdParty")

    def test_domain_option_becomes_initiator_domains(self):
        condition = rule("/a$domain=b.example|~c.b.example|A.example")["condition"]
        self.assertEqual(condition["initiatorDomains"], ["a.example", "b.example"])
        self.assertEqual(condition["excludedInitiatorDomains"], ["c.b.example"])

    def test_resource_types(self):
        self.assertEqual(rule("/a$script,image")["condition"]["resourceTypes"], ["script", "image"])
        self.assertEqual(rule("/ads.js$xmlhttprequest,subdocument")["condition"]["resourceTypes"],
                         ["sub_frame", "xmlhttprequest"])

    def test_only_excluded_types_never_reach_the_main_frame(self):
        # DNR would match main_frame once excludedResourceTypes is given without it.
        self.assertEqual(rule("/ads.js$~script")["condition"]["excludedResourceTypes"], ["main_frame", "script"])

    def test_no_types_leaves_dnr_default_which_skips_the_main_frame(self):
        self.assertNotIn("resourceTypes", rule("/ads.js")["condition"])
        self.assertNotIn("excludedResourceTypes", rule("/ads.js")["condition"])

    def test_exception_is_an_allow_rule_above_block_rules(self):
        allow = rule("@@||ads.example/ok/")
        self.assertEqual(allow["action"], {"type": "allow"})
        self.assertGreater(allow["priority"], rule("||ads.example/ok/")["priority"])

    def test_important_beats_exceptions(self):
        self.assertGreater(rule("/ads.js$important")["priority"], rule("@@/ads.js")["priority"])
        self.assertGreater(rule("@@/ads.js$important")["priority"], rule("/ads.js$important")["priority"])

    def test_list_priorities_stay_below_the_site_exception_priority(self):
        self.assertLess(bb.PRIORITY_IMPORTANT_ALLOW, bb.PRIORITY_SITE_EXCEPTION)

    def test_document_exception_allows_everything_on_the_page(self):
        rules = bb.convert_network_filter("@@||page.example^$document")
        self.assertEqual(rules, [{
            "priority": 2, "action": {"type": "allowAllRequests"},
            "condition": {"requestDomains": ["page.example"], "resourceTypes": ["main_frame"]}}])

    def test_document_exception_with_another_type_is_two_rules(self):
        rules = bb.convert_network_filter("@@||page.example^$document,script")
        self.assertEqual([entry["action"]["type"] for entry in rules], ["allowAllRequests", "allow"])
        self.assertEqual(rules[1]["condition"]["resourceTypes"], ["script"])

    def test_match_case(self):
        self.assertIs(rule("/Path$match-case")["condition"]["isUrlFilterCaseSensitive"], True)
        self.assertNotIn("isUrlFilterCaseSensitive", rule("/Path")["condition"])
        self.assertNotIn("isUrlFilterCaseSensitive", rule("||host.example^$match-case")["condition"])

    def test_regular_expression(self):
        self.assertEqual(rule(r"/banner\d+/")["condition"], {"regexFilter": r"banner\d+"})
        self.assertEqual(rule(r"/ads\.js$/")["condition"], {"regexFilter": r"ads\.js$"})
        self.assertEqual(rule(r"/x\d$/$script")["condition"],
                         {"regexFilter": r"x\d$", "resourceTypes": ["script"]})

    def test_wildcards_at_the_ends_are_removed(self):
        self.assertEqual(rule("*/ads/*")["condition"], {"urlFilter": "/ads/"})
        self.assertEqual(rule("||*.ads.example/x")["condition"], {"urlFilter": ".ads.example/x"})

    def test_international_names_are_punycode_and_paths_percent_encoded(self):
        self.assertEqual(rule("||bücher.example^")["condition"], {"requestDomains": ["xn--bcher-kva.example"]})
        self.assertEqual(rule("||bücher.example/ä")["condition"], {"urlFilter": "||xn--bcher-kva.example/%C3%A4"})
        self.assertEqual(rule("/a$domain=bücher.example")["condition"]["initiatorDomains"],
                         ["xn--bcher-kva.example"])

    def test_dropped_filters_name_their_reason(self):
        cases = {
            "||a.example^$csp=default-src 'none'": "csp",
            "||a.example^$redirect=noopjs": "redirect",
            "||a.example^$redirect-rule=noopjs": "redirect",
            "||a.example^$removeparam=utm_source": "removeparam",
            "$removeparam=/^utm_/": "removeparam",
            "||a.example^$popup": "popup",
            "||a.example^$webrtc": "webrtc",
            "||a.example^$object-subrequest": "object-subrequest",
            "||a.example^$header=x": "header",
            "||a.example^$nonsense": "unknown-option",
            "/a(?=b)/": "regex-unsupported",
            "/(a)\\1/": "regex-unsupported",
            "/a$domain=~shop.*": "domain-pattern",
            "/a$domain=shop.*": "domain-pattern",
            "$third-party": "too-broad",
            "@@||a.example^$elemhide": "cosmetic-exception",
            "@@||a.example^$genericblock": "genericblock",
            "||a b.example^": "invalid",
            "||a.example^$elemhide": "invalid",
            "||a.example^$badfilter": "badfilter",
        }
        for text, reason in cases.items():
            with self.subTest(text), self.assertRaises(bb.Dropped) as dropped:
                bb.convert_network_filter(text)
            self.assertEqual(dropped.exception.reason, reason, text)

    def test_cosmetic_filters_are_counted_not_converted(self):
        rules, stats, _ = bb.convert_list(
            "##.ad\nexample.com#@#.ad\nexample.com#?#div:-abp-has(.x)\nexample.com##+js(nowoif)\n")
        self.assertEqual(rules, [])
        self.assertEqual(stats["network"], 0)
        self.assertEqual(stats["cosmetic"], {"hide": 1, "exception": 1, "procedural": 1, "scriptlet": 1})

    def test_duplicates_are_counted_once(self):
        rules, stats, _ = bb.convert_list("/ads.js\n/ads.js\n||b.example^\n||B.example^\n")
        self.assertEqual(len(rules), 2)
        self.assertEqual((stats["converted"], stats["duplicate"]), (2, 2))

    def test_hosts_merge_only_with_the_same_options(self):
        rules, _, _ = bb.convert_list("||a.example^\n||b.example^\n||c.example^$third-party\n@@||d.example^\n")
        self.assertEqual([len(entry["condition"]["requestDomains"]) for entry in rules], [2, 1, 1])
        self.assertEqual([entry["id"] for entry in rules], [1, 2, 3])

    def test_header_fields(self):
        _, _, header = bb.convert_list("! Version: 12\n! Last modified: today\n! Title: T\n")
        self.assertEqual(header, {"version": "12", "last_modified": "today", "title": "T"})


class ValidateRulesTests(unittest.TestCase):
    def good(self):
        return {"id": 1, "priority": 1, "action": {"type": "block"}, "condition": {"urlFilter": "/ads/"}}

    def test_a_good_rule_passes(self):
        bb.validate_rules([self.good()])

    def test_what_chromium_refuses_is_refused(self):
        changes = [
            lambda r: r.update(id=2),
            lambda r: r.update(priority=0),
            lambda r: r["action"].update(type="redirect"),
            lambda r: r["condition"].update(urlFilter=""),
            lambda r: r["condition"].update(urlFilter="/ü"),
            lambda r: r["condition"].update(urlFilter="||*ads"),
            lambda r: r["condition"].update(regexFilter="a"),
            lambda r: r["condition"].update(requestDomains=[]),
            lambda r: r["condition"].update(initiatorDomains=["Upper.example"]),
            lambda r: r["condition"].update(resourceTypes=["frame"]),
            lambda r: r["condition"].update(resourceTypes=["script"], excludedResourceTypes=["script"]),
            lambda r: r["action"].update(type="allowAllRequests"),
            lambda r: r["condition"].update(domainType="any"),
            lambda r: r["condition"].update(topDomains=["a.example"]),
        ]
        for index, change in enumerate(changes):
            broken = self.good()
            change(broken)
            with self.subTest(index), self.assertRaises(bb.BuildError):
                bb.validate_rules([broken])


class LimitTests(TemporaryDirectoryCase):
    def entry(self, list_id, level, count, regex=0):
        return {"id": list_id, "level": level, "rules": {"count": count, "regex": regex}}

    def test_within_limits(self):
        problems, report = bb.check_limits([self.entry("a", 1, 20000), self.entry("b", 2, 25000, 400)])
        self.assertEqual(problems, [])
        self.assertEqual(report["levels"]["trackers"], {
            "lists": ["a"], "rules": 20000, "regex": 0, "from_global_pool": 0})
        self.assertEqual(report["levels"]["ads-and-trackers"]["from_global_pool"], 15000)
        self.assertEqual(report["levels"]["strict"]["lists"], ["a", "b"])

    def test_too_many_regex_rules_in_one_ruleset(self):
        problems, _ = bb.check_limits([self.entry("a", 1, 2000, 1001)])
        self.assertTrue(any("a: 1001 regex rules" in problem for problem in problems), problems)

    def test_too_many_regex_rules_enabled_together(self):
        problems, _ = bb.check_limits([self.entry("a", 1, 2000, 600), self.entry("b", 2, 2000, 600)])
        self.assertFalse(any(problem.startswith(("a:", "b:")) for problem in problems), problems)
        self.assertTrue(any(problem.startswith("ads-and-trackers: 1200 regex") for problem in problems), problems)

    def test_a_ruleset_above_the_guaranteed_rules_plus_the_global_pool(self):
        problems, _ = bb.check_limits([self.entry("a", 1, 330001)])
        self.assertTrue(any(problem.startswith("a: 330001 rules") for problem in problems), problems)

    def test_a_level_above_the_guaranteed_rules_plus_the_global_pool(self):
        problems, _ = bb.check_limits([self.entry("a", 1, 150000), self.entry("b", 3, 250000)])
        self.assertTrue(any(problem.startswith("strict: 400000 rules") for problem in problems), problems)
        self.assertFalse(any(problem.startswith("trackers:") for problem in problems), problems)

    def test_a_level_two_bundles_of_which_do_not_fit_the_global_pool(self):
        # A list update has the new bundle's lists on before the old bundle's go (tab/095).
        fits, _ = bb.check_limits([self.entry("a", 1, 180000)])
        self.assertEqual(fits, [])
        problems, _ = bb.check_limits([self.entry("a", 1, 180001)])
        self.assertTrue(any(problem.startswith("trackers: 180001 rules; during a list update")
                            for problem in problems), problems)

    def test_regional_lists_count_only_towards_all(self):
        problems, report = bb.check_limits([self.entry("a", 1, 10), self.entry("de", 0, 5)])
        self.assertEqual(problems, [])
        self.assertEqual(report["levels"]["strict"]["rules"], 10)
        self.assertEqual(report["levels"]["all"]["rules"], 15)

    def test_too_many_rulesets(self):
        problems, _ = bb.check_limits([self.entry(f"l{i}", 1, 1) for i in range(101)])
        self.assertTrue(any("101 rulesets" in problem for problem in problems), problems)
        self.assertTrue(any("rulesets enabled together" in problem for problem in problems), problems)

    def test_the_build_fails_on_a_limit_and_writes_nothing(self):
        raw = dict(RAW, ads="".join(f"/ad{i}\\d+/\n" for i in range(1001)))
        with self.assertRaises(bb.BuildError) as failure:
            self.bundle(raw=raw)
        self.assertIn("ads: 1001 regex rules", str(failure.exception))
        self.assertFalse((self.tmp / "bundle").exists())

    def test_a_cut_off_download_fails(self):
        lists = [dict(LISTS[0], min_filters=10)]
        with self.assertRaises(bb.BuildError) as failure:
            self.bundle(lists=lists)
        self.assertIn("expected at least 10", str(failure.exception))

    def test_an_html_page_is_not_a_list(self):
        with self.assertRaises(bb.BuildError):
            self.bundle(raw=dict(RAW, ads="<!DOCTYPE html><html>blocked</html>"))

    def test_only_https_sources(self):
        with self.assertRaises(bb.BuildError):
            bb.fetch("http://example.org/list.txt")


class TooBroadTests(TemporaryDirectoryCase):
    """Security CB-04: one line of an upstream list must not switch blocking off everywhere or
    block every page. Such a filter names no domain and next to nothing of the address."""

    def refused(self, text):
        with self.subTest(text):
            with self.assertRaises(bb.Dropped) as dropped:
                bb.convert_network_filter(text)
            self.assertEqual(dropped.exception.reason, "too-broad", text)

    def test_an_exception_for_every_site_is_refused(self):
        for text in ("@@.$document", "@@/$document", "@@*$document", "@@$document", "@@.", "@@/$image",
                     "@@://$script", "@@|http$document", "@@|https://$document,script", "@@.js",
                     r"@@/^https?:\/\//$document", "@@/.*/$document",
                     "@@.$document,important", "@@.$document,third-party", "@@.$document,to=~a.example"):
            self.refused(text)

    def test_a_block_rule_that_takes_every_page_or_frame_is_refused(self):
        for text in (".$all", ".$document", "/$subdocument", ".", "/", "://", "|http", ".$~script",
                     "*$document", ".$document,script", r"/^https?:/$document", ".$all,important"):
            self.refused(text)

    def test_a_short_block_rule_for_other_request_kinds_is_the_lists_own(self):
        self.assertEqual(rule(".js$script")["condition"], {"urlFilter": ".js", "resourceTypes": ["script"]})
        self.assertEqual(rule("/a$~subdocument")["condition"],
                         {"urlFilter": "/a", "excludedResourceTypes": ["main_frame", "sub_frame"]})

    def test_a_domain_makes_a_short_pattern_a_rule(self):
        self.assertEqual(bb.convert_network_filter("@@.$document,domain=shop.example"), [{
            "priority": 2, "action": {"type": "allowAllRequests"},
            "condition": {"initiatorDomains": ["shop.example"], "urlFilter": ".", "resourceTypes": ["main_frame"]}}])
        self.assertEqual(rule("@@/$image,to=cdn.example")["action"], {"type": "allow"})
        self.assertEqual(rule(".$subdocument,domain=shop.example")["action"], {"type": "block"})
        self.assertEqual(rule("@@||page.example^$document")["action"], {"type": "allowAllRequests"})

    def test_a_pattern_that_says_where_stays(self):
        self.assertEqual(rule("@@/ads.txt")["condition"], {"urlFilter": "/ads.txt"})
        self.assertEqual(rule("/adframe.$subdocument")["action"], {"type": "block"})
        self.assertEqual(rule("@@||ads.example/ok/")["action"], {"type": "allow"})
        self.assertEqual(rule(r"@@/banner\d+\.png$/$image")["action"], {"type": "allow"})

    def test_a_document_exception_with_a_broad_half_goes_whole(self):
        # $document,script is two rules; neither is kept when the filter is refused.
        self.refused("@@.$document,script")

    def test_the_check_on_written_rules_refuses_one_too(self):
        page = {"id": 1, "priority": 2, "action": {"type": "allowAllRequests"},
                "condition": {"urlFilter": ".", "resourceTypes": ["main_frame"]}}
        everything = {"id": 1, "priority": 1, "action": {"type": "block"},
                      "condition": {"regexFilter": "^https?://", "resourceTypes": ["main_frame", "script"]}}
        no_pattern = {"id": 1, "priority": 2, "action": {"type": "allow"},
                      "condition": {"domainType": "thirdParty"}}
        for broken in (page, everything, no_pattern):
            with self.subTest(broken), self.assertRaises(bb.BuildError) as failure:
                bb.validate_rules([broken])
            self.assertIn("too broad", str(failure.exception))
        bb.validate_rules([dict(page, condition=dict(page["condition"], requestDomains=["a.example"]))])

    def test_the_build_drops_the_line_counts_it_and_says_which(self):
        lines = []
        raw = self.raw_dir(dict(RAW, ads=RAW["ads"] + "@@.$document\n.$all\n"))
        manifest = bb.build_bundle(self.tmp / "bundle", LISTS, raw_dir=raw, now=NOW, log=lines.append)
        ads = manifest["lists"][1]
        self.assertEqual(ads["filters"]["dropped"]["too-broad"], 2)
        self.assertEqual(ads["rules"]["allow_all_requests"], 0)
        self.assertIn("ads: refused as too broad: @@.$document", lines)
        self.assertIn("ads: refused as too broad: .$all", lines)
        rules = json.loads((self.tmp / "bundle/rules/ads.json").read_text())
        self.assertFalse(any(bb.is_too_broad(entry) for entry in rules))

    def test_the_committed_bundle_has_no_such_rule(self):
        bundle = REPO / "shell" / "Resources" / "Blocklists"
        for path in sorted((bundle / "rules").glob("*.json")):
            broad = [entry for entry in json.loads(path.read_text()) if bb.is_too_broad(entry)]
            self.assertEqual(broad, [], path.name)


def path_filters(count):
    return "".join(f"/track{index}/pixel.gif\n" for index in range(count))


def host_filters(count):
    return "".join(f"||h{index}.example^\n" for index in range(count))


class CountChangeTests(TemporaryDirectoryCase):
    """Security CB-04: a list whose rule or host count moved by more than a quarter against the
    bundle it replaces fails the build until someone has read why."""

    def setUp(self):
        super().setUp()
        self.signing_key = self.key()
        self.public = bb.public_key_of(self.signing_key)
        self.lines = []

    def build(self, name, trackers, ads=RAW["ads"], previous=None, **options):
        raw = self.tmp / f"raw-{name}"
        raw.mkdir()
        (raw / "trackers.txt").write_text(trackers)
        (raw / "ads.txt").write_text(ads)
        out = self.tmp / name
        if previous is not None:
            options.setdefault("previous_public_key", self.public)
        bb.build_bundle(out, LISTS, key=self.signing_key, raw_dir=raw, now=NOW, log=self.lines.append,
                        previous=previous, **options)
        return out

    def test_a_list_that_moved_a_little_builds(self):
        before = self.build("before", path_filters(100))
        self.build("grown", path_filters(125), previous=before)
        self.build("shrunk", path_filters(75), previous=before)
        self.assertIn(f"comparing with bundle 202611180930 in {before}", self.lines)

    def test_a_list_that_grew_by_more_than_a_quarter_fails_the_build(self):
        before = self.build("before", path_filters(100))
        with self.assertRaises(bb.BuildError) as failure:
            self.build("after", path_filters(126), previous=before)
        self.assertIn("trackers: 100 to 126 rules (+26%)", str(failure.exception))
        self.assertIn("--allow-count-change", str(failure.exception))
        self.assertNotIn("ads:", str(failure.exception))
        self.assertFalse((self.tmp / "after").exists())

    def test_a_list_that_shrank_by_more_than_a_quarter_fails_the_build(self):
        before = self.build("before", path_filters(100))
        with self.assertRaises(bb.BuildError) as failure:
            self.build("after", path_filters(74), previous=before)
        self.assertIn("trackers: 100 to 74 rules (-26%)", str(failure.exception))

    def test_a_host_list_is_one_rule_so_its_hosts_are_counted(self):
        before = self.build("before", host_filters(400))
        with self.assertRaises(bb.BuildError) as failure:
            self.build("after", host_filters(200), previous=before)
        self.assertIn("trackers: 400 to 200 hosts (-50%)", str(failure.exception))
        self.assertNotIn("1 to 1 rules", str(failure.exception))

    def test_a_list_that_lost_everything_fails_and_one_that_was_empty_too(self):
        before = self.build("before", path_filters(100))
        with self.assertRaises(bb.BuildError) as failure:
            self.build("emptied", "! nothing\n", previous=before)
        self.assertIn("trackers: 100 to 0 rules (-100%)", str(failure.exception))
        empty = self.build("empty", "! nothing\n")
        with self.assertRaises(bb.BuildError) as failure:
            self.build("filled", path_filters(100), previous=empty)
        self.assertIn("trackers: 0 to 100 rules (from none)", str(failure.exception))

    def test_a_few_rules_more_or_less_never_fail(self):
        before = self.build("before", path_filters(4))
        self.build("after", path_filters(4 + bb.COUNT_CHANGE_SLACK), previous=before)
        with self.assertRaises(bb.BuildError):
            self.build("more", path_filters(5 + bb.COUNT_CHANGE_SLACK), previous=before)

    def test_the_override_builds_and_says_what_moved(self):
        before = self.build("before", path_filters(100))
        out = self.build("after", path_filters(200), previous=before, allow_count_change=True)
        self.assertEqual(bb.verify_bundle(out, self.public)["lists"][0]["rules"]["count"], 200)
        self.assertTrue(any("trackers: 100 to 200 rules (+100%)" in line and "--allow-count-change" in line
                            for line in self.lines), self.lines)

    def test_a_list_the_replaced_bundle_does_not_have_is_not_compared(self):
        raw = self.raw_dir()
        before = self.tmp / "before"
        bb.build_bundle(before, LISTS[:1], key=self.signing_key, raw_dir=raw, now=NOW, log=self.lines.append)
        bb.build_bundle(self.tmp / "after", LISTS, key=self.signing_key, raw_dir=raw, now=NOW,
                        log=self.lines.append, previous=before, previous_public_key=self.public)
        self.assertIn("ads: not in the bundle this one replaces; nothing to compare", self.lines)

    def test_the_replaced_bundle_must_be_signed_with_the_lists_key(self):
        before = self.build("before", path_filters(100))
        other = bb.public_key_of(self.key("other.key"))
        with self.assertRaises(bb.BuildError) as failure:
            self.build("after", path_filters(100), previous=before, previous_public_key=other)
        self.assertIn("signature", str(failure.exception))
        manifest = json.loads((before / "manifest.json").read_text())
        manifest["lists"][0]["rules"]["count"] = 1000
        (before / "manifest.json").write_text(json.dumps(manifest))
        with self.assertRaises(bb.BuildError):
            self.build("again", path_filters(1000), previous=before)

    def test_the_exceptions_a_list_gained_are_printed(self):
        before = self.build("before", path_filters(100))
        self.lines.clear()
        gained = path_filters(100) + "@@||cdn.example/ok/\n@@||shop.example^$document\n"
        self.build("after", gained, previous=before)
        self.assertIn("trackers: 2 exception(s) the replaced bundle did not have:", self.lines)
        printed = [line for line in self.lines if line.startswith("  {")]
        self.assertEqual(len(printed), 2)
        self.assertTrue(any('"allowAllRequests"' in line and "shop.example" in line for line in printed))
        self.assertTrue(any('"urlFilter": "||cdn.example/ok/"' in line for line in printed))
        self.lines.clear()
        self.build("same", gained, previous=self.tmp / "after")
        self.assertFalse(any("exception(s)" in line for line in self.lines), self.lines)

    def test_many_gained_exceptions_are_counted_past_the_first(self):
        before = self.build("before", path_filters(200))
        more = bb.MAX_PRINTED_EXCEPTIONS + 5
        gained = path_filters(200) + "".join(f"@@||cdn.example/ok{index}/\n" for index in range(more))
        self.build("after", gained, previous=before)
        self.assertIn(f"trackers: {more} exception(s) the replaced bundle did not have:", self.lines)
        self.assertIn("  and 5 more", self.lines)

    def test_the_command_compares_with_previous_and_takes_the_override(self):
        public = self.tmp / "public.txt"
        public.write_text(self.public + "\n")
        raw = self.tmp / "raw"
        raw.mkdir()
        (raw / "peter-lowe.txt").write_text(host_filters(1200))
        common = ("--key", self.signing_key, "--raw-dir", raw, "--lists", "peter-lowe", "--public-key", public)
        first = run("build", "--out", self.tmp / "first", *common, "--previous", self.tmp / "none")
        self.assertEqual(first.returncode, 1)
        self.assertIn("no manifest.json", first.stderr)
        # Against the repository's bundle by default, which these 1,200 hosts are far from.
        default = run("build", "--out", self.tmp / "first", "--key", self.signing_key, "--raw-dir", raw,
                      "--lists", "peter-lowe")
        self.assertEqual(default.returncode, 1)
        self.assertIn("peter-lowe:", default.stderr)
        self.assertIn("hosts", default.stderr)
        first = run("build", "--out", self.tmp / "first", "--key", self.signing_key, "--raw-dir", raw,
                    "--lists", "peter-lowe", "--allow-count-change")
        self.assertEqual(first.returncode, 0, first.stderr)
        (raw / "peter-lowe.txt").write_text(host_filters(2400))
        second = run("build", "--out", self.tmp / "second", *common, "--previous", self.tmp / "first")
        self.assertEqual(second.returncode, 1)
        self.assertIn("peter-lowe: 1200 to 2400 hosts (+100%)", second.stderr)
        self.assertFalse((self.tmp / "second").exists())
        allowed = run("build", "--out", self.tmp / "second", *common, "--previous", self.tmp / "first",
                      "--allow-count-change")
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertIn("peter-lowe: 1200 to 2400 hosts (+100%)", allowed.stdout)


class FakeResponse:
    def __init__(self, url, body=b"||a.example^\n", encoding=""):
        self.url, self.body, self.headers = url, body, {"Content-Encoding": encoding}

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def geturl(self):
        return self.url

    def read(self, _limit):
        return self.body


class FetchTests(unittest.TestCase):
    """Security CB-04: a list is fetched over https at every hop."""

    def request(self):
        return bb.urllib.request.Request("https://lists.example/list.txt")

    def test_a_redirect_that_leaves_https_is_refused(self):
        handler = bb.HttpsOnlyRedirects()
        for target in ("http://lists.example/list.txt", "HTTP://lists.example/list.txt",
                       "ftp://lists.example/list.txt", "//lists.example/list.txt", "/list.txt"):
            with self.subTest(target), self.assertRaises(bb.BuildError) as failure:
                handler.redirect_request(self.request(), None, 302, "Found", {}, target)
            self.assertIn("not https", str(failure.exception))

    def test_a_redirect_to_https_is_followed(self):
        followed = bb.HttpsOnlyRedirects().redirect_request(
            self.request(), None, 301, "Moved", {}, "https://mirror.example/list.txt")
        self.assertEqual(followed.full_url, "https://mirror.example/list.txt")

    def test_fetch_uses_the_https_only_redirects(self):
        handlers = [type(handler) for handler in bb.OPENER.handlers]
        self.assertIn(bb.HttpsOnlyRedirects, handlers)
        # In place of urllib's own redirect handler, not beside it.
        self.assertEqual([handler for handler in handlers
                          if issubclass(handler, bb.urllib.request.HTTPRedirectHandler)],
                         [bb.HttpsOnlyRedirects])

    def test_a_refused_redirect_fails_the_fetch_at_once(self):
        opener = mock.Mock()
        opener.open.side_effect = bb.BuildError("redirected to http://x, which is not https")
        with self.assertRaises(bb.BuildError):
            bb.fetch("https://lists.example/list.txt", opener=opener)
        self.assertEqual(opener.open.call_count, 1)

    def test_an_answer_from_another_scheme_is_refused(self):
        opener = mock.Mock()
        opener.open.return_value = FakeResponse("http://lists.example/list.txt")
        with self.assertRaises(bb.BuildError) as failure:
            bb.fetch("https://lists.example/list.txt", opener=opener)
        self.assertIn("answered from http://lists.example/list.txt", str(failure.exception))

    def test_an_https_answer_is_returned_and_a_network_error_tried_again(self):
        opener = mock.Mock()
        opener.open.side_effect = [OSError("reset"), FakeResponse("https://mirror.example/list.txt")]
        self.assertEqual(bb.fetch("https://lists.example/list.txt", opener=opener), b"||a.example^\n")
        self.assertEqual(opener.open.call_count, 2)

    def test_a_redirect_through_a_local_server_to_http_is_refused(self):
        # The handler inside a real opener: a loopback server answers 302 to an http address.
        import http.server
        import threading

        class Redirect(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/plain")
                self.end_headers()

            def log_message(self, *_):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Redirect)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        # fetch itself refuses an http start, so the opener is asked directly.
        with self.assertRaises(bb.BuildError) as failure:
            bb.OPENER.open(f"http://127.0.0.1:{server.server_port}/start", timeout=10)
        self.assertIn("which is not https", str(failure.exception))


class BundleTests(TemporaryDirectoryCase):
    def test_bundle_layout_and_manifest(self):
        out, manifest = self.bundle()
        self.assertEqual(sorted(str(path.relative_to(out)) for path in out.rglob("*") if path.is_file()), [
            "manifest.json", "raw/ads.txt", "raw/trackers.txt", "rules/ads.json", "rules/trackers.json"])
        self.assertEqual(manifest, json.loads((out / "manifest.json").read_text()))
        self.assertEqual(manifest["version"], "202611180930")
        self.assertEqual(manifest["created"], "2026-11-18T09:30:00Z")
        self.assertEqual(manifest["min_engine"], bb.MIN_ENGINE)
        self.assertEqual(manifest["priorities"]["site_exception"], 1000000)
        ads = manifest["lists"][1]
        self.assertEqual((ads["id"], ads["title"], ads["level"], ads["license"]), ("ads", "Ads", 2, "CC0-1.0"))
        self.assertEqual(ads["source"]["version"], "9")
        self.assertEqual(ads["source"]["sha256"], bb.sha256(RAW["ads"].encode()))
        self.assertEqual(ads["rules"]["path"], "rules/ads.json")
        self.assertEqual(ads["rules"]["sha256"], bb.sha256((out / "rules/ads.json").read_bytes()))
        self.assertEqual((ads["rules"]["count"], ads["rules"]["regex"], ads["rules"]["block"], ads["rules"]["allow"]),
                         (3, 1, 2, 1))
        self.assertEqual(ads["filters"]["dropped"], {"csp": 1})
        self.assertEqual(ads["filters"]["cosmetic"]["hide"], 1)
        self.assertEqual(manifest["limits"]["levels"]["ads-and-trackers"]["rules"], 6)

    def test_rules_files_are_dnr_json(self):
        out, _ = self.bundle()
        rules = json.loads((out / "rules/trackers.json").read_text())
        self.assertEqual([entry["id"] for entry in rules], [1, 2, 3])
        self.assertEqual(rules[0]["condition"], {"requestDomains": ["tracker.example"]})

    def test_building_again_from_a_bundle_fetches_nothing_and_gives_the_same_rules(self):
        key = self.key()
        first, manifest = self.bundle(key=key)
        public = bb.public_key_of(key)

        def no_fetch(url):
            raise AssertionError(f"fetched {url}")
        again = self.tmp / "again"
        rebuilt = bb.build_bundle(again, LISTS, key=key, from_bundle=first, from_public_key=public,
                                  now=NOW + datetime.timedelta(hours=1), fetcher=no_fetch, log=lambda _: None)
        self.assertEqual(rebuilt["version"], "202611181030")
        for name in ("rules/ads.json", "rules/trackers.json", "raw/ads.txt", "raw/trackers.txt"):
            self.assertEqual((again / name).read_bytes(), (first / name).read_bytes(), name)
        self.assertEqual(rebuilt["lists"][0]["source"], manifest["lists"][0]["source"])
        bb.verify_bundle(again, public)

    def test_building_again_from_a_copy_without_raw_files_takes_them_from_a_directory(self):
        key = self.key()
        first, _ = self.bundle(key=key)
        public = bb.public_key_of(key)
        app_copy = self.tmp / "app-copy"
        bb.install_bundle(first, app_copy, public)
        with self.assertRaises(bb.BuildError) as failure:
            bb.build_bundle(self.tmp / "x", LISTS, from_bundle=app_copy, from_public_key=public, log=lambda _: None)
        self.assertIn("--raw-dir", str(failure.exception))
        again = self.tmp / "again"
        bb.build_bundle(again, LISTS, key=key, from_bundle=app_copy, from_public_key=public,
                        raw_dir=first / "raw", now=NOW, log=lambda _: None)
        self.assertEqual((again / "rules/ads.json").read_bytes(), (first / "rules/ads.json").read_bytes())
        # The files must be the ones the signed manifest names.
        changed = self.raw_dir(dict(RAW, ads=RAW["ads"] + "||more.example^\n"))
        with self.assertRaises(bb.BuildError) as failure:
            bb.build_bundle(self.tmp / "x", LISTS, from_bundle=app_copy, from_public_key=public,
                            raw_dir=changed, log=lambda _: None)
        self.assertIn("does not match the sha256", str(failure.exception))

    def test_building_again_refuses_changed_raw_files_and_unsigned_bundles(self):
        key = self.key()
        first, _ = self.bundle(key=key)
        public = bb.public_key_of(key)
        unsigned, _ = self.bundle(name="unsigned")
        with self.assertRaises(bb.BuildError):
            bb.build_bundle(self.tmp / "x", LISTS, from_bundle=unsigned, from_public_key=public, log=lambda _: None)
        (first / "raw/ads.txt").write_text(RAW["ads"] + "||more.example^\n")
        with self.assertRaises(bb.BuildError) as failure:
            bb.build_bundle(self.tmp / "x", LISTS, from_bundle=first, from_public_key=public, log=lambda _: None)
        self.assertIn("raw/ads.txt", str(failure.exception))

    def test_install_copies_what_the_app_uses(self):
        key = self.key()
        out, _ = self.bundle(key=key)
        destination = self.tmp / "app" / "Blocklists"
        bb.install_bundle(out, destination, bb.public_key_of(key))
        self.assertEqual(sorted(str(path.relative_to(destination)) for path in destination.rglob("*") if path.is_file()),
                         ["manifest.json", "manifest.json.sig", "rules/ads.json", "rules/trackers.json"])
        self.assertEqual((destination / "manifest.json").read_bytes(), (out / "manifest.json").read_bytes())

    def test_pack_writes_the_mirror_files(self):
        key = self.key()
        out, manifest = self.bundle(key=key)
        public = bb.public_key_of(key)
        latest = bb.pack_bundle(out, self.tmp / "mirror", public_key=public)
        archive = self.tmp / "mirror" / "blocklists-202611180930.tar.gz"
        self.assertEqual(latest, {
            "version": "202611180930",
            "url": "https://rearc.imara.ae/blocklists/blocklists-202611180930.tar.gz",
            "sha256": bb.sha256(archive.read_bytes())})
        self.assertEqual(json.loads((self.tmp / "mirror" / "latest.json").read_text()), latest)
        with tarfile.open(archive) as tar:
            names = tar.getnames()
            for member in tar.getmembers():
                self.assertEqual((member.uid, member.gid, member.uname, member.gname), (0, 0, "", ""))
                target = self.tmp / "unpacked" / member.name
                if member.isdir():
                    target.mkdir(parents=True)
                else:
                    self.assertTrue(member.isfile(), member.name)
                    target.write_bytes(tar.extractfile(member).read())
        root = "blocklists-202611180930"
        self.assertEqual(names, [root, f"{root}/rules", f"{root}/manifest.json", f"{root}/manifest.json.sig",
                                 f"{root}/rules/ads.json", f"{root}/rules/trackers.json"])
        self.assertEqual(bb.verify_bundle(self.tmp / "unpacked" / root, public), manifest)
        # The same bundle packs to the same bytes.
        bb.pack_bundle(out, self.tmp / "mirror2", public_key=public)
        self.assertEqual((self.tmp / "mirror2" / archive.name).read_bytes(), archive.read_bytes())

    def test_pack_refuses_a_bundle_that_does_not_verify(self):
        key = self.key()
        out, _ = self.bundle(key=key)
        (out / "rules/ads.json").write_text("[]\n")
        with self.assertRaises(bb.BuildError):
            bb.pack_bundle(out, self.tmp / "mirror", public_key=bb.public_key_of(key))
        self.assertFalse((self.tmp / "mirror").exists())


class SignatureTests(TemporaryDirectoryCase):
    """Run with `cryptography` when installed; OpenSslSignatureTests repeats them through openssl."""

    def test_good_bundle(self):
        key = self.key()
        out, manifest = self.bundle(key=key)
        signature = (out / "manifest.json.sig").read_text()
        self.assertEqual(len(base64.b64decode(signature, validate=True)), 64)
        self.assertEqual(signature, signature.strip())
        self.assertEqual(bb.verify_bundle(out, bb.public_key_of(key)), manifest)

    def test_bad_signature(self):
        key = self.key()
        out, _ = self.bundle(key=key)
        signature = bytearray(base64.b64decode((out / "manifest.json.sig").read_text()))
        signature[0] ^= 1
        (out / "manifest.json.sig").write_text(base64.b64encode(bytes(signature)).decode())
        with self.assertRaises(bb.BuildError) as failure:
            bb.verify_bundle(out, bb.public_key_of(key))
        self.assertIn("signature", str(failure.exception))

    def test_changed_manifest(self):
        key = self.key()
        out, _ = self.bundle(key=key)
        text = (out / "manifest.json").read_text()
        (out / "manifest.json").write_text(text.replace('"version": "202611180930"', '"version": "202711180930"'))
        with self.assertRaises(bb.BuildError) as failure:
            bb.verify_bundle(out, bb.public_key_of(key))
        self.assertIn("signature", str(failure.exception))

    def test_another_key(self):
        out, _ = self.bundle(key=self.key())
        other = bb.public_key_of(self.key("other.key"))
        with self.assertRaises(bb.BuildError):
            bb.verify_bundle(out, other)

    def test_missing_or_garbled_signature(self):
        key = self.key()
        out, _ = self.bundle(key=key)
        public = bb.public_key_of(key)
        (out / "manifest.json.sig").write_text("not base64!")
        with self.assertRaises(bb.BuildError):
            bb.verify_bundle(out, public)
        (out / "manifest.json.sig").unlink()
        with self.assertRaises(bb.BuildError) as failure:
            bb.verify_bundle(out, public)
        self.assertIn("no manifest.json.sig", str(failure.exception))

    def test_hash_mismatch(self):
        key = self.key()
        out, _ = self.bundle(key=key)
        rules = out / "rules/ads.json"
        rules.write_bytes(rules.read_bytes().replace(b"ads.example", b"abs.example"))
        with self.assertRaises(bb.BuildError) as failure:
            bb.verify_bundle(out, bb.public_key_of(key))
        self.assertIn("rules/ads.json does not match its sha256", str(failure.exception))

    def test_missing_rules_file(self):
        key = self.key()
        out, _ = self.bundle(key=key)
        (out / "rules/ads.json").unlink()
        with self.assertRaises(bb.BuildError) as failure:
            bb.verify_bundle(out, bb.public_key_of(key))
        self.assertIn("rules/ads.json is missing", str(failure.exception))

    def test_the_key_is_private_and_made_once(self):
        key = self.key()
        self.assertEqual(stat.S_IMODE(key.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(key.parent.stat().st_mode), 0o700)
        self.assertIn(b"BEGIN PRIVATE KEY", key.read_bytes())
        before = key.read_bytes()
        self.assertFalse(bb.generate_key(key))
        self.assertEqual(key.read_bytes(), before)
        self.assertEqual(len(base64.b64decode(bb.public_key_of(key))), 32)

    def test_a_key_others_can_read_is_refused(self):
        key = self.key()
        key.chmod(0o644)
        with self.assertRaises(bb.BuildError) as failure:
            bb.sign(b"x", key)
        self.assertIn("readable by others", str(failure.exception))

    def test_sign_and_verify_bytes(self):
        key = self.key()
        public = bb.public_key_of(key)
        signature = bb.sign(b"manifest", key)
        self.assertTrue(bb.verify_signature(b"manifest", signature, public))
        self.assertTrue(bb.verify_signature(b"manifest", signature + "\n", public + "\n"))
        self.assertFalse(bb.verify_signature(b"manifesu", signature, public))
        self.assertFalse(bb.verify_signature(b"manifest", signature, base64.b64encode(bytes(32)).decode()))
        self.assertFalse(bb.verify_signature(b"manifest", "AAAA", public))


def openssl_available():
    try:
        bb._openssl()
    except bb.BuildError:
        return False
    return True


@unittest.skipUnless(openssl_available(), "no OpenSSL 3 command-line tool")
class OpenSslSignatureTests(SignatureTests):
    """The same checks without the `cryptography` package."""

    def setUp(self):
        super().setUp()
        patcher = mock.patch.object(bb, "_cryptography", return_value=None)
        patcher.start()
        self.addCleanup(patcher.stop)


@unittest.skipUnless(openssl_available() and bb._cryptography(), "needs both Ed25519 backends")
class CrossBackendTests(TemporaryDirectoryCase):
    def test_each_backend_verifies_the_other(self):
        key = self.key()
        with_package = bb.sign(b"manifest", key)
        public = bb.public_key_of(key)
        with mock.patch.object(bb, "_cryptography", return_value=None):
            self.assertEqual(bb.public_key_of(key), public)
            self.assertEqual(bb.sign(b"manifest", key), with_package)  # Ed25519 is deterministic.
            self.assertTrue(bb.verify_signature(b"manifest", with_package, public))
            self.assertFalse(bb.verify_signature(b"manifesu", with_package, public))
            openssl_key = self.tmp / "keys" / "openssl.key"
            self.assertTrue(bb.generate_key(openssl_key))
            from_openssl = bb.sign(b"manifest", openssl_key)
            openssl_public = bb.public_key_of(openssl_key)
        self.assertTrue(bb.verify_signature(b"manifest", from_openssl, openssl_public))


class SeveralKeysTests(TemporaryDirectoryCase):
    """Security CB-05: the lists key can be replaced. For one release a bundle may be signed with
    either of two keys, the key in use and the one that follows it."""

    def setUp(self):
        super().setUp()
        self.old_key, self.new_key = self.key("old.key"), self.key("new.key")
        self.old_public, self.new_public = bb.public_key_of(self.old_key), bb.public_key_of(self.new_key)
        self.signed_old, _ = self.bundle("signed-old", key=self.old_key)
        self.signed_new, _ = self.bundle("signed-new", key=self.new_key)

    def test_a_bundle_verifies_when_any_one_key_signed_it(self):
        for keys in ([self.old_public, self.new_public], [self.new_public, self.old_public],
                     (self.new_public, self.old_public)):
            self.assertEqual(bb.verify_bundle(self.signed_old, keys)["version"], "202611180930")
            self.assertEqual(bb.verify_bundle(self.signed_new, keys)["version"], "202611180930")

    def test_a_dropped_key_no_longer_verifies(self):
        bb.verify_bundle(self.signed_new, [self.new_public])
        with self.assertRaises(bb.BuildError) as failure:
            bb.verify_bundle(self.signed_old, [self.new_public])
        self.assertIn("signature", str(failure.exception))
        stranger = bb.public_key_of(self.key("stranger.key"))
        with self.assertRaises(bb.BuildError):
            bb.verify_bundle(self.signed_old, [stranger, self.new_public])

    def test_a_changed_manifest_verifies_with_no_key(self):
        manifest = self.signed_old / "manifest.json"
        manifest.write_bytes(manifest.read_bytes().replace(b'"Trackers"', b'"trackers"'))
        with self.assertRaises(bb.BuildError):
            bb.verify_bundle(self.signed_old, [self.old_public, self.new_public])

    def test_the_key_file_holds_a_key_a_line(self):
        path = self.tmp / "keys.txt"
        path.write_text(f"# the key in use\n{self.new_public}\n\n  # until the next release\n {self.old_public} \n")
        self.assertEqual(bb.read_public_keys(path), [self.new_public, self.old_public])
        path.write_text("# none\n\n")
        with self.assertRaises(bb.BuildError):
            bb.read_public_keys(path)
        with self.assertRaises(bb.BuildError):
            bb.read_public_keys(self.tmp / "missing.txt")

    def test_the_commands_take_a_file_of_several_keys(self):
        both = self.tmp / "both.txt"
        both.write_text(f"{self.new_public}\n{self.old_public}\n")
        only_new = self.tmp / "new.txt"
        only_new.write_text(f"{self.new_public}\n")
        self.assertEqual(run("verify", self.signed_old, "--public-key", both).returncode, 0)
        self.assertEqual(run("verify", self.signed_new, "--public-key", both).returncode, 0)
        refused = run("verify", self.signed_old, "--public-key", only_new)
        self.assertEqual(refused.returncode, 1)
        self.assertIn("signature", refused.stderr)
        packed = run("pack", self.signed_old, "--out", self.tmp / "mirror", "--public-key", both)
        self.assertEqual(packed.returncode, 0, packed.stderr)
        self.assertEqual(run("pack", self.signed_old, "--out", self.tmp / "mirror2", "--public-key", only_new).returncode, 1)


class CommandLineTests(TemporaryDirectoryCase):
    def test_build_verify_pack_install(self):
        key = self.tmp / "keys" / "signing.key"
        public = self.tmp / "public.txt"
        made = run("keygen", "--key", key, "--public-key", public)
        self.assertEqual(made.returncode, 0, made.stderr)
        self.assertEqual(made.stdout.strip(), public.read_text().strip())
        raw = self.raw_dir({"peter-lowe": "".join(f"||h{i}.example^\n" for i in range(1200))})
        out = self.tmp / "bundle"
        # --allow-count-change: these 1,200 hosts are compared with the repository's bundle.
        built = run("build", "--out", out, "--key", key, "--raw-dir", raw, "--lists", "peter-lowe",
                    "--version", "202611180930", "--allow-count-change")
        self.assertEqual(built.returncode, 0, built.stderr)
        self.assertIn("peter-lowe: 1 rules", built.stdout)
        verified = run("verify", out, "--public-key", public)
        self.assertEqual((verified.returncode, verified.stdout), (0, "ok: bundle 202611180930, 1 lists\n"))
        packed = run("pack", out, "--out", self.tmp / "mirror", "--public-key", public)
        self.assertEqual(packed.returncode, 0, packed.stderr)
        self.assertEqual(json.loads(packed.stdout)["version"], "202611180930")
        installed = run("install", out, self.tmp / "app", "--public-key", public)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        self.assertFalse((self.tmp / "app" / "raw").exists())
        (out / "rules/peter-lowe.json").write_text("[]\n")
        broken = run("verify", out, "--public-key", public)
        self.assertEqual(broken.returncode, 1)
        self.assertIn("does not match its sha256", broken.stderr)

    def test_unknown_list(self):
        result = run("build", "--out", self.tmp / "bundle", "--no-sign", "--lists", "nope")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unknown list: nope", result.stderr)


class CatalogueTests(unittest.TestCase):
    def test_catalogue(self):
        ids = [entry["id"] for entry in bb.CATALOGUE]
        self.assertEqual(len(ids), len(set(ids)))
        for entry in bb.CATALOGUE:
            with self.subTest(entry["id"]):
                self.assertRegex(entry["id"], r"^[a-z0-9][a-z0-9-]*$")
                self.assertTrue(entry["url"].startswith("https://"))
                self.assertTrue(entry["title"] and entry["homepage"] and entry["license"])
                self.assertEqual(entry["level"] == 0, bool(entry.get("regional")))

    def test_levels_follow_the_spec(self):
        def level(number):
            return [entry["id"] for entry in bb.select_lists(None, False) if 0 < entry["level"] <= number]
        self.assertEqual(level(1), ["easyprivacy", "peter-lowe"])
        self.assertEqual(level(2), ["easyprivacy", "peter-lowe", "easylist"])
        self.assertEqual(level(3), ["easyprivacy", "peter-lowe", "easylist", "fanboy-annoyance", "easylist-cookie"])

    def test_regional_lists_are_optional(self):
        self.assertFalse(any(entry.get("regional") for entry in bb.select_lists(None, False)))
        self.assertIn("easylist-germany", [entry["id"] for entry in bb.select_lists(None, True)])
        self.assertEqual([entry["id"] for entry in bb.select_lists(["liste-fr"], False)], ["liste-fr"])


class CommittedBundleTests(unittest.TestCase):
    """The built-in bundle and public key in the repository."""

    BUNDLE = REPO / "shell" / "Resources" / "Blocklists"

    def test_the_public_key_is_an_ed25519_key_and_not_sparkles(self):
        keys = bb.read_public_keys()
        # The key in use, and at most two more while one is brought in or retired (RELEASE.md).
        self.assertTrue(1 <= len(keys) <= 3, keys)
        self.assertEqual(len(set(keys)), len(keys))
        sparkle = (REPO / "shell/scripts/release/sparkle-public-key.txt").read_text().strip()
        for public in keys:
            self.assertEqual(len(base64.b64decode(public, validate=True)), 32)
            self.assertNotEqual(public, sparkle)

    def test_the_built_in_bundle_verifies_against_the_committed_key(self):
        manifest = bb.verify_bundle(self.BUNDLE, bb.read_public_keys())
        self.assertEqual([entry["id"] for entry in manifest["lists"]],
                         ["easyprivacy", "peter-lowe", "easylist", "fanboy-annoyance", "easylist-cookie"])
        for entry in manifest["lists"]:
            rules = json.loads((self.BUNDLE / entry["rules"]["path"]).read_text())
            bb.validate_rules(rules)
            self.assertEqual(len(rules), entry["rules"]["count"])
        problems, _ = bb.check_limits(manifest["lists"])
        self.assertEqual(problems, [])

    def test_the_repository_copy_has_no_raw_lists(self):
        # Upstream list text stays out of the repository; the full bundle is kept beside the key.
        self.assertFalse((self.BUNDLE / "raw").exists())

    def test_the_built_in_bundle_converts_again_to_the_same_rules(self):
        manifest = json.loads((self.BUNDLE / "manifest.json").read_text())
        kept = Path(os.environ.get("REARC_BLOCKLISTS_RAW_DIR")
                    or bb.DEFAULT_KEY.parent / "bundles" / manifest["version"] / "raw")
        if not kept.is_dir():
            self.skipTest(f"the bundle's upstream files are not on this Mac ({kept})")
        by_id = {entry["id"]: entry for entry in bb.CATALOGUE}
        for entry in manifest["lists"]:
            raw = (kept / f"{entry['id']}.txt").read_bytes()
            self.assertEqual(bb.sha256(raw), entry["source"]["sha256"])
            raw = raw.decode("utf-8")
            rules, stats, _ = bb.convert_list(raw, by_id[entry["id"]].get("format", "abp"))
            with self.subTest(entry["id"]):
                self.assertEqual(bb.sha256(bb.rules_json(rules)), entry["rules"]["sha256"])
                self.assertEqual(stats, entry["filters"])


if __name__ == "__main__":
    unittest.main()

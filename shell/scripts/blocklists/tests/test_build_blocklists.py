"""The blocklist builder (build-blocklists.py): filter conversion against golden files, dropped
filter counts, Chromium's DNR limits, the Ed25519 signature and the bundle's file hashes.
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
        self.assertEqual(rule("/a$third-party")["condition"]["domainType"], "thirdParty")
        self.assertEqual(rule("/a$~third-party")["condition"]["domainType"], "firstParty")
        self.assertEqual(rule("/a$1p")["condition"]["domainType"], "firstParty")
        self.assertEqual(rule("/a$~first-party")["condition"]["domainType"], "thirdParty")

    def test_domain_option_becomes_initiator_domains(self):
        condition = rule("/a$domain=b.example|~c.b.example|A.example")["condition"]
        self.assertEqual(condition["initiatorDomains"], ["a.example", "b.example"])
        self.assertEqual(condition["excludedInitiatorDomains"], ["c.b.example"])

    def test_resource_types(self):
        self.assertEqual(rule("/a$script,image")["condition"]["resourceTypes"], ["script", "image"])
        self.assertEqual(rule("/a$xmlhttprequest,subdocument")["condition"]["resourceTypes"],
                         ["sub_frame", "xmlhttprequest"])

    def test_only_excluded_types_never_reach_the_main_frame(self):
        # DNR would match main_frame once excludedResourceTypes is given without it.
        self.assertEqual(rule("/a$~script")["condition"]["excludedResourceTypes"], ["main_frame", "script"])

    def test_no_types_leaves_dnr_default_which_skips_the_main_frame(self):
        self.assertNotIn("resourceTypes", rule("/a")["condition"])
        self.assertNotIn("excludedResourceTypes", rule("/a")["condition"])

    def test_exception_is_an_allow_rule_above_block_rules(self):
        allow = rule("@@||ads.example/ok/")
        self.assertEqual(allow["action"], {"type": "allow"})
        self.assertGreater(allow["priority"], rule("||ads.example/ok/")["priority"])

    def test_important_beats_exceptions(self):
        self.assertGreater(rule("/a$important")["priority"], rule("@@/a")["priority"])
        self.assertGreater(rule("@@/a$important")["priority"], rule("/a$important")["priority"])

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
        rules, stats, _ = bb.convert_list("/a\n/a\n||b.example^\n||B.example^\n")
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
        return {"id": 1, "priority": 1, "action": {"type": "block"}, "condition": {"urlFilter": "/a"}}

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
        problems, _ = bb.check_limits([self.entry("a", 1, 200000), self.entry("b", 3, 200000)])
        self.assertTrue(any(problem.startswith("strict: 400000 rules") for problem in problems), problems)
        self.assertFalse(any(problem.startswith("trackers:") for problem in problems), problems)

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


class CommandLineTests(TemporaryDirectoryCase):
    def test_build_verify_pack_install(self):
        key = self.tmp / "keys" / "signing.key"
        public = self.tmp / "public.txt"
        made = run("keygen", "--key", key, "--public-key", public)
        self.assertEqual(made.returncode, 0, made.stderr)
        self.assertEqual(made.stdout.strip(), public.read_text().strip())
        raw = self.raw_dir({"peter-lowe": "".join(f"||h{i}.example^\n" for i in range(1200))})
        out = self.tmp / "bundle"
        built = run("build", "--out", out, "--key", key, "--raw-dir", raw, "--lists", "peter-lowe",
                    "--version", "202611180930")
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
        public = bb.read_public_key()
        self.assertEqual(len(base64.b64decode(public, validate=True)), 32)
        sparkle = (REPO / "shell/scripts/release/sparkle-public-key.txt").read_text().strip()
        self.assertNotEqual(public, sparkle)

    def test_the_built_in_bundle_verifies_against_the_committed_key(self):
        manifest = bb.verify_bundle(self.BUNDLE, bb.read_public_key())
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

#!/usr/bin/env python3
"""Builds ReArc's signed blocklist bundle (docs/FEATURE-SPECS/CONTENT-BLOCKING.md, section 4).

Fetches the pinned upstream filter lists, converts their network filters to
declarativeNetRequest (DNR) rules for the engine's "ReArc Blocker" component extension, checks
Chromium's DNR limits, writes the bundle and its manifest and signs the manifest with the lists
key (Ed25519; never the Sparkle key).

  build-blocklists.py build --out DIR [--key FILE | --no-sign] [--from-bundle DIR [--raw-dir DIR]]
                            [--lists ID,ID] [--with-regional] [--version YYYYMMDDHHMM]
                            [--previous DIR] [--allow-count-change]
                            [--accept-gained-page-exceptions] [--public-key FILE]
  build-blocklists.py verify DIR [--public-key FILE]
  build-blocklists.py pack DIR --out DIR [--base-url URL] [--public-key FILE]
  build-blocklists.py install DIR DEST [--public-key FILE]
  build-blocklists.py keygen [--key FILE] [--public-key FILE]

build     writes DIR/{manifest.json, manifest.json.sig, rules/<id>.json, raw/<id>.txt}.
          --from-bundle converts the upstream files of an earlier signed bundle again and
          fetches nothing. They are read from that bundle's raw/ or, for a copy without one
          (the app's, the repository's), from --raw-dir, and must match the sha256 its signed
          manifest records, so a release converts exactly what that bundle was built from.
          Each list is compared with the bundle this one replaces (--previous, by default the
          repository's shell/Resources/Blocklists): a rule or host count that moved by more than
          25% fails the build, and the exceptions the list gained are printed. Read them, then
          build again with --allow-count-change when the move is the list's own.
          A gained exception for whole pages or frames (allowAllRequests, or an allow for
          main_frame or sub_frame requests that is tied to no site) fails the build as well:
          one such line can switch blocking off. A person who has read them builds again with
          --accept-gained-page-exceptions; a job that runs by itself never passes that flag.
verify    checks the signature against the committed public keys (any one of them) and every
          file's sha256.
pack      verifies, then writes the mirror files: blocklists-<version>.tar.gz and latest.json
          ({version, url, sha256}). The archive holds what the app uses (no raw/).
install   verifies, then copies what the app uses (no raw/) to DEST. The repository's
          shell/Resources/Blocklists is such a copy; keep the full bundle outside the
          repository (~/.config/rearc/blocklists/bundles/<version>/).
keygen    creates the private key (mode 600) unless it exists and prints the public key.

Only the Python standard library, plus `cryptography` when it is installed; without it Ed25519
goes through an OpenSSL 3 command-line tool. Upstream files are data: they are only parsed.
"""
import argparse
import base64
import datetime
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

HERE = Path(__file__).resolve().parent
DEFAULT_KEY = Path.home() / ".config" / "rearc" / "blocklists" / "signing.key"
PUBLIC_KEY_FILE = HERE / "blocklists-public-key.txt"
MIRROR_URL = "https://rearc.imara.ae/blocklists/"
FORMAT = 1
# The oldest engine whose DNR reads everything the converter writes: Chromium's major version.
# Chromium 156 is the first ReArc engine with the blocker (C-ABI 1.66).
MIN_ENGINE = 156
USER_AGENT = "blocklist-builder/1"
MAX_DOWNLOAD_BYTES = 64 * 1024 * 1024
# The bundle in the repository: what a new bundle replaces in the app.
BUILT_IN_BUNDLE = HERE.parent.parent / "Resources" / "Blocklists"

# The lists key signs what the upstream lists say (security CB-04), so the build looks at what
# it is about to sign.
# A filter for every site must say something about the address: a pattern with fewer letters
# than this (anchors and wildcards aside), or one that matches every address in BROAD_PROBES
# under http or under https, is refused when the rule is an exception or blocks pages and frames.
# "For every site" includes a filter whose domains are top-level names (to=com|net|org): a name
# without a dot names no site (names_domain).
MIN_BROAD_PATTERN_CHARS = 4
BROAD_PROBES = (
    "example.com/",
    "a.test/index.html?x=1",
    "b.example.org/p/q.js",
    "cdn.example.net/assets/app.css",
)
# A list whose rule count or host count moved by more than this share against the bundle it
# replaces fails the build (--allow-count-change builds it all the same). Moves of up to
# COUNT_CHANGE_SLACK rules never fail: a list of a few rules doubles by gaining one.
MAX_COUNT_CHANGE = 0.25
COUNT_CHANGE_SLACK = 20
# Exceptions a list gained that the build prints in full; the rest are counted.
MAX_PRINTED_EXCEPTIONS = 40

# Chromium's limits (extensions/common/api/declarative_net_request.webidl and
# extensions/browser/api/declarative_net_request/constants.h at the pinned 156).
GUARANTEED_MINIMUM_STATIC_RULES = 30000
MAX_STATIC_RULES_PER_PROFILE = 300000  # the global pool every extension shares
MAX_RULES_PER_RULESET = GUARANTEED_MINIMUM_STATIC_RULES + MAX_STATIC_RULES_PER_PROFILE
MAX_NUMBER_OF_REGEX_RULES = 1000  # per ruleset, and across the enabled static rulesets
MAX_NUMBER_OF_STATIC_RULESETS = 100
MAX_NUMBER_OF_ENABLED_STATIC_RULESETS = 50

# Rule priorities inside one list. The engine's site exceptions and the person's own rules sit
# above all of them (see PRIORITY_* in the manifest and C-ABI.md).
PRIORITY_BLOCK = 1
PRIORITY_ALLOW = 2
PRIORITY_IMPORTANT = 3
PRIORITY_IMPORTANT_ALLOW = 4
PRIORITY_SITE_EXCEPTION = 1000000

# Blocking levels (spec section 2): 1 trackers only, 2 ads and trackers, 3 strict.
LEVELS = {1: "trackers", 2: "ads-and-trackers", 3: "strict"}

EASYLIST_LICENSE = "GPL-3.0-or-later OR CC-BY-SA-3.0"
CATALOGUE = [
    {
        "id": "easyprivacy",
        "title": "EasyPrivacy",
        "homepage": "https://easylist.to/",
        "license": EASYLIST_LICENSE,
        "license_url": "https://easylist.to/pages/licence.html",
        "url": "https://easylist.to/easylist/easyprivacy.txt",
        "format": "abp",
        "level": 1,
        "min_filters": 10000,
    },
    {
        "id": "peter-lowe",
        "title": "Peter Lowe's Ad and tracking server list",
        "homepage": "https://pgl.yoyo.org/adservers/",
        "license": "McRae General Public License (version 4.r53)",
        "license_url": "https://pgl.yoyo.org/license/",
        "url": "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=1&mimetype=plaintext",
        "format": "abp",
        "level": 1,
        "min_filters": 1000,
    },
    {
        "id": "easylist",
        "title": "EasyList",
        "homepage": "https://easylist.to/",
        "license": EASYLIST_LICENSE,
        "license_url": "https://easylist.to/pages/licence.html",
        "url": "https://easylist.to/easylist/easylist.txt",
        "format": "abp",
        "level": 2,
        "min_filters": 10000,
    },
    {
        "id": "fanboy-annoyance",
        "title": "Fanboy's Annoyance List",
        "homepage": "https://easylist.to/",
        "license": EASYLIST_LICENSE,
        "license_url": "https://easylist.to/pages/licence.html",
        "url": "https://secure.fanboy.co.nz/fanboy-annoyance.txt",
        "format": "abp",
        "level": 3,
        "min_filters": 1000,
    },
    {
        "id": "easylist-cookie",
        "title": "EasyList Cookie List",
        "homepage": "https://easylist.to/",
        "license": EASYLIST_LICENSE,
        "license_url": "https://easylist.to/pages/licence.html",
        "url": "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt",
        "format": "abp",
        "level": 3,
        "min_filters": 1000,
    },
    # Regional lists: off unless chosen under Advanced (phase 2). Built only with
    # --with-regional or --lists.
    {
        "id": "easylist-germany",
        "title": "EasyList Germany",
        "homepage": "https://easylist.to/",
        "license": EASYLIST_LICENSE,
        "license_url": "https://easylist.to/pages/licence.html",
        "url": "https://easylist.to/easylistgermany/easylistgermany.txt",
        "format": "abp",
        "level": 0,
        "regional": "de",
        "min_filters": 500,
    },
    {
        "id": "liste-fr",
        "title": "Liste FR",
        "homepage": "https://forums.lanik.us/viewforum.php?f=91",
        "license": EASYLIST_LICENSE,
        "license_url": "https://easylist.to/pages/licence.html",
        "url": "https://easylist-downloads.adblockplus.org/liste_fr.txt",
        "format": "abp",
        "level": 0,
        "regional": "fr",
        "min_filters": 500,
    },
    {
        "id": "easylist-italy",
        "title": "EasyList Italy",
        "homepage": "https://easylist.to/",
        "license": EASYLIST_LICENSE,
        "license_url": "https://easylist.to/pages/licence.html",
        "url": "https://easylist-downloads.adblockplus.org/easylistitaly.txt",
        "format": "abp",
        "level": 0,
        "regional": "it",
        "min_filters": 500,
    },
    {
        "id": "easylist-spanish",
        "title": "EasyList Spanish",
        "homepage": "https://easylist.to/",
        "license": EASYLIST_LICENSE,
        "license_url": "https://easylist.to/pages/licence.html",
        "url": "https://easylist-downloads.adblockplus.org/easylistspanish.txt",
        "format": "abp",
        "level": 0,
        "regional": "es",
        "min_filters": 500,
    },
    {
        "id": "easylist-dutch",
        "title": "EasyList Dutch",
        "homepage": "https://easylist.to/",
        "license": EASYLIST_LICENSE,
        "license_url": "https://easylist.to/pages/licence.html",
        "url": "https://easylist-downloads.adblockplus.org/easylistdutch.txt",
        "format": "abp",
        "level": 0,
        "regional": "nl",
        "min_filters": 500,
    },
]
LIST_ID = re.compile(r"[a-z0-9][a-z0-9-]{0,62}")


class BuildError(Exception):
    """A failure the caller reports and exits on."""


# --- Filter conversion -------------------------------------------------------------------------

# ABP option name -> DNR resource type.
TYPE_OPTIONS = {
    "script": "script",
    "image": "image",
    "stylesheet": "stylesheet",
    "css": "stylesheet",
    "object": "object",
    "xmlhttprequest": "xmlhttprequest",
    "xhr": "xmlhttprequest",
    "subdocument": "sub_frame",
    "frame": "sub_frame",
    "ping": "ping",
    "beacon": "ping",
    "websocket": "websocket",
    "media": "media",
    "font": "font",
    "other": "other",
    "document": "main_frame",
    "doc": "main_frame",
}
# Request kinds DNR has no resource type for. A filter for only these is dropped.
UNSUPPORTED_TYPES = {
    "popup": "popup",
    "popunder": "popup",
    "webrtc": "webrtc",
    "object-subrequest": "object-subrequest",
}
ALL_RESOURCE_TYPES = [
    "main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object",
    "xmlhttprequest", "ping", "csp_report", "media", "websocket", "webtransport", "webbundle",
    "other",
]
# Modifiers DNR cannot express, each with the reason the manifest counts it under.
UNSUPPORTED_OPTIONS = {
    "csp": "csp",
    "redirect": "redirect",
    "redirect-rule": "redirect",
    "rewrite": "redirect",
    "empty": "redirect",
    "mp4": "redirect",
    "removeparam": "removeparam",
    "queryprune": "removeparam",
    "replace": "response-rewrite",
    "hls": "response-rewrite",
    "jsonprune": "response-rewrite",
    "xmlprune": "response-rewrite",
    "uritransform": "response-rewrite",
    "urltransform": "response-rewrite",
    "urlskip": "response-rewrite",
    "header": "header",
    "removeheader": "header",
    "permissions": "header",
    "referrerpolicy": "header",
    "cookie": "header",
    "inline-script": "csp",
    "inline-font": "csp",
    "genericblock": "genericblock",
    "ipaddress": "unsupported-option",
    "cname": "unsupported-option",
    "strict1p": "unsupported-option",
    "strict3p": "unsupported-option",
    "app": "unsupported-option",
    "network": "unsupported-option",
    "dnstype": "unsupported-option",
    "dnsrewrite": "unsupported-option",
    "client": "unsupported-option",
    "ctag": "unsupported-option",
    "sitekey": "unsupported-option",
    "content": "unsupported-option",
    "jsinject": "unsupported-option",
    "urlblock": "unsupported-option",
    "extension": "unsupported-option",
    "stealth": "unsupported-option",
}
# Exception modifiers that only switch cosmetic filtering off: phase 2 reads them.
COSMETIC_EXCEPTION_OPTIONS = {"elemhide", "ehide", "generichide", "ghide", "specifichide", "shide"}
KNOWN_OPTIONS = (
    set(TYPE_OPTIONS) | set(UNSUPPORTED_TYPES) | set(UNSUPPORTED_OPTIONS) | COSMETIC_EXCEPTION_OPTIONS
    | {"third-party", "3p", "first-party", "1p", "domain", "from", "to", "denyallow", "method",
       "match-case", "important", "badfilter", "all"}
)
REQUEST_METHODS = {"connect", "delete", "get", "head", "options", "patch", "post", "put", "other"}

COSMETIC = re.compile(r'^([^/|@"!]*?)#(@?[?$%]{0,2})#(.*)$')
ADGUARD_HTML = re.compile(r"^[^/|]*\$@?\$")
# Selectors a style sheet cannot hold (uBO and ABP procedural operators).
PROCEDURAL = re.compile(
    r":(?:has-text|contains|-abp-[a-z-]+|matches-(?:css|attr|path|media|prop)[a-z-]*|min-text-length"
    r"|upward|xpath|watch-attr|remove(?:-attr|-class)?|style|others|if(?:-not)?|nth-ancestor)\("
)
OPTION_TOKEN = re.compile(r"~?[A-Za-z0-9_-]+(?:=.*)?")
PURE_HOST = re.compile(r"\|\|((?:[a-z0-9_](?:[a-z0-9_-]*[a-z0-9_])?\.)+[a-z][a-z0-9-]*[a-z0-9])\^")
DOMAIN = re.compile(r"(?:[a-z0-9_](?:[a-z0-9_-]*[a-z0-9_])?\.)*[a-z0-9_](?:[a-z0-9_-]*[a-z0-9_])?")
# A urlFilter that starts at a host of two labels or more and ends the host there
# (||ads.example/ok/, ||example.com^): the rule applies to that site and its subdomains only.
HOST_ANCHORED = re.compile(r"\|\|(?:[a-z0-9_](?:[a-z0-9_-]*[a-z0-9_])?\.)+[a-z][a-z0-9-]*[a-z0-9][/^:?]")
# What RE2 rejects that list regexes use: lookaround, backreferences, atomic and possessive forms.
RE2_UNSUPPORTED = re.compile(r"\(\?[=!<>]|\\[1-9]|\(\?>|[*+?}]\+|\\[zZGK]")
HOSTS_LINE = re.compile(r"^(?:0\.0\.0\.0|127\.0\.0\.1|::1?)\s+(\S+)")
LOCAL_HOSTS = {"localhost", "localhost.localdomain", "local", "broadcasthost", "0.0.0.0"}


class Dropped(Exception):
    """A filter the converter does not turn into a rule. `reason` is the manifest's count key."""

    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def encode_domain(domain):
    """Lower-case ASCII (punycode) form of a domain, or None when it is not a plain domain."""
    domain = domain.strip().lower().rstrip(".")
    if not domain:
        return None
    if not domain.isascii():
        try:
            domain = domain.encode("idna").decode("ascii")
        except UnicodeError:
            return None
    return domain if DOMAIN.fullmatch(domain) else None


def split_options(text):
    """(pattern, options text or None). The options start at the last `$` that begins a list of
    option tokens; a `$` inside a regular expression or a value is not one."""
    positions = [i for i, char in enumerate(text) if char == "$"]
    for index in reversed(positions):
        rest = text[index + 1:]
        if rest and all(OPTION_TOKEN.fullmatch(token) for token in rest.split(",")):
            return text[:index], rest
    # A value with its own `$` or comma (removeparam=/x$/, csp=...): take the first `$` that
    # starts a known option.
    for index in positions:
        name = re.match(r"~?([A-Za-z0-9_-]+)", text[index + 1:])
        if name and name.group(1).lower() in KNOWN_OPTIONS:
            return text[:index], text[index + 1:]
    return text, None


def parse_domain_list(value, separator="|"):
    """(included, excluded) domains of a domain=, to= or denyallow= value."""
    included, excluded = [], []
    for entry in value.split(separator):
        entry = entry.strip()
        if not entry:
            continue
        negated = entry.startswith("~")
        domain = encode_domain(entry[1:] if negated else entry)
        if domain is None:
            # example.* (any suffix) and /regex/ entries have no DNR form. Without an excluded
            # one the rule would block where the list says not to, so the filter goes; without
            # an included one the rule only applies in fewer places.
            if negated:
                raise Dropped("domain-pattern")
            continue
        (excluded if negated else included).append(domain)
    if not included and not excluded:
        raise Dropped("domain-pattern")
    return sorted(set(included)), sorted(set(excluded))


def convert_pattern(pattern, condition):
    """Sets urlFilter, regexFilter or requestDomains in `condition` from an ABP pattern."""
    if len(pattern) > 2 and pattern.startswith("/") and pattern.endswith("/"):
        regex = pattern[1:-1]
        if not regex.isascii():
            raise Dropped("regex-unsupported")
        if RE2_UNSUPPORTED.search(regex):
            raise Dropped("regex-unsupported")
        try:
            re.compile(regex)
        except (re.error, RecursionError, OverflowError):
            raise Dropped("regex-unsupported") from None
        condition["regexFilter"] = regex
        return
    if any(char.isspace() for char in pattern):
        raise Dropped("invalid")
    # Leading and trailing wildcards say nothing in either syntax.
    stripped = pattern.strip("*") if not pattern.startswith("|") else pattern.rstrip("*")
    if stripped.startswith("||"):
        # DNR refuses a wildcard straight after the domain anchor (||*ads): any host matches.
        rest = stripped[2:].lstrip("*")
        stripped = "||" + rest if rest == stripped[2:] else rest
        if stripped.startswith("||"):
            host_end = re.search(r"[/^*?|:]", stripped[2:])
            host = stripped[2:host_end.start() + 2] if host_end else stripped[2:]
            if not host.isascii():
                try:
                    encoded = host.encode("idna").decode("ascii")
                except UnicodeError:
                    raise Dropped("invalid") from None
                stripped = "||" + encoded + stripped[2 + len(host):]
    if stripped in ("|", "||", "^"):
        raise Dropped("invalid")
    if not stripped:
        return  # No URL condition: the domains decide (checked by the caller).
    if not stripped.isascii():
        stripped = "".join(
            char if char.isascii() else "".join(f"%{byte:02X}" for byte in char.encode("utf-8"))
            for char in stripped
        )
    host = PURE_HOST.fullmatch(stripped.lower())
    if host and "requestDomains" not in condition:
        condition["requestDomains"] = [host.group(1)]
        return
    condition["urlFilter"] = stripped


def url_filter_regex(url_filter):
    """A Python regular expression for a DNR urlFilter (`||` domain anchor, `|` anchors, `*`,
    `^` separator), as Chromium matches it: close enough to ask what a pattern can match."""
    prefix, suffix = "", ""
    if url_filter.startswith("||"):
        prefix, url_filter = r"^[a-z][a-z0-9+.-]*://(?:[^/?#]*\.)?", url_filter[2:]
    elif url_filter.startswith("|"):
        prefix, url_filter = "^", url_filter[1:]
    if url_filter.endswith("|"):
        suffix, url_filter = "$", url_filter[:-1]
    body = "".join(
        ".*" if char == "*" else r"(?:[^A-Za-z0-9_.%-]|$)" if char == "^" else re.escape(char)
        for char in url_filter
    )
    return prefix + body + suffix


def matches_every_address(condition):
    """True when the rule's urlFilter or regexFilter matches every address in BROAD_PROBES
    under one scheme, or is shorter than MIN_BROAD_PATTERN_CHARS, or is missing."""
    if "regexFilter" in condition:
        text, expression = condition["regexFilter"], condition["regexFilter"]
    elif "urlFilter" in condition:
        text = re.sub(r"[|*^]", "", condition["urlFilter"])
        expression = url_filter_regex(condition["urlFilter"])
    else:
        return True
    if len(text) < MIN_BROAD_PATTERN_CHARS:
        return True
    flags = 0 if condition.get("isUrlFilterCaseSensitive") else re.IGNORECASE
    try:
        return any(all(re.search(expression, f"{scheme}://{probe}", flags) for probe in BROAD_PROBES)
                   for scheme in ("https", "http"))
    except (re.error, RecursionError, OverflowError):
        return False


def names_domain(condition):
    """True when the rule applies only to requests to, or from, sites it names: requestDomains
    or initiatorDomains that hold nothing but names of two labels or more. A single-label name
    (com, net, org, any name without a dot) covers every site under it and names none, and a
    list with one such name in it is as wide as that name. The excluded forms say where a rule
    does not apply, so they never name a domain."""
    return any(
        condition.get(key) and all("." in domain for domain in condition[key])
        for key in ("requestDomains", "initiatorDomains"))


def takes_pages_or_frames(condition):
    """True when the rule matches main_frame or sub_frame requests, as DNR reads the types:
    without resourceTypes everything but main_frame, less the excluded types (and main_frame
    too once any type is excluded)."""
    types = condition.get("resourceTypes")
    if types is not None:
        return bool({"main_frame", "sub_frame"} & set(types))
    excluded = set(condition.get("excludedResourceTypes", []))
    return "sub_frame" not in excluded or (bool(excluded) and "main_frame" not in excluded)


def is_too_broad(rule):
    """True for a rule no list should carry (security CB-04): it names no domain, its pattern
    says next to nothing about the address, and it is an exception (one line then switches
    blocking off everywhere) or a block rule that takes pages or frames (one line then blocks
    every page). A block rule for other request kinds is left to the list: it breaks pages,
    visibly, and blocks nothing a person asked to see."""
    condition = rule["condition"]
    if names_domain(condition):
        return False
    if not matches_every_address(condition):
        return False
    if rule["action"]["type"] != "block":
        return True
    return takes_pages_or_frames(condition)


def is_page_exception(rule):
    """True for an exception a build must not gain unread (security CB-04): one line of it can
    switch blocking off for whole pages. That is every allowAllRequests rule (what
    @@...$document converts to: nothing is blocked in that page or frame), and an allow rule for
    main_frame or sub_frame requests that is tied to no site: it names no domain (names_domain)
    and its pattern does not start at a host of two labels or more (||example.com/...).
    is_too_broad drops the widest of these at conversion; no test of a pattern finds every wide
    one (@@.com/$document), so what is left is for a person to read."""
    kind, condition = rule["action"]["type"], rule["condition"]
    if kind == "allowAllRequests":
        return True
    if kind != "allow" or not takes_pages_or_frames(condition):
        return False
    return not names_domain(condition) and not HOST_ANCHORED.match(condition.get("urlFilter", "").lower())


def convert_network_filter(text):
    """DNR rules (without ids) for one network filter line. Raises Dropped."""
    exception = text.startswith("@@")
    pattern, options = split_options(text[2:] if exception else text)
    condition = {}
    types, excluded_types = set(), set()
    unsupported_type = None
    important = False
    cosmetic_exception = False
    for option in (options.split(",") if options else []):
        option = option.strip()
        negated = option.startswith("~")
        name, _, value = (option[1:] if negated else option).partition("=")
        name = name.lower()
        if name in ("", "_"):
            continue
        if name == "badfilter":
            raise Dropped("badfilter")
        if name in UNSUPPORTED_OPTIONS:
            raise Dropped(UNSUPPORTED_OPTIONS[name])
        if name in COSMETIC_EXCEPTION_OPTIONS:
            if not exception or negated:
                raise Dropped("invalid")
            cosmetic_exception = True
        elif name in UNSUPPORTED_TYPES:
            if not negated:
                unsupported_type = UNSUPPORTED_TYPES[name]
        elif name in TYPE_OPTIONS:
            if TYPE_OPTIONS[name] == "main_frame" and negated:
                continue  # ~document is the default.
            (excluded_types if negated else types).add(TYPE_OPTIONS[name])
        elif name == "all":
            types.update(ALL_RESOURCE_TYPES)
        elif name in ("third-party", "3p"):
            condition["domainType"] = "firstParty" if negated else "thirdParty"
        elif name in ("first-party", "1p"):
            condition["domainType"] = "thirdParty" if negated else "firstParty"
        elif name in ("domain", "from"):
            included, excluded = parse_domain_list(value)
            if included:
                condition["initiatorDomains"] = included
            if excluded:
                condition["excludedInitiatorDomains"] = excluded
        elif name == "to":
            included, excluded = parse_domain_list(value)
            if included:
                condition["requestDomains"] = included
            if excluded:
                condition["excludedRequestDomains"] = excluded
        elif name == "denyallow":
            included, excluded = parse_domain_list(value)
            if excluded:
                raise Dropped("invalid")
            condition["excludedRequestDomains"] = sorted(
                set(condition.get("excludedRequestDomains", [])) | set(included))
        elif name == "method":
            methods = [method.strip().lower() for method in value.split("|") if method.strip()]
            negations = {method.startswith("~") for method in methods}
            names = sorted({method.lstrip("~") for method in methods})
            if not names or len(negations) != 1 or not set(names) <= REQUEST_METHODS:
                raise Dropped("invalid")
            condition["excludedRequestMethods" if negations == {True} else "requestMethods"] = names
        elif name == "match-case":
            condition["isUrlFilterCaseSensitive"] = True
        elif name == "important":
            important = True
        else:
            raise Dropped("unknown-option")
    types -= excluded_types
    if unsupported_type and not types:
        raise Dropped(unsupported_type)
    if cosmetic_exception and not types:
        raise Dropped("cosmetic-exception")
    convert_pattern(pattern, condition)
    if "urlFilter" not in condition and "regexFilter" not in condition:
        condition.pop("isUrlFilterCaseSensitive", None)
    if not {"urlFilter", "regexFilter", "requestDomains", "initiatorDomains"} & set(condition):
        raise Dropped("too-broad")
    if exception:
        priority = PRIORITY_IMPORTANT_ALLOW if important else PRIORITY_ALLOW
    else:
        priority = PRIORITY_IMPORTANT if important else PRIORITY_BLOCK
    rules = []
    if exception and "main_frame" in types:
        # @@...$document: nothing is blocked on that page.
        page = dict(condition, resourceTypes=["main_frame"])
        rules.append({"priority": priority, "action": {"type": "allowAllRequests"}, "condition": page})
        types = types - {"main_frame"}
        if not types:
            return refuse_broad(rules)
    if types:
        condition["resourceTypes"] = [kind for kind in ALL_RESOURCE_TYPES if kind in types]
    elif excluded_types:
        # With only excluded types DNR would match main_frame too, which a filter never does
        # unless it says $document.
        excluded = excluded_types | {"main_frame"}
        condition["excludedResourceTypes"] = [kind for kind in ALL_RESOURCE_TYPES if kind in excluded]
    rules.append({
        "priority": priority,
        "action": {"type": "allow" if exception else "block"},
        "condition": condition,
    })
    return refuse_broad(rules)


def refuse_broad(rules):
    """`rules`, unless one of them is too broad to sign: then the whole filter is dropped."""
    if any(is_too_broad(rule) for rule in rules):
        raise Dropped("too-broad")
    return rules


def classify_cosmetic(separator, body):
    """The manifest's count key for a cosmetic filter line."""
    if separator in ("@",):
        return "exception"
    if "%" in separator or body.startswith("+js(") or body.startswith("^"):
        return "scriptlet"
    if "$" in separator or "?" in separator or PROCEDURAL.search(body):
        return "procedural"
    return "hide"


def new_stats():
    return {
        "lines": 0,
        "comments": 0,
        "network": 0,
        "converted": 0,
        "duplicate": 0,
        "dropped": {},
        "cosmetic": {"hide": 0, "exception": 0, "procedural": 0, "scriptlet": 0},
    }


def convert_list(text, list_format="abp", refused=None):
    """(rules, stats, header) for a filter list's text. Rules get ids from 1 in order: first the
    rules for whole hosts, merged by everything but the host, then the rest in list order.
    `refused`: a list that gets the lines dropped as too broad, for the build's log (the stats
    only count them: they go into the signed manifest, and a list's text does not belong there)."""
    stats = new_stats()
    header = {}
    converted = []  # (line, [rule, ...])
    bad = set()
    for raw in text.splitlines():
        line = raw.strip().lstrip("﻿")
        if not line:
            continue
        stats["lines"] += 1
        if line.startswith("!") or (line.startswith("[") and line.endswith("]")):
            stats["comments"] += 1
            field = re.match(r"!\s*(Title|Version|Last modified|Expires|Homepage|Licence|License):\s*(.+)", line, re.I)
            if field and field.group(1).lower() not in header:
                header[field.group(1).lower().replace(" ", "_")] = field.group(2).strip()
            continue
        if list_format == "hosts":
            if line.startswith("#"):
                stats["comments"] += 1
                continue
            line = line.split("#", 1)[0].strip()
            host = HOSTS_LINE.match(line)
            name = (host.group(1) if host else line).lower()
            stats["network"] += 1
            domain = None if name in LOCAL_HOSTS or " " in name else encode_domain(name)
            if domain is None or "." not in domain:
                stats["dropped"]["invalid"] = stats["dropped"].get("invalid", 0) + 1
                continue
            line = f"||{domain}^"
        else:
            cosmetic = COSMETIC.match(line)
            if cosmetic:
                stats["cosmetic"][classify_cosmetic(cosmetic.group(2), cosmetic.group(3))] += 1
                continue
            if ADGUARD_HTML.match(line):
                stats["cosmetic"]["scriptlet"] += 1
                continue
            stats["network"] += 1
        try:
            converted.append((line, convert_network_filter(line)))
        except Dropped as dropped:
            if dropped.reason == "badfilter":
                bad.add(re.sub(r"(?:\$|,)badfilter\b", "", line))
            elif dropped.reason == "too-broad" and refused is not None:
                refused.append(line)
            stats["dropped"][dropped.reason] = stats["dropped"].get(dropped.reason, 0) + 1
    seen = set()
    host_groups = {}  # condition without the host -> rule
    ordered = []
    for line, rules in converted:
        if line in bad:
            stats["dropped"]["badfilter"] = stats["dropped"].get("badfilter", 0) + 1
            continue
        fresh = False
        for rule in rules:
            key = json.dumps(rule, sort_keys=True)
            if key in seen:
                continue
            seen.add(key)
            fresh = True
            condition = rule["condition"]
            if len(condition.get("requestDomains", [])) == 1 and "urlFilter" not in condition \
                    and "regexFilter" not in condition:
                rest = dict(condition)
                host = rest.pop("requestDomains")[0]
                group = json.dumps({**rule, "condition": rest}, sort_keys=True)
                if group in host_groups:
                    host_groups[group]["condition"]["requestDomains"].append(host)
                else:
                    host_groups[group] = rule
                    ordered.append(rule)
            else:
                ordered.append(rule)
        stats["converted" if fresh else "duplicate"] += 1
    merged = [rule for rule in ordered if "requestDomains" in rule["condition"]
              and "urlFilter" not in rule["condition"] and "regexFilter" not in rule["condition"]]
    merged_ids = {id(rule) for rule in merged}
    for rule in merged:
        rule["condition"]["requestDomains"] = sorted(set(rule["condition"]["requestDomains"]))
    rules = merged + [rule for rule in ordered if id(rule) not in merged_ids]
    rules = [{"id": index, **rule} for index, rule in enumerate(rules, 1)]
    stats["dropped"] = dict(sorted(stats["dropped"].items()))
    return rules, stats, header


def rule_counts(rules):
    counts = {"rules": len(rules), "regex": 0, "block": 0, "allow": 0, "allow_all_requests": 0,
              "request_domains": 0}
    keys = {"block": "block", "allow": "allow", "allowAllRequests": "allow_all_requests"}
    for rule in rules:
        counts[keys[rule["action"]["type"]]] += 1
        counts["regex"] += "regexFilter" in rule["condition"]
        counts["request_domains"] += len(rule["condition"].get("requestDomains", []))
    return counts


CONDITION_KEYS = {
    "urlFilter", "regexFilter", "isUrlFilterCaseSensitive", "domainType", "initiatorDomains",
    "excludedInitiatorDomains", "requestDomains", "excludedRequestDomains", "resourceTypes",
    "excludedResourceTypes", "requestMethods", "excludedRequestMethods",
}
DOMAIN_KEYS = ("initiatorDomains", "excludedInitiatorDomains", "requestDomains", "excludedRequestDomains")


def validate_rules(rules):
    """Raises BuildError for a rule Chromium's indexer would refuse (IndexedRule::CreateIndexedRule
    in extensions/browser/api/declarative_net_request/indexed_rule.cc). The converter should
    never write one; this is the check that it did not."""
    for index, rule in enumerate(rules, 1):
        def bad(why):
            raise BuildError(f"rule {index} is not valid DNR ({why}): {json.dumps(rule)[:200]}")
        if set(rule) != {"id", "priority", "action", "condition"}:
            bad("keys")
        if rule["id"] != index or rule["priority"] < 1:
            bad("id or priority")
        kind = rule["action"].get("type")
        if rule["action"] != {"type": kind} or kind not in ("block", "allow", "allowAllRequests"):
            bad("action")
        condition = rule["condition"]
        if not set(condition) <= CONDITION_KEYS:
            bad("condition keys")
        if "urlFilter" in condition and "regexFilter" in condition:
            bad("two filters")
        for key in ("urlFilter", "regexFilter"):
            if key in condition and (not condition[key] or not condition[key].isascii()):
                bad(key)
        if condition.get("urlFilter", "").startswith("||*"):
            bad("wildcard after the domain anchor")
        for key in DOMAIN_KEYS:
            if key in condition:
                domains = condition[key]
                if not domains or any(not DOMAIN.fullmatch(domain) for domain in domains):
                    bad(key)
        types = condition.get("resourceTypes")
        excluded = condition.get("excludedResourceTypes")
        for value in (types, excluded):
            if value is not None and (not value or not set(value) <= set(ALL_RESOURCE_TYPES)
                                      or len(set(value)) != len(value)):
                bad("resource types")
        if types and excluded and set(types) & set(excluded):
            bad("a resource type both ways")
        if kind == "allowAllRequests" and (not types or not set(types) <= {"main_frame", "sub_frame"}):
            bad("allowAllRequests needs main_frame or sub_frame")
        for key in ("requestMethods", "excludedRequestMethods"):
            if key in condition and (not condition[key] or not set(condition[key]) <= REQUEST_METHODS):
                bad(key)
        if condition.get("domainType") not in (None, "firstParty", "thirdParty"):
            bad("domainType")
        if is_too_broad(rule):
            bad("too broad: no domain but top-level names and a pattern that matches every address")


def rules_json(rules):
    """One rule per line: stable to diff and to hash."""
    if not rules:
        return b"[]\n"
    lines = ",\n".join(json.dumps(rule, separators=(",", ":"), ensure_ascii=True) for rule in rules)
    return f"[\n{lines}\n]\n".encode("ascii")


def check_limits(lists):
    """(problems, report). `lists`: manifest list entries. Problems fail the build."""
    problems = []
    if len(lists) > MAX_NUMBER_OF_STATIC_RULESETS:
        problems.append(f"{len(lists)} rulesets, Chromium allows {MAX_NUMBER_OF_STATIC_RULESETS} per extension")
    for entry in lists:
        counts = entry["rules"]
        if counts["count"] > MAX_RULES_PER_RULESET:
            problems.append(f"{entry['id']}: {counts['count']} rules, a ruleset holds at most {MAX_RULES_PER_RULESET}")
        if counts["regex"] > MAX_NUMBER_OF_REGEX_RULES:
            problems.append(f"{entry['id']}: {counts['regex']} regex rules, the limit is {MAX_NUMBER_OF_REGEX_RULES}")
    report = {
        "guaranteed_minimum_static_rules": GUARANTEED_MINIMUM_STATIC_RULES,
        "max_static_rules_per_profile": MAX_STATIC_RULES_PER_PROFILE,
        "max_regex_rules": MAX_NUMBER_OF_REGEX_RULES,
        "max_enabled_static_rulesets": MAX_NUMBER_OF_ENABLED_STATIC_RULESETS,
        "levels": {},
    }
    combos = [(LEVELS[level], [entry for entry in lists if 0 < entry["level"] <= level]) for level in LEVELS]
    combos.append(("all", list(lists)))
    for name, members in combos:
        rules = sum(entry["rules"]["count"] for entry in members)
        regex = sum(entry["rules"]["regex"] for entry in members)
        report["levels"][name] = {
            "lists": [entry["id"] for entry in members],
            "rules": rules,
            "regex": regex,
            # Above the guaranteed minimum the rest comes from the pool other extensions share.
            "from_global_pool": max(0, rules - GUARANTEED_MINIMUM_STATIC_RULES),
        }
        if len(members) > MAX_NUMBER_OF_ENABLED_STATIC_RULESETS:
            problems.append(f"{name}: {len(members)} rulesets enabled together, the limit is {MAX_NUMBER_OF_ENABLED_STATIC_RULESETS}")
        if rules > MAX_RULES_PER_RULESET:
            problems.append(f"{name}: {rules} rules enabled together, above the guaranteed {GUARANTEED_MINIMUM_STATIC_RULES} plus the whole global pool of {MAX_STATIC_RULES_PER_PROFILE}")
        elif 2 * max(0, rules - GUARANTEED_MINIMUM_STATIC_RULES) > MAX_STATIC_RULES_PER_PROFILE:
            # On a list update the engine switches the new bundle's lists on before the old
            # bundle's go (tab/095, security CB-02), each in a blocker of its own.
            problems.append(f"{name}: {rules} rules; during a list update two bundles are on at once, and twice the {rules - GUARANTEED_MINIMUM_STATIC_RULES} rules above the guaranteed minimum is more than the global pool of {MAX_STATIC_RULES_PER_PROFILE}")
        if regex > MAX_NUMBER_OF_REGEX_RULES:
            problems.append(f"{name}: {regex} regex rules enabled together, the limit is {MAX_NUMBER_OF_REGEX_RULES}")
    return problems, report


# --- Ed25519 -----------------------------------------------------------------------------------

SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")  # SubjectPublicKeyInfo of a raw Ed25519 key


def _cryptography():
    if os.environ.get("REARC_BLOCKLISTS_NO_CRYPTOGRAPHY"):
        return None
    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import ed25519
    except ImportError:
        return None
    return serialization, ed25519


def _openssl():
    for candidate in filter(None, [os.environ.get("REARC_OPENSSL"), shutil.which("openssl"),
                                   "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"]):
        try:
            version = subprocess.run([candidate, "version"], capture_output=True, text=True, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        found = re.match(r"OpenSSL (\d+)\.", version)
        if found and int(found.group(1)) >= 3:
            return candidate
    raise BuildError("Ed25519 needs the Python package `cryptography` or an OpenSSL 3 `openssl`")


def _pem(label, der):
    body = base64.encodebytes(der).decode("ascii")
    return f"-----BEGIN {label}-----\n{body}-----END {label}-----\n"


def _private_key_bytes(key_path):
    """The private key's PEM text, refusing a key other users can read."""
    key_path = Path(key_path)
    if not key_path.is_file():
        raise BuildError(f"no signing key at {key_path} (build-blocklists.py keygen)")
    if key_path.stat().st_mode & 0o077:
        raise BuildError(f"{key_path} is readable by others; chmod 600 it")
    return key_path.read_bytes()


def generate_key(key_path):
    """Creates the private key (PKCS#8 PEM, mode 600) unless it exists. True when created."""
    key_path = Path(key_path)
    if key_path.exists():
        return False
    key_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    crypto = _cryptography()
    if crypto:
        serialization, ed25519 = crypto
        pem = ed25519.Ed25519PrivateKey.generate().private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    else:
        pem = subprocess.run([_openssl(), "genpkey", "-algorithm", "ed25519"],
                             capture_output=True, check=True, timeout=30).stdout
    try:
        handle = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return False  # Another run made it first; use that one.
    with os.fdopen(handle, "wb") as out:
        out.write(pem)
    return True


def public_key_of(key_path):
    """Base64 of the raw 32-byte public key."""
    pem = _private_key_bytes(key_path)
    crypto = _cryptography()
    if crypto:
        serialization, _ = crypto
        raw = serialization.load_pem_private_key(pem, password=None).public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    else:
        der = subprocess.run([_openssl(), "pkey", "-in", str(key_path), "-pubout", "-outform", "DER"],
                             capture_output=True, check=True, timeout=30).stdout
        if not der.startswith(SPKI_PREFIX) or len(der) != len(SPKI_PREFIX) + 32:
            raise BuildError(f"{key_path} is not an Ed25519 key")
        raw = der[len(SPKI_PREFIX):]
    return base64.b64encode(raw).decode("ascii")


def sign(data, key_path):
    """Base64 Ed25519 signature of `data`."""
    pem = _private_key_bytes(key_path)
    crypto = _cryptography()
    if crypto:
        serialization, ed25519 = crypto
        key = serialization.load_pem_private_key(pem, password=None)
        if not isinstance(key, ed25519.Ed25519PrivateKey):
            raise BuildError(f"{key_path} is not an Ed25519 key")
        signature = key.sign(data)
    else:
        with tempfile.TemporaryDirectory() as work:
            message = Path(work) / "message"
            message.write_bytes(data)
            signature = subprocess.run(
                [_openssl(), "pkeyutl", "-sign", "-inkey", str(key_path), "-rawin", "-in", str(message)],
                capture_output=True, check=True, timeout=30).stdout
    if len(signature) != 64:
        raise BuildError("the signature is not 64 bytes")
    return base64.b64encode(signature).decode("ascii")


def verify_signature(data, signature_b64, public_key_b64):
    """True when `signature_b64` is `public_key_b64`'s Ed25519 signature of `data`."""
    try:
        signature = base64.b64decode(signature_b64.strip(), validate=True)
        public = base64.b64decode(public_key_b64.strip(), validate=True)
    except (ValueError, TypeError):
        return False
    if len(signature) != 64 or len(public) != 32:
        return False
    crypto = _cryptography()
    if crypto:
        _, ed25519 = crypto
        from cryptography.exceptions import InvalidSignature
        try:
            ed25519.Ed25519PublicKey.from_public_bytes(public).verify(signature, data)
        except InvalidSignature:
            return False
        return True
    with tempfile.TemporaryDirectory() as work:
        work = Path(work)
        (work / "message").write_bytes(data)
        (work / "signature").write_bytes(signature)
        (work / "public.pem").write_text(_pem("PUBLIC KEY", SPKI_PREFIX + public))
        result = subprocess.run(
            [_openssl(), "pkeyutl", "-verify", "-pubin", "-inkey", str(work / "public.pem"), "-rawin",
             "-in", str(work / "message"), "-sigfile", str(work / "signature")],
            capture_output=True, timeout=30)
    return result.returncode == 0


# --- Bundle ------------------------------------------------------------------------------------

def sha256(data):
    return hashlib.sha256(data).hexdigest()


class HttpsOnlyRedirects(urllib.request.HTTPRedirectHandler):
    """Follows a redirect only to another https address (security CB-04): a list fetched over
    plain http is whatever the network says it is."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.lower().startswith("https://"):
            raise BuildError(f"{req.full_url}: redirected to {newurl}, which is not https")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


OPENER = urllib.request.build_opener(HttpsOnlyRedirects)


def fetch(url, opener=None):
    """The bytes at an https URL, over https at every hop. No cookies, no identifying headers."""
    if not url.startswith("https://"):
        raise BuildError(f"{url}: only https sources")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "text/plain, */*"})
    last = None
    for _ in range(3):
        try:
            with (opener or OPENER).open(request, timeout=60) as response:
                final = response.geturl()
                data = response.read(MAX_DOWNLOAD_BYTES + 1)
                encoding = response.headers.get("Content-Encoding", "")
        except OSError as error:  # URLError, timeouts, resets
            last = error
            continue
        if not final.lower().startswith("https://"):
            raise BuildError(f"{url}: answered from {final}, which is not https")
        if encoding == "gzip":
            data = gzip.decompress(data)
        if len(data) > MAX_DOWNLOAD_BYTES:
            raise BuildError(f"{url}: more than {MAX_DOWNLOAD_BYTES} bytes")
        return data
    raise BuildError(f"{url}: {last}")


def decode_list(data, source):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise BuildError(f"{source}: not UTF-8 text") from None
    if re.match(r"\s*<(?:!doctype|html)", text, re.I):
        raise BuildError(f"{source}: an HTML page, not a filter list")
    return text


def select_lists(ids, with_regional):
    if ids:
        by_id = {entry["id"]: entry for entry in CATALOGUE}
        unknown = [name for name in ids if name not in by_id]
        if unknown:
            raise BuildError(f"unknown list: {', '.join(unknown)} (known: {', '.join(by_id)})")
        return [by_id[name] for name in dict.fromkeys(ids)]
    return [entry for entry in CATALOGUE if with_regional or not entry.get("regional")]


def new_version(now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    return now.strftime("%Y%m%d%H%M")


def count_changes(entry, before):
    """The counts of a list that moved by more than MAX_COUNT_CHANGE against `before`, the same
    list's manifest entry in the bundle it replaces, as text. The rule count alone would miss a
    list of hosts, which is one rule however many hosts it names."""
    moved = []
    for key, name in (("count", "rules"), ("request_domains", "hosts")):
        old, new = before["rules"].get(key, 0), entry["rules"].get(key, 0)
        change = abs(new - old)
        if change > COUNT_CHANGE_SLACK and change > MAX_COUNT_CHANGE * old:
            share = f"{(new - old) / old:+.0%}" if old else "from none"
            moved.append(f"{old} to {new} {name} ({share})")
    return moved


def rule_key(rule):
    """A rule as comparable text (no id)."""
    return json.dumps({key: rule[key] for key in ("priority", "action", "condition")}, sort_keys=True)


def exception_keys(rules):
    """The allow and allowAllRequests rules of a list as comparable text."""
    return {rule_key(rule) for rule in rules if rule["action"]["type"] != "block"}


def page_exception_keys(rules):
    """The exceptions for whole pages or frames among `rules` (is_page_exception) as comparable
    text, one for each requested domain. The converter merges @@||a.example^$document and
    @@||b.example^$document into one rule; a merged rule that gained a host must show that host
    and not all of them, and one that only lost a host gained nothing."""
    keys = set()
    for rule in rules:
        condition = rule["condition"]
        for domain in condition.get("requestDomains") or [None]:
            single = rule if domain is None else dict(rule, condition=dict(condition, requestDomains=[domain]))
            if is_page_exception(single):
                keys.add(rule_key(single))
    return keys


def build_bundle(out, lists, *, key=None, from_bundle=None, from_public_key=None, raw_dir=None,
                 version=None, now=None, fetcher=fetch, log=print, previous=None,
                 previous_public_key=None, allow_count_change=False,
                 accept_gained_page_exceptions=False):
    """Writes a bundle to `out` (replaced) and returns its manifest. Raw list text comes from
    `from_bundle`'s raw/ files (a bundle signed by `from_public_key` when that is given), from
    `raw_dir` (<id>.txt), or from each list's URL.

    `previous`: the bundle this one replaces (signed by `previous_public_key` when that is
    given). A list whose counts moved by more than MAX_COUNT_CHANGE against it fails the build
    unless `allow_count_change`, and the exceptions each list gained are logged. A gained
    exception for whole pages or frames (is_page_exception) fails the build unless
    `accept_gained_page_exceptions`; for a list `previous` does not have, every such exception
    is gained."""
    replaced_bundle = previous
    now = now or datetime.datetime.now(datetime.timezone.utc)
    version = version or new_version(now)
    if not re.fullmatch(r"\d{12}", version):
        raise BuildError(f"version {version!r} is not YYYYMMDDHHMM")
    previous = {}
    if from_bundle:
        from_bundle = Path(from_bundle)
        previous_manifest = verify_bundle(from_bundle, from_public_key,
                                          require_signature=from_public_key is not None)
        previous = {entry["id"]: entry for entry in previous_manifest["lists"]}
    replaced, moved, gained_pages = None, [], []
    if replaced_bundle:
        replaced_bundle = Path(replaced_bundle)
        replaced_manifest = verify_bundle(replaced_bundle, previous_public_key,
                                          require_signature=previous_public_key is not None)
        replaced = {entry["id"]: entry for entry in replaced_manifest["lists"]}
        log(f"comparing with bundle {replaced_manifest['version']} in {replaced_bundle}")
    entries, payload = [], {}
    for item in lists:
        list_id = item["id"]
        if not LIST_ID.fullmatch(list_id):
            raise BuildError(f"list id {list_id!r}")
        fetched = now.strftime("%Y-%m-%dT%H:%M:%SZ")
        if from_bundle:
            if list_id not in previous:
                raise BuildError(f"{from_bundle} has no list {list_id}")
            places = [from_bundle / "raw"] + ([Path(raw_dir)] if raw_dir else [])
            raw_path = next((place / f"{list_id}.txt" for place in places
                             if (place / f"{list_id}.txt").is_file()), None)
            if raw_path is None:
                raise BuildError(f"no {list_id}.txt in {' or '.join(map(str, places))} to convert again "
                                 "(--raw-dir names where that bundle's upstream files are kept)")
            raw = raw_path.read_bytes()
            if sha256(raw) != previous[list_id]["source"]["sha256"]:
                raise BuildError(f"{raw_path} does not match the sha256 in {from_bundle}'s manifest")
            fetched = previous[list_id]["source"].get("fetched", fetched)
        elif raw_dir:
            raw = (Path(raw_dir) / f"{list_id}.txt").read_bytes()
        else:
            log(f"fetching {list_id}: {item['url']}")
            raw = fetcher(item["url"])
        text = decode_list(raw, list_id)
        refused = []
        rules, stats, header = convert_list(text, item.get("format", "abp"), refused)
        for line in refused:
            log(f"{list_id}: refused as too broad: {line[:200]}")
        if stats["network"] < item.get("min_filters", 0):
            raise BuildError(f"{list_id}: {stats['network']} network filters, expected at least "
                             f"{item['min_filters']} (a cut-off or wrong download?)")
        validate_rules(rules)
        data = rules_json(rules)
        counts = rule_counts(rules)
        payload[f"rules/{list_id}.json"] = data
        payload[f"raw/{list_id}.txt"] = raw
        entry = {
            "id": list_id,
            "title": item["title"],
            "homepage": item["homepage"],
            "license": item["license"],
            "license_url": item.get("license_url", ""),
            "level": item.get("level", 0),
            "source": {
                "url": item["url"],
                "sha256": sha256(raw),
                "bytes": len(raw),
                "version": header.get("version", ""),
                "last_modified": header.get("last_modified", ""),
                "fetched": fetched,
            },
            "rules": {
                "path": f"rules/{list_id}.json",
                "sha256": sha256(data),
                "bytes": len(data),
                "count": counts["rules"],
                "regex": counts["regex"],
                "block": counts["block"],
                "allow": counts["allow"],
                "allow_all_requests": counts["allow_all_requests"],
                "request_domains": counts["request_domains"],
            },
            "filters": stats,
        }
        if item.get("regional"):
            entry["regional"] = item["regional"]
        entries.append(entry)
        log(f"{list_id}: {counts['rules']} rules ({counts['regex']} regex) from {stats['converted']} of "
            f"{stats['network']} network filters; dropped {sum(stats['dropped'].values())}")
        if replaced is None:
            continue
        if list_id not in replaced:
            log(f"{list_id}: not in the bundle this one replaces; nothing to compare")
            gained_pages += [(list_id, text) for text in sorted(page_exception_keys(rules))]
            continue
        for change in count_changes(entry, replaced[list_id]):
            moved.append(f"{list_id}: {change}")
        try:
            before = json.loads((replaced_bundle / "rules" / f"{list_id}.json").read_bytes())
        except (OSError, ValueError):
            raise BuildError(f"{replaced_bundle}: rules/{list_id}.json cannot be read") from None
        gained = sorted(exception_keys(rules) - exception_keys(before))
        if gained:
            log(f"{list_id}: {len(gained)} exception(s) the replaced bundle did not have:")
            for text in gained[:MAX_PRINTED_EXCEPTIONS]:
                log(f"  {text[:300]}")
            if len(gained) > MAX_PRINTED_EXCEPTIONS:
                log(f"  and {len(gained) - MAX_PRINTED_EXCEPTIONS} more")
        gained_pages += [(list_id, text)
                         for text in sorted(page_exception_keys(rules) - page_exception_keys(before))]
    failures = []
    if moved:
        report = "\n  ".join(moved)
        if not allow_count_change:
            failures.append(
                f"a list moved by more than {MAX_COUNT_CHANGE:.0%} against the bundle it replaces:\n  "
                f"{report}\nRead what changed upstream, then build with --allow-count-change")
        else:
            log(f"lists that moved by more than {MAX_COUNT_CHANGE:.0%} (allowed by --allow-count-change):\n  {report}")
    if gained_pages:
        report = "\n  ".join(f"{list_id}: {text[:300]}" for list_id, text in gained_pages[:MAX_PRINTED_EXCEPTIONS])
        if len(gained_pages) > MAX_PRINTED_EXCEPTIONS:
            report += f"\n  and {len(gained_pages) - MAX_PRINTED_EXCEPTIONS} more"
        count = f"{len(gained_pages)} exception(s) for whole pages or frames that the replaced bundle did not have"
        if not accept_gained_page_exceptions:
            failures.append(
                f"{count}:\n  {report}\nEach can switch blocking off where it applies. Read them, then "
                "build with --accept-gained-page-exceptions (a person's decision; no job passes it)")
        else:
            log(f"{count} (accepted by --accept-gained-page-exceptions):\n  {report}")
    if failures:
        raise BuildError("\n".join(failures))
    problems, report = check_limits(entries)
    for name, level in report["levels"].items():
        log(f"level {name}: {level['rules']} rules, {level['regex']} regex, "
            f"{level['from_global_pool']} from the global pool")
    if problems:
        raise BuildError("Chromium's DNR limits are exceeded:\n  " + "\n  ".join(problems))
    manifest = {
        "format": FORMAT,
        "version": version,
        "created": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "min_engine": MIN_ENGINE,
        "priorities": {
            "block": PRIORITY_BLOCK,
            "allow": PRIORITY_ALLOW,
            "important": PRIORITY_IMPORTANT,
            "important_allow": PRIORITY_IMPORTANT_ALLOW,
            "site_exception": PRIORITY_SITE_EXCEPTION,
        },
        "lists": entries,
        "limits": report,
    }
    manifest_bytes = (json.dumps(manifest, indent=1, ensure_ascii=True) + "\n").encode("ascii")
    out = Path(out).absolute()
    out.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".blocklists-", dir=out.parent))
    try:
        for name, data in payload.items():
            path = staging / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (staging / "manifest.json").write_bytes(manifest_bytes)
        if key:
            (staging / "manifest.json.sig").write_text(sign(manifest_bytes, key))
        if out.exists():
            shutil.rmtree(out)
        os.replace(staging, out)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    out.chmod(0o755)
    return manifest


def read_public_keys(path=None):
    """The lists keys a bundle may be signed with: one base64 key a line, `#` lines are
    comments. The first is the key in use; a later one is a key being retired or brought in
    (engine/docs/RELEASE.md "Lists key"). The app accepts the same keys
    (BlocklistSigningKey.compiledInTexts)."""
    path = Path(path or PUBLIC_KEY_FILE)
    if not path.is_file():
        raise BuildError(f"no public key at {path}")
    keys = [line.strip() for line in path.read_text().splitlines()]
    keys = [line for line in keys if line and not line.startswith("#")]
    if not keys:
        raise BuildError(f"no public key in {path}")
    return keys


def verify_bundle(bundle, public_key=None, require_signature=True):
    """The manifest of a bundle whose signature (unless not required) and file hashes hold.
    `public_key`: one key or several, any of which may have signed; the committed keys when
    None. Raises BuildError naming the first thing that does not."""
    bundle = Path(bundle)
    manifest_path = bundle / "manifest.json"
    if not manifest_path.is_file():
        raise BuildError(f"{bundle}: no manifest.json")
    manifest_bytes = manifest_path.read_bytes()
    if require_signature:
        signature_path = bundle / "manifest.json.sig"
        if not signature_path.is_file():
            raise BuildError(f"{bundle}: no manifest.json.sig")
        keys = public_key or read_public_keys()
        keys = [keys] if isinstance(keys, str) else list(keys)
        signature = signature_path.read_text()
        if not any(verify_signature(manifest_bytes, signature, key) for key in keys):
            raise BuildError(f"{bundle}: the signature does not match manifest.json and the lists key")
    try:
        manifest = json.loads(manifest_bytes)
    except ValueError:
        raise BuildError(f"{bundle}: manifest.json is not JSON") from None
    if not isinstance(manifest, dict) or manifest.get("format") != FORMAT:
        raise BuildError(f"{bundle}: unknown manifest format")
    if not re.fullmatch(r"\d{12}", str(manifest.get("version", ""))):
        raise BuildError(f"{bundle}: bad version")
    seen = set()
    for entry in manifest.get("lists", []):
        list_id = entry.get("id", "")
        if not LIST_ID.fullmatch(list_id) or list_id in seen:
            raise BuildError(f"{bundle}: bad or repeated list id {list_id!r}")
        seen.add(list_id)
        rules = entry.get("rules", {})
        if rules.get("path") != f"rules/{list_id}.json":
            raise BuildError(f"{bundle}: {list_id} names an unexpected rules path")
        path = bundle / "rules" / f"{list_id}.json"
        if not path.is_file() or path.is_symlink():
            raise BuildError(f"{bundle}: rules/{list_id}.json is missing")
        if sha256(path.read_bytes()) != rules.get("sha256"):
            raise BuildError(f"{bundle}: rules/{list_id}.json does not match its sha256 in the manifest")
        raw = bundle / "raw" / f"{list_id}.txt"
        if raw.is_file() and sha256(raw.read_bytes()) != entry.get("source", {}).get("sha256"):
            raise BuildError(f"{bundle}: raw/{list_id}.txt does not match its sha256 in the manifest")
    if not seen:
        raise BuildError(f"{bundle}: no lists")
    return manifest


def app_files(bundle, manifest):
    """The bundle's files the app and the mirror carry, as relative paths: no raw/."""
    return ["manifest.json", "manifest.json.sig"] + [entry["rules"]["path"] for entry in manifest["lists"]]


def install_bundle(bundle, destination, public_key=None):
    """Verifies `bundle` and copies what the app uses to `destination` (replaced)."""
    bundle, destination = Path(bundle), Path(destination)
    manifest = verify_bundle(bundle, public_key)
    if destination.exists():
        shutil.rmtree(destination)
    for name in app_files(bundle, manifest):
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(bundle / name, target)
    verify_bundle(destination, public_key)
    return manifest


def pack_bundle(bundle, out, base_url=MIRROR_URL, public_key=None):
    """Verifies `bundle` and writes out/blocklists-<version>.tar.gz and out/latest.json. The
    archive is the same bytes for the same bundle. Returns latest.json's content."""
    bundle, out = Path(bundle), Path(out)
    manifest = verify_bundle(bundle, public_key)
    version = manifest["version"]
    name = f"blocklists-{version}"
    mtime = int(datetime.datetime.strptime(version, "%Y%m%d%H%M").replace(tzinfo=datetime.timezone.utc).timestamp())
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb", mtime=0, filename="") as zipped:
        with tarfile.open(fileobj=zipped, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            def add(path, data=None):
                info = tarfile.TarInfo(path)
                info.mtime, info.uid, info.gid, info.uname, info.gname = mtime, 0, 0, "", ""
                if data is None:
                    info.type, info.mode = tarfile.DIRTYPE, 0o755
                    archive.addfile(info)
                else:
                    info.size, info.mode = len(data), 0o644
                    archive.addfile(info, io.BytesIO(data))
            add(name)
            add(f"{name}/rules")
            for relative in sorted(app_files(bundle, manifest)):
                add(f"{name}/{relative}", (bundle / relative).read_bytes())
    data = buffer.getvalue()
    out.mkdir(parents=True, exist_ok=True)
    (out / f"{name}.tar.gz").write_bytes(data)
    latest = {"version": version, "url": base_url.rstrip("/") + f"/{name}.tar.gz", "sha256": sha256(data)}
    (out / "latest.json").write_text(json.dumps(latest, indent=1) + "\n")
    return latest


# --- Command line ------------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build", help="fetch, convert, check limits, write and sign a bundle")
    build.add_argument("--out", required=True, type=Path)
    build.add_argument("--key", type=Path, default=DEFAULT_KEY)
    build.add_argument("--no-sign", action="store_true", help="write no manifest.json.sig")
    build.add_argument("--from-bundle", type=Path,
                       help="convert this signed bundle's raw/ files again; no fetch")
    build.add_argument("--from-unsigned", action="store_true",
                       help="take --from-bundle without checking its signature")
    build.add_argument("--raw-dir", type=Path,
                       help="read <id>.txt from here instead of fetching; with --from-bundle, "
                            "where that bundle's upstream files are when it has no raw/")
    build.add_argument("--lists", help="comma-separated list ids (default: every non-regional list)")
    build.add_argument("--with-regional", action="store_true")
    build.add_argument("--version", help="YYYYMMDDHHMM (default: now, UTC)")
    build.add_argument("--previous", type=Path,
                       help="the signed bundle this one replaces, to compare each list's counts "
                            "with (default: the repository's shell/Resources/Blocklists)")
    build.add_argument("--public-key", type=Path,
                       help="the keys --from-bundle and --previous must be signed with "
                            "(default: the committed keys)")
    build.add_argument("--allow-count-change", action="store_true",
                       help=f"build although a list's rule or host count moved by more than "
                            f"{MAX_COUNT_CHANGE:.0%} against --previous")
    build.add_argument("--accept-gained-page-exceptions", action="store_true",
                       help="build although a list gained an exception for whole pages or frames "
                            "against --previous; for a person who has read them, never for a job "
                            "that runs by itself")
    verify = commands.add_parser("verify", help="check a bundle's signature and file hashes")
    verify.add_argument("bundle", type=Path)
    verify.add_argument("--public-key", type=Path)
    pack = commands.add_parser("pack", help="write the mirror's tar.gz and latest.json")
    pack.add_argument("bundle", type=Path)
    pack.add_argument("--out", required=True, type=Path)
    pack.add_argument("--base-url", default=MIRROR_URL)
    pack.add_argument("--public-key", type=Path)
    install = commands.add_parser("install", help="copy what the app uses of a verified bundle")
    install.add_argument("bundle", type=Path)
    install.add_argument("destination", type=Path)
    install.add_argument("--public-key", type=Path)
    keygen = commands.add_parser("keygen", help="create the signing key unless it exists")
    keygen.add_argument("--key", type=Path, default=DEFAULT_KEY)
    keygen.add_argument("--public-key", type=Path, help="also write the public key here")
    args = parser.parse_args(argv)
    try:
        if args.command == "build":
            lists = select_lists(args.lists.split(",") if args.lists else None, args.with_regional)
            if args.from_bundle and not args.lists and not args.with_regional:
                # The same lists as the bundle that is converted again.
                previous = json.loads((args.from_bundle / "manifest.json").read_text())
                lists = select_lists([entry["id"] for entry in previous["lists"]], False)
            from_key = None
            if args.from_bundle and not args.from_unsigned:
                from_key = read_public_keys(args.public_key)
            previous = args.previous
            if previous is None and (BUILT_IN_BUNDLE / "manifest.json").is_file():
                previous = BUILT_IN_BUNDLE
            if previous is None:
                print("no bundle to compare with (--previous): the lists' counts and the exceptions "
                      "they gained are not checked")
            manifest = build_bundle(
                args.out, lists, key=None if args.no_sign else args.key, from_bundle=args.from_bundle,
                from_public_key=from_key, raw_dir=args.raw_dir, version=args.version,
                previous=previous,
                previous_public_key=read_public_keys(args.public_key) if previous else None,
                allow_count_change=args.allow_count_change,
                accept_gained_page_exceptions=args.accept_gained_page_exceptions)
            if not args.no_sign:
                verify_bundle(args.out, public_key_of(args.key))
            print(f"bundle {manifest['version']} in {args.out}" + (" (unsigned)" if args.no_sign else ""))
        elif args.command == "verify":
            manifest = verify_bundle(args.bundle, read_public_keys(args.public_key))
            print(f"ok: bundle {manifest['version']}, {len(manifest['lists'])} lists")
        elif args.command == "pack":
            latest = pack_bundle(args.bundle, args.out, args.base_url, read_public_keys(args.public_key))
            print(json.dumps(latest))
        elif args.command == "install":
            manifest = install_bundle(args.bundle, args.destination, read_public_keys(args.public_key))
            print(f"installed bundle {manifest['version']} in {args.destination}")
        elif args.command == "keygen":
            created = generate_key(args.key)
            public = public_key_of(args.key)
            if args.public_key:
                args.public_key.write_text(public + "\n")
            print(f"{'created' if created else 'kept'} {args.key}", file=sys.stderr)
            print(public)
    except BuildError as error:
        print(f"build-blocklists: {error}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as error:
        print(f"build-blocklists: {error.cmd[0]} failed: {error.stderr.decode(errors='replace').strip()}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

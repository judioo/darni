import Foundation
import SidebarModel

/// The self-test's page for built-in ad and tracker blocking
/// (docs/FEATURE-SPECS/CONTENT-BLOCKING.md §8, security CB-02).
///
/// The loopback fixture server serves a page that asks for two scripts, one
/// from a tracker's host and one from an ad server's host. Both names are in
/// the built-in lists as whole hosts, so the real lists block them: the
/// tracker at every level, the ad from Ads and trackers up. The self-test's
/// resolver rule answers both names with 127.0.0.1, where the fixture server
/// listens, so nothing leaves the Mac, and the server counts what it is asked
/// for. "Was it fetched" is then the server's word, not the page's.
///
/// Here, outside `REARC_CHROMIUM`, so the unit tests can hold the fixture
/// against the bundle in the repository: a list update that drops one of the
/// hosts fails a test, not a self-test run on the screen.
enum SelfTestBlockingFixture {
    /// In EasyPrivacy and Peter Lowe's list (level 1, Trackers only).
    static let trackerHost = "2o7.net"
    /// In EasyList alone (level 2, Ads and trackers).
    static let adHost = "adsterra.com"

    static let pagePath = "/blocking"
    static let trackerScriptPath = "/blocking/tracker.js"
    static let adScriptPath = "/blocking/ad.js"

    /// A site under a private suffix, for the engine's site names
    /// (CONTENT-BLOCKING.md §9): `azurewebsites.net` is in the public suffix
    /// list, so every name under it is a site of its own, and the shell's old
    /// guess took all of `azurewebsites.net` for the site of this one
    /// (security CB-12). The self-test loads the page above from it, through
    /// the resolver rule and the fixture server.
    ///
    /// The label has an underscore, which Azure does not give out: nobody
    /// can take this name. Should the resolver switches ever be lost, the
    /// self-test would then find no page there, not a stranger's.
    static let siteSuffix = "azurewebsites.net"
    static let siteHost = "rearc_selftest.\(siteSuffix)"

    /// `--host-resolver-rules` entries that answer the fixture's names with
    /// the loopback address. They go before the rule that fails every other name.
    static let resolverRules = "MAP \(trackerHost) 127.0.0.1, MAP \(adHost) 127.0.0.1, MAP \(siteHost) 127.0.0.1"

    /// The page of one load. `run` is in the address, in the page's title
    /// and in its two requests, so a verdict and the server's counts belong
    /// to one load and never to the one before.
    static func pageURL(base: String, run: Int) -> URL {
        URL(string: "\(base)\(pagePath)?run=\(run)")!
    }

    /// The page. Its title becomes `blocking:run=<n>:tracker=<how>,ad=<how>`
    /// once both requests ended, `how` being `loaded` or `blocked`.
    static let pageHTML = """
    <!doctype html><html><head><title>blocking-pending</title></head>
    <body style="font:24px -apple-system"><h1>ReArc selftest blocking page</h1><script>
    var run = new URLSearchParams(location.search).get('run') || '0', seen = {};
    function settle(name, how) {
      seen[name] = how;
      if (seen.tracker && seen.ad) document.title = 'blocking:run=' + run + ':tracker=' + seen.tracker + ',ad=' + seen.ad;
    }
    function request(name, host) {
      var s = document.createElement('script');
      s.onload = function () { settle(name, 'loaded'); };
      s.onerror = function () { settle(name, 'blocked'); };
      s.src = 'http://' + host + ':' + location.port + '/blocking/' + name + '.js?run=' + run;
      document.head.appendChild(s);
    }
    request('tracker', '\(trackerHost)');
    request('ad', '\(adHost)');
    </script></body></html>
    """

    /// What the page saw of its two requests in one load.
    struct Verdict: Equatable {
        var run: Int
        var trackerBlocked: Bool
        var adBlocked: Bool

        /// From the page's title; nil while the page is still waiting.
        init?(title: String?) {
            guard let parts = title?.split(separator: ":"), parts.count == 3, parts[0] == "blocking",
                  parts[1].hasPrefix("run="), let run = Int(parts[1].dropFirst(4)) else { return nil }
            var seen: [Substring: Bool] = [:]
            for field in parts[2].split(separator: ",") {
                let pair = field.split(separator: "=")
                guard pair.count == 2, pair[1] == "blocked" || pair[1] == "loaded" else { return nil }
                seen[pair[0]] = pair[1] == "blocked"
            }
            guard seen.count == 2, let tracker = seen["tracker"], let ad = seen["ad"] else { return nil }
            self.run = run
            trackerBlocked = tracker
            adBlocked = ad
        }

        init(run: Int, trackerBlocked: Bool, adBlocked: Bool) {
            self.run = run
            self.trackerBlocked = trackerBlocked
            self.adBlocked = adBlocked
        }

        var text: String { "tracker \(trackerBlocked ? "blocked" : "loaded"), ad \(adBlocked ? "blocked" : "loaded")" }
    }

    /// The run of a request for one of the two scripts (`…?run=3`); nil for another path.
    static func scriptRequest(_ pathAndQuery: String) -> (isTracker: Bool, run: Int)? {
        let parts = pathAndQuery.split(separator: "?", maxSplits: 1)
        guard let route = parts.first, route == trackerScriptPath || route == adScriptPath else { return nil }
        let run = parts.count > 1 ? parts[1].split(separator: "&").first { $0.hasPrefix("run=") }.flatMap { Int($0.dropFirst(4)) } : nil
        return (route == trackerScriptPath, run ?? 0)
    }

    // MARK: The fixture against a bundle

    /// The lowest blocking level at which `bundle`'s lists block every
    /// third-party request to `host`: the level of a list with a block rule
    /// for the whole host and no other condition. nil when no list has one.
    static func blockingLevel(of host: String, in bundle: VerifiedBlocklist) -> Int? {
        var lowest: Int?
        for list in bundle.manifest.lists where list.level > 0 {
            guard rules(of: list, in: bundle).contains(where: { blocksWholeHost($0, host) }) else { continue }
            lowest = min(lowest ?? list.level, list.level)
        }
        return lowest
    }

    /// Why the fixture does not fit `bundle`; empty when it does. The
    /// tracker's host must be blocked from Trackers only, the ad's host from
    /// Ads and trackers and not before, and no list may carry an exception
    /// that names either host.
    static func problems(in bundle: VerifiedBlocklist) -> [String] {
        var problems: [String] = []
        let tracker = blockingLevel(of: trackerHost, in: bundle)
        if tracker != 1 {
            problems.append("\(trackerHost) is blocked from level \(tracker.map(String.init) ?? "none") in bundle \(bundle.version), not from 1 (Trackers only)")
        }
        let ad = blockingLevel(of: adHost, in: bundle)
        if ad != 2 {
            problems.append("\(adHost) is blocked from level \(ad.map(String.init) ?? "none") in bundle \(bundle.version), not from 2 (Ads and trackers)")
        }
        for list in bundle.manifest.lists {
            for rule in rules(of: list, in: bundle) where (rule["action"] as? [String: Any])?["type"] as? String != "block" {
                let condition = rule["condition"] as? [String: Any] ?? [:]
                let domains = (condition["requestDomains"] as? [String] ?? []) + (condition["initiatorDomains"] as? [String] ?? [])
                let filter = (condition["urlFilter"] as? String ?? "") + (condition["regexFilter"] as? String ?? "")
                for host in [trackerHost, adHost] where domains.contains(where: { covers($0, host) }) || filter.contains(host) {
                    problems.append("\(list.id) has an exception that names \(host)")
                }
            }
        }
        return problems
    }

    private static func rules(of list: BlocklistManifest.List, in bundle: VerifiedBlocklist) -> [[String: Any]] {
        let file = bundle.directory.appendingPathComponent("rules/\(list.id).json")
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    private static func covers(_ domain: String, _ host: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    /// A block rule for the whole host: `requestDomains` covers it and the
    /// only other condition, if any, is `domainType: thirdParty` (the
    /// fixture's requests are third-party: its page is on 127.0.0.1).
    private static func blocksWholeHost(_ rule: [String: Any], _ host: String) -> Bool {
        guard (rule["action"] as? [String: Any])?["type"] as? String == "block",
              let condition = rule["condition"] as? [String: Any],
              let domains = condition["requestDomains"] as? [String], domains.contains(where: { covers($0, host) }) else { return false }
        let others = condition.filter { $0.key != "requestDomains" }
        return others.isEmpty || (others.count == 1 && others["domainType"] as? String == "thirdParty")
    }

    // MARK: The blocked list's page

    /// A second page for "Blocked on this page" (spec §3, patch `tab/098`,
    /// security BL-09), for what the first page's two hosts cannot show.
    /// From 127.0.0.1 it asks for addresses the lists block by their path
    /// alone, on any host: EasyPrivacy's `/1pixel.php` and EasyList's
    /// `/88/tag.min.js`.
    ///
    /// - As it is: `localhost` for the pixel twice and the tag once, and a
    ///   public suffix for the pixel once. Two names that are not one site:
    ///   both are listed, `localhost` once with 3 and both tags, and neither
    ///   may have Allow.
    /// - `cap=1`: the pixel on `listCapSites` made-up sites, more than one
    ///   page's list holds.
    /// - `quiet=1`: nothing, so a navigation to it must leave the list empty.
    ///
    /// A blocked request never leaves the engine, and the self-test's
    /// resolver fails every name but its own, so no made-up name is asked of
    /// anyone.
    static let listPagePath = "/blocking/list"
    static let listHost = "localhost"
    /// A public suffix: a name sites hang under, never a site.
    static let listSuffixHost = "co.uk"
    /// EasyPrivacy (level 1): a tracker's pixel.
    static let listPixelPath = "/1pixel.php"
    /// EasyList (level 2): an ad network's script.
    static let listTagPath = "/88/tag.min.js"
    /// What the page as it is asks for: the pixel twice and the tag on `listHost`, the pixel on `listSuffixHost`.
    static let listRequests = 4
    static let listHostRequests = 3
    /// More sites than one page's list holds (`ContentBlockingBlockedList.maxEntries`).
    static let listCapSites = ContentBlockingBlockedList.maxEntries + 5
    /// Every made-up site's name starts with this. The page builds it from
    /// two pieces, so the whole of it is in no file the page is kept in, and
    /// the self-test can look for it on disk afterwards (security BL-09).
    static let listCapMarker = "rearc-blocked-cap-"

    enum ListMode: String {
        case sites, cap, quiet
    }

    static func listPageURL(base: String, run: Int, mode: ListMode = .sites) -> URL {
        URL(string: "\(base)\(listPagePath)?run=\(run)\(mode == .sites ? "" : "&\(mode.rawValue)=1")")!
    }

    /// Its title becomes `blocked-list:run=<n>:failed=<requests that did not load>`
    /// once every request ended, or `blocked-list:run=<n>:quiet` at once.
    static let listPageHTML = """
    <!doctype html><html><head><title>blocked-list-pending</title></head>
    <body style="font:24px -apple-system"><h1>ReArc selftest blocked list page</h1><script>
    var query = new URLSearchParams(location.search), run = query.get('run') || '0';
    var left = 0, failed = 0;
    function settle() {
      if (--left === 0) document.title = 'blocked-list:run=' + run + ':failed=' + failed;
    }
    function address(host, path, n) { return 'http://' + host + ':' + location.port + path + '?run=' + run + '&n=' + n; }
    function pixel(host, n) {
      left++;
      var image = new Image();
      image.onload = settle;
      image.onerror = function () { failed++; settle(); };
      image.src = address(host, '\(listPixelPath)', n);
    }
    function tag(host) {
      left++;
      var script = document.createElement('script');
      script.onload = settle;
      script.onerror = function () { failed++; settle(); };
      script.src = address(host, '\(listTagPath)', 0);
      document.head.appendChild(script);
    }
    if (query.get('quiet')) {
      document.title = 'blocked-list:run=' + run + ':quiet';
    } else if (query.get('cap')) {
      for (var n = 0; n < \(listCapSites); n++) pixel('rearc-blocked-' + 'cap-' + n + '.test', n);
    } else {
      pixel('\(listHost)', 0);
      pixel('\(listHost)', 1);
      tag('\(listHost)');
      pixel('\(listSuffixHost)', 0);
    }
    </script></body></html>
    """

    /// What the list page saw in one load: how many of its requests did not
    /// load; `quiet` when it asked for nothing.
    struct ListVerdict: Equatable {
        var run: Int
        var quiet = false
        var failed = 0

        init(run: Int, quiet: Bool = false, failed: Int = 0) {
            self.run = run
            self.quiet = quiet
            self.failed = failed
        }

        /// From the page's title; nil while the page is still waiting.
        init?(title: String?) {
            guard let parts = title?.split(separator: ":"), parts.count == 3, parts[0] == "blocked-list",
                  parts[1].hasPrefix("run="), let run = Int(parts[1].dropFirst(4)) else { return nil }
            self.run = run
            if parts[2] == "quiet" {
                quiet = true
                return
            }
            guard parts[2].hasPrefix("failed="), let failed = Int(parts[2].dropFirst(7)), failed >= 0 else { return nil }
            self.failed = failed
        }
    }

    /// A request for the pixel or the tag, which the fixture server answers
    /// when the engine lets one through; nil for another path.
    static func listRequestIsTag(_ pathAndQuery: String) -> Bool? {
        let route = pathAndQuery.split(separator: "?", maxSplits: 1).first.map(String.init)
        guard route == listPixelPath || route == listTagPath else { return nil }
        return route == listTagPath
    }

    /// Why the list page does not fit `bundle`; empty when it does: the
    /// pixel's path must be blocked by a list of Trackers only and the tag's
    /// by a list of Ads and trackers, each by a rule with no other condition.
    static func listProblems(in bundle: VerifiedBlocklist) -> [String] {
        func level(ofPath path: String) -> Int? {
            bundle.manifest.lists.filter { list in
                list.level > 0 && rules(of: list, in: bundle).contains { rule in
                    let condition = rule["condition"] as? [String: Any] ?? [:]
                    return (rule["action"] as? [String: Any])?["type"] as? String == "block"
                        && condition.count == 1 && condition["urlFilter"] as? String == path
                }
            }.map(\.level).min()
        }
        var problems: [String] = []
        if level(ofPath: listPixelPath) != 1 {
            problems.append("\(listPixelPath) is blocked from level \(level(ofPath: listPixelPath).map(String.init) ?? "none") in bundle \(bundle.version), not from 1")
        }
        if level(ofPath: listTagPath) != 2 {
            problems.append("\(listTagPath) is blocked from level \(level(ofPath: listTagPath).map(String.init) ?? "none") in bundle \(bundle.version), not from 2")
        }
        return problems
    }

    // MARK: The cold launch

    /// `--rearc-selftest` with this flag is the self-test's cold launch for
    /// blocking: a second process the self-test starts, whose only step is
    /// a restored tab on the page above.
    static let coldLaunchFlag = "--rearc-selftest-cold-blocking"

    static func isColdLaunch(_ arguments: [String]) -> Bool {
        arguments.contains(coldLaunchFlag)
    }

    /// What one cold launch does (`--rearc-selftest-cold-step=`).
    enum ColdStep: String, CaseIterable {
        /// Blocking on (a new install's state); the restored tab and the
        /// restored Little ReArc window must fetch neither the tracker nor the ad.
        case restore
        /// Blocking off from the start (an existing install that never turned
        /// it on): both pages fetch both, and the engine gets no blocker. It
        /// leaves a used profile whose blocker has no state.
        case off
        /// As `restore`, then a newer bundle arrives from the update folder and
        /// takes over from the one that is blocking (a list update).
        case takeover
    }

    static let coldStepFlag = "--rearc-selftest-cold-step="
    /// The shell's `Blocklists` folder, kept from one cold launch to the next
    /// (a downloaded bundle stays, as it does for a person).
    static let coldListsFlag = "--rearc-selftest-cold-lists="
    /// The folder with `latest.json` and the bundle archive the takeover step
    /// gets from its mirror stand-in (`SelfTestFileMirror`).
    static let coldUpdateFlag = "--rearc-selftest-cold-update="
    /// A lists key the self-test made for this run (base64 of 32 raw bytes).
    static let coldListsKeyFlag = "--rearc-selftest-cold-lists-key="
    /// After its check the launch switches blocking off and sees both
    /// requests load: the fixture can fetch them at all. That removes the
    /// blocker, so only a profile's last launch is asked for it.
    static let coldCheckOffFlag = "--rearc-selftest-cold-check-off"

    /// The cold launch's one shell profile, the same at every launch. The
    /// engine finds a profile's folder by this ID (`ChromiumProfileStorageMap`):
    /// the first launch on a user data folder adopts `Default` for it, and a
    /// later launch opens `Default` again only for the same ID. A store with a
    /// new ID at every launch got a new engine folder each time, so "the same
    /// profile again" and the launch after a list update never met the last
    /// session's blocker.
    static let coldProfileID = UUID(uuidString: "C01DB10C-0000-4000-8000-5E1F7E57B10C")!

    /// The engine's profile folders in a user data folder that are not the
    /// startup one: `ReArcProfile-…`, made for a shell profile that could not
    /// take `Default`. A cold launch that leaves one did not run in the profile
    /// the launches before it used.
    static func namedProfileFolders(in names: [String]) -> [String] {
        names.filter { $0.hasPrefix(ChromiumProfileStoragePlan.namedDirectoryName(forKey: "")) }.sorted()
    }

    static func coldStep(_ arguments: [String]) -> ColdStep? {
        guard let value = value(of: coldStepFlag, in: arguments) else { return .restore }
        return ColdStep(rawValue: value)
    }

    static func value(of flag: String, in arguments: [String]) -> String? {
        arguments.last { $0.hasPrefix(flag) }.map { String($0.dropFirst(flag.count)) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The cold launch's arguments (without the executable): the self-test's
    /// own, so the same Keychain mode and switches, with the flag and a user
    /// data directory of its own. The engine of this self-test holds its own.
    static func coldLaunchArguments(from arguments: [String], userDataDir: String, step: ColdStep = .restore,
                                    lists: String? = nil, update: String? = nil, listsKey: Data? = nil) -> [String] {
        let own = [coldStepFlag, coldListsFlag, coldUpdateFlag, coldListsKeyFlag, coldCheckOffFlag]
        var result = arguments.dropFirst().filter { argument in
            !argument.hasPrefix(ChromiumLaunchArguments.userDataDirFlag) && argument != coldLaunchFlag
                && !own.contains(where: { argument.hasPrefix($0) })
        }
        result += [coldLaunchFlag, ChromiumLaunchArguments.userDataDirFlag + userDataDir, coldStepFlag + step.rawValue]
        if let lists { result.append(coldListsFlag + lists) }
        if let update { result.append(coldUpdateFlag + update) }
        if let listsKey { result.append(coldListsKeyFlag + listsKey.base64EncodedString()) }
        return result
    }

    // MARK: A lists key for the self-test alone

    /// The lists keys a launch trusts. The compiled-in ones always, and only
    /// they in a bundle people get. The cold launch adds the key its self-test
    /// made for this run (`ChromiumRuntime.selfTestListsKey`), so that the
    /// takeover step can sign a second bundle; that key is never compiled in
    /// and exists only in the two processes of one run. Never in a shipped
    /// bundle, whatever set the runtime's key.
    static func trustedListsKeys(compiledIn: [Data], selfTestKey: Data?, shipped: Bool) -> [Data] {
        guard !shipped, let selfTestKey, selfTestKey.count == 32, !compiledIn.contains(selfTestKey) else { return compiledIn }
        return compiledIn + [selfTestKey]
    }

    /// The cold launch's key from its arguments; nil outside the cold launch.
    static func coldListsKey(_ arguments: [String]) -> Data? {
        guard isColdLaunch(arguments), let text = value(of: coldListsKeyFlag, in: arguments) else { return nil }
        return BlocklistSigningKey.parse(text)
    }

    // MARK: Which blocker the engine will load at the next launch

    /// "ReArc Blocker"'s two extension IDs (engine
    /// `rearc::kContentBlockerExtensionIds`), slot 0 first.
    static let blockerIDs = ["eoaoomnoofleafmoihlpjdhdceloddjm", "kanaeoiolklalbbkdlpbfohpmgkgackf"]

    /// The engine's marker of the blocker that was last ready, per slot: the
    /// bundle version in `extensions.settings.<id>.rearc_ready_bundle` of a
    /// profile's preferences file (`Secure Preferences` holds the extension
    /// settings on the Mac; `Preferences` is read too). nil for a slot with none.
    static func readyMarkers(inPreferences files: [Data]) -> [String?] {
        blockerIDs.map { id in
            for data in files {
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let extensions = root["extensions"] as? [String: Any],
                      let settings = extensions["settings"] as? [String: Any],
                      let entry = settings[id] as? [String: Any],
                      let marker = entry["rearc_ready_bundle"] as? String else { continue }
                return marker
            }
            return nil
        }
    }
}

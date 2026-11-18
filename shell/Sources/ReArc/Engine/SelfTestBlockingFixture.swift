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

    /// `--host-resolver-rules` entries that answer the two names with the
    /// loopback address. They go before the rule that fails every other name.
    static let resolverRules = "MAP \(trackerHost) 127.0.0.1, MAP \(adHost) 127.0.0.1"

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

    // MARK: The cold launch

    /// `--rearc-selftest` with this flag is the self-test's cold launch for
    /// blocking: a second process the self-test starts, whose only step is
    /// a restored tab on the page above.
    static let coldLaunchFlag = "--rearc-selftest-cold-blocking"

    static func isColdLaunch(_ arguments: [String]) -> Bool {
        arguments.contains(coldLaunchFlag)
    }

    /// The cold launch's arguments (without the executable): the self-test's
    /// own, so the same Keychain mode and switches, with the flag and a user
    /// data directory of its own. The engine of this self-test holds its own.
    static func coldLaunchArguments(from arguments: [String], userDataDir: String) -> [String] {
        arguments.dropFirst().filter { !$0.hasPrefix(ChromiumLaunchArguments.userDataDirFlag) && $0 != coldLaunchFlag }
            + [coldLaunchFlag, ChromiumLaunchArguments.userDataDirFlag + userDataDir]
    }
}

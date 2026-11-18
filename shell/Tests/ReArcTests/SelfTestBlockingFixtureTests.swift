import CryptoKit
import XCTest
import SidebarModel
@testable import ReArc

/// The self-test's blocking fixture (CONTENT-BLOCKING.md §8, security CB-02):
/// its two hosts against the lists in the repository, the resolver rule that
/// answers them from the loopback fixture server, what the page reports, and
/// the cold launch's arguments. The self-test itself needs the screen and an
/// engine with `tab/095`; these parts of it do not.
final class SelfTestBlockingFixtureTests: XCTestCase {
    private static let shellDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func builtInBundle() throws -> VerifiedBlocklist {
        try BlocklistVerifier.verify(directory: Self.shellDirectory.appendingPathComponent("Resources/Blocklists", isDirectory: true),
                                     source: .builtIn, publicKeys: BlocklistSigningKey.compiledIn, engine: nil).get()
    }

    /// A signed bundle with these lists: (id, level, rules as JSON text).
    private func bundle(_ lists: [(id: String, level: Int, rules: String)]) throws -> VerifiedBlocklist {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-blocking-fixture-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("rules"), withIntermediateDirectories: true)
        var entries: [[String: Any]] = []
        for list in lists {
            let data = Data(list.rules.utf8)
            try data.write(to: directory.appendingPathComponent("rules/\(list.id).json"))
            entries.append(["id": list.id, "title": list.id, "level": list.level,
                            "rules": ["path": "rules/\(list.id).json", "sha256": BlocklistVerifier.sha256(of: data)]])
        }
        let manifest = try JSONSerialization.data(withJSONObject: ["format": 1, "version": "202611180900", "lists": entries], options: [.sortedKeys])
        let key = Curve25519.Signing.PrivateKey()
        try manifest.write(to: directory.appendingPathComponent("manifest.json"))
        try Data(try key.signature(for: manifest).base64EncodedString().utf8).write(to: directory.appendingPathComponent("manifest.json.sig"))
        return try BlocklistVerifier.verify(directory: directory, source: .downloaded, publicKeys: [key.publicKey.rawRepresentation], engine: nil).get()
    }

    private func hostRule(_ host: String, action: String = "block", extra: String = "") -> String {
        #"{"id":1,"priority":1,"action":{"type":"\#(action)"},"condition":{"requestDomains":["other.test","\#(host)"]\#(extra)}}"#
    }

    // MARK: The hosts and the lists

    /// The lists in the repository block the tracker's host from Trackers
    /// only and the ad's host from Ads and trackers, and except neither. A
    /// list update that changes this fails here, before a self-test run does.
    func testTheFixturesHostsAreInTheBuiltInLists() throws {
        let bundle = try builtInBundle()
        XCTAssertEqual(SelfTestBlockingFixture.blockingLevel(of: SelfTestBlockingFixture.trackerHost, in: bundle), 1)
        XCTAssertEqual(SelfTestBlockingFixture.blockingLevel(of: SelfTestBlockingFixture.adHost, in: bundle), 2)
        XCTAssertEqual(SelfTestBlockingFixture.problems(in: bundle), [])
        XCTAssertNil(SelfTestBlockingFixture.blockingLevel(of: "127.0.0.1", in: bundle), "the fixture's own page is on no list")
        XCTAssertNil(SelfTestBlockingFixture.blockingLevel(of: "localhost", in: bundle))
    }

    func testAHostsLevelIsTheLowestLevelOfAListThatBlocksAllOfIt() throws {
        let tracker = SelfTestBlockingFixture.trackerHost, ad = SelfTestBlockingFixture.adHost
        let fits = try bundle([("privacy", 1, "[\(hostRule(tracker, extra: #","domainType":"thirdParty""#))]"),
                               ("ads", 2, "[\(hostRule(ad)),\(hostRule(tracker))]"),
                               ("regional", 0, "[\(hostRule(ad))]")])
        XCTAssertEqual(SelfTestBlockingFixture.blockingLevel(of: tracker, in: fits), 1)
        XCTAssertEqual(SelfTestBlockingFixture.blockingLevel(of: "cdn.\(tracker)", in: fits), 1, "a list's host covers its subdomains")
        XCTAssertEqual(SelfTestBlockingFixture.blockingLevel(of: ad, in: fits), 2, "a regional list is on at no level")
        XCTAssertEqual(SelfTestBlockingFixture.problems(in: fits), [])

        // A rule with a further condition does not block every request to the host.
        let narrowed = try bundle([("privacy", 1, "[\(hostRule(tracker, extra: #","resourceTypes":["image"]"#))]"),
                                   ("ads", 2, "[\(hostRule(ad, extra: #","initiatorDomains":["news.test"]"#))]")])
        XCTAssertNil(SelfTestBlockingFixture.blockingLevel(of: tracker, in: narrowed))
        XCTAssertNil(SelfTestBlockingFixture.blockingLevel(of: ad, in: narrowed))
        XCTAssertEqual(SelfTestBlockingFixture.problems(in: narrowed).count, 2)
    }

    func testAListUpdateThatMovesOrExceptsAHostIsAProblem() throws {
        let tracker = SelfTestBlockingFixture.trackerHost, ad = SelfTestBlockingFixture.adHost
        // The ad's host moved into a tracker list: Trackers only would block it too.
        let moved = try bundle([("privacy", 1, "[\(hostRule(tracker)),\(hostRule(ad))]"), ("ads", 2, "[\(hostRule(ad))]")])
        XCTAssertEqual(SelfTestBlockingFixture.problems(in: moved),
                       ["\(ad) is blocked from level 1 in bundle 202611180900, not from 2 (Ads and trackers)"])
        // The tracker's host is gone.
        let dropped = try bundle([("privacy", 1, "[]"), ("ads", 2, "[\(hostRule(ad))]")])
        XCTAssertEqual(SelfTestBlockingFixture.problems(in: dropped),
                       ["\(tracker) is blocked from level none in bundle 202611180900, not from 1 (Trackers only)"])
        // An exception names a host, as a domain or in a pattern.
        let excepted = try bundle([("privacy", 1, "[\(hostRule(tracker)),\(hostRule(tracker, action: "allow"))]"),
                                   ("ads", 2, #"[\#(hostRule(ad)),{"id":2,"priority":2,"action":{"type":"allow"},"condition":{"urlFilter":"||\#(ad)/ok/"}}]"#)])
        XCTAssertEqual(SelfTestBlockingFixture.problems(in: excepted),
                       ["privacy has an exception that names \(tracker)", "ads has an exception that names \(ad)"])
    }

    // MARK: The resolver rule

    /// Chromium takes the first rule that matches a name, so the two hosts
    /// come before the rule that fails every other name; nothing else resolves.
    func testTheSelfTestAnswersOnlyTheTwoHostsFromLoopback() throws {
        let arguments = ChromiumLaunchArguments.selfTestArguments(["ReArc", "--user-data-dir=/tmp/x"])
        let rules = try XCTUnwrap(arguments.first { $0.hasPrefix("--host-resolver-rules=") })
        XCTAssertEqual(arguments.filter { $0.hasPrefix("--host-resolver-rules=") }.count, 1)
        let entries = rules.dropFirst("--host-resolver-rules=".count).components(separatedBy: ", ")
        XCTAssertEqual(entries, ["MAP \(SelfTestBlockingFixture.trackerHost) 127.0.0.1", "MAP \(SelfTestBlockingFixture.adHost) 127.0.0.1",
                                 "MAP * ~NOTFOUND", "EXCLUDE 127.0.0.1", "EXCLUDE localhost"])
        // Whole names, no wildcard: a subdomain of either still fails to resolve.
        for host in [SelfTestBlockingFixture.trackerHost, SelfTestBlockingFixture.adHost] {
            XCTAssertFalse(host.contains("*"))
            XCTAssertNotNil(ContentBlockingHost.normalized(host))
        }
        XCTAssertNotEqual(SelfTestBlockingFixture.trackerHost, SelfTestBlockingFixture.adHost)
    }

    // MARK: The page

    func testThePageAsksBothHostsOnTheFixturesPortAndNamesItsLoad() {
        let html = SelfTestBlockingFixture.pageHTML
        XCTAssertTrue(html.contains("request('tracker', '\(SelfTestBlockingFixture.trackerHost)');"))
        XCTAssertTrue(html.contains("request('ad', '\(SelfTestBlockingFixture.adHost)');"))
        XCTAssertTrue(html.contains("'http://' + host + ':' + location.port + '/blocking/' + name + '.js?run=' + run"))
        XCTAssertEqual(SelfTestBlockingFixture.pageURL(base: "http://127.0.0.1:5123", run: 7).absoluteString, "http://127.0.0.1:5123/blocking?run=7")
        XCTAssertEqual(SelfTestBlockingFixture.trackerScriptPath, "/blocking/tracker.js")
        XCTAssertEqual(SelfTestBlockingFixture.adScriptPath, "/blocking/ad.js")
    }

    func testTheVerdictIsReadFromTheTitleOfOneLoad() {
        typealias Verdict = SelfTestBlockingFixture.Verdict
        XCTAssertEqual(Verdict(title: "blocking:run=3:tracker=blocked,ad=loaded"), Verdict(run: 3, trackerBlocked: true, adBlocked: false))
        XCTAssertEqual(Verdict(title: "blocking:run=12:tracker=loaded,ad=blocked"), Verdict(run: 12, trackerBlocked: false, adBlocked: true))
        XCTAssertEqual(Verdict(title: "blocking:run=0:ad=blocked,tracker=blocked"), Verdict(run: 0, trackerBlocked: true, adBlocked: true))
        XCTAssertEqual(Verdict(run: 1, trackerBlocked: true, adBlocked: false).text, "tracker blocked, ad loaded")
        for title in [nil, "", "blocking-pending", "blocking:run=3:tracker=blocked", "blocking:run=x:tracker=blocked,ad=blocked",
                      "blocking:run=3:tracker=maybe,ad=blocked", "blocking:tracker=blocked,ad=blocked", "ReArc Selftest A",
                      "blocking:run=3:tracker=blocked,tracker=loaded"] {
            XCTAssertNil(Verdict(title: title), title ?? "nil")
        }
    }

    func testTheServerCountsARequestUnderItsLoad() {
        XCTAssertTrue(SelfTestBlockingFixture.scriptRequest("/blocking/tracker.js?run=4").map { $0.isTracker && $0.run == 4 } ?? false)
        XCTAssertTrue(SelfTestBlockingFixture.scriptRequest("/blocking/ad.js?x=1&run=9").map { !$0.isTracker && $0.run == 9 } ?? false)
        XCTAssertTrue(SelfTestBlockingFixture.scriptRequest("/blocking/ad.js").map { !$0.isTracker && $0.run == 0 } ?? false)
        XCTAssertNil(SelfTestBlockingFixture.scriptRequest("/blocking?run=4"), "the page itself is not one of the two requests")
        XCTAssertNil(SelfTestBlockingFixture.scriptRequest("/blocking/other.js?run=4"))
        XCTAssertNil(SelfTestBlockingFixture.scriptRequest("/a"))
    }

    // MARK: The cold launch

    func testTheColdLaunchIsTheSelfTestWithItsFlagAndAProfileOfItsOwn() {
        let parent = ["/Apps/ReArc.app/Contents/MacOS/ReArc", "--rearc-selftest", "--user-data-dir=/tmp/parent", "--enable-logging"]
        let child = SelfTestBlockingFixture.coldLaunchArguments(from: parent, userDataDir: "/tmp/cold")
        XCTAssertEqual(child, ["--rearc-selftest", "--enable-logging", "--rearc-selftest-cold-blocking", "--user-data-dir=/tmp/cold"])
        XCTAssertTrue(SelfTestBlockingFixture.isColdLaunch(child))
        XCTAssertFalse(SelfTestBlockingFixture.isColdLaunch(parent))
        XCTAssertEqual(ChromiumLaunchArguments.userDataDir(in: ["ReArc"] + child), "/tmp/cold", "never the profile the self-test's own engine holds")
        // A cold launch never starts another.
        XCTAssertEqual(SelfTestBlockingFixture.coldLaunchArguments(from: ["ReArc"] + child, userDataDir: "/tmp/again")
            .filter { $0 == SelfTestBlockingFixture.coldLaunchFlag }.count, 1)
        // It is a self-test launch to the option parser: the engine is Chromium, and a release
        // bundle takes it only under verification, on a new profile.
        let options = EngineLaunchOptions.parse(arguments: ["ReArc"] + child, environment: [:])
        XCTAssertTrue(options.selfTest)
        XCTAssertNil(options.bench)
    }
}

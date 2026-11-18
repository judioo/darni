import XCTest
@testable import SidebarModel

/// Built-in ad and tracker blocking (docs/FEATURE-SPECS/CONTENT-BLOCKING.md
/// §8, "Model"): levels and lists, new and existing installs, the one-time
/// offer, new profiles, exceptions as hosts, and the sidebar file.

private func makeStore() -> SidebarStore {
    SidebarStore(spaces: [Space(name: "Home", sortRank: "b")], mutationJournal: SidebarMutationJournal(deviceID: UUID()))
}

private func reload(_ store: SidebarStore) throws -> SidebarStore {
    let data = try JSONEncoder().encode(store.makeSnapshot())
    let restored = makeStore()
    restored.applySnapshot(try JSONDecoder().decode(SidebarSnapshot.self, from: data))
    return restored
}

// MARK: - Levels and lists

final class ContentBlockingSettingsTests: XCTestCase {
    func testEachLevelTurnsOnItsLists() {
        XCTAssertEqual(ContentBlockingLists.defaults(for: .off), [])
        XCTAssertEqual(ContentBlockingLists.defaults(for: .trackersOnly), ["easyprivacy", "peter-lowe"])
        XCTAssertEqual(ContentBlockingLists.defaults(for: .adsAndTrackers), ["easyprivacy", "peter-lowe", "easylist"])
        XCTAssertEqual(ContentBlockingLists.defaults(for: .strict),
                       ["easyprivacy", "peter-lowe", "easylist", "fanboy-annoyance", "easylist-cookie"])
        XCTAssertEqual(ContentBlockingLevel.allCases.map(\.engineValue), [0, 1, 2, 3], "the ABI's level numbers")
    }

    func testRegionalListsAreOffAtEveryLevel() {
        XCTAssertEqual(ContentBlockingLists.known.filter { $0.level == nil }.map(\.id),
                       ["easylist-germany", "liste-fr", "easylist-italy", "easylist-spanish", "easylist-dutch"], "the pipeline's regional lists")
        for level in ContentBlockingLevel.strengths {
            let settings = ContentBlockingSettings(isEnabled: true, strength: level)
            XCTAssertFalse(settings.isListEnabled("easylist-germany"))
            XCTAssertFalse(settings.isListEnabled("liste-fr"))
        }
    }

    func testOffKeepsEverythingAndTellsTheEngineNothing() {
        var settings = ContentBlockingSettings(isEnabled: true, strength: .strict, ownRules: "||ads.test^", exceptions: ["shop.test"])
        settings.isEnabled = false
        XCTAssertEqual(settings.level, .off)
        XCTAssertEqual(settings.enabledListIDs(), [])
        XCTAssertEqual(settings.strength, .strict)
        XCTAssertEqual(settings.exceptions, ["shop.test"])
        settings.isEnabled = true
        XCTAssertEqual(settings.level, .strict, "the switch brings the chosen level back")
    }

    func testListChoicesStayUntilAnotherLevelIsChosen() {
        var settings = ContentBlockingSettings(isEnabled: true)
        settings.setList("easylist", enabled: false)
        settings.setList("liste-fr", enabled: true)
        XCTAssertEqual(settings.listOverrides, ["easylist": false, "liste-fr": true])
        XCTAssertEqual(settings.enabledListIDs(), ["easyprivacy", "peter-lowe", "liste-fr"])
        XCTAssertTrue(settings.isListEnabled("liste-fr"))
        XCTAssertFalse(settings.isListEnabled("easylist"))
        settings.setList("easylist", enabled: true)
        XCTAssertEqual(settings.enabledListIDs(), ["easyprivacy", "peter-lowe", "easylist", "liste-fr"])
        settings.setStrength(.strict)
        XCTAssertEqual(settings.listOverrides, [:])
        settings.setStrength(.off)
        XCTAssertEqual(settings.strength, .strict, "Off is the switch, never a strength")
        settings.setList("../rules", enabled: true)
        XCTAssertEqual(settings.listOverrides, [:], "a list ID names a file in the bundle")
    }

    func testOwnRulesOverTheLimitAreCutAtALine() {
        let line = String(repeating: "a", count: 99)
        let text = Array(repeating: line, count: 3000).joined(separator: "\n")
        var settings = ContentBlockingSettings(isEnabled: true)
        settings.setOwnRules(text)
        XCTAssertLessThanOrEqual(settings.ownRules.utf8.count, ContentBlockingSettings.maxOwnRulesBytes)
        XCTAssertTrue(settings.ownRules.split(separator: "\n").allSatisfy { $0.count == 99 }, "no line is cut in half")
    }

    func testSettingsDecodeTotalAndNeverTurnOnFromAnUnknownValue() throws {
        let odd = Data(#"{"isEnabled":"yes","strength":"nuclear","listOverrides":7,"exceptions":["Shop.Test","not a host"]}"#.utf8)
        let settings = try JSONDecoder().decode(ContentBlockingSettings.self, from: odd)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.strength, .adsAndTrackers)
        XCTAssertEqual(settings.exceptions, ["shop.test"])
        let saved = ContentBlockingSettings(isEnabled: true, strength: .trackersOnly, listOverrides: ["liste-fr": true],
                                            ownRules: "||ads.test^", exceptions: ["b.test", "a.test"])
        XCTAssertEqual(try JSONDecoder().decode(ContentBlockingSettings.self, from: JSONEncoder().encode(saved)), saved)
    }
}

// MARK: - Exceptions as hosts

final class ContentBlockingHostTests: XCTestCase {
    func testWhatAPersonTypesBecomesAHost() {
        let cases: [(String, String?)] = [
            ("example.com", "example.com"),
            ("  Example.COM  ", "example.com"),
            ("https://www.example.com/path?q=1#top", "example.com"),
            ("http://user:pw@shop.example.com:8443/cart", "shop.example.com"),
            ("*.example.com", "example.com"),
            ("example.com.", "example.com"),
            ("www.example.com", "example.com"),
            ("localhost:3000", "localhost"),
            ("192.168.1.10:8080", "192.168.1.10"),
            ("[::1]:8080", nil),
            ("bücher.example", "xn--bcher-kva.example"),
            ("", nil),
            ("not a host", nil),
            ("exa_mple!.com", nil),
            ("-bad.example.com", nil),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(ContentBlockingHost.normalized(input), expected, input)
        }
    }

    func testAnExceptionIsKeptUnderTheSitesRegistrableHost() {
        func host(_ url: String) -> String? { ContentBlockingHost.exceptionHost(for: URL(string: url)) }
        XCTAssertEqual(host("https://www.news.example.com/story"), "example.com")
        XCTAssertEqual(host("https://shop.example.co.uk/"), "example.co.uk")
        XCTAssertEqual(host("https://someone.github.io/blog"), "someone.github.io", "a shared host's tenants are separate sites")
        XCTAssertEqual(host("http://localhost:3000/"), "localhost")
        XCTAssertEqual(host("http://192.168.1.10:8080/"), "192.168.1.10")
        XCTAssertNil(host("http://[::1]:3000/"), "the engine's exception hosts are names")
        XCTAssertNil(host("about:blank"))
        XCTAssertNil(host("file:///Users/someone/page.html"))
        XCTAssertNil(host("chrome://settings/"))
    }

    func testExceptionsAreASortedSetAndCoverSubdomains() {
        var settings = ContentBlockingSettings(isEnabled: true, exceptions: ["Shop.Test", "https://www.shop.test/x", "b.test", "nonsense !"])
        XCTAssertEqual(settings.exceptions, ["b.test", "shop.test"])
        XCTAssertTrue(settings.addException("a.test:8080"))
        XCTAssertFalse(settings.addException("not a host"))
        XCTAssertEqual(settings.exceptions, ["a.test", "b.test", "shop.test"])
        XCTAssertEqual(settings.exception(covering: URL(string: "https://pay.shop.test/checkout")), "shop.test")
        XCTAssertNil(settings.exception(covering: URL(string: "https://notshop.test/")))
        XCTAssertNil(settings.exception(covering: URL(string: "https://shop.test.evil.example/")), "a suffix match is on whole labels")
        settings.removeException("https://shop.test/")
        XCTAssertEqual(settings.exceptions, ["a.test", "b.test"])
    }

    func testTurningBlockingOffAndOnForAPage() {
        var settings = ContentBlockingSettings(isEnabled: true, exceptions: ["cdn.news.test"])
        let page = URL(string: "https://www.news.test/story")
        XCTAssertTrue(settings.setException(true, forPage: page))
        XCTAssertEqual(settings.exceptions, ["cdn.news.test", "news.test"])
        XCTAssertTrue(settings.setException(true, forPage: page))
        XCTAssertEqual(settings.exceptions.count, 2, "already covered")
        XCTAssertTrue(settings.setException(false, forPage: URL(string: "https://cdn.news.test/a.js")))
        XCTAssertEqual(settings.exceptions, [], "on again removes every exception that covers the page")
        XCTAssertFalse(settings.setException(true, forPage: URL(string: "about:blank")))
        XCTAssertFalse(settings.setException(true, forPage: nil))
    }
}

// MARK: - New and existing installs

final class ContentBlockingRolloutTests: XCTestCase {
    func testANewInstallStartsEveryProfileAtAdsAndTrackers() {
        let store = makeStore()
        let work = store.addProfile(name: "Work")
        XCTAssertEqual(store.contentBlocking().level, .off, "before the first launch of a build with blocking")
        XCTAssertEqual(store.beginContentBlockingRollout(isNewInstall: true), .new)
        for profile in store.profiles {
            XCTAssertEqual(store.contentBlocking(for: profile.id), .newProfile)
            XCTAssertEqual(store.contentBlocking(for: profile.id).level, .adsAndTrackers)
        }
        XCTAssertEqual(store.contentBlocking(for: work.id).enabledListIDs(), ["easyprivacy", "peter-lowe", "easylist"])
        XCTAssertFalse(store.contentBlockingRollout.isOfferDue, "a new install is never shown the offer")
        XCTAssertFalse(store.takeContentBlockingOffer())
        XCTAssertTrue(store.isContentBlockingOnAnywhere)
    }

    func testAnExistingInstallStaysOffInEveryProfile() {
        let store = makeStore()
        _ = store.addProfile(name: "Work")
        XCTAssertEqual(store.beginContentBlockingRollout(isNewInstall: false), .existing)
        for profile in store.profiles {
            XCTAssertEqual(store.contentBlocking(for: profile.id).level, .off)
        }
        XCTAssertTrue(store.contentBlockingByProfile.isEmpty, "nothing is written for a profile nobody changed")
        XCTAssertFalse(store.isContentBlockingOnAnywhere)
        XCTAssertTrue(store.contentBlockingRollout.isOfferDue)
    }

    func testTheDecisionIsMadeOnce() throws {
        let store = makeStore()
        XCTAssertEqual(store.beginContentBlockingRollout(isNewInstall: false), .existing)
        XCTAssertNil(store.beginContentBlockingRollout(isNewInstall: true), "a later launch decides nothing")
        XCTAssertEqual(store.contentBlocking().level, .off)
        let relaunched = try reload(store)
        XCTAssertNil(relaunched.beginContentBlockingRollout(isNewInstall: true))
        XCTAssertEqual(relaunched.contentBlockingRollout.install, .existing)
        XCTAssertEqual(relaunched.contentBlocking().level, .off)
    }

    func testAnUpgradedSidebarFileHasNoBlockingAndIsAnExistingInstall() throws {
        // A file from before blocking: the same snapshot without the key.
        let before = makeStore()
        _ = before.addProfile(name: "Work")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(before.makeSnapshot())) as? [String: Any])
        XCTAssertNil(json["contentBlocking"], "nothing is written before the rollout")
        json["contentBlocking"] = nil
        let store = makeStore()
        store.applySnapshot(try JSONDecoder().decode(SidebarSnapshot.self, from: JSONSerialization.data(withJSONObject: json)))
        XCTAssertFalse(store.contentBlockingRollout.isDecided)
        store.beginContentBlockingRollout(isNewInstall: false)
        XCTAssertTrue(store.profiles.allSatisfy { store.contentBlocking(for: $0.id).level == .off })
        XCTAssertTrue(store.contentBlockingRollout.isOfferDue)
    }

    func testTheOfferIsShownOnceAndItsMarkerIsWrittenBeforeTheCard() throws {
        let store = makeStore()
        store.beginContentBlockingRollout(isNewInstall: false)
        // The marker is in the snapshot the moment the offer is taken, before any card exists.
        XCTAssertTrue(store.takeContentBlockingOffer())
        XCTAssertTrue(store.makeSnapshot().contentBlocking.rollout.offerShown)
        XCTAssertFalse(store.takeContentBlockingOffer(), "never twice in one launch")
        // A crash with the card up: the next launch reads the marker and shows nothing.
        let relaunched = try reload(store)
        XCTAssertFalse(relaunched.contentBlockingRollout.isOfferDue)
        XCTAssertFalse(relaunched.takeContentBlockingOffer())
        XCTAssertEqual(relaunched.contentBlocking().level, .off, "an unanswered offer turns nothing on")
    }

    func testTurnOnSwitchesEveryOffProfileOnAndNotNowChangesNothing() {
        let store = makeStore()
        let work = store.addProfile(name: "Work")
        store.beginContentBlockingRollout(isNewInstall: false)
        _ = store.takeContentBlockingOffer()
        XCTAssertFalse(store.isContentBlockingOnAnywhere, "Not Now, or closing the card, is no call at all")
        store.updateContentBlocking(for: work.id) { $0.setStrength(.strict) }
        store.acceptContentBlockingOffer()
        XCTAssertEqual(store.contentBlocking(for: store.profiles[0].id).level, .adsAndTrackers)
        XCTAssertEqual(store.contentBlocking(for: work.id).level, .strict, "a strength chosen before is kept")
    }

    func testAProfileMadeLaterStartsAtAdsAndTrackers() {
        let existing = makeStore()
        existing.beginContentBlockingRollout(isNewInstall: false)
        let later = existing.addProfile(name: "Later")
        XCTAssertEqual(existing.contentBlocking(for: later.id).level, .adsAndTrackers, "it has no pages that could break")
        XCTAssertEqual(existing.contentBlocking(for: existing.profiles[0].id).level, .off, "the old profile is untouched")

        let fresh = makeStore()
        fresh.beginContentBlockingRollout(isNewInstall: true)
        XCTAssertEqual(fresh.contentBlocking(for: fresh.addProfile(name: "Later").id).level, .adsAndTrackers)

        let undecided = makeStore()
        XCTAssertEqual(undecided.contentBlocking(for: undecided.addProfile(name: "Early").id).level, .off,
                       "an engine without blocking: nothing is decided and nothing is set")
    }

    func testAContainerFollowsItsParentAndADeletedProfileLeavesNoSettings() throws {
        let store = makeStore()
        store.beginContentBlockingRollout(isNewInstall: false)
        let parent = store.profiles[0].id
        let container = store.createContainerProfile(name: "Bank", theme: .default, of: parent)
        XCTAssertTrue(store.isContainer(container.id))
        XCTAssertNil(store.contentBlockingByProfile[container.id], "a container has no settings of its own")
        XCTAssertEqual(store.contentBlocking(for: container.id).level, .off, "the parent is Off")
        store.updateContentBlocking(for: container.id) { $0.isEnabled = true; $0.addException("bank.test") }
        XCTAssertEqual(store.contentBlocking(for: parent).exceptions, ["bank.test"], "a container's change is its parent's")
        XCTAssertEqual(store.contentBlocking(for: container.id).level, .adsAndTrackers)

        let work = store.addProfile(name: "Work")
        XCTAssertNotNil(store.contentBlockingByProfile[work.id])
        XCTAssertNil(store.deleteProfile(work.id, deletingSpaces: true))
        XCTAssertNil(store.contentBlockingByProfile[work.id])
    }

    func testSettingsAndTheRolloutRoundTripThroughTheSidebarFile() throws {
        let store = makeStore()
        store.beginContentBlockingRollout(isNewInstall: true)
        store.updateContentBlocking { settings in
            settings.setStrength(.strict)
            settings.setList("liste-fr", enabled: true)
            settings.setOwnRules("||ads.test^\n@@||good.test^")
            settings.addException("shop.test")
        }
        let restored = try reload(store)
        XCTAssertEqual(restored.contentBlocking(), store.contentBlocking())
        XCTAssertEqual(restored.contentBlockingRollout, ContentBlockingRollout(install: .new, offerShown: true))
        XCTAssertEqual(restored.makeSnapshot().contentBlocking, store.makeSnapshot().contentBlocking)
    }

    func testARolloutThisBuildCannotReadTurnsNothingOnAndShowsNoCard() throws {
        let rollout = try JSONDecoder().decode(ContentBlockingRollout.self, from: Data(#"{"install":"sideloaded"}"#.utf8))
        XCTAssertEqual(rollout, ContentBlockingRollout(install: .existing, offerShown: true))
        XCTAssertFalse(rollout.isOfferDue)
        XCTAssertFalse(try JSONDecoder().decode(ContentBlockingRollout.self, from: Data("{}".utf8)).isDecided)
    }
}

// MARK: - Sync

@MainActor
final class ContentBlockingSyncTests: XCTestCase {
    @MainActor
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @MainActor
    private final class Mac {
        let name: String
        let store: SidebarStore
        let coordinator: SidebarSyncCoordinator
        let clock: Clock

        init(_ name: String, server: InMemorySyncServer, clock: Clock, store: SidebarStore? = nil) {
            self.name = name
            self.clock = clock
            let store = store ?? makeStore()
            self.store = store
            coordinator = SidebarSyncCoordinator(transport: server.transport(account: "alice"), stateStore: InMemorySyncStateStore(),
                                                 deviceID: name, now: { [clock] in clock.date })
            coordinator.host = store
            coordinator.setEnabled(true)
        }

        @discardableResult
        func sync() async -> SyncCycleOutcome {
            clock.date = clock.date.addingTimeInterval(1)
            let outcome = await coordinator.sync()
            clock.date = clock.date.addingTimeInterval(1)
            return outcome
        }

        var records: [String: SyncRecordBody] { SidebarSyncProjection.extract(store.makeSnapshot()) }
    }

    private var server: InMemorySyncServer!
    private var clock: Clock!

    override func setUp() async throws {
        server = InMemorySyncServer()
        clock = Clock()
    }

    private func chosen() -> ContentBlockingSettings {
        ContentBlockingSettings(isEnabled: true, strength: .strict, listOverrides: ["liste-fr": true, "easylist-cookie": false],
                                ownRules: "||ads.test^$third-party\n@@||good.test^", exceptions: ["shop.test", "bank.test"])
    }

    func testTheRecordIsNamedAfterTheProfileAndRoundTripsThroughTheProjection() throws {
        XCTAssertEqual(SyncRecordKind.contentBlocking.rawValue, "SidebarContentBlockingRecord")
        let store = makeStore()
        let profile = store.profiles[0].id
        XCTAssertNil(SidebarSyncProjection.extract(store.makeSnapshot())[SyncRecordKind.contentBlocking.recordName(for: profile)],
                     "a profile nobody gave settings writes no record")
        store.setContentBlocking(chosen())
        let name = SyncRecordKind.contentBlocking.recordName(for: profile)
        XCTAssertEqual(name, "contentblocking_" + profile.uuidString.lowercased())
        XCTAssertEqual(SyncRecordKind.parse(recordName: name)?.kind, .contentBlocking)
        let body = try XCTUnwrap(SidebarSyncProjection.extract(store.makeSnapshot())[name])
        XCTAssertEqual(body.kind, .contentBlocking)
        XCTAssertEqual(body.values["enabled"], .bool(true))
        XCTAssertEqual(body.values["level"], .string("strict"))
        XCTAssertEqual(body.values["exceptions"], .array([.string("bank.test"), .string("shop.test")]))
        XCTAssertEqual(SidebarSyncProjection.contentBlocking(values: body.values), chosen())
    }

    func testSettingsReachTheOtherMacAndChangesComeBack() async throws {
        let a = Mac("A", server: server, clock: clock)
        a.store.beginContentBlockingRollout(isNewInstall: false)
        let profile = a.store.profiles[0].id
        a.store.setContentBlocking(chosen())
        await a.sync()

        let b = Mac("B", server: server, clock: clock)
        await b.sync()
        XCTAssertEqual(b.store.contentBlocking(for: profile), chosen(), "level, lists, own rules and exceptions all arrive")
        XCTAssertFalse(b.store.contentBlockingRollout.isDecided, "the rollout state is each Mac's own")

        b.store.updateContentBlocking(for: profile) { $0.removeException("bank.test"); $0.isEnabled = false }
        b.coordinator.captureLocalChanges()
        await b.sync()
        await a.sync()
        XCTAssertEqual(a.store.contentBlocking(for: profile).exceptions, ["shop.test"])
        XCTAssertEqual(a.store.contentBlocking(for: profile).level, .off)
        XCTAssertEqual(a.records, b.records)
        let quiet = await a.sync()
        XCTAssertEqual(quiet.pushed, 0, "nothing left to say")
    }

    func testTheSwitchOnOneMacAndTheLevelOnAnotherBothStay() async throws {
        let a = Mac("A", server: server, clock: clock)
        let profile = a.store.profiles[0].id
        a.store.setContentBlocking(ContentBlockingSettings(isEnabled: true))
        await a.sync()
        let b = Mac("B", server: server, clock: clock)
        await b.sync()

        a.store.updateContentBlocking(for: profile) { $0.isEnabled = false }
        a.coordinator.captureLocalChanges()
        b.store.updateContentBlocking(for: profile) { $0.setStrength(.trackersOnly) }
        b.coordinator.captureLocalChanges()
        await a.sync()
        await b.sync()
        await a.sync()
        for mac in [a, b] {
            XCTAssertFalse(mac.store.contentBlocking(for: profile).isEnabled, mac.name)
            XCTAssertEqual(mac.store.contentBlocking(for: profile).strength, .trackersOnly, mac.name)
        }
    }

    func testAnUpgradedMacUploadsNothingAndSyncNeverTurnsBlockingOnByItself() async throws {
        // A: an install from before blocking, upgraded, Off, never asked for it.
        let a = Mac("A", server: server, clock: clock)
        a.store.beginContentBlockingRollout(isNewInstall: false)
        let profile = a.store.profiles[0].id
        _ = a.store.addTab(kind: .pinned, title: "Mail", url: URL(string: "https://mail.test/")!)
        await a.sync()
        XCTAssertNil(a.records[SyncRecordKind.contentBlocking.recordName(for: profile)])

        // B: a new install of the same build. Its untouched starter adopts the iCloud sidebar.
        let b = Mac("B", server: server, clock: clock, store: SidebarStore(mutationJournal: SidebarMutationJournal(deviceID: UUID())))
        b.store.beginContentBlockingRollout(isNewInstall: true)
        XCTAssertTrue(SidebarSyncProjection.isPristine(b.store.makeSnapshot()), "a new install's defaults are not edits")
        await b.sync()
        XCTAssertEqual(b.store.profiles.map(\.id), [profile], "B took A's sidebar")
        XCTAssertEqual(b.store.contentBlocking(for: profile).level, .off, "A's profile keeps A's choice on B")
        await a.sync()
        XCTAssertEqual(a.store.contentBlocking(for: profile).level, .off, "and nothing came back to turn it on on A")
        XCTAssertEqual(b.store.contentBlocking(for: b.store.addProfile(name: "New").id).level, .adsAndTrackers)
    }

    func testARecordWithoutAReadableSwitchLeavesThisMacsSettings() throws {
        let store = makeStore()
        let profile = store.profiles[0].id
        store.setContentBlocking(chosen())
        let snapshot = store.makeSnapshot()
        let stamp = SyncStamp(millis: 1, device: "A")
        var records = SidebarSyncProjection.extract(snapshot).mapValues { body in
            SyncRecordPayload(kind: body.kind, fields: body.values.mapValues { SyncField(value: $0, stamp: stamp) })
        }
        let name = SyncRecordKind.contentBlocking.recordName(for: profile)
        records[name]?.fields["enabled"] = SyncField(value: .string("maybe"), stamp: stamp)
        XCTAssertFalse(SidebarSyncProjection.canMaterialize(name, records[name]!))
        XCTAssertEqual(SidebarSyncProjection.apply(records, onto: snapshot).contentBlocking.settingsByProfile[profile], chosen())

        // Hosts and list IDs from a record are normalised again.
        records[name]?.fields["enabled"] = SyncField(value: .bool(true), stamp: stamp)
        records[name]?.fields["exceptions"] = SyncField(value: .array([.string("HTTPS://Evil.Test/x"), .number(3), .string("no host")]), stamp: stamp)
        records[name]?.fields["lists"] = SyncField(value: .object(["../../etc": .bool(true), "liste-fr": .bool(true)]), stamp: stamp)
        let applied = try XCTUnwrap(SidebarSyncProjection.apply(records, onto: snapshot).contentBlocking.settingsByProfile[profile])
        XCTAssertEqual(applied.exceptions, ["evil.test"])
        XCTAssertEqual(applied.listOverrides, ["liste-fr": true])
    }

    func testDeletingAProfileFromICloudDeletesItsBlockingRecord() async throws {
        let a = Mac("A", server: server, clock: clock)
        let work = a.store.addProfile(name: "Work")
        a.store.setContentBlocking(chosen(), for: work.id)
        let names = SidebarSyncCoordinator.records(of: [work.id], in: a.store.makeSnapshot())
        XCTAssertTrue(names.contains(SyncRecordKind.contentBlocking.recordName(for: work.id)))
        XCTAssertFalse(names.contains(SyncRecordKind.contentBlocking.recordName(for: a.store.profiles[0].id)))
    }
}

// MARK: - Own rules to DNR

final class ContentBlockingRuleConverterTests: XCTestCase {
    private func one(_ filter: String, file: StaticString = #filePath, line: UInt = #line) throws -> ContentBlockingDNRRule {
        let conversion = ContentBlockingRuleConverter.convert(filter)
        XCTAssertEqual(conversion.dropped, [], file: file, line: line)
        return try XCTUnwrap(conversion.rules.first, "no rule for \(filter)", file: file, line: line)
    }

    func testAHostFilterBlocksEverythingButThePageItself() throws {
        let rule = try one("||ads.example.com^")
        XCTAssertEqual(rule, ContentBlockingDNRRule(id: 1, priority: 1, action: .init(type: "block"),
                                                    condition: .init(urlFilter: "||ads.example.com^")))
        XCTAssertEqual(ContentBlockingRuleConverter.convert("||ads.example.com^").json,
                       #"[{"action":{"type":"block"},"condition":{"urlFilter":"||ads.example.com^"},"id":1,"priority":1}]"#)
    }

    func testPatternsPassThroughAsDNRWrites() throws {
        XCTAssertEqual(try one("/banner/*/img^").condition.urlFilter, "/banner/*/img^")
        XCTAssertEqual(try one("|https://ads.test/pixel.gif|").condition.urlFilter, "|https://ads.test/pixel.gif|")
        XCTAssertEqual(try one("*tracker.js*").condition.urlFilter, "tracker.js", "a leading or trailing * says nothing")
        XCTAssertEqual(try one("0.0.0.0 Ads.Example.com").condition.urlFilter, "||ads.example.com^", "a hosts-file line")
    }

    func testPartyAndDomainOptions() throws {
        XCTAssertEqual(try one("||t.test^$third-party").condition.domainType, "thirdParty")
        XCTAssertEqual(try one("||t.test^$3p").condition.domainType, "thirdParty")
        XCTAssertEqual(try one("||t.test^$~third-party").condition.domainType, "firstParty")
        XCTAssertEqual(try one("||t.test^$1p").condition.domainType, "firstParty")
        let scoped = try one("||t.test^$domain=News.Test|~sport.news.test|blog.test")
        XCTAssertEqual(scoped.condition.initiatorDomains, ["news.test", "blog.test"])
        XCTAssertEqual(scoped.condition.excludedInitiatorDomains, ["sport.news.test"])
    }

    func testResourceTypes() throws {
        XCTAssertEqual(try one("||t.test^$script,image,xhr,subdocument").condition.resourceTypes,
                       ["sub_frame", "script", "image", "xmlhttprequest"])
        let excluded = try one("||t.test^$~image,~stylesheet")
        XCTAssertNil(excluded.condition.resourceTypes)
        XCTAssertEqual(excluded.condition.excludedResourceTypes, ["main_frame", "stylesheet", "image"],
                       "excluding types must not bring the page itself in")
        XCTAssertEqual(try one("||t.test^$script,~script,font").condition.resourceTypes, ["font"])
        XCTAssertEqual(try one("||t.test^$all").condition.resourceTypes?.count, 12)
        XCTAssertEqual(try one("||t.test^$document").condition.resourceTypes, ["main_frame"])
        XCTAssertEqual(try one("||t.test^$match-case").condition.isUrlFilterCaseSensitive, true)
        XCTAssertNil(try one("||t.test^").condition.isUrlFilterCaseSensitive)
    }

    func testExceptionsAndImportantSetThePriority() throws {
        let allow = try one("@@||good.test^$script")
        XCTAssertEqual(allow.action.type, "allow")
        XCTAssertEqual(allow.priority, 2)
        let page = try one("@@||good.test^$document")
        XCTAssertEqual(page.action.type, "allowAllRequests")
        XCTAssertEqual(page.condition.resourceTypes, ["main_frame"])
        XCTAssertEqual(try one("||ads.test^$important").priority, 3, "above an exception")
        XCTAssertEqual(try one("@@||good.test^$important").priority, 2, "important means nothing on an exception")
    }

    func testWhatDNRCannotExpressIsDroppedByLineAndCounted() {
        let text = """
        ! a comment
        [Adblock Plus 2.0]

        ||ads.test^
        example.com##.ad-banner
        ##.sponsored
        example.com#@#.ad
        /banner\\d+/
        /ads[0-9]+\\.js$/$script
        ||t.test^$csp=script-src 'none'
        ||t.test^$redirect=noop.js
        ||t.test^$removeparam=utm_source
        ||t.test^$domain=example.*
        ||t.test^$script,~script
        ||bücher.test^
        ||*.test^
        two words
        ||t.test^$
        ||fine.test^$third-party
        """
        let conversion = ContentBlockingRuleConverter.convert(text)
        XCTAssertEqual(conversion.rules.map(\.condition.urlFilter), ["||ads.test^", "||fine.test^"])
        XCTAssertEqual(conversion.rules.map(\.id), [1, 2], "ids are the kept rules, in order")
        XCTAssertEqual(conversion.dropped.map(\.line), Array(5...18))
        XCTAssertEqual(conversion.dropped.map(\.reason), [
            .cosmetic, .cosmetic, .cosmetic, .regex, .regex,
            .unsupportedOption("csp=script-src 'none'"), .unsupportedOption("redirect=noop.js"),
            .unsupportedOption("removeparam=utm_source"), .unsupportedOption("domain=example.*"),
            .invalid, .nonASCII, .invalid, .invalid, .invalid,
        ])
        XCTAssertEqual(conversion.summary, "2 rules. 14 lines are not supported and left out.")
        XCTAssertFalse(conversion.json.contains("redirect"), "own rules never redirect")
    }

    func testOnlyBlockAndAllowActionsAreEverWritten() {
        let text = (0..<300).map { "||h\($0).test^$\(["script", "important", "document", "3p", "all"][$0 % 5])" }.joined(separator: "\n")
            + "\n" + (0..<50).map { "@@||a\($0).test^$\(["document", "image", "document,subdocument"][$0 % 3])" }.joined(separator: "\n")
        let actions = Set(ContentBlockingRuleConverter.convert(text).rules.map(\.action.type))
        XCTAssertEqual(actions, ["block", "allow", "allowAllRequests"])
    }

    func testRulesPastTheLimitAreDroppedAndSaid() {
        let text = (1...5003).map { "||h\($0).test^" }.joined(separator: "\n")
        let conversion = ContentBlockingRuleConverter.convert(text)
        XCTAssertEqual(ContentBlockingRuleConverter.maxRules, 5000)
        XCTAssertEqual(conversion.rules.count, 5000)
        XCTAssertEqual(conversion.rules.last?.id, 5000)
        XCTAssertEqual(conversion.dropped.map(\.reason), [.overLimit, .overLimit, .overLimit])
        XCTAssertEqual(conversion.dropped.map(\.line), [5001, 5002, 5003])
        XCTAssertEqual(ContentBlockingRuleConverter.convert("").json, "[]")
    }
}

// MARK: - Telling the engine

private final class RecordingEngine: ContentBlockingEngine {
    var calls: [String] = []

    func setBlocklistDirectory(_ directory: URL) { calls.append("directory \(directory.lastPathComponent)") }
    func setContentBlocking(engineProfile: UInt64, level: ContentBlockingLevel, enabledListIDs: [String]) {
        calls.append("level \(engineProfile) \(level.engineValue) \(enabledListIDs.joined(separator: ","))")
    }
    func setBlockingExceptions(engineProfile: UInt64, hosts: [String]) {
        calls.append("exceptions \(engineProfile) \(hosts.joined(separator: ","))")
    }
    func setOwnBlockingRules(engineProfile: UInt64, dnrRulesJSON: String) {
        let count = (try? JSONSerialization.jsonObject(with: Data(dnrRulesJSON.utf8)) as? [Any])?.count ?? -1
        calls.append("rules \(engineProfile) \(count)")
    }

    func take() -> [String] {
        defer { calls = [] }
        return calls
    }
}

final class ContentBlockingEngineSyncTests: XCTestCase {
    private func bundle(_ version: String, lists: [BlocklistManifest.List]? = nil) -> VerifiedBlocklist {
        let lists = lists ?? [
            .init(id: "easyprivacy", title: "EasyPrivacy", level: 1), .init(id: "peter-lowe", title: "Peter Lowe", level: 1),
            .init(id: "easylist", title: "EasyList", level: 2), .init(id: "fanboy-annoyance", title: "Fanboy", level: 3),
            .init(id: "easylist-cookie", title: "Cookie", level: 3),
        ]
        let manifest = BlocklistManifest(version: BlocklistVersion(version)!, created: nil, minEngine: .none, lists: lists, files: [:])
        return VerifiedBlocklist(directory: URL(fileURLWithPath: "/lists/\(version)"), manifest: manifest, source: .downloaded)
    }

    /// C-ABI.md "Content blocking": the engine keeps no state, so at every
    /// profile load it is told the level, then the exceptions, then the own rules.
    func testEveryProfileLoadSendsLevelThenExceptionsThenOwnRules() {
        let store = makeStore()
        store.setContentBlocking(ContentBlockingSettings(isEnabled: true, ownRules: "||ads.test^", exceptions: ["shop.test"]))
        let profile = store.profiles[0].id
        let engine = RecordingEngine()
        let sync = ContentBlockingEngineSync(engine: engine) { store.contentBlocking(for: $0) }

        sync.profileOpened(engineProfile: 7, profile: profile)
        XCTAssertEqual(engine.take(), ["level 7 2 easyprivacy,peter-lowe,easylist", "exceptions 7 shop.test", "rules 7 1"],
                       "before a bundle is named too: the engine holds the state until one is")
        sync.setBundle(bundle("202611180900"))
        XCTAssertEqual(engine.take(), ["directory 202611180900"], "the engine sets exceptions and own rules again itself")

        // The profile closes and loads again (its last window closed, then a new one): all three again.
        sync.profileClosed(engineProfile: 7)
        sync.profileOpened(engineProfile: 8, profile: profile)
        XCTAssertEqual(engine.take(), ["level 8 2 easyprivacy,peter-lowe,easylist", "exceptions 8 shop.test", "rules 8 1"])

        // An Off profile is told so too, at load: a profile the shell says nothing about has no blocker either way.
        let off = store.addProfile(name: "Work")
        sync.profileOpened(engineProfile: 9, profile: off.id)
        XCTAssertEqual(engine.take(), ["level 9 0 ", "exceptions 9 ", "rules 9 0"])
        sync.profileOpened(engineProfile: 0, profile: profile)
        XCTAssertEqual(engine.take(), [], "0 is no engine profile")
    }

    func testAfterTheLoadOnlyWhatChangedIsSent() {
        let store = makeStore()
        store.beginContentBlockingRollout(isNewInstall: true)
        let engine = RecordingEngine()
        let sync = ContentBlockingEngineSync(engine: engine) { store.contentBlocking(for: $0) }
        sync.setBundle(bundle("202611180900"))
        sync.profileOpened(engineProfile: 7, profile: store.profiles[0].id)
        _ = engine.take()

        sync.settingsChanged()
        XCTAssertEqual(engine.take(), [], "nothing changed")
        store.updateContentBlocking { $0.addException("shop.test") }
        sync.settingsChanged()
        XCTAssertEqual(engine.take(), ["exceptions 7 shop.test"])
        store.updateContentBlocking { $0.setStrength(.strict) }
        sync.settingsChanged()
        XCTAssertEqual(engine.take(), ["level 7 3 easyprivacy,peter-lowe,easylist,fanboy-annoyance,easylist-cookie"])
        store.updateContentBlocking { $0.setOwnRules("||ads.test^\nexample.com##.ad") }
        sync.settingsChanged()
        XCTAssertEqual(engine.take(), ["rules 7 1"], "the line DNR cannot express is left out")
        store.updateContentBlocking { $0.setList("easylist-cookie", enabled: false); $0.setList("liste-fr", enabled: true) }
        sync.settingsChanged()
        XCTAssertEqual(engine.take(), ["level 7 3 easyprivacy,peter-lowe,easylist,fanboy-annoyance,liste-fr"],
                       "a list this bundle lacks is still named: the engine skips it until a bundle has it")
        store.updateContentBlocking { $0.isEnabled = false }
        sync.settingsChanged()
        XCTAssertEqual(engine.take(), ["level 7 0 "], "level 0 unloads the blocker; exceptions and own rules stay as they are")
    }

    /// Security review, addendum 4: the engine copies a bundle's rules into
    /// the user data folder, so it is named only once some profile has
    /// blocking on.
    func testTheBundleIsNamedOnlyOnceAProfileHasBlockingOn() {
        let store = makeStore()
        store.beginContentBlockingRollout(isNewInstall: false)
        let profile = store.profiles[0].id
        XCTAssertEqual(store.contentBlocking(for: profile).level, .off, "an existing install starts with blocking off")
        let engine = RecordingEngine()
        let sync = ContentBlockingEngineSync(engine: engine) { store.contentBlocking(for: $0) }
        sync.setBundle(bundle("202611180900"))
        sync.profileOpened(engineProfile: 7, profile: profile)
        XCTAssertEqual(engine.take(), ["level 7 0 ", "exceptions 7 ", "rules 7 0"], "no directory while every profile is off")
        XCTAssertNotNil(sync.activeBundle, "the bundle is still the one Settings reads its lists from")
        sync.setBundle(bundle("202611190900"))
        XCTAssertEqual(engine.take(), [], "a newer bundle is not named either")

        store.updateContentBlocking { $0.isEnabled = true }
        sync.settingsChanged()
        XCTAssertEqual(engine.take(), ["directory 202611190900", "level 7 2 easyprivacy,peter-lowe,easylist"],
                       "named before the level, once blocking is on")
        store.updateContentBlocking { $0.isEnabled = false }
        sync.settingsChanged()
        store.updateContentBlocking { $0.isEnabled = true }
        sync.settingsChanged()
        XCTAssertEqual(engine.take(), ["level 7 0 ", "level 7 2 easyprivacy,peter-lowe,easylist"], "the same bundle is named once")
    }

    func testABundleDecidesWhichLevelHasAList() {
        let store = makeStore()
        store.setContentBlocking(ContentBlockingSettings(isEnabled: true))
        let engine = RecordingEngine()
        let sync = ContentBlockingEngineSync(engine: engine) { store.contentBlocking(for: $0) }
        sync.setBundle(bundle("202611180900"))
        sync.profileOpened(engineProfile: 1, profile: store.profiles[0].id)
        _ = engine.take()

        sync.setBundle(bundle("202611180900"))
        XCTAssertEqual(engine.take(), [], "the same bundle again is nothing new")
        // A later bundle brings a list this build's table does not know, at Ads and trackers, and a regional one.
        let later: [BlocklistManifest.List] = [
            .init(id: "easyprivacy", title: "EasyPrivacy", level: 1), .init(id: "easylist", title: "EasyList", level: 2),
            .init(id: "new-ads", title: "New Ads", level: 2), .init(id: "liste-xx", title: "Liste XX", level: 0),
        ]
        sync.setBundle(bundle("202611190900", lists: later))
        XCTAssertEqual(engine.take(), ["directory 202611190900", "level 1 2 easyprivacy,easylist,new-ads"])
        XCTAssertEqual(sync.lists.map(\.id), ["easyprivacy", "easylist", "new-ads", "liste-xx"])
        XCTAssertEqual(sync.lists.map(\.level), [.trackersOnly, .adsAndTrackers, .adsAndTrackers, nil])
        XCTAssertEqual(sync.lists.map(\.title), ["EasyPrivacy", "EasyList", "New Ads", "Liste XX"])
    }
}

// MARK: - The site controls row

final class ContentBlockingSiteRowTests: XCTestCase {
    private let page = URL(string: "https://www.news.test/story")

    private func row(_ settings: ContentBlockingSettings, count: Int? = 12, lists: Bool = true, isPrivate: Bool = false,
                     url: URL? = URL(string: "https://www.news.test/story")) -> SiteControlCenter.SettingRow {
        SiteControlCenter.contentBlockingRow(settings: settings, pageURL: url, blockedCount: count, listsAvailable: lists, isPrivate: isPrivate)
    }

    func testOnShowsTheCountAndAClickTurnsBlockingOffForTheSite() {
        let on = row(ContentBlockingSettings(isEnabled: true))
        XCTAssertEqual(on.title, "Block ads and trackers")
        XCTAssertEqual(on.state, "12 blocked on this page")
        XCTAssertEqual(on.actions, [.turnOffBlockingForSite])
        XCTAssertFalse(on.isBlocked)
        XCTAssertEqual(row(ContentBlockingSettings(isEnabled: true), count: 0).state, "Nothing blocked on this page")
        XCTAssertEqual(row(ContentBlockingSettings(isEnabled: true), count: 1).state, "1 blocked on this page")
        XCTAssertEqual(row(ContentBlockingSettings(isEnabled: true), count: nil).state, "On for this site")
    }

    func testAnExceptedSiteAndAProfileThatIsOff() {
        let excepted = row(ContentBlockingSettings(isEnabled: true, exceptions: ["news.test"]))
        XCTAssertEqual(excepted.state, "Off for this site")
        XCTAssertEqual(excepted.actions, [.turnOnBlockingForSite])
        let off = row(.off)
        XCTAssertEqual(off.state, "Off in Settings")
        XCTAssertEqual(off.actions, [.openBlockingSettings], "one site's panel never turns blocking on for a profile")
        XCTAssertEqual(row(ContentBlockingSettings(isEnabled: true), lists: false).state, "No lists yet")
        XCTAssertEqual(row(ContentBlockingSettings(isEnabled: true), lists: false).actions, [])
    }

    func testAPrivateWindowOnlyReports() {
        XCTAssertEqual(row(ContentBlockingSettings(isEnabled: true), isPrivate: true).actions, [],
                       "a site visited in a private window is never written into the profile's exceptions")
        XCTAssertEqual(row(ContentBlockingSettings(isEnabled: true, exceptions: ["news.test"]), isPrivate: true).actions, [])
        XCTAssertEqual(row(.off, isPrivate: true).actions, [.openBlockingSettings])
        XCTAssertEqual(row(ContentBlockingSettings(isEnabled: true), url: URL(string: "about:blank")).actions, [], "a page that is no site")
    }

    func testTheRowLeadsThePanelsSettings() {
        let blocking = row(ContentBlockingSettings(isEnabled: true))
        let rows = SiteControlCenter.settingRows(contentBlocking: blocking, permissions: [], permissionsInEngine: true,
                                                 autoPiP: .enabled, autoPiPEnabled: true)
        XCTAssertEqual(rows.map(\.kind), [.contentBlocking, .autoPictureInPicture])
        XCTAssertEqual(SiteControlCenter.settingRows(permissions: [], permissionsInEngine: true, autoPiP: .enabled, autoPiPEnabled: true).map(\.kind),
                       [.autoPictureInPicture], "an engine without blocking: the panel is as it was")
    }
}

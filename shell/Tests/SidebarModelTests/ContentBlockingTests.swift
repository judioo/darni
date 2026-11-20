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

    func testAnExceptionIsKeptUnderThePagesOwnHost() {
        func host(_ url: String) -> String? { ContentBlockingHost.exceptionHost(for: URL(string: url)) }
        XCTAssertEqual(host("https://www.news.example.com/story"), "news.example.com")
        XCTAssertEqual(host("https://www.example.com/story"), "example.com")
        XCTAssertEqual(host("https://shop.example.co.uk/"), "shop.example.co.uk")
        XCTAssertEqual(host("https://someone.github.io/blog"), "someone.github.io", "a shared host's tenants are separate sites")
        // Security CB-12: a suffix the shell's guess does not know is never the exception.
        XCTAssertEqual(host("https://someone.web.app/"), "someone.web.app")
        XCTAssertEqual(host("https://shop.azurewebsites.net/"), "shop.azurewebsites.net")
        XCTAssertEqual(host("https://uni.edu.au/"), "uni.edu.au")
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

    func testTurningBlockingBackOnRemovesAnExceptionStoredUnderASuffix() {
        // 1027 kept `someone.web.app` under `web.app` (CB-12); on again at that page removes it.
        var settings = ContentBlockingSettings(isEnabled: true, exceptions: ["web.app"])
        XCTAssertTrue(settings.setException(false, forPage: URL(string: "https://someone.web.app/")))
        XCTAssertEqual(settings.exceptions, [])
        XCTAssertTrue(settings.setException(true, forPage: URL(string: "https://someone.web.app/")))
        XCTAssertEqual(settings.exceptions, ["someone.web.app"])
        XCTAssertNil(settings.exception(covering: URL(string: "https://other.web.app/")))
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

    // MARK: An exception for a site

    /// "On news.test, let ads.test through" is two rules: what a news.test
    /// document asks, and what any frame asks in a page of news.test. With
    /// the first alone a third party that was let in stayed blocked when it
    /// asked its own host from its own frame (Darni 2026.1120.1105).
    func testAnExceptionForASiteAlsoCoversWhatAFrameAsksInThatSitesPage() {
        let conversion = ContentBlockingRuleConverter.convert("@@||ads.test^$domain=news.test")
        XCTAssertEqual(conversion.dropped, [])
        XCTAssertEqual(conversion.rules, [
            ContentBlockingDNRRule(id: 1, priority: 2, action: .init(type: "allow"),
                                   condition: .init(urlFilter: "||ads.test^", initiatorDomains: ["news.test"])),
            ContentBlockingDNRRule(id: 2, priority: 2, action: .init(type: "allow"),
                                   condition: .init(urlFilter: "||ads.test^", topDomains: ["news.test"])),
        ])
        XCTAssertEqual(conversion.json,
                       #"[{"action":{"type":"allow"},"condition":{"initiatorDomains":["news.test"],"urlFilter":"||ads.test^"},"id":1,"priority":2},"#
                        + #"{"action":{"type":"allow"},"condition":{"topDomains":["news.test"],"urlFilter":"||ads.test^"},"id":2,"priority":2}]"#)
        XCTAssertEqual(conversion.filters, 1)
        XCTAssertEqual(conversion.summary, "1 rule", "the person typed one line")
    }

    /// The second rule is never wider than the filter: what it excludes
    /// stays out as a page and as a frame, and its party and types stay.
    func testThePageRuleKeepsWhatTheFilterExcludesAndItsOtherConditions() throws {
        let conversion = ContentBlockingRuleConverter.convert("@@||ads.test^$domain=news.test|~sport.news.test|blog.test,third-party,script,match-case")
        XCTAssertEqual(conversion.dropped, [])
        XCTAssertEqual(conversion.rules.count, 2)
        let first = conversion.rules[0].condition, second = conversion.rules[1].condition
        XCTAssertEqual(first, .init(urlFilter: "||ads.test^", isUrlFilterCaseSensitive: true, domainType: "thirdParty",
                                    initiatorDomains: ["news.test", "blog.test"], excludedInitiatorDomains: ["sport.news.test"],
                                    resourceTypes: ["script"]))
        XCTAssertEqual(second, .init(urlFilter: "||ads.test^", isUrlFilterCaseSensitive: true, domainType: "thirdParty",
                                     excludedInitiatorDomains: ["sport.news.test"], topDomains: ["news.test", "blog.test"],
                                     excludedTopDomains: ["sport.news.test"], resourceTypes: ["script"]))
        XCTAssertEqual(conversion.rules.map(\.action.type), ["allow", "allow"])
        XCTAssertEqual(conversion.rules.map(\.priority), [2, 2])
    }

    /// Only an exception that names sites gets one. A block keeps the
    /// filter's own meaning: widening it would block more than was typed.
    func testOnlyAnExceptionThatNamesSitesGetsAPageRule() {
        // `$first-party` among them: DNR counts the party against the frame that asks, so with the site as
        // the page it would let every frame in the page ask its own site (security addendum 14, remark 1).
        for filter in ["||ads.test^$domain=news.test", "||ads.test^$important,domain=news.test", "@@||good.test^", "@@||good.test^$script",
                       "@@||good.test^$domain=~news.test", "@@||news.test^$document,domain=news.test", "0.0.0.0 ads.test",
                       "@@$first-party,domain=shop.test", "@@||cdn.test^$1p,domain=shop.test", "@@||cdn.test^$~third-party,domain=shop.test"] {
            let conversion = ContentBlockingRuleConverter.convert(filter)
            XCTAssertEqual(conversion.dropped, [], filter)
            XCTAssertEqual(conversion.rules.count, 1, filter)
            XCTAssertNil(conversion.rules.first?.condition.topDomains, filter)
            XCTAssertNil(conversion.rules.first?.condition.excludedTopDomains, filter)
        }
        let rule = ContentBlockingDNRRule(id: 7, priority: 2, action: .init(type: "allow"), condition: .init(urlFilter: "||a.test^", initiatorDomains: []))
        XCTAssertNil(ContentBlockingRuleConverter.pageRule(of: rule), "DNR refuses an empty list")
    }

    /// Every filter's own rule comes first, so the rules of a text that
    /// fitted before are all still there, in the same places. The page
    /// rules take the room that is left, in the text's order.
    func testPageRulesComeLastAndNeverPushAFilterOut() {
        func text(blocks: Int) -> String {
            (["@@||a.test^$domain=n.test"] + (0..<blocks).map { "||h\($0).test^" } + ["@@||b.test^$domain=n.test"]).joined(separator: "\n")
        }
        let full = ContentBlockingRuleConverter.convert(text(blocks: 4998))
        XCTAssertEqual(full.dropped, [])
        XCTAssertEqual(full.rules.count, 5000)
        XCTAssertEqual(full.filters, 5000)
        XCTAssertTrue(full.rules.allSatisfy { $0.condition.topDomains == nil }, "no room: each exception works as it did before")
        XCTAssertEqual(full.rules.map(\.id), Array(1...5000))
        XCTAssertEqual(full.withoutPageRule, 2)
        XCTAssertEqual(full.summary, "5000 rules. 2 exceptions do not cover frames, because the limit of 5000 rules is reached.", "and the person is told")

        let oneLeft = ContentBlockingRuleConverter.convert(text(blocks: 4997))
        XCTAssertEqual(oneLeft.dropped, [])
        XCTAssertEqual(oneLeft.filters, 4999)
        XCTAssertEqual(oneLeft.rules.count, 5000)
        XCTAssertEqual(Array(oneLeft.rules.prefix(4999)), Array(full.rules.prefix(4998)) + [full.rules[4999]].map {
            var rule = $0
            rule.id = 4999
            return rule
        }, "the filters' own rules, as without page rules")
        XCTAssertEqual(oneLeft.rules.last, ContentBlockingDNRRule(id: 5000, priority: 2, action: .init(type: "allow"),
                                                                 condition: .init(urlFilter: "||a.test^", topDomains: ["n.test"])),
                       "the first exception's, in the text's order")
        XCTAssertEqual(oneLeft.withoutPageRule, 1)
        XCTAssertEqual(oneLeft.summary, "4999 rules. 1 exception does not cover frames, because the limit of 5000 rules is reached.")

        let small = ContentBlockingRuleConverter.convert(text(blocks: 2))
        XCTAssertEqual(small.rules.map(\.condition.urlFilter), ["||a.test^", "||h0.test^", "||h1.test^", "||b.test^", "||a.test^", "||b.test^"])
        XCTAssertEqual(small.rules.map(\.id), Array(1...6))
        XCTAssertEqual(small.summary, "4 rules")
        XCTAssertEqual(small.withoutPageRule, 0)
        // A filter past the limit is dropped whole, with no page rule left behind.
        let over = ContentBlockingRuleConverter.convert((0..<5000).map { "||h\($0).test^" }.joined(separator: "\n") + "\n@@||a.test^$domain=n.test")
        XCTAssertEqual(over.dropped.map(\.reason), [.overLimit])
        XCTAssertEqual(over.rules.count, 5000)
        XCTAssertTrue(over.rules.allSatisfy { $0.action.type == "block" })
        XCTAssertEqual(over.withoutPageRule, 0, "a dropped filter is said once, as dropped")
        XCTAssertEqual(over.summary, "5000 rules. 1 line is not supported and left out.")
        let both = ContentBlockingRuleConverter.convert((0..<4999).map { "||h\($0).test^" }.joined(separator: "\n") + "\n@@||a.test^$domain=n.test\n##.ad")
        XCTAssertEqual(both.summary, "5000 rules. 1 line is not supported and left out. 1 exception does not cover frames, because the limit of 5000 rules is reached.")
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

    // MARK: Site exceptions with the engine's site names (§9, security CB-12)

    /// Chromium's answers for the names these tests use.
    private let siteNames = SiteNames { host in
        let suffixes = ["web.app", "co.uk", "github.io", "com"]
        if suffixes.contains(host) { return #"{"host":"\#(host)","registrable":false,"suffix":true}"# }
        if host == "localhost" { return #"{"host":"localhost","registrable":false,"suffix":false}"# }
        if host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) { return #"{"host":"\#(host)","registrable":true,"suffix":false}"# }
        guard let suffix = suffixes.first(where: { host.hasSuffix("." + $0) }) else { return nil }
        let label = host.dropLast(suffix.count + 1).split(separator: ".").last ?? ""
        return #"{"host":"\#(label).\#(suffix)","registrable":true,"suffix":false}"#
    }

    func testAnExceptionIsKeyedByThePagesRealSite() {
        func key(_ page: String, _ names: SiteNames?) -> String? { ContentBlockingHost.exceptionHost(for: URL(string: page), names: names) }
        XCTAssertEqual(key("https://www.example.co.uk/a", siteNames), "example.co.uk")
        XCTAssertEqual(key("https://m.example.co.uk/a", siteNames), "example.co.uk", "the site's other hosts are the same site again")
        XCTAssertEqual(key("https://someone.web.app/", siteNames), "someone.web.app")
        XCTAssertEqual(key("https://a.someone.web.app/", siteNames), "someone.web.app")
        XCTAssertEqual(key("http://203.0.113.7:8080/", siteNames), "203.0.113.7")
        XCTAssertEqual(key("http://localhost:3000/", siteNames), "localhost", "a name with no suffix is its own key")
        XCTAssertNil(key("https://github.io/", siteNames), "a page on a suffix itself: its exception would be every site under it")
        // Without the engine's list: the page's own host, never a guess.
        XCTAssertEqual(key("https://www.example.co.uk/a", nil), "example.co.uk")
        XCTAssertEqual(key("https://m.example.co.uk/a", nil), "m.example.co.uk")
        XCTAssertEqual(key("https://someone.web.app/", nil), "someone.web.app")
        XCTAssertEqual(key("https://unknown.test/", siteNames), "unknown.test", "no answer for the name: the same")

        var settings = ContentBlockingSettings.newProfile
        XCTAssertTrue(settings.setException(true, forPage: URL(string: "https://www.example.co.uk/a"), names: siteNames))
        XCTAssertEqual(settings.exceptions, ["example.co.uk"])
        XCTAssertNotNil(settings.exception(covering: URL(string: "https://m.example.co.uk/")))
        XCTAssertNil(settings.exception(covering: URL(string: "https://other.co.uk/")))
        XCTAssertFalse(settings.setException(true, forPage: URL(string: "https://github.io/"), names: siteNames))
        XCTAssertEqual(settings.exceptions, ["example.co.uk"])
        XCTAssertTrue(settings.setException(false, forPage: URL(string: "https://m.example.co.uk/"), names: siteNames))
        XCTAssertEqual(settings.exceptions, [])
    }

    func testATypedExceptionThatIsAPublicSuffixIsRefused() {
        var settings = ContentBlockingSettings.newProfile
        for suffix in ["web.app", "co.uk", "com", "*.github.io", "https://web.app/"] {
            XCTAssertFalse(settings.addException(suffix, names: siteNames), suffix)
        }
        XCTAssertEqual(settings.exceptions, [])
        XCTAssertTrue(settings.addException("someone.web.app", names: siteNames))
        XCTAssertTrue(settings.addException("localhost", names: siteNames), "the person's own machine")
        XCTAssertTrue(settings.addException("unknown.test", names: siteNames))
        XCTAssertEqual(settings.exceptions, ["localhost", "someone.web.app", "unknown.test"])
        // Without the engine's list a name is taken as typed, as before.
        XCTAssertTrue(settings.addException("web.app", names: nil))
        XCTAssertTrue(ContentBlockingHost.isPublicSuffix("web.app", names: siteNames))
        XCTAssertFalse(ContentBlockingHost.isPublicSuffix("web.app", names: nil))
        XCTAssertFalse(ContentBlockingHost.isPublicSuffix("someone.web.app", names: siteNames))
    }

    /// Builds 1027 to 1049 stored `web.app` for a page on `someone.web.app`.
    /// It is marked, not rewritten: the shell cannot know which site was
    /// meant, and the list syncs.
    func testAStoredSuffixExceptionIsFoundAndCanBeNarrowedToThePagesSite() {
        let page = URL(string: "https://someone.web.app/x")
        var settings = ContentBlockingSettings(isEnabled: true, exceptions: ["web.app", "news.test"])
        XCTAssertEqual(settings.exceptions, ["news.test", "web.app"], "a stored list is kept as it is")
        XCTAssertEqual(settings.widerException(covering: page, names: siteNames), "web.app")
        XCTAssertNil(settings.widerException(covering: page, names: nil), "only the engine's list can say")
        XCTAssertNil(settings.widerException(covering: URL(string: "https://news.test/"), names: siteNames))

        XCTAssertTrue(settings.narrowException(toPage: page, names: siteNames))
        XCTAssertEqual(settings.exceptions, ["news.test", "someone.web.app"])
        XCTAssertNotNil(settings.exception(covering: page), "blocking stays off for the site the person is on")
        XCTAssertNil(settings.exception(covering: URL(string: "https://another.web.app/")), "and is back on for the others")
        XCTAssertFalse(settings.narrowException(toPage: page, names: siteNames), "nothing left to narrow")
        XCTAssertFalse(settings.narrowException(toPage: URL(string: "https://news.test/"), names: siteNames))
        XCTAssertEqual(settings.exceptions, ["news.test", "someone.web.app"])
    }

    /// The old guess was also too wide where it was no suffix: for a tenant
    /// of `cloudapp.azure.com` it stored `azure.com`, a real domain that
    /// holds every tenant. On a page the engine's list says what the site
    /// is, so an exception above it is found and narrowed the same way.
    func testAStoredExceptionAboveThePagesSiteIsWiderWithoutBeingASuffix() {
        let azure = SiteNames { host in
            if host == "cloudapp.azure.com" { return #"{"host":"cloudapp.azure.com","registrable":false,"suffix":true}"# }
            if host.hasSuffix(".cloudapp.azure.com") {
                return #"{"host":"\#(host.split(separator: ".").suffix(4).joined(separator: "."))","registrable":true,"suffix":false}"#
            }
            if host == "azure.com" || host.hasSuffix(".azure.com") { return #"{"host":"azure.com","registrable":true,"suffix":false}"# }
            return nil
        }
        let tenant = URL(string: "https://www.tenant.cloudapp.azure.com/")
        var settings = ContentBlockingSettings(isEnabled: true, exceptions: ["azure.com"])
        XCTAssertFalse(ContentBlockingHost.isPublicSuffix("azure.com", names: azure), "a real domain: Settings alone cannot tell")
        XCTAssertEqual(settings.widerException(covering: tenant, names: azure), "azure.com")
        // On a page of azure.com itself the same exception is that site's own.
        XCTAssertNil(settings.widerException(covering: URL(string: "https://portal.azure.com/"), names: azure))
        XCTAssertNil(settings.widerException(covering: tenant, names: nil))
        let row = SiteControlCenter.contentBlockingRow(settings: settings, pageURL: tenant, blockedCount: nil, listsAvailable: true,
                                                       isPrivate: false, names: azure)
        XCTAssertEqual(row.state, "Off for every site under azure.com")
        XCTAssertEqual(row.actions, [.turnOffBlockingForSiteOnly, .turnOnBlockingForSite])

        XCTAssertTrue(settings.narrowException(toPage: tenant, names: azure))
        XCTAssertEqual(settings.exceptions, ["tenant.cloudapp.azure.com"])
        XCTAssertNil(settings.exception(covering: URL(string: "https://other.cloudapp.azure.com/")))
        XCTAssertNil(settings.widerException(covering: tenant, names: azure), "the site's own exception is not wider than the site")
        XCTAssertFalse(settings.narrowException(toPage: tenant, names: azure))
    }

    func testTheRowSaysHowFarASuffixExceptionReaches() {
        func row(_ settings: ContentBlockingSettings, _ page: String, _ names: SiteNames?) -> SiteControlCenter.SettingRow {
            SiteControlCenter.contentBlockingRow(settings: settings, pageURL: URL(string: page), blockedCount: nil, listsAvailable: true,
                                                 isPrivate: false, names: names)
        }
        let stored = ContentBlockingSettings(isEnabled: true, exceptions: ["web.app"])
        let marked = row(stored, "https://someone.web.app/", siteNames)
        XCTAssertEqual(marked.state, "Off for every site under web.app")
        XCTAssertEqual(marked.actions, [.turnOffBlockingForSiteOnly, .turnOnBlockingForSite])
        XCTAssertTrue(marked.isBlocked)
        XCTAssertEqual(SiteControlCenter.SettingAction.turnOffBlockingForSiteOnly.title, "Turn Off Blocking for This Site Only")
        // Without the engine's list the row is as it was.
        let unmarked = row(stored, "https://someone.web.app/", nil)
        XCTAssertEqual(unmarked.state, "Off for this site")
        XCTAssertEqual(unmarked.actions, [.turnOnBlockingForSite])
        // A page on a suffix itself has no site to turn blocking off for.
        XCTAssertEqual(row(.newProfile, "https://github.io/", siteNames).actions, [])
        XCTAssertEqual(row(.newProfile, "https://someone.github.io/", siteNames).actions, [.turnOffBlockingForSite])
        XCTAssertTrue(SiteControlCenter.suffixExceptionRefusal("web.app").contains("example.web.app"))
    }
}

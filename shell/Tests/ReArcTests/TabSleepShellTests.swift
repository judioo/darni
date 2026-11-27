import Combine
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// SwiftUI has a `Tab` of its own.
private typealias Tab = SidebarModel.Tab

/// A tab's engine as the sleep checks drive it: it records what the shell
/// asks and answers as the test says. Its page is "loaded" at `currentURL`.
private final class SleepEngine: WebEngine, TabDiscarding, TabFreezing {
    var currentURL: URL?
    var pageTitle: String?
    var isLoading = false
    var loadProgress = 1.0
    var isCrashed = false
    var canGoBack = false
    var canGoForward = false
    var securityState = WebSecurityState.secure
    var faviconData: Data?
    var pageColor: PageColor?
    var mediaState = WebMediaState.silent
    var mediaStatePublisher: AnyPublisher<WebMediaState, Never> { Empty().eraseToAnyPublisher() }
    var linkPeekHandler: ((URL) -> Void)?
    var automaticPeekSourceURL: URL?
    var zoomFactor = 1.0
    let pagePrompts = PagePromptCenter()

    /// Everything the shell did to the page, in order.
    var calls: [String] = []
    var freezeAnswer = FreezeOutcome.requested
    var discardAnswer = DiscardOutcome.discarded
    var isFreezeRequested = false
    var isDiscarded = false
    /// What the renderer reports; nil: the engine cannot say.
    var isPageFrozen: Bool?

    init(url: URL) { currentURL = url }

    func load(_ url: URL) { calls.append("load"); currentURL = url }
    func reload(ignoringCache: Bool) { calls.append("reload") }
    func stopLoading() { calls.append("stop") }
    func goBack() { calls.append("back") }
    func goForward() { calls.append("forward") }
    func setMuted(_ muted: Bool) {}
    func togglePlayPause() { calls.append("playPause") }
    func skipToNextTrack() {}
    func skipToPreviousTrack() {}
    func pauseAllMedia() {}
    func setPictureInPicture(_ active: Bool) {}
    func setZoomFactor(_ factor: Double) {}
    func makeView() -> AnyView { AnyView(EmptyView()) }
    func installBoosts(_ entries: [BoostRuntimeEntry]) {}
    func refreshBoostsOnPage() {}
    func captureSnapshot(scope: CaptureScope) async throws -> Data { Data() }

    func freeze() -> FreezeOutcome {
        calls.append("freeze")
        if freezeAnswer == .requested { isFreezeRequested = true }
        return freezeAnswer
    }

    func unfreeze() {
        calls.append("unfreeze")
        isFreezeRequested = false
        isPageFrozen = false
    }

    func discard() -> DiscardOutcome {
        calls.append("discard")
        if discardAnswer == .discarded {
            isDiscarded = true
            // As the engine does: a discarded page holds no request.
            isFreezeRequested = false
        }
        return discardAnswer
    }

    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }
}

/// An engine with no freeze and no discard, as WebKit's.
private final class PlainEngine: WebEngine {
    var currentURL: URL?
    var pageTitle: String?
    var isLoading = false
    var loadProgress = 1.0
    var isCrashed = false
    var canGoBack = false
    var canGoForward = false
    var securityState = WebSecurityState.secure
    var faviconData: Data?
    var pageColor: PageColor?
    var mediaState = WebMediaState.silent
    var mediaStatePublisher: AnyPublisher<WebMediaState, Never> { Empty().eraseToAnyPublisher() }
    var linkPeekHandler: ((URL) -> Void)?
    var automaticPeekSourceURL: URL?
    var zoomFactor = 1.0
    let pagePrompts = PagePromptCenter()

    init(url: URL) { currentURL = url }

    func load(_ url: URL) { currentURL = url }
    func reload(ignoringCache: Bool) {}
    func stopLoading() {}
    func goBack() {}
    func goForward() {}
    func setMuted(_ muted: Bool) {}
    func togglePlayPause() {}
    func skipToNextTrack() {}
    func skipToPreviousTrack() {}
    func pauseAllMedia() {}
    func setPictureInPicture(_ active: Bool) {}
    func setZoomFactor(_ factor: Double) {}
    func makeView() -> AnyView { AnyView(EmptyView()) }
    func installBoosts(_ entries: [BoostRuntimeEntry]) {}
    func refreshBoostsOnPage() {}
    func captureSnapshot(scope: CaptureScope) async throws -> Data { Data() }
}

final class TabSleepShellTests: XCTestCase {
    /// The clock's own time: a change of the setting checks at once, with the time it is.
    private let now = Date()

    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    /// One domain for the class, emptied before and after each test and removed
    /// with its file at the end: the app's own defaults are never written.
    private static let domain = "darni-sleep-shell-tests"

    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: Self.domain)!
    }

    private static func clearDefaults() {
        UserDefaults.standard.removePersistentDomain(forName: domain)
        CFPreferencesAppSynchronize(domain as CFString)
    }

    override func setUp() {
        super.setUp()
        Self.clearDefaults()
    }

    override func tearDown() {
        Self.clearDefaults()
        super.tearDown()
    }

    override class func tearDown() {
        clearDefaults()
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(domain).plist")
        try? FileManager.default.removeItem(at: file)
        super.tearDown()
    }

    /// A model with a selected tab ("front", on screen) and `names` more tabs
    /// behind it, each with a `SleepEngine`, last shown `minutes` ago.
    private func makeModel(_ names: [String] = ["idle"], shown minutes: Double = 45)
        -> (model: BrowserViewModel, tabs: [String: Tab], engines: [String: SleepEngine]) {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("darni-sleep-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = scratchDefaults()
        model.tabFreezeThreshold = .thirtyMinutes
        model.tabUnloadThreshold = .fourHours
        var tabs: [String: Tab] = [:]
        var engines: [String: SleepEngine] = [:]
        for name in ["front"] + names {
            let url = URL(string: "https://\(name).test/")!
            let tab = store.addTab(kind: .today, title: name, url: url)
            let engine = SleepEngine(url: url)
            model.engineHost.adopt(engine, for: tab, profileID: model.profileID(for: tab))
            tabs[name] = tab
            engines[name] = engine
            model.tabLastShown[tab.id] = ago(minutes)
        }
        model.selectTab(tabs["front"]!.id)
        for engine in engines.values { engine.calls = [] }
        return (model, tabs, engines)
    }

    // MARK: The engine can freeze

    func testTabFreezeNeedsABIMinor71AndItsFeature() {
        let all: (String) -> Bool = { _ in true }
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 71, hasFeature: all).tabFreeze)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 73, hasFeature: all).tabFreeze)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 70, hasFeature: all).tabFreeze, "an engine before tab/103")
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 71, hasFeature: { $0 != "tab_freeze" }).tabFreeze)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: nil, hasFeature: all).tabFreeze)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 71, hasFeature: all).summary.contains("tab_freeze=1"))
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 70, hasFeature: all).summary.contains("tab_freeze=0"))
        // Unloading does not depend on it.
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 70, hasFeature: all).tabDiscard)
    }

    func testOnlyTheSelfTestShortensChromiumsProtectionTimes() throws {
        // Chromium does not freeze a page for five minutes after it was on screen. The
        // self-test's step cannot wait: its launch makes that a second. No other launch does.
        for (isRelease, isShipped) in [(false, false), (true, false), (true, true)] {
            let launch = ChromiumLaunchArguments.engineArguments(["Darni"], defaultUserDataDir: { "/data" }, keychain: .system,
                                                                 isRelease: isRelease, isShipped: isShipped)
            XCTAssertFalse(launch.contains { $0.contains("freezing_") }, "release \(isRelease), shipped \(isShipped)")
            XCTAssertFalse(ChromiumLaunchArguments.benchArguments(launch).contains { $0.contains("freezing_") })
            let selfTest = ChromiumLaunchArguments.selfTestArguments(launch)
            let last = try XCTUnwrap(selfTest.last { $0.hasPrefix("--enable-features=") })
            XCTAssertEqual(last, ChromiumLaunchArguments.selfTestFreezeSwitch)
            let features = last.dropFirst("--enable-features=".count).split(separator: ",").map(String.init)
            XCTAssertTrue(features.contains("CPUMeasurementInFreezingPolicy:freezing_visible_protection_time/1s/freezing_audio_protection_time/1s"))
            // It replaces the launch's own switch, so it carries what every launch turns on.
            for feature in ChromiumLaunchArguments.persistedProfileFeatureNames + ChromiumLaunchArguments.enabledEngineFeatureNames {
                XCTAssertTrue(features.contains(feature), feature)
            }
        }
    }

    // MARK: Freezing

    func testAHiddenTabUnseenForThirtyMinutesIsFrozenAndTheTabOnScreenIsNot() {
        let (model, tabs, engines) = makeModel()
        XCTAssertEqual(model.runAutoFreeze(now: now), [tabs["idle"]!.id])
        XCTAssertEqual(engines["idle"]!.calls, ["freeze"])
        XCTAssertTrue(model.isTabFrozen(tabs["idle"]!.id))
        XCTAssertEqual(engines["front"]!.calls, [], "on screen")
        XCTAssertFalse(model.isTabFrozen(tabs["front"]!.id))
        // Frozen is not unloaded: the row keeps its normal icon.
        XCTAssertFalse(model.isTabUnloaded(tabs["idle"]!.id))
        XCTAssertFalse(engines["idle"]!.isDiscarded)
        XCTAssertEqual(engines["idle"]!.activity, .idle)
    }

    func testATabSeenMoreRecentlyThanTheThresholdRuns() {
        let (model, _, engines) = makeModel(shown: 20)
        XCTAssertEqual(model.runAutoFreeze(now: now), [])
        XCTAssertEqual(engines["idle"]!.calls, [])
        model.tabFreezeThreshold = .fifteenMinutes
        XCTAssertEqual(engines["idle"]!.calls, ["freeze"], "a shorter wait applies at once")
    }

    func testAFrozenTabIsNotAskedTwice() {
        let (model, _, engines) = makeModel()
        model.runAutoFreeze(now: now)
        XCTAssertEqual(model.runAutoFreeze(now: now.addingTimeInterval(300)), [])
        XCTAssertEqual(engines["idle"]!.calls, ["freeze"])
    }

    func testNeverFreezesNothing() {
        let (model, _, engines) = makeModel(shown: 9 * 60)
        model.tabFreezeThreshold = .never
        model.tabUnloadThreshold = .never
        XCTAssertEqual(model.runAutoFreeze(now: now), [])
        XCTAssertEqual(engines["idle"]!.calls, [])
    }

    func testARefusalLeavesTheTabRunningAndItIsAskedAgainAtTheNextCheck() {
        let (model, tabs, engines) = makeModel()
        engines["idle"]!.freezeAnswer = .refusedForNow
        XCTAssertEqual(model.runAutoFreeze(now: now), [])
        XCTAssertFalse(model.isTabFrozen(tabs["idle"]!.id))
        engines["idle"]!.freezeAnswer = .requested
        XCTAssertEqual(model.runAutoFreeze(now: now.addingTimeInterval(300)), [tabs["idle"]!.id])
        XCTAssertEqual(engines["idle"]!.calls, ["freeze", "freeze"])
    }

    func testAnEngineThatCannotFreezeIsLeftAloneAndNothingIsUnloadedInstead() {
        let (model, tabs, engines) = makeModel()
        engines["idle"]!.freezeAnswer = .unsupported
        XCTAssertEqual(model.runAutoFreeze(now: now), [])
        XCTAssertEqual(engines["idle"]!.calls, ["freeze"])
        XCTAssertFalse(model.isTabUnloaded(tabs["idle"]!.id))
        XCTAssertNotNil(model.engineHost.engine(forTabID: tabs["idle"]!.id, profileID: model.profileID(for: tabs["idle"]!)))
    }

    func testAWebKitTabIsNeverFrozenAndStillUnloads() throws {
        // WKEngine has no freeze call: the page runs until the unload.
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("darni-sleep-\(UUID().uuidString)")
        let model = BrowserViewModel(store: store, persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
                                     syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil))
        model.tabUnloadDefaults = scratchDefaults()
        let a = store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!)
        let b = store.addTab(kind: .today, title: "B", url: URL(string: "https://b.test")!)
        model.selectTab(b.id)
        model.selectTab(a.id)
        XCTAssertFalse(try XCTUnwrap(model.engineHost.engine(forTabID: b.id, profileID: model.profileID(for: b))) is TabFreezing)
        model.tabLastShown[b.id] = ago(5 * 60)
        model.tabFreezeThreshold = .fifteenMinutes
        XCTAssertEqual(model.runAutoFreeze(now: now), [])
        XCTAssertFalse(model.isTabFrozen(b.id))
        XCTAssertFalse(model.isTabUnloaded(b.id))
        model.tabUnloadThreshold = .fourHours
        XCTAssertEqual(model.runAutoUnload(now: now), [b.id])
    }

    // MARK: Every exemption, as the model sees it

    func testATabThatPlaysOrIsHeardIsNotFrozen() {
        let (model, tabs, engines) = makeModel(["heard", "playing", "pip", "paused"])
        model.mediaStateByTab[tabs["heard"]!.id] = WebMediaState(isAudible: true)
        model.mediaStateByTab[tabs["playing"]!.id] = WebMediaState(isPlaying: true)
        model.mediaStateByTab[tabs["pip"]!.id] = WebMediaState(isPictureInPicture: true)
        // Paused media is not a use: the tab sleeps, and Play wakes it.
        model.mediaStateByTab[tabs["paused"]!.id] = WebMediaState(isPaused: true)
        XCTAssertEqual(model.runAutoFreeze(now: now), [tabs["paused"]!.id])
        for name in ["heard", "playing", "pip"] { XCTAssertEqual(engines[name]!.calls, [], name) }
    }

    func testATabWithAPromptOpenIsNotFrozen() {
        let (model, _, engines) = makeModel()
        engines["idle"]!.pagePrompts.presentDialog(
            JavaScriptDialogRequest(id: 1, kind: .confirm, message: "Sure?", origin: "https://idle.test")) { _ in }
        XCTAssertTrue(engines["idle"]!.pagePrompts.hasPendingPrompt)
        XCTAssertEqual(model.runAutoFreeze(now: now), [])
        XCTAssertEqual(engines["idle"]!.calls, [])
    }

    func testATabInACallOrSharingIsNotFrozen() {
        let (model, tabs, engines) = makeModel(["camera", "microphone", "sharing"])
        model.captureStateByTab[tabs["camera"]!.id] = MediaCaptureState(isCapturingVideo: true)
        model.captureStateByTab[tabs["microphone"]!.id] = MediaCaptureState(isCapturingAudio: true)
        model.screenShareCaptureChanged(tabs["sharing"]!.id, live: true)
        XCTAssertEqual(model.runAutoFreeze(now: now), [])
        for engine in engines.values { XCTAssertEqual(engine.calls, []) }
    }

    func testTheSharedTabItselfIsNotFrozenFromTheMomentItIsChosen() {
        let (model, tabs, engines) = makeModel(["meet", "docs"])
        let prompts = PagePromptCenter()
        prompts.ownerTabID = tabs["meet"]!.id
        // The person picked "docs" in the sheet; the stream is not live yet.
        model.screenShareStarted(ScreenShare(kind: .tab, target: tabs["docs"]!.id), site: "meet.test", from: prompts)
        XCTAssertEqual(model.runAutoFreeze(now: now), [tabs["meet"]!.id], "only the asking tab, which shares nothing yet")
        XCTAssertEqual(engines["docs"]!.calls, [])
        model.thawTab(tabs["meet"]!.id, reason: .due)
        // Live: neither the page that captures nor the tab it shows.
        model.screenShareCaptureChanged(tabs["meet"]!.id, live: true)
        XCTAssertEqual(model.runAutoFreeze(now: now), [])
        XCTAssertEqual(engines["docs"]!.calls, [])
        // Over: both may sleep again.
        model.screenShareCaptureChanged(tabs["meet"]!.id, live: false)
        XCTAssertEqual(Set(model.runAutoFreeze(now: now)), [tabs["meet"]!.id, tabs["docs"]!.id])
    }

    func testAFrozenTabThatIsPickedForAShareIsThawedAtTheNextCheck() {
        // The engine thaws the tab it starts to share at once; this is the shell's own check.
        let (model, tabs, engines) = makeModel(["meet", "docs"])
        model.runAutoFreeze(now: now)
        XCTAssertTrue(model.isTabFrozen(tabs["docs"]!.id))
        let prompts = PagePromptCenter()
        prompts.ownerTabID = tabs["meet"]!.id
        model.screenShareStarted(ScreenShare(kind: .tab, target: tabs["docs"]!.id), site: "meet.test", from: prompts)
        model.runAutoFreeze(now: now)
        XCTAssertFalse(model.isTabFrozen(tabs["docs"]!.id))
        XCTAssertEqual(engines["docs"]!.calls, ["freeze", "unfreeze"])
    }

    func testATabWithADownloadRunningIsNotFrozenUntilItEnds() {
        let (model, tabs, engines) = makeModel()
        let created = DownloadEvent(kind: .created, guid: "one", url: "https://idle.test/big.zip", targetPath: "/tmp/big.zip", totalBytes: 100)
        model.downloads.apply(created, source: .webKit)
        model.downloads.noteOrigin(DownloadOrigin(page: TidyDownloads.Origin(), isPrivate: false, engine: ObjectIdentifier(engines["idle"]!)), for: "one")
        XCTAssertTrue(model.downloads.hasLiveDownload(startedBy: engines["idle"]!))
        XCTAssertFalse(model.downloads.hasLiveDownload(startedBy: engines["front"]!))
        XCTAssertEqual(model.runAutoFreeze(now: now), [])
        model.downloads.apply(DownloadEvent(kind: .cancelled, guid: "one", url: created.url, targetPath: "/tmp/big.zip",
                                            totalBytes: 100, state: .cancelled), source: .webKit)
        let done = expectation(description: "the cancel is applied")
        func poll(_ tries: Int) {
            if !model.downloads.hasLiveDownload(startedBy: engines["idle"]!) || tries == 0 { return done.fulfill() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll(tries - 1) }
        }
        poll(200)
        wait(for: [done], timeout: 10)
        XCTAssertFalse(model.downloads.hasLiveDownload(startedBy: engines["idle"]!))
        XCTAssertEqual(model.runAutoFreeze(now: now), [tabs["idle"]!.id])
    }

    func testPeekAndLittleDarniPagesAreNeverFrozenOrUnloaded() throws {
        let (model, tabs, engines) = makeModel()
        // A Peek over the tab on screen and a Little Darni window: engines of their own.
        engines["front"]!.linkPeekHandler?(URL(string: "https://peek.test/page")!)
        let peek = try XCTUnwrap(model.peekEngine)
        _ = model.openLittleArc(url: URL(string: "https://little.test/")!)
        let listed = Set(model.tabSleepCandidates(now: now).map(\.tabID))
        XCTAssertEqual(listed, Set(tabs.values.map(\.id)), "only sidebar tabs are ever candidates")
        XCTAssertFalse(model.engineHost.allTabEngines().contains { ($0.2 as AnyObject) === (peek as AnyObject) })
        // And a tab engine that still carries a Peek's or a Little Darni's role is left alone.
        for role in [EngineRole.peek, .littleArc, .privateWindow] {
            engines["idle"]!.pagePrompts.role = role
            model.tabLastShown[tabs["idle"]!.id] = ago(9 * 60)
            XCTAssertEqual(model.runAutoFreeze(now: now), [], "\(role)")
            XCTAssertEqual(model.runAutoUnload(now: now), [], "\(role)")
        }
        XCTAssertEqual(engines["idle"]!.calls, [])
    }

    // MARK: Thawing

    func testShowingAFrozenTabThawsItAndLoadsNothing() {
        let (model, tabs, engines) = makeModel()
        model.runAutoFreeze(now: now)
        engines["idle"]!.calls = []
        let tabCount = model.store.displayTabs().count
        model.selectTab(tabs["idle"]!.id)
        // The one thing the shell does: no load, no reload, no script, no media command.
        XCTAssertEqual(engines["idle"]!.calls, ["unfreeze"])
        XCTAssertFalse(model.isTabFrozen(tabs["idle"]!.id))
        XCTAssertFalse(model.isTabUnloaded(tabs["idle"]!.id))
        // And nothing of the shell's own is run for the page at the thaw:
        // no prompt, no new tab, no download, no toast.
        XCTAssertFalse(engines["idle"]!.pagePrompts.hasPendingPrompt)
        XCTAssertEqual(model.store.displayTabs().count, tabCount)
        XCTAssertTrue(model.downloads.list.records.isEmpty)
        XCTAssertNil(model.toast)
    }

    func testShowingATabThatIsNotFrozenAsksTheEngineNothing() {
        let (model, tabs, engines) = makeModel()
        model.selectTab(tabs["idle"]!.id)
        XCTAssertEqual(engines["idle"]!.calls, [])
    }

    func testTheTabThatWasShownStartsItsWaitAgain() {
        let (model, tabs, engines) = makeModel()
        model.runAutoFreeze(now: now)
        model.selectTab(tabs["idle"]!.id)
        model.selectTab(tabs["front"]!.id)
        engines["idle"]!.calls = []
        // Hidden a moment ago: not due.
        XCTAssertEqual(model.runAutoFreeze(), [])
        XCTAssertEqual(engines["idle"]!.calls, [])
    }

    // MARK: The Task Manager's history

    private func events(_ model: BrowserViewModel, _ tab: Tab) -> [String] {
        (model.taskManager.history[TaskManagerStack.historyKey(sidebarID: tab.id.uuidString)]?.events ?? [])
            .map { "\($0.kind.rawValue) \($0.cause.rawValue)" }
    }

    func testTheTaskManagerHearsWhatTabSleepDidAndWhatDidIt() {
        let (model, tabs, _) = makeModel(["idle", "other"])
        // As with its window open (or the history kept while it's closed).
        model.taskManager.startPolling()
        defer { model.taskManager.stopPolling() }
        model.runAutoFreeze(now: now)
        XCTAssertEqual(events(model, tabs["idle"]!), ["fellAsleep automatic"])
        model.selectTab(tabs["idle"]!.id)
        XCTAssertEqual(events(model, tabs["idle"]!), ["fellAsleep automatic", "woke shown"])
        model.unloadTab(tabs["other"]!.id)
        XCTAssertEqual(events(model, tabs["other"]!), ["fellAsleep automatic", "unloaded sidebar"], "an unload ends its sleep")
        model.selectTab(tabs["other"]!.id)
        XCTAssertEqual(events(model, tabs["other"]!), ["fellAsleep automatic", "unloaded sidebar", "loaded shown"])
        XCTAssertEqual(events(model, tabs["front"]!), [], "showing a tab that never slept is no news")
    }

    func testTheTaskManagerHearsNothingWithItsWindowClosedAndItsHistoryOff() {
        let (model, tabs, _) = makeModel()
        XCTAssertFalse(model.taskManager.isPolling)
        XCTAssertFalse(model.taskManager.isReadingInBackground, "no engine attached in a test")
        model.runAutoFreeze(now: now)
        XCTAssertEqual(events(model, tabs["idle"]!), [])
    }

    func testSleepFromTheTaskManagerHoldsUntilTheTabIsUsedOrShown() {
        // Seen 5 minutes ago: the rule would not freeze it for another 25.
        let (model, tabs, engines) = makeModel(["idle"], shown: 5)
        let id = tabs["idle"]!.id
        model.taskManager.startPolling()
        defer { model.taskManager.stopPolling() }
        XCTAssertFalse(model.canSleepTab(tabs["front"]!.id), "on screen")
        XCTAssertTrue(model.canSleepTab(id))
        XCTAssertTrue(model.sleepTab(id))
        XCTAssertEqual(engines["idle"]!.calls, ["freeze"])
        XCTAssertFalse(model.canSleepTab(id), "already asleep")
        XCTAssertEqual(events(model, tabs["idle"]!), ["fellAsleep taskManager"])
        // The rule's next check finds it "not due" and leaves it asleep.
        model.runAutoFreeze(now: now.addingTimeInterval(60))
        XCTAssertEqual(engines["idle"]!.calls, ["freeze"])
        XCTAssertTrue(model.isTabFrozen(id))
        // In use: it runs again.
        model.captureStateByTab[id] = MediaCaptureState(isCapturingAudio: true)
        model.runAutoFreeze(now: now.addingTimeInterval(120))
        XCTAssertEqual(engines["idle"]!.calls, ["freeze", "unfreeze"])
        XCTAssertEqual(events(model, tabs["idle"]!), ["fellAsleep taskManager", "woke rule"])
        XCTAssertFalse(model.canSleepTab(id), "in use")
    }

    /// Security N-3 (PRE-task-manager-history-insights): Sleep from the Task
    /// Manager is refused, and its action does nothing, for every reason the
    /// rule counts a tab as in use.
    func testSleepIsRefusedForEveryInUseReason() {
        let reasons = ["heard", "playing", "pip", "prompt", "camera", "microphone", "sharing", "shareTarget", "download", "peek", "littleArc"]
        let (model, tabs, engines) = makeModel(["idle"] + reasons)
        let id = { (name: String) in tabs[name]!.id }
        model.mediaStateByTab[id("heard")] = WebMediaState(isAudible: true)
        model.mediaStateByTab[id("playing")] = WebMediaState(isPlaying: true)
        model.mediaStateByTab[id("pip")] = WebMediaState(isPictureInPicture: true)
        engines["prompt"]!.pagePrompts.presentDialog(
            JavaScriptDialogRequest(id: 1, kind: .confirm, message: "Sure?", origin: "https://prompt.test")) { _ in }
        model.captureStateByTab[id("camera")] = MediaCaptureState(isCapturingVideo: true)
        model.captureStateByTab[id("microphone")] = MediaCaptureState(isCapturingAudio: true)
        model.screenShareCaptureChanged(id("sharing"), live: true)
        let prompts = PagePromptCenter()
        prompts.ownerTabID = id("idle")
        model.screenShareStarted(ScreenShare(kind: .tab, target: id("shareTarget")), site: "meet.test", from: prompts)
        let created = DownloadEvent(kind: .created, guid: "n3", url: "https://download.test/big.zip", targetPath: "/tmp/big.zip", totalBytes: 100)
        model.downloads.apply(created, source: .webKit)
        model.downloads.noteOrigin(DownloadOrigin(page: TidyDownloads.Origin(), isPrivate: false, engine: ObjectIdentifier(engines["download"]!)), for: "n3")
        engines["peek"]!.pagePrompts.role = .peek
        engines["littleArc"]!.pagePrompts.role = .littleArc

        XCTAssertFalse(model.canSleepTab(id("front")), "on screen")
        XCTAssertFalse(model.sleepTab(id("front")), "on screen")
        for name in reasons {
            XCTAssertFalse(model.canSleepTab(id(name)), "\(name): Sleep is offered for a tab in use")
            XCTAssertFalse(model.sleepTab(id(name)), "\(name): the action froze a tab in use")
            XCTAssertEqual(engines[name]!.calls, [], name)
        }
        // The control: a tab with none of them sleeps.
        XCTAssertTrue(model.canSleepTab(id("idle")))
        XCTAssertTrue(model.sleepTab(id("idle")))
    }

    func testAnEngineThatCannotFreezeOffersNoSleep() throws {
        let (model, tabs, engines) = makeModel(["idle"])
        engines["idle"]!.freezeAnswer = .refusedForNow
        XCTAssertFalse(model.sleepTab(tabs["idle"]!.id), "the engine said not now")
        XCTAssertFalse(model.isTabFrozen(tabs["idle"]!.id))
    }

    func testTurningFreezingOffThawsEveryFrozenTabAtOnce() {
        let (model, tabs, engines) = makeModel(["one", "two"])
        model.runAutoFreeze(now: now)
        XCTAssertTrue(model.isTabFrozen(tabs["one"]!.id) && model.isTabFrozen(tabs["two"]!.id))
        model.tabFreezeThreshold = .never
        XCTAssertFalse(model.isTabFrozen(tabs["one"]!.id) || model.isTabFrozen(tabs["two"]!.id))
        XCTAssertEqual(engines["one"]!.calls, ["freeze", "unfreeze"])
    }

    func testAFrozenTabThatStartsToBeUsedIsThawedAtTheNextCheck() {
        let (model, tabs, engines) = makeModel()
        model.runAutoFreeze(now: now)
        model.captureStateByTab[tabs["idle"]!.id] = MediaCaptureState(isCapturingAudio: true)
        XCTAssertEqual(model.runAutoFreeze(now: now.addingTimeInterval(300)), [])
        XCTAssertEqual(engines["idle"]!.calls, ["freeze", "unfreeze"])
    }

    // MARK: The choice

    func testTheFreezeChoiceIsSavedAndTheUnloadChoiceIsUntouched() {
        let (model, _, _) = makeModel()
        model.tabUnloadThreshold = .twelveHours
        model.tabFreezeThreshold = .oneHour
        XCTAssertEqual(TabFreezeThreshold.load(from: model.tabUnloadDefaults), .oneHour)
        XCTAssertEqual(TabUnloadThreshold.load(from: model.tabUnloadDefaults), .twelveHours)
        XCTAssertEqual(model.tabUnloadDefaults.string(forKey: "ReArcTabFreezeThreshold"), "oneHour")
    }

    func testSettingsAndTheArchiveSayTheSameTwoChoices() {
        // Both bind the model's two values; these are the words of the rows.
        XCTAssertEqual(TabSleepSettings.freezeLabel, "Freeze inactive tabs")
        XCTAssertEqual(TabSleepSettings.unloadLabel, "Unload inactive tabs")
        XCTAssertFalse(TabSleepSettings.freezeDetail.isEmpty || TabSleepSettings.unloadDetail.isEmpty)
        XCTAssertEqual(TabFreezeThreshold.allCases.map(\.title), ["Never", "After 15 Minutes", "After 30 Minutes", "After 1 Hour"])
        XCTAssertEqual(TabUnloadThreshold.allCases.map(\.title),
                       ["Never", "After 30 Minutes", "After 1 Hour", "After 4 Hours", "After 12 Hours"])
    }

    // MARK: Unloading, after the freeze

    func testAFrozenTabIsUnloadedAtTheUnloadThresholdAndItsRequestEnds() {
        let (model, tabs, engines) = makeModel(shown: 5 * 60)
        model.runAutoFreeze(now: now)
        XCTAssertEqual(model.runAutoUnload(now: now), [tabs["idle"]!.id])
        XCTAssertEqual(engines["idle"]!.calls, ["freeze", "discard"])
        XCTAssertTrue(model.isTabUnloaded(tabs["idle"]!.id))
        XCTAssertFalse(model.isTabFrozen(tabs["idle"]!.id))
        // Unloaded: not asked to freeze again.
        XCTAssertEqual(model.runAutoFreeze(now: now.addingTimeInterval(300)), [])
    }

    func testTheUnloadSkipsEveryTabInUseAsTheFreezeDoes() {
        let (model, tabs, _) = makeModel(["call", "shared", "idle"], shown: 5 * 60)
        model.captureStateByTab[tabs["call"]!.id] = MediaCaptureState(isCapturingAudio: true)
        let prompts = PagePromptCenter()
        prompts.ownerTabID = tabs["call"]!.id
        model.screenShareStarted(ScreenShare(kind: .tab, target: tabs["shared"]!.id), site: "call.test", from: prompts)
        XCTAssertEqual(model.runAutoUnload(now: now), [tabs["idle"]!.id])
    }

    // MARK: "Leave site?": a page with unsaved input

    /// The engine refuses to discard a page with a beforeunload handler, every time.
    func testTheAutomaticUnloadNeverDropsAPageTheEngineWillNotDiscard() {
        let (model, tabs, engines) = makeModel(["guarded"], shown: 5 * 60)
        let guarded = engines["guarded"]!
        guarded.discardAnswer = .refusedForNow
        model.discardRetryDelays = [0.01, 0.01, 0.01]
        XCTAssertEqual(model.runAutoUnload(now: now), [tabs["guarded"]!.id], "it is due, and asked")
        // Waits for the three retries (a loaded Mac runs them late), then a moment more: no fifth.
        let retried = expectation(description: "every retry has run")
        func poll(_ tries: Int) {
            if guarded.count("discard") >= 4 || tries == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { retried.fulfill() }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll(tries - 1) }
        }
        poll(500)
        wait(for: [retried], timeout: 15)
        XCTAssertEqual(guarded.count("discard"), 4, "asked, and three more times")
        // Still loaded, with the same page: nothing was dropped and nothing reloaded.
        let engine = model.engineHost.engine(forTabID: tabs["guarded"]!.id, profileID: model.profileID(for: tabs["guarded"]!))
        XCTAssertTrue(engine === guarded)
        XCTAssertFalse(model.isTabUnloaded(tabs["guarded"]!.id))
        XCTAssertFalse(guarded.isDiscarded)
        XCTAssertFalse(guarded.calls.contains("load") || guarded.calls.contains("reload"))
        // The next check asks again, and again leaves it.
        model.runAutoUnload(now: now.addingTimeInterval(300))
        XCTAssertTrue(model.engineHost.engine(forTabID: tabs["guarded"]!.id, profileID: model.profileID(for: tabs["guarded"]!)) === guarded)
    }

    func testAPageWithUnsavedInputMayBeFrozenAndStaysFrozenWhenTheUnloadIsRefused() {
        let (model, tabs, engines) = makeModel(["guarded"], shown: 5 * 60)
        let guarded = engines["guarded"]!
        guarded.discardAnswer = .refusedForNow
        model.discardRetryDelays = []
        XCTAssertEqual(model.runAutoFreeze(now: now), [tabs["guarded"]!.id])
        model.runAutoUnload(now: now)
        XCTAssertEqual(guarded.calls, ["freeze", "discard"])
        XCTAssertTrue(model.isTabFrozen(tabs["guarded"]!.id), "the refusal does not wake it")
        XCTAssertFalse(model.isTabUnloaded(tabs["guarded"]!.id))
        XCTAssertTrue(model.engineHost.engine(forTabID: tabs["guarded"]!.id, profileID: model.profileID(for: tabs["guarded"]!)) === guarded)
    }

    // MARK: The file log (NIGHT-1125 point 7)

    private func logLines(_ url: URL) -> [String] {
        // Each line: timestamp, "pid N", then the journal's words.
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map {
            $0.split(separator: " ", maxSplits: 3).dropFirst(3).joined()
        }
    }

    func testFreezeFrozenAndThawGoToTheFileLogWithTheTabIdOnly() throws {
        let (model, tabs, engines) = makeModel(["idle", "other"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("darni-sleep-log-\(UUID().uuidString)/Logs/tab-sleep.log")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        model.tabSleepLog = TabSleepLog(url: file)
        let idle = tabs["idle"]!.id, other = tabs["other"]!.id

        XCTAssertEqual(Set(model.runAutoFreeze(now: now)), [idle, other])
        XCTAssertEqual(Set(logLines(file)), ["tab \(idle.uuidString) freeze requested", "tab \(other.uuidString) freeze requested"])

        // The renderer reports the freeze; the next look says so, once.
        engines["idle"]!.isPageFrozen = true
        model.observeTabFreezes()
        model.observeTabFreezes()
        XCTAssertEqual(logLines(file).last, "tab \(idle.uuidString) frozen")
        XCTAssertEqual(logLines(file).count, 3)

        // Shown: the shell ends the request and says the page had frozen.
        model.selectTab(idle)
        model.noteVisibleTabsShown(at: now)
        XCTAssertEqual(logLines(file).last, "tab \(idle.uuidString) thawed (shown); it had frozen")

        // The engine ended the other request by itself (the page was used).
        engines["other"]!.isFreezeRequested = false
        model.observeTabFreezes()
        XCTAssertEqual(logLines(file).last, "tab \(other.uuidString) thawed (the engine ended it: the tab was used or unloaded); not seen frozen")
        XCTAssertEqual(logLines(file).count, 5)

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("http") || text.contains(".test") || text.contains("idle") || text.contains("other"),
                       "no address and no title: \(text)")
        XCTAssertTrue(text.contains("pid \(ProcessInfo.processInfo.processIdentifier) "))
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600, "the person's only")
    }

    func testATestProcessWritesNoTabSleepLogOfItsOwn() {
        XCTAssertNil(TabSleepLog.standard.url, "tests never write into the real data folder")
        XCTAssertNil(BrowserViewModel(store: SidebarStore(spaces: [Space(name: "Main", sortRank: "a")]),
                                      persistence: SidebarFilePersistence(fileURL: FileManager.default.temporaryDirectory
                                          .appendingPathComponent("darni-sleep-\(UUID().uuidString)/sidebar.json")),
                                      syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil)).tabSleepLog.url)
    }

    // MARK: What the Task Manager shows

    func testTheTaskManagerSeesEachTabsStateAndIdleTimeAndChangesNothing() {
        let (model, tabs, engines) = makeModel(["idle", "heard", "asleep", "drowsy", "gone", "new"])
        model.mediaStateByTab[tabs["heard"]!.id] = WebMediaState(isAudible: true)
        engines["asleep"]!.isFreezeRequested = true
        engines["asleep"]!.isPageFrozen = true
        engines["drowsy"]!.isFreezeRequested = true
        engines["drowsy"]!.isPageFrozen = false
        model.unloadTab(tabs["gone"]!.id)
        XCTAssertTrue(model.isTabUnloaded(tabs["gone"]!.id))
        // A tab whose wait has not started: the Task Manager reads its last use, and starts nothing.
        model.tabLastShown[tabs["new"]!.id] = nil
        for engine in engines.values { engine.calls = [] }
        let waits = model.tabLastShown

        let sleep = model.taskManagerTabSleep(now: now)
        let state = { (name: String) in sleep.byTab[tabs[name]!.id] }
        XCTAssertEqual(state("front"), TaskManagerTabSleep(state: .active, idle: 0, isOnScreen: true))
        XCTAssertEqual(state("idle"), TaskManagerTabSleep(state: .active, idle: 45 * 60), "unseen, not asleep yet: active")
        XCTAssertEqual(state("heard")?.state, .keptAwake(.playingSound))
        XCTAssertEqual(state("asleep")?.state, .sleeping)
        XCTAssertEqual(state("drowsy")?.state, .fallingAsleep, "asked, but the renderer has not frozen")
        XCTAssertEqual(state("gone")?.state, .unloaded)
        XCTAssertNotNil(state("new")?.idle, "the tab's own last use")

        XCTAssertEqual(sleep.unloaded.map(\.id), [tabs["gone"]!.id.uuidString], "only the tab with no page in memory gets a row of its own")
        XCTAssertEqual(sleep.unloaded.first?.title, "gone")
        XCTAssertEqual(sleep.unloaded.first?.idle, 45 * 60)

        XCTAssertEqual(model.tabLastShown, waits, "looking starts no wait")
        for (name, engine) in engines { XCTAssertEqual(engine.calls, [], name) }
        XCTAssertFalse(model.isTabFrozen(tabs["idle"]!.id))
    }

    func testTabsImportedTogetherAreNotLoadedAndNotOpenedInDarniAndAnUnloadedTabIsUnloaded() throws {
        let (model, tabs, _) = makeModel(["gone"])
        // An import: every tab gets the import's time.
        let imported = now.addingTimeInterval(-(14 * 24 + 7) * 3600)
        model.store.now = { imported }
        let batch = (0 ..< 4).map { model.store.addTab(kind: .today, title: "Imported \($0)", url: URL(string: "https://import\($0).test/")!) }
        // One opened in Darni two days ago, alone at its time.
        model.store.now = { self.now.addingTimeInterval(-2 * 24 * 3600) }
        let visited = model.store.addTab(kind: .today, title: "Visited", url: URL(string: "https://visited.test/")!)
        model.unloadTab(tabs["gone"]!.id)
        let sleep = model.taskManagerTabSleep(now: now)
        let row = { (id: Tab.ID) in sleep.unloaded.first { $0.id == id.uuidString } }
        for tab in batch {
            XCTAssertEqual(row(tab.id)?.openedInDarni, false, tab.title)
            XCTAssertEqual(row(tab.id)?.wasUnloaded, false)
            XCTAssertEqual(row(tab.id)?.hasOwnRow, false, "folds")
        }
        XCTAssertEqual(row(visited.id)?.openedInDarni, true)
        XCTAssertEqual(row(visited.id)?.wasUnloaded, false)
        XCTAssertEqual(row(visited.id)?.hasOwnRow, false, "opened two days ago: folds")
        XCTAssertEqual(row(tabs["gone"]!.id)?.wasUnloaded, true, "tab sleep or the person unloaded it")
        XCTAssertEqual(row(tabs["gone"]!.id)?.hasOwnRow, true)
    }

    func testATabNotOpenedSinceLaunchIsListedUnloadedWithItsLastUse() throws {
        let (model, _, _) = makeModel([])
        model.store.now = { self.now.addingTimeInterval(-2 * 3600 - 59) }
        let folderless = model.store.addTab(kind: .today, title: "Report", url: URL(string: "https://report.test/")!)
        let pinned = model.store.addTab(kind: .pinned, title: "Wiki", url: URL(string: "https://wiki.test/")!)
        let sleep = model.taskManagerTabSleep(now: now)
        XCTAssertNil(sleep.byTab[folderless.id], "no engine: nothing for the sleep checks")
        XCTAssertEqual(Set(sleep.unloaded.map(\.id)), [folderless.id.uuidString, pinned.id.uuidString])
        let report = try XCTUnwrap(sleep.unloaded.first { $0.id == folderless.id.uuidString })
        XCTAssertEqual(report.title, "Report")
        XCTAssertEqual(report.idle, 2 * 3600, "whole minutes")
        XCTAssertEqual(model.sidebarTab(fromTaskManager: folderless.id.uuidString), folderless.id)
        XCTAssertNil(model.sidebarTab(fromTaskManager: UUID().uuidString), "a tab closed since the reading")
        XCTAssertNil(model.sidebarTab(fromTaskManager: "not an id"))
    }

    func testTheTaskManagersHelpFollowsTheSleepSettings() {
        let (model, _, _) = makeModel([])
        model.tabFreezeThreshold = .oneHour
        model.tabUnloadThreshold = .twelveHours
        XCTAssertEqual(model.taskManagerSleepSettings(canFreeze: true),
                       TaskManagerSleepSettings(freezeAfter: 3600, unloadAfter: 12 * 3600, canFreeze: true))
        model.tabFreezeThreshold = .never
        XCTAssertNil(model.taskManagerSleepSettings(canFreeze: false).freezeAfter)
    }

    func testTheJournalSaysEachThingOnce() {
        var journal = TabFreezeJournal()
        let id = UUID()
        XCTAssertNil(journal.observed(id, frozen: true), "no request, nothing to say")
        XCTAssertNil(journal.thawed(id, reason: .shown))
        XCTAssertEqual(journal.freezeRequested(id), "tab \(id.uuidString) freeze requested")
        XCTAssertNil(journal.freezeRequested(id))
        XCTAssertNil(journal.observed(id, frozen: false))
        XCTAssertNil(journal.observed(id, frozen: nil))
        XCTAssertEqual(journal.thawed(id, reason: .due, frozenNow: false), "tab \(id.uuidString) thawed (in use again or no longer due); it had not frozen yet")
        XCTAssertNil(journal.thawed(id, reason: .due))
        _ = journal.freezeRequested(id)
        journal.forget(id)
        XCTAssertEqual(journal, TabFreezeJournal())
    }

    // MARK: "Opened in Darni" marks (owner, 2026-11-27)

    /// Spins the main queue until `condition` holds (the mutation follow-up runs on the next turn).
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testATabIsMarkedTheFirstTimeItIsShownOrLoadedAndKeepsItsFirstDate() throws {
        let (model, tabs, _) = makeModel(["idle", "background"])
        XCTAssertNotNil(model.tabOpenedAt(tabs["front"]!.id), "selected, so shown")
        XCTAssertNil(model.tabOpenedAt(tabs["idle"]!.id), "never shown, never loaded")
        XCTAssertNil(model.tabOpenedAt(tabs["background"]!.id))

        model.selectTab(tabs["idle"]!.id)
        let first = try XCTUnwrap(model.tabOpenedAt(tabs["idle"]!.id))
        model.selectTab(tabs["front"]!.id)
        model.selectTab(tabs["idle"]!.id)
        XCTAssertEqual(model.tabOpenedAt(tabs["idle"]!.id), first, "the first time, not the last")

        // A page committed in a tab that isn't shown: loaded in Darni.
        model.handleTabNavigationCommit(tabID: tabs["background"]!.id, url: URL(string: "https://background.test/")!, title: "Background")
        XCTAssertNotNil(model.tabOpenedAt(tabs["background"]!.id))

        // A new engine's empty first document is not the tab's page.
        let fresh = model.store.addTab(kind: .today, title: "Fresh", url: URL(string: "https://fresh.test/")!)
        model.handleTabNavigationCommit(tabID: fresh.id, url: URL(string: "about:blank")!, title: "about:blank")
        XCTAssertNil(model.tabOpenedAt(fresh.id))
    }

    func testTheMarksOutliveALaunchInTheirOwnFileAndNotInTheSidebarFile() throws {
        let (model, tabs, _) = makeModel(["idle"])
        model.selectTab(tabs["idle"]!.id)
        let idle = try XCTUnwrap(model.tabOpenedAt(tabs["idle"]!.id))
        model.saveTabOpenedMarks()
        model.persistence.flush()
        let marksFile = try XCTUnwrap(model.tabOpenedMarksURL)
        XCTAssertEqual(marksFile.deletingLastPathComponent(), model.persistence.fileURL.deletingLastPathComponent(), "beside the sidebar file")
        XCTAssertNotEqual(marksFile.lastPathComponent, model.persistence.fileURL.lastPathComponent)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: marksFile.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600, "the person's only")

        // The next launch reads them back (to the second: the file keeps ISO 8601 times).
        let relaunched = BrowserViewModel(store: SidebarStore(spaces: [Space(name: "Main", sortRank: "a")]),
                                          persistence: SidebarFilePersistence(fileURL: model.persistence.fileURL),
                                          syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil))
        let reread = try XCTUnwrap(relaunched.tabOpenedMarks[tabs["idle"]!.id])
        XCTAssertEqual(reread.timeIntervalSince1970, idle.timeIntervalSince1970, accuracy: 1)
        XCTAssertNotNil(relaunched.tabOpenedMarks[tabs["front"]!.id])

        // sidebar.json, which builds up to 1451 read, is as it was: no key of the marks in any object.
        let sidebar = try JSONSerialization.jsonObject(with: Data(contentsOf: model.persistence.fileURL))
        XCTAssertFalse(Self.jsonKeys(sidebar).contains { $0.lowercased().contains("opened") }, "\(Self.jsonKeys(sidebar).sorted())")
    }

    private static func jsonKeys(_ value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            return object.reduce(into: Set(object.keys)) { $0.formUnion(jsonKeys($1.value)) }
        }
        if let array = value as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(jsonKeys($1)) } }
        return []
    }

    private static func syncKeys(_ value: SyncValue) -> Set<String> {
        switch value {
        case .object(let fields): return fields.reduce(into: Set(fields.keys)) { $0.formUnion(syncKeys($1.value)) }
        case .array(let items): return items.reduce(into: Set<String>()) { $0.formUnion(syncKeys($1)) }
        default: return []
        }
    }

    func testTheMarksAreInNoSyncRecord() throws {
        let (model, tabs, _) = makeModel(["idle"])
        let store = model.store
        let pinned = store.addTab(kind: .pinned, title: "Wiki", url: URL(string: "https://wiki.test/")!)
        let favorite = store.addTab(kind: .favorite, title: "Mail", url: URL(string: "https://mail.test/")!)
        // A pinned split: its record carries its tabs whole (a `Tab` minus the per-Mac keys).
        let left = store.addTab(kind: .pinned, title: "Left", url: URL(string: "https://left.test/")!)
        let right = store.addTab(kind: .pinned, title: "Right", url: URL(string: "https://right.test/")!)
        XCTAssertNotNil(store.createSplit(tabIDs: [left.id, right.id], orientation: .horizontal))
        let marked = [tabs["idle"]!.id, left.id, right.id, pinned.id, favorite.id]
        let opened = Date(timeIntervalSinceReferenceDate: 812_345_678)
        for id in marked { model.markTabOpened(id, at: opened) }
        XCTAssertEqual(marked.filter { model.tabOpenedAt($0) == opened }.count, marked.count)

        let records = SidebarSyncProjection.extract(store.makeSnapshot())
        XCTAssertTrue(records.values.contains { $0.values["type"] == .string("split") }, "the split is synced")
        XCTAssertTrue(records.values.contains { $0.values["url"] == .string("https://wiki.test/") }, "the pinned tab is synced")
        var keys = Set<String>()
        for body in records.values { keys.formUnion(Self.syncKeys(.object(body.values))) }
        XCTAssertFalse(keys.contains { $0.lowercased().contains("opened") }, "\(keys.sorted())")
        let written = String(describing: records)
        XCTAssertFalse(written.contains(String(opened.timeIntervalSinceReferenceDate)), "no record carries the mark's time")
        XCTAssertFalse(written.contains(ISO8601DateFormatter().string(from: opened)))
        // A tab as sidebar.json and a split record encode it: no mark either.
        let tab = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(store.tab(withID: pinned.id))))
        XCTAssertFalse(Self.jsonKeys(tab).contains { $0.lowercased().contains("opened") })
    }

    func testAPrivateWindowWritesNoMark() {
        let (model, _, _) = makeModel([])
        let before = model.tabOpenedMarks
        let window = model.openPrivateWindow(engine: PlainEngine(url: URL(string: "https://private.test/")!),
                                             url: URL(string: "https://private.test/")!)
        model.markTabOpened(window.id)
        XCTAssertEqual(model.tabOpenedMarks, before, "not a sidebar tab")
        XCTAssertNil(model.tabOpenedAt(window.id))
        model.privateWindowClosed(window.id)
        XCTAssertEqual(model.tabOpenedMarks, before)
    }

    func testClosingOrDeletingATabTakesItsMarkAndUnloadingKeepsIt() throws {
        let (model, tabs, _) = makeModel(["closed", "unloaded"])
        let pinned = model.store.addTab(kind: .pinned, title: "Wiki", url: URL(string: "https://wiki.test/")!)
        let deleted = model.store.addTab(kind: .pinned, title: "Old", url: URL(string: "https://old.test/")!)
        let gone = model.store.addTab(kind: .today, title: "Synced away", url: URL(string: "https://away.test/")!)
        for id in [tabs["closed"]!.id, tabs["unloaded"]!.id, pinned.id, deleted.id, gone.id] { model.markTabOpened(id) }

        model.closeTab(tabs["closed"]!.id)
        XCTAssertNil(model.store.tab(withID: tabs["closed"]!.id), "closed: archived")
        XCTAssertNil(model.tabOpenedAt(tabs["closed"]!.id))

        model.deleteTab(deleted.id)
        XCTAssertNil(model.tabOpenedAt(deleted.id))

        // ⌘W on a pinned tab unloads it: still in the sidebar, still opened in Darni.
        model.closeTab(pinned.id)
        XCTAssertNotNil(model.store.tab(withID: pinned.id))
        XCTAssertNotNil(model.tabOpenedAt(pinned.id))
        model.unloadTab(tabs["unloaded"]!.id)
        XCTAssertNotNil(model.tabOpenedAt(tabs["unloaded"]!.id))

        // Gone another way (a sync merge, a folder deleted): the next follow-up drops it.
        model.store.closeTab(gone.id)
        waitUntil { model.tabOpenedAt(gone.id) == nil }
        XCTAssertNil(model.tabOpenedAt(gone.id))

        model.saveTabOpenedMarks()
        let file = TabOpenedMarks.load(from: try XCTUnwrap(model.tabOpenedMarksURL))
        XCTAssertEqual(Set(file.openedAt.keys), Set(model.tabOpenedMarks.openedAt.keys))
        XCTAssertNil(file[tabs["closed"]!.id])
    }

    func testClearHistoryClearsEveryMarkAndRemovesTheFile() throws {
        let (model, tabs, _) = makeModel(["idle"])
        model.selectTab(tabs["idle"]!.id)
        model.saveTabOpenedMarks()
        let file = try XCTUnwrap(model.tabOpenedMarksURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        model.clearVisitHistory()
        XCTAssertTrue(model.tabOpenedMarks.isEmpty)
        model.historySaveQueue.sync {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing left to say when a tab was opened")
        // Shown again afterwards: a new mark.
        model.selectTab(tabs["front"]!.id)
        XCTAssertNotNil(model.tabOpenedAt(tabs["front"]!.id))
    }

    func testTheTaskManagerUsesTheMarkAndFallsBackToTheSameSecondRuleOnlyWithoutOne() throws {
        let (model, _, _) = makeModel([])
        // An Arc import: four tabs with the import's time.
        let imported = now.addingTimeInterval(-(14 * 24 + 7) * 3600)
        model.store.now = { imported }
        let batch = (0 ..< 4).map { model.store.addTab(kind: .today, title: "Imported \($0)", url: URL(string: "https://import\($0).test/")!) }
        // A tab of its own time, from before marks: the fallback says opened.
        model.store.now = { self.now.addingTimeInterval(-2 * 24 * 3600) }
        let legacy = model.store.addTab(kind: .today, title: "Legacy", url: URL(string: "https://legacy.test/")!)
        model.store.now = { self.now }
        // One imported tab was opened in Darni (a page loaded in it, in the background): its
        // last-active time is still the import's, yet it has a mark.
        model.handleTabNavigationCommit(tabID: batch[0].id, url: URL(string: "https://import0.test/")!, title: "Imported 0")

        func row(_ id: Tab.ID) -> TaskManagerUnloadedTab? {
            model.taskManagerTabSleep(now: now).unloaded.first { $0.id == id.uuidString }
        }
        XCTAssertEqual(model.store.tab(withID: batch[0].id)?.lastActiveAt, imported, "the date alone would say import")
        XCTAssertEqual(row(batch[0].id)?.openedInDarni, true, "the mark says opened")
        for tab in batch.dropFirst() { XCTAssertEqual(row(tab.id)?.openedInDarni, false, tab.title) }
        XCTAssertEqual(row(legacy.id)?.openedInDarni, true, "no mark: the fallback, a date of its own")
        let sleep = TaskManagerTabSleep(state: .notLoaded, idle: row(batch[1].id)?.idle, openedInDarni: row(batch[1].id)?.openedInDarni ?? true)
        XCTAssertEqual(sleep.idleText, TaskManagerHelp.notOpenedInDarni)

        // Clear History takes the mark: the fallback again.
        model.clearVisitHistory()
        XCTAssertEqual(row(batch[0].id)?.openedInDarni, false)
    }

    // MARK: The sidebar's Sleep Tab (owner, 2026-11-27)

    func testSidebarSleepIsOffWithItsReasonWhenItCantApply() {
        let (model, tabs, engines) = makeModel(["idle", "heard", "asleep", "gone"])
        model.mediaStateByTab[tabs["heard"]!.id] = WebMediaState(isAudible: true)
        engines["asleep"]!.isFreezeRequested = true
        model.unloadTab(tabs["gone"]!.id)
        let unopened = model.store.addTab(kind: .today, title: "Unopened", url: URL(string: "https://unopened.test/")!)
        let webKitLike = model.store.addTab(kind: .today, title: "No freeze", url: URL(string: "https://nofreeze.test/")!)
        model.engineHost.adopt(PlainEngine(url: webKitLike.url), for: webKitLike, profileID: model.profileID(for: webKitLike))

        XCTAssertNil(model.sleepTabUnavailable(tabs["idle"]!.id))
        XCTAssertTrue(model.canSleepTab(tabs["idle"]!.id))
        XCTAssertEqual(model.sleepTabUnavailable(tabs["front"]!.id), .onScreen)
        XCTAssertEqual(model.sleepTabUnavailable(tabs["heard"]!.id), .inUse(.playingSound))
        XCTAssertEqual(model.sleepTabUnavailable(tabs["asleep"]!.id), .asleep)
        XCTAssertEqual(model.sleepTabUnavailable(tabs["gone"]!.id), .unloaded)
        XCTAssertEqual(model.sleepTabUnavailable(unopened.id), .notLoaded)
        XCTAssertEqual(model.sleepTabUnavailable(webKitLike.id), .engineCannotFreeze)
        for id in [tabs["front"]!.id, tabs["heard"]!.id, tabs["asleep"]!.id, tabs["gone"]!.id, unopened.id, webKitLike.id] {
            XCTAssertFalse(model.canSleepTab(id))
        }
        // The disabled item's tooltip says why.
        XCTAssertEqual(TabSleepUnavailable.onScreen.text, "On screen. A tab sleeps once you leave it.")
        XCTAssertEqual(TabSleepUnavailable.inUse(.playingSound).text, "Doesn't sleep while it plays sound.")
        XCTAssertEqual(TabSleepUnavailable.engineCannotFreeze.text, "This engine can't freeze a tab.")

        // Off means off: the menu's action does nothing to a tab it can't sleep.
        for engine in engines.values { engine.calls = [] }
        model.sleepTabFromSidebar(tabs["front"]!.id)
        model.sleepTabFromSidebar(tabs["heard"]!.id)
        XCTAssertEqual(engines["front"]!.calls, [])
        XCTAssertEqual(engines["heard"]!.calls, [])
    }

    func testSidebarSleepFreezesTheTabAndTheTaskManagerSaysFromTheSidebar() {
        let (model, tabs, engines) = makeModel(["idle"], shown: 5)
        let id = tabs["idle"]!.id
        model.taskManager.startPolling()
        defer { model.taskManager.stopPolling() }
        model.sleepTabFromSidebar(id)
        XCTAssertEqual(engines["idle"]!.calls, ["freeze"])
        XCTAssertEqual(events(model, tabs["idle"]!), ["fellAsleep sidebar"])
        XCTAssertEqual(TaskManagerTabEvent.Cause.sidebar.title, "from the sidebar")
        XCTAssertEqual(model.sleepTabUnavailable(id), .asleep, "the item is off once it sleeps")
        XCTAssertTrue(model.tabsSleptByHand.contains(id), "it holds until shown or used, as the Task Manager's Sleep")
        model.runAutoFreeze(now: now)
        XCTAssertTrue(model.isTabFrozen(id), "not woken for being no longer due")
    }

    func testSidebarSleepInAMultiSelectionActsOnTheClickedRowOnly() {
        let (model, tabs, engines) = makeModel(["a", "b", "outside"])
        _ = model.handleSelectionClick(on: tabs["a"]!.id, in: nil, modifiers: .command)
        _ = model.handleSelectionClick(on: tabs["b"]!.id, in: nil, modifiers: .command)
        // A row of the selection gets the selection's menu, which (as for Unload Tab) has no Sleep.
        let targets = model.store.menuTargets(for: tabs["a"]!.id, in: nil)
        XCTAssertGreaterThan(targets.count, 1)
        XCTAssertTrue(targets.contains(tabs["b"]!.id))
        // A row outside it gets its own menu and its own Sleep Tab.
        XCTAssertEqual(model.store.menuTargets(for: tabs["outside"]!.id, in: nil), [tabs["outside"]!.id])
        model.sleepTabFromSidebar(tabs["outside"]!.id)
        XCTAssertEqual(engines["outside"]!.calls, ["freeze"])
        XCTAssertEqual(engines["a"]!.calls, [], "the selection is not put to sleep with it")
        XCTAssertEqual(engines["b"]!.calls, [])
    }
}

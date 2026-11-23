import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// The shell side of screen sharing (engine ABI 1.70 `display_capture`): the
/// page's sheet state, the bars' words, and the browser model's record of
/// what is shared, its sharing card and Stop.
@MainActor
final class ScreenShareShellTests: XCTestCase {
    // MARK: Capabilities

    func testScreenSharingNeedsItsMinorItsNameAndMediaCapture() {
        let all: (String) -> Bool = { _ in true }
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 69, hasFeature: all).screenSharing)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 70, hasFeature: all).screenSharing)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 70, hasFeature: { $0 != "display_capture" }).screenSharing)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 70, hasFeature: { $0 != "media_capture" }).screenSharing,
                       "without media_capture nothing would show what is shared")
        XCTAssertFalse(ChromiumCapabilities.none.screenSharing)
    }

    // MARK: The sheet

    private final class Router: ScreenShareRouting {
        var candidates: [ScreenShareCandidate] = []
        var asked: [(asker: UInt64, includeAsker: Bool)] = []
        var started: [(share: ScreenShare<UUID>, site: String)] = []
        var stopped: [UUID] = []

        func screenShareCandidates(for prompts: PagePromptCenter, asker: UInt64, includeAsker: Bool) -> [ScreenShareCandidate] {
            asked.append((asker, includeAsker))
            return candidates.filter { includeAsker || !$0.isCurrent }
        }
        func screenShareStarted(_ share: ScreenShare<UUID>, site: String, from prompts: PagePromptCenter) { started.append((share, site)) }
        func stopScreenShare(of capturer: UUID) { stopped.append(capturer) }
    }

    private let meetTab = UUID(), docsTab = UUID()

    /// The page's clock, moved by the test: Share waits half a second on it (SS-01).
    private final class Clock { var now: TimeInterval = 1000 }
    private let clock = Clock()

    /// The sheet has been still long enough for Share to answer.
    private func settle() { clock.now += PagePromptCenter.screenShareInputDelay }

    private func makePrompts(_ router: Router) -> PagePromptCenter {
        let prompts = PagePromptCenter(permissionClock: { [clock] in clock.now })
        prompts.ownerTabID = meetTab
        prompts.screenShareRouterOverride = router
        router.candidates = [
            ScreenShareCandidate(engineTabID: 7, tabID: meetTab, title: "Meet", site: "meet.example", isCurrent: true),
            ScreenShareCandidate(engineTabID: 9, tabID: docsTab, title: "Quarterly plan", site: "docs.example", isCurrent: false),
        ]
        return prompts
    }

    private let request = ScreenShareRequest(origin: "https://meet.example", wantsAudio: true, tabAudio: true, screenAudio: true)

    func testARequestOpensTheSheetWithNothingPicked() {
        let router = Router()
        let prompts = makePrompts(router)
        var replies: [ScreenShareChoice] = []
        prompts.presentScreenShare(id: 1, asker: 7, request: request) { replies.append($0); return true }

        XCTAssertTrue(prompts.screenShareSheetShown && prompts.hasPendingPrompt && prompts.permissionCovered && prompts.asksUser)
        XCTAssertEqual(router.asked.map(\.asker), [7])
        XCTAssertEqual(prompts.screenShare?.candidates.map(\.engineTabID), [7, 9])
        XCTAssertEqual(prompts.screenShareKind, .tab)
        XCTAssertNil(prompts.screenShareSelection, "nothing is picked for the person")
        XCTAssertNil(prompts.screenShareAnswer, "Share is disabled until a tab is picked")
        XCTAssertTrue(prompts.screenShareAudio, "a tab's own sound starts ticked when the page asked for sound")
        XCTAssertEqual(replies, [])
    }

    func testSharingATabAnswersOnceAndWaitsForTheOutcome() {
        let router = Router()
        let prompts = makePrompts(router)
        var replies: [ScreenShareChoice] = []
        var stops = 0
        prompts.stopScreenShareAction = { stops += 1 }
        prompts.presentScreenShare(id: 1, asker: 7, request: request) { replies.append($0); return true }
        prompts.screenShareSelection = 9
        XCTAssertEqual(prompts.screenShareAnswer, .tab(9, audio: true))

        settle()
        prompts.answerScreenShare(.tab(9, audio: true))
        prompts.answerScreenShare(.tab(9, audio: true))
        XCTAssertEqual(replies, [.tab(9, audio: true)], "one answer per request")
        XCTAssertFalse(prompts.screenShareSheetShown, "the sheet is out of the way")
        XCTAssertNotNil(prompts.screenShare, "the request is open until the engine says how it ended")
        XCTAssertNil(prompts.sharingLine, "nothing is shared before the stream is live")

        prompts.endScreenShare(id: 1, outcome: .shared(.tab, targetTab: 9, audio: true))
        XCTAssertNil(prompts.screenShare)
        XCTAssertEqual(router.started.map(\.share), [ScreenShare(kind: .tab, target: docsTab, audio: true)])
        XCTAssertEqual(router.started.map(\.site), ["meet.example"])
        XCTAssertNil(prompts.sharingLine, "still not live")

        prompts.screenShareCaptureChanged(true)
        XCTAssertEqual(prompts.sharingLine, "Sharing a tab with meet.example",
                       "the bar over the page in the call names no other tab: a screen share would show its title (N-1)")
        prompts.stopScreenShare()
        XCTAssertEqual(stops, 1)

        prompts.screenShareCaptureChanged(false)
        XCTAssertNil(prompts.sharingLine)
        XCTAssertEqual(prompts.screenShareChosen, [], "the share ended with its stream")
    }

    func testSharingThePagesOwnTabSaysThisTab() {
        let router = Router()
        let prompts = makePrompts(router)
        prompts.presentScreenShare(id: 1, asker: 7, request: ScreenShareRequest(origin: "https://meet.example", preference: .currentTab)) { _ in true }
        XCTAssertNil(prompts.screenShareSelection, "even a page that asks for its own tab gets nothing picked for the person")
        XCTAssertNil(prompts.screenShareAnswer)
        prompts.screenShareSelection = 7
        settle()
        prompts.answerScreenShare(.tab(7, audio: false))
        prompts.endScreenShare(id: 1, outcome: .shared(.tab, targetTab: 7, audio: false))
        prompts.screenShareCaptureChanged(true)
        XCTAssertEqual(prompts.sharingLine, "Sharing this tab with meet.example")
    }

    func testAWindowOrTheScreenIsHandedToTheSystemPicker() {
        let router = Router()
        let prompts = makePrompts(router)
        var replies: [ScreenShareChoice] = []
        prompts.presentScreenShare(id: 4, asker: 7, request: request) { replies.append($0); return true }
        prompts.selectScreenShareKind(.screen)
        XCTAssertFalse(prompts.screenShareAudio, "the whole Mac's sound is not ticked for the person")
        XCTAssertEqual(prompts.screenShareAnswer, .screen(audio: false))
        prompts.screenShareAudio = true
        settle()
        prompts.answerScreenShare(prompts.screenShareAnswer!)
        XCTAssertEqual(replies, [.screen(audio: true)])
        XCTAssertFalse(prompts.screenShareSheetShown, "Darni's sheet is gone while the macOS picker is open")

        // The person cancels in the macOS picker.
        prompts.endScreenShare(id: 4, outcome: .cancelled)
        XCTAssertNil(prompts.screenShare)
        XCTAssertTrue(router.started.isEmpty)
        prompts.screenShareCaptureChanged(false)
        XCTAssertNil(prompts.sharingLine)
    }

    // MARK: Share waits for a still sheet (security review SS-01)

    func testShareIsIgnoredForHalfASecondAfterTheSheetAppears() {
        let router = Router()
        let prompts = makePrompts(router)
        var replies: [ScreenShareChoice] = []
        prompts.presentScreenShare(id: 1, asker: 7, request: request) { replies.append($0); return true }
        // The page asked on a click; the sheet came up under the pointer. The kind is "screen" at once.
        prompts.selectScreenShareKind(.screen)
        clock.now += 0.2
        XCTAssertFalse(prompts.screenShareInputAllowed)
        XCTAssertFalse(prompts.screenShareInputEnabled, "the button is drawn as not taking input")
        prompts.answerScreenShare(.screen(audio: false))
        XCTAssertEqual(replies, [], "a click or Return 200 ms after the sheet changed does nothing")
        XCTAssertTrue(prompts.screenShareSheetShown, "and the sheet stays as it was")
        XCTAssertNil(prompts.answered["screen_share"])

        clock.now += 0.299
        prompts.answerScreenShare(.screen(audio: false))
        XCTAssertEqual(replies, [], "499 ms: still ignored")

        clock.now += 0.001
        XCTAssertTrue(prompts.screenShareInputAllowed)
        prompts.answerScreenShare(.screen(audio: false))
        XCTAssertEqual(replies, [.screen(audio: false)], "500 ms after the last change it answers")
    }

    func testShareWaitsFromTheSheetsAppearanceWithNothingElseChanging() {
        let router = Router()
        let prompts = makePrompts(router)
        var replies: [ScreenShareChoice] = []
        // The page prefers the screen: the sheet opens on a kind that has an answer at once.
        let prefersScreen = ScreenShareRequest(origin: "https://meet.example", preference: .screen)
        prompts.presentScreenShare(id: 1, asker: 7, request: prefersScreen) { replies.append($0); return true }
        XCTAssertEqual(prompts.screenShareAnswer, .screen(audio: false))
        prompts.answerScreenShare(.screen(audio: false))
        clock.now += 0.4
        prompts.answerScreenShare(.screen(audio: false))
        XCTAssertEqual(replies, [], "a Return typed into the page as the sheet appears opens nothing")
        clock.now += 0.1
        prompts.answerScreenShare(.screen(audio: false))
        XCTAssertEqual(replies, [.screen(audio: false)])
    }

    func testPickingAnotherRowMakesShareWaitAgain() {
        let router = Router()
        let prompts = makePrompts(router)
        var replies: [ScreenShareChoice] = []
        prompts.presentScreenShare(id: 1, asker: 7, request: request) { replies.append($0); return true }
        settle()
        XCTAssertTrue(prompts.screenShareInputAllowed, "a still sheet takes input")

        // A double click whose second half lands on a row, or ↓ then Return.
        prompts.screenShareSelection = 9
        XCTAssertFalse(prompts.screenShareInputAllowed)
        prompts.answerScreenShare(.tab(9, audio: true))
        XCTAssertEqual(replies, [], "Return right after the row was picked does nothing")

        clock.now += 0.3
        prompts.screenShareSelection = 7
        clock.now += 0.3
        prompts.answerScreenShare(.tab(7, audio: true))
        XCTAssertEqual(replies, [], "the wait starts again with each other row: 300 ms after the second one")

        prompts.screenShareSelection = 7
        clock.now += 0.2
        prompts.answerScreenShare(.tab(7, audio: true))
        XCTAssertEqual(replies, [.tab(7, audio: true)], "picking the same row again changes nothing and does not restart the wait")
    }

    func testChangingTheKindMakesShareWaitAgain() {
        let router = Router()
        let prompts = makePrompts(router)
        var replies: [ScreenShareChoice] = []
        prompts.presentScreenShare(id: 1, asker: 7, request: request) { replies.append($0); return true }
        settle()
        prompts.selectScreenShareKind(.window)
        prompts.answerScreenShare(.window(audio: false))
        XCTAssertEqual(replies, [])
        prompts.selectScreenShareKind(.window)
        settle()
        prompts.answerScreenShare(.window(audio: false))
        XCTAssertEqual(replies, [.window(audio: false)])
    }

    func testCancelNeverWaits() {
        let router = Router()
        let prompts = makePrompts(router)
        var replies: [ScreenShareChoice] = []
        prompts.presentScreenShare(id: 1, asker: 7, request: request) { replies.append($0); return true }
        prompts.answerScreenShare(.cancel)
        XCTAssertEqual(replies, [.cancel], "refusing is always possible, at once")
        XCTAssertFalse(prompts.screenShareInputAllowed, "no request, nothing to answer")
    }

    func testEveryNewRequestStartsItsOwnWait() {
        let router = Router()
        let prompts = makePrompts(router)
        var replies: [ScreenShareChoice] = []
        prompts.presentScreenShare(id: 1, asker: 7, request: request) { _ in true }
        settle()
        prompts.answerScreenShare(.cancel)
        // The page asks again at once: the time the first sheet was up does not count for the second.
        prompts.presentScreenShare(id: 2, asker: 7, request: ScreenShareRequest(origin: "https://meet.example", preference: .window)) {
            replies.append($0); return true
        }
        prompts.answerScreenShare(.window(audio: false))
        XCTAssertEqual(replies, [])
        settle()
        prompts.answerScreenShare(.window(audio: false))
        XCTAssertEqual(replies, [.window(audio: false)])
    }

    func testSoundNotOfferedForAKindIsNeverSent() {
        // Held here: the page keeps its router weakly.
        let router = Router()
        let prompts = makePrompts(router)
        prompts.presentScreenShare(id: 1, asker: 7, request: ScreenShareRequest(origin: "https://a.example", wantsAudio: true, tabAudio: true)) { _ in true }
        prompts.selectScreenShareKind(.window)
        prompts.screenShareAudio = true
        XCTAssertEqual(prompts.screenShareAnswer, .window(audio: false))
    }

    func testWithoutScreenRecordingTheSheetHasNoWindowOrScreenAnswer() {
        // Held here: the page keeps its router weakly.
        let router = Router()
        let prompts = makePrompts(router)
        let missing = ScreenShareRequest(origin: "https://a.example", screenRecording: .missing)
        prompts.presentScreenShare(id: 1, asker: 7, request: missing) { _ in true }
        prompts.selectScreenShareKind(.screen)
        XCTAssertNil(prompts.screenShareAnswer, "Darni explains and opens System Settings instead")
        prompts.selectScreenShareKind(.window)
        XCTAssertNil(prompts.screenShareAnswer)
        prompts.selectScreenShareKind(.tab)
        prompts.screenShareSelection = 9
        XCTAssertEqual(prompts.screenShareAnswer, .tab(9, audio: false), "a tab needs no permission of macOS")
    }

    func testAKindThePageExcludedCannotBeSelected() {
        // Held here: the page keeps its router weakly.
        let router = Router()
        let prompts = makePrompts(router)
        prompts.presentScreenShare(id: 1, asker: 7, request: ScreenShareRequest(origin: "https://a.example", offersScreen: false)) { _ in true }
        prompts.selectScreenShareKind(.screen)
        XCTAssertEqual(prompts.screenShareKind, .tab)
    }

    func testAPageThatExcludedItselfIsNotListed() {
        let router = Router()
        let prompts = makePrompts(router)
        prompts.presentScreenShare(id: 1, asker: 7, request: ScreenShareRequest(origin: "https://a.example", allowsCurrentTab: false)) { _ in true }
        XCTAssertEqual(router.asked.map(\.includeAsker), [false])
        XCTAssertEqual(prompts.screenShare?.candidates.map(\.engineTabID), [9])
    }

    func testCancelEndsTheRequestAtOnce() {
        // Held here: the page keeps its router weakly.
        let router = Router()
        let prompts = makePrompts(router)
        var replies: [ScreenShareChoice] = []
        prompts.presentScreenShare(id: 1, asker: 7, request: request) { replies.append($0); return true }
        prompts.answerScreenShare(.cancel)
        XCTAssertEqual(replies, [.cancel])
        XCTAssertNil(prompts.screenShare)
        XCTAssertFalse(prompts.hasPendingPrompt)
        prompts.endScreenShare(id: 1, outcome: .cancelled)
        XCTAssertEqual(prompts.answered["screen_share"], 1)
    }

    func testARefusedAnswerLeavesTheSheetAndDropsTheTab() {
        // Held here: the page keeps its router weakly.
        let router = Router()
        let prompts = makePrompts(router)
        prompts.presentScreenShare(id: 1, asker: 7, request: request) { _ in false }
        prompts.screenShareSelection = 9
        settle()
        prompts.answerScreenShare(.tab(9, audio: false))
        XCTAssertTrue(prompts.screenShareSheetShown, "the engine refused: the sheet stays")
        XCTAssertNotNil(prompts.screenShareProblem)
        XCTAssertEqual(prompts.screenShare?.candidates.map(\.engineTabID), [7], "the tab that could not be shared is gone from the list")
        XCTAssertNil(prompts.screenShareAnswer)
    }

    func testASecondRequestTakesTheSheetAndTheFirstIsCancelled() {
        // Held here: the page keeps its router weakly.
        let router = Router()
        let prompts = makePrompts(router)
        var first: [ScreenShareChoice] = [], second: [ScreenShareChoice] = []
        prompts.presentScreenShare(id: 1, asker: 7, request: request) { first.append($0); return true }
        prompts.presentScreenShare(id: 2, asker: 7, request: request) { second.append($0); return true }
        XCTAssertEqual(first, [.cancel])
        XCTAssertEqual(second, [])
        XCTAssertEqual(prompts.screenShare?.id, 2)
        prompts.endScreenShare(id: 1, outcome: .shared(.screen, targetTab: nil, audio: false))
        XCTAssertEqual(prompts.screenShare?.id, 2, "the end of another request changes nothing")
        XCTAssertEqual(prompts.screenShareChosen, [])
    }

    func testAWithdrawnRequestClosesTheSheetWithoutAReply() {
        // Held here: the page keeps its router weakly.
        let router = Router()
        let prompts = makePrompts(router)
        var replies: [ScreenShareChoice] = []
        prompts.presentScreenShare(id: 1, asker: 7, request: request) { replies.append($0); return true }
        prompts.endScreenShare(id: 1, outcome: .withdrawn)
        XCTAssertNil(prompts.screenShare)
        XCTAssertEqual(replies, [])
        XCTAssertEqual(prompts.cancelled["screen_share"], 1)
    }

    func testAClosedTabTakesItsSheetAndItsBarsWithIt() {
        // Held here: the page keeps its router weakly.
        let router = Router()
        let prompts = makePrompts(router)
        var replies: [ScreenShareChoice] = []
        prompts.presentScreenShare(id: 1, asker: 7, request: request) { replies.append($0); return true }
        prompts.screenShareCaptureChanged(true)
        prompts.sharedBy = [ScreenShareViewer(capturer: docsTab, site: "x.example")]
        prompts.withdrawAll()
        XCTAssertNil(prompts.screenShare)
        XCTAssertEqual(replies, [], "the engine retired the request itself")
        XCTAssertFalse(prompts.isSharingScreen)
        XCTAssertEqual(prompts.sharedBy, [])
    }

    func testAPageGoingAwayAnswersCancel() {
        // Held here: the page keeps its router weakly.
        let router = Router()
        let prompts = makePrompts(router)
        var replies: [ScreenShareChoice] = []
        prompts.presentScreenShare(id: 1, asker: 7, request: request) { replies.append($0); return true }
        prompts.answerAllConservatively()
        XCTAssertEqual(replies, [.cancel])
        XCTAssertNil(prompts.screenShare)
    }

    func testALiveStreamNobodyChoseStillHasABar() {
        // Held here: the page keeps its router weakly.
        let router = Router()
        let prompts = makePrompts(router)
        prompts.screenShareCaptureChanged(true)
        XCTAssertEqual(prompts.sharingLine, "Sharing your screen or a window")
    }

    func testTheBarOverASharedTabStopsTheSharersShares() {
        let router = Router()
        let prompts = makePrompts(router)
        let viewer = ScreenShareViewer(capturer: meetTab, site: "meet.example")
        prompts.stopScreenShare(of: viewer)
        XCTAssertEqual(router.stopped, [meetTab])
    }

    // MARK: The browser model

    private func makeModel() -> (BrowserViewModel, SidebarStore, Tab, Tab) {
        let store = SidebarStore(spaces: [Space(name: "Main")])
        let meet = store.addTab(kind: .today, title: "Meet", url: URL(string: "https://meet.test")!)
        let docs = store.addTab(kind: .today, title: "Plan", url: URL(string: "https://docs.test")!)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString).json")
        return (BrowserViewModel(store: store, persistence: SidebarFilePersistence(fileURL: file)), store, meet, docs)
    }

    func testASharingTabGetsACardOnlyWhenNotOnScreen() {
        let (model, store, meet, docs) = makeModel()
        let prompts = PagePromptCenter()
        prompts.ownerTabID = meet.id
        model.screenShareStarted(ScreenShare(kind: .screen), site: "meet.test", from: prompts)
        store.selectTab(docs.id)
        XCTAssertEqual(model.screenShareCards(in: nil), [], "chosen, but the stream is not live yet")

        model.screenShareCaptureChanged(meet.id, live: true)
        XCTAssertEqual(model.screenShareCards(in: nil), [meet.id])
        XCTAssertEqual(model.screenShareCardLine(for: meet.id), "Sharing your screen with meet.test")

        store.selectTab(meet.id)
        XCTAssertEqual(model.screenShareCards(in: nil), [], "the tab on screen has the bar over its page")

        store.selectTab(docs.id)
        model.screenShareCaptureChanged(meet.id, live: false)
        XCTAssertEqual(model.screenShareCards(in: nil), [])
        XCTAssertNil(model.screenShareSites[meet.id])
    }

    func testASharedTabsPageIsToldWhoSharesIt() {
        let (model, _, meet, docs) = makeModel()
        let docsEngine = model.engineHost.engine(for: docs, profileID: model.profileID(for: docs))
        let prompts = PagePromptCenter()
        prompts.ownerTabID = meet.id
        model.screenShareStarted(ScreenShare(kind: .tab, target: docs.id), site: "meet.test", from: prompts)
        XCTAssertEqual(docsEngine.pagePrompts.sharedBy, [], "not before the stream is live")

        model.screenShareCaptureChanged(meet.id, live: true)
        XCTAssertEqual(docsEngine.pagePrompts.sharedBy, [ScreenShareViewer(capturer: meet.id, site: "meet.test")])
        XCTAssertEqual(model.screenShareCardLine(for: meet.id), "Sharing “Plan” with meet.test")

        model.screenShareCaptureChanged(meet.id, live: false)
        XCTAssertEqual(docsEngine.pagePrompts.sharedBy, [], "the bar goes when the stream ends")
    }

    func testATabSharingItselfIsNotMarkedAsSharedByAnother() {
        let (model, store, meet, docs) = makeModel()
        let meetEngine = model.engineHost.engine(for: meet, profileID: model.profileID(for: meet))
        let prompts = PagePromptCenter()
        prompts.ownerTabID = meet.id
        model.screenShareStarted(ScreenShare(kind: .tab, target: meet.id), site: "meet.test", from: prompts)
        model.screenShareCaptureChanged(meet.id, live: true)
        XCTAssertEqual(meetEngine.pagePrompts.sharedBy, [], "its own bar says so already")
        store.selectTab(docs.id)
        XCTAssertEqual(model.screenShareCardLine(for: meet.id), "Sharing its own tab with meet.test")
    }

    func testClosingTheSharingTabForgetsItsShares() {
        let (model, store, meet, docs) = makeModel()
        let docsEngine = model.engineHost.engine(for: docs, profileID: model.profileID(for: docs))
        let prompts = PagePromptCenter()
        prompts.ownerTabID = meet.id
        model.screenShareStarted(ScreenShare(kind: .tab, target: docs.id), site: "meet.test", from: prompts)
        model.screenShareCaptureChanged(meet.id, live: true)
        store.selectTab(docs.id)
        model.closeTab(meet.id)
        XCTAssertTrue(model.screenShares.isEmpty)
        XCTAssertEqual(model.screenShareCards(in: nil), [])
        XCTAssertEqual(docsEngine.pagePrompts.sharedBy, [])
    }

    func testAPageThatIsNoSidebarTabIsNotRecordedInTheModel() {
        let (model, _, _, _) = makeModel()
        let peek = PagePromptCenter()
        model.screenShareStarted(ScreenShare(kind: .screen), site: "a.test", from: peek)
        XCTAssertEqual(model.screenShares, ScreenShareLedger<Tab.ID>(), "its own page still has its bar, from the engine's capture state")
    }

    func testTheSheetOffersTheAskingTabFirstAndAPrivatePageOnlyItself() {
        let (model, _, meet, _) = makeModel()
        let prompts = PagePromptCenter()
        prompts.ownerTabID = meet.id
        prompts.profileID = model.profileID(for: meet)
        let offered = model.screenShareCandidates(for: prompts, asker: 7, includeAsker: true)
        XCTAssertEqual(offered.map(\.engineTabID), [7], "a tab without a running Chromium page is not offered")
        XCTAssertEqual(offered.first?.title, "Meet")
        XCTAssertEqual(offered.first?.tabID, meet.id)
        XCTAssertTrue(offered.first?.isCurrent == true)
        XCTAssertEqual(model.screenShareCandidates(for: prompts, asker: 7, includeAsker: false), [])

        let privatePage = PagePromptCenter()
        privatePage.privateSession = UUID()
        let own = model.screenShareCandidates(for: privatePage, asker: 3, includeAsker: true)
        XCTAssertEqual(own.map(\.engineTabID), [3])
        XCTAssertEqual(own.first?.title, "This Page")
        XCTAssertNil(own.first?.tabID)
    }
}

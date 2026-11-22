import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Security RC-2026.1122.1231, the two low findings left after the focus gate.
///
/// FX-01: the blank-tab cap counted only tabs without an address, so a client
/// retrying `tabs.create({url})` could still fill the sidebar. Every tab and
/// window an extension asks for now counts towards `ExtensionTabRate`.
///
/// FX-02: `windows.create` opened a Little Darni window in front of everything
/// without asking the focus gate. It is still made, but comes to the front
/// only when the user started it, and the loop breaker counts it.
///
/// The owner's decision of 2026-11-22: a window opened behind is said in a
/// notice that stays in every browser window until it is answered, and the
/// Dock icon bounces once when Darni is not the active app (the Claude
/// extension asks for sign-in and permission in such windows).
///
/// The Chromium host is not compiled here (it needs the engine), so `Host`
/// makes the host's calls in the host's order, as in `ExtensionSpacePingPongTests`.
@MainActor
final class ExtensionTabFloodTests: XCTestCase {
    private static let extensionID = "fcoeoabgfenejglbffodgkkbkcdhcgfn"
    private var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// What the shell was asked to do with Little Darni windows.
    private final class Presenter: BrowserWindowPresenting {
        struct Shown: Equatable {
            var id: LittleArcWindow.ID
            var inFront: Bool
        }
        var shown: [Shown] = []
        func presentLittleArcWindow(_ id: LittleArcWindow.ID, inFront: Bool) { shown.append(Shown(id: id, inFront: inFront)) }
        func dismissLittleArcWindow(_ id: LittleArcWindow.ID) {}
        func presentPrivateWindow(_ window: PrivateWindowModel) {}
    }

    private func makeModel() -> (BrowserViewModel, Presenter) {
        let store = SidebarStore(spaces: [Space(name: "Personal", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-flood-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-flood-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-flood-links-\(UUID().uuidString)")!
        let presenter = Presenter()
        model.windowPresenter = presenter
        // Darni is the active app unless a test says otherwise, and no test reaches the real Dock.
        model.appIsActive = { true }
        model.requestDockAttention = {}
        return (model, presenter)
    }

    /// The host's side of an extension's calls (`ChromiumExtensionHost.handleTabRequest`).
    @MainActor
    private final class Host {
        let model: BrowserViewModel
        var clock: () -> Date
        private var nextRequest: UInt64 = 1

        init(model: BrowserViewModel, clock: @escaping () -> Date) {
            self.model = model
            self.clock = clock
        }

        /// `chrome.tabs.create({url, active: false})`: the tab, or nil when the extension's Promise fails.
        func tabsCreate(by extensionID: String, in profile: Profile.ID, url: String) -> Tab.ID? {
            let store = model.store
            let request = ExtensionTabRequest(id: nextRequest, profileID: 1, kind: .createTab, active: false, url: url, extensionID: extensionID)
            nextRequest += 1
            let shown = store.activeSpaceID
            let placement = ExtensionTabPlacement.resolve(
                request, currentSpace: shown, windowSpace: nil,
                spaces: [shown] + store.visibleSpaces.map(\.id).filter { $0 != shown }
            ) { store.space(withID: $0)?.profileID == profile }
            guard case .newTab(let space) = placement, model.extensionTabRefusal(for: request, in: space, at: clock()) == nil else { return nil }
            // `adoptBlankTab`, then the engine loads the extension's address in it.
            let tab = store.addTab(kind: .today, title: "New Tab", url: URL(string: "about:blank")!, in: space)
            model.noteExtensionOpenedTab(tab.id, for: request, in: space)
            store.updateTab(tab.id, title: "Pair", url: URL(string: url)!)
            return tab.id
        }

        /// `chrome.windows.create({url})`: the Little Darni window, or nil when the extension's Promise fails.
        func windowsCreate(by extensionID: String, in profile: Profile.ID) -> LittleArcWindow? {
            let request = ExtensionTabRequest(id: nextRequest, profileID: 1, kind: .createWindow, url: "https://example.com/prompt",
                                              extensionID: extensionID)
            nextRequest += 1
            guard model.extensionWindowRefusal(for: request, profile: profile, at: clock()) == nil else { return nil }
            // `adoptChromiumLittleArc(madeByExtension:)`.
            let record = model.store.createLittleArcWindow(url: URL(string: "about:blank")!, profileID: profile)
            model.presentExtensionLittleArc(record, by: extensionID, at: clock())
            return record
        }
    }

    private func name(_ model: BrowserViewModel, _ name: String, for extensionID: String? = nil) {
        // As the toolbar learns it: a tab showed the extension's action.
        let id = extensionID ?? Self.extensionID
        let shown = (model.extensions.actionsByEngine[ObjectIdentifier(nameEngine)] ?? []).filter { $0.id != id }
        model.extensions.setActions(shown + [ExtensionActionItem(id: id, name: name)], for: nameEngine)
    }

    /// Stands for the tab whose toolbar showed the actions.
    private final class NameEngine {}
    private let nameEngine = NameEngine()

    // MARK: FX-01, the rate cap

    func testAClientRetryingTabsCreateWithAnAddressFillsNothing() throws {
        let (model, _) = makeModel()
        let store = model.store
        let host = Host(model: model) { [unowned self] in self.clock }
        name(model, "Claude")
        let before = store.displayTabs(in: store.activeSpaceID).count

        // The flood of 2026-11-22 with an address in the call: 628 requests in 142 s.
        var opened = 0
        for _ in 0..<628 {
            clock.addTimeInterval(142.0 / 628)
            if host.tabsCreate(by: Self.extensionID, in: store.activeProfileID, url: "https://example.com/pair") != nil { opened += 1 }
        }
        XCTAssertEqual(opened, ExtensionTabRate.limit)
        XCTAssertEqual(store.displayTabs(in: store.activeSpaceID).count - before, ExtensionTabRate.limit, "618 requests failed, as in Chrome with no window")
        XCTAssertEqual(model.extensionTabRateLog.count, 1, "logged once for the whole flood")
        XCTAssertEqual(model.extensionTabRateLog.first?.contains(Self.extensionID), true)
        XCTAssertEqual(model.toast?.message, "Claude tried to open many tabs; Darni stopped it")
    }

    func testAFewTabsAtTheUsersClickPassAndTheCapComesBack() throws {
        let (model, _) = makeModel()
        let store = model.store
        let host = Host(model: model) { [unowned self] in self.clock }
        name(model, "Opener")
        func burst(_ count: Int) -> Int {
            (0..<count).filter { _ in host.tabsCreate(by: Self.extensionID, in: store.activeProfileID, url: "https://example.com/") != nil }.count
        }
        XCTAssertEqual(burst(ExtensionTabRate.limit), ExtensionTabRate.limit, "a full burst under the cap opens")
        XCTAssertNil(model.toast, "and nothing is said")
        XCTAssertEqual(burst(3), 0)
        let first = try XCTUnwrap(model.toast)
        XCTAssertEqual(first.message, "Opener tried to open many tabs; Darni stopped it")
        XCTAssertEqual(burst(5), 0)
        XCTAssertEqual(model.toast?.id, first.id, "one toast for the burst, however long it goes on")
        XCTAssertEqual(model.extensionTabRateLog.count, 1)

        // Another extension, and this one's copy in another profile, are not held back by it.
        XCTAssertNotNil(host.tabsCreate(by: "another", in: store.activeProfileID, url: "https://example.com/"))
        let work = store.addProfile(name: "Work")
        XCTAssertNotNil(host.tabsCreate(by: Self.extensionID, in: work.id, url: "https://example.com/"))

        // Once the burst is older than the window it opens tabs again; over the cap again, it is said again.
        clock.addTimeInterval(ExtensionTabRate.window + 1)
        XCTAssertEqual(burst(ExtensionTabRate.limit + 1), ExtensionTabRate.limit)
        XCTAssertNotEqual(model.toast?.id, first.id)
        XCTAssertEqual(model.extensionTabRateLog.count, 2)
    }

    func testTheToastNamesTheExtensionInOneClippedLine() {
        let (model, _) = makeModel()
        XCTAssertEqual(model.extensionToastName("unknown"), "An extension", "no tab has shown its action yet")
        name(model, "  Tab\nOpener  ", for: "a")
        XCTAssertEqual(model.extensionToastName("a"), "Tab Opener")
        // The extension chose its name: it cannot fill the toast with a message of its own.
        name(model, "Darni needs your password. Type it in the page that opens next", for: "b")
        XCTAssertEqual(model.extensionToastName("b"), "Darni needs your password. Type…")
    }

    func testTheBlankCapStillHoldsUnderTheRateCap() {
        let (model, _) = makeModel()
        let store = model.store
        var opened = 0
        // One blank tab every 2 s: never over the rate cap, and never used.
        for index in 0..<20 {
            clock.addTimeInterval(2)
            let request = ExtensionTabRequest(id: UInt64(index + 1), profileID: 1, kind: .createTab, active: false, extensionID: Self.extensionID)
            guard model.extensionTabRefusal(for: request, in: store.activeSpaceID, at: clock) == nil else { continue }
            let tab = store.addTab(kind: .today, title: "New Tab", url: URL(string: "about:blank")!, in: store.activeSpaceID)
            model.noteExtensionOpenedTab(tab.id, for: request, in: store.activeSpaceID)
            opened += 1
        }
        XCTAssertEqual(opened, ExtensionBlankTabs.limit)
        XCTAssertEqual(model.extensionTabRateLog, [], "the rate cap had nothing to stop")
    }

    // MARK: FX-02, windows.create

    func testAWindowAnExtensionMakesByItselfOpensBehindAndTakesNothing() throws {
        let (model, presenter) = makeModel()
        let store = model.store
        let host = Host(model: model) { [unowned self] in self.clock }
        name(model, "Claude")
        let shownSpace = store.activeSpaceID

        // Nobody at the keyboard: a permission question, or a client's retry.
        let record = try XCTUnwrap(host.windowsCreate(by: Self.extensionID, in: store.activeProfileID))
        XCTAssertEqual(presenter.shown, [.init(id: record.id, inFront: false)], "made, but not in front and not key")
        XCTAssertNil(model.keyLittleArcID)
        XCTAssertEqual(store.activeSpaceID, shownSpace)
        XCTAssertNotNil(store.littleArcWindow(withID: record.id), "the window exists: the extension's call succeeded")

        // The user is told, and Show is their own click.
        let notice = try XCTUnwrap(model.extensionWindowNotice)
        XCTAssertEqual(notice.message, "Claude opened a window behind this one")
        XCTAssertEqual(notice.toast.action, .show)
        XCTAssertNil(model.toast, "the notice has its own place: no toast is used up, and none can replace it")
        model.showExtensionWindowsBehind()
        XCTAssertEqual(presenter.shown.last, .init(id: record.id, inFront: true))
    }

    func testAWindowTheUserAskedForComesToTheFrontOncePerInput() throws {
        let (model, presenter) = makeModel()
        let store = model.store
        let host = Host(model: model) { [unowned self] in self.clock }

        // The user clicks the extension's button; it opens its window.
        model.noteUserInput(at: clock)
        clock.addTimeInterval(0.2)
        let asked = try XCTUnwrap(host.windowsCreate(by: Self.extensionID, in: store.activeProfileID))
        XCTAssertEqual(presenter.shown, [.init(id: asked.id, inFront: true)])
        XCTAssertNil(model.toast, "nothing to say about a window the user asked for")
        XCTAssertNil(model.extensionWindowNotice)

        // The click is spent: a second window by itself stays behind.
        clock.addTimeInterval(0.2)
        let second = try XCTUnwrap(host.windowsCreate(by: Self.extensionID, in: store.activeProfileID))
        XCTAssertEqual(presenter.shown.last, .init(id: second.id, inFront: false))

        // An input older than the gate's window started nothing.
        model.noteUserInput(at: clock)
        clock.addTimeInterval(ExtensionFocusGate.userInputWindow + 0.5)
        let late = try XCTUnwrap(host.windowsCreate(by: Self.extensionID, in: store.activeProfileID))
        XCTAssertEqual(presenter.shown.last, .init(id: late.id, inFront: false))
    }

    func testAWindowOfAProfileNotOnScreenStaysBehindWhateverTheUserDid() throws {
        let (model, presenter) = makeModel()
        let store = model.store
        let host = Host(model: model) { [unowned self] in self.clock }
        let work = store.addProfile(name: "Work")
        model.noteUserInput(at: clock)
        let record = try XCTUnwrap(host.windowsCreate(by: Self.extensionID, in: work.id))
        XCTAssertEqual(presenter.shown, [.init(id: record.id, inFront: false)], "a click in this profile is not a click for that one")
        XCTAssertEqual(model.extensionWindowNotice?.message, "An extension opened a window behind this one")
    }

    func testTheLoopBreakerCountsLittleDarniWindows() throws {
        let (model, presenter) = makeModel()
        let store = model.store
        let host = Host(model: model) { [unowned self] in self.clock }
        // The user keeps clicking; the extension answers each click with a window in front.
        for _ in 0..<6 {
            clock.addTimeInterval(1)
            model.noteUserInput(at: clock)
            _ = try XCTUnwrap(host.windowsCreate(by: Self.extensionID, in: store.activeProfileID))
        }
        XCTAssertEqual(presenter.shown.map(\.inFront), [true, true, true, true, false, false],
                       "one window out and \(ExtensionFocusGate.loopReturns) more, then the loop breaker holds")
        XCTAssertEqual(model.extensionFocusLog.count, 1, "logged once")
        XCTAssertEqual(model.extensionFocusLog.first?.contains("loop breaker"), true)

        // While it holds, an extension the user clicked does not switch the space either.
        let other = store.addSpace(name: "Other")
        store.selectSpace(store.visibleSpaces[0].id)
        let tab = store.addTab(kind: .today, title: "There", url: URL(string: "about:blank")!, in: other.id)
        _ = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        model.noteUserInput(at: clock)
        XCTAssertEqual(model.extensionActivatedTab(tab.id, at: clock.addingTimeInterval(0.1)), .inItsSpace(.loop))
    }

    func testTheLoopBreakersTripIsSaidInAToastAndTheNoticeCountsItsWindow() throws {
        let (model, _) = makeModel()
        let host = Host(model: model) { [unowned self] in self.clock }
        var last: LittleArcWindow?
        for _ in 0..<5 {
            clock.addTimeInterval(1)
            model.noteUserInput(at: clock)
            last = host.windowsCreate(by: Self.extensionID, in: model.store.activeProfileID)
        }
        XCTAssertEqual(model.toast?.message, "Stopped extensions bringing windows to the front")
        // The window that tripped it is behind like any other: it is not lost for the toast's sake.
        XCTAssertEqual(model.extensionWindowNotice?.windows, [try XCTUnwrap(last).id])
    }

    func testWindowsCountTowardsTheRateCapWithTabs() throws {
        let (model, presenter) = makeModel()
        let store = model.store
        let host = Host(model: model) { [unowned self] in self.clock }
        name(model, "Claude")
        // A client retrying windows.create: the first few are made, behind; the rest fail.
        var made = 0
        for _ in 0..<40 {
            clock.addTimeInterval(0.25)
            if host.windowsCreate(by: Self.extensionID, in: store.activeProfileID) != nil { made += 1 }
        }
        XCTAssertEqual(made, ExtensionTabRate.limit)
        XCTAssertEqual(store.littleArcLiveWindows.count, ExtensionTabRate.limit)
        XCTAssertFalse(presenter.shown.contains { $0.inFront }, "and none of them came to the front")
        XCTAssertEqual(model.toast?.message, "Claude tried to open many tabs; Darni stopped it")
        // One count for both: no tab either while it lasts.
        XCTAssertNil(host.tabsCreate(by: Self.extensionID, in: store.activeProfileID, url: "https://example.com/"))

        // A window uses up one of the burst's tabs.
        clock.addTimeInterval(ExtensionTabRate.window + 1)
        _ = try XCTUnwrap(host.windowsCreate(by: Self.extensionID, in: store.activeProfileID))
        let tabs = (0..<ExtensionTabRate.limit).filter { _ in
            host.tabsCreate(by: Self.extensionID, in: store.activeProfileID, url: "https://example.com/") != nil
        }.count
        XCTAssertEqual(tabs, ExtensionTabRate.limit - 1)
    }

    // MARK: The notice of windows opened behind

    func testTheNoticeStaysPastTheTimeAToastWouldHaveGone() throws {
        let (model, _) = makeModel()
        let host = Host(model: model) { [unowned self] in self.clock }
        name(model, "Claude")
        let record = try XCTUnwrap(host.windowsCreate(by: Self.extensionID, in: model.store.activeProfileID))

        // The toast it replaced went after 8 s. The main queue runs meanwhile, as a toast's timer needs.
        let waited = expectation(description: "longer than the old toast stayed")
        DispatchQueue.main.asyncAfter(deadline: .now() + ShellToast.defaultDuration + 3 + 0.4) { waited.fulfill() }
        wait(for: [waited], timeout: 15)
        XCTAssertEqual(model.extensionWindowNotice?.windows, [record.id], "still up: only the user's answer takes it away")
        XCTAssertEqual(model.extensionWindowNotice?.message, "Claude opened a window behind this one")
    }

    func testAToastDoesNotTakeTheNoticesPlace() throws {
        let (model, _) = makeModel()
        let host = Host(model: model) { [unowned self] in self.clock }
        let record = try XCTUnwrap(host.windowsCreate(by: Self.extensionID, in: model.store.activeProfileID))
        // The single toast slot gave the old one to whatever was said next.
        model.showToast("Copied Current URL", systemImage: "link")
        XCTAssertEqual(model.toast?.message, "Copied Current URL")
        XCTAssertEqual(model.extensionWindowNotice?.windows, [record.id])
    }

    func testTheNoticeIsInEveryBrowserWindowAndAnsweredInAllAtOnce() throws {
        let (model, _) = makeModel()
        let store = model.store
        let host = Host(model: model) { [unowned self] in self.clock }
        let key = SidebarWindowID(), other = SidebarWindowID(), third = SidebarWindowID()
        for window in [key, other, third] { store.registerWindow(window) }
        store.windowBecameKey(key)
        func shown() -> [ExtensionWindowNotice?] { [key, other, third].map { model.extensionWindowNotice(in: $0) } }

        let record = try XCTUnwrap(host.windowsCreate(by: Self.extensionID, in: store.activeProfileID))
        XCTAssertFalse(model.isKeyBrowserWindow(other), "a toast would not show here")
        XCTAssertEqual(shown().map { $0?.windows }, [[record.id], [record.id], [record.id]], "seen whichever window is in front")

        // Dismissed in one window: gone from every one, and the window stays behind.
        model.dismissExtensionWindowNotice()
        XCTAssertEqual(shown(), [nil, nil, nil])
        XCTAssertNotNil(store.littleArcWindow(withID: record.id))

        // Show in one window: gone from every one too.
        let again = try XCTUnwrap(host.windowsCreate(by: Self.extensionID, in: store.activeProfileID))
        XCTAssertEqual(shown().map { $0?.windows }, [[again.id], [again.id], [again.id]], "a dismissed window is not counted again")
        model.showExtensionWindowsBehind()
        XCTAssertEqual(shown(), [nil, nil, nil])
    }

    func testSeveralWindowsAreOneNoticeWithTheirCount() throws {
        let (model, _) = makeModel()
        let store = model.store
        let host = Host(model: model) { [unowned self] in self.clock }
        name(model, "Claude")
        var records: [LittleArcWindow] = []
        for expected in ["Claude opened a window behind this one", "Claude opened 2 windows behind this one",
                         "Claude opened 3 windows behind this one"] {
            clock.addTimeInterval(1)
            records.append(try XCTUnwrap(host.windowsCreate(by: Self.extensionID, in: store.activeProfileID)))
            XCTAssertEqual(model.extensionWindowNotice?.message, expected)
        }
        XCTAssertEqual(model.extensionWindowNotice?.windows, records.map(\.id), "oldest first")

        // Another extension's window joins the same notice; it names neither.
        name(model, "Wallet", for: "another")
        let fourth = try XCTUnwrap(host.windowsCreate(by: "another", in: store.activeProfileID))
        XCTAssertEqual(model.extensionWindowNotice?.message, "Extensions opened 4 windows behind this one")
        XCTAssertEqual(model.extensionWindowNotice?.windows, (records + [fourth]).map(\.id))
    }

    func testShowBringsEveryCountedWindowForwardTheMostRecentLast() throws {
        let (model, presenter) = makeModel()
        let store = model.store
        let host = Host(model: model) { [unowned self] in self.clock }
        let first = try XCTUnwrap(host.windowsCreate(by: Self.extensionID, in: store.activeProfileID))
        let closed = try XCTUnwrap(host.windowsCreate(by: Self.extensionID, in: store.activeProfileID))
        let last = try XCTUnwrap(host.windowsCreate(by: Self.extensionID, in: store.activeProfileID))
        XCTAssertFalse(presenter.shown.contains { $0.inFront }, "all three opened behind")
        model.closeLittleArcWindow(closed.id)
        presenter.shown = []

        model.showExtensionWindowsBehind()
        XCTAssertEqual(presenter.shown, [.init(id: first.id, inFront: true), .init(id: last.id, inFront: true)],
                       "in front and key, the most recent last so it ends on top; a closed one is not asked for")
        XCTAssertNil(model.extensionWindowNotice)

        // Show again has nothing left to bring forward.
        presenter.shown = []
        model.showExtensionWindowsBehind()
        XCTAssertEqual(presenter.shown, [])
    }

    func testTheNoticeGoesWhenItsWindowClosesOrComesForwardAnotherWay() throws {
        let (model, _) = makeModel()
        let store = model.store
        let host = Host(model: model) { [unowned self] in self.clock }
        name(model, "Claude")
        func open() throws -> LittleArcWindow { try XCTUnwrap(host.windowsCreate(by: Self.extensionID, in: store.activeProfileID)) }

        // Closed, by the user's close button or the extension's windows.remove.
        let closed = try open(), kept = try open()
        model.closeLittleArcWindow(closed.id)
        XCTAssertEqual(model.extensionWindowNotice?.windows, [kept.id])
        XCTAssertEqual(model.extensionWindowNotice?.message, "Claude opened a window behind this one", "the count follows")
        model.closeLittleArcWindow(kept.id)
        XCTAssertNil(model.extensionWindowNotice, "nothing is behind any more")

        // Archived by the store itself, with no word to the model (the idle auto-archive).
        let idle = try open()
        XCTAssertNotNil(model.extensionWindowNotice)
        store.archiveLittleArcWindow(id: idle.id, reason: .auto)
        XCTAssertNil(model.extensionWindowNotice)

        // Opened as a tab in a space: its window is gone too.
        let promoted = try open()
        model.promoteLittleArcWindow(promoted.id)
        XCTAssertNil(model.extensionWindowNotice)

        // Brought forward another way: the user clicked it, or chose it in the Window menu, and it took the keyboard.
        let clicked = try open(), behind = try open()
        model.keyLittleArcID = clicked.id
        XCTAssertEqual(model.extensionWindowNotice?.windows, [behind.id])
        model.keyLittleArcID = behind.id
        XCTAssertNil(model.extensionWindowNotice)
        // And it does not come back when that window loses the keyboard again.
        model.keyLittleArcID = nil
        XCTAssertNil(model.extensionWindowNotice)
    }

    func testTheDockIconBouncesOnlyWhenDarniIsNotTheActiveApp() throws {
        let (model, _) = makeModel()
        let store = model.store
        let host = Host(model: model) { [unowned self] in self.clock }
        var active = true, bounces = 0
        model.appIsActive = { active }
        model.requestDockAttention = { bounces += 1 }
        func open() throws -> LittleArcWindow { try XCTUnwrap(host.windowsCreate(by: Self.extensionID, in: store.activeProfileID)) }

        // Darni is in front: the notice is on screen, and the Dock is left alone.
        _ = try open()
        XCTAssertNotNil(model.extensionWindowNotice)
        XCTAssertEqual(bounces, 0)

        // The user works in another app: the next window behind bounces the icon, once.
        active = false
        _ = try open()
        XCTAssertEqual(bounces, 1)
        // More windows while they are away are the same notice: no bounce for each.
        _ = try open()
        _ = try open()
        XCTAssertEqual(bounces, 1)

        // They came back and used Darni, then left: a later window is news again.
        active = true
        model.noteUserInput(at: clock)
        clock.addTimeInterval(ExtensionFocusGate.userInputWindow + 1)
        active = false
        _ = try open()
        XCTAssertEqual(bounces, 2)

        // A window the user's own input brought to the front needs no attention at all.
        model.dismissExtensionWindowNotice()
        active = true
        model.noteUserInput(at: clock)
        active = false
        let asked = try open()
        XCTAssertNil(model.extensionWindowNotice, "it came to the front: \(asked.id)")
        XCTAssertEqual(bounces, 2)

        // After the notice was answered, the next one bounces again.
        clock.addTimeInterval(ExtensionFocusGate.userInputWindow + 1)
        _ = try open()
        model.dismissExtensionWindowNotice()
        _ = try open()
        XCTAssertEqual(bounces, 4)
    }

    // MARK: How the window comes on screen

    /// A window that records what it is asked instead of doing it: nothing appears on screen.
    private final class RecordingWindow: NSWindow {
        var calls: [String] = []
        var onScreen = false
        var number = 0
        override var isVisible: Bool { onScreen }
        override var windowNumber: Int { number }
        override func makeKeyAndOrderFront(_ sender: Any?) { calls.append("makeKeyAndOrderFront") }
        override func makeKey() { calls.append("makeKey") }
        override func makeMain() { calls.append("makeMain") }
        override func orderFront(_ sender: Any?) { calls.append("orderFront") }
        override func orderFrontRegardless() { calls.append("orderFrontRegardless") }
        override func orderBack(_ sender: Any?) { calls.append("orderBack") }
        override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
            calls.append("order \(place == .below ? "below" : place == .above ? "above" : "out") \(otherWin)")
        }
    }

    private func window(number: Int = 0, onScreen: Bool = false) -> RecordingWindow {
        let window = RecordingWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 300, height: 200), styleMask: [.titled],
                                     backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.number = number
        window.onScreen = onScreen
        return window
    }

    func testABackgroundLittleDarniGoesBehindTheFrontWindowAndIsNeverMadeKey() {
        let front = window(number: 41, onScreen: true)
        let little = window()
        LittleArcWindowOrdering.show(little, inFront: false, behind: front)
        XCTAssertEqual(little.calls, ["order below 41"], "on screen under the window in front; not key, not main, not ordered front")
        XCTAssertEqual(front.calls, [], "the window in front is left alone")

        // No window to go behind: at the back, still without the keyboard.
        let alone = window()
        LittleArcWindowOrdering.show(alone, inFront: false, behind: nil)
        XCTAssertEqual(alone.calls, ["orderBack"])
        let hidden = window()
        LittleArcWindowOrdering.show(hidden, inFront: false, behind: window(number: 7, onScreen: false))
        XCTAssertEqual(hidden.calls, ["orderBack"], "a window that is not on screen is nothing to go behind")

        // One that is on screen already stays where it is.
        let open = window(onScreen: true)
        LittleArcWindowOrdering.show(open, inFront: false, behind: front)
        XCTAssertEqual(open.calls, [])
    }

    func testALittleDarniTheUserAskedForIsKeyAndInFront() {
        let front = window(number: 41, onScreen: true)
        let little = window()
        LittleArcWindowOrdering.show(little, inFront: true, behind: front)
        XCTAssertEqual(little.calls, ["makeKeyAndOrderFront"])
        let open = window(onScreen: true)
        LittleArcWindowOrdering.show(open, inFront: true, behind: front)
        XCTAssertEqual(open.calls, ["makeKeyAndOrderFront"], "an open one comes forward again")
    }

    func testTheWindowABackgroundOneGoesBehindIsTheFrontmostOrdinaryOne() {
        let little = window(number: 1)
        let popup = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        let minimised = window(number: 2, onScreen: false)
        let browser = window(number: 3, onScreen: true)
        let older = window(number: 4, onScreen: true)
        XCTAssertTrue(LittleArcWindowOrdering.frontWindow(among: [little, popup, minimised, browser, older], except: little) === browser)
        XCTAssertNil(LittleArcWindowOrdering.frontWindow(among: [little, popup, minimised], except: little))
    }
}

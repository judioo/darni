import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Owner's report 2026-11-22: with the Claude extension in two profiles, one
/// Darni window switched by itself between those profiles' spaces about every
/// 0.35 s for as long as it ran, and two "New Tab" rows were left behind at
/// each switch (628 in 142 s).
///
/// To extensions a space is a window and only the space on screen is focused,
/// so the copy in the profile that is not on screen sees no focused window. It
/// opens a blank tab and makes it active to bring it forward; Darni showed
/// that tab's space; now the other copy saw no focused window. The tests
/// replay that with two such copies. The Chromium host is not compiled here
/// (it needs the engine), so `Host` makes the host's calls in the host's order:
/// the model's placement, `extensionTabRefusal`, `noteExtensionOpenedTab` and
/// `extensionActivatedTab` are the real ones.
@MainActor
final class ExtensionSpacePingPongTests: XCTestCase {
    private static let extensionID = "fcoeoabgfenejglbffodgkkbkcdhcgfn"
    private let blank = URL(string: "about:blank")!

    private var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Personal", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-pingpong-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-pingpong-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-pingpong-links-\(UUID().uuidString)")!
        return model
    }

    /// The host's side of an extension's calls.
    @MainActor
    private final class Host {
        let model: BrowserViewModel
        var clock: () -> Date
        private(set) var declined = 0
        private var nextRequest: UInt64 = 1

        init(model: BrowserViewModel, clock: @escaping () -> Date) {
            self.model = model
            self.clock = clock
        }

        /// `chrome.tabs.create`: the tab, or nil when the extension's Promise fails.
        func tabsCreate(by extensionID: String, in profile: Profile.ID, url: String = "about:blank", active: Bool = true,
                        window: Space.ID? = nil) -> Tab.ID? {
            let store = model.store
            let request = ExtensionTabRequest(id: nextRequest, profileID: 1, windowID: window == nil ? 0 : 1, kind: .createTab,
                                              active: active, url: url, extensionID: extensionID)
            nextRequest += 1
            let shown = store.activeSpaceID
            let placement = ExtensionTabPlacement.resolve(
                request, currentSpace: shown, windowSpace: window,
                spaces: [shown] + store.visibleSpaces.map(\.id).filter { $0 != shown }
            ) { store.space(withID: $0)?.profileID == profile }
            guard case .newTab(let space) = placement, model.extensionTabRefusal(for: request, in: space) == nil else {
                declined += 1
                return nil
            }
            // `adoptBlankTab`: a blank today tab with an open page.
            let tab = store.addTab(kind: .today, title: "New Tab", url: URL(string: "about:blank")!, in: space)
            _ = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
            model.noteExtensionOpenedTab(tab.id, for: request, in: space)
            if request.active, model.extensionActivatedTab(tab.id, newlyOpened: true, at: clock()) == .unavailable {
                declined += 1
                return nil
            }
            return tab.id
        }

        /// `chrome.tabs.update(tab, {active: true})`.
        @discardableResult
        func tabsUpdateActive(_ tab: Tab.ID) -> BrowserViewModel.ExtensionTabShowing {
            model.extensionActivatedTab(tab, at: clock())
        }
    }

    /// One profile's copy of an extension that wants its tab in front: when
    /// no window of its profile is focused it opens a blank tab in its
    /// window and makes it the active one, as the Claude extension does for a
    /// tab its client asked for.
    @MainActor
    private struct Copy {
        var profile: Profile.ID
        var space: Space.ID

        /// What the engine reports to this copy: the space on screen is the
        /// focused window, and a copy sees only its own profile's windows.
        func seesAFocusedWindow(_ store: SidebarStore) -> Bool {
            store.space(withID: store.activeSpaceID)?.profileID == profile
        }

        func turn(_ host: Host) {
            guard !seesAFocusedWindow(host.model.store) else { return }
            guard let tab = host.tabsCreate(by: ExtensionSpacePingPongTests.extensionID, in: profile, active: false, window: space) else { return }
            host.tabsUpdateActive(tab)
        }
    }

    private func blankRows(_ store: SidebarStore, in space: Space.ID) -> Int {
        store.displayTabs(in: space).filter { $0.title == "New Tab" && $0.url.absoluteString == "about:blank" }.count
    }

    // MARK: The ping-pong

    func testTwoProfilesCopiesOfOneExtensionDoNotPassTheWindowBetweenThem() throws {
        let model = makeModel()
        let store = model.store
        let personal = store.activeSpace
        let workProfile = store.addProfile(name: "Work")
        let work = try XCTUnwrap(store.spaces(in: workProfile.id).first)
        let host = Host(model: model) { [unowned self] in self.clock }
        let copies = [Copy(profile: personal.profileID, space: personal.id), Copy(profile: workProfile.id, space: work.id)]

        // The user is in the work profile; nobody touches Darni while the copies run.
        store.selectSpace(work.id)
        var switches = 0
        var shown = store.activeSpaceID
        for _ in 0..<20 {
            for copy in copies {
                clock.addTimeInterval(0.35)
                copy.turn(host)
                if store.activeSpaceID != shown {
                    switches += 1
                    shown = store.activeSpaceID
                }
            }
        }

        XCTAssertEqual(switches, 0, "the space on screen changed \(switches) times with nobody at the keyboard")
        XCTAssertEqual(store.activeSpaceID, work.id)
        XCTAssertEqual(model.extensionFocusLog, [], "the rule held: the loop breaker had nothing to stop")
        // The copy that is not on screen still has its tab as its own window's active tab.
        let selected = try XCTUnwrap(store.selectedTab(inSpace: personal.id))
        XCTAssertEqual(selected.title, "New Tab")
        // And no pile of blank rows: after the limit its requests fail, as in Chrome with no window to open in.
        XCTAssertEqual(blankRows(store, in: personal.id), ExtensionBlankTabs.limit)
        XCTAssertEqual(blankRows(store, in: work.id), 0, "the copy on screen saw its window focused and asked for nothing")
        XCTAssertEqual(host.declined, 20 - ExtensionBlankTabs.limit)
    }

    func testAnActiveNewTabOfAProfileNotOnScreenOpensInItsOwnSpaceOnly() throws {
        let model = makeModel()
        let store = model.store
        let personal = store.activeSpace
        let workProfile = store.addProfile(name: "Work")
        let work = try XCTUnwrap(store.spaces(in: workProfile.id).first)
        let host = Host(model: model) { [unowned self] in self.clock }
        let mine = store.addTab(kind: .today, title: "Mine", url: blank, in: personal.id)
        model.selectTab(mine.id)
        model.noteUserInput(at: clock)

        // The pairing page: `chrome.tabs.create({url})`, active by default, from the profile that is not on screen.
        clock.addTimeInterval(0.2)
        let pairing = try XCTUnwrap(host.tabsCreate(by: Self.extensionID, in: workProfile.id,
                                                    url: "chrome-extension://\(Self.extensionID)/pairing.html"))
        XCTAssertEqual(store.activeSpaceID, personal.id, "a click in this profile is not a click for that one")
        XCTAssertEqual(store.selectedTabID, mine.id)
        XCTAssertEqual(store.spaceContaining(tabID: pairing), work.id)
        XCTAssertEqual(store.selectedTab(inSpace: work.id)?.id, pairing, "active in its own window: the space shows it when the user goes there")
        XCTAssertEqual(host.tabsUpdateActive(pairing), .inItsSpace(.otherProfile))
        XCTAssertEqual(store.activeSpaceID, personal.id)
    }

    // MARK: What the user started still works

    func testATabOpenedFromTheSpaceOnScreenIsSelectedWithoutAnyInput() throws {
        let model = makeModel()
        let store = model.store
        let host = Host(model: model) { [unowned self] in self.clock }
        // A toolbar action or a popup calling `chrome.tabs.create`: the current space, selected.
        let tab = try XCTUnwrap(host.tabsCreate(by: "abc", in: store.activeProfileID, url: "chrome-extension://abc/page.html"))
        XCTAssertEqual(store.selectedTabID, tab)
        XCTAssertEqual(store.spaceContaining(tabID: tab), store.activeSpaceID)
        let other = store.addTab(kind: .today, title: "Other", url: blank)
        _ = model.engineHost.engine(for: other, profileID: model.profileID(for: other))
        XCTAssertEqual(host.tabsUpdateActive(other.id), .onScreen, "tabs.update({active}) in the space on screen needs no input either")
        XCTAssertEqual(store.selectedTabID, other.id)
    }

    func testAfterUserInputAnExtensionOfThisProfileBringsItsTabForwardOnce() throws {
        let model = makeModel()
        let store = model.store
        let host = Host(model: model) { [unowned self] in self.clock }
        let first = store.activeSpace
        let second = store.addSpace(name: "Second")
        store.selectSpace(first.id)
        let here = store.addTab(kind: .today, title: "Here", url: blank, in: first.id)
        let there = store.addTab(kind: .today, title: "There", url: blank, in: second.id)
        for tab in [here, there] { _ = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab)) }
        model.selectTab(here.id)

        // The user picks a tab in an extension's list (a tab switcher): tabs.update({active}) on a tab of another space.
        model.noteUserInput(at: clock)
        clock.addTimeInterval(0.3)
        XCTAssertEqual(host.tabsUpdateActive(there.id), .onScreen)
        XCTAssertEqual(store.activeSpaceID, second.id, "the user asked for it")
        XCTAssertEqual(store.selectedTabID, there.id)

        // The same extension calling again by itself has no input left to spend.
        clock.addTimeInterval(0.3)
        XCTAssertEqual(host.tabsUpdateActive(here.id), .inItsSpace(.noUserInput))
        XCTAssertEqual(store.activeSpaceID, second.id)
        XCTAssertEqual(store.selectedTab(inSpace: first.id)?.id, here.id)

        // A new tab asked into another window (space) right after a click follows the click too.
        model.noteUserInput(at: clock)
        let created = try XCTUnwrap(host.tabsCreate(by: "abc", in: store.activeProfileID, url: "chrome-extension://abc/page.html", window: first.id))
        XCTAssertEqual(store.activeSpaceID, first.id)
        XCTAssertEqual(store.selectedTabID, created)
    }

    // MARK: The loop breaker

    func testTheLoopBreakerStopsPagesPassingTheWindowAndSaysSoOnce() throws {
        let model = makeModel()
        let store = model.store
        let first = store.activeSpace
        let second = store.addSpace(name: "Second")
        store.selectSpace(first.id)

        // Two pages, one in each space, that each open a tab that takes focus (the engine's adopted tabs).
        var switches = 0
        var shown = store.activeSpaceID
        var opened: [Space.ID: Tab.ID] = [:]
        for step in 0..<12 {
            clock.addTimeInterval(0.35)
            let space = step.isMultiple(of: 2) ? second.id : first.id
            let tab = store.addTab(kind: .today, title: "Popup \(step)", url: blank, in: space)
            _ = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
            model.selectPageOpenedTab(tab.id, in: space, at: clock)
            opened[space] = tab.id
            if store.activeSpaceID != shown {
                switches += 1
                shown = store.activeSpaceID
            }
        }
        XCTAssertEqual(switches, ExtensionFocusGate.loopReturns + 1, "the window went back and forth \(switches) times")
        XCTAssertEqual(model.extensionFocusLog.count, 1, "logged once, however long the loop runs")
        XCTAssertEqual(model.extensionFocusLog.first?.contains("loop breaker"), true, model.extensionFocusLog.first ?? "nothing logged")
        XCTAssertEqual(model.toast?.message, "Stopped pages and extensions switching spaces")
        // Each page's last tab is still its own space's selected tab.
        for (space, tab) in opened { XCTAssertEqual(store.selectedTab(inSpace: space)?.id, tab) }

        // While it holds, an extension the user clicked does not move the window either.
        let held = store.activeSpaceID
        let target = held == first.id ? second.id : first.id
        model.noteUserInput(at: clock)
        XCTAssertEqual(model.extensionActivatedTab(try XCTUnwrap(opened[target]), at: clock.addingTimeInterval(0.1)), .inItsSpace(.loop))
        XCTAssertEqual(store.activeSpaceID, held)

        // The user's own switch always works, and after the pause programs may move the window again.
        model.selectSpace(target)
        XCTAssertEqual(store.activeSpaceID, target)
        clock.addTimeInterval(ExtensionFocusGate.loopPause + 1)
        let later = store.addTab(kind: .today, title: "Later", url: blank, in: held)
        _ = model.engineHost.engine(for: later, profileID: model.profileID(for: later))
        model.selectPageOpenedTab(later.id, in: held, at: clock)
        XCTAssertEqual(store.activeSpaceID, held)
        XCTAssertEqual(store.selectedTabID, later.id)
        XCTAssertEqual(model.extensionFocusLog.count, 1)
    }

    // MARK: Blank tabs

    func testAnExtensionThatNeverUsesItsBlankTabsGetsNoMore() throws {
        let model = makeModel()
        let store = model.store
        let host = Host(model: model) { [unowned self] in self.clock }
        let profile = store.activeProfileID
        let space = store.activeSpaceID

        // `chrome.tabs.create({url: "chrome://newtab", active: false})`, again and again.
        var made: [Tab.ID] = []
        for _ in 0..<40 {
            if let tab = host.tabsCreate(by: Self.extensionID, in: profile, active: false) { made.append(tab) }
        }
        XCTAssertEqual(made.count, ExtensionBlankTabs.limit)
        XCTAssertEqual(blankRows(store, in: space), ExtensionBlankTabs.limit)
        XCTAssertEqual(host.declined, 40 - ExtensionBlankTabs.limit)

        // A page of its own is not a blank tab, and another extension has its own count.
        XCTAssertNotNil(host.tabsCreate(by: Self.extensionID, in: profile, url: "chrome-extension://\(Self.extensionID)/options.html", active: false))
        XCTAssertNotNil(host.tabsCreate(by: "another", in: profile, active: false))

        // Once a blank tab loads a page, or is closed, there is room for one more.
        XCTAssertNil(host.tabsCreate(by: Self.extensionID, in: profile, active: false))
        store.updateTab(made[0], title: "Example", url: URL(string: "https://example.com/")!)  // what a committed navigation does to the row
        XCTAssertNotNil(host.tabsCreate(by: Self.extensionID, in: profile, active: false))
        XCTAssertNil(host.tabsCreate(by: Self.extensionID, in: profile, active: false))
        store.closeTab(made[1])
        XCTAssertNotNil(host.tabsCreate(by: Self.extensionID, in: profile, active: false))
        XCTAssertNil(host.tabsCreate(by: Self.extensionID, in: profile, active: false))
    }
}

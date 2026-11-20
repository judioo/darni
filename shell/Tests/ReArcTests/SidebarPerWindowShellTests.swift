import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// ⌘S per window in the shell. The owner's recording (builds 1080 and 1105)
/// has two browser windows side by side and ⌘S pressed three times: both
/// sidebars went and came back together, because the model every window
/// shares held one shown-or-hidden value. Each window now has its own.
@MainActor
final class SidebarPerWindowShellTests: XCTestCase {
    private func makeModel(_ configure: (SidebarStore) -> Void = { _ in }) -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        configure(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-sidebar-window-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-sidebar-window-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-sidebar-window-links-\(UUID().uuidString)")!
        return model
    }

    /// A browser window as `BrowserView` brings one up.
    private func openWindow(_ model: BrowserViewModel) -> SidebarWindowID {
        let window = SidebarWindowID()
        model.openSidebarMode(for: window)
        model.store.registerWindow(window)
        return window
    }

    /// As `BrowserView` does when its window closes.
    private func closeWindow(_ window: SidebarWindowID, in model: BrowserViewModel) {
        model.store.unregisterWindow(window)
        model.forgetSidebarMode(for: window)
    }

    func testCommandSHidesTheKeyWindowsSidebarOnly() {
        let model = makeModel()
        let left = openWindow(model)
        let right = openWindow(model)
        model.windowBecameKey(left)

        model.toggleSidebar()
        XCTAssertFalse(model.isSidebarVisible(in: left))
        XCTAssertFalse(model.isSidebarLaidOut(in: left), "its page goes wide")
        XCTAssertEqual(model.sidebarReveal(in: left), 0)
        XCTAssertTrue(model.isSidebarVisible(in: right), "the other window keeps its sidebar")
        XCTAssertTrue(model.isSidebarLaidOut(in: right), "and its page is not laid out again")
        XCTAssertEqual(model.sidebarReveal(in: right), 1)
        XCTAssertFalse(model.isSidebarSliding(in: right))

        // The recording's three presses: the right window never moves.
        _ = model.executeCommand(.toggleSidebar, commandID: nil)
        XCTAssertTrue(model.isSidebarVisible(in: left))
        model.toggleSidebar()
        XCTAssertFalse(model.isSidebarVisible(in: left))
        XCTAssertTrue(model.isSidebarVisible(in: right))
        XCTAssertEqual(model.sidebarVisibility.state(in: right), .shown)
    }

    func testTheMenuTitleAndTheCommandBarFollowTheKeyWindow() {
        let model = makeModel()
        let left = openWindow(model)
        let right = openWindow(model)
        model.windowBecameKey(left)
        model.toggleSidebar()
        XCTAssertEqual(model.sidebarMenuTitle, "Show Sidebar")
        XCTAssertTrue(model.commandBarCommandIndex.catalog.contains { $0.action == .toggleSidebar && $0.title == "Show Sidebar" })

        model.windowBecameKey(right)
        XCTAssertEqual(model.sidebarMenuTitle, "Hide Sidebar", "the window in use still shows its sidebar")
        XCTAssertTrue(model.isSidebarVisible, "what ⌘S would act on")
        XCTAssertTrue(model.commandBarCommandIndex.catalog.contains { $0.action == .toggleSidebar && $0.title == "Hide Sidebar" })

        model.windowBecameKey(left)
        XCTAssertEqual(model.sidebarMenuTitle, "Show Sidebar")
        XCTAssertFalse(model.isSidebarVisible)
    }

    func testAButtonActsOnItsOwnWindowWhicheverIsKey() {
        let model = makeModel()
        let left = openWindow(model)
        let right = openWindow(model)
        model.windowBecameKey(left)
        // The right window's Hide Sidebar button, pressed while the left is key.
        model.toggleSidebar(in: right)
        XCTAssertFalse(model.isSidebarVisible(in: right))
        XCTAssertTrue(model.isSidebarVisible(in: left))
    }

    func testANewWindowStartsAsTheWindowItWasOpenedFromAndAClosedOneIsForgotten() {
        let model = makeModel()
        let first = openWindow(model)
        model.windowBecameKey(first)
        model.toggleSidebar()

        let second = openWindow(model)
        XCTAssertFalse(model.isSidebarVisible(in: second), "New Window from a window with its sidebar hidden")
        XCTAssertEqual(model.sidebarVisibility.state(in: second), .hidden)

        model.windowBecameKey(second)
        model.toggleSidebar()
        XCTAssertTrue(model.isSidebarVisible(in: second))
        XCTAssertFalse(model.isSidebarVisible(in: first), "afterwards each has its own")
        let third = openWindow(model)
        XCTAssertTrue(model.isSidebarVisible(in: third))

        closeWindow(first, in: model)
        XCTAssertFalse(model.sidebarVisibility.isRegistered(first))
        XCTAssertFalse(model.sidebarModes.isRegistered(first))
        XCTAssertTrue(model.sidebarVisibility.isRegistered(second))
    }

    func testTheFloatingSidebarBelongsToTheWindowThePointerIsIn() {
        let model = makeModel()
        let left = openWindow(model)
        let right = openWindow(model)
        model.windowBecameKey(left)
        model.toggleSidebar(in: left)
        model.toggleSidebar(in: right)

        // The right window's edge monitor, while the left window is key.
        model.setSidebarPeeking(true, in: right)
        XCTAssertTrue(model.isSidebarPeeking(in: right))
        XCTAssertFalse(model.isSidebarPeeking(in: left), "both are hidden, one floats")
        model.setSidebarPeeking(false, in: right)
        XCTAssertFalse(model.isSidebarPeeking(in: right))

        model.toggleSidebar(in: left)
        model.setSidebarPeeking(true, in: left)
        XCTAssertFalse(model.isSidebarPeeking(in: left), "a shown sidebar never floats")

        model.setSidebarPeeking(true, in: right)
        model.setSidebarSide(model.sidebarSide == .left ? .right : .left)
        XCTAssertFalse(model.isSidebarPeeking(in: right), "a side change dismisses a floating sidebar in any window")
    }

    func testTheLibraryBringsBackTheSidebarOfTheWindowItOpensIn() {
        let model = makeModel()
        let left = openWindow(model)
        let right = openWindow(model)
        model.windowBecameKey(left)
        model.toggleSidebar(in: right)

        model.openLibrary(.media, in: left)
        XCTAssertFalse(model.isSidebarVisible(in: right), "the left window's Library leaves the right one hidden")

        model.openLibrary(.media, in: right)
        XCTAssertTrue(model.isSidebarVisible(in: right), "the Library lives in the sidebar")
        XCTAssertTrue(model.isSidebarVisible(in: left))
    }

    func testTheMiniSidebarComesBackInItsOwnWindow() {
        let model = makeModel()
        let left = openWindow(model)
        let right = openWindow(model)
        model.windowBecameKey(left)
        model.toggleSidebar(in: left)
        model.toggleSidebar(in: right)

        model.toggleMiniSidebar(in: right)
        XCTAssertTrue(model.isSidebarVisible(in: right), "⇧⌘S on a hidden sidebar shows it in the new mode")
        XCTAssertTrue(model.isMiniSidebar(in: right))
        XCTAssertFalse(model.isSidebarVisible(in: left), "the other window stays hidden")
    }

    func testThePeekIsCentredBesideItsOwnWindowsSidebar() {
        let model = makeModel()
        model.sidebarWidth = 300
        let left = openWindow(model)
        let right = openWindow(model)
        model.windowBecameKey(left)
        model.toggleSidebar(in: left)
        let size = CGSize(width: 1400, height: 900)
        XCTAssertEqual(model.peekLayout(in: left, windowSize: size).region.minX, 0, "no sidebar: the whole window")
        XCTAssertEqual(model.peekLayout(in: right, windowSize: size).region.minX, model.sidebarSide == .left ? 300 : 0)
        XCTAssertEqual(model.peekLayout(in: right, windowSize: size).region.width, 1100)
    }

    func testPageFullscreenKeepsItsOwnWindowsSidebar() {
        var tab: Tab!
        let model = makeModel { store in
            tab = store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!)
            store.selectTab(tab.id)
        }
        let left = openWindow(model)
        let right = openWindow(model)
        model.windowBecameKey(left)
        model.toggleSidebar(in: right)
        model.setSidebarPeeking(true, in: right)

        // The page is in the right window; the left one is key and shows its sidebar.
        _ = model.pageEnteredFullscreen(tabID: tab.id, engineTabID: 5, windowIsFullscreen: false, window: right)
        XCTAssertEqual(model.htmlFullscreen?.sidebarWasVisible, false)
        XCTAssertFalse(model.isSidebarPeeking(in: right), "the floating sidebar leaves the fullscreen page")
        XCTAssertEqual(model.pageExitedFullscreen(engineTabID: 5), [.restoreChrome(sidebarVisible: false), .exitNativeFullscreen])
        XCTAssertFalse(model.isSidebarVisible(in: right), "as it was")
        XCTAssertTrue(model.isSidebarVisible(in: left))

        _ = model.pageEnteredFullscreen(tabID: tab.id, engineTabID: 6, windowIsFullscreen: false)
        XCTAssertEqual(model.htmlFullscreen?.sidebarWasVisible, true, "no window named: the key window's")
    }

    func testTheInlineRenameAsksAboutTheKeyWindowsSidebar() {
        var tab: Tab!
        let model = makeModel { store in
            tab = store.addTab(kind: .pinned, title: "Page", url: URL(string: "https://p.test")!)
        }
        let left = openWindow(model)
        let right = openWindow(model)
        model.windowBecameKey(left)
        model.toggleSidebar(in: right)
        XCTAssertTrue(model.beginInlineRename(.tab(tab.id)), "the key window shows its sidebar: the row takes the field")
        _ = model.endInlineRename(.cancel)

        model.toggleSidebar(in: right)
        model.toggleSidebar(in: left)
        XCTAssertFalse(model.beginInlineRename(.tab(tab.id)), "hidden in the key window: no row to type into")
    }
}

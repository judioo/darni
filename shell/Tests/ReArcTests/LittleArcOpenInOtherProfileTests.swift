import Foundation
import Testing
import SidebarModel
@testable import ReArc

/// Little Darni's Open in across profiles (owner reports 2026-11-20). A space
/// of another profile gets the address opened afresh, by that profile's own
/// engine. The window's engine, and with it the page, cookies and sign-ins,
/// never moves there (S-01). It asks first, with the address taken when it
/// asks (OI-01, OI-03), and only a web address goes (OI-02). The main button
/// and ⌘O name the last focused browser window's space, whatever its profile,
/// and go the same way as a row of the picker.
@MainActor
struct LittleArcOpenInOtherProfileTests {
    private final class Presenter: BrowserWindowPresenting {
        var focused: [SidebarWindowID] = []
        var presented: [LittleArcWindow.ID] = []
        func presentLittleArcWindow(_ id: LittleArcWindow.ID) { presented.append(id) }
        func dismissLittleArcWindow(_ id: LittleArcWindow.ID) {}
        func presentPrivateWindow(_ window: PrivateWindowModel) {}
        func focusBrowserWindow(_ id: SidebarWindowID) { focused.append(id) }
    }

    /// The owner's shape: "Personal" with several spaces and a profile with one.
    private struct Fixture {
        let store: SidebarStore
        let model: BrowserViewModel
        let presenter: Presenter
        let window: SidebarWindowID
        let many: Profile.ID
        let manySpaces: [Space]
        let solo: Profile
        let soloSpace: Space
    }

    private func fixture() -> Fixture {
        let store = SidebarStore(spaces: [Space(name: "Many 1")])
        let many = store.activeProfileID
        for index in 2...4 { store.addSpace(name: "Many \(index)", profileID: many) }
        let solo = store.addProfile(name: "Solo")
        let soloSpace = store.spaces(in: solo.id)[0]
        let window = SidebarWindowID()
        store.registerWindow(window)
        store.windowBecameKey(window)
        // The browser window is on the one-space profile when the link opens.
        store.selectSpace(soloSpace.id)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("little-open-in-\(UUID().uuidString).json")
        let model = BrowserViewModel(store: store, persistence: SidebarFilePersistence(fileURL: file))
        let presenter = Presenter()
        model.windowPresenter = presenter
        return Fixture(store: store, model: model, presenter: presenter, window: window, many: many,
                       manySpaces: store.spaces(in: many), solo: solo, soloSpace: soloSpace)
    }

    @Test func aWindowInAOneSpaceProfileHasAMenuOfTheOtherProfilesSpaces() {
        let f = fixture()
        let little = f.model.openLittleArc(url: URL(string: "https://link.test/")!)
        #expect(little.profileID == f.solo.id)
        #expect(f.store.littleArcTargetSpace(for: little.id)?.id == f.soloSpace.id)
        let sections = LittleArcOpenInMenu.sections(store: f.store, windowID: little.id)
        #expect(sections.map(\.profileID) == [f.solo.id, f.many])
        #expect(sections.map(\.header) == ["Solo", "Personal"])
        #expect(sections.first?.entries.map(\.spaceID) == [f.soloSpace.id])
        #expect(sections.first?.entries.map(\.kind) == [.move])
        #expect(sections.last?.entries.map(\.spaceID) == f.manySpaces.map(\.id))
        #expect(sections.last?.entries.allSatisfy { $0.kind == .reopen && $0.isEnabled } == true)
    }

    @Test func anotherProfilesSpaceGetsTheAddressAfreshAndTheWindowsEngineStaysBehind() throws {
        let f = fixture()
        let little = f.model.openLittleArc(url: URL(string: "https://opened.test/")!, title: "Signed in as someone")
        let littleEngine = f.model.littleArcEngine(for: little.id)
        #expect(littleEngine.pagePrompts.profileID == f.solo.id)
        // The page went somewhere since: the address the window shows is what is asked about.
        let live = URL(string: "https://live.test/inbox?id=7")!
        littleEngine.load(live)
        f.model.keyLittleArcID = little.id
        f.model.focusedLittleArcID = little.id
        let destination = f.manySpaces[2]

        // It asks first, and nothing has happened yet.
        let question = LittleArcOpenInMenu.Question(windowID: little.id, spaceID: destination.id, url: live, host: "live.test")
        #expect(f.model.openLittleArcWindow(little.id, in: destination.id) == .ask(question))
        #expect(f.model.pendingLittleArcOpenIn == question)
        #expect(f.store.littleArcWindow(withID: little.id) != nil)
        #expect(f.store.activeSpaceID == f.soloSpace.id)
        #expect(f.store.content(for: destination.id).today.isEmpty)
        #expect(f.presenter.focused.isEmpty)

        #expect(f.model.confirmLittleArcOpenIn())
        #expect(f.model.pendingLittleArcOpenIn == nil)

        // A new tab with the address, in the chosen space, and the browser window shows it.
        let tab = try #require(f.store.selectedTab)
        #expect(tab.url == live)
        #expect(tab.title != "Signed in as someone")
        #expect(tab.id != little.id, "the tab is a new page, not the window's under another name")
        #expect(f.store.spaceContaining(tabID: tab.id) == destination.id)
        #expect(f.store.activeSpaceID == destination.id)
        #expect(f.store.focusedSpaceID(in: f.window) == destination.id)
        #expect(f.presenter.focused == [f.window])
        #expect(f.store.content(for: f.soloSpace.id).today.isEmpty)

        // Loaded by the other profile's engine: a different engine, in that profile.
        #expect(f.model.profileID(for: tab) == f.many)
        let tabEngine = try #require(f.model.engineHost.engine(forTabID: tab.id, profileID: f.many))
        #expect(tabEngine !== littleEngine)
        #expect(tabEngine.pagePrompts.profileID == f.many)
        #expect(tabEngine.pagePrompts.role == .tab)
        #expect(tabEngine.currentURL == live)
        #expect(f.model.engineHost.engine(forTabID: tab.id, profileID: f.solo.id) == nil)

        // The window's engine was dropped where it was: not promoted, not moved, not relabelled.
        #expect(littleEngine.pagePrompts.profileID == f.solo.id)
        #expect(littleEngine.pagePrompts.role == .littleArc)
        #expect(f.model.engineHost.existingLittleArcEngine(little.id, profileID: f.solo.id) == nil)
        #expect(f.model.engineHost.existingLittleArcEngine(little.id, profileID: f.many) == nil)

        // The record is gone as after a promote, and nothing still points at the window.
        #expect(f.store.littleArcWindow(withID: little.id) == nil)
        #expect(!f.store.littleArcArchivedWindows.contains { $0.id == little.id })
        #expect(f.model.keyLittleArcID == nil)
        #expect(f.model.focusedLittleArcID == nil)
    }

    @Test func aSpaceOfTheWindowsOwnProfileStillTakesThePageAsBefore() throws {
        let f = fixture()
        let second = f.store.addSpace(name: "Solo 2", profileID: f.solo.id)
        f.store.selectSpace(f.soloSpace.id)
        let little = f.model.openLittleArc(url: URL(string: "about:blank#same")!, title: "Same")
        #expect(LittleArcOpenInMenu.sections(store: f.store, windowID: little.id).first?.entries.first?.kind == .move)

        // Its own session: the page moves at once, unasked, whatever its address is.
        #expect(f.model.openLittleArcWindow(little.id, in: second.id) == .move)
        #expect(f.model.pendingLittleArcOpenIn == nil)
        #expect(f.model.littleArcToast == nil)

        let tab = try #require(f.store.selectedTab)
        #expect(tab.url.absoluteString == "about:blank#same")
        #expect(tab.title == "Same", "a promote keeps the page's title: same session")
        #expect(f.store.spaceContaining(tabID: tab.id) == second.id)
        #expect(f.model.profileID(for: tab) == f.solo.id)
        #expect(f.store.littleArcWindow(withID: little.id) == nil)
        #expect(f.presenter.focused == [f.window])
    }

    // MARK: - The main button and ⌘O follow the focused browser window

    /// The browser window moves on to a space of another profile: Open in
    /// names that space, and the main button asks before the address goes there.
    @Test func theMainButtonFollowsTheBrowserWindowIntoAnotherProfileAndAsks() throws {
        let f = fixture()
        let address = URL(string: "https://main.test/page")!
        let little = f.model.openLittleArc(url: address, title: "Signed in as someone")
        let littleEngine = f.model.littleArcEngine(for: little.id)
        #expect(f.store.littleArcTargetSpace(for: little.id)?.id == f.soloSpace.id)

        let destination = f.manySpaces[1]
        f.store.selectSpace(destination.id)
        #expect(f.store.littleArcTargetSpace(for: little.id)?.id == destination.id, "the label and the tint are this space's now")

        let question = LittleArcOpenInMenu.Question(windowID: little.id, spaceID: destination.id, url: address, host: "main.test")
        #expect(f.model.openLittleArcWindowInTarget(little.id) == .ask(question))
        #expect(f.model.pendingLittleArcOpenIn == question)
        #expect(f.store.littleArcWindow(withID: little.id) != nil, "nothing has happened yet")
        #expect(f.store.content(for: destination.id).today.isEmpty)
        #expect(f.model.engineHost.existingLittleArcEngine(little.id, profileID: f.solo.id) === littleEngine)

        // Cancel leaves everything as it was.
        f.model.cancelLittleArcOpenIn(for: little.id)
        #expect(f.store.littleArcWindow(withID: little.id) != nil)
        #expect(f.store.spaces.allSatisfy { f.store.content(for: $0.id).today.isEmpty })

        // Yes: the address opens afresh in the other profile's engine, and the window's engine stays behind.
        #expect(f.model.openLittleArcWindowInTarget(little.id) == .ask(question))
        #expect(f.model.confirmLittleArcOpenIn())
        let tab = try #require(f.store.selectedTab)
        #expect(tab.url == address)
        #expect(tab.title != "Signed in as someone")
        #expect(f.store.spaceContaining(tabID: tab.id) == destination.id)
        #expect(f.model.profileID(for: tab) == f.many)
        let tabEngine = try #require(f.model.engineHost.engine(forTabID: tab.id, profileID: f.many))
        #expect(tabEngine !== littleEngine)
        #expect(f.model.engineHost.existingLittleArcEngine(little.id, profileID: f.solo.id) == nil)
        #expect(f.model.engineHost.existingLittleArcEngine(little.id, profileID: f.many) == nil)
        #expect(f.store.content(for: f.soloSpace.id).today.isEmpty, "nothing lands in the window's own profile")
    }

    /// ⌘O is the main button: the same target, the same question.
    @Test func commandOAsksBeforeCrossingToTheBrowserWindowsProfile() throws {
        let f = fixture()
        let address = URL(string: "https://shortcut.test/")!
        let little = f.model.openLittleArc(url: address)
        let destination = f.manySpaces[2]
        f.store.selectSpace(destination.id)
        f.model.keyLittleArcID = little.id

        f.model.openLittleArcOrPeekInSpace()
        #expect(f.model.pendingLittleArcOpenIn
            == LittleArcOpenInMenu.Question(windowID: little.id, spaceID: destination.id, url: address, host: "shortcut.test"))
        #expect(f.store.littleArcWindow(withID: little.id) != nil, "⌘O alone moves nothing across profiles")
        #expect(f.store.spaces.allSatisfy { f.store.content(for: $0.id).today.isEmpty })
        #expect(f.presenter.focused.isEmpty)
    }

    /// The browser window is on a space of the window's own profile: the main
    /// button and ⌘O move the page there at once, unasked, as they always did.
    @Test func theMainButtonAndCommandOStillMoveThePageWithinItsOwnProfile() throws {
        let f = fixture()
        let second = f.store.addSpace(name: "Solo 2", profileID: f.solo.id)
        let little = f.model.openLittleArc(url: URL(string: "about:blank#main")!, title: "Main")
        f.store.selectSpace(second.id)
        #expect(f.store.littleArcTargetSpace(for: little.id)?.id == second.id)

        #expect(f.model.openLittleArcWindowInTarget(little.id) == .move)
        #expect(f.model.pendingLittleArcOpenIn == nil, "its own session never asks")
        #expect(f.model.littleArcToast == nil)
        var tab = try #require(f.store.selectedTab)
        #expect(tab.title == "Main")
        #expect(f.store.spaceContaining(tabID: tab.id) == second.id)
        #expect(f.model.profileID(for: tab) == f.solo.id, "still its own session")

        let other = f.model.openLittleArc(url: URL(string: "https://again.test/")!)
        f.model.keyLittleArcID = other.id
        f.model.openLittleArcOrPeekInSpace()
        #expect(f.model.pendingLittleArcOpenIn == nil)
        tab = try #require(f.store.selectedTab)
        #expect(tab.url.absoluteString == "https://again.test/")
        #expect(f.store.spaceContaining(tabID: tab.id) == second.id)
        #expect(f.store.littleArcWindow(withID: other.id) == nil)
    }

    /// A blank window, or any page that is not a web page, cannot follow the
    /// browser window into another profile: the main button says why, on the
    /// window, and the page stays. Back on its own profile it moves.
    @Test func theMainButtonRefusesAPageThatCannotCrossAndSaysWhy() throws {
        let f = fixture()
        let little = f.model.openLittleArc(url: URL(string: "about:blank#main")!)
        f.store.selectSpace(f.manySpaces[1].id)
        #expect(f.model.openLittleArcWindowInTarget(little.id) == .refuse)
        #expect(f.model.pendingLittleArcOpenIn == nil)
        #expect(f.model.littleArcToast?.windowID == little.id)
        #expect(f.model.littleArcToast?.toast.message == "Only web pages can open in another profile or container")
        #expect(f.store.littleArcWindow(withID: little.id) != nil)
        #expect(f.store.spaces.allSatisfy { f.store.content(for: $0.id).today.isEmpty })

        f.store.selectSpace(f.soloSpace.id)
        #expect(f.model.openLittleArcWindowInTarget(little.id) == .move)
        #expect(f.store.spaceContaining(tabID: try #require(f.store.selectedTab).id) == f.soloSpace.id)
    }

    /// The target is read when the button is pressed: another browser window
    /// took focus since the label was drawn, and its space is the one asked about.
    @Test func theTargetIsReadWhenTheButtonIsPressed() throws {
        let f = fixture()
        let other = SidebarWindowID()
        f.store.registerWindow(other, spaceID: f.manySpaces[3].id)
        let little = f.model.openLittleArc(url: URL(string: "https://late.test/")!)
        #expect(f.store.littleArcTargetSpace(for: little.id)?.id == f.soloSpace.id)
        f.model.windowBecameKey(other)
        #expect(f.store.littleArcTargetSpace(for: little.id)?.id == f.manySpaces[3].id)
        guard case .ask(let question)? = f.model.openLittleArcWindowInTarget(little.id) else {
            Issue.record("another profile's space asks")
            return
        }
        #expect(question.spaceID == f.manySpaces[3].id)
        #expect(f.model.openLittleArcWindowInTarget(UUID()) == nil, "no such window: nothing happens")
    }

    /// The model's own promote, which the command bar's "Promote Little Darni
    /// to tab" uses, never crosses: with no space named it stays in the
    /// window's profile wherever the browser window is.
    @Test func aPromoteWithNoSpaceNamedStaysInTheWindowsOwnProfile() throws {
        let f = fixture()
        let little = f.model.openLittleArc(url: URL(string: "about:blank#main")!)
        f.store.selectSpace(f.manySpaces[1].id)
        f.model.promoteLittleArcWindow(little.id)
        #expect(f.model.pendingLittleArcOpenIn == nil)
        let tab = try #require(f.store.selectedTab)
        #expect(f.store.spaceContaining(tabID: tab.id) == f.soloSpace.id)
        #expect(f.model.profileID(for: tab) == f.solo.id)
    }

    /// The menu was drawn, then the space went: nothing opens and the window stays.
    @Test func aSpaceThatWentWhileTheMenuWasUpOpensNothing() {
        let f = fixture()
        let little = f.model.openLittleArc(url: URL(string: "https://stale.test/")!)
        let gone = f.manySpaces[3]
        #expect(f.store.archiveSpace(gone.id) == nil)

        #expect(f.model.openLittleArcWindow(little.id, in: gone.id) == nil)
        #expect(f.model.openLittleArcWindow(little.id, in: UUID()) == nil)
        #expect(f.model.pendingLittleArcOpenIn == nil)

        #expect(f.store.littleArcWindow(withID: little.id) != nil)
        #expect(f.model.engineHost.existingLittleArcEngine(little.id, profileID: f.solo.id) != nil)
        #expect(f.store.activeSpaceID == f.soloSpace.id)
        #expect(f.presenter.focused.isEmpty)
        #expect(f.store.spaces.allSatisfy { f.store.content(for: $0.id).today.isEmpty })
    }

    // MARK: - The question (OI-01, OI-03)

    /// The address is taken when the question is put. The page goes somewhere
    /// else while it is up, and Yes still opens the address that was named.
    @Test func theAddressNamedInTheQuestionIsTheOneOpened() throws {
        let f = fixture()
        let asked = URL(string: "https://asked.test/document")!
        let little = f.model.openLittleArc(url: asked)
        let littleEngine = f.model.littleArcEngine(for: little.id)
        let destination = f.manySpaces[1]

        #expect(f.model.openLittleArcWindow(little.id, in: destination.id)
            == .ask(LittleArcOpenInMenu.Question(windowID: little.id, spaceID: destination.id, url: asked, host: "asked.test")))
        let later = URL(string: "https://elsewhere.test/takes-over")!
        littleEngine.load(later)
        f.model.handleLittleArcNavigationCommit(windowID: little.id, url: later, title: "Elsewhere")
        #expect(f.store.littleArcWindow(withID: little.id)?.url == later, "the window's record follows the page")

        #expect(f.model.confirmLittleArcOpenIn())
        let tab = try #require(f.store.selectedTab)
        #expect(tab.url == asked)
        #expect(tab.title == "asked.test")
        #expect(f.store.spaceContaining(tabID: tab.id) == destination.id)
        let tabEngine = try #require(f.model.engineHost.engine(forTabID: tab.id, profileID: f.many))
        #expect(tabEngine.currentURL == asked)
        #expect(!f.store.spaces.contains { space in f.store.displayTabs(in: space.id).contains { $0.url == later } })
    }

    @Test func theQuestionSaysWhereThePageGoesAndWhatStaysBehind() throws {
        let f = fixture()
        let little = f.model.openLittleArc(url: URL(string: "https://mail.example.test/reset?token=1")!)
        let destination = f.manySpaces[2]
        #expect(f.model.openLittleArcWindow(little.id, in: destination.id) != nil)
        let text = f.model.littleArcOpenInMessage(try #require(f.model.pendingLittleArcOpenIn))
        #expect(text.title == "Open in “Many 3”?")
        #expect(text.message == "The page at mail.example.test will open as a new tab in “Many 3” (Personal), without this window's sign-ins. "
            + "Cookies, sign-ins and site data stay in Solo, so you may need to sign in again. "
            + "This window closes, and its back and forward history is lost.")
        #expect(text.action == "Open")
    }

    /// A container's space is named as the menu marks it, and a container's
    /// window names its own session as Move to Profile names it.
    @Test func theQuestionNamesAContainerAsTheMenuDoes() throws {
        let f = fixture()
        let client = f.store.addSpace(name: "Client", profileID: f.solo.id)
        let container = try #require(f.store.createContainer(forSpace: client.id))
        f.store.selectSpace(f.soloSpace.id)

        let little = f.model.openLittleArc(url: URL(string: "https://into.test/")!)
        #expect(f.model.openLittleArcWindow(little.id, in: client.id) != nil)
        var text = f.model.littleArcOpenInMessage(try #require(f.model.pendingLittleArcOpenIn))
        #expect(text.title == "Open in “Client”?")
        #expect(text.message.hasPrefix("The page at into.test will open as a new tab in “Client” (Container), without this window's sign-ins. "
            + "Cookies, sign-ins and site data stay in Solo,"))
        f.model.cancelLittleArcOpenIn()

        let inside = f.model.openLittleArc(url: URL(string: "https://outof.test/")!, profileID: container.id)
        #expect(LittleArcOpenInMenu.sections(store: f.store, windowID: inside.id).map(\.header)
            == ["This container", "Solo (outside this container)", "Personal"])
        #expect(f.model.openLittleArcWindow(inside.id, in: f.soloSpace.id) != nil, "the parent's space is another session: it asks")
        text = f.model.littleArcOpenInMessage(try #require(f.model.pendingLittleArcOpenIn))
        #expect(text.message.hasPrefix("The page at outof.test will open as a new tab in “\(f.soloSpace.name)” (Solo), without this window's sign-ins. "
            + "Cookies, sign-ins and site data stay in the “Client” container,"))
    }

    /// Cancel: nothing opens, and the window, its engine and the sidebar are as they were.
    @Test func cancelLeavesTheWindowAndTheSidebarAsTheyWere() {
        let f = fixture()
        let address = URL(string: "https://kept.test/page")!
        let little = f.model.openLittleArc(url: address, title: "Kept")
        let littleEngine = f.model.littleArcEngine(for: little.id)
        f.model.keyLittleArcID = little.id
        f.model.focusedLittleArcID = little.id
        let before = f.store.makeSnapshot()

        #expect(f.model.openLittleArcWindow(little.id, in: f.manySpaces[0].id) != nil)
        #expect(f.model.pendingLittleArcOpenIn != nil)
        f.model.cancelLittleArcOpenIn(for: UUID())
        #expect(f.model.pendingLittleArcOpenIn != nil, "another window's Cancel is not this one's")
        f.model.cancelLittleArcOpenIn(for: little.id)

        #expect(f.model.pendingLittleArcOpenIn == nil)
        #expect(!f.model.confirmLittleArcOpenIn(), "no question, nothing to confirm")
        let after = f.store.makeSnapshot()
        #expect(after.littleArcWindows == before.littleArcWindows)
        #expect(after.spaces.map(\.id) == before.spaces.map(\.id))
        #expect(f.store.spaces.allSatisfy { f.store.content(for: $0.id).today.isEmpty }, "no tab was made anywhere")
        #expect(f.store.activeSpaceID == f.soloSpace.id)
        #expect(f.store.littleArcWindow(withID: little.id)?.url == address)
        #expect(f.model.engineHost.existingLittleArcEngine(little.id, profileID: f.solo.id) === littleEngine)
        #expect(littleEngine.currentURL == address)
        #expect(f.model.keyLittleArcID == little.id)
        #expect(f.model.focusedLittleArcID == little.id)
        #expect(f.presenter.focused.isEmpty)
    }

    /// The space went, or the window closed, while the question was up: Yes opens nothing.
    @Test func aQuestionAnsweredTooLateOpensNothing() {
        let f = fixture()
        let little = f.model.openLittleArc(url: URL(string: "https://late.test/")!)
        let gone = f.manySpaces[3]
        #expect(f.model.openLittleArcWindow(little.id, in: gone.id) != nil)
        #expect(f.store.archiveSpace(gone.id) == nil)
        #expect(!f.model.confirmLittleArcOpenIn())
        #expect(f.model.pendingLittleArcOpenIn == nil)
        #expect(f.store.littleArcWindow(withID: little.id) != nil)
        #expect(f.model.engineHost.existingLittleArcEngine(little.id, profileID: f.solo.id) != nil)
        #expect(f.presenter.focused.isEmpty)

        #expect(f.model.openLittleArcWindow(little.id, in: f.manySpaces[0].id) != nil)
        f.model.closeLittleArcWindow(little.id)
        #expect(f.model.pendingLittleArcOpenIn == nil, "closing the window withdraws its question")
        #expect(!f.model.confirmLittleArcOpenIn())
        #expect(f.store.spaces.allSatisfy { f.store.content(for: $0.id).today.isEmpty })
    }

    // MARK: - Only web addresses (OI-02)

    /// Anything but a web address stays in its window: no question, no tab,
    /// and a toast on that window says why.
    @Test func anAddressThatIsNotAWebAddressStaysInItsWindow() {
        let f = fixture()
        for address in ["about:blank#new", "data:text/html,<p>page</p>", "file:///tmp/page.html"] {
            let little = f.model.openLittleArc(url: URL(string: address)!)
            f.model.littleArcToast = nil
            let sections = LittleArcOpenInMenu.sections(store: f.store, windowID: little.id, url: f.model.littleArcAddress(little.id))
            #expect(sections.flatMap(\.entries).filter(\.isEnabled).map(\.spaceID) == [f.soloSpace.id],
                    "\(address): every row but the window's own space crosses, so it is disabled")
            #expect(LittleArcOpenInMenu.note(for: sections) == "Only web pages can open in another profile or container")

            #expect(f.model.openLittleArcWindow(little.id, in: f.manySpaces[0].id) == .refuse, "\(address)")
            #expect(f.model.pendingLittleArcOpenIn == nil)
            #expect(f.model.littleArcToast?.windowID == little.id)
            #expect(f.model.littleArcToast?.toast.message == "Only web pages can open in another profile or container")
            #expect(f.model.toast == nil, "the browser window behind shows nothing")
            #expect(f.store.littleArcWindow(withID: little.id) != nil)
            #expect(f.model.engineHost.existingLittleArcEngine(little.id, profileID: f.solo.id) != nil)
        }
        #expect(f.store.spaces.allSatisfy { f.store.content(for: $0.id).today.isEmpty }, "no tab was made anywhere")
        #expect(f.store.activeSpaceID == f.soloSpace.id)
        #expect(f.presenter.focused.isEmpty)
    }

    /// The page left the web after the question was put: the address asked
    /// about is still a web address, and it is the one that opens.
    @Test func theShownAddressDecidesNotTheRecord() {
        let f = fixture()
        let little = f.model.openLittleArc(url: URL(string: "https://first.test/")!)
        // The engine shows a page the record has not caught up with.
        f.model.littleArcEngine(for: little.id).load(URL(string: "data:text/html,<p>now</p>")!)
        #expect(f.store.littleArcWindow(withID: little.id)?.url.absoluteString == "https://first.test/")
        #expect(f.model.openLittleArcWindow(little.id, in: f.manySpaces[0].id) == .refuse)
        #expect(f.store.littleArcWindow(withID: little.id) != nil)
    }
}

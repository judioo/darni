import Foundation
import Testing
import SidebarModel
@testable import ReArc

/// Little Darni's Open in ⌄ across profiles (owner report 2026-11-20). A space
/// of another profile gets the address opened afresh, by that profile's own
/// engine. The window's engine, and with it the page, cookies and sign-ins,
/// never moves there (S-01).
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
        let little = f.model.openLittleArc(url: URL(string: "about:blank#link")!)
        #expect(little.profileID == f.solo.id)
        #expect(f.store.littleArcTargetSpace(for: little.id)?.id == f.soloSpace.id)
        let sections = LittleArcOpenInMenu.sections(store: f.store, windowID: little.id)
        #expect(sections.map(\.profileID) == [f.many])
        #expect(sections.first?.header == "Personal")
        #expect(sections.first?.entries.map(\.spaceID) == f.manySpaces.map(\.id))
        #expect(sections.first?.entries.allSatisfy { $0.kind == .reopen } == true)
    }

    @Test func anotherProfilesSpaceGetsTheAddressAfreshAndTheWindowsEngineStaysBehind() throws {
        let f = fixture()
        let little = f.model.openLittleArc(url: URL(string: "about:blank#opened")!, title: "Signed in as someone")
        let littleEngine = f.model.littleArcEngine(for: little.id)
        #expect(littleEngine.pagePrompts.profileID == f.solo.id)
        // The page went somewhere since: the address the window shows is what opens.
        let live = URL(string: "about:blank#live")!
        littleEngine.load(live)
        f.model.keyLittleArcID = little.id
        f.model.focusedLittleArcID = little.id
        let destination = f.manySpaces[2]

        #expect(f.model.openLittleArcWindow(little.id, in: destination.id) == .reopen)

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

        #expect(f.model.openLittleArcWindow(little.id, in: second.id) == .move)

        let tab = try #require(f.store.selectedTab)
        #expect(tab.url.absoluteString == "about:blank#same")
        #expect(tab.title == "Same", "a promote keeps the page's title: same session")
        #expect(f.store.spaceContaining(tabID: tab.id) == second.id)
        #expect(f.model.profileID(for: tab) == f.solo.id)
        #expect(f.store.littleArcWindow(withID: little.id) == nil)
        #expect(f.presenter.focused == [f.window])
    }

    /// The main button and ⌘O: unchanged, into the window's own profile.
    @Test func theMainButtonStaysInTheWindowsOwnProfile() throws {
        let f = fixture()
        let little = f.model.openLittleArc(url: URL(string: "about:blank#main")!)
        // The browser window moves on to the other profile before ⌘O.
        f.store.selectSpace(f.manySpaces[1].id)
        #expect(f.store.littleArcTargetSpace(for: little.id)?.id == f.soloSpace.id)
        f.model.promoteLittleArcWindow(little.id)
        let tab = try #require(f.store.selectedTab)
        #expect(f.store.spaceContaining(tabID: tab.id) == f.soloSpace.id)
        #expect(f.model.profileID(for: tab) == f.solo.id)
    }

    /// The menu was drawn, then the space went: nothing opens and the window stays.
    @Test func aSpaceThatWentWhileTheMenuWasUpOpensNothing() {
        let f = fixture()
        let little = f.model.openLittleArc(url: URL(string: "about:blank#stale")!)
        let gone = f.manySpaces[3]
        #expect(f.store.archiveSpace(gone.id) == nil)

        #expect(f.model.openLittleArcWindow(little.id, in: gone.id) == nil)
        #expect(f.model.openLittleArcWindow(little.id, in: UUID()) == nil)

        #expect(f.store.littleArcWindow(withID: little.id) != nil)
        #expect(f.model.engineHost.existingLittleArcEngine(little.id, profileID: f.solo.id) != nil)
        #expect(f.store.activeSpaceID == f.soloSpace.id)
        #expect(f.presenter.focused.isEmpty)
        #expect(f.store.spaces.allSatisfy { f.store.content(for: $0.id).today.isEmpty })
    }
}

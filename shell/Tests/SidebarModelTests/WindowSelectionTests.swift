import Foundation
import Testing
@testable import SidebarModel

/// Two windows on one space are separate browsers (owner, 2026-11-17): each
/// keeps its own selected tab, and a tab shows in one window at a time.
@MainActor
struct WindowSelectionTests {
    private func url(_ host: String) -> URL { URL(string: "https://\(host)/")! }

    /// One space, two tabs, two windows on it; `a` is key.
    private func twoWindows() -> (SidebarStore, a: SidebarWindowID, b: SidebarWindowID, meet: Tab, mail: Tab) {
        let store = SidebarStore()
        let meet = store.addTab(kind: .today, title: "Meet", url: url("meet.test"))
        let mail = store.addTab(kind: .today, title: "Mail", url: url("mail.test"))
        let a = SidebarWindowID(), b = SidebarWindowID()
        store.registerWindow(a)
        store.windowBecameKey(a)
        store.selectTab(meet.id)
        store.registerWindow(b)
        return (store, a, b, meet, mail)
    }

    @Test func eachWindowKeepsItsOwnTab() {
        let (store, a, b, meet, mail) = twoWindows()
        #expect(store.selectedItemID(in: a) == meet.id)
        #expect(store.selectedItemID(in: b) == nil, "a second window on the space does not show the first one's tab")

        store.windowBecameKey(b)
        #expect(store.selectedItemID == nil)
        store.selectTab(mail.id)
        #expect(store.selectedItemID(in: b) == mail.id)
        #expect(store.selectedItemID(in: a) == meet.id, "a selection in one window does not move the other")
        #expect(store.focusedSpaceID(in: a) == store.focusedSpaceID(in: b))

        store.windowBecameKey(a)
        #expect(store.selectedItemID == meet.id, "a window that becomes key brings its own tab back")
        #expect(store.selectedItemID(in: b) == mail.id)
        #expect(store.selectedTab(in: b)?.id == mail.id)
    }

    @Test func choosingTheOtherWindowsTabLeavesItThereWithNothingSelected() {
        let (store, a, b, meet, mail) = twoWindows()
        store.windowBecameKey(b)
        store.selectTab(mail.id)
        store.windowBecameKey(a)
        store.selectTab(mail.id)
        #expect(store.selectedItemID(in: a) == mail.id)
        #expect(store.selectedItemID(in: b) == nil, "the tab moves to the window that chose it")
        #expect(store.focusedSpaceID(in: b) == store.activeSpaceID, "the other window stays on the same space")
        #expect(store.isSelected(mail.id, inSpace: store.activeSpaceID, in: a))
        #expect(!store.isSelected(mail.id, inSpace: store.activeSpaceID, in: b))

        store.windowBecameKey(b)
        #expect(store.selectedItemID == nil, "and stays blank when it is key again")
        #expect(store.selectedItemID(in: a) == mail.id)
        _ = meet
    }

    @Test func aSplitTakesItsPanesFromTheOtherWindow() throws {
        let (store, a, b, meet, mail) = twoWindows()
        store.windowBecameKey(b)
        store.selectTab(mail.id)
        store.windowBecameKey(a)
        let split = try #require(store.createSplit(tabIDs: [meet.id, mail.id], orientation: .horizontal))
        store.selectSplit(split.id)
        #expect(store.selectedItemID(in: b) == nil, "the split shows mail, so the other window lets it go")
    }

    @Test func aClosedTabLeavesTheOtherWindowsSelection() {
        let (store, a, b, meet, mail) = twoWindows()
        store.windowBecameKey(b)
        store.selectTab(mail.id)
        store.windowBecameKey(a)
        store.closeTab(mail.id)
        #expect(store.selectedItemID(in: b) != mail.id)
        #expect(store.selectedItemID(in: b) != store.selectedItemID(in: a) || store.selectedItemID(in: a) == nil)
        _ = meet
    }

    @Test func windowsOnOtherSpacesAreUnchanged() {
        let store = SidebarStore()
        let home = store.activeSpaceID
        let pin = store.addTab(kind: .today, title: "Home tab", url: url("home.test"))
        let work = store.addSpace(name: "Work")
        let a = SidebarWindowID(), b = SidebarWindowID()
        store.registerWindow(a, spaceID: home)
        store.windowBecameKey(a)
        store.selectTab(pin.id)
        store.registerWindow(b, spaceID: work.id)
        store.windowBecameKey(b)
        let workTab = store.addTab(kind: .today, title: "Work tab", url: url("work.test"))
        store.selectTab(workTab.id)
        store.windowBecameKey(a)
        #expect(store.activeSpaceID == home)
        #expect(store.selectedItemID == pin.id)
        #expect(store.selectedItemID(in: b) == workTab.id)
        store.unregisterWindow(b)
        #expect(store.selectionByWindow[b] == nil)
    }
}

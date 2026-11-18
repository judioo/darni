import Foundation
import Testing
@testable import SidebarModel

/// Coming back to a space (a swipe, ⌃1…9, a click on its icon) loads nothing by
/// itself: it shows the tab focused last among the pages still open, else nothing.
@MainActor
struct SpaceReturnSelectionTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    private func makeStore() -> (SidebarStore, personal: Space.ID, work: Space.ID, tick: () -> Void) {
        let personal = Space(name: "Personal", sortRank: "a")
        let work = Space(name: "Work", sortRank: "b")
        let store = SidebarStore(spaces: [personal, work])
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
        store.now = { clock }
        return (store, personal.id, work.id, { clock += 60 })
    }

    @Test func aSpaceWithNothingOpenStaysBlank() {
        let (store, personal, work, _) = makeStore()
        store.selectSpace(work)
        store.addTab(kind: .pinned, title: "Plan", url: url("https://plan.test"))
        store.addTab(kind: .today, title: "Notes", url: url("https://notes.test"))
        store.selectSpace(personal)
        store.isTabOpen = { _ in false }
        store.selectionBySpace = [:]

        store.selectSpace(work)
        #expect(store.selectedItemID == nil, "no pin or tab loads by itself")
    }

    @Test func theRememberedTabComesBackWhileItIsOpen() {
        let (store, personal, work, tick) = makeStore()
        store.selectSpace(work)
        let a = store.addTab(kind: .today, title: "A", url: url("https://a.test"))
        let b = store.addTab(kind: .today, title: "B", url: url("https://b.test"))
        store.selectTab(a.id); tick()
        store.selectTab(b.id); tick()
        store.selectTab(a.id)
        store.isTabOpen = { _ in true }
        store.selectSpace(personal)

        store.selectSpace(work)
        #expect(store.selectedItemID == a.id)
    }

    @Test func anUnloadedRememberedTabGivesWayToTheOpenOneFocusedLast() {
        let (store, personal, work, tick) = makeStore()
        store.selectSpace(work)
        let pin = store.addTab(kind: .pinned, title: "Pin", url: url("https://pin.test"))
        let older = store.addTab(kind: .today, title: "Older", url: url("https://older.test"))
        let newer = store.addTab(kind: .today, title: "Newer", url: url("https://newer.test"))
        let remembered = store.addTab(kind: .today, title: "Gone", url: url("https://gone.test"))
        store.selectTab(newer.id); tick()
        store.selectTab(older.id); tick()
        store.selectTab(remembered.id); tick()
        store.selectSpace(personal)
        store.isTabOpen = { $0 == older.id || $0 == newer.id }

        store.selectSpace(work)
        #expect(store.selectedItemID == older.id, "focused after Newer; Gone was unloaded, Pin never opened")
        #expect(store.selectedItemID != pin.id)
    }

    @Test func anOpenFavoriteFromAnotherSpaceIsNotPicked() {
        let (store, personal, work, tick) = makeStore()
        let favorite = store.addTab(kind: .favorite, title: "Mail", url: url("https://mail.test"))
        store.selectSpace(work)
        let pin = store.addTab(kind: .pinned, title: "Plan", url: url("https://plan.test"))
        store.selectTab(pin.id); tick()
        store.selectSpace(personal)
        store.selectTab(favorite.id); tick()
        store.isTabOpen = { $0 == favorite.id }

        store.selectSpace(work)
        #expect(store.selectedItemID == nil)
    }
}

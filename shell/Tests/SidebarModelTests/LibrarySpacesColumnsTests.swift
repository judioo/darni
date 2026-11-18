import Foundation
import Testing
@testable import SidebarModel

struct LibrarySpacesColumnsTests {
    @Test func columnsFollowProfileAndSpaceOrderAndCountFolderContents() throws {
        let store = SidebarStore(spaces: [Space(name: "One", sortRank: "a"), Space(name: "Two", sortRank: "b")])
        let tab = store.addTab(kind: .pinned, title: "Nested", url: URL(string: "https://example.test")!)
        _ = try #require(store.createFolder(containing: [tab.id]))
        let groups = LibrarySpaces.groups(in: store)
        #expect(groups.count == 1)
        #expect(groups[0].rows.map(\.space.name) == ["One", "Two"])
        #expect(groups[0].rows.map(\.pinnedCount) == [1, 0])
        #expect(LibrarySpacesMotion.duration(opening: true) == 0.08)
        #expect(LibrarySpacesMotion.duration(opening: false) == 0.17)
    }

    /// Arc's move handle: a card dragged by whole card steps lands there, kept
    /// among its profile's spaces, and the cards between make room toward it.
    @Test func aCardDraggedByItsHandleLandsWholeStepsAwayAndTheOthersMakeRoom() {
        let step = LibrarySpaceCards.stride
        #expect(LibrarySpaceCards.destination(from: 1, translation: 0.4 * step, count: 4) == 1, "under half a card stays")
        #expect(LibrarySpaceCards.destination(from: 1, translation: 0.6 * step, count: 4) == 2)
        #expect(LibrarySpaceCards.destination(from: 1, translation: -1.6 * step, count: 4) == 0, "kept at the first place")
        #expect(LibrarySpaceCards.destination(from: 2, translation: 9 * step, count: 4) == 3, "kept at the last place")
        // 0 dragged to 2: 1 and 2 step back; 3 stays.
        #expect((0..<4).map { LibrarySpaceCards.shift(of: $0, dragging: 0, to: 2) } == [0, -1, -1, 0])
        // 3 dragged to 1: 1 and 2 step on; 0 stays.
        #expect((0..<4).map { LibrarySpaceCards.shift(of: $0, dragging: 3, to: 1) } == [0, 1, 1, 0])
    }

    /// The card's Move Left and Move Right, and the Spaces menu's: one place, and nothing at an end.
    @Test func movingASpaceByOnePlaceStopsAtTheEnds() {
        let store = SidebarStore(spaces: [Space(name: "A", sortRank: "a"), Space(name: "B", sortRank: "b"), Space(name: "C", sortRank: "c")])
        let names = { LibrarySpaces.groups(in: store)[0].rows.map(\.space.name) }
        let b = LibrarySpaces.groups(in: store)[0].rows[1].space.id
        #expect(store.moveSpace(b, by: 1))
        #expect(names() == ["A", "C", "B"])
        #expect(!store.moveSpace(b, by: 1), "already last")
        #expect(store.moveSpace(b, by: -1) && store.moveSpace(b, by: -1))
        #expect(names() == ["B", "A", "C"])
        #expect(!store.moveSpace(b, by: -1), "already first")
        #expect(names() == ["B", "A", "C"])
    }

    @Test func movingASpaceToTheHandlesDestinationReordersItsProfile() {
        let store = SidebarStore(spaces: [Space(name: "A", sortRank: "a"), Space(name: "B", sortRank: "b"), Space(name: "C", sortRank: "c")])
        let a = LibrarySpaces.groups(in: store)[0].rows[0].space.id
        let destination = LibrarySpaceCards.destination(from: 0, translation: 2 * LibrarySpaceCards.stride, count: 3)
        #expect(store.moveSpace(a, toIndex: destination))
        #expect(LibrarySpaces.groups(in: store)[0].rows.map(\.space.name) == ["B", "C", "A"])
    }
}

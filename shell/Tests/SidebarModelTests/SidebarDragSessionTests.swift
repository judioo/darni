import XCTest
@testable import SidebarModel

/// The sidebar drag shared by every window, and where its drop lands: which
/// space, which place, whether the rows change profile on the way.
final class SidebarDragSessionTests: XCTestCase {
    private func url(_ host: String) -> URL { URL(string: "https://\(host).test/")! }

    /// Engage (active) with Maps, Docs and Mail in Today, top to bottom;
    /// Personal with Welcome and News. One profile.
    private func makeStore() -> (store: SidebarStore, engage: Space.ID, personal: Space.ID, engageTabs: [Tab], personalTabs: [Tab]) {
        let store = SidebarStore(spaces: [Space(name: "Engage", sortRank: "a")])
        let engage = store.activeSpaceID
        let personal = store.addSpace(name: "Personal").id
        var engageTabs = ["Maps", "Docs", "Mail"].map { store.addTab(kind: .today, title: $0, url: url($0), in: engage) }
        var personalTabs = ["Welcome", "News"].map { store.addTab(kind: .today, title: $0, url: url($0), in: personal) }
        let order = store.outlineOrder(in: engage), other = store.outlineOrder(in: personal)
        engageTabs.sort { order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! }
        personalTabs.sort { other.firstIndex(of: $0.id)! < other.firstIndex(of: $1.id)! }
        return (store, engage, personal, engageTabs, personalTabs)
    }

    private func today(_ store: SidebarStore, _ space: Space.ID) -> [UUID] { store.outline(for: space).today.map(\.id) }
    private func pinned(_ store: SidebarStore, _ space: Space.ID) -> [UUID] { store.outline(for: space).pinned.map(\.id) }

    // MARK: The session

    func testADragShowsInItsOwnWindowAndInAnotherOnceItIsOverIt() {
        let right = SidebarWindowID(), left = SidebarWindowID(), third = SidebarWindowID()
        var drag = SidebarDragSession(itemID: UUID(), sourceWindow: right)
        XCTAssertTrue(drag.began(in: right))
        XCTAssertFalse(drag.began(in: left))
        XCTAssertTrue(drag.isShown(in: right))
        XCTAssertFalse(drag.isShown(in: left), "a drag that stays in its window changes nothing in the others")

        XCTAssertTrue(drag.reach(left), "news the first time")
        XCTAssertFalse(drag.reach(left))
        XCTAssertFalse(drag.reach(right), "its own window is not reached, it began there")
        XCTAssertTrue(drag.isShown(in: left))
        XCTAssertFalse(drag.isShown(in: third))
        XCTAssertFalse(drag.began(in: left), "reaching a window does not make it the source")
        XCTAssertEqual(drag.reached, [left])
    }

    func testAnUnknownWindowIsTheDragsOwn() {
        var bare = SidebarDragSession(itemID: UUID(), sourceWindow: nil)
        let window = SidebarWindowID()
        XCTAssertTrue(bare.began(in: window))
        XCTAssertTrue(bare.isShown(in: window))
        XCTAssertFalse(bare.reach(window))
        let known = SidebarDragSession(itemID: UUID(), sourceWindow: window)
        XCTAssertTrue(known.began(in: nil))
        XCTAssertTrue(known.isShown(in: nil))
    }

    // MARK: Where a drop lands

    func testADropBesideARowOfAnotherSpaceLandsThereAtThatPlace() {
        let f = makeStore()
        let right = SidebarWindowID(), left = SidebarWindowID()
        f.store.registerWindow(right, spaceID: f.engage)
        f.store.registerWindow(left, spaceID: f.personal)
        f.store.windowBecameKey(right)
        let maps = f.engageTabs[0].id, welcome = f.personalTabs[0].id, news = f.personalTabs[1].id

        XCTAssertEqual(f.store.parent(for: .beside(welcome, after: true)), .section(spaceID: f.personal, section: .unpinned))
        XCTAssertEqual(f.store.moveEntries([maps], to: .beside(welcome, after: true)), [maps])
        XCTAssertEqual(today(f.store, f.personal), [welcome, maps, news], "between the two rows it was dropped between")
        XCTAssertEqual(today(f.store, f.engage), [f.engageTabs[1].id, f.engageTabs[2].id])
        XCTAssertEqual(f.store.spaceContaining(tabID: maps), f.personal)
        XCTAssertEqual(f.store.kind(of: maps), .today)
        // The windows keep their spaces: the drop moved a row, not a window.
        XCTAssertEqual(f.store.activeSpaceID, f.engage)
        XCTAssertEqual(f.store.focusedSpaceID(in: right), f.engage)
        XCTAssertEqual(f.store.focusedSpaceID(in: left), f.personal)

        XCTAssertEqual(f.store.moveEntries([f.engageTabs[1].id], to: .beside(welcome, after: false)), [f.engageTabs[1].id])
        XCTAssertEqual(today(f.store, f.personal), [f.engageTabs[1].id, welcome, maps, news], "before the row")
    }

    func testASelectionLandsTogetherInOrder() {
        let f = makeStore()
        let ids = [f.engageTabs[0].id, f.engageTabs[2].id]
        let welcome = f.personalTabs[0].id, news = f.personalTabs[1].id
        XCTAssertEqual(f.store.moveEntries(ids, to: .beside(welcome, after: true)), ids)
        XCTAssertEqual(today(f.store, f.personal), [welcome] + ids + [news])
        XCTAssertEqual(today(f.store, f.engage), [f.engageTabs[1].id])

        // Refused when the target is one of the rows: nothing moves.
        XCTAssertEqual(f.store.moveEntries(ids, to: .beside(ids[0], after: true)), [])
        XCTAssertEqual(today(f.store, f.personal), [welcome] + ids + [news])
    }

    func testDropsAtASectionsEndPinAndUnpinInTheOtherSpace() {
        let f = makeStore()
        let ids = [f.engageTabs[0].id, f.engageTabs[1].id]
        let pinnedEnd = SidebarStore.ItemDestination.section(spaceID: f.personal, section: .pinned)
        XCTAssertEqual(f.store.parent(for: .end(pinnedEnd)), .section(spaceID: f.personal, section: .pinned))
        XCTAssertEqual(f.store.moveEntries(ids, to: .end(pinnedEnd)), ids)
        XCTAssertEqual(pinned(f.store, f.personal), ids, "an empty Pinned takes them, in order")
        XCTAssertEqual(f.store.kind(of: ids[0]), .pinned)

        let todayEnd = SidebarStore.ItemDestination.section(spaceID: f.engage, section: .unpinned)
        XCTAssertEqual(f.store.moveEntries([ids[1]], to: .end(todayEnd)), [ids[1]])
        XCTAssertEqual(today(f.store, f.engage), [f.engageTabs[2].id, ids[1]], "after the section's last row")
        XCTAssertEqual(f.store.kind(of: ids[1]), .today)

        XCTAssertEqual(f.store.moveEntries([f.engageTabs[2].id, ids[1]], to: .at(pinnedEnd, index: 0)), [f.engageTabs[2].id, ids[1]])
        XCTAssertEqual(pinned(f.store, f.personal), [f.engageTabs[2].id, ids[1], ids[0]], "at an index, in order from there")
    }

    func testADropIntoAFolderOfAnotherSpace() throws {
        let f = makeStore()
        let kept = f.store.addTab(kind: .pinned, title: "Kept", url: url("kept"), in: f.personal)
        let folder = try XCTUnwrap(f.store.createFolder(title: "Work", in: f.personal, containing: [kept.id]))
        let ids = [f.engageTabs[0].id, f.engageTabs[1].id]
        XCTAssertEqual(f.store.parent(for: .intoFolder(folder.id)), .folder(folder.id))
        XCTAssertEqual(f.store.spaceID(of: .folder(folder.id)), f.personal)
        XCTAssertEqual(f.store.moveEntries(ids, to: .intoFolder(folder.id)), ids)
        XCTAssertEqual(f.store.folder(withID: folder.id)?.children.map(\.id), [kept.id] + ids, "after the folder's last row")
        XCTAssertEqual(f.store.spaceContaining(tabID: ids[0]), f.personal)
        XCTAssertNil(f.store.parent(for: .intoFolder(UUID())), "a folder that is gone is no place")
        XCTAssertNil(f.store.parent(for: .beside(UUID(), after: true)))
    }

    // MARK: Another profile

    func testOnlyADropIntoAnotherProfileCrossesOne() throws {
        let f = makeStore()
        let work = f.store.addProfile(name: "Work")
        let workSpace = try XCTUnwrap(f.store.spaces(in: work.id).first).id
        let report = f.store.addTab(kind: .today, title: "Report", url: url("report"), in: workSpace)
        let workFolderTab = f.store.addTab(kind: .pinned, title: "Wiki", url: url("wiki"), in: workSpace)
        let workFolder = try XCTUnwrap(f.store.createFolder(title: "Docs", in: workSpace, containing: [workFolderTab.id]))
        let maps = f.engageTabs[0].id
        let personalProfile = try XCTUnwrap(f.store.space(withID: f.engage)?.profileID)

        // One profile: another space, another section, a folder. Nothing to ask.
        XCTAssertFalse(f.store.crossesProfile([maps], to: .section(spaceID: f.personal, section: .unpinned)))
        XCTAssertFalse(f.store.crossesProfile([maps], to: .section(spaceID: f.engage, section: .pinned)))
        XCTAssertFalse(f.store.crossesProfile([maps], to: .favorites(personalProfile)))
        // Another profile's space, folder and favorites.
        XCTAssertTrue(f.store.crossesProfile([maps], to: .section(spaceID: workSpace, section: .unpinned)))
        XCTAssertTrue(f.store.crossesProfile([maps], to: .folder(workFolder.id)))
        XCTAssertTrue(f.store.crossesProfile([maps], to: .favorites(work.id)))
        XCTAssertTrue(f.store.crossesProfile([report.id, maps], to: .section(spaceID: workSpace, section: .unpinned)),
                      "one row of the selection is enough")
        XCTAssertFalse(f.store.crossesProfile([report.id], to: .section(spaceID: workSpace, section: .pinned)))
        // The same answer Move to Space gives for the space.
        XCTAssertEqual(f.store.crossesProfile([maps], to: .section(spaceID: workSpace, section: .unpinned)),
                       f.store.crossesProfile([maps], toSpace: workSpace))

        // A favorite belongs to its profile, wherever its spaces are.
        XCTAssertTrue(f.store.addToFavorites(maps))
        XCTAssertFalse(f.store.crossesProfile([maps], to: .section(spaceID: f.personal, section: .unpinned)))
        XCTAssertTrue(f.store.crossesProfile([maps], to: .section(spaceID: workSpace, section: .unpinned)))
        XCTAssertNil(f.store.spaceID(of: .favorites(work.id)))
    }

    func testAContainersSpaceIsAnotherSession() throws {
        let f = makeStore()
        let container = try XCTUnwrap(f.store.createContainer(forSpace: f.personal))
        XCTAssertEqual(f.store.space(withID: f.personal)?.profileID, container.id)
        XCTAssertTrue(f.store.crossesProfile([f.engageTabs[0].id], to: .section(spaceID: f.personal, section: .unpinned)))
        XCTAssertTrue(f.store.crossesProfile([f.personalTabs[0].id], to: .section(spaceID: f.engage, section: .unpinned)))
    }
}

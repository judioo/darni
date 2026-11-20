import XCTest
@testable import SidebarModel

/// Little Darni's "Open in <Space> ⌘O ⌄": the ⌄ menu lists every other space,
/// in every profile. Owner report 2026-11-20: a link opened from a profile
/// with one space had no ⌄ at all, because the menu listed only that
/// profile's spaces, and the click moved the page into the one space.
final class LittleArcOpenInMenuTests: XCTestCase {
    private typealias Menu = LittleArcOpenInMenu

    private func url(_ host: String) -> URL { URL(string: "https://\(host)/")! }

    /// The owner's sidebar: one profile with many spaces, two with one each.
    private struct Owner {
        let store: SidebarStore
        let akilu: Profile.ID
        let akiluSpaces: [Space]
        let cwc: Profile
        let cwcSpace: Space
        let judioo: Profile
        let judiooSpace: Space
    }

    private func owner() -> Owner {
        let store = SidebarStore(spaces: [Space(name: "Akilu 1")])
        let akilu = store.activeProfileID
        for index in 2...14 { store.addSpace(name: "Akilu \(index)", profileID: akilu) }
        let cwc = store.addProfile(name: "CWC - YAVICA")
        let judioo = store.addProfile(name: "Judioo")
        return Owner(store: store, akilu: akilu, akiluSpaces: store.spaces(in: akilu),
                     cwc: cwc, cwcSpace: store.spaces(in: cwc.id)[0],
                     judioo: judioo, judiooSpace: store.spaces(in: judioo.id)[0])
    }

    // MARK: - One profile

    func testOneProfileWithSeveralSpacesListsTheOthersAsMovesWithNoHeader() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let two = store.addSpace(name: "Two")
        let three = store.addSpace(name: "Three")
        let one = store.spaces[0]
        XCTAssertEqual(store.activeSpaceID, one.id)
        let little = store.createLittleArcWindow(url: url("little.test"))

        XCTAssertEqual(store.littleArcTargetSpace(for: little.id)?.id, one.id)
        let sections = Menu.sections(store: store, windowID: little.id)
        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections[0].header, "one profile: no header to read past")
        XCTAssertEqual(sections[0].profileID, store.activeProfileID)
        XCTAssertEqual(sections[0].entries.map(\.spaceID), [two.id, three.id], "the target is the main button's, not the menu's")
        XCTAssertEqual(sections[0].entries.map(\.title), ["Two", "Three"])
        XCTAssertEqual(sections[0].entries.map(\.kind), [.move, .move])
        XCTAssertEqual(sections[0].entries.map(\.theme), [two.theme, three.theme])
    }

    func testASingleSpaceOverallGivesNoMenu() {
        let store = SidebarStore(spaces: [Space(name: "Only")])
        let little = store.createLittleArcWindow(url: url("little.test"))
        XCTAssertEqual(store.littleArcTargetSpace(for: little.id)?.id, store.spaces[0].id)
        XCTAssertTrue(Menu.sections(store: store, windowID: little.id).isEmpty, "nothing else to open in: the view draws no ⌄")
    }

    func testAWindowThatIsNotOpenHasNoMenu() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        store.addSpace(name: "Two")
        XCTAssertTrue(Menu.sections(store: store, windowID: UUID()).isEmpty)
        let closed = store.createLittleArcWindow(url: url("closed.test"))
        store.archiveLittleArcWindow(id: closed.id, reason: .manual)
        XCTAssertTrue(Menu.sections(store: store, windowID: closed.id).isEmpty)
    }

    // MARK: - The owner's shape

    /// The regression: a window in a one-space profile, while another profile
    /// has fourteen spaces. The menu is not empty, and every space it offers is
    /// in another profile, so each one opens the address afresh.
    func testAWindowInAOneSpaceProfileIsOfferedTheOtherProfilesSpacesAsReopens() {
        let o = owner()
        o.store.selectSpace(o.cwcSpace.id)
        XCTAssertEqual(o.store.activeProfileID, o.cwc.id)
        // As `BrowserViewModel.openLittleArc` makes it: in the active profile.
        let little = o.store.createLittleArcWindow(url: url("link.test"))
        XCTAssertEqual(little.profileID, o.cwc.id)
        XCTAssertEqual(o.store.littleArcTargetSpace(for: little.id)?.id, o.cwcSpace.id)

        let sections = Menu.sections(store: o.store, windowID: little.id)
        XCTAssertFalse(sections.isEmpty, "the ⌄ shows: there are fifteen other spaces")
        XCTAssertEqual(sections.map(\.profileID), [o.akilu, o.judioo.id],
                       "the window's own profile has only the target, so it has no section")
        XCTAssertEqual(sections.map(\.header), ["Personal", "Judioo"].map(Optional.some))
        XCTAssertEqual(sections[0].entries.map(\.spaceID), o.akiluSpaces.map(\.id))
        XCTAssertEqual(sections[0].entries.count, 14)
        XCTAssertEqual(sections[1].entries.map(\.spaceID), [o.judiooSpace.id])
        XCTAssertTrue(sections.flatMap(\.entries).allSatisfy { $0.kind == .reopen },
                      "another profile's space never takes the live page (S-01)")
        XCTAssertFalse(sections.flatMap(\.entries).contains { $0.spaceID == o.cwcSpace.id }, "the target is excluded")
    }

    /// Two profiles, the window's own with only the target: the one section is
    /// another profile's, and it says so.
    func testTheOnlySectionIsNamedWhenItIsAnotherProfiles() {
        let store = SidebarStore(spaces: [Space(name: "Home")])
        let work = store.addProfile(name: "Work")
        let little = store.createLittleArcWindow(url: url("little.test"))
        let sections = Menu.sections(store: store, windowID: little.id)
        XCTAssertEqual(sections.map(\.profileID), [work.id])
        XCTAssertEqual(sections[0].header, "Work")
        XCTAssertEqual(sections[0].entries.map(\.kind), [.reopen])
    }

    // MARK: - Order and sections

    func testTheWindowsOwnProfileComesFirstThenTheOthersInProfileOrder() {
        let o = owner()
        // The browser window is on a CWC space; the Little window belongs to Judioo.
        o.store.selectSpace(o.cwcSpace.id)
        let second = o.store.addSpace(name: "Judioo 2", profileID: o.judioo.id)
        let little = o.store.createLittleArcWindow(url: url("little.test"), profileID: o.judioo.id)
        XCTAssertEqual(o.store.littleArcTargetSpace(for: little.id)?.id, o.judiooSpace.id,
                       "the main button stays in the window's own profile")

        let sections = Menu.sections(store: o.store, windowID: little.id)
        XCTAssertEqual(sections.map(\.profileID), [o.judioo.id, o.akilu, o.cwc.id])
        XCTAssertEqual(sections.map(\.header), ["Judioo", "Personal", "CWC - YAVICA"].map(Optional.some),
                       "more than one profile: each section is named")
        XCTAssertEqual(sections[0].entries.map(\.spaceID), [second.id])
        XCTAssertEqual(sections[0].entries.map(\.kind), [.move])
        XCTAssertEqual(sections[1].entries.map(\.spaceID), o.akiluSpaces.map(\.id), "spaces in the strip's order")
        XCTAssertEqual(sections[2].entries.map(\.spaceID), [o.cwcSpace.id])
        XCTAssertTrue((sections[1].entries + sections[2].entries).allSatisfy { $0.kind == .reopen })
    }

    func testTheTargetIsExcludedWhereverItIs() {
        let o = owner()
        // The active space is in the window's profile: it is the target.
        let active = o.akiluSpaces[4]
        o.store.selectSpace(active.id)
        let little = o.store.createLittleArcWindow(url: url("little.test"))
        XCTAssertEqual(o.store.littleArcTargetSpace(for: little.id)?.id, active.id)
        var entries = Menu.sections(store: o.store, windowID: little.id).flatMap(\.entries)
        XCTAssertFalse(entries.contains { $0.spaceID == active.id })
        XCTAssertEqual(entries.count, 15, "sixteen spaces less the target")

        // The browser window moves to another profile: the target is the window's profile's last space.
        o.store.selectSpace(o.judiooSpace.id)
        XCTAssertEqual(o.store.littleArcTargetSpace(for: little.id)?.id, active.id)
        entries = Menu.sections(store: o.store, windowID: little.id).flatMap(\.entries)
        XCTAssertFalse(entries.contains { $0.spaceID == active.id })
        XCTAssertEqual(entries.first { $0.spaceID == o.judiooSpace.id }?.kind, .reopen)
        XCTAssertEqual(entries.first { $0.spaceID == o.akiluSpaces[0].id }?.kind, .move)
    }

    func testArchivedSpacesAreNotOffered() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let two = store.addSpace(name: "Two")
        let three = store.addSpace(name: "Three")
        let little = store.createLittleArcWindow(url: url("little.test"))
        XCTAssertNil(store.archiveSpace(three.id))
        XCTAssertEqual(Menu.sections(store: store, windowID: little.id).flatMap(\.entries).map(\.spaceID), [two.id])
        XCTAssertNil(Menu.kind(store: store, windowID: little.id, spaceID: three.id))
    }

    // MARK: - Containers

    /// A container's space is listed under its profile and is another
    /// session: it is offered there, marked, and never takes the live page.
    func testAContainersSpaceIsListedUnderItsProfileAndReopens() throws {
        let store = SidebarStore(spaces: [Space(name: "Home")])
        let personal = store.activeProfileID
        let plain = store.addSpace(name: "Plain")
        let client = store.addSpace(name: "Client")
        let container = try XCTUnwrap(store.createContainer(forSpace: client.id))
        XCTAssertEqual(store.activeSpaceID, store.spaces[0].id)

        let little = store.createLittleArcWindow(url: url("little.test"))
        var sections = Menu.sections(store: store, windowID: little.id)
        XCTAssertEqual(sections.map(\.profileID), [personal], "a container is not a profile of its own")
        XCTAssertNil(sections[0].header)
        XCTAssertEqual(sections[0].entries.map(\.title), ["Plain", "Client (Container)"])
        XCTAssertEqual(sections[0].entries.map(\.kind), [.move, .reopen])

        // A window in the container: its parent's spaces are another session.
        let inside = store.createLittleArcWindow(url: url("inside.test"), profileID: container.id)
        XCTAssertEqual(store.littleArcTargetSpace(for: inside.id)?.id, client.id)
        sections = Menu.sections(store: store, windowID: inside.id)
        XCTAssertEqual(sections.map(\.profileID), [personal])
        XCTAssertEqual(sections[0].entries.map(\.spaceID), [store.spaces[0].id, plain.id])
        XCTAssertEqual(sections[0].entries.map(\.kind), [.reopen, .reopen])
    }

    // MARK: - What a choice does

    func testKindFollowsStorage() {
        let o = owner()
        let little = o.store.createLittleArcWindow(url: url("little.test"), profileID: o.cwc.id)
        XCTAssertEqual(Menu.kind(store: o.store, windowID: little.id, spaceID: o.cwcSpace.id), .move)
        XCTAssertEqual(Menu.kind(store: o.store, windowID: little.id, spaceID: o.akiluSpaces[3].id), .reopen)
        XCTAssertNil(Menu.kind(store: o.store, windowID: little.id, spaceID: UUID()), "a space that is gone")
        XCTAssertNil(Menu.kind(store: o.store, windowID: UUID(), spaceID: o.cwcSpace.id), "a window that is gone")
    }

    /// The store's side of `.reopen`: a tab with the address in the chosen
    /// space, that space shown, and the window's record gone as after a promote.
    func testReopenMakesATabWithTheAddressInTheOtherProfilesSpace() throws {
        let o = owner()
        o.store.selectSpace(o.cwcSpace.id)
        let address = URL(string: "https://link.test/path?q=1")!
        let little = o.store.createLittleArcWindow(url: address, title: "Signed in as someone")
        let destination = o.akiluSpaces[6]

        let tab = try XCTUnwrap(o.store.reopenLittleArcAsTab(id: little.id, in: destination.id))
        XCTAssertEqual(tab.url, address)
        XCTAssertEqual(tab.title, "link.test", "the title the page had in the window's session stays behind")
        XCTAssertEqual(o.store.spaceContaining(tabID: tab.id), destination.id)
        XCTAssertEqual(o.store.content(for: destination.id).today.map(\.id), [tab.id])
        XCTAssertEqual(o.store.activeSpaceID, destination.id)
        XCTAssertEqual(o.store.activeProfileID, o.akilu)
        XCTAssertEqual(o.store.selectedTab?.id, tab.id)
        XCTAssertTrue(o.store.content(for: o.cwcSpace.id).today.isEmpty, "nothing lands in the window's own profile")
        XCTAssertNil(o.store.littleArcWindow(withID: little.id))
        XCTAssertFalse(o.store.littleArcArchivedWindows.contains { $0.id == little.id },
                       "removed as a promote removes it: the tab is the page's record")
    }

    func testReopenRefusesTheWindowsOwnSessionAndSpacesThatCannotBeShown() {
        let o = owner()
        let little = o.store.createLittleArcWindow(url: url("little.test"), profileID: o.cwc.id)
        let before = o.store.makeSnapshot()

        XCTAssertNil(o.store.reopenLittleArcAsTab(id: little.id, in: o.cwcSpace.id), "its own session: the page moves instead")
        XCTAssertNil(o.store.reopenLittleArcAsTab(id: little.id, in: UUID()))
        XCTAssertNil(o.store.reopenLittleArcAsTab(id: UUID(), in: o.akiluSpaces[0].id))
        XCTAssertNil(o.store.archiveSpace(o.judiooSpace.id))
        let archived = o.store.makeSnapshot()
        XCTAssertNil(o.store.reopenLittleArcAsTab(id: little.id, in: o.judiooSpace.id), "an archived space waits for Restore")

        XCTAssertNotNil(o.store.littleArcWindow(withID: little.id), "the window is still open")
        XCTAssertEqual(before.littleArcWindows, archived.littleArcWindows)
        XCTAssertEqual(o.store.makeSnapshot().spaces.map(\.id), archived.spaces.map(\.id))
        XCTAssertTrue(o.store.spaces.allSatisfy { o.store.content(for: $0.id).today.isEmpty }, "no tab was made anywhere")
    }

    /// The main button is unchanged: a promote never follows a space of
    /// another session, whatever it is handed.
    func testPromoteStillNeverLeavesTheWindowsSession() throws {
        let o = owner()
        o.store.selectSpace(o.akiluSpaces[2].id)
        let little = o.store.createLittleArcWindow(url: url("little.test"), profileID: o.cwc.id)
        let tab = try XCTUnwrap(o.store.promoteLittleArcToTab(id: little.id, into: o.akiluSpaces[5].id))
        XCTAssertEqual(o.store.spaceContaining(tabID: tab.id), o.cwcSpace.id)
        XCTAssertEqual(o.store.activeProfileID, o.cwc.id)
    }
}

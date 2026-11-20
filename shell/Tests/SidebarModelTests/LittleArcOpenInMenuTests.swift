import XCTest
@testable import SidebarModel

/// Little Darni's "Open in <Space> ⌘O ⌄": the ⌄ picker lists every space, in
/// every profile, the main button's target among them, as Arc's does. Owner
/// report 2026-11-20: a link opened from a profile with one space had no ⌄ at
/// all, because the menu listed only that profile's spaces, and the click
/// moved the page into the one space. The target is the space of the last
/// focused browser window, whatever its profile.
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

    func testOneProfileWithSeveralSpacesListsThemAllAsMovesWithNoHeader() {
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
        XCTAssertEqual(sections[0].entries.map(\.spaceID), [one.id, two.id, three.id], "every space is a row, as in Arc")
        XCTAssertEqual(sections[0].entries.map(\.title), ["One", "Two", "Three"])
        XCTAssertEqual(sections[0].entries.map(\.kind), [.move, .move, .move])
        XCTAssertEqual(sections[0].entries.map(\.theme), [one.theme, two.theme, three.theme])
        XCTAssertEqual(sections[0].entries.map(\.isTarget), [true, false, false], "the main button's space is marked")
    }

    /// One space in all: the picker is still there, with that one row.
    func testASingleSpaceOverallIsStillARow() {
        let store = SidebarStore(spaces: [Space(name: "Only")])
        let little = store.createLittleArcWindow(url: url("little.test"))
        XCTAssertEqual(store.littleArcTargetSpace(for: little.id)?.id, store.spaces[0].id)
        let sections = Menu.sections(store: store, windowID: little.id)
        XCTAssertEqual(sections.map(\.header), [nil])
        XCTAssertEqual(sections[0].entries.map(\.spaceID), [store.spaces[0].id])
        XCTAssertEqual(sections[0].entries.map(\.kind), [.move])
        XCTAssertEqual(sections[0].entries.map(\.isTarget), [true])
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
    /// has fourteen spaces. Its own space is one row, and every other space
    /// the picker offers is in another profile, so each one opens the address afresh.
    func testAWindowInAOneSpaceProfileIsOfferedTheOtherProfilesSpacesAsReopens() {
        let o = owner()
        o.store.selectSpace(o.cwcSpace.id)
        XCTAssertEqual(o.store.activeProfileID, o.cwc.id)
        // As `BrowserViewModel.openLittleArc` makes it: in the active profile.
        let little = o.store.createLittleArcWindow(url: url("link.test"))
        XCTAssertEqual(little.profileID, o.cwc.id)
        XCTAssertEqual(o.store.littleArcTargetSpace(for: little.id)?.id, o.cwcSpace.id)

        let sections = Menu.sections(store: o.store, windowID: little.id)
        XCTAssertEqual(sections.map(\.profileID), [o.cwc.id, o.akilu, o.judioo.id], "the window's own profile first")
        XCTAssertEqual(sections.map(\.header), ["CWC - YAVICA", "Personal", "Judioo"].map(Optional.some))
        XCTAssertEqual(sections[0].entries.map(\.spaceID), [o.cwcSpace.id])
        XCTAssertEqual(sections[0].entries.map(\.kind), [.move])
        XCTAssertEqual(sections[0].entries.map(\.isTarget), [true])
        XCTAssertEqual(sections[1].entries.map(\.spaceID), o.akiluSpaces.map(\.id))
        XCTAssertEqual(sections[1].entries.count, 14)
        XCTAssertEqual(sections[2].entries.map(\.spaceID), [o.judiooSpace.id])
        XCTAssertTrue((sections[1].entries + sections[2].entries).allSatisfy { $0.kind == .reopen && !$0.isTarget },
                      "another profile's space never takes the live page (S-01)")
    }

    /// Two profiles: each section is named, the window's own too.
    func testTwoProfilesAreBothNamed() {
        let store = SidebarStore(spaces: [Space(name: "Home")])
        let personal = store.activeProfileID
        let work = store.addProfile(name: "Work")
        let little = store.createLittleArcWindow(url: url("little.test"))
        let sections = Menu.sections(store: store, windowID: little.id)
        XCTAssertEqual(sections.map(\.profileID), [personal, work.id])
        XCTAssertEqual(sections.map(\.header), ["Personal", "Work"].map(Optional.some))
        XCTAssertEqual(sections.map { $0.entries.map(\.kind) }, [[.move], [.reopen]])
    }

    /// The window's own profile has no space left to show: the one section is
    /// another profile's, and it says so.
    func testTheOnlySectionIsNamedWhenItIsAnotherProfiles() throws {
        let store = SidebarStore(spaces: [Space(name: "Home")])
        let work = store.addProfile(name: "Work")
        let little = store.createLittleArcWindow(url: url("little.test"))
        XCTAssertNil(store.archiveSpace(store.spaces[0].id))
        let workSpace = try XCTUnwrap(store.spaces(in: work.id).first)
        XCTAssertEqual(store.littleArcTargetSpace(for: little.id)?.id, workSpace.id, "the browser window is on the other profile now")
        let sections = Menu.sections(store: store, windowID: little.id)
        XCTAssertEqual(sections.map(\.profileID), [work.id])
        XCTAssertEqual(sections[0].header, "Work")
        XCTAssertEqual(sections[0].entries.map(\.kind), [.reopen])
        XCTAssertEqual(sections[0].entries.map(\.isTarget), [true])
    }

    // MARK: - Order and sections

    func testTheWindowsOwnProfileComesFirstThenTheOthersInProfileOrder() {
        let o = owner()
        // The browser window is on a CWC space; the Little window belongs to Judioo.
        o.store.selectSpace(o.cwcSpace.id)
        let second = o.store.addSpace(name: "Judioo 2", profileID: o.judioo.id)
        let little = o.store.createLittleArcWindow(url: url("little.test"), profileID: o.judioo.id)
        XCTAssertEqual(o.store.littleArcTargetSpace(for: little.id)?.id, o.cwcSpace.id,
                       "the main button follows the browser window, into another profile too")

        let sections = Menu.sections(store: o.store, windowID: little.id)
        XCTAssertEqual(sections.map(\.profileID), [o.judioo.id, o.akilu, o.cwc.id])
        XCTAssertEqual(sections.map(\.header), ["Judioo", "Personal", "CWC - YAVICA"].map(Optional.some),
                       "more than one profile: each section is named")
        XCTAssertEqual(sections[0].entries.map(\.spaceID), [o.judiooSpace.id, second.id])
        XCTAssertEqual(sections[0].entries.map(\.kind), [.move, .move])
        XCTAssertEqual(sections[1].entries.map(\.spaceID), o.akiluSpaces.map(\.id), "spaces in the strip's order")
        XCTAssertEqual(sections[2].entries.map(\.spaceID), [o.cwcSpace.id])
        XCTAssertTrue((sections[1].entries + sections[2].entries).allSatisfy { $0.kind == .reopen })
        XCTAssertEqual(sections.flatMap(\.entries).filter(\.isTarget).map(\.spaceID), [o.cwcSpace.id],
                       "the target is a row of another profile here, and it reopens")
    }

    func testTheTargetIsARowWhereverItIs() {
        let o = owner()
        // The active space is in the window's profile: it is the target, and the page moves there.
        let active = o.akiluSpaces[4]
        o.store.selectSpace(active.id)
        let little = o.store.createLittleArcWindow(url: url("little.test"))
        XCTAssertEqual(o.store.littleArcTargetSpace(for: little.id)?.id, active.id)
        var entries = Menu.sections(store: o.store, windowID: little.id).flatMap(\.entries)
        XCTAssertEqual(entries.count, 16, "all sixteen spaces")
        XCTAssertEqual(entries.filter(\.isTarget).map(\.spaceID), [active.id])
        XCTAssertEqual(entries.first { $0.isTarget }?.kind, .move)

        // The browser window moves to another profile: the target goes with it.
        o.store.selectSpace(o.judiooSpace.id)
        XCTAssertEqual(o.store.littleArcTargetSpace(for: little.id)?.id, o.judiooSpace.id)
        entries = Menu.sections(store: o.store, windowID: little.id).flatMap(\.entries)
        XCTAssertEqual(entries.count, 16)
        XCTAssertEqual(entries.filter(\.isTarget).map(\.spaceID), [o.judiooSpace.id])
        XCTAssertEqual(entries.first { $0.isTarget }?.kind, .reopen, "another profile's: the address opens afresh, after the question")
        XCTAssertEqual(entries.first { $0.spaceID == active.id }?.kind, .move)
    }

    // MARK: - The target follows the focused browser window

    /// Arc: focus a browser window, or change its space, and Open in names
    /// that space at once, whatever its profile. A Little window never
    /// becomes the key browser window, so its own focus changes nothing.
    func testTheTargetFollowsTheKeyWindowAndItsSpaceIntoAnotherProfile() {
        let o = owner()
        let first = SidebarWindowID(), second = SidebarWindowID()
        o.store.registerWindow(first, spaceID: o.akiluSpaces[2].id)
        o.store.registerWindow(second, spaceID: o.judiooSpace.id)
        o.store.windowBecameKey(first)
        let little = o.store.createLittleArcWindow(url: url("little.test"), profileID: o.akilu)
        func target() -> Space.ID? { o.store.littleArcTargetSpace(for: little.id)?.id }
        func choice() -> Menu.Choice? {
            target().flatMap { Menu.choice(store: o.store, windowID: little.id, spaceID: $0, url: little.url) }
        }

        XCTAssertEqual(target(), o.akiluSpaces[2].id)
        XCTAssertEqual(choice(), .move, "its own session: the page moves")

        // Another browser window, on another profile's space, takes focus.
        o.store.windowBecameKey(second)
        XCTAssertEqual(target(), o.judiooSpace.id)
        XCTAssertEqual(choice(), .ask(Menu.Question(windowID: little.id, spaceID: o.judiooSpace.id, url: little.url, host: "little.test")),
                       "another session: the question first (OI-01)")

        // That window changes to a third profile's space: the target changes with it.
        o.store.selectSpace(o.cwcSpace.id)
        XCTAssertEqual(o.store.focusedSpaceID(in: second), o.cwcSpace.id)
        XCTAssertEqual(target(), o.cwcSpace.id)
        XCTAssertEqual(o.store.littleArcTargetSpace(for: little.id)?.theme, o.cwcSpace.theme, "the toolbar's tint is this space's")
        guard case .ask(let question)? = choice() else { return XCTFail("a third profile's space asks too") }
        XCTAssertEqual(question.spaceID, o.cwcSpace.id)

        // And back to a space of the window's own profile, in the same browser window.
        o.store.selectSpace(o.akiluSpaces[7].id)
        XCTAssertEqual(target(), o.akiluSpaces[7].id)
        XCTAssertEqual(choice(), .move)

        // The first window again: its own space, as it left it.
        o.store.windowBecameKey(first)
        XCTAssertEqual(target(), o.akiluSpaces[2].id)
    }

    /// A page that is not a web page is refused by the target as by any row,
    /// when the target is another session.
    func testTheTargetRefusesAPageThatCannotCrossSessions() throws {
        let o = owner()
        o.store.selectSpace(o.judiooSpace.id)
        let blank = o.store.createLittleArcWindow(url: try XCTUnwrap(URL(string: "about:blank")), profileID: o.akilu)
        let target = try XCTUnwrap(o.store.littleArcTargetSpace(for: blank.id))
        XCTAssertEqual(target.id, o.judiooSpace.id)
        XCTAssertEqual(Menu.choice(store: o.store, windowID: blank.id, spaceID: target.id, url: blank.url), .refuse)
        let row = try XCTUnwrap(Menu.sections(store: o.store, windowID: blank.id).flatMap(\.entries).first { $0.isTarget })
        XCTAssertFalse(row.isEnabled)
        o.store.selectSpace(o.akiluSpaces[1].id)
        XCTAssertEqual(Menu.choice(store: o.store, windowID: blank.id, spaceID: o.akiluSpaces[1].id, url: blank.url), .move,
                       "back in its own session a blank page still moves")
    }

    /// A window in the archive has the same target, and no window has none.
    func testAnArchivedWindowStillHasATarget() {
        let o = owner()
        let little = o.store.createLittleArcWindow(url: url("little.test"), profileID: o.cwc.id)
        o.store.archiveLittleArcWindow(id: little.id, reason: .manual)
        XCTAssertEqual(o.store.littleArcTargetSpace(for: little.id)?.id, o.store.activeSpaceID)
        XCTAssertNil(o.store.littleArcTargetSpace(for: UUID()), "no such window, no target")
    }

    func testArchivedSpacesAreNotOffered() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let two = store.addSpace(name: "Two")
        let three = store.addSpace(name: "Three")
        let little = store.createLittleArcWindow(url: url("little.test"))
        XCTAssertNil(store.archiveSpace(three.id))
        XCTAssertEqual(Menu.sections(store: store, windowID: little.id).flatMap(\.entries).map(\.spaceID), [store.spaces[0].id, two.id])
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
        XCTAssertEqual(sections[0].entries.map(\.title), ["Home", "Plain", "Client (Container)"])
        XCTAssertEqual(sections[0].entries.map(\.kind), [.move, .move, .reopen])

        // A window in the container: its own space first, alone, and its
        // parent's spaces after it, all another session.
        let inside = store.createLittleArcWindow(url: url("inside.test"), profileID: container.id)
        XCTAssertEqual(store.littleArcTargetSpace(for: inside.id)?.id, store.spaces[0].id,
                       "the browser window is on Home: that is the target, outside the container")
        sections = Menu.sections(store: store, windowID: inside.id)
        XCTAssertEqual(sections.map(\.profileID), [container.id, personal])
        XCTAssertEqual(sections.map(\.header), ["This container", "Personal (outside this container)"].map(Optional.some),
                       "its profile's other spaces are another session, and the header says so (OI-01)")
        XCTAssertEqual(sections[0].entries.map(\.spaceID), [client.id])
        XCTAssertEqual(sections[0].entries.map(\.title), ["Client (Container)"])
        XCTAssertEqual(sections[0].entries.map(\.kind), [.move], "the one row that keeps the page and its sign-ins")
        XCTAssertEqual(sections[1].entries.map(\.spaceID), [store.spaces[0].id, plain.id])
        XCTAssertEqual(sections[1].entries.map(\.kind), [.reopen, .reopen])
        XCTAssertEqual(sections[1].entries.map(\.isTarget), [true, false])
        XCTAssertEqual(Menu.thisContainerHeader, "This container")

        // The browser window goes to the container's space: the target is the window's own session again.
        store.selectSpace(client.id)
        XCTAssertEqual(store.littleArcTargetSpace(for: inside.id)?.id, client.id)
        XCTAssertEqual(Menu.choice(store: store, windowID: inside.id, spaceID: client.id, url: inside.url), .move)
        // And from the profile's own window that same target is the container: it asks.
        guard case .ask? = Menu.choice(store: store, windowID: little.id, spaceID: client.id, url: little.url) else {
            return XCTFail("a container's space is another session for its profile's window")
        }
    }

    /// From a container's window every other space of its profile is another
    /// session. The section says so, with or without other profiles, and
    /// another container there keeps its own mark.
    func testFromAContainersWindowItsProfilesSpacesAreMarkedAsOutsideIt() throws {
        let store = SidebarStore(spaces: [Space(name: "Home")])
        let personal = store.activeProfileID
        let client = store.addSpace(name: "Client")
        let bank = store.addSpace(name: "Bank")
        let container = try XCTUnwrap(store.createContainer(forSpace: client.id))
        XCTAssertNotNil(store.createContainer(forSpace: bank.id))
        let work = store.addProfile(name: "Work")
        let inside = store.createLittleArcWindow(url: url("inside.test"), profileID: container.id)

        let sections = Menu.sections(store: store, windowID: inside.id)
        XCTAssertEqual(sections.map(\.profileID), [container.id, personal, work.id])
        XCTAssertEqual(sections.map(\.header), ["This container", "Personal (outside this container)", "Work"].map(Optional.some))
        XCTAssertEqual(sections[0].entries.map(\.title), ["Client (Container)"])
        XCTAssertEqual(sections[1].entries.map(\.title), ["Home", "Bank (Container)"])
        XCTAssertTrue(sections.dropFirst().flatMap(\.entries).allSatisfy { $0.kind == .reopen },
                      "nothing under the other headers is the container's own session")
        XCTAssertEqual(sections.flatMap(\.entries).filter { $0.kind == .move }.map(\.spaceID), [client.id])

        // The same profile seen from its own window: its name, when it is named at all.
        let outside = store.createLittleArcWindow(url: url("outside.test"), profileID: personal)
        XCTAssertEqual(Menu.sections(store: store, windowID: outside.id).map(\.header), ["Personal", "Work"].map(Optional.some))
        XCTAssertEqual(Menu.outsideContainerHeader("Personal"), "Personal (outside this container)")
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

    /// The store's promote never follows a space of another session,
    /// whatever it is handed: the main button reaches one only through
    /// `choice`, as a `.reopen`.
    func testPromoteStillNeverLeavesTheWindowsSession() throws {
        let o = owner()
        o.store.selectSpace(o.akiluSpaces[2].id)
        let little = o.store.createLittleArcWindow(url: url("little.test"), profileID: o.cwc.id)
        let tab = try XCTUnwrap(o.store.promoteLittleArcToTab(id: little.id, into: o.akiluSpaces[5].id))
        XCTAssertEqual(o.store.spaceContaining(tabID: tab.id), o.cwcSpace.id)
        XCTAssertEqual(o.store.activeProfileID, o.cwc.id)
    }

    // MARK: - Only web addresses cross sessions (OI-02)

    func testOnlyWebAddressesCrossSessions() throws {
        for address in ["https://example.test/", "http://example.test/path?q=1#top", "HTTPS://EXAMPLE.TEST/", "https://example.test:8443/"] {
            XCTAssertTrue(Menu.canCrossSessions(try XCTUnwrap(URL(string: address))), address)
        }
        for address in ["file:///Users/someone/secret.html", "data:text/html,<p>page</p>", "blob:https://example.test/0b5e-11",
                        "chrome-extension://abcdefghijklmnopabcdefghijklmnop/popup.html", "rearc://settings", "chrome://settings",
                        "about:blank", "view-source:https://example.test/", "javascript:alert(1)", "ftp://example.test/file",
                        "https://user:secret@example.test/", "https:///no-host"] {
            XCTAssertFalse(Menu.canCrossSessions(try XCTUnwrap(URL(string: address))), address)
        }
    }

    /// A `.reopen` needs the question and a `.move` never does. The question
    /// carries the address it was put with.
    func testAReopenAsksAndAMoveDoesNot() {
        let o = owner()
        let second = o.store.addSpace(name: "CWC 2", profileID: o.cwc.id)
        let little = o.store.createLittleArcWindow(url: url("record.test"), profileID: o.cwc.id)
        let shown = URL(string: "https://mail.example.test/reset?token=1")!

        XCTAssertEqual(Menu.choice(store: o.store, windowID: little.id, spaceID: second.id, url: shown), .move)
        XCTAssertEqual(Menu.choice(store: o.store, windowID: little.id, spaceID: o.akiluSpaces[3].id, url: shown),
                       .ask(Menu.Question(windowID: little.id, spaceID: o.akiluSpaces[3].id, url: shown, host: "mail.example.test")),
                       "the address the window shows, not its record's")
        XCTAssertNil(Menu.choice(store: o.store, windowID: little.id, spaceID: UUID(), url: shown))
        XCTAssertNil(Menu.choice(store: o.store, windowID: UUID(), spaceID: second.id, url: shown))
        XCTAssertNotNil(o.store.littleArcWindow(withID: little.id), "asking changes nothing")
    }

    /// A long host in the question keeps the site's own name, as other trusted UI shows it.
    func testTheQuestionsHostKeepsTheSitesOwnName() throws {
        let o = owner()
        let little = o.store.createLittleArcWindow(url: url("record.test"), profileID: o.cwc.id)
        let long = try XCTUnwrap(URL(string: "https://accounts.google.com.verify-session.evil.example/login"))
        guard case .ask(let question)? = Menu.choice(store: o.store, windowID: little.id, spaceID: o.judiooSpace.id, url: long) else {
            return XCTFail("a web address to another profile asks")
        }
        XCTAssertEqual(question.url, long)
        XCTAssertEqual(question.host, PageOrigin.shortenedHost("accounts.google.com.verify-session.evil.example"))
        XCTAssertTrue(question.host.hasSuffix("evil.example"))
    }

    /// Anything but a web address is refused across sessions, and still moves
    /// within the window's own session: there the page itself goes.
    func testOtherAddressesAreRefusedAcrossSessionsAndStillMoveWithinOne() throws {
        let o = owner()
        let second = o.store.addSpace(name: "CWC 2", profileID: o.cwc.id)
        let little = o.store.createLittleArcWindow(url: url("record.test"), profileID: o.cwc.id)
        for address in ["file:///tmp/page.html", "data:text/html,hello", "blob:https://example.test/1", "about:blank",
                        "chrome-extension://abcdefghijklmnopabcdefghijklmnop/page.html", "rearc://settings"] {
            let shown = try XCTUnwrap(URL(string: address))
            XCTAssertEqual(Menu.choice(store: o.store, windowID: little.id, spaceID: o.akiluSpaces[0].id, url: shown), .refuse, address)
            XCTAssertEqual(Menu.choice(store: o.store, windowID: little.id, spaceID: second.id, url: shown), .move, address)
        }
    }

    /// The menu for a window that shows no web address: the rows that would
    /// cross are disabled, the rows of its own session are not, and the menu
    /// says why.
    func testRowsThatCannotCrossAreDisabledWithAReason() throws {
        let o = owner()
        let second = o.store.addSpace(name: "CWC 2", profileID: o.cwc.id)
        let little = o.store.createLittleArcWindow(url: url("record.test"), profileID: o.cwc.id)

        // A web address: every row is enabled and there is nothing to explain.
        var sections = Menu.sections(store: o.store, windowID: little.id)
        XCTAssertTrue(sections.flatMap(\.entries).allSatisfy(\.isEnabled), "the record's address when none is handed in")
        XCTAssertNil(Menu.note(for: sections))

        let local = try XCTUnwrap(URL(string: "file:///tmp/page.html"))
        sections = Menu.sections(store: o.store, windowID: little.id, url: local)
        let entries = sections.flatMap(\.entries)
        XCTAssertEqual(entries.count, 17, "the rows are all still listed")
        XCTAssertEqual(entries.filter(\.isEnabled).map(\.spaceID), [o.cwcSpace.id, second.id], "only the window's own session")
        XCTAssertTrue(entries.filter { !$0.isEnabled }.allSatisfy { $0.kind == .reopen })
        XCTAssertEqual(Menu.note(for: sections), "Only web pages can open in another profile or container")
        XCTAssertEqual(Menu.note(for: sections), Menu.webOnlyMessage)

        // The record's own address decides when none is handed in.
        let blank = o.store.createLittleArcWindow(url: try XCTUnwrap(URL(string: "about:blank")), profileID: o.cwc.id)
        XCTAssertFalse(Menu.sections(store: o.store, windowID: blank.id).flatMap(\.entries).contains { $0.kind == .reopen && $0.isEnabled })
    }

    /// The store opens the address it is handed (the one the person was asked
    /// about), and refuses one that is not a web address whoever asks.
    func testReopenOpensTheAddressItIsHandedAndOnlyAWebAddress() throws {
        let o = owner()
        o.store.selectSpace(o.cwcSpace.id)
        let little = o.store.createLittleArcWindow(url: url("later.test"), title: "Later")
        let asked = try XCTUnwrap(URL(string: "https://asked.test/page"))
        let before = o.store.makeSnapshot()

        for address in ["data:text/html,hello", "file:///tmp/page.html", "blob:https://asked.test/1"] {
            XCTAssertNil(o.store.reopenLittleArcAsTab(id: little.id, in: o.akiluSpaces[1].id, url: try XCTUnwrap(URL(string: address))), address)
        }
        XCTAssertEqual(o.store.makeSnapshot().littleArcWindows, before.littleArcWindows, "the window is still open")
        XCTAssertEqual(o.store.activeSpaceID, o.cwcSpace.id)
        XCTAssertTrue(o.store.spaces.allSatisfy { o.store.content(for: $0.id).today.isEmpty }, "no tab was made anywhere")

        let tab = try XCTUnwrap(o.store.reopenLittleArcAsTab(id: little.id, in: o.akiluSpaces[1].id, url: asked))
        XCTAssertEqual(tab.url, asked, "not the record's address")
        XCTAssertEqual(tab.title, "asked.test")
        XCTAssertNil(o.store.littleArcWindow(withID: little.id))

        // A record whose own address is not a web address stays where it is.
        let local = o.store.createLittleArcWindow(url: try XCTUnwrap(URL(string: "file:///tmp/page.html")), profileID: o.cwc.id)
        XCTAssertNil(o.store.reopenLittleArcAsTab(id: local.id, in: o.akiluSpaces[2].id))
        XCTAssertNotNil(o.store.littleArcWindow(withID: local.id))
        XCTAssertNotNil(o.store.promoteLittleArcToTab(id: local.id), "its own session still takes it")
    }
}

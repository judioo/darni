import XCTest
@testable import SidebarModel

/// Little Darni's space picker (Arc's "Search Spaces…" panel under Open in ⌄):
/// what it lists for what is typed, and which row the keys act on.
final class LittleArcSpacePickerTests: XCTestCase {
    private typealias Picker = LittleArcSpacePicker
    private typealias Menu = LittleArcOpenInMenu

    private func url(_ host: String) -> URL { URL(string: "https://\(host)/")! }

    /// Personal with Blogging, Personal and Imara; Work with Clients and Café.
    private struct Fixture {
        let store: SidebarStore
        let little: LittleArcWindow
        let personal: [Space]
        let work: Profile
        let workSpaces: [Space]
        var sections: [Menu.Section] { Menu.sections(store: store, windowID: little.id) }
    }

    private func fixture(url address: String = "https://little.test/") -> Fixture {
        let store = SidebarStore(spaces: [Space(name: "Blogging")])
        let personal = store.activeProfileID
        store.addSpace(name: "Personal", profileID: personal)
        store.addSpace(name: "Imara", profileID: personal)
        let work = store.addProfile(name: "Work")
        store.renameSpace(store.spaces(in: work.id)[0].id, to: "Clients")
        store.addSpace(name: "Café", profileID: work.id)
        let little = store.createLittleArcWindow(url: URL(string: address)!, profileID: personal)
        return Fixture(store: store, little: little, personal: store.spaces(in: personal), work: work, workSpaces: store.spaces(in: work.id))
    }

    private func titles(_ rows: [Picker.Row]) -> [String] {
        rows.map {
            switch $0 {
            case .header(_, let title): return "# \(title)"
            case .space(let entry): return entry.title
            case .note(let text): return "! \(text)"
            case .empty(let text): return "~ \(text)"
            }
        }
    }

    // MARK: - Rows

    func testEverySpaceIsARowUnderItsProfilesHeader() {
        let f = fixture()
        XCTAssertEqual(titles(Picker.rows(for: f.sections)),
                       ["# Personal", "Blogging", "Personal", "Imara", "# Work", "Clients", "Café"])
        XCTAssertEqual(Picker.placeholder, "Search Spaces…")
    }

    func testOneProfileHasNoHeader() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        store.addSpace(name: "Two")
        let little = store.createLittleArcWindow(url: url("little.test"))
        XCTAssertEqual(titles(Picker.rows(for: Menu.sections(store: store, windowID: little.id))), ["One", "Two"])
    }

    func testRowIdsAreStableAndDistinct() {
        let f = fixture()
        let rows = Picker.rows(for: f.sections)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertEqual(rows[1].id, Picker.Row.id(forSpace: f.personal[0].id))
    }

    // MARK: - Search

    func testTypingFiltersWhateverTheCaseOrAccents() {
        let f = fixture()
        XCTAssertEqual(titles(Picker.rows(for: f.sections, query: "blog")), ["# Personal", "Blogging"])
        XCTAssertEqual(titles(Picker.rows(for: f.sections, query: "IMA")), ["# Personal", "Imara"])
        XCTAssertEqual(titles(Picker.rows(for: f.sections, query: "cafe")), ["# Work", "Café"], "a section with no match goes, header and all")
        XCTAssertEqual(titles(Picker.rows(for: f.sections, query: "  ")), titles(Picker.rows(for: f.sections)), "spaces alone filter nothing")
        // Both profiles have a match: both headers stay.
        XCTAssertEqual(titles(Picker.rows(for: f.sections, query: "l")), ["# Personal", "Blogging", "Personal", "# Work", "Clients"])
    }

    func testEveryWordMustMatchInAnyOrder() {
        XCTAssertTrue(Picker.matches("Research/Preparation", query: "prep res"))
        XCTAssertFalse(Picker.matches("Research/Preparation", query: "prep xyz"))
        XCTAssertTrue(Picker.matches("Client (Container)", query: "container"), "the mark is part of what is read, so it is found")
        XCTAssertTrue(Picker.matches("Anything", query: ""))
    }

    func testNothingFoundSaysSo() {
        let f = fixture()
        let rows = Picker.rows(for: f.sections, query: "zzz")
        XCTAssertEqual(rows, [.empty("No spaces found")])
        XCTAssertTrue(Picker.choosable(rows).isEmpty)
        XCTAssertNil(Picker.highlight(nil, in: rows), "Return then chooses nothing")
        XCTAssertNil(Picker.highlight(nil, movedBy: 1, in: rows))
    }

    // MARK: - Disabled rows and the reason line

    /// A page that is not a web page: the rows of other sessions are listed,
    /// disabled, the reason is the last line, and the keys pass them over.
    func testRowsThatCannotCrossAreListedDisabledAndPassedOver() {
        let f = fixture(url: "about:blank")
        let rows = Picker.rows(for: f.sections)
        XCTAssertEqual(titles(rows), ["# Personal", "Blogging", "Personal", "Imara", "# Work", "Clients", "Café",
                                      "! Only web pages can open in another profile or container"])
        XCTAssertEqual(rows.compactMap(\.entry).filter { !$0.isEnabled }.map(\.title), ["Clients", "Café"])
        XCTAssertEqual(Picker.choosable(rows), f.personal.map(\.id))
        XCTAssertEqual(Picker.highlight(f.personal[2].id, movedBy: 1, in: rows), f.personal[2].id, "↓ stops at the last row that can be chosen")
        XCTAssertNil(Picker.highlight(f.workSpaces[0].id, in: Picker.rows(for: f.sections, query: "clients")), "a disabled row is never highlighted")

        // The reason goes when no disabled row is showing.
        XCTAssertEqual(titles(Picker.rows(for: f.sections, query: "imara")), ["# Personal", "Imara"])
        XCTAssertEqual(titles(Picker.rows(for: f.sections, query: "caf")),
                       ["# Work", "Café", "! Only web pages can open in another profile or container"])
    }

    func testContainerMarksAndHeadersReachTheRows() throws {
        let store = SidebarStore(spaces: [Space(name: "Home")])
        let client = store.addSpace(name: "Client")
        let container = try XCTUnwrap(store.createContainer(forSpace: client.id))
        let inside = store.createLittleArcWindow(url: url("inside.test"), profileID: container.id)
        XCTAssertEqual(titles(Picker.rows(for: Menu.sections(store: store, windowID: inside.id))),
                       ["# This container", "Client (Container)", "# Personal (outside this container)", "Home"])
    }

    // MARK: - ↑ ↓ and Return

    func testTheFirstRowIsHighlightedWhenThePanelOpens() {
        let f = fixture()
        let rows = Picker.rows(for: f.sections)
        XCTAssertEqual(Picker.highlight(nil, in: rows), f.personal[0].id)
        XCTAssertEqual(Picker.highlight(f.workSpaces[1].id, in: rows), f.workSpaces[1].id, "a highlight that is still listed stays")
        XCTAssertEqual(Picker.highlight(UUID(), in: rows), f.personal[0].id)
    }

    func testArrowsMoveThroughRowsAcrossHeadersAndStopAtTheEnds() {
        let f = fixture()
        let rows = Picker.rows(for: f.sections)
        let order = f.personal.map(\.id) + f.workSpaces.map(\.id)
        XCTAssertEqual(Picker.choosable(rows), order)
        var current = Picker.highlight(nil, in: rows)
        var visited: [Space.ID?] = [current]
        for _ in 0 ..< 6 {
            current = Picker.highlight(current, movedBy: 1, in: rows)
            visited.append(current)
        }
        XCTAssertEqual(visited, (order + [order[4], order[4]]).map(Optional.some), "↓ crosses the Work header and stops at the last row")
        XCTAssertEqual(Picker.highlight(order[3], movedBy: -1, in: rows), order[2], "↑ crosses the header back")
        XCTAssertEqual(Picker.highlight(order[0], movedBy: -1, in: rows), order[0], "↑ stops at the first row")
        XCTAssertEqual(Picker.highlight(nil, movedBy: -1, in: rows), order[4], "↑ from nothing takes the last row")
        XCTAssertEqual(Picker.highlight(nil, movedBy: 1, in: rows), order[0])
    }

    /// Typing narrows the list: the highlight goes to the first match, which
    /// is what Return then chooses.
    func testTheHighlightFollowsTheSearch() {
        let f = fixture()
        let all = Picker.rows(for: f.sections)
        let highlighted = Picker.highlight(Picker.highlight(nil, in: all), movedBy: 1, in: all)
        XCTAssertEqual(highlighted, f.personal[1].id)
        let narrowed = Picker.rows(for: f.sections, query: "caf")
        XCTAssertEqual(Picker.highlight(highlighted, in: narrowed), f.workSpaces[1].id)
        XCTAssertEqual(Picker.highlight(highlighted, in: Picker.rows(for: f.sections, query: "pers")), f.personal[1].id, "still listed: it stays")
    }
}

import XCTest
@testable import SidebarModel

/// "Opened in Darni" marks (owner, 2026-11-27): a local file of their own,
/// first date kept, read by builds that write it and ignored by older ones.
final class TabOpenedMarksTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("darni-opened-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var file: URL { directory.appendingPathComponent(TabOpenedMarks.fileName) }

    func testTheFirstDateIsKept() {
        var marks = TabOpenedMarks()
        let id = UUID()
        let first = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertTrue(marks.mark(id, at: first))
        XCTAssertFalse(marks.mark(id, at: first.addingTimeInterval(3600)), "already marked")
        XCTAssertEqual(marks[id], first)
    }

    func testKeepOnlyAndRemoveAllSayWhetherTheyChangedAnything() {
        let kept = UUID(), dropped = UUID()
        var marks = TabOpenedMarks(openedAt: [kept: Date(), dropped: Date()])
        XCTAssertTrue(marks.keepOnly { $0 == kept })
        XCTAssertFalse(marks.keepOnly { $0 == kept })
        XCTAssertEqual(Array(marks.openedAt.keys), [kept])
        XCTAssertTrue(marks.removeAll())
        XCTAssertFalse(marks.removeAll())
        XCTAssertTrue(marks.isEmpty)
    }

    func testSaveAndLoadRoundTripToTheSecondReadableByThePersonOnly() throws {
        let a = UUID(), b = UUID()
        let marks = TabOpenedMarks(openedAt: [a: Date(timeIntervalSinceReferenceDate: 800_000_000), b: Date(timeIntervalSinceReferenceDate: 800_086_400)])
        try marks.save(to: file)
        XCTAssertEqual(TabOpenedMarks.load(from: file), marks)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\"version\":1"), text)
        XCTAssertTrue(text.contains(a.uuidString), "keyed by the sidebar tab's ID")
        XCTAssertFalse(text.contains("http"), "no address, no title")
    }

    func testNoMarkLeftRemovesTheFile() throws {
        try TabOpenedMarks(openedAt: [UUID(): Date()]).save(to: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try TabOpenedMarks().save(to: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAMissingDamagedOrLaterFileReadsWhatItCan() throws {
        XCTAssertTrue(TabOpenedMarks.load(from: file).isEmpty, "no file: no marks, the fallback rule for every tab")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        XCTAssertTrue(TabOpenedMarks.load(from: file).isEmpty)
        // A later version with keys this build doesn't know, and a key that isn't a tab ID.
        let id = UUID()
        let later = #"{"version":2,"future":true,"opened":{"\#(id.uuidString)":"2026-11-27T10:00:00Z","nope":"2026-11-27T10:00:00Z"}}"#
        try Data(later.utf8).write(to: file)
        let marks = TabOpenedMarks.load(from: file)
        XCTAssertEqual(marks.openedAt.count, 1)
        XCTAssertEqual(marks[id], ISO8601DateFormatter().date(from: "2026-11-27T10:00:00Z"))
    }

    // MARK: The Task Manager's rule

    func testAMarkSaysOpenedAndOnlyATabWithoutOneFallsBackToTheSameSecondRule() {
        let imported = Date(timeIntervalSinceReferenceDate: 800_000_000.2)
        let counts = TaskManagerUnloadedTab.stampCounts([imported, imported, imported, Date(timeIntervalSinceReferenceDate: 800_100_000)])
        XCTAssertTrue(TaskManagerUnloadedTab.isOpenedInDarni(mark: Date(), lastActiveAt: imported, counts: counts),
                      "opened in Darni though its date is the import's")
        XCTAssertFalse(TaskManagerUnloadedTab.isOpenedInDarni(mark: nil, lastActiveAt: imported, counts: counts), "no mark, the import's date")
        XCTAssertTrue(TaskManagerUnloadedTab.isOpenedInDarni(mark: nil, lastActiveAt: Date(timeIntervalSinceReferenceDate: 800_100_000), counts: counts),
                      "no mark, a date of its own (opened by a build before marks)")
        XCTAssertFalse(TaskManagerUnloadedTab.isOpenedInDarni(mark: nil, lastActiveAt: nil, counts: counts))
        XCTAssertTrue(TaskManagerUnloadedTab.isOpenedInDarni(mark: Date(), lastActiveAt: nil, counts: counts))
    }

    func testTheFoldStaysAtADay() {
        // The owner kept 24 hours (2026-11-27).
        XCTAssertEqual(TaskManagerRows.foldAfter, 24 * 3600)
        XCTAssertTrue(TaskManagerUnloadedTab(id: "a", title: "a", idle: 24 * 3600 - 60, wasUnloaded: false).hasOwnRow)
        XCTAssertFalse(TaskManagerUnloadedTab(id: "b", title: "b", idle: 24 * 3600, wasUnloaded: false).hasOwnRow)
    }

    func testSleepsReasonsAreTheInspectorsWords() {
        XCTAssertEqual(TabSleepUnavailable.notLoaded.text, "Not loaded: nothing in memory to freeze.")
        XCTAssertEqual(TabSleepUnavailable.unloaded.text, "Already unloaded.")
        XCTAssertEqual(TabSleepUnavailable.asleep.text, "Already asleep.")
        XCTAssertEqual(TabSleepUnavailable.inUse(.capturing).text, TaskManagerTabState.keptAwake(.capturing).explanation)
    }
}

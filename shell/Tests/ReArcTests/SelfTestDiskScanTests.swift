import XCTest
@testable import ReArc

/// The self-test's "blocked list in memory only" step reads files for a
/// name that must be in none. It reads the folders the app alone writes to,
/// and refuses a folder other programs share: with the temporary folder at
/// `/tmp` it once read 30 GB in 75 s (QA on build 1126).
final class SelfTestDiskScanTests: XCTestCase {
    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-disk-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testANameInAnyFileOfTheFoldersIsFound() throws {
        let profile = try scratch(), shellData = try scratch()
        let nested = profile.appendingPathComponent("Default/Network", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("prefix selftest-blocked-7 suffix".utf8).write(to: nested.appendingPathComponent("log"))
        try Data("nothing here".utf8).write(to: profile.appendingPathComponent("Local State"))
        try Data(#"{"history":["selftest-blocked-3.example"]}"#.utf8).write(to: shellData.appendingPathComponent("history.json"))
        try Data("{}".utf8).write(to: shellData.appendingPathComponent("sidebar.json"))

        let found = SelfTestDiskScan.files(containing: "selftest-blocked-", in: [profile, shellData])
        XCTAssertEqual(Set(found.map { URL(fileURLWithPath: $0).lastPathComponent }), ["log", "history.json"])
        XCTAssertEqual(SelfTestDiskScan.files(containing: "selftest-absent-", in: [profile, shellData]), [])
        XCTAssertEqual(SelfTestDiskScan.files(containing: "selftest-blocked-", in: [profile.appendingPathComponent("missing")]), [],
                       "a folder that is not there holds nothing")
    }

    /// The guarantee is about the app's own folders: a file beside them is not read.
    func testAFileBesideTheFoldersIsNotRead() throws {
        let parent = try scratch()
        let profile = parent.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("selftest-blocked-1".utf8).write(to: parent.appendingPathComponent("another-programs-file"))
        XCTAssertEqual(SelfTestDiskScan.files(containing: "selftest-blocked-", in: [profile]), [])
    }

    func testASharedFolderIsNamedAndAFolderInsideOneIsNot() throws {
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        let home = URL(fileURLWithPath: "/Users/kai", isDirectory: true)
        let places = [temporary, home]
        func shared(_ paths: String...) -> [String] {
            SelfTestDiskScan.sharedFolders(among: paths.map { URL(fileURLWithPath: $0, isDirectory: true) }, sharedPlaces: places)
        }
        XCTAssertEqual(shared("/private/tmp/rearc-selftest-501", "/private/tmp/rearc-selftest-shell-1"), [], "folders of the run's own")
        XCTAssertEqual(shared("/private/tmp"), ["/private/tmp"], "the temporary folder itself")
        XCTAssertEqual(shared("/private/tmp/"), ["/private/tmp"])
        XCTAssertEqual(shared("/private"), ["/private"], "a folder above it")
        XCTAssertEqual(shared("/"), ["/"])
        XCTAssertEqual(shared("/Users/kai"), ["/Users/kai"], "the home folder")
        XCTAssertEqual(shared("/Users/kai/Library/Application Support/ReArc/Chromium"), [])
        XCTAssertEqual(shared("/private/tmpfiles"), [], "a name that only starts the same")
        XCTAssertEqual(shared("/private/tmp/a", "/private/tmp"), ["/private/tmp"], "only the shared one is named")
    }

    func testThisProcessesTemporaryAndHomeFoldersAreShared() throws {
        let temporary = FileManager.default.temporaryDirectory
        XCTAssertEqual(SelfTestDiskScan.sharedFolders(among: [temporary]).count, 1)
        XCTAssertEqual(SelfTestDiskScan.sharedFolders(among: [FileManager.default.homeDirectoryForCurrentUser]).count, 1)
        XCTAssertEqual(SelfTestDiskScan.sharedFolders(among: [URL(fileURLWithPath: "/tmp", isDirectory: true)]).count, 1,
                       "/tmp by its symbolic link")
        // As the self-test now sets up: the profile and the shell's folder, each inside the temporary folder.
        let profile = temporary.appendingPathComponent("rearc-selftest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        let shellData = temporary.appendingPathComponent("rearc-selftest-shell-\(UUID().uuidString)", isDirectory: true)
        XCTAssertEqual(SelfTestDiskScan.sharedFolders(among: [profile, shellData]), [])
    }

    func testPathsAreComparedWithTheirLinksFollowed() {
        XCTAssertEqual(SelfTestDiskScan.canonicalPath(URL(fileURLWithPath: "/tmp", isDirectory: true)), "/private/tmp")
        XCTAssertEqual(SelfTestDiskScan.canonicalPath(URL(fileURLWithPath: "/private/tmp", isDirectory: true)), "/private/tmp")
        XCTAssertEqual(SelfTestDiskScan.canonicalPath(URL(fileURLWithPath: "/tmp/rearc-not-there/profile", isDirectory: true)),
                       "/private/tmp/rearc-not-there/profile", "a folder that is not there yet")
        XCTAssertEqual(SelfTestDiskScan.canonicalPath(URL(fileURLWithPath: "/", isDirectory: true)), "/")
    }
}

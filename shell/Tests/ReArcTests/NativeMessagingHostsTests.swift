import XCTest
@testable import ReArc

/// Native messaging hosts copied from Arc and Chrome (1Password's unlock with
/// the app), narrowed by the security review of 41876855.
final class NativeMessagingHostsTests: XCTestCase {
    private var root: URL!
    private let origin = "chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-nmh-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func dir(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func manifestJSON(_ name: String, path: String = "/Applications/1Password.app/x", type: String = "stdio",
                              origins: [String]? = nil) -> String {
        let list = (origins ?? [origin]).map { "\"\($0)\"" }.joined(separator: ", ")
        return #"{"name": "\#(name)", "path": "\#(path)", "type": "\#(type)", "allowed_origins": [\#(list)]}"#
    }

    private func write(_ json: String, as file: String, in dir: URL) throws {
        try Data(json.utf8).write(to: dir.appendingPathComponent(file))
    }

    private func manifest(_ name: String, path: String = "/Applications/1Password.app/x", in dir: URL) throws {
        try write(manifestJSON(name, path: path), as: "\(name).json", in: dir)
    }

    private func hosts(_ data: URL) -> URL { data.appendingPathComponent("NativeMessagingHosts") }

    /// Helper paths under /gone are uninstalled; any other path counts as installed.
    @discardableResult
    private func mirror(_ data: URL, _ sources: [URL]) -> [String] {
        ChromiumNativeMessagingHosts.mirror(into: data, from: sources, isExecutable: { !$0.hasPrefix("/gone") })
    }

    private func exists(_ name: String, _ data: URL) -> Bool {
        FileManager.default.fileExists(atPath: hosts(data).appendingPathComponent(name).path)
    }

    private func read(_ name: String, _ data: URL) throws -> String {
        try String(contentsOf: hosts(data).appendingPathComponent(name), encoding: .utf8)
    }

    // 1. Allowlist

    func testOnlyOnePasswordIsCopiedArcFirstAndFollowsTheSource() throws {
        let arc = try dir("arc"), chrome = try dir("chrome"), data = try dir("data")
        try manifest("com.1password.1password", path: "/arc", in: arc)
        try manifest("com.1password.1password", path: "/chrome", in: chrome)
        try manifest("com.1password.1password7", in: chrome)
        try manifest("com.dropbox.nmh", in: chrome)
        try manifest("2bua8c4s2c.com.agilebits.1password", in: arc)

        let first = mirror(data, [arc, chrome])
        XCTAssertEqual(first, ["com.1password.1password.json", "com.1password.1password7.json"])
        XCTAssertTrue(try read("com.1password.1password.json", data).contains("/arc"), "Arc wins")
        XCTAssertFalse(exists("com.dropbox.nmh.json", data), "not allowed")
        XCTAssertFalse(exists("2bua8c4s2c.com.agilebits.1password.json", data), "not allowed")
        XCTAssertEqual(mirror(data, [arc, chrome]), [], "nothing changed")

        try manifest("com.1password.1password", path: "/arc2", in: arc)
        XCTAssertEqual(mirror(data, [arc, chrome]), ["com.1password.1password.json"])
        XCTAssertTrue(try read("com.1password.1password.json", data).contains("/arc2"), "an update follows")

        try FileManager.default.removeItem(at: chrome.appendingPathComponent("com.1password.1password7.json"))
        mirror(data, [arc, chrome])
        XCTAssertFalse(exists("com.1password.1password7.json", data), "a copy goes when its source goes")
    }

    func testNothingFoundLeavesNoFolder() throws {
        let chrome = try dir("chrome"), data = try dir("data")
        try manifest("com.dropbox.nmh", in: chrome)
        XCTAssertEqual(mirror(data, [chrome]), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: hosts(data).path))
    }

    func testNeverTouchesAManifestReArcDidNotCopy() throws {
        let arc = try dir("arc"), data = try dir("data")
        let own = try dir("data/NativeMessagingHosts")
        try manifest("com.1password.1password", path: "/mine", in: own)
        try manifest("com.1password.1password", path: "/arc", in: arc)

        XCTAssertEqual(mirror(data, [arc]), [])
        XCTAssertTrue(try read("com.1password.1password.json", data).contains("/mine"))
        try FileManager.default.removeItem(at: arc.appendingPathComponent("com.1password.1password.json"))
        mirror(data, [arc])
        XCTAssertTrue(try read("com.1password.1password.json", data).contains("/mine"), "not removed either")
    }

    /// A manifest the first version (41876855, every host) copied goes on the next launch.
    func testACopyNoLongerAllowedIsRemoved() throws {
        let chrome = try dir("chrome"), data = try dir("data")
        let target = try dir("data/NativeMessagingHosts")
        try manifest("com.dropbox.nmh", in: chrome)
        try manifest("com.dropbox.nmh", in: target)
        try write(#"["com.dropbox.nmh.json"]"#, as: ".rearc-copied.json", in: target)

        mirror(data, [chrome])
        XCTAssertFalse(exists("com.dropbox.nmh.json", data))
        XCTAssertEqual(try read(".rearc-copied.json", data), "[]")
    }

    // 2. Shipped runs on the person's own data only

    func testRunsOnlyForAShippedRunOnTheOwnersData() {
        let own = URL(fileURLWithPath: "/Users/x/Library/Application Support/ReArc/Chromium")
        func runs(_ switches: Bool, _ env: [String: String], _ dir: URL) -> Bool {
            ChromiumNativeMessagingHosts.runs(testSwitches: switches, userDataDir: dir, environment: env,
                                              infoDictionary: [:], ownUserDataDir: own)
        }
        XCTAssertTrue(runs(false, [:], own))
        XCTAssertTrue(runs(false, [:], own.appendingPathComponent("../Chromium")), "the same folder, spelled differently")
        XCTAssertFalse(runs(true, [:], own), "self-test and bench")
        XCTAssertFalse(runs(false, ["REARC_DATA_DIR": "/tmp/x"], own))
        XCTAssertTrue(runs(false, ["REARC_DATA_DIR": ""], own))
        XCTAssertFalse(runs(false, [:], URL(fileURLWithPath: "/tmp/dev-profile")), "a development --user-data-dir")
    }

    // 3. Names

    func testLedgerNamesThatAreNotPlainFileNamesAreIgnored() throws {
        let data = try dir("data")
        let target = try dir("data/NativeMessagingHosts")
        let outside = root.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        try write(#"["../../outside.json", "../outside.json", ".rearc-copied.json", "sub/x.json"]"#,
                  as: ".rearc-copied.json", in: target)

        mirror(data, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "nothing outside the folder is removed")
        XCTAssertTrue(exists(".rearc-copied.json", data))
    }

    func testPlainNames() {
        XCTAssertTrue(ChromiumNativeMessagingHosts.isPlainManifestName("com.1password.1password.json"))
        for name in ["../x.json", "a/b.json", ".rearc-copied.json", ".json", "com.1password.x", "com.1password.x.json/"] {
            XCTAssertFalse(ChromiumNativeMessagingHosts.isPlainManifestName(name), name)
        }
        XCTAssertFalse(ChromiumNativeMessagingHosts.isAllowed(".com.1password.x.json"))
    }

    // 4. Manifests

    func testOnlyValidManifestsAreCopied() throws {
        let arc = try dir("arc"), data = try dir("data")
        let cases: [(String, String)] = [
            ("com.1password.a", manifestJSON("com.1password.other")),                        // name is not the stem
            ("com.1password.b", manifestJSON("com.1password.b", type: "dll")),                // not stdio
            ("com.1password.c", manifestJSON("com.1password.c", path: "relative/helper")),    // not absolute
            ("com.1password.d", manifestJSON("com.1password.d", origins: [])),                // no origins
            ("com.1password.e", manifestJSON("com.1password.e", origins: ["https://evil.test/"])),
            ("com.1password.f", manifestJSON("com.1password.f", origins: ["chrome-extension://short/"])),
            ("com.1password.g", "not json"),
        ]
        for (name, json) in cases { try write(json, as: "\(name).json", in: arc) }
        let small = manifestJSON("com.1password.h")
        let big = String(small.dropLast(1)) + #", "pad": ""# + String(repeating: "x", count: 70_000) + #""}"#
        try write(big, as: "com.1password.h.json", in: arc)
        try write(manifestJSON("com.1password.i", origins: ["chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjnco\u{0061}\u{0301}/"]),
                  as: "com.1password.i.json", in: arc)                                    // a combining mark
        try manifest("com.1password.gone", path: "/gone/1Password7.app/helper", in: arc)  // the app is uninstalled
        try manifest("com.1password.ok", in: arc)

        XCTAssertEqual(mirror(data, [arc]), ["com.1password.ok.json"])
    }

    // The helper's path, for the 1Password connection check (pre-review of 2026-11-17, B-2)

    func testTheCopiedManifestGivesTheHelpersPath() throws {
        let arc = try dir("arc"), data = try dir("data")
        try manifest("com.1password.1password", path: "/Applications/1Password.app/helper", in: arc)
        mirror(data, [arc])

        XCTAssertEqual(ChromiumNativeMessagingHosts.copiedHostPath(named: "com.1password.1password", in: data, isExecutable: { _ in true }),
                       "/Applications/1Password.app/helper")
        XCTAssertNil(ChromiumNativeMessagingHosts.copiedHostPath(named: "com.1password.1password7", in: data, isExecutable: { _ in true }),
                     "no such manifest")
        XCTAssertNil(ChromiumNativeMessagingHosts.copiedHostPath(named: "com.1password.1password", in: data, isExecutable: { _ in false }),
                     "the helper is no longer installed")
    }

    func testAManifestReArcDidNotCopyGivesNoPath() throws {
        let data = try dir("data")
        try FileManager.default.createDirectory(at: hosts(data), withIntermediateDirectories: true)
        try manifest("com.1password.1password", in: hosts(data))
        XCTAssertNil(ChromiumNativeMessagingHosts.copiedHostPath(named: "com.1password.1password", in: data, isExecutable: { _ in true }),
                     "no ledger")

        try Data(#"["com.dropbox.nmh.json"]"#.utf8).write(to: hosts(data).appendingPathComponent(".rearc-copied.json"))
        XCTAssertNil(ChromiumNativeMessagingHosts.copiedHostPath(named: "com.1password.1password", in: data, isExecutable: { _ in true }),
                     "not in the ledger")
    }

    func testOnlyAnAllowedAndValidManifestGivesAPath() throws {
        let data = try dir("data")
        try FileManager.default.createDirectory(at: hosts(data), withIntermediateDirectories: true)
        try Data(#"["com.dropbox.nmh.json", "com.1password.1password.json", "../com.1password.x.json"]"#.utf8)
            .write(to: hosts(data).appendingPathComponent(".rearc-copied.json"))
        try manifest("com.dropbox.nmh", in: hosts(data))
        XCTAssertNil(ChromiumNativeMessagingHosts.copiedHostPath(named: "com.dropbox.nmh", in: data, isExecutable: { _ in true }),
                     "not on the allowlist")
        XCTAssertNil(ChromiumNativeMessagingHosts.copiedHostPath(named: "../com.1password.x", in: data, isExecutable: { _ in true }),
                     "not a plain name")

        try write(manifestJSON("com.1password.1password", path: "relative/helper"), as: "com.1password.1password.json", in: hosts(data))
        XCTAssertNil(ChromiumNativeMessagingHosts.copiedHostPath(named: "com.1password.1password", in: data, isExecutable: { _ in true }),
                     "the path must be absolute")
        try write(manifestJSON("com.1password.other", path: "/x"), as: "com.1password.1password.json", in: hosts(data))
        XCTAssertNil(ChromiumNativeMessagingHosts.copiedHostPath(named: "com.1password.1password", in: data, isExecutable: { _ in true }),
                     "the name must be the file's")
    }
}

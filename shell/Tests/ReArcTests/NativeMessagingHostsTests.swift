import XCTest
@testable import ReArc

/// Native messaging hosts copied from Arc and Chrome (1Password's unlock with the app).
final class NativeMessagingHostsTests: XCTestCase {
    private var root: URL!

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

    private func manifest(_ name: String, path: String, in dir: URL) throws {
        let json = #"{"name": "\#(name)", "path": "\#(path)", "type": "stdio", "allowed_origins": ["chrome-extension://abc/"]}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("\(name).json"))
    }

    private func read(_ name: String, _ data: URL) throws -> String {
        try String(contentsOf: data.appendingPathComponent("NativeMessagingHosts/\(name).json"), encoding: .utf8)
    }

    func testCopiesArcFirstThenChromeAndFollowsTheSource() throws {
        let arc = try dir("arc"), chrome = try dir("chrome"), data = try dir("data")
        try manifest("com.1password.1password", path: "/arc", in: arc)
        try manifest("com.1password.1password", path: "/chrome", in: chrome)
        try manifest("com.chrome.only", path: "/c", in: chrome)
        try Data("not json".utf8).write(to: chrome.appendingPathComponent("broken.json"))

        let first = ChromiumNativeMessagingHosts.mirror(into: data, from: [arc, chrome])
        XCTAssertEqual(first, ["com.1password.1password.json", "com.chrome.only.json"])
        XCTAssertTrue(try read("com.1password.1password", data).contains("/arc"), "Arc wins")
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("NativeMessagingHosts/broken.json").path))
        XCTAssertEqual(ChromiumNativeMessagingHosts.mirror(into: data, from: [arc, chrome]), [], "nothing changed")

        try manifest("com.1password.1password", path: "/arc2", in: arc)
        XCTAssertEqual(ChromiumNativeMessagingHosts.mirror(into: data, from: [arc, chrome]), ["com.1password.1password.json"])
        XCTAssertTrue(try read("com.1password.1password", data).contains("/arc2"), "an update follows")

        try FileManager.default.removeItem(at: chrome.appendingPathComponent("com.chrome.only.json"))
        ChromiumNativeMessagingHosts.mirror(into: data, from: [arc, chrome])
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("NativeMessagingHosts/com.chrome.only.json").path),
                       "a copy goes when its source goes")
    }

    func testNeverTouchesAManifestReArcDidNotCopy() throws {
        let arc = try dir("arc"), data = try dir("data")
        let own = try dir("data/NativeMessagingHosts")
        try manifest("com.mine", path: "/mine", in: own)
        try manifest("com.mine", path: "/arc", in: arc)

        XCTAssertEqual(ChromiumNativeMessagingHosts.mirror(into: data, from: [arc]), [])
        XCTAssertTrue(try read("com.mine", data).contains("/mine"))
        try FileManager.default.removeItem(at: arc.appendingPathComponent("com.mine.json"))
        ChromiumNativeMessagingHosts.mirror(into: data, from: [arc])
        XCTAssertTrue(try read("com.mine", data).contains("/mine"), "not removed either")
    }
}

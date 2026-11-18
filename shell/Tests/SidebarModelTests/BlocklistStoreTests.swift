import CryptoKit
import XCTest
@testable import SidebarModel

/// Blocklist bundles (docs/FEATURE-SPECS/CONTENT-BLOCKING.md §4 and §8,
/// "Signature"): a good bundle, a bad signature, a hash mismatch, an older
/// version, a wrong `min_engine`; which bundle is used; and the daily check.
/// Also what the security pre-review asked for: a rule that does more than
/// block or allow refuses its bundle (CB-03), and a bundle signed by any one
/// of a short list of keys is used, so the key can be replaced (CB-05).
/// The bundle the repository carries and the archive the pipeline packs are
/// read too, so the shell and `build-blocklists.py` cannot drift apart.

private let shellDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Makes signed format 1 bundles as `build-blocklists.py` writes them, with a key of its own.
private struct BundleMaker {
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: Data { key.publicKey.rawRepresentation }

    struct Options {
        var lists = ["easyprivacy", "peter-lowe", "easylist"]
        var minEngine: Any? = 156
        var created: String? = "2026-11-18T09:00:00Z"
        /// Signed with another key.
        var foreignKey = false
        /// Written after signing: the manifest no longer matches its signature.
        var manifestSuffix = ""
        /// Signed with this key and not the maker's.
        var signer: Curve25519.Signing.PrivateKey?
        /// A list's rules file, as text, in place of its one block rule (hashed as written).
        var rules: [String: String] = [:]
    }

    /// A rules file with one rule of each given action.
    static func rules(actions: [String]) -> String {
        "[" + actions.enumerated().map { index, action in
            #"{"id":\#(index + 1),"priority":1,"action":\#(action),"condition":{"urlFilter":"||ads.test^"}}"#
        }.joined(separator: ",") + "]"
    }

    @discardableResult
    func make(_ version: String, in parent: URL, named name: String? = nil, _ options: Options = Options()) throws -> URL {
        let directory = parent.appendingPathComponent(name ?? version, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("rules"), withIntermediateDirectories: true)
        var lists: [[String: Any]] = []
        for (index, id) in options.lists.enumerated() {
            let rules = Data((options.rules[id]
                ?? #"[{"id":1,"priority":1,"action":{"type":"block"},"condition":{"urlFilter":"||\#(id).ads.test^"}}]"#).utf8)
            try rules.write(to: directory.appendingPathComponent("rules/\(id).json"))
            lists.append(["id": id, "title": id.capitalized, "homepage": "https://lists.test/\(id)", "license": "GPL-3.0",
                          "level": min(index + 1, 3),
                          "rules": ["path": "rules/\(id).json", "sha256": BlocklistVerifier.sha256(of: rules), "bytes": rules.count, "count": 1]])
        }
        var manifest: [String: Any] = ["format": 1, "version": version, "lists": lists,
                                       "priorities": ["block": 1, "allow": 2, "important": 3, "important_allow": 4, "site_exception": 1_000_000]]
        if let created = options.created { manifest["created"] = created }
        if let minEngine = options.minEngine { manifest["min_engine"] = minEngine }
        var data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let signer = options.signer ?? (options.foreignKey ? Curve25519.Signing.PrivateKey() : key)
        let signature = try signer.signature(for: data)
        data.append(Data(options.manifestSuffix.utf8))
        try data.write(to: directory.appendingPathComponent("manifest.json"))
        try Data(signature.base64EncodedString().utf8).write(to: directory.appendingPathComponent("manifest.json.sig"))
        return directory
    }

    /// The mirror's `.tar.gz` of a bundle, made by the system's tar as plain ustar (as the builder writes it), and its `latest.json`.
    func archive(_ version: String, in scratch: URL, _ options: Options = Options()) throws -> (archive: Data, latest: Data) {
        let folder = scratch.appendingPathComponent("pack-\(UUID().uuidString)", isDirectory: true)
        try make(version, in: folder, named: "blocklists-\(version)", options)
        let file = scratch.appendingPathComponent("\(UUID().uuidString).tar.gz")
        try runTool("/usr/bin/tar", ["--format", "ustar", "--no-mac-metadata", "--no-xattrs", "-czf", file.path, "-C", folder.path, "blocklists-\(version)"])
        let archive = try Data(contentsOf: file)
        return (archive, latest(version, archive: archive))
    }

    func latest(_ version: String, archive: Data, url: String? = nil) -> Data {
        let json: [String: Any] = ["version": version, "url": url ?? "blocklists-\(version).tar.gz", "sha256": BlocklistVerifier.sha256(of: archive)]
        return try! JSONSerialization.data(withJSONObject: json)
    }
}

private func runTool(_ tool: String, _ arguments: [String], input: Data? = nil) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    // Finder's metadata would add AppleDouble entries the manifest does not list.
    process.environment = ["COPYFILE_DISABLE": "1"]
    let output = Pipe(), stdin = Pipe()
    process.standardOutput = output
    process.standardInput = stdin
    try process.run()
    if let input { stdin.fileHandleForWriting.write(input) }
    stdin.fileHandleForWriting.closeFile()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    return data
}

/// One ustar entry: a 512-byte header and the content, padded.
private func tarEntry(_ name: String, type: Character = "0", content: Data = Data(), link: String = "") -> Data {
    var header = [UInt8](repeating: 0, count: 512)
    func put(_ text: String, at offset: Int) { for (index, byte) in text.utf8.enumerated() { header[offset + index] = byte } }
    put(name, at: 0)
    put("0000644", at: 100)
    put(String(format: "%011o", content.count), at: 124)
    header[156] = type.asciiValue!
    put(link, at: 157)
    put("ustar", at: 257)
    put("00", at: 263)
    return Data(header) + content + Data(count: (512 - content.count % 512) % 512)
}

private func gzip(_ entries: [Data]) throws -> Data {
    try runTool("/usr/bin/gzip", ["-c"], input: entries.reduce(Data(), +) + Data(count: 1024))
}

private final class FakeMirror: BlocklistFetching, @unchecked Sendable {
    var pages: [String: Data] = [:]
    private(set) var requested: [String] = []

    func data(from url: URL, limit: Int) async throws -> Data {
        requested.append(url.absoluteString)
        guard let data = pages[url.absoluteString], data.count <= limit else { throw URLError(.fileDoesNotExist) }
        return data
    }
}

private func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-blocklists-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let engine = BlocklistEngineVersion(chromium: "156.0.8078.109")

// MARK: - The lists key

final class BlocklistSigningKeyTests: XCTestCase {
    private static let keyFile = shellDirectory.appendingPathComponent("scripts/blocklists/blocklists-public-key.txt")

    /// The keys in the app are the pipeline's committed public keys, in the
    /// file's order. A new key in the file alone fails here, loudly, in any
    /// build, and so does a key taken out of the file that the app still trusts.
    func testTheCompiledInKeysAreThePipelinesPublicKeys() throws {
        let text = try String(contentsOf: Self.keyFile, encoding: .utf8)
        let keys = try XCTUnwrap(BlocklistSigningKey.parseAll(text), "\(Self.keyFile.path) holds a line that is no Ed25519 public key, or no key")
        XCTAssertEqual(BlocklistSigningKey.compiledIn, keys,
                       "BlocklistSigningKey.compiledInTexts are not the keys in \(Self.keyFile.path): copy the file's keys into it, in its order.")
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        XCTAssertEqual(lines, BlocklistSigningKey.compiledInTexts)
    }

    /// A short list (security CB-05): the key in use, and at most two more
    /// while one is brought in or retired. A key that stays is a key that
    /// can still sign for every install.
    func testTheAppTrustsAShortListOfDistinctKeys() {
        XCTAssertEqual(BlocklistSigningKey.compiledIn.count, BlocklistSigningKey.compiledInTexts.count, "a compiled-in text is not a key")
        XCTAssertTrue((1...3).contains(BlocklistSigningKey.compiledIn.count), "\(BlocklistSigningKey.compiledIn.count) lists keys")
        XCTAssertEqual(Set(BlocklistSigningKey.compiledIn).count, BlocklistSigningKey.compiledIn.count)
    }

    func testZerosAreNotAKey() {
        XCTAssertNil(BlocklistSigningKey.parse(Data(count: 32).base64EncodedString()))
        XCTAssertFalse(BlocklistSigningKey.compiledIn.isEmpty)
    }

    func testAKeyFileOfSeveralKeysHasOneALine() {
        let first = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let second = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let hex = second.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(BlocklistSigningKey.parseAll("\(first.base64EncodedString())\n"), [first])
        XCTAssertEqual(BlocklistSigningKey.parseAll("# in use\n\(first.base64EncodedString())\n\n  # until the next release\n \(hex) \n"), [first, second])
        XCTAssertNil(BlocklistSigningKey.parseAll("\(first.base64EncodedString())\nnot a key\n"), "one bad line refuses the file: a key must not vanish quietly")
        XCTAssertNil(BlocklistSigningKey.parseAll("# nothing\n"))
        XCTAssertNil(BlocklistSigningKey.parseAll(""))
    }

    func testAKeyFileInEachUsualForm() {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let base64 = key.base64EncodedString()
        let hex = key.map { String(format: "%02x", $0) }.joined()
        let spki = (Data([0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00]) + key).base64EncodedString()
        XCTAssertEqual(BlocklistSigningKey.parse(base64), key)
        XCTAssertEqual(BlocklistSigningKey.parse("# ReArc lists key\n\(base64)\n"), key)
        XCTAssertEqual(BlocklistSigningKey.parse(hex), key)
        XCTAssertEqual(BlocklistSigningKey.parse("-----BEGIN PUBLIC KEY-----\n\(spki)\n-----END PUBLIC KEY-----\n"), key)
        XCTAssertNil(BlocklistSigningKey.parse("not a key"))
        XCTAssertNil(BlocklistSigningKey.parse(Data(count: 31).base64EncodedString()))
    }
}

// MARK: - Signature and hashes

final class BlocklistVerifierTests: XCTestCase {
    private let maker = BundleMaker()
    private var scratch: URL!

    override func setUpWithError() throws { scratch = try scratchDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private func verify(_ directory: URL, key: Data? = nil, engine: BlocklistEngineVersion? = engine) -> Result<VerifiedBlocklist, BlocklistRejection> {
        BlocklistVerifier.verify(directory: directory, source: .downloaded, publicKeys: [key ?? maker.publicKey], engine: engine)
    }

    private func rejection(_ result: Result<VerifiedBlocklist, BlocklistRejection>) -> BlocklistRejection? {
        if case .failure(let rejection) = result { return rejection }
        return nil
    }

    func testAGoodBundleVerifies() throws {
        let bundle = try verify(maker.make("202611180900", in: scratch)).get()
        XCTAssertEqual(bundle.version.description, "202611180900")
        XCTAssertEqual(bundle.manifest.lists.map(\.id), ["easyprivacy", "peter-lowe", "easylist"])
        XCTAssertEqual(bundle.manifest.lists.first?.title, "Easyprivacy")
        XCTAssertEqual(bundle.manifest.lists.first?.ruleCount, 1)
        XCTAssertEqual(bundle.manifest.lists.map(\.level), [1, 2, 3])
        XCTAssertEqual(bundle.manifest.minEngine, .chromiumMajor(156))
        XCTAssertEqual(bundle.manifest.files.count, 3)
        XCTAssertEqual(bundle.manifest.date, ISO8601DateFormatter().date(from: "2026-11-18T09:00:00Z"))
    }

    func testABadSignatureIsRefused() throws {
        var options = BundleMaker.Options()
        options.foreignKey = true
        XCTAssertEqual(rejection(verify(try maker.make("202611180900", in: scratch, options))), .badSignature, "signed with another key")

        options = BundleMaker.Options()
        options.manifestSuffix = " "
        XCTAssertEqual(rejection(verify(try maker.make("202611180901", in: scratch, options))), .badSignature, "the manifest changed after signing")

        let unsigned = try maker.make("202611180902", in: scratch)
        try FileManager.default.removeItem(at: unsigned.appendingPathComponent("manifest.json.sig"))
        XCTAssertEqual(rejection(verify(unsigned)), .missingSignature)
        try Data("not base64".utf8).write(to: unsigned.appendingPathComponent("manifest.json.sig"))
        XCTAssertEqual(rejection(verify(unsigned)), .badSignature)

        let good = try maker.make("202611180903", in: scratch)
        XCTAssertEqual(rejection(verify(good, key: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)), .badSignature)
        XCTAssertEqual(rejection(BlocklistVerifier.verify(directory: good, source: .downloaded, publicKeys: [], engine: engine)), .noKey,
                       "a build without the lists key uses no bundle")
        XCTAssertEqual(rejection(verify(scratch.appendingPathComponent("nothing"))), .missingManifest)
    }

    // MARK: Several keys (security CB-05)

    func testABundleSignedByAnyOneOfTheKeysVerifies() throws {
        let old = Curve25519.Signing.PrivateKey(), new = Curve25519.Signing.PrivateKey()
        func verify(_ directory: URL, keys: [Data]) -> Result<VerifiedBlocklist, BlocklistRejection> {
            BlocklistVerifier.verify(directory: directory, source: .downloaded, publicKeys: keys, engine: engine)
        }
        var options = BundleMaker.Options()
        options.signer = old
        let signedOld = try maker.make("202611180900", in: scratch, options)
        options.signer = new
        let signedNew = try maker.make("202611180901", in: scratch, options)
        let both = [new.publicKey.rawRepresentation, old.publicKey.rawRepresentation]

        // The release that brings the new key in: bundles from either verify, in either order of keys.
        XCTAssertEqual(try verify(signedOld, keys: both).get().version.description, "202611180900")
        XCTAssertEqual(try verify(signedNew, keys: both).get().version.description, "202611180901")
        XCTAssertNoThrow(try verify(signedOld, keys: both.reversed()).get())
        // The release that drops the old key: what it signed is refused from then on.
        XCTAssertEqual(rejection(verify(signedOld, keys: [new.publicKey.rawRepresentation])), .badSignature)
        XCTAssertNoThrow(try verify(signedNew, keys: [new.publicKey.rawRepresentation]).get())
        // A key that signed nothing here adds nothing.
        XCTAssertEqual(rejection(verify(signedOld, keys: [maker.publicKey, new.publicKey.rawRepresentation])), .badSignature)
        // Bytes that are no key are passed over; with nothing else, there is no key.
        XCTAssertNoThrow(try verify(signedOld, keys: [Data(count: 5), old.publicKey.rawRepresentation]).get())
        XCTAssertEqual(rejection(verify(signedOld, keys: [Data(count: 5)])), .noKey)
        XCTAssertEqual(rejection(verify(signedOld, keys: [])), .noKey)
    }

    func testAChangedManifestVerifiesWithNoneOfTheKeys() throws {
        let old = Curve25519.Signing.PrivateKey()
        var options = BundleMaker.Options()
        options.signer = old
        options.manifestSuffix = " "
        let changed = try maker.make("202611180900", in: scratch, options)
        let result = BlocklistVerifier.verify(directory: changed, source: .downloaded,
                                              publicKeys: [maker.publicKey, old.publicKey.rawRepresentation], engine: engine)
        XCTAssertEqual(rejection(result), .badSignature)
    }

    // MARK: What a signed list may do (security CB-03)

    /// The signature says who wrote a list. This says what a list may do:
    /// block, allow, or allow everything in a page. A signed bundle with any
    /// other action is refused before its directory goes to the engine.
    func testARuleThatDoesMoreThanBlockOrAllowRefusesTheBundle() throws {
        var version = 202_611_180_900
        func result(_ rules: String, list: String = "easylist") throws -> BlocklistRejection? {
            version += 1
            var options = BundleMaker.Options()
            options.rules = [list: rules]
            return rejection(verify(try maker.make(String(version), in: scratch, options)))
        }
        let block = #"{"type":"block"}"#
        XCTAssertNil(try result(BundleMaker.rules(actions: [block, #"{"type":"allow"}"#, #"{"type":"allowAllRequests"}"#])))
        XCTAssertNil(try result("[]"), "an empty list is a list")

        let forbidden = [
            #"{"type":"redirect","redirect":{"url":"https://evil.test/a.js"}}"#: "redirect",
            #"{"type":"upgradeScheme"}"#: "upgradeScheme",
            #"{"type":"modifyHeaders","responseHeaders":[{"header":"content-security-policy","operation":"remove"}]}"#: "modifyHeaders",
            #"{"type":"Block"}"#: "Block",
            #"{"type":""}"#: "",
            #"{}"#: "none",
            #"{"type":7}"#: "none",
        ]
        for (action, name) in forbidden {
            // Last among good rules: every rule is read, not the first.
            XCTAssertEqual(try result(BundleMaker.rules(actions: [block, block, action])),
                           .forbiddenAction(path: "rules/easylist.json", action: name), action)
        }
        XCTAssertEqual(try result(BundleMaker.rules(actions: [#"{"type":"redirect"}"#]), list: "peter-lowe"),
                       .forbiddenAction(path: "rules/peter-lowe.json", action: "redirect"), "in any list of the bundle")

        for notRules in [#"{"id":1}"#, "[1]", #"["block"]"#, #"[{"id":1,"priority":1,"condition":{}}]"#, #"[{"action":"block"}]"#, "not json", ""] {
            XCTAssertEqual(try result(notRules), .badRules("rules/easylist.json"), notRules)
        }
        XCTAssertEqual(BlocklistVerifier.allowedRuleActions, ["block", "allow", "allowAllRequests"])
    }

    func testAHashMismatchIsRefused() throws {
        let bundle = try maker.make("202611180900", in: scratch)
        try Data("[]".utf8).write(to: bundle.appendingPathComponent("rules/easylist.json"))
        XCTAssertEqual(rejection(verify(bundle)), .hashMismatch("rules/easylist.json"))
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("rules/easylist.json"))
        XCTAssertEqual(rejection(verify(bundle)), .missingFile("rules/easylist.json"))
    }

    func testAFileTheManifestDoesNotListIsRefused() throws {
        let extra = try maker.make("202611180900", in: scratch)
        try Data("[]".utf8).write(to: extra.appendingPathComponent("rules/extra.json"))
        XCTAssertEqual(rejection(verify(extra)), .unlistedFile("rules/extra.json"))

        let linked = try maker.make("202611180901", in: scratch)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("rules/passwd.json"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        XCTAssertEqual(rejection(verify(linked)), .unlistedFile("rules/passwd.json"))

        let browsed = try maker.make("202611180902", in: scratch)
        try Data().write(to: browsed.appendingPathComponent(".DS_Store"))
        XCTAssertNoThrow(try verify(browsed).get(), "Finder's own file is passed over")
    }

    func testAWrongMinEngineIsRefused() throws {
        func result(_ minEngine: Any?, _ version: String, on engine: BlocklistEngineVersion? = engine) throws -> BlocklistRejection? {
            var options = BundleMaker.Options()
            options.minEngine = minEngine
            return rejection(verify(try maker.make(version, in: scratch, options), engine: engine))
        }
        XCTAssertNil(try result(156, "202611180900"), "Chromium's major, the one this engine has")
        XCTAssertNil(try result(150, "202611180901"))
        XCTAssertEqual(try result(157, "202611180902"), .engineTooOld)
        XCTAssertNil(try result(nil, "202611180903"), "no requirement")
        XCTAssertEqual(try result("156", "202611180904"), .engineTooOld, "a requirement that is not the integer is not met")
        XCTAssertEqual(try result(156.5, "202611180905"), .engineTooOld)
        XCTAssertEqual(try result(true, "202611180906"), .engineTooOld)
        XCTAssertEqual(try result(160, "202611180907", on: BlocklistEngineVersion(chromium: "159.0.1.2")), .engineTooOld)
        XCTAssertNil(try result(160, "202611180908", on: BlocklistEngineVersion(chromium: "160.0.1.2")))
    }

    func testAManifestThatIsNotFormatOneOrNamesAnotherPathIsRefused() throws {
        let hash = String(repeating: "a", count: 64)
        func decode(format: Any? = 1, path: String = "rules/easylist.json", sha256: Any = String(repeating: "a", count: 64)) throws -> BlocklistManifest {
            var manifest: [String: Any] = ["version": "202611180900",
                                           "lists": [["id": "easylist", "title": "EasyList", "level": 2, "rules": ["path": path, "sha256": sha256]]]]
            manifest["format"] = format
            return try BlocklistManifest.decode(JSONSerialization.data(withJSONObject: manifest))
        }
        XCTAssertEqual(try decode().files, ["rules/easylist.json": hash])
        XCTAssertThrowsError(try decode(format: 2), "a later format is not guessed at")
        XCTAssertThrowsError(try decode(format: nil))
        XCTAssertThrowsError(try decode(path: "../outside.json")) { XCTAssertEqual($0 as? BlocklistRejection, .unsafePath("../outside.json")) }
        XCTAssertThrowsError(try decode(path: "/etc/hosts")) { XCTAssertEqual($0 as? BlocklistRejection, .unsafePath("/etc/hosts")) }
        XCTAssertThrowsError(try decode(path: "manifest.json"))
        XCTAssertThrowsError(try decode(path: "rules/other.json"), "a list's file is rules/<id>.json")
        XCTAssertThrowsError(try decode(sha256: "short"))
        XCTAssertEqual(try decode(sha256: hash.uppercased()).files, ["rules/easylist.json": hash])
        XCTAssertEqual(BlocklistVersion("202611180900")?.date, ISO8601DateFormatter().date(from: "2026-11-18T09:00:00Z"))
        XCTAssertNil(BlocklistVersion("20261118"))
        XCTAssertNil(BlocklistVersion("2026111809oo"))
    }

    // MARK: The bundle in the repository

    /// `shell/Resources/Blocklists` is what the app carries
    /// (`Contents/Resources/Blocklists`): it verifies against the compiled-in
    /// key on the engine this build pins, and its lists and levels are the
    /// table's (spec §2).
    func testTheBuiltInBundleVerifiesAgainstTheCompiledInKey() throws {
        let directory = shellDirectory.appendingPathComponent("Resources/Blocklists", isDirectory: true)
        let bundle = try BlocklistVerifier.verify(directory: directory, source: .builtIn, publicKeys: BlocklistSigningKey.compiledIn,
                                                  engine: BlocklistEngineVersion(chromiumMajor: 156)).get()
        XCTAssertEqual(bundle.manifest.minEngine, .chromiumMajor(156))
        XCTAssertNotNil(bundle.manifest.date)
        for list in bundle.manifest.lists {
            let known = try XCTUnwrap(ContentBlockingLists.known.first { $0.id == list.id }, "the bundle has a list the table lacks: \(list.id)")
            XCTAssertEqual(known.level.map { Int($0.engineValue) } ?? 0, list.level, "\(list.id): the table and the bundle disagree on its level")
            XCTAssertGreaterThan(list.ruleCount ?? 0, 0, list.id)
        }
        let lists = ContentBlockingLists.lists(of: bundle.manifest)
        for level in ContentBlockingLevel.strengths {
            XCTAssertEqual(ContentBlockingSettings(isEnabled: true, strength: level).enabledListIDs(in: lists),
                           ContentBlockingLists.defaults(for: level), "\(level): what the engine is told is spec §2's table")
        }
        XCTAssertEqual(ContentBlockingSettings.newProfile.enabledListIDs(in: lists), ["easyprivacy", "peter-lowe", "easylist"])
        // Every own-rule priority is in the range the engine places above the lists.
        let priorities = [ContentBlockingRuleConverter.Priority.block, ContentBlockingRuleConverter.Priority.allow, ContentBlockingRuleConverter.Priority.importantBlock]
        XCTAssertTrue(priorities.allSatisfy { (1...100).contains($0) })
    }

    /// Its signature file is as the spec says: base64, no newline.
    func testTheBuiltInSignatureIsBase64WithoutANewline() throws {
        let text = try String(contentsOf: shellDirectory.appendingPathComponent("Resources/Blocklists/manifest.json.sig"), encoding: .utf8)
        XCTAssertEqual(Data(base64Encoded: text)?.count, 64)
    }
}

// MARK: - The archive

final class BlocklistArchiveTests: XCTestCase {
    func testFilesAndFoldersUnpack() throws {
        let archive = try gzip([
            tarEntry("blocklists-1/", type: "5"),
            tarEntry("blocklists-1/manifest.json", content: Data("{}".utf8)),
            tarEntry("./blocklists-1/rules/easylist.json", content: Data(repeating: 0x41, count: 700)),
        ])
        let entries = try BlocklistArchive.entries(of: archive)
        XCTAssertEqual(entries.map(\.path), ["blocklists-1/manifest.json", "blocklists-1/rules/easylist.json"])
        XCTAssertEqual(entries[1].data.count, 700)
    }

    func testLinksAndPathsThatLeaveTheFolderRefuseTheWholeArchive() throws {
        func failure(_ entries: [Data]) throws -> BlocklistArchive.Failure? {
            do {
                _ = try BlocklistArchive.entries(of: gzip(entries))
                return nil
            } catch {
                return error as? BlocklistArchive.Failure
            }
        }
        let good = tarEntry("manifest.json", content: Data("{}".utf8))
        XCTAssertEqual(try failure([good, tarEntry("../escape.json", content: Data("x".utf8))]), .unsafeEntry("../escape.json"))
        XCTAssertEqual(try failure([good, tarEntry("/etc/cron.d/x", content: Data("x".utf8))]), .unsafeEntry("/etc/cron.d/x"))
        XCTAssertEqual(try failure([good, tarEntry("rules/a/../../../x", content: Data("x".utf8))]), .unsafeEntry("rules/a/../../../x"))
        XCTAssertEqual(try failure([good, tarEntry("rules/link.json", type: "2", link: "/etc/passwd")]), .unsafeEntry("rules/link.json"))
        XCTAssertEqual(try failure([good, tarEntry("rules/hard.json", type: "1", link: "manifest.json")]), .unsafeEntry("rules/hard.json"))
        XCTAssertEqual(try failure([good, good]), .unsafeEntry("manifest.json"), "one file, once")
    }

    /// CB-01: pax and GNU headers were parsed before the signature was checked, and a pax
    /// record shorter than its own length field, or with a length near Int.max, stopped the
    /// process. The builder writes plain ustar, so every extension header now refuses the archive.
    func testPaxAndGNUHeadersRefuseTheArchiveWithoutBeingRead() throws {
        func failure(_ entries: [Data]) throws -> BlocklistArchive.Failure? {
            do {
                _ = try BlocklistArchive.entries(of: gzip(entries))
                return nil
            } catch {
                return error as? BlocklistArchive.Failure
            }
        }
        let file = tarEntry("manifest.json", content: Data("{}".utf8))
        let shorterThanItsLength = tarEntry("PaxHeaders/x", type: "x", content: Data("1 path=evil\n".utf8))
        let hugeLength = tarEntry("PaxHeaders/y", type: "x", content: Data("9223372036854775806 path=evil\n".utf8))
        let global = tarEntry("PaxHeaders/g", type: "g", content: Data("20 comment=nothing\n".utf8))
        let gnuLongName = tarEntry("././@LongLink", type: "L", content: Data("rules/long.json".utf8))
        for header in [shorterThanItsLength, hugeLength, global, gnuLongName] {
            guard case .unsafeEntry = try failure([header, file]) else {
                return XCTFail("an extension header must refuse the archive")
            }
        }
    }

    func testSizesAreCapped() throws {
        var limits = BlocklistArchive.Limits()
        limits.unpackedBytes = 4096
        let big = try gzip([tarEntry("rules/big.json", content: Data(count: 1 << 20))])
        XCTAssertThrowsError(try BlocklistArchive.entries(of: big, limits: limits)) {
            XCTAssertEqual($0 as? BlocklistArchive.Failure, .tooLarge, "a megabyte of zeros is a kilobyte of gzip")
        }
        limits = BlocklistArchive.Limits()
        limits.archiveBytes = 16
        XCTAssertThrowsError(try BlocklistArchive.entries(of: big, limits: limits))
        limits = BlocklistArchive.Limits()
        limits.files = 1
        let two = try gzip([tarEntry("a.json"), tarEntry("b.json")])
        XCTAssertThrowsError(try BlocklistArchive.entries(of: two, limits: limits))
        XCTAssertThrowsError(try BlocklistArchive.entries(of: Data("not gzip at all, just some text".utf8))) {
            XCTAssertEqual($0 as? BlocklistArchive.Failure, .notGzip)
        }
    }
}

// MARK: - Which bundle is used, and updates

final class BlocklistStoreTests: XCTestCase {
    private let maker = BundleMaker()
    private var scratch: URL!
    private var downloads: URL { scratch.appendingPathComponent("Blocklists", isDirectory: true) }
    private var app: URL { scratch.appendingPathComponent("App", isDirectory: true) }
    private let latestURL = BlocklistMirror.latestURL
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        scratch = try scratchDirectory()
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private func store(builtIn: String? = "202611010000", key: Data? = nil, noKey: Bool = false, keys: [Data]? = nil) throws -> BlocklistStore {
        var builtInURL: URL?
        if let builtIn { builtInURL = try maker.make(builtIn, in: app, named: "Blocklists") }
        let date = now
        return BlocklistStore(configuration: .init(builtIn: builtInURL, downloads: downloads,
                                                   publicKeys: keys ?? (noKey ? [] : [key ?? maker.publicKey]),
                                                   engine: engine, latestURL: latestURL), now: { date })
    }

    private func downloaded() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []).filter { $0 != "state.json" }.sorted()
    }

    func testTheNewestValidBundleIsUsed() async throws {
        let builtInOnly = try store()
        let first = await builtInOnly.load()
        XCTAssertEqual(first?.version.description, "202611010000")
        XCTAssertEqual(first?.source, .builtIn, "works offline and on the first launch")

        try maker.make("202611180900", in: downloads)
        let newer = try await store().load()
        XCTAssertEqual(newer?.version.description, "202611180900")
        XCTAssertEqual(newer?.source, .downloaded)

        // An app update carries newer lists than the last download.
        let updatedApp = try await store(builtIn: "202612010000").load()
        XCTAssertEqual(updatedApp?.source, .builtIn)
        XCTAssertEqual(updatedApp?.version.description, "202612010000")
    }

    func testBadDownloadsAreDeletedAndTheCurrentOneStays() async throws {
        var foreign = BundleMaker.Options()
        foreign.foreignKey = true
        try maker.make("202611200900", in: downloads, foreign)
        let tampered = try maker.make("202611190900", in: downloads)
        try Data("[]".utf8).write(to: tampered.appendingPathComponent("rules/easylist.json"))
        var tooNew = BundleMaker.Options()
        tooNew.minEngine = 160
        try maker.make("202611210900", in: downloads, tooNew)
        try maker.make("202611170900", in: downloads, named: "202611220900") // a version in another version's folder
        try FileManager.default.createDirectory(at: downloads.appendingPathComponent(".incoming-crashed"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: downloads.appendingPathComponent("notes.txt"))
        try maker.make("202611180900", in: downloads)

        let store = try store()
        let active = await store.load()
        XCTAssertEqual(active?.version.description, "202611180900")
        XCTAssertEqual(downloaded(), ["202611180900"], "everything that did not verify is gone")
        let rejections = await store.rejections
        XCTAssertEqual(rejections.count, 5)
        XCTAssertTrue(rejections.contains("202611200900: the signature does not verify"))
        XCTAssertTrue(rejections.contains("202611190900: rules/easylist.json does not match its sha256"))
        XCTAssertTrue(rejections.contains("202611210900: it needs a newer engine"))
    }

    func testOnePreviousBundleIsKept() async throws {
        for version in ["202611150900", "202611160900", "202611170900", "202611180900"] { try maker.make(version, in: downloads) }
        let active = try await store().load()
        XCTAssertEqual(active?.version.description, "202611180900")
        XCTAssertEqual(downloaded(), ["202611170900", "202611180900"], "the one in use and one before it")
    }

    func testWithoutTheListsKeyNothingIsUsed() async throws {
        try maker.make("202611180900", in: downloads)
        let store = try store(noKey: true)
        let active = await store.load()
        XCTAssertNil(active)
        let rejections = await store.rejections
        XCTAssertTrue(rejections.contains("built-in bundle: this build has no lists key"))
    }

    func testANewerBundleIsDownloadedVerifiedAndUsed() async throws {
        let store = try store()
        await store.load()
        let pack = try maker.archive("202611180900", in: scratch)
        let mirror = FakeMirror()
        mirror.pages[latestURL.absoluteString] = pack.latest
        mirror.pages["https://rearc.imara.ae/blocklists/blocklists-202611180900.tar.gz"] = pack.archive

        let outcome = await store.checkForUpdate(using: mirror)
        XCTAssertEqual(outcome, .updated(BlocklistVersion("202611180900")!))
        let active = await store.active
        XCTAssertEqual(active?.source, .downloaded)
        XCTAssertEqual(active?.directory.lastPathComponent, "202611180900")
        XCTAssertEqual(downloaded(), ["202611180900"], "the unpacking folder is gone")
        XCTAssertEqual(mirror.requested, [latestURL.absoluteString, "https://rearc.imara.ae/blocklists/blocklists-202611180900.tar.gz"],
                       "two plain GETs and nothing else")
        let state = await store.updateState
        XCTAssertEqual(state.lastChecked, now)

        let again = await store.checkForUpdate(using: mirror)
        XCTAssertEqual(again, .upToDate)
        XCTAssertEqual(mirror.requested.count, 3, "an up to date check fetches latest.json only")
        let relaunched = try await self.store().load()
        XCTAssertEqual(relaunched?.version.description, "202611180900", "the next launch finds it")
    }

    func testAnOlderVersionIsNotUsed() async throws {
        try maker.make("202611180900", in: downloads)
        let store = try store()
        await store.load()
        let mirror = FakeMirror()
        let old = try maker.archive("202611100900", in: scratch)
        mirror.pages[latestURL.absoluteString] = old.latest
        let outcome = await store.checkForUpdate(using: mirror)
        XCTAssertEqual(outcome, .upToDate, "latest.json names nothing newer: the bundle is not even fetched")
        XCTAssertEqual(mirror.requested, [latestURL.absoluteString])

        // A mirror that names a newer version and serves an older bundle under it.
        mirror.pages[latestURL.absoluteString] = maker.latest("202611190900", archive: old.archive, url: "old.tar.gz")
        mirror.pages["https://rearc.imara.ae/blocklists/old.tar.gz"] = old.archive
        let downgraded = await store.checkForUpdate(using: mirror)
        XCTAssertEqual(downgraded, .rejected("version 202611100900 where 202611190900 was expected"))
        let active = await store.active
        XCTAssertEqual(active?.version.description, "202611180900", "the current one stays")
        XCTAssertEqual(downloaded(), ["202611180900"], "the download is deleted")
    }

    func testADownloadThatDoesNotVerifyIsDeletedAndTheCurrentOneStays() async throws {
        let store = try store()
        await store.load()
        let mirror = FakeMirror()
        func check(_ pack: (archive: Data, latest: Data), version: String) async -> BlocklistUpdateOutcome {
            mirror.pages[latestURL.absoluteString] = pack.latest
            mirror.pages["https://rearc.imara.ae/blocklists/blocklists-\(version).tar.gz"] = pack.archive
            return await store.checkForUpdate(using: mirror)
        }

        var foreign = BundleMaker.Options()
        foreign.foreignKey = true
        let badSignature = await check(try maker.archive("202611180900", in: scratch, foreign), version: "202611180900")
        XCTAssertEqual(badSignature, .rejected("the signature does not verify"))

        var tooNew = BundleMaker.Options()
        tooNew.minEngine = 157
        let wrongEngine = await check(try maker.archive("202611180901", in: scratch, tooNew), version: "202611180901")
        XCTAssertEqual(wrongEngine, .rejected("it needs a newer engine"))

        // The bundle's bytes are not the ones latest.json promised.
        var pack = try maker.archive("202611180902", in: scratch)
        pack.archive.append(0)
        let wrongHash = await check(pack, version: "202611180902")
        XCTAssertEqual(wrongHash, .rejected("the download does not match latest.json's sha256"))

        let junk = Data("this is not an archive".utf8)
        mirror.pages[latestURL.absoluteString] = maker.latest("202611180903", archive: junk)
        mirror.pages["https://rearc.imara.ae/blocklists/blocklists-202611180903.tar.gz"] = junk
        let notAnArchive = await store.checkForUpdate(using: mirror)
        guard case .rejected = notAnArchive else { return XCTFail("\(notAnArchive)") }

        let active = await store.active
        XCTAssertEqual(active?.source, .builtIn, "the bundle in use never changed")
        XCTAssertEqual(downloaded(), [], "nothing that failed is left on disk")
    }

    /// Security CB-03: a bundle the lists key signed is still refused when
    /// one of its rules redirects a request or changes headers. It never
    /// becomes the bundle in use, so its directory never goes to the engine.
    func testASignedDownloadWhoseRulesDoMoreThanBlockOrAllowIsDeleted() async throws {
        let store = try store()
        await store.load()
        var redirecting = BundleMaker.Options()
        redirecting.rules = ["easylist": BundleMaker.rules(actions: [#"{"type":"block"}"#, #"{"type":"redirect","redirect":{"url":"https://evil.test/a.js"}}"#])]
        let pack = try maker.archive("202611180900", in: scratch, redirecting)
        let mirror = FakeMirror()
        mirror.pages[latestURL.absoluteString] = pack.latest
        mirror.pages["https://rearc.imara.ae/blocklists/blocklists-202611180900.tar.gz"] = pack.archive

        let outcome = await store.checkForUpdate(using: mirror)
        XCTAssertEqual(outcome, .rejected("rules/easylist.json has a rule that neither blocks nor allows (redirect)"))
        let active = await store.active
        XCTAssertEqual(active?.source, .builtIn, "the bundle in use never changed")
        XCTAssertEqual(downloaded(), [], "the download is deleted")

        // One that got onto disk another way is deleted at the next launch.
        var stripping = BundleMaker.Options()
        stripping.rules = ["peter-lowe": BundleMaker.rules(actions: [#"{"type":"modifyHeaders","responseHeaders":[{"header":"x-frame-options","operation":"remove"}]}"#])]
        try maker.make("202611190900", in: downloads, stripping)
        let relaunched = try self.store()
        let used = await relaunched.load()
        XCTAssertEqual(used?.source, .builtIn)
        XCTAssertEqual(downloaded(), [])
        let rejections = await relaunched.rejections
        XCTAssertEqual(rejections, ["202611190900: rules/peter-lowe.json has a rule that neither blocks nor allows (modifyHeaders)"])
    }

    /// Security CB-05: while the lists key is replaced, the app trusts the
    /// new key and the old one, and the mirror's bundle may carry either.
    func testADownloadSignedByEitherOfTwoKeysIsUsed() async throws {
        let old = Curve25519.Signing.PrivateKey()
        var signedOld = BundleMaker.Options()
        signedOld.signer = old
        let mirror = FakeMirror()
        func check(_ store: BlocklistStore, _ version: String, _ options: BundleMaker.Options) async throws -> BlocklistUpdateOutcome {
            let pack = try maker.archive(version, in: scratch, options)
            mirror.pages[latestURL.absoluteString] = pack.latest
            mirror.pages["https://rearc.imara.ae/blocklists/blocklists-\(version).tar.gz"] = pack.archive
            return await store.checkForUpdate(using: mirror)
        }
        // The built-in bundle is the maker's; the mirror still serves one the old key signed.
        let both = try store(keys: [maker.publicKey, old.publicKey.rawRepresentation])
        await both.load()
        let fromOld = try await check(both, "202611180900", signedOld)
        XCTAssertEqual(fromOld, .updated(BlocklistVersion("202611180900")!))
        let fromNew = try await check(both, "202611180901", BundleMaker.Options())
        XCTAssertEqual(fromNew, .updated(BlocklistVersion("202611180901")!))

        // The release after: the old key is gone, and so is what only it signed.
        let newOnly = try store(keys: [maker.publicKey])
        let active = await newOnly.load()
        XCTAssertEqual(active?.version.description, "202611180901")
        XCTAssertEqual(downloaded(), ["202611180901"], "the bundle the dropped key signed is deleted")
        let late = try await check(newOnly, "202611180902", signedOld)
        XCTAssertEqual(late, .rejected("the signature does not verify"))
    }

    func testOnlyTheMirrorIsEverAsked() async throws {
        let store = try store()
        await store.load()
        let mirror = FakeMirror()
        let pack = try maker.archive("202611180900", in: scratch)
        for url in ["https://evil.test/blocklists/b.tar.gz", "http://rearc.imara.ae/blocklists/b.tar.gz", "https://rearc.imara.ae/other/b.tar.gz",
                    "https://rearc.imara.ae/blocklists/../b.tar.gz", "https://rearc.imara.ae/blocklists/b.tar.gz?install=1",
                    "https://rearc.imara.ae:8443/blocklists/b.tar.gz", "https://user@rearc.imara.ae/blocklists/b.tar.gz"] {
            mirror.pages[latestURL.absoluteString] = maker.latest("202611180900", archive: pack.archive, url: url)
            mirror.pages[url] = pack.archive
            let outcome = await store.checkForUpdate(using: mirror)
            XCTAssertEqual(outcome, .unreachable, url)
        }
        XCTAssertEqual(Set(mirror.requested), [latestURL.absoluteString], "no bundle URL off the mirror's folder was fetched")
        XCTAssertNil(latestURL.query)
        XCTAssertEqual(latestURL.absoluteString, "https://rearc.imara.ae/blocklists/latest.json")

        mirror.pages[latestURL.absoluteString] = nil
        let offline = await store.checkForUpdate(using: mirror)
        XCTAssertEqual(offline, .unreachable)
        let state = await store.updateState
        XCTAssertEqual(state.lastAttempt, now)
    }

    /// The mirror's files as the pipeline writes them (`build-blocklists.py
    /// pack` of the repository's bundle): the shell downloads, unpacks and
    /// verifies them with the compiled-in key.
    func testTheArchiveThePipelinePacksIsAccepted() async throws {
        let script = shellDirectory.appendingPathComponent("scripts/blocklists/build-blocklists.py")
        let out = scratch.appendingPathComponent("mirror", isDirectory: true)
        do {
            _ = try runTool("/usr/bin/env", ["python3", script.path, "pack", shellDirectory.appendingPathComponent("Resources/Blocklists").path, "--out", out.path])
        } catch {
            throw XCTSkip("build-blocklists.py pack did not run here (python3, or its Ed25519 tool, is missing)")
        }
        let latest = try Data(contentsOf: out.appendingPathComponent("latest.json"))
        let named = try XCTUnwrap(BlocklistLatest.decode(latest, from: latestURL), "latest.json is not {version, url, sha256} on the mirror")
        XCTAssertEqual(named.url.absoluteString, "https://rearc.imara.ae/blocklists/blocklists-\(named.version).tar.gz")
        let mirror = FakeMirror()
        mirror.pages[latestURL.absoluteString] = latest
        mirror.pages[named.url.absoluteString] = try Data(contentsOf: out.appendingPathComponent("blocklists-\(named.version).tar.gz"))

        let store = BlocklistStore(configuration: .init(builtIn: nil, downloads: downloads, engine: BlocklistEngineVersion(chromiumMajor: 156)))
        let outcome = await store.checkForUpdate(using: mirror)
        XCTAssertEqual(outcome, .updated(named.version))
        let active = await store.active
        XCTAssertEqual(active?.manifest.lists.map(\.id), ["easyprivacy", "peter-lowe", "easylist", "fanboy-annoyance", "easylist-cookie"])
        XCTAssertEqual(downloaded(), [named.version.description])
    }

    func testTheCheckIsDailyAndOnlyWhileBlockingIsOnSomewhere() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func due(_ on: Bool, checked: TimeInterval? = nil, attempt: TimeInterval? = nil) -> Bool {
            BlocklistMirror.isCheckDue(blockingOn: on, state: BlocklistUpdateState(lastChecked: checked.map { now.addingTimeInterval(-$0) },
                                                                                  lastAttempt: attempt.map { now.addingTimeInterval(-$0) }), now: now)
        }
        XCTAssertFalse(due(false), "blocking off in every profile: ReArc asks the mirror for nothing")
        XCTAssertFalse(due(false, checked: 30 * 86400))
        XCTAssertTrue(due(true), "never checked")
        XCTAssertFalse(due(true, checked: 23 * 3600))
        XCTAssertTrue(due(true, checked: 24 * 3600))
        XCTAssertFalse(due(true, checked: 3 * 86400, attempt: 600), "a failed check waits an hour")
        XCTAssertTrue(due(true, checked: 3 * 86400, attempt: 3601))
        XCTAssertTrue(due(true, checked: -3600), "a check dated in the future (the clock moved) does not stop checks")
    }
}

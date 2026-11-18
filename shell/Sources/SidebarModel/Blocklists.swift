import CryptoKit
import Foundation

// A blocklist bundle (docs/FEATURE-SPECS/CONTENT-BLOCKING.md §4, "As built", format 1):
//
//     manifest.json        format, version, created, min_engine, lists[…]; each list's
//                          `rules` has the `path` and `sha256` of its rules file
//     manifest.json.sig    Ed25519 signature over manifest.json's bytes, base64
//     rules/<list-id>.json DNR rule arrays
//
// Trust rests on the lists key alone: a bundle is used only when the
// signature verifies against the compiled-in public key and every file in
// the directory is one the signed manifest lists, with its hash.

/// The lists key's public half, compiled into the app. Never the Sparkle
/// key (spec §4 "Signing key").
public enum BlocklistSigningKey {
    /// The key in `shell/scripts/blocklists/blocklists-public-key.txt`:
    /// base64 of the raw 32 bytes. `BlocklistSigningKeyTests` fails when the
    /// two differ, so a new key cannot ship in the file alone.
    public static let compiledInText = "JzoQqIp57WYVyAiycJEzp8MuiD08WZ5jnZDUa8CzJEQ="

    /// The compiled-in key's 32 raw bytes.
    public static let compiledIn: Data? = parse(compiledInText)

    /// A public key file's text: the 32 raw bytes in base64 or hex, or the
    /// 44-byte SubjectPublicKeyInfo form (`openssl pkey -pubout`), with or
    /// without PEM armour. Lines starting with `#` are comments.
    public static func parse(_ text: String) -> Data? {
        let body = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("-----") }
            .joined()
        var bytes: Data?
        if body.count == 64, body.allSatisfy(\.isHexDigit) {
            bytes = Data(stride(from: 0, to: 64, by: 2).compactMap { offset in
                let start = body.index(body.startIndex, offsetBy: offset)
                return UInt8(body[start..<body.index(start, offsetBy: 2)], radix: 16)
            })
        } else {
            bytes = Data(base64Encoded: body)
        }
        // SubjectPublicKeyInfo for Ed25519: a fixed 12-byte header, then the key.
        let header = Data([0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00])
        if let der = bytes, der.count == 44, der.prefix(12) == header { bytes = Data(der.dropFirst(12)) }
        guard let key = bytes, key.count == 32, key.contains(where: { $0 != 0 }),
              (try? Curve25519.Signing.PublicKey(rawRepresentation: key)) != nil else { return nil }
        return key
    }
}

/// A bundle's version: `YYYYMMDDHHMM`, compared as a number.
public struct BlocklistVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let value: UInt64

    /// Exactly twelve digits, as the mirror and the directory name spell it.
    public init?(_ text: String) {
        guard text.utf8.count == 12, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let value = UInt64(text) else { return nil }
        self.value = value
    }

    public var description: String { String(format: "%012llu", value) }

    public static func < (lhs: BlocklistVersion, rhs: BlocklistVersion) -> Bool { lhs.value < rhs.value }

    /// The version's own time (UTC), when the manifest has no `created`.
    public var date: Date? {
        var parts = DateComponents()
        parts.calendar = Calendar(identifier: .gregorian)
        parts.timeZone = TimeZone(identifier: "UTC")
        parts.year = Int(value / 100_000_000)
        parts.month = Int(value / 1_000_000 % 100)
        parts.day = Int(value / 10_000 % 100)
        parts.hour = Int(value / 100 % 100)
        parts.minute = Int(value % 100)
        return parts.isValidDate ? parts.date : nil
    }
}

/// The running engine, for a manifest's `min_engine`: Chromium's major version.
public struct BlocklistEngineVersion: Equatable, Sendable {
    public var chromiumMajor: Int

    public init(chromiumMajor: Int) {
        self.chromiumMajor = chromiumMajor
    }

    /// From Chromium's version text, `156.0.8078.109`.
    public init(chromium: String) {
        chromiumMajor = chromium.split(separator: ".").first.flatMap { Int($0) } ?? 0
    }

    /// A requirement this build cannot read is not met.
    public func meets(_ requirement: BlocklistManifest.EngineRequirement) -> Bool {
        switch requirement {
        case .none: return true
        case .chromiumMajor(let major): return chromiumMajor >= major
        case .unreadable: return false
        }
    }
}

/// A bundle's signed `manifest.json`, as much of it as the shell uses.
public struct BlocklistManifest: Equatable, Sendable {
    /// The manifest format this build reads.
    public static let format = 1

    public struct List: Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var homepage: String?
        public var license: String?
        /// The lowest blocking level with the list (1, 2 or 3); 0 for a regional list.
        public var level: Int
        /// The list's DNR rule count.
        public var ruleCount: Int?

        public init(id: String, title: String, homepage: String? = nil, license: String? = nil, level: Int = 0, ruleCount: Int? = nil) {
            self.id = id
            self.title = title
            self.homepage = homepage
            self.license = license
            self.level = level
            self.ruleCount = ruleCount
        }
    }

    public enum EngineRequirement: Equatable, Sendable {
        case none
        /// `min_engine`: an integer, Chromium's major version.
        case chromiumMajor(Int)
        case unreadable
    }

    public var version: BlocklistVersion
    public var created: Date?
    public var minEngine: EngineRequirement
    public var lists: [List]
    /// Every file of the bundle by its path in it, with its lowercase sha256.
    public var files: [String: String]

    /// The date "Lists last updated" shows.
    public var date: Date? { created ?? version.date }

    /// Reads a format 1 manifest. Each list names one file, `rules.path`
    /// (always `rules/<id>.json`) with `rules.sha256`. Keys this build does
    /// not use (`priorities`, `limits`, a list's `source` and `filters`) are
    /// passed over; another `format` is refused.
    public static func decode(_ data: Data) throws -> BlocklistManifest {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BlocklistRejection.badManifest("not a JSON object")
        }
        guard let format = integer(root["format"]), format == Self.format else {
            throw BlocklistRejection.badManifest("format \(root["format"].map { "\($0)" } ?? "missing"), not \(Self.format)")
        }
        guard let version = (root["version"] as? String).flatMap(BlocklistVersion.init) else { throw BlocklistRejection.badManifest("no version") }
        guard let entries = root["lists"] as? [[String: Any]], !entries.isEmpty else { throw BlocklistRejection.badManifest("no lists") }

        var files: [String: String] = [:]
        var lists: [List] = []
        for entry in entries {
            guard let id = entry["id"] as? String, ContentBlockingSettings.isListID(id) else { throw BlocklistRejection.badManifest("a list without an id") }
            guard !lists.contains(where: { $0.id == id }) else { throw BlocklistRejection.badManifest("list \(id) twice") }
            guard let rules = entry["rules"] as? [String: Any], let path = rules["path"] as? String else {
                throw BlocklistRejection.badManifest("no rules file for \(id)")
            }
            guard isSafePath(path) else { throw BlocklistRejection.unsafePath(path) }
            guard path == "rules/\(id).json" else { throw BlocklistRejection.badManifest("\(path) is not rules/\(id).json") }
            guard let hash = (rules["sha256"] as? String)?.lowercased(), hash.utf8.count == 64, hash.allSatisfy(\.isHexDigit) else {
                throw BlocklistRejection.badManifest("no sha256 for \(path)")
            }
            files[path] = hash
            lists.append(List(id: id, title: (entry["title"] as? String) ?? id, homepage: entry["homepage"] as? String,
                              license: entry["license"] as? String, level: integer(entry["level"]) ?? 0, ruleCount: integer(rules["count"])))
        }

        var created: Date?
        if let text = root["created"] as? String { created = ISO8601DateFormatter().date(from: text) }

        let minEngine: EngineRequirement
        switch root["min_engine"] {
        case nil, is NSNull: minEngine = .none
        case let value?: minEngine = integer(value).map(EngineRequirement.chromiumMajor) ?? .unreadable
        }
        return BlocklistManifest(version: version, created: created, minEngine: minEngine, lists: lists, files: files)
    }

    /// A JSON whole number that is not a boolean and not negative.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue), number.intValue >= 0 else { return nil }
        return number.intValue
    }

    public static let fileName = "manifest.json"
    public static let signatureFileName = "manifest.json.sig"

    /// A relative path of plain names: no `..`, no leading `/`, no
    /// backslash, and not the manifest or its signature.
    static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 512, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        return path != fileName && path != signatureFileName
    }
}

/// Why a bundle is not used.
public enum BlocklistRejection: Error, Equatable, Sendable {
    /// The app has no lists key yet (`BlocklistSigningKey.isPlaceholder`).
    case noKey
    case missingManifest
    case missingSignature
    case badSignature
    case badManifest(String)
    case unsafePath(String)
    /// The manifest lists a file the bundle does not have.
    case missingFile(String)
    case hashMismatch(String)
    /// The bundle has a file (or a link) the signed manifest does not list.
    case unlistedFile(String)
    /// The directory is named for another version than the manifest's.
    case versionMismatch(expected: String, found: String)
    case engineTooOld
    /// Not newer than the bundle in use.
    case notNewer(inUse: String, found: String)

    public var text: String {
        switch self {
        case .noKey: return "this build has no lists key"
        case .missingManifest: return "no manifest.json"
        case .missingSignature: return "no manifest.json.sig"
        case .badSignature: return "the signature does not verify"
        case .badManifest(let why): return "the manifest is not usable (\(why))"
        case .unsafePath(let path): return "the manifest names a path outside the bundle (\(path))"
        case .missingFile(let path): return "\(path) is missing"
        case .hashMismatch(let path): return "\(path) does not match its sha256"
        case .unlistedFile(let path): return "\(path) is not in the manifest"
        case .versionMismatch(let expected, let found): return "version \(found) where \(expected) was expected"
        case .engineTooOld: return "it needs a newer engine"
        case .notNewer(let inUse, let found): return "version \(found) is not newer than \(inUse)"
        }
    }
}

/// A bundle whose signature and files were checked.
public struct VerifiedBlocklist: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case builtIn, downloaded }

    public var directory: URL
    public var manifest: BlocklistManifest
    public var source: Source

    public var version: BlocklistVersion { manifest.version }
}

public enum BlocklistVerifier {
    /// Checks the bundle in `directory`: the signature over the manifest's
    /// bytes, then the manifest, then every file. `engine` nil skips the
    /// `min_engine` check (tests, and a shell that does not know its engine).
    public static func verify(
        directory: URL,
        source: VerifiedBlocklist.Source,
        publicKey: Data?,
        engine: BlocklistEngineVersion?,
        fileManager: FileManager = .default
    ) -> Result<VerifiedBlocklist, BlocklistRejection> {
        guard let publicKey, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return .failure(.noKey) }
        guard let manifestData = try? Data(contentsOf: directory.appendingPathComponent(BlocklistManifest.fileName)) else {
            return .failure(.missingManifest)
        }
        guard let signatureText = try? String(contentsOf: directory.appendingPathComponent(BlocklistManifest.signatureFileName), encoding: .utf8) else {
            return .failure(.missingSignature)
        }
        // The signature first: nothing in an unsigned manifest is read.
        guard let signature = Data(base64Encoded: signatureText.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.isValidSignature(signature, for: manifestData) else { return .failure(.badSignature) }
        let manifest: BlocklistManifest
        do {
            manifest = try BlocklistManifest.decode(manifestData)
        } catch let rejection as BlocklistRejection {
            return .failure(rejection)
        } catch {
            return .failure(.badManifest("\(error)"))
        }
        if let engine, !engine.meets(manifest.minEngine) { return .failure(.engineTooOld) }

        // Every file there is must be listed, and every listed file must match.
        let found: [String]
        switch regularFiles(in: directory, fileManager: fileManager) {
        case .failure(let rejection): return .failure(rejection)
        case .success(let paths): found = paths
        }
        for path in found where path != BlocklistManifest.fileName && path != BlocklistManifest.signatureFileName && manifest.files[path] == nil {
            return .failure(.unlistedFile(path))
        }
        for (path, expected) in manifest.files.sorted(by: { $0.key < $1.key }) {
            guard found.contains(path) else { return .failure(.missingFile(path)) }
            guard sha256(of: directory.appendingPathComponent(path)) == expected else { return .failure(.hashMismatch(path)) }
        }
        return .success(VerifiedBlocklist(directory: directory, manifest: manifest, source: source))
    }

    /// The bundle's regular files by relative path. A link or anything else
    /// that is neither a file nor a directory is refused; Finder's
    /// `.DS_Store` is passed over.
    static func regularFiles(in directory: URL, fileManager: FileManager) -> Result<[String], BlocklistRejection> {
        // By path: the walker then gives each entry relative to the bundle and does not follow links.
        guard let walker = fileManager.enumerator(atPath: directory.path) else { return .failure(.missingManifest) }
        var paths: [String] = []
        while let path = walker.nextObject() as? String {
            switch walker.fileAttributes?[.type] as? FileAttributeType {
            case .typeDirectory?:
                continue
            case .typeRegular?:
                if (path as NSString).lastPathComponent != ".DS_Store" { paths.append(path) }
            default:
                return .failure(.unlistedFile(path))
            }
        }
        return .success(paths)
    }

    /// The file's sha256 in lowercase hex, read in pieces; nil when it cannot be read.
    public static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            // Nothing, or no bytes, is the end of the file.
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hex(hasher.finalize())
    }

    public static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

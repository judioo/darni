import Foundation

/// The network for list updates, as a seam: the shell's implementation is a
/// plain GET with no cookies, cache or identifiers
/// (`URLSessionBlocklistFetcher`), and a test replaces it.
public protocol BlocklistFetching: Sendable {
    /// The body of `url`, at most `limit` bytes; throws on anything else.
    func data(from url: URL, limit: Int) async throws -> Data
}

/// The mirror's `/blocklists/latest.json`: `{version, url, sha256}`.
public struct BlocklistLatest: Equatable, Sendable {
    public var version: BlocklistVersion
    /// The `.tar.gz` bundle, on the mirror's own host and under its folder.
    public var url: URL
    public var sha256: String

    /// nil for anything but a version, a bundle URL on the mirror and a sha256.
    public static func decode(_ data: Data, from latestURL: URL) -> BlocklistLatest? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let versionText = (root["version"] as? String) ?? (root["version"] as? NSNumber).map({ String(format: "%012llu", $0.uint64Value) }),
              let version = BlocklistVersion(versionText),
              let hash = (root["sha256"] as? String)?.lowercased(), hash.utf8.count == 64, hash.allSatisfy(\.isHexDigit),
              let text = root["url"] as? String,
              let url = URL(string: text, relativeTo: latestURL)?.absoluteURL,
              BlocklistMirror.isMirrorURL(url, for: latestURL) else { return nil }
        return BlocklistLatest(version: version, url: url, sha256: hash)
    }
}

public enum BlocklistMirror {
    /// Spec §4: the only place ReArc fetches lists from.
    public static let latestURL = URL(string: "https://rearc.imara.ae/blocklists/latest.json")!
    /// Once a day, and no sooner than an hour after a check that failed.
    public static let checkInterval: TimeInterval = 24 * 3600
    public static let retryInterval: TimeInterval = 3600
    public static let latestLimit = 64 << 10

    /// Anything is fetched only over https from the mirror's own host, from
    /// the folder `latest.json` is in, with nothing in the URL but the path
    /// (spec §6: no list fetch except from `rearc.imara.ae`).
    public static func isMirrorURL(_ url: URL, for latestURL: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: true), parts.scheme == "https",
              let host = parts.host?.lowercased(), host == latestURL.host?.lowercased(),
              parts.port == nil, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return false }
        let folder = latestURL.deletingLastPathComponent().path
        return url.standardized.path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") && !parts.path.contains("..")
    }

    /// Whether a check is due. Never while blocking is off in every profile:
    /// then ReArc asks the mirror for nothing.
    public static func isCheckDue(blockingOn: Bool, state: BlocklistUpdateState, now: Date) -> Bool {
        guard blockingOn else { return false }
        if let checked = state.lastChecked, now.timeIntervalSince(checked) < checkInterval, now >= checked { return false }
        if let attempt = state.lastAttempt, now.timeIntervalSince(attempt) < retryInterval, now >= attempt { return false }
        return true
    }
}

/// When the mirror was last asked, kept in the Blocklists folder.
public struct BlocklistUpdateState: Equatable, Codable, Sendable {
    public static let fileName = "state.json"

    /// The last check that got an answer from the mirror.
    public var lastChecked: Date?
    /// The last check that was started.
    public var lastAttempt: Date?

    public init(lastChecked: Date? = nil, lastAttempt: Date? = nil) {
        self.lastChecked = lastChecked
        self.lastAttempt = lastAttempt
    }
}

/// What a check ended with.
public enum BlocklistUpdateOutcome: Equatable, Sendable {
    /// The mirror has nothing newer than the bundle in use.
    case upToDate
    /// A newer bundle was verified and is now the one in use.
    case updated(BlocklistVersion)
    /// The mirror could not be reached or its answer was not readable.
    case unreachable
    /// The download was not used and is gone; the bundle in use stays.
    case rejected(String)

    public var text: String {
        switch self {
        case .upToDate: return "The lists are up to date."
        case .updated: return "The lists were updated."
        case .unreachable: return "ReArc couldn’t reach the lists. It will try again later."
        case .rejected: return "The new lists could not be verified and were not used."
        }
    }
}

/// Picks the blocklist bundle the engine gets (spec §4 "Updates in the
/// app"): the newest valid one of the copy built into the app and the ones
/// downloaded to `<data>/Blocklists/<version>/`. A downloaded bundle that
/// does not verify is deleted; the newest and the one before it are kept.
///
/// An actor: loading hashes every file and a check downloads, and neither
/// runs on the main thread or twice at once.
public actor BlocklistStore {
    public struct Configuration: Sendable {
        /// The bundle inside the app, when the build has one.
        public var builtIn: URL?
        /// `<data>/Blocklists`.
        public var downloads: URL
        /// The lists keys' raw bytes: a bundle signed by any one is used.
        /// None refuses every bundle.
        public var publicKeys: [Data]
        public var engine: BlocklistEngineVersion?
        public var latestURL: URL
        public var limits: BlocklistArchive.Limits

        public init(builtIn: URL?, downloads: URL, publicKeys: [Data] = BlocklistSigningKey.compiledIn,
                    engine: BlocklistEngineVersion? = nil, latestURL: URL = BlocklistMirror.latestURL,
                    limits: BlocklistArchive.Limits = BlocklistArchive.Limits()) {
            self.builtIn = builtIn
            self.downloads = downloads
            self.publicKeys = publicKeys
            self.engine = engine
            self.latestURL = latestURL
            self.limits = limits
        }
    }

    public static let folderName = "Blocklists"
    /// Downloaded bundles kept: the one in use and one before it.
    public static let keptDownloads = 2
    static let incomingPrefix = ".incoming-"

    private let configuration: Configuration
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    /// The bundle in use, once `load` ran.
    public private(set) var active: VerifiedBlocklist?
    /// Why bundles were refused, newest last (logs and tests).
    public private(set) var rejections: [String] = []

    public init(configuration: Configuration, fileManager: FileManager = .default, now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.now = now
    }

    private var stateURL: URL { configuration.downloads.appendingPathComponent(BlocklistUpdateState.fileName) }

    public var updateState: BlocklistUpdateState {
        guard let data = try? Data(contentsOf: stateURL) else { return BlocklistUpdateState() }
        return (try? JSONDecoder().decode(BlocklistUpdateState.self, from: data)) ?? BlocklistUpdateState()
    }

    private func save(_ state: BlocklistUpdateState) {
        try? fileManager.createDirectory(at: configuration.downloads, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    /// Verifies the built-in bundle and every downloaded one, deletes the
    /// downloaded ones that fail and the ones too old to keep, and returns
    /// the newest valid bundle (the built-in one when versions are equal).
    @discardableResult
    public func load() -> VerifiedBlocklist? {
        var downloaded: [VerifiedBlocklist] = []
        let children = (try? fileManager.contentsOfDirectory(at: configuration.downloads, includingPropertiesForKeys: nil)) ?? []
        for child in children {
            let name = child.lastPathComponent
            if name == BlocklistUpdateState.fileName || name == ".DS_Store" { continue }
            // What a download left behind (this one's own folder, or a crashed one's).
            if name.hasPrefix(Self.incomingPrefix) {
                try? fileManager.removeItem(at: child)
                continue
            }
            guard let version = BlocklistVersion(name) else {
                remove(child, because: "not a bundle")
                continue
            }
            switch verify(child, source: .downloaded) {
            case .success(let bundle) where bundle.version == version:
                downloaded.append(bundle)
            case .success(let bundle):
                remove(child, because: BlocklistRejection.versionMismatch(expected: name, found: bundle.version.description).text)
            case .failure(let rejection):
                remove(child, because: rejection.text)
            }
        }
        downloaded.sort { $0.version > $1.version }
        for stale in downloaded.dropFirst(Self.keptDownloads) { remove(stale.directory, because: "older than the kept bundles") }
        downloaded = Array(downloaded.prefix(Self.keptDownloads))

        var builtIn: VerifiedBlocklist?
        if let directory = configuration.builtIn {
            switch verify(directory, source: .builtIn) {
            case .success(let bundle): builtIn = bundle
            case .failure(let rejection): rejections.append("built-in bundle: \(rejection.text)")
            }
        }
        if let newest = downloaded.first, newest.version.value > (builtIn?.version.value ?? 0) {
            active = newest
        } else {
            active = builtIn
        }
        return active
    }

    /// Asks the mirror for `latest.json` and, when it names a newer bundle,
    /// downloads, checks and installs it. The bundle in use changes only on
    /// `.updated`. The caller decides whether a check is due
    /// (`BlocklistMirror.isCheckDue`); Check Now always asks.
    public func checkForUpdate(using fetcher: BlocklistFetching) async -> BlocklistUpdateOutcome {
        var state = updateState
        state.lastAttempt = now()
        save(state)
        guard let answer = try? await fetcher.data(from: configuration.latestURL, limit: BlocklistMirror.latestLimit),
              let latest = BlocklistLatest.decode(answer, from: configuration.latestURL) else { return .unreachable }
        state.lastChecked = now()
        save(state)
        if let active, latest.version <= active.version { return .upToDate }

        guard let archive = try? await fetcher.data(from: latest.url, limit: configuration.limits.archiveBytes) else { return .unreachable }
        guard BlocklistVerifier.sha256(of: archive) == latest.sha256 else { return reject("the download does not match latest.json's sha256") }

        // Unpacked beside the bundles under a name that is no version, so a
        // launch that finds it (a crash here) deletes it.
        let incoming = configuration.downloads.appendingPathComponent(Self.incomingPrefix + UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: incoming) }
        do {
            try? fileManager.createDirectory(at: configuration.downloads, withIntermediateDirectories: true)
            try BlocklistArchive.extract(archive, to: incoming, limits: configuration.limits, fileManager: fileManager)
        } catch {
            return reject("the archive could not be unpacked (\(error))")
        }
        let bundle: VerifiedBlocklist
        switch verify(bundleRoot(in: incoming), source: .downloaded) {
        case .failure(let rejection): return reject(rejection.text)
        case .success(let verified): bundle = verified
        }
        guard bundle.version == latest.version else {
            return reject(BlocklistRejection.versionMismatch(expected: latest.version.description, found: bundle.version.description).text)
        }
        if let active, bundle.version <= active.version {
            return reject(BlocklistRejection.notNewer(inUse: active.version.description, found: bundle.version.description).text)
        }

        let home = configuration.downloads.appendingPathComponent(bundle.version.description, isDirectory: true)
        do {
            if fileManager.fileExists(atPath: home.path) { try fileManager.removeItem(at: home) }
            try fileManager.moveItem(at: bundle.directory, to: home)
        } catch {
            return reject("the bundle could not be put in place (\(error.localizedDescription))")
        }
        // Checked again where it now is, and the older bundles thinned out.
        guard load()?.version == bundle.version else { return reject("the bundle did not verify in place") }
        return .updated(bundle.version)
    }

    /// The archive holds the bundle's files, or one folder with them (`blocklists-<version>/`).
    private func bundleRoot(in directory: URL) -> URL {
        if fileManager.fileExists(atPath: directory.appendingPathComponent(BlocklistManifest.fileName).path) { return directory }
        let children = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != ".DS_Store" }
        if children.count == 1, fileManager.fileExists(atPath: children[0].appendingPathComponent(BlocklistManifest.fileName).path) {
            return children[0]
        }
        return directory
    }

    private func verify(_ directory: URL, source: VerifiedBlocklist.Source) -> Result<VerifiedBlocklist, BlocklistRejection> {
        BlocklistVerifier.verify(directory: directory, source: source, publicKeys: configuration.publicKeys,
                                 engine: configuration.engine, fileManager: fileManager)
    }

    private func remove(_ url: URL, because reason: String) {
        rejections.append("\(url.lastPathComponent): \(reason)")
        try? fileManager.removeItem(at: url)
    }

    private func reject(_ reason: String) -> BlocklistUpdateOutcome {
        rejections.append("download: \(reason)")
        return .rejected(reason)
    }
}

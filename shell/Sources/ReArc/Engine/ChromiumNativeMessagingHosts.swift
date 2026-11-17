import Foundation
import SidebarModel

/// Native messaging hosts (Chromium's `NativeMessagingHosts` in the
/// user-data-dir): how an extension talks to its desktop app, as 1Password's
/// does to unlock with the app. Apps install their manifest only for browsers
/// they know, so ReArc's folder stays empty. At launch ReArc copies in the
/// allowed manifests already installed for Arc and Chrome; each still names
/// its own extensions in `allowed_origins`, so only they can use it. A
/// manifest ReArc did not copy is never touched; copied ones follow their
/// source and go when it goes or stops being allowed (the ledger records
/// which they are). Security review of 41876855: allowlist, not every host.
enum ChromiumNativeMessagingHosts {
    static let directoryName = "NativeMessagingHosts"
    static let ledgerName = ".rearc-copied.json"
    static let maximumManifestSize = 64 * 1024

    /// Hosts copied without asking. The bar for a name here: the host
    /// authenticates its caller itself (1Password checks the browser's
    /// signature and talks only to browsers the person has added in its
    /// settings: `OnePasswordConnect` shows that step). Anything else waits
    /// for a per-host switch in Settings, off by default.
    static let allowedNamePrefixes = ["com.1password."]

    /// Arc first (ReArc's people come from it), then Chrome.
    static var sourceDirectories: [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return [
            support.appendingPathComponent("Arc/User Data/\(directoryName)", isDirectory: true),
            support.appendingPathComponent("Google/Chrome/\(directoryName)", isDirectory: true),
        ]
    }

    /// The person's own engine folder.
    static var defaultUserDataDir: URL {
        ShellDataLocation.defaultRoot.appendingPathComponent("Chromium", isDirectory: true)
    }

    /// Only a shipped run on the person's own data: not a verification
    /// bundle, a `REARC_DATA_DIR` launch, the self-test or the bench (as
    /// `AppBundleIcon.defaultWrites`), nor any other engine folder (a
    /// development bundle given `--user-data-dir`), so throwaway profiles
    /// never get the owner's hosts and test runs never read Arc's folder.
    static func runs(testSwitches: Bool, userDataDir: URL,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
                     ownUserDataDir: URL = defaultUserDataDir) -> Bool {
        if testSwitches || ShippedBuild.isVerificationBundle(infoDictionary: infoDictionary) { return false }
        guard environment[ShellDataLocation.environmentKey]?.isEmpty ?? true else { return false }
        return userDataDir.standardizedFileURL.path == ownUserDataDir.standardizedFileURL.path
    }

    /// A plain manifest file name: no path, not hidden (the ledger's own
    /// name included), `.json`. Names from the ledger pass this too.
    static func isPlainManifestName(_ name: String) -> Bool {
        !name.contains("/") && !name.hasPrefix(".") && name.hasSuffix(".json") && name.count > ".json".count
    }

    static func isAllowed(_ name: String) -> Bool {
        isPlainManifestName(name) && allowedNamePrefixes.contains { name.hasPrefix($0) }
    }

    /// `name` is the file's stem, `type` stdio, `path` an existing
    /// executable (an uninstalled app's manifest is left behind; the copy
    /// comes and goes with the app), and `allowed_origins` a non-empty list
    /// of extension origins. Chromium checks most of this again; this keeps
    /// junk out of the folder.
    static func isValidManifest(_ data: Data, fileName: String,
                                isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Bool {
        validHostPath(data, fileName: fileName, isExecutable: isExecutable) != nil
    }

    /// A valid manifest's `path`: the executable the engine starts for it.
    private static func validHostPath(_ data: Data, fileName: String, isExecutable: (String) -> Bool) -> String? {
        guard data.count <= maximumManifestSize,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["name"] as? String == String(fileName.dropLast(".json".count)),
              json["type"] as? String == "stdio",
              let path = json["path"] as? String, path.hasPrefix("/"), isExecutable(path),
              let origins = json["allowed_origins"] as? [String], !origins.isEmpty,
              origins.allSatisfy(isExtensionOrigin) else { return nil }
        return path
    }

    /// The helper the engine starts for `host`, from the manifest ReArc
    /// itself copied into `userDataDir`: allowed, in the ledger, and valid
    /// when read again. nil for a manifest ReArc did not copy. This reads
    /// ReArc's own copy only, never the app's files
    /// (`OnePasswordConnection` knows 1Password's helper by this path).
    static func copiedHostPath(named host: String, in userDataDir: URL,
                               isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        let name = host + ".json"
        let target = userDataDir.appendingPathComponent(directoryName, isDirectory: true)
        guard isAllowed(name),
              let ledger = try? JSONDecoder().decode([String].self, from: Data(contentsOf: target.appendingPathComponent(ledgerName))),
              ledger.contains(name),
              let data = readManifest(at: target.appendingPathComponent(name)) else { return nil }
        return validHostPath(data, fileName: name, isExecutable: isExecutable)
    }

    /// The manifest's bytes, read only when its size allows.
    private static func readManifest(at url: URL) -> Data? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size <= maximumManifestSize else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func isExtensionOrigin(_ origin: String) -> Bool {
        let prefix = "chrome-extension://"
        guard origin.hasPrefix(prefix), origin.hasSuffix("/") else { return false }
        let id = origin.dropFirst(prefix.count).dropLast()
        return id.count == 32 && id.allSatisfy { $0.isASCII && ("a"..."p").contains($0) }
    }

    /// Returns the manifest names copied or updated.
    @discardableResult
    static func mirror(into userDataDir: URL, from sources: [URL] = sourceDirectories,
                       isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> [String] {
        let fm = FileManager.default
        let target = userDataDir.appendingPathComponent(directoryName, isDirectory: true)
        let ledgerURL = target.appendingPathComponent(ledgerName)
        let ledger = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: ledgerURL))) ?? []
        var copied = Set(ledger.filter(isPlainManifestName))

        var wanted: [String: Data] = [:]
        for source in sources {
            let names = (try? fm.contentsOfDirectory(atPath: source.path)) ?? []
            for name in names.sorted() where isAllowed(name) && wanted[name] == nil {
                guard let data = readManifest(at: source.appendingPathComponent(name)),
                      isValidManifest(data, fileName: name, isExecutable: isExecutable) else { continue }
                wanted[name] = data
            }
        }

        var changed: [String] = []
        if !wanted.isEmpty { try? fm.createDirectory(at: target, withIntermediateDirectories: true) }
        for (name, data) in wanted.sorted(by: { $0.key < $1.key }) {
            let destination = target.appendingPathComponent(name)
            let exists = fm.fileExists(atPath: destination.path)
            guard !exists || copied.contains(name) else { continue }
            if exists, (try? Data(contentsOf: destination)) == data { continue }
            guard (try? data.write(to: destination, options: .atomic)) != nil else { continue }
            copied.insert(name)
            changed.append(name)
        }
        for name in copied where wanted[name] == nil {
            try? fm.removeItem(at: target.appendingPathComponent(name))
            copied.remove(name)
        }
        if fm.fileExists(atPath: target.path) {
            try? JSONEncoder().encode(copied.sorted()).write(to: ledgerURL, options: .atomic)
        }
        return changed
    }
}

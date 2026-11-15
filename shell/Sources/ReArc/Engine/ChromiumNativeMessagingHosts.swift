import Foundation

/// Native messaging hosts (Chromium's `NativeMessagingHosts` in the
/// user-data-dir): how an extension talks to its desktop app, as 1Password's
/// does to unlock with the app. Apps install their manifest only for browsers
/// they know, so ReArc's folder stays empty. At launch ReArc copies in the
/// manifests already installed for Arc and Chrome; each still names its own
/// extensions in `allowed_origins`, so only they can use it. A manifest ReArc
/// did not copy is never touched; copied ones follow their source and go when
/// it goes (the ledger records which they are).
enum ChromiumNativeMessagingHosts {
    static let directoryName = "NativeMessagingHosts"
    static let ledgerName = ".rearc-copied.json"

    /// Arc first (ReArc's people come from it), then Chrome.
    static var sourceDirectories: [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return [
            support.appendingPathComponent("Arc/User Data/\(directoryName)", isDirectory: true),
            support.appendingPathComponent("Google/Chrome/\(directoryName)", isDirectory: true),
        ]
    }

    /// Returns the manifest names copied or updated.
    @discardableResult
    static func mirror(into userDataDir: URL, from sources: [URL] = sourceDirectories) -> [String] {
        let fm = FileManager.default
        let target = userDataDir.appendingPathComponent(directoryName, isDirectory: true)
        let ledgerURL = target.appendingPathComponent(ledgerName)
        var copied = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: ledgerURL))) ?? [])

        var wanted: [String: URL] = [:]
        for source in sources {
            let names = (try? fm.contentsOfDirectory(atPath: source.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".json") && wanted[name] == nil {
                wanted[name] = source.appendingPathComponent(name)
            }
        }

        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        var changed: [String] = []
        for (name, source) in wanted.sorted(by: { $0.key < $1.key }) {
            let destination = target.appendingPathComponent(name)
            let exists = fm.fileExists(atPath: destination.path)
            guard !exists || copied.contains(name),
                  let data = try? Data(contentsOf: source),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { continue }
            if exists, (try? Data(contentsOf: destination)) == data { continue }
            guard (try? data.write(to: destination, options: .atomic)) != nil else { continue }
            copied.insert(name)
            changed.append(name)
        }
        for name in copied where wanted[name] == nil {
            try? fm.removeItem(at: target.appendingPathComponent(name))
            copied.remove(name)
        }
        try? JSONEncoder().encode(copied.sorted()).write(to: ledgerURL, options: .atomic)
        return changed
    }
}

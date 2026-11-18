#if REARC_CHROMIUM
import Darwin
import Foundation
import ReArcEngine
import SidebarModel

/// The engine's content blocking entry points (CONTENT-BLOCKING.md §5,
/// engine patch `tab/095-content-blocker-component`). They are newer than
/// the header this shell builds against, so each is looked up with `dlsym`
/// and typed here, as `ReArcProfileOpenDirectory` is. Profiles and tabs are
/// the ABI's 64-bit IDs.
///
/// An engine without all five has no blocking: `resolve` is nil, nothing
/// attaches to the model, and every blocking surface stays hidden. The
/// count's change callback has no name in the spec yet, so the shell reads
/// `ReArcTabGetBlockedCount` while the site controls panel is open.
struct ChromiumContentBlockingCalls {
    typealias SetDirectory = @convention(c) (UnsafePointer<CChar>?) -> Void
    typealias SetBlocking = @convention(c) (UInt64, Int32, UnsafePointer<CChar>?) -> Void
    typealias SetJSON = @convention(c) (UInt64, UnsafePointer<CChar>?) -> Void
    typealias BlockedCount = @convention(c) (UInt64) -> UInt32

    static let symbols = [
        "ReArcEngineSetBlocklistDirectory", "ReArcProfileSetContentBlocking", "ReArcProfileSetBlockingExceptions",
        "ReArcProfileSetOwnBlockingRules", "ReArcTabGetBlockedCount",
    ]

    let setDirectory: SetDirectory
    let setBlocking: SetBlocking
    let setExceptions: SetJSON
    let setOwnRules: SetJSON
    let blockedCount: BlockedCount

    /// Every symbol, or nothing: half an interface is not used.
    static func resolve() -> ChromiumContentBlockingCalls? {
        let found = symbols.map { dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0) }
        guard found.allSatisfy({ $0 != nil }) else { return nil }
        return ChromiumContentBlockingCalls(
            setDirectory: unsafeBitCast(found[0], to: SetDirectory.self),
            setBlocking: unsafeBitCast(found[1], to: SetBlocking.self),
            setExceptions: unsafeBitCast(found[2], to: SetJSON.self),
            setOwnRules: unsafeBitCast(found[3], to: SetJSON.self),
            blockedCount: unsafeBitCast(found[4], to: BlockedCount.self)
        )
    }

    /// The symbols this engine lacks (the self-test's ABI-GAP line).
    static var missingSymbols: [String] {
        symbols.filter { dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0) == nil }
    }
}

/// `ContentBlockingEngine` over the C ABI. Main thread, as every ABI call.
final class ChromiumContentBlockingEngine: ContentBlockingEngine {
    private unowned let runtime: ChromiumRuntime
    private let calls: ChromiumContentBlockingCalls

    init(runtime: ChromiumRuntime, calls: ChromiumContentBlockingCalls) {
        self.runtime = runtime
        self.calls = calls
    }

    private var isUsable: Bool { runtime.isReady && !runtime.isStopping }

    func setBlocklistDirectory(_ directory: URL) {
        guard isUsable else { return }
        ChromiumLog.info("content blocking: bundle \(directory.path)")
        directory.path.withCString { calls.setDirectory($0) }
    }

    func setContentBlocking(engineProfile: UInt64, level: ContentBlockingLevel, enabledListIDs: [String]) {
        guard isUsable else { return }
        ChromiumLog.info("content blocking: profile \(engineProfile) level \(level.engineValue) lists \(enabledListIDs)")
        Self.json(enabledListIDs).withCString { calls.setBlocking(engineProfile, level.engineValue, $0) }
    }

    func setBlockingExceptions(engineProfile: UInt64, hosts: [String]) {
        guard isUsable else { return }
        // The count only: which sites are excepted stays out of the log.
        ChromiumLog.info("content blocking: profile \(engineProfile) has \(hosts.count) site exception(s)")
        Self.json(hosts).withCString { calls.setExceptions(engineProfile, $0) }
    }

    func setOwnBlockingRules(engineProfile: UInt64, dnrRulesJSON: String) {
        guard isUsable else { return }
        ChromiumLog.trace("content blocking: profile \(engineProfile) own rules, \(dnrRulesJSON.utf8.count) bytes of DNR JSON")
        dnrRulesJSON.withCString { calls.setOwnRules(engineProfile, $0) }
    }

    /// Requests blocked in the tab's current page (a main-frame navigation resets it).
    func blockedCount(tab: UInt64) -> Int? {
        guard isUsable, tab != 0 else { return nil }
        return Int(calls.blockedCount(tab))
    }

    private static func json(_ strings: [String]) -> String {
        (try? String(decoding: JSONEncoder().encode(strings), as: UTF8.self)) ?? "[]"
    }
}

extension ChromiumContentBlockingEngine {
    /// At ready: an engine with the blocking calls attaches to the model,
    /// and every profile that is already open gets its settings. Without
    /// the calls nothing happens here, and the app is as it was before blocking.
    @MainActor
    static func attach(to model: BrowserViewModel, runtime: ChromiumRuntime) {
        guard let calls = ChromiumContentBlockingCalls.resolve() else {
            ChromiumLog.info("content blocking: this engine lacks \(ChromiumContentBlockingCalls.missingSymbols.joined(separator: ", ")); blocking is hidden")
            return
        }
        let engine = ChromiumContentBlockingEngine(runtime: runtime, calls: calls)
        model.onContentBlockingEvent = { ChromiumLog.info("content blocking: \($0)") }
        model.contentBlocking.blockedCount = { [weak engine] page in
            (page as? ChromiumEngine).flatMap { engine?.blockedCount(tab: $0.tabID) }
        }
        runtime.onEngineProfileOpened = { [weak model] key, engineProfile in
            model?.contentBlockingProfileOpened(engineProfile: engineProfile, profile: key.parentProfileID)
        }
        runtime.onEngineProfileClosed = { [weak model] engineProfile in
            model?.contentBlockingProfileClosed(engineProfile: engineProfile)
        }
        model.attachContentBlocking(
            engine: engine,
            engineVersion: BlocklistEngineVersion(
                chromium: String(cString: ReArcEngineVersion()),
                bridge: String(cString: ReArcEngineBridgeVersion()),
                abiMinor: Int(runtime.capabilities.abiMinorVersion ?? 0)
            )
        )
        for key in runtime.openProfileKeys {
            guard let engineProfile = runtime.engineProfileID(for: key) else { continue }
            model.contentBlockingProfileOpened(engineProfile: engineProfile, profile: key.parentProfileID)
        }
    }
}
#endif

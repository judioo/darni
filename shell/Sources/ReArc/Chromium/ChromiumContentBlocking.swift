#if REARC_CHROMIUM
import Darwin
import Foundation
import ReArcEngine
import SidebarModel

/// The engine's content blocking entry points (ABI 1.66, feature
/// `content_blocking`; C-ABI.md "Content blocking", engine patch
/// `tab/095-content-blocker-component`). They are newer than the header this
/// shell builds against, so each is looked up with `dlsym` and typed here,
/// as `ReArcProfileOpenDirectory` is. Profiles and tabs are the ABI's 64-bit IDs.
///
/// An engine without the feature or without all six symbols has no
/// blocking: `resolve` is nil, nothing attaches to the model, and every
/// blocking surface stays hidden.
struct ChromiumContentBlockingCalls {
    typealias SetDirectory = @convention(c) (UnsafePointer<CChar>?) -> ReArcStatus
    typealias SetBlocking = @convention(c) (UInt64, Int32, UnsafePointer<CChar>?) -> ReArcStatus
    typealias SetJSON = @convention(c) (UInt64, UnsafePointer<CChar>?) -> ReArcStatus
    typealias BlockedCount = @convention(c) (UInt64) -> UInt32
    typealias BlockedCountCallback = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt32) -> Void
    typealias SetBlockedCountCallback = @convention(c) (BlockedCountCallback?, UnsafeMutableRawPointer?) -> Void

    static let symbols = [
        "ReArcEngineSetBlocklistDirectory", "ReArcProfileSetContentBlocking", "ReArcProfileSetBlockingExceptions",
        "ReArcProfileSetOwnBlockingRules", "ReArcTabGetBlockedCount", "ReArcEngineSetBlockedCountCallback",
    ]

    let setDirectory: SetDirectory
    let setBlocking: SetBlocking
    let setExceptions: SetJSON
    let setOwnRules: SetJSON
    let blockedCount: BlockedCount
    let setBlockedCountCallback: SetBlockedCountCallback

    /// Every symbol, or nothing: half an interface is not used.
    static func resolve() -> ChromiumContentBlockingCalls? {
        let found = symbols.map { dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0) }
        guard found.allSatisfy({ $0 != nil }) else { return nil }
        return ChromiumContentBlockingCalls(
            setDirectory: unsafeBitCast(found[0], to: SetDirectory.self),
            setBlocking: unsafeBitCast(found[1], to: SetBlocking.self),
            setExceptions: unsafeBitCast(found[2], to: SetJSON.self),
            setOwnRules: unsafeBitCast(found[3], to: SetJSON.self),
            blockedCount: unsafeBitCast(found[4], to: BlockedCount.self),
            setBlockedCountCallback: unsafeBitCast(found[5], to: SetBlockedCountCallback.self)
        )
    }

    /// The symbols this engine lacks (logs, and the self-test's ABI-GAP line).
    static var missingSymbols: [String] {
        symbols.filter { dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0) == nil }
    }
}

private let blockedCountCallback: ChromiumContentBlockingCalls.BlockedCountCallback = { context, _, _ in
    guard let context else { return }
    let engine = Unmanaged<ChromiumContentBlockingEngine>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { engine.onBlockedCountChanged?() }
}

/// `ContentBlockingEngine` over the C ABI. Main thread, as every ABI call.
/// It lives as long as the model that holds it (the app's lifetime), so the
/// count callback's context is unretained.
final class ChromiumContentBlockingEngine: ContentBlockingEngine {
    private unowned let runtime: ChromiumRuntime
    private let calls: ChromiumContentBlockingCalls
    /// Some tab's blocked count changed (at most every 250 ms).
    var onBlockedCountChanged: (() -> Void)?

    init(runtime: ChromiumRuntime, calls: ChromiumContentBlockingCalls) {
        self.runtime = runtime
        self.calls = calls
    }

    private var isUsable: Bool { runtime.isReady && !runtime.isStopping }

    private func report(_ call: String, _ status: ReArcStatus) {
        if status != .rearcOK { ChromiumLog.info("content blocking: \(call) rejected: \(status.rearcName)") }
    }

    func listenForBlockedCounts() {
        calls.setBlockedCountCallback(blockedCountCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    func setBlocklistDirectory(_ directory: URL) {
        guard isUsable else { return }
        ChromiumLog.info("content blocking: bundle \(directory.path)")
        report("ReArcEngineSetBlocklistDirectory", directory.path.withCString { calls.setDirectory($0) })
    }

    func setContentBlocking(engineProfile: UInt64, level: ContentBlockingLevel, enabledListIDs: [String]) {
        guard isUsable else { return }
        ChromiumLog.info("content blocking: profile \(engineProfile) level \(level.engineValue) lists \(enabledListIDs)")
        report("ReArcProfileSetContentBlocking(\(engineProfile))",
               Self.json(enabledListIDs).withCString { calls.setBlocking(engineProfile, level.engineValue, $0) })
    }

    func setBlockingExceptions(engineProfile: UInt64, hosts: [String]) {
        guard isUsable else { return }
        // The count only: which sites are excepted stays out of the log.
        ChromiumLog.info("content blocking: profile \(engineProfile) has \(hosts.count) site exception(s)")
        report("ReArcProfileSetBlockingExceptions(\(engineProfile))", Self.json(hosts).withCString { calls.setExceptions(engineProfile, $0) })
    }

    func setOwnBlockingRules(engineProfile: UInt64, dnrRulesJSON: String) {
        guard isUsable else { return }
        ChromiumLog.trace("content blocking: profile \(engineProfile) own rules, \(dnrRulesJSON.utf8.count) bytes of DNR JSON")
        report("ReArcProfileSetOwnBlockingRules(\(engineProfile))", dnrRulesJSON.withCString { calls.setOwnRules(engineProfile, $0) })
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
    /// At ready: an engine with `content_blocking` attaches to the model,
    /// and every persistent profile that is already open gets its state.
    /// Without the feature nothing happens here, and the app is as it was
    /// before blocking. Private windows follow their profile in the engine:
    /// an off-the-record profile gets no call (it would be `invalid_argument`).
    @MainActor
    static func attach(to model: BrowserViewModel, runtime: ChromiumRuntime) {
        guard runtime.capabilities.contentBlocking, let calls = ChromiumContentBlockingCalls.resolve() else {
            let missing = ChromiumContentBlockingCalls.missingSymbols
            ChromiumLog.info("content blocking: not in this engine (feature \(runtime.capabilities.contentBlocking ? "advertised" : "not advertised")"
                + (missing.isEmpty ? "" : ", missing \(missing.joined(separator: ", "))") + "); blocking is hidden")
            return
        }
        let engine = ChromiumContentBlockingEngine(runtime: runtime, calls: calls)
        engine.onBlockedCountChanged = { [weak model] in model?.contentBlocking.blockedCountChanged() }
        engine.listenForBlockedCounts()
        model.onContentBlockingEvent = { ChromiumLog.info("content blocking: \($0)") }
        model.contentBlocking.blockedCount = { [weak engine] page in
            (page as? ChromiumEngine).flatMap { engine?.blockedCount(tab: $0.tabID) }
        }
        runtime.onEngineProfileOpened = { [weak model] key, engineProfile in
            guard !key.isOffTheRecord else { return }
            model?.contentBlockingProfileOpened(engineProfile: engineProfile, profile: key.parentProfileID)
        }
        runtime.onEngineProfileClosed = { [weak model] engineProfile in
            model?.contentBlockingProfileClosed(engineProfile: engineProfile)
        }
        model.attachContentBlocking(engine: engine, engineVersion: BlocklistEngineVersion(chromium: String(cString: ReArcEngineVersion())))
        for key in runtime.openProfileKeys where !key.isOffTheRecord {
            guard let engineProfile = runtime.engineProfileID(for: key) else { continue }
            model.contentBlockingProfileOpened(engineProfile: engineProfile, profile: key.parentProfileID)
        }
    }
}
#endif

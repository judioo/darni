#if REARC_CHROMIUM
import Darwin
import Foundation
import ReArcEngine
import SidebarModel

/// The engine's dark mode entry points (ABI 1.73, feature
/// `website_dark_mode`; C-ABI.md "Dark mode for websites", engine patch
/// `tab/105-website-dark-mode`). They are newer than the header this shell
/// builds against, so each is looked up with `dlsym` and typed here, as the
/// content blocking calls are.
///
/// An engine without the feature or without both symbols has no dark mode:
/// `resolve` is nil, nothing attaches to the model, and the setting and the
/// site controls row stay hidden.
struct ChromiumWebsiteDarkModeCalls {
    /// `ReArcStatus ReArcProfileSetWebsiteDarkMode(uint64_t profile_id, bool dark,
    /// const char* dark_hosts_json, const char* light_hosts_json)`
    typealias SetDarkMode = @convention(c) (UInt64, Bool, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> ReArcStatus
    /// `ReArcStatus ReArcTabGetWebsiteDarkMode(uint64_t tab_id, bool* dark)`
    typealias GetDarkMode = @convention(c) (UInt64, UnsafeMutablePointer<Bool>?) -> ReArcStatus

    static let symbols = ["ReArcProfileSetWebsiteDarkMode", "ReArcTabGetWebsiteDarkMode"]

    let set: SetDarkMode
    let get: GetDarkMode

    /// Both symbols, or nothing: half an interface is not used.
    static func resolve() -> ChromiumWebsiteDarkModeCalls? {
        guard let found = ChromiumSymbols.resolve(symbols) else { return nil }
        return ChromiumWebsiteDarkModeCalls(set: unsafeBitCast(found[0], to: SetDarkMode.self),
                                            get: unsafeBitCast(found[1], to: GetDarkMode.self))
    }

    /// The symbols this engine lacks (logs, and the self-test's ABI-GAP line).
    static var missingSymbols: [String] { ChromiumSymbols.missing(symbols) }
}

/// `WebsiteDarkModeEngine` over the C ABI. Main thread, as every ABI call.
final class ChromiumWebsiteDarkModeEngine: WebsiteDarkModeEngine {
    private unowned let runtime: ChromiumRuntime
    private let calls: ChromiumWebsiteDarkModeCalls
    /// The engine's answer to the last call (the self-test reads it).
    private(set) var lastStatus: ReArcStatus = .rearcOK

    init(runtime: ChromiumRuntime, calls: ChromiumWebsiteDarkModeCalls) {
        self.runtime = runtime
        self.calls = calls
    }

    private var isUsable: Bool { runtime.isReady && !runtime.isStopping }

    func setWebsiteDarkMode(engineProfile: UInt64, state: WebsiteDarkMode.EngineState) {
        guard isUsable else { return }
        // The counts only: which sites have a choice stays out of the log.
        ChromiumLog.info("dark mode: profile \(engineProfile) dark \(state.dark), \(state.darkHosts.count) site(s) on, \(state.lightHosts.count) off")
        let status = Self.json(state.darkHosts).withCString { dark in
            Self.json(state.lightHosts).withCString { light in calls.set(engineProfile, state.dark, dark, light) }
        }
        lastStatus = status
        if status != .rearcOK { ChromiumLog.info("dark mode: ReArcProfileSetWebsiteDarkMode(\(engineProfile)) rejected: \(status.rearcName)") }
    }

    /// Whether the tab's page is dark by the engine's own word; nil when it cannot say.
    func isDark(tab: UInt64) -> Bool? {
        guard isUsable, tab != 0 else { return nil }
        var dark = false
        return calls.get(tab, &dark) == .rearcOK ? dark : nil
    }

    /// The most rows the engine gives for one history query (C-ABI.md, ABI 1.23).
    static let historyQueryLimit: UInt32 = 1000

    private static func json(_ strings: [String]) -> String {
        (try? String(decoding: JSONEncoder().encode(strings), as: UTF8.self)) ?? "[]"
    }

    /// At ready, after content blocking has attached (it sets the runtime's
    /// profile hooks; this adds to them): an engine with `website_dark_mode`
    /// attaches to the model, and every persistent profile that is already
    /// open gets its state. Without the feature nothing happens here.
    @MainActor
    static func attach(to model: BrowserViewModel, runtime: ChromiumRuntime) {
        guard runtime.capabilities.websiteDarkMode, let calls = ChromiumWebsiteDarkModeCalls.resolve() else {
            let missing = ChromiumWebsiteDarkModeCalls.missingSymbols
            ChromiumLog.info("dark mode: not in this engine (feature \(runtime.capabilities.websiteDarkMode ? "advertised" : "not advertised")"
                + (missing.isEmpty ? "" : ", missing \(missing.joined(separator: ", "))") + "); the setting is hidden")
            return
        }
        let engine = ChromiumWebsiteDarkModeEngine(runtime: runtime, calls: calls)
        model.websiteDarkMode.covers = { $0 is ChromiumEngine }
        model.websiteDarkMode.isDarkInEngine = { page in (page as? ChromiumEngine).flatMap { engine.isDark(tab: $0.tabID) } }
        let opened = runtime.onEngineProfileOpened
        runtime.onEngineProfileOpened = { [weak model] key, engineProfile in
            opened?(key, engineProfile)
            guard !key.isOffTheRecord else { return }
            model?.websiteDarkModeProfileOpened(engineProfile: engineProfile, profile: key.parentProfileID)
        }
        let closed = runtime.onEngineProfileClosed
        runtime.onEngineProfileClosed = { [weak model] engineProfile in
            closed?(engineProfile)
            model?.websiteDarkModeProfileClosed(engineProfile: engineProfile)
        }
        // The sites are kept only while history has them (security DM-1): the profile's
        // HistoryService is asked through the ABI's query, as the command bar and site search
        // ask it. The addresses go to the check that asked and are neither kept nor logged.
        model.websiteDarkMode.historyQuery = { [weak runtime] storage, text, reply in
            guard let runtime, runtime.capabilities.historyQuery else { return reply(nil) }
            runtime.withEngineProfile(.persistent(storage)) { [weak runtime] engineProfile in
                guard let runtime, let engineProfile else { return reply(nil) }
                let status = runtime.queryHistory(profile: engineProfile, text: text, limit: historyQueryLimit) { status, rows in
                    reply(status == .rearcOK ? rows.map(\.url) : nil)
                }
                if status != .rearcOK { reply(nil) }
            }
        }
        model.attachWebsiteDarkMode(engine: engine)
        for key in runtime.openProfileKeys where !key.isOffTheRecord {
            guard let engineProfile = runtime.engineProfileID(for: key) else { continue }
            model.websiteDarkModeProfileOpened(engineProfile: engineProfile, profile: key.parentProfileID)
        }
    }
}
#endif

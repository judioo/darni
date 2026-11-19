#if REARC_CHROMIUM
import Darwin
import Foundation
import ReArcEngine
import SidebarModel

/// The engine's answer to "what site is this host" (ABI 1.69, feature
/// `host_sites`; C-ABI.md "Host sites", engine patch `tab/098-blocked-hosts`):
/// Chromium's public suffix list, which the shell does not have. One call,
/// newer than the header this shell builds against, so it is looked up by
/// name. `SiteNames` is where the shell asks; this hands it the call.
enum ChromiumHostSites {
    /// `ReArcStatus ReArcEngineCopySiteOfHost(const char* utf8_host, char** json)`:
    /// the JSON is the engine's allocation and is freed with `ReArcBufferFree`.
    typealias CopySiteOfHost = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> ReArcStatus

    static let symbol = "ReArcEngineCopySiteOfHost"

    static func resolve() -> CopySiteOfHost? {
        ChromiumSymbols.address(symbol).map { unsafeBitCast($0, to: CopySiteOfHost.self) }
    }

    /// At ready: an engine with `host_sites` becomes the shell's namer of
    /// sites. Without it `SiteNames.shared` stays nil and every user keeps
    /// its own narrower rule.
    @MainActor
    static func attach(runtime: ChromiumRuntime) {
        guard runtime.capabilities.hostSites, let copy = resolve() else {
            return ChromiumLog.info("host sites: not in this engine (feature \(runtime.capabilities.hostSites ? "advertised, \(symbol) missing" : "not advertised")); "
                + "the shell names a site by its own rules")
        }
        SiteNames.shared = SiteNames { [weak runtime] host in
            // Every ABI call is the main thread's. Elsewhere there is no answer, and the caller's own rule holds.
            guard Thread.isMainThread, let runtime, runtime.isReady, !runtime.isStopping else { return nil }
            return reply(copy, host)
        }
    }

    /// The engine's JSON for `host`; nil when it refuses the name. Neither
    /// the name nor the reply is logged: they are hosts of the person's pages.
    static func reply(_ copy: CopySiteOfHost, _ host: String) -> String? {
        var json: UnsafeMutablePointer<CChar>?
        let status = host.withCString { copy($0, &json) }
        defer { if let json { ReArcBufferFree(json) } }
        guard status == .rearcOK, let json, strnlen(json, SiteNames.maxReplyBytes + 1) <= SiteNames.maxReplyBytes else { return nil }
        return String(cString: json)
    }
}
#endif

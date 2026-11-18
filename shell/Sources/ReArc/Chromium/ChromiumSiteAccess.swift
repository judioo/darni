#if REARC_CHROMIUM
import Darwin
import Foundation
import ReArcEngine
import SidebarModel

/// The engine's site permission entry points (ABI 1.67, feature
/// `site_permissions`; C-ABI.md "Site permissions", engine patch
/// `tab/096-site-permissions`). They are newer than the header this shell
/// builds against, so each is looked up with `dlsym` and typed here, as the
/// content blocking calls are. The state crosses as JSON and scalars: there
/// is no struct to mirror.
///
/// An engine without the feature or without all four symbols reports
/// nothing: `resolve` is nil, no engine's `SiteAccessModel` gets its calls,
/// and the site panel shows the shell's own record as before.
struct ChromiumSiteAccessCalls {
    typealias Completion = @convention(c) (UnsafeMutableRawPointer?, ReArcStatus, UInt64, UnsafePointer<CChar>?) -> Void
    typealias Get = @convention(c) (UInt64, Completion?, UnsafeMutableRawPointer?) -> ReArcStatus
    typealias SetPermission = @convention(c) (UInt64, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt32) -> ReArcStatus
    typealias RevokeDevice = @convention(c) (UInt64, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> ReArcStatus
    typealias Changed = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    typealias SetChanged = @convention(c) (Changed?, UnsafeMutableRawPointer?) -> Void

    static let symbols = [
        "ReArcTabGetSitePermissions", "ReArcTabSetSitePermission", "ReArcTabRevokeSiteDevice",
        "ReArcEngineSetSitePermissionsChangedCallback",
    ]

    let get: Get
    let setPermission: SetPermission
    let revokeDevice: RevokeDevice
    let setChanged: SetChanged

    /// Every symbol, or nothing: half an interface is not used.
    static func resolve() -> ChromiumSiteAccessCalls? {
        guard let found = ChromiumSymbols.resolve(symbols) else { return nil }
        return ChromiumSiteAccessCalls(
            get: unsafeBitCast(found[0], to: Get.self),
            setPermission: unsafeBitCast(found[1], to: SetPermission.self),
            revokeDevice: unsafeBitCast(found[2], to: RevokeDevice.self),
            setChanged: unsafeBitCast(found[3], to: SetChanged.self)
        )
    }

    static var missingSymbols: [String] {
        ChromiumSymbols.missing(symbols)
    }
}

/// One answer's receiver, retained from the call to its completion.
private final class SiteAccessReceiver {
    let receive: (SiteAccess?) -> Void
    init(_ receive: @escaping (SiteAccess?) -> Void) { self.receive = receive }
}

private let siteAccessCompletion: ChromiumSiteAccessCalls.Completion = { context, status, _, json in
    guard let context else { return }
    let receiver = Unmanaged<SiteAccessReceiver>.fromOpaque(context).takeRetainedValue()
    // The string is borrowed for the callback: decoded here.
    let access = status == .rearcOK ? json.flatMap { SiteAccess(json: String(cString: $0)) } : nil
    MainActor.assumeIsolated { receiver.receive(access) }
}

private let siteAccessChanged: ChromiumSiteAccessCalls.Changed = { context, tabID in
    guard let context else { return }
    MainActor.assumeIsolated {
        Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue().engine(forTab: tabID)?.siteAccess.refresh()
    }
}

/// The one engine's site permission channel. Main thread, as every ABI call.
enum ChromiumSiteAccessChannel {
    private(set) static var calls: ChromiumSiteAccessCalls?
    private(set) static weak var runtime: ChromiumRuntime?

    /// At `ready`, before any tab exists.
    static func register(runtime: ChromiumRuntime, context: UnsafeMutableRawPointer) {
        guard runtime.capabilities.sitePermissions, let calls = ChromiumSiteAccessCalls.resolve() else {
            let missing = ChromiumSiteAccessCalls.missingSymbols
            ChromiumLog.info("site permissions: not in this engine (feature \(runtime.capabilities.sitePermissions ? "advertised" : "not advertised")"
                + (missing.isEmpty ? "" : ", missing \(missing.joined(separator: ", "))") + "); the site panel shows the shell's record")
            return
        }
        self.calls = calls
        self.runtime = runtime
        calls.setChanged(siteAccessChanged, context)
    }

    private static var isUsable: Bool { runtime.map { $0.isReady && !$0.isStopping } ?? false }

    static func fetch(tab: UInt64, receive: @escaping (SiteAccess?) -> Void) {
        guard let calls, isUsable, tab != 0 else { return receive(nil) }
        let receiver = Unmanaged.passRetained(SiteAccessReceiver(receive))
        let status = calls.get(tab, siteAccessCompletion, receiver.toOpaque())
        if status != .rearcOK {
            // Rejected: no completion will come.
            receiver.release()
            receive(nil)
        }
    }

    static func setPermission(tab: UInt64, origin: String, type: String, setting: UInt32) -> Bool {
        guard let calls, isUsable, tab != 0 else { return false }
        let status = origin.withCString { origin in type.withCString { calls.setPermission(tab, origin, $0, setting) } }
        // The site's name stays out of the log; the setting and the outcome are enough to follow a report.
        ChromiumLog.info("site permissions: tab \(tab) \(type) -> \(["reset", "allow", "block"][Int(min(setting, 2))]): \(status.rearcName)")
        return status == .rearcOK
    }

    static func revokeDevice(tab: UInt64, origin: String, kind: String, key: String) -> Bool {
        guard let calls, isUsable, tab != 0 else { return false }
        let status = origin.withCString { origin in
            kind.withCString { kind in key.withCString { calls.revokeDevice(tab, origin, kind, $0) } }
        }
        ChromiumLog.info("site permissions: tab \(tab) revoke \(kind) device: \(status.rearcName)")
        return status == .rearcOK
    }
}

extension ChromiumRuntime {
    /// Registered at `ready`, before any tab exists.
    func registerSiteAccessChannel(context: UnsafeMutableRawPointer) {
        ChromiumSiteAccessChannel.register(runtime: self, context: context)
    }
}

extension ChromiumEngine {
    /// The model with the engine's calls, when this engine has them. The
    /// tab's ID is read at each call: it is 0 before the tab exists and
    /// after it closed, and then nothing is asked.
    func makeSiteAccessModel() -> SiteAccessModel {
        let model = SiteAccessModel()
        guard ChromiumSiteAccessChannel.calls != nil else { return model }
        model.fetch = { [weak self] receive in
            ChromiumSiteAccessChannel.fetch(tab: self?.tabID ?? 0, receive: receive)
        }
        model.setPermission = { [weak self] origin, type, setting in
            ChromiumSiteAccessChannel.setPermission(tab: self?.tabID ?? 0, origin: origin, type: type, setting: setting)
        }
        model.revokeDevice = { [weak self] origin, kind, key in
            ChromiumSiteAccessChannel.revokeDevice(tab: self?.tabID ?? 0, origin: origin, kind: kind, key: key)
        }
        return model
    }
}
#endif

import Foundation
import SidebarModel

/// An engine that reports what it holds for the page's site and changes it
/// (Chromium ABI 1.67). WebKit has no such store: there the shell's own
/// record of its prompts' answers is the state.
protocol SiteAccessProviding: AnyObject {
    var siteAccess: SiteAccessModel { get }
}

/// One page's site permissions as its engine holds them: the address's site
/// information entry and the site panel read it. It asks the engine again
/// when the engine says something changed, when the page commits a document
/// and when its camera or microphone use changes; it keeps nothing else.
@Observable
final class SiteAccessModel {
    /// The engine's latest answer; nil for a page without a site and until the first one.
    private(set) var access: SiteAccess?
    /// A setting was changed here since the document loaded: the page may
    /// keep what it had until a reload.
    private(set) var needsReload = false

    /// The engine's calls, set by the engine that has them. `fetch` answers
    /// once, later, on the main thread; nil for a page without a site.
    @ObservationIgnored var fetch: ((@escaping (SiteAccess?) -> Void) -> Void)?
    /// setting: 0 reset, 1 allow, 2 block (`ReArcTabSetSitePermission`). False when the engine refused.
    @ObservationIgnored var setPermission: ((_ origin: String, _ type: String, _ setting: UInt32) -> Bool)?
    @ObservationIgnored var revokeDevice: ((_ origin: String, _ kind: String, _ key: String) -> Bool)?

    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var stale = false
    /// Counts answers the engine gave, for logs and tests.
    @ObservationIgnored private(set) var answers = 0

    /// The engine reports site permissions (else the panel shows the shell's record).
    var isAvailable: Bool { fetch != nil }

    /// Asks the engine. A request made while one is out is made once more
    /// when it returns, so the last state always arrives.
    func refresh() {
        guard let fetch else { return }
        guard !fetching else {
            stale = true
            return
        }
        fetching = true
        fetch { [weak self] answer in
            guard let self else { return }
            fetching = false
            answers += 1
            if access != answer { access = answer }
            if stale {
                stale = false
                refresh()
            }
        }
    }

    /// A new document: what was changed before has taken effect by now.
    func documentChanged() {
        if needsReload { needsReload = false }
        refresh()
    }

    /// The tab is gone.
    func clear() {
        if access != nil { access = nil }
        if needsReload { needsReload = false }
        stale = false
    }

    /// Allow, block or reset one of the site's settings, or take a device
    /// away. `origin` is the site the row was shown for, from the view that
    /// drew it: the engine checks it against the page, and a page that went
    /// elsewhere changes nothing. The model's own answer is not used for it:
    /// by the click it may already be the next site's (security review
    /// PK-02). True when the engine took it.
    @discardableResult
    func perform(_ action: SiteControlCenter.SettingAction, on row: SiteControlCenter.SettingRow, origin: String) -> Bool {
        guard !origin.isEmpty else { return false }
        let done: Bool
        switch (row.kind, action) {
        case (.sitePermission(let type), .allow): done = setPermission?(origin, type, 1) ?? false
        case (.sitePermission(let type), .block): done = setPermission?(origin, type, 2) ?? false
        case (.sitePermission(let type), .reset): done = setPermission?(origin, type, 0) ?? false
        case (.siteDevice(let kind, let key), .removeDevice): done = revokeDevice?(origin, kind, key) ?? false
        default: return false
        }
        if done { needsReload = true }
        // The engine's callback asks again too; this covers an engine that
        // refused (the row then shows what really holds).
        refresh()
        return done
    }
}

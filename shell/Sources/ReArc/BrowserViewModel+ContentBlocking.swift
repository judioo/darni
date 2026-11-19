import Foundation
import Observation
import SidebarModel

/// The list mirror, fetched as spec §4 says: a plain GET from an ephemeral
/// session, so no cookie, cache, credential or stored state goes with it,
/// and the two headers the system would fill with the app's version, the
/// Mac's system version and the person's languages carry fixed words.
/// Nothing in the request identifies the install. A redirect is followed
/// only to another URL of the mirror.
struct URLSessionBlocklistFetcher: BlocklistFetching {
    private final class MirrorRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            let allowed = request.url.map { BlocklistMirror.isMirrorURL($0, for: BlocklistMirror.latestURL) } ?? false
            completionHandler(allowed ? request : nil)
        }
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.httpAdditionalHeaders = ["User-Agent": "ReArc", "Accept-Language": "en"]
        return URLSession(configuration: configuration, delegate: MirrorRedirects(), delegateQueue: nil)
    }()

    func data(from url: URL, limit: Int) async throws -> Data {
        guard BlocklistMirror.isMirrorURL(url, for: BlocklistMirror.latestURL) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (bytes, response) = try await Self.session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard response.expectedContentLength <= Int64(limit) else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        }
        return data
    }
}

/// Ad and tracker blocking's state outside the sidebar file
/// (docs/FEATURE-SPECS/CONTENT-BLOCKING.md): whether this engine can block,
/// the verified list bundle, and the list check in flight. The settings
/// themselves are the store's (`SidebarStore+ContentBlocking`).
@Observable
final class ContentBlockingController {
    /// An engine with the blocking calls is attached. False on WebKit and on
    /// a Chromium engine from before the calls: every blocking surface is
    /// then hidden, and the install is not yet counted as new or existing.
    private(set) var isAvailable = false
    /// The verified bundle the engine has; nil until one verified.
    private(set) var bundle: VerifiedBlocklist?
    /// The bundles were looked at (launch): "No lists yet" is then a fact.
    private(set) var didLoadLists = false
    private(set) var isCheckingLists = false
    /// What the last check in this launch ended with.
    private(set) var lastCheck: BlocklistUpdateOutcome?
    /// The one-time offer card is up (existing installs).
    var showsOffer = false
    /// Bumped when the engine reports a tab's blocked count changed, so the
    /// open site controls panel reads the count again.
    private(set) var blockedCountRevision = 0

    @ObservationIgnored private(set) var engineSync: ContentBlockingEngineSync?
    @ObservationIgnored private(set) var lists: BlocklistStore?
    @ObservationIgnored var fetcher: BlocklistFetching = URLSessionBlocklistFetcher()
    /// The engine's count of requests blocked in a tab's page; nil without one.
    @ObservationIgnored var blockedCount: ((any WebEngine) -> Int?)?
    /// The engine's list of the sites those requests were for, as its JSON
    /// (`ContentBlockingBlockedList.decode`); nil on an engine that only
    /// counts. Read while the site controls show the list, never kept.
    @ObservationIgnored var blockedHosts: ((any WebEngine) -> String?)?
    @ObservationIgnored fileprivate var checkTimer: Timer?

    /// The built-in bundle's place in the app: `Contents/Resources/Blocklists`.
    static var builtInListsURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(BlocklistStore.folderName, isDirectory: true)
    }

    fileprivate func attach(engine: ContentBlockingEngine, lists: BlocklistStore,
                            settings: @escaping (Profile.ID) -> ContentBlockingSettings) {
        engineSync = ContentBlockingEngineSync(engine: engine, settings: settings)
        self.lists = lists
        isAvailable = true
    }

    fileprivate func use(_ bundle: VerifiedBlocklist?) {
        didLoadLists = true
        if self.bundle != bundle { self.bundle = bundle }
        engineSync?.setBundle(bundle)
    }

    /// The engine's count callback (at most every 250 ms, C-ABI.md).
    func blockedCountChanged() {
        blockedCountRevision &+= 1
    }

    fileprivate func beginCheck() -> Bool {
        guard isAvailable, !isCheckingLists else { return false }
        isCheckingLists = true
        return true
    }

    fileprivate func endCheck(_ outcome: BlocklistUpdateOutcome) {
        isCheckingLists = false
        lastCheck = outcome
    }

    /// "Lists last updated 18 Nov 2026", or that there are none yet.
    var listsUpdatedText: String {
        guard let date = bundle?.manifest.date else { return didLoadLists ? "No lists yet" : "Lists" }
        return "Lists last updated \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}

/// Built-in ad and tracker blocking (docs/FEATURE-SPECS/CONTENT-BLOCKING.md).
/// The store holds each profile's settings; these commands change them and
/// then tell the engine, and the list bundle is verified and kept up to
/// date here. All of it waits for `attachContentBlocking`: without an engine
/// that can block there is no rollout, no network and no UI.
extension BrowserViewModel {
    /// The Chromium shell, at ready, when the engine has the blocking calls.
    /// This is the first launch of a build with blocking exactly once: a new
    /// install gets blocking on, an existing one stays Off and is offered it.
    func attachContentBlocking(
        engine: ContentBlockingEngine,
        engineVersion: BlocklistEngineVersion?,
        builtInLists: URL? = ContentBlockingController.builtInListsURL,
        publicKeys: [Data] = BlocklistSigningKey.compiledIn
    ) {
        guard !contentBlocking.isAvailable else { return }
        if let install = store.beginContentBlockingRollout(isNewInstall: isFirstRun) {
            // On disk with the profiles' settings before anything is shown or loaded.
            persistence.flush()
            contentBlockingLog("first launch with blocking: \(install.rawValue) install")
        }
        let downloads = Self.siblingFile(BlocklistStore.folderName, of: persistence.fileURL)
        let lists = BlocklistStore(configuration: .init(builtIn: builtInLists, downloads: downloads, publicKeys: publicKeys, engine: engineVersion))
        contentBlocking.attach(engine: engine, lists: lists) { [weak self] id in self?.store.contentBlocking(for: id) ?? .off }
        if publicKeys.isEmpty { contentBlockingLog("this build has no lists key: no bundle can verify and nothing is blocked") }
        Task { @MainActor [weak self] in
            let bundle = await lists.load()
            for rejection in await lists.rejections { self?.contentBlockingLog("bundle refused: \(rejection)") }
            self?.contentBlocking.use(bundle)
            self?.contentBlockingLog("lists: \(bundle.map { "\($0.version) (\($0.source))" } ?? "none")")
            self?.checkBlocklistsIfDue()
        }
        // An hour's tick asks only when a day has passed (or an hour after a failure).
        contentBlocking.checkTimer?.invalidate()
        contentBlocking.checkTimer = Timer.scheduledTimer(withTimeInterval: BlocklistMirror.retryInterval, repeats: true) { [weak self] _ in
            self?.checkBlocklistsIfDue()
        }
    }

    private func contentBlockingLog(_ message: String) {
        contentBlockingEvents.append(message)
        if contentBlockingEvents.count > 50 { contentBlockingEvents.removeFirst(contentBlockingEvents.count - 50) }
        onContentBlockingEvent?(message)
    }

    /// A persistent engine profile finished loading: it gets its shell
    /// profile's level, exceptions and own rules before any tab exists.
    /// Private windows follow their profile in the engine and get no call.
    func contentBlockingProfileOpened(engineProfile: UInt64, profile: Profile.ID) {
        contentBlocking.engineSync?.profileOpened(engineProfile: engineProfile, profile: profile)
    }

    func contentBlockingProfileClosed(engineProfile: UInt64) {
        contentBlocking.engineSync?.profileClosed(engineProfile: engineProfile)
    }

    /// After any sidebar change (an edit here, or settings merged from iCloud).
    func contentBlockingSettingsChanged() {
        guard contentBlocking.isAvailable else { return }
        contentBlocking.engineSync?.settingsChanged()
        // Blocking just went on somewhere: the lists may be days old.
        checkBlocklistsIfDue()
    }

    // MARK: Settings

    func setContentBlockingEnabled(_ enabled: Bool, for profileID: Profile.ID) {
        changeContentBlocking(for: profileID) { $0.isEnabled = enabled }
    }

    func setContentBlockingStrength(_ level: ContentBlockingLevel, for profileID: Profile.ID) {
        changeContentBlocking(for: profileID) { $0.setStrength(level) }
    }

    func setContentBlockingList(_ id: String, enabled: Bool, for profileID: Profile.ID) {
        changeContentBlocking(for: profileID) { $0.setList(id, enabled: enabled) }
    }

    func setContentBlockingOwnRules(_ text: String, for profileID: Profile.ID) {
        changeContentBlocking(for: profileID) { $0.setOwnRules(text) }
    }

    /// False when `text` names no host.
    @discardableResult
    func addContentBlockingException(_ text: String, for profileID: Profile.ID) -> Bool {
        var added = false
        changeContentBlocking(for: profileID) { added = $0.addException(text) }
        return added
    }

    func removeContentBlockingException(_ host: String, for profileID: Profile.ID) {
        changeContentBlocking(for: profileID) { $0.removeException(host) }
    }

    /// The store decides; the engine is told at once, not at the next follow-up.
    private func changeContentBlocking(for profileID: Profile.ID, _ change: (inout ContentBlockingSettings) -> Void) {
        store.updateContentBlocking(for: profileID, change)
        contentBlockingSettingsChanged()
    }

    /// The Advanced sheet's list rows: the bundle's lists, each with the level that turns it on.
    var contentBlockingListRows: [ContentBlockingList] {
        ContentBlockingLists.lists(of: contentBlocking.bundle?.manifest)
    }

    // MARK: Site Control Center

    /// The panel's row for `engine`'s page; nil when this engine cannot block.
    func contentBlockingRow(for engine: any WebEngine, site: SiteControlCenter.Site) -> SiteControlCenter.SettingRow? {
        guard contentBlocking.isAvailable, let profileID = engine.pagePrompts.profileID else { return nil }
        let settings = store.contentBlocking(for: profileID)
        let url = engine.currentURL ?? URL(string: site.origin)
        let counts = settings.isEnabled && settings.exception(covering: url) == nil
        // The count is the engine's: its change callback bumps the revision this reads.
        _ = contentBlocking.blockedCountRevision
        return SiteControlCenter.contentBlockingRow(
            settings: settings,
            pageURL: url,
            blockedCount: counts ? contentBlocking.blockedCount?(engine) : nil,
            listsAvailable: contentBlocking.bundle != nil,
            isPrivate: engine.pagePrompts.privateSession != nil,
            blockedListAvailable: contentBlocking.blockedHosts != nil
        )
    }

    // MARK: Blocked on this page

    /// What was blocked in `engine`'s page, for the list under the panel's
    /// row (spec §3 "Blocked on this page"); nil when this engine cannot
    /// say. The engine holds it, in memory, until the page's next
    /// navigation; this reads it for a view that is on screen, and neither
    /// keeps nor logs it.
    func blockedList(for engine: any WebEngine) -> ContentBlockingBlockedList? {
        guard contentBlocking.isAvailable, let read = contentBlocking.blockedHosts else { return nil }
        // The list changes when the count does: the count callback bumps the revision this reads.
        _ = contentBlocking.blockedCountRevision
        guard let json = read(engine) else { return ContentBlockingBlockedList() }
        return ContentBlockingBlockedList.decode(json, lists: contentBlockingListRows) ?? ContentBlockingBlockedList()
    }

    /// A line of `list` can be allowed: the engine names the page's site
    /// and it is one site, in a window that is not private (nothing a
    /// private window showed is written to the profile). A line whose own
    /// name is not one site still has no Allow (`Entry.canBeAllowed`).
    func canAllowBlockedHosts(for engine: any WebEngine, on list: ContentBlockingBlockedList) -> Bool {
        contentBlocking.isAvailable && engine.pagePrompts.privateSession == nil && engine.pagePrompts.profileID != nil
            && list.allowSite != nil
    }

    /// The hosts the person allowed on `pageSite`, the engine's name for the page's site.
    func allowedBlockedHosts(for engine: any WebEngine, pageSite: String) -> [String] {
        guard contentBlocking.isAvailable, let profileID = engine.pagePrompts.profileID else { return [] }
        return store.contentBlocking(for: profileID).allowedHosts(onSite: pageSite)
    }

    /// "Allow <host> on This Site", or that taken back: one line of the
    /// profile's own rules, and the tab reloads. Never from a private window.
    ///
    /// `pageSite` is the site the list was drawn with. The rule is written
    /// for that site and no other: the engine is asked again where the tab
    /// is (its committed page, not an address still on its way), and when
    /// that is another site by now nothing is written and the person is told
    /// (security BL-10). The site's name is the engine's, from Chromium's
    /// suffix list, never one cut from an address here (BL-11).
    func setBlockedHost(_ host: String, allowed: Bool, on pageSite: String, of engine: any WebEngine) {
        guard contentBlocking.isAvailable, engine.pagePrompts.privateSession == nil,
              let profileID = engine.pagePrompts.profileID else { return }
        guard let now = blockedList(for: engine), now.allowSite == pageSite else {
            return showToast(ContentBlockingSiteAllow.Refusal.pageMoved.message, systemImage: "shield.slash")
        }
        var changed = false
        var refusal: ContentBlockingSiteAllow.Refusal?
        changeContentBlocking(for: profileID) { settings in
            let before = settings.ownRules
            if allowed { refusal = settings.allowHost(host, onSite: pageSite) } else { settings.removeAllowedHost(host, onSite: pageSite) }
            changed = settings.ownRules != before
        }
        if changed { engine.reload() }
        // Nothing was written: the person is told why (security BL-04).
        if let refusal { showToast(refusal.message, systemImage: "shield.slash") }
    }

    /// The page a site controls command is for: the one the panel drew.
    ///
    /// A command used to take the tab's address at the click, which can be
    /// another site's by then, or one the tab has not reached (security
    /// BL-10, as for Allow). Where the engine names the tab's committed site
    /// (`ReArcTabCopyBlockedHosts`' `page`), the drawn origin must belong to
    /// it; otherwise the tab has moved on, nothing is written and the person
    /// is told. On an engine that cannot say, the address at the click is
    /// all there is, as before.
    private func contentBlockingPage(drawnFor site: SiteControlCenter.Site, in engine: any WebEngine) -> URL? {
        guard contentBlocking.blockedHosts != nil else { return engine.currentURL ?? URL(string: site.origin) }
        let drawn = URL(string: site.origin)
        guard let host = ContentBlockingHost.pageHost(drawn), let committed = blockedList(for: engine)?.pageSite,
              ContentBlockingHost.covers(committed, host: host) else {
            showToast(ContentBlockingSiteAllow.Refusal.pageMoved.message, systemImage: "shield.slash")
            return nil
        }
        return drawn
    }

    /// Blocking off or back on for the site of the page the panel drew, in
    /// its profile; the tab then reloads (spec §3). Never from a private
    /// window: the site would be written into the profile's exceptions.
    func setContentBlocking(_ blocking: Bool, forSiteOf engine: any WebEngine, site: SiteControlCenter.Site) {
        guard contentBlocking.isAvailable, engine.pagePrompts.privateSession == nil,
              let profileID = engine.pagePrompts.profileID, let url = contentBlockingPage(drawnFor: site, in: engine) else { return }
        var changed = false
        changeContentBlocking(for: profileID) { settings in
            let before = settings.exceptions
            settings.setException(!blocking, forPage: url)
            changed = settings.exceptions != before
        }
        if changed { engine.reload() }
    }

    /// An exception that reaches past the page's site covers the page
    /// (blocking is off for every site under `web.app`, as an older build
    /// stored it): it goes, and the page's own site takes its place
    /// (security CB-12). The tab reloads.
    func narrowContentBlockingException(forSiteOf engine: any WebEngine, site: SiteControlCenter.Site) {
        guard contentBlocking.isAvailable, engine.pagePrompts.privateSession == nil,
              let profileID = engine.pagePrompts.profileID, let url = contentBlockingPage(drawnFor: site, in: engine) else { return }
        var changed = false
        changeContentBlocking(for: profileID) { changed = $0.narrowException(toPage: url) }
        if changed { engine.reload() }
    }

    /// Why a name typed into Settings' exceptions was refused, when the
    /// reason is that it is a public suffix; nil for any other refusal.
    func contentBlockingExceptionRefusal(for text: String) -> String? {
        guard let host = ContentBlockingHost.normalized(text), ContentBlockingHost.isPublicSuffix(host) else { return nil }
        return SiteControlCenter.suffixExceptionRefusal(host)
    }

    // MARK: Lists

    /// The daily check, only while blocking is on in some profile (spec §4).
    func checkBlocklistsIfDue() {
        guard contentBlocking.isAvailable, !contentBlocking.isCheckingLists, let lists = contentBlocking.lists else { return }
        let blockingOn = store.isContentBlockingOnAnywhere
        guard blockingOn else { return }
        Task { @MainActor [weak self] in
            let state = await lists.updateState
            guard BlocklistMirror.isCheckDue(blockingOn: blockingOn, state: state, now: Date()) else { return }
            self?.checkBlocklists()
        }
    }

    /// Settings' Check Now, and the daily check once it is due.
    func checkBlocklists() {
        guard store.isContentBlockingOnAnywhere, let lists = contentBlocking.lists, contentBlocking.beginCheck() else { return }
        let fetcher = contentBlocking.fetcher
        Task { @MainActor [weak self] in
            let outcome = await lists.checkForUpdate(using: fetcher)
            let bundle = await lists.active
            guard let self else { return }
            if case .updated = outcome { self.contentBlocking.use(bundle) }
            self.contentBlocking.endCheck(outcome)
            self.contentBlockingLog("list check: \(outcome)")
        }
    }

    // MARK: The one-time offer (existing installs)

    /// The sidebar is about to show: an existing install that has not been
    /// offered blocking gets the card now. The marker goes to disk first, so
    /// a crash with the card up cannot bring it back.
    func presentContentBlockingOfferIfDue() {
        guard contentBlocking.isAvailable, !contentBlocking.showsOffer, store.takeContentBlockingOffer() else { return }
        persistence.flush()
        contentBlocking.showsOffer = true
    }

    /// Turn On: every profile that is Off gets blocking on.
    func acceptContentBlockingOffer() {
        contentBlocking.showsOffer = false
        store.acceptContentBlockingOffer()
        contentBlockingSettingsChanged()
    }

    /// Not Now, or the close button. Settings keeps the switch.
    func declineContentBlockingOffer() {
        contentBlocking.showsOffer = false
    }
}

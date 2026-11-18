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
            isPrivate: engine.pagePrompts.privateSession != nil
        )
    }

    /// Blocking off or back on for the site of `engine`'s page, in its
    /// profile; the tab then reloads (spec §3). Never from a private window:
    /// the site would be written into the profile's exceptions.
    func setContentBlocking(_ blocking: Bool, forSiteOf engine: any WebEngine, site: SiteControlCenter.Site) {
        guard contentBlocking.isAvailable, engine.pagePrompts.privateSession == nil,
              let profileID = engine.pagePrompts.profileID else { return }
        let url = engine.currentURL ?? URL(string: site.origin)
        var changed = false
        changeContentBlocking(for: profileID) { settings in
            let before = settings.exceptions
            settings.setException(!blocking, forPage: url)
            changed = settings.exceptions != before
        }
        if changed { engine.reload() }
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

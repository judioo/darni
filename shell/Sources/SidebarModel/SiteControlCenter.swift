import Foundation

/// The per-site panel behind the URL field's site icon (Arc `ARC_SiteControlCenter`,
/// `SiteControlCenterBoostsView`; BOOSTS §5): connection, permissions, the
/// site's boosts, its zoom and its cookies and site data.
public enum SiteControlCenter {
    /// The site a page belongs to, for web pages only.
    public struct Site: Equatable, Sendable {
        public var origin: String
        public var host: String
    }

    public static func site(for url: URL?) -> Site? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let origin = PageOrigin.of(url), let host = PageOrigin.displayHost(origin) else { return nil }
        return Site(origin: origin, host: host)
    }

    /// Whether a website-data record (WebKit names them by registrable
    /// domain, "example.co.uk") belongs to `host` or one of its parents.
    public static func siteDataRecord(_ recordDomain: String, belongsTo host: String) -> Bool {
        let record = recordDomain.lowercased()
        let name = host.lowercased().split(separator: ":").first.map(String.init) ?? host.lowercased()
        guard !record.isEmpty else { return false }
        return name == record || name.hasSuffix("." + record)
    }

    /// One boost row: its switch says whether it changes this site now.
    public struct BoostRow: Equatable, Identifiable, Sendable {
        public var id: UUID
        public var name: String
        public var isEnabled: Bool
    }

    public static func boostRows(_ matches: [(BoostPackage, BoostInstallation)]) -> [BoostRow] {
        matches.map { BoostRow(id: $0.0.manifest.id, name: $0.0.manifest.name, isEnabled: $0.1.enabled) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The site data line: what WebKit holds for the site, or where Chromium's lives.
    public static func siteDataSummary(recordCount: Int?) -> String {
        switch recordCount {
        case nil: return "Cookies and storage are kept by the engine"
        case 0: return "No cookies or site data"
        case 1: return "1 kind of site data stored"
        case let count?: return "\(count) kinds of site data stored"
        }
    }
}

// MARK: - Arc's site controls panel

/// What Arc's toolbar site-controls popover lists, top to bottom: four
/// square buttons, the Extensions grid, the site's Settings rows, then a
/// footer with the connection and a ⋯ menu (docs/arc-recordings/2026-11-06-site-controls-panel.md).
/// The capture commands' names, one for each wherever it shows: the File
/// menu, the command bar, the site controls and the Library's Media page
/// (its empty text said "Capture Page", a name no menu had).
public enum CaptureCommandTitle {
    public static let fullPage = "Capture Full Page"
    public static let visibleArea = "Capture Visible Area"
}

extension SiteControlCenter {
    /// The top row, in Arc's order.
    public enum QuickAction: String, CaseIterable, Sendable {
        case share, boost, capture, captureFullPage

        public var title: String {
            switch self {
            case .share: return "Share"
            case .boost: return "New Boost"
            case .capture: return "Capture"
            case .captureFullPage: return CaptureCommandTitle.fullPage
            }
        }

        public var symbol: String {
            switch self {
            case .share: return "square.and.arrow.up"
            case .boost: return "wand.and.sparkles"
            case .capture: return "camera"
            case .captureFullPage: return "text.viewfinder"
            }
        }
    }

    public struct QuickActionItem: Equatable, Identifiable, Sendable {
        public var action: QuickAction
        public var isEnabled: Bool
        public var id: QuickAction { action }
    }

    /// Boosts can't change some web pages (the Web Store, the engine's own).
    public static func quickActions(boostsEligible: Bool) -> [QuickActionItem] {
        QuickAction.allCases.map { QuickActionItem(action: $0, isEnabled: $0 != .boost || boostsEligible) }
    }

    /// One tile of the Extensions grid: an extension, or Arc's + last.
    public enum ExtensionTile: Equatable, Identifiable, Sendable {
        case action(ExtensionActionItem, pinned: Bool)
        case add

        public var id: String {
            switch self {
            case .action(let item, _): return item.id
            case .add: return "+"
            }
        }

        /// The tile's pin button: always on a pinned extension, on an
        /// unpinned one only while the pointer is over the tile, never on +.
        public func pinBadge(hovered: Bool) -> PinBadge? {
            switch self {
            case .action(_, pinned: true): return .pinned
            case .action(_, pinned: false): return hovered ? .offered : nil
            case .add: return nil
            }
        }

        /// The small label over the tile under the pointer: the extension's
        /// name, or what its pin button does while the pointer is on that.
        public func hoverLabel(onPin: Bool) -> String {
            switch self {
            case .action(let item, let pinned):
                return onPin ? (pinned ? PinBadge.pinned : .offered).title : item.name
            case .add:
                return "Chrome Web Store"
            }
        }
    }

    /// The round pin button on a tile's bottom-right corner (Arc
    /// `SiteControlCenterExtensionPinButton`). A click pins or unpins.
    public enum PinBadge: Equatable, Sendable {
        /// Solid blue: the extension is in the toolbar.
        case pinned
        /// Faint blue, under the pointer: a click puts it there.
        case offered

        /// Arc's tooltips for the button.
        public var title: String {
            switch self {
            case .pinned: return "Unpin extension"
            case .offered: return "Pin extension"
            }
        }
    }

    /// Where the pointer is in the Extensions grid: on a tile, or on that
    /// tile's pin button.
    public struct TileHover: Equatable, Sendable {
        public var id: String
        public var onPin: Bool

        public init(id: String, onPin: Bool = false) {
            self.id = id
            self.onPin = onPin
        }
    }

    /// How long the pointer rests on a tile before its label shows. Once
    /// one shows, the next tile's shows at once, as system tooltips do.
    public static let hoverLabelDelay: TimeInterval = 0.5

    /// A preview's pointer (`--rearc-site-controls-preview=NAME`, or
    /// `NAME:pin` for the tile's pin button): the tile by extension name or
    /// ID, `+` for the last one.
    public static func previewHover(_ value: String, in tiles: [ExtensionTile]) -> TileHover? {
        let pinSuffix = ":pin"
        let onPin = value.hasSuffix(pinSuffix)
        let name = onPin ? String(value.dropLast(pinSuffix.count)) : value
        let tile = tiles.first { tile in
            if case .action(let item, _) = tile, item.name.caseInsensitiveCompare(name) == .orderedSame { return true }
            return tile.id == name
        }
        return tile.map { TileHover(id: $0.id, onPin: onPin) }
    }

    public static let extensionColumns = 4

    /// Pinned extensions first, in the toolbar's order, then the rest in
    /// the engine's order, then +. Arc's grid starts with the toolbar's icons.
    /// `order`: the pins when the panel opened. A tile pinned or unpinned
    /// while it is open stays under the pointer, so its badge changes in
    /// place and a second click undoes the first; it moves on the next opening.
    public static func extensionTiles(_ actions: [ExtensionActionItem], pins: ExtensionPins, order: ExtensionPins? = nil) -> [ExtensionTile] {
        let order = order ?? pins
        let first = order.pinned(actions)
        let rest = actions.filter { !order.isPinned($0.id) }
        return (first + rest).map { .action($0, pinned: pins.isPinned($0.id)) } + [.add]
    }

    /// What a Settings row's menu can do.
    public enum SettingAction: Equatable, Sendable {
        case allow, block, reset, snoozeOneHour, openSiteSettings
        /// "Block ads and trackers": a site exception on or off, and the way to the switch.
        case turnOffBlockingForSite, turnOnBlockingForSite, openBlockingSettings
        /// Blocking is off for every site under a public suffix (an exception
        /// stored by an older build): keep it off for this site alone.
        case turnOffBlockingForSiteOnly
        /// A device chosen for the site (USB, HID, serial, Bluetooth) is taken from it again.
        case removeDevice
        /// After a permission change: the loaded page keeps what it had until it is reloaded.
        case reloadPage

        public var title: String {
            switch self {
            case .removeDevice: return "Remove Access"
            case .reloadPage: return "Reload Page"
            case .turnOffBlockingForSite: return "Turn Off Blocking for This Site"
            case .turnOnBlockingForSite: return "Turn On Blocking for This Site"
            case .turnOffBlockingForSiteOnly: return "Turn Off Blocking for This Site Only"
            case .openBlockingSettings: return "Blocking Settings…"
            case .allow: return "Allow"
            case .block: return "Block"
            case .reset: return "Reset"
            case .snoozeOneHour: return "Snooze for 1 Hour"
            case .openSiteSettings: return "Site Settings…"
            }
        }
    }

    /// One Settings row: a round icon, a title and the site's state.
    public struct SettingRow: Equatable, Identifiable, Sendable {
        public enum Kind: Hashable, Sendable {
            /// An answer in the shell's own record (`SitePermissionStore`), by prompt type key.
            case permission(String)
            /// A setting the engine holds for the site, by Chromium's name (`SiteAccess`).
            case sitePermission(String)
            /// A device the person chose for the site.
            case siteDevice(kind: String, key: String)
            case reloadToApply
            case autoPictureInPicture
            case contentBlocking
        }

        public var kind: Kind
        public var title: String
        public var state: String
        public var symbol: String
        public var isBlocked: Bool
        /// One action is a click; more are a menu; none is a label.
        public var actions: [SettingAction]
        /// The row has a list behind it, opened by a disclosure at its right
        /// edge: what was blocked on this page.
        public var hasBlockedList = false
        public var id: Kind { kind }
    }

    public static let contentBlockingTitle = "Block ads and trackers"

    /// The row's state for an exception that reaches past the page's site,
    /// and the line in Settings for one that is a public suffix: blocking is
    /// off for far more than one site.
    public static func suffixExceptionText(_ suffix: String) -> String { "Off for every site under \(suffix)" }
    /// The toasts when a command of the panel found the tab on another page
    /// than the one the panel was drawn for, so nothing was written. Each
    /// command has its own words.
    public static let blockingNotTurnedOffMessage = "The page changed before blocking was turned off. Nothing was changed."
    public static let blockingNotTurnedOnMessage = "The page changed before blocking was turned on. Nothing was changed."
    public static let blockingNotNarrowedMessage = "The page changed before blocking was narrowed to this site. Nothing was changed."
    public static let allowedHostNotRemovedMessage = "The page changed before the site was removed. Nothing was changed."

    /// Under the field in Settings when the typed name is a public suffix.
    public static func suffixExceptionRefusal(_ suffix: String) -> String {
        "\(suffix) is not one site: every site under it is someone else’s. Type one site, such as example.\(suffix)."
    }
    /// The disclosure on the blocking row, closed and open.
    public static let showBlockedListTitle = "Show What Was Blocked"
    public static let hideBlockedListTitle = "Hide What Was Blocked"
    /// The title over the hosts the person allowed on this site.
    public static let allowedOnSiteTitle = "Allowed on this site"

    /// What a click on a blocked line's button does.
    public enum BlockedLineClick: Equatable, Sendable {
        /// The line's command runs.
        case perform
        /// The line shows its button's title, and nothing else happens.
        case showTitle
    }

    /// A click acts only on a line that shows its button's title (security
    /// BL-13). The button is in the line before its title shows, so that a
    /// click cannot fall between the two. A line can come under a pointer
    /// that does not move: the list fills again after a reload and pushes
    /// the allowed section down, or the page asks a new host. A click there
    /// was meant for what stood in that place before, a Remove for one. It
    /// only makes the title show. The next click acts.
    public static func blockedLineClick(titleShows: Bool) -> BlockedLineClick {
        titleShows ? .perform : .showTitle
    }

    /// A blocked line's button, and the same for an allowed one.
    public static func allowHostTitle(_ host: String) -> String { "Allow \(host) on This Site" }
    public static func removeAllowedHostTitle(_ host: String) -> String { "Block \(host) on This Site Again" }

    /// "N blocked on this page" (spec §3). The count is this tab's, read
    /// from the engine while the panel is open; it never leaves the Mac.
    public static func blockedCountText(_ count: Int?) -> String {
        switch count {
        case nil: return "On for this site"
        case 0?: return "Nothing blocked on this page"
        case let count?: return "\(count) blocked on this page"
        }
    }

    /// The panel's "Block ads and trackers" row (spec §3). A click turns
    /// blocking off or back on for the page's site, and the tab then
    /// reloads. While the profile's switch is off the row leads to
    /// Settings: one site's panel never turns blocking on for a profile.
    /// In a private window the row only reports, so a site visited there
    /// is never written into the profile's exceptions.
    /// `blockedListAvailable`: the engine can say which sites the count is
    /// of; the row then opens that list while something is blocked.
    public static func contentBlockingRow(
        settings: ContentBlockingSettings,
        pageURL: URL?,
        blockedCount: Int?,
        listsAvailable: Bool,
        isPrivate: Bool,
        blockedListAvailable: Bool = false,
        names: SiteNames? = .shared
    ) -> SettingRow {
        var row = SettingRow(kind: .contentBlocking, title: contentBlockingTitle, state: blockedCountText(blockedCount),
                             symbol: "shield.lefthalf.filled", isBlocked: false, actions: [.turnOffBlockingForSite])
        row.hasBlockedList = blockedListAvailable && (blockedCount ?? 0) > 0
        if !settings.isEnabled {
            row.state = "Off in Settings"
            row.symbol = "shield.slash"
            row.isBlocked = true
            row.actions = [.openBlockingSettings]
        } else if let wider = settings.widerException(covering: pageURL, names: names) {
            // An exception that reaches past this page's site, as an older
            // build stored them (`web.app`, `azure.com`; security CB-12):
            // the row says how far it reaches, and offers this site alone
            // as well as blocking back on.
            row.state = suffixExceptionText(wider)
            row.symbol = "shield.slash"
            row.isBlocked = true
            row.actions = [.turnOffBlockingForSiteOnly, .turnOnBlockingForSite]
        } else if settings.exception(covering: pageURL) != nil {
            row.state = "Off for this site"
            row.symbol = "shield.slash"
            row.isBlocked = true
            row.actions = [.turnOnBlockingForSite]
        } else if !listsAvailable {
            row.state = "No lists yet"
            row.actions = []
        }
        if isPrivate || ContentBlockingHost.exceptionHost(for: pageURL, names: names) == nil { row.actions.removeAll { $0 != .openBlockingSettings } }
        // Off, excepted or without lists: nothing is counted, so nothing is listed.
        if row.isBlocked || !listsAvailable { row.hasBlockedList = false }
        return row
    }

    /// Location, camera, microphone and notifications lead, as in Arc; other types follow by name.
    static let leadingPermissions = ["geolocation", "camera_stream", "mic_stream", "notifications"]

    /// Blocking first (when the engine has it), then the site's
    /// permissions, then automatic Picture in Picture.
    /// `siteAccess`: the engine's own state for the site (Chromium ABI 1.67).
    /// With it the rows are the engine's (every setting the site holds, the
    /// devices chosen for it, what is in use) and the shell's record of its
    /// prompts' answers is not shown: it can only repeat or contradict them.
    /// `needsReload`: a setting was changed from the panel since the page loaded.
    /// `permissionsInEngine`: an engine that keeps remembered answers but
    /// does not report them (ABI before 1.67): a row opens its Site Settings.
    /// On WebKit the shell's store is the answer.
    public static func settingRows(
        contentBlocking: SettingRow? = nil,
        siteAccess: SiteAccess? = nil,
        needsReload: Bool = false,
        permissions: [(type: PermissionType, entry: SitePermissionStore.Entry)],
        permissionsInEngine: Bool,
        autoPiP: AutoPiPHostPreference,
        autoPiPEnabled: Bool,
        now: Date = Date()
    ) -> [SettingRow] {
        func rank(_ type: PermissionType) -> Int { leadingPermissions.firstIndex(of: type.key) ?? leadingPermissions.count }
        var rows: [SettingRow]
        if let siteAccess {
            rows = siteAccessRows(siteAccess)
            if needsReload { rows.insert(reloadToApplyRow, at: 0) }
        } else {
            let sorted = permissions.sorted { (rank($0.type), $0.type.name) < (rank($1.type), $1.type.name) }
            rows = sorted.map { type, entry in
                let blocked = entry.decision == .deny
                let actions: [SettingAction] = permissionsInEngine
                    ? [.openSiteSettings]
                    : [blocked ? .allow : .block, .reset]
                return SettingRow(kind: .permission(type.key), title: type.name, state: permissionState(entry),
                                  symbol: type.symbol, isBlocked: blocked, actions: actions)
            }
        }
        rows.append(autoPiPRow(autoPiP, enabled: autoPiPEnabled, now: now))
        if let contentBlocking { rows.insert(contentBlocking, at: 0) }
        return rows
    }

    public static func permissionState(_ entry: SitePermissionStore.Entry) -> String {
        let decision = entry.decision == .allow ? "Allowed" : "Blocked"
        return entry.remembered ? decision : "\(decision) this time"
    }

    /// Arc's "Automatic Picture-In-Picture" row, from ReArc's per-site
    /// allow, block and one-hour snooze. Off in Settings wins for every
    /// site, and then the row has nothing to change.
    static func autoPiPRow(_ preference: AutoPiPHostPreference, enabled: Bool, now: Date) -> SettingRow {
        var row = SettingRow(kind: .autoPictureInPicture, title: "Automatic Picture-In-Picture", state: "Allowed",
                             symbol: "pip", isBlocked: false, actions: [.block, .snoozeOneHour])
        switch preference {
        case .enabled:
            break
        case .disabled:
            row.state = "Blocked"
            row.isBlocked = true
            row.actions = [.allow]
        case .snoozedUntil(let deadline):
            let minutes = max(1, Int((deadline.timeIntervalSince(now) / 60).rounded(.up)))
            row.state = "Snoozed for \(minutes) min"
            row.isBlocked = true
            row.actions = [.allow, .block]
        }
        if !enabled {
            row.state = "Off for all sites"
            row.isBlocked = true
            row.actions = []
        }
        return row
    }

    /// The ⋯ menu: what the old panel held besides permissions.
    public enum MenuItem: Hashable, Sendable {
        case zoomLevel(percent: Int)
        case zoomIn, zoomOut, actualSize(enabled: Bool)
        case boost(id: UUID, name: String, enabled: Bool)
        case editBoosts
        /// WebKit: the shell clears the site's records itself.
        case clearSiteData
        /// Chromium: its Site Settings page lists and clears them.
        case cookiesAndSiteData
        case siteSettings

        public var title: String {
            switch self {
            case .zoomLevel(let percent): return "Zoom \(percent)%"
            case .zoomIn: return "Zoom In"
            case .zoomOut: return "Zoom Out"
            case .actualSize: return "Actual Size"
            case .boost(_, let name, _): return name
            case .editBoosts: return "Edit Boost…"
            case .clearSiteData: return "Clear Cookies and Site Data"
            case .cookiesAndSiteData: return "Cookies and Site Data…"
            case .siteSettings: return "Site Settings…"
            }
        }
    }

    /// Sections of the ⋯ menu, divided in the view.
    public static func moreMenu(zoomPercent: Int, boosts: [BoostRow], shellClearsSiteData: Bool, siteSettingsAvailable: Bool) -> [[MenuItem]] {
        var sections: [[MenuItem]] = [[.zoomLevel(percent: zoomPercent), .zoomIn, .zoomOut, .actualSize(enabled: zoomPercent != 100)]]
        if !boosts.isEmpty {
            sections.append(boosts.map { .boost(id: $0.id, name: $0.name, enabled: $0.isEnabled) } + [.editBoosts])
        }
        var site: [MenuItem] = []
        if shellClearsSiteData {
            site.append(.clearSiteData)
        } else if siteSettingsAvailable {
            site.append(.cookiesAndSiteData)
        }
        if siteSettingsAvailable { site.append(.siteSettings) }
        if !site.isEmpty { sections.append(site) }
        return sections
    }

    /// The connection as the footer shows it.
    public enum Connection: Sendable {
        case secure, insecure, dangerous, unknown
    }

    public enum FooterAction: Equatable, Sendable {
        case showCertificate, openSiteSettings
    }

    public struct Footer: Equatable, Sendable {
        public var title: String
        public var symbol: String
        public var isWarning: Bool
        /// Nil: the badge is a label.
        public var action: FooterAction?
    }

    /// "🔒 Secure" in Arc. A click shows the certificate where the engine
    /// hands one over (WebKit), otherwise the site's settings (Chromium).
    public static func footer(_ connection: Connection, certificateAvailable: Bool, siteSettingsAvailable: Bool) -> Footer {
        let action: FooterAction? = certificateAvailable ? .showCertificate : (siteSettingsAvailable ? .openSiteSettings : nil)
        switch connection {
        case .secure: return Footer(title: "Secure", symbol: "lock.fill", isWarning: false, action: action)
        case .insecure: return Footer(title: "Not Secure", symbol: "lock.open.fill", isWarning: true, action: action)
        case .dangerous: return Footer(title: "Dangerous", symbol: "exclamationmark.octagon.fill", isWarning: true, action: action)
        case .unknown: return Footer(title: "Site Info", symbol: "info.circle", isWarning: false, action: siteSettingsAvailable ? .openSiteSettings : nil)
        }
    }
}

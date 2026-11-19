import AppKit
import SecurityInterface
import SwiftUI
import SidebarModel

/// Engines that can count and clear a site's cookies and storage
/// (WebKit's data store). Chromium's live in its Site Settings page.
@MainActor
protocol SiteDataManaging: AnyObject {
    func siteDataKindCount(host: String) async -> Int
    func clearSiteData(host: String) async
}

/// Engines that hand over the page's server certificate (WebKit's
/// `serverTrust`). Chromium's engine ABI has none.
@MainActor
protocol ServerCertificateProviding: AnyObject {
    var serverTrust: SecTrust? { get }
}

extension BrowserViewModel {
    /// The site's boosts in the active profile, for the ⋯ menu's switches.
    func siteControlBoostRows(for url: URL) -> [SiteControlCenter.BoostRow] {
        guard BoostScopeMatcher.urlIsEligibleForBoosts(url) else { return [] }
        return SiteControlCenter.boostRows(store.boostsMatchingPage(url))
    }

    /// Zoom for the panel's page, whichever window it is in.
    func zoom(_ step: PageZoom.Step, engine: any WebEngine) {
        engine.setZoomFactor(PageZoom.factor(after: step, from: engine.zoomFactor))
    }

    /// The command bar's Site Controls: the key window's URL field opens its panel.
    func showSiteControlCenter() {
        siteControlCenterRequest += 1
    }

    /// What the engine holds for the page's site, when it reports that (Chromium ABI 1.67).
    func siteAccessModel(for engine: (any WebEngine)?) -> SiteAccessModel? {
        guard let model = (engine as? SiteAccessProviding)?.siteAccess, model.isAvailable else { return nil }
        return model
    }

    /// The panel's Settings rows: blocking (when the engine has it), the site's permissions
    /// (the engine's own state where it reports it, else the answers recorded here), then automatic PiP.
    func siteControlSettingRows(for engine: any WebEngine, site: SiteControlCenter.Site, now: Date = Date()) -> [SiteControlCenter.SettingRow] {
        let access = siteAccessModel(for: engine)
        return SiteControlCenter.settingRows(
            contentBlocking: contentBlockingRow(for: engine, site: site),
            // An answer for another site (the page moved on, the next answer is on its way) is not shown.
            siteAccess: access.map { $0.access.flatMap { $0.origin == site.origin ? $0 : nil } ?? SiteAccess(origin: site.origin) },
            needsReload: access?.needsReload ?? false,
            permissions: sitePermissions.entries(origin: site.origin, scope: engine.pagePrompts.permissionScope),
            permissionsInEngine: sitePermissionsLiveInEngine,
            autoPiP: AutoPiPPolicy.effectiveHostPreference(host: Self.autoPiPHost(site), settings: store.autoPiPPolicy, now: now),
            autoPiPEnabled: automaticPictureInPicture,
            now: now
        )
    }

    /// Auto-PiP keys sites by the URL's own host, `www.` and all.
    static func autoPiPHost(_ site: SiteControlCenter.Site) -> String {
        URL(string: site.origin)?.host() ?? site.host
    }

    func performSiteSetting(_ action: SiteControlCenter.SettingAction, on row: SiteControlCenter.SettingRow,
                            engine: any WebEngine, site: SiteControlCenter.Site) {
        switch row.kind {
        case .autoPictureInPicture:
            let host = Self.autoPiPHost(site)
            switch action {
            case .allow: store.allowAutoPiP(forHost: host)
            case .block: store.setAutoPiPDisabled(forHost: host)
            case .snoozeOneHour: store.snoozeAutoPiP(forHost: host)
            case .reset, .openSiteSettings, .turnOffBlockingForSite, .turnOnBlockingForSite, .openBlockingSettings,
                 .turnOffBlockingForSiteOnly, .removeDevice, .reloadPage: break
            }
        case .contentBlocking:
            switch action {
            case .turnOffBlockingForSite: setContentBlocking(false, forSiteOf: engine, site: site)
            case .turnOnBlockingForSite: setContentBlocking(true, forSiteOf: engine, site: site)
            case .turnOffBlockingForSiteOnly: narrowContentBlockingException(forSiteOf: engine, site: site)
            case .openBlockingSettings: showSettings(.profiles)
            case .allow, .block, .reset, .snoozeOneHour, .openSiteSettings, .removeDevice, .reloadPage: break
            }
        case .sitePermission, .siteDevice:
            // The engine's own state: it checks that the page is still on the site the row was shown for.
            if action == .openSiteSettings { return openSiteSettings(origin: site.origin) }
            // With the origin this view showed, not the one the model holds by now.
            siteAccessModel(for: engine)?.perform(action, on: row, origin: site.origin)
        case .reloadToApply:
            if action == .reloadPage { engine.reload(ignoringCache: false) }
        case .permission(let key):
            let scope = engine.pagePrompts.permissionScope
            let type = PermissionType(key)
            switch action {
            case .allow, .block:
                let request = PermissionPromptRequest(id: 0, origin: site.origin, types: [type])
                sitePermissions.record(action == .allow ? .allow : .deny, remembered: true, request: request, scope: scope)
            case .reset:
                sitePermissions.reset(origin: site.origin, scope: scope, type: type)
            case .openSiteSettings:
                openSiteSettings(origin: site.origin)
            case .snoozeOneHour, .turnOffBlockingForSite, .turnOnBlockingForSite, .openBlockingSettings, .turnOffBlockingForSiteOnly,
                 .removeDevice, .reloadPage:
                break
            }
        }
    }

    func siteControlsMenu(for engine: any WebEngine, site: SiteControlCenter.Site) -> [[SiteControlCenter.MenuItem]] {
        SiteControlCenter.moreMenu(
            zoomPercent: PageZoom.percent(engine.zoomFactor),
            boosts: siteControlBoostRows(for: engine.currentURL ?? URL(string: site.origin)!),
            shellClearsSiteData: engine is SiteDataManaging,
            siteSettingsAvailable: sitePermissionsLiveInEngine
        )
    }

    func performSiteControlsMenuItem(_ item: SiteControlCenter.MenuItem, engine: any WebEngine, site: SiteControlCenter.Site) {
        switch item {
        case .zoomLevel: break
        case .zoomIn: zoom(.zoomIn, engine: engine)
        case .zoomOut: zoom(.zoomOut, engine: engine)
        case .actualSize: zoom(.reset, engine: engine)
        case .boost(let id, _, let enabled): setBoostEnabled(id, enabled: !enabled)
        case .editBoosts: editBoostFromTabContextMenu()
        case .clearSiteData:
            guard let manager = engine as? SiteDataManaging else { return }
            Task { @MainActor in
                await manager.clearSiteData(host: site.host)
                engine.reload()
            }
        case .cookiesAndSiteData, .siteSettings:
            openSiteSettings(origin: site.origin)
        }
    }

    @MainActor
    func siteControlsFooter(for engine: any WebEngine) -> SiteControlCenter.Footer {
        let connection: SiteControlCenter.Connection
        switch engine.securityState {
        case .secure: connection = .secure
        case .insecure: connection = .insecure
        case .dangerous: connection = .dangerous
        case .none, .unknown: connection = .unknown
        }
        let trust = (engine as? ServerCertificateProviding)?.serverTrust
        return SiteControlCenter.footer(connection, certificateAvailable: trust != nil, siteSettingsAvailable: sitePermissionsLiveInEngine)
    }
}

/// Arc's site controls popover from the toolbar (Arc `ARC_SiteControlCenter`):
/// Share, Boost, Capture and Capture Full Page; every extension, pinned ones
/// first with a pin button; the site's settings; the connection and a ⋯ menu.
/// Built only while open: the toolbar reads none of this.
struct SiteControlCenterView: View {
    let model: BrowserViewModel
    let engine: any WebEngine
    let site: SiteControlCenter.Site
    /// The toolbar button: extension popups open under it once the panel closes.
    var anchor: NSView?
    /// A preview's pointer, by tile (`SiteControlsPreview`).
    var preview: String? = SiteControlsPreview.requested
    let dismiss: () -> Void
    @Environment(\.sidebarWindow) private var window
    @Environment(\.colorScheme) private var colorScheme
    /// The pointer is over the Extensions section: Manage shows.
    @State private var isOverExtensions = false
    /// The blocking row's list is open (spec §3 "Blocked on this page").
    @State private var showsBlockedList = false

    static let tile = CGSize(width: 48, height: 32)
    static let spacing: CGFloat = 8
    static let width = CGFloat(SiteControlCenter.extensionColumns) * tile.width + CGFloat(SiteControlCenter.extensionColumns - 1) * spacing

    private var url: URL { engine.currentURL ?? URL(string: site.origin)! }
    private var controller: ExtensionsController { model.extensions }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            quickActions
            if controller.isAvailable {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        header("Extensions", top: 10, bottom: 9)
                        Spacer()
                        // Arc shows it while the pointer is over the section
                        // (2026-11-14 captures); chrome://extensions/ in a
                        // tab, as the tiles' menus.
                        Button("Manage", action: manageExtensions)
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .opacity(isOverExtensions || preview != nil ? 1 : 0)
                            .help("Manage Extensions")
                            .accessibilityLabel("Manage Extensions")
                    }
                    SiteControlsExtensionGrid(model: model, engine: engine, preview: preview, manage: manageExtensions) { id in
                        dismiss()
                        // The popup opens once the panel has closed.
                        DispatchQueue.main.async { controller.run(id, for: engine, anchor: anchor) }
                    } add: {
                        dismiss()
                        model.openChromeWebStore()
                    }
                }
                .onHover { isOverExtensions = $0 }
                .animation(.easeOut(duration: 0.12), value: isOverExtensions)
            }
            header("Settings", top: 16, bottom: 8)
            settingRows
            Divider().padding(.top, 10).padding(.bottom, 8)
            footer
        }
        .padding(10)
        .frame(width: Self.width + 20)
    }

    private var settingRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.siteControlSettingRows(for: engine, site: site)) { row in
                SiteControlsSettingRowView(row: row, isDark: colorScheme == .dark,
                                           disclosure: row.hasBlockedList ? $showsBlockedList : nil) { action in
                    if action == .openSiteSettings || action == .openBlockingSettings || action == .reloadPage { dismiss() }
                    model.performSiteSetting(action, on: row, engine: engine, site: site)
                }
                if row.kind == .contentBlocking {
                    SiteControlsBlockedListView(model: model, engine: engine, site: site, isOpen: row.hasBlockedList && showsBlockedList)
                }
            }
        }
        // The engine's state is asked for when the panel opens, so it shows what holds now.
        .task { model.siteAccessModel(for: engine)?.refresh() }
    }

    private func manageExtensions() {
        dismiss()
        model.openBrowserPage(.extensions)
    }

    // MARK: Share, Boost, Capture

    private var quickActions: some View {
        HStack(spacing: Self.spacing) {
            ForEach(SiteControlCenter.quickActions(boostsEligible: BoostScopeMatcher.urlIsEligibleForBoosts(url))) { item in
                if item.action == .share {
                    ShareLink(item: url) { squareLabel(item.action) }
                        .buttonStyle(.plain)
                        .help(item.action.title)
                } else {
                    Button { run(item.action) } label: { squareLabel(item.action) }
                        .buttonStyle(.plain)
                        .disabled(!item.isEnabled)
                        .opacity(item.isEnabled ? 1 : 0.4)
                        .help(item.action.title)
                }
            }
        }
    }

    private func run(_ action: SiteControlCenter.QuickAction) {
        dismiss()
        switch action {
        case .share: break
        case .boost: model.newBoost()
        case .capture: _ = model.beginPageCapture(in: window)
        case .captureFullPage: Task { await model.performCapture(scope: .fullPage) }
        }
    }

    private func squareLabel(_ action: SiteControlCenter.QuickAction) -> some View {
        Image(systemName: action.symbol)
            .font(.system(size: 15))
            .foregroundStyle(.primary.opacity(0.8))
            .frame(width: Self.tile.width, height: Self.tile.height)
            .background(SiteControlsTileBackground(raised: true))
            .contentShape(Rectangle())
            .accessibilityLabel(action.title)
    }

    /// Arc's section titles: 14 pt, their capitals 14 pt under the buttons
    /// and 19 pt under the grid (2026-11-14 captures).
    private func header(_ title: String, top: CGFloat, bottom: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.top, top)
            .padding(.bottom, bottom)
    }

    // MARK: Secure and ⋯

    private var footer: some View {
        let footer = model.siteControlsFooter(for: engine)
        return HStack {
            Button { open(footer.action) } label: {
                Label(footer.title, systemImage: footer.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(footer.isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary.opacity(0.85)))
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(SiteControlsTileBackground(raised: false))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(footer.action == nil)
            .help(footer.action == .showCertificate ? "Show Certificate" : "Site Settings for \(site.host)")
            Spacer(minLength: 8)
            SiteControlsMoreButton(model: model, engine: engine, site: site, dismiss: dismiss)
        }
    }

    private func open(_ action: SiteControlCenter.FooterAction?) {
        switch action {
        case .showCertificate:
            guard let trust = (engine as? ServerCertificateProviding)?.serverTrust else { return }
            dismiss()
            DispatchQueue.main.async { SFCertificatePanel.shared()?.runModal(for: trust, showGroup: true) }
        case .openSiteSettings:
            dismiss()
            model.openSiteSettings(origin: site.origin)
        case nil:
            break
        }
    }
}

/// Arc's tiles: a light fill with a hairline; the top row's are raised (white).
private struct SiteControlsTileBackground: View {
    var raised: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let dark = colorScheme == .dark
        shape
            .fill(raised ? Color.white.opacity(dark ? 0.10 : 0.75) : Color.primary.opacity(dark ? 0.10 : 0.05))
            .overlay(shape.strokeBorder(Color.primary.opacity(raised ? 0.10 : 0), lineWidth: 0.5))
    }
}

/// The Extensions grid, four across. A pinned extension carries Arc's blue
/// pin button on its tile's corner; an unpinned one shows it faintly under
/// the pointer, and a click on it pins or unpins (as does a right-click).
/// The tile under the pointer names its extension. + opens the Chrome Web
/// Store; every tile's menu has Manage Extensions… (chrome://extensions/).
struct SiteControlsExtensionGrid: View {
    let model: BrowserViewModel
    let engine: (any WebEngine)?
    /// A preview's pointer, by tile (`SiteControlsPreview`).
    var preview: String?
    let manage: () -> Void
    let run: (String) -> Void
    let add: () -> Void
    @Environment(\.displayScale) private var displayScale
    /// The pins when the grid opened: its tiles keep that order while it is open.
    @State private var order: ExtensionPins?
    /// The tile under the pointer, and the one whose label shows.
    @State private var hover: SiteControlCenter.TileHover?
    @State private var labelled: SiteControlCenter.TileHover?

    private let columns = Array(repeating: GridItem(.fixed(SiteControlCenterView.tile.width), spacing: SiteControlCenterView.spacing),
                                count: SiteControlCenter.extensionColumns)

    var body: some View {
        let controller = model.extensions
        let tiles = SiteControlCenter.extensionTiles(controller.actions(for: engine), pins: controller.pins, order: order)
        let previewed = preview.flatMap { SiteControlCenter.previewHover($0, in: tiles) }
        let pointer = hover ?? previewed
        LazyVGrid(columns: columns, alignment: .leading, spacing: SiteControlCenterView.spacing) {
            ForEach(tiles) { tile in
                SiteControlsExtensionTileView(tile: tile, pointer: pointer?.id == tile.id ? pointer : nil, manage: manage) {
                    switch tile {
                    case .action(let action, _): run(action.id)
                    case .add: add()
                    }
                } togglePin: {
                    controller.togglePin(tile.id)
                } pointerMoved: { now in
                    // The next tile's arrival can come before this one's leave.
                    if let now { hover = now } else if hover?.id == tile.id { hover = nil }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if let shown = labelled ?? previewed, let index = tiles.firstIndex(where: { $0.id == shown.id }) {
                SiteControlsHoverLabel(text: tiles[index].hoverLabel(onPin: shown.onPin), tileIndex: index)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.1), value: labelled != nil)
        .onAppear { order = controller.pins }
        // The list is the tab's last answer. Asked again on opening, so an
        // extension that loaded after the tab first asked shows up (QA 2026-11-08 #20).
        .task { controller.refresh(engine, scale: displayScale) }
        .task(id: hover) {
            if hover == nil {
                // Crossing the gap between two tiles keeps the label up.
                try? await Task.sleep(for: .milliseconds(120))
            } else if labelled == nil {
                try? await Task.sleep(for: .seconds(SiteControlCenter.hoverLabelDelay))
            }
            if !Task.isCancelled { labelled = hover }
        }
    }
}

/// One tile: a click runs the extension (or opens the Web Store), a click
/// on the pin button at its corner pins or unpins.
private struct SiteControlsExtensionTileView: View {
    let tile: SiteControlCenter.ExtensionTile
    /// The pointer, while it is on this tile.
    let pointer: SiteControlCenter.TileHover?
    let manage: () -> Void
    let click: () -> Void
    let togglePin: () -> Void
    /// Nil: the pointer left.
    let pointerMoved: (SiteControlCenter.TileHover?) -> Void
    @State private var isOverTile = false
    @State private var isOverPin = false

    /// The pin button takes clicks a little past its disc, short of the next tile.
    private static let pinTarget: CGFloat = 20

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            switch tile {
            case .action(let action, let pinned):
                Button(action: click) {
                    ExtensionIcon(action: action, size: 16)
                        .frame(width: SiteControlCenterView.tile.width, height: SiteControlCenterView.tile.height)
                        .background(SiteControlsTileBackground(raised: false))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!action.isEnabled)
                .opacity(action.isEnabled ? 1 : 0.45)
                .accessibilityLabel(action.name)
                if let badge = tile.pinBadge(hovered: pointer != nil) {
                    Button(action: togglePin) {
                        SiteControlsPinBadge(badge: badge)
                            .frame(width: Self.pinTarget, height: Self.pinTarget)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isOverPin = $0 }
                    // Arc's disc is centred 4 pt inside the tile's corner.
                    .offset(x: Self.pinTarget / 2 - 4, y: Self.pinTarget / 2 - 4)
                    .accessibilityLabel(pinned ? "Unpin \(action.name)" : "Pin \(action.name)")
                }
            case .add:
                Button(action: click) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.7))
                        .frame(width: SiteControlCenterView.tile.width, height: SiteControlCenterView.tile.height)
                        .background(SiteControlsTileBackground(raised: false))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Extensions")
            }
        }
        .frame(width: SiteControlCenterView.tile.width, height: SiteControlCenterView.tile.height)
        .onHover { isOverTile = $0 }
        .onChange(of: [isOverTile, isOverPin]) { _, _ in
            pointerMoved(isOverTile || isOverPin ? SiteControlCenter.TileHover(id: tile.id, onPin: isOverPin) : nil)
        }
        .contextMenu {
            Button("Manage Extensions…", action: manage)
            if case .action(let action, let pinned) = tile {
                Divider()
                Button(pinned ? "Unpin \(action.name)" : "Pin \(action.name)", action: togglePin)
            }
        }
    }
}

/// Arc's pin button: a 14 pt disc in Arc's blue with a pale pin, the disc
/// at a third of its strength while it only offers to pin.
struct SiteControlsPinBadge: View {
    var badge: SiteControlCenter.PinBadge = .pinned

    /// #1F2AFF, read off Arc's (2026-11-14 captures).
    static let fill = Color(.sRGB, red: 0.122, green: 0.165, blue: 1)
    static let diameter: CGFloat = 14

    var body: some View {
        // Arc's pin takes the tile's grey (a cut-out, or drawn in it): white, a little short of full.
        Image(systemName: "pin.fill")
            .font(.system(size: 8.5, weight: .bold))
            .rotationEffect(.degrees(45))
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: Self.diameter, height: Self.diameter)
            .background(Self.fill.opacity(badge == .pinned ? 1 : 0.33), in: Circle())
    }
}

/// The label over the tile under the pointer: small, dark and rounded, as
/// Arc's own tooltips (`ArcTooltip`), and much sooner than a system one.
/// Centred over its tile, kept inside the panel.
private struct SiteControlsHoverLabel: View {
    let text: String
    let tileIndex: Int
    @Environment(\.colorScheme) private var colorScheme

    private static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let height: CGFloat = 20
    private static let inset: CGFloat = 7
    /// How far past the grid's sides it may reach (the panel's inset is 10).
    private static let overhang: CGFloat = 6

    var body: some View {
        let pitch = CGSize(width: SiteControlCenterView.tile.width + SiteControlCenterView.spacing,
                           height: SiteControlCenterView.tile.height + SiteControlCenterView.spacing)
        let column = CGFloat(tileIndex % SiteControlCenter.extensionColumns)
        let row = CGFloat(tileIndex / SiteControlCenter.extensionColumns)
        let limit = SiteControlCenterView.width + 2 * Self.overhang
        let width = min(ceil((text as NSString).size(withAttributes: [.font: Self.font]).width) + 2 * Self.inset, limit)
        let centre = column * pitch.width + SiteControlCenterView.tile.width / 2
        let x = min(max(centre - width / 2, -Self.overhang), SiteControlCenterView.width + Self.overhang - width)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Text(text)
            .font(Font(Self.font))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, Self.inset)
            .frame(width: width, height: Self.height)
            .background(Color(white: colorScheme == .dark ? 0.30 : 0.15), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
            .offset(x: x, y: row * pitch.height - Self.height - 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// `--rearc-site-controls-preview=NAME` opens the site controls on the first
/// web page, as if the pointer rested on that extension's tile (`NAME:pin`:
/// on its pin button; `+`: on the last tile), so the hover states can be
/// looked at without moving the pointer. The preview has its own pins, the
/// extension IDs in `--rearc-site-controls-preview-pins=ID,ID`: the
/// person's are neither shown nor changed, and they are kept in memory only. Like the self-test it runs only
/// where verification may (a development build, or a verification bundle
/// with `REARC_RELEASE_VERIFICATION=1`); a shipped bundle ignores the flags.
enum SiteControlsPreview {
    static let flagPrefix = "--rearc-site-controls-preview="
    static let pinsFlagPrefix = "--rearc-site-controls-preview-pins="
    static let requested: String? = requestedTile()

    static func requestedTile(arguments: [String] = CommandLine.arguments,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        guard let argument = arguments.dropFirst().last(where: { $0.hasPrefix(flagPrefix) }),
              EngineLaunchOptions.allowsVerification(infoDictionary: infoDictionary, environment: environment) else { return nil }
        return String(argument.dropFirst(flagPrefix.count))
    }

    static func requestedPins(arguments: [String] = CommandLine.arguments) -> ExtensionPins {
        let list = arguments.dropFirst().last { $0.hasPrefix(pinsFlagPrefix) }?.dropFirst(pinsFlagPrefix.count) ?? ""
        return ExtensionPins(pinnedIDs: list.split(separator: ",").map(String.init))
    }

    @MainActor private static var hasOpened = false

    /// Opens the panel once, when the window shows a web page.
    @MainActor
    static func openWhenReady(in model: BrowserViewModel) async {
        guard requested != nil, !hasOpened else { return }
        hasOpened = true
        model.extensions.usePinsInMemory(requestedPins())
        while SiteControlCenter.site(for: model.store.selectedTab?.url) == nil {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
        }
        // The toolbar and the tab's extension list need a moment more.
        try? await Task.sleep(for: .seconds(2))
        if !Task.isCancelled { model.showSiteControlCenter() }
    }
}

/// A Settings row: Arc's round taupe icon, the title and the site's state.
/// One action is the click; more open a menu under the row.
struct SiteControlsSettingRowView: View {
    let row: SiteControlCenter.SettingRow
    let isDark: Bool
    /// The row has a list under it: a chevron at its right edge opens and
    /// closes it, apart from the row's own click.
    var disclosure: Binding<Bool>?
    let perform: (SiteControlCenter.SettingAction) -> Void
    @State private var anchor: NSView?
    @State private var isHovering = false

    private static let disc = Color(.sRGB, red: 0.80, green: 0.76, blue: 0.72)

    var body: some View {
        HStack(spacing: 0) {
            rowButton
            if let disclosure {
                let title = disclosure.wrappedValue ? SiteControlCenter.hideBlockedListTitle : SiteControlCenter.showBlockedListTitle
                Button { disclosure.wrappedValue.toggle() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(disclosure.wrappedValue ? 90 : 0))
                        .frame(width: SiteControlsBlockedListMetrics.disclosureWidth, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(title)
                .accessibilityLabel(title)
                .accessibilityIdentifier("site-controls-blocked-list-disclosure")
            }
        }
    }

    private var rowButton: some View {
        Button(action: click) {
            HStack(spacing: 10) {
                Image(systemName: row.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(isDark ? Color.white.opacity(0.22) : Self.disc, in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(row.state)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(Color.primary.opacity(isHovering && !row.actions.isEmpty ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -4)
        .disabled(row.actions.isEmpty)
        .background(AnchorReader { anchor = $0 })
        .onHover { isHovering = $0 }
        .help(row.actions.count == 1 ? row.actions[0].title : "\(row.title): \(row.state)")
        .accessibilityLabel("\(row.title), \(row.state)")
    }

    private func click() {
        if row.actions.count == 1 { return perform(row.actions[0]) }
        let menu = NSMenu()
        for action in row.actions {
            menu.addItem(ClosureMenuItem(action.title) { perform(action) })
        }
        popUp(menu, under: anchor)
    }
}

enum SiteControlsBlockedListMetrics {
    /// Narrow: the row's title only just fits the panel beside it.
    static let disclosureWidth: CGFloat = 16
    static let lineHeight: CGFloat = 22
    /// More lines than this scroll.
    static let visibleLines = 7
    /// The list starts a little inside the row's icon.
    static let inset: CGFloat = 8
    /// A site's name is cut from the left past this many characters, so its registrable domain always shows.
    static let hostLimit = 24
}

/// "Blocked on this page" (CONTENT-BLOCKING.md §3): under the blocking row,
/// the sites whose requests were blocked in this tab's page, each with its
/// tag and count, most blocked first. Under the pointer a line offers Allow,
/// which adds one line to the person's own rules and reloads the tab; what
/// was allowed that way on this site is listed below with Remove.
///
/// The list is the engine's, read while this view is on screen. Nothing of
/// it is kept here once the panel closes.
struct SiteControlsBlockedListView: View {
    let model: BrowserViewModel
    let engine: any WebEngine
    let site: SiteControlCenter.Site
    /// The row's disclosure. The hosts allowed on this site show either way:
    /// once a host is allowed nothing of it is counted, and Remove must stay in reach.
    let isOpen: Bool

    var body: some View {
        // One reading of the engine gives the lines and the site they are for:
        // Allow and Remove carry the site this drew, not the tab's address at the click.
        if let list = model.blockedList(for: engine) {
            let canAllow = model.canAllowBlockedHosts(for: engine, on: list)
            let pageSite = list.pageSite
            let allowed = pageSite.map { model.allowedBlockedHosts(for: engine, pageSite: $0) } ?? []
            if (isOpen && !list.isEmpty) || !allowed.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    if isOpen, !list.isEmpty {
                        SiteControlsBlockedLinesView(list: list, canAllow: canAllow) { host in
                            if let pageSite { model.setBlockedHost(host, allowed: true, on: pageSite, of: engine) }
                        }
                    }
                    if let pageSite, !allowed.isEmpty {
                        Text(SiteControlCenter.allowedOnSiteTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(height: SiteControlsBlockedListMetrics.lineHeight)
                        ForEach(allowed, id: \.self) { host in
                            SiteControlsBlockedLine(host: host, tag: "", count: nil,
                                                    action: canAllow ? (title: "Remove", help: SiteControlCenter.removeAllowedHostTitle(host)) : nil,
                                                    actionAlwaysShows: true) {
                                model.setBlockedHost(host, allowed: false, on: pageSite, of: engine)
                            }
                        }
                    }
                }
                .padding(.leading, SiteControlsBlockedListMetrics.inset)
                .accessibilityIdentifier("site-controls-blocked-list")
            }
        }
    }
}

/// The blocked sites' lines. Made when the list opens, so the order by count
/// is taken then: while it is open a line stays where it is, its count
/// changes in place and new sites go underneath. The page decides the counts,
/// and lines that sorted themselves could change places under the pointer as
/// the person clicks Allow (security BL-03).
private struct SiteControlsBlockedLinesView: View {
    let list: ContentBlockingBlockedList
    let canAllow: Bool
    /// With the name the line showed.
    let allow: (String) -> Void
    /// The hosts shown, top to bottom.
    @State private var order: [String] = []

    var body: some View {
        let entries = list.entries(keeping: order)
        let lines = VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                SiteControlsBlockedLine(host: entry.host, tag: entry.tagText, count: entry.count, spoken: entry.spokenText,
                                        action: canAllow && entry.canBeAllowed ? (title: "Allow", help: SiteControlCenter.allowHostTitle(entry.host)) : nil) {
                    allow(entry.host)
                }
            }
            if let more = list.uncountedText {
                Text(more)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(height: SiteControlsBlockedListMetrics.lineHeight)
            }
        }
        let count = entries.count + (list.uncountedText == nil ? 0 : 1)
        Group {
            if count > SiteControlsBlockedListMetrics.visibleLines {
                ScrollView { lines }
                    .frame(height: CGFloat(SiteControlsBlockedListMetrics.visibleLines) * SiteControlsBlockedListMetrics.lineHeight)
            } else {
                lines
            }
        }
        .onChange(of: entries.map(\.host), initial: true) { _, hosts in order = hosts }
    }
}

/// One line of the blocked list: the site, never cut on its right; then its
/// tag and count, or under the pointer its button.
private struct SiteControlsBlockedLine: View {
    let host: String
    let tag: String
    let count: Int?
    var spoken: String?
    /// nil: the line only reports (a private window).
    let action: (title: String, help: String)?
    var actionAlwaysShows = false
    let perform: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(PageOrigin.shortenedHost(host, limit: SiteControlsBlockedListMetrics.hostLimit))
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            if let action, actionAlwaysShows || isHovering {
                Button(action.title, action: perform)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help(action.help)
                    .accessibilityLabel(action.help)
            } else {
                Text(tag)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .frame(height: SiteControlsBlockedListMetrics.lineHeight)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { if let action { Button(action.help, action: perform) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken ?? host)
        // The button shows under the pointer only: VoiceOver gets the action on the line.
        .accessibilityActions { if let action { Button(action.help, action: perform) } }
    }
}

/// Arc's ⋯ at the footer's right: zoom, the site's boosts, cookies and site data, Site Settings.
private struct SiteControlsMoreButton: View {
    let model: BrowserViewModel
    let engine: any WebEngine
    let site: SiteControlCenter.Site
    let dismiss: () -> Void
    @State private var anchor: NSView?

    var body: some View {
        Button(action: showMenu) {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.75))
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(AnchorReader { anchor = $0 })
        .help("More Site Controls")
        .accessibilityLabel("More Site Controls")
    }

    /// Built at the click, so the panel observes none of it.
    private func showMenu() {
        let menu = NSMenu()
        for (index, section) in model.siteControlsMenu(for: engine, site: site).enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for item in section {
                let entry = ClosureMenuItem(item.title) { [model, engine, site, dismiss] in
                    switch item {
                    case .editBoosts, .cookiesAndSiteData, .siteSettings: dismiss()
                    default: break
                    }
                    model.performSiteControlsMenuItem(item, engine: engine, site: site)
                }
                switch item {
                case .zoomLevel: entry.isEnabled = false
                case .actualSize(let enabled): entry.isEnabled = enabled
                case .boost(_, _, let enabled): entry.state = enabled ? .on : .off
                default: break
                }
                menu.addItem(entry)
            }
        }
        menu.autoenablesItems = false
        popUp(menu, under: anchor)
    }
}

/// Pops a menu just below `view`.
private func popUp(_ menu: NSMenu, under view: NSView?) {
    guard let view else { return }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
}

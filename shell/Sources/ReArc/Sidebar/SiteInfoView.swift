import AppKit
import SwiftUI
import SidebarModel

extension BrowserViewModel {
    func siteConnection(of engine: any WebEngine) -> SiteControlCenter.Connection {
        switch engine.securityState {
        case .secure: return .secure
        case .insecure: return .insecure
        case .dangerous: return .dangerous
        case .none, .unknown: return .unknown
        }
    }

    /// The engine's answer for `site`, when it reports one and the answer is for this site.
    func siteAccess(for engine: (any WebEngine)?, site: SiteControlCenter.Site) -> SiteAccess? {
        siteAccessModel(for: engine)?.access.flatMap { $0.origin == site.origin ? $0 : nil }
    }

    /// The site information entry at the start of the address.
    func siteInfoBadge(for engine: any WebEngine, site: SiteControlCenter.Site) -> SiteInfoBadge {
        SiteInfoBadge.make(host: site.host, connection: siteConnection(of: engine), access: siteAccess(for: engine, site: site))
    }

    /// The rows of the site information popover: the site's permissions and
    /// devices, without the panel's other settings (blocking, automatic PiP).
    func siteInfoRows(for engine: any WebEngine, site: SiteControlCenter.Site) -> [SiteControlCenter.SettingRow] {
        siteControlSettingRows(for: engine, site: site).filter { row in
            switch row.kind {
            case .permission, .sitePermission, .siteDevice, .reloadToApply: return true
            case .autoPictureInPicture, .contentBlocking, .websiteDarkMode: return false
            }
        }
    }
}

/// The site information entry at the start of the address (Chrome's tune
/// icon, Arc's lock): the connection, or what the page is using right now
/// (camera, microphone, a Bluetooth or USB device). A click lists what the
/// site may do, with a control on each row.
struct SiteInfoButton: View {
    let model: BrowserViewModel
    let engine: any WebEngine
    let site: SiteControlCenter.Site
    /// The address's ink, for the idle glyph.
    var ink: Color
    /// The popover's links to the Site Control Center and Chromium's Site
    /// Settings, which open in the main window on the profile's own rules.
    /// A private window has neither: its rules are its session's.
    var showsPanelLinks = true
    @State private var isShown = false

    var body: some View {
        let badge = model.siteInfoBadge(for: engine, site: site)
        Button { isShown.toggle() } label: {
            Image(systemName: badge.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.tint(badge) ?? ink)
                .frame(width: 22, height: 22)
                .background((Self.tint(badge) ?? .clear).opacity(badge.isInUse ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .addressBarControlFocus()
        .help(badge.help)
        .accessibilityLabel("Site information")
        .accessibilityValue(badge.help)
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            SiteInfoPopoverView(model: model, engine: engine, site: site, showsPanelLinks: showsPanelLinks) { isShown = false }
        }
        .transformPreference(AddressBarFocusPreference.self) { $0 = $0 || isShown }
    }

    /// In use: orange, as macOS marks a microphone in use. A connection problem: orange, a dangerous site red.
    static func tint(_ badge: SiteInfoBadge) -> Color? {
        if badge.isWarning, badge.symbol == "exclamationmark.octagon.fill" { return .red }
        return badge.isInUse || badge.isWarning ? .orange : nil
    }
}

/// What the site may do: the connection, what is in use now, every
/// permission the engine holds for the site and the devices chosen for it.
struct SiteInfoPopoverView: View {
    let model: BrowserViewModel
    let engine: any WebEngine
    let site: SiteControlCenter.Site
    var showsPanelLinks = true
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    static let width: CGFloat = 280

    var body: some View {
        let footer = model.siteControlsFooter(for: engine)
        let access = model.siteAccess(for: engine, site: site)
        let rows = model.siteInfoRows(for: engine, site: site)
        VStack(alignment: .leading, spacing: 0) {
            Text(site.host)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.head)
            Label(footer.title, systemImage: footer.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(footer.isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .padding(.top, 3)
            if let access, access.isAnythingInUse {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(SiteAccessType.inUseOrder.filter(access.inUse.contains), id: \.self) { name in
                        Label("Using \(SiteAccessType.inUsePhrase(name))", systemImage: SiteAccessType.inUseSymbol(name))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.top, 10)
                .accessibilityElement(children: .combine)
            }
            Text("Permissions")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.8))
                .padding(.top, 14)
                .padding(.bottom, 6)
            if rows.isEmpty {
                Text(access?.isPrivate == true
                    ? "This site has no permissions in this private window. It asks before it uses your camera, location or devices."
                    : "This site has no permissions of its own. It asks before it uses your camera, location or devices.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { row in
                        SiteControlsSettingRowView(row: row, isDark: colorScheme == .dark) { action in
                            if action == .openSiteSettings || action == .reloadPage { dismiss() }
                            model.performSiteSetting(action, on: row, engine: engine, site: site)
                        }
                    }
                }
            }
            if showsPanelLinks { panelLinks }
        }
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
        // Asked for when the popover opens, so it shows what holds now.
        .task { model.siteAccessModel(for: engine)?.refresh() }
    }

    @ViewBuilder
    private var panelLinks: some View {
        Divider().padding(.top, 10).padding(.bottom, 8)
        HStack {
            if model.sitePermissionsLiveInEngine {
                Button("Site Settings…") {
                    dismiss()
                    model.openSiteSettings(origin: site.origin)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .help("Every setting for \(site.host)")
            }
            Spacer()
            Button("Site Controls") {
                dismiss()
                // Once this popover has closed: two popovers do not open at once.
                DispatchQueue.main.async { model.showSiteControlCenter() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .help("Extensions, capture and the site's other settings")
        }
    }
}

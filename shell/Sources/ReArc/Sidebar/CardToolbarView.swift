import AppKit
import SwiftUI
import SidebarModel

/// Arc's toolbar strip inside the page card, shown with "URL in toolbar"
/// on (`topBarURLEnabled`, THEMES.md §4.4): 32 pt tall over the card's own
/// fill, back / forward / reload on a 37 pt pitch at the left, the address
/// centred, site controls and split view at the right, a hairline below.
struct CardToolbarView: View {
    let model: BrowserViewModel
    /// With the sidebar on the right the traffic lights sit at the strip's left.
    var trafficLightsClearance: CGFloat = 0
    @Environment(\.sidebarWindow) private var window
    @Environment(\.themeChrome) private var chrome
    @State private var showsSiteControls = false
    @State private var siteControlsAnchor: NSView?
    @State private var isHoveringURL = false
    @AppStorage(ToolbarURLPreference.key) private var urlInToolbar = ToolbarURLPreference.defaultValue
    @AppStorage(ToolbarPageColorPreference.key) private var matchesPageColor = ToolbarPageColorPreference.defaultValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 32

    var body: some View {
        let engine = model.focusedEngine(in: window)
        let tab = model.selectedTab(in: window)
        let url = engine?.currentURL ?? tab?.url
        let site = SiteControlCenter.site(for: url)
        let tint = matchesPageColor ? engine?.pageColor : nil
        let palette = CardToolbarInk(chrome: chrome, tint: tint)
        let ink = palette.ink, quietInk = palette.quiet
        let container = model.containerLabel(for: engine, tab: tab)
        ZStack {
            HStack(spacing: 6) {
                if let container { ContainerChip(label: container, ink: ink) }
                // Site information at the start of the address: the connection, or what the page uses now.
                if let engine, let site { SiteInfoButton(model: model, engine: engine, site: site, ink: quietInk) }
                Button { model.focusLocation() } label: {
                    // Two texts (security AG-01): the host, already cut from the left to keep its
                    // registrable domain, never truncates; only the path gives way, at its tail.
                    HStack(spacing: 0) {
                        if let parts = SplitPaneToolbarLayout.addressParts(url) {
                            Text(parts.host).fixedSize()
                            Text(parts.rest).truncationMode(.tail)
                        } else {
                            Text("Search or Enter URL…")
                        }
                    }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .accessibilityElement(children: .combine)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(palette.hover.opacity(isHoveringURL ? 1 : 0), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .addressBarControlFocus()
                .onHover { isHoveringURL = $0 }
                .help(url?.absoluteString ?? "Open the command bar (⌘L)")
            }
            .padding(.horizontal, 140)
            .padding(.trailing, 20) // centred about 10 pt left of the card's centre
            .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                let side = model.sidebarSide
                if !model.isSidebarVisible(in: window), side == .left {
                    // With the sidebar hidden its toggle moves here, before back (§3).
                    navButton(side.toggleSymbol, help: "Show Sidebar (⌘S)", enabled: true) { model.toggleSidebar(in: window) }
                }
                navButton("arrow.left", help: "Back (⌘[)", enabled: engine?.canGoBack == true) { model.goBack() }
                navButton("arrow.right", help: "Forward (⌘])", enabled: engine?.canGoForward == true) { model.goForward() }
                if engine?.isLoading == true {
                    navButton("xmark", help: "Stop Loading (⌘.)", enabled: true) { model.stopLoading() }
                } else {
                    navButton("arrow.clockwise", help: "Reload (⌘R, ⇧⌘R ignores the cache)", enabled: engine != nil) {
                        model.reload(ignoringCache: NSEvent.modifierFlags.contains(.shift))
                    }
                }
                Spacer(minLength: 0)
                ExtensionToolbarView(model: model, engine: engine)
                    .foregroundStyle(palette.extensionInk)
                Button { showsSiteControls.toggle() } label: {
                    Image(systemName: "slider.horizontal.2.square")
                        .font(.system(size: 15))
                        .frame(width: 36, height: Self.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .addressBarControlFocus()
                .foregroundStyle(quietInk)
                .disabled(site == nil || engine == nil)
                .background(AnchorReader { siteControlsAnchor = $0 })
                .help(site.map { "Site controls for \($0.host)" } ?? "Site controls")
                .accessibilityLabel("Site controls")
                .popover(isPresented: $showsSiteControls, arrowEdge: .bottom) {
                    if let engine, let site {
                        SiteControlCenterView(model: model, engine: engine, site: site, anchor: siteControlsAnchor) {
                            showsSiteControls = false
                        }
                    }
                }
                Button { model.addSplitView(orientation: .horizontal) } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 13))
                        .frame(width: 36, height: Self.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .addressBarControlFocus()
                .foregroundStyle(quietInk)
                .help("Add Split View")
                .accessibilityLabel("Add Split View")
                if !model.isSidebarVisible(in: window), side == .right {
                    // Mirrored: the toggle sits on the sidebar's side.
                    navButton(side.toggleSymbol, help: "Show Sidebar (⌘S)", enabled: true) { model.toggleSidebar(in: window) }
                }
            }
            .padding(.horizontal, 2.5)
            .padding(.leading, trafficLightsClearance)
        }
        .frame(height: Self.height)
        .pageColorToolbar(tint, palette: palette, reduceMotion: reduceMotion)
        .transformPreference(AddressBarFocusPreference.self) { $0 = $0 || showsSiteControls }
        .onChange(of: model.siteControlCenterRequest) { _, _ in
            if site != nil, model.isKeyBrowserWindow(window) { showsSiteControls = true }
        }
        .contextMenu {
            Button("Copy URL") { model.copyURL() }.disabled(tab == nil)
            Divider()
            Button("Show URL in Sidebar") { urlInToolbar = false }
        }
    }

    private func navButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        CardToolbarButton(symbol: symbol, help: help, enabled: enabled, action: action)
    }

}

/// Measured greys (§4.4): enabled glyphs and the address, disabled glyphs,
/// right icons. The split panes' rows use the same. On the page's colour
/// (Settings › Advanced › Match toolbar to website colours) they are white or
/// black, whichever contrasts more (`PageColorInk`).
struct CardToolbarInk {
    let isDark: Bool
    var pageInk: PageColorInk?

    init(isDark: Bool) {
        self.isDark = isDark
    }

    init(chrome: ThemeChromeColors, tint: PageColor?) {
        let ink = tint.map(PageColorInk.init(on:))
        // The strip sits on the card: 62 % white in light, so dark ink even
        // where the sidebar takes light ink; the bare gradient in dark.
        isDark = ink?.isLight ?? (chrome.isWindowDark && chrome.isDark)
        pageInk = ink
    }

    var ink: Color {
        if let pageInk { return Color(pageInk.base).opacity(pageInk.inkOpacity) }
        return isDark ? Color(white: 0.78) : Color(.sRGB, red: 0.384, green: 0.384, blue: 0.392)
    }
    var disabled: Color {
        if let pageInk { return Color(pageInk.base).opacity(pageInk.disabledOpacity) }
        return isDark ? Color(white: 0.42) : Color(.sRGB, red: 0.714, green: 0.714, blue: 0.737)
    }
    var quiet: Color {
        if let pageInk { return Color(pageInk.base).opacity(pageInk.quietOpacity) }
        return isDark ? Color(white: 0.55) : Color(.sRGB, red: 0.733, green: 0.725, blue: 0.733)
    }
    /// The extension buttons draw in `.secondary` of this.
    var extensionInk: Color { pageInk == nil ? .primary : ink }
    /// The address's hover wash.
    var hover: Color {
        if let pageInk { return Color(pageInk.base).opacity(pageInk.isLight ? 0.12 : 0.06) }
        return Color.primary.opacity(0.05)
    }
}

extension EnvironmentValues {
    /// The page colour the toolbar strip around a `CardToolbarButton` is drawn in.
    @Entry var pageToolbarTint: PageColor?
}

extension Color {
    init(_ color: PageColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }
}

extension View {
    /// The strip's fill and hairline. On the page's colour it is filled with it
    /// and loses the hairline, so it runs into the page's own top bar as in
    /// Arc; the change cross-fades in 0.25 s, at once under Reduce Motion.
    func pageColorToolbar(_ tint: PageColor?, palette: CardToolbarInk, reduceMotion: Bool) -> some View {
        environment(\.pageToolbarTint, tint)
            .background { if let tint { Color(tint) } }
            .overlay(alignment: .bottom) {
                if tint == nil {
                    Rectangle()
                        .fill(Color.primary.opacity(palette.isDark ? 0.12 : 0.05))
                        .frame(height: 1)
                        .offset(y: 1)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: tint)
    }
}

/// A navigation glyph on the card toolbar's 37 pt pitch.
struct CardToolbarButton: View {
    let symbol: String
    let help: String
    var enabled = true
    var width: CGFloat = 37
    let action: () -> Void
    @Environment(\.themeChrome) private var chrome
    @Environment(\.pageToolbarTint) private var tint

    var body: some View {
        let ink = CardToolbarInk(chrome: chrome, tint: tint)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: width, height: CardToolbarView.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .addressBarControlFocus()
        .foregroundStyle(enabled ? ink.ink : ink.disabled)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Puts the traffic lights where Arc draws them (THEMES.md §4.5): 14 pt
/// buttons on a 23 pt pitch, centred at x 19.5 / 42.5 / 65.5 and y 23.5 from
/// the window's top. AppKit lays the title bar out again on resize, key
/// changes and full screen, so it re-applies after each. It also does so
/// whenever the window's title changes (each tab switch and page title,
/// through `navigationTitle`), which no window notification reports: the
/// title is observed, and so are the title bar's own views, for any cause
/// not listed here.
struct TrafficLightPositioner: NSViewRepresentable {
    static let firstCentreX: CGFloat = 19.5
    static let pitch: CGFloat = 23
    static let centreY: CGFloat = 23.5
    /// The title bar area tall enough to hold the buttons at that centre.
    static let titlebarHeight: CGFloat = 47
    static let titlebarWidth: CGFloat = 84

    static func titlebarFrame(windowSize: NSSize) -> NSRect {
        NSRect(x: 0, y: windowSize.height - titlebarHeight,
               width: min(titlebarWidth, windowSize.width), height: titlebarHeight)
    }

    /// With the sidebar on the right and no toolbar strip, the card starts
    /// this far down: under the buttons (bottom at 30.5) by Arc's 7.5 pt.
    static let cardClearance: CGFloat = centreY + 7 + 7.5

    /// The sidebar is hidden: so are the buttons, as in Arc.
    var isHidden = false
    /// Arc's 23.5; the card toolbar's middle with the sidebar on the right.
    var centreY: CGFloat = Self.centreY

    func makeNSView(context: Context) -> PositionerView { PositionerView() }
    func updateNSView(_ nsView: PositionerView, context: Context) {
        nsView.buttonsHidden = isHidden
        nsView.centreY = centreY
        nsView.reposition()
    }

    final class PositionerView: NSView {
        private static let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        private var observers: [NSObjectProtocol] = []
        private var titleObservation: NSKeyValueObservation?
        /// True while `reposition` moves the views itself.
        private var isRepositioning = false
        private var repositionPending = false
        var buttonsHidden = false
        var centreY = TrafficLightPositioner.centreY

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            titleObservation = nil
            guard let window else { return }
            observeTitlebarLayout(in: window)
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didChangeScreenNotification,
            ]
            observers += names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reposition() }
                }
            }
            reposition()
            DispatchQueue.main.async { [weak self] in self?.reposition() }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        /// AppKit puts the title bar and its buttons back at the system's
        /// place whenever it tiles the title bar, and a new window title
        /// makes it tile. Seen on screen in build 1126: after a tab was
        /// selected the buttons sat up and left of their place, and the
        /// title bar again covered the window's whole top edge, until the
        /// window next changed key.
        ///
        /// The title is observed, so the buttons are back before the
        /// setter returns and no frame shows them out of place. The title
        /// bar's views are observed too, for causes nobody listed. A view
        /// cannot be moved from inside its own frame notification (AppKit
        /// drops the change), so that path re-applies on the next turn of
        /// the main queue, once for any number of moves.
        private func observeTitlebarLayout(in window: NSWindow) {
            titleObservation = window.observe(\.title) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reposition() }
            }
            guard let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview, let container = titlebar.superview else { return }
            let buttons = Self.kinds.compactMap { window.standardWindowButton($0) }
            for view in [container, titlebar] + buttons {
                view.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view,
                                                                        queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.titlebarViewMoved() }
                })
            }
        }

        private func titlebarViewMoved() {
            guard !isRepositioning, !repositionPending else { return }
            repositionPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.repositionPending = false
                self.reposition()
            }
        }

        func reposition() {
            guard !isRepositioning else { return }
            isRepositioning = true
            defer { isRepositioning = false }
            for kind in Self.kinds {
                guard let button = window?.standardWindowButton(kind), button.isHidden != buttonsHidden else { continue }
                button.isHidden = buttonsHidden
            }
            // In full screen, and on the way in and out, the buttons are in AppKit's own window.
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview, let container = titlebar.superview, container.window === window else { return }
            let height = TrafficLightPositioner.titlebarHeight
            // The titlebar container intercepts clicks even where it is transparent.
            // Keep it over the traffic lights, leaving the page toolbar and toast clickable.
            let frame = TrafficLightPositioner.titlebarFrame(windowSize: window.frame.size)
            if container.frame != frame { container.frame = frame }
            titlebar.frame = NSRect(x: 0, y: 0, width: container.bounds.width, height: height)
            for (index, kind) in Self.kinds.enumerated() {
                guard let button = window.standardWindowButton(kind) else { continue }
                let size = button.frame.size
                let centreX = TrafficLightPositioner.firstCentreX + TrafficLightPositioner.pitch * CGFloat(index)
                let fromTop = centreY
                let y = titlebar.isFlipped ? fromTop - size.height / 2 : height - fromTop - size.height / 2
                let origin = NSPoint(x: (centreX - size.width / 2).rounded(), y: y.rounded())
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }
    }
}

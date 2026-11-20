import SwiftUI
import SidebarModel

extension EnvironmentValues {
    /// The browser window a sidebar or content view belongs to (per-window focused space).
    @Entry var sidebarWindow: SidebarWindowID?
    /// The window's Library is drawn over its sidebar (`SidebarView`).
    @Entry var sidebarCoveredByLibrary = false
    /// The sidebar is the mini column (⇧⌘S): rows draw their icons only.
    @Entry var isMiniSidebar = false
}

/// Per-window focused space (wave 19): each browser window shows its own
/// space. The key window's space is the store's active space, so commands
/// act on it; these helpers give any window its own view of the sidebar.
extension BrowserViewModel {

    /// A browser window became key: bring back its space and selection, and
    /// load what it shows (the key window's host also takes the tab's lease).
    func windowBecameKey(_ window: SidebarWindowID) {
        if store.keyWindowID != window { cancelTabSwitcher() }
        // Another window taking the keys closes the bar, as Arc does, so typing
        // never lands in a bar that window does not show.
        closeCommandBar(openedOutside: window)
        keyLittleArcID = nil
        store.windowBecameKey(window)
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
    }

    /// `BrowserView` tells which NSWindow it sits in (nil: it left it).
    func noteBrowserWindow(_ window: NSWindow?, id: SidebarWindowID) {
        browserWindowRefs.removeAll { $0.window == nil || $0.id == id }
        if let window { browserWindowRefs.append(BrowserWindowRef(window: window, id: id)) }
    }

    /// The browser window an NSWindow is, if it is one.
    func sidebarWindowID(of window: NSWindow?) -> SidebarWindowID? {
        guard let window else { return nil }
        return browserWindowRefs.first { $0.window === window }?.id
    }

    /// The bar belongs to the window it opened in (`commandBarWindowID`):
    /// when browser window `window` takes the keys or a click while another
    /// one shows the bar, the bar closes. True when it did. The one rule for
    /// both ways in (`windowBecameKey`, `handleCommandBarMouseDown`).
    @discardableResult
    func closeCommandBar(openedOutside window: SidebarWindowID) -> Bool {
        guard isCommandBarPresented, let opened = commandBarWindowID, opened != window else { return false }
        dismissCommandBar()
        return true
    }

    /// The key monitor's part for a mouse-down (`installTabSwitcherMonitor`).
    /// The bar used to close only when AppKit made the clicked window key
    /// (`windowBecameKey`), and AppKit leaves a window where it is for a click
    /// with ⌘ held: the bar stayed open over a window that was being used.
    /// So the click itself closes the bar, and once it has been handled a
    /// window AppKit did not bring forward is brought forward here.
    func handleCommandBarMouseDown(in window: NSWindow?) {
        guard isCommandBarPresented, let window, let id = sidebarWindowID(of: window),
              closeCommandBar(openedOutside: id) else { return }
        DispatchQueue.main.async { [weak window] in
            guard let window, let app = NSApp, app.isActive, window.isVisible, !window.isKeyWindow else { return }
            window.makeKeyAndOrderFront(nil)
        }
    }

    func space(in window: SidebarWindowID?) -> Space {
        store.focusedSpace(in: window)
    }

    func themeColor(in window: SidebarWindowID?) -> Color {
        let theme = shownTheme(in: window)
        return Color(red: theme.red, green: theme.green, blue: theme.blue)
    }

    func selectedItemID(in window: SidebarWindowID?) -> UUID? {
        store.selectedItemID(in: window)
    }

    func selectedTab(in window: SidebarWindowID?) -> Tab? {
        store.selectedTab(in: window)
    }

    func selectedEaselRef(in window: SidebarWindowID?) -> SidebarEaselRef? {
        selectedItemID(in: window).flatMap { store.easelRef(withSidebarID: $0) }
    }

    func activeSplit(in window: SidebarWindowID?) -> SplitViewItem? {
        selectedItemID(in: window).flatMap { store.split(withID: $0) }
    }

    /// The window's profile as the person sees it: a container's parent.
    func profile(in window: SidebarWindowID?) -> Profile {
        store.profile(withID: store.owningProfileID(of: space(in: window).profileID)) ?? store.activeProfile
    }

    /// The engine of the tab a window shows (nil until it was loaded).
    func focusedEngine(in window: SidebarWindowID?) -> (any WebEngine)? {
        guard selectedEaselRef(in: window) == nil, let tab = selectedTab(in: window) else { return nil }
        return engineHost.engine(forTabID: tab.id, profileID: profileID(for: tab))
    }
}

/// A browser window's NSWindow with its sidebar identity (`BrowserViewModel.browserWindowRefs`).
struct BrowserWindowRef {
    weak var window: NSWindow?
    let id: SidebarWindowID
}

/// Reports when its window becomes key, stops being key, and closes.
struct WindowKeyObserver: NSViewRepresentable {
    var onBecameKey: () -> Void
    var onClose: () -> Void
    /// Focus left the window (it stays open).
    var onResignKey: () -> Void = {}
    /// The window the view is in now (nil: it left it).
    var onWindow: (NSWindow?) -> Void = { _ in }

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onBecameKey = onBecameKey
        view.onClose = onClose
        view.onResignKey = onResignKey
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {
        nsView.onBecameKey = onBecameKey
        nsView.onClose = onClose
        nsView.onResignKey = onResignKey
        nsView.onWindow = onWindow
    }

    final class ObservingView: NSView {
        var onBecameKey: (() -> Void)?
        var onClose: (() -> Void)?
        var onResignKey: (() -> Void)?
        var onWindow: ((NSWindow?) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            onWindow?(window)
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.onBecameKey?()
            })
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.onResignKey?()
            })
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.onClose?()
            })
            if window.isKeyWindow {
                // Only if it still is by then: a late report would leave a closed or
                // background window recorded as key (⌃Tab then refused to open).
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.window?.isKeyWindow == true else { return }
                    self.onBecameKey?()
                }
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

import SwiftUI
import SidebarModel

/// ⌘S per window (`SidebarVisibility`): each browser window shows or hides
/// its own sidebar. A view asks about the window it is in. Commands (⌘S,
/// the View menu, the command bar) act on the key window.
extension BrowserViewModel {

    func isSidebarVisible(in window: SidebarWindowID?) -> Bool {
        sidebarVisibility.isVisible(in: window)
    }

    /// `window`'s page is laid out beside its sidebar (wide from the start
    /// of a hide, narrow from the end of a show).
    func isSidebarLaidOut(in window: SidebarWindowID?) -> Bool {
        sidebarVisibility.isLaidOut(in: window)
    }

    /// 1 shown, 0 hidden; animated by ⌘S in `window`.
    func sidebarReveal(in window: SidebarWindowID?) -> Double {
        sidebarVisibility.reveal(in: window)
    }

    func isSidebarSliding(in window: SidebarWindowID?) -> Bool {
        sidebarVisibility.isSliding(in: window)
    }

    /// `window`'s hidden sidebar floats at its edge.
    func isSidebarPeeking(in window: SidebarWindowID?) -> Bool {
        sidebarVisibility.isPeeking(in: window)
    }

    /// A browser window comes up as the window it was opened from is (the
    /// key window), else with its sidebar shown. Registered before its
    /// first frame, with `openSidebarMode`.
    func openSidebarVisibility(for window: SidebarWindowID) {
        sidebarVisibility.open(window, openedFrom: store.keyWindowID == window ? nil : store.keyWindowID)
    }

    func forgetSidebarVisibility(for window: SidebarWindowID) {
        sidebarVisibility.forget(window)
    }

    /// The View menu's title for ⌘S: it follows the key window.
    var sidebarMenuTitle: String {
        isSidebarVisible(in: store.keyWindowID) ? "Hide Sidebar" : "Show Sidebar"
    }

    /// ⌘S (Arc's Show/Hide Sidebar) in `window`, or the key window, as the
    /// user's recording shows it (ARC-RECORDING-ANALYSIS.md §3): one quick
    /// push with no overshoot. The sidebar slides with the page's leading
    /// edge. A hide lays the page out wide at once and the receding sidebar
    /// uncovers it; a show slides the wide page right with the sidebar and
    /// lays it out narrow at the end. The page keeps keyboard focus. While
    /// hidden, the window's leading edge floats the sidebar. Every other
    /// window keeps its sidebar as it is.
    func toggleSidebar(in window: SidebarWindowID? = nil) {
        let target = window ?? store.keyWindowID
        PerfSignposts.interaction(.sidebarToggle, isSidebarVisible(in: target) ? "hide" : "show")
        let showing = sidebarVisibility.beginToggle(in: target)
        withAnimation(Self.sidebarAnimation, completionCriteria: .logicallyComplete) {
            sidebarVisibility.setReveal(showing ? 1 : 0, in: target)
        } completion: { [weak self] in
            guard let self else { return }
            self.sidebarVisibility.endToggle(showing: showing, in: target)
            self.onShellAnimationComplete?(.sidebarToggle)
        }
    }

    // MARK: - Floating sidebar

    func setSidebarPeeking(_ peeking: Bool, in window: SidebarWindowID? = nil) {
        let target = window ?? store.keyWindowID
        let state = sidebarVisibility.state(in: target)
        guard !state.isVisible || !peeking, state.isPeeking != peeking else { return }
        PerfSignposts.interaction(.sidebarPeek, peeking ? "reveal" : "dismiss")
        withAnimation(.easeOut(duration: 0.16), completionCriteria: .logicallyComplete) {
            _ = sidebarVisibility.setPeeking(peeking, in: target)
        } completion: { [weak self] in
            self?.onShellAnimationComplete?(.sidebarPeek)
        }
    }

    // MARK: - The key window's sidebar

    // What ⌘S would act on: for commands, the bench and tests. A view reads
    // its own window with the `in:` forms above, never these: the key
    // window's state drawn in every window is the bug this file fixes.

    var isSidebarVisible: Bool {
        get { isSidebarVisible(in: store.keyWindowID) }
        set { sidebarVisibility.update(in: store.keyWindowID) { $0.isVisible = newValue } }
    }

    var isSidebarLaidOut: Bool {
        get { isSidebarLaidOut(in: store.keyWindowID) }
        set { sidebarVisibility.update(in: store.keyWindowID) { $0.isLaidOut = newValue } }
    }

    var sidebarReveal: Double {
        get { sidebarReveal(in: store.keyWindowID) }
        set { sidebarVisibility.update(in: store.keyWindowID) { $0.reveal = newValue } }
    }

    var isSidebarSliding: Bool {
        isSidebarSliding(in: store.keyWindowID)
    }

    var isSidebarPeeking: Bool {
        get { isSidebarPeeking(in: store.keyWindowID) }
        set { sidebarVisibility.update(in: store.keyWindowID) { $0.isPeeking = newValue } }
    }
}

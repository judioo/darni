import Foundation

/// One window's sidebar between shown and hidden (⌘S), and its floating
/// state while hidden.
public struct SidebarVisibilityState: Equatable, Sendable {
    /// ⌘S's side: shown, or hidden (and then floating at the window's edge).
    public var isVisible = true
    /// The page is laid out beside the sidebar. It goes wide at the start of
    /// a hide and narrow at the end of a show, so Chromium resizes once per
    /// toggle and never per frame (ARC-RECORDING-ANALYSIS.md §3).
    public var isLaidOut = true
    /// 1 shown, 0 hidden; animated by ⌘S. The sidebar's edge sits at
    /// `reveal × sidebarWidth`.
    public var reveal: Double = 1
    /// ⌘S is mid-slide; `isVisible` says which way.
    public var isSliding = false
    /// The hidden sidebar shown floating while the pointer is at the window's
    /// edge (Arc `SidebarHovering` / floating sidebar).
    public var isPeeking = false

    public init() {}

    public static let shown = SidebarVisibilityState()

    public static var hidden: SidebarVisibilityState {
        var state = SidebarVisibilityState()
        state.isVisible = false
        state.isLaidOut = false
        state.reveal = 0
        return state
    }

    /// Where the state comes to rest: what a window opened from this one starts with.
    public var atRest: SidebarVisibilityState { isVisible ? .shown : .hidden }
}

/// Each browser window's sidebar, shown or hidden. ⌘S acts on one window
/// and the others keep theirs. A window opened from another starts as that
/// window is, any other starts shown, and a closed window is forgotten.
/// Nothing is saved: every window of a new launch starts shown.
///
/// The key is optional like `SidebarWidthMorph`'s: nil is a model with no
/// window (tests), which has a state of its own.
public struct SidebarVisibility: Equatable, Sendable {
    private var states: [SidebarWindowID?: SidebarVisibilityState] = [:]

    public init() {}

    /// A window never toggled or opened is shown.
    public func state(in window: SidebarWindowID?) -> SidebarVisibilityState {
        states[window] ?? .shown
    }

    public func isVisible(in window: SidebarWindowID?) -> Bool { state(in: window).isVisible }
    public func isLaidOut(in window: SidebarWindowID?) -> Bool { state(in: window).isLaidOut }
    public func reveal(in window: SidebarWindowID?) -> Double { state(in: window).reveal }
    public func isSliding(in window: SidebarWindowID?) -> Bool { state(in: window).isSliding }
    public func isPeeking(in window: SidebarWindowID?) -> Bool { state(in: window).isPeeking }

    public func isRegistered(_ window: SidebarWindowID) -> Bool { states[window] != nil }

    /// A new window: as the window it was opened from is, at rest, else
    /// shown. A window already registered keeps its state.
    public mutating func open(_ window: SidebarWindowID, openedFrom parent: SidebarWindowID? = nil) {
        guard states[window] == nil else { return }
        states[window] = parent.flatMap { states[$0] }?.atRest ?? .shown
    }

    public mutating func forget(_ window: SidebarWindowID) {
        states[window] = nil
    }

    /// Sets one value directly (tests, and the steps below).
    public mutating func update(in window: SidebarWindowID?, _ change: (inout SidebarVisibilityState) -> Void) {
        var state = state(in: window)
        change(&state)
        states[window] = state
    }

    /// ⌘S in `window`, before its slide: the new side, the page wide at once
    /// for a hide. Returns whether the sidebar is being shown. `reveal` is
    /// left for the animation (`setReveal`).
    @discardableResult
    public mutating func beginToggle(in window: SidebarWindowID?) -> Bool {
        let showing = !isVisible(in: window)
        update(in: window) { state in
            state.isVisible = showing
            state.isPeeking = false
            state.isSliding = true
            if !showing { state.isLaidOut = false }
        }
        return showing
    }

    public mutating func setReveal(_ reveal: Double, in window: SidebarWindowID?) {
        update(in: window) { $0.reveal = reveal }
    }

    /// The slide that `beginToggle` started is over. A newer toggle owns the
    /// state by then if the side changed, and a window closed meanwhile
    /// stays forgotten.
    public mutating func endToggle(showing: Bool, in window: SidebarWindowID?) {
        guard var state = states[window], state.isVisible == showing else { return }
        state.isSliding = false
        if showing { state.isLaidOut = true }
        states[window] = state
    }

    /// The floating sidebar comes or goes. Only a hidden sidebar floats.
    /// False when nothing changed.
    @discardableResult
    public mutating func setPeeking(_ peeking: Bool, in window: SidebarWindowID?) -> Bool {
        let state = state(in: window)
        guard !state.isVisible || !peeking, state.isPeeking != peeking else { return false }
        update(in: window) { $0.isPeeking = peeking }
        return true
    }

    /// Every floating sidebar is dismissed (the sidebar changes side).
    public mutating func endPeekingEverywhere() {
        for window in states.keys where states[window]?.isPeeking == true {
            states[window]?.isPeeking = false
        }
    }
}

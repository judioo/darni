import Foundation

/// Which tab opened which, for tabs a page opened from a link (⌘-click, a
/// middle click, `target=_blank`). Going back on such a tab when it has no page
/// behind it closes it and returns to the tab that opened it, as in Arc and
/// Safari. That covers the Back button, ⌘[ and the two-finger swipe (owner,
/// 2026-11-21: a ⌘-clicked tab could not be swiped back).
///
/// Kept in memory only: after a relaunch a tab has no opener, and Back does
/// what the page's own history allows.
public struct TabOpeners: Equatable, Sendable {
    private var openers: [Tab.ID: Tab.ID] = [:]

    public init() {}

    public mutating func record(_ tab: Tab.ID, openedBy opener: Tab.ID) {
        guard tab != opener else { return }
        openers[tab] = opener
    }

    /// The tab closed: it returns nowhere, and nothing returns to it.
    public mutating func forget(_ tab: Tab.ID) {
        openers[tab] = nil
        openers = openers.filter { $0.value != tab }
    }

    public func opener(of tab: Tab.ID) -> Tab.ID? { openers[tab] }

    /// The tab Back returns to from `tab`, closing it: only when the page has
    /// nothing behind it, the tab is an ordinary (today) tab outside a split,
    /// and its opener is still open. A pinned tab or a favorite is kept, so
    /// Back on one never closes it.
    public func returnTarget(for tab: Tab.ID, canGoBack: Bool, in store: SidebarStore) -> Tab.ID? {
        guard !canGoBack, let opener = openers[tab], opener != tab,
              store.kind(of: tab) == .today, store.splitContaining(tabID: tab) == nil,
              store.tab(withID: opener) != nil else { return nil }
        return opener
    }
}

import Foundation
import SidebarModel

/// What an extension's tab requests may do to the window (`ExtensionFocusGate`,
/// `ExtensionBlankTabs`). The Chromium host answers the engine; the decisions
/// and the sidebar changes are made here, where the model's tests reach them.
extension BrowserViewModel {
    /// What became of an extension's wish to have a tab in front.
    enum ExtensionTabShowing: Equatable {
        /// The tab is selected in the space on screen.
        case onScreen
        /// The space on screen stayed; the tab is now the selected tab of its own space.
        case inItsSpace(ExtensionFocusGate.Refusal)
        /// The tab cannot be its space's selection (`SidebarStore.selectTabInItsSpace`).
        case unavailable
    }

    /// A key or a mouse button went down in one of Darni's windows.
    func noteUserInput(at now: Date = Date()) {
        extensionFocusGate.noteUserInput(at: now)
    }

    /// Whether a program may bring the space `target` on screen now.
    func programMayShow(space target: Space.ID, source: ExtensionFocusGate.Source, at now: Date = Date()) -> ExtensionFocusGate.Verdict {
        guard let profile = store.space(withID: target)?.profileID else { return .stay(.otherProfile) }
        return programMayFocus(target, profile: profile, from: store.activeSpaceID, source: source, at: now)
    }

    /// Whether a program may bring a Little Arc window in front of the window that is key now.
    func programMayShow(littleArc record: LittleArcWindow, source: ExtensionFocusGate.Source, at now: Date = Date()) -> ExtensionFocusGate.Verdict {
        programMayFocus(record.id, profile: record.profileID, from: keyLittleArcID ?? store.activeSpaceID, source: source, at: now)
    }

    /// `target` and `shown` are what extensions see as windows: a space, or a
    /// Little Arc window. The loop breaker's trip is logged once, and said
    /// once in a toast.
    private func programMayFocus(_ target: UUID, profile: Profile.ID, from shown: UUID, source: ExtensionFocusGate.Source,
                                 at now: Date) -> ExtensionFocusGate.Verdict {
        guard target != shown else { return .follow }
        let sameProfile = store.owningProfileID(of: profile) == store.activeOwningProfileID
        let trips = extensionFocusGate.trips
        let verdict = extensionFocusGate.decide(from: shown, to: target, source: source, sameProfile: sameProfile, at: now)
        if extensionFocusGate.trips != trips {
            // Ids only: standard error belongs to whoever started the process.
            let line = "loop breaker: programs switched between the same spaces more than \(ExtensionFocusGate.loopReturns) times in "
                + "\(Int(ExtensionFocusGate.loopWindow)) s (last: \(shown.uuidString.prefix(8)) -> \(target.uuidString.prefix(8))); "
                + "no extension or page moves the window for \(Int(ExtensionFocusGate.loopPause)) s"
            extensionFocusLog.append(line)
            StandardError.write("[ReArc] \(line)\n")
            showToast("Stopped pages and extensions switching spaces", systemImage: "hand.raised")
        }
        return verdict
    }

    /// An extension made `id` its window's active tab: `tabs.update({active:
    /// true})`, `windows.update({focused: true})` on the tab's window, or a
    /// new tab that asked to be active (`newlyOpened`). In the space on screen
    /// the tab is selected, as before. In another space it is brought forward
    /// only when the user started it; otherwise it becomes that space's
    /// selected tab and the window stays where it is.
    @discardableResult
    func extensionActivatedTab(_ id: Tab.ID, newlyOpened: Bool = false, at now: Date = Date()) -> ExtensionTabShowing {
        guard store.tab(withID: id) != nil else { return .unavailable }
        let target = store.spaceContaining(tabID: id)
        // A favorite is in no space: it is on screen in every space of its profile.
        let onScreen = target.map { $0 == store.activeSpaceID } ?? (store.favoriteOwner(of: id) == store.activeProfileID)
        if !onScreen {
            guard let target else { return .unavailable }
            if case .stay(let refusal) = programMayShow(space: target, source: .extensionRequest, at: now) {
                return store.selectTabInItsSpace(id) ? .inItsSpace(refusal) : .unavailable
            }
        }
        if newlyOpened {
            if let target, target != store.activeSpaceID { store.selectSpace(target) }
            selectTab(id)
        } else {
            // As PiP's back-to-tab: coming to the tab is not a switch away from it.
            autoPiPEnteredTabIDs.remove(id)
            showTab(id)
        }
        return .onScreen
    }

    /// A tab the engine made for a page (popup, target=_blank) that takes
    /// focus: selected in its space, which comes on screen unless the loop
    /// breaker is holding the window still.
    func selectPageOpenedTab(_ id: Tab.ID, in space: Space.ID?, at now: Date = Date()) {
        if let space, space != store.activeSpaceID {
            if case .stay = programMayShow(space: space, source: .pageOpenedTab, at: now) {
                store.selectTabInItsSpace(id)
                return
            }
            store.selectSpace(space)
        }
        selectTab(id)
    }

    // MARK: Blank tabs

    private func isUnusedBlankTab(_ id: Tab.ID) -> Bool {
        store.tab(withID: id)?.url.absoluteString == "about:blank"
    }

    /// Why the shell will not open the tab an extension asked for in `space`,
    /// or nil when it will: an extension that already holds
    /// `ExtensionBlankTabs.limit` blank tabs it never used gets no more.
    func extensionTabRefusal(for request: ExtensionTabRequest, in space: Space.ID) -> String? {
        guard request.isForBlankTab, !request.extensionID.isEmpty, let profile = store.space(withID: space)?.profileID else { return nil }
        let unused = extensionBlankTabs.unused(for: request.extensionID, in: profile, stillBlank: isUnusedBlankTab)
        guard unused >= ExtensionBlankTabs.limit else { return nil }
        return "extension \(request.extensionID) already has \(unused) blank tabs it has not used"
    }

    /// The tab the shell opened for `request`.
    func noteExtensionOpenedTab(_ id: Tab.ID, for request: ExtensionTabRequest, in space: Space.ID) {
        guard request.isForBlankTab, !request.extensionID.isEmpty, let profile = store.space(withID: space)?.profileID else { return }
        extensionBlankTabs.opened(id, by: request.extensionID, in: profile)
    }
}

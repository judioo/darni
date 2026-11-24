import Foundation
import SidebarModel

/// Tab sleep: a tab left unseen is frozen first (30 minutes by default: the
/// page stays in memory, runs nothing, and goes on at once when shown) and
/// unloaded later (4 hours by default). Freezing is the engine's
/// (`TabFreezing`, Chromium `tab_freeze`, ABI 1.71); without it pages run
/// until the unload. Both are set in Settings › General and in the Archive.
///
/// Unloading tabs that stay in the sidebar (Arc "Unload Tab", pinned-tab
/// unload on ⌘W, and the automatic unload of tabs left unseen). Chromium
/// discards the page in place (`tab_discard`, ABI 1.25): the WebContents,
/// back/forward list, boosts and lease survive, and showing the tab
/// reloads it. WebKit, and Chromium without the feature, drop the engine,
/// and the tab loads its URL when it is shown. Unloaded rows show a dimmed
/// icon until the tab is shown again.
extension BrowserViewModel {
    /// Retries for a discard the engine refused because the tab was still on
    /// screen or loading (the view detaches after the selection moves).
    static let discardRetryDelays: [TimeInterval] = [0.25, 0.75, 2]

    /// How long after a freeze request the file log asks whether the page froze.
    static let freezeObservationDelay: TimeInterval = 2

    /// The context-menu Unload Tab and the Unload command: the tab stays where it is.
    func unloadTab(_ id: Tab.ID) {
        guard let tab = store.tab(withID: id) else { return }
        let profile = profileID(for: tab)
        guard let engine = engineHost.engine(forTabID: id, profileID: profile) else { return }
        if isTabVisible(id) {
            // Arc moves the selection away first; the page goes once it is hidden.
            if store.selectedTabID == id || store.splitContaining(tabID: id) != nil {
                selectNextTabAway(from: id)
            }
        }
        unloadEngine(engine, tabID: id, dropIfRefused: true)
    }

    /// True for a tab the shell unloaded (or whose page Chromium discarded) that has not been shown since.
    func isTabUnloaded(_ id: Tab.ID) -> Bool {
        if unloadedTabIDs.contains(id) { return true }
        guard let tab = store.tab(withID: id),
              let discarding = engineHost.engine(forTabID: id, profileID: profileID(for: tab)) as? TabDiscarding else { return false }
        return discarding.isDiscarded
    }

    /// Whether Unload Tab applies: the tab has a live, not yet unloaded page.
    func canUnloadTab(_ id: Tab.ID) -> Bool {
        guard let tab = store.tab(withID: id), engineHost.engine(forTabID: id, profileID: profileID(for: tab)) != nil else { return false }
        return !isTabUnloaded(id)
    }

    /// Discards when the engine can, else drops the engine. A discard the
    /// engine keeps refusing (playing media, an unload handler) leaves the
    /// page loaded for the automatic unload; an explicit unload
    /// (`dropIfRefused`) then drops the engine instead.
    func unloadEngine(_ engine: any WebEngine, tabID: Tab.ID, attempt: Int = 0, dropIfRefused: Bool = false) {
        guard let discarding = engine as? TabDiscarding else {
            releaseEngine(for: tabID)
            unloadedTabIDs.insert(tabID)
            return
        }
        switch discarding.discard() {
        case .discarded:
            unloadedTabIDs.remove(tabID)
        case .refusedForNow where attempt < discardRetryDelays.count:
            DispatchQueue.main.asyncAfter(deadline: .now() + discardRetryDelays[attempt]) { [weak self, weak engine] in
                guard let self, let engine, !self.isTabVisible(tabID),
                      let tab = self.store.tab(withID: tabID),
                      self.engineHost.engine(forTabID: tabID, profileID: self.profileID(for: tab)) === engine else { return }
                self.unloadEngine(engine, tabID: tabID, attempt: attempt + 1, dropIfRefused: dropIfRefused)
            }
        case .refusedForNow:
            // The automatic unload stops here: the page stays loaded. A page
            // that asks "Leave site?" (unsaved input) is refused every time,
            // and is never dropped behind the person's back.
            guard dropIfRefused, !isTabVisible(tabID) else { break }
            releaseEngine(for: tabID)
            unloadedTabIDs.insert(tabID)
        case .unsupported:
            releaseEngine(for: tabID)
            unloadedTabIDs.insert(tabID)
        }
    }

    /// Tabs a window may be showing: every space's selected item and every
    /// window's own (a split's panes too); the peeked page's tab is not one of them.
    var visibleTabIDs: Set<Tab.ID> {
        var visible: Set<Tab.ID> = []
        let selected = store.visibleSpaces.map { store.selectedItemID(inSpace: $0.id) }
            + store.focusedSpaceByWindow.keys.map { store.selectedItemID(in: $0) }
        for case let id? in selected {
            if let split = store.split(withID: id) {
                split.tabs.forEach { visible.insert($0.id) }
            } else {
                visible.insert(id)
            }
        }
        return visible
    }

    func isTabVisible(_ id: Tab.ID) -> Bool {
        visibleTabIDs.contains(id)
    }

    /// The tabs on screen were just shown: they are active now, no longer
    /// unloaded, and not frozen. The engine thaws a page it shows by itself;
    /// the shell says so too, and does nothing else for a thaw: it holds no
    /// list of things a frozen page wanted, and loads nothing.
    func noteVisibleTabsShown(at date: Date = Date()) {
        for id in visibleTabIDs {
            tabLastShown[id] = date
            unloadedTabIDs.remove(id)
            thawTab(id, reason: .shown)
        }
    }

    /// Ends the tab's freeze request, if its engine holds one. A request the
    /// engine already ended (it thaws a page it shows) gets its log line too.
    func thawTab(_ id: Tab.ID, reason: TabFreezeJournal.ThawReason) {
        guard let tab = store.tab(withID: id),
              let freezing = engineHost.engine(forTabID: id, profileID: profileID(for: tab)) as? TabFreezing else { return }
        guard freezing.isFreezeRequested else {
            tabSleepLog.write(tabFreezeJournal.thawed(id, reason: reason))
            return
        }
        let frozenNow = freezing.isPageFrozen
        freezing.unfreeze()
        tabSleepLog.write(tabFreezeJournal.thawed(id, reason: reason, frozenNow: frozenNow))
    }

    /// Tab sleep's file log: which requested tabs the engine reports frozen
    /// now, and which requests it ended by itself (the tab used or unloaded).
    func observeTabFreezes() {
        for id in tabFreezeJournal.requested {
            guard let tab = store.tab(withID: id),
                  let freezing = engineHost.engine(forTabID: id, profileID: profileID(for: tab)) as? TabFreezing else {
                tabFreezeJournal.forget(id)
                continue
            }
            if freezing.isFreezeRequested {
                tabSleepLog.write(tabFreezeJournal.observed(id, frozen: freezing.isPageFrozen))
            } else {
                tabSleepLog.write(tabFreezeJournal.thawed(id, reason: .engine))
            }
        }
    }

    /// Whether the tab's engine holds a freeze request (its page is frozen, or about to be).
    func isTabFrozen(_ id: Tab.ID) -> Bool {
        guard let tab = store.tab(withID: id),
              let freezing = engineHost.engine(forTabID: id, profileID: profileID(for: tab)) as? TabFreezing else { return false }
        return freezing.isFreezeRequested
    }

    /// Every sidebar tab with a live engine, as the freeze and unload checks
    /// see it. Peek pages and Little Darni windows have engines of their own
    /// and are not tabs: they are never listed, so never frozen or unloaded.
    func tabSleepCandidates(now: Date) -> [TabUnloadCandidate] {
        let visible = visibleTabIDs
        let shared = screenShares.chosenTargets.union(screenShareMarkedTabs)
        var candidates: [TabUnloadCandidate] = []
        for (id, profile, engine) in engineHost.allTabEngines() {
            guard store.tab(withID: id) != nil, profile == store.tab(withID: id).map(profileID(for:)) else { continue }
            let lastShown = tabLastShown[id] ?? now
            tabLastShown[id] = lastShown
            let media = mediaState(for: id)
            candidates.append(TabUnloadCandidate(
                tabID: id,
                lastActive: lastShown,
                isVisible: visible.contains(id),
                isAudible: media.isAudible || media.isPlaying || media.isPictureInPicture,
                isUnloaded: isTabUnloaded(id) || engine.isLoading,
                hasPendingPrompt: engine.pagePrompts.hasPendingPrompt,
                isCapturing: captureStateByTab[id] != nil || screenShares.isSharing(id),
                isShared: shared.contains(id),
                hasDownload: downloads.hasLiveDownload(startedBy: engine),
                isTransient: engine.pagePrompts.role != .tab,
                isFrozen: (engine as? TabFreezing)?.isFreezeRequested ?? false
            ))
        }
        return candidates
    }

    /// The automatic unload (checked with auto-archive, every five minutes).
    /// A discard the engine refuses (a page with unsaved input that asks
    /// "Leave site?", playing media, a share) leaves the page loaded: this
    /// path never drops an engine that said "not now".
    @discardableResult
    func runAutoUnload(now: Date = Date()) -> [Tab.ID] {
        noteVisibleTabsShown(at: now)
        let due = TabUnloadPolicy.tabsToUnload(tabSleepCandidates(now: now), threshold: tabUnloadThreshold, now: now)
        for id in due {
            guard let tab = store.tab(withID: id), let engine = engineHost.engine(forTabID: id, profileID: profileID(for: tab)) else { continue }
            unloadEngine(engine, tabID: id)
        }
        tabLastShown = tabLastShown.filter { store.tab(withID: $0.key) != nil }
        unloadedTabIDs = unloadedTabIDs.filter { store.tab(withID: $0) != nil }
        return due
    }

    /// The automatic freeze (checked with the unload, every five minutes, and
    /// when the setting changes). First the frozen tabs that are in use again
    /// or no longer due run again; then every loaded tab left unseen for the
    /// threshold is frozen, if its engine can and agrees. Returns the tabs
    /// whose engine took the request.
    @discardableResult
    func runAutoFreeze(now: Date = Date()) -> [Tab.ID] {
        noteVisibleTabsShown(at: now)
        observeTabFreezes()
        let candidates = tabSleepCandidates(now: now)
        for id in TabUnloadPolicy.tabsToThaw(candidates, threshold: tabFreezeThreshold, now: now) {
            thawTab(id, reason: .due)
        }
        var frozen: [Tab.ID] = []
        for id in TabUnloadPolicy.tabsToFreeze(candidates, threshold: tabFreezeThreshold, now: now) {
            guard let tab = store.tab(withID: id),
                  let freezing = engineHost.engine(forTabID: id, profileID: profileID(for: tab)) as? TabFreezing else { continue }
            if freezing.freeze() == .requested {
                frozen.append(id)
                tabSleepLog.write(tabFreezeJournal.freezeRequested(id))
            }
        }
        if !frozen.isEmpty {
            // The renderer reports the freeze a moment later: a line for it then, not five minutes on.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.freezeObservationDelay) { [weak self] in self?.observeTabFreezes() }
        }
        return frozen
    }

    private func selectNextTabAway(from id: Tab.ID) {
        let order = store.displayTabs()
        guard order.count > 1 else { return }
        if store.splitContaining(tabID: id) != nil {
            // A split pane is unloaded by leaving the split for the next item outside it.
            if let next = order.first(where: { store.splitContaining(tabID: $0.id) == nil && $0.id != id }) {
                selectTab(next.id)
            }
            return
        }
        selectNextTab()
    }
}

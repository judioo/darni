import Foundation
import SidebarModel

/// "Opened in Darni" marks (`TabOpenedMarks`): the first time a sidebar tab
/// was shown (selected in a window, or a pane of the split on screen) or
/// had a page commit in it, shown or in the background. Kept across
/// launches in `TabOpened.json` beside the sidebar file; never in
/// `sidebar.json` and never synced. Private windows aren't sidebar tabs and
/// never get one.
extension BrowserViewModel {
    /// Marks a sidebar tab opened, once. Anything that is not a tab of the
    /// sidebar (a private window's page, a Peek, Little Darni) is ignored.
    func markTabOpened(_ id: Tab.ID, at date: Date = Date()) {
        guard store.tab(withID: id) != nil, tabOpenedMarks.mark(id, at: date) else { return }
        scheduleTabOpenedMarksSave()
    }

    /// When the tab was first shown or loaded in Darni; nil when it has no mark.
    func tabOpenedAt(_ id: Tab.ID) -> Date? {
        tabOpenedMarks[id]
    }

    /// After any sidebar change: a tab no longer in the sidebar (closed,
    /// archived, deleted, here or by sync) loses its mark. A tab of an
    /// archived space is still in the sidebar and keeps its own.
    func pruneTabOpenedMarks() {
        guard tabOpenedMarks.keepOnly({ store.tab(withID: $0) != nil }) else { return }
        scheduleTabOpenedMarksSave()
    }

    /// The command bar's Clear History, and Clear Browsing Data being opened:
    /// the marks say when tabs were visited, so they all go.
    func clearTabOpenedMarks() {
        guard tabOpenedMarks.removeAll() else { return }
        startTabOpenedMarksSave()
    }

    func scheduleTabOpenedMarksSave() {
        tabOpenedMarksSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.tabOpenedMarksSaveWorkItem = nil
            self.enqueueTabOpenedMarksSave()
        }
        tabOpenedMarksSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Starts writing the file now; History.json's serial queue finishes it,
    /// so `prepareForQuit` waits for both.
    func startTabOpenedMarksSave() {
        tabOpenedMarksSaveWorkItem?.cancel()
        tabOpenedMarksSaveWorkItem = nil
        enqueueTabOpenedMarksSave()
    }

    /// Writes now and waits (tests).
    func saveTabOpenedMarks() {
        startTabOpenedMarksSave()
        historySaveQueue.sync {}
    }

    private func enqueueTabOpenedMarksSave() {
        guard let tabOpenedMarksURL else { return }
        let snapshot = tabOpenedMarks
        historySaveQueue.async {
            do {
                try snapshot.save(to: tabOpenedMarksURL)
            } catch {
                StandardError.write("[ReArc] could not save \(tabOpenedMarksURL.lastPathComponent): \(error.localizedDescription)\n")
            }
        }
    }
}

/// The sidebar's Sleep Tab, beside Unload Tab: tab sleep's freeze now, as
/// the Task Manager's Sleep does, filed in its history as "from the sidebar".
extension BrowserViewModel {
    /// Why Sleep doesn't apply to the tab now; nil when it does. The same
    /// checks as `canSleepTab`, which is this being nil.
    func sleepTabUnavailable(_ id: Tab.ID) -> TabSleepUnavailable? {
        if isTabUnloaded(id) { return .unloaded }
        guard let engine = liveEngine(for: id) else { return .notLoaded }
        guard let freezing = engine as? TabFreezing else { return .engineCannotFreeze }
        if freezing.isFreezeRequested { return .asleep }
        guard let candidate = tabSleepCandidates(now: Date(), recordsFirstSight: false).first(where: { $0.tabID == id }) else {
            return .notLoaded
        }
        if candidate.isVisible { return .onScreen }
        if candidate.isAudible { return .inUse(.playingSound) }
        if candidate.isCapturing { return .inUse(.capturing) }
        if candidate.isShared { return .inUse(.shared) }
        if candidate.hasDownload { return .inUse(.downloading) }
        if candidate.hasPendingPrompt { return .inUse(.waitingForAnswer) }
        if candidate.isInUse { return .notNow }
        return nil
    }

    /// The sidebar menu's Sleep Tab.
    func sleepTabFromSidebar(_ id: Tab.ID) {
        sleepTab(id, cause: .sidebar)
    }
}

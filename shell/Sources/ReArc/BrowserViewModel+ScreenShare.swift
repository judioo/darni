import AppKit
import SidebarModel

/// Screen sharing in the browser model (Chromium `display_capture`, ABI
/// 1.70): the tabs the sharing sheet offers, the record of what is shared
/// now, the bar over a tab another page shares, the sidebar's sharing card,
/// and Stop.
extension BrowserViewModel: ScreenShareRouting {
    // MARK: The sheet's tabs

    /// The asking page's own tab first (when the page did not exclude it),
    /// then every loaded tab of its profile, space by space as the sidebar
    /// lists them. A tab without a running page (never loaded, unloaded,
    /// crashed) has nothing to share and is left out. A private window's page
    /// is offered itself only: its session is its own.
    func screenShareCandidates(for prompts: PagePromptCenter, asker: UInt64, includeAsker: Bool) -> [ScreenShareCandidate] {
        var result: [ScreenShareCandidate] = []
        var seen: Set<UInt64> = [asker]
        if includeAsker {
            let tab = prompts.ownerTabID.flatMap { store.tab(withID: $0) }
            result.append(candidate(for: tab, engineTabID: asker, isCurrent: true))
        }
        guard prompts.privateSession == nil, let profile = prompts.profileID else { return result }
        for space in store.spaces where space.profileID == profile {
            for tab in store.displayTabs(in: space.id) where profileID(for: tab) == profile {
                guard let engine = engineHost.engine(forTabID: tab.id, profileID: profile) as? ScreenShareProviding,
                      let id = engine.screenShareTargetID, seen.insert(id).inserted else { continue }
                result.append(candidate(for: tab, engineTabID: id, isCurrent: false))
            }
        }
        return result
    }

    private func candidate(for tab: Tab?, engineTabID: UInt64, isCurrent: Bool) -> ScreenShareCandidate {
        ScreenShareCandidate(engineTabID: engineTabID, tabID: tab?.id,
                             title: tab?.displayTitle ?? "This Page",
                             site: tab?.url.host() ?? "",
                             isCurrent: isCurrent,
                             favicon: tab.flatMap { favicon(for: $0) },
                             faviconToken: tab?.faviconToken ?? "")
    }

    // MARK: What is shared now

    /// A request of the page was answered with `share`. It shows once the
    /// page's stream is live (`screenShareCaptureChanged`).
    func screenShareStarted(_ share: ScreenShare<UUID>, site: String, from prompts: PagePromptCenter) {
        guard let capturer = prompts.ownerTabID, store.tab(withID: capturer) != nil else { return }
        screenShares.noteChosen(share, by: capturer)
        screenShareSites[capturer] = site
        refreshScreenShareMarks()
    }

    /// `media_capture` for a tab: its page holds a share stream, or its last one ended.
    func screenShareCaptureChanged(_ tabID: Tab.ID, live: Bool) {
        guard live != screenShares.isSharing(tabID) else { return }
        screenShares.captureChanged(tabID, isCapturingDisplay: live)
        if !live { screenShareSites[tabID] = nil }
    }

    func forgetScreenShares(of tabID: Tab.ID) {
        screenShares.forget(tabID)
        screenShareSites[tabID] = nil
        screenShareMarkedTabs.remove(tabID)
    }

    /// Tells each shared tab's page who shares it, for its bar, and clears the tabs no longer shared.
    func refreshScreenShareMarks() {
        var viewers: [Tab.ID: [ScreenShareViewer]] = [:]
        for capturer in screenShares.capturers.sorted(by: { $0.uuidString < $1.uuidString }) {
            for share in screenShares.shares(of: capturer) where share.kind == .tab {
                // The page's own tab has the sharing bar already.
                guard let target = share.target, target != capturer else { continue }
                let viewer = ScreenShareViewer(capturer: capturer, site: screenShareSites[capturer] ?? "A page")
                if viewers[target]?.contains(viewer) != true { viewers[target, default: []].append(viewer) }
            }
        }
        for id in screenShareMarkedTabs.union(viewers.keys) {
            guard let tab = store.tab(withID: id),
                  let engine = engineHost.engine(forTabID: id, profileID: profileID(for: tab)) else { continue }
            let now = viewers[id] ?? []
            if engine.pagePrompts.sharedBy != now { engine.pagePrompts.sharedBy = now }
        }
        screenShareMarkedTabs = Set(viewers.keys)
    }

    func screenShareTitle(of tab: UUID) -> String? {
        store.tab(withID: tab)?.displayTitle
    }

    // MARK: Stop

    /// Ends everything the tab's page shares, as its own Stop would. The
    /// engine then reports the stream gone and the bars and the card go.
    func stopScreenShare(of capturer: UUID) {
        guard let tab = store.tab(withID: capturer),
              let engine = engineHost.engine(forTabID: capturer, profileID: profileID(for: tab)) as? ScreenShareProviding else { return }
        engine.stopScreenShare()
    }

    // MARK: The sidebar's card

    /// Tabs whose page shares something and that this window is not showing:
    /// each gets a sharing card above the call cards, so a share can be seen
    /// and stopped from any window and any tab. The tab on screen has the bar
    /// over its page instead.
    func screenShareCards(in window: SidebarWindowID?) -> [Tab.ID] {
        let visible = visibleTabIDs(in: window)
        return screenShares.capturers
            .filter { !visible.contains($0) && store.tab(withID: $0) != nil }
            .sorted { $0.uuidString < $1.uuidString }
    }

    /// The card's line: "Sharing your screen with meet.google.com".
    func screenShareCardLine(for capturer: Tab.ID) -> String {
        // The card is never on the sharing tab itself, so "this tab" would point at the wrong one.
        let summary = screenShares.summary(of: capturer) { [store] id in
            id == capturer ? nil : store.tab(withID: id)?.displayTitle
        }
        let words = summary == "this tab" ? "its own tab" : summary
        guard let site = screenShareSites[capturer], !site.isEmpty else { return "Sharing \(words)" }
        return ScreenShareText.capturerLine(summary: words, site: site)
    }
}

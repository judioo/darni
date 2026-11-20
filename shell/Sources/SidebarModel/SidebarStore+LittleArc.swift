import Foundation

extension SidebarStore {

    // MARK: - Little Arc state

    public var littleArcLiveWindows: [LittleArcWindow] {
        littleArcWindows
    }

    public var littleArcArchivedWindows: [ArchivedLittleArcWindow] {
        archivedLittleArcWindows
    }

    public func littleArcWindow(withID id: LittleArcWindow.ID) -> LittleArcWindow? {
        littleArcWindows.first(where: { $0.id == id })
    }

    @discardableResult
    public func createLittleArcWindow(
        id: LittleArcWindow.ID = UUID(),
        url: URL,
        title: String? = nil,
        profileID: Profile.ID? = nil,
        at date: Date = Date()
    ) -> LittleArcWindow {
        let resolvedTitle = title ?? url.host() ?? url.absoluteString
        let originProfile = profileID ?? activeProfileID
        let window = LittleArcWindow(
            id: id,
            url: url,
            title: resolvedTitle,
            profileID: originProfile,
            createdAt: date,
            lastActiveAt: date
        )
        littleArcWindows.append(window)
        notifyMutation()
        return window
    }

    public func touchLittleArcWindow(id: LittleArcWindow.ID, at date: Date = Date()) {
        guard let index = littleArcWindows.firstIndex(where: { $0.id == id }) else { return }
        littleArcWindows[index].lastActiveAt = date
        notifyMutation()
    }

    public func updateLittleArcWindow(id: LittleArcWindow.ID, title: String?, url: URL?) {
        guard let index = littleArcWindows.firstIndex(where: { $0.id == id }) else { return }
        if let title { littleArcWindows[index].title = title }
        if let url { littleArcWindows[index].url = url }
        notifyMutation()
    }

    @discardableResult
    public func archiveLittleArcWindow(
        id: LittleArcWindow.ID,
        at date: Date = Date(),
        reason: LittleArcArchiveReason
    ) -> ArchivedLittleArcWindow? {
        guard let index = littleArcWindows.firstIndex(where: { $0.id == id }) else { return nil }
        let window = littleArcWindows.remove(at: index)
        let archived = ArchivedLittleArcWindow(window: window, archivedAt: date, reason: reason)
        archivedLittleArcWindows.append(archived)
        notifyMutation()
        return archived
    }

    /// Where Open in <Space> puts a Little Arc's page (Arc's toolbar names it
    /// and takes its tint): the space of the last focused browser window,
    /// whatever its profile, as in Arc. A Little Arc never becomes the key
    /// browser window, so this is the active space, and it changes as soon as
    /// another browser window takes focus or the focused one changes space.
    /// The space may be another session than the window's: what Open in does
    /// with it is `LittleArcOpenInMenu.choice`'s to say, never this.
    public func littleArcTargetSpace(for id: LittleArcWindow.ID) -> Space? {
        guard let profileID = littleArcWindows.first(where: { $0.id == id })?.profileID
            ?? archivedLittleArcWindows.first(where: { $0.window.id == id })?.window.profileID else { return nil }
        return listedSpace(withID: activeSpaceID) ?? littleArcOwnSpace(usingStorageOf: profileID)
    }

    /// A space of the window's own session, for when the active space cannot
    /// be shown: that profile's last active one, else its first.
    private func littleArcOwnSpace(usingStorageOf profileID: Profile.ID) -> Space? {
        let candidates = spaces(in: profileID)
        if let remembered = lastActiveSpaceByProfile[profileID],
           let space = candidates.first(where: { $0.id == remembered }) {
            return space
        }
        return candidates.first
    }

    /// Promotes a live or archived Little Arc into a today tab in `spaceID`
    /// (a space of the window's profile). With none, or with a space of
    /// another session, the page stays in its own session: the active space
    /// when it shares the window's profile, else that profile's last space.
    /// A space of another session is `reopenLittleArcAsTab`'s.
    @discardableResult
    public func promoteLittleArcToTab(id: LittleArcWindow.ID, into spaceID: Space.ID? = nil) -> Tab? {
        let window: LittleArcWindow
        if let live = littleArcWindows.first(where: { $0.id == id }) {
            window = live
            littleArcWindows.removeAll { $0.id == id }
        } else if let archivedIndex = archivedLittleArcWindows.firstIndex(where: { $0.id == id }) {
            window = archivedLittleArcWindows.remove(at: archivedIndex).window
        } else {
            return nil
        }
        if activeSpace.profileID != window.profileID {
            selectSpace(usingStorageOf: window.profileID)
        }
        if let spaceID, space(withID: spaceID)?.profileID == window.profileID {
            selectSpace(spaceID)
        }
        let tab = addTab(kind: .today, title: window.title, url: window.url, in: activeSpaceID)
        selectTab(tab.id)
        notifyMutation()
        return tab
    }

    /// Open in ▸ a space of another session (another profile, or a container):
    /// the window's address opens afresh as a Today tab in `spaceID`, and that
    /// space is shown, as a link sent to a space by Air Traffic Control is.
    /// Only the address goes. The tab is named by its host until the page
    /// loads there, so the title the page had in the window's session stays
    /// behind with its cookies and sign-ins (S-01). The window's record is
    /// removed, as a promote removes it: the page lives on as the tab, and an
    /// archived copy would name the session it left. `url` is the address to
    /// open: the one the person was asked about (OI-01, OI-03), or the
    /// record's when nil. Nil, and nothing changes, for a space of the
    /// window's own session (`promoteLittleArcToTab`), a space that cannot be
    /// shown, a window that is not open, or an address that is not a web
    /// address (`LittleArcOpenInMenu.canCrossSessions`, OI-02).
    @discardableResult
    public func reopenLittleArcAsTab(id: LittleArcWindow.ID, in spaceID: Space.ID, url: URL? = nil) -> Tab? {
        guard let index = littleArcWindows.firstIndex(where: { $0.id == id }),
              let space = listedSpace(withID: spaceID), space.profileID != littleArcWindows[index].profileID else { return nil }
        let address = url ?? littleArcWindows[index].url
        guard LittleArcOpenInMenu.canCrossSessions(address) else { return nil }
        littleArcWindows.remove(at: index)
        let tab = addTab(kind: .today, title: address.host() ?? "New Tab", url: address, in: space.id)
        focusTab(tab.id)
        notifyMutation()
        return tab
    }

    /// Auto-archives idle live windows; returns ids archived.
    @discardableResult
    public func autoArchiveIdleLittleArcWindows(
        referenceDate: Date = Date(),
        threshold: TimeInterval = LittleArcPolicy.autoArchiveIdleThreshold,
        keeping: Set<LittleArcWindow.ID> = []
    ) -> [LittleArcWindow.ID] {
        let ids = LittleArcPolicy.windowsEligibleForAutoArchive(
            live: littleArcWindows, referenceDate: referenceDate, threshold: threshold, keeping: keeping)
        for id in ids {
            archiveLittleArcWindow(id: id, at: referenceDate, reason: .auto)
        }
        return ids
    }
}

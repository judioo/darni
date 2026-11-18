import Foundation

/// Ad and tracker blocking per profile (docs/FEATURE-SPECS/CONTENT-BLOCKING.md
/// §2). The store is the source of truth; the shell tells the engine after
/// every change (`ContentBlockingEngineSync`). The settings sync with the
/// profile in a record of their own (`SyncRecordKind.contentBlocking`); the
/// rollout state is this Mac's.
extension SidebarStore {
    /// A container follows its parent's settings. A profile without settings is Off.
    public func contentBlocking(for profileID: Profile.ID? = nil) -> ContentBlockingSettings {
        contentBlockingByProfile[owningProfileID(of: profileID ?? activeProfileID)] ?? .off
    }

    /// Replaces the profile's settings (a container's go to its parent).
    public func setContentBlocking(_ settings: ContentBlockingSettings, for profileID: Profile.ID? = nil) {
        let id = owningProfileID(of: profileID ?? activeProfileID)
        guard profiles.contains(where: { $0.id == id }), contentBlocking(for: id) != settings else { return }
        contentBlockingByProfile[id] = settings
        notifyMutation()
    }

    /// One change to the profile's settings.
    public func updateContentBlocking(for profileID: Profile.ID? = nil, _ change: (inout ContentBlockingSettings) -> Void) {
        var settings = contentBlocking(for: profileID)
        change(&settings)
        setContentBlocking(settings, for: profileID)
    }

    /// Blocking is on in some profile: the lists are worth keeping up to date.
    public var isContentBlockingOnAnywhere: Bool {
        profiles.contains { contentBlocking(for: $0.id).isEnabled }
    }

    /// The first launch of a build with blocking, and a no-op on every later
    /// one. A new install (no ReArc data before this launch) starts every
    /// profile at Ads and trackers and is never shown the offer. An existing
    /// install's profiles stay as they are, which is Off, and the offer is due.
    /// Either way, a profile made from now on starts with blocking on.
    /// Returns what was decided, nil when it had been decided before.
    @discardableResult
    public func beginContentBlockingRollout(isNewInstall: Bool) -> ContentBlockingRollout.Install? {
        guard !contentBlockingRollout.isDecided else { return nil }
        if isNewInstall {
            contentBlockingRollout = ContentBlockingRollout(install: .new, offerShown: true)
            for profile in profiles where contentBlockingByProfile[profile.id] == nil {
                contentBlockingByProfile[profile.id] = .newProfile
            }
        } else {
            contentBlockingRollout = ContentBlockingRollout(install: .existing, offerShown: false)
        }
        notifyMutation()
        return contentBlockingRollout.install
    }

    /// Records the offer as shown. True the one time the card may then be
    /// shown: the caller saves the sidebar before showing it.
    public func takeContentBlockingOffer() -> Bool {
        guard contentBlockingRollout.isOfferDue else { return false }
        contentBlockingRollout.offerShown = true
        notifyMutation()
        return true
    }

    /// The offer's Turn On: every profile that is Off gets the switch on, at
    /// the strength it already holds (Ads and trackers unless chosen before).
    public func acceptContentBlockingOffer() {
        var changed = false
        for profile in profiles where !isContainer(profile.id) && contentBlockingByProfile[profile.id]?.isEnabled != true {
            var settings = contentBlockingByProfile[profile.id] ?? .off
            settings.isEnabled = true
            contentBlockingByProfile[profile.id] = settings
            changed = true
        }
        if changed { notifyMutation() }
    }
}

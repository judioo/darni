import Foundation

/// The engine's blocking calls (spec §5), as a seam: the Chromium shell
/// implements it over the C ABI (`ChromiumContentBlockingEngine`), a test
/// with a recorder. Profiles are the engine's own profile IDs.
public protocol ContentBlockingEngine: AnyObject {
    /// `ReArcEngineSetBlocklistDirectory`: a verified bundle's directory.
    /// The engine reloads its blocker from it in every loaded profile.
    func setBlocklistDirectory(_ directory: URL)
    /// `ReArcProfileSetContentBlocking`.
    func setContentBlocking(engineProfile: UInt64, level: ContentBlockingLevel, enabledListIDs: [String])
    /// `ReArcProfileSetBlockingExceptions`: replaces the profile's exceptions.
    func setBlockingExceptions(engineProfile: UInt64, hosts: [String])
    /// `ReArcProfileSetOwnBlockingRules`: replaces the profile's own rules (DNR JSON).
    func setOwnBlockingRules(engineProfile: UInt64, dnrRulesJSON: String)
}

/// Keeps the engine at the shell's settings (spec §1: nothing in the engine
/// is authoritative). It tells the engine a profile's level, lists,
/// exceptions and own rules when the profile loads, and afterwards only what
/// changed. A new bundle directory is followed by every profile's state
/// again, because the engine reloads its blocker from the new directory.
///
/// Until a verified bundle is known the engine is told nothing: it has no
/// rules to switch on.
public final class ContentBlockingEngineSync {
    private struct Applied: Equatable {
        var level: ContentBlockingLevel
        var lists: [String]
        var exceptions: [String]
        var ownRules: String
    }

    private let engine: ContentBlockingEngine
    /// The shell's settings for a shell profile (a private window's parent,
    /// a container's parent profile: `SidebarStore.contentBlocking(for:)`).
    private let settings: (Profile.ID) -> ContentBlockingSettings
    private var bundle: VerifiedBlocklist?
    /// Loaded engine profiles and the shell profile each takes its settings from.
    private var profiles: [UInt64: Profile.ID] = [:]
    private var applied: [UInt64: Applied] = [:]
    /// The last own-rules text converted, per text: a settings change
    /// elsewhere does not convert 5,000 lines again.
    private var conversions: [String: String] = [:]

    public init(engine: ContentBlockingEngine, settings: @escaping (Profile.ID) -> ContentBlockingSettings) {
        self.engine = engine
        self.settings = settings
    }

    /// The bundle in use; nil while none has verified.
    public var activeBundle: VerifiedBlocklist? { bundle }

    /// A bundle was verified (launch, or an update). The engine gets its
    /// directory and then every loaded profile's state.
    public func setBundle(_ bundle: VerifiedBlocklist?) {
        guard bundle?.directory != self.bundle?.directory || bundle?.version != self.bundle?.version else { return }
        self.bundle = bundle
        guard let bundle else { return }
        engine.setBlocklistDirectory(bundle.directory)
        applied = [:]
        apply()
    }

    /// An engine profile finished loading, before any of its tabs exist.
    public func profileOpened(engineProfile: UInt64, profile: Profile.ID) {
        guard engineProfile != 0 else { return }
        profiles[engineProfile] = profile
        applied[engineProfile] = nil
        apply()
    }

    public func profileClosed(engineProfile: UInt64) {
        profiles[engineProfile] = nil
        applied[engineProfile] = nil
    }

    /// The settings may have changed (any sidebar mutation, a sync merge).
    public func settingsChanged() {
        apply()
    }

    private func apply() {
        guard let bundle else { return }
        let available = bundle.manifest.lists.map(\.id)
        var texts = Set<String>()
        for (engineProfile, profile) in profiles.sorted(by: { $0.key < $1.key }) {
            let settings = settings(profile)
            // Off is off: the profile's own rules block nothing either.
            let wanted = Applied(level: settings.level, lists: settings.enabledListIDs(available: available),
                                 exceptions: settings.exceptions, ownRules: settings.isEnabled ? settings.ownRules : "")
            texts.insert(wanted.ownRules)
            let before = applied[engineProfile]
            guard before != wanted else { continue }
            // Exceptions and own rules first, so no page loads under a level
            // that is on without them.
            if before?.exceptions != wanted.exceptions {
                engine.setBlockingExceptions(engineProfile: engineProfile, hosts: wanted.exceptions)
            }
            if before?.ownRules != wanted.ownRules {
                engine.setOwnBlockingRules(engineProfile: engineProfile, dnrRulesJSON: dnrJSON(for: wanted.ownRules))
            }
            if before?.level != wanted.level || before?.lists != wanted.lists {
                engine.setContentBlocking(engineProfile: engineProfile, level: wanted.level, enabledListIDs: wanted.lists)
            }
            applied[engineProfile] = wanted
        }
        conversions = conversions.filter { texts.contains($0.key) }
    }

    private func dnrJSON(for text: String) -> String {
        if let known = conversions[text] { return known }
        let json = ContentBlockingRuleConverter.convert(text).json
        conversions[text] = json
        return json
    }
}

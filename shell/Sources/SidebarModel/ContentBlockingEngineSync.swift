import Foundation

/// The engine's blocking calls (spec §5; engine/docs/C-ABI.md "Content
/// blocking (ABI 1.66)"), as a seam: the Chromium shell implements it over
/// the C ABI (`ChromiumContentBlockingEngine`), a test with a recorder.
/// Profiles are the engine's own profile IDs, never an off-the-record one:
/// private windows follow their profile in the engine.
public protocol ContentBlockingEngine: AnyObject {
    /// `ReArcEngineSetBlocklistDirectory`: a verified bundle's directory.
    /// Every profile with blocking on gets that bundle's blocker; the engine
    /// sets their exceptions and own rules again itself.
    func setBlocklistDirectory(_ directory: URL)
    /// `ReArcProfileSetContentBlocking`. Level 0 leaves the profile without a blocker.
    func setContentBlocking(engineProfile: UInt64, level: ContentBlockingLevel, enabledListIDs: [String])
    /// `ReArcProfileSetBlockingExceptions`: replaces the profile's exceptions.
    func setBlockingExceptions(engineProfile: UInt64, hosts: [String])
    /// `ReArcProfileSetOwnBlockingRules`: replaces the profile's own rules (DNR JSON).
    func setOwnBlockingRules(engineProfile: UInt64, dnrRulesJSON: String)
}

/// Keeps the engine at the shell's settings (spec §1: nothing in the engine
/// is authoritative, and it keeps the state in memory only). At every
/// profile load the engine is told the profile's level and lists, then its
/// site exceptions, then its own rules, in that order; afterwards only what
/// changed, in the same order.
///
/// The state does not wait for a bundle: the engine holds it until a bundle
/// is named. A bundle's manifest says which level has each list, so a new
/// bundle can change the lists a level means; the difference is sent.
public final class ContentBlockingEngineSync {
    private struct Applied: Equatable {
        var level: ContentBlockingLevel
        var lists: [String]
        var exceptions: [String]
        var ownRules: String
    }

    private let engine: ContentBlockingEngine
    /// The shell's settings for a shell profile (a container's are its
    /// parent's: `SidebarStore.contentBlocking(for:)`).
    private let settings: (Profile.ID) -> ContentBlockingSettings
    private var bundle: VerifiedBlocklist?
    /// Loaded engine profiles and the shell profile each takes its settings from.
    private var profiles: [UInt64: Profile.ID] = [:]
    private var applied: [UInt64: Applied] = [:]
    /// The own-rules texts in use, converted: a change elsewhere does not
    /// convert 5,000 lines again.
    private var conversions: [String: String] = [:]

    public init(engine: ContentBlockingEngine, settings: @escaping (Profile.ID) -> ContentBlockingSettings) {
        self.engine = engine
        self.settings = settings
    }

    /// The bundle in use; nil while none has verified.
    public var activeBundle: VerifiedBlocklist? { bundle }

    /// The lists and levels the settings are read against: the bundle's.
    public var lists: [ContentBlockingList] { ContentBlockingLists.lists(of: bundle?.manifest) }

    /// A bundle was verified (launch, or an update): the engine gets its
    /// directory, and any profile whose lists the new bundle changes gets them.
    public func setBundle(_ bundle: VerifiedBlocklist?) {
        guard bundle?.directory != self.bundle?.directory || bundle?.version != self.bundle?.version else { return }
        self.bundle = bundle
        guard let bundle else { return }
        engine.setBlocklistDirectory(bundle.directory)
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
        let lists = self.lists
        var texts = Set<String>()
        for (engineProfile, profile) in profiles.sorted(by: { $0.key < $1.key }) {
            let settings = settings(profile)
            let wanted = Applied(level: settings.level, lists: settings.enabledListIDs(in: lists),
                                 exceptions: settings.exceptions, ownRules: settings.ownRules)
            texts.insert(wanted.ownRules)
            let before = applied[engineProfile]
            guard before != wanted else { continue }
            if before?.level != wanted.level || before?.lists != wanted.lists {
                engine.setContentBlocking(engineProfile: engineProfile, level: wanted.level, enabledListIDs: wanted.lists)
            }
            if before?.exceptions != wanted.exceptions {
                engine.setBlockingExceptions(engineProfile: engineProfile, hosts: wanted.exceptions)
            }
            if before?.ownRules != wanted.ownRules {
                engine.setOwnBlockingRules(engineProfile: engineProfile, dnrRulesJSON: dnrJSON(for: wanted.ownRules))
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

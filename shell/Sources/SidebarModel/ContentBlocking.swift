import Foundation

/// Built-in ad and tracker blocking (docs/FEATURE-SPECS/CONTENT-BLOCKING.md).
/// The shell owns the settings and the site exceptions; the engine is told
/// them at profile load and on every change (`ContentBlockingEngineSync`).
/// Nothing here leaves the Mac except through the profile's own sync record.
public enum ContentBlockingLevel: String, Codable, CaseIterable, Sendable {
    case off, trackersOnly, adsAndTrackers, strict

    /// `ReArcProfileSetContentBlocking`'s level: 0 off, 1 trackers, 2 ads and trackers, 3 strict.
    public var engineValue: Int32 {
        switch self {
        case .off: return 0
        case .trackersOnly: return 1
        case .adsAndTrackers: return 2
        case .strict: return 3
        }
    }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .trackersOnly: return "Trackers only"
        case .adsAndTrackers: return "Ads and trackers"
        case .strict: return "Strict"
        }
    }

    /// The levels the picker offers; Off is the switch.
    public static let strengths: [ContentBlockingLevel] = [.trackersOnly, .adsAndTrackers, .strict]
    /// A new install's profiles, and every profile made after blocking arrived.
    public static let newProfileDefault: ContentBlockingLevel = .adsAndTrackers
}

/// One filter list as Settings › Advanced shows it, and the level that turns
/// it on. The table below is spec §2's; a bundle's signed manifest says the
/// same of each list it carries (`level`), and decides for a list the table
/// does not know.
public struct ContentBlockingList: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// The lowest level that turns the list on; nil for a regional list,
    /// which is on only when chosen.
    public var level: ContentBlockingLevel?

    public init(id: String, title: String, level: ContentBlockingLevel?) {
        self.id = id
        self.title = title
        self.level = level
    }
}

public enum ContentBlockingLists {
    public static let easyPrivacy = "easyprivacy"
    public static let peterLowe = "peter-lowe"
    public static let easyList = "easylist"
    public static let fanboyAnnoyance = "fanboy-annoyance"
    public static let easyListCookie = "easylist-cookie"

    /// Spec §2 "Levels to lists", then the regional lists (off at every level).
    public static let known: [ContentBlockingList] = [
        ContentBlockingList(id: easyPrivacy, title: "EasyPrivacy", level: .trackersOnly),
        ContentBlockingList(id: peterLowe, title: "Peter Lowe’s list", level: .trackersOnly),
        ContentBlockingList(id: easyList, title: "EasyList", level: .adsAndTrackers),
        ContentBlockingList(id: fanboyAnnoyance, title: "Fanboy’s Annoyance list", level: .strict),
        ContentBlockingList(id: easyListCookie, title: "EasyList Cookie List", level: .strict),
        ContentBlockingList(id: "easylist-germany", title: "EasyList Germany", level: nil),
        ContentBlockingList(id: "liste-fr", title: "Liste FR", level: nil),
        ContentBlockingList(id: "easylist-italy", title: "EasyList Italy", level: nil),
        ContentBlockingList(id: "easylist-spanish", title: "EasyList Spanish", level: nil),
        ContentBlockingList(id: "easylist-dutch", title: "EasyList Dutch", level: nil),
    ]

    /// The lists a level turns on, in `lists`' order. Off turns on none.
    public static func defaults(for level: ContentBlockingLevel, in lists: [ContentBlockingList] = known) -> [String] {
        guard level != .off else { return [] }
        return lists.filter { list in list.level.map { $0.engineValue <= level.engineValue } ?? false }.map(\.id)
    }

    /// The lists of a bundle, for Settings › Advanced and for what the
    /// engine is told: the table's lists the bundle carries, in the table's
    /// order and at the bundle's levels, then lists only the bundle knows
    /// (added to the mirror after this build), under the bundle's titles.
    /// Without a bundle, the table's non-regional lists.
    public static func lists(of bundle: BlocklistManifest?) -> [ContentBlockingList] {
        guard let bundle else { return known.filter { $0.level != nil } }
        func level(_ list: BlocklistManifest.List) -> ContentBlockingLevel? {
            ContentBlockingLevel.strengths.first { Int($0.engineValue) == list.level }
        }
        let carried = known.compactMap { row in
            bundle.lists.first { $0.id == row.id }.map { ContentBlockingList(id: row.id, title: row.title, level: level($0)) }
        }
        let extra = bundle.lists.filter { list in !known.contains { $0.id == list.id } }
            .map { ContentBlockingList(id: $0.id, title: $0.title.isEmpty ? $0.id : $0.title, level: level($0)) }
        return carried + extra
    }
}

/// One profile's blocking settings (spec §2). A profile without settings is
/// Off: that is every profile from before blocking, until the person turns
/// it on.
public struct ContentBlockingSettings: Equatable, Codable, Sendable {
    /// Own rules as typed, at most this much text (5,000 rules of ordinary
    /// length; the settings travel in one sync record).
    public static let maxOwnRulesBytes = 256 * 1024
    public static let maxExceptions = 1000

    /// The switch. Off keeps the chosen strength, lists, rules and exceptions.
    public var isEnabled: Bool
    /// Trackers only, Ads and trackers or Strict; never Off.
    public private(set) var strength: ContentBlockingLevel
    /// Lists the person switched on or off themselves, by list ID; the
    /// strength decides the others.
    public private(set) var listOverrides: [String: Bool]
    /// uBO/ABP network filters, one a line (`ContentBlockingRuleConverter`).
    public private(set) var ownRules: String
    /// Hosts blocking is off for, normalised and sorted (`ContentBlockingHost`).
    public private(set) var exceptions: [String]

    public init(
        isEnabled: Bool,
        strength: ContentBlockingLevel = .newProfileDefault,
        listOverrides: [String: Bool] = [:],
        ownRules: String = "",
        exceptions: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.strength = strength == .off ? .newProfileDefault : strength
        self.listOverrides = [:]
        self.ownRules = ""
        self.exceptions = []
        for (id, enabled) in listOverrides { setList(id, enabled: enabled) }
        setOwnRules(ownRules)
        setExceptions(exceptions)
    }

    /// Every profile from before blocking, and a profile with no settings.
    public static let off = ContentBlockingSettings(isEnabled: false)
    /// A new install's profiles and every profile made later.
    public static let newProfile = ContentBlockingSettings(isEnabled: true)

    /// What the engine is told.
    public var level: ContentBlockingLevel { isEnabled ? strength : .off }

    /// Choosing a strength puts the lists back to what it sets.
    public mutating func setStrength(_ level: ContentBlockingLevel) {
        guard level != .off, level != strength else { return }
        strength = level
        listOverrides = [:]
    }

    /// `lists`: the bundle's lists and levels (`ContentBlockingLists.lists(of:)`).
    public func isListEnabled(_ id: String, in lists: [ContentBlockingList] = ContentBlockingLists.known) -> Bool {
        listOverrides[id] ?? ContentBlockingLists.defaults(for: strength, in: lists).contains(id)
    }

    public mutating func setList(_ id: String, enabled: Bool) {
        guard Self.isListID(id) else { return }
        listOverrides[id] = enabled
    }

    /// List IDs name files in the bundle (`rules/<id>.json`).
    public static func isListID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
        }
    }

    /// The lists the engine switches on: none while Off, otherwise the
    /// strength's lists with the person's changes, in `lists`' order, then
    /// lists the person switched on that `lists` does not have, by ID (the
    /// engine skips an ID its bundle lacks until a later bundle has it).
    public func enabledListIDs(in lists: [ContentBlockingList] = ContentBlockingLists.known) -> [String] {
        guard isEnabled else { return [] }
        let known = lists.map(\.id)
        return known.filter { isListEnabled($0, in: lists) }
            + listOverrides.filter { $0.value && !known.contains($0.key) }.keys.sorted()
    }

    /// Text over the limit is cut at the end of the last whole line.
    public mutating func setOwnRules(_ text: String) {
        guard text.utf8.count > Self.maxOwnRulesBytes else { return ownRules = text }
        var kept = ""
        var size = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let cost = line.utf8.count + 1
            guard size + cost <= Self.maxOwnRulesBytes else { break }
            kept += line + "\n"
            size += cost
        }
        ownRules = kept
    }

    public mutating func setExceptions(_ hosts: [String]) {
        let normalised = Set(hosts.compactMap(ContentBlockingHost.normalized))
        exceptions = Array(normalised.sorted().prefix(Self.maxExceptions))
    }

    /// False when `host` is no host, or the list is full.
    @discardableResult
    public mutating func addException(_ host: String) -> Bool {
        guard let host = ContentBlockingHost.normalized(host) else { return false }
        guard !exceptions.contains(host) else { return true }
        guard exceptions.count < Self.maxExceptions else { return false }
        exceptions = (exceptions + [host]).sorted()
        return true
    }

    public mutating func removeException(_ host: String) {
        guard let host = ContentBlockingHost.normalized(host) else { return }
        exceptions.removeAll { $0 == host }
    }

    /// The exception that covers `url`'s page: its host, or a parent of it.
    public func exception(covering url: URL?) -> String? {
        guard let host = ContentBlockingHost.pageHost(url) else { return nil }
        return exceptions.first { ContentBlockingHost.covers($0, host: host) }
    }

    /// Turns blocking off or back on for `url`'s site. Off adds the page's
    /// host (`ContentBlockingHost.exceptionHost`); on removes every exception
    /// that covers the page.
    /// False when the page has no site (about:, file:, the engine's own pages).
    @discardableResult
    public mutating func setException(_ excepted: Bool, forPage url: URL?) -> Bool {
        guard let host = ContentBlockingHost.pageHost(url), let site = ContentBlockingHost.exceptionHost(for: url) else { return false }
        if excepted {
            return exception(covering: url) != nil || addException(site)
        }
        exceptions.removeAll { ContentBlockingHost.covers($0, host: host) }
        return true
    }

    enum CodingKeys: String, CodingKey { case isEnabled, strength, listOverrides, ownRules, exceptions }

    /// Total: a value this build does not know reads as its default, and
    /// the switch reads as off, never on.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? false,
            strength: (try? c.decodeIfPresent(ContentBlockingLevel.self, forKey: .strength)) ?? .newProfileDefault,
            listOverrides: (try? c.decodeIfPresent([String: Bool].self, forKey: .listOverrides)) ?? [:],
            ownRules: (try? c.decodeIfPresent(String.self, forKey: .ownRules)) ?? "",
            exceptions: (try? c.decodeIfPresent([String].self, forKey: .exceptions)) ?? []
        )
    }
}

/// Hosts as site exceptions keep them: lowercase ASCII (an international
/// name in its `xn--` form), no scheme, port, path or trailing dot.
public enum ContentBlockingHost {
    /// A host from what a person typed or a record holds: a bare host, a
    /// host with a port, a URL, or `*.example.com`. nil when no host is in it.
    public static func normalized(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if text.hasPrefix("*.") { text.removeFirst(2) }
        // The host through the system's URL parser: it drops the user, port
        // and path and gives an international name its ASCII form.
        guard var host = URLComponents(string: "https://" + text)?.encodedHost?.lowercased() else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        while host.hasPrefix(".") { host.removeFirst() }
        if host.hasPrefix("www."), host.count > 4 { host.removeFirst(4) }
        return isHost(host) ? host : nil
    }

    static func isHost(_ host: String) -> Bool {
        guard (1...253).contains(host.utf8.count) else { return false }
        // Names and IPv4 addresses. The engine's exception hosts are names
        // (C-ABI.md "Content blocking"): an IPv6 literal is not one.
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            (1...63).contains(label.utf8.count) && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }
        }
    }

    /// A web page's own host, normalised but with `www.` and subdomains
    /// kept; nil for a page that is no site.
    public static func pageHost(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.encodedHost?.lowercased() else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return isHost(host) ? host : nil
    }

    /// The host an exception for `url`'s site is kept under: the page's own
    /// host (without `www.`), which is always one site, and its subdomains
    /// are covered. Not the registrable domain: the shell has no public
    /// suffix list, and its guess (`BoostScopeMatcher.registrableDomain`)
    /// made `someone.web.app` an exception for all of `web.app` (security
    /// CB-12). The site from the engine's suffix list replaces this later.
    /// An exception stored under a suffix by 1027 stays until the site is
    /// turned back on: on removes every exception that covers the page.
    public static func exceptionHost(for url: URL?) -> String? {
        guard let host = pageHost(url) else { return nil }
        return normalized(host) ?? host
    }

    /// An exception covers its own host and every subdomain of it, as the
    /// engine's `requestDomains` do.
    public static func covers(_ exception: String, host: String) -> Bool {
        host == exception || host.hasSuffix("." + exception)
    }
}

/// The first launch of a build with blocking decides, once, whether this is
/// a new or an existing install (spec §2 "New versus existing installs"),
/// and an existing install is offered the switch once. Kept in the sidebar
/// file with the profiles' settings, so the two are written together.
public struct ContentBlockingRollout: Equatable, Codable, Sendable {
    public enum Install: String, Codable, Sendable {
        /// No ReArc data before that launch: every profile starts at Ads and trackers.
        case new
        /// Profiles from before blocking stay Off; the sidebar offers the switch once.
        case existing
    }

    /// nil until that first launch.
    public var install: Install?
    /// `contentBlockingOfferShown`: set before the card is first shown, so
    /// a crash cannot show it again.
    public var offerShown: Bool

    public init(install: Install? = nil, offerShown: Bool = false) {
        self.install = install
        self.offerShown = offerShown
    }

    public var isDecided: Bool { install != nil }
    /// The offer card has yet to be shown.
    public var isOfferDue: Bool { install == .existing && !offerShown }

    enum CodingKeys: String, CodingKey { case install, offerShown }

    /// Total. A value this build cannot read counts as an existing install
    /// whose offer was shown: blocking then stays as it is and no card comes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.install) {
            install = (try? c.decode(Install.self, forKey: .install)) ?? .existing
            offerShown = (try? c.decodeIfPresent(Bool.self, forKey: .offerShown)) ?? true
        } else {
            install = nil
            offerShown = false
        }
    }

    public static let offerTitle = "Darni can now block ads and trackers"
    public static let offerMessage = "Blocking is off for your profiles. Turn it on here, or later in Settings › Profiles."
    public static let offerAccept = "Turn On"
    public static let offerDecline = "Not Now"
}

/// The sidebar file's `contentBlocking` key: additive, with its own version,
/// as `tabGroups` is. An older build drops the key when it saves; a later
/// launch of this build then treats the install as an existing one (Off).
public struct ContentBlockingSnapshot: Equatable, Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var rollout: ContentBlockingRollout
    public var settingsByProfile: [Profile.ID: ContentBlockingSettings]

    public init(rollout: ContentBlockingRollout = ContentBlockingRollout(),
                settingsByProfile: [Profile.ID: ContentBlockingSettings] = [:]) {
        self.version = Self.currentVersion
        self.rollout = rollout
        self.settingsByProfile = settingsByProfile
    }

    public var isEmpty: Bool { !rollout.isDecided && settingsByProfile.isEmpty }
}

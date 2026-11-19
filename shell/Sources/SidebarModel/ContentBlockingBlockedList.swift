import Foundation

/// "Blocked on this page" (docs/FEATURE-SPECS/CONTENT-BLOCKING.md §3): the
/// sites whose requests the blocker stopped in one tab's current page, each
/// with how often and with the kind of list that stopped it.
///
/// The engine holds the list, in memory, beside the tab's count, and drops it
/// with the count at the page's next navigation. The shell reads it while the
/// site controls show it and keeps no copy: nothing here is written to disk,
/// logged, synced or sent anywhere.
public struct ContentBlockingBlockedList: Equatable, Sendable {
    /// What a list blocks, as the line's tag says it.
    public enum Kind: String, CaseIterable, Sendable {
        case ad, tracker, annoyance, ownRule

        public var title: String {
            switch self {
            case .ad: return "Ad"
            case .tracker: return "Tracker"
            case .annoyance: return "Annoyance"
            case .ownRule: return "Your rule"
            }
        }
    }

    /// One line: a site, the requests blocked for it, and its tags in `Kind`'s order.
    public struct Entry: Equatable, Identifiable, Sendable {
        public var host: String
        public var count: Int
        public var kinds: [Kind]
        /// The name is one site (a registrable domain or an address), so
        /// Allow may name it. False for a single-label name and for a public
        /// suffix such as `co.uk`: a rule for one of those would allow every
        /// name under it (security BL-02). The engine says which, from
        /// Chromium's suffix list; `ContentBlockingSiteAllow.isOneSite` must agree.
        public var canBeAllowed: Bool
        public var id: String { host }

        public init(host: String, count: Int, kinds: [Kind], canBeAllowed: Bool = true) {
            self.host = host
            self.count = count
            self.kinds = kinds
            self.canBeAllowed = canBeAllowed
        }

        /// "Ad", "Ad, Tracker"; empty for a list this build cannot name.
        public var tagText: String { kinds.map(\.title).joined(separator: ", ") }

        /// What VoiceOver reads for the line.
        public var spokenText: String {
            ([host] + kinds.map(\.title) + ["\(count) blocked"]).joined(separator: ", ")
        }
    }

    /// Most blocked first, then by name.
    public var entries: [Entry]
    /// Blocked requests whose site is not in `entries`: the engine's cap, or this one.
    public var uncounted: Int
    /// The page's own site, as the engine names it: the registrable domain
    /// of the tab's committed address, from Chromium's suffix list, in the
    /// same reply as the entries. It is the site Allow writes for. The shell
    /// does not work it out from the tab's address: that may already be the
    /// next page's, and the shell's own idea of a site takes `web.app` or
    /// `edu.au` for one (security BL-10, BL-11). nil for a page that is no site.
    public var pageSite: String?
    /// `pageSite` is one site, by the engine and by `ContentBlockingSiteAllow.isOneSite`.
    public var pageSiteIsOneSite: Bool

    public init(entries: [Entry] = [], uncounted: Int = 0, pageSite: String? = nil, pageSiteIsOneSite: Bool = false) {
        self.entries = entries
        self.uncounted = uncounted
        self.pageSite = pageSite
        self.pageSiteIsOneSite = pageSite != nil && pageSiteIsOneSite
    }

    /// The site Allow may write a rule for; nil when the page has none.
    public var allowSite: String? { pageSiteIsOneSite ? pageSite : nil }

    public var isEmpty: Bool { entries.isEmpty && uncounted == 0 }

    /// The lines of a list that is open, given the hosts it shows now, top
    /// to bottom: those stay where they are with their counts brought up to
    /// date, and new sites go underneath. The order by count is taken again
    /// only when the list is opened again. The page decides how often each
    /// host is blocked, so a list that sorted itself while open would let a
    /// page swap two lines under the pointer as the person clicks Allow
    /// (security BL-03).
    public func entries(keeping shown: [String]) -> [Entry] {
        let byHost = Dictionary(entries.map { ($0.host, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(shown)
        return shown.compactMap { byHost[$0] } + entries.filter { !kept.contains($0.host) }
    }

    /// The sites one page's list holds, as the engine's (`C-ABI.md`, "Blocked hosts").
    public static let maxEntries = 100
    /// A full list of the longest names stays under this; a longer reply is not read.
    public static let maxReplyBytes = 64 * 1024
    /// The engine's name for the person's own rules among a blocker's rulesets.
    public static let ownRulesListID = "_dynamic"
    /// A site blocked by more lists than this has a broken reply.
    static let maxListsPerEntry = 16
    /// No page's count is past this; a larger number in a reply is cut to it.
    static let maxCount = 1_000_000

    /// The last line when the list is cut: "and 12 more requests".
    public var uncountedText: String? {
        guard uncounted > 0 else { return nil }
        return uncounted == 1 ? "and 1 more request" : "and \(uncounted) more requests"
    }

    // MARK: The engine's reply

    private struct Reply: Decodable {
        struct Host: Decodable {
            var host: String
            var count: Int
            var lists: [String]?
            var registrable: Bool?
        }

        struct Page: Decodable {
            var host: String
            var registrable: Bool?
        }

        var page: Page?
        var hosts: [Host]
        var more: Int?
    }

    /// The list from `ReArcTabCopyBlockedHosts`' JSON. `lists`: the bundle's
    /// lists with their levels (`ContentBlockingLists.lists(of:)`), which
    /// give the tags.
    ///
    /// A page chooses the hosts it asks for, so the reply is read as a
    /// stranger's: a name that is not a host is left out, a number is cut to
    /// what a page can reach, and what is past `maxEntries` is only counted.
    /// nil for a reply that is too long or is not this JSON.
    public static func decode(_ json: String, lists: [ContentBlockingList], names: SiteNames? = .shared) -> ContentBlockingBlockedList? {
        guard json.utf8.count <= maxReplyBytes,
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(json.utf8)) else { return nil }
        var counts: [String: Int] = [:]
        var kinds: [String: Set<Kind>] = [:]
        var notOneSite: Set<String> = []
        var uncounted = min(max(reply.more ?? 0, 0), maxCount)
        for item in reply.hosts {
            let count = min(max(item.count, 0), maxCount)
            guard count > 0 else { continue }
            guard ContentBlockingHost.isHost(item.host) else {
                uncounted = min(uncounted + count, maxCount)
                continue
            }
            counts[item.host] = min((counts[item.host] ?? 0) + count, maxCount)
            if item.registrable != true { notOneSite.insert(item.host) }
            let named = (item.lists ?? []).prefix(maxListsPerEntry).compactMap { kind(ofList: $0, in: lists) }
            kinds[item.host, default: []].formUnion(named)
        }
        var entries = counts.map { host, count in
            Entry(host: host, count: count, kinds: Kind.allCases.filter { kinds[host]?.contains($0) ?? false },
                  canBeAllowed: !notOneSite.contains(host) && ContentBlockingSiteAllow.isOneSite(host, names: names))
        }
        entries.sort { ($1.count, $0.host) < ($0.count, $1.host) }
        for cut in entries.dropFirst(maxEntries) { uncounted = min(uncounted + cut.count, maxCount) }
        let page = reply.page.flatMap { ContentBlockingHost.isHost($0.host) ? $0 : nil }
        return ContentBlockingBlockedList(entries: Array(entries.prefix(maxEntries)), uncounted: uncounted, pageSite: page?.host,
                                          pageSiteIsOneSite: page?.registrable == true && ContentBlockingSiteAllow.isOneSite(page?.host ?? "", names: names))
    }

    /// The tag for a rule of list `id`: a list of the Trackers only level
    /// blocks trackers, one of Ads and trackers and every regional list
    /// blocks ads, one of Strict blocks annoyances. `lists` (the bundle's,
    /// from its signed manifest) decides, then this build's table. nil for an
    /// ID neither knows.
    public static func kind(ofList id: String, in lists: [ContentBlockingList]) -> Kind? {
        if id == ownRulesListID { return .ownRule }
        guard ContentBlockingSettings.isListID(id),
              let list = lists.first(where: { $0.id == id }) ?? ContentBlockingLists.known.first(where: { $0.id == id }) else { return nil }
        switch list.level {
        case .trackersOnly?: return .tracker
        case .adsAndTrackers?, nil: return .ad
        case .strict?: return .annoyance
        case .off?: return nil
        }
    }
}

/// "Allow doubleclick.net on this site" (spec §3): one line of the person's
/// own rules, `@@||doubleclick.net^$domain=example.com`. It is what they
/// could type in Settings › Advanced; it shows there, syncs with the own
/// rules, and Remove deletes exactly that line.
public enum ContentBlockingSiteAllow {
    /// Why Allow wrote nothing. The person is told (`message`).
    public enum Refusal: Equatable, Sendable {
        /// The tab is no longer on the site the list was shown for.
        case pageMoved
        /// The page is not one site: no web page, or a host that could be a whole suffix.
        case noSite
        /// The name to allow is not one site: no host, a single label, a public suffix.
        case notOneSite
        /// The own rules are at their limit of text or of rules.
        case full

        public var message: String {
            switch self {
            case .pageMoved: return "The page has changed, so nothing was allowed. Open the list again."
            case .noSite: return "Nothing can be allowed on this page."
            case .notOneSite: return "That name covers more than one site, so it can’t be allowed."
            case .full: return "Your own rules are full. Remove some in Settings › Profiles."
            }
        }
    }

    /// `host` names one site: a host of two labels or more that is not
    /// itself a suffix other sites hang under. A rule for a single label or
    /// for `co.uk` would allow every name under it (security BL-02, BL-04).
    ///
    /// The engine's public suffix list decides where there is one
    /// (`SiteNames`), as for every other user of a site's name: a name it
    /// calls a suffix, or anything but one site, is refused. Without an
    /// answer the shell's guess stands in (`BoostScopeMatcher.registrableDomain`,
    /// asked whether it treats the name as a suffix), and by the guess alone
    /// `web.app` and `edu.au` read as one site. The shared-hosting domains
    /// this build knows are refused either way: this check may refuse more
    /// than the engine, never less.
    public static func isOneSite(_ host: String, names: SiteNames? = .shared) -> Bool {
        guard ContentBlockingHost.isHost(host), host.contains("."),
              !BoostPublicSuffixList.isSharedHostingRegistrableDomain(host) else { return false }
        if let site = names?.site(of: host) { return site.isOneSite }
        let below = "a." + host
        return BoostScopeMatcher.registrableDomain(below) != below
    }

    /// The line. Both names come from pages (the page's own host, and a host
    /// it asked), so each must be a plain host that is one site before it is
    /// put into filter syntax; nil otherwise.
    public static func rule(host: String, site: String, names: SiteNames? = .shared) -> String? {
        guard isOneSite(host, names: names), isOneSite(site, names: names) else { return nil }
        return "@@||\(host)^$domain=\(site)"
    }

    /// The hosts allowed on `site` by lines of exactly that form, in the text's order.
    public static func hosts(in ownRules: String, site: String, names: SiteNames? = .shared) -> [String] {
        guard isOneSite(site, names: names) else { return [] }
        let prefix = "@@||", suffix = "^$domain=\(site)"
        var hosts: [String] = []
        for raw in ownRules.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix), line.hasSuffix(suffix), line.count > prefix.count + suffix.count else { continue }
            let host = String(line.dropFirst(prefix.count).dropLast(suffix.count))
            if isOneSite(host, names: names), !hosts.contains(host) { hosts.append(host) }
        }
        return hosts
    }
}

extension ContentBlockingSettings {
    /// The hosts the person allowed on `site` from the blocked list. `site`
    /// is the engine's name for the page (`ContentBlockingBlockedList.pageSite`).
    public func allowedHosts(onSite site: String, names: SiteNames? = .shared) -> [String] {
        ContentBlockingSiteAllow.hosts(in: ownRules, site: site, names: names)
    }

    /// Adds the own rule that lets `site` ask `host`: one line, which must
    /// convert as a typed rule does, to one allow rule for that site.
    /// `site` is the engine's name for the page the list was shown for,
    /// never one cut from an address here. Returns why nothing was written,
    /// nil when the line is there.
    @discardableResult
    public mutating func allowHost(_ host: String, onSite site: String, names: SiteNames? = .shared) -> ContentBlockingSiteAllow.Refusal? {
        guard ContentBlockingSiteAllow.isOneSite(site, names: names) else { return .noSite }
        guard let line = ContentBlockingSiteAllow.rule(host: host, site: site, names: names) else { return .notOneSite }
        if ContentBlockingSiteAllow.hosts(in: ownRules, site: site, names: names).contains(host) { return nil }
        // The same converter and limits as a rule typed in Settings (security BL-04).
        let converted = ContentBlockingRuleConverter.convert(line)
        guard converted.dropped.isEmpty, converted.rules.count == 1, converted.rules[0].action.type == "allow",
              converted.rules[0].condition.urlFilter == "||\(host)^", converted.rules[0].condition.initiatorDomains == [site] else { return .notOneSite }
        let text = ownRules.isEmpty || ownRules.hasSuffix("\n") ? ownRules + line + "\n" : ownRules + "\n" + line + "\n"
        guard text.utf8.count <= Self.maxOwnRulesBytes,
              ContentBlockingRuleConverter.convert(ownRules).rules.count < ContentBlockingRuleConverter.maxRules else { return .full }
        setOwnRules(text)
        return nil
    }

    /// Deletes the lines `allowHost` wrote for `host` on `site`, and no other.
    public mutating func removeAllowedHost(_ host: String, onSite site: String, names: SiteNames? = .shared) {
        guard let line = ContentBlockingSiteAllow.rule(host: host, site: site, names: names), ownRules.contains(line) else { return }
        let kept = ownRules.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .filter { $0.trimmingCharacters(in: .whitespaces) != line }
        setOwnRules(kept.joined(separator: "\n"))
    }
}

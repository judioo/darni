import Foundation

/// One `declarativeNetRequest` rule, with the keys the converter writes.
public struct ContentBlockingDNRRule: Equatable, Codable, Sendable {
    public struct Action: Equatable, Codable, Sendable {
        /// `block`, `allow` or `allowAllRequests`. The converter writes no other
        /// action: own rules can never redirect a request or change a header.
        public var type: String
    }

    public struct Condition: Equatable, Codable, Sendable {
        public var urlFilter: String?
        public var isUrlFilterCaseSensitive: Bool?
        public var domainType: String?
        public var initiatorDomains: [String]?
        public var excludedInitiatorDomains: [String]?
        /// The site of the page in the tab, whichever of its frames asks
        /// (DNR: "the associated top-level frame's domain").
        public var topDomains: [String]?
        public var excludedTopDomains: [String]?
        public var resourceTypes: [String]?
        public var excludedResourceTypes: [String]?
    }

    public var id: Int
    public var priority: Int
    public var action: Action
    public var condition: Condition
}

/// The shell's converter for a profile's own rules (spec §2, §5
/// `ReArcProfileSetOwnBlockingRules`): the uBO/ABP network filter subset the
/// list converter also takes, one filter a line, to DNR rules.
///
/// Taken: `||host^`, `|https://…`, plain text with `*` and `^` (DNR's
/// `urlFilter` is the same syntax), `@@` exceptions, hosts-file lines
/// (`0.0.0.0 host`), and the options `third-party`/`3p`, `first-party`/`1p`,
/// `domain=`/`from=`, the resource types and their `~` forms, `all`,
/// `document`, `important` and `match-case`. Everything else is dropped and
/// reported by line: cosmetic filters, regular expressions, `$csp`,
/// `$redirect`, `$removeparam`, scriptlets and any option not named here.
/// A filter is never half applied.
///
/// An exception for a site is two rules. `@@||ads.example^$domain=news.example`
/// says "on news.example, let ads.example through". DNR's `initiatorDomains`
/// alone is narrower than that: it matches what a news.example document asks
/// for, and not what a frame inside the page asks for. A third party that is
/// let in opens its own frame and asks its own host from there, and the lists
/// block that host for every asker, so the exception left it blocked on the
/// very page it was written for. The second rule has the same condition with
/// the site as `topDomains`: any frame's request, in a page of that site.
/// Only exceptions get one. A block with `$domain=` keeps the filter's own
/// meaning, and so do the signed lists.
public enum ContentBlockingRuleConverter {
    /// Spec §2: at most 5,000 own rules.
    public static let maxRules = 5000

    /// A block is 1, an `@@` exception 2, an `$important` block 3. The
    /// engine keeps the order of own rules' priorities (1 to 100) and places
    /// them above every list rule and below the site exceptions; it numbers
    /// the rules itself, so `id` only has to be unique.
    public enum Priority {
        public static let block = 1
        public static let allow = 2
        public static let importantBlock = 3
    }

    public enum DropReason: Equatable, Sendable {
        /// `##`, `#@#`, `#?#`, `#$#`: element hiding and scriptlets (phase 2 at the earliest).
        case cosmetic
        /// `/…/`: a regular expression.
        case regex
        /// An option DNR cannot express, or one the converter does not know.
        case unsupportedOption(String)
        /// Not a filter: spaces inside it, no pattern, `||*`.
        case invalid
        /// DNR patterns are ASCII.
        case nonASCII
        /// A good rule past `maxRules`.
        case overLimit

        public var text: String {
            switch self {
            case .cosmetic: return "Element hiding rules are not supported"
            case .regex: return "Regular expressions are not supported"
            case .unsupportedOption(let name): return "The option “\(name)” is not supported"
            case .invalid: return "Not a filter"
            case .nonASCII: return "Only ASCII patterns are supported"
            case .overLimit: return "Over the limit of \(ContentBlockingRuleConverter.maxRules) rules"
            }
        }
    }

    public struct Dropped: Equatable, Sendable {
        /// 1-based line in the text.
        public var line: Int
        public var text: String
        public var reason: DropReason
    }

    public struct Conversion: Equatable, Sendable {
        /// The DNR rules: one a filter, in the text's order, then the second
        /// rule of each exception for a site (`pageRule`).
        public var rules: [ContentBlockingDNRRule]
        public var dropped: [Dropped]
        /// The filters taken. The person counts lines, not DNR rules.
        public var filters: Int
        /// Exceptions for a site whose second rule found no room under the
        /// limit: they cover what the site's own documents ask, as before,
        /// and not the frames in its pages. The person is told (security
        /// addendum 14, remark 4).
        public var withoutPageRule = 0

        /// The DNR rule array the engine takes; `[]` for no rules.
        public var json: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? String(decoding: encoder.encode(rules), as: UTF8.self)) ?? "[]"
        }

        /// The line under the own-rules field.
        public var summary: String {
            let rules = filters == 1 ? "1 rule" : "\(filters) rules"
            var text = rules
            if !dropped.isEmpty {
                let lines = dropped.count == 1 ? "1 line is" : "\(dropped.count) lines are"
                text += ". \(lines) not supported and left out."
            }
            if withoutPageRule > 0 {
                let exceptions = withoutPageRule == 1 ? "1 exception does" : "\(withoutPageRule) exceptions do"
                text += (dropped.isEmpty ? ". " : " ") + "\(exceptions) not cover frames, because the limit of "
                    + "\(ContentBlockingRuleConverter.maxRules) rules is reached."
            }
            return text
        }
    }

    /// `limit` is the engine's, on DNR rules. Every filter's own rule comes
    /// first, so a text that fitted before exceptions had a second rule
    /// still fits whole, and the second rules take the room that is left, in
    /// the text's order. An exception past that room works as it did before:
    /// for the site's own requests.
    public static func convert(_ text: String, limit: Int = maxRules) -> Conversion {
        var rules: [ContentBlockingDNRRule] = []
        var pageRules: [ContentBlockingDNRRule] = []
        var dropped: [Dropped] = []
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Blank lines, comments and a list's header are not filters.
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["), !(line.hasPrefix("#") && !line.hasPrefix("##")) else { continue }
            switch parse(line) {
            case .failure(let reason):
                dropped.append(Dropped(line: index + 1, text: line, reason: reason.reason))
            case .success(var rule):
                guard rules.count < limit else {
                    dropped.append(Dropped(line: index + 1, text: line, reason: .overLimit))
                    continue
                }
                rule.id = rules.count + 1
                rules.append(rule)
                if let second = pageRule(of: rule) { pageRules.append(second) }
            }
        }
        let filters = rules.count
        let fitting = pageRules.prefix(max(limit - rules.count, 0))
        for var rule in fitting {
            rule.id = rules.count + 1
            rules.append(rule)
        }
        return Conversion(rules: rules, dropped: dropped, filters: filters, withoutPageRule: pageRules.count - fitting.count)
    }

    /// The second rule of an exception for a site: `rule` with its sites as
    /// the page's, so a frame's request in a page of that site is let
    /// through too. nil for anything but an `allow` that names sites.
    ///
    /// It allows nothing outside pages of the named sites. What the filter
    /// excludes stays excluded twice over: no page of an excluded site, and
    /// no frame of one in any page. `$third-party` and the types stay as
    /// written.
    ///
    /// None for a `$first-party` exception (security addendum 14, remark
    /// 1). DNR counts the party against the frame that asks, not against
    /// the page: `@@$first-party,domain=shop.example` means what
    /// shop.example's documents ask of their own site, and with the site as
    /// the page it would mean that every frame in a shop.example page may
    /// ask its own site for anything.
    static func pageRule(of rule: ContentBlockingDNRRule) -> ContentBlockingDNRRule? {
        guard rule.action.type == "allow", rule.condition.domainType != "firstParty",
              let sites = rule.condition.initiatorDomains, !sites.isEmpty else { return nil }
        var second = rule
        second.condition.initiatorDomains = nil
        second.condition.topDomains = sites
        second.condition.excludedTopDomains = rule.condition.excludedInitiatorDomains
        return second
    }

    private struct Refusal: Error {
        var reason: DropReason
    }

    /// The filter's option names and the DNR resource type each stands for.
    private static let resourceTypes: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "stylesheet", "css": "stylesheet",
        "object": "object", "xmlhttprequest": "xmlhttprequest", "xhr": "xmlhttprequest",
        "subdocument": "sub_frame", "frame": "sub_frame", "ping": "ping", "beacon": "ping",
        "websocket": "websocket", "font": "font", "media": "media", "other": "other",
        "document": "main_frame", "doc": "main_frame",
    ]
    /// DNR's types in its own order, for `$all` and a stable output.
    private static let allResourceTypes = [
        "main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object",
        "xmlhttprequest", "ping", "media", "websocket", "other",
    ]

    private static func parse(_ line: String) -> Result<ContentBlockingDNRRule, Refusal> {
        if isCosmetic(line) { return .failure(Refusal(reason: .cosmetic)) }
        var body = Substring(line)
        let allow = body.hasPrefix("@@")
        if allow { body = body.dropFirst(2) }

        // A hosts-file line names a host to block.
        let words = body.split(whereSeparator: \.isWhitespace)
        if words.count == 2, ["0.0.0.0", "127.0.0.1", "::", "::1"].contains(String(words[0])), !allow {
            guard let host = ContentBlockingHost.normalizedKeepingWWW(String(words[1])), host.contains(".") else {
                return .failure(Refusal(reason: .invalid))
            }
            return .success(rule(pattern: "||\(host)^", allow: false, options: Options()))
        }
        guard !words.isEmpty else { return .failure(Refusal(reason: .invalid)) }

        if body.hasPrefix("/"), body.count > 1, body.hasSuffix("/") { return .failure(Refusal(reason: .regex)) }
        var pattern = body
        var optionText: Substring = ""
        if let dollar = body.lastIndex(of: "$") {
            pattern = body[..<dollar]
            optionText = body[body.index(after: dollar)...]
            if pattern.hasPrefix("/"), pattern.count > 1, pattern.hasSuffix("/") { return .failure(Refusal(reason: .regex)) }
        }
        // An option's value may hold a space (`$csp=script-src 'none'`); a pattern never does.
        guard !pattern.contains(where: \.isWhitespace) else { return .failure(Refusal(reason: .invalid)) }
        guard pattern.allSatisfy(\.isASCII) else { return .failure(Refusal(reason: .nonASCII)) }

        var options = Options()
        for option in optionText.split(separator: ",", omittingEmptySubsequences: true) {
            if let refusal = options.take(String(option)) { return .failure(refusal) }
        }
        if body.contains("$"), optionText.isEmpty { return .failure(Refusal(reason: .invalid)) }
        // `$script,~script` names no type at all.
        if !options.types.isEmpty, options.types.isSubset(of: options.excludedTypes) { return .failure(Refusal(reason: .invalid)) }

        // Leading and trailing `*` say nothing; DNR refuses an empty filter and `||*`.
        var filter = String(pattern)
        while filter.hasPrefix("*") { filter.removeFirst() }
        while filter.hasSuffix("*") { filter.removeLast() }
        if filter.hasPrefix("||*") || filter == "||" || filter == "|" { return .failure(Refusal(reason: .invalid)) }
        // A filter with neither pattern nor option would block every request.
        if filter.isEmpty, optionText.isEmpty { return .failure(Refusal(reason: .invalid)) }
        return .success(rule(pattern: filter, allow: allow, options: options))
    }

    /// `example.com##.ad`, `#@#`, `#?#`, `#$#`, `#%#` after an optional list of hosts.
    private static func isCosmetic(_ line: String) -> Bool {
        guard let hash = line.firstIndex(of: "#") else { return false }
        let hosts = line[..<hash]
        guard !hosts.contains("/"), !hosts.contains("|"), !hosts.contains("$") else { return false }
        let rest = line[line.index(after: hash)...]
        return ["#", "@#", "?#", "$#", "%#", "@?#", "@$#"].contains { rest.hasPrefix($0) }
    }

    private struct Options {
        var domainType: String?
        var initiators: [String] = []
        var excludedInitiators: [String] = []
        var types: Set<String> = []
        var excludedTypes: Set<String> = []
        var important = false
        var matchCase = false

        /// nil when the option was understood.
        mutating func take(_ option: String) -> Refusal? {
            let text = option.trimmingCharacters(in: .whitespaces)
            let lower = text.lowercased()
            let negated = lower.hasPrefix("~")
            let name = negated ? String(lower.dropFirst()) : lower
            switch name {
            case "third-party", "3p":
                domainType = negated ? "firstParty" : "thirdParty"
            case "first-party", "1p":
                domainType = negated ? "thirdParty" : "firstParty"
            case "important" where !negated:
                important = true
            case "match-case" where !negated:
                matchCase = true
            case "all" where !negated:
                types.formUnion(ContentBlockingRuleConverter.allResourceTypes)
            default:
                if let type = ContentBlockingRuleConverter.resourceTypes[name] {
                    if negated { excludedTypes.insert(type) } else { types.insert(type) }
                } else if !negated, name.hasPrefix("domain=") || name.hasPrefix("from=") {
                    let value = name[name.index(after: name.firstIndex(of: "=")!)...]
                    let entries = value.split(separator: "|")
                    guard !entries.isEmpty else { return Refusal(reason: .unsupportedOption(text)) }
                    for entry in entries {
                        let excluded = entry.hasPrefix("~")
                        let raw = String(excluded ? entry.dropFirst() : entry)
                        // `example.*` and `/regex/` domains have no DNR form.
                        guard !raw.contains("*"), !raw.contains("/"),
                              let host = ContentBlockingHost.normalizedKeepingWWW(raw) else {
                            return Refusal(reason: .unsupportedOption(text))
                        }
                        if excluded { excludedInitiators.append(host) } else { initiators.append(host) }
                    }
                } else {
                    return Refusal(reason: .unsupportedOption(text))
                }
            }
            return nil
        }
    }

    private static func rule(pattern: String, allow: Bool, options: Options) -> ContentBlockingDNRRule {
        var condition = ContentBlockingDNRRule.Condition()
        if !pattern.isEmpty { condition.urlFilter = pattern }
        if options.matchCase { condition.isUrlFilterCaseSensitive = true }
        condition.domainType = options.domainType
        if !options.initiators.isEmpty { condition.initiatorDomains = options.initiators }
        if !options.excludedInitiators.isEmpty { condition.excludedInitiatorDomains = options.excludedInitiators }

        // DNR takes named types or excluded types, not both. With neither it
        // matches everything but the page itself, which is what a filter
        // without type options means.
        let named = options.types.subtracting(options.excludedTypes)
        var action = allow ? "allow" : "block"
        if !options.types.isEmpty {
            condition.resourceTypes = allResourceTypes.filter(named.contains)
            // `@@||site^$document` turns blocking off for the whole page.
            if allow, named.contains("main_frame"), named.isSubset(of: ["main_frame", "sub_frame"]) { action = "allowAllRequests" }
        } else if !options.excludedTypes.isEmpty {
            // Naming excluded types would bring the page itself in: keep it out.
            condition.excludedResourceTypes = allResourceTypes.filter { options.excludedTypes.contains($0) || $0 == "main_frame" }
        }
        let priority = allow ? Priority.allow : (options.important ? Priority.importantBlock : Priority.block)
        return ContentBlockingDNRRule(id: 0, priority: priority, action: .init(type: action), condition: condition)
    }
}

extension ContentBlockingHost {
    /// As `normalized`, for a filter's `domain=` and a hosts-file line: the
    /// host exactly as written, `www.` included.
    static func normalizedKeepingWWW(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains("/"), !text.contains(":"),
              var host = URLComponents(string: "https://" + text)?.encodedHost?.lowercased() else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return isHost(host) ? host : nil
    }
}

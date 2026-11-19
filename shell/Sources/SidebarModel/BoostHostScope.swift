import Foundation

public enum BoostHostMatch: String, Codable, Equatable, Sendable {
    case exact
    case registrable
}

public struct BoostHostRule: Codable, Equatable, Hashable, Sendable {
    public var host: String
    public var hostMatch: BoostHostMatch
    public var pathPrefix: String
    public var schemes: [String]

    public init(
        host: String,
        hostMatch: BoostHostMatch = .registrable,
        pathPrefix: String = "",
        schemes: [String] = ["https"]
    ) {
        self.host = host.lowercased()
        self.hostMatch = hostMatch
        self.pathPrefix = pathPrefix
        self.schemes = schemes.isEmpty ? ["https"] : schemes
    }
}

public enum BoostScopeRefusal: Equatable, Sendable {
    case unsupportedScheme
    case internalPage
    case emptyHost
}

/// Which pages a boost applies to. A rule's host is a site (its registrable
/// domain, for every host of the site) or one exact host.
///
/// What a site is comes from the engine's public suffix list where there is
/// one (`SiteNames`, CONTENT-BLOCKING.md §9). The shell's own guess
/// (`registrableDomain`, the last two or three labels) takes `web.app`,
/// `edu.au` or `or.jp` for a site, and a boost scoped to one of those runs on
/// every site under it; a boost from a file names its own scope and can
/// carry a script (security BO-01). With an answer a scope that is a suffix
/// is refused, a new boost is for the page's real site, and a rule matches
/// only pages of its real site. Without one the rules are the guess's, as
/// before.
public enum BoostScopeMatcher {
    private static let allowedSchemes: Set<String> = ["http", "https"]
    private static let refusedHosts: Set<String> = ["", "blank"]
    private static let refusedPrefixes = ["about:", "rearc:", "data:", "blob:", "file:", "javascript:"]

    public static func urlIsEligibleForBoosts(_ url: URL) -> Bool {
        scopeRefusal(for: url) == nil
    }

    public static func scopeRefusal(for url: URL) -> BoostScopeRefusal? {
        let scheme = (url.scheme ?? "").lowercased()
        if !allowedSchemes.contains(scheme) { return .unsupportedScheme }
        let absolute = url.absoluteString.lowercased()
        for prefix in refusedPrefixes where absolute.hasPrefix(prefix) { return .internalPage }
        if url.absoluteString == "about:blank" { return .internalPage }
        if url.host()?.isEmpty != false { return .emptyHost }
        return nil
    }

    public static func matches(scope rules: [BoostHostRule], url: URL, names: SiteNames? = .shared) -> Bool {
        guard urlIsEligibleForBoosts(url) else { return false }
        guard !rules.isEmpty else { return false }
        return rules.contains { matches(rule: $0, url: url, names: names) }
    }

    public static func matches(rule: BoostHostRule, url: URL, names: SiteNames? = .shared) -> Bool {
        guard urlIsEligibleForBoosts(url) else { return false }
        let scheme = (url.scheme ?? "").lowercased()
        guard rule.schemes.map({ $0.lowercased() }).contains(scheme) else { return false }
        guard let hostRaw = url.host()?.lowercased(), !hostRaw.isEmpty else { return false }
        let host = hostRaw.hasPrefix("xn--") ? hostRaw : hostRaw
        let hostOk: Bool
        if isIPLiteral(host) {
            hostOk = rule.hostMatch == .exact && host == rule.host.lowercased()
        } else if rule.hostMatch == .exact {
            hostOk = host == rule.host.lowercased()
        } else if names?.site(of: rule.host)?.isSuffix == true {
            // A scope that is a public suffix (`web.app`, kept from the
            // guess or brought by a file) is no page's site: it matches
            // nothing, whatever is known of the page.
            hostOk = false
        } else if let site = names?.site(of: host) {
            // The page's real site: a rule for example.co.uk holds on www.example.co.uk.
            hostOk = site.isOneSite && site.name == rule.host.lowercased()
        } else {
            hostOk = registrableDomain(host) == rule.host.lowercased()
                && registrableDomain(rule.host.lowercased()) == rule.host.lowercased()
        }
        guard hostOk else { return false }
        if rule.pathPrefix.isEmpty { return true }
        return pathHasPrefix(url.path, rule.pathPrefix)
    }

    /// The scope of a boost made on `url`'s page: the page's site.
    public static func defaultRule(forPage url: URL, names: SiteNames? = .shared) -> BoostHostRule? {
        guard let host = url.host()?.lowercased(), urlIsEligibleForBoosts(url) else { return nil }
        if let site = names?.site(of: host) {
            let scheme = (url.scheme ?? "https").lowercased()
            // An address is one host.
            if isIPLiteral(host) { return BoostHostRule(host: host, hostMatch: .exact, schemes: [scheme]) }
            // A page that sits on a public suffix itself (`github.io`) gets no
            // boost: a suffix is never a scope. A name with no suffix
            // (`localhost`) gets none either, as before.
            guard site.isOneSite else { return nil }
            return BoostHostRule(host: site.name, hostMatch: .registrable, schemes: [scheme])
        }
        let registrable = registrableDomain(host)
        guard registrable != host || host.split(separator: ".").count >= 2 else { return nil }
        if BoostPublicSuffixList.isSharedHostingRegistrableDomain(registrable) {
            return BoostHostRule(host: host, hostMatch: .exact, schemes: [(url.scheme ?? "https").lowercased()])
        }
        return BoostHostRule(host: registrable, hostMatch: .registrable, schemes: [(url.scheme ?? "https").lowercased()])
    }

    /// Whether a rule may be a boost's scope. Every boost passes through
    /// here, one from a file too (`BoostSecurity.validatePackage`).
    public static func validateRule(_ rule: BoostHostRule, names: SiteNames? = .shared) -> Bool {
        guard !rule.host.isEmpty, rule.host.count <= 253 else { return false }
        if rule.host.contains(":") || rule.host.contains("/") { return false }
        let banned = Set(["com", "co.uk", "org", "net"])
        if banned.contains(rule.host.lowercased()) { return false }
        let site = names?.site(of: rule.host)
        // A public suffix is nobody's site: not as a site, not as an exact host.
        if site?.isSuffix == true { return false }
        if rule.hostMatch == .registrable {
            if BoostPublicSuffixList.isSharedHostingRegistrableDomain(rule.host.lowercased()) {
                return false
            }
            if let site {
                // The rule must name a site: its host is its own registrable domain.
                guard site.isOneSite, site.name == rule.host.lowercased(), !isIPLiteral(rule.host) else { return false }
            } else if registrableDomain(rule.host) != rule.host.lowercased() {
                return false
            }
        }
        if !rule.pathPrefix.isEmpty, !rule.pathPrefix.hasPrefix("/") { return false }
        guard !rule.schemes.isEmpty else { return false }
        return rule.schemes.allSatisfy { allowedSchemes.contains($0.lowercased()) }
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        host.contains(":") || host.split(separator: ".").allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// Simplified eTLD+1: last two labels, or three when second label is a common public suffix token.
    public static func registrableDomain(_ host: String) -> String {
        let parts = host.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return host.lowercased() }
        let publicSuffixes = Set(["co", "com", "org", "net", "ac", "gov"])
        if parts.count >= 3, publicSuffixes.contains(parts[parts.count - 2]) {
            return parts.suffix(3).joined(separator: ".")
        }
        return parts.suffix(2).joined(separator: ".")
    }

    private static func pathHasPrefix(_ path: String, _ prefix: String) -> Bool {
        if path == prefix { return true }
        guard prefix.hasSuffix("/") || path.hasPrefix(prefix + "/") else {
            return path.hasPrefix(prefix) && path.count > prefix.count && path[path.index(path.startIndex, offsetBy: prefix.count)] == "/"
        }
        return path.hasPrefix(prefix)
    }
}

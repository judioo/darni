import Foundation

/// The site of a host by a real public suffix list
/// (docs/FEATURE-SPECS/CONTENT-BLOCKING.md §9).
public struct SiteName: Equatable, Sendable {
    /// The registrable domain of the host, private registries included
    /// (`someone.web.app`), or the host itself when it has none.
    public var name: String
    /// `name` is a registrable domain or an address: one site.
    public var isOneSite: Bool
    /// The host is itself a public suffix (`com`, `co.uk`, `web.app`):
    /// every site under it is another party's. Never the key of a rule, an
    /// exception or a scope.
    public var isSuffix: Bool

    public init(name: String, isOneSite: Bool, isSuffix: Bool = false) {
        self.name = name
        self.isOneSite = isOneSite
        self.isSuffix = isSuffix
    }
}

/// Where the shell asks for a site's name. The shell has no public suffix
/// list: `BoostScopeMatcher.registrableDomain` guesses from the last two or
/// three labels, and for a page on `someone.web.app` or `school.edu.au` the
/// guess is the suffix, which is every site under it (security CB-12, AG-05,
/// BO-01, BL-11). The engine has Chromium's list (`ReArcEngineCopySiteOfHost`,
/// ABI 1.69), and this is the one place that asks it.
///
/// `SidebarModel` cannot call the engine, so the Chromium side hands in the
/// call (`shared`, set once the engine is ready). Without one (WebKit, an
/// engine before 1.69, before the engine is ready) there is no answer, and
/// each user keeps its own narrower rule. Nothing goes back to the guess for
/// a key.
///
/// What it remembers are hosts of pages the person visited, private windows
/// included: a small number of answers, in memory only, never logged and
/// never written anywhere.
public final class SiteNames: @unchecked Sendable {
    /// The process's namer; nil until an engine that can answer is ready.
    /// Set and cleared on the main thread, by the Chromium host.
    nonisolated(unsafe) public static var shared: SiteNames?

    /// The answers kept. The same few hosts are asked again and again, and
    /// the list does not change while the app runs.
    public static let maxRemembered = 256
    /// An answer is a host and two flags; a longer reply is not one.
    public static let maxReplyBytes = 1024

    /// The engine's reply for a host, as its JSON; nil when it has none
    /// (not ready, another thread, a name it refuses).
    private let ask: (String) -> String?
    private let lock = NSLock()
    private var remembered: [String: SiteName] = [:]
    private var order: [String] = []

    public init(ask: @escaping (String) -> String?) {
        self.ask = ask
    }

    /// The site of `host`; nil when there is no answer to trust.
    public func site(of host: String) -> SiteName? {
        guard let asked = Self.normalized(host) else { return nil }
        if let known = lock.withLock({ remembered[asked] }) { return known }
        guard let reply = ask(asked), let answer = Self.decode(reply, asked: asked) else { return nil }
        lock.withLock {
            guard remembered[asked] == nil else { return }
            remembered[asked] = answer
            order.append(asked)
            if order.count > Self.maxRemembered { remembered[order.removeFirst()] = nil }
        }
        return answer
    }

    /// How many answers are kept (tests).
    var rememberedCount: Int { lock.withLock { remembered.count } }

    /// The name as it is asked: lower case, no trailing dot, a plain host.
    /// nil for anything else (a port, a path, an IPv6 literal).
    static func normalized(_ host: String) -> String? {
        var name = host.lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        return ContentBlockingHost.isHost(name) ? name : nil
    }

    private struct Reply: Decodable {
        var host: String
        var registrable: Bool
        var suffix: Bool?
    }

    /// The answer in `reply`, when it is one about `asked`.
    ///
    /// Some plain-looking names are addresses to the engine (`1.2` is
    /// `1.0.0.2`), and a name from a boost file or typed in Settings does
    /// not arrive in the engine's form. An answer is taken only when its
    /// name is the asked name, or the asked name ends with a dot and that
    /// name (security BL-12). The engine refuses such names too; this is
    /// the shell's own hold, in the one place every user goes through.
    static func decode(_ reply: String, asked: String) -> SiteName? {
        guard reply.utf8.count <= maxReplyBytes,
              let answer = try? JSONDecoder().decode(Reply.self, from: Data(reply.utf8)),
              ContentBlockingHost.isHost(answer.host),
              answer.host == asked || asked.hasSuffix("." + answer.host) else { return nil }
        let isSuffix = answer.suffix ?? false
        // One site and a suffix at once is no answer, and neither is a name
        // that is not one site and yet shorter than what was asked.
        guard !(answer.registrable && isSuffix), answer.registrable || answer.host == asked else { return nil }
        return SiteName(name: answer.host, isOneSite: answer.registrable, isSuffix: isSuffix)
    }
}

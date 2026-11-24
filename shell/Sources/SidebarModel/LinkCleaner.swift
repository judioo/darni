import Foundation

/// Arc's Copy URL "without any trackers": query parameters from the tracker
/// table in Arc 1.171.0's binary are removed before the link is copied
/// (docs/SHORTCUTS.md "Copy URL"). A name ending in `_` is a prefix; the rest
/// match exactly. The site groups follow the table's order after its
/// twitter.com / x.com entry; which site each later group belongs to is
/// inferred from the names (eBay, YouTube, Amazon). `clickIdentifiers` adds
/// what the table lacks and `needed` protects what a site uses itself.
/// Rule-based: a name is in a table or it stays.
public enum LinkCleaner {
    static let anywhere: Set<String> = [
        "_bta_c", "_bta_tid", "_ga", "_hsenc", "_hsmi", "_ke", "_openstat", "dm_i", "ef_id", "epik", "gclsrc",
        "gdffi", "gdfms", "gdftrk", "hsa_", "igsh", "matomo_", "mc_", "mkwid", "msclkid", "mtm_", "ns_",
        "oly_anon_id", "oly_enc_id", "otc", "pcrid", "piwik_", "pk_", "rb_clickid", "ref", "s_kwcid",
        "sb_referer_host", "soc_src", "soc_trk", "spm", "sr_", "stm_", "trk_", "utm_", "vero_",
        "cm_mmc", "fbclid", "gad_source", "gclid", "pla", "si", "trackingId", "mt", "mcid", "linkCode",
        "srsltid", "ocid", "trk", "ncid", "mtc", "srcid", "_pos", "_sid", "_ss", "share_id",
    ]

    /// Host suffix → extra names for that site.
    static let sites: [(hosts: [String], names: Set<String>)] = [
        (["twitter.com", "x.com"], ["t", "s"]),
        (["ebay.com", "ebay.co.uk", "ebay.de"], ["_trkparms", "_trksid", "_from", "hash", "_skw", "itmmeta", "itmprp"]),
        (["youtube.com", "youtu.be"], ["feature", "app", "source_ve_path"]),
        (["amazon.com", "amazon.co.uk", "amazon.de", "amazon.fr", "amazon.ca", "amazon.co.jp", "amazon.in"], [
            "_encoding", "ascsubtag", "pd_rd_", "pf", "pf_rd_", "psc", "tag", "ie", "hv", "content-id", "crid",
            "dib", "dib_tag", "keywords", "qid", "rnid", "s", "sprefix", "th",
        ]),
    ]

    /// Names Firefox and Brave strip from every link (their query-stripping
    /// lists, 2026) that Arc's table lacks: click and subscriber identifiers
    /// of ad and mail platforms, which no page needs to show itself.
    static let clickIdentifiers: Set<String> = [
        "__hsfp", "__hssc", "__hstc", "__s", "_bhlid", "_gl", "_kx", "bsft_clkid", "bsft_uid", "ck_subscriber_id",
        "dclid", "gbraid", "guce_referrer", "guce_referrer_sig", "hsCtaTracking", "igshid", "irclickid", "li_fat_id",
        "ml_subscriber", "ml_subscriber_hash", "oft_c", "oft_ck", "oft_d", "oft_id", "oft_ids", "oft_k", "oft_lk",
        "oft_sk", "s_cid", "ss_email_id", "ttclid", "twclid", "vgo_ee", "wbraid", "wickedid", "yclid", "ysclid",
    ]

    /// Host suffix → names the site needs, whatever the tables say. `ref` is
    /// a referrer tag on most of the web and a branch, tag or commit on a
    /// code host (github.com/codespaces/new?ref=main, GitLab's pipelines).
    static let needed: [(hosts: [String], names: Set<String>)] = [
        (["github.com", "gitlab.com", "bitbucket.org", "codeberg.org", "gitea.com", "sr.ht"], ["ref"]),
    ]

    /// The URL without tracking parameters, and whether any were removed.
    public static func clean(_ url: URL) -> (url: URL, removedTrackers: Bool) {
        guard let text = cleanedText(url.absoluteString), let cleaned = URL(string: text) else { return (url, false) }
        return (cleaned, true)
    }

    /// `link` without its tracking parameters, when it is one web link that
    /// has some; nil for anything else. Only whole `name=value` pieces of the
    /// query are cut out of the text: the scheme, host, path, fragment and
    /// every other parameter stay as they were written, byte for byte.
    public static func cleanedText(_ link: String) -> String? {
        guard !link.contains(where: \.isWhitespace), let url = URL(string: link),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        // RFC 3986: the query runs from the first "?" to the first "#".
        let fragment = link.firstIndex(of: "#") ?? link.endIndex
        guard let mark = link[..<fragment].firstIndex(of: "?") else { return nil }
        let pieces = link[link.index(after: mark)..<fragment].split(separator: "&", omittingEmptySubsequences: false)
        let trackers = anywhere.union(clickIdentifiers).union(names(in: sites, for: host))
        var stays = names(in: needed, for: host)
        // A self-hosted GitLab: its project pages sit under "/-/".
        if url.path.contains("/-/") { stays.insert("ref") }
        let kept = pieces.filter { piece in
            let raw = piece.prefix { $0 != "=" }
            let name = raw.removingPercentEncoding ?? String(raw)
            return stays.contains(name) || !matches(name, trackers)
        }
        guard kept.count != pieces.count else { return nil }
        let query = kept.joined(separator: "&")
        return String(link[..<mark]) + (query.isEmpty ? "" : "?" + query) + String(link[fragment...])
    }

    static func names(in table: [(hosts: [String], names: Set<String>)], for host: String) -> Set<String> {
        table.filter { group in
            group.hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }.reduce(into: Set<String>()) { $0.formUnion($1.names) }
    }

    static func matches(_ name: String, _ names: Set<String>) -> Bool {
        if names.contains(name) { return true }
        return names.contains { $0.hasSuffix("_") && name.hasPrefix($0) }
    }
}

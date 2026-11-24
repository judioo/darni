import XCTest
@testable import SidebarModel

/// Copy clean links: what `LinkCleaner` removes and, more to the point, what
/// it never touches.
final class LinkCleanerTests: XCTestCase {
    private func clean(_ link: String) -> String { LinkCleaner.cleanedText(link) ?? link }

    // MARK: Only known query parameters go (security's condition, 2026-11-24)

    func testHostPathFragmentAndOtherParametersSurviveByteForByte() throws {
        // An upper-case host, a port, escaped path pieces, a matrix parameter, values with "+" and
        // "%2B", an empty value, a bare name, a link inside a value and a fragment that looks like a query.
        let before = "https://Sub.Example.COM:8443/a%20b/c%2Fd;v=1/?q=a%2Bb+c&utm_source=news&empty=&flag"
            + "&redirect=https%3A%2F%2Fb.test%2F%3Futm_source%3Dy&gclid=1&q=again#frag?utm_source=z&x=1"
        let after = "https://Sub.Example.COM:8443/a%20b/c%2Fd;v=1/?q=a%2Bb+c&empty=&flag"
            + "&redirect=https%3A%2F%2Fb.test%2F%3Futm_source%3Dy&q=again#frag?utm_source=z&x=1"
        XCTAssertEqual(LinkCleaner.cleanedText(before), after)

        let result = LinkCleaner.clean(try XCTUnwrap(URL(string: before)))
        XCTAssertTrue(result.removedTrackers)
        XCTAssertEqual(result.url.absoluteString, after)

        let old = try XCTUnwrap(URLComponents(string: before)), new = try XCTUnwrap(URLComponents(string: after))
        XCTAssertEqual(new.scheme, old.scheme)
        XCTAssertEqual(new.percentEncodedHost, old.percentEncodedHost)
        XCTAssertEqual(new.port, old.port)
        XCTAssertEqual(new.percentEncodedPath, old.percentEncodedPath)
        XCTAssertEqual(new.percentEncodedFragment, old.percentEncodedFragment)
        let removed: Set<String> = ["utm_source", "gclid"]
        XCTAssertEqual(new.percentEncodedQueryItems, old.percentEncodedQueryItems?.filter { !removed.contains($0.name) },
                       "the other parameters, in their order and as they were written")
    }

    func testTheTextOutsideTheRemovedPiecesIsNeverRewritten() {
        // Whatever is removed, the result is the link with whole "name=value" pieces cut out of its query.
        let links = [
            "https://user:pw@a.test/p?utm_source=x&id=4",
            "https://xn--bcher-kva.example/s%C3%B6k?fbclid=1&q=%E2%9C%93",
            "http://[2001:db8::1]:8080/p?gclid=1&a=b",
            "https://a.test/p/?a=1&utm_medium=x&b=%26%3D&c=d%20e",
            "https://a.test//double//slash/./..?fbclid=1&k=v",
            "https://a.test/p?utm_source=x#",
            "https://a.test/?utm_source=x&&a=1&",
        ]
        for link in links {
            guard let cleaned = LinkCleaner.cleanedText(link) else { XCTFail("\(link) kept its trackers"); continue }
            let mark = link.firstIndex(of: "?")!, end = link.firstIndex(of: "#") ?? link.endIndex
            XCTAssertTrue(cleaned.hasPrefix(link[..<mark]), "\(link): everything before the query stays")
            XCTAssertTrue(cleaned.hasSuffix(link[end...]), "\(link): the fragment stays")
            let pieces = Set(link[link.index(after: mark)..<end].split(separator: "&", omittingEmptySubsequences: false).map(String.init))
            let cleanedEnd = cleaned.firstIndex(of: "#") ?? cleaned.endIndex
            // Nothing left of the query: the question mark went with it.
            guard let cleanedMark = cleaned[..<cleanedEnd].firstIndex(of: "?") else { continue }
            for piece in cleaned[cleaned.index(after: cleanedMark)..<cleanedEnd].split(separator: "&", omittingEmptySubsequences: false) {
                XCTAssertTrue(pieces.contains(String(piece)), "\(link): '\(piece)' was not in the link")
            }
        }
        XCTAssertEqual(clean("https://user:pw@a.test/p?utm_source=x&id=4"), "https://user:pw@a.test/p?id=4")
        XCTAssertEqual(clean("https://a.test/p?utm_source=x#"), "https://a.test/p#")
        XCTAssertEqual(clean("https://a.test/?utm_source=x&&a=1&"), "https://a.test/?&a=1&")
        XCTAssertEqual(clean("https://a.test/p?utm_source=x&"), "https://a.test/p", "nothing left: no question mark")
        XCTAssertEqual(clean("https://a.test/p?a=%2B&fbclid=1"), "https://a.test/p?a=%2B", "an escaped plus stays escaped")
    }

    func testAnEscapedNameIsStillItsName() {
        XCTAssertEqual(clean("https://a.test/p?utm%5Fsource=x&id=4"), "https://a.test/p?id=4")
    }

    func testOnlyWebLinksAreCleaned() {
        for other in [
            "mailto:someone@a.test?subject=hi&utm_source=x", "file:///tmp/a.html?utm_source=x", "about:blank",
            "chrome://settings/?utm_source=x", "javascript:void(0)", "a.test/p?utm_source=x", "utm_source=x",
            "see https://a.test/p?utm_source=x", "https://a.test/p?utm_source=x and more", "", "https://a.test/p",
            "https://a.test/p#frag?utm_source=x",
        ] {
            XCTAssertNil(LinkCleaner.cleanedText(other), other)
        }
        let mail = URL(string: "mailto:someone@a.test?subject=hi&utm_source=x")!
        XCTAssertEqual(LinkCleaner.clean(mail).url, mail)
        XCTAssertFalse(LinkCleaner.clean(mail).removedTrackers)
    }

    // MARK: The table

    func testEveryClickIdentifierIsRemoved() {
        XCTAssertFalse(LinkCleaner.clickIdentifiers.isEmpty)
        for name in LinkCleaner.clickIdentifiers.sorted() {
            XCTAssertEqual(clean("https://a.test/p?id=4&\(name)=v1"), "https://a.test/p?id=4", name)
            XCTAssertEqual(clean("https://a.test/p?\(name)=v1"), "https://a.test/p", name)
        }
    }

    func testTheTrackersNamedForThisReleaseAreRemoved() {
        // Mailchimp, Klaviyo, Yandex, X, LinkedIn, Wicked Reports, TikTok, DoubleClick, Google Ads on iOS,
        // Drip, HubSpot, Omeda and Vero: in Arc's table (a prefix among them) or in `clickIdentifiers`.
        let names = [
            "mc_eid", "mc_cid", "_kx", "_ke", "yclid", "ysclid", "twclid", "li_fat_id", "wickedid", "ttclid", "dclid", "gbraid",
            "wbraid", "__s", "__hssc", "__hstc", "__hsfp", "_hsenc", "_hsmi", "hsCtaTracking", "oly_anon_id", "oly_enc_id",
            "vero_id", "vero_conv", "igshid", "igsh", "msclkid", "fbclid", "gclid", "utm_source", "utm_id", "_gl", "s_cid",
        ]
        for name in names {
            XCTAssertEqual(clean("https://shop.test/item/9?\(name)=abc&size=m#reviews"), "https://shop.test/item/9?size=m#reviews", name)
        }
    }

    func testParametersAPageNeedsStay() {
        // Names that look like the table's without being in it, and everyday ones.
        let kept = [
            "https://a.test/search?q=arc&page=2&sort=new&lang=en&id=7&v=3&tab=repositories",
            "https://www.youtube.com/watch?v=abc&t=42s&list=PL1&index=3",
            "https://a.test/p?utm=1&utmsource=2&reference=3&refs=4&referrer=5&mc=6&sid=7&source=8&gclid2=9&xfbclid=10",
            "https://a.test/p?s=20&t=abc&tag=x&keywords=y&th=1&feature=z&hash=h&_from=f",
            "https://a.test/p?__ss=1&_k=2&hsa=3&pk=4&oft=5&dcl=6&si_=7&mt_=8",
            "https://maps.test/dir?origin=a&destination=b&token=abc.def&signature=xyz&expires=99",
        ]
        for link in kept {
            XCTAssertNil(LinkCleaner.cleanedText(link), link)
        }
    }

    func testRefIsABranchOnCodeHosts() {
        // Elsewhere "ref" says who sent the reader; on a code host it names a branch, tag or commit.
        XCTAssertEqual(clean("https://www.producthunt.test/posts/darni?ref=producthunt"), "https://www.producthunt.test/posts/darni")
        let needed = [
            "https://github.com/codespaces/new?hide_repo_select=true&ref=main&repo=42",
            "https://api.github.com/repos/o/r/contents/README.md?ref=v1.2.0",
            "https://gitlab.com/group/project/-/pipelines?ref=release&scope=finished",
            "https://codeberg.org/o/r/actions?ref=main",
            "https://bitbucket.org/o/r/addon/pipelines/home?ref=main",
            "https://git.company.test/group/project/-/pipelines/new?ref=hotfix",
        ]
        for link in needed {
            XCTAssertNil(LinkCleaner.cleanedText(link), link)
        }
        XCTAssertEqual(clean("https://github.com/o/r?ref=main&utm_source=news"), "https://github.com/o/r?ref=main",
                       "the trackers beside it still go")
        XCTAssertEqual(clean("https://notgithub.com/o/r?ref=main"), "https://notgithub.com/o/r", "a host that only ends in the name is another site")
    }

    func testSiteNamesBelongToTheirSites() {
        XCTAssertEqual(clean("https://x.com/arc/status/1?s=20&t=abc"), "https://x.com/arc/status/1")
        XCTAssertEqual(clean("https://mobile.twitter.com/arc/status/1?s=20&lang=en"), "https://mobile.twitter.com/arc/status/1?lang=en")
        XCTAssertEqual(clean("https://www.amazon.co.uk/dp/B0?tag=aff-21&psc=1&colour=red"), "https://www.amazon.co.uk/dp/B0?colour=red")
        XCTAssertEqual(clean("https://youtu.be/abc?si=XYZ&t=42"), "https://youtu.be/abc?t=42")
        XCTAssertEqual(clean("https://www.ebay.com/itm/1?_trksid=p1&hash=item1&var=2"), "https://www.ebay.com/itm/1?var=2")
    }

    // MARK: The setting

    func testCleanLinksAreOnUntilSwitchedOff() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "rearc-clean-links-\(UUID().uuidString)"))
        XCTAssertTrue(CleanLinksPreference.isEnabled(in: defaults))
        defaults.set(false, forKey: CleanLinksPreference.defaultsKey)
        XCTAssertFalse(CleanLinksPreference.isEnabled(in: defaults))
    }
}

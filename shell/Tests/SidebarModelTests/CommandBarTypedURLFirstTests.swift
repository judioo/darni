import Foundation
import XCTest
@testable import SidebarModel

/// A typed or edited address opens itself first; Switch to Tab rows for
/// matching tabs follow it (owner's report, 2026-11-20: editing a Gmail
/// address offered only Switch to Tab, and Return never opened the address).
final class CommandBarTypedURLFirstTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func url(_ string: String) -> URL { URL(string: string)! }

    private func gmailStore() -> (store: SidebarStore, u0: Tab, u3: Tab) {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let u0 = store.addTab(kind: .today, title: "Inbox (9) - udo@imara.ae - Imara Co Mail",
                              url: url("https://mail.google.com/mail/u/0/#inbox"))
        let u3 = store.addTab(kind: .today, title: "Inbox (7) - udo@assured.living - Assured Co Mail",
                              url: url("https://mail.google.com/mail/u/3/#inbox"))
        return (store, u0, u3)
    }

    func testTypedFullURLWithAnOpenTabOpensTheAddressFirst() {
        let (store, _, u3) = gmailStore()
        let typed = "https://mail.google.com/mail/u/3/#inbox"
        let results = CommandBarSearch.results(for: typed, in: store, now: now)
        XCTAssertEqual(results.first?.kind, .openURL, "Return opens the typed address")
        XCTAssertEqual(results.first?.destinationURL, url(typed))
        XCTAssertEqual(results.dropFirst().first?.kind, .openTab, "Switch to Tab is one ↓ away")
        XCTAssertEqual(results.dropFirst().first?.tabID, u3.id)
        XCTAssertEqual(results.filter { $0.kind == .openURL && $0.destinationURL == url(typed) }.count, 1)
    }

    func testAnotherAccountsTabIsNotTheTypedPage() {
        let (store, u0, u3) = gmailStore()
        // Edited from u/0 to u/3: u/3's tab is the page typed, u/0's is not.
        let results = CommandBarSearch.results(for: "https://mail.google.com/mail/u/3/#inbox", in: store, now: now)
        XCTAssertEqual(results.first?.kind, .openURL)
        XCTAssertEqual(results.dropFirst().first?.tabID, u3.id)
        XCTAssertFalse(results.prefix(2).contains { $0.tabID == u0.id }, "u/0 is another account's page")

        // Only u/0 open: u/3 still opens, and u/0's tab never leads.
        let onlyU0 = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let other = onlyU0.addTab(kind: .today, title: "Inbox (9) - udo@imara.ae - Imara Co Mail",
                                  url: url("https://mail.google.com/mail/u/0/#inbox"))
        let alone = CommandBarSearch.results(for: "https://mail.google.com/mail/u/3/#inbox", in: onlyU0, now: now)
        XCTAssertEqual(alone.first?.destinationURL, url("https://mail.google.com/mail/u/3/#inbox"))
        XCTAssertNotEqual(alone.first?.tabID, other.id)

        // A shared prefix lists both tabs, after the Open row.
        let prefix = CommandBarSearch.results(for: "https://mail.google.com/mail/u/", in: store, now: now)
        XCTAssertEqual(prefix.first?.kind, .openURL)
        XCTAssertEqual(Set(prefix.filter { $0.kind == .openTab }.compactMap(\.tabID)), [u0.id, u3.id])
    }

    func testTypedURLWithoutSchemeStillLeadsAndItsTabFollows() {
        let (store, _, u3) = gmailStore()
        // "mail.google.com/mail/u/3/" matches the tab only inside its address,
        // a weak match, but it is the typed page: listed right after.
        let results = CommandBarSearch.results(for: "mail.google.com/mail/u/3/", in: store, now: now)
        XCTAssertEqual(results.first?.kind, .openURL)
        XCTAssertEqual(results.first?.destinationURL?.host(), "mail.google.com")
        XCTAssertEqual(results.dropFirst().first?.tabID, u3.id)
    }

    func testTypedBareDomainOpensFirst() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let home = store.addTab(kind: .today, title: "GitHub", url: url("https://github.com/"))
        let repo = store.addTab(kind: .today, title: "judioo/rearc", url: url("https://github.com/judioo/rearc"))
        let results = CommandBarSearch.results(for: "github.com", in: store, now: now)
        XCTAssertEqual(results.first?.kind, .openURL)
        XCTAssertEqual(results.first?.destinationURL?.host(), "github.com")
        XCTAssertEqual(results.dropFirst().first?.tabID, home.id, "the tab on exactly that page comes next")
        XCTAssertTrue(results.contains { $0.tabID == repo.id }, "other tabs on the site are still listed")
        XCTAssertFalse(results.contains { $0.kind == .search }, "an address, not a search")
    }

    func testSearchWordsKeepTabsFirst() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let mail = store.addTab(kind: .today, title: "Inbox - Mail", url: url("https://mail.google.com/mail/u/0/#inbox"))
        for words in ["inbox", "mail"] {
            let results = CommandBarSearch.results(for: words, in: store, now: now)
            XCTAssertEqual(results.first?.tabID, mail.id, "'\(words)': Switch to Tab leads a search")
            XCTAssertFalse(results.contains { $0.kind == .openURL }, "'\(words)' is not an address")
            XCTAssertTrue(results.contains { $0.kind == .search })
        }
    }

    func testUntouchedLocationPrefillKeepsTheTabsOwnRow() {
        // ⌘L fills in the tab's own address. Untouched, Return picks the tab
        // itself (Switch to Tab on the tab on screen): no reload, as before.
        let (store, u0, _) = gmailStore()
        let prefill = u0.url.absoluteString
        let untouched = CommandBarSearch.results(for: prefill, in: store, typedAddressFirst: false, now: now)
        XCTAssertEqual(untouched.first?.tabID, u0.id)
        XCTAssertFalse(untouched.contains { $0.kind == .openURL && $0.destinationURL == u0.url }, "as before: the page is the tab")
        // Any edit, even back to an address an open tab shows, opens it.
        let edited = CommandBarSearch.results(for: prefill, in: store, now: now)
        XCTAssertEqual(edited.first?.kind, .openURL)
        XCTAssertEqual(edited.dropFirst().first?.tabID, u0.id)
    }

    func testTypedAddressIsNotRepeatedAsHistoryOrSuggestion() {
        let (store, _, _) = gmailStore()
        let typed = "https://mail.google.com/mail/u/3/#inbox"
        var history = VisitHistory()
        history.recordVisit(url: url(typed), title: "Inbox", at: now)
        history.recordVisit(url: url("https://mail.google.com/mail/u/3/#sent"), title: "Sent", at: now)
        let live = CommandBarLiveResults(query: typed, suggestions: [
            SearchSuggestion(text: "u3 inbox", destinationURL: url("https://mail.google.com/mail/u/3/")),
        ], classification: .url(url(typed)))
        let results = CommandBarSearch.results(for: typed, in: store, history: history, live: live, now: now)
        XCTAssertEqual(results.first?.kind, .openURL)
        XCTAssertFalse(results.contains { $0.kind == .history || $0.kind == .suggestion },
                       "the typed page (fragment aside) is listed once")
    }

    func testInlineCompletionKeepsATypedAddress() {
        // A visited "google.com.au" ranks ahead of the bundled "google.com".
        let hosts = ["google.com.au", "github.community", "google.com", "github.com"]
        XCTAssertNil(InlineDomainCompletion.complete("google.com", candidates: hosts), "a known host typed in full stays")
        XCTAssertNil(InlineDomainCompletion.complete("https://google.com", candidates: hosts))
        XCTAssertNil(InlineDomainCompletion.complete("github.com", candidates: hosts))
        XCTAssertNil(InlineDomainCompletion.complete("https://mail.google.com/mail/u/3/#inbox", candidates: ["mail.google.com.evil"]))
        XCTAssertNil(InlineDomainCompletion.complete("google.com?q=x", candidates: ["google.com.au"]))
        XCTAssertNil(InlineDomainCompletion.complete("google.com#top", candidates: ["google.com.au"]))
        XCTAssertEqual(InlineDomainCompletion.complete("goo", candidates: hosts), "google.com.au", "a partial host still completes")
        XCTAssertEqual(InlineDomainCompletion.complete("https://git", candidates: hosts), "github.community")
    }

    func testInlineCompletionOfAPartialHostKeepsItsOrder() {
        // "github.c" completing to github.com: the field shows the completion,
        // and the rows stay as they were for it.
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let home = store.addTab(kind: .today, title: "GitHub", url: url("https://github.com/"))
        let results = CommandBarSearch.results(for: "github.c", in: store, inlineCompletion: "github.com", now: now)
        XCTAssertEqual(results.first?.id, "inline-github.com", "Return goes where the field shows")
        XCTAssertEqual(results.first?.destinationURL, url("https://github.com/"))
        XCTAssertFalse(results.prefix(1).contains { $0.destinationURL?.host() == "github.c" })
        _ = home // the same page as the completion: listed once, as before
    }
}

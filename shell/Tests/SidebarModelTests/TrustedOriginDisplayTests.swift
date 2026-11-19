import XCTest
@testable import SidebarModel

/// Security RC-0.1.0-564 S-02 (the auto-hiding bar shows a new origin) and RC-0.1.0-544 N-06
/// (long hosts keep their real domain in prompts).
final class TrustedOriginDisplayTests: XCTestCase {
    func testAnOriginChangeRevealsTheBarForAFewSeconds() {
        var state = AddressBarVisibility(autoHideEnabled: true)
        state.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: false, now: 0)
        XCTAssertFalse(state.isRevealed)
        state.reveal(for: AddressBarVisibility.originRevealDuration, now: 10)
        XCTAssertTrue(state.isRevealed)
        // Pointer moves elsewhere: the reveal is not cut short.
        state.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: false, now: 10.5)
        state.hideIfDue(at: 11)
        XCTAssertTrue(state.isRevealed)
        // Hovering the bar and leaving early keeps it until the reveal ends.
        state.update(autoHideEnabled: true, pointer: .toolbar, hasKeyboardFocus: false, now: 11)
        state.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: false, now: 11.2)
        state.hideIfDue(at: 11.6)
        XCTAssertTrue(state.isRevealed)
        state.hideIfDue(at: 10 + AddressBarVisibility.originRevealDuration)
        XCTAssertFalse(state.isRevealed)
        XCTAssertNil(state.revealedUntil)
    }

    func testRevealIsANoOpWithAFixedBar() {
        var state = AddressBarVisibility(autoHideEnabled: false)
        state.reveal(for: 3, now: 0)
        XCTAssertNil(state.revealedUntil)
        XCTAssertNil(state.hideDeadline)
    }

    func testAPromptHoldsTheBarLikeFocus() {
        var state = AddressBarVisibility(autoHideEnabled: true)
        // The container treats a page prompt as focus: shown with no deadline while it is up.
        state.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: true, now: 0)
        state.hideIfDue(at: 100)
        XCTAssertTrue(state.isRevealed)
        state.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: false, now: 100)
        XCTAssertEqual(state.hideDeadline, 100 + AddressBarVisibility.hideDelay)
    }

    func testLongHostsKeepTheirRegistrableDomain() {
        let host = "accounts.google.com.verify-session.evil.example"
        let short = PageOrigin.shortenedHost(host)
        XCTAssertTrue(short.hasSuffix("evil.example"), short)
        XCTAssertTrue(short.hasPrefix("…"), short)
        XCTAssertFalse(short.contains("google"), short)
        XCTAssertLessThanOrEqual(short.count, 36)
        XCTAssertEqual(PageOrigin.shortenedHost("meet.google.com"), "meet.google.com", "short hosts are untouched")
        let insecure = PageOrigin.shortenedHost("http://login.bank.example.attacker-controlled-subdomain.co.uk:8443")
        XCTAssertTrue(insecure.hasPrefix("http://…"), insecure)
        XCTAssertTrue(insecure.hasSuffix(".co.uk:8443"), insecure)
        // A registrable domain longer than the limit is still shown whole, with one label more.
        let long = "b.a.\(String(repeating: "x", count: 60)).example"
        XCTAssertEqual(PageOrigin.shortenedHost(long), "…a.\(String(repeating: "x", count: 60)).example")
        // Security AG-05: a suffix the guess does not know never stands for the site.
        let tenant = "accounts-google-com-sign-in-verify.web.app"
        XCTAssertEqual(PageOrigin.shortenedHost(tenant), tenant)
        let deep = "login.accounts-google-com-sign-in-verify.web.app"
        XCTAssertEqual(PageOrigin.shortenedHost(deep), "…accounts-google-com-sign-in-verify.web.app")
    }

    /// With the engine's public suffix list (§9 of CONTENT-BLOCKING.md) the
    /// labels always kept are the site's own, exactly: also where the suffix
    /// has three labels and the guess reads it as two, which the one extra
    /// label of the interim rule does not reach.
    func testWithTheEnginesSiteNamesALongHostKeepsExactlyItsSite() {
        let bucket = "\(String(repeating: "b", count: 30)).s3.amazonaws.com"
        let school = "\(String(repeating: "s", count: 30)).k12.ca.us"
        let names = SiteNames { host in
            for suffix in ["s3.amazonaws.com", "k12.ca.us", "web.app"] where host.hasSuffix("." + suffix) {
                let label = host.dropLast(suffix.count + 1).split(separator: ".").last ?? ""
                return #"{"host":"\#(label).\#(suffix)","registrable":true,"suffix":false}"#
            }
            if host.hasSuffix("evil.example") { return #"{"host":"evil.example","registrable":true,"suffix":false}"# }
            if host == "web.app" { return #"{"host":"web.app","registrable":false,"suffix":true}"# }
            return nil
        }
        // The interim rule loses the site's label here; the engine's answer keeps it.
        XCTAssertEqual(PageOrigin.shortenedHost("login.\(bucket)", names: nil), "…s3.amazonaws.com")
        XCTAssertEqual(PageOrigin.shortenedHost("login.\(bucket)", names: names), "…\(bucket)")
        XCTAssertEqual(PageOrigin.shortenedHost("login.\(school)", names: nil), "…k12.ca.us")
        XCTAssertEqual(PageOrigin.shortenedHost("login.\(school)", names: names), "…\(school)")
        // Where the interim rule already kept the site, nothing changes but the one label it no longer needs.
        let deep = "login.accounts-google-com-sign-in-verify.web.app"
        XCTAssertEqual(PageOrigin.shortenedHost(deep, names: names), "…accounts-google-com-sign-in-verify.web.app")
        let phish = PageOrigin.shortenedHost("accounts.google.com.verify-session.evil.example", names: names)
        XCTAssertTrue(phish.hasPrefix("…") && phish.hasSuffix("evil.example") && !phish.contains("google") && phish.count <= 36, phish)
        // A port and an http:// prefix are cut off before the name is asked, and put back.
        XCTAssertEqual(PageOrigin.shortenedHost("http://login.\(bucket):8443", names: names), "http://…\(bucket):8443")
        // A name with no answer keeps the interim rule; a short host is untouched either way.
        XCTAssertEqual(PageOrigin.shortenedHost("b.a.\(String(repeating: "x", count: 60)).example", names: names), "…a.\(String(repeating: "x", count: 60)).example")
        XCTAssertEqual(PageOrigin.shortenedHost("meet.google.com", names: names), "meet.google.com")
    }
}

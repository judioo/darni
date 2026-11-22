import JavaScriptCore
import Testing
@testable import ReArc

/// The history swipe's edge probe, run in JavaScriptCore against a small fake
/// page. The engine-level check, on real pages with shadow roots, is self-test
/// step 14a (`historySwipeChecks`).
struct HistorySwipeEdgeScriptTests {
    /// A page whose root holds one child under the point. `childStyle` and
    /// `rootStyle` are `getComputedStyle` results; `shadow` puts the child
    /// inside an open shadow root of a custom element (`X-APP`), as on YouTube.
    private func edges(scrollLeft: Int = 0, range: Int = 0, direction: String = "ltr",
                       childBehavior: String = "auto", rootBehavior: String = "auto", overflowX: String = "auto",
                       nested: Bool = false, tag: String = "DIV", shadow: Bool = false,
                       closedShadowHost: Bool = false) throws -> [String: Bool] {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var innerWidth = 800, innerHeight = 600;
        function ShadowRoot(host) { this.host = host; }
        var root = {tagName: 'HTML', clientWidth: 800, scrollWidth: 800, scrollLeft: 0, parentElement: null,
                    style: {direction: '\(direction)', overflowX: 'visible', overscrollBehaviorX: '\(rootBehavior)'}};
        var child = {tagName: '\(tag)', clientWidth: 100, scrollWidth: \(100 + range), scrollLeft: \(scrollLeft),
                     style: {direction: '\(direction)', overflowX: '\(overflowX)', overscrollBehaviorX: '\(childBehavior)'}};
        var top = child;
        if (\(shadow)) {
          var host = {tagName: 'X-APP', clientWidth: 800, scrollWidth: 800, scrollLeft: 0, parentElement: root,
                      style: {direction: 'ltr', overflowX: 'visible', overscrollBehaviorX: 'auto'}};
          var shadowRoot = new ShadowRoot(host);
          host.shadowRoot = {elementFromPoint: function() { return child; }};
          child.parentElement = null;
          child.parentNode = shadowRoot;
          top = host;
        } else if (\(closedShadowHost)) {
          // A closed shadow root: the host is all the page can see.
          child.tagName = 'YTD-APP';
          child.shadowRoot = null;
          child.parentElement = root;
        } else {
          child.parentElement = root;
        }
        var document = {documentElement: root, scrollingElement: \(nested ? "root" : "child"),
                        elementFromPoint: function() { return top; }};
        function getComputedStyle(node) { return node.style; }
        """)
        return try #require(context.evaluateScript(HistorySwipeEdgeScript.source(x: 0.5, y: 0.5))?.toDictionary() as? [String: Bool])
    }

    @Test func rootAndNestedScrollersMustBeAtTheDirectionalEdge() throws {
        #expect(try edges() == ["back": true, "forward": true])
        #expect(try edges(scrollLeft: 0, range: 100) == ["back": true, "forward": false])
        #expect(try edges(scrollLeft: 100, range: 100) == ["back": false, "forward": true])
        #expect(try edges(scrollLeft: 50, range: 100, nested: true) == ["back": false, "forward": false])
        #expect(try edges(scrollLeft: -100, range: 100, direction: "rtl") == ["back": true, "forward": false])
        #expect(try edges(scrollLeft: 0, range: 100, direction: "rtl") == ["back": false, "forward": true])
    }

    /// `overscroll-behavior-x` stops a swipe on the root, and on a horizontal
    /// scroller; on any other element it has no effect, as in Chrome.
    @Test func overscrollBehaviourCountsOnlyOnTheRootAndOnHorizontalScrollers() throws {
        #expect(try edges(rootBehavior: "contain") == ["back": false, "forward": false])
        #expect(try edges(rootBehavior: "none") == ["back": false, "forward": false])
        #expect(try edges(childBehavior: "contain", nested: true) == ["back": true, "forward": true],
                "contain on an element that does not scroll sideways changes nothing")
        #expect(try edges(scrollLeft: 0, range: 100, childBehavior: "contain", nested: true) == ["back": false, "forward": false],
                "contain on a horizontal scroller keeps the swipe in it")
        #expect(try edges(range: 100, overflowX: "hidden", nested: true) == ["back": true, "forward": true],
                "content clipped with overflow hidden is not a scroller")
    }

    @Test func embeddedDocumentsRejectSwipes() throws {
        #expect(try edges(tag: "IFRAME") == ["back": false, "forward": false])
        #expect(try edges(tag: "EMBED") == ["back": false, "forward": false])
    }

    /// Custom elements are ordinary elements: a swipe over YouTube's or
    /// GitHub's app shell goes back (owner, 2026-11-21: it went to the page).
    @Test func customElementsAndShadowRootsAreWalkedThrough() throws {
        #expect(try edges(closedShadowHost: true) == ["back": true, "forward": true])
        #expect(try edges(nested: true, shadow: true) == ["back": true, "forward": true])
        #expect(try edges(scrollLeft: 50, range: 100, nested: true, shadow: true) == ["back": false, "forward": false],
                "a scroller inside an open shadow root holds the swipe until it reaches its edge")
        #expect(try edges(scrollLeft: 0, range: 100, nested: true, shadow: true) == ["back": true, "forward": false])
    }
}

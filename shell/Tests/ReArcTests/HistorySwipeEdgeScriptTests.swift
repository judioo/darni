import JavaScriptCore
import Testing
@testable import ReArc

/// The edge probe in a small fake page: a root and one element under the point.
/// The self-test runs the same probe on a real page (step 14a, `/swipe-edges`).
struct HistorySwipeEdgeScriptTests {
    /// `behavior` is the element's `overscroll-behavior-x`, `rootBehavior` the root's.
    /// `nested`: the root scrolls the page, so the element is an inner scroller.
    /// `shadowScroller`: the element hosts an open shadow root whose scroller,
    /// with this `scrollLeft` and a range of 100, is under the point.
    private func edges(scrollLeft: Int = 0, range: Int = 0, direction: String = "ltr",
                       behavior: String = "auto", rootBehavior: String = "auto", nested: Bool = false,
                       tag: String = "DIV", shadowScroller: Int? = nil) throws -> [String: Bool] {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var innerWidth = 800, innerHeight = 600;
        function ShadowRoot() {}
        var root = {tagName: 'HTML', clientWidth: 800, scrollWidth: 800, scrollLeft: 0, parentElement: null, parentNode: null};
        var child = {tagName: '\(tag)', clientWidth: 100, scrollWidth: \(100 + range), scrollLeft: \(scrollLeft),
                     parentElement: root, parentNode: root};
        var document = {documentElement: root, scrollingElement: \(nested ? "root" : "child"),
                        elementFromPoint: function() { return child; }};
        var inner = null;
        if (\(shadowScroller.map(String.init) ?? "null") !== null) {
          var shadow = new ShadowRoot();
          shadow.host = child;
          inner = {tagName: 'DIV', clientWidth: 100, scrollWidth: 200, scrollLeft: \(shadowScroller ?? 0),
                   parentElement: null, parentNode: shadow};
          shadow.elementFromPoint = function() { return inner; };
          child.shadowRoot = shadow;
        }
        function getComputedStyle(node) {
          return {direction: '\(direction)', overflowX: 'auto',
                  overscrollBehaviorX: node === root ? '\(rootBehavior)' : node === child ? '\(behavior)' : 'auto'};
        }
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

    @Test func overscrollBehaviorStopsTheSwipeOnlyWhereChromeHonoursIt() throws {
        // On an inner scroller that would chain on to the page.
        #expect(try edges(scrollLeft: 0, range: 100, behavior: "contain", nested: true) == ["back": false, "forward": false])
        // On an element that does not scroll sideways it has no effect.
        #expect(try edges(behavior: "contain", nested: true) == ["back": true, "forward": true])
        // On the root it stops the page's swipe.
        #expect(try edges(rootBehavior: "none", nested: true) == ["back": false, "forward": false])
    }

    @Test func embeddedDocumentsRejectSwipesAndCustomElementsDoNot() throws {
        #expect(try edges(tag: "IFRAME") == ["back": false, "forward": false])
        // YouTube and GitHub are built from custom elements (owner, 2026-11-21).
        #expect(try edges(nested: true, tag: "YT-APP") == ["back": true, "forward": true])
    }

    @Test func theWalkGoesIntoOpenShadowRootsAndBackOutThroughTheHost() throws {
        #expect(try edges(nested: true, tag: "X-CAROUSEL", shadowScroller: 50) == ["back": false, "forward": false])
        #expect(try edges(nested: true, tag: "X-CAROUSEL", shadowScroller: 0) == ["back": true, "forward": false])
        // Out through the host: the host's own overscroll-behavior still counts on the way up.
        #expect(try edges(range: 100, behavior: "contain", nested: true, tag: "X-CAROUSEL", shadowScroller: 0)
            == ["back": false, "forward": false])
    }
}

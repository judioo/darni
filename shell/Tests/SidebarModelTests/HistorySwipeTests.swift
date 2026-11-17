import Testing
@testable import SidebarModel

struct HistorySwipeTests {
    let edges = HistorySwipe.Edges(back: true, forward: true)

    @Test func commitsBackAndForwardAtThreshold() {
        for x in [50.0, -50.0] {
            var swipe = HistorySwipe()
            let first = swipe.handle(phase: .began, x: x, y: 1, edges: edges, canGoBack: true, canGoForward: true)
            #expect(first.consumes)
            #expect(first.progress == 0.5)
            #expect(first.direction == (x > 0 ? .back : .forward))
            _ = swipe.handle(phase: .changed, x: x, y: 0, edges: edges, canGoBack: true, canGoForward: true)
            #expect(swipe.handle(phase: .ended, x: 0, y: 0, edges: edges, canGoBack: true, canGoForward: true).commit == first.direction)
            #expect(swipe.handle(phase: .momentum, x: 500, y: 0, edges: edges, canGoBack: true, canGoForward: true).commit == nil)
        }
    }

    @Test func pageConsumptionAndVerticalStartRejectWholeGesture() {
        for (x, y, edge) in [(20.0, 0.0, false), (3.0, 10.0, true), (10.0, 10.0, true)] {
            var swipe = HistorySwipe()
            #expect(!swipe.handle(phase: .began, x: x, y: y, edges: .init(back: edge, forward: edge), canGoBack: true, canGoForward: true).consumes)
            #expect(!swipe.handle(phase: .changed, x: 300, y: 0, edges: edges, canGoBack: true, canGoForward: true).consumes)
        }
    }

    @Test func zeroBeginWaitsForDirectionAndKeepsInitialEdges() {
        var swipe = HistorySwipe()
        _ = swipe.handle(phase: .began, x: 0, y: 0, edges: .init(back: false, forward: true), canGoBack: true, canGoForward: true)
        #expect(!swipe.handle(phase: .changed, x: 150, y: 0, edges: edges, canGoBack: true, canGoForward: true).consumes)
    }

    @Test func reversalCancellationAndMissingHistoryDoNotCommit() {
        var swipe = HistorySwipe()
        _ = swipe.handle(phase: .began, x: 100, y: 0, edges: edges, canGoBack: true, canGoForward: true)
        _ = swipe.handle(phase: .changed, x: -60, y: 0, edges: edges, canGoBack: true, canGoForward: true)
        #expect(swipe.handle(phase: .ended, x: 0, y: 0, edges: edges, canGoBack: true, canGoForward: true).commit == nil)
        _ = swipe.handle(phase: .began, x: 200, y: 0, edges: edges, canGoBack: true, canGoForward: true)
        #expect(swipe.handle(phase: .cancelled, x: 0, y: 0, edges: edges, canGoBack: true, canGoForward: true).commit == nil)
        #expect(!swipe.handle(phase: .began, x: 200, y: 0, edges: edges, canGoBack: false, canGoForward: true).consumes)
        #expect(!swipe.handle(phase: .unphased, x: 200, y: 0, edges: edges, canGoBack: true, canGoForward: true).consumes)
        #expect(!swipe.handle(phase: .momentum, x: 200, y: 0, edges: edges, canGoBack: true, canGoForward: true).consumes)
    }

    @Test func releaseIsReportedOnlyForTrackedSwipes() {
        var swipe = HistorySwipe()
        _ = swipe.handle(phase: .began, x: 40, y: 0, edges: edges, canGoBack: true, canGoForward: true)
        let ended = swipe.handle(phase: .ended, x: 0, y: 0, edges: edges, canGoBack: true, canGoForward: true)
        #expect(ended.released && ended.commit == nil)
        _ = swipe.handle(phase: .began, x: 40, y: 0, edges: edges, canGoBack: true, canGoForward: true)
        #expect(swipe.handle(phase: .cancelled, x: 0, y: 0, edges: edges, canGoBack: true, canGoForward: true).released)
        _ = swipe.handle(phase: .began, x: 2, y: 40, edges: edges, canGoBack: true, canGoForward: true)
        #expect(!swipe.handle(phase: .ended, x: 0, y: 0, edges: edges, canGoBack: true, canGoForward: true).released)
        #expect(!swipe.handle(phase: .momentum, x: 50, y: 0, edges: edges, canGoBack: true, canGoForward: true).released)
    }

    /// Owner, 2026-11-18: a real swipe's first event was (1, 2), and the whole sideways swipe
    /// went to the page. The axis is decided over the first few points, as the space swipe does.
    @Test func aSlightlyVerticalFirstEventStillSwipesBack() {
        var swipe = HistorySwipe()
        let first = swipe.handle(phase: .began, x: 1, y: 2, edges: edges, canGoBack: true, canGoForward: false)
        #expect(first.consumes && first.holds && first.direction == nil)
        let second = swipe.handle(phase: .changed, x: 18, y: 0, edges: edges, canGoBack: true, canGoForward: false)
        #expect(second.consumes && !second.holds && !second.replay)
        #expect(second.direction == .back && second.progress == 0.19)
        for _ in 0..<5 { _ = swipe.handle(phase: .changed, x: 18, y: 0, edges: edges, canGoBack: true, canGoForward: false) }
        #expect(swipe.handle(phase: .ended, x: 0, y: 0, edges: edges, canGoBack: true, canGoForward: false).commit == .back)
    }

    @Test func aVerticalDecisionGivesTheHeldEventsToThePage() {
        var swipe = HistorySwipe()
        #expect(swipe.handle(phase: .began, x: 0, y: 0, edges: edges, canGoBack: true, canGoForward: true).holds)
        #expect(swipe.handle(phase: .changed, x: 1, y: 2, edges: edges, canGoBack: true, canGoForward: true).holds)
        let vertical = swipe.handle(phase: .changed, x: 0, y: 6, edges: edges, canGoBack: true, canGoForward: true)
        #expect(!vertical.consumes && !vertical.holds && vertical.replay)
        let next = swipe.handle(phase: .changed, x: 30, y: 0, edges: edges, canGoBack: true, canGoForward: true)
        #expect(!next.consumes && !next.replay, "the page keeps the gesture; the held events go back once")
    }

    @Test func aGestureThatEndsUndecidedGoesToThePage() {
        var swipe = HistorySwipe()
        _ = swipe.handle(phase: .began, x: 2, y: 0, edges: edges, canGoBack: true, canGoForward: true)
        let ended = swipe.handle(phase: .ended, x: 0, y: 0, edges: edges, canGoBack: true, canGoForward: true)
        #expect(!ended.consumes && ended.replay && !ended.released)
        _ = swipe.handle(phase: .began, x: 2, y: 0, edges: edges, canGoBack: true, canGoForward: true)
        let cancelled = swipe.handle(phase: .cancelled, x: 0, y: 0, edges: edges, canGoBack: true, canGoForward: true)
        #expect(!cancelled.consumes && cancelled.replay)
    }

    @Test func nothingIsHeldWhenThereIsNowhereToGo() {
        var swipe = HistorySwipe()
        let first = swipe.handle(phase: .began, x: 1, y: 0, edges: edges, canGoBack: false, canGoForward: false)
        #expect(!first.consumes && !first.holds && !first.replay)
        var edged = HistorySwipe()
        let atEdge = edged.handle(phase: .began, x: 1, y: 0, edges: .init(back: false, forward: false),
                                  canGoBack: true, canGoForward: true)
        #expect(!atEdge.consumes && !atEdge.holds)
    }

    @Test func discSlidesOutAtFixedSizeThenSwellsWhenArmed() {
        let hidden = HistorySwipe.indicator(progress: 0, reduceMotion: false)
        #expect(hidden.centre + hidden.radius == 0)
        let half = HistorySwipe.indicator(progress: 0.5, reduceMotion: false)
        #expect(half == .init(radius: 70, centre: -35, arrowCentre: 0, opacity: 0.5, armed: false))
        let near = HistorySwipe.indicator(progress: 0.99, reduceMotion: false)
        #expect(near.radius == 70 && !near.armed && near.opacity == 0.7)
        let armed = HistorySwipe.indicator(progress: 1, reduceMotion: false)
        #expect(armed == .init(radius: 76, centre: -6, arrowCentre: 35, opacity: 0.79, armed: true))
        #expect(HistorySwipe.indicator(progress: 3, reduceMotion: false) == armed)
        #expect(HistorySwipe.indicator(progress: -1, reduceMotion: false) == hidden)
    }

    @Test func toneDarkensWithProgress() {
        let tones = stride(from: 0.0, through: 1.0, by: 0.1).map { HistorySwipe.indicator(progress: $0, reduceMotion: false).opacity }
        #expect(zip(tones, tones.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(abs(tones[4] - 0.44) < 1e-9)
    }

    @Test func reduceMotionParksTheDiscButKeepsToneAndSwell() {
        for p in [0.0, 0.3, 0.8] {
            let still = HistorySwipe.indicator(progress: p, reduceMotion: true)
            #expect(still.centre == 0 && still.radius == 70 && still.arrowCentre == 35)
            #expect(still.opacity == HistorySwipe.indicator(progress: p, reduceMotion: false).opacity)
        }
        #expect(HistorySwipe.indicator(progress: 1, reduceMotion: true) == HistorySwipe.indicator(progress: 1, reduceMotion: false))
    }
}

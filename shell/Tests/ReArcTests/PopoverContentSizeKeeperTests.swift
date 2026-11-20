import AppKit
import Observation
import SwiftUI
import XCTest
@testable import ReArc

/// The site controls popover was once left at its short size under tall
/// content after Allow (QA on build 1126, d1-6-popover-clipped-s.png). SwiftUI
/// sizes a popover only when its content changes size, so a popover at a
/// wrong size stays there. `PopoverContentSizeKeeper` puts it right.
///
/// The popover is on a window far off every screen. There its resizes are not
/// animated, so the on-screen race cannot be played: the tests put the
/// popover at a wrong size, the state the race leaves, and wait.
@MainActor
final class PopoverContentSizeKeeperTests: XCTestCase {
    @Observable
    final class Model {
        var isShown = false
        var lines = 7
        var keeps = true
    }

    struct Panel: View {
        let model: Model

        var body: some View {
            VStack(spacing: 0) {
                Color.clear.frame(height: 200)
                ForEach(0..<model.lines, id: \.self) { _ in Color.clear.frame(height: 22) }
            }
            .frame(width: 236)
            .background { if model.keeps { PopoverContentSizeKeeper() } }
            .background(PopoverFinder())
        }
    }

    /// Finds the popover the way the keeper does, for the test's own reading.
    struct PopoverFinder: NSViewRepresentable {
        @MainActor static weak var view: NSView?
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            Self.view = view
            return view
        }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    struct Root: View {
        @Bindable var model: Model

        var body: some View {
            Color.clear.frame(width: 300, height: 200)
                .popover(isPresented: $model.isShown, arrowEdge: .bottom) { Panel(model: model) }
        }
    }

    private var window: NSWindow!
    private let model = Model()

    override func setUp() async throws {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 300, height: 200),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Root(model: model))
        window.orderFrontRegardless()
        drain(0.2)
    }

    override func tearDown() async throws {
        model.isShown = false
        drain(0.3)
        window.orderOut(nil)
        window = nil
    }

    private func drain(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    private func openPopover() throws -> (popover: NSPopover, content: NSView) {
        model.isShown = true
        drain(0.6)
        var responder: NSResponder? = try XCTUnwrap(PopoverFinder.view, "the popover did not open")
        while let next = responder, !(next is NSPopover) { responder = next.nextResponder }
        let popover = try XCTUnwrap(responder as? NSPopover, "no popover in the responder chain")
        return (popover, try XCTUnwrap(popover.contentViewController?.view))
    }

    func testAPopoverLeftShortIsMadeAsTallAsItsContent() throws {
        let (popover, content) = try openPopover()
        let fitting = content.fittingSize
        XCTAssertEqual(popover.contentSize, fitting, "SwiftUI's own size at the start")

        popover.contentSize = NSSize(width: fitting.width, height: fitting.height - 154)
        drain(0.1)
        XCTAssertEqual(content.frame.height, fitting.height - 154, accuracy: 0.5, "short, as after the race")
        drain(PopoverContentSizeKeeper.KeeperView.settleDelay + 0.5)
        XCTAssertEqual(popover.contentSize, fitting)
        XCTAssertEqual(content.frame.size, fitting, "the content is whole again")
    }

    func testAPopoverLeftTallIsBroughtBackToItsContent() throws {
        let (popover, content) = try openPopover()
        let fitting = content.fittingSize
        popover.contentSize = NSSize(width: fitting.width, height: fitting.height + 80)
        drain(PopoverContentSizeKeeper.KeeperView.settleDelay + 0.6)
        XCTAssertEqual(popover.contentSize, fitting)
    }

    /// What the keeper is for: without it the wrong size stays.
    func testWithoutTheKeeperTheWrongSizeStays() throws {
        model.keeps = false
        let (popover, content) = try openPopover()
        let fitting = content.fittingSize
        let short = NSSize(width: fitting.width, height: fitting.height - 154)
        popover.contentSize = short
        drain(PopoverContentSizeKeeper.KeeperView.settleDelay + 0.6)
        XCTAssertEqual(popover.contentSize, short)
        XCTAssertEqual(content.fittingSize, fitting, "and the content still asks for its full size")
    }

    func testThePopoverStillFollowsItsContent() throws {
        let (popover, content) = try openPopover()
        let before = popover.contentSize
        model.lines = 0
        drain(0.05)
        model.lines = 9
        drain(PopoverContentSizeKeeper.KeeperView.settleDelay + 0.6)
        XCTAssertEqual(popover.contentSize.height, before.height + 44, accuracy: 0.5)
        XCTAssertEqual(popover.contentSize, content.fittingSize)
    }

    func testOnlyARealDifferenceThatFitsTheScreenIsCorrected() {
        let screen = NSSize(width: 1512, height: 944)
        let fitting = NSSize(width: 262, height: 536)
        XCTAssertEqual(PopoverContentSizeKeeper.correction(shown: NSSize(width: 262, height: 334), fitting: fitting, screen: screen), fitting)
        XCTAssertEqual(PopoverContentSizeKeeper.correction(shown: NSSize(width: 262, height: 600), fitting: fitting, screen: screen), fitting)
        XCTAssertNil(PopoverContentSizeKeeper.correction(shown: fitting, fitting: fitting, screen: screen))
        XCTAssertNil(PopoverContentSizeKeeper.correction(shown: NSSize(width: 262, height: 536.4), fitting: fitting, screen: screen),
                     "a rounding difference")
        XCTAssertNil(PopoverContentSizeKeeper.correction(shown: NSSize(width: 262, height: 334), fitting: .zero, screen: screen),
                     "content not laid out yet")
        XCTAssertNil(PopoverContentSizeKeeper.correction(shown: NSSize(width: 262, height: 334), fitting: NSSize(width: 262, height: 1200),
                                                         screen: screen), "taller than the screen: SwiftUI's own limit stands")
        XCTAssertEqual(PopoverContentSizeKeeper.correction(shown: NSSize(width: 262, height: 334), fitting: fitting, screen: nil), fitting)
    }
}

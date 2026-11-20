import AppKit
import SwiftUI
import XCTest
@testable import ReArc

/// The traffic lights stay where `TrafficLightPositioner` puts them when
/// AppKit tiles the title bar again. A new window title does that, and the
/// window's title follows the selected tab (`BrowserView.navigationTitle`),
/// so before the fix the buttons went back to the system's place on a tab
/// switch (seen on screen in build 1126) and stayed there until the window
/// next changed key. The windows here are never ordered in.
@MainActor
final class TrafficLightPlacementTests: XCTestCase {

    /// A window as `ChromiumShell.makeWindow` builds a browser window.
    private func makeWindow(content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.title = "Darni"
        window.tabbingMode = .disallowed
        window.contentView = content
        return window
    }

    /// Each button's centre from the window's top left, as THEMES.md §4.5 gives it.
    private func centres(in window: NSWindow) throws -> [NSPoint] {
        try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { kind in
            let button = try XCTUnwrap(window.standardWindowButton(kind))
            let frame = button.convert(button.bounds, to: nil)
            return NSPoint(x: frame.midX, y: window.frame.height - frame.midY)
        }
    }

    private func assertPlaced(in window: NSWindow, centreY: CGFloat? = nil, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let centreY = centreY ?? TrafficLightPositioner.centreY
        for (index, centre) in try centres(in: window).enumerated() {
            let x = TrafficLightPositioner.firstCentreX + TrafficLightPositioner.pitch * CGFloat(index)
            // The origin is rounded to a whole point.
            XCTAssertEqual(centre.x, x, accuracy: 0.5, "button \(index) x, \(message)", file: file, line: line)
            XCTAssertEqual(centre.y, centreY, accuracy: 0.5, "button \(index) y, \(message)", file: file, line: line)
        }
        let container = try XCTUnwrap(window.standardWindowButton(.closeButton)?.superview?.superview)
        XCTAssertEqual(container.frame, TrafficLightPositioner.titlebarFrame(windowSize: window.frame.size),
                       "the title bar covers only the buttons, \(message)", file: file, line: line)
    }

    private func settle(_ window: NSWindow) {
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testANewWindowTitleLeavesTheButtonsInPlace() throws {
        let positioner = TrafficLightPositioner.PositionerView()
        let content = NSView()
        content.addSubview(positioner)
        let window = makeWindow(content: content)
        defer { window.close() }
        settle(window)
        try assertPlaced(in: window, "at first")

        window.title = "Aurora - Wikipedia"
        try assertPlaced(in: window, "right after the title changed")
        settle(window)
        try assertPlaced(in: window, "after the next layout")

    }

    /// Causes other than the title are caught by watching the title bar's
    /// views, and put right on the next turn of the main queue.
    func testOtherTitleBarChangesArePutRightOnTheNextTurn() throws {
        let positioner = TrafficLightPositioner.PositionerView()
        let content = NSView()
        content.addSubview(positioner)
        let window = makeWindow(content: content)
        defer { window.close() }
        settle(window)

        window.subtitle = "en.wikipedia.org"
        settle(window)
        try assertPlaced(in: window, "after a subtitle")
        window.representedURL = URL(fileURLWithPath: NSTemporaryDirectory())
        settle(window)
        try assertPlaced(in: window, "after a document icon")
        window.representedURL = nil
        window.subtitle = ""
        settle(window)
        try assertPlaced(in: window, "after both went")
    }

    func testTheSidebarOnTheRightKeepsItsHeightAcrossATitleChange() throws {
        let positioner = TrafficLightPositioner.PositionerView()
        let content = NSView()
        content.addSubview(positioner)
        let window = makeWindow(content: content)
        defer { window.close() }
        let centreY = BrowserView.cardInset + CardToolbarView.height / 2
        positioner.centreY = centreY
        positioner.reposition()
        try assertPlaced(in: window, centreY: centreY, "at first")

        window.title = "PyPI"
        settle(window)
        try assertPlaced(in: window, centreY: centreY, "after the title changed")
    }

    func testHiddenButtonsStayHiddenAndComeBackInPlace() throws {
        let positioner = TrafficLightPositioner.PositionerView()
        let content = NSView()
        content.addSubview(positioner)
        let window = makeWindow(content: content)
        defer { window.close() }
        positioner.buttonsHidden = true
        positioner.reposition()
        window.title = "Hidden"
        settle(window)
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, true)

        positioner.buttonsHidden = false
        positioner.reposition()
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, false)
        try assertPlaced(in: window, "shown again")
    }

    /// The way the browser window does it: SwiftUI's `navigationTitle` sets
    /// the window's title after the view update, so `updateNSView` is no help.
    func testATitleFromSwiftUILeavesTheButtonsInPlace() throws {
        let model = TitleModel()
        let hosting = NSHostingView(rootView: TitledRoot(model: model))
        hosting.sizingOptions = []
        let window = makeWindow(content: hosting)
        defer { window.close() }
        settle(window)
        try assertPlaced(in: window, "at first")

        for title in ["Aurora - Wikipedia", "PyPI · The Python Package Index", "Darni"] {
            model.title = title
            settle(window)
            XCTAssertEqual(window.title, title, "the window's title follows the view's")
            try assertPlaced(in: window, "with the title \(title)")
        }
    }

    func testAResizeStillLeavesTheButtonsInPlace() throws {
        let positioner = TrafficLightPositioner.PositionerView()
        let content = NSView()
        content.addSubview(positioner)
        let window = makeWindow(content: content)
        defer { window.close() }
        settle(window)
        window.setFrame(NSRect(x: -30000, y: -30000, width: 900, height: 600), display: false)
        settle(window)
        try assertPlaced(in: window, "after a resize")
    }
}

@Observable
private final class TitleModel {
    var title = "Darni"
}

private struct TitledRoot: View {
    let model: TitleModel

    var body: some View {
        Color.clear
            .frame(minWidth: 760, minHeight: 520)
            .background(TrafficLightPositioner().frame(width: 0, height: 0))
            .navigationTitle(model.title)
    }
}

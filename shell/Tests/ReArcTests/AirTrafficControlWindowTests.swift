import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// The Air Traffic Control window, laid out offscreen (never ordered in, far off
/// any display). Owner, 2026-11-22: with more rules than fit, the scroll bar
/// covered each rule's bin button, the window was too narrow for a space's
/// name, and it could not be made bigger.
@MainActor
final class AirTrafficControlWindowTests: XCTestCase {

    private let longSpace = "CWC - YAVICA"
    private let longProfile = "Akilu"

    private func makeModel(rules count: Int) -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        _ = store.renameProfile(store.activeProfileID, to: longProfile)
        let space = store.addSpace(name: longSpace, theme: .default, profileID: store.activeProfileID)
        // Two profiles, as on the owner's Mac: each destination names its profile too.
        _ = store.addProfile(name: "Studio")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-atc-\(UUID().uuidString)")
        let model = BrowserViewModel(store: store,
                                     persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
                                     syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil))
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-atc-\(UUID().uuidString)")!
        model.linkRouting = LinkRoutingState(rules: (0 ..< count).map {
            LinkRoutingRule(matchType: .domain, pattern: "site\($0).dynamics.com", destination: .space(space.id))
        })
        return model
    }

    /// The product's window, configured as `AirTrafficControlWindow.make` does,
    /// in a window that is never constrained onto a screen.
    private func window(for model: BrowserViewModel, contentSize: NSSize? = nil,
                        style: NSScroller.Style = .overlay) -> (NSWindow, NSView) {
        let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: -30000, width: 100, height: 100),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
        AirTrafficControlWindow.configure(window, model: model)
        if let contentSize { window.setContentSize(contentSize) }
        let host = window.contentView!
        settle(host)
        for scrollView in Self.scrollViews(in: host) { scrollView.scrollerStyle = style }
        settle(host)
        return (window, host)
    }

    private func settle(_ host: NSView) {
        for _ in 0 ..< 2 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
    }

    /// SwiftUI builds its accessibility tree only for a client that asked.
    private func withAccessibility(_ host: NSView, _ body: () throws -> Void) rethrows {
        AccessibilityTree.setAssistiveClient(true)
        defer { AccessibilityTree.setAssistiveClient(false) }
        _ = host.accessibilityChildren()
        settle(host)
        try body()
    }

    func testTheWindowOpensWideAndCanBeResized() {
        let window = AirTrafficControlWindow.make(model: makeModel(rules: 2))
        defer { window.close() }
        XCTAssertTrue(window.styleMask.contains(.resizable), "the window can be made bigger")
        XCTAssertGreaterThanOrEqual(window.contentRect(forFrameRect: window.frame).width, 860)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, AirTrafficControlView.minWidth)
        XCTAssertEqual(window.frameAutosaveName, AirTrafficControlWindow.autosaveName, "it keeps the size it was given")
    }

    /// Every rule's bin and arrows stay clear of the scroll bar, with the
    /// overlay scroll bar of a trackpad and the legacy one of a mouse.
    func testTheScrollBarNeverCoversARulesButtons() throws {
        for style in [NSScroller.Style.overlay, .legacy] {
            let (window, host) = window(for: makeModel(rules: 16), style: style)
            defer { window.close() }
            let scrollView = try XCTUnwrap(Self.scrollViews(in: host).first, "the rules scroll")
            let scroller = try XCTUnwrap(scrollView.verticalScroller)
            XCTAssertGreaterThan(scrollView.documentView?.frame.height ?? 0, scrollView.contentView.bounds.height,
                                 "16 rules are more than the window shows at once (\(style))")
            let scrollerFrame = Self.screenFrame(of: scroller)
            try withAccessibility(host) {
                for label in ["Delete Rule", "Move Rule Up", "Move Rule Down"] {
                    let buttons = Self.elements(labelled: label, in: host)
                    XCTAssertFalse(buttons.isEmpty, "no \"\(label)\" buttons")
                    for button in buttons {
                        let frame = try XCTUnwrap(button.accessibilityFrame?())
                        XCTAssertLessThanOrEqual(frame.maxX, scrollerFrame.minX,
                                                 "\"\(label)\" ends at \(frame.maxX), under the \(style) scroll bar from \(scrollerFrame.minX)")
                    }
                }
            }
        }
    }

    /// A rule's space and profile name fits its pop-up at the window's
    /// opening size, and a wider window gives the rule more room.
    func testASpacesNameFitsAndAWiderWindowWidensTheRule() throws {
        let model = makeModel(rules: 3)
        let name = ExternalLinkRouting.describe(model.linkRouting.rules[0].destination, in: model.store)
        XCTAssertEqual(name, "\(longSpace) (\(longProfile))")
        // What a pop-up button needs to draw that title in full: text, insets and arrows.
        let probe = NSPopUpButton(frame: .zero, pullsDown: false)
        probe.addItem(withTitle: name)
        probe.sizeToFit()
        let needed = probe.frame.width

        let (narrow, narrowHost) = window(for: model)
        defer { narrow.close() }
        var openingWidth: CGFloat = 0
        try withAccessibility(narrowHost) {
            let destinations = Self.elements(labelled: "Destination", in: narrowHost)
            XCTAssertEqual(destinations.count, 3)
            openingWidth = try XCTUnwrap(destinations.first?.accessibilityFrame?()).width
            XCTAssertGreaterThanOrEqual(openingWidth, needed, "\"\(name)\" is cut short at the opening size")
        }

        let (wide, wideHost) = window(for: model, contentSize: NSSize(width: 1200, height: 480))
        defer { wide.close() }
        try withAccessibility(wideHost) {
            let bin = try XCTUnwrap(Self.elements(labelled: "Delete Rule", in: wideHost).first?.accessibilityFrame?())
            XCTAssertGreaterThan(bin.maxX, Self.screenFrame(of: wideHost).minX + 1000,
                                 "a wider window takes the rule row to its trailing edge")
        }
    }

    /// Set `REARC_ATC_DIR` to keep a picture of the window at its opening size,
    /// with more rules than fit (light only: an offscreen cache drops the dark
    /// window background).
    func testWindowSnapshots() throws {
        guard let path = ProcessInfo.processInfo.environment["REARC_ATC_DIR"] else {
            throw XCTSkip("set REARC_ATC_DIR to write the Air Traffic Control snapshots")
        }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let (window, host) = window(for: makeModel(rules: 16))
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        settle(host)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path).appendingPathComponent("air-traffic-control.png"))
    }

    // MARK: - Helpers

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private static func screenFrame(of view: NSView) -> NSRect {
        view.window!.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private static func elements(labelled label: String, in root: Any) -> [AnyObject] {
        AccessibilityTree.elements(labelled: label, in: root)
    }
}

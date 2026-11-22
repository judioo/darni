import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// What the tests of bugs found on build 1164 share: a model on throwaway
/// files, and a SwiftUI view laid out in a window that is never on screen
/// and read through accessibility (no event is posted).
enum Build1164TestSupport {
    static func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-1164-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-1164-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-1164-links-\(UUID().uuidString)")!
        model.shortcutOverrides = ShortcutOverrides()
        return model
    }

    /// `view` in a window off every screen, laid out; `body` gets its hosting view.
    static func hosted<V: View, Result>(_ view: V, size: NSSize, _ body: (NSHostingView<V>, NSWindow) throws -> Result) rethrows -> Result {
        _ = NSApplication.shared
        let window = OffscreenWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: view)
        window.contentView = host
        settle(host)
        return try body(host, window)
    }

    static func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    static func subviews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + subviews(of: $0) }
    }

    /// Every label, title, value and help text (a tooltip) in a view's accessibility tree.
    static func accessibilityTexts<V: View>(of view: V, size: NSSize) -> [String] {
        hosted(view, size: size) { host, _ in
            // SwiftUI builds its accessibility tree only for a client that asked.
            let assistive = [NSAccessibility.Attribute(rawValue: "AXManualAccessibility"), NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")]
            for attribute in assistive { (NSApplication.shared as NSObject).accessibilitySetValue(true, forAttribute: attribute) }
            defer { for attribute in assistive { (NSApplication.shared as NSObject).accessibilitySetValue(false, forAttribute: attribute) } }
            _ = host.accessibilityChildren()
            settle(host)
            var found: [String] = []
            func walk(_ root: Any, depth: Int) {
                let node = root as AnyObject
                guard depth < 14 else { return }
                // Asked by name: a label can come back attributed, which a typed call cannot bridge.
                for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityHelp"] {
                    let selector = NSSelectorFromString(name)
                    guard node.responds(to: selector), let raw = node.perform(selector)?.takeUnretainedValue() else { continue }
                    let text = (raw as? String) ?? (raw as? NSAttributedString)?.string ?? ""
                    if !text.isEmpty { found.append(text) }
                }
                for child in (node.accessibilityChildren?() as [Any]?) ?? [] { walk(child, depth: depth + 1) }
            }
            walk(host, depth: 0)
            return found
        }
    }
}

private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

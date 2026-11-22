import AppKit

/// A window for laying out or drawing a view in a test: never constrained onto
/// a screen, never ordered in. Tests place it far off screen (-30000, -30000).
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Reading a hosted SwiftUI view through accessibility, as VoiceOver would:
/// its buttons by label, their frames, and a press.
enum AccessibilityTree {
    /// SwiftUI builds its accessibility tree only for a client that asked.
    /// Turn this on before reading the tree, and off when done.
    static func setAssistiveClient(_ on: Bool) {
        let assistive = [NSAccessibility.Attribute(rawValue: "AXManualAccessibility"),
                         NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")]
        for attribute in assistive { (NSApplication.shared as NSObject).accessibilitySetValue(on, forAttribute: attribute) }
    }

    /// Every element under `root` labelled `label`, depth first, down to `maxDepth`.
    static func elements(labelled label: String, in root: Any, maxDepth: Int = 16) -> [AnyObject] {
        func walk(_ root: Any, _ depth: Int) -> [AnyObject] {
            let node = root as AnyObject
            guard depth < maxDepth else { return [] }
            var found: [AnyObject] = (node.accessibilityLabel?() as String?) == label ? [node] : []
            for child in (node.accessibilityChildren?() as [Any]?) ?? [] { found += walk(child, depth + 1) }
            return found
        }
        return walk(root, 0)
    }

    /// The first element under `root` labelled `label`, depth first, down to `maxDepth`.
    static func element(labelled label: String, in root: Any, maxDepth: Int = 16) -> AnyObject? {
        func walk(_ root: Any, _ depth: Int) -> AnyObject? {
            let node = root as AnyObject
            guard depth < maxDepth else { return nil }
            if (node.accessibilityLabel?() as String?) == label { return node }
            for child in (node.accessibilityChildren?() as [Any]?) ?? [] {
                if let found = walk(child, depth + 1) { return found }
            }
            return nil
        }
        return walk(root, 0)
    }
}

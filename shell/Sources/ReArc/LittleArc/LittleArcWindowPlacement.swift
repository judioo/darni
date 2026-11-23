import AppKit
import SidebarModel

/// Where a new Little Darni window opens: where the user last left one, on
/// that screen, at that size (owner, 2026-11-23: every Little Darni opened in
/// the same place, even after one was moved to another screen). With nothing
/// remembered, or the remembered screen gone, the shell falls back to its
/// cascade from the key window.
enum LittleArcWindowPlacement {
    /// A second window opened while one sits at the remembered spot steps
    /// down and right by this much, as a cascade does.
    static let cascadeStep: CGFloat = 28
    /// At least this much of the remembered frame must lie on a screen for
    /// that screen to count as the one the user left it on.
    static let minimumOverlap: CGFloat = 40

    /// The frame for a new window, or nil for the shell's default placement.
    /// `screens` are the visible frames of the displays now attached;
    /// `occupied` the frames of the Little Darni windows already open.
    static func frame(remembered: NSRect?, screens: [NSRect], occupied: [NSRect] = [],
                      minimumSize: CGSize = LittleArcWindowView.minimumSize) -> NSRect? {
        guard let remembered, remembered.width > 0, remembered.height > 0,
              let screen = screen(for: remembered, among: screens) else { return nil }
        let size = NSSize(width: max(min(remembered.width, screen.width), min(minimumSize.width, screen.width)),
                          height: max(min(remembered.height, screen.height), min(minimumSize.height, screen.height)))
        var frame = clamp(NSRect(origin: remembered.origin, size: size), into: screen)
        // Step off windows already at that spot, so one never hides another.
        var steps = 0
        while steps < 12, occupied.contains(where: { sameTopLeft($0, frame) }) {
            let next = NSRect(x: frame.minX + cascadeStep, y: frame.minY - cascadeStep, width: size.width, height: size.height)
            let clamped = clamp(next, into: screen)
            if sameTopLeft(clamped, frame) { break }
            frame = clamped
            steps += 1
        }
        return frame
    }

    /// The screen holding the most of `frame`, if it holds enough of it.
    static func screen(for frame: NSRect, among screens: [NSRect]) -> NSRect? {
        let best = screens.max { overlap(frame, $0) < overlap(frame, $1) }
        guard let best else { return nil }
        let shared = frame.intersection(best)
        return shared.width >= min(minimumOverlap, frame.width) && shared.height >= min(minimumOverlap, frame.height) ? best : nil
    }

    static func clamp(_ frame: NSRect, into screen: NSRect) -> NSRect {
        var frame = frame
        frame.size.width = min(frame.width, screen.width)
        frame.size.height = min(frame.height, screen.height)
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        return frame
    }

    private static func overlap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let shared = a.intersection(b)
        return shared.isNull ? 0 : shared.width * shared.height
    }

    private static func sameTopLeft(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.maxY - b.maxY) < 2
    }
}

/// The last place a Little Darni window was left. The installed app keeps it
/// in its defaults (a `REARC_DATA_DIR` launch under its own key); the
/// self-test and benches keep it in memory only.
final class LittleArcFrameMemory {
    static let defaultsKey = ShellDataLocation.isOverridden ? "ReArcLittleDarniFrame.isolated" : "ReArcLittleDarniFrame"

    private let defaults: UserDefaults?
    private let key: String
    private var inMemory: NSRect?

    init(defaults: UserDefaults?, key: String = LittleArcFrameMemory.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    var frame: NSRect? {
        if let defaults {
            guard let text = defaults.string(forKey: key) else { return nil }
            let frame = NSRectFromString(text)
            return frame.width > 0 && frame.height > 0 ? frame : nil
        }
        return inMemory
    }

    /// Called when a Little Darni window is moved, resized or closed. A
    /// full-screen or minimised window is no place to come back to.
    @MainActor
    func remember(_ window: NSWindow) {
        guard window.isVisible, !window.isMiniaturized, !window.styleMask.contains(.fullScreen) else { return }
        remember(window.frame)
    }

    func remember(_ frame: NSRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        if let defaults {
            defaults.set(NSStringFromRect(frame), forKey: key)
        } else {
            inMemory = frame
        }
    }
}

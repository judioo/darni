import AppKit
import SwiftUI

/// The Air Traffic Control window of the Chromium shell. It is wide enough for
/// a rule's space and profile names in full, can be resized, and remembers its
/// size. Its list of rules grows with it (owner, 2026-11-22: the fixed
/// 640×360 window showed three rules, cut the space names short, and its
/// scroll bar covered the bin buttons).
enum AirTrafficControlWindow {
    static let title = "Air Traffic Control"
    static let autosaveName = "AirTrafficControl"
    static let defaultContentSize = NSSize(width: 880, height: 480)
    static let minContentSize = NSSize(width: AirTrafficControlView.minWidth, height: AirTrafficControlView.minHeight)

    @MainActor
    static func make(model: BrowserViewModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: defaultContentSize),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        configure(window, model: model)
        if !window.setFrameUsingName(autosaveName) { window.center() }
        window.setFrameAutosaveName(autosaveName)
        return window
    }

    /// Everything but the frame, for `make` and for tests' offscreen windows.
    @MainActor
    static func configure(_ window: NSWindow, model: BrowserViewModel) {
        window.isReleasedWhenClosed = false
        window.title = title
        window.styleMask.insert(.resizable)
        window.contentMinSize = minContentSize
        let host = NSHostingView(rootView: AirTrafficControlView(model: model))
        // The window, not the view, sets the size; the view only sets the minimum.
        host.sizingOptions = [.minSize]
        window.contentView = host
        window.setContentSize(defaultContentSize)
    }
}

import AppKit

/// How a Little Darni window comes on screen.
///
/// The user's own (a link, ⌥⌘-click, the hotkey, a restore) is key and
/// frontmost. One a program made that may not take the keyboard
/// (`BrowserViewModel.presentExtensionLittleArc`) is put on screen directly
/// behind the app's frontmost window: it is neither key nor main, nothing is
/// ordered front and the app is not activated, so what the user was typing
/// into keeps the keyboard. The Window menu, Mission Control and the toast's
/// Show button reach it.
enum LittleArcWindowOrdering {
    /// `front` is the window a background one goes behind (`frontWindow`);
    /// with none it goes to the back. A window already on screen is left
    /// where it is unless it may come to the front.
    @MainActor
    static func show(_ window: NSWindow, inFront: Bool, behind front: NSWindow?) {
        if inFront {
            window.makeKeyAndOrderFront(nil)
        } else if window.isVisible || window.isMiniaturized {
            return
        } else if let front, front !== window, front.isVisible {
            window.order(.below, relativeTo: front.windowNumber)
        } else {
            window.orderBack(nil)
        }
    }

    /// The frontmost ordinary window among `windows` (front to back, as
    /// `NSApp.orderedWindows`): on screen, not `window` itself, and no panel
    /// (an extension's popup or a suggestion list hangs off the window behind it).
    @MainActor
    static func frontWindow(among windows: [NSWindow], except window: NSWindow? = nil) -> NSWindow? {
        windows.first { $0 !== window && $0.isVisible && !$0.isMiniaturized && !($0 is NSPanel) && $0.level == .normal }
    }
}

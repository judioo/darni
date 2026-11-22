import AppKit
import SwiftUI

extension NSMenu {
    /// A context menu of Darni's own: it holds what Darni puts in it and
    /// nothing else. macOS appends its own items to a context menu that
    /// allows plug-in items: Services, and "Ask Siri" at the head of the menu
    /// of a view that offers text or a file (a download row does: it drags
    /// its file out). Items keep the enabled state they are given.
    static func darniContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.allowsContextMenuPlugIns = false
        menu.autoenablesItems = false
        return menu
    }
}

extension View {
    /// A right-click (or ⌃-click) menu built with AppKit when it opens, for a
    /// row whose SwiftUI `contextMenu` macOS adds its own items to (SwiftUI
    /// gives no say over them). `menu` should build on `NSMenu.darniContextMenu()`.
    /// Every other event goes to the row itself: its click, hover and drag.
    func darniContextMenu(_ menu: @escaping () -> NSMenu?) -> some View {
        overlay(DarniContextMenuArea(menu: menu))
    }
}

private struct DarniContextMenuArea: NSViewRepresentable {
    let menu: () -> NSMenu?

    func makeNSView(context: Context) -> DarniContextMenuView {
        let view = DarniContextMenuView()
        view.menuProvider = menu
        return view
    }

    func updateNSView(_ view: DarniContextMenuView, context: Context) {
        view.menuProvider = menu
    }
}

/// Takes only the click that asks for a menu; AppKit then shows `menu(for:)`.
final class DarniContextMenuView: NSView {
    var menuProvider: (() -> NSMenu?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        Self.asksForMenu(NSApp.currentEvent) ? super.hitTest(point) : nil
    }

    /// A right-click, or a click with Control held.
    static func asksForMenu(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

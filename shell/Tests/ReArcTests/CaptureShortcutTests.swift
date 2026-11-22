import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Build 1164 (2026-11-22): File › Capture showed its shortcut as ⌘@ in the
/// menu bar instead of ⇧⌘2.
final class CaptureShortcutTests: XCTestCase {
    func testCaptureIsShiftCommand2OnBothMenuPaths() throws {
        _ = NSApplication.shared
        let model = Build1164TestSupport.makeModel()
        let capture = try XCTUnwrap(ShellMenus.capture(model).first?.first)
        XCTAssertEqual(capture.title, "Capture")

        // Chromium path: the NSMenuItem's key is the digit with Shift in the mask, which
        // the menu bar draws as ⇧⌘2 ("@" with ⌘ alone is drawn ⌘@).
        let equivalent = capture.appKitKeyEquivalent
        XCTAssertEqual(equivalent.key, "2")
        XCTAssertEqual(equivalent.mask, [.command, .shift])
        XCTAssertEqual(MenuKeyEquivalents.chord(key: equivalent.key, mask: equivalent.mask)?.display, "⇧⌘2")

        // The shortcut still works: a ⇧⌘2 press as the keyboard makes it (a CGEvent, never
        // posted: AppKit matches a shifted digit by its key, which an NSEvent built from
        // characters does not carry), also after Settings › Shortcuts has passed over the menu.
        final class Target: NSObject {
            var hits: [String] = []
            @objc func run(_ sender: NSMenuItem) { hits.append(sender.title) }
        }
        let target = Target()
        let menu = NSMenu(title: "Main")
        // In the menu bar's order: File's Capture comes before Tabs' Tab 2 (⌘2).
        let tab2 = try XCTUnwrap(ShellMenus.tabPositions(model).first?[1])
        var built: [NSMenuItem] = []
        for entry in [capture, tab2] {
            let item = NSMenuItem(title: entry.title, action: #selector(Target.run(_:)), keyEquivalent: entry.appKitKeyEquivalent.key)
            item.keyEquivalentModifierMask = entry.appKitKeyEquivalent.mask
            item.target = target
            menu.addItem(item)
            built.append(item)
        }
        func press(_ flags: CGEventFlags) throws -> NSEvent {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 19, keyDown: true))  // the 2 key
            event.flags = flags
            return try XCTUnwrap(NSEvent(cgEvent: event))
        }
        XCTAssertTrue(menu.performKeyEquivalent(with: try press([.maskCommand, .maskShift])))
        MenuKeyEquivalents().apply(ShortcutOverrides(), to: menu)
        XCTAssertEqual(built[0].keyEquivalent, "2")
        XCTAssertEqual(built[0].keyEquivalentModifierMask, [.command, .shift])
        XCTAssertTrue(menu.performKeyEquivalent(with: try press([.maskCommand, .maskShift])))
        XCTAssertEqual(target.hits, ["Capture", "Capture"])
        // ⌘2 alone stays Tab 2's.
        XCTAssertTrue(menu.performKeyEquivalent(with: try press(.maskCommand)))
        XCTAssertEqual(target.hits.last, "Tab 2")
        menu.removeItem(built[1])
        XCTAssertFalse(menu.performKeyEquivalent(with: try press(.maskCommand)), "⌘2 does not run Capture")

        // WebKit path: SwiftUI's shortcut, the same key and modifiers.
        let shortcut = try XCTUnwrap(capture.keyboardShortcut(with: ShortcutOverrides()))
        XCTAssertEqual(shortcut.key.character, "2")
        XCTAssertEqual(shortcut.modifiers, [.command, .shift])
        // The command bar's row for the menu item reads the same.
        XCTAssertEqual(capture.arcShortcut?.id, "capturePage")
    }
}

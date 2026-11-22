import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Small things found on screen 2026-11-22 (QA build of main 2e0c72cb):
/// Settings › Profiles' Download location button read "Chan…", the
/// Library's Downloads page had a link named for Chromium, and the Media
/// page's empty text named a command the menus do not have.
@MainActor
final class Leftovers1122Tests: XCTestCase {
    /// The accessibility frame of the first element whose label, title or value (a text's words) is `text`, in a hosted view.
    private func frame<V: View>(of text: String, in view: V, size: NSSize) -> NSRect? {
        Build1164TestSupport.hosted(view, size: size) { host, _ in
            let assistive = [NSAccessibility.Attribute(rawValue: "AXManualAccessibility"), NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")]
            for attribute in assistive { (NSApplication.shared as NSObject).accessibilitySetValue(true, forAttribute: attribute) }
            defer { for attribute in assistive { (NSApplication.shared as NSObject).accessibilitySetValue(false, forAttribute: attribute) } }
            _ = host.accessibilityChildren()
            Build1164TestSupport.settle(host)
            func walk(_ root: Any, depth: Int) -> NSRect? {
                let node = root as AnyObject
                guard depth < 14 else { return nil }
                for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                    let selector = NSSelectorFromString(name)
                    guard node.responds(to: selector), let raw = node.perform(selector)?.takeUnretainedValue() else { continue }
                    let found = (raw as? String) ?? (raw as? NSAttributedString)?.string ?? ""
                    if found == text, let element = node as? NSAccessibilityElementProtocol { return element.accessibilityFrame() }
                }
                for child in (node.accessibilityChildren?() as [Any]?) ?? [] {
                    if let frame = walk(child, depth: depth + 1) { return frame }
                }
                return nil
            }
            return walk(host, depth: 0)
        }
    }

    // MARK: Settings › Profiles › Download location

    /// The row in a box `width` wide; the Profiles pane's is `ProfilesSettingsPane.detailWidth`.
    private func rowFrame(of text: String, folder: String, width: CGFloat) throws -> NSRect {
        let row = SettingsGroup { DownloadLocationRowContent(folderName: folder, choose: {}) }.frame(width: width)
        return try XCTUnwrap(frame(of: text, in: row, size: NSSize(width: width, height: 120)),
                             "no \(text) in the Download location row \(width) pt wide")
    }

    /// The box beside the profile list is 341 pt. The row came to more than
    /// that even for "Downloads", and the button gave way: it read "Chan…".
    func testTheDownloadLocationRowFitsItsBoxBesideTheProfileList() throws {
        let box = ProfilesSettingsPane.detailWidth
        XCTAssertEqual(box, 341, "the Profiles pane's detail column")
        let roomy: CGFloat = 900
        let button = try rowFrame(of: DownloadLocationRowContent.changeTitle, folder: "Downloads", width: roomy)
        XCTAssertGreaterThan(button.width, 50, "Change… with its border")
        let label = try rowFrame(of: DownloadLocationRow.label, folder: "Downloads", width: roomy)
        let detail = try rowFrame(of: DownloadLocationRowContent.detail, folder: "Downloads", width: roomy)
        let name = try rowFrame(of: "Downloads", folder: "Downloads", width: roomy)

        // The ordinary folder: everything whole and on one line.
        XCTAssertEqual(try rowFrame(of: DownloadLocationRowContent.changeTitle, folder: "Downloads", width: box).width, button.width,
                       accuracy: 0.5, "the button is squeezed in the Profiles pane's box: it read \"Chan…\"")
        XCTAssertEqual(try rowFrame(of: "Downloads", folder: "Downloads", width: box).width, name.width, accuracy: 0.5,
                       "the folder's name is cut short")
        XCTAssertEqual(try rowFrame(of: DownloadLocationRow.label, folder: "Downloads", width: box).height, label.height, accuracy: 0.5,
                       "the label wraps")
        XCTAssertEqual(try rowFrame(of: DownloadLocationRowContent.detail, folder: "Downloads", width: box).height, detail.height,
                       accuracy: 0.5, "the detail wraps")

        // A long name gives way, never the button or the label's own line.
        for folder in ["Downloads from the browser I am testing today", String(repeating: "A very long folder name ", count: 8)] {
            XCTAssertEqual(try rowFrame(of: DownloadLocationRowContent.changeTitle, folder: folder, width: box).width, button.width,
                           accuracy: 0.5, "the button was squeezed to make room for \(folder)")
            XCTAssertLessThanOrEqual(try rowFrame(of: folder, folder: folder, width: box).width,
                                     DownloadLocationRowContent.folderNameMaxWidth + 0.5, "a long name is shortened")
            XCTAssertEqual(try rowFrame(of: DownloadLocationRow.label, folder: folder, width: box).height, label.height, accuracy: 0.5,
                           "the label keeps its line beside \(folder)")
        }
    }

    // MARK: Library

    func testTheDownloadsPageLinkIsNotNamedForChromium() {
        XCTAssertEqual(LibraryDownloadsPage.enginePageLinkTitle, "Open Downloads Page")
        XCTAssertFalse(LibraryDownloadsPage.enginePageLinkTitle.localizedCaseInsensitiveContains("chromium"))
    }

    /// The Media page's empty text names the capture commands as the File menu and the page's own menu do.
    func testTheMediaPagesEmptyTextNamesTheMenusCommands() {
        let menu = ShellMenus.capture(Build1164TestSupport.makeModel()).flatMap { $0 }.map(\.title)
        let text = LibraryMediaPage.emptyDescription
        XCTAssertTrue(menu.contains(CaptureCommandTitle.fullPage) && menu.contains(CaptureCommandTitle.visibleArea), "\(menu)")
        XCTAssertEqual(CaptureCommandTitle.fullPage, "Capture Full Page")
        XCTAssertTrue(text.contains(CaptureCommandTitle.fullPage), text)
        XCTAssertTrue(text.contains(CaptureCommandTitle.visibleArea), text)
        XCTAssertFalse(text.contains("Capture Page"), "no command is called Capture Page: \(text)")
        XCTAssertEqual(SiteControlCenter.QuickAction.captureFullPage.title, CaptureCommandTitle.fullPage, "the site controls' tile says the same")
    }
}

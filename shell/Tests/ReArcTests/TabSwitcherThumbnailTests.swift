import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// The ⌃Tab switcher's thumbnail cards: what a page's capture is cut down
/// to, and offscreen renders of the panel.
///
/// The renders use `ImageRenderer`: no window, nothing on screen. They are
/// always made (and checked for size); they are written as PNGs only when
/// `REARC_TABSWITCHER_DIR` names a directory, for example
/// `REARC_TABSWITCHER_DIR=$PWD/dist/tabswitcher swift test --filter TabSwitcherThumbnailTests`.
@MainActor
final class TabSwitcherThumbnailTests: XCTestCase {

    // MARK: Thumbnails

    func testACaptureIsCutToTheTopOfThePageAtThumbnailSize() throws {
        // A tall viewport at 2×: red at the top, blue below.
        let png = try Self.png(width: 1600, height: 2400) { size in
            NSColor.blue.setFill()
            NSRect(origin: .zero, size: size).fill()
            NSColor.red.setFill()
            NSRect(x: 0, y: size.height - 600, width: size.width, height: 600).fill()
        }
        let image = try XCTUnwrap(TabThumbnails.scaled(png))
        XCTAssertEqual(image.width, TabThumbnails.pixelWidth)
        XCTAssertEqual(image.height, 347, "no taller than a card's 3:2")
        XCTAssertLessThanOrEqual(image.width * image.height * 4, 730_000, "about 0.7 MB a thumbnail")
        let top = try Self.pixel(of: image, x: 260, yFromTop: 10)
        XCTAssertGreaterThan(top.red, 200)
        XCTAssertLessThan(top.blue, 60, "the top of the page is kept")
        let bottom = try Self.pixel(of: image, x: 260, yFromTop: 340)
        XCTAssertGreaterThan(bottom.blue, 200)
    }

    func testAWideCaptureKeepsItsWholeHeight() throws {
        let png = try Self.png(width: 2000, height: 800) { size in
            NSColor.green.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        let image = try XCTUnwrap(TabThumbnails.scaled(png))
        XCTAssertEqual(image.width, 520)
        XCTAssertEqual(image.height, 208)
    }

    func testASmallCaptureIsNotEnlargedAndRubbishIsRefused() throws {
        let png = try Self.png(width: 300, height: 150) { size in
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        let image = try XCTUnwrap(TabThumbnails.scaled(png))
        XCTAssertEqual(image.width, 300)
        XCTAssertEqual(image.height, 150)
        XCTAssertNil(TabThumbnails.scaled(Data("not a png".utf8)))
        XCTAssertNil(TabThumbnails.scaled(Data()))
    }

    func testThumbnailsAreOnlyHeldForTheirOwnPageAndGoWithTheTab() {
        let thumbnails = TabThumbnails()
        let tab = Tab(kind: .today, title: "A", url: URL(string: "https://a.test/")!)
        XCTAssertNil(thumbnails.image(for: tab), "a tab that was never shown has none")
        thumbnails.remove(tab.id)
        XCTAssertEqual(thumbnails.revision, 0, "nothing to drop, nothing to redraw")
    }

    // MARK: The switcher keeps working

    func testOpeningTheSwitcherWithNoPageToCaptureStillSwitches() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-tabswitcher-\(UUID().uuidString)")
        let model = BrowserViewModel(store: store,
                                     persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
                                     syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil))
        var clock = Date(timeIntervalSince1970: 5_000)
        store.now = { clock }
        let tabs = (0 ..< 8).map { store.addTab(kind: .today, title: "Tab \($0)", url: URL(string: "https://\($0).test/")!) }
        for tab in tabs {
            clock += 5
            store.selectTab(tab.id)
        }
        model.cycleRecentTabs(forward: true, controlHeld: true)
        let session = model.tabSwitcher
        XCTAssertEqual(session?.items.map(\.id), tabs.reversed().map(\.id), "most recent first, as before")
        XCTAssertEqual(session?.highlighted.id, tabs[6].id)
        // Seven more steps reach the eighth card and wrap: the strip follows.
        let layout = TabSwitcherLayout(itemCount: 8, availableWidth: 1200)
        var first = 0
        var seen: [Int] = []
        for _ in 0 ..< 7 {
            first = layout.firstVisible(showing: model.tabSwitcher?.index ?? 0, from: first)
            seen.append(first)
            model.cycleRecentTabs(forward: true, controlHeld: true)
        }
        XCTAssertEqual(seen, [0, 0, 0, 0, 1, 2, 3])
        XCTAssertEqual(model.tabSwitcher?.index, 0, "wrapped to the tab on screen")
        model.cycleRecentTabs(forward: true, controlHeld: true)
        model.commitTabSwitcher()
        XCTAssertNil(model.tabSwitcher)
        XCTAssertEqual(store.selectedTabID, tabs[6].id)
    }

    // MARK: Renders

    func testRendersOfThePanel() throws {
        let green = SpaceTheme.editorVibrant[6]
        let cases: [(name: String, count: Int, index: Int, dark: Bool, theme: SpaceTheme, width: Double)] = [
            ("light-3-tabs", 3, 1, false, .arcDefault, 1200),
            ("dark-3-tabs", 3, 1, true, .arcDefault, 1200),
            ("light-15-tabs", 15, 1, false, .arcDefault, 1200),
            ("dark-15-tabs", 15, 1, true, .arcDefault, 1200),
            ("light-15-tabs-ninth", 15, 8, false, .arcDefault, 1200),
            ("dark-15-tabs-last", 15, 14, true, .arcDefault, 1200),
            ("light-5-tabs-green-space", 5, 2, false, green, 1200),
            ("dark-5-tabs-green-space", 5, 2, true, green, 1200),
            ("light-15-tabs-narrow-window", 15, 4, false, green, 700),
        ]
        let directory = ProcessInfo.processInfo.environment["REARC_TABSWITCHER_DIR"].map { URL(fileURLWithPath: $0) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for item in cases {
            let items = Self.items(item.count)
            var session = try XCTUnwrap(TabSwitcherSession(items: items, forward: true))
            while session.index != item.index { session.step(forward: true) }
            let layout = TabSwitcherLayout(itemCount: items.count, availableWidth: item.width)
            let first = layout.firstVisible(showing: session.index, from: 0)
            let fakes = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
            let panel = TabSwitcherPanel(
                session: session, layout: layout, first: first, theme: item.theme, dark: item.dark,
                favicon: { fakes[$0.id].flatMap { $0 % 4 == 3 ? nil : Self.favicon($0) } },
                // Every third tab was never shown: no thumbnail.
                thumbnail: { fakes[$0.id].flatMap { $0 % 3 == 2 ? nil : Self.page($0, dark: $0 % 5 == 4) } },
                onSelect: { _ in }
            )
            let size = CGSize(width: item.width, height: 320)
            let content = panel
                .frame(width: size.width, height: size.height)
                .background(Self.backdrop(dark: item.dark))
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage, item.name)
            XCTAssertEqual(image.width, Int(size.width) * 2, item.name)
            XCTAssertEqual(image.height, Int(size.height) * 2, item.name)
            // The panel's surface is where the panel is: in its padding, above the cards.
            let y = Int((size.height - layout.panelHeight) / 2 + 6) * 2
            let pixel = try Self.pixel(of: image, x: image.width / 2, yFromTop: y)
            let surface = TabSwitcherInk.surface(dark: item.dark)
            XCTAssertEqual(Double(pixel.red) / 255, surface.red, accuracy: 0.03, "\(item.name): the panel's fill")
            XCTAssertEqual(Double(pixel.blue) / 255, surface.blue, accuracy: 0.03, "\(item.name): the panel's fill")
            if let directory {
                let rep = NSBitmapImageRep(cgImage: image)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(item.name).png"))
            }
        }
    }

    // MARK: Fakes

    private static let titles = [
        "Feed", "Plex Webplayer and more", "Join the waitlist for Darni", "CLI: log in to several accounts", "Inbox (3)",
        "Storage – Vercel", "Members | widi | Convex Dashboard", "Wallet – Link", "App Store Connect", "Health | dev",
        "GRIT Winter Games 2026", "Listen to Yadim Hunter Jr. Songs", "Pin on Visual", "What's new in Darni", "Pipeline – Dynamics 365",
    ]

    private static func items(_ count: Int) -> [TabSwitcherItem] {
        (0 ..< count).map { index in
            TabSwitcherItem(id: UUID(), title: titles[index % titles.count], url: URL(string: "https://site\(index).test/")!,
                            spaceName: "Main", lastActiveAt: Date(timeIntervalSince1970: Double(10_000 - index)))
        }
    }

    private static func hue(_ index: Int) -> CGFloat { CGFloat((index * 47) % 360) / 360 }

    private static func backdrop(dark: Bool) -> Color {
        dark ? Color(white: 0.11) : Color(white: 0.93)
    }

    /// A stand-in page at a thumbnail's size: a header, a picture and lines of text.
    private static func page(_ index: Int, dark: Bool) -> NSImage {
        let size = NSSize(width: 520, height: 347)
        return NSImage(size: size, flipped: true) { rect in
            (dark ? NSColor(white: 0.08, alpha: 1) : NSColor.white).setFill()
            rect.fill()
            let accent = NSColor(hue: hue(index), saturation: 0.65, brightness: dark ? 0.75 : 0.85, alpha: 1)
            accent.setFill()
            NSRect(x: 0, y: 0, width: size.width, height: 44).fill()
            accent.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: NSRect(x: 28, y: 70, width: 200, height: 130), xRadius: 8, yRadius: 8).fill()
            (dark ? NSColor(white: 1, alpha: 0.75) : NSColor(white: 0, alpha: 0.7)).setFill()
            NSRect(x: 252, y: 76, width: 220, height: 16).fill()
            (dark ? NSColor(white: 1, alpha: 0.3) : NSColor(white: 0, alpha: 0.22)).setFill()
            for line in 0 ..< 9 {
                let y = CGFloat(line < 4 ? 108 + line * 22 : 150 + line * 22)
                let x: CGFloat = line < 4 ? 252 : 28
                let width: CGFloat = (line < 4 ? 220 : 444) - CGFloat((line * 37 + index * 13) % 90)
                NSRect(x: x, y: y, width: width, height: 9).fill()
            }
            return true
        }
    }

    private static func favicon(_ index: Int) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor(hue: hue(index), saturation: 0.7, brightness: 0.8, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 20, dy: 20)).fill()
            return true
        }
    }

    private static func png(width: Int, height: Int, draw: (NSSize) -> Void) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(NSSize(width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private static func pixel(of image: CGImage, x: Int, yFromTop: Int) throws -> (red: Int, green: Int, blue: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Draw the image so that the wanted pixel lands on the context's only one.
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - yFromTop), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }
}
